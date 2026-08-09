import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

final class VaultReturnRecoveryFeatureTests: XCTestCase {
    func testVaultReturnRecoveryFeature() async throws {
        try await BrineFeatureRunner.run(
            "vault-return-recovery",
            registry: StepRegistry(VaultReturnRecoverySteps.make(world: try .init())))
    }
}

private final class VaultReturnService: VaultSignupService, @unchecked Sendable {
    var seenToken: String?
    var reconcileResult: Result<VaultProvisionStatus, Error> = .success(.pending)

    func createCheckoutAttempt(plan: VaultPlan, idToken: String?) async throws -> VaultCheckoutAttempt {
        .init(id: "paid-return")
    }
    func reconcile(attemptId: String, idToken: String?) async throws -> VaultProvisionStatus {
        seenToken = idToken
        return try reconcileResult.get()
    }
    func exchangeReturn(ticket: String, idToken: String?) async throws -> VaultProvisionStatus {
        .pending
    }
}

private final class VaultReturnBrowser: VaultCheckoutBrowser, @unchecked Sendable {
    func open(_ url: URL) async throws -> URL? { nil }
}

private final class VaultReturnRecoveryWorld: @unchecked Sendable {
    let fixture: PairingTestFixture
    let defaults: UserDefaults
    let service = VaultReturnService()
    let secrets = ScriptedPairingSecretStore()
    var attempts: VaultCheckoutAttemptStore!
    var model: VaultFunnelModel!
    var refreshedToken: String?
    var refreshCount = 0
    var cleanupStatus: RemoteSession.Status = .signedOut

    init() throws {
        fixture = try PairingTestFixture()
        defaults = fixture.defaults
    }

    @MainActor func reset(cachedToken: String? = nil) {
        try? fixture.activateOther(subject: "vault-return-owner")
        attempts = VaultCheckoutAttemptStore(defaults: defaults)
        attempts.save(attemptId: "paid-return", plan: .pro)
        let world = self
        model = VaultFunnelModel(
            service: service,
            browser: VaultReturnBrowser(),
            cellStore: CellStore(
                defaults: defaults,
                keychainService: fixture.cellService,
                secretStore: secrets),
            attempts: attempts,
            idToken: { cachedToken },
            refreshingIdToken: { world.refreshCount += 1; return world.refreshedToken },
            storefrontCountryCode: { "USA" })
    }
}

private enum VaultReturnRecoverySteps {
    static func make(world w: VaultReturnRecoveryWorld) -> [StepDefinition] {[
        defineStep("I paid for a Vault in the browser") { ctx, _, _ in
            await MainActor.run { w.reset(cachedToken: "stale-before-browser") }
            return ctx
        },
        defineStep("I paid for a Vault") { ctx, _, _ in
            await MainActor.run { w.reset() }
            return ctx
        },
        defineStep("the sign-in credential cached before leaving the app is stale") { ctx, _, _ in
            w.refreshedToken = "fresh-after-browser"
            w.service.reconcileResult = .success(.ready(
                cellURL: "https://vault.example", handoff: "handoff"))
            return ctx
        },
        defineStep("I return to the app from checkout") { ctx, _, _ in
            await w.model.reconcileOnForeground(generation: CaptureAccountScope.identityGeneration)
            return ctx
        },
        defineCheck("the app refreshes my sign-in credential before reconciling") { _, _, _ in
            guard w.refreshCount == 1, w.service.seenToken == "fresh-after-browser" else {
                throw BrineStepError("browser-return reconcile did not use the refreshed credential")
            }
        },
        defineCheck("my Vault converges to ready") { _, _, _ in
            guard await MainActor.run(body: { w.model.entitlement == .live }) else {
                throw BrineStepError("paid Vault did not converge to live")
            }
        },
        defineStep("the Vault server rejects my reconcile for a reason other than credential expiry") { ctx, _, _ in
            await MainActor.run { w.reset() }
            w.refreshedToken = "currently-valid"
            w.service.reconcileResult = .failure(VaultSignupError.requestRejected)
            return ctx
        },
        defineStep("the app handles the rejection") { ctx, _, _ in
            await w.model.reconcileOnForeground(generation: CaptureAccountScope.identityGeneration)
            return ctx
        },
        defineCheck("I am told the Vault status check was rejected") { _, _, _ in
            let p = await MainActor.run { w.model.statusPresentation }
            guard p.title == "We couldn't check your Vault" else {
                throw BrineStepError("generic rejection was mistranslated: \(p)")
            }
        },
        defineCheck("I am not told that my sign-in expired") { _, _, _ in
            let p = await MainActor.run { w.model.statusPresentation }
            guard !p.allVisibleText.localizedCaseInsensitiveContains("sign-in expired") else {
                throw BrineStepError("generic rejection was rendered as expiry")
            }
        },
        defineCheck("I am not offered an identical sign-in retry") { _, _, _ in
            let p = await MainActor.run { w.model.statusPresentation }
            guard p.primaryAction == .leaveProvisioning else {
                throw BrineStepError("rejected request offered a sign-in loop")
            }
        },
        defineStep("the app cannot currently determine my entitlement") { ctx, _, _ in
            await MainActor.run { w.reset() }
            w.refreshedToken = nil
            w.service.reconcileResult = .failure(VaultSignupError.credentialUnavailable)
            await w.model.reconcileOnForeground(generation: CaptureAccountScope.identityGeneration)
            return ctx
        },
        defineStep("my Vault setup still needs attention") { ctx, _, _ in ctx },
        defineStep("I open Settings") { ctx, _, _ in ctx },
        defineCheck("my Vault entitlement is shown as temporarily unknown") { _, _, _ in
            guard await MainActor.run(body: { w.model.entitlement == .unknown }) else {
                throw BrineStepError("unknown entitlement collapsed to unentitled")
            }
        },
        defineCheck("I do not see the Vault waitlist") { _, _, _ in
            guard await MainActor.run(body: { !VaultSettingsPresentation.showWaitlist(
                entitlement: w.model.entitlement) }) else {
                throw BrineStepError("paid/unknown owner was shown the waitlist")
            }
        },
        defineCheck("I see the current Vault setup status") { _, _, _ in
            let p = await MainActor.run { w.model.statusPresentation }
            guard !p.title.isEmpty else { throw BrineStepError("Settings omitted Vault setup status") }
        },
        defineStep("my previous account deletion cleanup completed successfully") { ctx, _, _ in
            w.cleanupStatus = .deletionCleanupSucceeded
            return ctx
        },
        defineStep("the sign-in recovery status is shown") { ctx, _, _ in ctx },
        defineCheck("I see that cleanup completed") { _, _, _ in
            guard WelcomeFrontDoor.signInRecoveryPresentation(w.cleanupStatus)?.text
                    .contains("finished") == true else {
                throw BrineStepError("completed cleanup was not visible")
            }
        },
        defineCheck("I do not see a cleanup retry control") { _, _, _ in
            guard WelcomeFrontDoor.signInRecoveryPresentation(w.cleanupStatus)?.action == nil,
                  !WelcomeFrontDoor.showsCleanupRetry(w.cleanupStatus) else {
                throw BrineStepError("completed cleanup retained a retry affordance")
            }
        },
    ]}
}
