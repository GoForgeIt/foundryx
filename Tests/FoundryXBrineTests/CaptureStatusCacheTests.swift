import XCTest
import Foundation
@testable import FoundryXKit

/// TARGET 2 (WS-B perf): the launch WARM stat-storm. `CaptureWAL.warmStatus()` re-derived
/// every hydrated capture's segment/sync/byte state by enumerating its thousands of segment
/// files + `.ack` markers EVERY launch (capture-status-warm-n128 avg 180s, max 1780s on
/// device). A durable per-capture status cache lets a clean warm pass READ the snapshot and
/// SKIP the scan. Correctness first: a stale cache must NEVER re-upload ACK'd audio or lose
/// audio, so any doubt (missing / corrupt / mutated) falls back to a full scan.
final class CaptureStatusCacheTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-statuscache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func target() -> DoorTarget {
        DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
    }

    private func cacheURL(_ dir: URL, _ id: String) -> URL {
        dir.appendingPathComponent(id, isDirectory: true).appendingPathComponent(".status-cache.json")
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

    /// Wait for the WAL's @Published status to reflect a scan/cache publish (publish hops to main).
    private func settled(_ wal: CaptureWAL) async -> CaptureStatus {
        for _ in 0..<200 {
            if wal.status.totalSegments > 0 || wal.status.bytes > 0 { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return wal.status
    }

    // Scenario: a warm scan writes a durable cache; its counts match a real scan.
    func testWarmScanWritesCacheMatchingRealScan() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-cache-scan"
        try seedSegments(dir: dir, captureId: id, n: 8, ackedThrough: 4)   // 5 synced, 8 total

        let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir)
        let truth = wal.snapshot()   // a full scan
        XCTAssertEqual(truth.totalSegments, 8)
        XCTAssertEqual(truth.syncedSegments, 5)

        wal.warmStatus()   // cache miss → scan → writes cache
        _ = await settled(wal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL(dir, id).path),
                      "warm scan persists a durable status cache")

        // A FRESH WAL (a relaunch) warms from the cache and matches the real scan's counts.
        let wal2 = CaptureWAL(captureId: id, target: target(), baseDir: dir)
        wal2.warmStatus()
        let restored = await settled(wal2)
        XCTAssertEqual(restored.totalSegments, truth.totalSegments)
        XCTAssertEqual(restored.syncedSegments, truth.syncedSegments)
        XCTAssertEqual(restored.bytes, truth.bytes)
        XCTAssertEqual(restored.stage, .savedOnPhone, "5/8 synced ⇒ still savedOnPhone")
    }

    // Scenario: a CLEAN cache short-circuits the scan — proven by planting a cache with
    // deliberately WRONG counts and showing warm publishes those (i.e. it did NOT rescan).
    func testCleanCacheShortCircuitsScan() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-cache-shortcircuit"
        try seedSegments(dir: dir, captureId: id, n: 6, ackedThrough: 5)   // real: 6/6

        // Plant a cache claiming 99/99 — a value a real scan could never produce here.
        let planted = CaptureWAL.StatusCache(v: CaptureWAL.StatusCache.schema,
                                             totalSegments: 99, syncedSegments: 99,
                                             bytes: 12345, watermark: 98)
        try JSONEncoder().encode(planted).write(to: cacheURL(dir, id))

        let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir)
        wal.warmStatus()
        for _ in 0..<200 { if wal.status.totalSegments == 99 { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(wal.status.totalSegments, 99, "warm read the planted cache — it did NOT rescan the dir")
        XCTAssertEqual(wal.status.syncedSegments, 99)
        XCTAssertEqual(wal.status.bytes, 12345)
    }

    // Scenario: a CORRUPT cache falls back to a full scan (never trusts garbage).
    func testCorruptCacheFallsBackToScan() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-cache-corrupt"
        try seedSegments(dir: dir, captureId: id, n: 4, ackedThrough: 3)   // real: 4/4

        try Data("{not valid json".utf8).write(to: cacheURL(dir, id))

        let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir)
        wal.warmStatus()
        let s = await settled(wal)
        XCTAssertEqual(s.totalSegments, 4, "corrupt cache ignored → real scan")
        XCTAssertEqual(s.syncedSegments, 4)
        XCTAssertEqual(s.stage, .savedToComputer, "4/4 synced ⇒ savedToComputer")
    }

    // Scenario: a wrong-SCHEMA cache is ignored (auto-invalidation on shape change).
    func testWrongSchemaCacheIgnored() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-cache-schema"
        try seedSegments(dir: dir, captureId: id, n: 3, ackedThrough: 0)   // real: 1/3
        let stale = CaptureWAL.StatusCache(v: 999, totalSegments: 42, syncedSegments: 42,
                                           bytes: 7, watermark: 41)
        try JSONEncoder().encode(stale).write(to: cacheURL(dir, id))

        let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir)
        wal.warmStatus()
        let s = await settled(wal)
        XCTAssertEqual(s.totalSegments, 3, "future-schema cache ignored → real scan")
        XCTAssertEqual(s.syncedSegments, 1)
    }

    // Scenario: appending a segment INVALIDATES the cache (dirty on append).
    func testAppendInvalidatesCache() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-cache-append"
        try seedSegments(dir: dir, captureId: id, n: 2, ackedThrough: 1)

        let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir, chunkFrames: 1)
        wal.warmStatus()
        _ = await settled(wal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL(dir, id).path), "cache written by warm")

        wal.appendFrame(Data([9, 9, 9]))
        wal.flushAndWait()   // forces the buffered frame to disk (a new segment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL(dir, id).path),
                       "appending a segment invalidates the durable cache")
    }

    // Scenario: an ACK (a real sync pass) INVALIDATES the cache (dirty on ack).
    func testAckInvalidatesCache() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-cache-ack"
        try seedSegments(dir: dir, captureId: id, n: 3, ackedThrough: -1)   // nothing acked

        let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir,
                             upload: { _, _ in })   // every upload succeeds → writes acks
        wal.warmStatus()
        _ = await settled(wal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL(dir, id).path), "cache written by warm")

        _ = await wal.sync()   // acks segments → invalidation
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL(dir, id).path),
                       "an ACK invalidates the durable cache")
    }

    // Scenario: a static out-of-instance prune invalidation drops the cache.
    func testStaticInvalidationRemovesCache() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-cache-prune"
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cacheURL(dir, id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL(dir, id).path))

        CaptureWAL.invalidateStatusCache(captureDir: cdir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL(dir, id).path),
                       "prune-site invalidation removes the cache")
    }
}
