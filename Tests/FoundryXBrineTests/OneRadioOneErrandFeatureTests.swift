import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// `features/one-radio-one-errand-even-when-nobody-is-looking.feature` — P3.0.
///
/// The last scenario is the one a flag gets wrong. A pre-empted holder eventually finishes and
/// releases — and a naive "clear the flag" release would take the radio away from whoever
/// pre-empted it, handing the owner's session to nobody mid-tap. The lease ignores a stale id.
final class OneRadioOneErrandFeatureTests: XCTestCase {
    func testOneRadioOneErrandEvenWhenNobodyIsLooking() async throws {
        let world = RadioArbiterWorld()
        let result = try await BrineFeatureRunner.run(
            "one-radio-one-errand-even-when-nobody-is-looking",
            registry: StepRegistry(RadioArbiterSteps.make(world)))
        XCTAssertEqual(result.passed, 5, "all five scenarios must run and pass")
    }
}

private enum RadioArbiterSteps {
    static func make(_ world: RadioArbiterWorld) -> [StepDefinition] {
        let givens = ["a drain running in the background", "the owner is using the radio"]
        let whens = [
            "another background drain asks for the radio",
            "the owner taps something that needs the radio",
            "a background drain asks for the radio",
            "that drain finishes",
            "the pushed-aside drain finishes",
        ]
        let thens = [
            "it is refused",
            "it is told a background drain has it",
            "the owner gets it",
            "it is told the owner has it",
            "the radio is free",
            "a background drain can have it again",
            "the owner still has the radio",
        ]
        var steps = givens.map { p in defineStep(p) { c, _, _ in try world.given(p); return c } }
        steps += whens.map { p in defineStep(p) { c, _, _ in try world.when(p); return c } }
        steps += thens.map { p in defineCheck(p) { _, _, _ in try world.then(p) } }
        return steps
    }
}

private final class RadioArbiterWorld {
    private var arbiter = PocketRadioArbiter()
    private var firstHolder: PocketRadioLease?
    private var ownerLease: PocketRadioLease?
    private var latest: PocketRadioGrant?

    func given(_ phrase: String) throws {
        arbiter = PocketRadioArbiter(); firstHolder = nil; ownerLease = nil; latest = nil
        switch phrase {
        case "a drain running in the background":
            guard case .granted(let l) = arbiter.claim(.automaticDrain) else {
                throw BrineStepError("an idle radio refused a drain")
            }
            firstHolder = l
        case "the owner is using the radio":
            guard case .granted(let l) = arbiter.claim(.owner) else {
                throw BrineStepError("an idle radio refused the owner")
            }
            firstHolder = l
        default: throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    func when(_ phrase: String) throws {
        switch phrase {
        case "another background drain asks for the radio", "a background drain asks for the radio":
            latest = arbiter.claim(.automaticDrain)
        case "the owner taps something that needs the radio":
            latest = arbiter.claim(.owner)
            if case .granted(let l) = latest! { ownerLease = l }
        case "that drain finishes", "the pushed-aside drain finishes":
            // THE HOLDER GOES AWAY. Release is deinit, so this is what "finished" means.
            firstHolder = nil
        default: throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    func then(_ phrase: String) throws {
        switch phrase {
        case "it is refused":
            guard case .heldBy = latest else {
                throw BrineStepError("a second errand was granted the radio: \(latest as Any) — "
                                     + "two authenticated sessions on one phone")
            }
        case "it is told a background drain has it":
            guard case .heldBy(.automaticDrain) = latest else {
                throw BrineStepError("\(latest as Any)")
            }
        case "it is told the owner has it":
            guard case .heldBy(.owner) = latest else { throw BrineStepError("\(latest as Any)") }
        case "the owner gets it":
            guard case .granted = latest else {
                throw BrineStepError(
                    "the owner was made to wait for a background drain — a person waiting is "
                        + "worth more than work that can be redone")
            }
        case "the radio is free":
            guard arbiter.currentHolder == nil else {
                throw BrineStepError("still held by \(arbiter.currentHolder as Any) after the "
                                     + "holder went away — a lease nobody holds is a deadlock")
            }
        case "a background drain can have it again":
            guard case .granted = arbiter.claim(.automaticDrain) else {
                throw BrineStepError("a freed radio refused the next drain")
            }
        case "the owner still has the radio":
            guard arbiter.currentHolder == .owner, ownerLease != nil else {
                throw BrineStepError(
                    "the pushed-aside drain's release took the radio from the owner — the bug a "
                        + "clear-the-flag release has, mid-tap")
            }
        default: throw BrineStepError("unhandled Then: \(phrase)")
        }
    }
}
