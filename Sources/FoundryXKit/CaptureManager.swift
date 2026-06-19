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
/// main actor so the source's frame callback never hops actors per frame.
final class FrameRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var wal: CaptureWAL?
    private var paused = false
    func setWAL(_ w: CaptureWAL?) { lock.lock(); wal = w; lock.unlock() }
    func setPaused(_ p: Bool) { lock.lock(); paused = p; lock.unlock() }
    func route(_ frame: Data) {
        lock.lock(); let target = paused ? nil : wal; lock.unlock()
        target?.appendFrame(frame)
    }
}

@MainActor
public final class CaptureManager: ObservableObject {
    @Published public private(set) var captures: [CaptureWAL] = []
    @Published public private(set) var active: CaptureWAL?
    @Published public private(set) var sourceState: AudioSourceState = .idle
    /// Ambient capture is paused (device stays connected; frames are dropped).
    @Published public private(set) var isPaused: Bool = false

    private let target: DoorTarget
    private let baseDir: URL
    private let log: DoorLog?
    private let source: AudioFrameSource
    private let router = FrameRouter()
    private var drainTimer: Timer?

    public init(target: DoorTarget,
                baseDir: URL? = nil,
                log: DoorLog? = nil,
                source: AudioFrameSource) {
        self.target = target
        self.baseDir = baseDir ?? CaptureWAL.documentsCaptures()
        self.log = log
        self.source = source
        // Frame path: serial source queue → router → WAL io queue. No main hop.
        source.onFrame = { [router] frame in router.route(frame) }
        source.onState = { [weak self] state in
            Task { @MainActor in self?.onSourceState(state) }
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
            if active == nil { beginSession() }   // connected + audio flowing → ambient capture
        case .stopped, .failed:
            endSession()                          // disconnected → end the session
        case .idle, .scanning:
            break
        }
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
