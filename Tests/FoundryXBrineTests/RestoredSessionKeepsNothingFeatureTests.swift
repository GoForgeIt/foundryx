import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// `features/a-restored-session-keeps-nothing-it-cannot-account-for.feature` — P2.2, AC1.
///
/// The second scenario is the paired existence and it is not decoration: every other scenario
/// here is satisfied by an implementation that refuses everything, which would be a drain that
/// never keeps a recording. AC2 exists in the spec for exactly this reason.
///
/// The fourth is the one a digest cannot catch. `PocketRecorderFileWriter` re-reads what it wrote
/// and compares a hash, which proves the bytes ARRIVED INTACT — not that they are ALL of them. A
/// truncated file with a correct digest is a complete-looking recording that is missing its end.
final class RestoredSessionKeepsNothingFeatureTests: XCTestCase {
    func testARestoredSessionKeepsNothingItCannotAccountFor() async throws {
        let world = RestoredKeepWorld()
        let result = try await BrineFeatureRunner.run(
            "a-restored-session-keeps-nothing-it-cannot-account-for",
            registry: StepRegistry(RestoredKeepSteps.make(world)))
        XCTAssertEqual(result.passed, 4, "all four scenarios must run and pass")
    }
}

private enum RestoredKeepSteps {
    static func make(_ world: RestoredKeepWorld) -> [StepDefinition] {
        let givens = [
            "a transfer a previous run of the app opened",
            "a transfer this run opened, with the recorder's announced size",
            "a transfer this run opened, where the announced size was never seen",
        ]
        let whens = [
            "the whole payload is offered to be kept",
            "only part of the payload is offered to be kept",
        ]
        let thens = [
            "it is refused as belonging to another run",
            "nothing was kept",
            "it is kept",
            "it is refused for having nothing to check against",
            "it is refused for weighing less than the recorder said",
            "the refusal names both numbers",
        ]
        var steps = givens.map { p in defineStep(p) { c, _, _ in try world.given(p); return c } }
        steps += whens.map { p in defineStep(p) { c, _, _ in try world.when(p); return c } }
        steps += thens.map { p in defineCheck(p) { _, _, _ in try world.then(p) } }
        return steps
    }
}

private final class RestoredKeepWorld {
    private static let announced = 19_770
    private var gate = PocketRestorationGate()
    private var carried = PocketTransferGeneration(0)
    private var announcedTotal: Int?
    private var admission: PocketCommitAdmission?

    func given(_ phrase: String) throws {
        gate = PocketRestorationGate(startingAfter: PocketTransferGeneration(7))
        admission = nil
        switch phrase {
        case "a transfer a previous run of the app opened":
            gate.openTransferInThisProcess()
            carried = PocketTransferGeneration(7)   // the previous run's stamp
            announcedTotal = Self.announced
        case "a transfer this run opened, with the recorder's announced size":
            carried = gate.openTransferInThisProcess()
            announcedTotal = Self.announced
        case "a transfer this run opened, where the announced size was never seen":
            carried = gate.openTransferInThisProcess()
            announcedTotal = nil
        default: throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    func when(_ phrase: String) throws {
        let bytes: Int
        switch phrase {
        case "the whole payload is offered to be kept": bytes = Self.announced
        case "only part of the payload is offered to be kept": bytes = Self.announced - 512
        default: throw BrineStepError("unhandled When: \(phrase)")
        }
        admission = PocketRestoredTransaction.admit(
            payload: Data(repeating: 0x5A, count: bytes),
            carried: carried, gate: gate, announced: announcedTotal)
    }

    func then(_ phrase: String) throws {
        switch phrase {
        case "it is refused as belonging to another run":
            guard admission == .refuseRestoredStream else {
                throw BrineStepError(
                    "bytes from a previous run's transfer were \(admission as Any) — committed, "
                        + "they become a file that looks like a recording and is not")
            }
        case "nothing was kept":
            guard admission?.isAdmitted == false else { throw BrineStepError("admitted") }
        case "it is kept":
            guard admission?.isAdmitted == true else {
                throw BrineStepError(
                    "this run's own complete transfer was refused: \(admission as Any). Every "
                        + "other scenario here passes on a build that refuses everything")
            }
        case "it is refused for having nothing to check against":
            guard admission == .refuseNoAnnouncedTotal else {
                throw BrineStepError("\(admission as Any)")
            }
        case "it is refused for weighing less than the recorder said":
            guard case .refuseByteCountMismatch = admission else {
                throw BrineStepError(
                    "a short payload was \(admission as Any) — its digest is correct, so nothing "
                        + "downstream would ever notice the missing end")
            }
        case "the refusal names both numbers":
            guard case .refuseByteCountMismatch(let got, let ann) = admission,
                  got != ann, admission?.reason?.contains("\(ann)") == true else {
                throw BrineStepError("the refusal does not say what arrived versus what was owed")
            }
        default: throw BrineStepError("unhandled Then: \(phrase)")
        }
    }
}
