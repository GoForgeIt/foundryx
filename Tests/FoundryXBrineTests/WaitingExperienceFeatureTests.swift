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

    // The sync strip (WS-B) hysteresis machine, driven by a synthetic clock.
    let base = Date(timeIntervalSince1970: 1_000_000)
    var presenter = SyncBarPresenter()
    var presentation: SyncBarPresentation = .settled
    var everSyncing = false
    var destination: CaptureDestination = .phone

    func reset(_ model: WaitingExperienceModel) {
        self.model = model
        elapsed = 0
        tipEarly = nil; tipLate = nil; tipRepeat = nil
    }

    /// Fresh strip machine for a new sync scenario.
    func resetStrip() {
        presenter = SyncBarPresenter()
        presentation = .settled
        everSyncing = false
        destination = .phone
    }

    /// Step the presenter at `base + offset` seconds, remembering if the syncing bar was
    /// ever shown (the debounce guarantee).
    func step(syncing: Bool, at offset: TimeInterval) {
        presentation = presenter.step(syncing: syncing, now: base.addingTimeInterval(offset))
        if presentation == .syncing { everSyncing = true }
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
                try expect(line.contains("longer voice notes take longer"),
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
                try expect(world.model.copy.headline == "Naming this voice note",
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

            // MARK: Sync strip (WS-B) — debounce, minimum-show, no layout shift.

            defineStep("my library shows some conversations") { ctx, _, _ in
                world.resetStrip()
                return ctx
            },
            defineStep("a sync starts and finishes within a second") { ctx, _, _ in
                // Active for < the 1.5s appear delay, then stops — never earns the bar.
                world.step(syncing: true, at: 0)
                world.step(syncing: true, at: 0.5)
                world.step(syncing: false, at: 0.9)
                return ctx
            },
            defineStep("a sync stays active for more than two seconds") { ctx, _, _ in
                world.step(syncing: true, at: 0)
                world.step(syncing: true, at: 2.0)
                return ctx
            },
            defineStep("a sync has been active long enough to show the syncing bar") { ctx, _, _ in
                world.step(syncing: true, at: 0)
                world.step(syncing: true, at: 2.0)   // shown at base+2.0
                return ctx
            },
            defineStep("the sync finishes right away") { ctx, _, _ in
                world.step(syncing: false, at: 2.0)  // finishes the instant it showed
                return ctx
            },
            defineStep("a sync has run and then finished and settled") { ctx, _, _ in
                world.step(syncing: true, at: 0)
                world.step(syncing: true, at: 2.0)   // shown
                world.step(syncing: false, at: 2.0)  // finished
                world.step(syncing: false, at: 10.0) // well past the 3s minimum-show
                return ctx
            },
            defineStep("I read the strip") { ctx, _, _ in ctx },

            defineCheck("the syncing bar is never shown") { _, _, _ in
                try expect(!world.everSyncing, "the syncing bar was shown for a brief sync")
            },
            defineCheck("the syncing bar is shown") { _, _, _ in
                try expect(world.presentation == .syncing,
                           "expected the syncing bar, got \(world.presentation)")
            },
            defineCheck("the conversation list below the strip never moves") { _, _, _ in
                // The strip is one height for every presentation ⇒ nothing below can move.
                let a = SyncStripLayout.height(for: .syncing)
                let b = SyncStripLayout.height(for: .settled)
                try expect(a == b && a == SyncStripLayout.totalHeight,
                           "strip height changed between presentations: \(a) vs \(b)")
            },
            defineCheck("the syncing bar is still shown two seconds later") { _, _, _ in
                // 2s after it showed (base+4.0) — still inside the 3s minimum-show window.
                world.step(syncing: false, at: 4.0)
                try expect(world.presentation == .syncing,
                           "the bar disappeared inside the 3s minimum-show window")
            },
            defineCheck("it has settled by four seconds later") { _, _, _ in
                // 4s after it showed (base+6.0) — past the minimum-show window.
                world.step(syncing: false, at: 6.0)
                try expect(world.presentation == .settled,
                           "the bar had not settled after the minimum-show window")
            },
            defineCheck("it says all my conversations are saved") { _, _, _ in
                try expect(world.presentation == .settled,
                           "expected the settled strip, got \(world.presentation)")
                try expect(SyncStripCopy.allSaved(destination: world.destination)
                               == "All voice notes saved",
                           "settled copy was "
                           + "\(SyncStripCopy.allSaved(destination: world.destination))")
            },
        ]
    }

    private static func expect(_ cond: Bool, _ message: String) throws {
        if !cond { throw BrineStepError(message) }
    }
}
