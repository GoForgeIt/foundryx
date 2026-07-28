import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for `features/device-gap-recovery.feature` (track
/// 20260725T2306_device_agnostic_recording_source, task T3).
///
/// Drives the real `GapRecoveryWindow` and the real `OmiOfflineSyncEngine.Outcome` values
/// the shipped engine produces. The window is a value type precisely so every close path is
/// data rather than a call-site count, which is what makes this hermetic.
final class DeviceGapRecoveryFeatureTests: XCTestCase {

    func testDeviceGapRecoveryFeature() async throws {
        let world = DeviceGapRecoveryWorld()
        let result = try await BrineFeatureRunner.run(
            "device-gap-recovery",
            registry: StepRegistry(DeviceGapRecoverySteps.make(world: world)))
        XCTAssertEqual(result.passed, 13,
                       "device-gap-recovery must run all 13 scenarios (6 plain + 7 outline rows)")
    }

    /// Every engine ending must map to exactly one outcome, and the mapping must be TOTAL:
    /// a new engine case with no mapping would otherwise silently inherit some default.
    func testEveryEngineEndingMapsAndOnlyRealLossIsALoss() {
        let endings: [(OmiOfflineSyncEngine.Outcome, GapRecoveryOutcome, Bool)] = [
            (.nothingToSync, .nothingBuffered, false),
            (.synced(records: 3, frames: 120), .recovered(records: 3, frames: 120), false),
            (.synced(records: 0, frames: 0), .nothingBuffered, false),
        ]
        for (ending, expected, isLoss) in endings {
            XCTAssertEqual(GapRecoveryWindow.outcome(for: ending), expected,
                           "wrong outcome for \(ending)")
            XCTAssertEqual(GapRecoveryWindow.outcome(for: ending).isLoss, isLoss)
        }
        // The three reason-carrying endings, checked by SHAPE so the wording stays free.
        switch GapRecoveryWindow.outcome(for: .aborted(records: 2, frames: 40, reason: "link dropped")) {
        case .partiallyRecovered(let records, let frames, _):
            XCTAssertEqual([records, frames], [2, 40])
        default:
            XCTFail("a partial transfer is not partially recovered")
        }
        XCTAssertFalse(GapRecoveryWindow.outcome(for: .failed("link dropped")).isLoss,
                       "a failed sync leaves the span ON THE DEVICE — reporting it as a loss is a lie")
        XCTAssertTrue(GapRecoveryWindow.outcome(for: .unsupportedProtocol("not ring-shaped")).isLoss,
                      "firmware that cannot replay the gap means the audio really is gone")
    }

    /// The rule the plan states: at most one outcome per opened window, and exactly one
    /// only for a window tagged at open as following an interrupted capture.
    func testAtMostOneOutcomePerWindowAndNoneWithoutAnInterruptedCapture() {
        for cause: GapRecoveryWindow.Close in [
            .linkDroppedBeforeEngine,
            .decisionDeadlinePassed,
            .closedWithoutEngine(reason: "superseded"),
            .engineFinished(.nothingToSync),
        ] {
            var tagged = GapRecoveryWindow(interruptedCaptureId: "cap-1")
            XCTAssertNotNil(tagged.close(cause), "a tagged window published nothing for \(cause)")
            XCTAssertNil(tagged.close(cause), "a second close published a second outcome for \(cause)")
            XCTAssertFalse(tagged.isOpen)

            var untagged = GapRecoveryWindow(interruptedCaptureId: nil)
            XCTAssertNil(untagged.close(cause),
                         "a window that interrupted nothing spoke anyway for \(cause)")
            XCTAssertNil(untagged.published)
        }
    }
}

// MARK: - World

final class DeviceGapRecoveryWorld: @unchecked Sendable {
    var window: GapRecoveryWindow?
    var outcomes: [GapRecoveryOutcome] = []
    /// Every outcome the scenario has seen, including across window re-opens, so
    /// "nothing anywhere claimed a loss" can be asserted over the whole history.
    var history: [GapRecoveryOutcome] = []
    var continuation: GapCaptureContinuation?
    var interruptedCaptureId: String?

    static let conversation = "cap-2026-07-28T0300"

    func open() {
        window = GapRecoveryWindow(interruptedCaptureId: interruptedCaptureId)
        outcomes = []
    }

    func close(_ cause: GapRecoveryWindow.Close) {
        guard var current = window else { return }
        if let outcome = current.close(cause) {
            outcomes.append(outcome)
            history.append(outcome)
        }
        window = current
    }
}

enum DeviceGapRecoverySteps {

    static func ending(named label: String) throws -> OmiOfflineSyncEngine.Outcome {
        switch label {
        case "nothing to sync": return .nothingToSync
        case "a full transfer": return .synced(records: 4, frames: 200)
        case "a transfer with no frames": return .synced(records: 0, frames: 0)
        case "a partial transfer": return .aborted(records: 2, frames: 40, reason: "sync budget exhausted")
        case "a failure": return .failed("link dropped")
        case "a dropped link": return .failed("link dropped")
        case "unsupported firmware": return .unsupportedProtocol("status not ring-shaped")
        default: throw BrineStepError("unknown engine ending: \(label)")
        }
    }

    static func matches(_ outcome: GapRecoveryOutcome, _ label: String) throws -> Bool {
        switch label {
        case "nothing buffered": if case .nothingBuffered = outcome { return true }
        case "recovered": if case .recovered = outcome { return true }
        case "partially recovered": if case .partiallyRecovered = outcome { return true }
        case "still on the device": if case .nothingToRecover = outcome { return true }
        case "unrecoverable": if case .unrecoverable = outcome { return true }
        default: throw BrineStepError("unknown outcome label: \(label)")
        }
        return false
    }

    static func make(world: DeviceGapRecoveryWorld) -> [StepDefinition] {
        [
            defineStep("a conversation was interrupted when the link dropped") { ctx, _, _ in
                world.interruptedCaptureId = DeviceGapRecoveryWorld.conversation
                world.history = []
                return ctx
            },
            defineStep("no conversation was interrupted when the link dropped") { ctx, _, _ in
                world.interruptedCaptureId = nil
                world.history = []
                return ctx
            },
            defineStep("the device reconnects and the gap window opens") { ctx, _, _ in
                world.open()
                guard world.window?.isOpen == true else {
                    throw BrineStepError("the window did not open")
                }
                return ctx
            },
            defineStep("the link drops again before the sync engine starts") { ctx, _, _ in
                world.close(.linkDroppedBeforeEngine)
                return ctx
            },
            defineStep("the storage service never appears and the decision deadline passes") { ctx, _, _ in
                world.close(.decisionDeadlinePassed)
                return ctx
            },
            defineStep("the sync engine ends with {string}") { ctx, p, _ in
                world.close(.engineFinished(try ending(named: try p.requireString(0))))
                return ctx
            },
            defineStep("the window is closed twice") { ctx, _, _ in
                world.close(.linkDroppedBeforeEngine)
                world.close(.engineFinished(.synced(records: 9, frames: 900)))
                return ctx
            },
            defineStep("the device reconnects and the same span is pulled back") { ctx, _, _ in
                world.open()
                world.close(.engineFinished(.synced(records: 3, frames: 150)))
                return ctx
            },
            defineCheck("the outcome says the audio is still on the device") { _, _, _ in
                guard let outcome = world.outcomes.last else {
                    throw BrineStepError("no outcome was published at all")
                }
                guard case .nothingToRecover = outcome else {
                    throw BrineStepError("the outcome is \(outcome)")
                }
            },
            defineCheck("the outcome is not a loss") { _, _, _ in
                guard let outcome = world.outcomes.last else {
                    throw BrineStepError("no outcome was published at all")
                }
                guard !outcome.isLoss else { throw BrineStepError("\(outcome) is reported as a loss") }
            },
            defineCheck("the outcome reports the audio as recovered") { _, _, _ in
                guard let outcome = world.outcomes.last else {
                    throw BrineStepError("no outcome was published at all")
                }
                guard case .recovered(let records, let frames) = outcome, records > 0, frames > 0 else {
                    throw BrineStepError("the outcome is \(outcome)")
                }
            },
            defineCheck("no outcome anywhere in this scenario claimed the audio was unrecoverable") { _, _, _ in
                guard world.history.count >= 2 else {
                    throw BrineStepError(
                        "only \(world.history.count) outcome(s) seen — the claim is vacuous")
                }
                let losses = world.history.filter(\.isLoss)
                guard losses.isEmpty else {
                    throw BrineStepError("audio still on the device was reported lost: \(losses)")
                }
            },
            defineCheck("no outcome is published at all") { _, _, _ in
                guard world.outcomes.isEmpty else {
                    throw BrineStepError("a window that interrupted nothing published \(world.outcomes)")
                }
                // The check must be able to see an outcome, or "none" is free: the same
                // close on a TAGGED window must publish exactly one.
                var tagged = GapRecoveryWindow(interruptedCaptureId: "control")
                guard tagged.close(.linkDroppedBeforeEngine) != nil else {
                    throw BrineStepError("no window ever publishes anything — the check is vacuous")
                }
            },
            defineCheck("the outcome reads {string}") { _, p, _ in
                let label = try p.requireString(0)
                guard let outcome = world.outcomes.last else {
                    throw BrineStepError("no outcome was published at all")
                }
                guard try matches(outcome, label) else {
                    throw BrineStepError("the outcome is \(outcome), expected \(label)")
                }
            },
            defineCheck("the outcome is a loss only when the audio is really gone") { _, _, _ in
                guard let outcome = world.outcomes.last else {
                    throw BrineStepError("no outcome was published at all")
                }
                // Only the unrecoverable case may report a loss, and it must.
                if case .unrecoverable = outcome {
                    guard outcome.isLoss else { throw BrineStepError("\(outcome) does not report a loss") }
                } else {
                    guard !outcome.isLoss else { throw BrineStepError("\(outcome) reports a loss") }
                }
            },
            defineCheck("exactly one outcome is published") { _, _, _ in
                guard world.outcomes.count == 1 else {
                    throw BrineStepError("\(world.outcomes.count) outcomes were published: \(world.outcomes)")
                }
            },
            defineCheck("the window still carries that conversation identity") { _, _, _ in
                guard world.window?.interruptedCaptureId == DeviceGapRecoveryWorld.conversation else {
                    throw BrineStepError(
                        "the window carries \(String(describing: world.window?.interruptedCaptureId))")
                }
            },
            defineStep("nothing proposes a different conversation") { ctx, _, _ in
                world.continuation = world.window?.continuation(forProposedCaptureId: nil)
                return ctx
            },
            defineStep("a replacement conversation is proposed") { ctx, _, _ in
                world.continuation = world.window?.continuation(forProposedCaptureId: "cap-REPLACEMENT")
                return ctx
            },
            defineCheck("the original conversation is resumed") { _, _, _ in
                guard world.continuation == .resumeSame(captureId: DeviceGapRecoveryWorld.conversation) else {
                    throw BrineStepError("continuation is \(String(describing: world.continuation))")
                }
            },
            defineCheck("the replacement is refused and the original identity is kept") { _, _, _ in
                guard world.continuation == .refuseReplacement(
                        carrying: DeviceGapRecoveryWorld.conversation, proposed: "cap-REPLACEMENT") else {
                    throw BrineStepError("continuation is \(String(describing: world.continuation))")
                }
            },
            defineCheck("a fresh conversation is opened") { _, _, _ in
                guard world.continuation == .openFresh else {
                    throw BrineStepError("continuation is \(String(describing: world.continuation))")
                }
                // "openFresh" is the value an unimplemented continuation returns for
                // everything, so this arm proves nothing on its own. The same call on a
                // window that IS carrying an identity must resume it.
                let carrying = GapRecoveryWindow(interruptedCaptureId: "control-cap")
                guard carrying.continuation(forProposedCaptureId: nil)
                        == .resumeSame(captureId: "control-cap") else {
                    throw BrineStepError(
                        "continuation answers openFresh even when carrying an identity — the check is vacuous")
                }
            },
        ]
    }
}
