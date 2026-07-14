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
            newestSegmentAge: thirtyOneDays, confirmedInLore: true, hasReadableTombstone: true),
            ">30d + in_lore + readable tombstone ⇒ prune")
    }

    func testNeverPrunesWhenNotConfirmedInLore() {
        XCTAssertFalse(CaptureRetention.shouldPruneAudio(
            newestSegmentAge: thirtyOneDays, confirmedInLore: false, hasReadableTombstone: true),
            "audio not confirmed in Lore ⇒ never prune (even if old + tombstone)")
    }

    func testNeverPrunesWithoutReadableTombstone() {
        XCTAssertFalse(CaptureRetention.shouldPruneAudio(
            newestSegmentAge: thirtyOneDays, confirmedInLore: true, hasReadableTombstone: false),
            "no readable tombstone ⇒ never prune (nothing browsable would survive)")
    }

    func testNeverPrunesWithinWindow() {
        XCTAssertFalse(CaptureRetention.shouldPruneAudio(
            newestSegmentAge: tenDays, confirmedInLore: true, hasReadableTombstone: true),
            "<30d ⇒ keep the audio")
    }

    // MARK: transcript-text retention (~14 days, pure decision)

    private let fifteenDays: TimeInterval = 15 * 24 * 60 * 60
    private let thirteenDays: TimeInterval = 13 * 24 * 60 * 60

    func testTranscriptIsRecentWithin14Days() {
        XCTAssertTrue(CaptureRetention.isRecentForTranscriptCache(conversationAge: thirteenDays),
                      "<14d ⇒ recent (cache the transcript on sight)")
        XCTAssertFalse(CaptureRetention.isRecentForTranscriptCache(conversationAge: fifteenDays),
                       ">14d ⇒ not recent (load on demand)")
    }

    func testTranscriptPrunesOnlyAfter14Days() {
        XCTAssertFalse(CaptureRetention.shouldPruneTranscript(conversationAge: thirteenDays),
                       "<14d ⇒ keep the transcript text")
        XCTAssertTrue(CaptureRetention.shouldPruneTranscript(conversationAge: fifteenDays),
                      ">14d ⇒ prune the transcript text (metadata kept)")
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

    func testTranscriptCacheRoundTripsSpeakerSegments() throws {
        let dir = try tempDir("retention-cache-speakers")
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = CachedTranscript(
            transcript: "Alice said hello. Bob answered.",
            title: "Speaker chat",
            summary: nil,
            segments: [
                TranscriptSegment(seq: 0, startMs: 0, endMs: 800, text: "Alice said hello.", speaker: "speaker_0"),
                TranscriptSegment(seq: 1, startMs: 900, endMs: 1400, text: "Bob answered.", speaker: "speaker_1"),
            ],
            speakers: [
                CaptureSpeaker(slot: "speaker_0", status: .confirmed, name: "Alice"),
                CaptureSpeaker(slot: "speaker_1", status: .anonymous),
            ],
            fetchedAt: 456)

        TranscriptCacheStore.save(entry, captureId: "c-speakers", baseDir: dir)

        let loaded = try XCTUnwrap(TranscriptCacheStore.load(captureId: "c-speakers", baseDir: dir))
        XCTAssertEqual(loaded, entry)
        XCTAssertEqual(loaded.segments.count, 2)
        XCTAssertEqual(loaded.speakers.first?.name, "Alice")
    }

    func testOldTranscriptCacheWithoutSpeakersStillDecodes() throws {
        let json = """
        {
          "transcript": "legacy transcript",
          "title": "Legacy",
          "summary": "Old shape",
          "fetchedAt": 123
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CachedTranscript.self, from: json)

        XCTAssertEqual(decoded.transcript, "legacy transcript")
        XCTAssertEqual(decoded.title, "Legacy")
        XCTAssertEqual(decoded.segments, [])
        XCTAssertEqual(decoded.speakers, [])
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
        // init runs loadExisting + the retention sweep (async now).
        let mgr = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []))
        await mgr.hydration?.value

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
        let mgr = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []))
        await mgr.hydration?.value

        XCTAssertTrue(segExists("old-unconfirmed", baseDir: dir),
                      "audio not safely in Lore is never deleted, however old")
    }
}
