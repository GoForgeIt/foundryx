import XCTest
import Foundation
import BrineSwiftCore
import FoundryXKit

/// Model-picker grouping/labeling + the secure Auto default. Two layers:
///  - Plain XCTest unit assertions on the real `ModelCatalog` (classification, friendly
///    labels, menu shape).
///  - A HERMETIC Brine run of `features/model-picker.feature` driving the same real types
///    (ModelCatalog + ChatConversationStore + ChatRequest) in-memory — no live door, no UI.
final class ModelPickerTests: XCTestCase {

    // MARK: unit — catalog classification + labeling

    func testProviderClassification() {
        XCTAssertEqual(ModelCatalog.provider(for: .init(id: "claude-opus-4.8", label: "Claude Opus 4.8")), .anthropic)
        XCTAssertEqual(ModelCatalog.provider(for: .init(id: "claude-sonnet-4.6", label: "")), .anthropic)
        XCTAssertEqual(ModelCatalog.provider(for: .init(id: "gpt-5.5", label: "GPT-5.5")), .openai)
        XCTAssertEqual(ModelCatalog.provider(for: .init(id: "o3", label: "o3")), .openai)
        XCTAssertEqual(ModelCatalog.provider(for: .init(id: "local-qwen3-8b", label: "")), .local)
        XCTAssertEqual(ModelCatalog.provider(for: .init(id: "mystery-model", label: "")), .local,
                       "unknown ids fall into the Local catch-all so nothing drops out of the menu")
    }

    func testFriendlyDisplayName() {
        // Prefers a meaningful door label.
        XCTAssertEqual(ModelCatalog.displayName(for: .init(id: "claude-opus-4.8", label: "Claude Opus 4.8")),
                       "Claude Opus 4.8")
        // Empty label → prettified id (strip local- prefix, GPT acronym, version intact).
        XCTAssertEqual(ModelCatalog.displayName(for: .init(id: "local-qwen3-8b", label: "")), "Qwen3 8b")
        XCTAssertEqual(ModelCatalog.displayName(for: .init(id: "gpt-5.5-mini", label: "")), "GPT 5.5 Mini")
        // Label equal to id (the door's fallback) is treated as "no friendly label" → prettify.
        XCTAssertEqual(ModelCatalog.displayName(for: .init(id: "local-llama3", label: "local-llama3")), "Llama3")
    }

    func testMenuGroupsInProviderOrderOmittingEmpty() {
        let menu = ModelCatalog.menu(from: [
            .init(id: "local-qwen3-8b", label: ""),
            .init(id: "gpt-5.5", label: "GPT-5.5"),
            .init(id: "claude-opus-4.8", label: "Claude Opus 4.8"),
        ])
        XCTAssertEqual(menu.groups.map(\.title), ["Anthropic", "OpenAI", "Local"])
        // Each group carries its own options.
        XCTAssertEqual(menu.groups.first(where: { $0.provider == .openai })?.options.map(\.id), ["gpt-5.5"])
    }

    func testEmptyListYieldsZeroGroupsButSecureAuto() {
        let menu = ModelCatalog.menu(from: [])
        XCTAssertTrue(menu.groups.isEmpty)
        XCTAssertTrue(menu.auto.secure)
        XCTAssertTrue(menu.auto.recommended)
        XCTAssertTrue(menu.auto.caption.lowercased().contains("local"))
    }

    // MARK: hermetic brine — wire the feature scenarios to real state

    func testModelPickerScenarios() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }     // Tests/FoundryXBrineTests/<file> -> package root
        let featurePath = url.appendingPathComponent("features/model-picker.feature").path
        let text = try String(contentsOfFile: featurePath, encoding: .utf8)
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        let world = ModelPickerWorld()
        let registry = StepRegistry(ModelPickerSteps.make(world: world))

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
        XCTAssertTrue(failures.isEmpty, "model-picker scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
        XCTAssertEqual(result.passed, parsed.features[0].scenarios.count, "all scenarios should pass")
    }
}

// MARK: - Brine world + steps (in-memory, no door)

final class ModelPickerWorld: @unchecked Sendable {
    var options: [ModelOption] = []
    var menu: ModelMenu?
    var lastOption: ModelOption?
    var store = ChatConversationStore()
    var convoId = ""
    var request: ChatRequest?
    var requestJSON: [String: Any] = [:]
}

enum ModelPickerSteps {
    static func make(world: ModelPickerWorld) -> [StepDefinition] {
        [
            // --- grouping/labeling ---
            defineStep("the door offers a model list with Anthropic, OpenAI, and local entries") { ctx, _, _ in
                world.options = [
                    .init(id: "claude-opus-4.8", label: "Claude Opus 4.8"),
                    .init(id: "claude-sonnet-4.6", label: "Claude Sonnet 4.6"),
                    .init(id: "gpt-5.5", label: "GPT-5.5"),
                    .init(id: "gpt-5.5-mini", label: "GPT-5.5 Mini"),
                    .init(id: "local-qwen3-8b", label: ""),
                ]
                return ctx
            },
            defineStep("the door offers no models") { ctx, _, _ in
                world.options = []
                return ctx
            },
            defineStep("the picker menu is built from that list") { ctx, _, _ in
                world.menu = ModelCatalog.menu(from: world.options)
                return ctx
            },
            defineStep("the picker menu is built from any model list") { ctx, _, _ in
                world.menu = ModelCatalog.menu(from: [.init(id: "local-qwen3-8b", label: "")])
                return ctx
            },
            defineCheck("the provider groups are {string}, {string}, {string} in that order") { _, p, _ in
                let want = [try p.requireString(0), try p.requireString(1), try p.requireString(2)]
                let got = world.menu?.groups.map(\.title) ?? []
                guard got == want else { throw ModelPickerError("groups \(got) != \(want)") }
            },
            defineCheck("each model shows a friendly display name not its raw id") { _, _, _ in
                let groups = world.menu?.groups ?? []
                guard !groups.isEmpty else { throw ModelPickerError("no groups to check") }
                for group in groups {
                    for option in group.options {
                        let name = ModelCatalog.displayName(for: option)
                        guard name != option.id, !name.isEmpty else {
                            throw ModelPickerError("option \(option.id) shows raw id as display name")
                        }
                    }
                }
            },
            defineCheck("there are zero provider groups") { _, _, _ in
                let count = world.menu?.groups.count ?? -1
                guard count == 0 else { throw ModelPickerError("expected 0 groups, got \(count)") }
            },

            // --- single-id classification ---
            defineStep("a model id {string} labeled {string}") { ctx, p, _ in
                world.lastOption = .init(id: try p.requireString(0), label: try p.requireString(1))
                return ctx
            },
            defineCheck("its provider group is {string}") { _, p, _ in
                let want = try p.requireString(0)
                guard let opt = world.lastOption else { throw ModelPickerError("no model set") }
                let got = ModelCatalog.provider(for: opt).title
                guard got == want else { throw ModelPickerError("provider \(got) != \(want) for \(opt.id)") }
            },
            defineCheck("its friendly display name is {string}") { _, p, _ in
                let want = try p.requireString(0)
                guard let opt = world.lastOption else { throw ModelPickerError("no model set") }
                let got = ModelCatalog.displayName(for: opt)
                guard got == want else { throw ModelPickerError("display name \(got) != \(want) for \(opt.id)") }
            },

            // --- secure Auto default ---
            defineCheck("the Auto entry is marked secure and recommended") { _, _, _ in
                let auto = world.menu?.auto
                guard auto?.secure == true, auto?.recommended == true else {
                    throw ModelPickerError("Auto entry not secure+recommended: \(String(describing: auto))")
                }
            },
            defineCheck("the Auto entry is still marked secure and recommended") { _, _, _ in
                let auto = world.menu?.auto
                guard auto?.secure == true, auto?.recommended == true else {
                    throw ModelPickerError("Auto entry not secure+recommended: \(String(describing: auto))")
                }
            },
            defineCheck("the Auto entry caption mentions keeping data local") { _, _, _ in
                let caption = world.menu?.auto.caption.lowercased() ?? ""
                guard caption.contains("local") else { throw ModelPickerError("caption '\(caption)' omits 'local'") }
            },

            // --- selection passes the right requested_target (real ChatRequest encoding) ---
            defineStep("a conversation with no model selected") { ctx, _, _ in
                world.store = ChatConversationStore()
                world.convoId = world.store.active!.id
                return ctx
            },
            defineStep("a conversation with the model {string} selected") { ctx, p, _ in
                world.store = ChatConversationStore()
                world.convoId = world.store.active!.id
                world.store.setModel(try p.requireString(0), for: world.convoId)
                return ctx
            },
            defineStep("I build a chat request for that conversation") { ctx, _, _ in
                let req = world.store.chatRequest(text: "hello", for: world.convoId)
                world.request = req
                world.requestJSON = (try? JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(req)) as? [String: Any]) ?? [:]
                return ctx
            },
            defineCheck("the chat request's requested_target is {string}") { _, p, _ in
                let want = try p.requireString(0)
                guard world.request?.requestedTarget == want else {
                    throw ModelPickerError("requested_target = \(String(describing: world.request?.requestedTarget)), want \(want)")
                }
                guard world.requestJSON["requested_target"] as? String == want else {
                    throw ModelPickerError("encoded requested_target missing/wrong")
                }
            },
            defineCheck("the chat request omits requested_target so the router decides") { _, _, _ in
                guard world.request?.requestedTarget == nil else {
                    throw ModelPickerError("expected nil requested_target, got \(String(describing: world.request?.requestedTarget))")
                }
                guard world.requestJSON["requested_target"] == nil else {
                    throw ModelPickerError("encoded JSON must OMIT requested_target for the router default")
                }
            },
        ]
    }
}

struct ModelPickerError: Error { let message: String; init(_ m: String) { message = m } }
