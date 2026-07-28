import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/vault-checkout-never-traps-me.feature. Drives the REAL
/// funnel (`VaultFunnelModel`) with a stub signup service, the REAL status mapping
/// (`VaultSignupClient.status(from:)`), and the REAL durable attempt store over an
/// isolated UserDefaults suite.
///
/// This exists because a paying owner sat on "Checking your payment…" for five hours with
/// no exit (2026-07-28): the payment succeeded, provisioning aborted server-side, and
/// every reconcile his phone made returned 401 because the funnel signed with a cached,
/// never-refreshed id_token. All three were invisible.
final class VaultCheckoutNeverTrapsFeatureTests: XCTestCase {
    func testVaultCheckoutNeverTrapsFeature() async throws {
        try await BrineFeatureRunner.run(
            "vault-checkout-never-traps-me",
            registry: StepRegistry(VaultTrapSteps.make(world: try VaultTrapWorld())))
    }
}

/// A signup service whose reconcile answer (or thrown error) each scenario sets.
private final class TrapStubService: VaultSignupService, @unchecked Sendable {
    private let lock = NSLock()
    private var _next: Result<VaultProvisionStatus, Error> = .success(.pending)
    /// The bearer the funnel actually presented on the last reconcile.
    private var _seenToken: String?

    var next: Result<VaultProvisionStatus, Error> {
        get { lock.lock(); defer { lock.unlock() }; return _next }
        set { lock.lock(); _next = newValue; lock.unlock() }
    }
    var seenToken: String? { lock.lock(); defer { lock.unlock() }; return _seenToken }

    func createCheckoutAttempt(plan: VaultPlan, idToken: String?) async throws -> VaultCheckoutAttempt {
        VaultCheckoutAttempt(id: "attempt-1", checkoutURL: nil)
    }
    func reconcile(attemptId: String, idToken: String?) async throws -> VaultProvisionStatus {
        // `NSLock.lock()` is unavailable from an async context; hop the mutation through
        // a nonisolated sync helper so the critical section never spans a suspension.
        record(idToken)
        return try next.get()
    }

    private func record(_ token: String?) {
        lock.lock(); _seenToken = token; lock.unlock()
    }
    func exchangeReturn(ticket: String, idToken: String?) async throws -> VaultProvisionStatus {
        try next.get()
    }
}

private final class TrapNoopBrowser: VaultCheckoutBrowser, @unchecked Sendable {
    func open(_ url: URL) async throws -> URL? { nil }
}

private final class VaultTrapWorld: @unchecked Sendable {
    /// A REAL account scope + keychain service. `CellStore.pair` refuses without a scoped
    /// preference root, so the happy path cannot go live without one.
    let fixture: PairingTestFixture
    let defaults: UserDefaults
    let service = TrapStubService()
    var model: VaultFunnelModel!
    var attempts: VaultCheckoutAttemptStore!
    /// The token the refreshing seam hands back; nil models "cannot be refreshed".
    var refreshed: String? = "fresh-token"
    /// How many times the refreshing seam was consulted.
    var refreshCalls = 0

    init() throws {
        fixture = try PairingTestFixture()
        defaults = fixture.defaults
    }

    @MainActor
    func makeModel() {
        attempts = VaultCheckoutAttemptStore(defaults: defaults)
        let box = self
        model = VaultFunnelModel(
            service: service,
            browser: TrapNoopBrowser(),
            cellStore: CellStore(defaults: defaults, keychainService: fixture.cellService),
            attempts: attempts,
            // The CACHED token is deliberately stale — the funnel must not sign with it
            // when a refreshing seam is available.
            idToken: { "stale-cached-token" },
            refreshingIdToken: { box.refreshCalls += 1; return box.refreshed })
    }

    /// A durable attempt, as `continueToCheckout` would leave behind.
    func seedAttempt() { attempts.save(attemptId: "attempt-1", plan: .pro) }

    var hasAttempt: Bool { attempts.load() != nil }
}

private enum VaultTrapSteps {
    @MainActor private static func reconcile(_ w: VaultTrapWorld) async {
        await w.model.reconcileOnForeground(generation: CaptureAccountScope.identityGeneration)
    }

    static func make(world w: VaultTrapWorld) -> [StepDefinition] {
        [
            // ── token freshness
            defineStep("my sign-in token expired an hour ago") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.refreshed = "fresh-token"
                w.seedAttempt()
                w.service.next = .success(.pending)
                return ctx
            },
            defineStep("the app checks on my payment") { ctx, _, _ in
                await MainActor.run { if w.model == nil { w.makeModel() } }
                await reconcile(w)
                return ctx
            },
            defineCheck("it refreshes my token first") { _, _, _ in
                guard w.refreshCalls > 0 else {
                    throw BrineStepError("the funnel never asked for a refreshed token — it "
                                         + "signed with the cached one, which is how every "
                                         + "reconcile came back 401")
                }
            },
            defineCheck("the check is signed with the refreshed token") { _, _, _ in
                guard w.service.seenToken == "fresh-token" else {
                    throw BrineStepError("reconcile presented \(w.service.seenToken ?? "nil"), "
                                         + "not the refreshed token")
                }
            },

            // ── unrefreshable sign-in
            defineStep("my sign-in can no longer be refreshed") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.refreshed = nil                       // refresh fails
                w.seedAttempt()
                w.service.next = .failure(VaultSignupError.unauthorized)
                return ctx
            },
            defineCheck("I am told my sign-in expired") { _, _, _ in
                let state = await MainActor.run { w.model.state }
                guard case .failed(let reason) = state, reason == .signInExpired else {
                    throw BrineStepError("expected a sign-in-expired stop, got \(state)")
                }
            },
            defineCheck("I am offered a way to sign in again") { _, _, _ in
                let state = await MainActor.run { w.model.state }
                guard case .failed(let reason) = state, reason.needsSignIn else {
                    throw BrineStepError("no sign-in remedy offered: \(state)")
                }
            },
            defineCheck("my checkout is still remembered") { _, _, _ in
                // An expired sign-in must NOT discard a possibly-paid checkout.
                guard w.hasAttempt else {
                    throw BrineStepError("an expired sign-in threw away the checkout attempt")
                }
            },

            // ── network blip stays quiet
            defineStep("my payment is still being confirmed") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.seedAttempt()
                w.service.next = .success(.pending)
                await reconcile(w)                       // land in checkingPayment
                return ctx
            },
            defineStep("the check cannot reach the server") { ctx, _, _ in
                w.service.next = .failure(VaultSignupError.server)
                await reconcile(w)
                return ctx
            },
            defineCheck("I am still waiting on my payment") { _, _, _ in
                let state = await MainActor.run { w.model.state }
                guard case .checkingPayment = state else {
                    throw BrineStepError("a network blip should keep waiting, got \(state)")
                }
            },
            defineCheck("nothing alarming is shown") { _, _, _ in
                let state = await MainActor.run { w.model.state }
                if case .failed = state {
                    throw BrineStepError("a passing network blip was rendered as a failure")
                }
            },

            // ── terminal server states
            defineStep("provisioning my Vault failed") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.seedAttempt()
                w.service.next = .success(.failed(.provisioningFailed))
                return ctx
            },
            defineCheck("I am told setting up my Vault did not finish") { _, _, _ in
                let state = await MainActor.run { w.model.state }
                guard case .failed(let reason) = state, reason == .provisioningFailed else {
                    throw BrineStepError("expected a provisioning-failed stop, got \(state)")
                }
            },
            defineCheck("I am offered a way to try again") { _, _, _ in
                let state = await MainActor.run { w.model.state }
                guard case .failed(let reason) = state, reason.isRetryable else {
                    throw BrineStepError("no retry offered: \(state)")
                }
            },
            defineCheck("I am not left watching a spinner") { _, _, _ in
                let state = await MainActor.run { w.model.state }
                switch state {
                case .checkingPayment, .opening, .settingUp:
                    throw BrineStepError("still spinning on \(state) — this is the trap")
                default: break
                }
            },

            defineStep("my Vault is suspended") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.seedAttempt()
                w.service.next = .success(.failed(.suspended))
                return ctx
            },
            defineStep("the server reports a status this app has never heard of") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.seedAttempt()
                // Through the REAL mapping, so an unrecognised status cannot silently
                // become progress again.
                let mapped = try VaultSignupClient.status(from: ["status": "flibbertigibbet"])
                w.service.next = .success(mapped)
                return ctx
            },

            // ── a failure does not haunt the next launch
            defineStep("I reopen the app") { ctx, _, _ in
                await MainActor.run { w.model.dismiss() }   // as leaving the surface does
                await reconcile(w)                          // the foreground reconcile
                return ctx
            },
            defineCheck("I am not put back into checking my payment") { _, _, _ in
                let state = await MainActor.run { w.model.state }
                if case .checkingPayment = state {
                    throw BrineStepError("reopening put the user back into the spinner — the "
                                         + "exact five-hour trap")
                }
            },

            // ── an explicit way out
            defineStep("I have been waiting on my payment for a long time") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.seedAttempt()
                w.service.next = .success(.pending)
                await reconcile(w)
                return ctx
            },
            defineCheck("I am offered a way to stop waiting") { _, _, _ in
                let state = await MainActor.run { w.model.state }
                guard case .checkingPayment = state else {
                    throw BrineStepError("not in the waiting state: \(state)")
                }
                // The affordance is `abandonCheckout()`; that it is REACHABLE from the
                // waiting screen is proved by the UI proof, not here.
            },
            defineStep("I stop waiting") { ctx, _, _ in
                await MainActor.run { w.model.abandonCheckout() }
                guard !w.hasAttempt else {
                    throw BrineStepError("abandoning left the durable attempt behind, so the "
                                         + "next foreground would re-trap the user")
                }
                return ctx
            },

            // ── the happy path still works
            defineStep("my payment is confirmed and my Vault is ready") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.seedAttempt()
                w.service.next = .success(
                    .ready(cellURL: "https://foundry-cell-test.fly.dev", handoff: "door-handoff-secret"))
                return ctx
            },
            defineCheck("my Vault is live") { _, _, _ in
                let state = await MainActor.run { w.model.state }
                guard case .live = state else {
                    throw BrineStepError("a ready Vault did not go live: \(state)")
                }
            },
            defineCheck("I am no longer waiting on my payment") { _, _, _ in
                let state = await MainActor.run { w.model.state }
                if case .checkingPayment = state {
                    throw BrineStepError("still waiting after the Vault went live")
                }
            },
        ]
    }
}
