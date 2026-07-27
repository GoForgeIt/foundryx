import XCTest
import Foundation
import BrineSwiftCore
import FoundryXKit

/// The Vault funnel spine (track T-IOS-FUNNEL): the phone half of the paid-Vault
/// activation chain — paid-intent routing, browser hand-off, and server reconciliation.
/// Two layers, exactly like LocalFirstOnboardingTests:
///  - Plain XCTest unit assertions on the PURE core (VaultRouter, VaultPlan, the durable
///    checkout-attempt store).
///  - A HERMETIC Brine run of the `@funnel` scenarios in `features/vault-funnel.feature`,
///    driving the REAL VaultFunnelModel state machine with the network + browser STUBBED
///    at their seams (never the live foundry-signup service).
final class VaultFunnelTests: XCTestCase {

    // MARK: unit — pure routing

    func testEntitlementRoutingSendsPaidIntentToTriggerWhenOff() {
        for action in VaultAction.allCases {
            XCTAssertEqual(VaultRouter.route(action: action, entitlement: .off), .trigger(action))
            XCTAssertEqual(VaultRouter.route(action: action, entitlement: .live), .vault(action))
        }
    }

    // MARK: unit — plans

    func testPlansHaveTheLockedPricesAndProIsTheRecommendedDefault() {
        XCTAssertEqual(VaultPlan.starter.priceUSD, 29)
        XCTAssertEqual(VaultPlan.pro.priceUSD, 79)
        XCTAssertEqual(VaultPlan.power.priceUSD, 199)
        XCTAssertTrue(VaultPlan.pro.recommended)
        XCTAssertFalse(VaultPlan.starter.recommended)
        XCTAssertEqual(VaultPlan.recommendedDefault, .pro)
    }

    // MARK: unit — settings entry affordance

    func testVaultEntryPresentationIsEntitlementAware() {
        let off = VaultEntry.presentation(entitlement: .off)
        XCTAssertEqual(off.title, "Turn on your Vault")
        XCTAssertTrue(off.actionable, "an off Vault must offer a tap that launches setup")

        let live = VaultEntry.presentation(entitlement: .live)
        XCTAssertEqual(live.title, "Your Vault")
        XCTAssertFalse(live.actionable, "a live Vault has nothing to turn on")
    }

    // MARK: unit — durable checkout-attempt store

    func testCheckoutAttemptStoreRoundTripsAndClears() {
        let defaults = UserDefaults(suiteName: "vault-attempt-\(UUID().uuidString)")!
        let store = VaultCheckoutAttemptStore(defaults: defaults)
        XCTAssertNil(store.load())
        store.save(attemptId: "att-1", plan: .power)
        XCTAssertEqual(store.load(), .init(attemptId: "att-1", plan: .power))
        store.clear()
        XCTAssertNil(store.load(), "a cleared attempt no longer reconciles")
    }

    func testReturnTicketIsExtractedFromTheDeepLink() {
        let url = URL(string: "foundryx://vault/return?ticket=OPAQUE123")!
        XCTAssertEqual(VaultFunnelModel.ticket(from: url), "OPAQUE123")
        XCTAssertNil(VaultFunnelModel.ticket(from: URL(string: "foundryx://vault/return")!))
    }

    // MARK: hermetic brine — wire the @funnel scenarios to the real state machine

    func testFunnelScenarios() async throws {
        // Provisioning a Vault stores its bearer in the Keychain, and since the
        // pairing became account-scoped a pairing that CANNOT store its secret
        // correctly refuses to report `.live` rather than claiming a Vault that would
        // not work. The iOS unit-test bundle has no keychain entitlement, so these
        // scenarios skip there instead of failing; they are enforced on macOS.
        // Proper fix, tracked separately: host the iOS test target on the app so it
        // inherits keychain access, and this skip disappears.
        try XCTSkipUnless(
            AccountDataIsolationFeatureTests.keychainUsable,
            "this test host has no keychain entitlement; the Vault funnel is "
                + "covered on macOS")
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let featurePath = url.appendingPathComponent("features/vault-funnel.feature").path
        let text = try String(contentsOfFile: featurePath, encoding: .utf8)
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        let world = try VaultWorld()
        defer { world.cleanup() }
        let registry = StepRegistry(VaultSteps.make(world: world))

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry, resources: [],
                                             tagFilter: TagFilter(include: ["@funnel"]),
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
        XCTAssertTrue(failures.isEmpty, "@funnel scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0)
        let tagged = parsed.features[0].scenarios.filter { $0.tags.contains("@funnel") }.count
        XCTAssertEqual(result.passed, tagged, "every @funnel scenario runs and passes")
        XCTAssertGreaterThan(result.passed, 0, "the @funnel lane must not be empty")
    }
}

// MARK: - Brine world + steps (real VaultFunnelModel, stubbed network + browser)

final class VaultWorld: @unchecked Sendable {
    private struct ResetError: Error, CustomStringConvertible {
        let description =
            "the prior scenario's Vault pairing could not be cleared"
    }

    private let fixture: PairingTestFixture
    var defaults: UserDefaults!
    var attempts: VaultCheckoutAttemptStore!
    var service: StubSignupService!
    var browser: StubBrowser!
    var cellStore: CellStore!
    var model: VaultFunnelModel!
    var lastRoute: VaultRoute?
    /// Snapshotted by the browser stub the instant open() is called, to PROVE the checkout
    /// attempt was persisted before the browser opened.
    var attemptPersistedWhenBrowserOpened = false

    init() throws {
        fixture = try PairingTestFixture()
        defaults = fixture.defaults
    }

    func cleanup() {
        fixture.cleanup()
    }

    /// Fresh, hermetic funnel: no Vault (entitlement off), no persisted attempt.
    @MainActor func reset() throws {
        if let cellStore, !cellStore.unpair() {
            throw ResetError()
        }
        attempts?.clear()
        attempts = VaultCheckoutAttemptStore(defaults: defaults)
        service = StubSignupService()
        browser = StubBrowser()
        cellStore = CellStore(
            defaults: defaults,
            keychainService: fixture.cellService)
        lastRoute = nil
        attemptPersistedWhenBrowserOpened = false
        let attemptsRef = attempts!
        browser.onOpen = { [weak self] in
            guard let self else { return }
            self.attemptPersistedWhenBrowserOpened = (attemptsRef.load() != nil)
        }
        model = VaultFunnelModel(service: service, browser: browser, cellStore: cellStore,
                                 attempts: attempts, idToken: { "id-token-abc" },
                                 // The funnel's purchase path is storefront-gated (T-STOREFRONT);
                                 // these scenarios exercise the eligible (US) storefront.
                                 storefrontCountryCode: { "USA" })
    }

    @MainActor var state: VaultFunnelState { model.state }
}

/// The signup-service seam stub — programmable per scenario, records what it was asked.
final class StubSignupService: VaultSignupService, @unchecked Sendable {
    var attemptId = "attempt-xyz"
    var checkoutURL: URL?
    var reconcileStatus: VaultProvisionStatus = .pending
    var exchangeStatus: VaultProvisionStatus = .pending
    private(set) var createdPlans: [VaultPlan] = []
    private(set) var reconcileCalls = 0

    func createCheckoutAttempt(plan: VaultPlan, idToken: String?) async throws -> VaultCheckoutAttempt {
        createdPlans.append(plan)
        return VaultCheckoutAttempt(id: attemptId, checkoutURL: checkoutURL)
    }
    func reconcile(attemptId: String, idToken: String?) async throws -> VaultProvisionStatus {
        reconcileCalls += 1
        return reconcileStatus
    }
    func exchangeReturn(ticket: String, idToken: String?) async throws -> VaultProvisionStatus {
        exchangeStatus
    }
}

/// The external-browser seam stub. `returnURL == nil` models a dismissed sheet.
final class StubBrowser: VaultCheckoutBrowser, @unchecked Sendable {
    var returnURL: URL?
    var onOpen: (() -> Void)?
    private(set) var openedURLs: [URL] = []
    func open(_ url: URL) async throws -> URL? {
        openedURLs.append(url)
        onOpen?()
        return returnURL
    }
}

enum VaultSteps {
    struct StepError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static let readyCellURL = "https://foundry-cell-test.fly.dev"
    static let readyHandoff = "door-handoff-secret"
    static let returnTicketURL = URL(string: "foundryx://vault/return?ticket=OPAQUE123")!

    static func make(world: VaultWorld) -> [StepDefinition] {
        [
            // ── Givens (each re-inits the hermetic world) ────────────────────
            defineStep("a free on-device user with no Vault") { ctx, _, _ in
                try await MainActor.run { try world.reset() }
                return ctx
            },

            defineStep("a free on-device user on the plans screen") { ctx, _, _ in
                try await MainActor.run {
                    try world.reset()
                    world.model.beginSetup()
                    world.model.seePlans()
                }
                return ctx
            },

            defineStep("a free on-device user who completed browser checkout") { ctx, _, _ in
                // Browser returns a verified return-ticket; the ticket exchange is verified.
                try await MainActor.run {
                    try world.reset()
                    world.browser.returnURL = returnTicketURL
                    world.service.exchangeStatus = .ready(cellURL: readyCellURL, handoff: readyHandoff)
                    world.model.beginSetup(); world.model.seePlans()
                }
                return ctx
            },

            defineStep("a free on-device user who dismissed the browser without paying") { ctx, _, _ in
                try await MainActor.run {
                    try world.reset()
                    world.browser.returnURL = nil                 // dismissed
                    world.service.reconcileStatus = .pending       // no payment yet
                    world.model.beginSetup(); world.model.seePlans()
                }
                await world.model.continueToCheckout(plan: .pro)   // lands in Checking payment
                return ctx
            },

            defineStep("a free on-device user whose payment is confirmed but the cell is still provisioning") { ctx, _, _ in
                try await MainActor.run {
                    try world.reset()
                    world.browser.returnURL = nil
                    world.service.reconcileStatus = .pending
                    world.model.beginSetup(); world.model.seePlans()
                }
                await world.model.continueToCheckout(plan: .pro)   // Checking payment
                await MainActor.run { world.service.reconcileStatus = .provisioning }
                return ctx
            },

            defineStep("a user with a live Vault") { ctx, _, _ in
                try await MainActor.run {
                    try world.reset()
                    world.browser.returnURL = returnTicketURL
                    world.service.exchangeStatus = .ready(cellURL: readyCellURL, handoff: readyHandoff)
                    world.model.beginSetup(); world.model.seePlans()
                }
                await world.model.continueToCheckout(plan: .pro)   // provisions live
                let live = await MainActor.run { world.model.entitlement == .live }
                guard live else { throw StepError("failed to reach a live Vault in the given") }
                return ctx
            },

            defineStep("a returning free on-device user with no checkout attempt") { ctx, _, _ in
                try await MainActor.run { try world.reset() }
                return ctx
            },

            // ── Whens ────────────────────────────────────────────────────────
            defineStep("they tap a Vault-only action") { ctx, _, _ in
                await MainActor.run { world.lastRoute = world.model.intent(.chat) }
                return ctx
            },

            defineStep("they turn on their Vault from Settings") { ctx, _, _ in
                await MainActor.run { world.model.activateFromSettings() }
                return ctx
            },

            defineStep("they continue with a plan") { ctx, _, _ in
                await world.model.continueToCheckout(plan: .pro)
                return ctx
            },

            defineStep("the app reconciles on return with a verified payment") { ctx, _, _ in
                await world.model.continueToCheckout(plan: .pro)
                return ctx
            },

            defineStep("the payment clears and the app reconciles on the next foreground") { ctx, _, _ in
                await MainActor.run {
                    world.service.reconcileStatus = .ready(cellURL: readyCellURL, handoff: readyHandoff)
                }
                await world.model.reconcileOnForeground()
                return ctx
            },

            defineStep("the app reconciles on foreground") { ctx, _, _ in
                await world.model.reconcileOnForeground()
                return ctx
            },

            defineStep("a later reconcile brings the Vault live") { ctx, _, _ in
                await MainActor.run {
                    world.service.reconcileStatus = .ready(cellURL: readyCellURL, handoff: readyHandoff)
                }
                await world.model.reconcileOnForeground()
                return ctx
            },

            // ── Thens ────────────────────────────────────────────────────────
            defineCheck("they are routed to the Vault trigger, not a dead end") { _, _, _ in
                guard world.lastRoute == .trigger(.chat) else {
                    throw StepError("route was \(String(describing: world.lastRoute)) — expected the trigger")
                }
                let s = await MainActor.run { world.state }
                guard s == .trigger(.chat) else { throw StepError("state \(s) — expected the trigger screen") }
            },

            defineCheck("the trigger can start Vault setup") { _, _, _ in
                let s = await MainActor.run { () -> VaultFunnelState in
                    world.model.beginSetup(); return world.model.state
                }
                guard s == .intro else { throw StepError("beginSetup did not reach the intro: \(s)") }
            },

            defineCheck("a checkout attempt is persisted before the browser opens") { _, _, _ in
                guard world.attemptPersistedWhenBrowserOpened else {
                    throw StepError("the browser opened BEFORE the checkout attempt was persisted")
                }
                guard world.attempts.load()?.attemptId == world.service.attemptId else {
                    throw StepError("persisted attempt id mismatch: \(String(describing: world.attempts.load()))")
                }
            },

            defineCheck("the browser opens to the checkout for that plan") { _, _, _ in
                guard let opened = world.browser.openedURLs.last else { throw StepError("browser never opened") }
                let s = opened.absoluteString
                guard s.contains("plan=pro"), s.contains(world.service.attemptId) else {
                    throw StepError("checkout URL missing plan/attempt: \(s)")
                }
            },

            defineCheck("the app provisions and connects the Vault") { _, _, _ in
                let (s, ent) = await MainActor.run { (world.model.state, world.model.entitlement) }
                guard case .live = s else { throw StepError("expected a live Vault, got \(s)") }
                guard ent == .live else { throw StepError("entitlement not live") }
            },

            defineCheck("the connected Vault is handed to the app's cell backend") { _, _, _ in
                let (backend, paired) = await MainActor.run {
                    (world.model.connectedVault, world.cellStore.isPaired)
                }
                guard let backend else { throw StepError("no CellBackend was connected") }
                guard backend.target.baseURL.absoluteString == readyCellURL else {
                    throw StepError("cell backend points at \(backend.target.baseURL) — expected \(readyCellURL)")
                }
                guard backend.target.bearer == readyHandoff else {
                    throw StepError("cell backend bearer is not the server handoff")
                }
                guard paired else { throw StepError("the cell was not paired for reconnect on launch") }
            },

            defineCheck("the funnel is checking payment, not failed") { _, _, _ in
                let s = await MainActor.run { world.state }
                guard s == .checkingPayment else {
                    throw StepError("expected Checking payment (a dismissal is not a failure), got \(s)")
                }
            },

            defineCheck("the Vault becomes live") { _, _, _ in
                let (s, backend) = await MainActor.run { (world.model.state, world.model.connectedVault) }
                guard case .live = s, backend != nil else { throw StepError("Vault did not become live: \(s)") }
            },

            defineCheck("the funnel is setting up the Vault") { _, _, _ in
                let s = await MainActor.run { world.state }
                guard s == .settingUp else { throw StepError("expected Setting up, got \(s)") }
            },

            defineCheck("they are routed into the Vault, not the trigger") { _, _, _ in
                guard world.lastRoute == .vault(.chat) else {
                    throw StepError("route was \(String(describing: world.lastRoute)) — expected the Vault")
                }
                let s = await MainActor.run { world.state }
                if case .trigger = s { throw StepError("a live Vault must not drop to the trigger") }
            },

            defineCheck("the funnel stays idle") { _, _, _ in
                let s = await MainActor.run { world.state }
                guard s == .idle else { throw StepError("a returning free user was dragged into the funnel: \(s)") }
            },

            defineCheck("the funnel begins Vault setup") { _, _, _ in
                let (s, p) = await MainActor.run {
                    (world.model.state, VaultEntry.presentation(entitlement: world.model.entitlement))
                }
                guard s == .intro else {
                    throw StepError("the Settings entry did not launch the funnel intro: \(s)")
                }
                guard p.actionable, p.title == "Turn on your Vault" else {
                    throw StepError("the off-state entry row copy is wrong: \(p)")
                }
            },

            defineCheck("the Settings entry does not launch the funnel") { _, _, _ in
                let (s, ent, p) = await MainActor.run {
                    (world.model.state, world.model.entitlement,
                     VaultEntry.presentation(entitlement: world.model.entitlement))
                }
                guard ent == .live else { throw StepError("a live Vault was expected, entitlement is \(ent)") }
                if case .intro = s { throw StepError("a live Vault re-launched the funnel intro from Settings") }
                if case .plans = s { throw StepError("a live Vault re-launched the funnel plans from Settings") }
                guard !p.actionable, p.title == "Your Vault" else {
                    throw StepError("the live-state entry row should reflect the connected Vault, got: \(p)")
                }
            },
        ]
    }
}
