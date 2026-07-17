import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Drives `features/speaker-confirm-feedback.feature` against the REAL confirm seams
/// (track 20260717T0900_speaker_confirm_feedback):
///  • `SpeakerConfirmController` — the per-slot phase machine the inline
///    "Confirm: <name>" affordances render (in-flight → confirmed / failed).
///  • `SpeakerConfirmFlow.run` + `SpeakerConfirmPresentation.sheetReaction` — the tag
///    sheet's durable, deadline-bounded confirm and its dismiss/stay-open decision.
///  • `SpeakerConfirmQueue` — the durable intent that survives every failure.
///  • `SpeakerConfirmFlow.drainPending` — the 5s-drain retry leg incl. the 401 →
///    re-auth stop (the observed silent ExpiredSignature loop).
/// Hermetic: the door leg is an injected `ship` closure; no network, no SwiftUI.
final class SpeakerConfirmFeedbackTests: XCTestCase {

    func testSpeakerConfirmFeedbackFeature() async throws {
        let world = ConfirmFeedbackWorld()
        defer { world.cleanup() }
        let registry = StepRegistry(ConfirmFeedbackSteps.make(world: world))
        try await BrineFeatureRunner.run("speaker-confirm-feedback", registry: registry)
    }
}

// MARK: - world

private final class ConfirmFeedbackWorld: @unchecked Sendable {
    enum ShipBehavior {
        case acknowledge          // door 200 + ConfirmOutcome
        case unreachable          // transport failure
        case hang                 // request lands, answer never returns (b230 class)
        case reject               // door/Lore refuses (HTTP 500)
    }

    let captureId = "cap-feedback"
    let slot = "speaker_1"
    var dir: URL
    var behavior: ShipBehavior = .acknowledge
    var deadline: TimeInterval = 5

    var controller: SpeakerConfirmController?
    var observedInFlight = false
    var resolvedPhase: SpeakerConfirmPhase?
    var sheetReaction: SpeakerSheetReaction?
    var tapTask: Task<SpeakerConfirmPhase, Never>?

    // drain scenario
    var drainAuthExpired = false
    var drainShipCalls = 0

    init() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scfb-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func cleanup() {
        tapTask?.cancel()
        try? FileManager.default.removeItem(at: dir)
    }

    func reset() {
        tapTask?.cancel(); tapTask = nil
        behavior = .acknowledge
        deadline = 5
        controller = nil
        observedInFlight = false
        resolvedPhase = nil
        sheetReaction = nil
        drainAuthExpired = false
        drainShipCalls = 0
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func outcome() -> ConfirmOutcome {
        ConfirmOutcome(captureId: captureId, slotLabel: slot, status: "confirmed",
                       speakerId: "sp-9", speakerName: "Nick", offeredCaptures: [])
    }

    /// The injected door leg, per the declared behavior.
    func ship() -> @Sendable () async throws -> ConfirmOutcome {
        let behavior = behavior
        let outcome = outcome()
        return {
            switch behavior {
            case .acknowledge: return outcome
            case .unreachable: throw DoorError.transport("computer unreachable")
            case .reject: throw DoorError.http(500)
            case .hang:
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw DoorError.transport("never answered")
            }
        }
    }

    @MainActor
    func makeController() -> SpeakerConfirmController {
        let c = SpeakerConfirmController(baseDir: dir, deadline: deadline, successDwell: 10)
        controller = c
        return c
    }

    @MainActor
    func phase() -> SpeakerConfirmPhase {
        controller?.phase(for: slot) ?? .idle
    }

    func pending() -> [SpeakerConfirmQueue.Entry] {
        SpeakerConfirmQueue.pending(baseDir: dir)
    }
}

// MARK: - steps

private enum ConfirmFeedbackSteps {
    static func make(world w: ConfirmFeedbackWorld) -> [StepDefinition] {
        [
            // ── Givens ────────────────────────────────────────────────────────
            defineStep("a conversation with a tentatively matched speaker") { ctx, _, _ in
                w.reset()
                return ctx
            },
            defineStep("the tag-speaker sheet is open for a tentatively matched speaker") { ctx, _, _ in
                w.reset()
                return ctx
            },
            defineStep("the tag-speaker sheet is open for an unnamed speaker") { ctx, _, _ in
                w.reset()
                return ctx
            },
            defineStep("speaker confirms are pending on my phone") { ctx, _, _ in
                w.reset()
                SpeakerConfirmQueue.enqueue(captureId: "cap-a", slot: "speaker_0", baseDir: w.dir)
                SpeakerConfirmQueue.enqueue(captureId: "cap-b", slot: "speaker_1",
                                            name: "Dana", baseDir: w.dir)
                return ctx
            },
            defineStep("my computer acknowledges the confirmation") { ctx, _, _ in
                w.behavior = .acknowledge
                return ctx
            },
            defineStep("my computer cannot be reached") { ctx, _, _ in
                w.behavior = .unreachable
                return ctx
            },
            defineStep("my computer accepts the request but the answer never arrives") { ctx, _, _ in
                w.behavior = .hang
                w.deadline = 0.3   // the flow's ceiling, scaled down for the test
                return ctx
            },
            defineStep("my computer rejects the confirmation") { ctx, _, _ in
                w.behavior = .reject
                return ctx
            },
            defineStep("my sign-in to the computer has expired") { ctx, _, _ in
                // Drain scenario: every ship attempt is rejected 401 (ExpiredSignature).
                return ctx
            },

            // ── Whens ─────────────────────────────────────────────────────────
            defineStep("I tap the confirm affordance for that speaker") { ctx, _, _ in
                // The tap starts the flow; the affordance must read in-flight BEFORE
                // the door has answered (behavior defaults to a pending round trip).
                w.behavior = .hang
                w.deadline = 0.5
                let controller = await w.makeController()
                let ship = w.ship()
                let captureId = w.captureId, slot = w.slot
                w.tapTask = Task { @MainActor in
                    await controller.confirm(captureId: captureId, slot: slot, ship: ship)
                }
                for _ in 0..<200 where !w.observedInFlight {
                    if await w.phase() == .inFlight { w.observedInFlight = true; break }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                return ctx
            },
            defineStep("I tap the confirm affordance and the round trip completes") { ctx, _, _ in
                let controller = await w.makeController()
                let ship = w.ship()
                w.resolvedPhase = await controller.confirm(
                    captureId: w.captureId, slot: w.slot, ship: ship)
                return ctx
            },
            defineStep("I tap the confirm affordance and wait past the deadline") { ctx, _, _ in
                let controller = await w.makeController()
                let ship = w.ship()
                let start = Date()
                w.resolvedPhase = await controller.confirm(
                    captureId: w.captureId, slot: w.slot, ship: ship)
                guard Date().timeIntervalSince(start) < 5 else {
                    throw BrineStepError("deadline did not bound the wait")
                }
                return ctx
            },
            defineStep("I confirm the speaker from the sheet and the round trip completes") { ctx, _, _ in
                let result = await SpeakerConfirmFlow.run(
                    captureId: w.captureId, slot: w.slot, name: nil,
                    baseDir: w.dir, deadline: w.deadline, ship: w.ship())
                w.sheetReaction = SpeakerConfirmPresentation.sheetReaction(result)
                return ctx
            },
            defineStep("I save a name for the speaker and the round trip completes") { ctx, _, _ in
                let result = await SpeakerConfirmFlow.run(
                    captureId: w.captureId, slot: w.slot, name: "Dana",
                    baseDir: w.dir, deadline: w.deadline, ship: w.ship())
                w.sheetReaction = SpeakerConfirmPresentation.sheetReaction(result)
                return ctx
            },
            defineStep("the phone retries the pending confirms") { ctx, _, _ in
                await SpeakerConfirmFlow.drainPending(
                    baseDir: w.dir,
                    ship: { _ in
                        w.drainShipCalls += 1
                        throw DoorError.unauthorized
                    },
                    onAuthExpired: { w.drainAuthExpired = true })
                return ctx
            },

            // ── Thens ─────────────────────────────────────────────────────────
            defineStep("the confirm shows an in-flight state before the computer has answered") { ctx, _, _ in
                guard w.observedInFlight else {
                    throw BrineStepError("tap did not flip the affordance to in-flight")
                }
                return ctx
            },
            defineStep("I see a confirmed state for that speaker") { ctx, _, _ in
                guard w.resolvedPhase == .confirmed else {
                    throw BrineStepError("expected .confirmed, got \(String(describing: w.resolvedPhase))")
                }
                return ctx
            },
            defineStep("the change is no longer pending on my phone") { ctx, _, _ in
                guard w.pending().isEmpty else {
                    throw BrineStepError("acknowledged confirm still queued: \(w.pending())")
                }
                return ctx
            },
            defineStep("the sheet dismisses itself") { ctx, _, _ in
                guard w.sheetReaction == .dismiss else {
                    throw BrineStepError("expected .dismiss, got \(String(describing: w.sheetReaction))")
                }
                return ctx
            },
            defineStep("I see an honest failure that says the change is saved on my phone") { ctx, _, _ in
                guard case .failed(let failure)? = w.resolvedPhase else {
                    throw BrineStepError("expected a failed phase, got \(String(describing: w.resolvedPhase))")
                }
                let copy = SpeakerConfirmPresentation.failureCopy(failure)
                guard copy.message.lowercased().contains("saved on your phone") else {
                    throw BrineStepError("copy must say the change is safe: \(copy.message)")
                }
                return ctx
            },
            defineStep("the change stays pending on my phone so it ships later") { ctx, _, _ in
                let pending = w.pending()
                guard pending.contains(where: { $0.captureId == w.captureId && $0.slot == w.slot }) else {
                    throw BrineStepError("failed confirm lost its durable intent: \(pending)")
                }
                return ctx
            },
            defineStep("I am offered a retry") { ctx, _, _ in
                guard case .failed(let failure)? = w.resolvedPhase else {
                    throw BrineStepError("no failure to retry")
                }
                guard SpeakerConfirmPresentation.failureCopy(failure).retryable else {
                    throw BrineStepError("this failure should offer a retry")
                }
                return ctx
            },
            defineStep("the confirm resolves to an honest unreachable failure") { ctx, _, _ in
                guard w.resolvedPhase == .failed(.unreachable) else {
                    throw BrineStepError("expected .failed(.unreachable), got \(String(describing: w.resolvedPhase))")
                }
                return ctx
            },
            defineStep("I see an honest failure, not a confirmed state") { ctx, _, _ in
                guard case .failed? = w.resolvedPhase else {
                    throw BrineStepError("expected a failure, got \(String(describing: w.resolvedPhase))")
                }
                return ctx
            },
            defineStep("the retry stops and requests re-authentication") { ctx, _, _ in
                guard w.drainAuthExpired else {
                    throw BrineStepError("the 401 must fire the re-auth seam")
                }
                guard w.drainShipCalls == 1 else {
                    throw BrineStepError("the 401 must stop the pass (ship calls: \(w.drainShipCalls))")
                }
                return ctx
            },
            defineStep("the pending confirms are kept for after I sign in again") { ctx, _, _ in
                guard w.pending().count == 2 else {
                    throw BrineStepError("pending confirms were lost: \(w.pending())")
                }
                return ctx
            },
        ]
    }
}
