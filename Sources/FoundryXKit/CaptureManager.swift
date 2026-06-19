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

    /// Off-main per-frame level (0…1) for the meter. Must be cheap + non-blocking.
    var onLevel: ((Float) -> Void)?
    /// Off-main conversation boundary; the owner hops to the main actor to act.
    var onSegment: ((SegmentEvent) -> Void)?

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
    func setSilenceGap(_ g: TimeInterval) { lock.lock(); segmenter.silenceGap = g; lock.unlock() }

    func route(_ frame: Data) {
        lock.lock()
        let isPaused = paused
        let target = isPaused ? nil : wal
        var level: Float = 0
        var event: SegmentEvent?
        if !isPaused {
            level = opusFrameLevel(frame)
            event = segmenter.observe(level: level, at: clock())
        }
        lock.unlock()
        target?.appendFrame(frame)
        if !isPaused {
            onLevel?(level)
            if let e = event { onSegment?(e) }
        }
    }
}

@MainActor
public final class CaptureManager: ObservableObject {
    @Published public private(set) var captures: [CaptureWAL] = []
    @Published public private(set) var active: CaptureWAL?
    @Published public private(set) var sourceState: AudioSourceState = .idle
    /// Ambient capture is paused (device stays connected; frames are dropped).
    @Published public private(set) var isPaused: Bool = false
    /// Rolling audio-level bars (0…1, oldest→newest) for the live meter (req 8).
    @Published public private(set) var levels: [Float]
    /// Silence gap (seconds) that auto-ends a conversation (req 9). Persisted.
    @Published public private(set) var silenceGapSeconds: TimeInterval

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

    public init(target: DoorTarget,
                baseDir: URL? = nil,
                log: DoorLog? = nil,
                source: AudioFrameSource) {
        self.target = target
        self.baseDir = baseDir ?? CaptureWAL.documentsCaptures()
        self.log = log
        self.source = source
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
        loadExisting()
        startDrainTimer()
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
    }

    private func beginSession() {
        let id = Self.newCaptureId()
        let wal = CaptureWAL(captureId: id, target: target, baseDir: baseDir, log: log)
        active = wal
        captures.insert(wal, at: 0)               // newest first (Omi-style timeline)
        wal.beginStreaming()
        router.setPaused(isPaused)
        router.setWAL(wal)                        // frames now flow into this WAL
        log?.info("capture \(id): ambient session started")
    }

    private func endSession() {
        router.setWAL(nil)
        guard let finished = active else { return }
        finished.finish()
        active = nil
        Task { await finished.sync() }            // snappy first sync; drain timer retries
        log?.info("capture \(finished.captureId): session ended")
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

    public func drainPending() async {
        for wal in captures where wal.status.pendingSegments > 0 { await wal.sync() }
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
