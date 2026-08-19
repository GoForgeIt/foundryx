import XCTest
import Foundation
@testable import FoundryXKit

/// All-time metadata + 14-day transcript cache + load-on-demand (track 20260627):
///   • EVERY conversation shows a name + description from a durable card tombstone,
///     and stays browsable even after its transcript text AND audio were pruned.
///   • RECENT (~14d) conversations have their transcript fetched + cached on sight.
///   • OLDER conversations are NOT auto-fetched — they load on demand.
/// Door-free: the content fetch is injected, the rest is disk-backed.
@MainActor
final class ConversationCardCacheTests: XCTestCase {

    private let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
    private let day: TimeInterval = 24 * 60 * 60

    private func tempDir(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Records the capture ids a content fetch was requested for.
    final class FetchRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _ids: [String] = []
        let response: CaptureContent?
        init(response: CaptureContent?) { self.response = response }
        var ids: [String] { lock.lock(); defer { lock.unlock() }; return _ids }
        func fetch(_ id: String) -> CaptureContent? { lock.lock(); _ids.append(id); lock.unlock(); return response }
    }

    /// Seed a capture dir: optional aged segment+ack, conversation start age, and
    /// (optionally) a cached transcript + lore-confirmed marker.
    private func seed(_ id: String, baseDir: URL,
                      startedDaysAgo: Double,
                      segmentDaysAgo: Double? = nil,
                      transcript: CachedTranscript? = nil) throws {
        let cdir = baseDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        let started = UInt64(max(0, Date().timeIntervalSince1970 - startedDaysAgo * day))
        ConversationMetaStore.save(ConversationMeta(startedAt: started, endedAt: started + 60),
                                   captureId: id, baseDir: baseDir)
        if let segDays = segmentDaysAgo {
            let seg = cdir.appendingPathComponent(CaptureWAL.segName(0))
            try Data([1, 2, 3, 4]).write(to: seg)
            try Data().write(to: seg.deletingPathExtension().appendingPathExtension("ack"))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -segDays * day)], ofItemAtPath: seg.path)
        }
        if let t = transcript { TranscriptCacheStore.save(t, captureId: id, baseDir: baseDir) }
    }

    private // Deadline is generous ON PURPOSE. The `flake` gate runs this suite a second time
    // under deliberately induced CPU load, where a capture session can be starved for
    // seconds. A 3s bound there tested the SCHEDULER, not the behaviour — it made the
    // flake gate fail ~70% of the time on a clean main, which trains everyone to ignore
    // the one gate whose job is catching real flakiness (track 20260726T0030).
    // The assertion is unchanged: the condition must still become true.
    func waitUntil(timeout: TimeInterval = 300, _ cond: () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: list shows name + description for ALL conversations (durable tombstone)

    func testOldConversationStaysBrowsableWithNameAndDescriptionAfterPruning() async throws {
        let dir = try tempDir("alltime")
        defer { try? FileManager.default.removeItem(at: dir) }
        // A 40-day-old conversation: transcript text cached + confirmed in Lore, audio
        // present but also 40 days old (so it's eligible for the 30-day audio prune).
        try seed("old-1", baseDir: dir, startedDaysAgo: 40, segmentDaysAgo: 40,
                 transcript: CachedTranscript(transcript: "long ago we spoke about the harvest",
                                              title: "Harvest planning",
                                              summary: "We planned the autumn harvest schedule.",
                                              fetchedAt: 1))

        // init runs loadExisting + pruneOldTranscripts (>14d) + pruneOldAudio (>30d).
        let mgr = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []),
                                 fetchContent: { _ in nil })
        await mgr.hydration?.value

        // The transcript TEXT is pruned, the audio is pruned…
        XCTAssertFalse(TranscriptCacheStore.hasCachedTranscript(captureId: "old-1", baseDir: dir),
                       "transcript text >14d is pruned")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("old-1").appendingPathComponent(CaptureWAL.segName(0)).path),
            "audio >30d (confirmed + tombstone) is pruned")
        // …but the lightweight name/description survives, and it's still in the list.
        let card = try XCTUnwrap(mgr.cardMeta(for: "old-1"), "the durable card tombstone survives pruning")
        XCTAssertEqual(card.title, "Harvest planning", "the NAME is kept for the list")
        XCTAssertEqual(card.summary, "We planned the autumn harvest schedule.", "the DESCRIPTION is kept")
        XCTAssertTrue(mgr.visibleCaptures.contains { $0.captureId == "old-1" },
                      "an all-time conversation stays browsable after audio + transcript are pruned")
    }

    // MARK: recent (~14d) transcript cached on sight

    func testRecentTranscriptCachedOnSight() async throws {
        let dir = try tempDir("recent")
        defer { try? FileManager.default.removeItem(at: dir) }
        try seed("recent-1", baseDir: dir, startedDaysAgo: 3)   // within the 14-day window
        let rec = FetchRecorder(response: CaptureContent(
            transcript: "this morning's standup", capturedAt: 100, found: true,
            title: "Standup", summary: "Daily standup notes."))

        let mgr = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []),
                                 fetchContent: { rec.fetch($0) })

        mgr.ensureRecentTranscriptCached("recent-1")   // "on sight"
        try await waitUntil { TranscriptCacheStore.hasCachedTranscript(captureId: "recent-1", baseDir: dir) }

        let cached = try XCTUnwrap(TranscriptCacheStore.load(captureId: "recent-1", baseDir: dir))
        XCTAssertEqual(cached.transcript, "this morning's standup", "recent transcript cached locally")
        let card = try XCTUnwrap(ConversationCardStore.load(captureId: "recent-1", baseDir: dir))
        XCTAssertEqual(card.title, "Standup")
        XCTAssertEqual(card.summary, "Daily standup notes.", "card tombstone seeded from the fetch")
    }

    // MARK: older conversations are NOT auto-cached on sight (load on demand instead)

    func testOlderConversationNotCachedOnSight() async throws {
        let dir = try tempDir("older")
        defer { try? FileManager.default.removeItem(at: dir) }
        try seed("older-1", baseDir: dir, startedDaysAgo: 20)   // outside the 14-day window
        let rec = FetchRecorder(response: CaptureContent(
            transcript: "should not be fetched", capturedAt: 1, found: true))

        let mgr = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []),
                                 fetchContent: { rec.fetch($0) })

        mgr.ensureRecentTranscriptCached("older-1")
        // Give any (erroneously spawned) fetch a chance to run.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(rec.ids.isEmpty, "older conversation is NOT auto-fetched — it loads on demand")
        XCTAssertFalse(TranscriptCacheStore.hasCachedTranscript(captureId: "older-1", baseDir: dir),
                       "no transcript cached on sight for an older conversation")
    }
}

// MARK: - the reason a voice note died outlives the poller that heard it

/// THE DURABLE HALF OF "A FAILED TRANSCRIPTION SAYS WHY".
///
/// `CaptureStatusPoller` publishes Lore's terminal drop reason, and then stops: it is a
/// live object bound to a card on screen. The detail view opens later, joins from the
/// durable `card.json` tombstone, and had nothing to read — so `CaptureJourneyReading.detail`
/// hardcoded `droppedReason: nil` and every failed voice note showed the generic
/// "Transcription failed." while the specific reason was thrown away on every poll.
final class ConversationCardDroppedReasonTests: XCTestCase {

    private func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cardreason-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testTheDropReasonIsPersistedAndSurvivesAReload() throws {
        let dir = try tempDir("persist")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(ConversationCardStore.merge(captureId: "cap-1", baseDir: dir,
                                                  stage: "failed",
                                                  droppedReason: "silent_no_transcript"))
        let card = try XCTUnwrap(ConversationCardStore.load(captureId: "cap-1", baseDir: dir))
        XCTAssertEqual(card.stage, "failed")
        XCTAssertEqual(card.droppedReason, "silent_no_transcript",
                       "the reason was not written to the tombstone the detail view reads")
        // And it reaches the sentence, through the join the app actually uses.
        let journey = CaptureJourney.build(.detail(
            status: nil, brain: .foundryCloud, transfer: .none, cardStage: card.stage,
            content: nil, hasTranscript: false, separatedSpeakers: 0, hasSummary: false,
            synthesizingSummary: false, decisions: [], actions: .empty,
            droppedReason: card.droppedReason))
        XCTAssertEqual(journey.step(.transcript)?.detail, "No speech detected")
    }

    /// A repeat poll with the same reason must not churn the card (the merge is
    /// change-gated, and a false "wrote" rebuilds the whole list).
    func testARepeatedReasonDoesNotRewriteTheCard() throws {
        let dir = try tempDir("idempotent")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(ConversationCardStore.merge(captureId: "cap-2", baseDir: dir,
                                                  stage: "failed", droppedReason: "noise"))
        XCTAssertFalse(ConversationCardStore.merge(captureId: "cap-2", baseDir: dir,
                                                   stage: "failed", droppedReason: "noise"),
                       "an unchanged poll rewrote the card")
    }

    /// A card written before this field existed still decodes, with no reason.
    func testACardWrittenBeforeTheFieldExistedStillDecodes() throws {
        let dir = try tempDir("legacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let capDir = dir.appendingPathComponent("cap-3", isDirectory: true)
        try FileManager.default.createDirectory(at: capDir, withIntermediateDirectories: true)
        try Data(#"{"title":"Old one","stage":"failed","updated_at":1}"#.utf8)
            .write(to: capDir.appendingPathComponent("card.json"))
        let card = try XCTUnwrap(ConversationCardStore.load(captureId: "cap-3", baseDir: dir))
        XCTAssertEqual(card.title, "Old one")
        XCTAssertNil(card.droppedReason)
    }
}
