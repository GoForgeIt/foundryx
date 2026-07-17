import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// The honest-waiting experience: every scenario in features/waiting-experience.feature
/// drives the REAL `WaitingExperienceModel` (the same model the shared SwiftUI
/// component binds to), asserting the plain-language naming, the true-vs-fake progress
/// contract, and the deterministic rotating fact.
final class WaitingExperienceFeatureTests: XCTestCase {
    func testWaitingExperienceScenarios() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let featurePath = url.appendingPathComponent("features/waiting-experience.feature").path
        let text = try String(contentsOfFile: featurePath, encoding: .utf8)
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        let world = WaitingExperienceWorld()
        let registry = StepRegistry(WaitingExperienceSteps.make(world: world))

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
        XCTAssertTrue(failures.isEmpty, "waiting-experience scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
        XCTAssertEqual(result.passed, parsed.features[0].scenarios.count, "all scenarios should pass")
    }
}

private final class WaitingExperienceWorld: @unchecked Sendable {
    var model: WaitingExperienceModel = WaitingExperienceModel(kind: .recap)
    var elapsed: TimeInterval = 0
    // For the "rotating fact over time" scenario.
    var tipEarly: WaitingTip?
    var tipLate: WaitingTip?
    var tipRepeat: WaitingTip?

    func reset(_ model: WaitingExperienceModel) {
        self.model = model
        elapsed = 0
        tipEarly = nil; tipLate = nil; tipRepeat = nil
    }
}

private enum WaitingExperienceSteps {
    static func make(world: WaitingExperienceWorld) -> [StepDefinition] {
        [
            defineStep("a recap is being generated on my iPhone") { ctx, _, _ in
                world.reset(WaitingExperienceModel(kind: .recap, onDevice: true))
                return ctx
            },
            defineStep("a conversation is being transcribed on my iPhone") { ctx, _, _ in
                world.reset(WaitingExperienceModel(kind: .transcription, onDevice: true))
                return ctx
            },
            defineStep("content is being fetched from my Mac") { ctx, _, _ in
                world.reset(WaitingExperienceModel(kind: .doorFetch, onDevice: false))
                return ctx
            },
            defineStep("a conversation is being titled on my iPhone") { ctx, _, _ in
                world.reset(WaitingExperienceModel(kind: .title, onDevice: true))
                return ctx
            },
            defineStep("214 of 1210 segments have synced to my computer") { ctx, _, _ in
                world.reset(WaitingExperienceModel(kind: .sync, onDevice: false,
                                                   progress: .determinate(done: 214, total: 1210)))
                return ctx
            },
            defineStep("I look at the waiting experience") { ctx, _, _ in
                world.elapsed = 0
                return ctx
            },
            defineStep("I look at the rotating fact") { ctx, _, _ in
                world.tipEarly = world.model.tip(elapsed: 0)
                return ctx
            },
            defineStep("it has been transcribing for 25 seconds") { ctx, _, _ in
                world.elapsed = 25
                return ctx
            },
            defineStep("I look at the rotating fact after 0 seconds and again after 5 seconds") { ctx, _, _ in
                world.tipEarly = world.model.tip(elapsed: 0)
                world.tipLate = world.model.tip(elapsed: 5)
                world.tipRepeat = world.model.tip(elapsed: 0)
                return ctx
            },

            defineCheck("it says it is summarizing on my iPhone") { _, _, _ in
                try expect(world.model.copy.headline == "Summarizing on your iPhone",
                           "headline was \(world.model.copy.headline)")
            },
            defineCheck("it tells me the recap is written entirely on my device") { _, _, _ in
                try expect(world.model.copy.privacyLine.contains("entirely on your device"),
                           "privacy line was \(world.model.copy.privacyLine)")
            },
            defineCheck("it does not show a progress bar") { _, _, _ in
                try expect(world.model.progress.fraction == nil,
                           "unexpected progress fraction \(String(describing: world.model.progress.fraction))")
            },
            defineCheck("the fact is one of the true things the app does locally") { _, _, _ in
                let tip = world.tipEarly ?? world.model.tip(elapsed: 0)
                try expect(world.model.tipDeck.tips.contains(tip),
                           "tip '\(tip.text)' not in the deck")
            },
            defineCheck("it shows a real progress bar") { _, _, _ in
                try expect(world.model.progress.fraction != nil, "expected a real progress fraction")
            },
            defineCheck("it says \"214 of 1,210 segments safely on your computer\"") { _, _, _ in
                let line = world.model.statusLine(elapsed: world.elapsed)
                try expect(line == "214 of 1,210 segments safely on your computer",
                           "status line was \(line)")
            },
            defineCheck("it says it is transcribing locally") { _, _, _ in
                try expect(world.model.copy.headline == "Transcribing locally",
                           "headline was \(world.model.copy.headline)")
            },
            defineCheck("it tells me the audio never leaves my phone") { _, _, _ in
                try expect(world.model.copy.privacyLine.contains("never leaves your phone"),
                           "privacy line was \(world.model.copy.privacyLine)")
            },
            defineCheck("it tells me longer recordings take longer") { _, _, _ in
                let line = world.model.statusLine(elapsed: world.elapsed)
                try expect(line.contains("longer recordings take longer"),
                           "status line at \(world.elapsed)s was \(line)")
            },
            defineCheck("it says it is fetching from my Mac") { _, _, _ in
                try expect(world.model.copy.headline == "Fetching from your Mac",
                           "headline was \(world.model.copy.headline)")
            },
            defineCheck("it tells me the tunnel is end-to-end encrypted") { _, _, _ in
                try expect(world.model.copy.privacyLine.contains("end-to-end-encrypted"),
                           "privacy line was \(world.model.copy.privacyLine)")
            },
            defineCheck("it says it is naming this conversation") { _, _, _ in
                try expect(world.model.copy.headline == "Naming this conversation",
                           "headline was \(world.model.copy.headline)")
            },
            defineCheck("the two facts are different") { _, _, _ in
                try expect(world.tipEarly != world.tipLate,
                           "facts did not rotate: \(String(describing: world.tipEarly))")
            },
            defineCheck("looking again at the same moment shows the same fact") { _, _, _ in
                try expect(world.tipEarly == world.tipRepeat,
                           "same-moment fact was not stable")
            },
        ]
    }

    private static func expect(_ cond: Bool, _ message: String) throws {
        if !cond { throw BrineStepError(message) }
    }
}
