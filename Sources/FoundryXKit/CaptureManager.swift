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

/// Lock-guarded routing of frames → the active WAL, gated by pause. Lives off the
/// main actor so the source's frame callback never hops actors per frame. Also the
/// single tap point for the audio-level signal: per frame it computes the cheap
/// level (→ the meter) and feeds the silence segmenter (→ conversation boundaries),
/// all under the same lock so order is preserved and pause freezes everything.
final class FrameRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var wal: CaptureWAL?
    private var paused = false
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
        wal = w
        if w != nil { sessionVoicedFrames = 0; lastVoicedAt = nil }   // fresh session → reset tallies
        lock.unlock()
    }
    /// Voiced frames captured for the current session (drives the min-substance upload gate).
    func sessionVoicedFrameCount() -> Int { lock.lock(); defer { lock.unlock() }; return sessionVoicedFrames }
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
        let isPaused = paused
        // Count only frames we actually CAPTURE. When paused the BLE source still
        // delivers frames (we drop them), but the counter must FREEZE so a paused
        // capture doesn't look like it's still recording.
        if !isPaused {
            frameCount += 1
            lastBytes = frame.count
        }
        let target = isPaused ? nil : wal
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
    /// in `loadExisting`). Seeded synchronously in `init`; the Capture list renders these
    /// populated rows immediately and swaps to the real WAL cards the instant off-main
    /// hydration publishes `visibleCaptures` (which clears this).
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
                && snap.bestTranscriptText == nil
                && !snap.confirmedInLore
        }.count
        statsSummary = makeStatsSummary(for: visible)
        persistWarmListIndexIfChanged(from: visible)
    }

    /// The captureIds last written to the warm-rows index — so a rebuild that didn't change the
    /// top-N set skips the (off-main) rewrite.
    private var lastIndexedIds: [String] = []

    /// Persist the top `warmSeedCount` warm rows to the durable single-file index (T3, WS-B),
    /// OFF the main actor, whenever the top-N set changes (a new/reordered conversation, or the
    /// first hydration). The main actor only snapshots ids + memoised durable starts; the
    /// detached task reads each card + writes the file. A slightly-stale title is tolerated — the
    /// real cards replace these rows the instant hydration publishes `visibleCaptures`.
    private func persistWarmListIndexIfChanged(from visible: [CaptureWAL]) {
        guard !visible.isEmpty else { return }
        let snapshot: [(id: String, started: UInt64)] = visible.prefix(Self.warmSeedCount).map {
            ($0.captureId, UInt64(max(0, startTime(of: $0))))
        }
        let ids = snapshot.map(\.id)
        guard ids != lastIndexedIds else { return }
        lastIndexedIds = ids
        let base = baseDir
        Task.detached(priority: .utility) {
            var rows: [ConversationRowLite] = []
            rows.reserveCapacity(snapshot.count)
            for s in snapshot {
                let card = ConversationCardStore.load(captureId: s.id, baseDir: base)
                let started = card?.startedAt ?? s.started
                let title = (card?.title?.isEmpty == false) ? card!.title! : "Conversation"
                rows.append(ConversationRowLite(captureId: s.id, title: title,
                                                dateLabel: CaptureManager.warmDateLabel(started)))
            }
            WarmListIndexStore.save(rows, baseDir: base)
        }
    }

    /// Test seam: force a visible-list rebuild WITHOUT any invalidation, so a test can prove
    /// the rebuild reads the per-capture sidecar MEMO and not disk (in production a `captures`
    /// mutation is the trigger). Internal — reachable only via `@testable import`.
    func rebuildVisibleCapturesForTests() { rebuildVisibleCaptures() }

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
        // Both inputs come from MEMORY: meta from the metaCache (warmed at hydration,
        // invalidated on every meta write), transcript from the sidecar memo's stripped
        // stats transcript (text + speakers + extra-slot stubs — byte-identical word +
        // distinct-speaker counts without retaining the heavy segment/paragraph arrays).
        let snapshots = visible.map { wal in
            StatsConversationSnapshot(
                captureId: wal.captureId,
                meta: conversationMeta(for: wal.captureId),
                transcript: sidecar(for: wal.captureId).statsTranscript
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
        if let text = snap.bestTranscriptText {
            return ConversationContentFilter.isMeaningful(
                transcript: text, durationSeconds: conversationDurationSeconds(id))
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
        guard let dur = conversationMeta(for: captureId)?.durationSeconds else { return nil }
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
        if let t = durableStart(captureId: wal.captureId) {
            startTimeCache[wal.captureId] = t
            return t
        }
        return wal.status.startedAt.timeIntervalSince1970
    }

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
    public func hasCachedTranscript(_ captureId: String) -> Bool {
        TranscriptCacheStore.hasCachedTranscript(captureId: captureId, baseDir: baseDir)
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
    @Published public private(set) var active: CaptureWAL?

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
    /// Silence gap (seconds) that auto-ends a conversation (req 9). Persisted.
    @Published public private(set) var silenceGapSeconds: TimeInterval

    /// The live, on-device PROVISIONAL transcript for the ACTIVE conversation
    /// (Feature 1). An ephemeral PREVIEW only — it empties when no conversation is
    /// open, and the AUTHORITATIVE transcript still comes from Kiln (door → Lore →
    /// Kiln). Stays `.empty` when live transcription is unavailable (older OS / no
    /// model / no factory wired), so the UI simply shows nothing extra.
    @Published public private(set) var liveTranscript: LiveTranscript = .empty
    /// True while the retry/drain loop is actively trying to move local work toward
    /// the desktop (segment upload, finalize retry, or delete retry). The sync banner
    /// uses this instead of equating "unsynced bytes exist" with "a drain is in flight".
    @Published public private(set) var drainActive = false

    /// Number of bars in the meter window (~4s at the 12 Hz sample tick).
    public static let meterBarCount = 48

    private let target: DoorTarget
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

    /// Whether a phone-mic source is wired (drives the Record control's availability).
    public var phoneMicAvailable: Bool { micSource != nil }
    /// True while the phone mic is actively recording (drives the Record/Stop button).
    @Published public private(set) var isRecordingMic: Bool = false
    /// Whether the user MINIMIZED the full-screen recording surface (recording keeps
    /// running; the app becomes reachable again and the persistent pill offers the way
    /// back). Reset to false whenever a fresh recording STARTS and whenever one is
    /// explicitly STOPPED/ended, so a new recording always presents full-screen.
    @Published public private(set) var recordingScreenMinimized = false
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
    @Published public private(set) var recordingCandidates: [AmbientCandidate] = []
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
    private var drainTimer: Timer?
    private var meterTimer: Timer?

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

    /// Discarded junk fragments (`.discarded`) kept on disk beyond this age are pruned — the
    /// audio was never uploaded and is not shown, so retaining tens of thousands of tiny
    /// folders forever only bloats the container + slows launch enumeration. A short window
    /// preserves recent auditability without unbounded accumulation.
    public nonisolated static let discardedRetention: TimeInterval = 2 * 24 * 60 * 60   // 2 days

    /// Per-capture upload retry state (consecutive failures + earliest next attempt).
    private struct RetryState { var failures = 0; var nextEligible: TimeInterval = 0 }
    private var retryStates: [String: RetryState] = [:]

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

    /// A held-open Omi conversation awaiting a possible reconnect (its WAL + when the
    /// disconnect happened, in reference-date seconds — the same clock as `lastVoicedInstant()`
    /// so the silence-boundary check compares on one clock). Non-nil ⇒ `active` is SUSPENDED,
    /// not ended: a reconnect before `SilenceSegmenter.defaultSilenceGap` of voiced silence
    /// resumes it (same captureId), else `resolveReconnectGrace` ends it at the real boundary.
    private var suspendedSession: (wal: CaptureWAL, at: TimeInterval)?

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
    #if canImport(AVFoundation)
    /// Thread-safe holder so the off-main frame path can feed the CURRENT transcriber
    /// without touching main-actor state (the frame tap runs on the serial source queue).
    private let liveBox = CurrentLiveTranscriber()
    #endif

    /// Test seam: override the per-segment door upload for every WAL this manager
    /// builds (so the bounded-retry / backoff / abandon / re-auth paths are exercised
    /// deterministically without a live door). nil ⇒ the real door POST.
    private let uploadSegment: (@Sendable (String, UInt64, Data) async throws -> Void)?

    public init(target: DoorTarget,
                baseDir: URL? = nil,
                log: DoorLog? = nil,
                source: AudioFrameSource,
                micSource: AudioFrameSource? = nil,
                finalize: (@Sendable (String, ConversationMeta?) async throws -> Void)? = nil,
                deleteCapture: (@Sendable (String) async throws -> Void)? = nil,
                fetchContent: (@Sendable (String) async -> CaptureContent?)? = nil,
                fetchSegments: (@Sendable (String) async throws -> [UInt64]?)? = nil,
                locationProvider: ConversationLocationProviding? = nil,
                liveTranscriber: LiveTranscriberFactory? = nil,
                uploadSegment: (@Sendable (String, UInt64, Data) async throws -> Void)? = nil) {
        self.target = target
        self.uploadSegment = uploadSegment
        self.makeLiveTranscriber = liveTranscriber
        self.baseDir = baseDir ?? CaptureWAL.documentsCaptures()
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
        // app restart must come back paused — not silently capturing. First-ever launch
        // (no stored value) defaults to `.listening` (today's behavior). beginSession()
        // re-applies this via router.setPaused(isPaused) on the next (re)connect, so a
        // paused desired-state means the Omi connects but stays paused.
        self.isPaused = (CaptureSettings.omiCaptureDesiredState == .paused)
        self.meter = AudioMeterModel(barCount: Self.meterBarCount)
        self.router = FrameRouter(segmenter: SilenceSegmenter(silenceGap: gap))
        // Frame path: serial source queue → router → WAL io queue. No main hop.
        source.onFrame = { [router] frame in router.route(frame) }
        source.onState = { [weak self] state in
            Task { @MainActor in self?.onSourceState(state) }
        }
        // The phone mic feeds the SAME router + the SAME lifecycle handler — it's just
        // another frame source. Its `.streaming`/`.stopped` begin/end a session exactly
        // like the Omi's, so capture id / finalize / live transcription are identical.
        micSource?.onFrame = { [router] frame in router.route(frame) }
        micSource?.onState = { [weak self] state in
            Task { @MainActor in self?.onSourceState(state) }
        }
        // Level tap (off-main, cheap) + silence-gap boundaries (→ main to rotate).
        router.onLevel = { [levelBuffer] lvl in levelBuffer.record(lvl) }
        router.onSegment = { [weak self] event in
            Task { @MainActor in self?.handleSegment(event) }
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
        firstPaintSpan = PerfSpan(name: "capture-list-first-paint")  // arm time-to-first-row
        firstPaintPending = true
        seedWarmListRows()     // scan-free first-paint rows (T1 AC5) — before the off-main hydrate
        loadExisting()         // OFF-MAIN hydration; finishes via finishStartupAfterHydration
        startDrainTimer()
        startSegmentTimer()    // wall-clock silence + runaway force-split watchdog
        // OUT-OF-MANAGER sidecar writes (the detail view's content cache re-saves
        // transcript.json + card.json on a fetch/speaker-confirm) invalidate the memo via a
        // notification, so the next rebuild reflects them (track 20260717T0448).
        sidecarObserver = NotificationCenter.default.addObserver(
            forName: .foundryxSidecarChanged, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["captureId"] as? String else { return }
            MainActor.assumeIsolated {
                self?.invalidateSidecar(id)
                self?.scheduleSidecarRebuild()
            }
        }
    }

    /// The `.foundryxSidecarChanged` observer token — removed in deinit so a torn-down
    /// manager (each test builds a fresh one) leaves no dangling registration.
    private nonisolated(unsafe) var sidecarObserver: NSObjectProtocol?

    deinit {
        if let sidecarObserver { NotificationCenter.default.removeObserver(sidecarObserver) }
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
        CaptureWidgetSnapshotStore.write(makeWidgetSnapshot())
        reloadWidgetTimelines()
    }

    /// Memoised meta.json loads: the timeline re-reads conversationMeta up to 3× per
    /// row per render (deep-review perf finding). Meta is written only through the
    /// manager's own recordStart/recordEnd call sites, which invalidate the entry —
    /// so rendering is memory-only after the first load. `.some(nil)` memoises the
    /// "no meta on disk" answer too (pre-F1 captures would otherwise re-stat forever).
    private var metaCache: [String: ConversationMeta?] = [:]

    /// Drop a capture's memoised meta after writing meta.json (recordStart/recordEnd).
    private func invalidateMeta(_ captureId: String) { metaCache[captureId] = nil }

    /// The durable conversation metadata (start/end/location) for a capture, for
    /// the timeline card (F1). `nil` for captures recorded before this shipped.
    public func conversationMeta(for captureId: String) -> ConversationMeta? {
        if let hit = metaCache[captureId] { return hit }
        let loaded = ConversationMetaStore.load(captureId: captureId, baseDir: baseDir)
        metaCache[captureId] = loaded
        return loaded
    }

    // MARK: per-capture sidecar memo (R3) — kill the list-rebuild main-thread disk storm

    /// A per-capture memo of the DURABLE sidecar state `rebuildVisibleCaptures` reads, so
    /// the rebuild (membership + processing count + stats) does ZERO synchronous sidecar
    /// disk I/O on the main actor. Audit (2026-07-17): the rebuild fired on every
    /// `captures` didSet + 7 sites and did up to ~3×N full transcript.json decodes + card
    /// loads + marker stats ON MAIN — a same-site, library-size-proportional hang.
    ///
    /// TEXT + speakers ONLY — never the decoded segment/paragraph arrays (those are the
    /// memory bulk; membership needs text + markers, stats needs word-count + distinct
    /// speakers). Seeded OFF the main actor during hydration and INVALIDATED at every
    /// write site (see `invalidateSidecar`).
    struct SidecarSnapshot: Sendable {
        /// `.discarded` marker present (sub-substance junk → never shown).
        let isDiscarded: Bool
        /// `.deleted` tombstone present (user-deleted → never shown).
        let isDeleted: Bool
        /// The best local transcript for the empty/filler membership filter: the cached
        /// transcript text if non-empty, else the card's provisional body. nil ⇒ no
        /// readable text yet (still processing) → the caller falls back to audio presence.
        let bestTranscriptText: String?
        /// transcript.json exists (the readable tombstone / "Ready" signal).
        let hasCachedTranscript: Bool
        /// card.json exists (the all-time browsable tombstone).
        let cardExists: Bool
        /// `.lore-confirmed` marker present.
        let confirmedInLore: Bool
        /// The STRIPPED cached transcript for StatsSummary: text + speakers + stub segments
        /// carrying ONLY the extra (segment-referenced but speaker-array-absent) slots, so
        /// the distinct-speaker + word counts are byte-identical to loading the full
        /// transcript WITHOUT retaining the heavy segment/paragraph arrays. nil when no
        /// transcript.json decoded (matches the pre-change stats snapshot's nil transcript).
        let statsTranscript: CachedTranscript?
    }

    private var sidecarCache: [String: SidecarSnapshot] = [:]

    /// Build a capture's sidecar memo from disk. `nonisolated static` so hydration can run
    /// it OFF the main actor (pure disk — touches no actor state, Sendable result).
    nonisolated static func loadSidecar(captureId id: String, baseDir: URL) -> SidecarSnapshot {
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
        // Strip the stats transcript to text + speakers + extra-slot stubs so the heavy
        // arrays are dropped but StatsSummary.countDistinctSpeakers sees the SAME identities:
        // it counts speaker-array identities PLUS any segment slot not in the speaker array,
        // so one empty stub segment per extra slot reproduces the count exactly.
        let stats: CachedTranscript? = cached.map { full in
            let knownSlots = Set(full.speakers.map(\.slot))
            let extraSlots = Set(full.segments.map(\.speaker)).subtracting(knownSlots).subtracting([""])
            let stubs = extraSlots.enumerated().map {
                TranscriptSegment(seq: $0.offset, text: "", speaker: $0.element)
            }
            return CachedTranscript(transcript: full.transcript, title: nil, summary: nil,
                                    segments: stubs, speakers: full.speakers,
                                    paragraphs: [], fetchedAt: 0)
        }
        return SidecarSnapshot(
            isDiscarded: discarded,
            isDeleted: deleted,
            bestTranscriptText: best,
            hasCachedTranscript: TranscriptCacheStore.hasCachedTranscript(captureId: id, baseDir: baseDir),
            cardExists: ConversationCardStore.exists(captureId: id, baseDir: baseDir),
            confirmedInLore: TranscriptCacheStore.isConfirmedInLore(captureId: id, baseDir: baseDir),
            statsTranscript: stats)
    }

    /// The memoised sidecar for a capture, loading from disk ONLY on a cold miss. Hydration
    /// warms every capture BEFORE the first rebuild, so the rebuild path stays memory-only;
    /// a cold miss (a capture added after hydration, or just-invalidated) loads exactly one.
    private func sidecar(for id: String) -> SidecarSnapshot {
        if let hit = sidecarCache[id] { return hit }
        let snap = Self.loadSidecar(captureId: id, baseDir: baseDir)
        sidecarCache[id] = snap
        return snap
    }

    /// Drop a capture's memoised sidecar after ANY write to its transcript / card / markers,
    /// so the next rebuild reflects the change. Liberal invalidation is SAFE (a cold miss
    /// re-loads one capture); a MISSED one — stale membership/stats — is the only real
    /// hazard, so every writer (in-manager + the poller + the detail-view cache) calls this.
    func invalidateSidecar(_ id: String) { sidecarCache[id] = nil }

    /// A COALESCED visible-list rebuild for OUT-OF-MANAGER writers (the status poller's card
    /// merge, the detail-view content cache): several can fire in one runloop tick, so hop
    /// once and rebuild a single time rather than N times.
    private var sidecarRebuildScheduled = false
    private func scheduleSidecarRebuild() {
        guard !sidecarRebuildScheduled else { return }
        sidecarRebuildScheduled = true
        Task { @MainActor [weak self] in
            self?.sidecarRebuildScheduled = false
            self?.rebuildVisibleCaptures()
        }
    }

    /// The durable, lightweight card metadata (name/description/stage) for a capture —
    /// the all-time tombstone that lets EVERY conversation show a title + summary in
    /// the list, even after its transcript text has been pruned. `nil` for a capture
    /// the door hasn't reported a title/summary for yet.
    ///
    /// NOT memoised: card.json is also written by each capture's status poller (title/
    /// summary merges) outside the manager's sight, and the render path reads it once
    /// per row (the title/summary a row shows live come from the poller's @Published
    /// state, so a slightly-stale disk read here has no visible effect anyway).
    public nonisolated func cardMeta(for captureId: String) -> ConversationCardMeta? {
        ConversationCardStore.load(captureId: captureId, baseDir: baseDir)
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
        guard !isDeleted(captureId) else { return }
        guard !TranscriptCacheStore.hasCachedTranscript(captureId: captureId, baseDir: baseDir) else { return }
        guard CaptureRetention.isRecentForTranscriptCache(conversationAge: conversationAgeSeconds(captureId)) else { return }
        guard !cachingTranscripts.contains(captureId) else { return }
        cachingTranscripts.insert(captureId)
        let baseDir = self.baseDir
        let fetch = self.fetchContent
        Task { [weak self] in
            defer { self?.cachingTranscripts.remove(captureId) }
            guard self?.isDeleted(captureId) == false else { return }
            guard let c = await fetch(captureId), c.found, !c.transcript.isEmpty else { return }
            let entry = CachedTranscript(transcript: c.transcript, title: c.title,
                                         summary: c.summary, segments: c.segments, speakers: c.speakers,
                                         paragraphs: c.paragraphs,
                                         fetchedAt: UInt64(max(0, Date().timeIntervalSince1970)))
            TranscriptCacheStore.save(entry, captureId: captureId, baseDir: baseDir)
            // Also seed the durable card tombstone with the name/description.
            ConversationCardStore.merge(captureId: captureId, baseDir: baseDir,
                                        title: c.title, summary: c.summary, stage: nil)
            self?.invalidateSidecar(captureId)   // transcript + card just changed on disk
            self?.rebuildVisibleCaptures()   // a freshly-cached tombstone can change membership
        }
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
        if captureSource == .omi { source.start() }
    }
    public func stopSource() { source.stop() }

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
            lastRecordBlockReason = "Finish the current conversation first"
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
        lastRecordBlockReason = nil   // starting cleanly — clear any prior block message
        recordingScreenMinimized = false   // a fresh recording always presents full-screen
        isRecordingMic = true
        // A fresh recording is never born paused (the `.streaming` mic branch clears any
        // inherited pause) — anchor the session clock to now. `beginSession` will preserve
        // this when the mic's `.streaming` opens the WAL, so internal rolls keep it.
        recordingClock = RecordingClock(startedAt: Date())
        router.resetSegmenter()
        micSource.start()
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
        recordingCandidates.removeAll { $0.utterance == candidate.utterance }
        recordingCandidates.insert(candidate, at: 0)
        if recordingCandidates.count > Self.maxRecordingCandidates {
            recordingCandidates = Array(recordingCandidates.prefix(Self.maxRecordingCandidates))
        }
    }

    /// Drop a candidate the user acted on or dismissed from the live surface.
    public func dismissRecordingCandidate(_ candidate: AmbientCandidate) {
        recordingCandidates.removeAll { $0.utterance == candidate.utterance }
        UsageHook.action("dismissed")   // content-free: the enum outcome, never the candidate text
    }

    // MARK: ambient session lifecycle (driven by the source, not a button)

    private func onSourceState(_ state: AudioSourceState) {
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
                router.resetSegmenter(); beginSession()   // fresh ambient capture
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
            }
        case .idle, .scanning:
            break
        }
    }

    // MARK: silence-gap auto-segmentation (req 9)

    /// A silence gap closes the current conversation and immediately opens the next,
    /// so each closed conversation (which by construction contained voice) surfaces
    /// in the timeline on its own — no pause/stop needed. Capture stays continuous.
    private func handleSegment(_ event: SegmentEvent) {
        switch event {
        case .opened:
            log?.info("capture: segment OPENED (voice after idle)")
            if active == nil { beginSession() }   // edge: open if somehow idle
        case .closed:
            guard active != nil else { return }
            endSession()
            beginSession()
            router.resetSegmenter()   // fresh boundary state for the new conversation
            log?.info("capture: silence gap (\(Int(silenceGapSeconds))s) → new conversation")
        }
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
                let started = startTime(of: wal)
                if !wal.status.streaming,
                   Date().timeIntervalSince1970 - started > Self.stuckEmptyRecordingSecs,
                   !TranscriptCacheStore.isConfirmedInLore(captureId: id, baseDir: baseDir),
                   !hasCachedTranscript(id),
                   !ConversationCardStore.exists(captureId: id, baseDir: baseDir) {
                    let dir = baseDir.appendingPathComponent(id, isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? Data("stuck empty recording — 0 segments, never received audio".utf8)
                        .write(to: discardMarker(id), options: [.atomic])
                    clearNeedsFinalize(id)
                    retryStates[id] = nil
                    invalidateSidecar(id)   // `.discarded` now present
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
            invalidateMeta(id)
            markNeedsFinalize(id)
            log?.info("capture \(id): orphan reconciled on launch — bounded (ended_at set) + pending finalize")
        }
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
        // Always refresh the home-screen widget snapshot + ask WidgetKit to reload — it's
        // cheap and the widget has no other way to learn capture changed.
        CaptureWidgetSnapshotStore.write(makeWidgetSnapshot())
        reloadWidgetTimelines()

        #if canImport(ActivityKit) && os(iOS)
        guard #available(iOS 16.2, *), let controller = liveActivityController else { return }
        let state = makeActivityState()
        switch kind {
        case .start:
            lastLiveActivityPushAt = Date().timeIntervalSince1970
            lastPushedState = state
            controller.start(state)
        case .update:
            // A lifecycle transition (pause/resume/source-switch) — push unconditionally,
            // but still record it so the next throttled tick can coalesce against it.
            lastLiveActivityPushAt = Date().timeIntervalSince1970
            lastPushedState = state
            controller.update(state)
        case .throttledUpdate:
            let now = Date().timeIntervalSince1970
            guard now - lastLiveActivityPushAt >= Self.liveActivityThrottle else { return }
            // Coalesce: if the meaningful content is unchanged since the last push, skip —
            // the elapsed timer ticks ON-DEVICE, so an identical phase/level/transcript
            // never needs a re-push. This keeps the update cadence to "only when something
            // the user sees actually changed", so battery impact stays negligible.
            if let last = lastPushedState, Self.liveStateEquivalent(last, state) { return }
            lastLiveActivityPushAt = now
            lastPushedState = state
            controller.update(state)
        case .end:
            lastPushedState = nil
            controller.end(final: state)
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
        CaptureWidgetSnapshotStore.write(makeWidgetSnapshot())
        reloadWidgetTimelines()
    }

    /// Build a WAL, threading the (test-only) per-segment upload override so every
    /// capture this manager owns uploads through the same (real or injected) path.
    private nonisolated func makeWAL(captureId id: String) -> CaptureWAL {
        let upload: (@Sendable (UInt64, Data) async throws -> Void)?
        if let uploadSegment { upload = { seq, body in try await uploadSegment(id, seq, body) } }
        else { upload = nil }
        return CaptureWAL(captureId: id, target: target, baseDir: baseDir, log: log, upload: upload)
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
        startLiveTranscription()
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
            Task { [weak self] in
                await primaryWal.sync()
                await self?.tryFinalize(primaryWal)
            }
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
        if recordingClock == nil {
            recordingClock = RecordingClock(startedAt: Date(), paused: isPaused, now: Date())
        }
        let id = Self.newCaptureId()
        let wal = makeWAL(captureId: id)
        active = wal
        // A fresh conversation surface starts with NO ambient rows (belt-and-suspenders
        // with the captureId guard in noteRecordingCandidate) — a candidate from the
        // just-closed conversation must never bleed onto this one.
        recordingCandidates = []
        captures.insert(wal, at: 0)               // newest first (Omi-style timeline)
        // Durably stamp the conversation START (F1) — the card's start time + the
        // door's `capturedAt`. Idempotent (won't clobber an existing record). Also
        // stamp the durable `card.json` start so the conversation keeps this date even
        // if its meta sidecar is ever pruned (track 20260628T1609).
        let startSecs = nowUnixSecs()
        ConversationMetaStore.recordStart(captureId: id, baseDir: baseDir, at: startSecs)
        invalidateMeta(id)
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
        startLiveTranscription()                  // additive live preview (no-op if unwired)
        lastHeartbeatAt = 0; lastHeartbeatFrames = router.stats().count   // fresh heartbeat baseline
        pushLiveState(.start)   // start the Live Activity + refresh the home-screen widget
        startMeter()            // a live capture is ALWAYS metered, regardless of which screen is visible (Bug 2)
        log?.info("capture \(id): ambient session started (source=\(captureSource.rawValue), state=\(sourceStateLabel))")
    }

    // MARK: live on-device transcription lifecycle (Feature 1)

    /// Spin up a fresh per-conversation live transcriber (if a factory is wired) and
    /// pump its provisional transcript into `liveTranscript`. All failures are
    /// non-fatal: capture continues with no live preview.
    private func startLiveTranscription() {
        guard let make = makeLiveTranscriber, let t = make() else { return }
        liveTranscript = .empty
        liveTranscriber = t
        #if canImport(AVFoundation)
        liveBox.set(t)
        #endif
        let pump = Task { @MainActor [weak self] in
            for await snap in t.transcript {
                guard !Task.isCancelled else { break }
                self?.liveTranscript = snap
            }
        }
        liveTranscriptTask = pump
        Task { @MainActor [weak self] in
            do { try await t.start() }
            catch {
                self?.log?.warn("live transcription off: \((error as NSError).localizedDescription)")
                #if canImport(AVFoundation)
                self?.liveBox.set(nil)
                #endif
                self?.liveTranscriber = nil
                pump.cancel()
                self?.liveTranscript = .empty
            }
        }
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
        liveTranscript = .empty
        if let t {
            Task { @MainActor [weak self] in
                let settled = await t.finish()
                if let captureId, !settled.isEmpty { self?.seedProvisionalCard(captureId, transcript: settled) }
            }
        }
    }

    /// Persist the on-device transcript as the capture's PROVISIONAL card content + a
    /// provisional title (first words / "Processing…"), then refresh the list so the
    /// card shows it immediately. Never downgrades a card that already has authoritative
    /// Kiln content. Does NOT stamp the in-Lore/cached-transcript tombstone — provisional
    /// content must not read as "Ready".
    private func seedProvisionalCard(_ captureId: String, transcript: String) {
        let title = ProvisionalTitle.from(transcript: transcript)
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
        recordingCandidates = []   // the live surface's rows belong to the closing conversation
        guard let finished = active else {
            // No active session — still ensure any live preview is torn down.
            endLiveTranscription()
            router.setExternalPCM(false)
            return
        }
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
        seedProvisionalCard(finishedId, transcript: onDeviceNow)
        endLiveTranscription(seedInto: finishedId)   // stop + (async) refine the seed
        router.setExternalPCM(false)                 // clear the mic's direct-PCM tap mode
        finished.finish()
        active = nil
        // A closed conversation must reach the Lore inbox: mark it pending-finalize
        // (durably, so it survives relaunch — mirrors the WAL's waitingForInternet
        // ethos), then drive sync→finalize. The drain timer + app-foreground retry
        // any that don't complete now (door/Lore down, or segments not yet ACK'd).
        markNeedsFinalize(finished.captureId)
        let id = finished.captureId
        let baseDir = self.baseDir
        let provider = self.locationProvider
        Task { [weak self] in
            // Stamp the conversation END + an opportunistic location fix (F1, F5)
            // BEFORE finalize, so the metadata is durable and finalize sends it. The
            // location is best-effort: nil (denied / backgrounded / no fix) → time-only.
            let fix = await provider.currentLocation()
            ConversationMetaStore.recordEnd(captureId: id, baseDir: baseDir,
                                            at: nowUnixSecs(), location: fix)
            self?.invalidateMeta(id)
            await finished.sync()                 // snappy first sync
            await self?.tryFinalize(finished)     // finalize once segments are ACK'd
        }
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
    private func tryFinalize(_ wal: CaptureWAL) async {
        let id = wal.captureId
        guard isPendingFinalize(id), !finalizing.contains(id) else { return }
        let snap = wal.snapshot()
        // Gate: audio must be durably on the desktop before finalize.
        guard snap.totalSegments > 0, snap.pendingSegments == 0 else {
            log?.info("capture \(id): finalize deferred — \(snap.pendingSegments) segment(s) not yet ACK'd")
            return
        }
        finalizing.insert(id)
        defer { finalizing.remove(id) }
        // The durable conversation metadata (start/end/location) becomes the
        // finalize POST body so the door persists it + threads it into the ingest
        // envelope (F1, F9). Absent (older capture) → an empty body (still valid).
        let meta = ConversationMetaStore.load(captureId: id, baseDir: baseDir)
        do {
            try await finalizeCapture(id, meta)
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
        drainTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            // When the manager is gone (a torn-down test case), stop the timer so
            // it doesn't keep firing on the main run loop — leaked repeating timers
            // across a 400+ test suite starved the timing-sensitive drain/resync
            // tests into flaky timeouts. Idempotent in production (self never nil).
            guard self != nil else { timer.invalidate(); return }
            Task { @MainActor in await self?.drainPending() }
        }
    }

    /// Guards against overlapping drains: the 5s timer can fire a new drain while the
    /// previous one is still `await`-ing a slow `wal.sync()`, which ran two `sync()`/
    /// `computeStatus()`/prune passes on the SAME WAL concurrently (off-main) → a data
    /// race that crashed in `objc_retain` (EXC_BAD_ACCESS). One drain at a time.
    private var isDraining = false

    public func drainPending() async {
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
        await retryPendingFinalizes()
        await retryPendingDeletes()
        await retryPendingSpeakerConfirms()   // durable speaker-name confirms (hub-blip safe)
        shipAmbientSignalIfDue()   // redacted gate/card signal → desktop door (v3.3)
        await maybePrune()   // retention sweeps — throttled + run OFF the main thread
    }

    private func drainBatch(now: TimeInterval) -> [CaptureWAL] {
        var batch: [CaptureWAL] = []
        batch.reserveCapacity(Self.maxCapturesPerDrain)
        for wal in captures {
            guard wal.snapshot().pendingSegments > 0 else { continue }
            let id = wal.captureId
            if isAbandoned(id) { continue }
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
    }

    private func isPendingDelete(_ captureId: String) -> Bool {
        FileManager.default.fileExists(atPath: needsDeleteMarker(captureId).path)
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
        metaCache[captureId] = nil
        invalidateSidecar(captureId)   // `.deleted` marker + files just changed on disk
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
        for id in touched { invalidateSidecar(id) }
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

    /// Age (seconds) since the conversation started, from its meta on disk (0 when absent).
    nonisolated static func conversationAgeOnDisk(_ captureId: String, baseDir: URL) -> TimeInterval {
        guard let started = ConversationMetaStore.load(captureId: captureId, baseDir: baseDir)?.startedAt,
              started > 0 else { return 0 }
        return max(0, Date().timeIntervalSince1970 - TimeInterval(started))
    }

    /// Age (seconds) of the newest `seg-*.opus` by mtime, or nil when no segments remain.
    nonisolated static func newestSegmentAgeOnDisk(_ captureId: String, baseDir: URL) -> TimeInterval? {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let mtimes = files
            .filter { $0.pathExtension == "opus" }
            .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        guard let newest = mtimes.max() else { return nil }
        return Date().timeIntervalSince(newest)
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

    /// Ship any speaker-name confirms that couldn't reach the hub when the user made them
    /// (durable + offline-safe — mirrors the finalize/delete retry ethos). Stops on the
    /// first transport failure (hub still down) to avoid hammering; resumes next drain.
    public func retryPendingSpeakerConfirms() async {
        // The queue is a full-file read+rewrite; keep it OFF the main actor (this method
        // runs on the @MainActor CaptureManager) so a drain never hangs the UI.
        let base = baseDir
        let entries = await Task.detached { SpeakerConfirmQueue.pending(baseDir: base) }.value
        guard !entries.isEmpty else { return }
        let client = DoorClient(target: target)
        for e in entries {
            do {
                _ = try await client.confirmSpeaker(captureId: e.captureId, slot: e.slot,
                                                    speakerId: e.speakerId, name: e.name)
                let capId = e.captureId, slot = e.slot
                await Task.detached { SpeakerConfirmQueue.remove(captureId: capId, slot: slot, baseDir: base) }.value
            } catch {
                break   // hub unreachable — keep the rest queued, retry next drain
            }
        }
    }

    /// Retry finalize for every capture still marked pending-finalize. Safe to call
    /// from the drain timer and on app-foreground (mirrors the WAL drain ethos).
    public func retryPendingFinalizes() async {
        for wal in captures where wal !== active && !isDeleted(wal.captureId) && isPendingFinalize(wal.captureId) {
            await tryFinalize(wal)
        }
    }

    /// Retry all durable remote-deletion intents. This enumerates disk rather than
    /// `captures` because deleted captures intentionally do NOT hydrate into memory.
    /// On ACK, the whole capture dir is removed; until then only `.deleted` +
    /// `.needs-delete` remain, so the row cannot resurrect while offline.
    public func retryPendingDeletes() async {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else { return }
        for dir in entries {
            let id = dir.lastPathComponent
            guard !id.hasPrefix("."), isPendingDelete(id) else { continue }
            do {
                try await deleteCaptureRemote(id)
                try? fm.removeItem(at: dir)
                log?.info("capture \(id): remote delete acknowledged; local tombstone removed")
            } catch {
                log?.warn("capture \(id): remote delete failed (\((error as NSError).localizedDescription)) — staying pending")
            }
        }
    }

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
            let title = (card.title?.isEmpty == false) ? card.title! : "Conversation"
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
            seededSidecars.reserveCapacity(picked.count)
            seededMeta.reserveCapacity(picked.count)
            for id in picked {
                seededSidecars[id] = Self.loadSidecar(captureId: id, baseDir: self.baseDir)
                seededMeta[id] = ConversationMetaStore.load(captureId: id, baseDir: self.baseDir)
            }
            let seedMs = seedSpan.elapsedMs()
            await MainActor.run {
                // Seed BEFORE append so the append's didSet rebuild hits the warm cache.
                // Keep any entry the main actor already wrote during the async gap (a
                // capture started mid-hydration) — the disk seed must not clobber live state.
                self.sidecarCache.merge(seededSidecars) { current, _ in current }
                self.metaCache.merge(seededMeta) { current, _ in current }
                // A capture STARTED before hydration finished sits at index 0
                // (newest); the hydrated backlog appends behind it — order holds.
                self.captures.append(contentsOf: hydrated)   // one didSet -> one rebuild; swaps NOW
            }
            PerfHook.span("capture-hydrate-n\(hydrated.count)", ms: ms)
            PerfHook.span("capture-sidecar-seed-n\(picked.count)", ms: seedMs)

            // Phase 2 — WARM the statuses (the deferred per-segment scan) OFF the first-paint
            // path, then the startup work that needs true counts. Under its OWN span so the
            // moved work stays visible in telemetry WITHOUT counting against the hydrate
            // budget (the harness matches `capture-hydrate*`, not `capture-status-warm*`).
            let warm = PerfSpan(name: "capture-status-warm")
            for wal in hydrated { wal.warmStatus() }
            // Retention sweep ALSO off the main actor (was a startup main-thread hang).
            let retention = Self.retentionSweep(ids: picked, baseDir: self.baseDir)
            let warmMs = warm.elapsedMs()
            await MainActor.run {
                // R4 — the startup main-actor TAIL (orphan reconcile + retention apply +
                // rebuild + widget seed) was invisible (capture-status-warm stops before this
                // hop). Measure it under its own span so any residual main-thread cost shows.
                let finishSpan = PerfSpan(name: "capture-startup-finish")
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
        let base = baseDir
        let retention = Self.discardedRetention
        Task.detached(priority: .background) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return }
            let now = Date()
            for url in entries {
                let marker = url.appendingPathComponent(".discarded")
                guard fm.fileExists(atPath: marker.path) else { continue }
                let m = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let m, now.timeIntervalSince(m) > retention { try? fm.removeItem(at: url) }
            }
        }
    }

    static func newCaptureId() -> String {
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
public enum OmiCaptureDesiredState: String {
    case listening
    case paused
}

/// Persisted capture preferences (UserDefaults). The silence-gap that drives
/// auto-segmentation (req 9; default ~2 min, à la Omi), the chosen capture source,
/// and the durable pause/listen intent restored on launch.
public enum CaptureSettings {
    private static let gapKey = "foundryx.capture.silence-gap-seconds"
    public static let defaultGapSeconds: TimeInterval = 120

    public static var silenceGapSeconds: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: gapKey)
            return v > 0 ? v : defaultGapSeconds
        }
        set { UserDefaults.standard.set(newValue, forKey: gapKey) }
    }

    private static let sourceKey = "foundryx.capture.source"

    /// The chosen capture device (Omi by default — today's behavior). Persisted.
    public static var captureSource: CaptureSourceKind {
        get { CaptureSourceKind(rawValue: UserDefaults.standard.string(forKey: sourceKey) ?? "") ?? .omi }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sourceKey) }
    }

    private static let desiredStateKey = "foundryx.capture.omi-desired-state"

    /// The user's last ambient-capture intent. Default `.listening` on first-ever
    /// launch (no stored value) — unchanged from today's behavior. Once the user
    /// pauses/resumes, that choice is honored across restarts.
    public static var omiCaptureDesiredState: OmiCaptureDesiredState {
        get { OmiCaptureDesiredState(rawValue: UserDefaults.standard.string(forKey: desiredStateKey) ?? "") ?? .listening }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: desiredStateKey) }
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
