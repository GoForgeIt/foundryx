import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// `features/one-session-at-a-time-survives-a-restart.feature` — P2.4 / AC11.
///
/// The second scenario is the load-bearing one. "May not open a session" is trivially satisfied by
/// a policy that never lets anyone open one; what this holds is that the policy names the NEXT
/// step, and names a different one as each is completed. A refusal that cannot say what to do next
/// is a deadlock with better manners.
///
/// The fourth is the paired existence: a link this run opened is used without ceremony, or the
/// policy has made every ordinary transfer impossible.
final class OneSessionSurvivesARestartFeatureTests: XCTestCase {
    func testOneSessionAtATimeSurvivesARestart() async throws {
        let world = OneSessionWorld()
        let result = try await BrineFeatureRunner.run(
            "one-session-at-a-time-survives-a-restart",
            registry: StepRegistry(OneSessionSteps.make(world)))
        XCTAssertEqual(result.passed, 4, "all four scenarios must run and pass")
    }
}

private enum OneSessionSteps {
    static func make(_ world: OneSessionWorld) -> [StepDefinition] {
        let givens = [
            "a link iOS handed back from a previous run",
            "a link this run of the app opened itself",
            "the app has stopped accepting what it sends",
            "the half-finished transfer is dropped",
            "the old link is retired",
        ]
        let thens = [
            "the app may not open a session yet",
            "it is told to stop accepting what the old link is sending",
            "it is told to drop the half-finished transfer",
            "the app may open a session",
        ]
        var steps = givens.map { p in defineStep(p) { c, _, _ in try world.given(p); return c } }
        steps += thens.map { p in defineCheck(p) { _, _, _ in try world.then(p) } }
        return steps
    }
}

private final class OneSessionWorld {
    private var restored = true
    private var done: [PocketRestoredSessionStep] = []

    func given(_ phrase: String) throws {
        switch phrase {
        case "a link iOS handed back from a previous run":
            restored = true; done = []
        case "a link this run of the app opened itself":
            restored = false; done = []
        case "the app has stopped accepting what it sends":
            done.append(.closeIngress)
        case "the half-finished transfer is dropped":
            done.append(.discardPartialTransfer)
        case "the old link is retired":
            done.append(.retireLink)
        default: throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    private var blocking: PocketRestoredSessionStep? {
        if PocketRestoredSessionPolicy.maySkipReconciliation(
            linkWasOpenedByThisProcess: !restored) { return nil }
        return PocketRestoredSessionPolicy.blockingStep(afterCompleting: done)
    }

    func then(_ phrase: String) throws {
        switch phrase {
        case "the app may not open a session yet":
            guard blocking != nil else {
                throw BrineStepError(
                    "the app was allowed to write its key over a link the recorder still "
                        + "associates with the previous run's session — which may silently re-key")
            }
        case "it is told to stop accepting what the old link is sending":
            guard blocking == .closeIngress else {
                throw BrineStepError("the first thing asked for was \(blocking as Any); the radio "
                                     + "does not stop talking while the later steps run")
            }
        case "it is told to drop the half-finished transfer":
            guard blocking == .discardPartialTransfer else {
                throw BrineStepError("asked for \(blocking as Any) rather than the discard — a "
                                     + "refusal that cannot name the next step is a deadlock")
            }
        case "the app may open a session":
            guard blocking == nil else {
                throw BrineStepError("still blocked on \(blocking as Any) — a policy that never "
                                     + "lets anyone talk satisfies every refusal above")
            }
        default: throw BrineStepError("unhandled Then: \(phrase)")
        }
    }
}
