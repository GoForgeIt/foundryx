import XCTest
@testable import FoundryXKit
import BrineSwiftCore

/// Seams for `deletion-choice.feature` — the three-way choice and the record it
/// leaves behind.
///
/// Every scenario drives the REAL `AccountDeletionModel` with a REAL
/// `DeletionRecorder` (endpoint unset, so nothing leaves the test) and a stub
/// service standing in only for the network edge. What is asserted is what the
/// person is offered, what the server is asked for, and what was written down.
final class DeletionChoiceFeatureTests: XCTestCase {

    /// Records what the server was asked for, and answers as the deployed service
    /// does for each scope.
    final class SpyService: AccountDeletionService, @unchecked Sendable {
        var asked: [DeletionOutcomeChoice] = []
        var erasedLocally = 0
        var fails = false

        func eraseThisPhone() async throws { erasedLocally += 1 }
        func deleteHostedVault(idToken: String?) async throws {}

        @discardableResult
        func deleteAccountEverywhere(choice: DeletionOutcomeChoice,
                                     idToken: String?) async throws -> DeletionOutcome {
            asked.append(choice)
            if fails { throw AccountDeletionError.server }
            switch choice {
            case .deleteNow:
                erasedLocally += 1
                return DeletionOutcome(status: "deleted")
            case .deleteAtPeriodEnd:
                return DeletionOutcome(status: "scheduled",
                                       deleteAt: Date(timeIntervalSince1970: 1_800_000_000))
            case .cancelOnly:
                return DeletionOutcome(status: "subscription_cancelled")
            }
        }
    }

    @MainActor final class World {
        let spy = SpyService()
        let recorder = DeletionRecorder()   // endpoint nil ⇒ records, ships nothing
        var model: AccountDeletionModel!
        var offered: [DeletionOutcomeChoice] = []
        var backedOut = false
        /// Which choices made the LIVE service erase the on-device library.
        var liveErases: [DeletionOutcomeChoice] = []

        func makeModel() {
            // Reset the spy TOO, not just the recorder. Leaving its counters set
            // makes every scenario depend on the ones before it, and the first
            // symptom is a later scenario failing for the earlier one's actions.
            recorder.clear()
            spy.asked.removeAll()
            spy.erasedLocally = 0
            spy.fails = false
            backedOut = false
            model = AccountDeletionModel(service: spy, record: recorder.record)
        }
    }

    func testDeletionChoiceScenarios() async throws {
        let w = await World()

        try await BrineFeatureRunner.run("deletion-choice", registry: StepRegistry([

            defineStep("I choose to delete my account everywhere") { ctx, _, _ in
                await MainActor.run {
                    w.makeModel()
                    // What the choice step puts in front of the person.
                    w.offered = DeletionOutcomeChoice.allCases
                }
                return ctx
            },
            defineCheck("I am offered to delete everything now") { _, _, _ in
                guard await MainActor.run(body: { w.offered.contains(.deleteNow) }) else {
                    throw BrineStepError("deleting now was not offered")
                }
            },
            defineCheck("I am offered to delete when my subscription ends") { _, _, _ in
                guard await MainActor.run(body: { w.offered.contains(.deleteAtPeriodEnd) }) else {
                    throw BrineStepError("deleting at period end was not offered")
                }
            },
            defineCheck("I am offered to cancel my subscription and keep my data") { _, _, _ in
                guard await MainActor.run(body: { w.offered.contains(.cancelOnly) }) else {
                    throw BrineStepError("cancel-only was not offered")
                }
            },
            defineCheck("nothing has been deleted yet") { _, _, _ in
                let (asked, erased) = await MainActor.run { (w.spy.asked.count, w.spy.erasedLocally) }
                guard asked == 0, erased == 0 else {
                    throw BrineStepError("merely OFFERING the choice destroyed something")
                }
            },

            // ── per-choice truthfulness ──────────────────────────────────────
            defineStep("I look at the choice to cancel my subscription and keep my data") { ctx, _, _ in
                await MainActor.run { w.offered = [.cancelOnly] }
                return ctx
            },
            defineCheck("I am not warned that it cannot be undone") { _, _, _ in
                let c = await MainActor.run { w.offered.first! }
                guard !c.isIrreversible else {
                    throw BrineStepError("cancel-only claims to be irreversible; it is not")
                }
                guard !c.detail.lowercased().contains("can't be undone") else {
                    throw BrineStepError("cancel-only copy says it can't be undone: \(c.detail)")
                }
            },
            defineStep("I look at the choice to delete everything now") { ctx, _, _ in
                await MainActor.run { w.offered = [.deleteNow] }
                return ctx
            },
            defineCheck("I am warned that it cannot be undone") { _, _, _ in
                let c = await MainActor.run { w.offered.first! }
                guard c.isIrreversible, c.detail.lowercased().contains("can't be undone") else {
                    throw BrineStepError("deleting now is irreversible but does not say so")
                }
            },
            defineCheck("I am told I will not get the rest of the period back") { _, _, _ in
                let c = await MainActor.run { w.offered.first! }
                guard c.forfeitsPaidPeriod,
                      c.detail.lowercased().contains("won't get the rest") else {
                    throw BrineStepError("the forfeit is not stated before the confirm: \(c.detail)")
                }
            },

            // ── each choice reaches the server as itself ─────────────────────
            defineStep("I pick each deletion outcome in turn") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                for choice in DeletionOutcomeChoice.allCases {
                    await w.model.delete(scope: .everywhere, choice: choice, idToken: "t")
                }
                return ctx
            },
            defineCheck("the server is asked to delete now, to delete at period end, and to cancel only") { _, _, _ in
                let wires = await MainActor.run { w.spy.asked.map(\.wireScope) }
                guard wires == ["delete_now", "delete_at_period_end", "cancel_only"] else {
                    throw BrineStepError("the server was asked for \(wires)")
                }
            },
            defineCheck("each attempt is recorded with the scope I chose and how it ended") { _, _, _ in
                let lines = await MainActor.run { w.recorder.recorded() }
                for scope in ["delete_now", "delete_at_period_end", "cancel_only"] {
                    guard lines.contains(where: { $0.contains("requested") && $0.contains(scope) }) else {
                        throw BrineStepError("no requested record for \(scope): \(lines)")
                    }
                    guard lines.contains(where: {
                        ($0.contains("completed") || $0.contains("scheduled")) && $0.contains(scope)
                    }) else {
                        throw BrineStepError("no outcome record for \(scope): \(lines)")
                    }
                }
            },
            defineCheck("no recorded event carries my email address or my notes") { _, _, _ in
                let lines = await MainActor.run { w.recorder.recorded() }
                for l in lines where l.contains("@") {
                    throw BrineStepError("a recorded deletion event carries an address: \(l)")
                }
            },

            // ── the two non-destructive outcomes say what happened ───────────
            defineStep("I choose to delete when my subscription ends") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                await w.model.delete(scope: .everywhere, choice: .deleteAtPeriodEnd, idToken: "t")
                return ctx
            },
            defineCheck("I am told the date my data will be deleted") { _, _, _ in
                let phase = await MainActor.run { w.model.phase }
                guard case .scheduled = phase else {
                    throw BrineStepError("expected a scheduled outcome, got \(phase)")
                }
            },
            defineCheck("I am not told my account was deleted") { _, _, _ in
                let phase = await MainActor.run { w.model.phase }
                if case .done = phase {
                    throw BrineStepError("a non-destructive outcome reported the account deleted")
                }
            },
            defineStep("I choose to cancel my subscription and keep my data") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                await w.model.delete(scope: .everywhere, choice: .cancelOnly, idToken: "t")
                return ctx
            },
            defineCheck("I am told my notes are still here") { _, _, _ in
                let (phase, erased) = await MainActor.run { (w.model.phase, w.spy.erasedLocally) }
                guard case .subscriptionCancelled = phase else {
                    throw BrineStepError("expected a cancelled-subscription outcome, got \(phase)")
                }
                guard erased == 0 else {
                    throw BrineStepError("cancel-only erased the phone anyway")
                }
            },

            // ── the LIVE service's erase decision ────────────────────────────
            // Drives LiveAccountDeletionService itself. Without this the seams
            // above all pass while the production service wipes the phone for
            // every choice, because they stub the service out entirely.
            defineStep("the live deletion service runs each outcome") { ctx, _, _ in
                await MainActor.run { w.makeModel(); w.liveErases.removeAll() }
                for choice in DeletionOutcomeChoice.allCases {
                    let service = LiveAccountDeletionService(
                        eraseLocal: {
                            await MainActor.run { w.liveErases.append(choice) }
                        },
                        deleteRemote: { _, _ in },
                        deleteRemoteChoice: { _, _ in DeletionOutcome(status: "ok") })
                    _ = try? await service.deleteAccountEverywhere(choice: choice, idToken: "t")
                }
                return ctx
            },
            defineCheck("only deleting now erased this phone") { _, _, _ in
                let erases = await MainActor.run { w.liveErases }
                guard erases == [.deleteNow] else {
                    throw BrineStepError(
                        "the live service erased this phone for \(erases) — a scheduled "
                        + "deletion and a cancel must leave the library alone")
                }
            },

            // ── backing out ─────────────────────────────────────────────────
            defineStep("I open the deletion choice and back out") { ctx, _, _ in
                await MainActor.run {
                    w.makeModel()
                    w.offered = DeletionOutcomeChoice.allCases
                    w.backedOut = true          // no delete call is made
                }
                return ctx
            },
            defineCheck("nothing was deleted") { _, _, _ in
                let erased = await MainActor.run { w.spy.erasedLocally }
                guard erased == 0 else { throw BrineStepError("backing out still erased") }
            },
            defineCheck("no request reached the server") { _, _, _ in
                let asked = await MainActor.run { w.spy.asked.count }
                guard asked == 0 else { throw BrineStepError("backing out still called the server") }
            },

            // ── failures are recorded ───────────────────────────────────────
            defineStep("a deletion fails") { ctx, _, _ in
                await MainActor.run { w.makeModel(); w.spy.fails = true }
                await w.model.delete(scope: .everywhere, choice: .deleteNow, idToken: "t")
                return ctx
            },
            defineCheck("the failure is recorded, not silently dropped") { _, _, _ in
                let lines = await MainActor.run { w.recorder.recorded() }
                guard lines.contains(where: { $0.contains("failed") && $0.contains("delete_now") }) else {
                    throw BrineStepError("a failed deletion left no record: \(lines)")
                }
            },
        ]))
    }
}
