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
        var service: ScriptedDeletionService?
        var model: AccountDeletionModel?

        func reset() {
            status = .signedOut
            caption = nil
            recovered = false
            signedIn = false
            eraseCalled = 0
            eraseShouldFail = false
            service = nil
            model = nil
            DeletionRecorder.shared.clear()
        }

        /// The real state Nick was in: the tenant is gone server-side and the
        /// local erase refused once, leaving the model in `.incomplete`. The
        /// counters are zeroed AFTER that first attempt, so what the retry does
        /// is measured on its own.
        func installHalfFinishedDeletion() async {
            let service = ScriptedDeletionService()
            service.localFailures = 1
            let model = AccountDeletionModel(service: service)
            self.service = service
            self.model = model
            await model.delete(scope: .everywhere, idToken: "token")
            service.remoteCalls = 0
            service.localErases = 0
        }

        func installRouteMissingDeletion() {
            let service = ScriptedDeletionService()
            service.remoteAnswer = .routeMissing
            self.service = service
            self.model = AccountDeletionModel(service: service)
        }
    }

    /// A deletion seam that counts each leg separately, so "the retry re-ran the
    /// server call" is a measurement rather than an inference.
    final class ScriptedDeletionService: AccountDeletionService, @unchecked Sendable {
        enum RemoteAnswer { case ok, routeMissing }

        private let lock = NSLock()
        private var _remoteAnswer: RemoteAnswer = .ok
        private var _remoteCalls = 0
        private var _localErases = 0
        private var _localFailures = 0

        var remoteAnswer: RemoteAnswer {
            get { lock.withLock { _remoteAnswer } }
            set { lock.withLock { _remoteAnswer = newValue } }
        }
        var remoteCalls: Int {
            get { lock.withLock { _remoteCalls } }
            set { lock.withLock { _remoteCalls = newValue } }
        }
        var localErases: Int {
            get { lock.withLock { _localErases } }
            set { lock.withLock { _localErases = newValue } }
        }
        /// How many of the next local erases refuse before one succeeds.
        var localFailures: Int {
            get { lock.withLock { _localFailures } }
            set { lock.withLock { _localFailures = newValue } }
        }

        func eraseThisPhone() async throws {
            try lock.withLock {
                _localErases += 1
                if _localFailures > 0 {
                    _localFailures -= 1
                    throw AccountDeletionError.cleanupFailed(
                        "localRoot the erase was interrupted")
                }
            }
        }

        func deleteHostedVault(idToken: String?) async throws {
            try recordRemote()
        }

        @discardableResult
        func deleteAccountEverywhere(
            choice: DeletionOutcomeChoice, idToken: String?
        ) async throws -> DeletionOutcome {
            try recordRemote()
            try await eraseThisPhone()
            return DeletionOutcome(status: "deleted")
        }

        private func recordRemote() throws {
            try lock.withLock {
                _remoteCalls += 1
                if _remoteAnswer == .routeMissing {
                    throw AccountDeletionError.routeMissing
                }
            }
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
                    status: await MainActor.run { w.status }, underlying: nil, destination: .computer)
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

            // ── retrying an erase whose server side is already gone ──────────
            defineStep("my account is already deleted on the server and the erase stopped half-way") { ctx, _, _ in
                await MainActor.run { w.reset() }
                await w.installHalfFinishedDeletion()
                return ctx
            },
            defineStep("the server answers that there is no such account") { ctx, _, _ in
                await MainActor.run { w.service?.remoteAnswer = .routeMissing }
                return ctx
            },
            defineStep("I retry the deletion") { ctx, _, _ in
                let model = await MainActor.run { w.model }
                guard let model else {
                    throw BrineStepError("no half-finished deletion was prepared")
                }
                // Exactly what the screen does: the phase decides whether the
                // remote leg is still owed anything.
                let localOnly = await MainActor.run { model.awaitsLocalRetryOnly }
                if localOnly {
                    await model.retryLocalErase(scope: .everywhere)
                } else {
                    await model.delete(scope: .everywhere, idToken: "token")
                }
                return ctx
            },
            defineCheck("this iPhone is erased") { _, _, _ in
                let calls = await MainActor.run { w.service?.localErases ?? 0 }
                guard calls == 1 else {
                    throw BrineStepError(
                        "the local erase — the ONLY thing still owed — ran \(calls) times")
                }
            },
            defineCheck("the server is not asked to delete the account again") { _, _, _ in
                let calls = await MainActor.run { w.service?.remoteCalls ?? -1 }
                guard calls == 0 else {
                    throw BrineStepError(
                        "the retry called a server that no longer has this account (\(calls) times)")
                }
            },
            defineCheck("the deletion finishes") { _, _, _ in
                let phase = await MainActor.run { w.model?.phase }
                guard case .done = phase else {
                    throw BrineStepError(
                        "the retry did not finish the deletion: \(String(describing: phase))")
                }
            },
            defineStep("the deletion never reached the server because the route is missing") { ctx, _, _ in
                await MainActor.run {
                    w.reset()
                    w.installRouteMissingDeletion()
                }
                let model = await MainActor.run { w.model }
                guard let model else {
                    throw BrineStepError("no deletion was prepared")
                }
                await model.delete(scope: .everywhere, idToken: "token")
                return ctx
            },
            defineCheck("I am not offered a way to try again") { _, _, _ in
                let failure = await MainActor.run {
                    w.model?.progress.presentation.failure
                }
                guard let failure else {
                    throw BrineStepError("no failure was reported at all")
                }
                guard !failure.isRetryable else {
                    throw BrineStepError(
                        "offered a retry that provably cannot succeed: \(failure.message)")
                }
            },
            defineCheck("I am told to erase this iPhone's data instead") { _, _, _ in
                let failure = await MainActor.run {
                    w.model?.progress.presentation.failure
                }
                guard let message = failure?.message,
                      message.lowercased().contains("local data") else {
                    throw BrineStepError(
                        "the only thing that still works was not named: "
                        + String(describing: failure?.message))
                }
            },
        ]))
    }
}
