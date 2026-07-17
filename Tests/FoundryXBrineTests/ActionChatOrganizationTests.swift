import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Actions link to their chats, and chats know where they came from
/// (features/action-chat-organization.feature, track 20260715T1500 EXT1-3).
///
/// The steps drive the REAL kit pieces every surface renders from: the
/// enriched ActivityStore entries (EXT1's action join), ActionChatLinkStore +
/// the Row.linkedChatId join (EXT2), and ChatConversationStore provenance +
/// ChatListOrganizer (EXT3) — file-backed in a temp dir where durability is
/// the point.
final class ActionChatOrganizationFeatureTests: XCTestCase {
    func testActionChatOrganizationScenarios() async throws {
        let world = ActionChatWorld()
        try await BrineFeatureRunner.run(
            "action-chat-organization",
            registry: StepRegistry(ActionChatSteps.make(world: world)))
    }
}

// MARK: - World

private final class ActionChatWorld: @unchecked Sendable {
    let captureId = "conv-org-1"
    let utterance = "Remind me to send Sarah the numbers section tonight"
    let summary = "Set a reminder to send Sarah the numbers section tonight"

    var dir: URL!
    var chats: ChatConversationStore!
    var entries: [ActivityEntry] = []
    var filteredList: [ChatConversationStore.Conversation] = []
    var groups: [ChatListOrganizer.SourceGroup] = []
    var row: ConversationActionsPresentation.Row?
    var legacyChat: ChatConversationStore.Conversation?

    var decisionsURL: URL { dir.appendingPathComponent("ambient-decisions.jsonl") }
    var cardsURL: URL { dir.appendingPathComponent(ConversationActions.outcomeLogFilename) }
    var chatStoreURL: URL { dir.appendingPathComponent("chat-conversations.json") }

    func reset() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-action-chat-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chats = ChatConversationStore(storageURL: chatStoreURL)
        entries = []
        filteredList = []
        groups = []
        row = nil
        legacyChat = nil
    }

    func writeCandidate(captureId: String? = nil, utterance: String? = nil,
                        summary: String? = nil, ts: UInt64 = 100) throws {
        let line = """
        {"ts":\(ts),"captureId":"\(captureId ?? self.captureId)","windowChars":480,"outcome":"candidate","candidate":{"utterance":"\(utterance ?? self.utterance)","summary":"\(summary ?? self.summary)","confidence":0.86},"latencyMs":210}
        """
        let existing = (try? String(contentsOf: decisionsURL, encoding: .utf8)) ?? ""
        try (existing + line + "\n").write(to: decisionsURL, atomically: true, encoding: .utf8)
    }

    func writeCardOutcome(_ outcome: String, seed: String) throws {
        let obj: [String: Any] = ["ts": Int(Date().timeIntervalSince1970),
                                  "outcome": outcome, "seed": String(seed.prefix(300))]
        let data = try JSONSerialization.data(withJSONObject: obj)
        let existing = (try? String(contentsOf: cardsURL, encoding: .utf8)) ?? ""
        try (existing + String(decoding: data, as: UTF8.self) + "\n")
            .write(to: cardsURL, atomically: true, encoding: .utf8)
    }

    /// The full act-in-chat send path the app performs: mint the origin-tagged
    /// chat, log the run outcome, write the action↔chat link. Returns the chat.
    @discardableResult
    func actInChatAndSend(category: String? = nil) throws -> ChatConversationStore.Conversation {
        let convo = chats.newConversation(origin: .action(
            captureId: captureId, actionKey: utterance, category: category))
        try writeCardOutcome("run", seed: utterance)
        ActionChatLinkStore.link(captureId: captureId, utterance: utterance,
                                 chatId: convo.id, baseDir: dir)
        return convo
    }

    /// A genuine re-read from disk — what every surface's reload does.
    func rebuildRow() -> ConversationActionsPresentation.Row? {
        var links = ActionChatLinkStore.links(captureId: captureId, baseDir: dir)
        // The app lazily prunes links whose chat is gone (isChatAlive).
        links = links.filter { _, chatId in chats.conversation(chatId) != nil }
        return ConversationActionsPresentation.build(
            captureId: captureId,
            decisions: AmbientLane.readDecisions(at: decisionsURL),
            outcomes: ConversationActions.readOutcomes(at: cardsURL),
            answers: [], userActions: [],
            feedback: ActionFeedbackStore.load(captureId: captureId, baseDir: dir),
            chatLinks: links).rows.first
    }

    func reloadEntries() {
        entries = ActivityStore.entries(decisionLogURL: decisionsURL, cardsLogURL: cardsURL)
    }
}

// MARK: - Steps

private enum ActionChatSteps {
    static func make(world w: ActionChatWorld) -> [StepDefinition] {
        [
            // EXT1 — the Activity surface
            defineStep("the activity ledger shows a surfaced action") { ctx, _, _ in
                try w.reset()
                try w.writeCandidate()
                w.reloadEntries()
                return ctx
            },
            defineStep("the activity ledger shows a dismissed-nudge entry") { ctx, _, _ in
                try w.reset()
                try w.writeCardOutcome("dismissed", seed: "Please help with the thing")
                w.reloadEntries()
                return ctx
            },
            defineCheck("the activity entry carries enough to act on it, reject it, or refine it") { _, _, _ in
                guard let entry = w.entries.first(where: { $0.kind == .nudgeShown }) else {
                    throw BrineStepError("no surfaced-action entry")
                }
                guard let cid = entry.actionCaptureId, entry.utterance != nil else {
                    throw BrineStepError("entry carries no action join (captureId/utterance)")
                }
                guard cid == w.captureId, entry.utterance == w.utterance else {
                    throw BrineStepError("entry joins to the wrong action")
                }
            },
            defineCheck("that entry offers no action options") { _, _, _ in
                guard let entry = w.entries.first else { throw BrineStepError("no entry") }
                guard entry.actionCaptureId == nil else {
                    throw BrineStepError("a card-outcome entry must not offer action options")
                }
            },

            // EXT2 — linkback
            defineStep("a conversation that surfaced an action") { ctx, _, _ in
                try w.reset()
                try w.writeCandidate()
                return ctx
            },
            defineStep("an action that was acted on in a chat") { ctx, _, _ in
                try w.reset()
                try w.writeCandidate()
                try w.actInChatAndSend()
                return ctx
            },
            defineStep("I act on it in chat and send the turn") { ctx, _, _ in
                try w.actInChatAndSend(category: w.pendingCategory)
                return ctx
            },
            defineStep("the actions are rebuilt from disk") { ctx, _, _ in
                w.row = w.rebuildRow()
                return ctx
            },
            defineStep("that chat is deleted") { ctx, _, _ in
                guard let chatId = ActionChatLinkStore.chatId(
                    captureId: w.captureId, utterance: w.utterance, baseDir: w.dir) else {
                    throw BrineStepError("no linked chat to delete")
                }
                w.chats.delete(chatId)
                // The app's delete affordance also forgets the links.
                ActionChatLinkStore.removeLinks(toChatId: chatId, baseDir: w.dir)
                return ctx
            },
            defineCheck("the action is linked to that chat") { _, _, _ in
                guard let linked = ActionChatLinkStore.chatId(
                    captureId: w.captureId, utterance: w.utterance, baseDir: w.dir) else {
                    throw BrineStepError("no link recorded")
                }
                guard w.chats.conversation(linked) != nil else {
                    throw BrineStepError("link points at no live chat")
                }
            },
            defineCheck("the action offers to continue in that chat instead of starting fresh") { _, _, _ in
                guard let row = w.row else { throw BrineStepError("no rebuilt row") }
                guard let linked = row.linkedChatId else {
                    throw BrineStepError("row carries no linked chat")
                }
                guard w.chats.conversation(linked) != nil else {
                    throw BrineStepError("row links a dead chat")
                }
            },
            defineCheck("the action offers to act in chat afresh") { _, _, _ in
                let row = w.rebuildRow()
                guard let row else { throw BrineStepError("no row") }
                guard row.linkedChatId == nil else {
                    throw BrineStepError("deleted chat still linked — would route to a ghost")
                }
                guard row.seed != nil else { throw BrineStepError("no fresh act-in-chat seed") }
            },

            // EXT3 — provenance
            defineStep("a conversation filed under the category {string} that surfaced an action") { ctx, p, _ in
                try w.reset()
                try w.writeCandidate()
                w.pendingCategory = try p.requireString(0)
                return ctx
            },
            defineStep("I start a new chat myself") { ctx, _, _ in
                if w.dir == nil { try w.reset() }
                w.legacyChat = w.chats.newConversation()
                return ctx
            },
            defineCheck("the chat records that it came from that conversation") { _, _, _ in
                guard let chat = w.chats.conversations.first(where: { $0.isFromConversation }) else {
                    throw BrineStepError("no conversation-born chat")
                }
                guard chat.origin?.captureId == w.captureId else {
                    throw BrineStepError("chat origin misses the source conversation")
                }
                guard chat.origin?.actionKey == ConversationActions.utteranceKey(w.utterance) else {
                    throw BrineStepError("chat origin misses the action key")
                }
            },
            defineCheck("the chat records the category {string}") { _, p, _ in
                let want = try p.requireString(0)
                guard w.chats.conversations.contains(where: { $0.origin?.category == want }) else {
                    throw BrineStepError("no chat carries category \(want)")
                }
            },
            defineCheck("the chat records when it was created") { _, _, _ in
                guard let chat = w.chats.conversations.first(where: { $0.isFromConversation }) else {
                    throw BrineStepError("no conversation-born chat")
                }
                guard abs(chat.createdAt.timeIntervalSinceNow) < 60 else {
                    throw BrineStepError("createdAt is not the creation moment")
                }
            },
            defineCheck("the chat records that I started it") { _, _, _ in
                guard let chat = w.legacyChat.flatMap({ w.chats.conversation($0.id) }) else {
                    throw BrineStepError("no chat")
                }
                guard !chat.isFromConversation else {
                    throw BrineStepError("a hand-started chat must read as mine")
                }
            },

            // EXT3 — list organization
            defineStep("chats that came from conversations and chats I started myself") { ctx, _, _ in
                try w.reset()
                _ = w.chats.newConversation(origin: .action(captureId: w.captureId))
                _ = w.chats.newConversation()  // manual
                return ctx
            },
            defineStep("conversation-born chats from the categories {string} and {string}") { ctx, p, _ in
                try w.reset()
                _ = w.chats.newConversation(origin: .action(captureId: "cap-a",
                                                            category: try p.requireString(0)))
                _ = w.chats.newConversation(origin: .action(captureId: "cap-b",
                                                            category: try p.requireString(1)))
                return ctx
            },
            defineStep("two chats born from the same conversation and one from another") { ctx, _, _ in
                try w.reset()
                _ = w.chats.newConversation(origin: .action(captureId: "cap-same"))
                _ = w.chats.newConversation(origin: .action(captureId: "cap-same"))
                _ = w.chats.newConversation(origin: .action(captureId: "cap-other"))
                return ctx
            },
            defineStep("I filter the chat list to {string}") { ctx, p, _ in
                let label = try p.requireString(0)
                guard let mode = ChatListOrganizer.Provenance(rawValue: label) else {
                    throw BrineStepError("unknown filter \(label)")
                }
                w.filteredList = ChatListOrganizer.filter(w.chats.conversations, provenance: mode)
                return ctx
            },
            defineStep("I filter the chat list to the category {string}") { ctx, p, _ in
                w.filteredList = ChatListOrganizer.filter(
                    w.chats.conversations, provenance: .fromConversations,
                    category: try p.requireString(0))
                return ctx
            },
            defineStep("the chat list is grouped by source") { ctx, _, _ in
                w.groups = ChatListOrganizer.groupedBySource(w.chats.conversations)
                return ctx
            },
            defineCheck("only the conversation-born chats remain") { _, _, _ in
                guard !w.filteredList.isEmpty,
                      w.filteredList.allSatisfy(\.isFromConversation) else {
                    throw BrineStepError("filter leaked non-conversation chats (or nothing)")
                }
            },
            defineCheck("only my own chats remain") { _, _, _ in
                guard !w.filteredList.isEmpty,
                      w.filteredList.allSatisfy({ !$0.isFromConversation }) else {
                    throw BrineStepError("filter leaked conversation-born chats (or nothing)")
                }
            },
            defineCheck("only the {string} chats remain") { _, p, _ in
                let want = try p.requireString(0)
                guard !w.filteredList.isEmpty,
                      w.filteredList.allSatisfy({ $0.origin?.category == want }) else {
                    throw BrineStepError("category filter leaked other categories (or nothing)")
                }
            },
            defineCheck("the two chats sit together under their conversation") { _, _, _ in
                guard let group = w.groups.first(where: { $0.captureId == "cap-same" }) else {
                    throw BrineStepError("no group for the shared conversation")
                }
                guard group.conversations.count == 2 else {
                    throw BrineStepError("expected 2 chats together, got \(group.conversations.count)")
                }
            },
            defineCheck("the third sits under its own") { _, _, _ in
                guard let group = w.groups.first(where: { $0.captureId == "cap-other" }),
                      group.conversations.count == 1 else {
                    throw BrineStepError("the other conversation's chat is misfiled")
                }
            },

            // Legacy compat
            defineStep("a chat saved before provenance existed") { ctx, _, _ in
                try w.reset()
                // The exact shape the store persisted before origin existed.
                let legacy = """
                {"conversations":[{"id":"legacy-1","title":"Old chat","messages":[],"createdAt":"2026-06-01T12:00:00Z","updatedAt":"2026-06-01T12:00:00Z"}],"activeId":"legacy-1"}
                """
                try legacy.write(to: w.chatStoreURL, atomically: true, encoding: .utf8)
                w.chats = ChatConversationStore(storageURL: w.chatStoreURL)
                return ctx
            },
            defineCheck("it still loads and reads as started by me") { _, _, _ in
                guard let chat = w.chats.conversation("legacy-1") else {
                    throw BrineStepError("legacy chat failed to decode")
                }
                guard !chat.isFromConversation, chat.origin == nil else {
                    throw BrineStepError("legacy chat misread as conversation-born")
                }
            },
        ]
    }
}

private extension ActionChatWorld {
    /// The category the current scenario's Given filed the conversation under.
    var pendingCategory: String? {
        get { _pendingCategory }
        set { _pendingCategory = newValue }
    }
}
private nonisolated(unsafe) var _pendingCategory: String?

// MARK: - Wire + store units

final class ChatProvenanceWireTests: XCTestCase {
    /// The first turn ships the origin fields; later turns don't repeat them.
    func testOriginRidesOnlyTheFirstTurn() throws {
        let store = ChatConversationStore()
        let convo = store.newConversation(origin: .action(
            captureId: "cap-1", actionKey: "do the thing", category: "MSCI-Work"))

        let first = store.chatRequest(text: "hello", for: convo.id)
        let firstJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(first)) as! [String: Any]
        XCTAssertEqual(firstJSON["origin"] as? String, "action")
        XCTAssertEqual(firstJSON["origin_capture_id"] as? String, "cap-1")
        XCTAssertEqual(firstJSON["origin_category"] as? String, "MSCI-Work")

        store.setMessages([.init(role: "user", text: "hello")], for: convo.id)
        let second = store.chatRequest(text: "again", for: convo.id)
        let secondJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(second)) as! [String: Any]
        XCTAssertNil(secondJSON["origin"], "session-scoped metadata must not repeat per turn")
        XCTAssertNil(secondJSON["origin_capture_id"])
        XCTAssertNil(secondJSON["origin_category"])
    }

    /// A manual chat ships no origin fields at all (the door sees the same
    /// six-field body it always did).
    func testManualChatShipsNoOriginFields() throws {
        let store = ChatConversationStore()
        let convo = store.newConversation()
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(store.chatRequest(text: "hi", for: convo.id)))
            as! [String: Any]
        XCTAssertNil(json["origin"])
        XCTAssertNil(json["origin_capture_id"])
        XCTAssertNil(json["origin_category"])
    }
}

final class ActionChatLinkStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { if let dir { try? FileManager.default.removeItem(at: dir) } }

    func testLinkRoundTripAndCaptureScoping() {
        ActionChatLinkStore.link(captureId: "c1", utterance: "same words",
                                 chatId: "chat-1", baseDir: dir)
        ActionChatLinkStore.link(captureId: "c2", utterance: "same words",
                                 chatId: "chat-2", baseDir: dir)
        XCTAssertEqual(ActionChatLinkStore.chatId(captureId: "c1", utterance: "same words",
                                                  baseDir: dir), "chat-1")
        XCTAssertEqual(ActionChatLinkStore.chatId(captureId: "c2", utterance: "same words",
                                                  baseDir: dir), "chat-2",
                       "the same sentence in two conversations keeps two links")
        XCTAssertEqual(ActionChatLinkStore.links(captureId: "c1", baseDir: dir),
                       [ConversationActions.utteranceKey("same words"): "chat-1"])
    }

    func testReActingRebindsAndRemoveForgets() {
        ActionChatLinkStore.link(captureId: "c1", utterance: "u", chatId: "chat-1", baseDir: dir)
        ActionChatLinkStore.link(captureId: "c1", utterance: "u", chatId: "chat-9", baseDir: dir)
        XCTAssertEqual(ActionChatLinkStore.chatId(captureId: "c1", utterance: "u",
                                                  baseDir: dir), "chat-9")
        ActionChatLinkStore.removeLinks(toChatId: "chat-9", baseDir: dir)
        XCTAssertNil(ActionChatLinkStore.chatId(captureId: "c1", utterance: "u", baseDir: dir))
    }

    func testCorruptFileReadsAsNoLinks() throws {
        try "not json".write(to: dir.appendingPathComponent(ActionChatLinkStore.filename),
                             atomically: true, encoding: .utf8)
        XCTAssertNil(ActionChatLinkStore.chatId(captureId: "c1", utterance: "u", baseDir: dir))
    }
}
