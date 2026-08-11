// CaptureManager — turns a connected audio source into AMBIENT capture: while the
// source is streaming (an Omi is connected) it runs a capture session, wiring the
// Opus frames → CaptureWAL; on disconnect it ends the session. No "Record" button.
// pause()/resume() stop/start feeding the WAL WITHOUT disconnecting the device.
//
// The source is injected (app: DeviceManager — the live Omi; tests: a controllable
// source / ReplaySource) so the pipeline is identical either way. The per-frame
// path goes through a lock-guarded FrameRouter — never a per-frame main hop — so
// Opus frame order is preserved (the source's callback queue is serial; the WAL's
// io queue is serial) and pause is race-free.

import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
public protocol CaptureManagerTimer: AnyObject {
    func invalidate()
}

extension Timer: CaptureManagerTimer {}

public typealias CaptureManagerDrainTimerFactory =
    @MainActor (
        TimeInterval,
        @escaping @MainActor () -> Void
    ) -> any CaptureManagerTimer

@MainActor
final class ManualCaptureManagerTimer: CaptureManagerTimer {
    private var callback: (@MainActor () -> Void)?
    private(set) var invalidated = false

    func install(_ callback: @escaping @MainActor () -> Void) {
        self.callback = callback
    }

    func fire() {
        guard !invalidated else { return }
        callback?()
    }

    func fireRetainedCallbackForTests() {
        callback?()
    }

    func invalidate() {
        invalidated = true
    }
}

private final class CaptureManagerTaskInstallationGate:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var installed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if installed {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        installed = true
        let current = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in current { waiter.resume() }
    }
}

/// Lock-guarded routing of frames → the active WAL, gated by pause. Lives off the
/// main actor so the source's frame callback never hops actors per frame. Also the
/// single tap point for the audio-level signal: per frame it computes the cheap
/// level (→ the meter) and feeds the silence segmenter (→ conversation boundaries),
/// all under the same lock so order is preserved and pause freezes everything.
final class FrameRouterRouteBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var targetSelected = false
    private var closeWaiting = false
    private var selectedRouteReleased = false

    func pauseAfterTargetSelection() {
        condition.lock()
        targetSelected = true
        condition.broadcast()
        while !selectedRouteReleased { condition.wait() }
        condition.unlock()
    }

    func noteCloseWaiting() {
        condition.lock()
        closeWaiting = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilTargetSelected(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !targetSelected {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func waitUntilCloseIsWaiting(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !closeWaiting {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func releaseSelectedRoute() {
        condition.lock()
        selectedRouteReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

final class FrameRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var wal: CaptureWAL?
    private var paused = false
    private var accountExposureClosed = false
    private var closeAcknowledged = false
    private var selectedRoutesInFlight = 0
    private var closeWaiters:
        [CheckedContinuation<AccountExposureCloseResult, Never>] = []
    private var routeBarrierForTests: FrameRouterRouteBarrier?
    /// Frames routed while NO session WAL is wired yet (the main-actor hop between
    /// `.streaming` and beginSession/resumeSession, or a session roll). Bounded;
    /// drained into the next `setWAL`. Lock-guarded.
    private var preSessionHold: [Data] = []
    private static let preSessionHoldMax = 6_000   // ~60s of Omi audio
    // ARMED LISTENING (ambient Omi, no conversation open yet). While `armed`, frames
    // are metered for the live waveform and kept in a SHORT most-recent-frames ring —
    // but NOT written to a WAL, segmented, transcribed, or persisted as a card. A
    // confirmed speech onset (`onsetDetector`) fires `onSpeechOnset` ONCE; the owner
    // opens the session and `setWAL` drains the ring so nothing said before the gate
    // tripped is lost. This is what stops silence / one-off noise from minting empty
    // "Untitled conversation" cards.
    private var armed = false
    private var preRollRing: [Data] = []
    private static let preRollRingMax = 60         // ~1.2s of Omi audio — the onset pre-roll
    private var onsetDetector = SpeechOnsetDetector()
    private var onsetSignaled = false
    private let segmenter: SilenceSegmenter
    private let clock: () -> TimeInterval
    // True decoded-amplitude RMS level meter (replaces the byte-size proxy). Stateful
    // (one Opus decoder); recreated per capture session via `resetLevelMeter()` so a
    // new stream starts with clean decoder state. Used under this serial lock only.
    private let levelMeter = OpusLevelMeter()
    // Live on-device transcription tap (Feature 1): a SIDE-EFFECT-ONLY consumer of the
    // decoded PCM. Only decodes when `onPCM` is wired (i.e. live preview is enabled +
    // supported), so non-live builds pay nothing. Off the lock, after appendFrame — it
    // never blocks, throws into, or reorders the sacred WAL/upload frame path.
    #if canImport(AVFoundation)
    private let pcmDecoder = OpusPCMDecoder()
    /// Off-main decoded-PCM tap for live transcription (nil ⇒ no live preview).
    var onPCM: ((AVAudioPCMBuffer) -> Void)?
    #endif
    // Diagnostics: how many frames the source has routed in (regardless of pause)
    // and the most recent frame's byte size — surfaced to the UI/log so a flat
    // meter can be told apart from "no frames arriving at all."
    private var frameCount = 0
    private var lastBytes = 0
    // Wall-clock instant (reference-date seconds) of the most recent VOICED frame in the
    // current session (level ≥ the segmenter's silence threshold). Drives the Live
    // Activity's RECORDING-ACTIVE-vs-IDLE phase: capture is only "actively recording" when
    // voice was heard recently, so an extended silence while armed reads as LISTENING (not
    // a live conversation with a ticking timer). nil until the first voiced frame; reset
    // per session with the WAL.
    private var lastVoicedAt: TimeInterval?
    // VOICED frames captured for the CURRENT session (level ≥ the segmenter's silence
    // threshold). Reset when a new capture's WAL is set (a fresh session begins); survives
    // silence-gap segment events. The owner reads this at endSession to decide whether the
    // capture has enough substance to upload (see CaptureManager.minVoicedFramesToUpload).
    private var sessionVoicedFrames = 0
    // When true, the live-STT PCM is supplied DIRECTLY by the source (the phone mic
    // hands us its already-decoded 48 kHz PCM), so we SKIP the internal Opus→PCM decode
    // tap — avoiding an avoidable encode→decode round-trip of latency for live preview
    // (Feature 2). The durable WAL/upload Opus path is unchanged either way.
    private var externalPCM = false

    /// Off-main per-frame level (0…1) for the meter. Must be cheap + non-blocking.
    var onLevel: ((Float) -> Void)?
    /// Off-main conversation boundary; the owner hops to the main actor to act.
    var onSegment: ((SegmentEvent) -> Void)?
    /// Off-main: a real speech onset was heard while ARMED (ambient, no session yet).
    /// The owner hops to the main actor and opens the conversation.
    var onSpeechOnset: (() -> Void)?
    /// Off-main throttled diagnostic line (decode status + level) → the capture log,
    /// so a flat meter / 0-segment capture is debuggable server-side.
    var onDiag: ((String) -> Void)?

    init(segmenter: SilenceSegmenter,
         clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.segmenter = segmenter
        self.clock = clock
    }

    func setWAL(_ w: CaptureWAL?) {
        lock.lock()
        guard !accountExposureClosed else {
            wal = nil
            lock.unlock()
            return
        }
        wal = w
        if w != nil { sessionVoicedFrames = 0; lastVoicedAt = nil }   // fresh session → reset tallies
        // Drain any frames that arrived BEFORE the session's WAL was wired (the
        // @MainActor hop between the source's `.streaming` and beginSession/
        // resumeSession). Without this, early frames — including offline-cache gap
        // audio recovered on reconnect, which the device is then told to ADVANCE
        // past — were silently dropped. Drained UNDER the lock (appendFrame is a
        // cheap async enqueue onto the WAL's own queue) so they are enqueued ahead
        // of every subsequently routed frame — order preserved.
        if let w {
            for f in preSessionHold { w.appendFrame(f) }
            preSessionHold.removeAll()
            // Armed-listening pre-roll → into the session so the speech onset isn't
            // clipped. (Mutually exclusive with preSessionHold: the armed branch above
            // fills only the ring; the non-armed pre-session hop fills only the hold.)
            for f in preRollRing { w.appendFrame(f) }
            preRollRing.removeAll()
            armed = false                 // a session is live now → stop arming
            onsetSignaled = false
            onsetDetector.reset()
        }
        lock.unlock()
    }
    /// Enter/leave ARMED LISTENING (ambient Omi streaming, no conversation yet). Arming
    /// resets the onset detector + pre-roll ring so each listening window starts clean.
    func setArmed(_ b: Bool) {
        lock.lock()
        guard !accountExposureClosed else {
            armed = false
            preRollRing.removeAll()
            preSessionHold.removeAll()
            lock.unlock()
            return
        }
        armed = b
        onsetSignaled = false
        onsetDetector.reset()
        preRollRing.removeAll()
        lock.unlock()
    }
    /// Voiced frames captured for the current session (drives the min-substance upload gate).
    func sessionVoicedFrameCount() -> Int { lock.lock(); defer { lock.unlock() }; return sessionVoicedFrames }
    /// Test seam: whether the router is ARMED (listening for a speech onset, no session yet).
    func isArmedForTests() -> Bool { lock.lock(); defer { lock.unlock() }; return armed }
    /// Wall-clock instant (reference-date seconds) of the most recent voiced frame, or nil
    /// if no voice yet this session — drives the Live Activity's active-vs-idle phase.
    func lastVoicedInstant() -> TimeInterval? { lock.lock(); defer { lock.unlock() }; return lastVoicedAt }
    /// Rebaseline the segmenter's voice clock without changing open/closed state — used on
    /// an Omi reconnect so the brief disconnect gap isn't read as a silence boundary.
    func noteActiveNow() { lock.lock(); segmenter.noteActive(at: clock()); lock.unlock() }
    func setPaused(_ p: Bool) {
        lock.lock()
        paused = p
        if !p { segmenter.noteActive(at: clock()) }   // resume ≠ a silence gap
        lock.unlock()
    }
    func resetSegmenter() { lock.lock(); segmenter.reset(); lock.unlock() }
    /// Wall-clock silence boundary check for the manager's segmentation watchdog,
    /// independent of frame arrival. Returns `.closed` when the open conversation has
    /// been quiet past the gap AND has enough voiced content to stand alone; nil when
    /// paused or no boundary. This is what segments the Omi ambient stream when the
    /// source stops delivering frames during silence (the frame-driven path can't).
    func tickSilence() -> SegmentEvent? {
        lock.lock(); defer { lock.unlock() }
        if paused { return nil }
        return segmenter.checkSilence(at: clock())
    }
    /// Recreate the Opus decoder so a new capture stream starts clean.
    func resetLevelMeter() { lock.lock(); levelMeter.reset(); lock.unlock() }
    /// When true, the source feeds live-STT PCM directly (mic) → skip the decode tap.
    func setExternalPCM(_ b: Bool) { lock.lock(); externalPCM = b; lock.unlock() }
    #if canImport(AVFoundation)
    /// Recreate the live-STT Opus decoder so a new conversation starts clean.
    func resetPCMDecoder() { lock.lock(); pcmDecoder.reset(); lock.unlock() }
    #endif
    func setSilenceGap(_ g: TimeInterval) { lock.lock(); segmenter.silenceGap = g; lock.unlock() }

    /// Diagnostics snapshot for the UI/log: total frames routed + last frame size.
    func stats() -> (count: Int, lastBytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (frameCount, lastBytes)
    }

    func route(_ frame: Data) {
        lock.lock()
        guard !accountExposureClosed else {
            lock.unlock()
            return
        }
        let isPaused = paused
        // Count only frames we actually CAPTURE. When paused the BLE source still
        // delivers frames (we drop them), but the counter must FREEZE so a paused
        // capture doesn't look like it's still recording.
        if !isPaused {
            frameCount += 1
            lastBytes = frame.count
        }
        // ARMED LISTENING: meter the waveform + keep a short pre-roll ring + watch for a
        // real speech onset. No WAL, no segmenter, no transcription, no durable card — so
        // silence or a one-off noise never opens an empty conversation. The onset fires
        // once → the owner opens the session → setWAL drains the ring (no clipped onset).
        if armed && !isPaused {
            let lvl = levelMeter.level(for: frame)
            preRollRing.append(frame)
            if preRollRing.count > Self.preRollRingMax {
                preRollRing.removeFirst(preRollRing.count - Self.preRollRingMax)
            }
            let voiced = lvl >= segmenter.silenceThreshold
            var fireOnset = false
            if !onsetSignaled, onsetDetector.observe(voiced: voiced) {
                onsetSignaled = true
                fireOnset = true
            }
            lock.unlock()
            onLevel?(lvl)                 // the "Listening…" waveform still breathes
            if fireOnset { onSpeechOnset?() }
            return
        }
        let target = isPaused ? nil : wal
        let selectedDurableTarget = target != nil
        if selectedDurableTarget { selectedRoutesInFlight += 1 }
        let routeBarrier = selectedDurableTarget ? routeBarrierForTests : nil
        // No session WAL yet (pre-session window)? HOLD the frame instead of
        // dropping it — setWAL drains in order. Bounded: past the cap the newest
        // frames are dropped (the hold's contiguous head is the audio that matters).
        if !isPaused, wal == nil, preSessionHold.count < Self.preSessionHoldMax {
            preSessionHold.append(frame)
        }
        var level: Float = 0
        var event: SegmentEvent?
        if !isPaused {
            level = levelMeter.level(for: frame)   // true Opus→PCM RMS (perceptual 0…1)
            event = segmenter.observe(level: level, at: clock())
            // Voiced-frame accounting for the substance gate — the SAME voice/silence
            // definition the segmenter uses (level ≥ its silence threshold). Also stamp the
            // most-recent voiced instant so the Live Activity can tell RECORDING-ACTIVE
            // (recent voice) from LISTENING/IDLE (armed but silent).
            if level >= segmenter.silenceThreshold { sessionVoicedFrames += 1; lastVoicedAt = clock() }
        }
        // Diag locals (read under lock): first few frames + every 50th, plus the
        // decode outcome, so a flat meter's cause is visible.
        let fc = frameCount, lb = lastBytes, hasWAL = wal != nil
        let dstatus = levelMeter.lastStatus, dpcm = levelMeter.lastPCMFrames
        let drms = levelMeter.lastRMS, dconv = levelMeter.hasConverter
        let dcookie = levelMeter.lastCookieStatus
        let emitDiag = !isPaused && (fc <= 3 || fc % 50 == 0)
        let useExternalPCM = externalPCM
        lock.unlock()
        routeBarrier?.pauseAfterTargetSelection()
        target?.appendFrame(frame)
        if !isPaused {
            onLevel?(level)
            #if canImport(AVFoundation)
            // Live-transcription tap: decode the SAME packet to PCM and hand it off.
            // Strictly additive + downstream of appendFrame — a decoder/transcriber
            // failure can never affect the durable capture. Only runs when live preview
            // is wired (onPCM set) AND the source isn't already feeding PCM directly (the
            // phone mic supplies its decoded PCM straight to the transcriber, Feature 2).
            // `route` is serial (serial source queue), so the stateful decoder is fed
            // serially.
            if !useExternalPCM, let onPCM, let buf = pcmDecoder.decode(frame) { onPCM(buf) }
            #endif
            if let e = event { onSegment?(e) }
            if emitDiag {
                onDiag?(String(format: "cap frame#%d bytes=%d wal=%@ level=%.3f decode[conv=%@ cookie=%d status=%d pcm=%d rms=%.4f]",
                               fc, lb, hasWAL ? "y" : "n", level, dconv ? "y" : "n", Int(dcookie), Int(dstatus), dpcm, drms))
            }
        }
        if selectedDurableTarget { finishSelectedRoute() }
    }

    func setRouteBarrierForTests(_ barrier: FrameRouterRouteBarrier?) {
        lock.lock()
        routeBarrierForTests = barrier
        lock.unlock()
    }

    /// Terminally close this router and wait for a frame that already selected the
    /// old WAL to enqueue its append. New routes and future WAL wiring are rejected,
    /// and both pre-session holds are erased at the privacy boundary.
    func closeAccountExposure() async -> AccountExposureCloseResult {
        await withCheckedContinuation { continuation in
            beginAccountExposureClose(continuation)
        }
    }

    private func beginAccountExposureClose(
        _ continuation:
            CheckedContinuation<AccountExposureCloseResult, Never>
    ) {
        lock.lock()
        if closeAcknowledged {
            lock.unlock()
            continuation.resume(returning: .alreadyClosed)
            return
        }
        accountExposureClosed = true
        wal = nil
        armed = false
        paused = true
        preSessionHold.removeAll()
        preRollRing.removeAll()
        onsetSignaled = false
        onsetDetector.reset()
        if selectedRoutesInFlight == 0 {
            closeAcknowledged = true
            lock.unlock()
            continuation.resume(returning: .closed)
            return
        }
        closeWaiters.append(continuation)
        let barrier = routeBarrierForTests
        lock.unlock()
        barrier?.noteCloseWaiting()
    }

    private func finishSelectedRoute() {
        lock.lock()
        selectedRoutesInFlight -= 1
        guard accountExposureClosed, selectedRoutesInFlight == 0 else {
            lock.unlock()
            return
        }
        closeAcknowledged = true
        let waiters = closeWaiters
        closeWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: .closed) }
    }
}

@MainActor
public final class CaptureManager: ObservableObject {
    @Published public private(set) var captures: [CaptureWAL] = [] {
        didSet { rebuildVisibleCaptures() }
    }

    /// Captures worth showing, newest-first. STORED (not computed) — recomputed only when
    /// the capture SET changes, never per render. The filter/sort touch disk
    /// (`hasCachedTranscript`, `startTime` → `meta.json`); doing that inside a computed
    /// property meant 56 disk stats on every SwiftUI invalidation → scroll jank. Now the
    /// list view just reads this array.
    @Published public private(set) var visibleCaptures: [CaptureWAL] = []

    /// Scan-free warm seed for the FIRST paint of the Capture list (T1 AC5): the newest
    /// captures' captureId + title + date, read from `card.json` ONLY — NO CaptureWAL /
    /// segment scan (the per-segment stat storm is what hung launch, so it stays off-main
    /// in `loadExisting`). Seeded synchronously when source ownership activates; the
    /// Capture list renders these populated rows immediately and swaps to the real WAL
    /// cards the instant off-main hydration publishes `visibleCaptures` (which clears this).
    @Published public private(set) var listRows: [ConversationRowLite] = [] {
        didSet {
            // One-shot: the "load-to-zero" number nobody had — wall-time from
            // startup to the FIRST non-empty capture list (whether it came from
            // the warm seed or off-main hydration). Emitted once per launch.
            if firstPaintPending, !listRows.isEmpty {
                firstPaintPending = false
                if let s = firstPaintSpan { PerfHook.span("capture-list-first-paint", ms: s.elapsedMs()) }
            }
        }
    }
    /// Time-to-first-row instrumentation (see `listRows.didSet`). Armed at startup.
    private var firstPaintSpan: PerfSpan?
    private var firstPaintPending = false

    /// Recompute the visible list. Hide ones that recorded NOTHING (0 segments, not
    /// streaming) — useless empty cards; keep ones with real audio, still-streaming, or a
    /// pruned-to-transcript tombstone. Order newest-first by the durable conversation start.
    private func rebuildVisibleCaptures() {
        rebuildCountForTests += 1
        invalidateLastFinishedMemo()   // membership/order/active just moved
        let visible = CaptureManager.deduplicatedByCaptureId(captures)
            .filter { self.isBrowsable($0) }
            .sorted { self.startTime(of: $0) > self.startTime(of: $1) }
        visibleCaptures = visible
        // Once the real WAL cards exist, the scan-free seed has done its job — drop it so
        // the list renders from one source of truth (and the seed can't linger stale).
        if !visible.isEmpty, !listRows.isEmpty { listRows = [] }
        // Count "still processing" conversations HERE (the single list-rebuild choke
        // point) so the processing banner reads a cached count — no per-render disk
        // churn. A conversation is processing when it has real audio but no transcript
        // yet (not cached, not confirmed in Lore) and isn't the live recording.
        // Reads the per-capture sidecar MEMO (seeded off-main at hydration) — no disk here.
        processingConversationCount = visible.filter { wal in
            let snap = sidecar(for: wal.captureId)
            return wal !== active
                && wal.status.totalSegments > 0
                && !snap.hasLocalTranscriptText
                && !snap.confirmedInLore
        }.count
        statsSummary = makeStatsSummary(for: visible)
        persistWarmListIndexIfChanged(from: visible)
    }

    /// The captureIds last written to the warm-rows index — so a rebuild that didn't change the
    /// top-N set skips the (off-main) rewrite.
    private var lastIndexedIds: [String] = []
    private var warmListIndexTasks: [UUID: Task<Void, Never>] = [:]
    private var latestWarmListIndexTask: Task<Void, Never>?
    private var sidecarWarmTasks: [UUID: Task<Void, Never>] = [:]

    /// Persist the top `warmSeedCount` warm rows to the durable single-file index (T3, WS-B),
    /// OFF the main actor, whenever the top-N set changes (a new/reordered conversation, or the
    /// first hydration). The main actor only snapshots ids + memoised durable starts; the
    /// detached task reads each card + writes the file. A slightly-stale title is tolerated — the
    /// real cards replace these rows the instant hydration publishes `visibleCaptures`.
    private func persistWarmListIndexIfChanged(from visible: [CaptureWAL]) {
        guard !accountExposureClosing, !accountExposureClosed else { return }
        guard !visible.isEmpty else { return }
        let snapshot: [(id: String, started: UInt64)] = visible.prefix(Self.warmSeedCount).map {
            ($0.captureId, UInt64(max(0, startTime(of: $0))))
        }
        let ids = snapshot.map(\.id)
        guard ids != lastIndexedIds else { return }
        lastIndexedIds = ids
        let base = baseDir
        let predecessor = latestWarmListIndexTask
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            if let predecessor { await predecessor.value }
            guard !Task.isCancelled else {
                self?.warmListIndexTasks[taskID] = nil
                return
            }
            await Task.detached(priority: .utility) {
                var rows: [ConversationRowLite] = []
                rows.reserveCapacity(snapshot.count)
                for s in snapshot {
                    guard !Task.isCancelled else { return }
                    let card = ConversationCardStore.load(
                        captureId: s.id, baseDir: base)
                    let started = card?.startedAt ?? s.started
                    let title = (card?.title?.isEmpty == false)
                        ? card!.title!
                        : "Voice note"
                    rows.append(ConversationRowLite(
                        captureId: s.id,
                        title: title,
                        dateLabel: CaptureManager.warmDateLabel(started)))
                }
                guard !Task.isCancelled else { return }
                WarmListIndexStore.save(rows, baseDir: base)
            }.value
            self?.warmListIndexTasks[taskID] = nil
        }
        warmListIndexTasks[taskID] = task
        latestWarmListIndexTask = task
    }

    /// Test seam: force a visible-list rebuild WITHOUT any invalidation, so a test can prove
    /// the rebuild reads the per-capture sidecar MEMO and not disk (in production a `captures`
    /// mutation is the trigger). Internal — reachable only via `@testable import`.
    func rebuildVisibleCapturesForTests() { rebuildVisibleCaptures() }

    /// Test seam: attach a live, mid-stream WAL as the active capture (inserted at the head of
    /// `captures`, exactly where `beginSession` puts a real one) WITHOUT wiring the audio
    /// source / segmenter. Lets the drain-gate streaming-eligibility path be driven
    /// deterministically. Internal — reachable only via `@testable import`.
    func attachStreamingWALForTests(_ wal: CaptureWAL) {
        active = wal
        captures.insert(wal, at: 0)
    }

    /// Test seam: how many times the visible conversation list has been rebuilt. The
    /// acceptance instrument for the live/library split (track 20260722T1244) — N live
    /// transcript/title publishes must move this ZERO. Internal — `@testable` only.
    private(set) var rebuildCountForTests = 0

    /// Test seam: drive ONE live-transcript tick through the EXACT path the transcriber
    /// pump uses (`live.transcript` + the rolling-title update), with no transcriber, no
    /// audio source and no timers running — so a test can prove that a live tick
    /// invalidates only `live`, never the manager (and so never the conversation list).
    func publishLiveSnapshotForTests(_ snapshot: LiveTranscript) {
        live.transcript = snapshot
        updateLiveTitle(with: snapshot)
    }

    /// How many visible conversations are still being processed (audio captured, no
    /// transcript yet) — drives the top-of-list processing banner. Recomputed only on
    /// list rebuild, so reading it per render is free.
    @Published public private(set) var processingConversationCount: Int = 0

    /// Cached local library stats for the "Your library" page. Recomputed only when
    /// the visible conversation list is rebuilt, so SwiftUI renders never read disk.
    @Published public private(set) var statsSummary: StatsSummary = .empty

    /// When a conversation last finished processing (B3). Set at the END of the
    /// finalize success path alongside the `.foundryxConversationFinalized` post,
    /// so the Activity recap can rebuild the DAILY recap live as the day fills in.
    @Published public private(set) var lastFinalizedAt: Date?

    private func makeStatsSummary(for visible: [CaptureWAL]) -> StatsSummary {
        // Both inputs come from MEMORY, and both are COUNTS: meta from the metaCache
        // (warmed at hydration, refreshed off-main on every meta write), word +
        // distinct-speaker counts from the sidecar memo, derived once off-main at warm.
        // Nothing here splits, lowercases or traverses transcript text — that per-rebuild
        // full-library text scan is exactly what made the rebuild O(total transcript bytes).
        let snapshots = visible.map { wal in
            let snap = sidecar(for: wal.captureId)
            return StatsConversationSnapshot(
                captureId: wal.captureId,
                meta: cachedMeta(wal.captureId),
                wordCount: snap.wordCount,
                speakerIdentities: snap.speakerIdentities
            )
        }
        return StatsSummary.build(from: snapshots)
    }

    /// Collapse any duplicate capture-ids, keeping the FIRST occurrence. The door keys
    /// transcript `/content` by exact `externalId == capture_id`, so the ONLY way one
    /// transcript can appear under two list rows is two rows sharing a capture-id — this
    /// enforces the "one row per capture" invariant the list renders by (`id: \.captureId`),
    /// guaranteeing no duplicate entries regardless of how a dup id entered the array.
    public nonisolated static func deduplicatedByCaptureId(_ wals: [CaptureWAL]) -> [CaptureWAL] {
        var seen = Set<String>()
        var out: [CaptureWAL] = []
        out.reserveCapacity(wals.count)
        for w in wals where seen.insert(w.captureId).inserted { out.append(w) }
        return out
    }

    /// A conversation belongs in the all-time list when it has real audio / is
    /// streaming, OR it has any durable readable tombstone — a cached transcript, the
    /// lightweight name/description card, or a confirmed-in-Lore marker. This keeps a
    /// conversation browsable forever (with its name + description) even after its
    /// audio AND its transcript text have been pruned. Empty (0-segment) captures with
    /// no tombstone are still hidden (useless cards).
    private func isBrowsable(_ wal: CaptureWAL) -> Bool {
        // All sidecar state (discard/delete markers, transcript text, card + confirmed
        // tombstones) reads from the per-capture MEMO — no synchronous disk I/O here (R3).
        let snap = sidecar(for: wal.captureId)
        if snap.isDiscarded { return false }   // sub-substance junk fragment — never show
        if snap.isDeleted { return false }     // user-deleted captures never show again
        if wal.status.streaming { return true }   // the active capture always shows
        let id = wal.captureId
        // If we hold judge-able transcript text locally, HIDE empty / near-silent /
        // filler captures — they pollute the timeline with useless noise cards
        // (track 20260628T1654; Omi empty-conversation gates). Data is kept, not shown.
        // The verdict is taken over the CACHED meaningful-word count derived off-main at
        // sidecar warm — no transcript text is scanned on this path, which is what makes
        // the rebuild independent of total transcript bytes.
        if snap.hasLocalTranscriptText {
            // S2 (no lenient flip) — `nil` duration means "unknown → KEEP" to the filter, so a
            // MISSING meta memo would flip a borderline (exactly-one-meaningful-word, short)
            // card from hidden to VISIBLE and then hide it again when the warm landed: the
            // appear→vanish flicker R3 forbids. A missing memo is NOT the same as a memoised
            // meta that simply has no duration yet (still recording — that stays lenient, as
            // before). When we hold NO memo at all we resolve conservatively — as a short clip
            // — which is the same "stay hidden until the real facts land" direction the
            // `.unwarmed` placeholder takes, and the only direction that cannot flicker.
            let duration: TimeInterval?
            if metaCache[id] == nil {
                scheduleSidecarWarm(id)
                duration = 0
            } else {
                duration = conversationDurationSeconds(id)
            }
            return ConversationContentFilter.isMeaningful(
                meaningfulWordCount: snap.meaningfulWordCount,
                durationSeconds: duration)
        }
        // No transcript text yet (still processing): keep the prior visibility rule —
        // show real-audio / tombstoned captures, hide 0-segment empties.
        if CaptureManager.isWorthShowing(wal.status) { return true }
        return snap.hasCachedTranscript || snap.cardExists || snap.confirmedInLore
    }

    /// The conversation's duration (seconds) from its durable meta, or nil when not yet
    /// finalized — drives Omi's "higher bar for short clips" empty filter. Reads the
    /// memoised `metaCache` (warmed at hydration, invalidated on every meta write), so the
    /// filler filter costs no disk on the rebuild path.
    private func conversationDurationSeconds(_ captureId: String) -> TimeInterval? {
        guard let dur = cachedMeta(captureId)?.durationSeconds else { return nil }
        return TimeInterval(dur)
    }

    /// A capture's durable conversation REAL START (unix seconds) for date grouping +
    /// ordering. Resolution order, all stable across relaunch / re-ingest:
    ///   1. `meta.json` start — the authoritative recorded conversation start.
    ///   2. `card.json` `started_at` — the durable tombstone (set from meta, else id).
    ///   3. the capture-id's UTC timestamp — a fixed instant baked into the id.
    ///   4. (last resort only) the WAL's in-memory `startedAt` — which is re-stamped to
    ///      LAUNCH time when an existing capture is reloaded, so it must never win when
    ///      any durable source exists. This was the bug: meta-less captures dated to
    ///      launch time and piled up under "Today".
    /// We memoise only the durable (1–3) resolutions; the launch-time fallback is left
    /// uncached so a late-arriving meta/card is picked up next pass.
    private var startTimeCache: [String: TimeInterval] = [:]
    private func startTime(of wal: CaptureWAL) -> TimeInterval {
        if let cached = startTimeCache[wal.captureId] { return cached }
        // A cold miss here used to be driver #4: `durableStart` BYPASSED the meta memo and
        // decoded `meta.json`/`card.json` off DISK on the main actor, so the first
        // post-hydration sort paid N synchronous decodes (370ms at N=175). It now resolves
        // from MEMORY ONLY — the warm `metaCache` and the sidecar memo's `cardStartedAt`,
        // both seeded during the off-main hydration hop. If neither memo exists yet (a
        // capture the manager has never seen) we schedule the off-main warm and answer from
        // the capture-id's baked-in timestamp; the warm hop clears this memo so the durable
        // answer replaces it.
        if metaCache[wal.captureId] == nil { scheduleSidecarWarm(wal.captureId) }
        if let t = durableStartCached(captureId: wal.captureId) {
            startTimeCache[wal.captureId] = t
            return t
        }
        return wal.status.startedAt.timeIntervalSince1970
    }

    /// `durableStart`'s resolution order (meta → card → capture-id time) taken over MEMORY
    /// ONLY — the memoised meta + the sidecar memo's cached `card.json` start. Used by the
    /// sort comparator, which must never touch disk on the main actor.
    private func durableStartCached(captureId: String) -> TimeInterval? {
        if let memo = metaCache[captureId], let meta = memo, meta.startedAt > 0 {
            return TimeInterval(meta.startedAt)
        }
        if let started = sidecarCache[captureId]?.cardStartedAt, started > 0 {
            return TimeInterval(started)
        }
        if let idStart = CaptureIdTime.startedAt(fromCaptureId: captureId), idStart > 0 {
            return TimeInterval(idStart)
        }
        return nil
    }

    /// Test seam: drop the memoised durable-start cache so a subsequent measured rebuild
    /// re-pays the COLD sort cost (driver #4) in isolation — the first-post-hydration
    /// `durableStart` disk reads. Mirrors the other `*ForTests` seams; internal (reachable
    /// only via `@testable import`), no production effect.
    func invalidateStartTimeCacheForTests() { startTimeCache.removeAll() }

    /// Test seam (review S6): DROP the sidecar memo entirely for `ids`, leaving NO entry at
    /// all — the genuine COLD-MISS state `sidecar(for:)` handles. Production never reaches
    /// this state after hydration (`invalidateSidecar` keeps the last-known memo on purpose),
    /// which is precisely why the disk-free gate needs a seam that does: without it, "the
    /// rebuild does zero main-actor decodes" is true by construction and the assertion can no
    /// longer fail for the reason it exists. Internal — reachable only via `@testable import`.
    func dropSidecarMemoForTests(_ ids: [String]) {
        for id in ids {
            sidecarCache[id] = nil
            metaCache[id] = nil
            startTimeCache[id] = nil
        }
    }

    /// Test seam (review S2): drop ONLY the memoised meta, leaving the sidecar memo warm —
    /// the state in which a missing duration could flip `isBrowsable` in the LENIENT
    /// direction and make a hidden card appear and then vanish. Internal.
    func dropMetaMemoForTests(_ ids: [String]) {
        for id in ids { metaCache[id] = nil }
    }

    /// Test seam: how many captures currently hold a WARM sidecar memo — lets a test wait for
    /// the off-main re-warms scheduled by a cold-miss rebuild to have landed.
    var warmSidecarMemoCountForTests: Int { sidecarCache.values.filter(\.isWarm).count }

    /// The durable (processing-time-proof) start for a capture, or nil if none of the
    /// stable sources are available (only then does the caller fall back to WAL time).
    private func durableStart(captureId: String) -> TimeInterval? {
        if let meta = ConversationMetaStore.load(captureId: captureId, baseDir: baseDir),
           meta.startedAt > 0 {
            return TimeInterval(meta.startedAt)
        }
        if let started = ConversationCardStore.load(captureId: captureId, baseDir: baseDir)?.startedAt,
           started > 0 {
            return TimeInterval(started)
        }
        if let idStart = CaptureIdTime.startedAt(fromCaptureId: captureId), idStart > 0 {
            return TimeInterval(idStart)
        }
        return nil
    }

    /// The durable conversation start as a `Date` (for the list's time grouping). Public
    /// wrapper over the same memoised `meta.json`-preferring start used to order the list.
    public func conversationStartDate(_ wal: CaptureWAL) -> Date {
        Date(timeIntervalSince1970: startTime(of: wal))
    }

    /// True once a transcript has been cached locally for this capture (used to keep a
    /// pruned/tombstoned conversation visible + to drive the card's "Ready" chip).
    ///
    /// Served from the per-capture sidecar memo (the fact is derived off-main in
    /// `loadSidecar`): this is read ONCE PER RENDERED ROW, and a `fileExists` per row per
    /// render is per-row disk on the main actor. Same freshness rule as `cardMeta` — a
    /// known-stale memo (a write's re-read still in flight, or a throttled re-read not yet
    /// started) falls back to the real stat. See `freshMemo(for:)`.
    public func hasCachedTranscript(_ captureId: String) -> Bool {
        if let snap = freshMemo(for: captureId) { return snap.hasCachedTranscript }
        return TranscriptCacheStore.hasCachedTranscript(captureId: captureId, baseDir: baseDir)
    }

    /// The per-capture sidecar memo, but ONLY when it is known-fresh — the single freshness
    /// rule every memo-served render read shares (`cardMeta`, `hasCachedTranscript`).
    ///
    /// Fresh means all three:
    ///   • WARM (it has actually been derived, not the `.unwarmed` placeholder);
    ///   • no re-read IN FLIGHT (`warmingSidecars`) — a write already invalidated it and the
    ///     off-main re-derive has not landed, so the memo is known-stale;
    ///   • no re-read PENDING BEHIND THE LIVE THROTTLE (`liveSidecarWarmPending`). This third
    ///     clause is not redundant: `invalidateSidecar`'s throttled branch (the ACTIVE
    ///     capture, within `liveSidecarRewarmInterval`) calls `discardInFlightSidecarWarm`,
    ///     which CLEARS `warmingSidecars[id]` while leaving `sidecarCache[id]` warm and
    ///     known-stale. Without this clause the active capture's card/Ready fact could be
    ///     served stale for up to the throttle window (5s) after a write — so the "a caller
    ///     can never observe a value older than the last write" contract would hold for every
    ///     capture EXCEPT the live one. Cost is bounded: at most one capture (the active one)
    ///     takes the disk path, only between a write and its throttled re-warm.
    private func freshMemo(for captureId: String) -> SidecarSnapshot? {
        guard let snap = sidecarCache[captureId], snap.isWarm,
              warmingSidecars[captureId] == nil,
              !liveSidecarWarmPending.contains(captureId) else { return nil }
        return snap
    }

    /// A capture is worth showing if it has ≥1 recorded segment, or is actively streaming
    /// (a just-started capture that hasn't flushed its first segment yet).
    public nonisolated static func isWorthShowing(_ status: CaptureStatus) -> Bool {
        status.totalSegments > 0 || status.streaming
    }

    /// The live audio meter's observable state, deliberately SEPARATE from the
    /// manager so its 12 Hz tick invalidates only the small meter strip view.
    @MainActor public final class AudioMeterModel: ObservableObject {
        /// Rolling audio-level bars (0…1, oldest→newest) for the live meter (req 8).
        @Published public fileprivate(set) var levels: [Float]
        /// Diagnostics (surfaced on the capture screen): total Opus frames the BLE
        /// source has delivered into the pipeline, and the last frame's byte size. A
        /// flat meter with framesReceived==0 ⇒ the device isn't notifying; >0 ⇒ frames
        /// arrive (then the meter/levels are the thing to look at).
        @Published public fileprivate(set) var framesReceived: Int = 0
        @Published public fileprivate(set) var lastFrameBytes: Int = 0
        /// Whether every bar is already zero — lets the tick skip publishing entirely
        /// while idle (no invalidation at all when nothing is audible).
        fileprivate var isFlat = true
        fileprivate init(barCount: Int) { levels = Array(repeating: 0, count: barCount) }
    }

    /// The LIVE recording surface's observable state, deliberately SEPARATE from the
    /// manager for the same reason `AudioMeterModel` is: these fields are written on
    /// EVERY transcriber snapshot — several times per second while recording. Left as
    /// `@Published` vars on the manager, each tick invalidated every view that observes
    /// the manager: the whole Capture screen, the MainTabs body, and with them the
    /// conversation LIST — turning a ~2ms list rebuild into a multi-second freeze by
    /// sheer frequency (track 20260722T1244). The split is live-surface vs LIBRARY:
    /// list/library state stays on the manager, which no longer changes on a live tick.
    ///
    /// `CaptureManager` still READS these directly (R4): the substance gate in
    /// `endSession` reads `transcript.displayText` to decide whether a conversation is
    /// real, and the settled title seeds the provisional card. Reading a plain property
    /// on an injected object is exactly as available as reading a stored one — what
    /// changes is only WHO gets invalidated on a write.
    @MainActor public final class LiveCaptureModel: ObservableObject {
        /// The live, on-device PROVISIONAL transcript for the ACTIVE conversation.
        @Published public fileprivate(set) var transcript: LiveTranscript = .empty
        /// The ROLLING live title for the ACTIVE conversation.
        @Published public fileprivate(set) var title: String?
        /// Ambient candidates surfaced by the Tier-1 lane DURING the active recording.
        @Published public fileprivate(set) var candidates: [AmbientCandidate] = []
        fileprivate init() {}
    }
    @Published public private(set) var active: CaptureWAL? {
        // `lastFinishedConversation()` EXCLUDES the active capture, so which capture is
        // active is one of its inputs — a session that begins or ends must re-derive it.
        didSet {
            invalidateLastFinishedMemo()
            if active != nil {
                let waiters = activeCaptureWaitersForTests
                activeCaptureWaitersForTests.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
    }

    #if DEBUG
    /// DEV-only: seed a throwaway active session so the recording pill renders in a
    /// screenshot (`-CapturePhase`). Visual proof only — no audio, no upload; the
    /// elapsed clock starts now. No effect in a normal (non-preview) launch.
    public func seedPreviewSession(target: DoorTarget) {
        if active == nil {
            active = CaptureWAL(captureId: "preview-active", target: target)
        }
    }
    #endif
    @Published public private(set) var sourceState: AudioSourceState = .idle
    /// Ambient capture is paused (device stays connected; frames are dropped).
    @Published public private(set) var isPaused: Bool = false
    /// The 12 Hz live audio meter, ISOLATED in its own observable so its tick
    /// invalidates only the meter strip — not the whole capture screen. When these
    /// lived as @Published vars on the manager, every 1/12 s tick re-rendered the
    /// entire conversation list, and each row re-read meta.json/card.json off disk:
    /// ~250 synchronous main-thread file reads PER SECOND (deep-review finding,
    /// 2026-07-07 — the single biggest "app feels slow" cause).
    public let meter: AudioMeterModel
    /// The LIVE recording surface's fast-moving text state (transcript + rolling title +
    /// ambient candidates), ISOLATED in its own observable for the same reason as the
    /// meter: its several-times-a-second publishes must invalidate only the live surface,
    /// never the conversation list. See `LiveCaptureModel`.
    public let live: LiveCaptureModel
    /// Silence gap (seconds) that auto-ends a conversation (req 9). Persisted.
    @Published public private(set) var silenceGapSeconds: TimeInterval

    /// The live, on-device PROVISIONAL transcript for the ACTIVE conversation
    /// (Feature 1). An ephemeral PREVIEW only — it empties when no conversation is
    /// open, and the AUTHORITATIVE transcript still comes from Kiln (door → Lore →
    /// Kiln). Stays `.empty` when live transcription is unavailable (older OS / no
    /// model / no factory wired), so the UI simply shows nothing extra.
    ///
    /// Stored on `live` (NOT `@Published` here) — reading it costs nothing and keeps every
    /// existing caller, including the substance gate, working unchanged; writing it no
    /// longer invalidates the library.
    public var liveTranscript: LiveTranscript { live.transcript }
    /// The ROLLING live title — derived from the WHOLE conversation to this point
    /// (track 20260717T1015): a cheap whole-context salience heuristic on new
    /// finalized words, upgraded on a debounced cadence by the on-device titler
    /// where one is wired. Stabilized by `LiveTitleArbiter` (a settled name only
    /// changes when meaningfully different). The ONE title both the recording
    /// screen and the capture hero tile render. Ephemeral — the post-recording
    /// pipeline's title stays authoritative. Stored on `live` (see `liveTranscript`).
    public var liveTitle: String? { live.title }
    /// True while the retry/drain loop is actively trying to move local work toward
    /// the desktop (segment upload, finalize retry, or delete retry). The sync banner
    /// uses this instead of equating "unsynced bytes exist" with "a drain is in flight".
    @Published public private(set) var drainActive = false
    /// User-initiated recovery lanes. Kept separate from the automatic drain so an
    /// expired capture can be retried without allowing two syncs of the same WAL.
    @Published public private(set) var manuallyRecoveringCaptureIds: Set<String> = []

    /// Number of bars in the meter window (~4s at the 12 Hz sample tick).
    public static let meterBarCount = 48

    private let target: DoorTarget
    /// Identity generation captured with this manager. App-Group and Live Activity
    /// producers must never publish after this generation is replaced.
    private let accountBinding: CaptureAccountScope.AccountBinding?
    /// One-time account-owner preference handoff. Normal app construction installs
    /// this immediately after the account binding is published; a missing owner stays
    /// fail-closed for locked/pending restoration.
    private var capturePreferenceSnapshotInstalled = false
    /// Internal (not private) so organizer helpers in the module can reach the
    /// same capture tree (search text, segment sizes, category store).
    let baseDir: URL
    private let log: DoorLog?
    private let source: AudioFrameSource
    /// Optional SECOND frame source: the phone's own microphone (a `MicFrameSource`).
    /// Wired into the SAME router/WAL/lifecycle as the Omi — the mic is just another
    /// frame source. Started/stopped explicitly via the Record control (not ambiently).
    private let micSource: AudioFrameSource?
    private let router: FrameRouter
    private var ownerActivated = false

    /// Whether a phone-mic source is wired (drives the Record control's availability).
    public var phoneMicAvailable: Bool { micSource != nil }
    /// True while the phone mic is actively recording (drives the Record/Stop button).
    @Published public private(set) var isRecordingMic: Bool = false
    /// Whether the user MINIMIZED the full-screen recording surface (recording keeps
    /// running; the app becomes reachable again and the persistent pill offers the way
    /// back). Reset to false whenever a fresh recording STARTS and whenever one is
    /// explicitly STOPPED/ended, so a new recording always presents full-screen.
    @Published public private(set) var recordingScreenMinimized = false
    /// A surface that OWNS THE SCREEN and is driving capture itself (today: onboarding's
    /// first-note step) holds this for its lifetime, and the library's recording cover
    /// stays down regardless of the session lifecycle.
    ///
    /// `recordingScreenMinimized` is deliberately NOT enough: it is reset to false on
    /// every fresh start, on `armForSpeech`, and when an ambient capture opens — so a
    /// caller that minimizes once gets overridden the moment the session actually
    /// establishes, and the full-screen recorder slams up over whatever was there. That
    /// is a real defect, not a test artifact: it dropped a user out of onboarding
    /// mid-flow, and they finished on Capture home having never seen the rest.
    @Published public var suppressesRecordingSurface = false
    /// The session-owned, pause-aware elapsed clock (track 20260717T0630). Anchored to
    /// the RECORDING SESSION, not the conversation: internal silence-gap rolls PRESERVE
    /// it (`beginSession` stamps only when nil), and ONLY explicit boundaries clear it
    /// (phone-mic stop, End-current / manual split, reconnect-grace expiry). Views DERIVE
    /// the readout from this — they hold no timer or pause `@State` — so a re-present
    /// (minimize → restore) can never reset it or lose its paused deductions.
    @Published public private(set) var recordingClock: RecordingClock?
    /// Ambient candidates surfaced by the Tier-1 lane DURING the active recording —
    /// most-recent-first, deduped by utterance, capped small. The recording screen maps
    /// these to its notification/task rows; cleared when the conversation ends.
    /// Stored on `live` (see `liveTranscript`).
    public var recordingCandidates: [AmbientCandidate] { live.candidates }
    /// How many recording candidates the surface will stack at once.
    private static let maxRecordingCandidates = 3
    /// Why the last record-tap did nothing, or nil when the last start succeeded / none
    /// attempted. Lets the Record CTA explain a SILENT block (no mic source / permission,
    /// or an in-flight conversation) instead of tapping into a void.
    @Published public private(set) var lastRecordBlockReason: String?
    /// The user's chosen capture device (Omi vs phone mic). Persisted. Selecting the
    /// phone mic stops the Omi from auto-grabbing an ambient session.
    @Published public private(set) var captureSource: CaptureSourceKind = CaptureSettings.captureSource
    private let levelBuffer = LevelBuffer()
    private var drainTimer: (any CaptureManagerTimer)?
    private var meterTimer: Timer?
    private let drainTimerFactory: CaptureManagerDrainTimerFactory
    private let hydrationBeforeCommit: (@Sendable () async -> Void)?
    private let discardedPruneBeforeDelete:
        (@Sendable (URL) async -> Void)?
    private var drainTask: Task<Void, Never>?
    private var eagerEndSessionTasks: [UUID: Task<Void, Never>] = [:]
    private var recentTranscriptCacheTasks:
        [String: Task<Void, Never>] = [:]
    private var discardedFragmentPruneTasks:
        [UUID: Task<Void, Never>] = [:]
    private var mergeFinalizeTasks:
        [UUID: Task<Void, Never>] = [:]
    private var mergeOperationsInFlight = 0
    private var mergeOperationWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var accountExposureClosing = false
    private var accountExposureClosed = false
    private var accountExposureWorkQuiesced = false
    private var accountExposureRegistrations:
        [AccountExposureRegistration] = []
    private var sourceExposureClosePending = false
    private var micExposureClosePending = false
    private var audioExposureCloseRetryInFlight = false
    private var audioExposureCloseRetryWaiters:
        [CheckedContinuation<AccountExposureCloseResult, Never>] = []
    private var accountExposureClosingWaitersForTests:
        [CheckedContinuation<Void, Never>] = []
    private var accountExposureQuiescenceWaitersForTests:
        [CheckedContinuation<Void, Never>] = []
    private var activeCaptureWaitersForTests:
        [CheckedContinuation<Void, Never>] = []

    // MARK: Live Activity + home-screen widget (Dynamic Island / WidgetKit)

    /// The capture Live Activity (lock-screen banner + Dynamic Island). Driven IN-APP
    /// (no push server in v1) on the same lifecycle transitions as capture. nil on
    /// pre-16.1 OSes / when ActivityKit is unavailable — every use is guarded.
    #if canImport(ActivityKit) && os(iOS)
    private let liveActivity: Any? = {
        if #available(iOS 16.2, *) { return CaptureLiveActivityController() }
        return nil
    }()
    @available(iOS 16.2, *)
    private var liveActivityController: CaptureLiveActivityController? {
        liveActivity as? CaptureLiveActivityController
    }
    #endif

    /// Throttle for live level/elapsed pushes — the Live Activity must NEVER update at
    /// audio frame rate (it would burn the system's update budget and get throttled).
    /// One refresh every few seconds is plenty; the elapsed timer ticks on-device via
    /// `Text(timerInterval:)`, so we only push to move the level indicator.
    public nonisolated static let liveActivityThrottle: TimeInterval = 2
    private var lastLiveActivityPushAt: TimeInterval = 0
    /// The last time the HOME-SCREEN WIDGET snapshot was written (a main-actor App-Group
    /// file write) + its timeline reload hinted. Separate from `lastLiveActivityPushAt` —
    /// see the throttle comment in `pushLiveState`.
    private var lastWidgetPushAt: TimeInterval = 0

    /// Count of widget snapshot writes + reload hints (test-observable, deterministic).
    /// The acceptance instrument for the addendum: N meter ticks during a recording must
    /// drive AT MOST the throttled number of these, not one per tick.
    nonisolated private static let _widgetPushLock = NSLock()
    nonisolated(unsafe) private static var _widgetPushes = 0
    nonisolated static func noteWidgetPush() {
        _widgetPushLock.lock(); _widgetPushes += 1; _widgetPushLock.unlock()
    }
    nonisolated static var widgetPushesForTests: Int {
        _widgetPushLock.lock(); defer { _widgetPushLock.unlock() }; return _widgetPushes
    }
    nonisolated static func resetWidgetPushesForTests() {
        _widgetPushLock.lock(); _widgetPushes = 0; _widgetPushLock.unlock()
    }
    #if canImport(ActivityKit) && os(iOS)
    /// The last ContentState we actually pushed — a coalescing gate so a throttled tick
    /// that produces an IDENTICAL state pushes nothing (no wasted update-budget / battery).
    /// `startedAt` is excluded from the comparison intentionally: it's the timer anchor
    /// that ticks ON-DEVICE, so an unchanged phase/level/transcript never needs a re-push
    /// just because wall-clock advanced.
    @available(iOS 16.2, *)
    private var lastPushedState: CaptureActivityAttributes.ContentState? {
        get { _lastPushedState as? CaptureActivityAttributes.ContentState }
        set { _lastPushedState = newValue }
    }
    private var _lastPushedState: Any?
    #endif
    /// Finalize-the-conversation seam (injectable for door-free tests): given a
    /// closed capture id + its conversation metadata (start/end/location), tell the
    /// door to assemble + ingest it to Lore. Throws on failure so the capture stays
    /// pending-finalize and is retried.
    private let finalizeCapture: @Sendable (String, ConversationMeta?) async throws -> Void
    /// Delete-the-conversation seam (injectable for door-free tests): tells the door to
    /// remove the capture + Lore content. Throws on retryable failure so the durable
    /// `.needs-delete` marker remains queued.
    private let deleteCaptureRemote: @Sendable (String) async throws -> Void
    /// Fetch a capture's transcript content from the door (injectable for door-free
    /// tests). Drives the proactive 14-day transcript cache ("fetch on sight"). Returns
    /// nil on any transport error (the cache just stays empty until next sight).
    private let fetchContent: @Sendable (String) async -> CaptureContent?
    /// Resync-handshake seam (capture-sync AC1, injectable for door-free tests): ask
    /// the door which segment seqs it ALREADY durably stores for a capture. `nil` ⇒
    /// an old door without the endpoint (404) — no resync, drain exactly as today.
    /// Throws on transport failure so the drain retries the handshake next pass.
    private let fetchDoorSegments: @Sendable (String) async throws -> [UInt64]?
    /// One-shot location at conversation boundaries (When-In-Use, opportunistic —
    /// F5). Degrades to no-location off the main app / when denied.
    private let locationProvider: ConversationLocationProviding
    /// In-flight finalize attempts, so a retry tick never double-fires for the same
    /// capture while one is already running.
    private var finalizing: Set<String> = []

    /// Whether the AUTOMATIC finalize drivers run — the finished-path finalize on
    /// conversation-close and the drain timer's `retryPendingFinalizes`. Default true
    /// (production). Tests that assert the RETRY semantics of `retryPendingFinalizes`
    /// deterministically set this false so finalize fires ONLY when they call it —
    /// otherwise the fire-and-forget finished-path finalize races the explicit call
    /// for the `finalizing` marker (it holds the marker across an off-main snapshot),
    /// which flakes those tests under a saturated executor. Gating only the automatic
    /// callers leaves the explicit `retryPendingFinalizes()` path (and all production
    /// behavior) unchanged.
    private var autoFinalizeEnabled = true
    /// Test seam: quiesce the automatic finalize drivers (see `autoFinalizeEnabled`).
    /// Set right after construction, before any capture is opened.
    public func setAutoFinalizeForTests(_ enabled: Bool) { autoFinalizeEnabled = enabled }

    // MARK: bounded backlog drain + re-auth (anti-storm)

    /// Exponential-backoff bounds for a capture whose uploads keep failing — so a
    /// persistent failure (door down / offline) backs off instead of re-firing every
    /// 5s drain tick (the retry storm that pegged the device). Tunable.
    public nonisolated static let retryBaseDelay: TimeInterval = 2
    /// Transient upload failures retry FOREVER at a bounded cadence (≤ this ceiling), so
    /// a multi-hour recording on a flaky / briefly-offline link keeps making forward
    /// progress instead of being given up on. NEVER LOSE AUDIO: there is deliberately
    /// NO size cap, NO age cap, and NO failure-count cap — a large, old, or slow capture
    /// is never auto-discarded; it just keeps draining (resuming from its watermark)
    /// until every segment is uploaded and it can finalize. The ONLY auto-retire is
    /// genuine permanent poison (see `shouldAbandonCapture`), and even then audio is kept.
    public nonisolated static let retryMaxDelay: TimeInterval = 5 * 60        // 5-minute ceiling — retry forever
    /// A closed capture may retry transient delivery for this long. Past this bound it
    /// becomes explicitly incomplete: the phone keeps every segment, finalize is never
    /// called, and the durable reason is shown to the user instead of deferring forever.
    public nonisolated static let incompleteRecoveryWindow: TimeInterval = 7 * 24 * 60 * 60
    /// At most this many distinct captures are ATTEMPTED per drain tick (the in-flight /
    /// backlog concurrency valve) — so a multi-day backlog drains steadily, never a storm.
    public nonisolated static let maxCapturesPerDrain = 3

    /// Most-recent captures hydrated into the in-memory timeline at launch. Bounded so a
    /// long-lived install with a large on-disk backlog doesn't enumerate + hydrate tens of
    /// thousands of folders on the main thread at launch — which overran the iOS launch
    /// watchdog and got the app SIGKILL'd (FRONTBOARD). Older captures stay on disk.
    public nonisolated static let maxCapturesToLoad = 300

    /// How many scan-free placeholder rows to seed for the FIRST paint of the Capture
    /// list (T1 AC5) — about a first screen's worth. Bounded so the synchronous warm read
    /// stays O(first-screen), never O(all folders).
    public nonisolated static let warmSeedCount = 10

    /// How many of the NEWEST captures the resume-candidate scan (`resumableCaptureId`)
    /// inspects on the hot Omi `.streaming` / relaunch path. Strictly bounded so the scan
    /// stays O(first-few) on the @MainActor — an unbounded per-segment stat storm over a
    /// backlogged library was the watchdog-hang risk that fragmented one 07-16 meeting into
    /// many. The conversation to resume is, by construction, among the very newest captures.
    public nonisolated static let resumeCandidateScanLimit = 8

    /// Discarded junk fragments (`.discarded`) kept on disk beyond this age are pruned — the
    /// audio was never uploaded and is not shown, so retaining tens of thousands of tiny
    /// folders forever only bloats the container + slows launch enumeration. A short window
    /// preserves recent auditability without unbounded accumulation.
    public nonisolated static let discardedRetention: TimeInterval = 2 * 24 * 60 * 60   // 2 days

    /// Per-capture upload retry state (consecutive failures + earliest next attempt).
    private struct RetryState { var failures = 0; var nextEligible: TimeInterval = 0 }
    private var retryStates: [String: RetryState] = [:]

    /// Deterministic test seam: model an elapsed upload-backoff window without a
    /// fixed wall-clock sleep. Production scheduling still uses real time.
    func expireUploadBackoffForTests() {
        for id in retryStates.keys {
            retryStates[id]?.nextEligible = 0
        }
    }

    /// Captures whose resync handshake (AC1) already ran this tunnel-session — so the
    /// door's seq set is fetched ONCE per capture, not on every 5s drain tick. An
    /// entry is cleared when the capture's uploads FAIL (a dropped socket / tunnel
    /// flap — the moment ACKs can be lost), so the next pass after a reconnect
    /// re-fetches cheaply instead of re-uploading blind (AC4).
    private var resyncedCaptures: Set<String> = []

    /// Fired when an upload is rejected as auth-expired (401). The app wires this to the
    /// remote session so it refreshes the id_token ONCE and, failing that, surfaces the
    /// login screen — instead of the phone retry-looping with a known-expired token.
    public var onAuthExpired: (@MainActor () -> Void)?
    /// True once a 401/expired-token rejection was seen — suppresses all further upload
    /// attempts (the immediate storm-stop) until the pipeline is rebuilt with a fresh
    /// token. Surfaced so the UI can show a "session expired" state.
    @Published public private(set) var authExpired = false
    private var authExpiredFired = false

    /// Pure exponential-backoff-with-jitter delay for the Nth consecutive failure
    /// (attempt ≥ 1): doubles from `retryBaseDelay`, capped at `retryMaxDelay`, then
    /// scaled by `jitter` (default ±25%). Tested deterministically with jitter = 1.
    public nonisolated static func retryDelay(forFailures n: Int,
                                              jitter: Double = Double.random(in: 0.75...1.25)) -> TimeInterval {
        guard n > 0 else { return 0 }
        let exp = retryBaseDelay * pow(2, Double(min(n - 1, 20)))   // clamp the exponent
        return min(retryMaxDelay, exp) * jitter
    }

    /// Pure terminal-retire decision. NEVER LOSE AUDIO: a capture is retired ONLY on
    /// genuine, segment-level PERMANENT poison (the WAL's `.poisoned` outcome — a
    /// missing/corrupt segment file, or a permanent non-auth 4xx from the door). It is
    /// NEVER retired for being large, old, or for a run of transient upload failures —
    /// those keep draining. Even on poison the audio bytes are KEPT (a durable marker,
    /// never a delete). Tested to prove a huge / ancient / long-failing capture is not
    /// retired (`permanentPoison: false` ⇒ false).
    public nonisolated static func shouldAbandonCapture(permanentPoison: Bool) -> Bool {
        permanentPoison
    }

    // MARK: capture-substance gate + Omi reconnect coalescing (junk-fragment control)

    /// The VOICED-frame bar used ONLY when there is NO on-device transcript at all (STT
    /// unavailable on this OS, or it produced literally nothing). A capture is a real
    /// conversation if either (a) it has meaningful transcribed SPEECH, or (b) — absent any
    /// transcript — it ran this long. This bar is deliberately HIGH (~60 s at Omi's ~50
    /// voiced-frames/s) because voiced-amplitude ALONE is a weak signal: ambient noise,
    /// HVAC, keyboard clatter all clear the level threshold without being speech. Requiring
    /// a full minute of continuous voiced audio before we'll keep a transcript-less capture
    /// rejects the short noise fragments (the junk backlog was all < ~27 s) while still
    /// preserving a genuinely long real conversation an old device couldn't transcribe.
    /// (Contrast `SilenceSegmenter.minVoicedFramesToClose` ≈ 2 s, which only decides
    /// silence-gap SEGMENT boundaries, not upload-worthiness.) Tunable.
    public nonisolated static let minVoicedFramesToUpload = 3000

    /// A recording that opened but received 0 segments (Omi dropped before delivering any
    /// audio) is pruned on launch once it has been open at least this long — clears the
    /// "Recording · 0/0 · 0.0 KB" cards that otherwise linger forever. Generous so a
    /// genuinely just-started capture is never mistaken for a stuck-empty one.
    public nonisolated static let stuckEmptyRecordingSecs: TimeInterval = 5 * 60

    /// Fallback hold for a session that NEVER heard voiced audio before the disconnect —
    /// there is no conversation to continue, so the hold ends after this short window rather
    /// than lingering for a full silence gap. (For a session that DID hear voice, the end
    /// boundary is real voiced SILENCE, not disconnect wall-clock — see
    /// `shouldEndSuspendedSession`.) An EXPLICIT stop (phone-mic Stop / permission-deny) ends
    /// immediately, bypassing the grace. Tunable.
    public nonisolated static let reconnectGraceWindow: TimeInterval = 20

    /// Absolute backstop for a held (reconnect-grace) session: however the reconnect / silence
    /// signals play out, a session held longer than this is force-closed, so a truly abandoned
    /// conversation can never linger open forever. 4 hours.
    public nonisolated static let suspendedSessionMaxHold: TimeInterval = 4 * 3600

    /// Whether a just-closed capture is a real CONVERSATION worth finalizing + uploading to
    /// Lore, or a JUNK FRAGMENT to drop locally. The Omi model: a conversation is SPEECH,
    /// not merely sound above a level threshold. So:
    ///
    ///   1. If we hold an on-device transcript, gate on MEANINGFUL SPEECH
    ///      (`ConversationContentFilter`, the same empty/filler bar the timeline uses).
    ///      Ambient noise transcribes to nothing or to filler ("thank you", "okay") and is
    ///      DROPPED however long it ran — this is what stops the junk backlog at the source.
    ///   2. Only when there is NO transcript at all (STT unavailable / produced nothing) do
    ///      we fall back to the raised voiced-audio bar (`minVoicedFramesToUpload`, ~60 s),
    ///      so a genuinely long real conversation an old device couldn't transcribe is still
    ///      kept, but short voiced-only noise is not.
    ///
    /// Prior behavior let ~8 s of voiced AMPLITUDE upload regardless of content, which is
    /// exactly how thousands of noise/silence captures reached Lore.
    public nonisolated static func hasUploadSubstance(voicedFrames: Int,
                                                      onDeviceTranscript: String?,
                                                      durationSeconds: TimeInterval?) -> Bool {
        // A strong VOICED-AUDIO signal always wins, regardless of the on-device transcript.
        // The on-device transcript is the low-quality LIVE PREVIEW (SpeechAnalyzer/WhisperKit),
        // NOT the authoritative Kiln transcript that runs after upload — so a real, long
        // conversation whose preview classified as filler must NOT be destroyed before Kiln
        // ever sees it (2026-07-15: an 11,669-voiced-frame / ~4-min conversation was discarded
        // this way). Keep when EITHER the (preview) transcript is meaningful OR there is
        // substantial voiced audio (>= the ~60 s bar); only genuinely thin captures — a filler
        // preview AND sub-bar voiced audio — are dropped.
        if voicedFrames >= minVoicedFramesToUpload {
            return true
        }
        return ConversationContentFilter.isMeaningful(transcript: onDeviceTranscript,
                                                      durationSeconds: durationSeconds)
    }

    /// Whether a held (reconnect-grace) Omi session has reached a real conversation boundary
    /// and must end. The boundary is CONVERSATIONAL SILENCE — `silenceGap` seconds with no
    /// VOICED audio, measured from the last voiced instant — NOT disconnect wall-clock.
    ///
    /// Why: a BLE disconnect (backgrounding the app, walking briefly out of range) is not
    /// silence. The old rule ended the hold after a fixed `reconnectGraceWindow` of disconnect
    /// wall-clock, evaluated by the main-runloop segment timer — which is SUSPENDED while the
    /// app is backgrounded. So the entire background interval counted against the window, and
    /// the first foreground tick split the LIVE conversation, minting a fresh capture id on the
    /// next reconnect (the "going in/out of the app starts a new conversation" bug). Gating on
    /// real voiced silence instead means a reconnect within `silenceGap` of the last voiced
    /// audio finds the session STILL HELD and resumes the SAME capture id; only genuine
    /// >= silenceGap of voiced silence (a true conversation boundary) ends it.
    ///
    /// All time arguments share one clock (reference-date seconds, as `lastVoicedInstant()`).
    /// - lastVoicedAt: instant of the most recent voiced frame, or nil if no voice was ever
    ///   heard this session.
    /// - suspendedAt: when the hold began.
    /// - noVoicedTimeout: fallback hold when `lastVoicedAt` is nil — nothing to continue, so
    ///   close after the short reconnect window instead of a full silence gap.
    /// - maxHold: absolute backstop so a truly abandoned held session always eventually closes.
    public nonisolated static func shouldEndSuspendedSession(
        lastVoicedAt: TimeInterval?,
        suspendedAt: TimeInterval,
        now: TimeInterval,
        silenceGap: TimeInterval,
        noVoicedTimeout: TimeInterval = reconnectGraceWindow,
        maxHold: TimeInterval = suspendedSessionMaxHold
    ) -> Bool {
        // Absolute backstop: a held session never lingers open past this, whatever the signals.
        if now - suspendedAt >= maxHold { return true }
        guard let lastVoicedAt else {
            // No voiced audio ever this session — there is no conversation to continue. Fall
            // back to the short reconnect timeout rather than holding for a full silence gap.
            return now - suspendedAt >= noVoicedTimeout
        }
        // The real end-of-conversation signal: >= silenceGap of VOICED silence since the last
        // voiced instant. A disconnect gap shorter than this keeps the session held to resume.
        return now - lastVoicedAt >= silenceGap
    }

    /// WHICH device this manager is recording from, supplied by the composition root.
    ///
    /// Read at each capture-creation site and at each resume decision. Defaulted to
    /// `blocked` so every existing construction keeps its exact shipped behaviour: no
    /// device record is written and resume falls through to the legacy source-marker arm.
    /// The app sets it (`App/RootView.swift`); nothing inside `CaptureManager` discovers it.
    ///
    /// WHAT IS RECORDING IS A PARAMETER, NOT SOMETHING THE CLOSURE FETCHES (review round 9,
    /// L4). The first shape of this closure took nothing and the composition root reached
    /// back into the manager for `recordingSourceForAttribution` — through a `weak` capture,
    /// because the closure is stored ON the manager. That forced the call site to supply a
    /// fallback for "the manager is gone", i.e. to give a DEFAULT to the one parameter
    /// `resolveDeviceContext` deliberately declares without one, whose fallback value
    /// (`.externalStream`) is exactly the wrong answer for the bug that parameter exists to
    /// prevent. Handing the source IN removes the question: the manager is the authority on
    /// what is recording, so the manager is what says it, and no call site has anything left
    /// to default.
    public var captureDeviceContext: (CaptureRecordingSource) -> CaptureDeviceContextResolution = { _ in
        .blocked(reason: "no device context was supplied to this capture manager")
    }

    /// The Bluetooth audio INPUT ROUTE the handset is recording THROUGH, when it is one.
    ///
    /// WHY THIS SEAM EXISTS (T5, S01). A Bluetooth audio-route recorder records through the
    /// handset's phone-mic path — `captureSource == .phoneMic`, `isRecordingMic == true` —
    /// which is indistinguishable, from inside `CaptureManager`, from the handset's own
    /// built-in microphone. So every conversation made with a Field Recorder was attributed
    /// to "Phone": the device the user connected, whose name is on the row they tapped, never
    /// appeared against its own recordings. The registry is what knows which route is active,
    /// and the registry lives outside this type, so the composition root hands it in.
    ///
    /// `nil` means the handset's OWN microphone, which is the honest default: a manager that
    /// guessed a route here would attribute a plain Record-button conversation to whatever
    /// happened to be paired, which is the bug T4 paid for.
    public var activeAudioRoute: () -> (token: String, displayName: String)? = { nil }

    /// WHAT IS ACTUALLY RECORDING right now, for the composition root to attribute by.
    ///
    /// This is the question the archive needs answered. `isRecordingMic` is the manager's own
    /// authority on it — it is what the phone-mic arm of `onSourceState` keys off, what the
    /// live surface's "Phone" label keys off, and what `endSession`'s usage token keys off —
    /// so reading it here keeps the durable record agreeing with all three instead of with
    /// the handset's address book.
    public var recordingSourceForAttribution: CaptureRecordingSource {
        if isRecordingMic || captureSource == .phoneMic {
            if let route = activeAudioRoute() {
                return .handsetAudioRoute(token: route.token, displayName: route.displayName)
            }
            return .handsetMicrophone
        }
        return .externalStream
    }

    /// The identity to narrow a resume by, or nil when the composition root could not
    /// resolve one (in which case the shipped, un-narrowed rule applies).
    private var resumingDeviceIdentity: RecordingDeviceIdentity? {
        captureDeviceContext(recordingSourceForAttribution).context?.identity
    }

    /// A held-open Omi conversation awaiting a possible reconnect (its WAL + when the
    /// disconnect happened, in reference-date seconds — the same clock as `lastVoicedInstant()`
    /// so the silence-boundary check compares on one clock). Non-nil ⇒ `active` is SUSPENDED,
    /// not ended: a reconnect before `SilenceSegmenter.defaultSilenceGap` of voiced silence
    /// resumes it (same captureId), else `resolveReconnectGrace` ends it at the real boundary.
    private var suspendedSession: (wal: CaptureWAL, at: TimeInterval)? {
        // `didSet` rather than a push at each of the six assignment sites: the same reason
        // the gap window enumerates its close causes instead of counting call sites — a
        // seventh assignment must not be able to skip the notification.
        didSet { onInterruptedCaptureChanged?(suspendedSession?.wal.captureId) }
    }

    /// Pushed whenever the conversation a device drop interrupted changes. `DeviceManager`
    /// holds the value as a snapshot it can read on its own queue; this side is
    /// `@MainActor`, so it must PUSH rather than be read (track 20260725T2306, T3).
    public var onInterruptedCaptureChanged: (@Sendable (String?) -> Void)?

    /// True while an Omi conversation is being HELD open awaiting a possible reconnect (a
    /// transient BLE drop inside the grace window). The capture surface can surface a
    /// "reconnecting…" state; a reconnect within the window resumes the same conversation.
    public var isAwaitingReconnect: Bool { suspendedSession != nil }


    /// Resolve a pending Omi reconnect-grace hold: end the held conversation only when a REAL
    /// conversation boundary has been reached — `SilenceSegmenter.defaultSilenceGap` of voiced
    /// silence since the last voiced instant (NOT disconnect wall-clock), a session that never
    /// heard voice timing out, or the absolute backstop. Otherwise the hold stands so a
    /// reconnect can resume the SAME captureId. The substance gate then decides
    /// upload-vs-discard for an ended conversation. No-op when nothing is held or no boundary
    /// has been reached. The capture watchdog calls this each tick; tests pass an explicit
    /// `now` (reference-date seconds) to advance it deterministically.
    public func resolveReconnectGrace(now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        guard let held = suspendedSession else { return }
        guard CaptureManager.shouldEndSuspendedSession(lastVoicedAt: router.lastVoicedInstant(),
                                                       suspendedAt: held.at,
                                                       now: now,
                                                       silenceGap: SilenceSegmenter.defaultSilenceGap) else { return }
        suspendedSession = nil
        recordingClock = nil   // the held session finally ends here — no new session begins
        log?.info("capture \(held.wal.captureId): reconnect-grace silence boundary reached — ending held conversation")
        endSession()
        stopMeterIfIdle()   // ended to idle — the user may be off the capture surface (review M1)
    }

    /// Re-arm the drain after a fresh id_token has been obtained (the rebuilt pipeline
    /// starts clean, but this lets a same-instance recovery resume too). Idempotent.
    public func clearAuthExpired() {
        authExpired = false
        authExpiredFired = false
        retryStates.removeAll()
        // The pending-remote-delete lane backs off on an unreachable/failing door; a fresh
        // token is exactly the event that can make it succeed, so close its breaker too.
        deleteLaneRetry = RetryState()
        // A re-auth / rebuilt pipeline is a new tunnel-session: re-run the resync
        // handshake per capture instead of trusting a pre-flap seq snapshot.
        resyncedCaptures.removeAll()
    }

    // MARK: live on-device transcription (Feature 1) — additive, ephemeral, off-path
    /// Factory for the per-conversation live transcriber (nil ⇒ no live preview wired,
    /// e.g. door-free tests + older OSes). Injected so tests drive a fake transcriber.
    private let makeLiveTranscriber: LiveTranscriberFactory?
    /// The active conversation's live transcriber (nil when none / unavailable).
    private var liveTranscriber: LiveTranscribing?
    /// Pump republishing the transcriber's stream into `liveTranscript` on the main actor.
    private var liveTranscriptTask: Task<Void, Never>?
    /// Settled-transcript finishers can persist a provisional card, so account
    /// closure owns and joins them before acknowledging the old root is quiescent.
    private var liveTranscriptionFinishTasks: [UUID: Task<Void, Never>] = [:]
    #if canImport(AVFoundation)
    /// Thread-safe holder so the off-main frame path can feed the CURRENT transcriber
    /// without touching main-actor state (the frame tap runs on the serial source queue).
    private let liveBox = CurrentLiveTranscriber()
    #endif

    // MARK: rolling live title (track 20260717T1015) — whole-conversation, debounced
    /// The optional on-device titler for LIVE refreshes (nil ⇒ heuristic-only). This
    /// is the INSTANT PLACEHOLDER's upgrade AND the offline fallback (Nick, track
    /// 20260717T1500): it keeps naming the conversation cheaply and works with no
    /// network; the external refresh only SHARPENS it when a door is reachable.
    private let liveTitler: LocalTitleSummary?
    /// The refresh cadence (injected so tests collapse the debounce).
    private let liveTitleCadence: LiveTitleCadence
    /// The settled title + its tier (heuristic / model / external) behind `liveTitle`.
    private var liveTitleState: LiveTitleState?
    private var titleWordsAtLastHeuristic = 0
    private var titleWordsAtLastModel = 0
    private var lastModelTitleAt: Date?
    private var modelTitleInFlight = false
    private var modelTitleFailures = 0
    /// Consecutive live-titler failures tolerated before the session goes
    /// heuristic-only (on-device turns have hung in the wild).
    private static let maxModelTitleFailures = 2

    // MARK: external live title (track 20260717T1500) — phone-originated, backoff-scheduled
    /// The EXTERNAL live-title refresh (nil ⇒ off — "just my phone" / offline: the
    /// on-device placeholder stands alone). Called on the exponential backoff with the
    /// whole-conversation history + a monotonic seq; returns a sharpened external title
    /// (nil ⇒ door has no route / no title). Injected so tests drive it without a door.
    private let liveTitleExternal: (@Sendable (_ captureId: String, _ history: String, _ seq: Int) async throws -> String?)?
    /// The exponential backoff schedule (injected so tests collapse the wait).
    private let liveTitleBackoff: LiveTitleBackoff
    /// The conversation-scoped backoff anchor. `nil` until the first fresh conversation
    /// arms it; PRESERVED across an internal silence-gap roll and a resume-same-id so a
    /// long conversation keeps its widened spacing (never re-tightens to 60s on a roll).
    private var backoffStartedAt: Date?
    /// Absolute time of the next scheduled external refresh (nil ⇒ not armed).
    private var nextExternalFireAt: Date?
    /// External refreshes that have already fired this conversation (drives the doubling).
    private var externalRefreshCount = 0
    private var externalTitleInFlight = false
    private var externalTitleFailures = 0
    /// Finalized word count at the last SUCCESSFUL external refresh — the "skip a tick
    /// with no new words" gate (never spend an external call on silence).
    private var wordsAtLastExternal = 0
    /// Monotonic per-conversation request sequence so the door applies only the latest.
    private var nextLiveTitleSeq = 0
    /// Consecutive external failures tolerated before the conversation stops asking the
    /// door (a down/absent door must not be hammered; the on-device title stands).
    private static let maxExternalTitleFailures = 3

    /// Test seam: override the per-segment door upload for every WAL this manager
    /// builds (so the bounded-retry / backoff / abandon / re-auth paths are exercised
    /// deterministically without a live door). nil ⇒ the real door POST.
    private let uploadSegment: (@Sendable (String, UInt64, Data) async throws -> Void)?

    public init(target: DoorTarget,
                baseDir: URL? = nil,
                log: DoorLog? = nil,
                source: AudioFrameSource,
                micSource: AudioFrameSource? = nil,
                attachToSourcesImmediately: Bool = true,
                finalize: (@Sendable (String, ConversationMeta?) async throws -> Void)? = nil,
                deleteCapture: (@Sendable (String) async throws -> Void)? = nil,
                fetchContent: (@Sendable (String) async -> CaptureContent?)? = nil,
                fetchSegments: (@Sendable (String) async throws -> [UInt64]?)? = nil,
                locationProvider: ConversationLocationProviding? = nil,
                liveTranscriber: LiveTranscriberFactory? = nil,
                liveTitler: LocalTitleSummary? = nil,
                liveTitleCadence: LiveTitleCadence = .default,
                liveTitleExternal: (@Sendable (String, String, Int) async throws -> String?)? = nil,
                liveTitleBackoff: LiveTitleBackoff = .default,
                uploadSegment: (@Sendable (String, UInt64, Data) async throws -> Void)? = nil,
                hydrationBeforeCommit: (@Sendable () async -> Void)? = nil,
                drainTimerFactory: @escaping CaptureManagerDrainTimerFactory =
                    CaptureManager.defaultDrainTimerFactory,
                discardedPruneBeforeDelete:
                    (@Sendable (URL) async -> Void)? = nil) {
        self.target = target
        self.hydrationBeforeCommit = hydrationBeforeCommit
        self.drainTimerFactory = drainTimerFactory
        self.discardedPruneBeforeDelete = discardedPruneBeforeDelete
        self.uploadSegment = uploadSegment
        self.makeLiveTranscriber = liveTranscriber
        self.liveTitler = liveTitler
        self.liveTitleCadence = liveTitleCadence
        self.liveTitleExternal = liveTitleExternal
        self.liveTitleBackoff = liveTitleBackoff
        // A manager handed an explicit container still binds — to THAT root. Binding
        // only to the account root left every producer (widget, Live Activity, ambient)
        // silently dead whenever the two differed.
        let resolved = CaptureAccountScope.currentAccountBinding()
        let root = baseDir ?? resolved?.root ?? CaptureWAL.documentsCaptures()
        self.accountBinding = resolved?.root == root
            ? resolved
            : CaptureAccountScope.binding(forExplicitRoot: root)
        self.baseDir = root
        self.log = log
        self.source = source
        self.micSource = micSource
        // Default finalize = the real door call (carrying the conversation metadata
        // body). Tests inject a stub to assert the close seam fires finalize once per
        // closed capture and that the body shape is right.
        if let finalize {
            self.finalizeCapture = finalize
        } else {
            let client = DoorClient(target: target, log: log)
            self.finalizeCapture = { captureId, meta in
                try await client.finalize(captureId: captureId, meta: meta)
            }
        }
        if let deleteCapture {
            self.deleteCaptureRemote = deleteCapture
        } else {
            let client = DoorClient(target: target, log: log)
            self.deleteCaptureRemote = { captureId in
                try await client.deleteCapture(captureId: captureId)
            }
        }
        // Default content fetch = the real door /content call. Tests inject a stub to
        // drive the proactive transcript cache without HTTP.
        if let fetchContent {
            self.fetchContent = fetchContent
        } else {
            let client = DoorClient(target: target, log: log)
            self.fetchContent = { captureId in try? await client.captureContent(captureId: captureId) }
        }
        // Default resync handshake = the real door /segments call (nil on 404 = old
        // door → no resync). Tests inject a stub to drive the bulk-ACK path.
        if let fetchSegments {
            self.fetchDoorSegments = fetchSegments
        } else {
            let client = DoorClient(target: target, log: log)
            self.fetchDoorSegments = { captureId in try await client.captureSegments(captureId: captureId) }
        }
        // Default location = the real When-In-Use one-shot on iOS; the no-location
        // degradation provider elsewhere (and the injected stub in door-free tests).
        if let locationProvider {
            self.locationProvider = locationProvider
        } else {
            #if canImport(CoreLocation) && os(iOS)
            self.locationProvider = LocationProvider()
            #else
            self.locationProvider = NoLocationProvider()
            #endif
        }
        let gap = CaptureSettings.silenceGapSeconds
        self.silenceGapSeconds = gap
        // Restore the durable capture intent (req 2). A user who PAUSED before a full
        // app restart must come back paused — not silently capturing. An absent owner
        // snapshot is reachable only while identity/restoration is unresolved and fails
        // closed; normal fresh/signed-out/active construction installs an explicit
        // snapshot before starting the source. beginSession() re-applies this via
        // router.setPaused(isPaused) on the next (re)connect.
        self.isPaused = (CaptureSettings.omiCaptureDesiredState == .paused)
        self.meter = AudioMeterModel(barCount: Self.meterBarCount)
        self.live = LiveCaptureModel()
        self.router = FrameRouter(segmenter: SilenceSegmenter(silenceGap: gap))
        // Level tap (off-main, cheap) + silence-gap boundaries (→ main to rotate).
        router.onLevel = { [levelBuffer] lvl in levelBuffer.record(lvl) }
        router.onSegment = { [weak self] event in
            Task { @MainActor in self?.handleSegment(event) }
        }
        // Speech onset while armed-listening → open the conversation (→ main to begin).
        router.onSpeechOnset = { [weak self] in
            Task { @MainActor in self?.handleSpeechOnset() }
        }
        // Capture-pipeline diagnostics → the (diag-shipping) log, so a flat meter /
        // 0-segment capture is debuggable server-side.
        router.onDiag = { [weak self] line in
            Task { @MainActor in self?.log?.info(line) }
        }
        #if canImport(AVFoundation)
        // Live-transcription PCM tap (only when a factory is wired). Feeds the CURRENT
        // transcriber via the thread-safe box — no main-actor hop on the frame path.
        if makeLiveTranscriber != nil {
            router.onPCM = { [liveBox] buf in liveBox.append(buf) }
            // Phone mic: feed its DECODED PCM straight to the transcriber (no Opus
            // encode→decode round-trip, Feature 2). When the mic is the active source the
            // router skips its own decode tap (see beginSession) so we never double-feed.
            (micSource as? MicFrameSource)?.onPCM = { [liveBox] buf in liveBox.append(buf) }
        }
        #endif
        if attachToSourcesImmediately {
            activateSourceOwnership()
        }
    }

    /// Activate this manager as the live capture owner. SwiftUI app construction defers
    /// this until the accepted `StateObject` appears: ordinary parent redraws may eagerly
    /// construct candidates that SwiftUI then discards. Those candidates must not claim
    /// source callbacks, reconcile the active WAL as an orphan, start timers, or register
    /// observers. Tests and non-SwiftUI callers keep immediate activation by default.
    public func activateSourceOwnership() {
        guard !ownerActivated,
              !accountExposureClosing,
              !accountExposureClosed else { return }
        ownerActivated = true
        // Frame path: serial source queue → router → WAL io queue. No main hop.
        source.onFrame = { [router] frame in router.route(frame) }
        source.onState = { [weak self] state in
            Task { @MainActor in self?.onSourceState(state) }
        }
        // The phone mic feeds the SAME router + lifecycle handler.
        micSource?.onFrame = { [router] frame in router.route(frame) }
        micSource?.onState = { [weak self] state in
            Task { @MainActor in self?.onSourceState(state) }
        }
        firstPaintSpan = PerfSpan(name: "capture-list-first-paint")
        firstPaintPending = true
        seedWarmListRows()
        loadExisting()
        startDrainTimer()
        startSegmentTimer()
        // OUT-OF-MANAGER sidecar writes (detail content fetch / speaker confirm) invalidate
        // the accepted owner's memo; discarded candidates never subscribe.
        sidecarObserver = NotificationCenter.default.addObserver(
            forName: .foundryxSidecarChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["captureId"] as? String else { return }
            MainActor.assumeIsolated {
                self?.invalidateSidecar(id)
                self?.scheduleSidecarRebuild()
            }
        }
        identityObserver = NotificationCenter.default.addObserver(
            forName: CaptureAccountScope.identityDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearLiveActivityForIdentityTransition()
            }
        }
    }

    public static func defaultDrainTimerFactory(
        interval: TimeInterval,
        tick: @escaping @MainActor () -> Void
    ) -> any CaptureManagerTimer {
        Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    /// The `.foundryxSidecarChanged` observer token — removed in deinit so a torn-down
    /// manager (each test builds a fresh one) leaves no dangling registration.
    private nonisolated(unsafe) var sidecarObserver: NSObjectProtocol?
    private nonisolated(unsafe) var identityObserver: NSObjectProtocol?

    deinit {
        if let sidecarObserver { NotificationCenter.default.removeObserver(sidecarObserver) }
        if let identityObserver { NotificationCenter.default.removeObserver(identityObserver) }
    }

    private func clearLiveActivityForIdentityTransition() {
        guard let accountBinding, !accountBinding.isCurrent else { return }
        #if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.2, *) {
            lastPushedState = nil
            liveActivityController?.endImmediately()
        }
        #endif
    }

    /// Startup work that NEEDS the hydrated timeline (orphan reconcile, retention
    /// sweeps, the widget seed) — runs once hydration lands on the main actor.
    private func finishStartupAfterHydration(retention: RetentionSweepResult) {
        reconcileOrphanedCaptures()  // give crash-orphaned captures real bounds + finalize them
        applyRetentionSweep(retention)  // the sweep already ran off-main; invalidates touched memos
        // Hydration is authoritative now — drop the scan-free warm seed unconditionally.
        // (rebuildVisibleCaptures only clears it when `visible` is non-empty; a library whose
        // newest captures are ALL filler resolves to visible==[] with a non-empty seed, which
        // would otherwise leave hidden-filler rows on the home surface. Clearing here covers it.)
        if !listRows.isEmpty { listRows = [] }
        // Seed the home-screen widget with current (idle / last-conversation) state so it
        // renders correctly before the first capture transition fires.
        refreshHomeWidget()   // one accounted, un-throttled widget push (see refreshHomeWidget)
    }

    /// Memoised meta.json loads: the timeline re-reads conversationMeta up to 3× per
    /// row per render (deep-review perf finding). Meta is written only through the
    /// manager's own recordStart/recordEnd call sites, which invalidate the entry —
    /// so rendering is memory-only after the first load. `.some(nil)` memoises the
    /// "no meta on disk" answer too (pre-F1 captures would otherwise re-stat forever).
    private var metaCache: [String: ConversationMeta?] = [:]

    /// Refresh a capture's memoised meta after writing meta.json (recordStart/recordEnd).
    ///
    /// S2 — this does NOT drop the entry. The rebuild's `cachedMeta` has no disk fallback, so
    /// a dropped entry answers `nil`, and `nil` duration is the LENIENT direction in the
    /// membership filter: dropping it would make a hidden borderline card appear and then
    /// vanish when the warm landed. It follows the same R3 rule `invalidateSidecar` follows —
    /// the LAST-KNOWN value stays authoritative and the fresh one is read OFF the main actor,
    /// where `applyWarmSidecar` swaps it in (and re-renders only if it actually differs).
    private func invalidateMeta(_ captureId: String) {
        scheduleSidecarWarm(captureId, force: true)
    }

    /// The durable conversation metadata (start/end/location) for a capture, for
    /// the timeline card (F1). `nil` for captures recorded before this shipped.
    public func conversationMeta(for captureId: String) -> ConversationMeta? {
        if let hit = metaCache[captureId] { return hit }
        let loaded = ConversationMetaStore.load(captureId: captureId, baseDir: baseDir)
        metaCache[captureId] = loaded
        return loaded
    }

    /// The memoised meta WITHOUT the disk fallback — for the list-rebuild path (membership
    /// filter, sort, stats), which must do zero synchronous disk on the main actor. A miss
    /// schedules the off-main warm and answers `nil` for this pass; the warm hop re-renders.
    private func cachedMeta(_ captureId: String) -> ConversationMeta? {
        if let hit = metaCache[captureId] { return hit }
        scheduleSidecarWarm(captureId)
        return nil
    }

    // MARK: per-capture sidecar memo (R3) — kill the list-rebuild main-thread disk storm

    /// A per-capture memo of the DURABLE sidecar state `rebuildVisibleCaptures` reads, so
    /// the rebuild (membership + processing count + stats) does ZERO synchronous sidecar
    /// disk I/O on the main actor. Audit (2026-07-17): the rebuild fired on every
    /// `captures` didSet + 7 sites and did up to ~3×N full transcript.json decodes + card
    /// loads + marker stats ON MAIN — a same-site, library-size-proportional hang.
    ///
    /// COUNTS AND FLAGS ONLY — never transcript text, and never the decoded
    /// segment/paragraph arrays (track `rebuild_is_byte_independent_and_disk_free`).
    /// The memo used to retain the full transcript string and the rebuild re-scanned it per
    /// capture per rebuild, which made the rebuild O(total transcript bytes) AND held every
    /// conversation's text resident. Every derived fact the rebuild needs is now computed
    /// ONCE, off the main actor, in `loadSidecar`.
    ///
    /// MEMORY WIN, stated accurately (review N1): the old memo held the transcript under two
    /// names (`bestTranscriptText` and `statsTranscript.transcript`), but those were the SAME
    /// `String` instance — Swift strings are COW, so it was ONE retained buffer per capture,
    /// not two. Dropping it therefore saves ~the corpus size (≈7.9MB at the 7.9MB test
    /// corpus), NOT double that. Seeded OFF the main actor during hydration and refreshed
    /// off-main at every write site (see `invalidateSidecar`).
    /// The `card.json` facts the RENDER path needs, derived once off the main actor.
    ///
    /// This is deliberately NOT a `ConversationCardMeta`: the card carries
    /// `provisionalTranscript`, the FULL on-device transcript body, and memoising that per
    /// capture would put the whole corpus back in memory — undoing the ≈7.9MB win the
    /// `rebuild_is_byte_independent_and_disk_free` track just landed. Only a bounded HEAD of
    /// it is kept (`provisionalHeadChars`), which is everything the two consumers need: the
    /// first-words fallback title (6 words) and the card's summary line (the view clamps it
    /// to two lines). The full body is still available on demand from disk, off the render
    /// path, via `ConversationCardStore.load` / `searchText(for:)`.
    struct CardFacts: Sendable, Equatable {
        /// How much of the provisional transcript the memo keeps. Bounded on purpose — see
        /// the type doc. 400 chars comfortably covers a 6-word title and a 2-line summary.
        static let provisionalHeadChars = 400

        let title: String?
        let summary: String?
        let stage: String?
        let isProvisional: Bool
        let updatedAt: UInt64
        let startedAt: UInt64?
        /// HEAD ONLY of `provisional_transcript` — never the full body.
        let provisionalHead: String?

        init(_ card: ConversationCardMeta) {
            title = card.title
            summary = card.summary
            stage = card.stage
            isProvisional = card.isProvisional
            updatedAt = card.updatedAt
            startedAt = card.startedAt
            provisionalHead = card.provisionalTranscript.map { String($0.prefix(Self.provisionalHeadChars)) }
        }

        /// Equality is over what the list RENDERS. `updatedAt` is deliberately excluded: it
        /// is a PROCESSING timestamp that bumps on every poll/re-ingest and nothing displays
        /// it, so comparing it would make `rendersDifferently` request a list rebuild for a
        /// card merge that changed nothing visible.
        static func == (a: CardFacts, b: CardFacts) -> Bool {
            a.title == b.title && a.summary == b.summary && a.stage == b.stage
                && a.isProvisional == b.isProvisional && a.startedAt == b.startedAt
                && a.provisionalHead == b.provisionalHead
        }

        /// The card the render path sees. Byte-identical to disk except a provisional body
        /// longer than `provisionalHeadChars`, which is truncated (see the type doc).
        var renderCard: ConversationCardMeta {
            ConversationCardMeta(title: title, summary: summary, stage: stage,
                                 provisionalTranscript: provisionalHead,
                                 isProvisional: isProvisional,
                                 updatedAt: updatedAt, startedAt: startedAt)
        }
    }

    struct SidecarSnapshot: Sendable {
        /// `card.json`'s render facts (nil = no card on disk). Lets `cardMeta(for:)` answer
        /// the list's per-row title/summary from MEMORY — the un-memoized `card.json` decode
        /// per row per render was driver #2 of the nav stall.
        let card: CardFacts?
        /// `.discarded` marker present (sub-substance junk → never shown).
        let isDiscarded: Bool
        /// `.deleted` tombstone present (user-deleted → never shown).
        let isDeleted: Bool
        /// There IS best-local transcript text (cached transcript, else the card's
        /// provisional body). false ⇒ no readable text yet (still processing) → the caller
        /// falls back to audio presence. Replaces the retained string.
        let hasLocalTranscriptText: Bool
        /// Distinct MEANINGFUL words in that best-local text, capped at the filter's
        /// decision threshold — the whole input `ConversationContentFilter` needs to judge
        /// the empty/near-silent/filler membership gate, as an `Int`.
        let meaningfulWordCount: Int
        /// transcript.json exists (the readable tombstone / "Ready" signal).
        let hasCachedTranscript: Bool
        /// card.json exists (the all-time browsable tombstone).
        let cardExists: Bool
        /// `.lore-confirmed` marker present.
        let confirmedInLore: Bool
        /// Words in the CACHED transcript text (`transcript.json` only — the same text the
        /// old stats snapshot counted), for `StatsSummary.totalWords`.
        let wordCount: Int
        /// The distinct speaker identities this conversation contributes to
        /// `StatsSummary.totalSpeakersIdentified` — byte-identical to the old per-rebuild
        /// scan of speakers + extra segment slots, but derived once.
        let speakerIdentities: [String]
        /// `card.json`'s durable `started_at`, so the sort's `durableStart` resolves from
        /// MEMORY instead of re-reading the card off disk on the main actor.
        let cardStartedAt: UInt64?
        /// False for the R3 PLACEHOLDER a rebuild renders while a never-seen capture's real
        /// sidecar is being read off-main. A warm value always wins over a placeholder.
        let isWarm: Bool

        /// The R3 default for a capture whose sidecar has never been read: "nothing is known
        /// yet". All markers absent, no text, no tombstones — so `isBrowsable` falls through
        /// to the streaming / real-audio rule and the capture is only shown once a durable
        /// reason exists. See `sidecar(for:)` for why this direction is the no-flicker one.
        static let unwarmed = SidecarSnapshot(
            card: nil, isDiscarded: false, isDeleted: false, hasLocalTranscriptText: false,
            meaningfulWordCount: 0, hasCachedTranscript: false, cardExists: false,
            confirmedInLore: false, wordCount: 0, speakerIdentities: [],
            cardStartedAt: nil, isWarm: false)

        /// The same snapshot with a marker the MANAGER ITSELF just wrote applied in memory.
        /// Used so a discard/delete hides the row in the SAME runloop tick it happens (the
        /// substance gate + delete are user-visible, immediate operations) without a
        /// main-actor disk read — the off-main re-warm then confirms it.
        func marking(discarded: Bool = false, deleted: Bool = false) -> SidecarSnapshot {
            SidecarSnapshot(
                card: card,
                isDiscarded: isDiscarded || discarded, isDeleted: isDeleted || deleted,
                hasLocalTranscriptText: hasLocalTranscriptText,
                meaningfulWordCount: meaningfulWordCount,
                hasCachedTranscript: hasCachedTranscript, cardExists: cardExists,
                confirmedInLore: confirmedInLore, wordCount: wordCount,
                speakerIdentities: speakerIdentities, cardStartedAt: cardStartedAt,
                isWarm: isWarm)
        }

        /// Whether swapping `self` for `other` could change ANYTHING the list renders
        /// (membership, the processing banner, or the stats tiles). The off-main re-warm
        /// only triggers a re-render when this is true — an identical warm value must never
        /// cause a visible list churn (R3).
        func rendersDifferently(from other: SidecarSnapshot) -> Bool {
            // The card facts are now what every ROW renders (title + summary), so a changed
            // card is a render reason — it was not one while `cardMeta` re-read disk per row.
            card != other.card
                || isDiscarded != other.isDiscarded
                || isDeleted != other.isDeleted
                || hasLocalTranscriptText != other.hasLocalTranscriptText
                || meaningfulWordCount != other.meaningfulWordCount
                || hasCachedTranscript != other.hasCachedTranscript
                || cardExists != other.cardExists
                || confirmedInLore != other.confirmedInLore
                || wordCount != other.wordCount
                || cardStartedAt != other.cardStartedAt
                || Set(speakerIdentities) != Set(other.speakerIdentities)
        }
    }

    private var sidecarCache: [String: SidecarSnapshot] = [:]

    /// Build a capture's sidecar memo from disk. `nonisolated static` so hydration can run
    /// it OFF the main actor (pure disk — touches no actor state, Sendable result).
    nonisolated static func loadSidecar(captureId id: String, baseDir: URL) -> SidecarSnapshot {
        // GATE INTEGRITY: this is a full transcript decode. It is legitimate OFF the main
        // actor (hydration + the off-main re-warm) and a bug ON it — that synchronous
        // main-thread decode is the pathology this whole track removed. Count it HERE, at the
        // expensive operation itself, so ANY future caller that reintroduces it on the main
        // thread trips the deterministic gate — not just the callers we happen to know about
        // today. Without this the counter would only watch `cardMeta` and would be blind to
        // exactly the regression it exists to catch.
        if Thread.isMainThread { Self.noteMainThreadDecode() }
        let dir = baseDir.appendingPathComponent(id, isDirectory: true)
        let fm = FileManager.default
        let discarded = fm.fileExists(atPath: dir.appendingPathComponent(".discarded").path)
        let deleted = fm.fileExists(atPath: dir.appendingPathComponent(".deleted").path)
        let cached = TranscriptCacheStore.load(captureId: id, baseDir: baseDir)   // transient full decode
        let card = ConversationCardStore.load(captureId: id, baseDir: baseDir)
        // bestLocalTranscript: the cached transcript text if non-empty, else the card's
        // on-device provisional body (identical resolution to the old bestLocalTranscript).
        let best: String?
        if let c = cached, !c.transcript.isEmpty { best = c.transcript }
        else if let body = card?.provisionalTranscript, !body.isEmpty { best = body }
        else { best = nil }
        // DERIVE, don't retain (byte-independence): every fact the rebuild needs is reduced
        // to an Int / Bool / small identity list HERE — off the main actor, once per write —
        // and the decoded transcript (text + segment/paragraph arrays) is released with this
        // function's frame. The rebuild then never touches transcript bytes at all.
        return SidecarSnapshot(
            // DERIVE, don't retain (see CardFacts): the row's title/summary/stage are kept,
            // the provisional BODY is reduced to a bounded head, and the decoded card is
            // released with this frame.
            card: card.map { CardFacts($0) },
            isDiscarded: discarded,
            isDeleted: deleted,
            hasLocalTranscriptText: best != nil,
            meaningfulWordCount: best.map { ConversationContentFilter.meaningfulWordCount(in: $0) } ?? 0,
            hasCachedTranscript: TranscriptCacheStore.hasCachedTranscript(captureId: id, baseDir: baseDir),
            cardExists: ConversationCardStore.exists(captureId: id, baseDir: baseDir),
            confirmedInLore: TranscriptCacheStore.isConfirmedInLore(captureId: id, baseDir: baseDir),
            wordCount: StatsSummary.wordCount(cached?.transcript ?? ""),
            speakerIdentities: cached.map { StatsSummary.speakerIdentities(in: $0, captureId: id) } ?? [],
            cardStartedAt: (card?.startedAt).flatMap { $0 > 0 ? $0 : nil },
            isWarm: true)
    }

    /// The memoised sidecar for a capture, loading from disk ONLY on a cold miss. Hydration
    /// warms every capture BEFORE the first rebuild, so the rebuild path stays memory-only;
    /// a cold miss (a capture added after hydration, or just-invalidated) loads exactly one.
    private func sidecar(for id: String) -> SidecarSnapshot {
        if let hit = sidecarCache[id] { return hit }
        // R3 — a NEVER-SEEN capture (added after hydration). The rebuild MUST NOT read disk
        // on the main actor, so it renders the "nothing known yet" placeholder and re-warms
        // off-main. The placeholder is the CONSERVATIVE direction on purpose: it carries no
        // durable tombstone, so `isBrowsable` only shows the capture when the WAL itself
        // justifies it (streaming / real audio). A capture can therefore APPEAR when its warm
        // value lands, but it can never appear → vanish → reappear, which is the flicker the
        // list must never show. (Hydration seeds every existing capture before the first
        // rebuild, and the live capture is shown by the streaming rule, so in practice this
        // path is only ever taken for a capture the manager just created itself.)
        sidecarCache[id] = .unwarmed
        scheduleSidecarWarm(id)
        return .unwarmed
    }

    /// Re-read a capture's sidecar (+ meta) OFF the main actor and apply the small `Sendable`
    /// result back on main. `force` (an invalidation) always starts a fresh read; a cold-miss
    /// warm coalesces onto whatever is already in flight.
    private func scheduleSidecarWarm(_ id: String, force: Bool = false) {
        guard !accountExposureClosing, !accountExposureClosed else { return }
        guard force || warmingSidecars[id] == nil else { return }
        let generation = (sidecarGeneration[id] ?? 0) + 1
        sidecarGeneration[id] = generation
        warmingSidecars[id] = generation
        let base = baseDir
        let taskID = UUID()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let span = PerfSpan(name: "sidecar-rewarm")
            let snap = CaptureManager.loadSidecar(captureId: id, baseDir: base)
            let meta = ConversationMetaStore.load(captureId: id, baseDir: base)
            PerfHook.span("sidecar-rewarm", ms: span.elapsedMs())
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                defer { self.sidecarWarmTasks[taskID] = nil }
                guard !self.accountExposureClosing,
                      !self.accountExposureClosed else { return }
                self.applyWarmSidecar(
                    id, snapshot: snap, meta: meta, generation: generation)
            }
        }
        sidecarWarmTasks[taskID] = task
    }

    /// Apply an off-main sidecar re-warm. Ignores a result superseded by a newer invalidation
    /// (the newer read has its own task in flight), and only asks for a re-render when the
    /// fresh value would actually change what the list shows — an identical warm value must
    /// never churn the list.
    private func applyWarmSidecar(_ id: String, snapshot: SidecarSnapshot,
                                  meta: ConversationMeta?, generation: Int) {
        guard !accountExposureClosing, !accountExposureClosed else { return }
        guard sidecarGeneration[id] == generation else { return }
        warmingSidecars[id] = nil
        let previous = sidecarCache[id]
        // S1 — this hop mutates THREE memos the list reads (sidecar, meta, durable start), so
        // the re-render guard must cover all three. Guarding on the SIDECAR delta alone landed
        // meta-only changes silently: `recordEnd` writes endedAt/duration while the transcript
        // and card are untouched, so the "Hours this week"/duration tiles never ticked up when
        // a conversation ended, the re-resolved durable start never reached the sort, and the
        // duration branch of `isBrowsable` was never re-evaluated.
        let previousMeta = metaCache[id] ?? nil
        let previousStart = startTimeCache[id]
        sidecarCache[id] = snapshot
        metaCache[id] = .some(meta)   // memoise "no meta on disk" too (see metaCache)
        invalidateLastFinishedMemo()  // a fresh card title / endedAt can move the answer
        startTimeCache[id] = nil      // recomputed from the warm meta/card on next sort
        let metaChanged = previousMeta != meta
        // Only a CHANGED memoised sort key matters: if the sort never memoised one, the next
        // sort resolves it fresh, so an absent-to-present transition is not a re-render reason.
        let startChanged = previousStart != nil && durableStartCached(captureId: id) != previousStart
        guard (previous?.rendersDifferently(from: snapshot) ?? true) || metaChanged || startChanged
        else { return }
        scheduleSidecarRebuild()
    }

    /// Re-read MANY captures' sidecars off the main actor in ONE hop (S7). Bulk invalidations
    /// — the retention sweep, the stuck-empty prune, orphan reconcile — touch tens to hundreds
    /// of captures at once; scheduling one `.userInitiated` `Task.detached` per capture fans
    /// out N concurrent FULL TRANSCRIPT decodes all competing with the main actor for exactly
    /// the frames this track exists to protect. One `.utility` task, one main-actor apply, one
    /// coalesced rebuild. (These are background maintenance passes — nothing is waiting on
    /// them, so `.utility` is the correct QoS.)
    private func invalidateSidecars(_ ids: [String]) {
        guard !accountExposureClosing, !accountExposureClosed else { return }
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return }
        var generations: [String: Int] = [:]
        generations.reserveCapacity(unique.count)
        for id in unique {
            let generation = (sidecarGeneration[id] ?? 0) + 1
            sidecarGeneration[id] = generation
            warmingSidecars[id] = generation
            generations[id] = generation
        }
        let base = baseDir
        let taskID = UUID()
        let task = Task.detached(priority: .utility) { [weak self] in
            let span = PerfSpan(name: "sidecar-rewarm-batch")
            var loaded: [(id: String, snap: SidecarSnapshot, meta: ConversationMeta?)] = []
            loaded.reserveCapacity(unique.count)
            for id in unique {
                guard !Task.isCancelled else { return }
                loaded.append((id,
                               CaptureManager.loadSidecar(captureId: id, baseDir: base),
                               ConversationMetaStore.load(captureId: id, baseDir: base)))
            }
            PerfHook.span("sidecar-rewarm-batch-n\(unique.count)", ms: span.elapsedMs())
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                defer { self.sidecarWarmTasks[taskID] = nil }
                guard !self.accountExposureClosing,
                      !self.accountExposureClosed else { return }
                for entry in loaded {
                    self.applyWarmSidecar(entry.id, snapshot: entry.snap, meta: entry.meta,
                                          generation: generations[entry.id] ?? 0)
                }
            }
        }
        sidecarWarmTasks[taskID] = task
    }

    /// Generation counter per capture, bumped on every invalidation, so a slow off-main
    /// re-warm can never clobber a newer one's result.
    private var sidecarGeneration: [String: Int] = [:]
    /// The generation of the re-warm currently in flight per capture (nil = none).
    private var warmingSidecars: [String: Int] = [:]

    /// Mark a capture's memo with a marker the MANAGER ITSELF just wrote to disk, in the same
    /// runloop tick — discard + delete are immediate, user-visible operations, so they must
    /// not wait a hop to leave the list. Memory-only; the off-main re-warm confirms it.
    private func applySidecarMarker(_ id: String, discarded: Bool = false, deleted: Bool = false) {
        sidecarCache[id] = (sidecarCache[id] ?? .unwarmed).marking(discarded: discarded, deleted: deleted)
        // N3 — a warm already IN FLIGHT was started from a pre-marker disk state, so letting it
        // land would silently un-mark the row (the marker is the whole point of this call).
        // Bumping the generation makes any in-flight result arrive stale and be dropped.
        discardInFlightSidecarWarm(id)
    }

    /// Invalidate whatever off-main sidecar warm is currently in flight for `id`: its result
    /// will fail `applyWarmSidecar`'s generation check and be dropped.
    private func discardInFlightSidecarWarm(_ id: String) {
        sidecarGeneration[id] = (sidecarGeneration[id] ?? 0) + 1
        warmingSidecars[id] = nil
    }

    /// Refresh a capture's memoised sidecar after ANY write to its transcript / card /
    /// markers, so a later rebuild reflects the change.
    ///
    /// R3 (no flicker): this NO LONGER drops the memo. Dropping it made the next rebuild
    /// cold-miss into a synchronous `transcript.json` decode ON THE MAIN ACTOR — the measured
    /// nav-stall — and now that the rebuild may not read disk, dropping it would instead make
    /// the conversation momentarily render from a placeholder and possibly VANISH. So the
    /// LAST-KNOWN value stays authoritative (the list keeps rendering exactly what it was
    /// rendering), the fresh value is read OFF-main, and a re-render is requested only if the
    /// fresh value actually differs. A stale membership/stats value survives at most one
    /// re-warm hop, which is the same window the old async writers already had.
    func invalidateSidecar(_ id: String) {
        // R2 — the LIVE conversation's rule. The ACTIVE capture's transcript changes
        // continuously, so re-deriving its facts per write would trade the CPU win for cache
        // thrash. It doesn't need them either: `isBrowsable` decides the active capture by
        // `status.streaming` (it is ALWAYS shown) and the processing banner explicitly skips
        // it, so its cached counts only feed the stats tiles. It is therefore re-warmed at
        // most once per `liveSidecarRewarmInterval` seconds, off-main, with the last request
        // in the window coalesced to the end of it. The moment the capture stops being
        // active — the finalize/endSession invalidations — the throttle no longer applies and
        // its authoritative facts land immediately.
        guard id == active?.captureId else {
            // Not (or no longer) the live capture — no throttle applies, and any window this
            // capture opened while it WAS live is done with. Drop its throttle state so the
            // per-capture bookkeeping can't outlive the capture.
            lastLiveSidecarWarmAt[id] = nil
            liveSidecarWarmPending.remove(id)
            return scheduleSidecarWarm(id, force: true)
        }
        let now = Date().timeIntervalSince1970
        // S3 — the throttle is keyed PER CAPTURE. Keyed globally, a window opened by capture X
        // swallowed capture Y's invalidation and never rescheduled it (the pending task
        // captured X's id), so Y's derived facts could stay stale indefinitely.
        let last = lastLiveSidecarWarmAt[id] ?? 0
        if now - last >= Self.liveSidecarRewarmInterval {
            lastLiveSidecarWarmAt[id] = now
            scheduleSidecarWarm(id, force: true)
            return
        }
        guard !liveSidecarWarmPending.contains(id) else { return }   // coalesced into this window
        liveSidecarWarmPending.insert(id)
        // N3 — the throttled branch still has to invalidate whatever warm is in flight: a
        // marker applied in this tick must not be clobbered by a read started before it.
        discardInFlightSidecarWarm(id)
        let wait = Self.liveSidecarRewarmInterval - (now - last)
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            guard let self else { return }
            defer { self.sidecarWarmTasks[taskID] = nil }
            guard !Task.isCancelled,
                  !self.accountExposureClosing,
                  !self.accountExposureClosed else { return }
            self.liveSidecarWarmPending.remove(id)
            self.lastLiveSidecarWarmAt[id] = Date().timeIntervalSince1970
            self.scheduleSidecarWarm(id, force: true)
        }
        sidecarWarmTasks[taskID] = task
    }

    /// How often the ACTIVE (live, still-growing) conversation's sidecar facts are re-derived
    /// off-main. Tunable; see the R2 rule in `invalidateSidecar`.
    public nonisolated static let liveSidecarRewarmInterval: TimeInterval = 5
    /// PER-CAPTURE throttle state (S3) — never global: one capture's window must not swallow
    /// another capture's invalidation.
    private var lastLiveSidecarWarmAt: [String: TimeInterval] = [:]
    private var liveSidecarWarmPending: Set<String> = []

    // MARK: main-actor decode counter (test-only, deterministic) — the CQRS invariant proof

    /// Count of transcript/meta/card decodes that ran SYNCHRONOUSLY on the MAIN ACTOR — the
    /// disk-on-main pathology a warm rebuild must never do. Incremented at every site that
    /// still reads a capture sidecar off disk SYNCHRONOUSLY (today only the deliberately
    /// un-memoized `cardMeta`; `sidecar(for:)` and `startTime` were converted to memory-only
    /// + off-main re-warm), each GATED on `Thread.isMainThread` so OFF-main warms and the
    /// off-main warm-index writer never count. Static because the sites span a nonisolated
    /// static and nonisolated instance method. Makes the CQRS assertion a hard integer
    /// (0 on a warm library; K>0 under the repro) rather than a wall-clock flake. Mirrors the
    /// existing `*ForTests` seam idiom; a nonisolated NSLock protects the counter.
    nonisolated private static let _decodeCounterLock = NSLock()
    nonisolated(unsafe) private static var _mainThreadDecodes = 0
    /// Increment the main-actor decode counter iff we are ON the main thread (the pathology).
    nonisolated static func noteMainThreadDecode() {
        guard Thread.isMainThread else { return }
        _decodeCounterLock.lock(); _mainThreadDecodes += 1; _decodeCounterLock.unlock()
    }
    /// Read the count of synchronous main-actor transcript/meta/card decodes (test-observable).
    nonisolated static var mainThreadTranscriptDecodesForTests: Int {
        _decodeCounterLock.lock(); defer { _decodeCounterLock.unlock() }; return _mainThreadDecodes
    }
    /// Reset the main-actor decode counter — call immediately before a measured rebuild.
    nonisolated static func resetMainThreadTranscriptDecodesForTests() {
        _decodeCounterLock.lock(); _mainThreadDecodes = 0; _decodeCounterLock.unlock()
    }

    // MARK: pending-remote-delete lane probes (test-only, deterministic)

    /// Two hard integers that pin the build-286 field hang (`retryPendingDeletes` sampled at
    /// `libsystem_kernel ; Foundation ; …` — a synchronous directory walk ON MAIN — while the
    /// door was unreachable and every pending delete paid a full network timeout, serially,
    /// on EVERY 5s drain):
    ///
    ///  * `mainThreadPendingDeleteDiskOpsForTests` — blocking filesystem operations the
    ///    delete lane performed while ON the main thread (the scan + each tombstone teardown).
    ///    Must be 0: the lane's disk work belongs off the main actor.
    ///  * `remoteDeleteAttemptsForTests` — door delete calls attempted. Bounds the per-cycle
    ///    fan-out and proves the unreachable-door breaker stops the cycle after the first
    ///    failure instead of paying N timeouts.
    ///
    /// Same nonisolated NSLock idiom as the decode counter above, so the
    /// assertions are machine-independent integers rather than wall-clock budgets.
    nonisolated private static let _deleteLaneLock = NSLock()
    nonisolated(unsafe) private static var _mainThreadDeleteDiskOps = 0
    nonisolated(unsafe) private static var _remoteDeleteAttempts = 0
    /// Increment the delete-lane disk-op counter iff we are ON the main thread (the pathology).
    nonisolated static func noteDeleteLaneDiskOp() {
        guard Thread.isMainThread else { return }
        _deleteLaneLock.lock(); _mainThreadDeleteDiskOps += 1; _deleteLaneLock.unlock()
    }
    nonisolated static func noteRemoteDeleteAttempt() {
        _deleteLaneLock.lock(); _remoteDeleteAttempts += 1; _deleteLaneLock.unlock()
    }
    nonisolated static var mainThreadPendingDeleteDiskOpsForTests: Int {
        _deleteLaneLock.lock(); defer { _deleteLaneLock.unlock() }; return _mainThreadDeleteDiskOps
    }
    nonisolated static var remoteDeleteAttemptsForTests: Int {
        _deleteLaneLock.lock(); defer { _deleteLaneLock.unlock() }; return _remoteDeleteAttempts
    }
    nonisolated static func resetPendingDeleteProbesForTests() {
        _deleteLaneLock.lock(); _mainThreadDeleteDiskOps = 0; _remoteDeleteAttempts = 0
        _deleteLaneLock.unlock()
    }

    /// A COALESCED visible-list rebuild for OUT-OF-MANAGER writers (the status poller's card
    /// merge, the detail-view content cache): several can fire in one runloop tick, so hop
    /// once and rebuild a single time rather than N times.
    private var sidecarRebuildScheduled = false
    private func scheduleSidecarRebuild() {
        guard !accountExposureClosing, !accountExposureClosed else { return }
        guard !sidecarRebuildScheduled else { return }
        sidecarRebuildScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.sidecarRebuildScheduled = false
            guard !self.accountExposureClosing,
                  !self.accountExposureClosed else { return }
            self.rebuildVisibleCaptures()
        }
    }

    /// The durable, lightweight card metadata (name/description/stage) for a capture —
    /// the all-time tombstone that lets EVERY conversation show a title + summary in
    /// the list, even after its transcript text has been pruned. `nil` for a capture
    /// the door hasn't reported a title/summary for yet.
    ///
    /// MEMOISED (track `residual_on_main_actor_work`) through the SAME per-capture sidecar
    /// memo everything else on the render path reads. It used to be deliberately un-memoized
    /// — driver #2 of the nav stall: `recapConversationPool()` and every rendered row called
    /// it, so one pass at N=175 was 175 synchronous `card.json` decodes ON THE MAIN ACTOR,
    /// and `lastFinishedConversation()` re-paid that scan 12×/second for the whole duration
    /// of a recording.
    ///
    /// FRESHNESS, unchanged: `card.json` is also written behind the manager's back (each
    /// capture's status poller merges title/summary), and those writers already call
    /// `invalidateSidecar`, which starts an off-main re-read. So:
    ///   • memo FRESH (see `freshMemo(for:)` — warm, no re-read in flight, and none pending
    ///     behind the live capture's re-warm throttle) → answer from MEMORY (zero disk, the
    ///     whole point);
    ///   • memo cold, or KNOWN-STALE (a re-read is in flight, or the ACTIVE capture's
    ///     re-read is waiting out its throttle window) → read disk and answer from it, so a
    ///     caller can never observe a value older than the last write — for EVERY capture,
    ///     the live one included. This is the only branch that touches disk, it is bounded by
    ///     the number of card WRITES (not renders/ticks), and it keeps every existing
    ///     freshness contract (e.g. the retention sweep's card merge is visible to the very
    ///     next read).
    /// The answer is byte-identical to disk except a >400-char provisional body, which is
    /// truncated on purpose — see `CardFacts`.
    public func cardMeta(for captureId: String) -> ConversationCardMeta? {
        if let snap = freshMemo(for: captureId) { return snap.card?.renderCard }
        // Count it: a synchronous main-actor card decode is exactly the pathology the gate
        // watches. Reaching here means a write invalidated the memo and its off-main re-read
        // has not landed yet (or the capture has never been warmed at all).
        Self.noteMainThreadDecode()
        if sidecarCache[captureId] == nil { _ = sidecar(for: captureId) }   // schedule the warm
        return ConversationCardStore.load(captureId: captureId, baseDir: baseDir)
    }

    /// Per-capture status pollers (the door→Lore stage chip, F11). Lazily created +
    /// memoised so a card re-render reuses the same poller (one poll loop per
    /// capture). Driven by the card's onAppear/onDisappear.
    private var pollers: [String: CaptureStatusPoller] = [:]

    /// The status poller for a capture, creating one on first ask. The card calls
    /// `.start()` on appear and `.stop()` on disappear.
    public func statusPoller(for captureId: String) -> CaptureStatusPoller? {
        guard !isDeleted(captureId) else { return nil }
        if let existing = pollers[captureId] { return existing }
        let client = DoorClient(target: target, log: log)
        // Pass baseDir so the poller persists title/summary/stage into the durable card
        // tombstone (card.json) — the all-time browsable name + description.
        // F1 — the poller merges title/summary into card.json OUTSIDE the manager's sight
        // (its own off-main loop). Wire a callback (fired only when the merge actually
        // changed the card) that invalidates the memo + coalesces a rebuild, so the
        // browsable tombstone / card reflect it without a per-rebuild disk read.
        let poller = CaptureStatusPoller(captureId: captureId, client: client, baseDir: baseDir,
                                         onCardWritten: { [weak self] id in
            self?.invalidateSidecar(id)
            self?.scheduleSidecarRebuild()
        })
        pollers[captureId] = poller
        return poller
    }

    // MARK: proactive transcript cache (recent ~14d conversations cached on sight)

    /// In-flight proactive caches, so an on-sight fetch never double-fires for the
    /// same capture while one is already running.
    private var cachingTranscripts: Set<String> = []

    /// Ensure a RECENT conversation's transcript is cached locally — fetch it from the
    /// door "on sight" (when its card appears / reaches a ready stage) and persist it,
    /// so recent conversations are available offline + instantly. No-op when the
    /// transcript is already cached, when the conversation is OLDER than the ~14-day
    /// window (those load on demand from the detail view), or when a fetch is already
    /// in flight. Offline-safe: a failed/empty fetch simply caches nothing.
    public func ensureRecentTranscriptCached(_ captureId: String) {
        guard !accountExposureClosing, !accountExposureClosed else { return }
        guard !isDeleted(captureId) else { return }
        // Memo-served (see `hasCachedTranscript`): this runs from every row's `onAppear`, so
        // a raw `fileExists` here is per-row disk on the main actor.
        guard !hasCachedTranscript(captureId) else { return }
        guard CaptureRetention.isRecentForTranscriptCache(conversationAge: conversationAgeSeconds(captureId)) else { return }
        guard !cachingTranscripts.contains(captureId) else { return }
        cachingTranscripts.insert(captureId)
        let baseDir = self.baseDir
        let fetch = self.fetchContent
        let task = Task { @MainActor [weak self] in
            defer {
                self?.cachingTranscripts.remove(captureId)
                self?.recentTranscriptCacheTasks[captureId] = nil
            }
            guard self?.isDeleted(captureId) == false else { return }
            guard let c = await fetch(captureId), c.found, !c.transcript.isEmpty else { return }
            guard !Task.isCancelled,
                  self?.accountExposureClosing != true,
                  self?.accountExposureClosed != true else { return }
            let entry = CachedTranscript(transcript: c.transcript, title: c.title,
                                         summary: c.summary, segments: c.segments, speakers: c.speakers,
                                         paragraphs: c.paragraphs,
                                         fetchedAt: UInt64(max(0, Date().timeIntervalSince1970)))
            TranscriptCacheStore.save(entry, captureId: captureId, baseDir: baseDir)
            // Also seed the durable card tombstone with the name/description.
            ConversationCardStore.merge(captureId: captureId, baseDir: baseDir,
                                        title: c.title, summary: c.summary, stage: nil)
            // Transcript + card just changed on disk. STALE-COMMENT FIX (N5): the immediate
            // rebuild here can no longer see that change — `invalidateSidecar` keeps the
            // last-known memo and re-reads OFF-main, and `applyWarmSidecar` schedules the
            // re-render when the fresh facts land. Membership from the freshly-cached
            // tombstone therefore arrives one off-main hop later, by design; the rebuild
            // below is kept only to republish state that changed on the main actor.
            self?.invalidateSidecar(captureId)
            self?.rebuildVisibleCaptures()
        }
        recentTranscriptCacheTasks[captureId] = task
    }

    /// Age (seconds) of a conversation since it started, from the durable `meta.json`
    /// start. 0 (treated as "recent") when there's no metadata yet.
    private func conversationAgeSeconds(_ captureId: String) -> TimeInterval {
        guard let started = ConversationMetaStore.load(captureId: captureId, baseDir: baseDir)?.startedAt,
              started > 0 else { return 0 }
        return max(0, Date().timeIntervalSince1970 - TimeInterval(started))
    }

    public var pendingSegments: Int { captures.reduce(0) { $0 + $1.status.pendingSegments } }
    public var hasPending: Bool { pendingSegments > 0 }
    public var isCapturing: Bool { active != nil && !isPaused }

    /// Begin the source's connect flow (app: start scanning / auto-reconnect the
    /// saved Omi). Call from the screen's onAppear. When the user has chosen the phone
    /// mic as the capture device, we do NOT auto-start the Omi BLE — so it can't grab
    /// an ambient session out from under a phone-mic recording.
    public func startSource() {
        // The accepted SwiftUI owner may reach its child onAppear before the parent's
        // onAppear. Claim first so a synchronous source.start() transition is never lost.
        activateSourceOwnership()
        if captureSource == .omi { source.start() }
    }
    public func stopSource() { source.stop() }

    /// Deterministic test join for the source-state callback that opens a capture.
    func waitUntilActiveCaptureForTests() async {
        guard active == nil else { return }
        await withCheckedContinuation { continuation in
            activeCaptureWaitersForTests.append(continuation)
        }
    }

    /// Inert, idempotent process registration retained by this actual manager
    /// instance, so SwiftUI StateObject reuse cannot strand a transient token.
    public func registerAccountExposures(
        with coordinator: AccountExposureCoordinator = .process
    ) {
        guard accountExposureRegistrations.isEmpty else { return }
        let live = AccountExposureRegistration(
            participantID: "capture-manager",
            kind: .live,
            binding: accountBinding,
            owner: self,
            close: { manager, expected in
                await manager.closeAccountExposure(expected: expected)
            })
        let stale = AccountExposureRegistration(
            participantID: "capture-manager-stale-work",
            kind: .staleWork,
            binding: accountBinding,
            owner: self,
            close: { manager, expected in
                await manager.closeAccountExposure(expected: expected)
            })
        accountExposureRegistrations = [live, stale]
        coordinator.register(live)
        coordinator.register(stale)
    }

    /// Deterministic notification that terminal account closure has installed its
    /// callback gate, before any injected continuation is released.
    func waitUntilAccountExposureClosingForTests() async {
        guard !accountExposureClosing else { return }
        await withCheckedContinuation { continuation in
            accountExposureClosingWaitersForTests.append(continuation)
        }
    }

    /// Join terminal work without sleeping. Returns true only after the close ACK
    /// has drained every manager-owned task covered by this boundary.
    func awaitAccountExposureWorkQuiescenceForTests() async -> Bool {
        if accountExposureWorkQuiesced { return true }
        guard accountExposureClosing else { return false }
        await withCheckedContinuation { continuation in
            accountExposureQuiescenceWaitersForTests.append(continuation)
        }
        return accountExposureWorkQuiesced
    }

    /// Terminally seal this manager for one exact account generation. No user
    /// preference is changed: this is a privacy/lifecycle boundary, not a pause.
    public func closeAccountExposure(
        expected: CaptureAccountScope.AccountBinding
    ) async -> AccountExposureCloseResult {
        guard let accountBinding else { return .unavailable }
        guard expected == accountBinding else { return .ownerMismatch }
        if accountExposureClosed { return .alreadyClosed }
        if accountExposureClosing {
            guard await awaitAccountExposureWorkQuiescenceForTests() else {
                return .verificationFailed
            }
            if accountExposureClosed { return .alreadyClosed }
            return await retryOutstandingAudioExposureClosure()
        }

        accountExposureClosing = true
        accountExposureWorkQuiesced = false
        let closingWaiters = accountExposureClosingWaitersForTests
        accountExposureClosingWaitersForTests.removeAll()
        for waiter in closingWaiters { waiter.resume() }

        drainTimer?.invalidate()
        drainTimer = nil
        meterTimer?.invalidate()
        meterTimer = nil
        segmentTimer?.invalidate()
        segmentTimer = nil

        hydration?.cancel()
        drainTask?.cancel()
        let closingWarmListIndexTasks = Array(warmListIndexTasks.values)
        for task in closingWarmListIndexTasks { task.cancel() }
        let closingSidecarWarmTasks = Array(sidecarWarmTasks.values)
        for task in closingSidecarWarmTasks { task.cancel() }
        let closingRecentTranscriptTasks =
            Array(recentTranscriptCacheTasks.values)
        for task in closingRecentTranscriptTasks { task.cancel() }
        let closingDiscardPruneTasks =
            Array(discardedFragmentPruneTasks.values)
        for task in closingDiscardPruneTasks { task.cancel() }
        let closingMergeFinalizeTasks = Array(mergeFinalizeTasks.values)
        for task in closingMergeFinalizeTasks { task.cancel() }
        let eagerTasks = Array(eagerEndSessionTasks.values)
        for task in eagerTasks { task.cancel() }

        _ = await router.closeAccountExposure()

        sourceExposureClosePending = true
        micExposureClosePending = micSource.map { $0 !== source } ?? false
        let sourceFailure = await closeOutstandingAudioExposures()

        let activeAtClose = active
        if let wal = activeAtClose {
            wal.finish()
            active = nil
        }
        if let held = suspendedSession {
            if held.wal !== activeAtClose { held.wal.finish() }
            suspendedSession = nil
        }
        isRecordingMic = false
        recordingClock = nil
        endLiveTranscription()
        let closingLiveFinishTasks =
            Array(liveTranscriptionFinishTasks.values)
        for task in closingLiveFinishTasks { task.cancel() }

        if let hydration { await hydration.value }
        if let drainTask { await drainTask.value }
        if mergeOperationsInFlight > 0 {
            await withCheckedContinuation { continuation in
                mergeOperationWaiters.append(continuation)
            }
        }
        for task in closingWarmListIndexTasks { await task.value }
        for task in closingSidecarWarmTasks { await task.value }
        for task in closingRecentTranscriptTasks { await task.value }
        for task in closingDiscardPruneTasks { await task.value }
        for task in closingMergeFinalizeTasks { await task.value }
        for task in closingLiveFinishTasks { await task.value }
        for task in eagerTasks { await task.value }
        eagerEndSessionTasks.removeAll()
        self.drainTask = nil
        warmListIndexTasks.removeAll()
        latestWarmListIndexTask = nil
        sidecarWarmTasks.removeAll()
        recentTranscriptCacheTasks.removeAll()
        discardedFragmentPruneTasks.removeAll()
        mergeFinalizeTasks.removeAll()
        liveTranscriptionFinishTasks.removeAll()

        let currentPollers = Array(pollers.values)
        for poller in currentPollers { await poller.close() }
        pollers.removeAll()

        if sourceFailure == nil {
            accountExposureClosed = true
        }
        accountExposureWorkQuiesced = true
        let quiescenceWaiters = accountExposureQuiescenceWaitersForTests
        accountExposureQuiescenceWaitersForTests.removeAll()
        for waiter in quiescenceWaiters { waiter.resume() }
        return sourceFailure ?? .closed
    }

    /// Retry only audio-source closure verification after the manager's router,
    /// timers, WAL, and old-root tasks have already been terminally sealed.
    private func closeOutstandingAudioExposures()
        async -> AccountExposureCloseResult?
    {
        // COLLECTED, then folded by severity — NOT "the first result that wasn't
        // closed". Once `.unavailable` counts as proof of closure, taking the
        // first non-closed answer lets an absent `source` hide a
        // `.verificationFailed` from `micSource`, and the erase proceeds while the
        // microphone could not confirm it had stopped for this account.
        var answers: [AccountExposureCloseResult] = []
        if sourceExposureClosePending {
            let result: AccountExposureCloseResult
            if let closable = source as? any AccountAudioSourceExposure {
                result = await closable.closeAudioExposure()
            } else {
                source.stop()
                result = .closed
            }
            // Latching still requires that something was actually closed: an
            // absent child leaves the retry path free to ask again.
            if result == .closed || result == .alreadyClosed {
                sourceExposureClosePending = false
            } else {
                answers.append(result)
            }
        }
        if micExposureClosePending, let micSource {
            let result: AccountExposureCloseResult
            if let closable = micSource as? any AccountAudioSourceExposure {
                result = await closable.closeAudioExposure()
            } else {
                micSource.stop()
                result = .closed
            }
            if result == .closed || result == .alreadyClosed {
                micExposureClosePending = false
            } else {
                answers.append(result)
            }
        }
        guard !answers.isEmpty else { return nil }
        return AccountExposureCloseResult.aggregate(answers)
    }

    private func retryOutstandingAudioExposureClosure()
        async -> AccountExposureCloseResult
    {
        if audioExposureCloseRetryInFlight {
            return await withCheckedContinuation { continuation in
                audioExposureCloseRetryWaiters.append(continuation)
            }
        }
        audioExposureCloseRetryInFlight = true
        let failed = await closeOutstandingAudioExposures()
        let result = failed ?? .closed
        if failed == nil { accountExposureClosed = true }
        audioExposureCloseRetryInFlight = false
        let waiters = audioExposureCloseRetryWaiters
        audioExposureCloseRetryWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
        return result
    }

    // MARK: capture-source selection (Omi vs phone mic) + phone-mic recording

    /// Choose the active capture device. Persisted. Picking the phone mic stops the
    /// Omi link so it won't auto-capture; picking the Omi (re)starts its connect flow.
    public func selectCaptureSource(_ kind: CaptureSourceKind) {
        guard kind != captureSource else { return }
        captureSource = kind
        CaptureSettings.captureSource = kind
        switch kind {
        case .phoneMic:
            source.stop()                 // release the Omi so it can't grab a session
        case .omi:
            if isRecordingMic { stopMicRecording() }
            source.start()
        }
        pushLiveState(.update)   // source switch → refresh the source label on both surfaces
        log?.info("capture source → \(kind.rawValue)")
    }

    /// Start recording from the phone microphone. No-op if there's no mic source, it's
    /// already recording, or an Omi session is already active (the UX only offers this
    /// when the Omi is disconnected). Drives the normal lifecycle via the mic's
    /// `.streaming` state → beginSession.
    public func startMicRecording() {
        // Make a silent block OBSERVABLE: record WHY before the guard returns so the UI can
        // explain it (the guard logic itself is unchanged — it stays correct).
        if micSource == nil {
            lastRecordBlockReason = "Microphone access is needed — enable it in Settings"
        } else if isRecordingMic {
            lastRecordBlockReason = nil   // already recording — not an error state
        } else if !(active == nil || suspendedSession != nil) {
            lastRecordBlockReason = "Finish the current voice note first"
        } else {
            lastRecordBlockReason = nil
        }
        // Allowed when idle OR when the only "active" session is an Omi conversation
        // HELD for reconnect-grace (the user's explicit record outranks the hold —
        // onSourceState closes it and begins a fresh mic session).
        guard let micSource, !isRecordingMic, active == nil || suspendedSession != nil else { return }

        // Resolve mic permission BEFORE presenting the recording surface. The old order
        // set `isRecordingMic = true` (which presents the recording screen) and only THEN
        // let `micSource.start()` resolve permission — so a denial flashed the recording
        // UI up and immediately tore it down (the `.failed` path resets the flag). Now:
        // present only once we KNOW the mic is usable; a denial surfaces the block caption
        // and never presents. On non-iOS hosts (the test runner) permission is implicit —
        // keep the original synchronous begin so the pipeline/tests are unchanged.
        #if os(iOS)
        switch micPermission() {
        case .granted:
            beginMicRecording(micSource)
        case .denied:
            lastRecordBlockReason = "Microphone access is needed — enable it in Settings"
        case .undetermined:
            requestMicPermission { [weak self] granted in
                Task { @MainActor in self?.onMicPermissionResolved(granted) }
            }
        }
        #else
        beginMicRecording(micSource)
        #endif
    }

    /// Start the mic session for real (flag → present, reset segmenter, ask the source to
    /// start). Split out of `startMicRecording` so the permission-gated path and the
    /// already-granted path share one begin.
    private func beginMicRecording(_ micSource: AudioFrameSource) {
        // `record-start` span (track 20260717T0759 AC6): OUR work from begin through the
        // runloop turn that commits the recording surface's presentation. Deliberately
        // starts here — after any first-run permission prompt — so the metric is app
        // latency, not user decision time. Budget-gated in sim-perf's nav phase (<200ms).
        let recordStartSpan = PerfSpan(name: "record-start")
        DispatchQueue.main.async { PerfHook.span("record-start", ms: recordStartSpan.elapsedMs()) }
        lastRecordBlockReason = nil   // starting cleanly — clear any prior block message
        recordingScreenMinimized = false   // a fresh recording always presents full-screen
        isRecordingMic = true
        // A fresh recording is never born paused (the `.streaming` mic branch clears any
        // inherited pause) — anchor the session clock to now. `beginSession` will preserve
        // this when the mic's `.streaming` opens the WAL, so internal rolls keep it.
        recordingClock = RecordingClock(startedAt: Date())
        router.resetSegmenter()
        micSource.start()
        // Diagnostic slice: how much of record-start is OUR synchronous begin work vs
        // the SwiftUI presentation commit that follows in the same runloop turn.
        PerfHook.span("record-start-sync", ms: recordStartSpan.elapsedMs())
        log?.info("phone mic: recording requested")
    }

    #if os(iOS)
    /// The mic permission decision after a first-run prompt. Re-checks the guard (state
    /// may have moved while the OS prompt was up) then begins, or surfaces the block.
    private func onMicPermissionResolved(_ granted: Bool) {
        guard let micSource, !isRecordingMic, active == nil || suspendedSession != nil else { return }
        if granted {
            beginMicRecording(micSource)
        } else {
            lastRecordBlockReason = "Microphone access is needed — enable it in Settings"
        }
    }

    /// Three-state mic permission, normalised across the iOS 17 split (`AVAudioApplication`)
    /// and the older `AVAudioSession` API.
    private enum MicPermission { case granted, denied, undetermined }
    /// Test seam: the iOS-simulator test runner cannot drive the real
    /// AVAudioApplication permission prompt, so mic tests (which inject a fake
    /// source) would otherwise stall on `.undetermined`. Setting this forces the
    /// decision so the state machine runs on iOS exactly as it does on the macOS
    /// runner. `nil` (default) = use the real system API — production is untouched.
    public var micPermissionOverrideForTests: Bool?
    private func micPermission() -> MicPermission {
        if let forced = micPermissionOverrideForTests {
            return forced ? .granted : .denied
        }
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            default: return .undetermined
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            default: return .undetermined
            }
        }
    }
    private func requestMicPermission(_ done: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { done($0) }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { done($0) }
        }
    }
    #endif

    /// Stop the phone-mic recording. The mic's `.stopped` state ends the session and
    /// finalizes the capture through the normal path.
    public func stopMicRecording() {
        guard let micSource, isRecordingMic else { return }
        recordingScreenMinimized = false   // explicit end — clean slate for the next recording
        micSource.stop()
        log?.info("phone mic: stop requested")
    }

    public func toggleMicRecording() { isRecordingMic ? stopMicRecording() : startMicRecording() }

    // MARK: full-screen recording surface — minimize / restore (never stops recording)

    /// MINIMIZE the full-screen recording surface: the recording keeps running, the
    /// cover dismisses, and the rest of the app becomes reachable. The persistent
    /// recording pill is the way back.
    public func minimizeRecordingScreen() { recordingScreenMinimized = true }

    /// RESTORE the full-screen recording surface (the pill tap) — re-present the cover
    /// over whatever screen the user wandered to.
    public func restoreRecordingScreen() { recordingScreenMinimized = false }

    // MARK: recording-time ambient candidates (the notification/task rows)

    /// Record a lane-surfaced candidate for the live recording surface: newest first,
    /// deduped by utterance, capped. Called on the main actor from the ambient tick.
    /// `forCapture` is the id the candidate was mined FROM — the lane's `consider()`
    /// runs detached and slow (an on-device LLM, ~1–5s), so by the time it returns the
    /// user may have ended the recording or the session may have rolled to a new
    /// conversation. Drop the candidate unless it still belongs to the active capture,
    /// so a card mined from a closed/previous conversation never appears on the next one.
    public func noteRecordingCandidate(_ candidate: AmbientCandidate, forCapture captureId: String) {
        guard active?.captureId == captureId else { return }
        live.candidates.removeAll { $0.utterance == candidate.utterance }
        live.candidates.insert(candidate, at: 0)
        if live.candidates.count > Self.maxRecordingCandidates {
            live.candidates = Array(live.candidates.prefix(Self.maxRecordingCandidates))
        }
    }

    /// Drop a candidate the user acted on or dismissed from the live surface.
    public func dismissRecordingCandidate(_ candidate: AmbientCandidate) {
        live.candidates.removeAll { $0.utterance == candidate.utterance }
        UsageHook.action("dismissed")   // content-free: the enum outcome, never the candidate text
    }

    // MARK: ambient session lifecycle (driven by the source, not a button)

    private func onSourceState(_ state: AudioSourceState) {
        guard !accountExposureClosing, !accountExposureClosed else { return }
        sourceState = state
        switch state {
        case .streaming:
            if isRecordingMic {
                // PHONE-MIC start. This `.streaming` came from the MIC, not the Omi —
                // it must NEVER be mistaken for an Omi reconnect (that hijack resumed
                // the PAUSED held Omi capture and silently ate the mic's frames:
                // "recording but nothing records"). An explicit user recording
                // outranks the reconnect-grace hold: close the held conversation now
                // and start a FRESH, UNPAUSED mic session.
                if suspendedSession != nil {
                    suspendedSession = nil
                    log?.info("phone mic: closing Omi conversation held for reconnect — user chose to record")
                    endSession()
                }
                if isPaused { isPaused = false }   // a new recording is never born paused
                if active == nil { router.resetSegmenter(); beginSession() }
            } else if suspendedSession != nil {
                // Transient Omi reconnect WITHIN the grace window → RESUME the SAME
                // conversation (same captureId). Do NOT mint a new session or finalize a
                // stub — this is what coalesces reconnect churn into one conversation.
                suspendedSession = nil
                if !isPaused { router.noteActiveNow() }   // the disconnect gap is not a silence gap
                log?.info("capture \(active?.captureId ?? "?"): Omi reconnected within grace → resumed (no new session)")
            } else if active == nil {
                recordingScreenMinimized = false   // a fresh ambient capture presents full-screen
                router.resetSegmenter()
                // Omi-continuity (07-16 over-split fix): a reconnect or app-relaunch INSIDE
                // the silence gap RESUMES the in-flight conversation (same capture id +
                // continued segment sequence) instead of minting a new one — the in-memory
                // `suspendedSession` hold dies with the app, so a watchdog kill or a
                // >grace link gap used to fragment one meeting into many. Ambient Omi only;
                // the `isRecordingMic` branch above owns the phone-mic path (unchanged).
                if captureSource == .omi,
                   let resumeId = CaptureManager.resumableCaptureId(
                       baseDir: baseDir,
                       silenceGap: silenceGapSeconds,
                       resumingDevice: resumingDeviceIdentity),
                   resumeSession(captureId: resumeId) {
                    // resumed the same conversation — no new id minted
                } else if isPaused {
                    // Paused desired-state: open the (paused) session as before — it
                    // captures nothing until the user resumes. Speech-gating is only for
                    // the LISTENING path; a paused session writes no frames and the
                    // segmenter isn't fed, so it never rolls into empty cards.
                    beginSession()
                } else {
                    // Ambient Omi, LISTENING: don't open a conversation on stream-start —
                    // wait for real speech (armForSpeech). Silence / one-off noise never
                    // mints an empty "Untitled conversation" (Nick 2026-07-21).
                    armForSpeech()
                }
            }
        case .stopped, .failed:
            if isRecordingMic {
                // Phone-mic Stop / permission-deny is an EXPLICIT boundary → end now and
                // reset the mic flag so the Record button returns to idle (no grace).
                isRecordingMic = false
                recordingClock = nil   // explicit stop → clear the session clock (no roll)
                endSession()
                stopMeterIfIdle()   // session ended to idle — the user may be off the capture surface
                // A permission-denied failure is otherwise silent — surface it so the
                // Record CTA can point the user at Settings.
                if case .failed(let reason) = state {
                    lastRecordBlockReason = reason.range(of: "permission", options: .caseInsensitive) != nil
                        ? "Microphone access is needed — enable it in Settings"
                        : reason
                }
            } else if let wal = active, suspendedSession == nil {
                // Omi BLE dropped mid-conversation → HOLD it open for a brief reconnect
                // grace so a flaky link doesn't split the conversation into fragments. The
                // capture watchdog ends it if the device doesn't return within the window.
                suspendedSession = (wal, Date().timeIntervalSinceReferenceDate)
                log?.info("capture \(wal.captureId): Omi disconnected — holding for reconnect (ends after \(Int(SilenceSegmenter.defaultSilenceGap))s of voiced silence)")
            } else if active == nil {
                // Omi dropped while armed-listening (no conversation open) → stop arming;
                // the reconnect's `.streaming` re-arms. Nothing to hold or finalize.
                router.setArmed(false)
                stopMeterIfIdle()
            }
        case .idle, .scanning:
            break
        }
    }

    // MARK: silence-gap auto-segmentation (req 9)

    /// A silence gap closes the current conversation and returns to LISTENING — the next
    /// conversation opens only when real speech is heard again (armForSpeech), so each
    /// closed conversation (which by construction contained voice) surfaces on its own and
    /// the quiet BETWEEN conversations never mints an empty card. Capture stays live.
    private func handleSegment(_ event: SegmentEvent) {
        guard !accountExposureClosing, !accountExposureClosed else { return }
        switch event {
        case .opened:
            log?.info("capture: segment OPENED (voice after idle)")
            if active == nil { beginSession() }   // edge: open if somehow idle
        case .closed:
            guard active != nil else { return }
            endSession()
            recordingClock = nil       // the conversation ended → the next anchors on its own speech
            armForSpeech()             // back to LISTENING — next voice opens a fresh conversation
            log?.info("capture: silence gap (\(Int(silenceGapSeconds))s) → conversation closed, listening")
        }
    }

    /// Ambient Omi is streaming but no one is speaking yet: LISTEN (meter the live
    /// waveform) WITHOUT opening a conversation. A confirmed speech onset
    /// (`router.onSpeechOnset`) opens the session — so silence and one-off noises never
    /// mint an empty "Untitled conversation." Ambient-Omi only; the phone-mic path opens
    /// immediately (an explicit recording is never speech-gated).
    private func armForSpeech() {
        guard active == nil, !isPaused else { return }   // paused = idle; a live session isn't re-armed
        recordingScreenMinimized = false
        router.resetSegmenter()          // clean boundary state for the session we may open
        router.resetLevelMeter()         // fresh Opus decoder for an accurate listening meter
        router.setArmed(true)            // meter + pre-roll ring + onset detection; no WAL/card
        startMeter()                     // the "Listening…" waveform breathes while we wait
        log?.info("capture: armed — listening for speech (ambient \(captureSource.rawValue); no conversation until voice)")
    }

    /// A real speech onset was heard while armed → open the conversation now. The
    /// router's pre-roll ring drains into the new session on setWAL, so the first words
    /// aren't clipped.
    private func handleSpeechOnset() {
        guard !accountExposureClosing, !accountExposureClosed else { return }
        guard active == nil, !isRecordingMic, !isPaused else { return }   // already recording / mic / paused
        log?.info("capture: speech onset → opening conversation")
        beginSession()
    }

    // MARK: segmentation watchdog (wall-clock silence + runaway force-split)

    /// Hard backstops on a single conversation. Omi has NO max-duration boundary (the
    /// 120s silence gap is THE rule); these only catch a runaway with truly continuous
    /// audio so nothing accumulates for hours/days. 4h matches Omi's silence-gap clamp
    /// ceiling. Tunable. (`foundryx-hearth/research/20260628_omi_segmentation_learnings.md`.)
    public nonisolated static let maxConversationSeconds: TimeInterval = 4 * 60 * 60
    /// ~4h of audio at the WAL's ~1 segment/s — a segment-count backstop in case the
    /// clock is unreliable (backgrounded). Tunable.
    public nonisolated static let maxConversationSegments = 15_000

    private var segmentTimer: Timer?

    // MARK: Ambient-intelligence lane (track 20260710T2030 v3, Tier 1)

    /// The opt-in on-device ambient lane. `nil` (default) = feature absent. Wired at
    /// app startup; the lane itself re-checks the user toggle per call, so flipping
    /// Settings applies immediately without rewiring.
    public var ambientLane: AmbientLane?
    /// Called with a surfaced candidate (App wires the local notification). Runs on
    /// the main actor.
    public var onAmbientCandidate: (@MainActor (AmbientCandidate) -> Void)?
    /// Ships the on-device ambient GATE/CARD signal (redacted — no raw text) to the
    /// desktop door on the drain cadence (track v3.3). Wired ONLY in computer mode
    /// (local-only tier has no door → nil → never ships). The shipper self-gates on
    /// the ambient opt-in and is best-effort — it never blocks or fails the drain.
    public var ambientSignalShipper: AmbientSignalShipper?
    /// Throttle the piggybacked signal ship well below the 5s drain tick — the logs
    /// grow slowly and shipping is pure visibility, never latency-sensitive.
    private var lastAmbientShip = Date.distantPast
    private static let ambientShipInterval: TimeInterval = 30
    /// Segmentation ticks (5s each) between gate evaluations. 2 ⇒ the gate runs on
    /// the rolling LIVE transcript about every 10s — responsive without hammering the
    /// on-device model (running an LLM every second is 60× the battery for no gain;
    /// a conversation's meaning barely moves in a second). Tunable from AC0 data.
    public static let ambientGateEveryNTicks = 2
    private var ambientTickDivider = 0

    /// Best-effort: on the drain cadence (throttled to ~30s), ship any NEW redacted
    /// ambient signal to the desktop door. Detached so it never blocks the drain; the
    /// shipper self-gates on the opt-in and swallows all errors. No-op when no shipper
    /// is wired (local-only tier).
    private func shipAmbientSignalIfDue() {
        guard let shipper = ambientSignalShipper else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAmbientShip) >= Self.ambientShipInterval else { return }
        lastAmbientShip = now
        Task.detached(priority: .utility) { await shipper.shipIfEnabled() }
    }

    /// About every 10s while a capture is actively recording, gate the current rolling
    /// LIVE transcript window (the SpeechAnalyzer preview already streaming — no
    /// re-transcription). Runs on a detached task so it never blocks segmentation; a
    /// surfaced candidate is handed to `onAmbientCandidate` (Tier 2/notification).
    private func tickAmbientLane(captureId: String) {
        guard let lane = ambientLane else { return }
        ambientTickDivider += 1
        guard ambientTickDivider >= Self.ambientGateEveryNTicks else { return }
        ambientTickDivider = 0
        let window = liveTranscript.displayText
        guard !window.isEmpty else { return }
        let onCandidate = onAmbientCandidate
        Task.detached(priority: .utility) { [weak self] in
            if let candidate = await lane.consider(captureId: captureId, window: window) {
                // Surface it on the live recording screen (notification/task rows) AND
                // hand it to Tier 2 (door routing + local notification).
                await self?.noteRecordingCandidate(candidate, forCapture: captureId)
                if let onCandidate { await onCandidate(candidate) }
            }
        }
    }

    /// Always-on watchdog: closes a conversation after a real silence gap EVEN when the
    /// source has stopped delivering frames (the Omi BLE stream goes quiet during
    /// silence, so the frame-driven segmenter never sees the gap — the root cause of one
    /// capture swallowing many conversations), and force-splits a runaway that has blown
    /// past the hard duration/segment backstop. Runs regardless of which screen is
    /// visible (unlike the meter), so ambient capture is always bounded.
    private func startSegmentTimer() {
        segmentTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }   // stop after teardown
            Task { @MainActor in self?.tickSegmentation() }
        }
    }

    private func tickSegmentation() {
        emitCaptureHeartbeatIfDue()   // Omi-path diagnostics (runs even while paused)
        resolveReconnectGrace()       // end a held session the device never reconnected to
        guard suspendedSession == nil else { return }   // don't segment/split a suspended session
        guard let wal = active, !isPaused else { return }
        tickAmbientLane(captureId: wal.captureId)   // opt-in Tier-1 lane, ~60s cadence
        // 1. Wall-clock silence boundary (fires when no frames arrive during quiet).
        if let event = router.tickSilence() {
            handleSegment(event)
            return
        }
        // 2. Hard backstop: force-split a runaway conversation (duration/segment cap).
        if CaptureManager.shouldForceSplit(startedAt: startTime(of: wal),
                                           totalSegments: wal.status.totalSegments,
                                           now: Date().timeIntervalSince1970) {
            forceSplit()
        }
    }

    // MARK: Omi capture-path diagnostics (debug "shows recording but nothing records")

    /// Cadence of the capture heartbeat — one rate-limited diag line so the storm-prone
    /// device never floods the diag sink. Tunable.
    public nonisolated static let captureHeartbeatInterval: TimeInterval = 10
    private var lastHeartbeatAt: TimeInterval = 0
    private var lastHeartbeatFrames = 0

    private var sourceStateLabel: String {
        switch sourceState {
        case .idle: return "idle"
        case .scanning: return "scanning"
        case .streaming: return "streaming"
        case .stopped: return "stopped"
        case .failed(let m): return "failed(\(m))"
        }
    }

    /// While a capture session is open, emit ONE diag line every ~10s summarizing the
    /// Omi path end-to-end — source kind + liveness, FRAMES received since the last beat,
    /// last frame size, and segment progress — so the desktop `/diag/log` shows whether
    /// live frames are arriving at all. A zero-frame beat while capturing is the precise
    /// signature of "shows recording but nothing records" (BLE subscribed, no audio
    /// notifications) — surfaced as an explicit warning. Routed through the same `log`
    /// the door ships to `/diag/log` (grep `omi diag:`).
    private func emitCaptureHeartbeatIfDue() {
        guard active != nil else { return }   // only while a session is open
        let now = Date().timeIntervalSince1970
        guard now - lastHeartbeatAt >= Self.captureHeartbeatInterval else { return }
        let s = router.stats()
        let delta = s.count - lastHeartbeatFrames
        lastHeartbeatFrames = s.count
        lastHeartbeatAt = now
        let st = active?.status
        log?.info(String(format: "omi diag: src=%@ state=%@ paused=%@ frames+%d total=%d lastBytes=%d seg=%d/%d",
                         captureSource.rawValue, sourceStateLabel, isPaused ? "y" : "n",
                         delta, s.count, s.lastBytes, st?.syncedSegments ?? 0, st?.totalSegments ?? 0))
        if delta == 0 && !isPaused {
            log?.warn("omi diag: 0 frames in last \(Int(Self.captureHeartbeatInterval))s while capturing — the source is delivering NO audio (check BLE notify/subscription or the device mic)")
        }
    }

    /// Pure force-split decision: a conversation that has run past the hard duration OR
    /// segment backstop must be split so nothing accumulates indefinitely. Tested.
    public nonisolated static func shouldForceSplit(startedAt: TimeInterval,
                                                    totalSegments: Int,
                                                    now: TimeInterval) -> Bool {
        if totalSegments >= maxConversationSegments { return true }
        return (now - startedAt) >= maxConversationSeconds
    }

    /// Finalize the runaway conversation (clean bounds via endSession → recordEnd) and
    /// open a fresh one. The forced boundary is NOT gated by the min-content rule — a
    /// runaway by definition has plenty of content.
    private func forceSplit() {
        endSession()
        beginSession()
        router.resetSegmenter()
        log?.info("capture: hard cap reached → forced new conversation (max duration/segments)")
    }

    // MARK: orphan reconcile (crash-orphaned captures get bounds + finalize on launch)

    /// A capture that was active when the app was killed never ran `endSession`, so it
    /// has no `ended_at` and was never finalized → it shows as un-bounded and never
    /// reaches Lore. On launch, give every such orphan real bounds (end = its newest
    /// segment time) and mark it pending-finalize so the drain ships it. Conservative:
    /// only captures with real audio, a recorded start, NO recorded end, not already
    /// pending-finalize, and not confirmed in Lore. (Forward-only: this bounds + ingests
    /// an already-merged capture; it cannot un-merge one.)
    private func reconcileOrphanedCaptures() {
        // Track whether this pass discarded anything: the markers land on DISK, but the
        // published list was built BEFORE they existed — without republishing, a pruned
        // zombie card stays visible for the entire (days-long) iOS session and only
        // vanished on a cold relaunch. Removing the WALs from `captures` (not just
        // re-filtering) also removes their segments from the sync banner count and
        // their WALs from every later drain/prune iteration.
        var discardedAny = false
        // S7 — every capture this pass touches (stuck-empty discard, orphan meta bound) is
        // re-warmed in ONE batched off-main hop at the end, not one `.userInitiated`
        // full-transcript decode per capture fanned out from inside the loop.
        var touched: [String] = []
        for wal in captures where wal !== active {
            let id = wal.captureId
            guard !isDiscarded(id) else { continue }   // discarded fragments are never re-queued
            guard !isDeleted(id) else { continue }     // user-deleted captures never re-queued
            // Prune STUCK-EMPTY recordings: a capture that opened but received 0 segments
            // (Omi dropped immediately / connection never delivered a frame) is finalized by
            // neither the branch below (which requires totalSegments > 0) nor anything else,
            // so it lingers forever as a "Recording · 0/0 segments · 0.0 KB" card. If it's
            // non-active, still has no segments, and has been open past the stuck threshold,
            // discard it (durable `.discarded` marker — nothing real is lost, it's empty).
            if wal.status.totalSegments == 0 {
                // Discard a stale zero-segment capture that is GENUINELY empty (an
                // Omi-drop card that never received audio). "Empty" means: no cached
                // transcript, not confirmed in Lore, AND no durable card tombstone.
                //
                // DATA-LOSS FIX (2026-07-13): a REAL conversation whose audio (30d)
                // and transcript text (14d) were pruned by RETENTION still holds its
                // card tombstone (title + summary) and reads as 0-segment. The old
                // condition (only isConfirmedInLore + hasCachedTranscript) discarded
                // those — then pruneDiscardedFragments deleted the whole folder 2 days
                // later, silently destroying every phone-only conversation past the
                // retention window (nothing is "confirmed in Lore" without a computer).
                // A card tombstone IS real content: never discard it — it stays
                // browsable as title + summary, it just can't replay/show full text.
                // MEMO DELIBERATELY BYPASSED (track `residual_on_main_actor_work`): this
                // condition is DESTRUCTIVE — writing the `.discarded` marker below makes
                // `pruneDiscardedFragments` delete the capture's whole folder two days
                // later — so it must read the REAL filesystem, never a derived memo. The
                // manager's `hasCachedTranscript(_:)` is memo-served for the RENDER path
                // (that is where the per-row disk win is); a stale `false` there is a
                // one-frame cosmetic miss, but here it would re-open the 2026-07-13
                // silent-data-loss hole documented above. `reconcileOrphanedCaptures` runs
                // ONCE PER LAUNCH, off the render path, so the real `fileExists` costs
                // nothing measurable and buys correctness.
                let started = startTime(of: wal)
                if !wal.status.streaming,
                   Date().timeIntervalSince1970 - started > Self.stuckEmptyRecordingSecs,
                   !TranscriptCacheStore.isConfirmedInLore(captureId: id, baseDir: baseDir),
                   !TranscriptCacheStore.hasCachedTranscript(captureId: id, baseDir: baseDir),
                   !ConversationCardStore.exists(captureId: id, baseDir: baseDir) {
                    let dir = baseDir.appendingPathComponent(id, isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? Data("stuck empty recording — 0 segments, never received audio".utf8)
                        .write(to: discardMarker(id), options: [.atomic])
                    clearNeedsFinalize(id)
                    retryStates[id] = nil
                    // The marker we JUST wrote is applied to the memo in this same tick
                    // (a discard must hide the row immediately), then confirmed off-main.
                    applySidecarMarker(id, discarded: true)
                    touched.append(id)      // `.discarded` now present — confirmed in the batch
                    discardedAny = true
                    log?.info("capture \(id): pruned stuck-empty capture (0 segments, aged out)")
                }
                continue
            }
            guard let meta = ConversationMetaStore.load(captureId: id, baseDir: baseDir),
                  meta.startedAt > 0, meta.endedAt == nil else { continue }
            guard !isPendingFinalize(id),
                  !TranscriptCacheStore.isConfirmedInLore(captureId: id, baseDir: baseDir) else { continue }
            // End at the newest segment's wall-clock time (real bounds), else now.
            let endSecs: UInt64
            if let age = newestSegmentAge(id) {
                endSecs = UInt64(max(TimeInterval(meta.startedAt), Date().timeIntervalSince1970 - age))
            } else {
                endSecs = nowUnixSecs()
            }
            ConversationMetaStore.recordEnd(captureId: id, baseDir: baseDir, at: endSecs, location: nil)
            touched.append(id)      // meta.json changed — re-read in the batch, not per capture
            markNeedsFinalize(id)
            log?.info("capture \(id): orphan reconciled on launch — bounded (ended_at set) + pending finalize")
        }
        invalidateSidecars(touched)
        if discardedAny {
            captures.removeAll { isDiscarded($0.captureId) }   // didSet republishes the list
        }
    }

    /// Change the silence-gap threshold (settings UI); applies live + persists.
    public func setSilenceGap(_ seconds: TimeInterval) {
        silenceGapSeconds = seconds
        CaptureSettings.silenceGapSeconds = seconds
        router.setSilenceGap(seconds)
    }

    /// Install one immutable account-bound preference snapshot without persisting
    /// anything back to the legacy compatibility store. This seam is deliberately
    /// dormant until the account-root owner explicitly calls it.
    @discardableResult
    public func installCapturePreferenceSnapshot(
        _ snapshot: CaptureAccountPreferenceSnapshot
    ) -> Bool {
        guard !capturePreferenceSnapshotInstalled,
              let accountBinding,
              snapshot.binding == accountBinding,
              snapshot.binding.isCurrent else {
            return false
        }
        capturePreferenceSnapshotInstalled = true
        applyCapturePreferenceSnapshot(snapshot)
        return true
    }

    /// Explicit compatibility refresh for the already-bound manager. Identity
    /// notifications do not invoke this in Task 3.
    @discardableResult
    public func refreshCapturePreferences(
        compatibility: AccountPreferenceCompatibilityStore,
        binding: CaptureAccountScope.AccountBinding
    ) -> Bool {
        guard let accountBinding,
              binding == accountBinding,
              binding.isCurrent else {
            return false
        }
        applyCapturePreferenceSnapshot(
            CaptureSettings.snapshot(
                compatibility: compatibility,
                binding: binding))
        return true
    }

    private func applyCapturePreferenceSnapshot(
        _ snapshot: CaptureAccountPreferenceSnapshot
    ) {
        silenceGapSeconds = snapshot.silenceGapSeconds
        router.setSilenceGap(snapshot.silenceGapSeconds)
        isPaused = snapshot.omiDesiredState == .paused
        router.setPaused(isPaused)
    }

    // MARK: live audio meter (req 8)

    /// Start sampling the level buffer into the bars (call from the capture screen's
    /// onAppear). Idempotent.
    public func startMeter() {
        guard meterTimer == nil else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }   // 12Hz — stop hard after teardown
            Task { @MainActor in self?.tickMeter() }
        }
    }

    /// Stop sampling + flatten the bars (call from onDisappear).
    public func stopMeter() {
        meterTimer?.invalidate(); meterTimer = nil
        meter.levels = Array(repeating: 0, count: Self.meterBarCount)
        meter.isFlat = true
    }

    /// The capture surface (CaptureScreen) DISAPPEARED — stop the meter ONLY when no
    /// session is live. Presenting the full-screen RecordingScreen as a `fullScreenCover`
    /// fires the PRESENTING CaptureScreen's `onDisappear`; an unconditional `stopMeter()`
    /// there flattens the levels the instant recording begins, so the hero voice ring on
    /// the recording surface, the pill's mini ring off the capture tab, and the Live
    /// Activity's level (all driven by `tickMeter`) go permanently dead — every phone-mic
    /// recording then reads as "nothing's happening" (track 20260717T0630, Bug 2). A live
    /// capture must keep metering regardless of which screen is visible; the meter only
    /// stops once genuinely idle. (`startMeter`/`stopMeter` are both idempotent.)
    public func captureSurfaceDidDisappear() {
        stopMeterIfIdle()
    }

    /// Stop the 12 Hz meter timer ONLY when no session is live. Called from the capture
    /// surface's disappear AND from the two session-ends-to-idle boundaries (phone-mic
    /// `.stopped`/`.failed`, reconnect-grace expiry) — a session that ends while the user
    /// is on another tab (minimized / wandered off) otherwise leaves the timer firing
    /// every 83 ms forever with nothing to stop it (adversarial review M1, track
    /// 20260717T0630). NOT called inside `endSession()` itself: the silence-gap roll
    /// (`endSession(); beginSession()`) would stop→start flap the meter on every roll.
    private func stopMeterIfIdle() {
        guard active == nil && !isRecordingMic else { return }
        stopMeter()
    }

    /// Test seam (internal, reachable via `@testable import`): whether the 12 Hz meter
    /// timer is currently running — lets the meter-lifecycle tests assert the session-aware
    /// start/stop decisions without reaching into the private timer.
    var meterIsRunningForTests: Bool { meterTimer != nil }

    /// Test seam: ambient LISTENING — the Omi is armed and metering, waiting for a
    /// speech onset, with NO conversation open. Distinguishes speech-gated listening
    /// from a live recording (`active != nil`) and from idle.
    var isListeningForSpeechForTests: Bool { active == nil && router.isArmedForTests() }

    #if canImport(AVFoundation)
    /// Test seam: deliver a buffer at the downstream edge of the live PCM tap. The
    /// decoded-Opus test separately proves FrameRouter reaches this holder; foreground
    /// tests use this seam to prove the holder now targets the replacement transcriber.
    func appendLivePCMForTests(_ pcm: AVAudioPCMBuffer) { liveBox.append(pcm) }
    #endif

    /// Test seam: drive ONE 12 Hz meter tick through the EXACT path the timer uses, with no
    /// timer running — so a test can prove that N ticks during a recording do ZERO main-actor
    /// disk reads and drive at most the throttled number of widget pushes. Internal
    /// (`@testable` only), mirroring `publishLiveSnapshotForTests`.
    func tickMeterForTests() { tickMeter() }

    private func tickMeter() {
        let peak = isPaused ? 0 : levelBuffer.drainPeak()
        // Idle skip: nothing audible and the ring is already flat → publish NOTHING
        // (zero invalidations while the room is quiet / capture is idle).
        if peak > 0 || !meter.isFlat {
            var ring = meter.levels
            if !ring.isEmpty { ring.removeFirst() }
            ring.append(peak)
            meter.levels = ring
            meter.isFlat = ring.allSatisfy { $0 == 0 }
        }
        // Surface the frame diagnostics on the same 12 Hz tick (no per-frame main hop).
        let s = router.stats()
        if s.count != meter.framesReceived { meter.framesReceived = s.count }
        if s.lastBytes != meter.lastFrameBytes { meter.lastFrameBytes = s.lastBytes }
        // Move the Live Activity's live level indicator — THROTTLED to a few seconds, NOT
        // the 12 Hz meter rate (the elapsed timer ticks on-device, so this only carries
        // the level). No-op when not recording / the throttle window hasn't elapsed.
        if isCapturing { pushLiveState(.throttledUpdate) }
    }

    // MARK: Live Activity / widget snapshot projection + push

    /// The display title + finish time of the most recent FINISHED conversation (the
    /// active one excluded) — shown by the Live Activity / widget when idle. Reuses the
    /// same card tombstone + generic-title disambiguation the timeline list renders, so
    /// the surfaces agree. nil when there is no finished conversation with a title yet.
    private func lastFinishedConversation() -> (title: String, at: Date)? {
        if lastFinishedMemoValid { return lastFinishedMemo }
        let computed = computeLastFinishedConversation()
        lastFinishedMemo = computed
        lastFinishedMemoValid = true
        return computed
    }

    /// The memoised answer + its validity flag. Invalidated wherever its INPUTS change: a
    /// list rebuild (membership/order/active), and an off-main sidecar warm (a card's title
    /// or a meta's endedAt landing). Without the memo this whole scan ran on every
    /// `makeWidgetSnapshot` — i.e. 12×/second while recording, before the throttle.
    private var lastFinishedMemo: (title: String, at: Date)?
    private var lastFinishedMemoValid = false
    private func invalidateLastFinishedMemo() {
        lastFinishedMemoValid = false
        lastFinishedMemo = nil
    }

    private func computeLastFinishedConversation() -> (title: String, at: Date)? {
        for wal in visibleCaptures where wal !== active {
            guard let title = cardMeta(for: wal.captureId)?.title,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let start = conversationStartDate(wal)
            let display = ConversationTitleDisplay.display(
                title: title, start: start,
                timeString: { Self.liveActivityTimeFmt.string(from: $0) })
            // Prefer the conversation END for "finished at" when known, else its start.
            let endedAt = conversationMeta(for: wal.captureId)?.endedAt
            let at = endedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? start
            return (display, at)
        }
        return nil
    }

    private static let liveActivityTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// The current 0…1 level for the live indicator (the newest meter bar), or nil when
    /// not actively recording.
    private var currentLiveLevel: Double? {
        guard isCapturing else { return nil }
        return Double(meter.levels.last ?? 0)
    }

    // MARK: Live Activity phase (RECORDING-ACTIVE vs PAUSED vs IDLE) — the bug fix

    /// The DISTINCT capture phase for the live surfaces, derived from REAL voiced-capture
    /// activity (recent voice), NOT merely from a session being armed. This is what stops
    /// the Live Activity claiming a live 30-min conversation while paused / during an
    /// extended silence. `lastVoicedAt` (router) and `now` are BOTH reference-date seconds
    /// so the recent-voice window compares on one clock.
    private var livePhase: CaptureActivityPhase {
        CaptureLiveStatus.phase(
            hasActiveSession: active != nil,
            isPaused: isPaused,
            lastVoicedAt: router.lastVoicedInstant(),
            now: Date().timeIntervalSinceReferenceDate)
    }

    /// Test/inspection seam: the CURRENT Live Activity phase (RECORDING-ACTIVE / PAUSED /
    /// IDLE) as the live surfaces would render it. Lets a door-free test prove the
    /// "in a conversation while paused/idle" fix through the real manager, on any platform.
    /// `now` is injectable (reference-date seconds) so a test can advance past the
    /// active-voice window deterministically without sleeping.
    public func liveActivityPhase(now: TimeInterval = Date().timeIntervalSinceReferenceDate)
        -> CaptureActivityPhase {
        CaptureLiveStatus.phase(
            hasActiveSession: active != nil,
            isPaused: isPaused,
            lastVoicedAt: router.lastVoicedInstant(),
            now: now)
    }

    /// Test/inspection seam: the most-recent voiced instant (reference-date seconds), or
    /// nil if no voice yet this session — lets a test drive the active-voice window.
    public func lastVoicedInstant() -> TimeInterval? { router.lastVoicedInstant() }

    /// The elapsed-timer anchor for the live surfaces: the instant the CURRENT active-voice
    /// run began, ONLY while `.recordingActive`. nil when paused / listening so the timer
    /// never runs during silence or while armed-but-idle. Anchored to the conversation
    /// start (stable across brief dips within the active-voice window), which reads as the
    /// natural "how long this conversation has been going" without a per-second push.
    private func liveStartedAt(phase: CaptureActivityPhase) -> Date? {
        guard phase == .recordingActive, let wal = active else { return nil }
        return conversationStartDate(wal)
    }

    /// Coarse 0…3 stepped level for the live indicator (a few discrete bars), or nil when
    /// not actively recording. Snapshot-friendly + battery-cheap — updated ~1×/sec, never
    /// at frame rate. Maps the 0…1 peak onto 4 steps (0 = silence … 3 = loud).
    private func liveLevelStep(phase: CaptureActivityPhase) -> Int? {
        guard phase == .recordingActive, let lvl = currentLiveLevel else { return nil }
        return CaptureLiveStatus.levelStep(fromLevel: lvl)
    }

    /// The latest live transcript line, TRUNCATED for the small surfaces — only while
    /// actively recording (empty otherwise). Prefers the volatile tail (what's being said
    /// now); falls back to the finalized body.
    private func liveTranscriptLine(phase: CaptureActivityPhase, maxChars: Int) -> String {
        guard phase == .recordingActive else { return "" }
        let text = liveTranscript.displayText
        guard !text.isEmpty else { return "" }
        return CaptureLiveStatus.truncatedTranscript(text, maxChars: maxChars)
    }

    /// Build the App-Group snapshot the home-screen widget reads from current state. Uses
    /// the SAME real-activity-derived phase as the Live Activity so the home widget never
    /// claims a live conversation during silence / while paused.
    private func makeWidgetSnapshot() -> CaptureWidgetSnapshot {
        let last = lastFinishedConversation()
        let phase = livePhase
        return CaptureWidgetSnapshot(
            phase: phase,
            sourceLabel: CaptureLiveStatus.sourceLabel(source: captureSource, isRecordingMic: isRecordingMic),
            sourceSymbol: CaptureLiveStatus.sourceSymbol(source: captureSource, isRecordingMic: isRecordingMic),
            startedAt: liveStartedAt(phase: phase),
            lastFinishedTitle: last?.title,
            lastFinishedAt: last?.at,
            updatedAt: Date())
    }

    #if canImport(ActivityKit) && os(iOS)
    /// Build the Live Activity content state from current capture state.
    @available(iOS 16.2, *)
    private func makeActivityState() -> CaptureActivityAttributes.ContentState {
        let last = lastFinishedConversation()
        let phase = livePhase
        return CaptureActivityAttributes.ContentState(
            phase: phase,
            sourceLabel: CaptureLiveStatus.sourceLabel(source: captureSource, isRecordingMic: isRecordingMic),
            sourceSymbol: CaptureLiveStatus.sourceSymbol(source: captureSource, isRecordingMic: isRecordingMic),
            startedAt: liveStartedAt(phase: phase),
            levelStep: liveLevelStep(phase: phase),
            transcriptLine: liveTranscriptLine(phase: phase,
                                               maxChars: CaptureLiveStatus.transcriptCharsLockScreen),
            lastFinishedTitle: last?.title,
            lastFinishedAt: last?.at)
    }
    #endif

    /// Push the current state to the home-screen widget (always) and the Live Activity
    /// (when one should be live). `kind` distinguishes the lifecycle transition so we
    /// start/update/end the Live Activity correctly; level/elapsed pushes are throttled.
    private enum LivePush { case start, update, throttledUpdate, end }
    private func pushLiveState(_ kind: LivePush) {
        // THROTTLED, and this guard is FIRST (track `residual_on_main_actor_work`, addendum).
        // It used to sit BELOW the widget push, so the 12 Hz meter tick drove a main-actor
        // App-Group FILE WRITE plus a `WidgetCenter.reloadAllTimelines()` twelve times a
        // second for the entire duration of every recording. The widget is a best-effort
        // glance that iOS throttles to a background budget anyway (see
        // `reloadWidgetTimelines`), so pushing it faster than the Live Activity's cadence
        // bought nothing and cost the main thread. Lifecycle transitions
        // (start/update/end) are never throttled.
        //
        // The widget keeps its OWN timestamp: the Live Activity's `lastLiveActivityPushAt`
        // is deliberately NOT advanced when a throttled push coalesces away as equivalent,
        // so sharing it would let the widget push on every tick again.
        // Only the WIDGET leg is throttled here — the Live Activity below keeps its own
        // (unchanged) throttle + content-coalescing rules, so its latency is untouched.
        let nowSeconds = Date().timeIntervalSince1970
        if let accountBinding,
           kind != .throttledUpdate
                || nowSeconds - lastWidgetPushAt >= Self.liveActivityThrottle {
            let snapshot = makeWidgetSnapshot()
            if CaptureWidgetSnapshotStore.write(snapshot, as: accountBinding) {
                lastWidgetPushAt = nowSeconds
                Self.noteWidgetPush()
                reloadWidgetTimelines()
            }
        }

        #if canImport(ActivityKit) && os(iOS)
        guard #available(iOS 16.2, *),
              let accountBinding,
              let controller = liveActivityController else { return }
        let state = makeActivityState()
        CaptureAccountScope.perform(as: accountBinding) { binding in
            switch kind {
            case .start:
                lastLiveActivityPushAt = Date().timeIntervalSince1970
                lastPushedState = state
                controller.start(state, as: binding)
            case .update:
                // A lifecycle transition (pause/resume/source-switch) — push unconditionally,
                // but still record it so the next throttled tick can coalesce against it.
                lastLiveActivityPushAt = Date().timeIntervalSince1970
                lastPushedState = state
                controller.update(state, as: binding)
            case .throttledUpdate:
                let now = Date().timeIntervalSince1970
                guard now - lastLiveActivityPushAt >= Self.liveActivityThrottle else { return }
                // Coalesce: if the meaningful content is unchanged since the last push, skip —
                // the elapsed timer ticks ON-DEVICE, so an identical phase/level/transcript
                // never needs a re-push.
                if let last = lastPushedState, Self.liveStateEquivalent(last, state) { return }
                lastLiveActivityPushAt = now
                lastPushedState = state
                controller.update(state, as: binding)
            case .end:
                lastPushedState = nil
                controller.end(final: state, as: binding)
            }
        }
        #endif
    }

    #if canImport(ActivityKit) && os(iOS)
    /// Whether two ContentStates are equivalent for THROTTLE-COALESCING purposes — i.e.
    /// nothing the user perceives differs. Compares phase, coarse level, transcript, and
    /// source/last-finished labels but IGNORES `startedAt` (the on-device timer anchor,
    /// which advances every second without needing a push). A pure static so it's testable.
    @available(iOS 16.2, *)
    static func liveStateEquivalent(_ a: CaptureActivityAttributes.ContentState,
                                    _ b: CaptureActivityAttributes.ContentState) -> Bool {
        a.phase == b.phase
            && a.levelStep == b.levelStep
            && a.transcriptLine == b.transcriptLine
            && a.sourceLabel == b.sourceLabel
            && a.sourceSymbol == b.sourceSymbol
            && a.lastFinishedTitle == b.lastFinishedTitle
    }
    #endif

    /// Ask WidgetKit to reload the home-screen widget timelines (no-op off iOS).
    ///
    /// NOTE: this is only a FRESHNESS HINT. The home-screen widget is snapshot-rendered and
    /// iOS THROTTLES timeline reloads (a background budget) — even with this call the tile
    /// can lag a live capture by minutes and is NOT real-time. Real-time status is the Live
    /// Activity's job (Dynamic Island / lock screen); the home widget is a best-effort
    /// "current status + last conversation" glance. Do NOT try to force it fresher than the
    /// reload hint — that just burns the budget and iOS ignores it anyway.
    private func reloadWidgetTimelines() {
        #if canImport(WidgetKit) && os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Re-write the App-Group snapshot the home widget reads AND hint a reload — call this
    /// whenever the widget's inputs (capture status / last-finished title) change OUTSIDE a
    /// `pushLiveState` transition, e.g. the async transcript-refine or a completed finalize.
    private func refreshHomeWidget() {
        // Same accounting as `pushLiveState`'s widget leg: it IS a widget push (so the
        // counter sees it and the throttle window restarts), and it is NOT throttled — it
        // only fires on real, occasional input changes, never on the meter tick.
        guard let accountBinding else { return }
        let snapshot = makeWidgetSnapshot()
        if CaptureWidgetSnapshotStore.write(snapshot, as: accountBinding) {
            lastWidgetPushAt = Date().timeIntervalSince1970
            Self.noteWidgetPush()
            reloadWidgetTimelines()
        }
    }

    /// Build a WAL, threading the (test-only) per-segment upload override so every
    /// capture this manager owns uploads through the same (real or injected) path.
    private nonisolated func makeWAL(captureId id: String) -> CaptureWAL {
        let upload: (@Sendable (UInt64, Data) async throws -> Void)?
        if let uploadSegment { upload = { seq, body in try await uploadSegment(id, seq, body) } }
        else { upload = nil }
        return CaptureWAL(
            captureId: id,
            target: target,
            baseDir: baseDir,
            binding: accountBinding,
            log: log,
            upload: upload)
    }

    private func hasLocalAudio(_ captureId: String) -> Bool {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.contains { $0.pathExtension == "opus" }
    }

    /// A conversation can be resumed only when its original local audio is still present,
    /// it has not been deleted/discarded, and no other source is currently recording.
    /// This is intentionally local-first: the WAL on this phone is the append target.
    public func canResumeRecording(captureId: String) -> Bool {
        guard active == nil, suspendedSession == nil else { return false }
        guard !isDeleted(captureId), !isDiscarded(captureId), !isAbandoned(captureId) else { return false }
        // A capture that is (or was, before a crash) a merge PRIMARY mid-fold carries a
        // pinned `.folding-<source>` marker reserving a [base, base+count) seq range on
        // disk. Resuming it would allocate new segments from the same `max + 1` and write
        // INTO that reserved range — a later re-merge would then either skip the copy
        // (range already "present" → source audio lost) or overwrite the resume segments
        // (resume audio lost). Block resume until the merge finishes and clears the marker.
        guard !hasPendingFoldMarker(captureId) else { return false }
        return hasLocalAudio(captureId)
    }

    /// True when the capture directory holds a pinned `.folding-<source>` marker — a merge
    /// fold into this primary is in progress or was interrupted mid-flight. Such a capture
    /// must not be resumed (a resume would collide with the reserved fold seq range). The
    /// marker is dropped once the merge deletes the source, so this is self-clearing.
    private func hasPendingFoldMarker(_ captureId: String) -> Bool {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.contains { $0.lastPathComponent.hasPrefix(".folding-") }
    }

    /// Re-open an existing capture as the active conversation, appending new frames to
    /// the same WAL/capture id. Ending it later follows the normal finalize path, which
    /// re-ingests the fuller audio under the same external id.
    @discardableResult
    public func resumeRecording(captureId: String) -> Bool {
        guard canResumeRecording(captureId: captureId) else { return false }
        // Resuming is an explicit user action → a FRESH session anchor (recording resumed
        // now), respecting the current pause intent. Does not flow through beginSession.
        recordingClock = RecordingClock(startedAt: Date(), paused: isPaused, now: Date())
        let wal = captures.first(where: { $0.captureId == captureId }) ?? makeWAL(captureId: captureId)
        active = wal
        captures.removeAll { $0.captureId == captureId }
        captures.insert(wal, at: 0)
        clearNeedsFinalize(captureId)
        retryStates[captureId] = nil
        finalizing.remove(captureId)
        if captureSource == .phoneMic, micSource != nil { isRecordingMic = true }
        ConversationMetaStore.recordOpen(captureId: captureId, baseDir: baseDir, at: nowUnixSecs())
        invalidateMeta(captureId)
        ConversationCardStore.recordStart(captureId: captureId, baseDir: baseDir, startedAt: nowUnixSecs())
        invalidateSidecar(captureId)   // card.json may have just been created (cardExists)
        CaptureEventLog.append(.captureStarted, captureId: captureId,
                               payload: ["source": captureSource.rawValue, "resume": "true"],
                               baseDir: baseDir)
        wal.beginStreaming()
        router.resetLevelMeter()
        #if canImport(AVFoundation)
        router.resetPCMDecoder()
        #endif
        router.resetSegmenter()
        router.setExternalPCM(isRecordingMic)
        router.setPaused(isPaused)
        router.setWAL(wal)
        // Resume-same-id (explicit user re-open): CONTINUE the external backoff spacing
        // rather than re-tightening to 60s — the conversation is the same one.
        startLiveTranscription(freshConversation: false)
        lastHeartbeatAt = 0; lastHeartbeatFrames = router.stats().count
        pushLiveState(.start)
        startMeter()            // a live capture is ALWAYS metered, regardless of which screen is visible (Bug 2)
        rebuildVisibleCaptures()
        if isRecordingMic { micSource?.start() }
        else { source.start() }
        log?.info("capture \(captureId): resumed existing conversation (source=\(captureSource.rawValue))")
        return true
    }

    // MARK: merge conversations (fold split captures into ONE — phone-orchestrated WAL concat)

    /// A capture that can take part in a merge RIGHT NOW: it still holds its local audio on
    /// this phone (the phone owns the audio — a pruned capture can't contribute), and it is
    /// not the live/suspended recording, nor deleted / discarded / abandoned. The same
    /// local-first rule `resumeRecording` uses, so merge only ever concatenates real audio.
    /// A capture is too old to merge once the DOOR may have retention-pruned its raw audio
    /// (door default `FOUNDRYX_RETAIN_SECS_DEFAULT` = 7 days). Merging a pruned capture is
    /// lossy: the phone re-uploads only the newly-folded segments, so the door's replace
    /// re-ingests only the new audio and destroys the fuller transcript already in Lore.
    /// Bounded conservatively BELOW 7 days so the door still holds the full audio and the
    /// fold re-ingests losslessly. (Captures with no durable start are allowed — age
    /// unknown; the door's own "refuse replace when an ingested segment is missing" guard is
    /// the correctness backstop.)
    static let mergeMaxAgeSeconds: TimeInterval = 6 * 24 * 60 * 60

    private func isMergeable(_ captureId: String) -> Bool {
        guard active?.captureId != captureId else { return false }
        guard suspendedSession?.wal.captureId != captureId else { return false }
        guard !isDeleted(captureId), !isDiscarded(captureId), !isAbandoned(captureId) else { return false }
        if let start = durableStart(captureId: captureId),
           Date().timeIntervalSince1970 - start > Self.mergeMaxAgeSeconds {
            return false   // door may have pruned this capture's audio → merging it would be lossy
        }
        return hasLocalAudio(captureId)
    }

    /// The durable conversation start (unix seconds) used to ORDER a merge: meta → card →
    /// the capture-id's embedded time (the same resolution `durableStart` uses). The
    /// EARLIEST becomes the primary and the rest append after it, so the merged transcript
    /// reads in time order. Falls back to 0 (sorts earliest) only for a capture with no
    /// durable start at all — its audio still merges.
    private func mergeStart(of captureId: String) -> TimeInterval {
        durableStart(captureId: captureId) ?? 0
    }

    /// Merge several split captures into ONE conversation. The EARLIEST capture (by durable
    /// start) is the PRIMARY; every other source's `seg-*.opus` audio is appended — in time
    /// order — onto the primary's WAL (renumbered to CONTINUE its sequence), the primary is
    /// marked pending-finalize and its grown WAL re-uploaded, so the door's ingest SWEEP
    /// (segment-count-growth → replace path) re-ingests the fuller audio under the primary's
    /// external id — re-transcribing into ONE conversation (the finalize POST itself is a
    /// no-op for an already-InLore capture; the sweep does the work). Each source is deleted
    /// (phone + door + Lore) so only the primary remains. Returns the primary id to navigate
    /// to, or nil when there's nothing to merge (fewer than two valid, mergeable captures).
    ///
    /// Crash-safe + idempotent. A source's segments are COPIED (never moved) and each write
    /// is atomic (temp + rename), so a concurrent drain never sees a torn segment and an
    /// interruption never loses audio. A source is deleted ONLY after its whole audio is
    /// verified on the primary, and copies happen one source at a time, so an interruption
    /// leaves at most the in-flight source un-deleted — a re-run re-folds it to the SAME
    /// pinned range (`.folding-<source>` marker) so it is never duplicated, and completing
    /// twice is a no-op (folded sources carry `.deleted`).
    ///
    /// @MainActor-safe: the heavy WAL file work runs OFF the main actor (mirrors the
    /// retention sweep / hydration hops); `captures` is mutated + rebuilt back on main.
    @discardableResult
    public func merge(captureIds: [String]) async -> String? {
        guard !accountExposureClosing, !accountExposureClosed else { return nil }
        mergeOperationsInFlight += 1
        defer {
            mergeOperationsInFlight -= 1
            if mergeOperationsInFlight == 0 {
                let waiters = mergeOperationWaiters
                mergeOperationWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        // Resolve to distinct, mergeable captures (real local audio; not active/deleted/…).
        var seen = Set<String>()
        let candidates = captureIds.filter { seen.insert($0).inserted && isMergeable($0) }
        guard candidates.count >= 2 else { return nil }   // nothing to merge — safe no-op

        // PRIMARY = the earliest by durable start; the rest are sources in ascending time
        // order, so appending them after the primary keeps the audio globally time-ordered.
        let ordered = candidates.sorted { mergeStart(of: $0) < mergeStart(of: $1) }
        let primaryId = ordered[0]
        let sourceIds = Array(ordered.dropFirst())
        let base = baseDir

        var mergedAny = false
        for sourceId in sourceIds {
            // Copy THIS source's segments onto the primary (OFF the main actor), continuing
            // the primary's seq. Returns true only once every segment is verified present.
            let ok = await Task.detached(priority: .userInitiated) {
                Self.appendSourceToPrimary(primaryId: primaryId, sourceId: sourceId, baseDir: base)
            }.value
            guard !accountExposureClosing,
                  !accountExposureClosed,
                  !Task.isCancelled else { return nil }
            guard ok else { break }   // copy failed — stop; sources already folded stay folded
            // The source's audio is now safely on the primary → delete the source (phone +
            // door + Lore). Done BEFORE the next source so an interruption never re-copies a
            // source that's already folded in.
            deleteConversation(sourceId)
            // Fold complete + source deleted → drop the idempotency marker. Harmless if it
            // lingers (a deleted source is never re-folded), but keep the primary dir clean.
            try? FileManager.default.removeItem(
                at: base.appendingPathComponent(primaryId, isDirectory: true)
                    .appendingPathComponent(".folding-\(sourceId)"))
            mergedAny = true
        }
        guard mergedAny else { return nil }

        // Rebuild the primary WAL so its in-memory seq/watermark reflect the appended
        // segments (a stale nextSeq would let a later resume OVERWRITE merged audio), then
        // mark it pending-finalize + drive the re-ingest. The rebuilt WAL re-scans disk:
        // nextSeq = merged max + 1, watermark derived from the surviving `.ack` markers, so
        // the newly appended (un-ACK'd) segments read as PENDING and get uploaded.
        if let idx = captures.firstIndex(where: { $0.captureId == primaryId }) {
            let rebuilt = makeWAL(captureId: primaryId)
            // Warm the fresh WAL's status NOW (on the main actor `publish()` applies
            // synchronously) so the segment scan is lazy but the merged primary is
            // immediately browsable — its real 0/N counts are in `status` before the
            // rebuild below reads them, instead of the empty just-constructed default.
            rebuilt.warmStatus()
            captures[idx] = rebuilt
        }
        retryStates[primaryId] = nil
        finalizing.remove(primaryId)
        markNeedsFinalize(primaryId)
        invalidateMeta(primaryId)
        rebuildVisibleCaptures()

        // Kick the sync→finalize now (drain timer + app-foreground retry finish it if the
        // door is down — the pending-finalize marker is durable, mirroring endSession).
        if let primaryWal = captures.first(where: { $0.captureId == primaryId }) {
            let taskID = UUID()
            let task = Task { @MainActor [weak self] in
                defer { self?.mergeFinalizeTasks[taskID] = nil }
                await primaryWal.sync()
                guard !Task.isCancelled,
                      self?.accountExposureClosing != true,
                      self?.accountExposureClosed != true else { return }
                await self?.tryFinalize(primaryWal)
            }
            mergeFinalizeTasks[taskID] = task
        }
        log?.info("merge: folded \(sourceIds.count) source(s) into primary \(primaryId)")
        return primaryId
    }

    /// Append ONE source capture's `seg-*.opus` onto the PRIMARY's WAL directory, renumbered
    /// to CONTINUE the primary's sequence (so the audio stays time-ordered). Pure disk —
    /// safe to run OFF the main actor (touches no actor state). Each segment is COPIED via an
    /// ATOMIC write (temp + rename) so a concurrent drain never reads a torn file; on any
    /// failure the source's partial copies are rolled back and it returns false (the caller
    /// then leaves the source un-deleted — its audio is never lost). Returns true only when
    /// every source segment is verified present on the primary. The fold is IDEMPOTENT: the
    /// destination range is pinned in a durable `.folding-<source>` marker, so a crash and
    /// retry re-copies the SAME seqs (overwrite) instead of appending a DUPLICATE span. The
    /// `.ack` / watermark markers are intentionally NOT copied, so the appended segments read
    /// as PENDING and the door re-uploads + re-ingests them under the primary's id.
    nonisolated static func appendSourceToPrimary(primaryId: String,
                                                  sourceId: String,
                                                  baseDir: URL) -> Bool {
        let fm = FileManager.default
        let primaryDir = baseDir.appendingPathComponent(primaryId, isDirectory: true)
        let sourceDir = baseDir.appendingPathComponent(sourceId, isDirectory: true)
        // Idempotent fold. The destination range [base, base+count) for THIS source is
        // allocated ONCE and pinned in a durable marker ("base:count") BEFORE any copy. A
        // re-run after a crash in the copy-done / source-not-yet-deleted window reuses the
        // SAME range and OVERWRITES it — so re-folding is a no-op, never a duplicated
        // (double-transcribed) span. If the marker shows the whole range is already on the
        // primary (the source was copied + verified, even if it has since been deleted),
        // the fold is already complete → true. Each source pins its own base, so later
        // sources still get non-overlapping ranges.
        let marker = primaryDir.appendingPathComponent(".folding-\(sourceId)")
        let savedFields = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
        let savedBase = savedFields?.first.flatMap { UInt64($0) }
        func rangeAllPresent(_ base: UInt64, _ count: Int) -> Bool {
            count > 0 && (0 ..< UInt64(count)).allSatisfy {
                fm.fileExists(atPath: primaryDir.appendingPathComponent(CaptureWAL.segName(base + $0)).path)
            }
        }
        if let base = savedBase,
           let count = savedFields.flatMap({ $0.count == 2 ? Int($0[1]) : nil }),
           rangeAllPresent(base, count) {
            return true   // already fully folded — idempotent re-run (even if the source is gone)
        }

        let seqs = segmentSeqsOnDisk(sourceId, baseDir: baseDir).sorted()
        guard !seqs.isEmpty else { return false }   // no source audio to contribute

        // Reuse the pinned base if present, else allocate at primary-max+1 and pin it BEFORE
        // any copy so a crash mid-copy re-folds to the SAME seqs (no drift, no duplication).
        let base: UInt64
        if let saved = savedBase {
            base = saved
        } else {
            base = (segmentSeqsOnDisk(primaryId, baseDir: baseDir).max().map { $0 + 1 }) ?? 0
            try? "\(base):\(seqs.count)".write(to: marker, atomically: true, encoding: .utf8)
        }

        var written: [URL] = []
        var seq = base
        for srcSeq in seqs {
            let src = sourceDir.appendingPathComponent(CaptureWAL.segName(srcSeq))
            let dst = primaryDir.appendingPathComponent(CaptureWAL.segName(seq))
            do {
                let bytes = try Data(contentsOf: src)
                try bytes.write(to: dst, options: [.atomic])   // temp + atomic rename (overwrites on retry)
                written.append(dst)
                seq += 1
            } catch {
                for u in written { try? fm.removeItem(at: u) }   // roll back this run's partial copies
                return false                                     // marker stays → retry reuses same base
            }
        }
        // Every intended segment must be present on the primary before the caller deletes
        // the source — the "safely on the primary" gate that makes the fold loss-free.
        guard written.allSatisfy({ fm.fileExists(atPath: $0.path) }) else {
            for u in written { try? fm.removeItem(at: u) }
            return false
        }
        return true
    }

    /// The segment sequence numbers a capture holds on disk (parsed from `seg-<seq>.opus`).
    /// Nonisolated (pure disk) so the off-main merge copy can read it.
    nonisolated static func segmentSeqsOnDisk(_ captureId: String, baseDir: URL) -> [UInt64] {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> UInt64? in
            guard url.pathExtension == "opus" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent   // seg-000…000
            guard let seqStr = name.split(separator: "-").last, let seq = UInt64(seqStr) else { return nil }
            return seq
        }
    }

    private func beginSession() {
        // Stamp the session clock ONLY when there isn't one — so an internal silence-gap
        // roll (`endSession(); beginSession()`) PRESERVES the existing anchor and stays
        // invisible to the user. An explicit boundary (split/stop/grace-expiry) clears the
        // clock first, so the next fresh session re-anchors here (track 20260717T0630).
        // The SAME nil-clock signal distinguishes a genuinely new conversation (re-arm the
        // external title backoff) from an internal roll (keep the widened spacing).
        let freshConversation = (recordingClock == nil)
        if recordingClock == nil {
            recordingClock = RecordingClock(startedAt: Date(), paused: isPaused, now: Date())
        }
        let id = Self.newCaptureId()
        let wal = makeWAL(captureId: id)
        active = wal
        // A fresh conversation surface starts with NO ambient rows (belt-and-suspenders
        // with the captureId guard in noteRecordingCandidate) — a candidate from the
        // just-closed conversation must never bleed onto this one.
        live.candidates = []
        captures.insert(wal, at: 0)               // newest first (Omi-style timeline)
        // Durably stamp the conversation START (F1) — the card's start time + the
        // door's `capturedAt`. Idempotent (won't clobber an existing record). Also
        // stamp the durable `card.json` start so the conversation keeps this date even
        // if its meta sidecar is ever pruned (track 20260628T1609).
        let startSecs = nowUnixSecs()
        ConversationMetaStore.recordStart(captureId: id, baseDir: baseDir, at: startSecs)
        invalidateMeta(id)
        // Durable source tag (review P2): mark WHICH device owns this capture so a later
        // Omi reconnect only ever resumes an ambient/Omi capture — never a phone-mic
        // recording (they share the `omi-` id prefix). Atomic; best-effort.
        try? Data(captureSource.rawValue.utf8)
            .write(to: Self.sourceMarkerURL(id, baseDir: baseDir), options: [.atomic])
        // WHICH device, not just which kind. The FIRST of the two capture-creation sites
        // (the other is OmiRestorationSpool's background open); both write it, or a
        // conversation's attribution would depend on which one happened to open it.
        // A blocked context writes NOTHING — never a placeholder.
        if let deviceContext = captureDeviceContext(recordingSourceForAttribution).context,
           !CaptureDeviceSidecar.write(deviceContext, captureId: id, baseDir: baseDir) {
            log?.error("capture \(id): opened but its device record could not be written")
        }
        ConversationCardStore.recordStart(captureId: id, baseDir: baseDir, startedAt: startSecs)
        invalidateSidecar(id)   // card.json may have just been created (cardExists)
        // Append-only event log (track 20260705T1100, decision #3): the durable
        // history a future brain is seeded from by replay.
        CaptureEventLog.append(.captureStarted, captureId: id,
                               payload: ["source": captureSource.rawValue], baseDir: baseDir)
        wal.beginStreaming()
        router.resetLevelMeter()                  // fresh Opus decoder per conversation
        #if canImport(AVFoundation)
        router.resetPCMDecoder()                  // fresh live-STT decoder per conversation
        #endif
        // Phone-mic sessions feed PCM directly to the transcriber → skip the router's
        // Opus-decode tap (Feature 2). Omi ambient sessions keep the decode tap.
        router.setExternalPCM(isRecordingMic)
        router.setPaused(isPaused)
        router.setWAL(wal)                        // frames now flow into this WAL
        startLiveTranscription(freshConversation: freshConversation)   // additive live preview (no-op if unwired)
        lastHeartbeatAt = 0; lastHeartbeatFrames = router.stats().count   // fresh heartbeat baseline
        pushLiveState(.start)   // start the Live Activity + refresh the home-screen widget
        startMeter()            // a live capture is ALWAYS metered, regardless of which screen is visible (Bug 2)
        log?.info("capture \(id): ambient session started (source=\(captureSource.rawValue), state=\(sourceStateLabel))")
    }

    /// Re-open an existing on-disk capture as the active conversation on a reconnect or
    /// relaunch INSIDE the silence gap (the candidate chosen by `resumableCaptureId`).
    /// Ambient-only — the phone-mic path never routes here (its guard stays first +
    /// unchanged in `onSourceState`). Unlike the user-driven `resumeRecording`, the source
    /// is ALREADY streaming (we're inside its `.streaming` callback), so we never
    /// re-`start()` it. Continues the SAME capture id + segment sequence (CaptureWAL
    /// derives its next seq from the highest on-disk segment), clears any half-shipped
    /// finalize marker so a resumed session doesn't race it, and clears the stale early
    /// `endedAt` (recordOpen) so the resumed conversation reads as open again — the
    /// eventual real end re-stamps the true bound. Idempotent on `captures` (reuses the
    /// hydrated WAL row rather than inserting a duplicate).
    @discardableResult
    private func resumeSession(captureId: String) -> Bool {
        // Belt-and-suspenders with resumableCaptureId's selection: never resume something
        // terminal / mid-merge / deliberately-ended. A recent open Omi capture may still
        // be segmentless because its first frames have not filled one WAL chunk yet.
        guard !isDeleted(captureId), !isDiscarded(captureId), !isAbandoned(captureId),
              !Self.isEndedDeliberatelyOnDisk(captureId, baseDir: baseDir),
              !hasPendingFoldMarker(captureId),
              hasLocalAudio(captureId)
                || Self.isRecentSegmentlessOpenOmiCapture(
                    captureId,
                    baseDir: baseDir,
                    now: Date(),
                    silenceGap: silenceGapSeconds
                ) else { return false }
        // Stamp the session clock ONLY when there isn't one (mirrors beginSession) — a
        // relaunch has no clock, so anchor the visible timer here; the DURABLE start in
        // meta.json is preserved by recordOpen below (never re-stamped).
        if recordingClock == nil {
            recordingClock = RecordingClock(startedAt: Date(), paused: isPaused, now: Date())
        }
        let wal = captures.first(where: { $0.captureId == captureId }) ?? makeWAL(captureId: captureId)
        active = wal
        live.candidates = []
        captures.removeAll { $0.captureId == captureId }   // avoid a duplicate row
        captures.insert(wal, at: 0)                        // newest first
        // A half-shipped finalize must not race the resumed session; drop its intent and
        // reopen the durable meta (preserves start/location, clears the stale early end).
        clearNeedsFinalize(captureId)
        retryStates[captureId] = nil
        finalizing.remove(captureId)
        ConversationMetaStore.recordOpen(captureId: captureId, baseDir: baseDir, at: nowUnixSecs())
        invalidateMeta(captureId)
        invalidateSidecar(captureId)
        CaptureEventLog.append(.captureStarted, captureId: captureId,
                               payload: ["source": captureSource.rawValue, "resume": "reconnect"],
                               baseDir: baseDir)
        wal.beginStreaming()
        router.resetLevelMeter()                  // fresh Opus decoder for the continued stream
        #if canImport(AVFoundation)
        router.resetPCMDecoder()
        #endif
        router.setExternalPCM(false)              // ambient Omi keeps the internal decode tap
        router.setPaused(isPaused)
        router.setWAL(wal)                        // frames now flow into this WAL — continued sequence
        // Resume-same-id across reconnect/relaunch: CONTINUE the external backoff schedule
        // (the same conversation continues — never reset the spacing on an internal roll).
        startLiveTranscription(freshConversation: false)
        lastHeartbeatAt = 0; lastHeartbeatFrames = router.stats().count
        pushLiveState(.start)
        startMeter()
        rebuildVisibleCaptures()
        log?.info("capture \(captureId): reconnect/relaunch within silence gap → RESUMED (same id, no split)")
        return true
    }

    // MARK: live on-device transcription lifecycle (Feature 1)

    /// Spin up a fresh per-conversation live transcriber (if a factory is wired) and
    /// pump its provisional transcript into `liveTranscript`. All failures are
    /// non-fatal: capture continues with no live preview.
    private func startLiveTranscription(
        freshConversation: Bool,
        carryingForward priorSnapshot: LiveTranscript? = nil
    ) {
        // A conversation boundary starts with empty live state. A foreground restart is
        // different: iOS may retire the Speech publisher while the app is suspended, but
        // the conversation and its already-rendered words are still live. Preserve that
        // snapshot and only invalidate in-flight title requests tied to the retired
        // transcriber; clearing the title/transcript here painted the blank shell from the
        // foreground bug.
        if priorSnapshot == nil {
            resetLiveTitleTransient()
        } else {
            modelTitleInFlight = false
            externalTitleInFlight = false
        }
        if freshConversation { resetLiveTitleBackoff() }
        guard let make = makeLiveTranscriber, let t = make() else { return }
        live.transcript = priorSnapshot ?? .empty
        liveTranscriber = t
        #if canImport(AVFoundation)
        liveBox.set(t)
        #endif
        let pump = Task { @MainActor [weak self] in
            for await snap in t.transcript {
                guard !Task.isCancelled else { break }
                let published = priorSnapshot.map {
                    Self.appendingLiveTranscript(snap, after: $0)
                } ?? snap
                self?.live.transcript = published
                self?.updateLiveTitle(with: published)
            }
        }
        liveTranscriptTask = pump
        Task { @MainActor [weak self] in
            do { try await t.start() }
            catch {
                guard let self, self.liveTranscriber === t else { return }
                self.log?.warn("live transcription off: \((error as NSError).localizedDescription)")
                #if canImport(AVFoundation)
                self.liveBox.set(nil)
                #endif
                self.liveTranscriber = nil
                pump.cancel()
                // A start failure is non-fatal and must not erase a transcript that was
                // already visible before suspension. Re-publish the retained value so a
                // newly-attached foreground surface reads it immediately.
                self.live.transcript = self.live.transcript
            }
        }
    }

    /// Re-attach the ephemeral live-transcript producer after the app returns to the
    /// foreground. Speech frameworks may terminate their result publisher while iOS
    /// suspends the process even though the WAL session remains open. Re-publish the last
    /// snapshot immediately (so the restored view never paints blank), retire the stale
    /// transcriber, and start a continuation whose new words append to the retained window.
    ///
    /// This is lifecycle-only work: no defaults reads, durable locks, or WAL reads are
    /// introduced on the audio/frame path.
    public func restoreLiveTranscriptionAfterForeground() {
        guard active != nil else { return }

        let carried = Self.carriedLiveTranscript(live.transcript)
        // @Published sends even when the value is equal. That explicit replay is the
        // scene-phase reattachment signal the restored RecordingScreen was missing.
        live.transcript = carried

        guard !isPaused, makeLiveTranscriber != nil else { return }
        let retired = liveTranscriber
        #if canImport(AVFoundation)
        liveBox.set(nil)
        #endif
        liveTranscriber = nil
        liveTranscriptTask?.cancel()
        liveTranscriptTask = nil

        #if canImport(AVFoundation)
        // Suspension can leave the stateful Opus decoder straddling a discontinuity in
        // the source stream. Re-baseline it at the same boundary where the PCM consumer
        // is replaced. startLiveTranscription installs the replacement into liveBox
        // synchronously before the next routed frame is handed to it.
        router.resetPCMDecoder()
        #endif

        // Release the retired framework session best-effort. The new publisher is wired
        // synchronously below so incoming PCM can continue flowing without waiting for an
        // OS speech finalization that may itself have been interrupted by suspension.
        if let retired {
            Task { _ = await retired.finish() }
        }
        startLiveTranscription(
            freshConversation: false,
            carryingForward: carried)
    }

    /// Freeze the pre-suspension volatile tail into the carried finalized window. Those
    /// words were already rendered to the user; a replacement recognizer starts with an
    /// empty context and must build after them rather than replace them.
    private static func carriedLiveTranscript(_ snapshot: LiveTranscript) -> LiveTranscript {
        let text = LiveTranscriptBuffer.boundedTail(snapshot.displayText)
        let context = snapshot.titleContext.isEmpty ? text : snapshot.titleContext
        return LiveTranscript(
            finalizedText: text,
            volatileTail: "",
            isComplete: false,
            titleContext: context)
    }

    /// Merge a replacement transcriber's whole post-foreground revision after the retained
    /// pre-foreground window. Both display and title contexts remain bounded.
    private static func appendingLiveTranscript(
        _ continuation: LiveTranscript,
        after retained: LiveTranscript
    ) -> LiveTranscript {
        let finalized = LiveTranscriptBuffer.boundedTail(
            joinedLiveText(retained.finalizedText, continuation.finalizedText))
        let retainedContext = retained.titleContext.isEmpty
            ? retained.finalizedText
            : retained.titleContext
        let combinedContext = joinedLiveText(
            retainedContext,
            continuation.titleContext)
        var titleContext = RollingTitleContext()
        titleContext.replaceAll(combinedContext)
        return LiveTranscript(
            finalizedText: finalized,
            volatileTail: continuation.volatileTail,
            isComplete: continuation.isComplete,
            titleContext: titleContext.text)
    }

    private static func joinedLiveText(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + " " + second
    }

    /// Finish the active conversation's live transcriber + clear the preview. When a
    /// `seedInto` capture id is given, the transcriber's SETTLED text (more complete than
    /// the last volatile snapshot) refines that capture's persisted provisional card
    /// once `finish()` returns (Feature 1).
    private func endLiveTranscription(seedInto captureId: String? = nil) {
        #if canImport(AVFoundation)
        liveBox.set(nil)
        #endif
        let t = liveTranscriber
        liveTranscriber = nil
        liveTranscriptTask?.cancel()
        liveTranscriptTask = nil
        live.transcript = .empty
        // Remember the session's settled live title BEFORE clearing: it seeds the
        // provisional card (better than first-words-of-tail) until the authoritative
        // pipeline title lands. Then clear the published title with the preview.
        let sessionTitle = liveTitleState?.text
        // Only the transient title clears here; the conversation-scoped external backoff
        // survives a transcriber teardown so an internal roll keeps its schedule.
        resetLiveTitleTransient()
        if let t {
            let taskID = UUID()
            let task = Task { @MainActor [weak self] in
                let settled = await t.finish()
                guard let self else { return }
                defer { self.liveTranscriptionFinishTasks[taskID] = nil }
                guard !Task.isCancelled,
                      !self.accountExposureClosing,
                      !self.accountExposureClosed,
                      let captureId,
                      !settled.isEmpty else { return }
                self.seedProvisionalCard(
                    captureId,
                    transcript: settled,
                    preferredTitle: sessionTitle)
            }
            liveTranscriptionFinishTasks[taskID] = task
        }
    }

    /// Clear the TRANSIENT rolling-title state tied to one transcriber (the visible
    /// title + the heuristic/on-device-model cadence counters). Runs on every
    /// transcriber (re)start — including an internal roll / resume — because a fresh
    /// transcriber begins with an empty context. Does NOT touch the conversation-scoped
    /// external backoff schedule.
    private func resetLiveTitleTransient() {
        live.title = nil
        liveTitleState = nil
        titleWordsAtLastHeuristic = 0
        titleWordsAtLastModel = 0
        lastModelTitleAt = nil
        modelTitleInFlight = false
        modelTitleFailures = 0
        // Transcriber-scoped external guards: a transcriber swap (roll/resume) invalidates
        // any in-flight external call and RESETS the per-transcriber word watermark (the
        // fresh transcriber's context restarts small — otherwise the stale-and-larger
        // watermark would suppress the external refresh for the rest of the conversation).
        externalTitleInFlight = false
        wordsAtLastExternal = 0
    }

    /// Arm the EXTERNAL backoff schedule for a genuinely NEW conversation (track
    /// 20260717T1500): first external refresh one `firstDelay` from now, counters
    /// cleared. Deliberately NOT called on an internal silence-gap roll or a
    /// resume-same-id, so a long conversation keeps its widened spacing rather than
    /// re-tightening to 60s every time the transcriber is swapped.
    private func resetLiveTitleBackoff() {
        // Conversation-scoped only (transcriber-scoped guards live in the transient reset,
        // which always runs alongside this). Re-arming here re-tightens spacing to 60s —
        // done ONLY for a genuinely new conversation, never an internal roll / resume.
        let now = Date()
        backoffStartedAt = now
        nextExternalFireAt = now.addingTimeInterval(liveTitleBackoff.delay(afterRefreshes: 0))
        externalRefreshCount = 0
        externalTitleFailures = 0
        nextLiveTitleSeq = 0
    }

    /// Recompute the rolling title from the WHOLE conversation context. Runs only on
    /// FINALIZED snapshots (finals land every few seconds — never per volatile word)
    /// and only after enough NEW words, so the render path stays untouched between
    /// meaningful changes. The heuristic is a single scan of the bounded context
    /// (≤ ~5 KB); the model refresh is debounced + async (never on the main thread).
    private func updateLiveTitle(with snap: LiveTranscript) {
        guard snap.volatileTail.isEmpty, !snap.titleContext.isEmpty else { return }
        let words = snap.titleContext.split(separator: " ").count
        if liveTitleState == nil
            || words - titleWordsAtLastHeuristic >= liveTitleCadence.heuristicMinNewWords {
            titleWordsAtLastHeuristic = words
            if let t = WholeConversationTitle.heuristic(from: snap.titleContext) {
                applyTitleCandidate(t, tier: .heuristic)
            }
        }
        maybeRefreshModelTitle(context: snap.titleContext, words: words)
        maybeRefreshExternalTitle(context: snap.titleContext, words: words)
    }

    /// A debounced on-device model refresh of the live title: at most one in flight,
    /// ≥ `modelRefreshSeconds` apart, ≥ `modelMinNewWords` of new speech, disabled
    /// for the session after repeated failures, skipped while paused.
    private func maybeRefreshModelTitle(context: String, words: Int) {
        // `isAvailable` re-checked per refresh: phones without Apple Intelligence
        // (and the availability flipping mid-session) stay honestly heuristic-only.
        guard let titler = liveTitler, titler.isAvailable, !modelTitleInFlight,
              modelTitleFailures < Self.maxModelTitleFailures, !isPaused else { return }
        guard words >= liveTitleCadence.modelMinWords,
              words - titleWordsAtLastModel >= liveTitleCadence.modelMinNewWords else { return }
        if let last = lastModelTitleAt,
           Date().timeIntervalSince(last) < liveTitleCadence.modelRefreshSeconds { return }
        modelTitleInFlight = true
        // The session identity at launch: a conversation ROLL (split / silence gap)
        // swaps the transcriber, and a stale completion must neither title the NEXT
        // conversation nor disturb its fresh cadence counters.
        let session = liveTranscriber
        Task { @MainActor [weak self] in
            do {
                let title = try await titler.liveTitle(for: context)
                guard let self, self.liveTranscriber === session else { return }
                self.modelTitleInFlight = false
                self.lastModelTitleAt = Date()
                self.titleWordsAtLastModel = words
                self.applyTitleCandidate(title, tier: .model)
            } catch {
                guard let self, self.liveTranscriber === session else { return }
                self.modelTitleInFlight = false
                self.lastModelTitleAt = Date()
                self.modelTitleFailures += 1
                self.log?.warn("live title refresh failed (\(self.modelTitleFailures)): \((error as NSError).localizedDescription)")
            }
        }
    }

    /// The EXTERNAL live-title refresh on the EXPONENTIAL BACKOFF (track 20260717T1500,
    /// Nick-approved). The on-device heuristic/model title is the INSTANT placeholder;
    /// this asks the door for an external (Fireworks) re-title that SHARPENS it on a
    /// geometric cadence (~1, 3, 7, 15, 31 min… capped 30 min between refreshes). It is
    /// SNAPSHOT-DRIVEN — evaluated only when new finalized speech arrives — so it never
    /// spends a call on silence. Guards: external wired at all (nil ⇒ "just my phone" /
    /// offline → placeholder stands); at most one in flight; not paused; ≥ minimum words;
    /// NEW words since the last success; the backoff time reached; not disabled after
    /// repeated failures; an active capture id. The whole-conversation `context` (the
    /// phone's bounded head+tail) is what the door titles — not the recent words.
    private func maybeRefreshExternalTitle(context: String, words: Int) {
        guard let fetch = liveTitleExternal, !isPaused,
              !externalTitleInFlight,
              externalTitleFailures < Self.maxExternalTitleFailures,
              let captureId = active?.captureId else { return }
        // Don't title a near-empty conversation, and skip a tick with no new words.
        guard words >= WholeConversationTitle.minimumWords,
              words > wordsAtLastExternal else { return }
        // Self-arm if a resume-same-id continued into a conversation the backoff was
        // never armed for (fresh app process); otherwise honor the standing schedule.
        if nextExternalFireAt == nil { resetLiveTitleBackoff() }
        guard let due = nextExternalFireAt, Date() >= due else { return }

        externalTitleInFlight = true
        let seq = nextLiveTitleSeq
        nextLiveTitleSeq += 1
        // The session identity at launch: a roll/resume swaps the transcriber, and a
        // stale completion must not title the NEXT transcriber's conversation.
        let session = liveTranscriber
        Task { @MainActor [weak self] in
            do {
                let title = try await fetch(captureId, context, seq)
                guard let self, self.liveTranscriber === session else { return }
                self.externalTitleInFlight = false
                self.externalTitleFailures = 0
                self.wordsAtLastExternal = words
                self.advanceExternalBackoff()
                if let title, !title.isEmpty {
                    self.applyTitleCandidate(title, tier: .external)
                }
            } catch {
                guard let self, self.liveTranscriber === session else { return }
                self.externalTitleInFlight = false
                self.externalTitleFailures += 1
                // Widen on failure too (spacing keeps growing); the on-device title stands.
                self.advanceExternalBackoff()
                self.log?.warn("external live title refresh failed (\(self.externalTitleFailures)): \((error as NSError).localizedDescription)")
            }
        }
    }

    /// Advance the backoff after an external attempt (success OR failure) so the next
    /// refresh is one doubled interval out (capped at the ceiling), anchored to now.
    private func advanceExternalBackoff() {
        externalRefreshCount += 1
        nextExternalFireAt = Date().addingTimeInterval(
            liveTitleBackoff.delay(afterRefreshes: externalRefreshCount))
    }

    /// Route a candidate through the anti-flicker arbiter; publish only real changes.
    private func applyTitleCandidate(_ text: String, tier: LiveTitleState.Tier) {
        let merged = LiveTitleArbiter.merged(current: liveTitleState, candidateText: text, tier: tier)
        guard merged != liveTitleState else { return }
        liveTitleState = merged
        live.title = merged?.text
    }

    /// Persist the on-device transcript as the capture's PROVISIONAL card content + a
    /// provisional title (first words / "Processing…"), then refresh the list so the
    /// card shows it immediately. Never downgrades a card that already has authoritative
    /// Kiln content. Does NOT stamp the in-Lore/cached-transcript tombstone — provisional
    /// content must not read as "Ready".
    private func seedProvisionalCard(_ captureId: String, transcript: String,
                                     preferredTitle: String? = nil) {
        // Prefer the session's settled ROLLING title (whole-conversation, possibly
        // model-tier) over first-words-of-transcript; the authoritative pipeline
        // title still replaces either when it lands.
        let preferred = preferredTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (preferred?.isEmpty == false) ? preferred! : ProvisionalTitle.from(transcript: transcript)
        let changed = ConversationCardStore.seedProvisional(
            captureId: captureId, baseDir: baseDir, transcript: transcript, title: title)
        if changed {
            invalidateSidecar(captureId)   // the provisional body/title just landed on the card
            rebuildVisibleCaptures()
            // The last-finished title the home widget shows is derived from the newest card.
            // This seed (incl. the async transcript-refine after endSession) can change it,
            // so re-write the App-Group snapshot + hint WidgetKit to reload — otherwise the
            // widget keeps showing the earlier provisional title until the next transition.
            refreshHomeWidget()
        }
    }

    /// Manually split the conversation (Feature 2): finalize the CURRENT capture (it's
    /// sent for transcription via the existing finalize path) and immediately begin a
    /// NEW conversation — the SAME boundary the silence-gap segmenter draws, triggered
    /// by hand. No-op when nothing is being captured. Audio is never dropped: endSession
    /// flushes/finalizes the closed WAL and beginSession opens the next before the next
    /// frame is routed (both run synchronously on the main actor).
    public func splitConversation() {
        guard active != nil else { return }
        // An explicit boundary (manual split / Live Activity "End current", which routes
        // here) RESETS the session clock: clear it BEFORE the roll so the following
        // beginSession re-anchors a fresh clock rather than preserving the old one.
        recordingClock = nil
        endSession()
        beginSession()
        router.resetSegmenter()   // fresh boundary state for the new conversation
        log?.info("capture: manual split → new conversation")
    }

    /// The Live Activity "End Current" button (App Intent) target: end/finalize the CURRENT
    /// conversation now (it becomes a discrete card, sent for transcription) and keep
    /// capture running — the next voiced audio opens a fresh conversation. Semantically the
    /// same end-current-start-new boundary as `splitConversation()`, just surfaced to the
    /// user as "end this conversation". Returns whether it acted (false = nothing was
    /// recording → the button was a no-op). No-op is intentional so a stale button press
    /// during a lull never mints an empty conversation.
    @discardableResult
    public func endCurrentConversation() -> Bool {
        guard active != nil else { return false }
        recordingScreenMinimized = false   // explicit end — clean slate for the next recording
        splitConversation()
        return true
    }

    /// Whether the Live Activity's "End Current" button should be enabled — there must be
    /// an open conversation to end. (The button also no-ops safely if pressed when false.)
    public var canEndCurrentConversation: Bool { active != nil }

    private func endSession() {
        router.setWAL(nil)
        live.candidates = []   // the live surface's rows belong to the closing conversation
        guard let finished = active else {
            // No active session — still ensure any live preview is torn down.
            endLiveTranscription()
            router.setExternalPCM(false)
            return
        }
        // Every endSession is a DELIBERATE boundary — a silence-gap roll, grace-expiry, an
        // explicit mic Stop, or a manual split. Stamp the durable marker (review P2) so a
        // later reconnect never resumes this conversation: only orphan-stamped / never-ended
        // captures (where the app died and catch-up audio kept arriving) may be resumed.
        try? Data().write(to: Self.endedDeliberatelyMarkerURL(finished.captureId, baseDir: baseDir),
                          options: [.atomic])
        // Substance gate: read how much VOICED audio this capture accumulated and the
        // on-device transcript we hold RIGHT NOW (before teardown clears it).
        let voiced = router.sessionVoicedFrameCount()
        let onDeviceNow = liveTranscript.displayText
        let duration = max(0, Date().timeIntervalSince1970 - startTime(of: finished))
        let kept = CaptureManager.hasUploadSubstance(voicedFrames: voiced,
                                                     onDeviceTranscript: onDeviceNow,
                                                     durationSeconds: duration)
        // CONTENT-FREE usage: a recording session + a conversation boundary closed.
        // Counts + durations + the source/kept enum ONLY — never the transcript
        // (`onDeviceNow`), the title, or any speaker name.
        let sourceToken = captureSource == .omi ? "omi" : "mic"
        UsageHook.session(kind: "recording", source: sourceToken,
                          durationSec: Int(duration), kept: kept)
        UsageHook.conversation(kind: "ended", durationSec: Int(duration),
                               segmentCount: finished.status.totalSegments)
        if !kept {
            // JUNK FRAGMENT — drop it LOCALLY. Never seed a card, never mark it
            // pending-finalize, never POST it to the door. The bytes stay on disk under a
            // durable `.discarded` marker (nothing deleted); drain + visibility both skip it.
            endLiveTranscription()                       // tear down the transcriber (no seed)
            router.setExternalPCM(false)
            finished.finish()
            active = nil
            discardLowSubstance(finished.captureId, voicedFrames: voiced)
            rebuildVisibleCaptures()                     // ensure the fragment never shows
            pushLiveState(.end)
            log?.info("capture \(finished.captureId): DISCARDED — thin capture (\(voiced) voiced frame(s) < \(Self.minVoicedFramesToUpload) AND on-device preview not meaningful); not uploaded")
            return
        }
        // Above the bar — the existing real-conversation finalize path. Persist the
        // on-device transcript as PROVISIONAL content so the card shows readable text the
        // INSTANT it's stopped — resilient to slow/failed Kiln transcription (Feature 1).
        let finishedId = finished.captureId
        // S4 — CLEAR `active` FIRST. `seedProvisionalCard` invalidates the sidecar, and
        // `invalidateSidecar` throttles the ACTIVE capture (R2, up to 5s). Seeding while
        // `active` was still this capture meant the ended conversation's single most
        // important invalidation was the one that got throttled: for up to 5s its memo still
        // read `hasLocalTranscriptText == false`, so it counted in `processingConversationCount`
        // ("still processing") and contributed 0 words to the stats tiles. Matches the order
        // the discard branch above and `discardLowSubstance`/`deleteConversation` already use.
        router.setExternalPCM(false)                 // clear the mic's direct-PCM tap mode
        finished.finish()
        active = nil
        seedProvisionalCard(finishedId, transcript: onDeviceNow,
                            preferredTitle: liveTitleState?.text)
        endLiveTranscription(seedInto: finishedId)   // stop + (async) refine the seed
        // A closed conversation must reach the Lore inbox: mark it pending-finalize
        // (durably, so it survives relaunch — mirrors the WAL's waitingForInternet
        // ethos), then drive sync→finalize. The drain timer + app-foreground retry
        // any that don't complete now (door/Lore down, or segments not yet ACK'd).
        markNeedsFinalize(finished.captureId)
        let id = finished.captureId
        let baseDir = self.baseDir
        let provider = self.locationProvider
        let eagerTaskID = UUID()
        let eagerTask = Task { [weak self] in
            defer { self?.eagerEndSessionTasks[eagerTaskID] = nil }
            // Stamp the conversation END + an opportunistic location fix (F1, F5)
            // BEFORE finalize, so the metadata is durable and finalize sends it. The
            // location is best-effort: nil (denied / backgrounded / no fix) → time-only.
            let fix = await provider.currentLocation()
            guard !Task.isCancelled,
                  self?.accountExposureClosing != true,
                  self?.accountExposureClosed != true else { return }
            ConversationMetaStore.recordEnd(captureId: id, baseDir: baseDir,
                                            at: nowUnixSecs(), location: fix)
            self?.invalidateMeta(id)
            await finished.sync()                 // snappy first sync
            guard !Task.isCancelled,
                  self?.accountExposureClosing != true,
                  self?.accountExposureClosed != true else { return }
            // The drain timer also retries this; skip the eager close-path finalize
            // when the automatic drivers are quiesced (deterministic finalize tests).
            if self?.autoFinalizeEnabled == true {
                await self?.tryFinalize(finished) // finalize once segments are ACK'd
            }
        }
        eagerEndSessionTasks[eagerTaskID] = eagerTask
        // End the Live Activity into a brief idle "last conversation" state + refresh the
        // widget. The provisional card seeded above gives `lastFinishedConversation()` a
        // title immediately; a later Kiln title refresh re-pushes via the next transition.
        pushLiveState(.end)
        log?.info("capture \(id): session ended (pending finalize → Lore)")
    }

    // MARK: finalize-on-conversation-close (advance the capture to the Lore inbox)

    /// A capture is pending-finalize iff its dir has the marker (set on close,
    /// removed on a successful door finalize). Durable so a relaunch retries.
    private func needsFinalizeMarker(_ captureId: String) -> URL {
        baseDir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent(".needs-finalize")
    }

    private func markNeedsFinalize(_ captureId: String) {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data().write(to: needsFinalizeMarker(captureId), options: [.atomic])
    }

    private func isPendingFinalize(_ captureId: String) -> Bool {
        FileManager.default.fileExists(atPath: needsFinalizeMarker(captureId).path)
    }

    private func clearNeedsFinalize(_ captureId: String) {
        try? FileManager.default.removeItem(at: needsFinalizeMarker(captureId))
    }

    /// Finalize one closed capture IF it is pending-finalize and its segments are
    /// all durably on the desktop (ACK'd). Finalize must run AFTER the audio is on
    /// the desktop — else the door has nothing to assemble — so we gate on a fully
    /// synced WAL (no pending segments). On success the marker is cleared; on
    /// failure it stays so the next retry tick tries again. Idempotent + guarded
    /// against concurrent attempts for the same capture.
    private func tryFinalize(_ wal: CaptureWAL, allowExpiredRecovery: Bool = false) async {
        guard !accountExposureClosing,
              !accountExposureClosed,
              !Task.isCancelled else { return }
        let id = wal.captureId
        guard isPendingFinalize(id), !finalizing.contains(id) else { return }
        // Claim the concurrency marker BEFORE the first suspension point below. Finalize reads
        // the DURABLE on-disk truth (`.ack` markers) off the main actor (see next comment), and
        // that `await` would otherwise let a second caller (the finished-capture path / the next
        // retry tick) slip past the `!finalizing.contains` guard and finalize the same capture
        // TWICE. Any early return past this point must release it (the `else` below + the defer).
        finalizing.insert(id)
        // Finalize is gated on the DURABLE on-disk truth (`.ack` markers), so it reads
        // `snapshot()` — NOT the in-memory `status`, which lags here: `sync()`'s 200-ACK
        // `publish()` hops to main ASYNC, so `wal.status` is often still pre-ACK when this runs
        // synchronously on the main actor right after the sync loop. Reading the stale count
        // could WRONGLY defer a fully-synced finalize (or, worse in principle, mis-gate it). But
        // `snapshot()` is a full segment enumeration, and doing it per pending-finalize capture
        // ON the main actor is the same class of stall as the drain-gate hang — so run it OFF
        // the main actor (the single-drain guard means no concurrent `sync()`/`computeStatus`
        // races this WAL). Correctness is preserved (disk truth); the main thread does no I/O.
        let snap = await Task.detached { wal.snapshot() }.value
        guard !accountExposureClosing,
              !accountExposureClosed,
              !Task.isCancelled else {
            finalizing.remove(id)
            return
        }
        // Gate: audio must be durably on the desktop before finalize.
        guard snap.totalSegments > 0, snap.pendingSegments == 0 else {
            if snap.pendingSegments > 0, recoveryWindowExpired(id), !allowExpiredRecovery {
                markIncomplete(id, pendingSegments: snap.pendingSegments)
                wal.refreshStatus()
                finalizing.remove(id)
                return
            }
            finalizing.remove(id)   // released — not a real attempt, retry next tick
            log?.info("capture \(id): finalize deferred — \(snap.pendingSegments) segment(s) not yet ACK'd")
            return
        }
        defer { finalizing.remove(id) }
        // P2 — the recorded end must never predate this capture's newest audio. Omi
        // delivers buffered catch-up segments AFTER a BLE gap (faster than real time),
        // which land AFTER a premature orphan-reconcile / endSession end-stamp — freezing
        // endedAt seconds after the conversation began while the WAL still holds minutes.
        // Bump endedAt forward to max(recorded end, newest on-disk segment mtime) so the
        // door ingests the TRUE end, not a stale early bound (which drove premature ingest
        // + replace churn). recordEnd overwrites the end + preserves any existing location.
        if let mtime = CaptureManager.newestSegmentMTimeOnDisk(id, baseDir: baseDir) {
            let newestEnd = UInt64(max(0, mtime.timeIntervalSince1970))
            let recordedEnd = ConversationMetaStore.load(captureId: id, baseDir: baseDir)?.endedAt ?? 0
            if newestEnd > recordedEnd {
                ConversationMetaStore.recordEnd(captureId: id, baseDir: baseDir, at: newestEnd, location: nil)
                invalidateMeta(id)
            }
        }
        // The durable conversation metadata (start/end/location) becomes the
        // finalize POST body so the door persists it + threads it into the ingest
        // envelope (F1, F9). Absent (older capture) → an empty body (still valid).
        let meta = ConversationMetaStore.load(captureId: id, baseDir: baseDir)
        do {
            // TIME-BOXED (audited with the pending-delete lane): the direct-LAN transport
            // bounds itself at 60s but the relay/mux leg had NO bound at all, so a wedged
            // round trip could park the finalize lane indefinitely. A deadline lands in the
            // catch below — "staying pending, will retry" — so the durable `.needs-finalize`
            // marker is untouched and nothing is lost.
            let finalize = finalizeCapture
            try await AsyncDeadline.race(Self.finalizeCallTimeout) { try await finalize(id, meta) }
            guard !accountExposureClosing, !accountExposureClosed,
                  !Task.isCancelled else { return }
            clearNeedsFinalize(id)
            // The finalize backend may be the LOCAL brain (LocalBackend), which writes the
            // transcript + card sidecars directly — OUTSIDE the manager's sight. Invalidate
            // the memo + rebuild so a phone-only transcript's membership/stats reflect it
            // (a no-op cost for the door path, whose transcript arrives via ensureRecent…).
            invalidateSidecar(id)
            rebuildVisibleCaptures()
            // The ambient lane's rolling buffer is ephemeral by design — the finalized
            // capture's authoritative transcript comes from the normal pipeline.
            if let lane = ambientLane { Task.detached { await lane.endCapture(captureId: id) } }
            CaptureEventLog.append(.captureFinalized, captureId: id, baseDir: baseDir)
            // The conversation is now the authoritative last-finished; make sure the home
            // widget's snapshot reflects it the moment finalize completes (best-effort hint).
            refreshHomeWidget()
            // B3: announce the finished conversation so the Activity daily recap
            // rebuilds live (grows through the day), not only on screen appear.
            lastFinalizedAt = Date()
            NotificationCenter.default.post(name: .foundryxConversationFinalized,
                                            object: nil, userInfo: ["captureId": id])
            log?.info("capture \(id): finalized → advanced to Lore inbox")
        } catch {
            log?.warn("capture \(id): finalize failed (\((error as NSError).localizedDescription)) — staying pending, will retry")
        }
    }

    // MARK: pause / resume (device stays connected)

    // pause()/resume() persist the user's capture INTENT (req 1) so it survives a full
    // app restart: a paused Omi stays paused on the next launch + reconnect instead of
    // silently auto-capturing.
    public func pause() {
        isPaused = true
        recordingClock?.pause(at: Date())   // freeze the session clock while paused
        CaptureSettings.omiCaptureDesiredState = .paused
        router.setPaused(true)
        pushLiveState(.update)   // reflect paused state on the Live Activity + widget
        log?.info("capture: paused")
    }
    public func resume() {
        isPaused = false
        recordingClock?.resume(at: Date())   // fold the paused span in; continue without a jump
        CaptureSettings.omiCaptureDesiredState = .listening
        router.setPaused(false)
        pushLiveState(.update)
        log?.info("capture: resumed")
    }
    public func togglePause() { isPaused ? resume() : pause() }

    // MARK: drain (retry until every segment is ACK'd)

    private func startDrainTimer() {
        drainTimer = drainTimerFactory(5) { [weak self] in
            guard let self,
                  !self.accountExposureClosing,
                  !self.accountExposureClosed,
                  self.drainTask == nil else { return }
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.drainPending()
                self.drainTask = nil
            }
            self.drainTask = task
        }
    }

    /// Guards against overlapping drains: the 5s timer can fire a new drain while the
    /// previous one is still `await`-ing a slow `wal.sync()`, which ran two `sync()`/
    /// `computeStatus()`/prune passes on the SAME WAL concurrently (off-main) → a data
    /// race that crashed in `objc_retain` (EXC_BAD_ACCESS). One drain at a time.
    private var isDraining = false

    public func drainPending() async {
        guard !accountExposureClosing, !accountExposureClosed,
              !Task.isCancelled else { return }
        guard !isDraining else { return }   // a drain is already in flight — skip this tick
        isDraining = true
        drainActive = true
        defer { isDraining = false; drainActive = false }

        // Storm-stop: a known-expired bearer means EVERY upload will 401 — fire none.
        // `onAuthExpired` drives a one-shot token refresh / login; the rebuilt pipeline
        // (or `clearAuthExpired`) re-arms the drain.
        guard !authExpired else { return }

        while !authExpired {
            let now = Date().timeIntervalSince1970
            let batch = drainBatch(now: now)
            guard !batch.isEmpty else { break }

            // Resync handshake (AC1): before re-uploading anything, ask the door which
            // seqs it ALREADY stores durably and bulk-ACK them locally — lost ACKs must
            // never cause re-uploads. Runs sequentially on the main actor (memoised once
            // per capture per tunnel-session); the actual uploads below still run
            // concurrently in the task group.
            for wal in batch { await resyncIfNeeded(wal) }
            guard !accountExposureClosing, !accountExposureClosed,
                  !Task.isCancelled else { return }

            var madeProgress = false
            var shouldStop = false
            await withTaskGroup(of: (CaptureWAL, SyncOutcome).self) { group in
                for wal in batch {
                    group.addTask { (wal, await wal.sync()) }
                }
                while let (wal, outcome) = await group.next() {
                    let id = wal.captureId
                    switch outcome {
                    case .idle:
                        retryStates[id] = nil
                    case .progressed:
                        retryStates[id] = nil                 // healthy → reset backoff
                        madeProgress = true
                    case .failed:
                        recordUploadFailure(id, now: now)     // transient — back off; retry FOREVER
                        // A dropped socket / flap may have lost in-flight ACKs — re-run the
                        // resync handshake on the next pass instead of re-uploading blind (AC4).
                        resyncedCaptures.remove(id)
                    case .poisoned(let seq, let reason):
                        // Permanent poison on a specific segment — retire so it can't wedge the
                        // drain. The audio is KEPT (durable marker, no delete).
                        abandon(id, reason: "segment \(seq): \(reason)")
                    case .authExpired:
                        recordUploadFailure(id, now: now)
                        resyncedCaptures.remove(id)
                        handleUploadAuthExpired()             // stop everything + request re-auth
                        shouldStop = true
                    }
                }
            }
            if shouldStop || !madeProgress { break }
        }
        // After syncing, retry any pending-finalize captures whose segments are now
        // all ACK'd — this is the retry path for a finalize that didn't complete at
        // conversation-close (door/Lore was down, or segments weren't ACK'd yet).
        if autoFinalizeEnabled { await retryPendingFinalizes() }
        guard !accountExposureClosing, !accountExposureClosed,
              !Task.isCancelled else { return }
        await retryPendingDeletes()
        await retryPendingSpeakerConfirms()   // durable speaker-name confirms (hub-blip safe)
        shipAmbientSignalIfDue()   // redacted gate/card signal → desktop door (v3.3)
        await maybePrune()   // retention sweeps — throttled + run OFF the main thread
    }

    private func drainBatch(now: TimeInterval) -> [CaptureWAL] {
        var batch: [CaptureWAL] = []
        batch.reserveCapacity(Self.maxCapturesPerDrain)
        for wal in captures {
            // HANG FIX (build-286, 15/22 stallstacks): read the already-@Published, in-memory
            // `status.pendingSegments` — NOT `snapshot()`/`computeStatus()`, which is a full
            // synchronous on-disk segment enumeration (`allSegmentURLs`) that, run per capture
            // on the main actor every 5s, pinned the main thread on a 212-capture library
            // (nav-stalls to 4161ms). `pendingSegments == max(0, total − synced)` needs no disk.
            //
            // NEVER LOSE AUDIO — why the in-memory count can't wrongly skip a capture with real
            // pending uploads:
            //  • synced only ever RISES on a real 200 ACK / bulk-ACK / watermark (each publishes
            //    a fresh count), and total is derived from disk truth at every publish — so the
            //    count is never fabricated in a direction that hides pending work, EXCEPT
            //  • the actively-STREAMING capture, whose mid-stream flushes write segments to disk
            //    WITHOUT publishing, so its in-memory `total` can lag. That one is kept eligible
            //    unconditionally via `status.streaming`; `sync()` then reads the real on-disk
            //    pending set (`pendingSegmentURLs`) and uploads it. A non-streaming capture gets
            //    no new segments after `finish()`/warm published its count, so its count is exact.
            //  • a just-reloaded capture is warmed (its count published) during startup before
            //    steady-state drains; a pre-warm tick simply defers it one cycle (audio is kept
            //    and retried forever), never a loss.
            guard wal.status.pendingSegments > 0 || wal.status.streaming else { continue }
            let id = wal.captureId
            if isAbandoned(id) { continue }
            if isIncomplete(id) { continue }
            if manuallyRecoveringCaptureIds.contains(id) { continue }
            if isDiscarded(id) { continue }   // a sub-substance junk fragment never uploads
            if isDeleted(id) { continue }     // user-deleted captures never resurrect/re-upload
            if let held = suspendedSession, held.wal === wal { continue }   // hold uploads until the grace resolves
            // NEVER LOSE AUDIO: there is NO size / age / failure-count abandon here. A
            // large, old, or briefly-offline capture keeps draining (resuming from its
            // watermark) until fully uploaded. The only retire is permanent poison,
            // surfaced by `wal.sync()` returning `.poisoned`.
            // Backoff gate: skip a failing capture until its next-eligible instant.
            if let st = retryStates[id], now < st.nextEligible { continue }
            batch.append(wal)
            if batch.count >= Self.maxCapturesPerDrain {
                break
            }
        }
        return batch
    }

    /// The resync handshake (capture-sync AC1), ONCE per capture per tunnel-session:
    /// before draining a capture with pending segments, ask the door which seqs it
    /// ALREADY stores durably and bulk-mark those ACK'd locally — so ACKs lost to a
    /// tunnel drop mid-drain (the desktop-restart case: 1310 segs on disk, phone still
    /// counting 594+ "pending") never cause re-uploading audio the desktop holds.
    /// Old-door tolerance: a 404 (`nil`) means no endpoint → memoise + behave exactly
    /// as today (full drain, no resync, no error spam). A transport failure skips the
    /// memo so the handshake is retried on the next drain pass.
    private func resyncIfNeeded(_ wal: CaptureWAL) async {
        let id = wal.captureId
        guard !resyncedCaptures.contains(id) else { return }
        let doorSeqs: [UInt64]?
        do {
            doorSeqs = try await fetchDoorSegments(id)
        } catch {
            // Transport failure (tunnel down / door unreachable): drain as before —
            // the upload itself will fail + back off; re-try the handshake next pass.
            return
        }
        guard !accountExposureClosing, !accountExposureClosed,
              !Task.isCancelled else { return }
        resyncedCaptures.insert(id)
        guard let doorSeqs, !doorSeqs.isEmpty else { return }   // old door (404) / nothing stored yet
        let skipped = wal.bulkMarkSynced(doorSeqs)
        if skipped > 0 {
            log?.info("capture \(id): resync — \(skipped) segments already on desktop, skipped")
        }
    }

    /// Record an upload failure: bump the consecutive-failure count and schedule the
    /// next eligible retry with exponential backoff + jitter (no tight loop).
    private func recordUploadFailure(_ id: String, now: TimeInterval) {
        var st = retryStates[id] ?? RetryState()
        st.failures += 1
        st.nextEligible = now + CaptureManager.retryDelay(forFailures: st.failures)
        retryStates[id] = st
    }

    /// React to a 401/expired-token upload rejection: stop the drain immediately and
    /// ask the app to re-authenticate (refresh once, else surface the login screen).
    /// Idempotent — fires the hook once per expired-token epoch.
    private func handleUploadAuthExpired() {
        authExpired = true
        guard !authExpiredFired else { return }
        authExpiredFired = true
        log?.warn("capture: upload rejected as token-expired (401) — paused uploads, requesting re-auth")
        onAuthExpired?()
    }

    // MARK: terminal-retire (ONLY permanent poison — audio is never deleted)

    private func incompleteMarker(_ captureId: String) -> URL {
        baseDir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent(".incomplete")
    }
    private func isIncomplete(_ captureId: String) -> Bool {
        FileManager.default.fileExists(atPath: incompleteMarker(captureId).path)
    }
    private func recoveryWindowExpired(_ captureId: String, now: Date = Date()) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(
            atPath: needsFinalizeMarker(captureId).path),
              let closedAt = attrs[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(closedAt) >= Self.incompleteRecoveryWindow
    }
    private func markIncomplete(_ captureId: String, pendingSegments: Int,
                                detail: String? = nil) {
        let suffix = detail.map { "; \($0)" } ?? ""
        let reason = "incomplete: \(pendingSegments) segments unrecovered; audio kept on phone\(suffix)"
        try? Data(reason.utf8).write(to: incompleteMarker(captureId), options: [.atomic])
        clearNeedsFinalize(captureId)
        retryStates[captureId] = nil
        log?.error("capture \(captureId): INCOMPLETE — \(pendingSegments) segment(s) unrecovered; audio KEPT on device")
    }

    /// Whether the card should offer its explicit recovery action. The marker is the
    /// durable source of truth; a failed attempt always restores it.
    public func canManuallyRecover(_ captureId: String) -> Bool {
        isIncomplete(captureId) && !manuallyRecoveringCaptureIds.contains(captureId)
    }

    public func isManualRecoveryInProgress(_ captureId: String) -> Bool {
        manuallyRecoveringCaptureIds.contains(captureId)
    }

    /// Deliberately bypass the automatic seven-day give-up for one capture. A fresh
    /// manifest reconciliation happens before upload, so durable desktop segments are
    /// ACK'd locally and never sent twice. Every failure restores `.incomplete`; no
    /// segment or ACK file is removed here.
    public func recoverIncompleteCapture(_ captureId: String) async {
        guard !accountExposureClosing, !accountExposureClosed,
              !Task.isCancelled, isIncomplete(captureId),
              !manuallyRecoveringCaptureIds.contains(captureId),
              let wal = captures.first(where: { $0.captureId == captureId }),
              wal !== active, !isDeleted(captureId) else { return }

        manuallyRecoveringCaptureIds.insert(captureId)
        defer { manuallyRecoveringCaptureIds.remove(captureId) }
        DeletionRecorder.shared.emit("capture_manual_recovery", "started capture=\(captureId)")

        // Removing only the terminal marker re-arms the existing durable upload/finalize
        // path. Phone audio remains untouched throughout the attempt.
        try? FileManager.default.removeItem(at: incompleteMarker(captureId))
        markNeedsFinalize(captureId)
        retryStates[captureId] = nil
        resyncedCaptures.remove(captureId) // force a current desktop manifest read
        wal.refreshStatus()

        await resyncIfNeeded(wal)
        let outcome = await wal.sync()
        let failureDetail: String?
        switch outcome {
        case .failed:
            failureDetail = wal.snapshot().lastSyncError ?? "upload failed"
        case .poisoned(let seq, let reason):
            failureDetail = "segment \(seq): \(reason)"
        case .authExpired:
            handleUploadAuthExpired()
            failureDetail = "session expired"
        case .idle, .progressed:
            failureDetail = nil
        }

        if failureDetail == nil {
            await tryFinalize(wal, allowExpiredRecovery: true)
        }
        let snap = await Task.detached { wal.snapshot() }.value
        if !isPendingFinalize(captureId) {
            try? FileManager.default.removeItem(at: incompleteMarker(captureId))
            wal.refreshStatus()
            DeletionRecorder.shared.emit("capture_manual_recovery", "succeeded capture=\(captureId)")
            return
        }

        let detail = failureDetail ?? "manual recovery failed before finalize completed"
        markIncomplete(captureId, pendingSegments: snap.pendingSegments,
                       detail: "manual recovery failed: \(detail)")
        wal.refreshStatus()
        DeletionRecorder.shared.emit("capture_manual_recovery",
                                     "failed capture=\(captureId) reason=\(detail)")
    }

    private func abandonedMarker(_ captureId: String) -> URL {
        baseDir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent(".abandoned")
    }
    private func isAbandoned(_ captureId: String) -> Bool {
        FileManager.default.fileExists(atPath: abandonedMarker(captureId).path)
    }
    /// Record a clear terminal state for a permanently-poisoned capture (a durable
    /// marker carrying the reason, NOT a silent drop) and clear its pending-finalize
    /// intent so it stops being retried. The audio segments on disk are KEPT — only the
    /// retry intent is dropped; nothing is deleted here.
    private func abandon(_ captureId: String, reason: String) {
        try? Data(reason.utf8).write(to: abandonedMarker(captureId), options: [.atomic])
        clearNeedsFinalize(captureId)
        retryStates[captureId] = nil
        log?.error("capture \(captureId): RETIRED (permanent poison: \(reason)) — audio KEPT on device, no longer retried")
    }

    // MARK: local discard (sub-substance junk fragments — audio kept, never uploaded)

    private func discardMarker(_ captureId: String) -> URL {
        baseDir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent(".discarded")
    }
    /// True once a capture was locally discarded as a sub-substance junk fragment — so it
    /// stays discarded across relaunch and is never re-queued for upload nor shown.
    private func isDiscarded(_ captureId: String) -> Bool {
        FileManager.default.fileExists(atPath: discardMarker(captureId).path)
    }
    /// Locally DISCARD a sub-substance capture: write a durable `.discarded` marker (so a
    /// relaunch keeps it discarded + never re-queues it) and clear any finalize/retry
    /// intent. The audio bytes on disk are KEPT (nothing is deleted) but are never uploaded
    /// to the door, and the capture is hidden from the timeline. This is the phone's
    /// junk-fragment gate for silent blips + transient Omi BLE reconnect stubs.
    private func discardLowSubstance(_ captureId: String, voicedFrames: Int) {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let reason = "below min-substance bar: \(voicedFrames) voiced frame(s) < \(Self.minVoicedFramesToUpload)"
        try? Data(reason.utf8).write(to: discardMarker(captureId), options: [.atomic])
        clearNeedsFinalize(captureId)
        retryStates[captureId] = nil
        // Same-tick hide (the substance gate is immediate + user-visible), then the
        // off-main re-warm confirms the marker from disk.
        applySidecarMarker(captureId, discarded: true)
        invalidateSidecar(captureId)   // `.discarded` now present → memo must not show it
    }

    // MARK: delete conversation (user intent — instant local hide, durable remote retry)

    private func deletedMarker(_ captureId: String) -> URL {
        baseDir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent(".deleted")
    }

    private func needsDeleteMarker(_ captureId: String) -> URL {
        baseDir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent(".needs-delete")
    }

    /// True once the user deleted the capture. This is checked anywhere a discarded
    /// fragment is checked: hydration, browsing, reconcile, drain, poll/cache refresh.
    /// The marker is the choke point that prevents a status refresh or relaunch from
    /// rebuilding a row after the card vanished locally.
    public func isDeleted(_ captureId: String) -> Bool {
        FileManager.default.fileExists(atPath: deletedMarker(captureId).path)
    }

    private func markNeedsDelete(_ captureId: String) {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data().write(to: needsDeleteMarker(captureId), options: [.atomic])
        // The durable marker is the source of truth; the in-memory queue is how the drain
        // finds it without re-walking the captures dir on the main actor every 5s.
        enqueuePendingDelete(captureId)
        // A fresh, deliberate user intent deserves an immediate attempt even if the lane was
        // backed off from an earlier unreachable-door window.
        deleteLaneRetry = RetryState()
    }

    /// True while a capture still owes the door a remote delete. ONE definition of the
    /// predicate, shared by the (off-main, `nonisolated`) seed scan — mirrors `isDeletedOnDisk`.
    nonisolated static func isPendingDeleteOnDisk(_ captureId: String, baseDir: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: baseDir.appendingPathComponent(captureId, isDirectory: true)
                .appendingPathComponent(".needs-delete").path)
    }

    private func deleteConversationFilesKeepingMarkers(_ captureId: String) {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files {
            let name = f.lastPathComponent
            if name == ".deleted" || name == ".needs-delete" { continue }
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// Delete a conversation from the phone immediately and queue the desktop/Lore
    /// removal durably. Idempotent by design: a second delete re-writes the two tiny
    /// markers, finds no content files, and keeps the row hidden.
    public func deleteConversation(_ captureId: String) {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data().write(to: deletedMarker(captureId), options: [.atomic])
        markNeedsDelete(captureId)

        if active?.captureId == captureId {
            source.stop()
            micSource?.stop()
            suspendedSession = nil
            router.setWAL(nil)
            router.setExternalPCM(false)
            endLiveTranscription()
            active?.finish()
            active = nil
            isRecordingMic = false
            // Deleting the LIVE recording is an explicit end — clear the session clock so
            // the next session (e.g. the Omi re-streaming) anchors FRESH; a stale clock
            // here would survive `beginSession`'s stamp-only-if-nil and inflate the timer
            // (adversarial review M1, track 20260717T0630).
            recordingClock = nil
            pushLiveState(.end)
        }
        clearNeedsFinalize(captureId)
        retryStates[captureId] = nil
        finalizing.remove(captureId)
        cachingTranscripts.remove(captureId)
        if let poller = pollers.removeValue(forKey: captureId) { poller.stop() }
        deleteConversationFilesKeepingMarkers(captureId)
        // N2 — a deleted capture must not LEAK memo entries, and no off-main warm may
        // repopulate them afterwards. `applySidecarMarker` bumps the generation, so any warm
        // already in flight is dropped on arrival; everything else per-capture is released
        // here (meta, durable start, live-throttle state, the in-flight warm handle). Two
        // things are kept ON PURPOSE and both are a handful of bytes: the `.deleted` marker
        // snapshot (what keeps the row hidden in the same tick, and hidden again if a
        // mid-flight hydration re-offers the id) and the generation counter (it must stay
        // monotonic or a late warm could match a recycled generation).
        metaCache[captureId] = nil
        startTimeCache[captureId] = nil
        lastLiveSidecarWarmAt[captureId] = nil
        liveSidecarWarmPending.remove(captureId)
        applySidecarMarker(captureId, deleted: true)   // same-tick hide; no re-warm needed
        captures.removeAll { $0.captureId == captureId }   // didSet republishes immediately
        log?.info("capture \(captureId): deleted locally; remote delete queued")
    }

    // MARK: retention throttle (keep the big disk sweeps off the every-5s drain)

    /// The retention sweeps iterate ALL captures touching disk; running them every 5s on
    /// the main actor churned the main thread under a large backlog. Throttle to a calm
    /// cadence so the UI stays responsive. Tunable.
    public nonisolated static let pruneInterval: TimeInterval = 120
    private var lastPruneAt: TimeInterval = 0
    private func maybePrune() async {
        let now = Date().timeIntervalSince1970
        guard now - lastPruneAt >= Self.pruneInterval else { return }
        lastPruneAt = now
        // The retention sweep enumerates every capture's directory (contentsOfDirectory
        // → getattrlistbulk). Run ON the main actor it was the 0.5s-per-capture hang
        // STORM (spindump: 51 samples pinned on com.apple.main-thread). Snapshot the ids
        // on the main actor, do ALL the disk scanning + pruning OFF the main thread, then
        // apply the (small) UI result back on the main actor.
        let activeId = active?.captureId
        let ids = captures.compactMap { $0.captureId == activeId ? nil : $0.captureId }
        let base = baseDir
        let result = await Task.detached(priority: .utility) {
            Self.retentionSweep(ids: ids, baseDir: base)
        }.value
        applyRetentionSweep(result)
    }

    // MARK: retention — the sweep runs OFF the main actor (pure disk); the caller applies
    // the small UI result on the main actor. Prunes ~14d transcript TEXT (keeping the
    // name/description tombstone) and ~30d local AUDIO (only when confirmed in Lore AND a
    // readable tombstone survives). Idempotent + offline-safe. Never the active capture.

    /// What the off-main retention sweep changed on disk, so the main actor can invalidate
    /// the sidecar memo for EXACTLY the touched captures (a text prune + card merge, or an
    /// audio prune, both shift a capture's memoised membership/stats).
    struct RetentionSweepResult: Sendable {
        /// Captures whose local audio was pruned (their WAL status must be refreshed).
        let prunedAudioIds: [String]
        /// Captures whose cached transcript TEXT was pruned (+ card merged) — memo stale.
        let prunedTextIds: [String]
    }

    /// The full retention sweep for `ids`, done ENTIRELY off the main thread. NOTHING here
    /// touches actor state — disk only — so it is safe to run from a detached task. Returns
    /// the ids whose local audio / transcript text was pruned, so the caller can refresh
    /// those WALs, invalidate their sidecar memo, and rebuild the visible list on main.
    nonisolated static func retentionSweep(ids: [String], baseDir: URL) -> RetentionSweepResult {
        // ~14d transcript TEXT (preserve the name/description card first, then drop the text).
        var prunedText: [String] = []
        for id in ids {
            guard !isDeletedOnDisk(id, baseDir: baseDir) else { continue }
            guard TranscriptCacheStore.hasCachedTranscript(captureId: id, baseDir: baseDir) else { continue }
            guard CaptureRetention.shouldPruneTranscript(
                conversationAge: conversationAgeOnDisk(id, baseDir: baseDir)) else { continue }
            if let t = TranscriptCacheStore.load(captureId: id, baseDir: baseDir) {
                ConversationCardStore.merge(captureId: id, baseDir: baseDir,
                                            title: t.title, summary: t.summary, stage: nil)
            }
            TranscriptCacheStore.pruneTranscriptText(captureId: id, baseDir: baseDir)
            prunedText.append(id)
        }
        // ~30d local AUDIO (confirmed in Lore AND a readable tombstone survives).
        var prunedAudio: [String] = []
        for id in ids {
            guard !isDeletedOnDisk(id, baseDir: baseDir) else { continue }
            guard let age = newestSegmentAgeOnDisk(id, baseDir: baseDir) else { continue }
            let confirmed = TranscriptCacheStore.isConfirmedInLore(captureId: id, baseDir: baseDir)
            let tombstone = TranscriptCacheStore.hasCachedTranscript(captureId: id, baseDir: baseDir)
                || ConversationCardStore.exists(captureId: id, baseDir: baseDir)
            guard CaptureRetention.shouldPruneAudio(newestSegmentAge: age,
                                                    confirmedInLore: confirmed,
                                                    hasReadableTombstone: tombstone) else { continue }
            deleteLocalAudioOnDisk(id, baseDir: baseDir)
            prunedAudio.append(id)
        }
        return RetentionSweepResult(prunedAudioIds: prunedAudio, prunedTextIds: prunedText)
    }

    /// Apply the off-main sweep's result on the main actor: invalidate the memo for every
    /// touched capture (text prune / card merge / audio prune all shift membership/stats),
    /// refresh the audio-pruned WALs' status, and rebuild the visible list once.
    private func applyRetentionSweep(_ result: RetentionSweepResult) {
        let touched = Set(result.prunedAudioIds).union(result.prunedTextIds)
        guard !touched.isEmpty else { return }
        // S7 — ONE batched off-main hop, not N `.userInitiated` full-transcript decodes fanned
        // out at sweep scale (see `invalidateSidecars`).
        invalidateSidecars(Array(touched))
        let prunedAudio = Set(result.prunedAudioIds)
        for wal in captures where prunedAudio.contains(wal.captureId) { wal.refreshStatus() }
        rebuildVisibleCaptures()
        if !result.prunedAudioIds.isEmpty {
            log?.info("retention: pruned local audio for \(result.prunedAudioIds.count) capture(s) (>30d, confirmed, tombstoned)")
        }
    }

    // MARK: retention — nonisolated disk primitives (safe to run off the main actor)

    /// True when the capture carries a `.deleted` tombstone marker.
    nonisolated static func isDeletedOnDisk(_ captureId: String, baseDir: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: baseDir.appendingPathComponent(captureId, isDirectory: true)
                .appendingPathComponent(".deleted").path)
    }

    /// True when the capture carries a `.discarded` tombstone marker (a sub-substance
    /// junk fragment). The nonisolated peer of `isDiscarded` for the disk-scanning
    /// resume-candidate selection (`resumableCaptureId`).
    nonisolated static func isDiscardedOnDisk(_ captureId: String, baseDir: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: baseDir.appendingPathComponent(captureId, isDirectory: true)
                .appendingPathComponent(".discarded").path)
    }

    /// Durable per-capture source tag written at `beginSession` (`.capture-source`
    /// containing the `CaptureSourceKind` raw value). Lets the resume-candidate scan tell
    /// an AMBIENT/Omi capture from a phone-mic one — they share the `omi-` id prefix, so
    /// without this an Omi reconnect could hijack (and cancel the finalize of) a mic
    /// recording the user explicitly Stopped. `nil` = a legacy capture from before this
    /// shipped (handled conservatively by the caller).
    nonisolated static func sourceMarkerURL(_ captureId: String, baseDir: URL) -> URL {
        baseDir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent(".capture-source")
    }
    nonisolated static func capturedSourceOnDisk(_ captureId: String, baseDir: URL) -> String? {
        guard let data = try? Data(contentsOf: sourceMarkerURL(captureId, baseDir: baseDir)),
              let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Durable marker written by `endSession` — the single choke point for EVERY
    /// deliberate conversation boundary (silence-gap roll, grace-expiry, explicit mic
    /// stop, manual split). Its ABSENCE on a capture with an `endedAt` means the end was
    /// orphan-stamped (`reconcileOrphanedCaptures`) or the app died — the only ends a
    /// reconnect may resume. Distinguishes "the user/segmenter ended this" from "a crash
    /// froze it early while catch-up audio kept arriving."
    nonisolated static func endedDeliberatelyMarkerURL(_ captureId: String, baseDir: URL) -> URL {
        baseDir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent(".ended-deliberately")
    }
    nonisolated static func isEndedDeliberatelyOnDisk(_ captureId: String, baseDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: endedDeliberatelyMarkerURL(captureId, baseDir: baseDir).path)
    }

    /// Age (seconds) since the conversation started, from its meta on disk (0 when absent).
    nonisolated static func conversationAgeOnDisk(_ captureId: String, baseDir: URL) -> TimeInterval {
        guard let started = ConversationMetaStore.load(captureId: captureId, baseDir: baseDir)?.startedAt,
              started > 0 else { return 0 }
        return max(0, Date().timeIntervalSince1970 - TimeInterval(started))
    }

    /// Wall-clock mtime of the newest `seg-*.opus`, or nil when no segments remain. The
    /// TRUE tail of a capture's audio — including catch-up segments an Omi delivers after
    /// a BLE gap (faster than real time), which land AFTER a premature orphan-reconcile /
    /// endSession end-stamp. Both the resume-candidate scan and the finalize end-stamp
    /// bump read this so a capture's bound never predates its own newest audio.
    public nonisolated static func newestSegmentMTimeOnDisk(_ captureId: String, baseDir: URL) -> Date? {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "opus" }
            .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            .max()
    }

    /// Age (seconds) of the newest `seg-*.opus` by mtime, or nil when no segments remain.
    nonisolated static func newestSegmentAgeOnDisk(_ captureId: String, baseDir: URL) -> TimeInterval? {
        guard let newest = newestSegmentMTimeOnDisk(captureId, baseDir: baseDir) else { return nil }
        return Date().timeIntervalSince(newest)
    }

    /// Newest `seg-*.opus` mtime found WITHOUT statting every segment. Segment names are
    /// zero-padded monotonic (`seg-%012llu`), so the lexicographically-greatest name is the
    /// newest (and, since the WAL is append-only, the last-written = newest mtime): one
    /// `resourceValues` stat on that single file. The hot resume-candidate path uses this
    /// instead of `newestSegmentMTimeOnDisk` (which stats every segment) so a giant capture
    /// can't storm the @MainActor on an Omi reconnect.
    public nonisolated static func newestSegmentMTimeByName(_ captureId: String, baseDir: URL) -> Date? {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let newest = names.filter({ $0.hasPrefix("seg-") && $0.hasSuffix(".opus") }).max() else { return nil }
        let url = dir.appendingPathComponent(newest)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// `beginSession` durably writes open metadata and the Omi source tag before the
    /// first WAL chunk fills. Those synchronous stamps are the continuation proof during
    /// the segmentless buffer window after owner replacement or process relaunch.
    private nonisolated static func isRecentSegmentlessOpenOmiCapture(
        _ captureId: String,
        baseDir: URL,
        now: Date,
        silenceGap: TimeInterval
    ) -> Bool {
        guard newestSegmentMTimeByName(captureId, baseDir: baseDir) == nil,
              capturedSourceOnDisk(captureId, baseDir: baseDir)
                == CaptureSourceKind.omi.rawValue,
              let meta = ConversationMetaStore.load(
                captureId: captureId,
                baseDir: baseDir
              ),
              meta.endedAt == nil,
              meta.startedAt > 0 else { return false }
        let age = max(
            0,
            now.timeIntervalSince(
                Date(timeIntervalSince1970: TimeInterval(meta.startedAt))
            )
        )
        return age < silenceGap
    }

    /// The newest RESUMABLE capture on disk, or nil when a fresh conversation should be
    /// minted. Omi-continuity blueprint: a reconnect or app-relaunch WITHIN the silence
    /// gap continues the SAME conversation (same capture id) rather than fragmenting it —
    /// the 07-16 bug split one meeting into 5+ because every relaunch/reconnect minted a
    /// new id. Pure + disk-scanning so it works BEFORE the async hydration pass populates
    /// `captures`, and is unit-testable from a fixture directory.
    ///
    /// BOUNDED (watchdog-hang fix, review P1): it runs on the @MainActor at the exact Omi
    /// `.streaming` / relaunch instant, so — like `seedWarmListRows` after the earlier
    /// FRONTBOARD SIGKILL — it enumerates NAMES once, sorts newest-first by the id's
    /// embedded start time, inspects only the newest `resumeCandidateScanLimit` directories,
    /// and per candidate stats a SINGLE file (the newest segment by name). No per-segment
    /// stat storm. (Kept synchronous rather than hopping off-main: `onSourceState` is a
    /// @MainActor state machine, and an async hop would race a concurrent `.stopped` /
    /// mic-start against the resume decision — the strictly-bounded synchronous scan is the
    /// safer choice and is cheap enough.)
    ///
    /// A capture qualifies when its newest segment is younger than the silence gap (THE
    /// conversation boundary), or—before its first segment exists—when recent open metadata
    /// and an Omi source tag prove the segmentless session. It carries no terminal /
    /// in-flight marker (`.deleted`, `.discarded`, `.abandoned`, `.folding-*`, or
    /// `.ended-deliberately`) and is not confirmed-in-Lore; it is an AMBIENT/Omi capture
    /// (never a phone-mic recording—they share the `omi-` id prefix, so an Omi reconnect
    /// must not hijack a mic recording the user Stopped); and its end is orphan-stamped or
    /// absent, never a deliberate boundary. New builds tag the source + deliberate-end on
    /// disk; a legacy untagged capture is treated conservatively—resumable only if it never
    /// got any end (`endedAt == nil`).
    /// `resumingDevice` narrows the answer to captures THIS device recorded. It applies
    /// only where the answer is known — a capture carrying a device record that names a
    /// different device is skipped; one with no record is judged by the shipped rules
    /// below, unchanged. See `CaptureDeviceSidecar.mayContinue` for why the widening is
    /// gated on the record existing rather than on the device being supplied.
    public nonisolated static func resumableCaptureId(baseDir: URL,
                                                      now: Date = Date(),
                                                      silenceGap: TimeInterval,
                                                      resumingDevice: RecordingDeviceIdentity? = nil) -> String? {
        let fm = FileManager.default
        // Enumerate NAMES once (no property prefetch), newest-first by the id's embedded
        // start time (prefix-agnostic; ties fall back to name) — mirrors seedWarmListRows.
        let names = ((try? fm.contentsOfDirectory(atPath: baseDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { a, b in
                let ta = CaptureIdTime.startedAt(fromCaptureId: a) ?? 0
                let tb = CaptureIdTime.startedAt(fromCaptureId: b) ?? 0
                return ta != tb ? ta > tb : a > b
            }
        var inspected = 0
        for id in names {
            if inspected >= resumeCandidateScanLimit { break }
            let dir = baseDir.appendingPathComponent(id, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            inspected += 1   // bound the expensive work to real capture directories
            // Newest audio younger than the silence gap? (ONE stat via the by-name
            // shortcut.) Before the first chunk exists, the synchronous open metadata +
            // Omi source tag are the durable continuation proof.
            let recentAudio = newestSegmentMTimeByName(id, baseDir: baseDir)
                .map { now.timeIntervalSince($0) < silenceGap } ?? false
            guard recentAudio
                    || isRecentSegmentlessOpenOmiCapture(
                        id,
                        baseDir: baseDir,
                        now: now,
                        silenceGap: silenceGap
                    ) else { continue }
            // Terminal / in-flight / deliberate-end markers are never resumed.
            if isDeletedOnDisk(id, baseDir: baseDir) { continue }
            if isDiscardedOnDisk(id, baseDir: baseDir) { continue }
            if isEndedDeliberatelyOnDisk(id, baseDir: baseDir) { continue }
            if fm.fileExists(atPath: dir.appendingPathComponent(".abandoned").path) { continue }
            if TranscriptCacheStore.isConfirmedInLore(captureId: id, baseDir: baseDir) { continue }
            let marks = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            if marks.contains(where: { $0.hasPrefix(".folding-") }) { continue }
            // Device gate: a capture that RECORDS which device made it may only be
            // continued by that device. Without this, a second remembered device
            // reconnecting inside the silence gap would append its audio to the first
            // device's conversation and the archive's attribution would be a lie.
            if !CaptureDeviceSidecar.mayContinue(captureId: id, baseDir: baseDir,
                                                 device: resumingDevice) { continue }
            // Source gate: only an AMBIENT/Omi capture may be resumed by an Omi reconnect.
            let tag = capturedSourceOnDisk(id, baseDir: baseDir)
            if let tag, tag != CaptureSourceKind.omi.rawValue { continue }
            // Boundary gate: for an UNTAGGED (legacy) capture we can't tell an orphan end
            // from a deliberate one, so resume ONLY a true orphan that never got any end.
            // A TAGGED (new-build) capture that cleared `.ended-deliberately` above is an
            // orphan-stamped or never-ended Omi capture → resumable.
            if tag == nil,
               ConversationMetaStore.load(captureId: id, baseDir: baseDir)?.endedAt != nil { continue }
            // Newest-first ordering ⇒ the first qualifying candidate is the one to resume.
            return id
        }
        return nil
    }

    /// Delete a capture's `seg-*.opus` + `seg-*.ack`, keeping the dir + tombstone files.
    nonisolated static func deleteLocalAudioOnDisk(_ captureId: String, baseDir: URL) {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "opus" || f.pathExtension == "ack" {
            try? FileManager.default.removeItem(at: f)
        }
        // Segment files vanished underneath any (possibly not-yet-hydrated) WAL — drop its
        // durable status cache so the next warm rescans to the pruned (0-segment) truth.
        CaptureWAL.invalidateStatusCache(captureDir: dir)
    }

    /// Instance shim for the reconcile path — delegates to the nonisolated primitive.
    private func newestSegmentAge(_ captureId: String) -> TimeInterval? {
        Self.newestSegmentAgeOnDisk(captureId, baseDir: baseDir)
    }

    #if DEBUG
    /// -ConfirmProof offline-then-ack pacing: returns false on the first drain (keep the
    /// change PENDING so the glyph is observable), true afterwards (ACK → glyph clears).
    private nonisolated(unsafe) static var proofDrainCount = 0
    private static let proofDrainLock = NSLock()
    private static func proofDrainAdvance() -> Bool {
        proofDrainLock.lock(); defer { proofDrainLock.unlock() }
        proofDrainCount += 1
        return proofDrainCount > 1
    }
    #endif

    /// Ship any speaker-name confirms that couldn't reach the hub when the user made them
    /// (durable + offline-safe — mirrors the finalize/delete retry ethos). Stops on the
    /// first transport failure (hub still down) to avoid hammering; resumes next drain.
    public func retryPendingSpeakerConfirms() async {
        // The queue is a full-file read+rewrite; the shared drain keeps it OFF the main
        // actor so a drain never hangs the UI. LOCAL-FIRST (track 20260717T1600): on a
        // successful ACK the drain reconciles the canonical name/id into the cached
        // transcript (write-through) and posts the synced notification so the pending
        // glyph clears and any propagation offer surfaces; on a 4xx rejection it drops the
        // intent and posts the gentle revert; on a 401 it fires the SAME re-auth seam the
        // segment uploads use instead of silently 401-looping forever (observed
        // 2026-07-17, ExpiredSignature).
        let client = DoorClient(target: target)
        let base = baseDir
        #if DEBUG
        // -ConfirmProof offline-then-ack: the INTERACTIVE ship fails transport (instant
        // local save + glyph); the DRAIN then succeeds so the simulator can watch the glyph
        // clear on the ACK. The FIRST drain after launch is skipped so the pending glyph is
        // reliably observable for a full ~5s cycle before the ACK clears it (otherwise a
        // drain firing right after the tap could clear it before it's seen). Never active
        // outside DEBUG.
        let proofAck = ConfirmShip.proofMode == "offline-then-ack" && Self.proofDrainAdvance()
        #endif
        await SpeakerConfirmFlow.drainPending(
            baseDir: base,
            ship: { e in
                #if DEBUG
                if proofAck {
                    return ConfirmOutcome(captureId: e.captureId, slotLabel: e.slot,
                                          status: "confirmed",
                                          speakerId: e.speakerId ?? "proof-speaker",
                                          speakerName: e.name ?? "Nick", offeredCaptures: [])
                }
                #endif
                return try await client.confirmSpeaker(captureId: e.captureId, slot: e.slot,
                                                       speakerId: e.speakerId, name: e.name,
                                                       entityId: e.entityId)
            },
            onSynced: { e, outcome in
                await Task.detached {
                    TranscriptCacheStore.confirmSpeaker(
                        captureId: e.captureId, slot: e.slot,
                        name: outcome.speakerName.isEmpty ? e.name : outcome.speakerName,
                        speakerId: outcome.speakerId.isEmpty ? e.speakerId : outcome.speakerId,
                        baseDir: base)
                }.value
                await SpeakerConfirmSync.postSynced(outcome)
            },
            onRejected: { e in
                await SpeakerConfirmSync.postRejected(captureId: e.captureId, slot: e.slot, name: e.name)
            },
            onAuthExpired: { [weak self] in self?.handleUploadAuthExpired() })
    }

    /// Retry finalize for every capture still marked pending-finalize. Safe to call
    /// from the drain timer and on app-foreground (mirrors the WAL drain ethos).
    ///
    /// AUDITED alongside `retryPendingDeletes` (the build-286 main-thread hang). It shares
    /// PART of that shape and the audit is recorded here so nobody has to re-derive it:
    ///
    ///  * Main-actor disk: the selection is two `fileExists` calls per HYDRATED capture
    ///    (bounded by `maxCapturesToLoad`), not an unbounded base-dir walk, and `tryFinalize`
    ///    reads `card`/`meta` for the few captures that pass the gate. Unlike the delete lane
    ///    there is no `contentsOfDirectory` here, which is the syscall the field stallstack
    ///    actually caught.
    ///  * Serial network with no breaker: TRUE, but structurally bounded — finalize is gated
    ///    on `pendingSegments == 0`, so the exact condition that made the delete lane pay N
    ///    timeouts (an unreachable door) leaves segments un-ACK'd and gates these captures out
    ///    BEFORE any network call happens.
    ///  * No per-call timeout: FIXED — see the deadline in `tryFinalize`.
    ///
    /// Moving the selection off the main actor was TRIED and REVERTED: the extra suspension
    /// point between selecting and finalizing lets a concurrent drain tick interleave, and
    /// `CaptureSubstanceGateTests` went from 0/10 to 2/10 failures under CPU load. The ~600
    /// cheap stats it would have saved are not worth a real race in the finalize lane.
    public func retryPendingFinalizes() async {
        guard !accountExposureClosing,
              !accountExposureClosed,
              !Task.isCancelled else { return }
        for wal in captures where wal !== active && !isDeleted(wal.captureId) && isPendingFinalize(wal.captureId) {
            await tryFinalize(wal)
        }
    }

    // MARK: pending remote-delete lane (off-main, bounded, breakered)
    //
    // WHAT THIS LANE USED TO DO, AND WHY IT FROZE THE APP (build 286, owner's phone, 212
    // conversations; 8 MetricKit hangs 598–1939ms, nav-stall spans to 4161ms). The sampler
    // caught it directly:
    //
    //     stallstack ms=501 fr=libsystem_kernel.dylib+0x6844 ; Foundation+0x26ec8 ;
    //                FoundryX+0xb904c (retryPendingDeletes) ; libswift_Concurrency+0x53b4
    //
    // The owner had deleted many junk conversations and the desktop door was unreachable, so
    // every delete stayed pending and the lane — which the drain loop re-enters every 5s —
    //   (1) walked the WHOLE captures dir synchronously ON the main actor (the Foundation
    //       `getattrlistbulk` frame above), plus a `fileExists` per entry;
    //   (2) then serially awaited one UN-TIMEBOXED door call per pending delete;
    //   (3) then, on ACK, recursively removed each capture dir (audio included) ON main;
    //   with no batch bound and no breaker, so a down door cost N full network timeouts and
    //   the freeze RECURRED on every drain tick.
    //
    // The lane now:
    //   * derives the pending set ONCE per process, OFF the main actor, and maintains it in
    //     memory thereafter (`deleteConversation` is the only writer of `.needs-delete`), so a
    //     steady state costs zero syscalls;
    //   * attempts at most `maxPendingDeletesPerDrain` per cycle;
    //   * time-boxes every door call (`pendingDeleteCallTimeout`) instead of inheriting a
    //     30–60s URLSession/relay timeout;
    //   * STOPS the cycle on the first failure and backs the whole lane off on the SAME
    //     exponential schedule the upload drain uses (`retryDelay`), so an unreachable door
    //     costs one bounded call every backoff window rather than N timeouts every 5s;
    //   * tears the acknowledged tombstone down OFF the main actor.
    //
    // TOMBSTONE SEMANTICS ARE UNCHANGED, and that is non-negotiable: a delete is dequeued and
    // its directory removed ONLY after the door ACKs. Until then `.deleted` + `.needs-delete`
    // both remain on disk, so the row can never resurrect, and if the in-memory queue is ever
    // lost (crash, relaunch) the one-time seed scan re-derives it from those markers.

    /// At most this many pending remote-deletes are attempted per drain tick.
    public nonisolated static let maxPendingDeletesPerDrain = 5
    /// Wall-clock bound on ONE door delete. A few seconds — a delete that can't be reached
    /// fast is a delete that stays queued, not one the UI waits on.
    public nonisolated static let pendingDeleteCallTimeout: TimeInterval = 5
    /// Wall-clock bound on ONE finalize round trip. Generous (the door assembles + ingests
    /// behind it) and matched to the direct-LAN transport's own 60s timeout, so the point of
    /// the bound is to cap the RELAY leg, which had none.
    public nonisolated static let finalizeCallTimeout: TimeInterval = 60

    /// The pending remote-delete queue, held in MEMORY (seeded once from disk) so the drain
    /// never re-walks the captures dir. Order = FIFO by intent.
    private var pendingDeleteIds: [String] = []
    /// Whether the one-time, off-main seed scan has run for this manager.
    private var pendingDeleteSeeded = false
    /// Lane-wide breaker state — an unreachable door fails ALL of these identically, so the
    /// backoff belongs to the lane, not to each id (mirrors `retryStates` for uploads).
    private var deleteLaneRetry = RetryState()

    /// Queue a capture for remote deletion in memory (the durable `.needs-delete` marker is
    /// written by `markNeedsDelete`). Idempotent.
    private func enqueuePendingDelete(_ captureId: String) {
        guard !pendingDeleteIds.contains(captureId) else { return }
        pendingDeleteIds.append(captureId)
    }

    /// The one-time disk derivation of the pending set — the ONLY base-dir walk this lane ever
    /// does, and it runs OFF the main actor. `nonisolated static`: touches no actor state.
    nonisolated static func scanPendingDeleteIds(baseDir: URL) -> [String] {
        noteDeleteLaneDiskOp()   // 0 unless this ran on main — the pathology being pinned
        guard let entries = try? FileManager.default
            .contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil)
        else { return [] }
        return entries.compactMap { dir in
            let id = dir.lastPathComponent
            guard !id.hasPrefix("."), isPendingDeleteOnDisk(id, baseDir: baseDir) else { return nil }
            return id
        }.sorted()
    }

    /// Retry the durable remote-deletion intents. Bounded per cycle, time-boxed per call, and
    /// stopped + backed off on the first failure. Captures are deleted, never hydrated, so the
    /// queue is disk-derived once and then maintained in memory.
    public func retryPendingDeletes() async {
        if !pendingDeleteSeeded {
            let base = baseDir
            let onDisk = await Task.detached(priority: .utility) {
                Self.scanPendingDeleteIds(baseDir: base)
            }.value
            pendingDeleteSeeded = true
            // Union, not assign: a delete queued while the scan ran is already in memory.
            for id in onDisk { enqueuePendingDelete(id) }
        }
        guard !pendingDeleteIds.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        guard now >= deleteLaneRetry.nextEligible else { return }   // breaker OPEN — door is down

        let base = baseDir
        // An explicit snapshot: the loop dequeues from `pendingDeleteIds` as it ACKs.
        let batch = Array(pendingDeleteIds.prefix(Self.maxPendingDeletesPerDrain))
        for id in batch {
            do {
                Self.noteRemoteDeleteAttempt()
                let remote = deleteCaptureRemote
                try await AsyncDeadline.race(Self.pendingDeleteCallTimeout) {
                    try await remote(id)
                }
            } catch {
                // The door is unreachable / failing. STOP this cycle — the remaining intents
                // would each pay the same bounded timeout for nothing — and back the lane off
                // so subsequent drain ticks are free. NOTHING is dequeued: both markers stay.
                deleteLaneRetry.failures += 1
                deleteLaneRetry.nextEligible =
                    now + CaptureManager.retryDelay(forFailures: deleteLaneRetry.failures)
                log?.warn("capture \(id): remote delete failed (\((error as NSError).localizedDescription)) — " +
                          "staying pending; \(pendingDeleteIds.count) queued, lane backing off")
                return
            }
            // ACKed → safe to dequeue and tear the tombstone down (OFF the main actor). If the
            // teardown fails the markers survive and the next launch's seed scan re-queues it.
            pendingDeleteIds.removeAll { $0 == id }
            deleteLaneRetry = RetryState()
            let dir = base.appendingPathComponent(id, isDirectory: true)
            await Task.detached(priority: .utility) {
                CaptureManager.noteDeleteLaneDiskOp()
                try? FileManager.default.removeItem(at: dir)
            }.value
            log?.info("capture \(id): remote delete acknowledged; local tombstone removed")
        }
    }

    /// Test seams (deterministic, `@testable`-only — mirrors the `*ForTests` idiom): the lane's
    /// queue depth (proves nothing is dropped while the door is down), and a way to say "the
    /// backoff window elapsed" without a real drain having to wait it out.
    var pendingDeleteQueueDepthForTests: Int { pendingDeleteIds.count }
    func expirePendingDeleteBackoffForTests() { deleteLaneRetry.nextEligible = 0 }

    // MARK: persistence (resume across launches)

    /// Hydrate the timeline from disk — SYNCHRONOUS so a launch/resume sees its captures
    /// immediately, but BOUNDED so it can't overrun the launch watchdog. We enumerate names
    /// only (one cheap bulk syscall), walk them newest-first, skip discarded junk fragments,
    /// and STOP after hydrating `maxCapturesToLoad` — so launch work is O(cap), never O(all
    /// folders on disk). A large backlog of discarded fragments used to be hydrated in full
    /// on the main thread and SIGKILL'd the app (FRONTBOARD watchdog). Old discarded folders
    /// are reclaimed separately, off the launch path (`pruneDiscardedFragments`).
    /// Seed the scan-free warm list so the Capture home paints POPULATED on the very first
    /// frame — WITHOUT re-introducing the launch-time segment-scan hang (T1 AC5). This
    /// enumerates directory NAMES once (one cheap bulk syscall, same as `loadExisting`),
    /// takes the newest `warmSeedCount`, and reads each capture's `card.json` (title +
    /// durable start) — NO `CaptureWAL`/`makeWAL`, NO per-segment stat storm (the per-WAL
    /// segment scan is now lazy — `CaptureWAL.warmStatus` off the first-paint path — and
    /// this never touches it). Bounded to a first screen, so the work is O(first-screen small
    /// JSON reads), never O(all folders × all segments). The off-main WAL hydration then
    /// replaces these with the real cards + their status pollers.
    private func seedWarmListRows() {
        // FAST PATH (T3, WS-B): read the persisted warm-rows index — ONE synchronous file
        // decode — instead of enumerating the ENTIRE captures dir (thousands of entries incl.
        // `.discarded` junk) + 3 `fileExists` + a `card.json` read per row on the main actor at
        // startup (first-paint 495ms avg / 2722ms max @ N=128 on device). A bounded
        // (O(warmSeedCount)) filter drops any row deleted/discarded since the index was written,
        // so a stale index never shows a removed conversation. Empty after filtering ⇒ fall
        // through to the scan (rare all-deleted top-N). Off-main hydration then corrects/replaces.
        if let indexed = WarmListIndexStore.load(baseDir: baseDir) {
            let fm = FileManager.default
            let rows = indexed.filter { row in
                let dir = baseDir.appendingPathComponent(row.captureId, isDirectory: true)
                var isDir: ObjCBool = false
                // Dir gone entirely (remote-delete ACK removed it) OR tombstoned → filter it out.
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return false }
                if fm.fileExists(atPath: dir.appendingPathComponent(".deleted").path) { return false }
                if fm.fileExists(atPath: dir.appendingPathComponent(".discarded").path) { return false }
                return true
            }
            if !rows.isEmpty { listRows = rows; return }
        }
        seedWarmListRowsByScan()
    }

    /// Index-MISS fallback (first launch after update): the original enumeration path. Bounded to
    /// a first screen, so the work is O(first-screen small JSON reads), never O(all folders).
    private func seedWarmListRowsByScan() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil)
        else { return }
        // Newest-first by the capture id's embedded start time (prefix-agnostic — a
        // non-`omi-` id would sort wrong under a raw lexicographic name sort). Cheap:
        // derived from the id string, no card.json read. Ties/unparseable fall back to name.
        let names = entries.map { $0.lastPathComponent }
            .filter { !$0.hasPrefix(".") }
            .sorted { a, b in
                let ta = CaptureIdTime.startedAt(fromCaptureId: a) ?? 0
                let tb = CaptureIdTime.startedAt(fromCaptureId: b) ?? 0
                return ta != tb ? ta > tb : a > b
            }
        var rows: [ConversationRowLite] = []
        rows.reserveCapacity(Self.warmSeedCount)
        for name in names {
            if rows.count >= Self.warmSeedCount { break }
            let dir = baseDir.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if fm.fileExists(atPath: dir.appendingPathComponent(".discarded").path) { continue }
            if fm.fileExists(atPath: dir.appendingPathComponent(".deleted").path) { continue }
            // Title + date from card.json only (no segment scan). Skip captures without a
            // card tombstone — they simply appear once the off-main WAL hydration lands.
            guard let card = ConversationCardStore.load(captureId: name, baseDir: baseDir) else { continue }
            let started = card.startedAt ?? CaptureIdTime.startedAt(fromCaptureId: name) ?? 0
            let title = (card.title?.isEmpty == false) ? card.title! : "Voice note"
            rows.append(ConversationRowLite(
                captureId: name, title: title, dateLabel: Self.warmDateLabel(started)))
        }
        listRows = rows
    }

    /// A compact "when" label for a scan-free seed row (the full time·place·duration meta
    /// arrives with the real card).
    private nonisolated static func warmDateLabel(_ startedAt: UInt64) -> String {
        guard startedAt > 0 else { return "" }
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d · h:mm a"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(startedAt)))
    }

    private func loadExisting() {
        // Hydration runs off the main actor in TWO phases so first paint never waits on
        // the per-segment scan (launch-hang fix, 2026-07-16):
        //   1. FAST SWAP — enumerate the library and construct each `CaptureWAL` CHEAPLY
        //      (the segment scan is now LAZY, see CaptureWAL), then append once. This is
        //      the `capture-hydrate` span, and it's what unblocks the list's warm-seed ->
        //      real-card swap. Constructing 300 WALs used to EAGERLY scan every segment
        //      dir here (6–11s `capture-hydrate` on backlogged phones), stranding the list
        //      on its warm seed for seconds.
        //   2. WARM — off-main, off the first-paint path: `warmStatus()` runs the deferred
        //      scan per WAL to fill in true segment/sync counts, then the startup work that
        //      NEEDS those counts (orphan reconcile, retention). A moment behind the swap.
        let base = baseDir
        hydration = Task.detached(priority: .userInitiated) { [weak self] in
            // Measure the FAST construction phase (perf span "capture-hydrate") so a
            // launch-cost regression greps out of fleet telemetry as SLOW.
            let span = PerfSpan(name: "capture-hydrate")
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            else { return }
            let names = entries.map { $0.lastPathComponent }
                .filter { !$0.hasPrefix(".") }
                .sorted(by: >)   // ids are timestamp-prefixed -> newest first
            var picked: [String] = []
            picked.reserveCapacity(Self.maxCapturesToLoad)
            for name in names {
                if picked.count >= Self.maxCapturesToLoad { break }
                let dir = base.appendingPathComponent(name, isDirectory: true)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                // Discarded junk fragments are never shown or finalized — don't hydrate them.
                if fm.fileExists(atPath: dir.appendingPathComponent(".discarded").path) { continue }
                if fm.fileExists(atPath: dir.appendingPathComponent(".deleted").path) { continue }
                picked.append(name)
            }
            guard let self else { return }
            // Phase 1 — cheap WAL construction (no segment scan). The list swaps to real
            // cards the instant this appends; titles/summaries come scan-free from card.json.
            let hydrated = picked.map { self.makeWAL(captureId: $0) }
            let ms = span.elapsedMs()   // capture-hydrate = WAL construction ONLY (unchanged)
            // R3 — seed the per-capture sidecar (+meta) memo OFF the main actor, under its
            // OWN span (NOT matching capture-hydrate* — the budget-grep rule), so the didSet
            // rebuild that fires on `captures.append` reads a WARM cache (memory), not disk.
            // This is the work that previously ran ON the main actor inside every rebuild.
            let seedSpan = PerfSpan(name: "capture-sidecar-seed")
            var seededSidecars: [String: SidecarSnapshot] = [:]
            var seededMeta: [String: ConversationMeta?] = [:]
            // Seed the DURABLE START too (requirement 6): the sort comparator's
            // `startTimeCache` was previously seeded nowhere, so the first post-hydration
            // sort cold-missed every capture into a main-actor `meta.json`/`card.json`
            // decode (370ms / 175 decodes at N=175). Resolved HERE, off-main, from the same
            // meta → card → capture-id order `durableStart` uses.
            var seededStarts: [String: TimeInterval] = [:]
            seededSidecars.reserveCapacity(picked.count)
            seededMeta.reserveCapacity(picked.count)
            seededStarts.reserveCapacity(picked.count)
            for id in picked {
                let snap = Self.loadSidecar(captureId: id, baseDir: self.baseDir)
                let meta = ConversationMetaStore.load(captureId: id, baseDir: self.baseDir)
                seededSidecars[id] = snap
                seededMeta[id] = meta
                if let started = meta?.startedAt, started > 0 {
                    seededStarts[id] = TimeInterval(started)
                } else if let started = snap.cardStartedAt, started > 0 {
                    seededStarts[id] = TimeInterval(started)
                } else if let idStart = CaptureIdTime.startedAt(fromCaptureId: id), idStart > 0 {
                    seededStarts[id] = TimeInterval(idStart)
                }
            }
            let seedMs = seedSpan.elapsedMs()
            await MainActor.run {
                // Seed BEFORE append so the append's didSet rebuild hits the warm cache.
                // Keep any entry the main actor already wrote during the async gap (a
                // capture started mid-hydration) — the disk seed must not clobber live state.
                // A PLACEHOLDER (`isWarm == false`, written by a pre-hydration rebuild that
                // cold-missed) must NOT beat the disk seed — only a genuinely warm entry the
                // main actor already holds wins.
                // S5 — a MARKED entry always wins too, warm or not. `applySidecarMarker`
                // builds from `.unwarmed` and `marking()` keeps `isWarm: false`, so an
                // `isWarm`-only rule let a delete/discard that landed DURING the (off-main,
                // whole-library) seed loop be overwritten by the pre-delete seeded snapshot:
                // the just-deleted conversation reappeared and then vanished again when the
                // confirming re-warm landed.
                self.sidecarCache.merge(seededSidecars) { current, seeded in
                    (current.isWarm || current.isDeleted || current.isDiscarded) ? current : seeded
                }
                self.metaCache.merge(seededMeta) { current, _ in current }
                self.startTimeCache.merge(seededStarts) { current, _ in current }
                // A capture STARTED before hydration finished sits at index 0
                // (newest); the hydrated backlog appends behind it — order holds.
                // S5 — `picked` was chosen off-main BEFORE this hop, so a capture the user
                // deleted (or the manager discarded) during the seed loop is still in it.
                // Re-appending its WAL would resurrect the row; drop it here.
                let live = hydrated.filter { wal in
                    let snap = self.sidecarCache[wal.captureId]
                    return !(snap?.isDeleted ?? false) && !(snap?.isDiscarded ?? false)
                }
                self.captures.append(contentsOf: live)   // one didSet -> one rebuild; swaps NOW
            }
            PerfHook.span("capture-hydrate-n\(hydrated.count)", ms: ms)
            PerfHook.span("capture-sidecar-seed-n\(picked.count)", ms: seedMs)

            // Phase 2 — WARM the statuses (the deferred per-segment scan) OFF the first-paint
            // path, then the startup work that needs true counts. Under its OWN span so the
            // moved work stays visible in telemetry WITHOUT counting against the hydrate
            // budget (the harness matches `capture-hydrate*`, not `capture-status-warm*`).
            let warm = PerfSpan(name: "capture-status-warm")
            // Compute every capture's warm status HERE, off the main actor, into a batch —
            // then apply the whole batch in the SINGLE main-actor hop below. The old
            // `for wal in hydrated { wal.warmStatus() }` published each status via its own
            // `DispatchQueue.main.async`, flooding the main thread with N @Published writes
            // (N SwiftUI card invalidations) in a burst — the `capture-status-warm-n<N>`
            // main-thread stall on a big library. One batched apply = one runloop tick =
            // one coalesced list diff. (warmedSnapshot does the cache-hit-or-scan off-main.)
            let warmed: [(CaptureWAL, CaptureStatus)] = hydrated.map { ($0, $0.warmedSnapshot()) }
            // Retention sweep ALSO off the main actor (was a startup main-thread hang).
            let retention = Self.retentionSweep(ids: picked, baseDir: self.baseDir)
            let warmMs = warm.elapsedMs()
            if let hydrationBeforeCommit = self.hydrationBeforeCommit {
                await hydrationBeforeCommit()
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !self.accountExposureClosing,
                      !self.accountExposureClosed else { return }
                // R4 — the startup main-actor TAIL (orphan reconcile + retention apply +
                // rebuild + widget seed) was invisible (capture-status-warm stops before this
                // hop). Measure it under its own span so any residual main-thread cost shows.
                let finishSpan = PerfSpan(name: "capture-startup-finish")
                // Apply all warmed statuses in this ONE tick; each is a no-op unless it
                // actually changed the capture's status (publish() skips equal writes).
                for (wal, s) in warmed { wal.applyWarmedStatus(s) }
                self.pruneDiscardedFragments()
                self.finishStartupAfterHydration(retention: retention)
                self.rebuildVisibleCaptures()   // reflect warmed counts (banner/stats/orphan prune)
                PerfHook.span("capture-startup-finish-n\(hydrated.count)", ms: finishSpan.elapsedMs())
            }
            PerfHook.span("capture-status-warm-n\(hydrated.count)", ms: warmMs)
        }
    }

    /// The startup hydration task — awaitable so tests (and callers that need the
    /// resumed timeline) can join it instead of assuming a synchronous load.
    public private(set) var hydration: Task<Void, Never>?

    /// Reclaim discarded junk-fragment folders older than `discardedRetention`, OFF the main
    /// thread so it never touches launch latency. The audio was never uploaded and is not
    /// shown; keeping tens of thousands of tiny folders forever only bloats the container and
    /// slows every launch enumeration.
    private func pruneDiscardedFragments() {
        guard !accountExposureClosing, !accountExposureClosed else { return }
        let base = baseDir
        let retention = Self.discardedRetention
        let beforeDelete = discardedPruneBeforeDelete
        let taskID = UUID()
        let installed = CaptureManagerTaskInstallationGate()
        let task = Task.detached(priority: .background) { [weak self] in
            await installed.wait()
            let fm = FileManager.default
            if let entries = try? fm.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: nil) {
                let now = Date()
                for url in entries {
                    if Task.isCancelled { break }
                    let marker = url.appendingPathComponent(".discarded")
                    guard fm.fileExists(atPath: marker.path) else { continue }
                    let values = try? marker.resourceValues(
                        forKeys: [.contentModificationDateKey])
                    let m = values?.contentModificationDate
                    if Task.isCancelled { break }
                    if let m, now.timeIntervalSince(m) > retention {
                        if let beforeDelete { await beforeDelete(url) }
                        guard !Task.isCancelled else { break }
                        let exposureOpen = await MainActor.run { [weak self] in
                            guard let self else { return false }
                            return !self.accountExposureClosing
                                && !self.accountExposureClosed
                        }
                        guard exposureOpen else { break }
                        try? fm.removeItem(at: url)
                    }
                }
            }
            await MainActor.run {
                self?.discardedFragmentPruneTasks[taskID] = nil
            }
        }
        discardedFragmentPruneTasks[taskID] = task
        installed.open()
    }

    // nonisolated: pure (formatter + UUID) — also minted off-main by the
    // background-restoration spool (OmiRestorationSpool).
    nonisolated static func newCaptureId() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        let stamp = f.string(from: Date())
        return "omi-\(stamp)-\(String(UUID().uuidString.prefix(8)))"
    }
}

/// The user's durable AMBIENT-capture intent across launches: are we listening, or
/// did the user pause? Persisted so a paused Omi stays paused after a full app
/// restart instead of silently auto-capturing on reconnect.
public enum OmiCaptureDesiredState: String, Sendable {
    case listening
    case paused
}

/// Immutable capture-runtime preferences resolved for one account generation.
/// Task 6 installs this once into each capture owner after active publication.
public struct CaptureAccountPreferenceSnapshot: Sendable, Equatable {
    public let binding: CaptureAccountScope.AccountBinding
    public let silenceGapSeconds: TimeInterval
    public let omiDesiredState: OmiCaptureDesiredState
    public let sourceEnabledOverrides: [String: Bool]

    public init(
        binding: CaptureAccountScope.AccountBinding,
        silenceGapSeconds: TimeInterval,
        omiDesiredState: OmiCaptureDesiredState,
        sourceEnabledOverrides: [String: Bool]
    ) {
        self.binding = binding
        self.silenceGapSeconds = silenceGapSeconds
        self.omiDesiredState = omiDesiredState
        self.sourceEnabledOverrides = sourceEnabledOverrides
    }
}

/// Persisted capture preferences (UserDefaults). The silence-gap that drives
/// auto-segmentation (req 9; default ~2 min, à la Omi), the chosen capture source,
/// and the durable pause/listen intent restored on launch.
public enum CaptureSettings {
    public static let defaultGapSeconds: TimeInterval = 120

    public static var silenceGapSeconds: TimeInterval {
        get {
            switch AccountPreferences.read(
                AccountPreferenceCatalog.captureSilenceGapSeconds)
            {
            case .value(let value) where value > 0: return value
            case .value: return defaultGapSeconds
            case .absent: return defaultGapSeconds
            }
        }
        set {
            _ = AccountPreferences.write(
                newValue,
                for: AccountPreferenceCatalog.captureSilenceGapSeconds)
        }
    }

    private static let sourceKey = "foundryx.capture.source"

    /// The chosen capture device (Omi by default — today's behavior). Persisted.
    public static var captureSource: CaptureSourceKind {
        get { CaptureSourceKind(rawValue: UserDefaults.standard.string(forKey: sourceKey) ?? "") ?? .omi }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sourceKey) }
    }

    /// The account's last ambient-capture intent. Fresh and signed-out snapshots
    /// materialize `.paused`; established owners adopt an explicit legacy choice.
    public static var omiCaptureDesiredState: OmiCaptureDesiredState {
        get {
            switch AccountPreferences.read(
                AccountPreferenceCatalog.captureOMIDesiredState)
            {
            case .value(let raw):
                return OmiCaptureDesiredState(rawValue: raw) ?? .paused
            case .absent: return .paused
            }
        }
        set {
            _ = AccountPreferences.write(
                newValue.rawValue,
                for: AccountPreferenceCatalog.captureOMIDesiredState)
        }
    }

    /// Normal/fresh/signed-out active snapshot. This is cache-only and performs
    /// no identity or defaults resolution on frame delivery.
    public static func snapshot(
        binding: CaptureAccountScope.AccountBinding
    ) -> CaptureAccountPreferenceSnapshot {
        let gap: TimeInterval
        switch AccountPreferences.read(
            AccountPreferenceCatalog.captureSilenceGapSeconds) {
        case .value(let value) where value > 0: gap = value
        default: gap = defaultGapSeconds
        }
        let desired: OmiCaptureDesiredState
        switch AccountPreferences.read(
            AccountPreferenceCatalog.captureOMIDesiredState) {
        case .value(let raw):
            desired = OmiCaptureDesiredState(rawValue: raw) ?? .paused
        case .absent:
            desired = .paused
        }
        let overrides: [String: Bool]
        switch AccountPreferences.read(
            AccountPreferenceCatalog.captureSourceEnabledOverrides) {
        case .value(let value): overrides = value
        case .absent: overrides = [:]
        }
        return CaptureAccountPreferenceSnapshot(
            binding: binding,
            silenceGapSeconds: gap,
            omiDesiredState: desired,
            sourceEnabledOverrides: overrides)
    }

    /// Resolve the three dormant capture-runtime catalog entries through the
    /// shipped compatibility adapter. Invalid legacy values retain today's
    /// defaults; no scoped preference branch is activated here.
    public static func snapshot(
        compatibility: AccountPreferenceCompatibilityStore,
        binding: CaptureAccountScope.AccountBinding
    ) -> CaptureAccountPreferenceSnapshot {
        let gap: TimeInterval
        switch compatibility.read(
            AccountPreferenceCatalog.captureSilenceGapSeconds)
        {
        case .value(let value) where value > 0:
            gap = value
        default:
            gap = defaultGapSeconds
        }

        let desired: OmiCaptureDesiredState
        switch compatibility.read(
            AccountPreferenceCatalog.captureOMIDesiredState)
        {
        case .value(let raw):
            desired = OmiCaptureDesiredState(rawValue: raw) ?? .listening
        case .absent:
            desired = .listening
        }

        let overrides: [String: Bool]
        switch compatibility.read(
            AccountPreferenceCatalog.captureSourceEnabledOverrides)
        {
        case .value(let value):
            overrides = value
        case .absent:
            overrides = [:]
        }

        return CaptureAccountPreferenceSnapshot(
            binding: binding,
            silenceGapSeconds: gap,
            omiDesiredState: desired,
            sourceEnabledOverrides: overrides)
    }
}

#if canImport(AVFoundation)
/// Thread-safe holder for the CURRENT live transcriber, so the off-main frame tap
/// (serial source queue) can feed decoded PCM without touching main-actor state. The
/// CaptureManager swaps the held transcriber on the main actor at conversation
/// boundaries; the frame path only ever calls `append`.
final class CurrentLiveTranscriber: @unchecked Sendable {
    private let lock = NSLock()
    private var transcriber: LiveTranscribing?
    func set(_ t: LiveTranscribing?) { lock.lock(); transcriber = t; lock.unlock() }
    func append(_ pcm: AVAudioPCMBuffer) {
        lock.lock(); let t = transcriber; lock.unlock()
        t?.append(pcm)
    }
}
#endif
