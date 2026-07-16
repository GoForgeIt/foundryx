import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for `features/capture-upload-throughput.feature`. Drives the REAL
/// CaptureWAL drain over a large pre-seeded backlog with an INJECTED per-segment upload
/// (no network) — the same hermetic model as CaptureResumeTests / CaptureStormTests. It
/// proves the backlog drains promptly in one continuous run (not one segment per hourly
/// retry), that concurrency stays inside the bounded upload limit, and that the
/// conversation reaches zero pending segments.
final class CaptureUploadThroughputFeatureTests: XCTestCase {
    func testCaptureUploadThroughputFeature() async throws {
        let world = ThroughputWorld()
        try await BrineFeatureRunner.run("capture-upload-throughput",
                                         registry: StepRegistry(ThroughputSteps.make(world: world)))
    }
}

private final class ThroughputWorld: @unchecked Sendable {
    /// Records upload attempts + peak in-flight concurrency (mirrors CaptureStormTests).
    final class UploadRecorder: @unchecked Sendable {
        private let q = DispatchQueue(label: "foundryx.throughput-recorder")
        private var _attempts = 0
        private var _inFlight = 0
        private var _maxInFlight = 0
        var attempts: Int { q.sync { _attempts } }
        var maxInFlight: Int { q.sync { _maxInFlight } }
        func slowSuccess() async {
            q.sync { _attempts += 1; _inFlight += 1; _maxInFlight = max(_maxInFlight, _inFlight) }
            try? await Task.sleep(nanoseconds: 3_000_000)
            q.sync { _inFlight -= 1 }
        }
    }

    var dir: URL!
    var captureId = "omi-throughput-backlog"
    var rec = UploadRecorder()
    var wal: CaptureWAL!
    var backlog = 50

    func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-throughput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Seed `n` un-ACK'd segment files — a large saved backlog waiting on the phone.
    func seedBacklog(_ n: Int) throws {
        dir = try tempDir()
        let cdir = dir.appendingPathComponent(captureId, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        for seq in 0..<n {
            let name = String(format: "seg-%012llu.opus", UInt64(seq))
            try Data([UInt8(seq & 0xff), 1, 2, 3]).write(to: cdir.appendingPathComponent(name))
        }
        rec = UploadRecorder()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        wal = CaptureWAL(captureId: captureId, target: target, baseDir: dir,
                         upload: { [rec] _, _ in await rec.slowSuccess() })
    }

    func drainToDone() async {
        var out = await wal.sync()
        var guardLoops = 0
        while out == .progressed, guardLoops < 10_000 { out = await wal.sync(); guardLoops += 1 }
    }
}

private enum ThroughputSteps {
    static func make(world w: ThroughputWorld) -> [StepDefinition] {
        return [
            defineStep("a recent conversation has many saved segments waiting on the phone") { ctx, _, _ in
                try w.seedBacklog(w.backlog)
                guard w.wal.snapshot().pendingSegments == w.backlog else {
                    throw BrineStepError("expected \(w.backlog) pending, got \(w.wal.snapshot().pendingSegments)")
                }
                return ctx
            },
            defineStep("the computer door is reachable") { ctx, _, _ in ctx },   // injected upload succeeds
            defineStep("the phone starts the upload drain") { ctx, _, _ in
                await w.drainToDone(); return ctx
            },
            defineCheck("the conversation's saved segments are uploaded without waiting for hourly retries") { _, _, _ in
                // A single continuous drain uploaded every backlogged segment — no per-hour gate.
                guard w.rec.attempts >= w.backlog else {
                    throw BrineStepError("only \(w.rec.attempts)/\(w.backlog) segments uploaded in the drain")
                }
            },
            defineCheck("multiple segment uploads may be in flight within the bounded upload limit") { _, _, _ in
                guard w.rec.maxInFlight >= 2 else {
                    throw BrineStepError("uploads were not concurrent (peak in-flight \(w.rec.maxInFlight))")
                }
                guard w.rec.maxInFlight <= CaptureWAL.maxConcurrentSegmentUploads else {
                    throw BrineStepError("in-flight \(w.rec.maxInFlight) exceeded bound \(CaptureWAL.maxConcurrentSegmentUploads)")
                }
            },
            defineCheck("the conversation has no phone segments left waiting to upload") { _, _, _ in
                let pending = w.wal.snapshot().pendingSegments
                guard pending == 0 else { throw BrineStepError("\(pending) segments still pending") }
            },
        ]
    }
}
