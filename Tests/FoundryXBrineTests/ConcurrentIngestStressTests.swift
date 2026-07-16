import XCTest
import Foundation
import FoundryXKit

/// Phase 3 — concurrent-ingest drain stress. Under a LARGE capture drained
/// concurrently, the WAL must never hold more than `maxConcurrentSegmentUploads`
/// uploads in flight at once (the guard against the FD/upload-storm class that
/// once exhausted the relay's file descriptors), and must upload every segment
/// exactly once. Hermetic — the upload closure is injected, no real network.
final class ConcurrentIngestStressTests: XCTestCase {

    /// Thread-safe max-in-flight meter: each upload enters/leaves, we track the
    /// high-water mark and the total distinct sends.
    private final class InFlightMeter: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private(set) var maxInFlight = 0
        private(set) var seqs: [UInt64] = []
        func enter(_ seq: UInt64) {
            lock.lock()
            current += 1
            if current > maxInFlight { maxInFlight = current }
            seqs.append(seq)
            lock.unlock()
        }
        func leave() { lock.lock(); current -= 1; lock.unlock() }
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func seedSegments(dir: URL, captureId: String, n: Int) throws {
        let cdir = dir.appendingPathComponent(captureId, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        for seq in 0..<n {
            let name = String(format: "seg-%012llu", UInt64(seq))
            try Data([UInt8(seq & 0xff), 1, 2, 3]).write(to: cdir.appendingPathComponent("\(name).opus"))
        }
    }

    func testLargeConcurrentDrainNeverExceedsTheInFlightCap() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-ingest-stress"
        let n = 200
        try seedSegments(dir: dir, captureId: id, n: n)

        let meter = InFlightMeter()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let wal = CaptureWAL(captureId: id, target: target, baseDir: dir,
                             upload: { seq, _ in
            meter.enter(seq)
            // Hold briefly so overlapping uploads actually coexist — otherwise a
            // fast closure would serialize and never exercise the cap.
            try? await Task.sleep(nanoseconds: 2_000_000)
            meter.leave()
        })

        // Drain to completion (each sync ships a bounded wave).
        var out = await wal.sync()
        var loops = 0
        while out == .progressed, loops < 10_000 { out = await wal.sync(); loops += 1 }

        XCTAssertLessThanOrEqual(meter.maxInFlight, CaptureWAL.maxConcurrentSegmentUploads,
            "in-flight uploads stayed within the cap under a \(n)-segment concurrent drain — no FD storm")
        XCTAssertGreaterThan(meter.maxInFlight, 1, "the drain WAS concurrent (sanity: >1 overlapped)")
        XCTAssertEqual(Set(meter.seqs).count, n, "every segment uploaded exactly once")
        XCTAssertEqual(meter.seqs.count, n, "no segment re-sent")
        XCTAssertEqual(wal.snapshot().pendingSegments, 0, "the whole capture drained")
    }
}
