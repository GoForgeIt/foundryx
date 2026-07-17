import XCTest
import Foundation
@testable import FoundryXKit

/// TARGET 3 (WS-B perf): first-paint. `seedWarmListRows` enumerated the ENTIRE captures dir
/// (thousands of entries incl. `.discarded` junk), sorted, then per row did 3 `fileExists` + a
/// `card.json` read — SYNCHRONOUSLY on the main actor at startup (first-paint 495ms avg /
/// 2722ms max @ N=128 on device; budget <300ms). A persisted single-file warm-rows index lets
/// launch read ONE file; the enumeration is a fallback only on index-miss.
final class WarmListIndexTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-warmindex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func target() -> DoorTarget {
        DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
    }

    /// Seed a visible capture (one ACK'd segment + a durable start + a card title).
    private func seedCapture(_ id: String, baseDir: URL, startedAt: UInt64, title: String) throws {
        let cdir = baseDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        let seg = cdir.appendingPathComponent(CaptureWAL.segName(0))
        try Data([1, 2, 3, 4]).write(to: seg)
        try Data().write(to: seg.deletingPathExtension().appendingPathExtension("ack"))
        ConversationMetaStore.save(ConversationMeta(startedAt: startedAt), captureId: id, baseDir: baseDir)
        ConversationCardStore.save(ConversationCardMeta(title: title, summary: "s", stage: "in_lore"),
                                   captureId: id, baseDir: baseDir)
    }

    // Scenario: the index round-trips (save → load).
    func testIndexRoundTrip() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rows = [
            ConversationRowLite(captureId: "a", title: "Alpha", dateLabel: "Mon"),
            ConversationRowLite(captureId: "b", title: "Beta", dateLabel: "Tue"),
        ]
        WarmListIndexStore.save(rows, baseDir: dir)
        XCTAssertEqual(WarmListIndexStore.load(baseDir: dir), rows)
    }

    // Scenario: a missing index → nil (the caller falls back to the enumeration scan).
    func testMissingIndexReturnsNil() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(WarmListIndexStore.load(baseDir: dir))
    }

    // Scenario: a corrupt index → nil (never trusts garbage).
    func testCorruptIndexReturnsNil() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{garbage".utf8).write(to: WarmListIndexStore.indexURL(baseDir: dir))
        XCTAssertNil(WarmListIndexStore.load(baseDir: dir))
    }

    // Scenario: launch seeds the FIRST paint from the index (one file), before hydration.
    @MainActor
    func testManagerSeedsFirstPaintFromIndex() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Give the index rows real capture dirs so the deleted/gone filter keeps them.
        try seedCapture("cap-1", baseDir: dir, startedAt: 3_000, title: "Real One")
        try seedCapture("cap-2", baseDir: dir, startedAt: 2_000, title: "Real Two")
        // A planted index with a DISTINCT title proves the seed came from the index file
        // (not a fresh card read).
        WarmListIndexStore.save([
            ConversationRowLite(captureId: "cap-1", title: "Indexed One", dateLabel: "L1"),
            ConversationRowLite(captureId: "cap-2", title: "Indexed Two", dateLabel: "L2"),
        ], baseDir: dir)

        // Construct the manager but DO NOT await hydration — read the synchronous first-paint seed.
        let mgr = CaptureManager(target: target(), baseDir: dir, source: ReplaySource(frames: []))
        XCTAssertEqual(mgr.listRows.map(\.captureId), ["cap-1", "cap-2"])
        XCTAssertEqual(mgr.listRows.map(\.title), ["Indexed One", "Indexed Two"],
                       "first paint came from the persisted index, not a dir enumeration")
        mgr.hydration?.cancel()
    }

    // Scenario: a deleted/gone capture in the index doesn't crash and gets filtered.
    @MainActor
    func testDeletedCaptureInIndexIsFiltered() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try seedCapture("live", baseDir: dir, startedAt: 3_000, title: "Live")
        try seedCapture("tombstoned", baseDir: dir, startedAt: 2_000, title: "Tombstoned")
        // Tombstone one; leave the other's dir entirely absent (a fully-removed capture).
        try Data().write(to: dir.appendingPathComponent("tombstoned").appendingPathComponent(".deleted"))
        WarmListIndexStore.save([
            ConversationRowLite(captureId: "live", title: "Live", dateLabel: "L"),
            ConversationRowLite(captureId: "tombstoned", title: "Tombstoned", dateLabel: "T"),
            ConversationRowLite(captureId: "gone-forever", title: "Gone", dateLabel: "G"),
        ], baseDir: dir)

        let mgr = CaptureManager(target: target(), baseDir: dir, source: ReplaySource(frames: []))
        XCTAssertEqual(mgr.listRows.map(\.captureId), ["live"],
                       "tombstoned + fully-removed captures are filtered from the seed")
        mgr.hydration?.cancel()
    }

    // Scenario: index-MISS falls back to the enumeration scan (first launch after update).
    @MainActor
    func testIndexMissFallsBackToScan() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try seedCapture("scan-1", baseDir: dir, startedAt: 3_000, title: "Scanned")
        XCTAssertNil(WarmListIndexStore.load(baseDir: dir), "no index yet")

        let mgr = CaptureManager(target: target(), baseDir: dir, source: ReplaySource(frames: []))
        XCTAssertEqual(mgr.listRows.map(\.captureId), ["scan-1"],
                       "index-miss fell back to the enumeration scan and still painted")
        XCTAssertEqual(mgr.listRows.first?.title, "Scanned")
        mgr.hydration?.cancel()
    }

    // Scenario: hydration PERSISTS the index off-main, so the next launch has a fast path.
    @MainActor
    func testHydrationPersistsIndex() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try seedCapture("h-1", baseDir: dir, startedAt: 3_000, title: "Hydrated One")
        try seedCapture("h-2", baseDir: dir, startedAt: 2_000, title: "Hydrated Two")
        XCTAssertNil(WarmListIndexStore.load(baseDir: dir))

        let mgr = CaptureManager(target: target(), baseDir: dir, source: ReplaySource(frames: []))
        await mgr.hydration?.value

        // The off-main index write is a detached task — poll for it.
        var loaded: [ConversationRowLite]?
        for _ in 0..<200 {
            loaded = WarmListIndexStore.load(baseDir: dir)
            if loaded != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(loaded?.map(\.captureId), ["h-1", "h-2"],
                       "hydration persisted the warm-rows index newest-first")
        XCTAssertEqual(loaded?.first?.title, "Hydrated One")
    }
}
