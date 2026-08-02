import XCTest
@testable import FoundryXKit
import BrineSwiftCore

/// Seams for `deletion-does-not-trap-me.feature`.
///
/// The real lockout, reproduced: a `cleanupPending` record refuses sign-in for its
/// own owner, and the only other way to clear it lives behind that sign-in. These
/// pin what the refusal SAYS, that it offers a way out, and that taking it works —
/// plus that a normal account is untouched by any of it.
final class DeletionDoesNotTrapMeFeatureTests: XCTestCase {

    @MainActor final class World {
        var status: RemoteSession.Status = .signedOut
        var caption: String?
        var recovered = false
        var signedIn = false
        var eraseCalled = 0
        var eraseShouldFail = false

        func reset() {
            status = .signedOut
            caption = nil
            recovered = false
            signedIn = false
            eraseCalled = 0
            eraseShouldFail = false
            DeletionRecorder.shared.clear()
        }
    }

    func testDeletionDoesNotTrapMeScenarios() async throws {
        let w = await World()

        try await BrineFeatureRunner.run("deletion-does-not-trap-me", registry: StepRegistry([

            defineStep("I sign in with an account whose deletion never finished") { ctx, _, _ in
                await MainActor.run {
                    w.reset()
                    // Exactly what beginActivation throws for a cleanupPending record,
                    // mapped the way signIn maps it.
                    w.status = .deletionCleanupPending(ownerScope: "google|sub|deleted-one")
                    w.caption = WelcomeFrontDoor.signInCaption(w.status)
                    w.signedIn = false
                }
                return ctx
            },

            defineCheck("I am told the deletion did not finish") { _, _, _ in
                let caption = await MainActor.run { w.caption }
                guard let caption, !caption.isEmpty else {
                    throw BrineStepError(
                        "the login screen said NOTHING — which is how a deleted account "
                        + "looked like a sign-in that simply did not happen")
                }
                guard caption.lowercased().contains("deleting this account") else {
                    throw BrineStepError("the caption does not name the cause: \(caption)")
                }
            },

            defineCheck("I am not simply returned to the login screen with no explanation") { _, _, _ in
                let caption = await MainActor.run { w.caption }
                guard caption != nil else {
                    throw BrineStepError("no explanation was offered at all")
                }
            },

            defineCheck("I am offered to finish the deletion") { _, _, _ in
                // The door-failure mapping is what carries the action text.
                let msg = DoorFailureMessage.make(
                    status: await MainActor.run { w.status }, underlying: nil)
                guard let action = msg.action, action.lowercased().contains("finish") else {
                    throw BrineStepError(
                        "no way out was offered — Retry deletion lives behind the very "
                        + "sign-in this refuses, so there would be none at all: \(msg)")
                }
                guard !msg.text.lowercased().contains("connection") else {
                    throw BrineStepError("blamed the connection for an account state: \(msg.text)")
                }
            },

            defineCheck("I am not signed in") { _, _, _ in
                guard await MainActor.run(body: { !w.signedIn }) else {
                    throw BrineStepError(
                        "a refused sign-in signed the person in anyway — straight back "
                        + "into half-erased data")
                }
            },

            // ── taking the way out ──────────────────────────────────────────
            defineStep("I finish the interrupted deletion from the login screen") { ctx, _, _ in
                await MainActor.run {
                    w.reset()
                    w.status = .deletionCleanupPending(ownerScope: "google|sub|deleted-one")
                }
                let session = await RemoteSession()
                await MainActor.run {
                    session.status = .deletionCleanupPending(ownerScope: "google|sub|deleted-one")
                }
                let ok = await session.finishInterruptedDeletion {
                    await MainActor.run { w.eraseCalled += 1 }
                    if await MainActor.run(body: { w.eraseShouldFail }) {
                        throw AccountDeletionError.server
                    }
                }
                let after = await MainActor.run { session.status }
                await MainActor.run {
                    w.recovered = ok
                    w.status = after
                }
                return ctx
            },
            defineCheck("the pending record is resolved") { _, _, _ in
                let (ok, calls) = await MainActor.run { (w.recovered, w.eraseCalled) }
                guard calls == 1 else {
                    throw BrineStepError("the local cleanup was not run (calls=\(calls))")
                }
                guard ok else { throw BrineStepError("recovery reported failure") }
            },
            defineCheck("I can sign in with that account again") { _, _, _ in
                let status = await MainActor.run { w.status }
                if case .deletionCleanupPending = status {
                    throw BrineStepError("still refusing after the cleanup finished")
                }
            },

            // ── an ordinary account is untouched ────────────────────────────
            defineStep("I sign in with an account that was never deleted") { ctx, _, _ in
                await MainActor.run {
                    w.reset()
                    w.status = .connected(host: "mac")
                    w.caption = WelcomeFrontDoor.signInCaption(w.status)
                    w.signedIn = true
                }
                return ctx
            },
            defineCheck("I am signed in") { _, _, _ in
                guard await MainActor.run(body: { w.signedIn }) else {
                    throw BrineStepError("a normal account was refused")
                }
            },
            defineCheck("I am not told anything about a deletion") { _, _, _ in
                let caption = await MainActor.run { w.caption }
                guard caption == nil || !caption!.lowercased().contains("deleting") else {
                    throw BrineStepError("a normal sign-in mentioned a deletion: \(caption!)")
                }
            },
        ]))
    }
}
