import XCTest
import Foundation
import BrineSwiftCore
import FoundryXKit

/// FX-5A — the chat header's route control: it opens, it names the Kiln router, and a
/// completed turn reports the route that SERVED it.
///
/// Three layers, because the defect had three separate parts and each needs its own kind
/// of proof:
///
///  - Plain XCTest over the real `ChatRouteLine` — the words, and the rule that a receipt
///    beats a request.
///  - A HERMETIC Brine run of `features/chat-route-line.feature` driving the real
///    `ChatViewModel` + `ChatConversationStore` in-memory (no door, no UI, no account
///    state written anywhere).
///  - A SOURCE guard over `App/ChatScreen.swift`. `swift test` cannot compile `App/`, so
///    the claim "the header control is tappable" is proved on the rendered simulator
///    surface by `UITests/ChatHeaderRouteLineUITests`. That test does not run in this
///    gate, so this file holds the same claim in the only form this gate CAN hold it:
///    the header's route control is wrapped in a `Menu` and is not a bare `HStack`. The
///    guard is deliberately narrow — it is a tripwire for the exact regression that
///    shipped (the interactive control being deleted and replaced by inert text), not a
///    substitute for the simulator run.
final class ChatRouteLineTests: XCTestCase {

    // MARK: - unit: the words

    func testDefaultRouteIsTheKilnRouterNamed() {
        let reading = ChatRouteLine.reading(isPrivate: false, requestedTargetId: nil,
                                            resolvedTargetId: nil, models: [])
        XCTAssertEqual(reading.route, "Kiln router")
        XCTAssertEqual(reading.text, "Open · Kiln router")
        XCTAssertFalse(reading.isResolved)
        // The bug in one assertion: the header must not fall back to a word that names
        // no one. "Auto" is not a router, a model, or a decision anybody can see.
        XCTAssertFalse(reading.text.contains("Auto"),
                       "the default route is the Kiln router — 'Auto' names nobody")
    }

    func testPrivateChatStillNamesTheRouter() {
        let reading = ChatRouteLine.reading(isPrivate: true, requestedTargetId: nil,
                                            resolvedTargetId: nil, models: [])
        XCTAssertEqual(reading.text, "Private · Kiln router")
    }

    func testAResolvedRouteBeatsTheRequestedPin() {
        // The chat ASKED for Claude; Fireworks ANSWERED. The header must say Fireworks.
        // This is the assertion the shipped code could not make: `resolvedModelLabel`
        // read `Conversation.modelTargetId` and nothing else, so a turn served by
        // gpt-oss-120b could sit under a header reading "Claude Opus 4 8".
        let reading = ChatRouteLine.reading(isPrivate: false,
                                            requestedTargetId: "claude-opus-4-8",
                                            resolvedTargetId: "cloud-fireworks-chat",
                                            models: [])
        XCTAssertTrue(reading.isResolved)
        XCTAssertEqual(reading.text, "Open · answered by Cloud Fireworks Chat")
        XCTAssertFalse(reading.text.contains("Claude"),
                       "the header reported the REQUEST while a resolved route was known")
    }

    func testRequestedPinShowsUntilSomethingAnswers() {
        let reading = ChatRouteLine.reading(isPrivate: false,
                                            requestedTargetId: "claude-opus-4-8",
                                            resolvedTargetId: nil, models: [])
        XCTAssertFalse(reading.isResolved, "a pin is a request, never a receipt")
        XCTAssertEqual(reading.text, "Open · Claude Opus 4 8")
    }

    func testAResolvedRoutePrefersTheDoorsOwnLabel() {
        let reading = ChatRouteLine.reading(
            isPrivate: false, requestedTargetId: nil,
            resolvedTargetId: "accounts/fireworks/models/gpt-oss-120b",
            models: [.init(id: "accounts/fireworks/models/gpt-oss-120b", label: "GPT OSS 120B")])
        XCTAssertEqual(reading.text, "Open · answered by GPT OSS 120B")
    }

    func testBlankTargetsReadAsNoRouteRatherThanAnEmptyWord() {
        let reading = ChatRouteLine.reading(isPrivate: false, requestedTargetId: "   ",
                                            resolvedTargetId: "", models: [])
        XCTAssertEqual(reading.text, "Open · Kiln router")
        XCTAssertFalse(reading.isResolved)
    }

    // MARK: - unit: what the live model and the durable store report as "answered"

    func testViewModelReportsTheTargetOfTheLatestAnsweredTurn() {
        let model = ChatViewModel()
        XCTAssertNil(model.resolvedTargetId, "nothing has answered yet")
        model.beginUserTurn("hello")
        model.apply(.boundary(label: "routed: cloud-fireworks-chat"))
        model.apply(.assistantDelta(text: "hi"))
        XCTAssertEqual(model.resolvedTargetId, "cloud-fireworks-chat")
        // A second turn re-routes: the header follows the LATEST answer, not the first.
        model.beginUserTurn("again")
        model.apply(.boundary(label: "routed: cloud-anthropic"))
        model.apply(.assistantDelta(text: "hey"))
        XCTAssertEqual(model.resolvedTargetId, "cloud-anthropic")
    }

    func testTheAnsweredRouteSurvivesBeingWrittenBackToTheDurableList() {
        let store = ChatConversationStore()          // in-memory: no account state written
        let id = store.active!.id
        let model = ChatViewModel()
        model.beginUserTurn("hello")
        model.apply(.boundary(label: "routed: cloud-fireworks-chat"))
        model.apply(.assistantDelta(text: "hi"))
        store.setMessages(model.snapshot(), for: id)
        XCTAssertEqual(store.conversation(id)?.resolvedTargetId, "cloud-fireworks-chat",
                       "the answered route did not survive into the durable conversation")
    }

    // MARK: - unit: what may be offered as a pin

    func testOnlyAProvedRouteIsOfferedAsAPin() {
        let store = ChatConversationStore()
        let id = store.active!.id
        store.setMessages([
            .init(role: "user", text: "hi"),
            .init(role: "assistant", text: "hello", routedVia: "cloud-fireworks-chat"),
        ], for: id)
        XCTAssertEqual(store.provenTargets, ["cloud-fireworks-chat"])
        // The door's catalog is NOT a credential list — `project_chat_models` marks a
        // target credential-backed the moment it names a `connection_id`, which on a
        // hosted cell is true of `cloud-anthropic` before the tenant has ever run the
        // Claude login it needs. Offering it would offer a route the cell cannot
        // authenticate.
        XCTAssertFalse(store.provenTargets.contains("claude-opus-4-8"))
    }

    func testAChatNothingHasAnsweredOffersNoPins() {
        let store = ChatConversationStore()
        XCTAssertTrue(store.provenTargets.isEmpty,
                      "a route nothing has ever answered from is not proved")
    }

    func testProvenTargetsAreMostRecentFirstAndDeduplicated() {
        let store = ChatConversationStore()
        let first = store.active!.id
        store.setMessages([
            .init(role: "assistant", text: "a", routedVia: "cloud-fireworks-chat"),
            .init(role: "assistant", text: "b", routedVia: "cloud-anthropic"),
        ], for: first)
        let second = store.newConversation().id
        store.setMessages([
            .init(role: "assistant", text: "c", routedVia: "cloud-fireworks-chat"),
        ], for: second)
        // `setMessages` bumps a touched chat to the front, so the most recently answered
        // route leads.
        XCTAssertEqual(store.provenTargets, ["cloud-fireworks-chat", "cloud-anthropic"])
    }

    // MARK: - source guard: the header control is interactive

    /// Is the view that carries the `route-line` accessibility identifier built from a
    /// `Menu`?
    ///
    /// Scoped to ONE view declaration, not the file: take everything up to the
    /// identifier, then keep only what follows the `some View {` that opened the
    /// declaration carrying it. A `Menu` somewhere else in `ChatScreen.swift` cannot
    /// satisfy this. Returns nil when the identifier isn't in the source at all, so an
    /// absent control fails loud instead of defaulting to "interactive".
    static func routeControlIsAMenu(in code: String) -> Bool? {
        guard let id = code.range(of: "accessibilityIdentifier(\"route-line\")") else { return nil }
        let upToIdentifier = code[code.startIndex..<id.lowerBound]
        guard let declaration = upToIdentifier.range(of: "some View {", options: .backwards) else {
            return nil
        }
        return upToIdentifier[declaration.upperBound...].contains("Menu {")
    }

    /// The regression that shipped, in the only form `swift test` can hold it: the header's
    /// route control must be built from a `Menu` (which renders as a tappable button) and
    /// not from a bare `HStack` with nothing to tap.
    func testHeaderRouteControlIsAMenuNotInertText() throws {
        let source = try String(
            contentsOf: AppSourceTree.repoRoot.appendingPathComponent("App/ChatScreen.swift"),
            encoding: .utf8)
        let code = AppSourceTree.withoutComments(of: source)

        XCTAssertEqual(Self.routeControlIsAMenu(in: code), true,
                       "the header route control is not a Menu — there is nothing to tap. "
                       + "This is exactly the defect FX-5A fixes: 5b02aec replaced the "
                       + "interactive picker with a bare HStack of an Image and a Text.")
        XCTAssertTrue(code.contains("store.setModel("),
                      "nothing in App/ writes the pinned model — `ChatConversationStore."
                      + "setModel` is a dead writer again, so the picker cannot pick")
        XCTAssertTrue(code.contains("store.setSensitivity("),
                      "nothing in App/ writes the chat's sensitivity — the header's "
                      + "\"Private\"/\"Open\" word is hardcoded rather than a live reading")
        XCTAssertTrue(code.contains("ChatRouteLine.reading("),
                      "the header does not render the kit's route reading, so its words "
                      + "are a second implementation free to disagree with the tested one")
        XCTAssertTrue(code.contains("store.provenTargets"),
                      "the picker no longer offers the routes the cell has PROVED it can "
                      + "reach — it is either offering nothing or offering the door's "
                      + "catalog, which lists targets a cell holds no credential for")
    }

    /// The guard above is not vacuous: the exact shape that shipped fails it, and the
    /// shape that replaces it passes.
    func testTheSourceGuardCanGoRed() {
        let shipped = """
        private var routeLine: some View {
            HStack(spacing: GrainSpacing.x1) {
                Image(systemName: isPrivate ? "lock.fill" : "cloud")
                Text(routeLineText).grainTextStyle(.caption)
            }
            .accessibilityIdentifier("route-line")
        }
        """
        XCTAssertEqual(Self.routeControlIsAMenu(in: shipped), false,
                       "the guard would pass on the very source it exists to reject")

        let fixed = """
        private var routeLine: some View {
            Menu {
                Button { onSelectRoute(nil) } label: { Text("Kiln router") }
            } label: {
                Text(reading.text)
            }
            .accessibilityIdentifier("route-line")
        }
        """
        XCTAssertEqual(Self.routeControlIsAMenu(in: fixed), true)

        XCTAssertNil(Self.routeControlIsAMenu(in: "struct Nothing {}"),
                     "an absent route control must fail loud, not read as interactive")
    }

    // MARK: - hermetic brine

    func testChatRouteLineScenarios() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }     // Tests/FoundryXBrineTests/<file> -> package root
        let featurePath = url.appendingPathComponent("features/chat-route-line.feature").path
        let text = try String(contentsOfFile: featurePath, encoding: .utf8)
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        let world = ChatRouteLineWorld()
        let registry = StepRegistry(ChatRouteLineSteps.make(world: world))

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
        XCTAssertTrue(failures.isEmpty, "chat-route-line scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
        XCTAssertEqual(result.passed, parsed.features[0].scenarios.count, "all scenarios should pass")
    }
}

// MARK: - Brine world + steps (in-memory, no door, no account state)

final class ChatRouteLineWorld: @unchecked Sendable {
    var store = ChatConversationStore()
    var model: ChatViewModel
    var convoId = ""
    var catalog: [ModelOption] = []
    /// Set once a finished turn has been written back to the durable list — after that
    /// the header reads the DURABLE conversation, the way it does when you leave a chat
    /// and come back.
    var readFromStore = false
    var request: ChatRequest?

    init() {
        model = ChatViewModel()
        convoId = store.active!.id
    }

    /// Exactly what `ChatScreen`'s header renders: the live turn's answer when there is
    /// one, else the durable conversation's.
    var reading: ChatRouteReading {
        let convo = store.conversation(convoId)
        let resolved = readFromStore ? convo?.resolvedTargetId : model.resolvedTargetId
        return ChatRouteLine.reading(isPrivate: convo?.sensitivity == ChatConversationStore.Sensitivity.private,
                                     requestedTargetId: convo?.modelTargetId,
                                     resolvedTargetId: resolved,
                                     models: catalog)
    }
}

enum ChatRouteLineSteps {
    static func make(world: ChatRouteLineWorld) -> [StepDefinition] {
        [
            defineStep("a chat with no model pinned and no turn answered yet") { ctx, _, _ in
                world.store = ChatConversationStore()
                world.convoId = world.store.active!.id
                world.model = ChatViewModel()
                world.readFromStore = false
                return ctx
            },
            defineStep("a private chat with no model pinned and no turn answered yet") { ctx, _, _ in
                world.store = ChatConversationStore()
                world.convoId = world.store.active!.id
                world.model = ChatViewModel()
                world.readFromStore = false
                world.store.setSensitivity(ChatConversationStore.Sensitivity.private,
                                           for: world.convoId)
                return ctx
            },
            defineStep("a chat pinned to {string}") { ctx, p, _ in
                let target = try p.requireString(0)
                world.store = ChatConversationStore()
                world.convoId = world.store.active!.id
                world.model = ChatViewModel()
                world.readFromStore = false
                world.store.setModel(target, for: world.convoId)
                return ctx
            },
            defineStep("the door catalog offers {string}") { ctx, p, _ in
                world.catalog.append(.init(id: try p.requireString(0), label: ""))
                return ctx
            },
            defineStep("a turn is answered by {string}") { ctx, p, _ in
                let target = try p.requireString(0)
                world.model.beginUserTurn("hello")
                world.model.apply(.boundary(label: "routed: \(target)"))
                world.model.apply(.assistantDelta(text: "hi"))
                return ctx
            },
            defineStep("the finished turn is recorded and the chat is reopened") { ctx, _, _ in
                world.store.setMessages(world.model.snapshot(), for: world.convoId)
                world.model = ChatViewModel()          // left the chat: live state is gone
                world.readFromStore = true
                return ctx
            },
            defineStep("the route picked is the Kiln router") { ctx, _, _ in
                world.store.setModel(nil, for: world.convoId)
                world.request = world.store.chatRequest(text: "hello", for: world.convoId)
                return ctx
            },
            defineStep("the route picked is {string}") { ctx, p, _ in
                let target = try p.requireString(0)
                world.store.setModel(target, for: world.convoId)
                world.request = world.store.chatRequest(text: "hello", for: world.convoId)
                return ctx
            },

            defineCheck("the header reads {string}") { _, p, _ in
                let want = try p.requireString(0)
                let got = world.reading.text
                guard got == want else { throw ChatRouteLineError("header reads '\(got)', want '\(want)'") }
            },
            defineCheck("the header is reporting a resolved route") { _, _, _ in
                let resolved = world.reading.isResolved
                guard resolved else {
                    throw ChatRouteLineError("the header is reporting a request, not the route that answered")
                }
            },
            defineCheck("the header is not reporting a resolved route") { _, _, _ in
                let resolved = world.reading.isResolved
                guard !resolved else {
                    throw ChatRouteLineError("the header claims a resolved route when nothing has answered")
                }
            },
            defineCheck("the routes offered to pin are {string}") { _, p, _ in
                let want = [try p.requireString(0)]
                let got = world.store.provenTargets
                guard got == want else { throw ChatRouteLineError("offered \(got), want \(want)") }
            },
            defineCheck("{string} is not offered as a route to pin") { _, p, _ in
                let unwanted = try p.requireString(0)
                let got = world.store.provenTargets
                guard !got.contains(unwanted) else {
                    throw ChatRouteLineError("'\(unwanted)' is offered, but the cell has never "
                                             + "proved it can reach it")
                }
            },
            defineCheck("there are no routes offered to pin") { _, _, _ in
                let got = world.store.provenTargets
                guard got.isEmpty else { throw ChatRouteLineError("offered \(got), want none") }
            },
            defineCheck("the chat request omits its requested target") { _, _, _ in
                let req = world.request
                guard req?.requestedTarget == nil else {
                    throw ChatRouteLineError("requested_target = \(String(describing: req?.requestedTarget)), want nil")
                }
                let json = (try? JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(req)) as? [String: Any]) ?? [:]
                guard json["requested_target"] == nil else {
                    throw ChatRouteLineError("encoded JSON must OMIT requested_target for the router")
                }
            },
            defineCheck("the chat request's requested target is {string}") { _, p, _ in
                let want = try p.requireString(0)
                guard world.request?.requestedTarget == want else {
                    throw ChatRouteLineError("requested_target = \(String(describing: world.request?.requestedTarget)), want \(want)")
                }
            },
        ]
    }
}

struct ChatRouteLineError: Error { let message: String; init(_ m: String) { message = m } }
