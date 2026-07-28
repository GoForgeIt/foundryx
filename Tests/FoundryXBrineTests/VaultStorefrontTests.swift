import XCTest
import Foundation
import BrineSwiftCore
import FoundryXKit

/// Storefront-gated purchasing + in-app account deletion (track T-STOREFRONT). Two layers,
/// exactly like VaultFunnelTests:
///  - Plain XCTest unit assertions on the PURE core (VaultStorefrontGate, the storefront-aware
///    VaultEntry presentation, the AccountDeletion scopes + model → seam routing).
///  - A HERMETIC Brine run of the `@storefront` scenarios in `features/vault-storefront.feature`,
///    driving the REAL VaultFunnelModel + AccountDeletionModel with the storefront code injected
///    and the deletion seam STUBBED (never a live service).
final class VaultStorefrontTests: XCTestCase {

    // MARK: unit — the storefront gate (US → true, others → false, unknown → fail closed)

    func testStorefrontGateAllowsUSAndFailsClosedEverywhereElse() {
        XCTAssertTrue(VaultStorefrontGate.purchaseAllowed(storefrontCountryCode: "US"))
        XCTAssertTrue(VaultStorefrontGate.purchaseAllowed(storefrontCountryCode: "USA"))
        XCTAssertTrue(VaultStorefrontGate.purchaseAllowed(storefrontCountryCode: "usa"),
                      "storefront comparison is case-insensitive")
        XCTAssertFalse(VaultStorefrontGate.purchaseAllowed(storefrontCountryCode: "GB"))
        XCTAssertFalse(VaultStorefrontGate.purchaseAllowed(storefrontCountryCode: "CAN"))
        XCTAssertFalse(VaultStorefrontGate.purchaseAllowed(storefrontCountryCode: nil),
                       "an undeterminable storefront must fail closed — no purchase CTA")
        XCTAssertFalse(VaultStorefrontGate.purchaseAllowed(storefrontCountryCode: ""),
                       "a blank storefront must fail closed")
    }

    // MARK: unit — the storefront-aware Settings entry presentation

    func testVaultEntryHidesThePurchaseCTAWhenTheStorefrontDisallowsIt() {
        // US, off Vault → the purchase CTA is offered.
        let us = VaultEntry.presentation(entitlement: .off, purchaseAllowed: true)
        XCTAssertTrue(us.showsPurchaseCTA)
        XCTAssertEqual(us.title, "Turn on your Vault")

        // Non-eligible storefront, off Vault → sign-in only, NO purchase CTA.
        let blocked = VaultEntry.presentation(entitlement: .off, purchaseAllowed: false)
        XCTAssertFalse(blocked.showsPurchaseCTA,
                       "a blocked storefront must not surface the purchase CTA")

        // A live Vault never shows a purchase CTA regardless of storefront (nothing to buy).
        let live = VaultEntry.presentation(entitlement: .live, purchaseAllowed: true)
        XCTAssertFalse(live.showsPurchaseCTA)
        XCTAssertEqual(live.title, "Your Vault")

        // The legacy single-arg presentation is unchanged (purchase-eligible world).
        XCTAssertTrue(VaultEntry.presentation(entitlement: .off).showsPurchaseCTA)
    }

    // MARK: unit — account deletion offers exactly the three scopes

    func testAccountDeletionOffersExactlyThreeScopes() {
        XCTAssertEqual(Set(AccountDeletionScope.allCases),
                       [.thisPhone, .hostedVault, .everywhere])
    }

    // MARK: unit — the deletion model routes each scope to the right seam

    func testDeletionModelInvokesTheRightSeamPerScope() async {
        let service = StubDeletionService()
        let model = await AccountDeletionModel(service: service)

        await model.delete(scope: .thisPhone, idToken: "id-token")
        XCTAssertEqual(service.calls, [.thisPhone])

        await model.delete(scope: .hostedVault, idToken: "id-token")
        XCTAssertEqual(service.calls, [.thisPhone, .hostedVault])

        await model.delete(scope: .everywhere, idToken: "id-token")
        XCTAssertEqual(service.calls, [.thisPhone, .hostedVault, .everywhere])
    }

    func testPendingLocalDeletionSurfacesBlockedRetryState() async {
        let service = PendingDeletionService()
        let model = await AccountDeletionModel(service: service)

        await model.delete(scope: .thisPhone, idToken: nil)

        let phase = await MainActor.run { model.phase }
        XCTAssertEqual(phase, .blocked(.thisPhone))
    }

    func testHostedVaultNeverInvokesLocalErasure() async throws {
        let calls = DeletionCallRecorder()
        let service = LiveAccountDeletionService(
            eraseLocal: {
                calls.recordLocal()
            },
            deleteRemote: { scope, _ in
                calls.recordRemote(scope)
            })

        try await service.deleteHostedVault(idToken: "id-token")

        XCTAssertEqual(calls.localCount, 0)
        XCTAssertEqual(calls.remoteScopes, [.hostedVault])
    }

    func testEverywhereRemoteFailureDoesNotStartLocalErasure() async {
        let calls = DeletionCallRecorder()
        let service = LiveAccountDeletionService(
            eraseLocal: {
                calls.recordLocal()
            },
            deleteRemote: { scope, _ in
                calls.recordRemote(scope)
                throw AccountDeletionError.server
            })

        do {
            try await service.deleteAccountEverywhere(idToken: "id-token")
            XCTFail("expected remote account deletion to fail")
        } catch {}

        XCTAssertEqual(calls.localCount, 0)
        XCTAssertEqual(calls.remoteScopes, [.everywhere])
    }

    // MARK: hermetic brine — wire the @storefront scenarios to the real models

    func testStorefrontScenarios() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let featurePath = url.appendingPathComponent("features/vault-storefront.feature").path
        let text = try String(contentsOfFile: featurePath, encoding: .utf8)
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        let world = StorefrontWorld()
        let registry = StepRegistry(StorefrontSteps.make(world: world))

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry, resources: [],
                                             tagFilter: TagFilter(include: ["@storefront"]),
                                             collector: { collected.append($0) })

        var failures: [String] = []
        for ev in collected {
            guard case .object(let o) = ev,
                  case .string("scenario_end")? = o["type"],
                  case .string(let status)? = o["status"], status != "passed" else { continue }
            let name: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(name): \(err)")
        }
        XCTAssertTrue(failures.isEmpty, "@storefront scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0)
        let tagged = parsed.features[0].scenarios.filter { $0.tags.contains("@storefront") }.count
        XCTAssertEqual(result.passed, tagged, "every @storefront scenario runs and passes")
        XCTAssertGreaterThan(result.passed, 0, "the @storefront lane must not be empty")
    }
}

// MARK: - Deletion seam stub (records which scope's seam fired)

final class StubDeletionService: AccountDeletionService, @unchecked Sendable {
    private(set) var calls: [AccountDeletionScope] = []
    func eraseThisPhone() async throws { calls.append(.thisPhone) }
    func deleteHostedVault(idToken: String?) async throws { calls.append(.hostedVault) }
    func deleteAccountEverywhere(idToken: String?) async throws { calls.append(.everywhere) }
}

final class PendingDeletionService:
    AccountDeletionService, @unchecked Sendable
{
    func eraseThisPhone() async throws {
        throw AccountDeletionError.cleanupPending
    }
    func deleteHostedVault(idToken: String?) async throws {}
    func deleteAccountEverywhere(idToken: String?) async throws {
        throw AccountDeletionError.cleanupPending
    }
}

private final class DeletionCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var local = 0
    private var remote: [AccountDeletionScope] = []

    var localCount: Int { lock.withLock { local } }
    var remoteScopes: [AccountDeletionScope] {
        lock.withLock { remote }
    }

    func recordLocal() {
        lock.withLock { local += 1 }
    }

    func recordRemote(_ scope: AccountDeletionScope) {
        lock.withLock { remote.append(scope) }
    }
}

// MARK: - Brine world + steps (real VaultFunnelModel with an injected storefront + real
// AccountDeletionModel with the deletion seam stubbed)

final class StorefrontWorld: @unchecked Sendable {
    var storefront: String?
    var model: VaultFunnelModel!
    var deletion: AccountDeletionModel!
    var deletionService: StubDeletionService!

    /// A fresh, hermetic off-Vault funnel whose storefront is `storefront`, plus a fresh
    /// deletion model over the stub seam.
    @MainActor func reset(storefront: String?) {
        self.storefront = storefront
        let defaults = UserDefaults(suiteName: "vault-storefront-\(UUID().uuidString)")!
        let store = storefront
        model = VaultFunnelModel(
            service: NoopSignupService(),
            browser: NoopBrowser(),
            cellStore: CellStore(defaults: defaults),
            attempts: VaultCheckoutAttemptStore(defaults: defaults),
            storefrontCountryCode: { store })
        deletionService = StubDeletionService()
        deletion = AccountDeletionModel(service: deletionService)
    }

    @MainActor var entry: VaultEntry.Presentation {
        VaultEntry.presentation(entitlement: model.entitlement, purchaseAllowed: model.purchaseAllowed)
    }
}

/// Inert seams — the storefront lane never dials the signup service or the browser (the gate
/// stops the flow before checkout), so these must never actually be reached for a blocked
/// storefront; for the US lane we only advance as far as the plans screen.
final class NoopSignupService: VaultSignupService, @unchecked Sendable {
    func createCheckoutAttempt(plan: VaultPlan, idToken: String?) async throws -> VaultCheckoutAttempt {
        VaultCheckoutAttempt(id: "noop")
    }
    func reconcile(attemptId: String, idToken: String?) async throws -> VaultProvisionStatus { .pending }
    func exchangeReturn(ticket: String, idToken: String?) async throws -> VaultProvisionStatus { .pending }
}
final class NoopBrowser: VaultCheckoutBrowser, @unchecked Sendable {
    func open(_ url: URL) async throws -> URL? { nil }
}

enum StorefrontSteps {
    struct StepError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static func make(world: StorefrontWorld) -> [StepDefinition] {
        [
            // ── Givens ────────────────────────────────────────────────────────
            defineStep("a free on-device user whose App Store storefront is the US") { ctx, _, _ in
                await MainActor.run { world.reset(storefront: "USA") }
                return ctx
            },
            defineStep("a free on-device user whose App Store storefront is outside the US") { ctx, _, _ in
                await MainActor.run { world.reset(storefront: "GB") }
                return ctx
            },
            defineStep("a free on-device user whose App Store storefront cannot be determined") { ctx, _, _ in
                await MainActor.run { world.reset(storefront: nil) }
                return ctx
            },
            defineStep("a signed-in user on the account-deletion screen") { ctx, _, _ in
                await MainActor.run { world.reset(storefront: "USA") }
                return ctx
            },

            // ── Thens (storefront gating) ─────────────────────────────────────
            defineCheck("the Vault entry shows the purchase CTA") { _, _, _ in
                let p = await MainActor.run { world.entry }
                guard p.showsPurchaseCTA else {
                    throw StepError("the US storefront must surface the purchase CTA, got \(p)")
                }
            },
            defineCheck("turning on the Vault from Settings reaches the plans screen") { _, _, _ in
                let s = await MainActor.run { () -> VaultFunnelState in
                    world.model.activateFromSettings()
                    world.model.seePlans()
                    return world.model.state
                }
                guard case .plans = s else {
                    throw StepError("a US storefront must reach the plans screen, got \(s)")
                }
            },
            defineCheck("the Vault entry shows sign-in only, with no purchase CTA") { _, _, _ in
                let p = await MainActor.run { world.entry }
                guard !p.showsPurchaseCTA else {
                    throw StepError("a blocked/unknown storefront must NOT surface the purchase CTA, got \(p)")
                }
            },
            defineCheck("turning on the Vault from Settings does not reach the plans screen") { _, _, _ in
                let s = await MainActor.run { () -> VaultFunnelState in
                    world.model.activateFromSettings()
                    world.model.seePlans()
                    return world.model.state
                }
                if case .plans = s {
                    throw StepError("a blocked storefront must not reach the purchase plans screen")
                }
            },

            // ── Account deletion ──────────────────────────────────────────────
            defineCheck("the account-deletion screen offers erase-this-phone, delete-hosted-Vault, and delete-everywhere") { _, _, _ in
                guard Set(AccountDeletionScope.allCases) == [.thisPhone, .hostedVault, .everywhere] else {
                    throw StepError("deletion must offer exactly the three scopes, got \(AccountDeletionScope.allCases)")
                }
            },
            defineStep("they choose to delete the hosted Vault") { ctx, _, _ in
                await world.deletion.delete(scope: .hostedVault, idToken: "id-token")
                return ctx
            },
            defineCheck("only the hosted-Vault deletion seam is invoked") { _, _, _ in
                guard world.deletionService.calls == [.hostedVault] else {
                    throw StepError("expected only the hosted-Vault seam, got \(world.deletionService.calls)")
                }
            },
            defineStep("they choose to delete the account everywhere") { ctx, _, _ in
                await world.deletion.delete(scope: .everywhere, idToken: "id-token")
                return ctx
            },
            defineCheck("the delete-everywhere seam is invoked") { _, _, _ in
                guard world.deletionService.calls.last == .everywhere else {
                    throw StepError("expected the delete-everywhere seam last, got \(world.deletionService.calls)")
                }
            },
        ]
    }
}
