import XCTest
import Foundation
import FoundryXKit

/// Resync-handshake tests (capture-sync AC1): lost ACKs (a tunnel drop mid-drain —
/// the 0.1.245 desktop restart) left the phone re-uploading audio the desktop ALREADY
/// stores (omi-20260708: 1310 segs on desktop disk, phone still counting 594+
/// "pending") at 0.5 segs/s. The fix under test: before draining a capture with
/// pending segments, the phone fetches the door's stored seq set ONCE per capture per
/// tunnel-session and bulk-marks those seqs ACK'd in the WAL — so only genuinely
/// missing segments upload. An OLD door without the endpoint (404 → nil) behaves
/// exactly as today. All door-free: the segment fetch + per-segment upload are
/// injected, no network.
final class CaptureResyncTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-resync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func target() -> DoorTarget {
        DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
    }

    /// Write `n` segment files (seq 0…n-1) into a capture dir, and `.ack` siblings for
    /// the first `ackedThrough + 1` of them (−1 ⇒ none) — the state a drain interrupted
    /// by a tunnel drop leaves on disk.
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

    /// Thread-safe recorder of the seqs the (injected) upload was asked to send.
    private final class SeqRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var seqs: [UInt64] = []
        var error: Error?
        func send(_ seq: UInt64) throws {
            lock.lock(); seqs.append(seq); let e = error; lock.unlock()
            if let e { throw e }
        }
        var sent: [UInt64] { lock.lock(); defer { lock.unlock() }; return seqs }
    }

    // MARK: WAL bulk-ACK bookkeeping (the exact mechanism a live 200 ACK uses)

    // The door reports it already stores most seqs → those flip to ACK'd (pending
    // drops) and ONLY the genuinely-missing seqs upload. The spec's scenario: desktop
    // stores 1300 of 1310, only the 10 missing transfer — scaled to 8 of 10.
    func testBulkMarkSyncedDropsPendingAndOnlyMissingSeqsUpload() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-resync-missing"
        try seedSegments(dir: dir, captureId: id, n: 10, ackedThrough: -1)   // ALL pending (lost ACKs)

        let rec = SeqRecorder()
        let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir,
                             upload: { seq, _ in try rec.send(seq) })
        XCTAssertEqual(wal.snapshot().pendingSegments, 10, "every segment starts pending")

        // The door's /segments answer: it already durably stores 0…5, 7 and 8.
        let marked = wal.bulkMarkSynced([0, 1, 2, 3, 4, 5, 7, 8])
        XCTAssertEqual(marked, 8, "each door-held seq is newly marked ACK'd")
        XCTAssertEqual(wal.snapshot().pendingSegments, 2, "pending drops to the genuinely-missing seqs")
        XCTAssertEqual(wal.uploadWatermark(), 5, "watermark advances over the contiguous ACK'd run 0…5")

        // Drain: ONLY the missing seqs (6, 9) upload — never the 8 the desktop holds.
        var out = await wal.sync()
        var guardLoops = 0
        while out == .progressed, guardLoops < 100 { out = await wal.sync(); guardLoops += 1 }
        // Order-free: segments upload concurrently (bounded), so 6 and 9 may land in
        // either order — the invariant is that ONLY the two missing seqs transfer.
        XCTAssertEqual(rec.sent.sorted(), [6, 9], "only genuinely-missing segments transfer")
        XCTAssertEqual(wal.snapshot().pendingSegments, 0)
        XCTAssertEqual(wal.uploadWatermark(), 9, "bulk-ACK'd 7,8 fold into the contiguous run")
    }

    // Already-ACK'd seqs and seqs the phone doesn't hold are ignored — the returned
    // count is ONLY the newly-marked segments (what the resync diag line reports).
    func testBulkMarkSyncedIgnoresUnknownAndAlreadyAckedSeqs() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-resync-idempotent"
        try seedSegments(dir: dir, captureId: id, n: 5, ackedThrough: 2)   // 0…2 already ACK'd

        let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir, upload: { _, _ in })
        XCTAssertEqual(wal.uploadWatermark(), 2)

        // 0…2 already ACK'd (not re-counted), 3 is new, 99 isn't on this phone.
        XCTAssertEqual(wal.bulkMarkSynced([0, 1, 2, 3, 99]), 1, "only seq 3 is newly marked")
        XCTAssertEqual(wal.snapshot().pendingSegments, 1, "seq 4 remains the only pending segment")
        XCTAssertEqual(wal.uploadWatermark(), 3, "watermark folds the new ACK into the run")

        // Re-applying the same door answer is a no-op (idempotent across drain passes).
        XCTAssertEqual(wal.bulkMarkSynced([0, 1, 2, 3, 99]), 0)
        XCTAssertEqual(wal.snapshot().pendingSegments, 1)
    }

    func testBulkMarkSyncedEmptyIsNoop() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-resync-empty"
        try seedSegments(dir: dir, captureId: id, n: 3, ackedThrough: -1)
        let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir, upload: { _, _ in })
        XCTAssertEqual(wal.bulkMarkSynced([]), 0)
        XCTAssertEqual(wal.snapshot().pendingSegments, 3, "an empty door answer changes nothing")
    }
}

// MARK: - Manager drain path: fetch ONCE per capture per tunnel-session, old-door
// tolerance, and re-fetch after a flap (AC4) — driven through the REAL drain.
@MainActor
final class CaptureResyncDrainTests: XCTestCase {

    private final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    /// Thread-safe stub of the door's /segments answer: counts fetches, can throw
    /// (transport failure) or answer nil (an old door's 404) / a fixed seq list.
    private final class SegmentsStub: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var answer: [UInt64]?
        var error: Error?
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        func fetch() throws -> [UInt64]? {
            lock.lock(); _calls += 1; let e = error; let a = answer; lock.unlock()
            if let e { throw e }
            return a
        }
    }

    private final class SeqRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _seqs: [UInt64] = []
        var error: Error?
        func send(_ seq: UInt64) throws {
            lock.lock(); _seqs.append(seq); let e = error; lock.unlock()
            if let e { throw e }
        }
        var sent: [UInt64] { lock.lock(); defer { lock.unlock() }; return _seqs }
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-resync-drain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func seedPendingCapture(dir: URL, captureId: String, n: Int) throws {
        let cdir = dir.appendingPathComponent(captureId, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        for seq in 0..<n {
            try Data([UInt8(seq & 0xff), 1, 2, 3]).write(
                to: cdir.appendingPathComponent(String(format: "seg-%012llu.opus", UInt64(seq))))
        }
    }

    private func makeManager(dir: URL, stub: SegmentsStub, rec: SeqRecorder) async -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let m = CaptureManager(target: target, baseDir: dir, source: TestSource(),
                               fetchSegments: { _ in try stub.fetch() },
                               uploadSegment: { _, seq, _ in try rec.send(seq) })
        await m.hydration?.value   // hydration is async now (startup-hang fix)
        return m
    }

    // The spec's Gherkin: Given the desktop already stores most of a capture's
    // segments, When the phone reconnects (drains), Then only the missing ones
    // transfer — and the handshake runs ONCE per capture, not on every 5s tick.
    func testDrainResyncSkipsSegmentsTheDesktopAlreadyHas() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try seedPendingCapture(dir: dir, captureId: "omi-drain-resync", n: 10)

        let stub = SegmentsStub(); stub.answer = (0...7).map(UInt64.init)   // desktop already holds 0…7
        let rec = SeqRecorder()
        let mgr = await makeManager(dir: dir, stub: stub, rec: rec)

        await mgr.drainPending()   // continuous drain empties the whole backlog in one call
        XCTAssertEqual(Set(rec.sent), [8, 9], "only the genuinely-missing segments upload (order-free: they transfer concurrently)")
        XCTAssertEqual(stub.calls, 1, "the door's seq set is fetched once for the capture")
        XCTAssertEqual(mgr.pendingSegments, 0, "the capture is fully on the desktop")

        await mgr.drainPending()
        XCTAssertEqual(stub.calls, 1, "a drained capture never re-fetches (memo holds)")
    }

    // Old-door tolerance: a 404 (nil) means no resync endpoint — the drain behaves
    // EXACTLY as today (everything uploads), with ONE probe, no error spam.
    func testOldDoorWithout404EndpointDrainsExactlyAsToday() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try seedPendingCapture(dir: dir, captureId: "omi-old-door", n: 10)

        let stub = SegmentsStub(); stub.answer = nil            // old door: 404 → nil
        let rec = SeqRecorder()
        let mgr = await makeManager(dir: dir, stub: stub, rec: rec)

        await mgr.drainPending()   // continuous drain ships the whole backlog in one call
        XCTAssertEqual(Set(rec.sent), Set(Array(0...9).map(UInt64.init)), "every segment uploads, as today")
        XCTAssertEqual(mgr.pendingSegments, 0, "nothing is left pending")
        XCTAssertEqual(stub.calls, 1, "the 404 answer is memoised — no per-tick probe spam")
    }

    // A transport failure on the handshake itself is NOT memoised — the next drain
    // pass retries it (the fetch is cheap). Under continuous drain a "next pass" only
    // exists while work remains, so pass 1 flaps fully (handshake AND uploads 503 →
    // backoff, nothing memoised); once the door is back, pass 2 re-runs the handshake.
    func testHandshakeTransportFailureRetriesNextPass() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try seedPendingCapture(dir: dir, captureId: "omi-handshake-flap", n: 10)

        let stub = SegmentsStub(); stub.error = DoorError.http(503)   // handshake unreachable
        let rec = SeqRecorder(); rec.error = DoorError.http(503)      // and uploads fail → backoff
        let mgr = await makeManager(dir: dir, stub: stub, rec: rec)

        await mgr.drainPending()
        XCTAssertEqual(stub.calls, 1, "the handshake was attempted")
        XCTAssertGreaterThan(mgr.pendingSegments, 0, "the flap left segments pending — there IS a next pass")

        // Door back: the un-memoised handshake must be retried, and this time it reports
        // the desktop already holds everything → the backlog bulk-ACKs with no re-upload.
        stub.error = nil; stub.answer = (0...9).map(UInt64.init)
        rec.error = nil
        try await Task.sleep(nanoseconds: 2_600_000_000)   // wait out the one-failure backoff
        await mgr.drainPending()
        XCTAssertEqual(stub.calls, 2, "an un-memoised handshake is retried next pass")
        XCTAssertEqual(mgr.pendingSegments, 0, "the re-fetched seq set bulk-ACKs the whole backlog")
    }

    // AC4: a dropped socket fails in-flight segments back to pending AND clears the
    // capture's memo, so the seq set is re-fetched cheaply on the next eligible pass
    // (never trusted stale across a flap).
    func testUploadFlapClearsMemoAndRefetchesAfterBackoff() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try seedPendingCapture(dir: dir, captureId: "omi-flap-refetch", n: 3)

        let stub = SegmentsStub(); stub.answer = []             // desktop has nothing yet
        let rec = SeqRecorder(); rec.error = DoorError.http(503) // socket flap: uploads fail
        let mgr = await makeManager(dir: dir, stub: stub, rec: rec)

        await mgr.drainPending()
        XCTAssertEqual(stub.calls, 1)
        let sentDuringFlap = rec.sent.count   // however many raced onto the wire before the 503

        // Reconnected: uploads work again. Wait out the failure backoff (≤ 2.5s for
        // one failure), then drain — the flap must have cleared the memo → re-fetch.
        rec.error = nil
        stub.answer = [0, 1, 2]                                  // the drop lost our ACK knowledge only
        try await Task.sleep(nanoseconds: 2_600_000_000)
        await mgr.drainPending()
        XCTAssertEqual(stub.calls, 2, "a flap clears the memo — the seq set is re-fetched on reconnect")
        XCTAssertEqual(mgr.pendingSegments, 0, "the re-fetched seq set bulk-ACKs everything (no re-upload)")
        XCTAssertEqual(rec.sent.count, sentDuringFlap, "reconnect uploads nothing new — resync bulk-ACKs the whole backlog")
    }
}
