import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// `features/a-new-session-says-why-it-happened.feature` — P2.5 / AC10, and the open half of the
/// predecessor track's AC12.
///
/// The first scenario is the one that keeps the others honest: five distinct causes must produce
/// five distinct records. A vocabulary where two causes render the same is a vocabulary that
/// cannot answer "why did the radio come back", which is the question that cost eight restarts.
///
/// The last is the one with a wrong answer that looks right. A refused key and a dropped link both
/// end a session — but a refusal names something a person can act on, and a disconnect sends them
/// to look at the radio.
final class ANewSessionSaysWhyFeatureTests: XCTestCase {
    func testANewSessionSaysWhyItHappened() async throws {
        let world = ReattachReasonWorld()
        let result = try await BrineFeatureRunner.run(
            "a-new-session-says-why-it-happened",
            registry: StepRegistry(ReattachReasonSteps.make(world)))
        XCTAssertEqual(result.passed, 4, "all four scenarios must run and pass")
    }
}

private enum ReattachReasonSteps {
    static func make(_ world: ReattachReasonWorld) -> [StepDefinition] {
        let givens = [
            "all the reasons a session can restart",
            "the owner stopped a recording",
            "the recorder went quiet on the second of four attempts",
            "the recorder refused this phone's key",
        ]
        let thens = [
            "no two of them read the same",
            "none of them is unnamed",
            "the record says the owner ended it",
            "it is marked as a consequence of something the app or owner did",
            "the record says the recorder went quiet",
            "it says which attempt that was",
            "it is not marked as something the app or owner did",
            "the record says the recorder declined the key",
            "it does not read as the recorder simply leaving",
        ]
        var steps = givens.map { p in defineStep(p) { c, _, _ in try world.given(p); return c } }
        steps += thens.map { p in defineCheck(p) { _, _, _ in try world.then(p) } }
        return steps
    }
}

private final class ReattachReasonWorld {
    private var all: [PocketReattachReason] = []
    private var one: PocketReattachReason?

    func given(_ phrase: String) throws {
        switch phrase {
        case "all the reasons a session can restart":
            // THE SAME ATTEMPT NUMBERS ON BOTH, DELIBERATELY. An earlier version used 2-of-4
            // and 1-of-4, so the two rendered differently because of the NUMBERS — and a
            // mutation that gave them an identical template still passed. The causes must be
            // distinguishable by cause alone, which is the only thing a reader has when the
            // attempt counts happen to match.
            all = [.ownerStoppedOneRecording,
                   .recorderWentQuiet(attempt: 2, of: 4),
                   .linkDropped(attempt: 2, of: 4),
                   .budgetSpentMovingOn,
                   .reconciledAfterRestoration,
                   .reauthenticationRefused]
        case "the owner stopped a recording":
            one = .ownerStoppedOneRecording
        case "the recorder went quiet on the second of four attempts":
            one = .recorderWentQuiet(attempt: 2, of: 4)
        case "the recorder refused this phone's key":
            one = .reauthenticationRefused
        default: throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    private func requireOne() throws -> PocketReattachReason {
        guard let one else { throw BrineStepError("no reason staged") }
        return one
    }

    func then(_ phrase: String) throws {
        switch phrase {
        case "no two of them read the same":
            let lines = Set(all.map(\.line)), tokens = Set(all.map(\.token))
            guard lines.count == all.count, tokens.count == all.count else {
                throw BrineStepError(
                    "\(all.count) causes render \(lines.count) line(s) and \(tokens.count) "
                        + "token(s) — two causes that read alike cannot answer why the radio "
                        + "came back")
            }

        case "none of them is unnamed":
            // PAIRED EXISTENCE: six empty strings are all distinct from nothing and would satisfy
            // uniqueness only by accident. They must actually say something.
            guard all.allSatisfy({ $0.line.count > 20 && $0.token.hasPrefix("reattach:") }) else {
                throw BrineStepError("a cause renders nothing usable")
            }

        case "the record says the owner ended it":
            guard try requireOne().line.contains("you stopped") else {
                throw BrineStepError("reads as \(try requireOne().line)")
            }

        case "it is marked as a consequence of something the app or owner did":
            guard try requireOne().isConsequenceOfSomethingElse else {
                throw BrineStepError(
                    "an owner's stop is not marked as a consequence, so it reads as a fault — "
                        + "which is the misreading that cost eight app restarts")
            }

        case "the record says the recorder went quiet":
            guard try requireOne().line.contains("went quiet") else {
                throw BrineStepError("reads as \(try requireOne().line)")
            }

        case "it says which attempt that was":
            let line = try requireOne().line
            guard line.contains("2") && line.contains("4") else {
                throw BrineStepError("'\(line)' does not say which attempt of how many, so three "
                                     + "of these in a row look identical")
            }

        case "it is not marked as something the app or owner did":
            guard try !requireOne().isConsequenceOfSomethingElse else {
                throw BrineStepError("a quiet recorder was blamed on the app")
            }

        case "the record says the recorder declined the key":
            guard try requireOne().line.contains("declined") else {
                throw BrineStepError("reads as \(try requireOne().line)")
            }

        case "it does not read as the recorder simply leaving":
            let line = try requireOne().line
            guard !line.contains("left"), !line.contains("went quiet") else {
                throw BrineStepError(
                    "a refused key reads as '\(line)' — a refusal names something a person can "
                        + "act on and a disconnect sends them to look at the radio")
            }

        default: throw BrineStepError("unhandled Then: \(phrase)")
        }
    }
}
