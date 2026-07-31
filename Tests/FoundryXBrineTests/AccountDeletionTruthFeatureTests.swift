import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/account-deletion-tells-the-truth.feature.
///
/// Nick tapped "Delete your account everywhere" and got "Check your connection and try
/// again" with a working connection and a healthy gateway. The request never left the
/// phone: the call is signed with `remote.idToken`, a snapshot from the last session
/// resolve, and a nil snapshot threw before any HTTP call — then every cause rendered as
/// the same connection-blaming sentence.
final class AccountDeletionTruthFeatureTests: XCTestCase {
    func testAccountDeletionTruthFeature() async throws {
        try await BrineFeatureRunner.run(
            "account-deletion-tells-the-truth",
            registry: StepRegistry(DeletionTruthSteps.make(world: DeletionTruthWorld())))
    }
}

private final class DeletionTruthWorld: @unchecked Sendable {
    /// What the refreshing seam yields; nil models "cannot be refreshed".
    var refreshed: String? = "fresh-token"
    /// The stale snapshot the UI would otherwise sign with.
    var cachedSnapshot: String? = "stale-snapshot"
    /// What the server does with whatever bearer arrives.
    enum ServerBehaviour { case accepts, rejectsAuth, unreachable, noRoute }
    var server: ServerBehaviour = .accepts

    var presentedToken: String?
    var deletedOnServer = false
    var localErased = false
    var model: AccountDeletionModel!
    /// How many times the central router drove the app to signed-out.
    var signedOutCount = 0

    @MainActor
    func makeModel() {
        signedOutCount = 0
        AuthExpiryRouter.shared.identityChanged()
        let router = self
        AuthExpiryRouter.shared.onExpired = { router.signedOutCount += 1 }
        presentedToken = nil
        deletedOnServer = false
        localErased = false
        let box = self
        let service = LiveAccountDeletionService(
            eraseLocal: { box.localErased = true },
            deleteRemote: { _, idToken in
                // Mirrors the production wiring: refresh at request time, fall back to the
                // snapshot, and treat a missing token as an AUTH failure rather than a
                // transport one.
                let token = box.refreshed ?? idToken
                guard let token, !token.isEmpty else {
                    throw AccountDeletionError.signInExpired
                }
                box.presentedToken = token
                switch box.server {
                case .accepts:      box.deletedOnServer = true
                case .rejectsAuth:  throw AccountDeletionError.signInExpired
                case .unreachable:  throw AccountDeletionError.server
                case .noRoute:      throw AccountDeletionError.routeMissing
                }
            })
        model = AccountDeletionModel(service: service)
    }

    @MainActor func deleteEverywhere() async {
        await model.delete(scope: .everywhere, idToken: cachedSnapshot)
    }
}

private enum DeletionTruthSteps {
    static func make(world w: DeletionTruthWorld) -> [StepDefinition] {
        [
            defineStep("my cached sign-in token is stale") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.refreshed = "fresh-token"
                w.cachedSnapshot = "stale-snapshot"
                w.server = .accepts
                return ctx
            },
            defineStep("my sign-in can no longer be refreshed") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.refreshed = nil
                w.cachedSnapshot = nil          // the snapshot is nil too — Nick's case
                w.server = .accepts
                return ctx
            },
            defineStep("the server rejects my sign-in") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.refreshed = "expired-but-present"
                w.server = .rejectsAuth
                return ctx
            },
            defineStep("the server cannot be reached") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.refreshed = "fresh-token"
                w.server = .unreachable
                return ctx
            },
            defineStep("my sign-in is valid") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.refreshed = "fresh-token"
                w.server = .accepts
                return ctx
            },

            defineStep("I delete my account everywhere") { ctx, _, _ in
                await w.deleteEverywhere()
                return ctx
            },

            defineCheck("the app refreshes my token first") { _, _, _ in
                guard w.presentedToken != nil else {
                    throw BrineStepError("no token reached the server at all")
                }
            },
            defineCheck("the delete is signed with the refreshed token") { _, _, _ in
                guard w.presentedToken == "fresh-token" else {
                    throw BrineStepError("delete presented \(w.presentedToken ?? "nil") — "
                                         + "the stale snapshot, not a refreshed token")
                }
            },
            defineCheck("I am told my sign-in expired") { _, _, _ in
                let phase = await MainActor.run { w.model.phase }
                guard case .signInExpired = phase else {
                    throw BrineStepError("expected a sign-in-expired stop, got \(phase)")
                }
            },
            defineCheck("I am not told to check my connection") { _, _, _ in
                let phase = await MainActor.run { w.model.phase }
                if case .failed = phase {
                    throw BrineStepError("an auth failure rendered as a connection failure — "
                                         + "this sends the user to fix the one thing that works")
                }
            },
            defineCheck("nothing was deleted") { _, _, _ in
                guard !w.deletedOnServer, !w.localErased else {
                    throw BrineStepError("a failed delete still destroyed something")
                }
            },
            defineCheck("I am told to check my connection") { _, _, _ in
                let phase = await MainActor.run { w.model.phase }
                guard case .failed = phase else {
                    throw BrineStepError("a genuine network failure must still read as one, "
                                         + "got \(phase)")
                }
            },
            defineStep("the server is not serving the deletion route") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.refreshed = "fresh-token"
                w.server = .noRoute
                return ctx
            },
            defineCheck("I am told the server isn't offering deletion at this address") { _, _, _ in
                let phase = await MainActor.run { w.model.phase }
                guard case .routeMissing = phase else {
                    throw BrineStepError("expected a not-available stop, got \(phase)")
                }
            },
            defineCheck("the app signs me out so I can sign in again") { _, _, _ in
                guard w.signedOutCount >= 1 else {
                    throw BrineStepError("a rejected sign-in left the app looking signed in — "
                                         + "the one action that fixes it was never offered")
                }
            },
            defineStep("several requests are rejected at once") { ctx, _, _ in
                for _ in 0..<3 { await w.deleteEverywhere() }
                return ctx
            },
            defineCheck("the app signs me out exactly once") { _, _, _ in
                guard w.signedOutCount == 1 else {
                    throw BrineStepError("signed out \(w.signedOutCount) times — a burst of "
                                         + "in-flight 401s must collapse to one sign-out")
                }
            },
            defineCheck("the account is deleted on the server") { _, _, _ in
                guard w.deletedOnServer else { throw BrineStepError("server delete never happened") }
            },
            defineCheck("this account's local data is erased") { _, _, _ in
                guard w.localErased else { throw BrineStepError("local data survived the delete") }
            },
        ]
    }
}
