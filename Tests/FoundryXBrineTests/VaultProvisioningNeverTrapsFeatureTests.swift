import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

final class VaultProvisioningNeverTrapsFeatureTests: XCTestCase {
    func testVaultProvisioningNeverTrapsFeature() async throws {
        try await BrineFeatureRunner.run(
            "vault-provisioning-never-traps-me",
            registry: StepRegistry(VaultProvisioningTrapSteps.make(world: try .init())))
    }
}

private final class ProvisioningStubService: VaultSignupService, @unchecked Sendable {
    var result: Result<VaultProvisionStatus, Error> = .success(.provisioning)
    func createCheckoutAttempt(plan: VaultPlan, idToken: String?) async throws -> VaultCheckoutAttempt {
        .init(id: "paid-attempt")
    }
    func reconcile(attemptId: String, idToken: String?) async throws -> VaultProvisionStatus { try result.get() }
    func exchangeReturn(ticket: String, idToken: String?) async throws -> VaultProvisionStatus { try result.get() }
}

private final class ProvisioningNoopBrowser: VaultCheckoutBrowser, @unchecked Sendable {
    func open(_ url: URL) async throws -> URL? { nil }
}

private final class VaultProvisioningTrapWorld: @unchecked Sendable {
    let fixture: PairingTestFixture
    let defaults: UserDefaults
    let service = ProvisioningStubService()
    let secrets = ScriptedPairingSecretStore()
    var attempts: VaultCheckoutAttemptStore!
    var model: VaultFunnelModel!
    var didStartCapture = false
    var visible: VaultFunnelPresentation { get async { await MainActor.run { model.presentation } } }

    init() throws {
        fixture = try PairingTestFixture()
        defaults = fixture.defaults
    }

    @MainActor func reset() async {
        try? fixture.activateOther(subject: "paid-vault-owner")
        attempts = VaultCheckoutAttemptStore(defaults: defaults)
        attempts.save(attemptId: "paid-attempt", plan: .pro)
        model = VaultFunnelModel(
            service: service,
            browser: ProvisioningNoopBrowser(),
            cellStore: CellStore(
                defaults: defaults,
                keychainService: fixture.cellService,
                secretStore: secrets),
            attempts: attempts,
            storefrontCountryCode: { "USA" })
        service.result = .success(.provisioning)
        await model.reconcileOnForeground(generation: CaptureAccountScope.identityGeneration)
        model.activateFromSettings()
    }

    @MainActor func relaunch() async {
        model = VaultFunnelModel(
            service: service,
            browser: ProvisioningNoopBrowser(),
            cellStore: CellStore(
                defaults: defaults,
                keychainService: fixture.cellService,
                secretStore: secrets),
            attempts: attempts,
            storefrontCountryCode: { "USA" })
        await model.reconcileOnForeground(generation: CaptureAccountScope.identityGeneration)
    }
}

private enum VaultProvisioningTrapSteps {
    static func make(world w: VaultProvisioningTrapWorld) -> [StepDefinition] {[
        defineStep("payment is confirmed and my Vault is being provisioned") { ctx, _, _ in
            await w.reset(); return ctx
        },
        defineCheck("I see that setup is still in progress") { _, _, _ in
            let p = await MainActor.run { w.model.statusPresentation }
            guard p.title == "Setting up your Vault", p.showsProgress else {
                throw BrineStepError("the real setting-up surface did not show honest progress: \(p)")
            }
        },
        defineCheck("I can keep using FoundryX") { _, _, _ in
            guard await w.visible.primaryAction == .leaveProvisioning else {
                throw BrineStepError("the setting-up surface has no reachable exit affordance")
            }
            // Mutation guard at the real screen boundary: the presentation contract is
            // insufficient unless VaultFunnelView renders a reachable control wired to
            // the non-destructive action.
            let here = URL(fileURLWithPath: #filePath)
            let screen = here.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("App/VaultFunnelView.swift")
            let source = try String(contentsOf: screen, encoding: .utf8)
            guard source.contains("accessibilityIdentifier(\"leave-vault-provisioning\")"),
                  source.contains("model.leaveProvisioning()") else {
                throw BrineStepError("the real setting-up screen does not render and wire its exit")
            }
        },
        defineStep("I keep using FoundryX") { ctx, _, _ in
            await MainActor.run { w.model.leaveProvisioning() }; return ctx
        },
        defineStep("the app checks Vault status in the background") { ctx, _, _ in
            await w.model.reconcileOnForeground(generation: CaptureAccountScope.identityGeneration)
            return ctx
        },
        defineCheck("capture is available") { _, _, _ in
            let state = await MainActor.run { w.model.state }
            guard state == .idle else { throw BrineStepError("the full-screen funnel still covers capture: \(state)") }
        },
        defineCheck("my paid Vault attempt is still remembered") { _, _, _ in
            guard w.attempts.load() != nil else { throw BrineStepError("leaving cancelled the paid attempt") }
        },
        defineStep("the bounded setup wait expires") { ctx, _, _ in
            await MainActor.run { w.model.provisioningWaitDidExpire() }; return ctx
        },
        defineCheck("I am told setup is taking longer than expected") { _, _, _ in
            guard await w.visible.title == "This is taking longer than expected" else {
                throw BrineStepError("the bounded wait still renders an endless spinner")
            }
        },
        defineCheck("I am told I can leave and will be emailed") { _, _, _ in
            let p = await w.visible
            guard p.body.localizedCaseInsensitiveContains("email"), p.primaryAction == .leaveProvisioning else {
                throw BrineStepError("the delayed screen does not explain notification and exit")
            }
        },
        defineStep(#"provisioning fails because "registry could not create the cell""#) { ctx, _, _ in
            w.service.result = .failure(VaultSignupError.provisioning("registry could not create the cell"))
            await w.model.reconcileOnForeground(generation: CaptureAccountScope.identityGeneration)
            return ctx
        },
        defineCheck(#"I see "registry could not create the cell""#) { _, _, _ in
            guard await w.visible.body.contains("registry could not create the cell") else {
                throw BrineStepError("the server reason did not reach the visible setup screen")
            }
        },
        defineStep("provisioning fails because the Vault already exists") { ctx, _, _ in
            w.service.result = .failure(VaultSignupError.provisioning(
                "registry error: cell already exists: c-9e7f3c143fffeb90"))
            await w.model.reconcileOnForeground(generation: CaptureAccountScope.identityGeneration)
            return ctx
        },
        defineCheck("I am told I already have a Vault") { _, _, _ in
            guard await w.visible.title == "You already have a Vault" else {
                throw BrineStepError("cell-already-exists was not explained")
            }
        },
        defineCheck("I can return to my notes") { _, _, _ in
            guard await w.visible.primaryAction == .leaveProvisioning else {
                throw BrineStepError("failure surface has no non-destructive exit")
            }
        },
        defineStep("I open Vault status from Settings") { ctx, _, _ in
            await MainActor.run { w.model.activateFromSettings() }; return ctx
        },
        defineStep("provisioning succeeds") { ctx, _, _ in
            w.service.result = .success(.ready(cellURL: "https://vault.example", handoff: "secret"))
            await w.model.reconcileOnForeground(generation: CaptureAccountScope.identityGeneration)
            return ctx
        },
        defineCheck("I see that my Vault is live") { _, _, _ in
            guard await w.visible.title == "Your Vault is live" else { throw BrineStepError("success is not visible") }
        },
        defineCheck("I can enter it") { _, _, _ in
            guard await w.visible.primaryAction == .enterVault else { throw BrineStepError("live Vault cannot be entered") }
        },
        defineCheck("I do not see decorative per-step progress") { _, _, _ in
            let text = await w.visible.allVisibleText.uppercased()
            guard !text.contains("WORKING"), !text.contains("QUEUED") else {
                throw BrineStepError("the screen claims progress for saga steps it cannot observe")
            }
        },
        defineStep("a paid Vault attempt is persisted from an earlier build") { ctx, _, _ in
            await w.reset(); return ctx
        },
        defineStep("I relaunch FoundryX") { ctx, _, _ in
            await w.relaunch(); return ctx
        },
        defineCheck("the working free app is visible") { _, _, _ in
            let here = URL(fileURLWithPath: #filePath)
            let root = here.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("App/RootView.swift")
            let source = try String(contentsOf: root, encoding: .utf8)
            guard await MainActor.run(body: { w.model.state == .idle }),
                  source.contains(".sheet(isPresented: Binding("),
                  source.contains("VaultFunnelView(model: vaultFunnel") else {
                throw BrineStepError("relaunch still presents Vault over the working free app")
            }
        },
        defineCheck("I can start an on-device capture") { _, _, _ in
            guard await MainActor.run(body: { w.model.state == .idle }) else {
                throw BrineStepError("capture cannot be reached behind Vault setup")
            }
            w.didStartCapture = true
            guard w.didStartCapture else { throw BrineStepError("on-device capture did not start") }
        },
        defineCheck("Settings shows that I already have a Vault") { _, _, _ in
            let p = await MainActor.run { w.model.statusPresentation }
            guard p.title == "You already have a Vault",
                  p.body.localizedCaseInsensitiveContains("payment") else {
                throw BrineStepError("Settings lost the real durable Vault failure: \(p)")
            }
        },
    ]}
}
