import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// `features/recordings-come-over-without-being-asked.feature` — Phase 3: AC7, AC8, AC15, AC16, AC17.
///
/// The FIRST scenario is the paired existence for all seven refusals. Every other scenario here is
/// satisfied by a policy that never starts anything, which would be a feature that does not exist.
///
/// The LAST is a product decision rather than a technical one: an automatic drain contributes no
/// candidates to the owner-armed clear. Clearing removes a recording from the only device holding
/// it, and an unattended pull composed with an unattended delete is irreversible with nobody
/// watching.
final class RecordingsComeOverWithoutBeingAskedFeatureTests: XCTestCase {
    func testRecordingsComeOverWithoutBeingAsked() async throws {
        let world = AutoDrainWorld()
        let result = try await BrineFeatureRunner.run(
            "recordings-come-over-without-being-asked",
            registry: StepRegistry(AutoDrainSteps.make(world)))
        XCTAssertEqual(result.passed, 8, "all eight scenarios must run and pass")
    }
}

private enum AutoDrainSteps {
    static func make(_ world: AutoDrainWorld) -> [StepDefinition] {
        let givens = [
            "a recorder this phone has been set up with, holding two recordings",
            "a recorder this phone has never been set up with",
            "a recorder this phone has been set up with, whose waiting list is corrupt",
            "a recorder this phone has been set up with, holding nothing",
            "the owner stopped everything",
            "the recorder is already talking to another phone",
            "the phone is in low power mode",
            "two recordings that came over without anybody asking",
        ]
        let thens = [
            "a drain starts on its own",
            "no drain starts",
            "the reason is that the recorder is not set up here",
            "the reason is that the owner stopped everything",
            "the reason is that another phone has it",
            "the reason is low power mode",
            "the reason names the unreadable list",
            "the reason is simply that nothing is waiting",
            "none of them is offered up to be cleared from the recorder",
        ]
        var steps = givens.map { p in defineStep(p) { c, _, _ in try world.given(p); return c } }
        steps += thens.map { p in defineCheck(p) { _, _, _ in try world.then(p) } }
        return steps
    }
}

private final class AutoDrainWorld {
    private var paired = true
    private var backlog: PocketBacklogReadout = .none
    private var radio: PocketRadioClaimant?
    private var foreign = false
    private var lowPower = false
    private var autoCommitted: [PocketRecordingRequest] = []

    private static func twoWaiting(stopEverything: Bool = false) -> PocketBacklogReadout {
        .backlog(PocketBacklog(entries: [
            PocketBacklogEntry(date: "2026-08-07", timestamp: "20260807142852", sizeBytes: 19_770),
            PocketBacklogEntry(date: "2026-08-07", timestamp: "20260807153240", sizeBytes: 185_078),
        ], stopEverything: stopEverything))
    }

    private func reset() {
        paired = true; backlog = .none; radio = nil; foreign = false; lowPower = false
        autoCommitted = []
    }

    func given(_ phrase: String) throws {
        switch phrase {
        case "a recorder this phone has been set up with, holding two recordings":
            reset(); backlog = Self.twoWaiting()
        case "a recorder this phone has never been set up with":
            reset(); paired = false; backlog = Self.twoWaiting()
        case "a recorder this phone has been set up with, whose waiting list is corrupt":
            reset(); backlog = .unreadable(because: "the backlog file did not decode")
        case "a recorder this phone has been set up with, holding nothing":
            reset(); backlog = .backlog(PocketBacklog())
        case "the owner stopped everything":
            backlog = Self.twoWaiting(stopEverything: true)
        case "the recorder is already talking to another phone":
            foreign = true
        case "the phone is in low power mode":
            lowPower = true
        case "two recordings that came over without anybody asking":
            reset()
            autoCommitted = [PocketRecordingRequest(date: "2026-08-07", timestamp: "20260807142852"),
                             PocketRecordingRequest(date: "2026-08-07", timestamp: "20260807153240")]
        default: throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    private var refusal: PocketAutomaticDrainRefusal? {
        PocketAutomaticDrainPolicy.refusal(.init(
            recorderIsPaired: paired, backlog: backlog, radioHeldBy: radio,
            recorderReportsForeignSession: foreign, lowPowerModeEnabled: lowPower))
    }

    func then(_ phrase: String) throws {
        switch phrase {
        case "a drain starts on its own":
            guard refusal == nil else {
                throw BrineStepError(
                    "a paired recorder with recordings waiting refused to drain: \(refusal!) — "
                        + "every other scenario here passes on a policy that never starts")
            }
        case "no drain starts":
            guard refusal != nil else { throw BrineStepError("a drain started") }
        case "the reason is that the recorder is not set up here":
            guard refusal == .recorderNotPaired else { throw BrineStepError("\(refusal!)") }
        case "the reason is that the owner stopped everything":
            guard refusal == .ownerStoppedEverything else { throw BrineStepError("\(refusal!)") }
        case "the reason is that another phone has it":
            guard refusal == .anotherPhoneIsDraining else {
                throw BrineStepError("\(refusal!) — two phones draining one recorder is a state "
                                     + "nobody designed for; refuse rather than race")
            }
        case "the reason is low power mode":
            guard refusal == .lowPowerMode else { throw BrineStepError("\(refusal!)") }
        case "the reason names the unreadable list":
            guard case .backlogUnreadable(let why) = refusal, why.count > 5 else {
                throw BrineStepError("\(refusal as Any) — an unreadable intent and an empty queue "
                                     + "are opposite states")
            }
        case "the reason is simply that nothing is waiting":
            guard refusal == .backlogEmpty else { throw BrineStepError("\(refusal!)") }
        case "none of them is offered up to be cleared from the recorder":
            let candidates = PocketAutomaticDrainPolicy.clearCandidates(
                broughtOverAutomatically: autoCommitted)
            guard autoCommitted.count == 2 else { throw BrineStepError("nothing came over, so this proves nothing") }
            guard candidates.isEmpty else {
                throw BrineStepError(
                    "\(candidates.count) recording(s) queued for deletion by a drain nobody "
                        + "watched — clearing removes a recording from the only device holding it")
            }
        default: throw BrineStepError("unhandled Then: \(phrase)")
        }
    }
}
