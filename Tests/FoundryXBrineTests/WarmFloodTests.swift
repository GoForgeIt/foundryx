import XCTest
import Combine
import Foundation
@testable import FoundryXKit

/// LIST-OPEN WARM-FLOOD (2026-07-20). Every 2–4s "capture-status-warm" main-thread hang
/// MetricKit reports on a big library collapses to one cost: the launch warm pass
/// republished EVERY hydrated capture's `@Published` status via its own
/// `DispatchQueue.main.async` — N SwiftUI card invalidations dispatched onto the main
/// thread in a burst — and did so on EVERY warm (relaunch / merge / refresh churn), even
/// when nothing changed. The fix has three deterministic, provable properties:
///
///   1. the per-capture decode/scan runs OFF the main actor and returns a status WITHOUT
///      publishing (`warmedSnapshot`), so the owner can apply the whole batch in ONE hop;
///   2. warming an UNCHANGED library a second time publishes ZERO times — no main-thread
///      work at all (idempotent per instance + no-op-skip publish) — so an empty/errored
///      door refresh can never drive a re-warm flood;
///   3. a genuinely CHANGED capture STILL re-warms (correctness is not sacrificed for the
///      memoization).
///
/// The counts here ARE the before/after: "before", a second warm of N captures published N
/// times (N main-thread invalidations); "after", it publishes 0.
final class WarmFloodTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-warmflood-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func target() -> DoorTarget {
        DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
    }

    /// Seed `n` segment files (seq 0…n-1), `.ack` siblings through `ackedThrough` (−1 ⇒ none).
    private func seedSegments(dir: URL, captureId: String, n: Int, ackedThrough: Int) throws {
        let cdir = dir.appendingPathComponent(captureId, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        for seq in 0..<n {
            let name = String(format: "seg-%012llu", UInt64(seq))
            try Data([UInt8(seq & 0xff), 1, 2, 3]).write(to: cdir.appendingPathComponent("\(name).opus"))
            if seq <= ackedThrough {
                try Data().write(to: cdir.appendingPathComponent("\(name).ack"))
            }
        }
    }

    /// Count `objectWillChange` emissions on a WAL — each is exactly one `@Published status`
    /// write, i.e. one SwiftUI invalidation on the main thread.
    private func countingSink(_ wal: CaptureWAL, into counter: @escaping () -> Void) -> AnyCancellable {
        wal.objectWillChange.sink { _ in counter() }
    }

    // 1. warmedSnapshot computes the true status OFF the main actor and does NOT publish.
    func testWarmedSnapshotComputesOffMainWithoutPublishing() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-warmflood-offmain"
        try seedSegments(dir: dir, captureId: id, n: 12, ackedThrough: 5)   // 6 synced, 12 total

        let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir)
        var publishes = 0
        let bag = countingSink(wal) { publishes += 1 }

        // Compute off the main actor (a detached task). It must NOT need the main thread and
        // must NOT mutate the @Published status.
        let snap = await Task.detached { wal.warmedSnapshot() }.value
        // Give any (erroneous) async publish a chance to land — there must be none.
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(snap.totalSegments, 12, "warmedSnapshot returns the real scanned counts")
        XCTAssertEqual(snap.syncedSegments, 6)
        XCTAssertEqual(publishes, 0, "warmedSnapshot must not publish — the owner batches the apply")
        XCTAssertEqual(wal.status.totalSegments, 0, "the @Published status is untouched by warmedSnapshot")
        _ = bag
    }

    // 2. A batch apply on the main thread publishes exactly once per capture on the FIRST
    //    warm, and a SECOND warm of the unchanged library publishes ZERO times.
    @MainActor
    func testRewarmOfUnchangedLibraryPublishesZeroTimes() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let n = 140
        var wals: [CaptureWAL] = []
        var publishes = 0
        var bag: [AnyCancellable] = []
        for i in 0..<n {
            let id = String(format: "omi-warmflood-%03d", i)
            try seedSegments(dir: dir, captureId: id, n: 8, ackedThrough: 3)
            let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir)
            bag.append(countingSink(wal) { publishes += 1 })
            wals.append(wal)
        }

        // FIRST warm — mirrors the manager batch: compute off-main, apply on main in one tick.
        let warmed = wals.map { ($0, $0.warmedSnapshot()) }
        publishes = 0
        for (wal, s) in warmed { wal.applyWarmedStatus(s) }   // on main → synchronous publish
        XCTAssertEqual(publishes, n, "first warm publishes exactly once per changed capture")

        // SECOND warm of the SAME, unchanged library — the flood that used to hang the main
        // thread on every relaunch / refresh. Now it must be a complete no-op.
        publishes = 0
        for wal in wals { wal.warmStatus() }                  // idempotent per instance → skip
        let rewarmed = wals.map { ($0, $0.warmedSnapshot()) } // recompute (unchanged)
        for (wal, s) in rewarmed { wal.applyWarmedStatus(s) } // no-op-skip publish (equal status)
        XCTAssertEqual(publishes, 0,
                       "a re-warm of an unchanged library publishes 0 times — no main-thread flood")
        _ = bag
    }

    // 3. A genuinely CHANGED capture is never hidden by the memoization: the change is
    //    published AND a fresh warm scan sees the new count (the durable cache re-armed).
    @MainActor
    func testChangedCaptureRescansAndStaysVisible() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-warmflood-changed"
        try seedSegments(dir: dir, captureId: id, n: 4, ackedThrough: 3)

        let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir, chunkFrames: 1)
        var publishes = 0
        let bag = countingSink(wal) { publishes += 1 }

        wal.warmStatus()                                  // first warm → publishes, writes cache
        XCTAssertEqual(wal.status.totalSegments, 4)
        XCTAssertGreaterThan(publishes, 0)

        publishes = 0
        wal.warmStatus()                                  // idempotent → no publish
        XCTAssertEqual(publishes, 0, "unchanged re-warm is a no-op")

        // A real change: append a segment. The write invalidates the durable status cache
        // (re-arming warmStatus) AND the append path publishes the new status itself.
        publishes = 0
        wal.appendFrame(Data([9, 9, 9]))
        wal.flushAndWait()
        XCTAssertGreaterThan(publishes, 0, "the append publishes the new status — a change is never hidden")
        XCTAssertEqual(wal.status.totalSegments, 5, "the change is visible")

        // The durable cache was invalidated: a fresh warm scan sees the NEW count (not the
        // stale cached 4) — the memoization re-armed on the real change.
        XCTAssertEqual(wal.warmedSnapshot().totalSegments, 5,
                       "a changed capture rescans — memoization never serves a stale count")
        _ = bag
    }

    // 4. Perf floor: computing the whole batch off-main + applying it in one main-thread pass
    //    stays well under a hang threshold for a 140-capture cache-hit library. This is the
    //    main-thread cost the fix bounds (the OLD path dispatched 140 async publishes here).
    @MainActor
    func testBatchApplyMainThreadTimeIsBounded() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let n = 140
        var wals: [CaptureWAL] = []
        for i in 0..<n {
            let id = String(format: "omi-warmflood-perf-%03d", i)
            try seedSegments(dir: dir, captureId: id, n: 8, ackedThrough: 8)
            let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir)
            wal.warmStatus()               // seed the durable status cache (cold pass)
            wals.append(wal)
        }
        // Fresh instances = a relaunch: warm is a cache HIT for every capture.
        let fresh = wals.map { CaptureWAL(captureId: $0.captureId, target: target(), baseDir: dir) }

        // Off-main compute (batch) — this is where the segment work would be.
        let warmed = fresh.map { ($0, $0.warmedSnapshot()) }

        // Main-thread apply in one pass — the only main-thread cost of the warm.
        let start = DispatchTime.now().uptimeNanoseconds
        for (wal, s) in warmed { wal.applyWarmedStatus(s) }
        let applyMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        print("WarmFloodTests: 140-capture batch main-thread apply = \(String(format: "%.2f", applyMs)) ms")
        XCTAssertLessThan(applyMs, 250,
                          "batch apply must stay well under the 250ms stall threshold (was a 0.6–4s flood)")
    }
}
