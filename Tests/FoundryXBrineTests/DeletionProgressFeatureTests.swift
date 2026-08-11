import XCTest
@testable import FoundryXKit
import BrineSwiftCore

/// `features/deletion-shows-me-what-it-is-doing.feature`.
///
/// Drives the REAL `AccountDeletionProgressModel` with the REAL
/// `DeletionSignInRecoveryEvent` stream the deletion lifecycle emits, and asserts
/// against the real `presentation` the screen renders from. Steps are addressed
/// by the words a person reads, not by raw stage identifiers.
final class DeletionProgressFeatureTests: XCTestCase {
    fileprivate final class World: @unchecked Sendable {
        var model = AccountDeletionProgressModel()

        func reset() {
            model = AccountDeletionProgressModel()
            model.begin()
        }

        var presentation: AccountDeletionProgressPresentation {
            model.presentation
        }

        func step(titled title: String) throws -> AccountDeletionProgressStep {
            guard let step = presentation.steps.first(where: {
                $0.title.caseInsensitiveCompare(title) == .orderedSame
            }) else {
                throw BrineStepError(
                    "no erase step is called \"\(title)\"; the screen shows "
                        + presentation.steps.map(\.title).joined(separator: " | "))
            }
            return step
        }

        func stage(titled title: String) throws
            -> RemoteSession.DeletionCleanupStage
        {
            try step(titled: title).stage
        }
    }

    func testDeletionProgressScenarios() async throws {
        let world = World()

        try await BrineFeatureRunner.run(
            "deletion-shows-me-what-it-is-doing",
            registry: StepRegistry([
                defineStep("I am deleting my account") { ctx, _, _ in
                    world.reset()
                    return ctx
                },
                defineStep("the erase reaches {string}") { ctx, args, _ in
                    let title = try args.requireString(0)
                    world.model.report(.stage(try world.stage(titled: title)))
                    return ctx
                },
                defineStep("that step refuses because it could not be saved") { ctx, _, _ in
                    guard let stage = world.presentation.currentStage else {
                        throw BrineStepError("no step was in progress to refuse")
                    }
                    world.model.fail(
                        stage: stage,
                        reason: "UserDefaults did not durably retain the removal")
                    return ctx
                },
                defineStep("the erase refuses without naming a step") { ctx, _, _ in
                    // EXACTLY the shape Nick hit: the lifecycle throws
                    // `exposureBarrierFailed`, which carries no stage, so the
                    // presentation layer's fallback is `.preparing`.
                    world.model.fail(
                        stage: .preparing, reason: "exposureBarrierFailed")
                    return ctx
                },
                defineStep("the erase refuses because this iPhone cannot prove who owns the data") { ctx, _, _ in
                    world.model.fail(
                        stage: .preparing, reason: "owner_unproven no_identity")
                    return ctx
                },
                defineStep("the erase finishes") { ctx, _, _ in
                    world.model.complete()
                    return ctx
                },
                defineCheck("I am told the erase is starting") { _, _, _ in
                    guard world.presentation.headline == "Starting the erase…" else {
                        throw BrineStepError(
                            "the screen said \"\(world.presentation.headline)\" before any step reported")
                    }
                },
                defineCheck("that step is shown as in progress") { _, _, _ in
                    guard let stage = world.presentation.currentStage,
                          try world.step(titled: stage.title).state == .running else {
                        throw BrineStepError("no step is shown as in progress")
                    }
                },
                defineCheck("{string} is shown as finished") { _, args, _ in
                    let title = try args.requireString(0)
                    guard try world.step(titled: title).state == .finished else {
                        throw BrineStepError(
                            "\"\(title)\" is not shown as finished")
                    }
                },
                defineCheck("{string} is shown as not started") { _, args, _ in
                    let title = try args.requireString(0)
                    guard try world.step(titled: title).state == .waiting else {
                        throw BrineStepError(
                            "\"\(title)\" is not shown as not started")
                    }
                },
                defineCheck("every step is shown as finished") { _, _, _ in
                    let unfinished = world.presentation.steps
                        .filter { $0.state != .finished }
                    guard unfinished.isEmpty else {
                        throw BrineStepError(
                            "steps left unfinished: \(unfinished.map(\.title))")
                    }
                },
                defineCheck("I am told everything on this iPhone was erased") { _, _, _ in
                    guard world.presentation.isFinished,
                          world.presentation.headline
                            == "Everything on this iPhone was erased" else {
                        throw BrineStepError(
                            "the finished screen said \"\(world.presentation.headline)\"")
                    }
                },
                defineCheck("I am told which step did not finish") { _, _, _ in
                    guard let failure = world.presentation.failure else {
                        throw BrineStepError("no failure is shown at all")
                    }
                    guard failure.stage != .preparing else {
                        throw BrineStepError(
                            "the failure was blamed on \"preparing\", which is not a step")
                    }
                    guard failure.title.contains(failure.stage.title) else {
                        throw BrineStepError(
                            "the failure headline does not name the step: \(failure.title)")
                    }
                },
                defineCheck("I am told what stopped the deletion") { _, _, _ in
                    guard let failure = world.presentation.failure else {
                        throw BrineStepError("no failure is shown at all")
                    }
                    guard !failure.title.isEmpty, !failure.message.isEmpty else {
                        throw BrineStepError(
                            "the refusal is shown with nothing written on it")
                    }
                },
                defineCheck("the step I am told about is {string}") { _, args, _ in
                    let title = try args.requireString(0)
                    guard let failure = world.presentation.failure,
                          failure.stage.title.caseInsensitiveCompare(title)
                            == .orderedSame else {
                        throw BrineStepError(
                            "the failure named \(String(describing: world.presentation.failure?.stage.title)), not \"\(title)\"")
                    }
                },
                defineCheck("that step is shown as failed") { _, _, _ in
                    guard let failure = world.presentation.failure,
                          try world.step(titled: failure.stage.title).state
                            == .failed else {
                        throw BrineStepError(
                            "the failing step is not shown as failed")
                    }
                },
                defineCheck("the steps after it are shown as not started") { _, _, _ in
                    guard let failure = world.presentation.failure,
                          let index = world.presentation.steps.firstIndex(where: {
                              $0.stage == failure.stage
                          }) else {
                        throw BrineStepError("no failing step to measure from")
                    }
                    let after = world.presentation.steps.dropFirst(index + 1)
                        .filter { $0.state != .waiting }
                    guard after.isEmpty else {
                        throw BrineStepError(
                            "steps after the failure claim progress: \(after.map(\.title))")
                    }
                },
                defineCheck("I am offered a way to try again") { _, _, _ in
                    guard world.presentation.failure?.isRetryable == true else {
                        throw BrineStepError(
                            "a retryable failure offered no retry")
                    }
                },
                defineCheck("I am not offered a way to try again") { _, _, _ in
                    guard world.presentation.failure?.isRetryable == false else {
                        throw BrineStepError(
                            "a failure retrying cannot fix still offered a retry")
                    }
                },
                defineCheck("I am told to sign in again") { _, _, _ in
                    guard let message = world.presentation.failure?.message,
                          message.lowercased().contains("sign in again") else {
                        throw BrineStepError(
                            "the message gives the person nothing to do: \(String(describing: world.presentation.failure?.message))")
                    }
                },
                defineCheck("I am not shown an indefinite spinner") { _, _, _ in
                    guard !world.presentation.isRunning,
                          world.presentation.failure != nil else {
                        throw BrineStepError(
                            "the screen is still spinning after the erase refused")
                    }
                },
            ]))
    }
}
