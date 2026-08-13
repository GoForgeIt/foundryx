import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/vault-purchase-recovery.feature — the four defects one real
/// purchase surfaced (Nick, 2026-08-13):
///
///   1. An abandoned checkout stranded him on the funnel's FIRST screen, with the durable
///      attempt sitting in the store, unmentioned and unreachable.
///   2. The checkout URL the service hands back was opened VERBATIM, so the web page was
///      never told the `foundryx://vault/return` link to hand him back with.
///   3. "Your Vault is live" said who can open it, not what he could now do.
///   4. The Settings row wore a chevron that led nowhere.
///
/// Everything here drives the REAL funnel model, the REAL durable attempt store over an
/// isolated UserDefaults suite, and the REAL copy/presentation types the app renders.
/// The APP-side halves (which screen calls what) are gated by
/// VaultPurchaseRecoveryCompositionTests, in the house style — `swift test` cannot see App/.
final class VaultPurchaseRecoveryFeatureTests: XCTestCase {
    func testVaultPurchaseRecoveryFeature() async throws {
        try await BrineFeatureRunner.run(
            "vault-purchase-recovery",
            registry: StepRegistry(VaultRecoverySteps.make(world: try VaultRecoveryWorld())))
    }
}

/// A signup service whose checkout URL and reconcile answer each scenario sets.
private final class RecoveryStubService: VaultSignupService, @unchecked Sendable {
    private let lock = NSLock()
    private var _next: Result<VaultProvisionStatus, Error> = .success(.pending)
    private var _checkoutURL: URL?
    private var _attemptId = "attempt-recovery"

    var next: Result<VaultProvisionStatus, Error> {
        get { lock.lock(); defer { lock.unlock() }; return _next }
        set { lock.lock(); _next = newValue; lock.unlock() }
    }
    var checkoutURL: URL? {
        get { lock.lock(); defer { lock.unlock() }; return _checkoutURL }
        set { lock.lock(); _checkoutURL = newValue; lock.unlock() }
    }
    var attemptId: String {
        get { lock.lock(); defer { lock.unlock() }; return _attemptId }
        set { lock.lock(); _attemptId = newValue; lock.unlock() }
    }

    func createCheckoutAttempt(plan: VaultPlan, idToken: String?) async throws -> VaultCheckoutAttempt {
        VaultCheckoutAttempt(id: attemptId, checkoutURL: checkoutURL)
    }
    func reconcile(attemptId: String, idToken: String?) async throws -> VaultProvisionStatus {
        try next.get()
    }
    func exchangeReturn(ticket: String, idToken: String?) async throws -> VaultProvisionStatus {
        try next.get()
    }
}

/// A browser that RECORDS what it was asked to open and always resolves "dismissed".
private final class RecordingBrowser: VaultCheckoutBrowser, @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [URL] = []
    var opened: [URL] { lock.lock(); defer { lock.unlock() }; return _opened }

    func open(_ url: URL) async throws -> URL? {
        // `NSLock.lock()` is unavailable from an async context; hop the mutation through a
        // sync helper so the critical section never spans a suspension.
        record(url)
        return nil
    }

    private func record(_ url: URL) {
        lock.lock(); _opened.append(url); lock.unlock()
    }
}

private final class VaultRecoveryWorld: @unchecked Sendable {
    let fixture: PairingTestFixture
    let defaults: UserDefaults
    let service = RecoveryStubService()
    let browser = RecordingBrowser()
    var attempts: VaultCheckoutAttemptStore!
    var model: VaultFunnelModel!
    /// The `.live` funnel state under test for the copy scenarios. Built as a VALUE rather
    /// than by pairing a cell: the iOS unit bundle is deliberately hostless, so a real
    /// pairing cannot be stored there, and the copy contract must be gated on every host.
    var liveState: VaultFunnelState = .live(
        CellConfig(url: "https://vault-abc.fly.dev", auth: .bearer("door-handoff")))
    var entitlement: VaultEntitlement = .off
    var visible: VaultFunnelPresentation = VaultFunnelCopy.presentation(for: .idle)

    let subject = "vault-recovery-owner"

    init() throws {
        fixture = try PairingTestFixture()
        defaults = fixture.defaults
    }

    /// A model whose durable attempt was written BEFORE it existed — an attempt inherited
    /// from a previous app session, which is exactly what "I left the app mid-checkout"
    /// leaves behind.
    @MainActor func makeModelInheritingAttempt(id: String, plan: VaultPlan) {
        try? fixture.activateOther(subject: subject)
        attempts = VaultCheckoutAttemptStore(defaults: defaults)
        attempts.save(attemptId: id, plan: plan)
        buildModel()
    }

    /// A model with NO durable attempt — the checkout, if any, happens in this session.
    @MainActor func makeModel() {
        try? fixture.activateOther(subject: subject)
        attempts = VaultCheckoutAttemptStore(defaults: defaults)
        attempts.clear()
        buildModel()
    }

    @MainActor private func buildModel() {
        model = VaultFunnelModel(
            service: service,
            browser: browser,
            cellStore: CellStore(defaults: defaults, keychainService: fixture.cellService),
            attempts: attempts,
            idToken: { "recovery-token" },
            refreshingIdToken: { "recovery-token" },
            storefrontCountryCode: { "USA" })
    }

    @MainActor var status: VaultFunnelPresentation { model.statusPresentation }
    @MainActor var state: VaultFunnelState { model.state }

    /// The last URL the funnel actually handed the browser, decomposed.
    var lastOpenedQuery: [URLQueryItem] {
        guard let url = browser.opened.last,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        return comps.queryItems ?? []
    }
}

private let paymentDidNotGoThrough = "Your payment didn't go through"

private enum VaultRecoverySteps {
    static func make(world w: VaultRecoveryWorld) -> [StepDefinition] {
        [
            // ── 1 · abandoned checkout

            defineStep("I started checkout and left the app before paying") { ctx, _, _ in
                await MainActor.run { w.makeModelInheritingAttempt(id: "attempt-abandoned", plan: .pro) }
                w.service.next = .success(.pending)
                return ctx
            },
            defineStep("I come back and the app checks with the server") { ctx, _, _ in
                await w.model.reconcileOnForeground(generation: CaptureAccountScope.identityGeneration)
                return ctx
            },
            defineCheck("I am told my payment did not go through") { _, _, _ in
                let status = await w.status
                guard status.title == paymentDidNotGoThrough else {
                    throw BrineStepError(
                        "an abandoned checkout said \"\(status.title)\" — the app knows a "
                        + "checkout attempt is sitting in the store and still would not say so")
                }
            },
            defineCheck("I am offered a way to pick up where I left off") { _, _, _ in
                let status = await w.status
                guard status.primaryAction == .resumeCheckout else {
                    throw BrineStepError(
                        "no way back into payment (\(status.primaryAction)) — the dead end")
                }
            },
            defineCheck("I am not put back on the first screen of the purchase funnel") { _, _, _ in
                let state = await w.state
                switch state {
                case .intro, .plans, .trigger:
                    throw BrineStepError(
                        "an unfinished checkout was answered with the purchase funnel's first "
                        + "screen (\(state)) — being sold the Vault you are already buying")
                default: break
                }
                let status = await w.status
                guard status.primaryAction == .resumeCheckout else {
                    throw BrineStepError("nothing durable points back at the payment either")
                }
            },

            // ── 2 · resuming reopens the SAME attempt

            defineStep("I pick up where I left off") { ctx, _, _ in
                await w.model.resumeCheckout(generation: CaptureAccountScope.identityGeneration)
                return ctx
            },
            defineCheck("the browser reopens the checkout I already started") { _, _, _ in
                guard w.browser.opened.last != nil else {
                    throw BrineStepError("resuming never opened a browser at all")
                }
                let items = w.lastOpenedQuery
                guard items.first(where: { $0.name == "attempt" })?.value == "attempt-abandoned" else {
                    throw BrineStepError(
                        "resuming did not reopen the SAME checkout attempt: \(items)")
                }
                guard items.first(where: { $0.name == "plan" })?.value == VaultPlan.pro.rawValue else {
                    throw BrineStepError("resuming lost the plan I had chosen: \(items)")
                }
            },
            defineCheck("I am waiting on my payment again") { _, _, _ in
                let state = await w.state
                guard case .checkingPayment = state else {
                    throw BrineStepError("after resuming, the funnel is \(state), not waiting")
                }
            },

            // ── 3 · choosing a different plan

            defineStep("I choose a different plan") { ctx, _, _ in
                await MainActor.run { w.model.seePlans() }
                return ctx
            },
            defineCheck("I am on the plans screen") { _, _, _ in
                let state = await w.state
                guard case .plans = state else {
                    throw BrineStepError("choosing a different plan landed on \(state)")
                }
            },

            // ── 4 · an in-flight checkout is not a failed payment

            defineStep("I just closed the checkout browser without paying") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.service.attemptId = "attempt-in-flight"
                w.service.checkoutURL = nil
                w.service.next = .success(.pending)
                await w.model.continueToCheckout(
                    plan: .pro, generation: CaptureAccountScope.identityGeneration)
                return ctx
            },
            defineStep("the app checks with the server") { ctx, _, _ in
                await w.model.reconcileOnForeground(generation: CaptureAccountScope.identityGeneration)
                return ctx
            },
            defineCheck("I am waiting on my payment") { _, _, _ in
                let state = await w.state
                guard case .checkingPayment = state else {
                    throw BrineStepError("a checkout still in flight shows \(state)")
                }
            },
            defineCheck("I am not told my payment did not go through") { _, _, _ in
                let status = await w.status
                guard status.title != paymentDidNotGoThrough else {
                    throw BrineStepError(
                        "a checkout the user closed SECONDS ago, whose webhook has not landed "
                        + "yet, was declared a failed payment — the opposite lie")
                }
            },

            // ── 5 · Settings reaches the recovery

            defineStep("I open my Vault from Settings") { ctx, _, _ in
                await MainActor.run { w.model.activateFromSettings() }
                return ctx
            },

            // ── 6 · the hand-back link always travels with checkout

            defineStep("the Vault service hands the app its own checkout page") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.service.attemptId = "attempt-handback"
                w.service.checkoutURL = URL(string: "https://pay.goforgeit.com/session/abc")
                w.service.next = .success(.pending)
                return ctx
            },
            defineStep("the Vault service hands the app a checkout page that already names its return link") { ctx, _, _ in
                await MainActor.run { w.makeModel() }
                w.service.attemptId = "attempt-handback-2"
                w.service.checkoutURL = URL(
                    string: "https://pay.goforgeit.com/session/abc?return=foundryx://vault/return/custom")
                w.service.next = .success(.pending)
                return ctx
            },
            defineStep("I continue to checkout") { ctx, _, _ in
                await w.model.continueToCheckout(
                    plan: .pro, generation: CaptureAccountScope.identityGeneration)
                return ctx
            },
            defineCheck("the checkout page is told which app link to return to") { _, _, _ in
                let items = w.lastOpenedQuery
                guard items.first(where: { $0.name == "return" })?.value == "foundryx://vault/return" else {
                    throw BrineStepError(
                        "the checkout page the app opened carries no return deep link "
                        + "(\(w.browser.opened.last?.absoluteString ?? "nothing opened")) — the "
                        + "web has no way to hand the user back, so it can only leave them on a "
                        + "page and hope")
                }
            },
            defineCheck("the checkout page is told which checkout attempt this is") { _, _, _ in
                let items = w.lastOpenedQuery
                guard items.first(where: { $0.name == "attempt" })?.value == "attempt-handback" else {
                    throw BrineStepError("the checkout page was not told the attempt id: \(items)")
                }
            },
            defineCheck("the return link the service chose is left alone") { _, _, _ in
                let returns = w.lastOpenedQuery.filter { $0.name == "return" }
                guard returns.count == 1,
                      returns.first?.value == "foundryx://vault/return/custom" else {
                    throw BrineStepError(
                        "the app overwrote or duplicated the return link the service set: \(returns)")
                }
            },

            // ── 7 · what a live Vault actually gives you

            defineStep("my payment is confirmed and my Vault is ready") { ctx, _, _ in
                w.entitlement = .live
                return ctx
            },
            defineStep("I see that my Vault is live") { ctx, _, _ in
                w.visible = VaultFunnelCopy.presentation(for: w.liveState)
                guard w.visible.title == "Your Vault is live" else {
                    throw BrineStepError("the live screen is no longer the live screen")
                }
                return ctx
            },
            defineCheck("I am told my recordings now go to my Vault") { _, _, _ in
                let text = w.visible.allVisibleText.lowercased()
                guard text.contains("recording"), text.contains("vault") else {
                    throw BrineStepError(
                        "the success screen never says the one thing that changed about "
                        + "capture: \(w.visible.allVisibleText)")
                }
            },
            defineCheck("I am told I can search my whole history") { _, _, _ in
                let text = w.visible.allVisibleText.lowercased()
                guard text.contains("search") else {
                    throw BrineStepError(
                        "the success screen never mentions the search that now spans "
                        + "everything: \(w.visible.allVisibleText)")
                }
            },
            defineCheck("I am not promised chat with my Vault") { _, _, _ in
                // Chat through the cell returns 503. Promising it here is a lie the user
                // discovers by tapping.
                let text = w.visible.allVisibleText.lowercased()
                for word in ["chat", "ask ", "conversation with"] where text.contains(word) {
                    throw BrineStepError(
                        "the success screen promises chat (\"\(word)\"), which the cell "
                        + "answers 503 to: \(w.visible.allVisibleText)")
                }
            },
            defineCheck("I am not promised that my Pocket syncs to my Vault") { _, _, _ in
                let text = w.visible.allVisibleText.lowercased()
                for word in ["pocket", "sync"] where text.contains(word) {
                    throw BrineStepError(
                        "the success screen promises Pocket sync (\"\(word)\"), which nothing "
                        + "in this build performs: \(w.visible.allVisibleText)")
                }
            },

            // ── 8 · the Settings row leads somewhere

            defineStep("a free on-device user with no Vault at all") { ctx, _, _ in
                w.entitlement = .off
                return ctx
            },
            defineStep("I look at my Vault in Settings") { ctx, _, _ in
                w.visible = VaultFunnelCopy.presentation(
                    for: w.entitlement == .live ? w.liveState : .idle, inSettings: true)
                return ctx
            },
            defineCheck("the row leads to my Vault detail") { _, _, _ in
                guard w.visible.primaryAction == .openVaultDetail else {
                    throw BrineStepError(
                        "the live Vault row's action is \(w.visible.primaryAction) — the "
                        + "chevron points at nothing")
                }
            },
            defineCheck("the row does not lead to a Vault detail") { _, _, _ in
                guard w.visible.primaryAction != .openVaultDetail else {
                    throw BrineStepError("a Vault that does not exist offered a detail page")
                }
                guard VaultDetail.presentation(entitlement: w.entitlement, host: nil) == nil else {
                    throw BrineStepError("a detail page was built for a Vault nobody has")
                }
            },
            defineCheck("the detail tells me my Vault is live") { _, _, _ in
                guard let detail = VaultDetail.presentation(
                    entitlement: w.entitlement, host: "vault-abc.fly.dev") else {
                    throw BrineStepError("a live Vault has no detail page to lead to")
                }
                guard detail.stateLine.lowercased().contains("live"),
                      detail.stateLine.contains("vault-abc.fly.dev") else {
                    throw BrineStepError("the detail does not say the Vault's state: \(detail.stateLine)")
                }
            },
            defineCheck("the detail tells me what my Vault holds") { _, _, _ in
                guard let detail = VaultDetail.presentation(
                    entitlement: w.entitlement, host: "vault-abc.fly.dev") else {
                    throw BrineStepError("a live Vault has no detail page to lead to")
                }
                guard detail.holds == VaultLiveBenefits.items, !detail.holds.isEmpty else {
                    throw BrineStepError(
                        "the detail says something different from the success screen about "
                        + "what the Vault does — one of them is wrong")
                }
            },
            defineCheck("the detail offers me a way to delete my Vault") { _, _, _ in
                guard let detail = VaultDetail.presentation(
                    entitlement: w.entitlement, host: "vault-abc.fly.dev"),
                      detail.manage.contains(where: { $0.kind == .deleteVault }) else {
                    throw BrineStepError("the detail cannot manage or delete the Vault it describes")
                }
            },
            defineCheck("the detail offers me a way back to my phone") { _, _, _ in
                guard let detail = VaultDetail.presentation(
                    entitlement: w.entitlement, host: "vault-abc.fly.dev"),
                      detail.manage.contains(where: { $0.kind == .useThisPhone }) else {
                    throw BrineStepError("the detail is a one-way door onto the Vault brain")
                }
            },
        ]
    }
}
