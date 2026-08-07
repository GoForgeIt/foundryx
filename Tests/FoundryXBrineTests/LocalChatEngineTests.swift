import XCTest
import Foundation
import FoundryXKit

/// Phase 4 (track 20260705T1100): whole-library local chat. Retrieval is pure and
/// spans EVERY cached conversation (decision #6); the engine composes retrieval +
/// the LocalChatModel seam; the presentation contract carries the honesty notice +
/// waitlist button verbatim (decision #1).
final class LocalChatEngineTests: XCTestCase {

    final class FakeChatModel: LocalChatModel, @unchecked Sendable {
        var lastPrompt = ""
        var isAvailable: Bool { true }
        func respond(to prompt: String) async throws -> String {
            lastPrompt = prompt
            return "canned answer"
        }
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-localchat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func seedConversation(_ id: String, dir: URL, title: String, transcript: String,
                                  startedAt: UInt64) {
        ConversationCardStore.save(
            .init(title: title, summary: nil, stage: "ready", updatedAt: 1, startedAt: startedAt),
            captureId: id, baseDir: dir)
        TranscriptCacheStore.save(
            CachedTranscript(transcript: transcript, title: title, summary: nil, fetchedAt: 1),
            captureId: id, baseDir: dir)
    }

    func testRetrievalSpansTheWholeLibraryNotOneConversation() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        seedConversation("c-old", dir: dir, title: "Garden planning",
                         transcript: "we discussed planting tomatoes near the fence", startedAt: 100)
        seedConversation("c-mid", dir: dir, title: "Standup",
                         transcript: "the relay deploy shipped and the tomatoes joke landed", startedAt: 200)
        seedConversation("c-new", dir: dir, title: "Lunch",
                         transcript: "sandwiches and nothing else", startedAt: 300)

        let hits = LocalLibraryRetriever.retrieve(question: "what did we say about tomatoes?", baseDir: dir)
        let ids = Set(hits.map(\.captureId))
        XCTAssertTrue(ids.contains("c-old") && ids.contains("c-mid"),
                      "answers draw on EVERY matching conversation: \(ids)")
        XCTAssertFalse(ids.contains("c-new"), "irrelevant conversations are not padded in")
    }

    func testRetrievalRespectsTheContextBudget() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<10 {
            seedConversation("c\(i)", dir: dir, title: "Budget talk \(i)",
                             transcript: String(repeating: "budget planning words ", count: 200),
                             startedAt: UInt64(i))
        }
        let hits = LocalLibraryRetriever.retrieve(question: "budget planning", baseDir: dir, budget: 3_000)
        let total = hits.reduce(0) { $0 + $1.text.count }
        XCTAssertLessThanOrEqual(total, 3_000 + 1_500, "snippet text stays within the tight budget")
        XCTAssertFalse(hits.isEmpty)
    }

    func testEngineFeedsSnippetsAndReportsWhatItDrewOn() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        seedConversation("c1", dir: dir, title: "Kiln chat",
                         transcript: "the kiln model compaction question came up", startedAt: 1)
        seedConversation("c2", dir: dir, title: "Walk",
                         transcript: "we walked and talked about kiln again", startedAt: 2)

        let model = FakeChatModel()
        let engine = LocalChatEngine(baseDir: dir, model: model)
        let (text, drewOn) = try await engine.answer("what about kiln?")
        XCTAssertEqual(text, "canned answer")
        XCTAssertEqual(Set(drewOn), ["c1", "c2"], "the engine reports every conversation it used")
        XCTAssertTrue(model.lastPrompt.contains("kiln model compaction"),
                      "retrieved transcript text reaches the model prompt")
        XCTAssertTrue(model.lastPrompt.contains("what about kiln?"))
    }

    func testPresentationContractCarriesTheLockedCopy() {
        XCTAssertTrue(LocalChatPresentation.honestyNotice.contains("entirely on your phone"))
        XCTAssertTrue(LocalChatPresentation.honestyNotice.contains("upgrade to Solleva"))
        XCTAssertEqual(LocalChatPresentation.waitlistButtonTitle, "Join the waitlist")
        XCTAssertTrue(LocalChatPresentation.noAppleIntelligencePrompt.contains("make voice notes"))
    }
}
