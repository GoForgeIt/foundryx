import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// `features/a-restored-radio-commits-nothing.feature` — P2.1, the ingress gate.
///
/// The fourth scenario is the one that stops this being a gate that simply says no to everything:
/// after a restoration is reconciled, a transfer this run opens must work normally. A refusal
/// mechanism with no path back is indistinguishable from a broken radio.
final class RestoredRadioCommitsNothingFeatureTests: XCTestCase {
    func testARestoredRadioCommitsNothing() async throws {
        let world = RestoredRadioWorld()
        let result = try await BrineFeatureRunner.run(
            "a-restored-radio-commits-nothing",
            registry: StepRegistry(RestoredRadioSteps.make(world)))
        XCTAssertEqual(result.passed, 4, "all four scenarios must run and pass")
    }
}

private enum RestoredRadioSteps {
    static func make(_ world: RestoredRadioWorld) -> [StepDefinition] {
        let givens = [
            "a transfer opened by a previous run of the app",
            "a transfer this run of the app opened",
            "no transfer is open",
        ]
        let whens = [
            "the restored radio delivers a chunk",
            "the radio delivers a chunk",
            "the restoration is reconciled",
            "this run opens a transfer and the radio delivers a chunk",
        ]
        let thens = [
            "the chunk is refused as belonging to another run",
            "the refusal says which run it came from",
            "the chunk is accepted",
            "the chunk is refused for having no transfer to belong to",
            "the previous run's chunks are still refused",
        ]
        var steps = givens.map { p in defineStep(p) { c, _, _ in try world.given(p); return c } }
        steps += whens.map { p in defineStep(p) { c, _, _ in try world.when(p); return c } }
        steps += thens.map { p in defineCheck(p) { _, _, _ in try world.then(p) } }
        return steps
    }
}

private final class RestoredRadioWorld {
    private var gate = PocketRestorationGate()
    /// What the arriving bytes claim. A restored stream carries the previous run's stamp.
    private var carried = PocketTransferGeneration(0)
    private var verdict: PocketIngressVerdict?
    private var staleVerdict: PocketIngressVerdict?

    func given(_ phrase: String) throws {
        gate = PocketRestorationGate(startingAfter: PocketTransferGeneration(7))
        verdict = nil
        staleVerdict = nil
        switch phrase {
        case "a transfer opened by a previous run of the app":
            // The previous run's transfer, still delivering. This process opened its own.
            carried = PocketTransferGeneration(7)
            gate.openTransferInThisProcess()
        case "a transfer this run of the app opened":
            carried = gate.openTransferInThisProcess()
        case "no transfer is open":
            carried = gate.generation
        default: throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    func when(_ phrase: String) throws {
        switch phrase {
        case "the restored radio delivers a chunk", "the radio delivers a chunk":
            verdict = gate.admit(carried)
        case "the restoration is reconciled":
            gate.reconcileRestoration()
        case "this run opens a transfer and the radio delivers a chunk":
            carried = gate.openTransferInThisProcess()
            verdict = gate.admit(carried)
            // AND THE OLD STREAM, ASKED AGAIN. Without this the scenario passes whether or not
            // the generation actually advanced — proved by mutation: deleting the increment left
            // it green, because "a transfer can be opened afterwards" is true either way.
            staleVerdict = gate.admit(PocketTransferGeneration(7))
        default: throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    func then(_ phrase: String) throws {
        switch phrase {
        case "the chunk is refused as belonging to another run":
            guard case .refuseRestoredStream = verdict else {
                throw BrineStepError(
                    "a chunk from a transfer this process never opened was \(verdict as Any) — "
                        + "it would reach a fresh writer with no expected byte count")
            }
        case "the refusal says which run it came from":
            guard case .refuseRestoredStream(let c, let cur) = verdict, c != cur else {
                throw BrineStepError("the refusal names no generations, so a log cannot tell "
                                     + "a restored stream from an idle radio")
            }
        case "the chunk is accepted":
            guard verdict?.isAccepted == true else {
                throw BrineStepError("this run's own chunk was refused: \(verdict as Any)")
            }
        case "the previous run's chunks are still refused":
            guard case .refuseRestoredStream = staleVerdict else {
                throw BrineStepError(
                    "after reconciliation the PREVIOUS run's stream was \(staleVerdict as Any) — "
                        + "the generation did not advance, so a restored stream and this run's "
                        + "own transfer are indistinguishable")
            }

        case "the chunk is refused for having no transfer to belong to":
            guard verdict == .refuseNoTransferOpen else {
                throw BrineStepError("a chunk with nothing open was \(verdict as Any)")
            }
        default: throw BrineStepError("unhandled Then: \(phrase)")
        }
    }
}
