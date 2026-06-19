// CaptureManager — owns the capture timeline: starts/stops a capture (wiring an
// AudioFrameSource → CaptureWAL), keeps the list of captures (active + past,
// resumed from disk across launches), and runs the periodic drain that retries
// any segment not yet ACK'd by the desktop (the offline/door-down resilience).
//
// The audio source is injected so the app uses OmiBleSource and Brine uses
// ReplaySource against the real door — the pipeline is identical either way.

import Foundation
#if canImport(Combine)
import Combine
#endif

@MainActor
public final class CaptureManager: ObservableObject {
    @Published public private(set) var captures: [CaptureWAL] = []
    @Published public private(set) var active: CaptureWAL?
    @Published public private(set) var sourceState: AudioSourceState = .idle

    private let target: DoorTarget
    private let baseDir: URL
    private let makeSource: (DoorLog?) -> AudioFrameSource
    private let log: DoorLog?
    private var source: AudioFrameSource?
    private var drainTimer: Timer?

    /// `makeSource` builds the audio source (the app: `{ OmiBleSource(log: $0) }`;
    /// tests: `{ _ in ReplaySource(frames: …) }`).
    public init(target: DoorTarget,
                baseDir: URL? = nil,
                log: DoorLog? = nil,
                makeSource: @escaping (DoorLog?) -> AudioFrameSource) {
        self.target = target
        self.baseDir = baseDir ?? CaptureWAL.documentsCaptures()
        self.makeSource = makeSource
        self.log = log
        loadExisting()
        startDrainTimer()
    }

    /// Total segments across all captures not yet ACK'd by the desktop.
    public var pendingSegments: Int { captures.reduce(0) { $0 + $1.status.pendingSegments } }
    public var hasPending: Bool { pendingSegments > 0 }

    // MARK: record control

    public func startCapture() {
        guard active == nil else { return }
        let id = Self.newCaptureId()
        let wal = CaptureWAL(captureId: id, target: target, baseDir: baseDir, log: log)
        let src = makeSource(log)
        src.onFrame = { [weak wal] frame in wal?.appendFrame(frame) }
        src.onState = { [weak self] state in
            Task { @MainActor in
                self?.sourceState = state
                if case .streaming = state { wal.beginStreaming() }
            }
        }
        source = src
        active = wal
        captures.insert(wal, at: 0)   // newest first (Omi-style timeline)
        wal.beginStreaming()
        src.start()
        log?.info("capture \(id): started")
    }

    public func stopCapture() {
        source?.stop()
        source = nil
        let finished = active
        finished?.finish()
        active = nil
        if let f = finished { Task { await f.sync() } }   // snappy first sync; drain timer retries
    }

    // MARK: drain (retry until every segment is ACK'd)

    private func startDrainTimer() {
        drainTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.drainPending() }
        }
    }

    /// Re-sync every capture that still has unsynced segments (offline → drains on reconnect).
    public func drainPending() async {
        for wal in captures where wal.status.pendingSegments > 0 {
            await wal.sync()
        }
    }

    // MARK: persistence (resume across launches)

    private func loadExisting() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else { return }
        let ids = dirs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
        // Newest-first by start time isn't known until the WAL loads; sort by id (id embeds a timestamp).
        for id in ids.sorted(by: >) {
            captures.append(CaptureWAL(captureId: id, target: target, baseDir: baseDir, log: log))
        }
    }

    /// Stable, allow-list-safe id (the door uses it as a directory name). Time-ordered.
    static func newCaptureId() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        let stamp = f.string(from: Date())
        let suffix = String(UUID().uuidString.prefix(8))
        return "omi-\(stamp)-\(suffix)"
    }
}
