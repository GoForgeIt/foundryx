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

    func setWAL(_ w: CaptureWAL?) { lock.lock(); wal = w; lock.unlock() }
    func setPaused(_ p: Bool) {
        lock.lock()
        paused = p
        if !p { segmenter.noteActive(at: clock()) }   // resume ≠ a silence gap
        lock.unlock()
    }
    func resetSegmenter() { lock.lock(); segmenter.reset(); lock.unlock() }
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

    /// Recompute the visible list. Hide ones that recorded NOTHING (0 segments, not
    /// streaming) — useless empty cards; keep ones with real audio, still-streaming, or a
    /// pruned-to-transcript tombstone. Order newest-first by the durable conversation start.
    private func rebuildVisibleCaptures() {
        visibleCaptures = captures
            .filter { self.isBrowsable($0) }
            .sorted { self.startTime(of: $0) > self.startTime(of: $1) }
    }

    /// A conversation belongs in the all-time list when it has real audio / is
    /// streaming, OR it has any durable readable tombstone — a cached transcript, the
    /// lightweight name/description card, or a confirmed-in-Lore marker. This keeps a
    /// conversation browsable forever (with its name + description) even after its
    /// audio AND its transcript text have been pruned. Empty (0-segment) captures with
    /// no tombstone are still hidden (useless cards).
    private func isBrowsable(_ wal: CaptureWAL) -> Bool {
        if CaptureManager.isWorthShowing(wal.status) { return true }
        let id = wal.captureId
        return hasCachedTranscript(id)
            || ConversationCardStore.exists(captureId: id, baseDir: baseDir)
            || TranscriptCacheStore.isConfirmedInLore(captureId: id, baseDir: baseDir)
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
    @Published public private(set) var active: CaptureWAL?
    @Published public private(set) var sourceState: AudioSourceState = .idle
    /// Ambient capture is paused (device stays connected; frames are dropped).
    @Published public private(set) var isPaused: Bool = false
    /// Rolling audio-level bars (0…1, oldest→newest) for the live meter (req 8).
    @Published public private(set) var levels: [Float]
    /// Silence gap (seconds) that auto-ends a conversation (req 9). Persisted.
    @Published public private(set) var silenceGapSeconds: TimeInterval
    /// Diagnostics (surfaced on the capture screen): total Opus frames the BLE
    /// source has delivered into the pipeline, and the last frame's byte size. A
    /// flat meter with framesReceived==0 ⇒ the device isn't notifying; >0 ⇒ frames
    /// arrive (then the meter/levels are the thing to look at).
    @Published public private(set) var framesReceived: Int = 0
    @Published public private(set) var lastFrameBytes: Int = 0

    /// The live, on-device PROVISIONAL transcript for the ACTIVE conversation
    /// (Feature 1). An ephemeral PREVIEW only — it empties when no conversation is
    /// open, and the AUTHORITATIVE transcript still comes from Kiln (door → Lore →
    /// Kiln). Stays `.empty` when live transcription is unavailable (older OS / no
    /// model / no factory wired), so the UI simply shows nothing extra.
    @Published public private(set) var liveTranscript: LiveTranscript = .empty

    /// Number of bars in the meter window (~4s at the 12 Hz sample tick).
    public static let meterBarCount = 48

    private let target: DoorTarget
    private let baseDir: URL
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
    /// The user's chosen capture device (Omi vs phone mic). Persisted. Selecting the
    /// phone mic stops the Omi from auto-grabbing an ambient session.
    @Published public private(set) var captureSource: CaptureSourceKind = CaptureSettings.captureSource
    private let levelBuffer = LevelBuffer()
    private var drainTimer: Timer?
    private var meterTimer: Timer?
    /// Finalize-the-conversation seam (injectable for door-free tests): given a
    /// closed capture id + its conversation metadata (start/end/location), tell the
    /// door to assemble + ingest it to Lore. Throws on failure so the capture stays
    /// pending-finalize and is retried.
    private let finalizeCapture: @Sendable (String, ConversationMeta?) async throws -> Void
    /// Fetch a capture's transcript content from the door (injectable for door-free
    /// tests). Drives the proactive 14-day transcript cache ("fetch on sight"). Returns
    /// nil on any transport error (the cache just stays empty until next sight).
    private let fetchContent: @Sendable (String) async -> CaptureContent?
    /// One-shot location at conversation boundaries (When-In-Use, opportunistic —
    /// F5). Degrades to no-location off the main app / when denied.
    private let locationProvider: ConversationLocationProviding
    /// In-flight finalize attempts, so a retry tick never double-fires for the same
    /// capture while one is already running.
    private var finalizing: Set<String> = []

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

    public init(target: DoorTarget,
                baseDir: URL? = nil,
                log: DoorLog? = nil,
                source: AudioFrameSource,
                micSource: AudioFrameSource? = nil,
                finalize: (@Sendable (String, ConversationMeta?) async throws -> Void)? = nil,
                fetchContent: (@Sendable (String) async -> CaptureContent?)? = nil,
                locationProvider: ConversationLocationProviding? = nil,
                liveTranscriber: LiveTranscriberFactory? = nil) {
        self.target = target
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
        // Default content fetch = the real door /content call. Tests inject a stub to
        // drive the proactive transcript cache without HTTP.
        if let fetchContent {
            self.fetchContent = fetchContent
        } else {
            let client = DoorClient(target: target, log: log)
            self.fetchContent = { captureId in try? await client.captureContent(captureId: captureId) }
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
        self.levels = Array(repeating: 0, count: Self.meterBarCount)
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
        loadExisting()
        pruneOldTranscripts()  // ~14d transcript-text sweep (keeps name/description metadata)
        pruneOldAudio()        // ~30d audio sweep (keeps transcripts, prunes safe-in-Lore audio)
        startDrainTimer()
    }

    /// The durable conversation metadata (start/end/location) for a capture, for
    /// the timeline card (F1). `nil` for captures recorded before this shipped.
    public func conversationMeta(for captureId: String) -> ConversationMeta? {
        ConversationMetaStore.load(captureId: captureId, baseDir: baseDir)
    }

    /// The durable, lightweight card metadata (name/description/stage) for a capture —
    /// the all-time tombstone that lets EVERY conversation show a title + summary in
    /// the list, even after its transcript text has been pruned. `nil` for a capture
    /// the door hasn't reported a title/summary for yet.
    public func cardMeta(for captureId: String) -> ConversationCardMeta? {
        ConversationCardStore.load(captureId: captureId, baseDir: baseDir)
    }

    /// Per-capture status pollers (the door→Lore stage chip, F11). Lazily created +
    /// memoised so a card re-render reuses the same poller (one poll loop per
    /// capture). Driven by the card's onAppear/onDisappear.
    private var pollers: [String: CaptureStatusPoller] = [:]

    /// The status poller for a capture, creating one on first ask. The card calls
    /// `.start()` on appear and `.stop()` on disappear.
    public func statusPoller(for captureId: String) -> CaptureStatusPoller {
        if let existing = pollers[captureId] { return existing }
        let client = DoorClient(target: target, log: log)
        // Pass baseDir so the poller persists title/summary/stage into the durable card
        // tombstone (card.json) — the all-time browsable name + description.
        let poller = CaptureStatusPoller(captureId: captureId, client: client, baseDir: baseDir)
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
        guard !TranscriptCacheStore.hasCachedTranscript(captureId: captureId, baseDir: baseDir) else { return }
        guard CaptureRetention.isRecentForTranscriptCache(conversationAge: conversationAgeSeconds(captureId)) else { return }
        guard !cachingTranscripts.contains(captureId) else { return }
        cachingTranscripts.insert(captureId)
        let baseDir = self.baseDir
        let fetch = self.fetchContent
        Task { [weak self] in
            defer { self?.cachingTranscripts.remove(captureId) }
            guard let c = await fetch(captureId), c.found, !c.transcript.isEmpty else { return }
            let entry = CachedTranscript(transcript: c.transcript, title: c.title,
                                         summary: c.summary,
                                         fetchedAt: UInt64(max(0, Date().timeIntervalSince1970)))
            TranscriptCacheStore.save(entry, captureId: captureId, baseDir: baseDir)
            // Also seed the durable card tombstone with the name/description.
            ConversationCardStore.merge(captureId: captureId, baseDir: baseDir,
                                        title: c.title, summary: c.summary, stage: nil)
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
        log?.info("capture source → \(kind.rawValue)")
    }

    /// Start recording from the phone microphone. No-op if there's no mic source, it's
    /// already recording, or an Omi session is already active (the UX only offers this
    /// when the Omi is disconnected). Drives the normal lifecycle via the mic's
    /// `.streaming` state → beginSession.
    public func startMicRecording() {
        guard let micSource, !isRecordingMic, active == nil else { return }
        isRecordingMic = true
        router.resetSegmenter()
        micSource.start()
        log?.info("phone mic: recording requested")
    }

    /// Stop the phone-mic recording. The mic's `.stopped` state ends the session and
    /// finalizes the capture through the normal path.
    public func stopMicRecording() {
        guard let micSource, isRecordingMic else { return }
        micSource.stop()
        log?.info("phone mic: stop requested")
    }

    public func toggleMicRecording() { isRecordingMic ? stopMicRecording() : startMicRecording() }

    // MARK: ambient session lifecycle (driven by the source, not a button)

    private func onSourceState(_ state: AudioSourceState) {
        sourceState = state
        switch state {
        case .streaming:
            if active == nil { router.resetSegmenter(); beginSession() }  // ambient capture
        case .stopped, .failed:
            // A source stopping (Omi disconnect OR a phone-mic Stop/permission-deny)
            // ends the session and resets the mic-recording flag so the Record button
            // returns to its idle state.
            isRecordingMic = false
            endSession()
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
            log?.info("capture: silence gap (\(Int(silenceGapSeconds))s) → new conversation")
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
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMeter() }
        }
    }

    /// Stop sampling + flatten the bars (call from onDisappear).
    public func stopMeter() {
        meterTimer?.invalidate(); meterTimer = nil
        levels = Array(repeating: 0, count: Self.meterBarCount)
    }

    private func tickMeter() {
        let peak = isPaused ? 0 : levelBuffer.drainPeak()
        var ring = levels
        if !ring.isEmpty { ring.removeFirst() }
        ring.append(peak)
        levels = ring
        // Surface the frame diagnostics on the same 12 Hz tick (no per-frame main hop).
        let s = router.stats()
        if s.count != framesReceived { framesReceived = s.count }
        if s.lastBytes != lastFrameBytes { lastFrameBytes = s.lastBytes }
    }

    private func beginSession() {
        let id = Self.newCaptureId()
        let wal = CaptureWAL(captureId: id, target: target, baseDir: baseDir, log: log)
        active = wal
        captures.insert(wal, at: 0)               // newest first (Omi-style timeline)
        // Durably stamp the conversation START (F1) — the card's start time + the
        // door's `capturedAt`. Idempotent (won't clobber an existing record). Also
        // stamp the durable `card.json` start so the conversation keeps this date even
        // if its meta sidecar is ever pruned (track 20260628T1609).
        let startSecs = nowUnixSecs()
        ConversationMetaStore.recordStart(captureId: id, baseDir: baseDir, at: startSecs)
        ConversationCardStore.recordStart(captureId: id, baseDir: baseDir, startedAt: startSecs)
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
        log?.info("capture \(id): ambient session started")
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
        if changed { rebuildVisibleCaptures() }
    }

    /// Manually split the conversation (Feature 2): finalize the CURRENT capture (it's
    /// sent for transcription via the existing finalize path) and immediately begin a
    /// NEW conversation — the SAME boundary the silence-gap segmenter draws, triggered
    /// by hand. No-op when nothing is being captured. Audio is never dropped: endSession
    /// flushes/finalizes the closed WAL and beginSession opens the next before the next
    /// frame is routed (both run synchronously on the main actor).
    public func splitConversation() {
        guard active != nil else { return }
        endSession()
        beginSession()
        log?.info("capture: manual split → new conversation")
    }

    private func endSession() {
        router.setWAL(nil)
        // Capture the on-device transcript BEFORE teardown clears it, and persist it as
        // the conversation's PROVISIONAL content so the card shows readable text the
        // INSTANT it's stopped — resilient to slow/failed Kiln transcription (Feature 1).
        let onDeviceNow = liveTranscript.displayText
        let finishedId = active?.captureId
        if let finishedId { seedProvisionalCard(finishedId, transcript: onDeviceNow) }
        endLiveTranscription(seedInto: finishedId)   // stop + (async) refine the seed
        router.setExternalPCM(false)                 // clear the mic's direct-PCM tap mode
        guard let finished = active else { return }
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
            await finished.sync()                 // snappy first sync
            await self?.tryFinalize(finished)     // finalize once segments are ACK'd
        }
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
        CaptureSettings.omiCaptureDesiredState = .paused
        router.setPaused(true)
        log?.info("capture: paused")
    }
    public func resume() {
        isPaused = false
        CaptureSettings.omiCaptureDesiredState = .listening
        router.setPaused(false)
        log?.info("capture: resumed")
    }
    public func togglePause() { isPaused ? resume() : pause() }

    // MARK: drain (retry until every segment is ACK'd)

    private func startDrainTimer() {
        drainTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
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
        defer { isDraining = false }
        for wal in captures where wal.status.pendingSegments > 0 { await wal.sync() }
        // After syncing, retry any pending-finalize captures whose segments are now
        // all ACK'd — this is the retry path for a finalize that didn't complete at
        // conversation-close (door/Lore was down, or segments weren't ACK'd yet).
        await retryPendingFinalizes()
        pruneOldTranscripts()   // ~14d transcript-text sweep (keeps name/description metadata)
        pruneOldAudio()         // periodic retention sweep (cheap: stats files, only acts >30d)
    }

    // MARK: retention (prune transcript text after ~14d; prune local audio after ~30d)

    /// Prune the cached transcript TEXT for every conversation older than the ~14-day
    /// window, FIRST copying its name/description into the durable card tombstone so the
    /// conversation stays browsable (and the transcript stays loadable on demand from
    /// the door). Keeps `meta.json`, `card.json`, `.lore-confirmed`. Never touches the
    /// active capture or a recent one. Offline-safe (disk only).
    public func pruneOldTranscripts() {
        for wal in captures where wal !== active {
            let id = wal.captureId
            guard TranscriptCacheStore.hasCachedTranscript(captureId: id, baseDir: baseDir) else { continue }
            guard CaptureRetention.shouldPruneTranscript(conversationAge: conversationAgeSeconds(id)) else { continue }
            // Preserve the readable name/description before dropping the transcript text.
            if let t = TranscriptCacheStore.load(captureId: id, baseDir: baseDir) {
                ConversationCardStore.merge(captureId: id, baseDir: baseDir,
                                            title: t.title, summary: t.summary, stage: nil)
            }
            TranscriptCacheStore.pruneTranscriptText(captureId: id, baseDir: baseDir)
            log?.info("capture \(id): pruned transcript text (>14d) — name/description kept, loadable on demand")
        }
    }

    // MARK: retention (prune local audio after 30d once it's safe in Lore — keep a readable tombstone)

    /// Prune the local audio for every capture whose newest segment is older than the
    /// retention window AND is confirmed durably in Lore AND has a cached transcript.
    /// Deletes the `seg-*.opus` + `.ack` files but KEEPS the dir + `transcript.json`
    /// (a readable tombstone). Never prunes the active capture, an unconfirmed
    /// capture, or one without a cached transcript. Idempotent + offline-safe (all
    /// inputs come from disk — no network).
    public func pruneOldAudio() {
        var prunedAny = false
        for wal in captures where wal !== active {
            let id = wal.captureId
            guard let age = newestSegmentAge(id) else { continue }   // nil ⇒ no audio (already pruned)
            let confirmed = TranscriptCacheStore.isConfirmedInLore(captureId: id, baseDir: baseDir)
            // A readable tombstone survives locally as either the cached transcript or —
            // once that's been pruned at ~14d — the lightweight name/description card.
            let tombstone = TranscriptCacheStore.hasCachedTranscript(captureId: id, baseDir: baseDir)
                || ConversationCardStore.exists(captureId: id, baseDir: baseDir)
            guard CaptureRetention.shouldPruneAudio(newestSegmentAge: age,
                                                    confirmedInLore: confirmed,
                                                    hasReadableTombstone: tombstone) else { continue }
            deleteLocalAudio(id)
            wal.refreshStatus()
            prunedAny = true
            log?.info("capture \(id): pruned local audio (>30d, confirmed in Lore, transcript cached) — transcript kept")
        }
        if prunedAny { rebuildVisibleCaptures() }   // membership may shift to tombstone state
    }

    /// Age (seconds) of the newest `seg-*.opus` segment by file mtime, or `nil` when
    /// there are no segments left on disk.
    private func newestSegmentAge(_ captureId: String) -> TimeInterval? {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let mtimes = files
            .filter { $0.pathExtension == "opus" }
            .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        guard let newest = mtimes.max() else { return nil }
        return Date().timeIntervalSince(newest)
    }

    /// Delete a capture's `seg-*.opus` + `seg-*.ack` files, keeping everything else
    /// (the dir, `transcript.json`, `meta.json`, markers) as a tombstone.
    private func deleteLocalAudio(_ captureId: String) {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "opus" || f.pathExtension == "ack" {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// Retry finalize for every capture still marked pending-finalize. Safe to call
    /// from the drain timer and on app-foreground (mirrors the WAL drain ethos).
    public func retryPendingFinalizes() async {
        for wal in captures where wal !== active && isPendingFinalize(wal.captureId) {
            await tryFinalize(wal)
        }
    }

    // MARK: persistence (resume across launches)

    private func loadExisting() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else { return }
        let ids = dirs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
        for id in ids.sorted(by: >) {
            captures.append(CaptureWAL(captureId: id, target: target, baseDir: baseDir, log: log))
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
