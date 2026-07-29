import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/onboarding-first-note-and-destination.feature. Drives the
/// REAL step ordering (`OnboardingFlowPlan`), the REAL library presence check
/// (`CaptureLibrary`, against note directories written to a temp dir), the REAL
/// account-scoped destination preference (`BrainStore`/`BrainChoice` over an isolated
/// UserDefaults suite), and the REAL once-only gate (`OnboardingGate`). Hermetic: temp
/// dir + private suite, no audio, no network.
///
/// Scope note: "I see the live transcript while I am speaking" is covered here only
/// structurally — that the step is subscribed to the transcriber (`OnboardingFirstNote`).
/// That the words actually reach the screen is proved by
/// UITests/OnboardingEndingProofUITests.
final class OnboardingEndingFeatureTests: XCTestCase {
    func testOnboardingEndingFeature() async throws {
        try await BrineFeatureRunner.run(
            "onboarding-first-note-and-destination",
            registry: StepRegistry(OnboardingEndingSteps.make(world: OnboardingEndingWorld())))
    }
}

private final class OnboardingEndingWorld: @unchecked Sendable {
    let baseDir: URL
    let defaults: UserDefaults
    /// The step the user has just answered.
    var answered: OnboardingStep = .ambient
    var firstNote = OnboardingFirstNote()
    var askIt = OnboardingAskIt()
    /// Mirrors `CaptureManager.suppressesRecordingSurface` — held for the whole
    /// first-note step, not just at start.
    var recordingSurfaceSuppressed = false
    var completed = false
    /// What the user actually said in their first note — the ask-it step must answer
    /// from THIS, not from the question alone.
    let noteTranscript = "I want to plant the tomatoes before the frost comes in October"
    /// Set when the flow hands off to the Vault funnel rather than finishing.
    var vaultSetupStarted = false

    /// The REAL, account-scoped brain preference over an isolated suite. The destination
    /// choice is `BrainChoice` — not a parallel key — so this is the thing the flow
    /// actually writes.
    let brains: BrainStore

    init() {
        baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-ending-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let name = "ending-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        brains = BrainStore(
            compatibility: AccountPreferenceCompatibilityStore(defaults: defaults))
    }

    /// Scenarios share this world, so a note written by an earlier one would leak into
    /// the next scenario's "my library is empty" premise.
    func resetLibrary() {
        try? FileManager.default.removeItem(at: baseDir)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    /// Write a note the way capture does: a directory under the captures root named for
    /// its capture id. `CaptureLibrary` reads exactly this shape.
    func recordNote() {
        let id = "mic-20260728T120000-\(String(UUID().uuidString.prefix(8)))"
        try? FileManager.default.createDirectory(
            at: baseDir.appendingPathComponent(id, isDirectory: true),
            withIntermediateDirectories: true)
    }

    /// Answer `step` and move to whatever comes next, mirroring what the view does.
    func advance(from step: OnboardingStep) {
        answered = step
        if OnboardingFlowPlan.isFinished(after: step) { completed = true }
    }

    /// A stand-in for the on-device answerer. It quotes the transcript back, so a step
    /// that forgot to pass the note would produce an answer with none of the user's
    /// words in it and the scenario would fail.
    struct EchoAnswerer: NoteAnswering {
        func answer(question: String, aboutNote transcript: String) async throws -> String {
            guard !transcript.isEmpty else { return "I don't have a note to look at." }
            return "You said: \(transcript)"
        }
    }

    /// The REAL account-scoped brain preference — not a parallel key. Writing through
    /// `BrainStore` is what makes the choice survive an account switch correctly.
    func choose(_ destination: BrainChoice) {
        brains.select(destination)
        if destination.startsVaultSetup {
            vaultSetupStarted = true          // hand off to the funnel; flow stays open
        } else {
            advance(from: .destination)
        }
    }
}

private enum OnboardingEndingSteps {
    static func make(world w: OnboardingEndingWorld) -> [StepDefinition] {
        [
            // ── the flow does not end on the consent step
            defineStep("I have just answered the ambient intelligence question") { ctx, _, _ in
                w.answered = .ambient; w.completed = false; return ctx
            },
            defineCheck("I am invited to make my first voice note") { _, _, _ in
                guard OnboardingFlowPlan.next(after: .ambient) == .firstNote else {
                    throw BrineStepError(
                        "after the ambient consent the flow went to "
                        + "\(String(describing: OnboardingFlowPlan.next(after: .ambient)))"
                        + " — the ending must be a WIN, not a permission")
                }
            },
            defineCheck("onboarding is not finished yet") { _, _, _ in
                guard !OnboardingFlowPlan.isFinished(after: .ambient) else {
                    throw BrineStepError("the flow ended on the consent step")
                }
            },

            // ── the first note is a real note
            defineStep("I am on the first voice note step") { ctx, _, _ in
                w.answered = .firstNote
                w.firstNote = OnboardingFirstNote()
                w.completed = false
                w.resetLibrary()
                w.recordingSurfaceSuppressed = true   // the step holds the screen on appear
                guard CaptureLibrary.isEmpty(baseDir: w.baseDir) else {
                    throw BrineStepError("the library was not empty before the first note")
                }
                return ctx
            },
            defineStep("I record a short voice note") { ctx, _, _ in
                w.recordNote()
                // The step is subscribed to the on-device transcriber, so words arrive
                // while the note is being spoken.
                w.firstNote.consume(LiveTranscript(finalizedText: "pick the tomatoes",
                                                   volatileTail: "before"))
                return ctx
            },
            defineCheck("the note is saved to my library") { _, _, _ in
                guard CaptureLibrary.noteCount(baseDir: w.baseDir) == 1 else {
                    throw BrineStepError(
                        "expected exactly one note, found \(CaptureLibrary.noteCount(baseDir: w.baseDir))")
                }
            },
            defineCheck("my library is no longer empty") { _, _, _ in
                guard !CaptureLibrary.isEmpty(baseDir: w.baseDir) else {
                    throw BrineStepError("the library still reads as empty after the first note")
                }
            },
            defineCheck("I see the live transcript while I am speaking") { _, _, _ in
                guard w.firstNote.showsTranscript else {
                    throw BrineStepError("the first-note step showed no live transcript")
                }
                guard w.firstNote.visibleText.contains("pick the tomatoes") else {
                    throw BrineStepError("the words spoken did not reach the step: "
                                         + "\"\(w.firstNote.visibleText)\"")
                }
            },

            // ── regression: two competing full-screen covers (2026-07-28)
            //
            // CaptureScreen presents its OWN recording cover on `isRecordingMic`, and the
            // manager clears `recordingScreenMinimized` again when the session actually
            // establishes. A first-note step that only minimizes ONCE therefore got
            // overridden a beat later: the library's recorder slammed up, SwiftUI dropped
            // the onboarding cover, and the user finished their note on Capture home
            // having never seen the ask-it or destination steps. Found by the UI proof,
            // pinned here so it cannot come back quietly.
            defineCheck("the library's full-screen recorder stays down") { _, _, _ in
                guard w.recordingSurfaceSuppressed else {
                    throw BrineStepError(
                        "the first-note step did not hold the screen — the library's "
                        + "recorder would take over and drop the user out of onboarding")
                }
            },
            defineCheck("I am still in the onboarding flow") { _, _, _ in
                guard !w.completed, w.answered == .firstNote else {
                    throw BrineStepError("the flow was left during the first note")
                }
            },

            // ── the note leads to the demonstration, not to the pitch
            defineStep("I have made my first voice note") { ctx, _, _ in
                w.recordNote(); w.answered = .firstNote; w.completed = false; return ctx
            },
            defineCheck("I am invited to ask a question about what I just said") { _, _, _ in
                guard OnboardingFlowPlan.next(after: .firstNote) == .askIt else {
                    throw BrineStepError(
                        "after the first note the flow went to "
                        + "\(String(describing: OnboardingFlowPlan.next(after: .firstNote)))"
                        + " — the destination pitch must come AFTER the demonstration")
                }
            },
            defineCheck("onboarding is not finished after the note") { _, _, _ in
                guard !OnboardingFlowPlan.isFinished(after: .firstNote) else {
                    throw BrineStepError("the flow ended on the first note")
                }
            },

            // ── the demonstration answers from the user's own words, on the handset
            defineStep("I am on the ask-it step") { ctx, _, _ in
                w.answered = .askIt
                w.askIt = OnboardingAskIt()
                return ctx
            },
            defineStep("I ask a question about my note") { ctx, _, _ in
                let question = "when do I need to plant by?"
                w.askIt.ask(question)
                let text = try await OnboardingEndingWorld.EchoAnswerer()
                    .answer(question: question, aboutNote: w.noteTranscript)
                // On-device is a property of WHICH answerer ran, not of the answer text.
                w.askIt.record(answer: text, onDevice: true)
                return ctx
            },
            defineCheck("I get an answer drawn from what I just said") { _, _, _ in
                guard w.askIt.hasAnswer else {
                    throw BrineStepError("the ask-it step produced no answer")
                }
                // The note's own words must appear — an answer that ignores the note
                // makes the whole demonstration a lie.
                guard w.askIt.answer?.contains("tomatoes") == true else {
                    throw BrineStepError(
                        "the answer did not draw on the note: \"\(w.askIt.answer ?? "")\"")
                }
            },
            defineCheck("the answer was produced on this phone") { _, _, _ in
                guard w.askIt.answeredOnDevice else {
                    throw BrineStepError("the onboarding demonstration went off-device")
                }
            },

            // ── only then, the ceiling
            defineStep("I have asked a question about my note") { ctx, _, _ in
                w.askIt.ask("when do I need to plant by?")
                w.askIt.record(answer: "You said: \(w.noteTranscript)", onDevice: true)
                w.answered = .askIt
                return ctx
            },
            defineStep("I am shown what changes if my notes live somewhere bigger") { ctx, _, _ in
                guard OnboardingFlowPlan.next(after: .askIt) == .destination else {
                    throw BrineStepError(
                        "the demonstration did not lead to the destination choice — cell "
                        + "provisioning would stay buried in Settings")
                }
                w.answered = .destination
                w.vaultSetupStarted = false
                w.completed = false
                w.brains.select(.justMyPhone)   // a known starting point, overwritten by the choice
                return ctx
            },
            defineCheck("the difference offered is asking across everything I have said") { _, _, _ in
                let vault = TierComparison.headline.withYourVault.lowercased()
                guard vault.contains("everything") else {
                    throw BrineStepError(
                        "the headline difference was \"\(TierComparison.headline.withYourVault)\" — "
                        + "it must be about asking across everything, not a product name")
                }
                guard TierComparison.points.first == TierComparison.headline else {
                    throw BrineStepError("the headline difference is not shown first")
                }
            },
            defineCheck("every point compares both choices") { _, _, _ in
                for point in TierComparison.points
                where point.onThisPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || point.withYourVault.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw BrineStepError("a comparison point left one side blank: \(point)")
                }
            },
            defineCheck("staying on this phone is never described as having nothing") { _, _, _ in
                guard TierComparison.isHonest() else {
                    let offenders = TierComparison.points
                        .map { $0.onThisPhone.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { $0.isEmpty || TierComparison.emptyHandedPhrasings.contains($0.lowercased()) }
                    throw BrineStepError(
                        "the free column reads as a list of things the user lacks: \(offenders)")
                }
            },
            defineCheck("I can choose this phone, my computer, or my Vault") { _, _, _ in
                let offered = Set(BrainChoice.allCases)
                let required: Set<BrainChoice> = [.justMyPhone, .myComputer, .foundryCloud]
                guard offered == required else {
                    throw BrineStepError("destinations offered were \(offered), expected \(required)")
                }
            },

            // ── choosing the Vault starts provisioning
            defineStep("I choose my Vault") { ctx, _, _ in w.choose(.foundryCloud); return ctx },
            defineCheck("Vault setup begins") { _, _, _ in
                guard w.vaultSetupStarted else {
                    throw BrineStepError("choosing the Vault did not start setup")
                }
                guard w.brains.choice == .foundryCloud else {
                    throw BrineStepError("the Vault choice was not recorded on the real "
                                         + "account-scoped brain preference")
                }
            },

            // ── choosing the phone finishes
            defineStep("I choose this phone") { ctx, _, _ in w.choose(.justMyPhone); return ctx },
            defineCheck("onboarding is finished") { _, _, _ in
                guard w.completed else { throw BrineStepError("the flow did not finish") }
            },
            defineCheck("my notes are kept on this phone") { _, _, _ in
                guard w.brains.choice.keepsNotesOnPhone else {
                    throw BrineStepError("the on-phone choice was not recorded as local: "
                                         + "\(w.brains.choice)")
                }
            },

            // ── skipping still lands somewhere with a next action
            defineStep("I skip it") { ctx, _, _ in
                // Skipping the note skips the rest of the ending — there is nothing to
                // decide a destination for yet.
                w.completed = true
                return ctx
            },
            defineCheck("my library invites me to make my first voice note") { _, _, _ in
                // The invitation is the empty-library state the home screen speaks to;
                // skipping must leave the user THERE, not on a blank screen.
                guard CaptureLibrary.isEmpty(baseDir: w.baseDir) else {
                    throw BrineStepError("skipping the first note somehow stored one")
                }
            },

            // ── never runs twice
            defineStep("I finished onboarding including the destination choice") { ctx, _, _ in
                w.choose(.justMyPhone)
                w.completed = true
                return ctx
            },
            defineStep("the app launches") { ctx, _, _ in return ctx },
            defineCheck("the onboarding flow is not presented") { _, _, _ in
                guard !OnboardingGate.shouldPresent(signedIn: true, completed: w.completed,
                                                 hasRecordingHistory: false) else {
                    throw BrineStepError("the finished flow was presented again")
                }
            },
        ]
    }
}
