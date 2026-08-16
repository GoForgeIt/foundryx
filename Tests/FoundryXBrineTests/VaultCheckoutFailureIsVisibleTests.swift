// A checkout attempt that cannot even be REGISTERED must say so.
//
// What shipped: `continueToCheckout` caught every error from `createCheckoutAttempt` and
// set `.plans(selected:)` — the screen the owner was already looking at. Tapping a price
// returned them to the price list with no message, no reason, and nothing to act on. It is
// indistinguishable from a dead button, and it was reported as exactly that on 2026-08-16:
// "I tried to go through the vault setup and it doesn't link out after choosing price".
//
// The most common cause never reaches the network. `VaultSignupClient` deliberately refuses
// to send a headerless request that production maps to 401, so an empty or expired id_token
// throws `credentialUnavailable` BEFORE the POST — which is why the signup service logged
// no `/signup/checkout-attempt` at all for a failed attempt. A silent bounce plus a silent
// server makes the failure invisible from both ends at once.
//
// These tests pin the two halves that make it visible: the state is TERMINAL and escapable
// rather than a return to plans, and the reason distinguishes "sign in again" from failures
// where signing in again would loop.

import XCTest
@testable import FoundryXKit

@MainActor
final class VaultCheckoutFailureIsVisibleTests: XCTestCase {

    /// THE ONE THAT MATTERS. Under the shipped code this lands on `.plans` and the assertion
    /// fails — which is the whole point: `.plans` is not a failure state, it is the screen
    /// the owner just tapped on.
    func testAMissingCredentialIsShownAsAStopWithARemedy() async {
        let model = makeModel(failing: .credentialUnavailable)
        await model.continueToCheckout(plan: .starter)

        let state = model.state
        guard case .failed(let reason) = state else {
            return XCTFail(
                "a checkout that could not be registered must land on a terminal, escapable "
                + "state; got \(state). `.plans` is the screen the owner just tapped, so it "
                + "reads as a dead button.")
        }
        XCTAssertEqual(
            reason, .signInExpired,
            "an absent credential is fixed by signing in again — the remedy has to be the "
            + "one the copy offers")
    }

    /// An expired credential and a rejected-but-not-expired one need DIFFERENT remedies.
    /// Collapsing them sends the owner around the sign-in carousel forever on the second.
    func testARejectionThatSigningInCannotFixIsNotReportedAsAnExpiredSignIn() async {
        let model = makeModel(failing: .requestRejected)
        await model.continueToCheckout(plan: .starter)

        let state = model.state
        guard case .failed(let reason) = state else {
            return XCTFail("expected a terminal state, got \(state)")
        }
        XCTAssertEqual(reason, .statusCheckRejected)
        XCTAssertNotEqual(
            reason, .signInExpired,
            "signing in again would mint an equivalent token and loop")
    }

    /// A server-supplied reason must survive to the screen rather than being flattened.
    func testAServerReasonIsCarriedThroughVerbatim() async {
        let model = makeModel(failing: .provisioning("card declined"))
        await model.continueToCheckout(plan: .starter)

        let state = model.state
        guard case .failed(.server(let text)) = state else {
            return XCTFail("expected a server reason, got \(state)")
        }
        XCTAssertEqual(text, "card declined")
    }

    /// The mapping is a pure function; pin it directly so a future case cannot be added
    /// without a deliberate decision about its remedy.
    func testEveryKnownSignupErrorMapsToARemedy() {
        XCTAssertEqual(VaultFunnelModel.checkoutAttemptFailure(from: VaultSignupError.credentialUnavailable), .signInExpired)
        XCTAssertEqual(VaultFunnelModel.checkoutAttemptFailure(from: VaultSignupError.credentialExpired), .signInExpired)
        XCTAssertEqual(VaultFunnelModel.checkoutAttemptFailure(from: VaultSignupError.unauthorized), .signInExpired)
        XCTAssertEqual(VaultFunnelModel.checkoutAttemptFailure(from: VaultSignupError.requestRejected), .statusCheckRejected)
        XCTAssertEqual(VaultFunnelModel.checkoutAttemptFailure(from: VaultSignupError.server), .provisioningFailed)
        XCTAssertEqual(VaultFunnelModel.checkoutAttemptFailure(from: VaultSignupError.malformedResponse), .provisioningFailed)
        // A non-signup error must not be silently attributed to sign-in.
        struct Other: Error {}
        XCTAssertEqual(VaultFunnelModel.checkoutAttemptFailure(from: Other()), .provisioningFailed)
    }

    // MARK: - world

    private func makeModel(failing error: VaultSignupError) -> VaultFunnelModel {
        let suite = "leg9.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return VaultFunnelModel(
            service: FailingSignupService(error: error),
            browser: FailureVisibleNoopBrowser(),
            cellStore: CellStore(defaults: defaults, keychainService: suite),
            attempts: VaultCheckoutAttemptStore(defaults: defaults),
            // No credential at all — the condition that makes the client refuse to dial.
            idToken: { nil },
            // A purchase-eligible storefront, so the run reaches the checkout attempt.
            // Without this the storefront gate returns EARLY and silently, leaving `.idle` —
            // a second dead end of the same class, and a live candidate for the reported
            // symptom whenever StoreKit cannot read a storefront on device.
            storefrontCountryCode: { "USA" })
    }
}

private struct FailingSignupService: VaultSignupService, Sendable {
    let error: VaultSignupError
    func createCheckoutAttempt(plan: VaultPlan, idToken: String?) async throws -> VaultCheckoutAttempt {
        throw error
    }
    func reconcile(attemptId: String, idToken: String?) async throws -> VaultProvisionStatus { .pending }
    func exchangeReturn(ticket: String, idToken: String?) async throws -> VaultProvisionStatus { .pending }
}

private struct FailureVisibleNoopBrowser: VaultCheckoutBrowser, Sendable {
    func open(_ url: URL) async throws -> URL? { nil }
}
