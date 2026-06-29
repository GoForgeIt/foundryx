import XCTest
import Foundation
import BrineSwiftCore
import FoundryXKit

/// Session-based chat + model selection. Two layers:
///  - Plain XCTest unit assertions on the real ChatConversationStore + ChatRequest
///    encoding (fast, deterministic).
///  - A HERMETIC Brine run of `features/chat-sessions.feature` driving the same real
///    types in-memory (no live door) so the Gherkin scenarios are wired to real state.
final class ChatSessionTests: XCTestCase {

    // MARK: unit — store + request contract

    func testNewConversationMintsDistinctNonLegacyId() {
        let store = ChatConversationStore()              // seeds one conversation
        let existing = store.active!.id
        let convo = store.newConversation()
        XCTAssertNotEqual(convo.id, existing, "new chat must have a distinct id")
        XCTAssertNotEqual(convo.id, ChatConversationStore.legacyChatId,
                          "new chat must not reuse the legacy \"ios\" id")
        XCTAssertEqual(store.activeId, convo.id, "new chat becomes active")
        XCTAssertEqual(store.conversations.count, 2)
    }

    func testSwitchingPreservesEachHistory() {
        let store = ChatConversationStore()
        let a = store.active!.id
        store.setMessages([.init(role: "user", text: "alpha-1"),
                           .init(role: "assistant", text: "alpha-2")], for: a)
        let b = store.newConversation().id
        store.setMessages([.init(role: "user", text: "bravo-1")], for: b)

        store.select(a)
        XCTAssertEqual(store.active?.messages.map(\.text), ["alpha-1", "alpha-2"])
        store.select(b)
        XCTAssertEqual(store.active?.messages.map(\.text), ["bravo-1"])
        store.select(a)
        XCTAssertEqual(store.active?.messages.map(\.text), ["alpha-1", "alpha-2"])
    }

    func testChatRequestCarriesSelectedModelAndChatId() throws {
        let store = ChatConversationStore()
        let id = store.active!.id
        store.setModel("local-qwen3-8b", for: id)
        let req = store.chatRequest(text: "hi", for: id)
        XCTAssertEqual(req.requestedTarget, "local-qwen3-8b")
        XCTAssertEqual(req.chatId, id)

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        XCTAssertEqual(json["requested_target"] as? String, "local-qwen3-8b")
        XCTAssertEqual(json["chat_id"] as? String, id)
    }

    func testDefaultModelOmitsRequestedTarget() throws {
        let store = ChatConversationStore()
        let id = store.active!.id           // no model selected ⇒ Auto (router)
        let req = store.chatRequest(text: "hi", for: id)
        XCTAssertNil(req.requestedTarget)

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        XCTAssertNil(json["requested_target"],
                     "Auto (router) must OMIT requested_target so Kiln's router decides")
    }

    func testChatRequestCarriesSensitivityWhenPrivate() throws {
        let store = ChatConversationStore()
        let id = store.active!.id
        store.setSensitivity(ChatConversationStore.Sensitivity.private, for: id)
        let req = store.chatRequest(text: "hi", for: id)
        XCTAssertEqual(req.sensitivity, "confidential")

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        XCTAssertEqual(json["sensitivity"] as? String, "confidential")
    }

    func testDefaultOmitsSensitivity() throws {
        let store = ChatConversationStore()
        let id = store.active!.id            // Open (default) ⇒ no sensitivity on the wire
        let req = store.chatRequest(text: "hi", for: id)
        XCTAssertNil(req.sensitivity)

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        XCTAssertNil(json["sensitivity"],
                     "Open must OMIT sensitivity so the door uses its default")
    }

    func testNewConversationInheritsSensitivity() {
        let store = ChatConversationStore()
        store.setSensitivity(ChatConversationStore.Sensitivity.private, for: store.active!.id)
        let convo = store.newConversation()
        XCTAssertEqual(convo.sensitivity, "confidential",
                       "a new chat keeps the prior chat's privacy posture")
    }

    func testPersistenceRoundTrips() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-chat-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = ChatConversationStore(storageURL: url)
        let id = first.active!.id
        first.setMessages([.init(role: "user", text: "remember me")], for: id)
        first.setModel("claude-max", for: id)
        first.setSensitivity(ChatConversationStore.Sensitivity.private, for: id)

        let reloaded = ChatConversationStore(storageURL: url)
        XCTAssertEqual(reloaded.conversation(id)?.messages.first?.text, "remember me")
        XCTAssertEqual(reloaded.conversation(id)?.modelTargetId, "claude-max")
        XCTAssertEqual(reloaded.conversation(id)?.sensitivity, "confidential",
                       "privacy posture must survive reload")
    }

    func testModelOptionDecodesLabelFallback() throws {
        let data = Data(#"{"models":[{"id":"local-qwen3-8b"},{"id":"claude-max","label":"Claude"}]}"#.utf8)
        let resp = try JSONDecoder().decode(ModelsResponse.self, from: data)
        XCTAssertEqual(resp.models.map(\.id), ["local-qwen3-8b", "claude-max"])
        XCTAssertEqual(resp.models[0].label, "local-qwen3-8b")  // fell back to id
        XCTAssertEqual(resp.models[1].label, "Claude")
    }

    // MARK: hermetic brine — wire the feature scenarios to real state

    func testChatSessionScenarios() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }     // Tests/FoundryXBrineTests/<file> -> package root
        let featurePath = url.appendingPathComponent("features/chat-sessions.feature").path
        let text = try String(contentsOfFile: featurePath, encoding: .utf8)
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        let world = ChatWorld()
        let registry = StepRegistry(ChatSteps.make(world: world))

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry,
                                             resources: [], collector: { collected.append($0) })

        var failures: [String] = []
        for ev in collected {
            guard case .object(let o) = ev,
                  case .string("scenario_end")? = o["type"],
                  case .string(let status)? = o["status"], status != "passed" else { continue }
            let name: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(name): \(err)")
        }
        XCTAssertTrue(failures.isEmpty, "chat-session scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
        XCTAssertEqual(result.passed, parsed.features[0].scenarios.count, "all scenarios should pass")
    }
}

// MARK: - Brine world + steps (in-memory, no door)

final class ChatWorld: @unchecked Sendable {
    var store = ChatConversationStore()
    var existingId = ""
    var newId = ""
    var firstId = ""
    var secondId = ""
    var request: ChatRequest?
    var requestJSON: [String: Any] = [:]
}

enum ChatSteps {
    static func make(world: ChatWorld) -> [StepDefinition] {
        [
            defineStep("a conversation store with one existing conversation") { ctx, _, _ in
                world.store = ChatConversationStore()
                world.existingId = world.store.active!.id
                return ctx
            },
            defineStep("I start a new chat") { ctx, _, _ in
                world.newId = world.store.newConversation().id
                return ctx
            },
            defineCheck("the new conversation has a chat id distinct from the existing one") { _, _, _ in
                guard world.newId != world.existingId, !world.newId.isEmpty else {
                    throw ChatTestError("new id \(world.newId) not distinct from existing \(world.existingId)")
                }
            },
            defineCheck("the new conversation's chat id is not the legacy {string} id") { _, p, _ in
                let legacy = try p.requireString(0)
                guard world.newId != legacy else { throw ChatTestError("new id reused legacy \(legacy)") }
            },

            defineStep("two conversations each with their own messages") { ctx, _, _ in
                world.store = ChatConversationStore()
                world.firstId = world.store.active!.id
                world.store.setMessages([.init(role: "user", text: "first-msg")], for: world.firstId)
                world.secondId = world.store.newConversation().id
                world.store.setMessages([.init(role: "user", text: "second-msg")], for: world.secondId)
                return ctx
            },
            defineStep("I switch from the first conversation to the second and back") { ctx, _, _ in
                world.store.select(world.firstId)
                world.store.select(world.secondId)
                world.store.select(world.firstId)
                return ctx
            },
            defineCheck("each conversation still shows its own original messages") { _, _, _ in
                let first = world.store.conversation(world.firstId)?.messages.map(\.text)
                let second = world.store.conversation(world.secondId)?.messages.map(\.text)
                guard first == ["first-msg"] else { throw ChatTestError("first history changed: \(String(describing: first))") }
                guard second == ["second-msg"] else { throw ChatTestError("second history changed: \(String(describing: second))") }
            },

            defineStep("a conversation with the model {string} selected") { ctx, p, _ in
                let model = try p.requireString(0)
                world.store = ChatConversationStore()
                world.firstId = world.store.active!.id
                world.store.setModel(model, for: world.firstId)
                return ctx
            },
            defineStep("a conversation with no model selected") { ctx, _, _ in
                world.store = ChatConversationStore()
                world.firstId = world.store.active!.id
                return ctx
            },
            defineStep("I build a chat request for that conversation") { ctx, _, _ in
                let req = world.store.chatRequest(text: "hello", for: world.firstId)
                world.request = req
                world.requestJSON = (try? JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(req)) as? [String: Any]) ?? [:]
                return ctx
            },
            defineCheck("the chat request's requested_target is {string}") { _, p, _ in
                let want = try p.requireString(0)
                guard world.request?.requestedTarget == want else {
                    throw ChatTestError("requested_target = \(String(describing: world.request?.requestedTarget)), want \(want)")
                }
                guard world.requestJSON["requested_target"] as? String == want else {
                    throw ChatTestError("encoded requested_target missing/wrong")
                }
            },
            defineCheck("the chat request carries that conversation's chat id") { _, _, _ in
                guard world.request?.chatId == world.firstId else {
                    throw ChatTestError("chat_id = \(String(describing: world.request?.chatId)), want \(world.firstId)")
                }
            },
            defineCheck("the chat request omits requested_target so the router decides") { _, _, _ in
                guard world.request?.requestedTarget == nil else {
                    throw ChatTestError("expected nil requested_target, got \(String(describing: world.request?.requestedTarget))")
                }
                guard world.requestJSON["requested_target"] == nil else {
                    throw ChatTestError("encoded JSON must OMIT requested_target for the router default")
                }
            },
        ]
    }
}

struct ChatTestError: Error { let message: String; init(_ m: String) { message = m } }
