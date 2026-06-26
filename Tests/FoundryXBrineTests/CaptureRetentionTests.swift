import XCTest
import Foundation
@testable import FoundryXKit

/// Retention policy (track 20260626): the phone keeps audio ~30 days, then prunes the
/// local audio BUT keeps the transcript — and ONLY prunes audio confirmed durably in
/// Lore. The prune DECISION is pure + unit-tested here; the manager's prune pass
/// (seeded from disk) is exercised end-to-end.
final class CaptureRetentionTests: XCTestCase {

    private func tempDir(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let thirtyOneDays: TimeInterval = 31 * 24 * 60 * 60
    private let tenDays: TimeInterval = 10 * 24 * 60 * 60

    // MARK: the pure decision (the four required cases)

    func testPrunesWhenOldConfirmedAndCached() {
        XCTAssertTrue(CaptureRetention.shouldPruneAudio(
            newestSegmentAge: thirtyOneDays, confirmedInLore: true, hasCachedTranscript: true),
            ">30d + in_lore + transcript ⇒ prune")
    }

    func testNeverPrunesWhenNotConfirmedInLore() {
        XCTAssertFalse(CaptureRetention.shouldPruneAudio(
            newestSegmentAge: thirtyOneDays, confirmedInLore: false, hasCachedTranscript: true),
            "audio not confirmed in Lore ⇒ never prune (even if old + transcript)")
    }

    func testNeverPrunesWithoutCachedTranscript() {
        XCTAssertFalse(CaptureRetention.shouldPruneAudio(
            newestSegmentAge: thirtyOneDays, confirmedInLore: true, hasCachedTranscript: false),
            "no cached transcript ⇒ never prune (nothing readable would survive)")
    }

    func testNeverPrunesWithinWindow() {
        XCTAssertFalse(CaptureRetention.shouldPruneAudio(
            newestSegmentAge: tenDays, confirmedInLore: true, hasCachedTranscript: true),
            "<30d ⇒ keep the audio")
    }

    // MARK: transcript cache roundtrip

    func testTranscriptCacheRoundTripAndConfirmation() throws {
        let dir = try tempDir("retention-cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(TranscriptCacheStore.hasCachedTranscript(captureId: "c1", baseDir: dir))
        XCTAssertFalse(TranscriptCacheStore.isConfirmedInLore(captureId: "c1", baseDir: dir))

        let entry = CachedTranscript(transcript: "hello world", title: "Catch-up",
                                     summary: "A short chat", fetchedAt: 123)
        TranscriptCacheStore.save(entry, captureId: "c1", baseDir: dir)

        let loaded = try XCTUnwrap(TranscriptCacheStore.load(captureId: "c1", baseDir: dir))
        XCTAssertEqual(loaded, entry)
        XCTAssertTrue(TranscriptCacheStore.hasCachedTranscript(captureId: "c1", baseDir: dir))
        XCTAssertTrue(TranscriptCacheStore.isConfirmedInLore(captureId: "c1", baseDir: dir),
                      "caching a transcript also confirms the capture reached Lore")
    }

    // MARK: end-to-end prune pass (seeded from disk)

    /// Seed a capture dir with one segment + ack, optionally aged + confirmed + cached.
    private func seedCapture(_ id: String, baseDir: URL, ageSeconds: TimeInterval,
                             confirmedAndCached: Bool) throws {
        let cdir = baseDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        let seg = cdir.appendingPathComponent(CaptureWAL.segName(0))
        try Data([1, 2, 3, 4]).write(to: seg)
        try Data().write(to: seg.deletingPathExtension().appendingPathExtension("ack"))
        // Age the segment so the retention window is crossed.
        let when = Date(timeIntervalSinceNow: -ageSeconds)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: seg.path)
        if confirmedAndCached {
            TranscriptCacheStore.save(
                CachedTranscript(transcript: "old conversation text", title: "T", summary: nil, fetchedAt: 1),
                captureId: id, baseDir: baseDir)
        }
    }

    private func segExists(_ id: String, baseDir: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: baseDir.appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(CaptureWAL.segName(0)).path)
    }

    @MainActor
    func testPruneRemovesOldConfirmedAudioButKeepsTranscript() async throws {
        let dir = try tempDir("retention-prune")
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedCapture("old-confirmed", baseDir: dir, ageSeconds: thirtyOneDays, confirmedAndCached: true)

        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        // init runs loadExisting + the retention sweep.
        _ = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []))

        XCTAssertFalse(segExists("old-confirmed", baseDir: dir), "old confirmed+cached audio is pruned")
        XCTAssertTrue(TranscriptCacheStore.hasCachedTranscript(captureId: "old-confirmed", baseDir: dir),
                      "the transcript tombstone is kept")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("old-confirmed", isDirectory: true).path),
            "the capture dir is kept as a tombstone")
    }

    @MainActor
    func testPruneLeavesUnconfirmedAudioAlone() async throws {
        let dir = try tempDir("retention-keep")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Old, but never confirmed in Lore + no cached transcript → must NOT be pruned.
        try seedCapture("old-unconfirmed", baseDir: dir, ageSeconds: thirtyOneDays, confirmedAndCached: false)

        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        _ = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []))

        XCTAssertTrue(segExists("old-unconfirmed", baseDir: dir),
                      "audio not safely in Lore is never deleted, however old")
    }
}
