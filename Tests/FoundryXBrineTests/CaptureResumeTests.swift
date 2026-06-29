import XCTest
import Foundation
import FoundryXKit

/// Resumable-upload tests for LARGE recordings (the user's "don't lose large
/// recordings" requirement). A multi-hour Omi capture is thousands of segments; if an
/// interrupted/relaunched sync restarted from seq 0 it would re-upload everything and
/// never finish (the real `omi-20260623-202901-66651093` churn). These prove the WAL
/// resumes from a durable UPLOAD WATERMARK — the highest contiguously-ACK'd seq —
/// uploading only segments AFTER it, making MONOTONIC forward progress across retries
/// and app-restarts (a fresh WAL on the same dir), then reaching pending == 0.
///
/// All door-free: the WAL's per-segment upload is injected, no network.
final class CaptureResumeTests: XCTestCase {

    /// Thread-safe recorder of the seqs the (injected) upload was asked to send.
    private final class SeqRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var seqs: [UInt64] = []
        var failAfter: Int = .max          // throw a TRANSIENT error after this many sends
        func send(_ seq: UInt64) throws {
            lock.lock(); seqs.append(seq); let n = seqs.count; let cap = failAfter; lock.unlock()
            if n > cap { throw DoorError.http(503) }   // door transiently down
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return seqs.count }
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func target() -> DoorTarget {
        DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
    }

    /// Write `n` segment files (seq 0…n-1) into a capture dir, and `.ack` siblings for
    /// the first `ackedThrough + 1` of them (−1 ⇒ none) — the durable resume point an
    /// interrupted or pre-existing upload would leave on disk.
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

    /// Drain a WAL to completion (each `sync()` ships up to `maxSegmentsPerSync`).
    private func drainToDone(_ wal: CaptureWAL) async {
        var out = await wal.sync()
        var guardLoops = 0
        while out == .progressed, guardLoops < 10_000 { out = await wal.sync(); guardLoops += 1 }
    }

    // A pre-existing capture with the first N segments already ACK'd resumes from N+1,
    // never re-sending 0…N — the watermark is DERIVED from the on-disk `.ack` markers.
    func testResumesFromWatermarkNotZero() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-resume-watermark"
        try seedSegments(dir: dir, captureId: id, n: 10, ackedThrough: 4)   // 0…4 ACK'd

        let rec = SeqRecorder()
        let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir,
                             upload: { seq, _ in try rec.send(seq) })

        XCTAssertEqual(wal.uploadWatermark(), 4, "watermark derived from on-disk acks (contiguous run 0…4)")

        await drainToDone(wal)

        XCTAssertEqual(rec.seqs, [5, 6, 7, 8, 9], "resumes AFTER the watermark — never re-sends 0…4")
        XCTAssertEqual(wal.uploadWatermark(), 9, "watermark advances to the last segment")
        XCTAssertEqual(wal.snapshot().pendingSegments, 0, "the large capture fully uploads")
    }

    // An interrupted sync PERSISTS progress (the watermark advances over the ACK'd
    // prefix), and a fresh WAL (an app-restart) advances from there — not from 0.
    func testInterruptedSyncPersistsProgressAndNextRunAdvances() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-resume-interrupted"
        try seedSegments(dir: dir, captureId: id, n: 10, ackedThrough: -1)   // nothing ACK'd yet

        // First run fails transiently after the 3rd send → seqs 0,1,2 ACK'd, 3 fails.
        let rec1 = SeqRecorder(); rec1.failAfter = 3
        let wal1 = CaptureWAL(captureId: id, target: target(), baseDir: dir,
                              upload: { seq, _ in try rec1.send(seq) })
        let out1 = await wal1.sync()
        XCTAssertEqual(out1, .failed, "a transient door error stops the pass (not poison)")
        XCTAssertEqual(rec1.seqs, [0, 1, 2, 3], "attempted through the failing seq")
        XCTAssertEqual(wal1.uploadWatermark(), 2, "progress persisted: watermark advanced over 0,1,2")

        // Relaunch: a brand-new WAL on the same dir resumes from the persisted watermark.
        let rec2 = SeqRecorder()
        let wal2 = CaptureWAL(captureId: id, target: target(), baseDir: dir,
                              upload: { seq, _ in try rec2.send(seq) })
        XCTAssertEqual(wal2.uploadWatermark(), 2, "the fresh WAL loads the persisted watermark")

        await drainToDone(wal2)

        XCTAssertEqual(rec2.seqs, [3, 4, 5, 6, 7, 8, 9], "the next run advances past the watermark, no re-sends")
        XCTAssertEqual(wal2.snapshot().pendingSegments, 0, "the capture completes across the interruption")
    }

    // A missing/corrupt local segment file is permanent poison — the WAL reports it so
    // the owner can retire the capture (keeping the audio that remains).
    func testMissingLocalSegmentIsPoison() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-resume-poison"
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        // A segment whose .opus file is unreadable: write an entry the scanner sees, then
        // make the path a DIRECTORY (so Data(contentsOf:) throws) to simulate corruption.
        let seg = cdir.appendingPathComponent("seg-000000000000.opus")
        try FileManager.default.createDirectory(at: seg, withIntermediateDirectories: true)

        let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir,
                             upload: { _, _ in })   // upload would succeed — but the read fails first
        let out = await wal.sync()
        guard case .poisoned = out else { return XCTFail("expected .poisoned, got \(out)") }
        // The (corrupt) segment is still on disk — poison never deletes audio.
        XCTAssertTrue(FileManager.default.fileExists(atPath: seg.path), "poison keeps the data on disk")
    }
}
