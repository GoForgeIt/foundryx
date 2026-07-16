import XCTest
import Foundation
@testable import FoundryXKit

/// Merge conversations (phone side): fold several split captures into ONE. The EARLIEST
/// capture (by durable start) becomes the primary; every other source's WAL audio is
/// appended — in time order — onto it, the primary is marked pending-finalize so the door
/// RE-INGESTS the fuller audio under the primary's id, and each source is deleted (phone +
/// door + Lore). Door-free: the upload/finalize/delete seams are injected; disk is real, so
/// the WAL concat, idempotence, and guard behavior are exercised against real files.
@MainActor
final class CaptureMergeTests: XCTestCase {

    private let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")

    /// A source the test drives directly (start/stop no-ops; onState begins a session).
    private final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ id: String) { lock.lock(); _calls.append(id); lock.unlock() }
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Seed a CLOSED, saved-to-computer capture: `segments` opus files (each tagged with
    /// `tag &+ seq` as its first byte so a merge's byte order is verifiable), all `.ack`'d,
    /// with durable meta whose `startedAt` drives the primary pick + the time ordering.
    private func seed(_ id: String, baseDir: URL, segments: Int, tag: UInt8, startedAt: UInt64) throws {
        let cdir = baseDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        for seq in 0..<segments {
            let name = String(format: "seg-%012llu", UInt64(seq))
            try Data([tag &+ UInt8(seq), 0xEE]).write(to: cdir.appendingPathComponent("\(name).opus"))
            try Data().write(to: cdir.appendingPathComponent("\(name).ack"))
        }
        ConversationMetaStore.save(ConversationMeta(startedAt: startedAt, endedAt: startedAt + 60),
                                   captureId: id, baseDir: baseDir)
    }

    private func makeManager(_ dir: URL,
                             src: TestSource = TestSource(),
                             finalizes: Recorder = Recorder(),
                             deletes: Recorder = Recorder()) async -> CaptureManager {
        let m = CaptureManager(target: target, baseDir: dir, source: src,
                               finalize: { id, _ in finalizes.record(id) },
                               deleteCapture: { deletes.record($0) },
                               // Door-free: no /content, no resync dial, and a SUCCEEDING
                               // per-segment upload so the appended segments ACK + the primary
                               // reaches pending == 0 → re-ingest finalize fires deterministically.
                               fetchContent: { _ in nil },
                               fetchSegments: { _ in nil },
                               uploadSegment: { _, _, _ in })
        await m.hydration?.value
        return m
    }

    private func markerExists(_ dir: URL, _ id: String, _ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(id, isDirectory: true).appendingPathComponent(name).path)
    }

    private func firstBytes(_ dir: URL, _ id: String) throws -> [UInt8] {
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        let opus = try FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "opus" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try opus.map { try Data(contentsOf: $0).first ?? 0 }
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout {
                throw NSError(domain: "CaptureMergeTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "waitUntil timed out"])
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: the merge

    func testMergeFoldsSourcesIntoEarliestPrimaryInTimeOrder() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Three split captures, ASCENDING start times. Primary (earliest) has 2 segments; the
        // two later sources have 3 and 1. Distinct tag bytes make the concat order verifiable.
        let primary = "omi-20260101-090000-A"
        let mid     = "omi-20260101-100000-B"
        let late    = "omi-20260101-110000-C"
        try seed(primary, baseDir: dir, segments: 2, tag: 0xA0, startedAt: 1_800_000_000)
        try seed(mid,     baseDir: dir, segments: 3, tag: 0xB0, startedAt: 1_800_000_600)
        try seed(late,    baseDir: dir, segments: 1, tag: 0xC0, startedAt: 1_800_001_200)

        let finalizes = Recorder()
        let mgr = await makeManager(dir, finalizes: finalizes)
        XCTAssertEqual(mgr.visibleCaptures.count, 3)

        // Pass the ids in a SCRAMBLED order — the primary is chosen by start time, not input.
        let returned = await mgr.merge(captureIds: [late, primary, mid])
        XCTAssertEqual(returned, primary, "the earliest capture is the primary to navigate to")

        // (a) ONE capture remains, and it is the earliest id.
        XCTAssertEqual(mgr.visibleCaptures.map(\.captureId), [primary])
        XCTAssertTrue(mgr.captures.contains { $0.captureId == primary })

        // (b) the primary WAL now holds ALL segments (2 + 3 + 1) in TIME order.
        XCTAssertEqual(mgr.captures.first { $0.captureId == primary }?.snapshot().totalSegments, 6,
                       "sum of the three captures' segments")
        XCTAssertEqual(try firstBytes(dir, primary), [0xA0, 0xA1, 0xB0, 0xB1, 0xB2, 0xC0],
                       "primary audio, then mid, then late — a time-ordered concat, renumbered contiguously")

        // (c) the primary is queued for re-ingest → finalize fires under ITS id (and no other).
        XCTAssertTrue(markerExists(dir, primary, ".needs-finalize") || finalizes.calls.contains(primary),
                      "the primary is marked pending-finalize (or already finalized)")
        try await waitUntil { finalizes.calls.contains(primary) }
        XCTAssertFalse(finalizes.calls.contains(mid))
        XCTAssertFalse(finalizes.calls.contains(late))

        // (d) the two sources are gone — deleted markers on disk, and off both lists.
        for s in [mid, late] {
            XCTAssertTrue(markerExists(dir, s, ".deleted"), "\(s) carries a delete tombstone")
            XCTAssertTrue(markerExists(dir, s, ".needs-delete"), "\(s) remote delete is queued")
            XCTAssertFalse(mgr.visibleCaptures.contains { $0.captureId == s })
            XCTAssertFalse(mgr.captures.contains { $0.captureId == s })
        }
    }

    // MARK: crash-safety / idempotence + guards

    func testMergeIsIdempotentReRunIsNoOp() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = "omi-20260101-090000-A"
        let b = "omi-20260101-100000-B"
        try seed(a, baseDir: dir, segments: 2, tag: 0xA0, startedAt: 1_800_000_000)
        try seed(b, baseDir: dir, segments: 2, tag: 0xB0, startedAt: 1_800_000_600)
        let mgr = await makeManager(dir)

        let first = await mgr.merge(captureIds: [a, b])
        XCTAssertEqual(first, a)
        XCTAssertEqual(mgr.captures.first { $0.captureId == a }?.snapshot().totalSegments, 4)

        // Re-run with the SAME ids: b is deleted (not mergeable) → < 2 valid → clean no-op.
        let second = await mgr.merge(captureIds: [a, b])
        XCTAssertNil(second, "sources already folded in are deleted → a re-run is a no-op")
        XCTAssertEqual(mgr.captures.first { $0.captureId == a }?.snapshot().totalSegments, 4,
                       "the primary is NOT double-appended on re-run")
        XCTAssertEqual(mgr.visibleCaptures.map(\.captureId), [a])
    }

    /// The dangerous window: a crash AFTER a source's audio is copied onto the primary but
    /// BEFORE the source is deleted leaves the source still mergeable. A naive re-run would
    /// renumber from primary-max+1 and copy the source's audio a SECOND time — a duplicated,
    /// double-transcribed span. The pinned `.folding-<source>` marker makes the re-fold
    /// overwrite the SAME range instead, so the merged audio is present exactly once.
    func testFoldIsIdempotentAcrossCopyDoneDeleteNotCommittedCrash() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let primary = "omi-20260715-100000-PRIMARY0"
        let source = "omi-20260715-100600-SOURCE00"
        try seed(primary, baseDir: dir, segments: 2, tag: 0xA0, startedAt: 1_800_000_000)
        try seed(source, baseDir: dir, segments: 3, tag: 0xB0, startedAt: 1_800_000_600)

        // First fold: primary's 2 segs + source's 3, in order. Source NOT deleted (the crash
        // is simulated by stopping right here, before deleteConversation commits).
        XCTAssertTrue(CaptureManager.appendSourceToPrimary(primaryId: primary, sourceId: source, baseDir: dir))
        XCTAssertEqual(try firstBytes(dir, primary), [0xA0, 0xA1, 0xB0, 0xB1, 0xB2],
                       "primary holds its own 2 segs + the source's 3, time-ordered")

        // Crash-window RETRY: re-folding the same source must OVERWRITE the same range, not
        // append a duplicate — the byte sequence is unchanged (no double-transcribed span).
        XCTAssertTrue(CaptureManager.appendSourceToPrimary(primaryId: primary, sourceId: source, baseDir: dir))
        XCTAssertEqual(try firstBytes(dir, primary), [0xA0, 0xA1, 0xB0, 0xB1, 0xB2],
                       "re-run is idempotent — the source's audio appears exactly once")

        // And if the retry path already deleted the source, the pinned marker proves the
        // range is fully present → the fold reports complete without needing the source.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(source, isDirectory: true))
        XCTAssertTrue(CaptureManager.appendSourceToPrimary(primaryId: primary, sourceId: source, baseDir: dir),
                      "already-folded + source-gone still reports complete")
        XCTAssertEqual(try firstBytes(dir, primary), [0xA0, 0xA1, 0xB0, 0xB1, 0xB2])
    }

    /// A primary with a pinned fold range must NOT be resumable, or a crash-then-resume
    /// would allocate new segments into the reserved [base, base+count) range and lose audio
    /// on the re-merge. The `.folding-<source>` marker blocks resume until the merge clears it.
    func testPrimaryIsNotResumableWhileAFoldIsPending() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let primary = "omi-20260715-090000-PRIMARY0"
        let source = "omi-20260715-091000-SOURCE00"
        try seed(primary, baseDir: dir, segments: 2, tag: 0xA0, startedAt: 1_800_000_000)
        try seed(source, baseDir: dir, segments: 2, tag: 0xB0, startedAt: 1_800_000_600)
        let mgr = await makeManager(dir)

        XCTAssertTrue(mgr.canResumeRecording(captureId: primary), "resumable before any merge")

        // Simulate a fold interrupted before deleteConversation: the marker is pinned + segs
        // copied, but the source is not yet deleted (the exact crash window).
        XCTAssertTrue(CaptureManager.appendSourceToPrimary(primaryId: primary, sourceId: source, baseDir: dir))
        XCTAssertFalse(mgr.canResumeRecording(captureId: primary),
                       "a primary with a pending fold marker must NOT be resumable")

        // A completed merge deletes the source + clears the marker → resumable again.
        _ = await mgr.merge(captureIds: [primary, source])
        XCTAssertTrue(mgr.canResumeRecording(captureId: primary),
                      "after the merge completes and the marker clears, the primary is resumable again")
    }

    /// A capture old enough that the DOOR may have retention-pruned its audio (>6 days) is
    /// excluded from merge: folding it would re-upload only the new segments, so the door's
    /// replace would re-ingest only the new audio and destroy the fuller existing transcript.
    func testMergeRefusesCapturesTooOldForLosslessFold() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = UInt64(Date().timeIntervalSince1970)
        let aged = "omi-20260701-100000-AGED0000"
        let fresh = "omi-20260716-060000-FRESH000"
        try seed(aged, baseDir: dir, segments: 2, tag: 0xA0, startedAt: now - 10 * 24 * 3600)
        try seed(fresh, baseDir: dir, segments: 2, tag: 0xB0, startedAt: now - 60)
        let mgr = await makeManager(dir)

        // Aged capture excluded → only the fresh one is mergeable → fewer than two → no-op.
        let result = await mgr.merge(captureIds: [aged, fresh])
        XCTAssertNil(result, "an aged (door-pruned-risk) capture is excluded → nothing to merge")
        XCTAssertEqual(mgr.captures.first { $0.captureId == fresh }?.snapshot().totalSegments, 2,
                       "the fresh capture is untouched")
        XCTAssertTrue(mgr.visibleCaptures.contains { $0.captureId == aged }, "the aged capture survives")
    }

    func testMergeSingleOrEmptyIsSafeNoOp() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = "omi-20260101-090000-A"
        let b = "omi-20260101-100000-B"
        try seed(a, baseDir: dir, segments: 2, tag: 0xA0, startedAt: 1_800_000_000)
        try seed(b, baseDir: dir, segments: 2, tag: 0xB0, startedAt: 1_800_000_600)
        let mgr = await makeManager(dir)

        let single = await mgr.merge(captureIds: [a])
        XCTAssertNil(single, "a single id has nothing to merge")
        let empty = await mgr.merge(captureIds: [])
        XCTAssertNil(empty, "no ids is a no-op")
        let dupe = await mgr.merge(captureIds: [a, a])
        XCTAssertNil(dupe, "the same id twice de-dupes to one → no-op")
        XCTAssertEqual(mgr.visibleCaptures.count, 2, "no capture was touched")
        XCTAssertEqual(mgr.captures.first { $0.captureId == a }?.snapshot().totalSegments, 2)
        XCTAssertEqual(mgr.captures.first { $0.captureId == b }?.snapshot().totalSegments, 2)
    }

    func testMergeGuardsAgainstTheActiveCapture() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let saved = "omi-20260101-090000-A"
        try seed(saved, baseDir: dir, segments: 2, tag: 0xA0, startedAt: 1_800_000_000)
        let src = TestSource()
        let mgr = await makeManager(dir, src: src)

        // Open a LIVE recording — a fresh active capture with an id we don't control.
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let activeId = try XCTUnwrap(mgr.active?.captureId)

        // Merging the active capture with a saved one guards the active out → < 2 valid → no-op.
        let r = await mgr.merge(captureIds: [activeId, saved])
        XCTAssertNil(r, "the active capture is never merged")
        XCTAssertEqual(mgr.active?.captureId, activeId, "the live recording is untouched")
        XCTAssertFalse(markerExists(dir, saved, ".deleted"), "the saved capture was not consumed")
    }

    func testMergeSkipsDeletedAndDiscardedSources() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = "omi-20260101-090000-A"
        let deletedSrc = "omi-20260101-100000-B"
        try seed(a, baseDir: dir, segments: 2, tag: 0xA0, startedAt: 1_800_000_000)
        try seed(deletedSrc, baseDir: dir, segments: 2, tag: 0xB0, startedAt: 1_800_000_600)
        // Pre-mark the second capture deleted (a tombstone) — it must never be folded in.
        try Data().write(to: dir.appendingPathComponent(deletedSrc, isDirectory: true)
            .appendingPathComponent(".deleted"))
        let mgr = await makeManager(dir)

        let r = await mgr.merge(captureIds: [a, deletedSrc])
        XCTAssertNil(r, "a deleted capture is not mergeable → only one valid → no-op")
        XCTAssertEqual(mgr.captures.first { $0.captureId == a }?.snapshot().totalSegments, 2,
                       "the primary is unchanged")
    }
}
