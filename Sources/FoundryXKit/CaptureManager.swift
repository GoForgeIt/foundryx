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
    // Diagnostics: how many frames the source has routed in (regardless of pause)
    // and the most recent frame's byte size — surfaced to the UI/log so a flat
    // meter can be told apart from "no frames arriving at all."
    private var frameCount = 0
    private var lastBytes = 0

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
        lock.unlock()
        target?.appendFrame(frame)
        if !isPaused {
            onLevel?(level)
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
            .filter { CaptureManager.isWorthShowing($0.status) || self.hasCachedTranscript($0.captureId) }
            .sorted { self.startTime(of: $0) > self.startTime(of: $1) }
    }

    /// A capture's durable conversation start (unix seconds) for ordering. Prefers the
    /// `meta.json` start (stable across relaunch) over the WAL's in-memory `startedAt`
    /// (which is re-stamped to launch time when an existing capture is reloaded).
    /// Memoised once a stable meta start is found so the list sort doesn't re-read disk.
    private var startTimeCache: [String: TimeInterval] = [:]
    private func startTime(of wal: CaptureWAL) -> TimeInterval {
        if let cached = startTimeCache[wal.captureId] { return cached }
        if let meta = ConversationMetaStore.load(captureId: wal.captureId, baseDir: baseDir) {
            let t = TimeInterval(meta.startedAt)
            startTimeCache[wal.captureId] = t
            return t
        }
        return wal.status.startedAt.timeIntervalSince1970
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

    /// Number of bars in the meter window (~4s at the 12 Hz sample tick).
    public static let meterBarCount = 48

    private let target: DoorTarget
    private let baseDir: URL
    private let log: DoorLog?
    private let source: AudioFrameSource
    private let router: FrameRouter
    private let levelBuffer = LevelBuffer()
    private var drainTimer: Timer?
    private var meterTimer: Timer?
    /// Finalize-the-conversation seam (injectable for door-free tests): given a
    /// closed capture id + its conversation metadata (start/end/location), tell the
    /// door to assemble + ingest it to Lore. Throws on failure so the capture stays
    /// pending-finalize and is retried.
    private let finalizeCapture: @Sendable (String, ConversationMeta?) async throws -> Void
    /// One-shot location at conversation boundaries (When-In-Use, opportunistic —
    /// F5). Degrades to no-location off the main app / when denied.
    private let locationProvider: ConversationLocationProviding
    /// In-flight finalize attempts, so a retry tick never double-fires for the same
    /// capture while one is already running.
    private var finalizing: Set<String> = []

    public init(target: DoorTarget,
                baseDir: URL? = nil,
                log: DoorLog? = nil,
                source: AudioFrameSource,
                finalize: (@Sendable (String, ConversationMeta?) async throws -> Void)? = nil,
                locationProvider: ConversationLocationProviding? = nil) {
        self.target = target
        self.baseDir = baseDir ?? CaptureWAL.documentsCaptures()
        self.log = log
        self.source = source
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
        self.levels = Array(repeating: 0, count: Self.meterBarCount)
        self.router = FrameRouter(segmenter: SilenceSegmenter(silenceGap: gap))
        // Frame path: serial source queue → router → WAL io queue. No main hop.
        source.onFrame = { [router] frame in router.route(frame) }
        source.onState = { [weak self] state in
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
        loadExisting()
        pruneOldAudio()      // retention sweep on launch (keeps transcripts, prunes safe-in-Lore audio)
        startDrainTimer()
    }

    /// The durable conversation metadata (start/end/location) for a capture, for
    /// the timeline card (F1). `nil` for captures recorded before this shipped.
    public func conversationMeta(for captureId: String) -> ConversationMeta? {
        ConversationMetaStore.load(captureId: captureId, baseDir: baseDir)
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
        let poller = CaptureStatusPoller(captureId: captureId, client: client)
        pollers[captureId] = poller
        return poller
    }

    public var pendingSegments: Int { captures.reduce(0) { $0 + $1.status.pendingSegments } }
    public var hasPending: Bool { pendingSegments > 0 }
    public var isCapturing: Bool { active != nil && !isPaused }

    /// Begin the source's connect flow (app: start scanning / auto-reconnect the
    /// saved Omi). Call from the screen's onAppear.
    public func startSource() { source.start() }
    public func stopSource() { source.stop() }

    // MARK: ambient session lifecycle (driven by the source, not a button)

    private func onSourceState(_ state: AudioSourceState) {
        sourceState = state
        switch state {
        case .streaming:
            if active == nil { router.resetSegmenter(); beginSession() }  // ambient capture
        case .stopped, .failed:
            endSession()                          // disconnected → end the session
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
        // door's `capturedAt`. Idempotent (won't clobber an existing record).
        ConversationMetaStore.recordStart(captureId: id, baseDir: baseDir, at: nowUnixSecs())
        wal.beginStreaming()
        router.resetLevelMeter()                  // fresh Opus decoder per conversation
        router.setPaused(isPaused)
        router.setWAL(wal)                        // frames now flow into this WAL
        log?.info("capture \(id): ambient session started")
    }

    private func endSession() {
        router.setWAL(nil)
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

    public func pause() { isPaused = true; router.setPaused(true); log?.info("capture: paused") }
    public func resume() { isPaused = false; router.setPaused(false); log?.info("capture: resumed") }
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
        pruneOldAudio()   // periodic retention sweep (cheap: stats files, only acts >30d)
    }

    // MARK: retention (prune local audio after 30d once it's safe in Lore — keep the transcript)

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
            let hasTranscript = TranscriptCacheStore.hasCachedTranscript(captureId: id, baseDir: baseDir)
            guard CaptureRetention.shouldPruneAudio(newestSegmentAge: age,
                                                    confirmedInLore: confirmed,
                                                    hasCachedTranscript: hasTranscript) else { continue }
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

/// Persisted capture preferences (UserDefaults). Currently the silence-gap that
/// drives auto-segmentation (req 9); default ~2 min, à la Omi.
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
}
