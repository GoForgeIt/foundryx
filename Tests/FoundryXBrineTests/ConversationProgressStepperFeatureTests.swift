import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/conversation-progress-stepper.feature. Wires the scenarios
/// to the REAL `ConversationProgress` step machine (the same pure derivation
/// ConversationProgressTests unit-tests): `state(of:)` marks past steps done, the
/// current one active/failed, and future ones pending; a `.ready` conversation shows the
/// transcript and steps the stepper aside.
final class ConversationProgressStepperFeatureTests: XCTestCase {
    func testConversationProgressStepperFeature() async throws {
        try await BrineFeatureRunner.run("conversation-progress-stepper",
                                         registry: StepRegistry(ConversationProgressStepperSteps.make(world: .init())))
    }
}

private final class ProgressStepperWorld: @unchecked Sendable {
    var progress: ConversationProgress = .transcribing
    var opened = false
    /// The detail view shows the stepper only while the conversation is still moving —
    /// once it's `.ready` the transcript is shown directly and the stepper steps aside.
    var showsStepper: Bool { progress != .ready }
}

private enum ConversationProgressStepperSteps {
    typealias Step = ConversationProgress.Step
    static func make(world w: ProgressStepperWorld) -> [StepDefinition] {
        [
            defineStep("a conversation whose transcript is still being produced") { ctx, _, _ in
                w.progress = .transcribing; w.opened = false; return ctx
            },
            defineStep("a conversation whose transcript is ready") { ctx, _, _ in
                w.progress = .ready; w.opened = false; return ctx
            },
            defineStep("a conversation that failed to transcribe") { ctx, _, _ in
                w.progress = .failed; w.opened = false; return ctx
            },
            defineStep("I open it") { ctx, _, _ in w.opened = true; return ctx },

            defineCheck("I see the steps Recorded and Saved marked complete") { _, _, _ in
                guard w.progress.state(of: .recorded) == .done, w.progress.state(of: .saved) == .done else {
                    throw BrineStepError("Recorded/Saved not both .done for \(w.progress)")
                }
            },
            defineCheck("I see the Transcribing step marked as in progress") { _, _, _ in
                guard w.progress.state(of: .transcribing) == .active else {
                    throw BrineStepError("Transcribing not .active for \(w.progress)")
                }
            },
            defineCheck("I see the Ready step still ahead") { _, _, _ in
                guard w.progress.state(of: .ready) == .pending else {
                    throw BrineStepError("Ready not .pending for \(w.progress)")
                }
            },
            defineCheck("I see the transcript") { _, _, _ in
                guard w.opened, w.progress == .ready else {
                    throw BrineStepError("transcript is only shown directly once ready (\(w.progress))")
                }
            },
            defineCheck("I do not see the progress stepper") { _, _, _ in
                guard !w.showsStepper else { throw BrineStepError("stepper still shown for \(w.progress)") }
            },
            defineCheck("the Transcribing step is marked failed") { _, _, _ in
                guard w.progress.state(of: .transcribing) == .failed else {
                    throw BrineStepError("Transcribing not .failed for \(w.progress)")
                }
            },
        ]
    }
}
