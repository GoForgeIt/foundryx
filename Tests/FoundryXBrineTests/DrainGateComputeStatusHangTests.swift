import XCTest
import Foundation
@testable import FoundryXKit

/// REGRESSION GATE for the build-286 field hang — the DOMINANT remaining stall.
///
/// Device telemetry (owner's phone, 212 conversations) produced 22 `stallstack` samples in
/// 12h; 15 of 22 symbolicate (dSYM 60BD8356) to this exact main-thread chain:
///
///     CaptureManager.drainPending()            (async)
///       → CaptureManager.drainBatch(now:)
///         → CaptureWAL.snapshot()              (== computeStatus())
///           → CaptureWAL.allSegmentURLs()      (blocked in malloc/kernel/Foundation)
///
/// Root cause: `drainBatch` used `wal.snapshot().pendingSegments > 0` as its skip guard.
/// `snapshot()` is `computeStatus()` — a FULL synchronous on-disk segment enumeration
/// (`allSegmentURLs()` = `contentsOfDirectory`) — run ON THE MAIN ACTOR, per capture, every
/// 5s drain. At 212 captures that is an O(captures × segments) directory/stat storm on
/// `com.apple.main-thread` (nav-stalls to 4161ms). But `pendingSegments` needs NO disk: it is
/// `max(0, totalSegments - syncedSegments)` off the already-@Published, in-memory `status`.
///
/// The instrument is the deterministic counter idiom this repo already uses for hang gates
/// (`mainThreadPendingDeleteDiskOpsForTests` and friends) — a HARD INTEGER, not a wall-clock
/// budget, so nothing can flake into green:
///
///   * `CaptureWAL.mainThreadComputeStatusCallsForTests` — `computeStatus()`
///     (segment-enumeration) calls made while ON the main thread. The drain gate must make 0.
///
/// CORRECTNESS IS THE OTHER HALF and is asserted just as hard: a capture WITH pending segments
/// is still selected and drained to completion; a fully-synced one is skipped. Behaviour is
/// unchanged — only cheaper. NEVER LOSE AUDIO.
@MainActor
final class DrainGateComputeStatusHangTests: XCTestCase {

    private let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")

    /// The field shape: a large backlog of already-uploaded conversations.
    private static let backlogN = 12

    private func tempDir(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Thread-safe recorder of the (capture, seq) pairs the injected upload was asked to send.
    private final class UploadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [(String, UInt64)] = []
        func send(_ id: String, _ seq: UInt64) {
            lock.lock(); _sent.append((id, seq)); lock.unlock()
        }
        var sent: [(String, UInt64)] { lock.lock(); defer { lock.unlock() }; return _sent }
        func seqs(for id: String) -> [UInt64] {
            lock.lock(); defer { lock.unlock() }; return _sent.filter { $0.0 == id }.map { $0.1 }
        }
    }

    /// Seed a capture dir with `n` segment files (seq 0…n-1); the first `ackedThrough + 1`
    /// carry a sibling `.ack` marker (−1 ⇒ none) plus a durable card/meta tombstone so the
    /// hydrate + warm path treats it as a real reloaded conversation.
    @discardableResult
    private func seedCapture(dir: URL, id: String, n: Int, ackedThrough: Int) throws -> String {
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        for seq in 0..<n {
            let name = String(format: "seg-%012llu", UInt64(seq))
            try Data([UInt8(seq & 0xff), 1, 2, 3]).write(to: cdir.appendingPathComponent("\(name).opus"))
            if seq <= ackedThrough {
                try Data().write(to: cdir.appendingPathComponent("\(name).ack"))
            }
        }
        ConversationMetaStore.save(ConversationMeta(startedAt: 1_000, endedAt: 1_060),
                                   captureId: id, baseDir: dir)
        ConversationCardStore.merge(captureId: id, baseDir: dir,
                                    title: "Conv \(id)", summary: "seeded", stage: "ready")
        return id
    }

    private func manager(_ dir: URL, rec: UploadRecorder) async -> CaptureManager {
        let m = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []),
                               fetchSegments: { _ in nil },   // old-door: no resync endpoint
                               uploadSegment: { id, seq, _ in rec.send(id, seq) })
        await m.hydration?.value   // hydration warms every capture → in-memory status is accurate
        return m
    }

    // MARK: - THE REPRO

    /// A backlog of FULLY-SYNCED captures + one drain cycle. The gate must decide "skip" from
    /// the in-memory `status.pendingSegments`, doing ZERO `computeStatus()` disk enumerations on
    /// the main actor. RED (pre-fix): the gate called `snapshot()` for each capture → N. GREEN
    /// (post-fix): 0.
    func testDrainGateDoesNoMainThreadComputeStatusOnASyncedBacklog() async throws {
        let dir = try tempDir("drain-gate-hang"); defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<Self.backlogN {
            // n segments, ALL ACK'd (ackedThrough = n-1) ⇒ pendingSegments == 0.
            try seedCapture(dir: dir, id: String(format: "omi-synced-%03d", i), n: 4, ackedThrough: 3)
        }

        let rec = UploadRecorder()
        let mgr = await manager(dir, rec: rec)
        XCTAssertEqual(mgr.pendingSegments, 0, "the whole backlog is already on the desktop")

        CaptureWAL.resetMainThreadComputeStatusCallsForTests()
        await mgr.drainPending()                              // ONE drain cycle over the backlog

        let calls = CaptureWAL.mainThreadComputeStatusCallsForTests
        print("REPRO drain-gate: N=\(Self.backlogN) mainThreadComputeStatus=\(calls)")

        XCTAssertEqual(calls, 0,
                       "the drain gate must read the in-memory status.pendingSegments — it must " +
                       "make ZERO main-thread computeStatus() segment enumerations. RED: it made " +
                       "\(calls) (one per capture — the build-286 stallstack frame)")
        XCTAssertTrue(rec.sent.isEmpty, "a fully-synced backlog uploads nothing")
    }

    // MARK: - CORRECTNESS: the cheaper gate still selects exactly the right captures

    /// A pending capture is STILL drained to completion; a fully-synced one is skipped. Same
    /// selection as the disk-scan gate — only cheaper.
    func testPendingCaptureStillDrainsAndSyncedIsSkipped() async throws {
        let dir = try tempDir("drain-gate-select"); defer { try? FileManager.default.removeItem(at: dir) }
        let pendingId = try seedCapture(dir: dir, id: "omi-pending", n: 5, ackedThrough: -1)   // ALL pending
        let syncedId  = try seedCapture(dir: dir, id: "omi-synced",  n: 5, ackedThrough: 4)    // ALL synced

        let rec = UploadRecorder()
        let mgr = await manager(dir, rec: rec)

        await mgr.drainPending()

        XCTAssertEqual(rec.seqs(for: pendingId).sorted(), [0, 1, 2, 3, 4],
                       "the capture with pending segments must be drained to completion — NEVER lose audio")
        XCTAssertTrue(rec.seqs(for: syncedId).isEmpty,
                      "a fully-synced capture must be skipped (no re-upload)")
        XCTAssertEqual(mgr.pendingSegments, 0, "after the drain nothing is left pending")
    }

    /// The active/streaming capture is ALWAYS eligible even though its in-memory
    /// `status.totalSegments` legitimately lags (mid-stream flushes don't publish), so its
    /// pending segments are still drained. This is the lag path the gate handles via
    /// `status.streaming`, so switching off the disk scan never strands a live recording.
    func testStreamingCaptureIsStillDrainedDespiteLaggingInMemoryCount() async throws {
        let dir = try tempDir("drain-gate-streaming"); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-streaming"
        let rec = UploadRecorder()

        // Manager first, over an EMPTY base dir, so hydration does NOT create a competing WAL
        // for our streaming capture (it doesn't exist on disk yet).
        let mgr = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []),
                                 fetchSegments: { _ in nil },
                                 uploadSegment: { cid, seq, _ in rec.send(cid, seq) })
        await mgr.hydration?.value

        // The live capture, with its OWN injected upload sink (the drain uses the WAL's own).
        let wal = CaptureWAL(captureId: id, target: target, baseDir: dir,
                             upload: { seq, _ in rec.send(id, seq) })
        wal.beginStreaming()   // async: publishes streaming=true with the dir still empty (total=0)
        let deadline = Date().addingTimeInterval(2)
        while !wal.status.streaming, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(wal.status.streaming, "the active capture reports streaming")

        // Segments land on disk WITHOUT a publish (the real mid-stream flush path), so the
        // in-memory status.totalSegments stays 0 — a disk scan would see 3, the counter says 0.
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        for seq in 0..<3 {
            try Data([UInt8(seq), 9, 9]).write(
                to: cdir.appendingPathComponent(String(format: "seg-%012llu.opus", UInt64(seq))))
        }
        XCTAssertEqual(wal.status.pendingSegments, 0, "the in-memory count legitimately lags mid-stream")

        mgr.attachStreamingWALForTests(wal)
        await mgr.drainPending()

        XCTAssertEqual(rec.seqs(for: id).sorted(), [0, 1, 2],
                       "a streaming capture's pending segments must still upload despite the lagging count")
    }
}
