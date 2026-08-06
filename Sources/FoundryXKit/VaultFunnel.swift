// VaultFunnel — the phone-side activation spine for the paid Vault (track T-IOS-FUNNEL,
// design canon: funnel-and-auth-spine-design.md "6 · Vault").
//
// The free app is on-device only (no Vault). A paid-intent action (chat / search
// everything / add a device) that needs the Vault routes to a TRIGGER when the Vault is
// off, or straight through when it's live — entitlement-aware routing (never a dead end).
// Turning the Vault on hands off to an EXTERNAL browser for login + payment (Apple's rules
// + review-clean). The mechanism of return is SERVER RECONCILIATION, not the deep link: a
// checkout attempt is persisted BEFORE the browser opens, and entitlement is reconciled on
// every foreground. A dismissed browser is NOT a failure — the server is authoritative.
//
// This file is the PURE, hermetically-testable core: the state enum, the routing rule, the
// durable checkout-attempt store, the network/browser SEAMS (protocols), and the model that
// drives the flow. The SwiftUI screens (App/VaultFunnelView.swift) and the live network
// client (VaultSignupClient.swift) sit on top of these seams.

import Foundation

// MARK: - Actions + entitlement (pure routing)

/// A paid-intent action — something that only works with a live Vault.
public enum VaultAction: String, CaseIterable, Equatable, Sendable {
    /// Ask Foundry about everything you've captured.
    case chat
    /// Search every capture by meaning (not just exact text).
    case searchEverything
    /// Add another device to your Vault.
    case addDevice

    /// The context label shown on the trigger ("Chat · Search everything").
    public var triggerLabel: String {
        switch self {
        case .chat: return "Chat"
        case .searchEverything: return "Search everything"
        case .addDevice: return "Add a device"
        }
    }
}

/// Whether this phone currently has a live, paid Vault.
public enum VaultEntitlement: Equatable, Sendable {
    case off
    case live
}

/// Where a paid-intent action lands.
public enum VaultRoute: Equatable, Sendable {
    /// No Vault: guide the user into setup, preserving the attempted action.
    case trigger(VaultAction)
    /// Vault live: perform the action against the Vault.
    case vault(VaultAction)
}

public enum VaultRouter {
    /// Entitlement-aware routing (design §"Routing must be entitlement-aware"): a
    /// Vault-only action routes to the trigger when the Vault is off, to the Vault
    /// when it's live. Never a dead end.
    public static func route(action: VaultAction, entitlement: VaultEntitlement) -> VaultRoute {
        switch entitlement {
        case .off: return .trigger(action)
        case .live: return .vault(action)
        }
    }
}

// MARK: - Settings entry affordance (pure presentation)

/// The Settings "Your Vault" row — the low-collision entry point that launches the funnel
/// (track T-IOS-VAULT-ENTRY). Off ⇒ invite setup (tapping drives the funnel intro); live ⇒
/// reflect the connected Vault (nothing to turn on). Pure so the row's copy + actionability
/// are entitlement-aware and Brine-testable without SwiftUI — the same seam pattern as
/// VaultRouter.
public enum VaultEntry {
    /// What the Settings row shows for a given entitlement.
    public struct Presentation: Equatable, Sendable {
        /// The row title ("Turn on your Vault" off · "Your Vault" live · "Open your Vault"
        /// when purchasing is gated off by the storefront).
        public let title: String
        /// The supporting line under the title.
        public let subtitle: String
        /// True when tapping should do something (off ⇒ launch setup or sign-in; a live Vault
        /// is not actionable — there's nothing to turn on).
        public let actionable: Bool
        /// Whether tapping should launch the PURCHASE path (native plans → external checkout).
        /// False when the Vault is live (nothing to buy) OR when the App Store storefront
        /// disallows purchasing here (track T-STOREFRONT) — then the row is sign-in only so an
        /// existing subscriber can still open their Vault, with NO purchase CTA (review-clean).
        public let showsPurchaseCTA: Bool

        public init(title: String, subtitle: String, actionable: Bool, showsPurchaseCTA: Bool = false) {
            self.title = title
            self.subtitle = subtitle
            self.actionable = actionable
            self.showsPurchaseCTA = showsPurchaseCTA
        }
    }

    /// Legacy single-arg presentation — the purchase-eligible world (storefront allows it).
    /// Kept for callers that don't gate on the storefront; delegates to the gated form.
    public static func presentation(entitlement: VaultEntitlement) -> Presentation {
        presentation(entitlement: entitlement, purchaseAllowed: true)
    }

    /// The storefront-aware presentation (track T-STOREFRONT). `purchaseAllowed` comes from
    /// VaultStorefrontGate over the App Store storefront country. When the Vault is off and
    /// purchasing is disallowed (or the storefront is unknown → fail closed), the row becomes
    /// sign-in only: an existing subscriber can still open their Vault, and NO purchase CTA is
    /// shown anywhere the storefront doesn't allow it.
    public static func presentation(entitlement: VaultEntitlement, purchaseAllowed: Bool) -> Presentation {
        switch entitlement {
        case .live:
            return Presentation(
                title: "Your Vault",
                subtitle: "On. Encrypted, isolated, and yours — only your voice and login open it.",
                actionable: false,
                showsPurchaseCTA: false)
        case .off where purchaseAllowed:
            return Presentation(
                title: "Turn on your Vault",
                subtitle: "Search everything, chat with your memory, and let Solleva act — on your private, isolated Vault.",
                actionable: true,
                showsPurchaseCTA: true)
        case .off:
            // Storefront-gated off: no purchase CTA. Existing subscribers sign in to open it.
            return Presentation(
                title: "Open your Vault",
                subtitle: "Already have a Vault? Sign in to open it on this iPhone.",
                actionable: true,
                showsPurchaseCTA: false)
        }
    }
}

// MARK: - Plans (native pricing rows)

/// A Vault plan. Copy locked from the design (rewritten differentiator copy).
public enum VaultPlan: String, CaseIterable, Equatable, Sendable {
    case starter
    case pro
    case power

    public var title: String {
        switch self {
        case .starter: return "Starter"
        case .pro: return "Pro"
        case .power: return "Power"
        }
    }

    public var priceUSD: Int {
        switch self {
        case .starter: return 29
        case .pro: return 79
        case .power: return 199
        }
    }

    public var blurb: String {
        switch self {
        case .starter:
            return "Search every capture by meaning, and connect your memory to your own tools."
        case .pro:
            return "Everything in Starter, plus chat with Solleva about anything you've captured. Larger AI allowance."
        case .power:
            return "Everything in Pro, plus scheduled playbooks, advanced approvals, and premium voice recognition."
        }
    }

    /// Pro is the recommended default (design: three selectable rows, Pro★).
    public var recommended: Bool { self == .pro }

    /// The default selection when the plans screen opens.
    public static let recommendedDefault: VaultPlan = .pro
}

// MARK: - Provisioning status (what the server tells us on reconcile)

/// The server-authoritative outcome of a reconcile / return-ticket exchange. The
/// opaque single-use ticket NEVER carries the cell URL or bearer (design law) — the
/// server returns them here, only after verifying payment.
public enum VaultProvisionStatus: Equatable, Sendable {
    /// No verified payment yet (browser dismissed, still processing). NOT a failure —
    /// the funnel stays in "Checking payment" and reconciles again on next foreground.
    case pending
    /// Payment verified; the isolated cell is still being provisioned.
    case provisioning
    /// The Vault is live: connect to `cellURL` with `handoff` as the door bearer.
    case ready(cellURL: String, handoff: String)
    /// A TERMINAL server state — provisioning failed, the Vault is suspended, or the
    /// account is not entitled.
    ///
    /// This case exists because its absence trapped a paying user. The server has always
    /// been able to answer `failed`, `suspended` and `unentitled`; the client mapped all
    /// three (and anything else it did not recognise) onto `.pending`, so a provision
    /// that aborted at 14:05 was still rendering "Checking your payment…" five hours
    /// later. An unknown status is now terminal-with-an-exit rather than eternal
    /// progress: being wrong in the direction of "tell the user something" is recoverable;
    /// being wrong in the direction of "spin forever" is not.
    case failed(VaultProvisionFailure)
}

/// Why a Vault did not come up, in terms the funnel can render honestly.
public enum VaultProvisionFailure: Equatable, Sendable {
    /// Payment took, provisioning did not finish. Retryable.
    case provisioningFailed
    /// The provisioner reported the account's cell already exists. This is not a
    /// mysterious retryable failure: the paid owner already has a Vault to recover.
    case alreadyExists
    /// A safe, user-displayable reason returned by the provisioning service.
    case server(String)
    /// The Vault exists but is suspended.
    case suspended
    /// The server does not consider this account entitled.
    case notEntitled
    /// The sign-in the funnel presented was rejected. Retryable AFTER signing in again —
    /// distinct from `provisioningFailed` because the remedy is different.
    case signInExpired
    /// A status string this build has never seen.
    case unknown(String)

    /// What the user is told. Short, no jargon, and never blames them.
    public var headline: String {
        switch self {
        case .provisioningFailed, .server: return "Setting up your Vault didn't finish"
        case .alreadyExists: return "You already have a Vault"
        case .suspended: return "Your Vault is paused"
        case .notEntitled: return "We couldn't confirm your Vault"
        case .signInExpired: return "Your sign-in expired"
        case .unknown: return "Something went wrong setting up your Vault"
        }
    }

    /// Does the remedy start with signing in again, rather than retrying?
    public var needsSignIn: Bool { self == .signInExpired }

    /// Is retrying meaningful? `suspended` is not something a retry fixes.
    public var isRetryable: Bool {
        switch self {
        case .suspended, .alreadyExists: return false
        default: return true
        }
    }

    public var explanation: String {
        switch self {
        case .server(let reason): return reason
        case .alreadyExists:
            return "This account already has a Vault. Your payment and existing Vault are safe."
        default:
            return "Your payment is safe. You can leave while we sort this out."
        }
    }
}

/// User-visible contract for the funnel. SwiftUI renders this value and behavior tests
/// assert it, preventing model-only tests from passing while the actual screen stays stuck.
public struct VaultFunnelPresentation: Equatable, Sendable, CustomStringConvertible {
    public enum Action: Equatable, Sendable { case none, leaveProvisioning, enterVault }
    public let title: String
    public let body: String
    public let showsProgress: Bool
    public let primaryAction: Action
    public var allVisibleText: String { "\(title) \(body)" }
    public var description: String { allVisibleText }
}

/// The result of persisting a checkout attempt: the opaque id we reconcile against,
/// plus the browser URL to open (server-provided, else the model builds the canonical
/// `goforgeit.com/vault/start` URL).
public struct VaultCheckoutAttempt: Equatable, Sendable {
    public let id: String
    public let checkoutURL: URL?
    public init(id: String, checkoutURL: URL? = nil) {
        self.id = id
        self.checkoutURL = checkoutURL
    }
}

// MARK: - Seams (network + browser)

/// The signup-service seam (live impl: VaultSignupClient → foundry-signup Cloud Run).
/// Stubbed in the hermetic test — the funnel never dials the live service under test.
public protocol VaultSignupService: Sendable {
    /// POST /signup/checkout-attempt — persist a checkout reference BEFORE opening the
    /// browser (the return-reconciliation model). Returns the opaque attempt id.
    func createCheckoutAttempt(plan: VaultPlan, idToken: String?) async throws -> VaultCheckoutAttempt
    /// POST /signup/reconcile (Bearer id_token) — server-authoritative entitlement for
    /// this attempt. Called on every foreground.
    func reconcile(attemptId: String, idToken: String?) async throws -> VaultProvisionStatus
    /// POST /app/return {ticket} — exchange the deep-link ticket for provisioning status
    /// (a callback proves navigation, not payment — this verifies server-side).
    func exchangeReturn(ticket: String, idToken: String?) async throws -> VaultProvisionStatus
}

/// The external-browser seam (live impl wraps ASWebAuthenticationSession). Returns the
/// return-callback URL if the session completed with one, or nil if the user dismissed
/// it (dismissal ≠ failure). Stubbed in the hermetic test.
public protocol VaultCheckoutBrowser: Sendable {
    func open(_ url: URL) async throws -> URL?
}

// MARK: - Durable checkout-attempt store

/// Persists the in-flight checkout attempt (id + plan) so reconcile survives the app
/// being backgrounded or killed mid-checkout (design: "reconcile entitlement on every
/// launch/foreground"). UserDefaults-backed, injectable for tests.
public struct VaultCheckoutAttemptStore {
    private static let idKey = "foundryx.vault.checkoutAttempt.id"
    private static let planKey = "foundryx.vault.checkoutAttempt.plan"

    private let compatibility: AccountPreferenceCompatibilityStore?
    private let mutations = MutationCounter()

    private final class MutationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func read() -> Int { lock.withLock { value } }
        func advance() { lock.withLock { value += 1 } }
    }

    fileprivate var mutationGeneration: Int { mutations.read() }

    public init() {
        compatibility = nil
    }

    public init(defaults: UserDefaults) {
        compatibility = .init(defaults: defaults)
    }

    public init(compatibility: AccountPreferenceCompatibilityStore) {
        self.compatibility = compatibility
    }

    public struct Pending: Equatable, Sendable {
        public let attemptId: String
        public let plan: VaultPlan
        public init(attemptId: String, plan: VaultPlan) {
            self.attemptId = attemptId
            self.plan = plan
        }
    }

    public func save(attemptId: String, plan: VaultPlan) {
        _ = save(attemptId: attemptId, plan: plan, generation: 0)
    }

    @discardableResult
    public func save(
        attemptId: String,
        plan: VaultPlan,
        generation: UInt64
    ) -> AccountPreferenceWriteResult {
        _ = generation
        let result: AccountPreferenceWriteResult
        if let compatibility {
            result = compatibility.writeLegacyCheckoutAttempt(
                id: attemptId,
                plan: plan.rawValue)
        } else {
            result = AccountPreferences.writeCheckoutAttempt(
                id: attemptId,
                plan: plan.rawValue,
                generation: generation)
        }
        mutations.advance()
        return result
    }

    public func load() -> Pending? {
        load(generation: 0)
    }

    public func load(generation: UInt64) -> Pending? {
        _ = generation
        let idPresence = compatibility?.read(
            AccountPreferenceCatalog.vaultCheckoutAttemptID)
            ?? AccountPreferences.read(
                AccountPreferenceCatalog.vaultCheckoutAttemptID)
        guard case .value(let id) = idPresence,
              !id.isEmpty else {
            return nil
        }
        let plan: VaultPlan
        let planPresence = compatibility?.read(
            AccountPreferenceCatalog.vaultCheckoutAttemptPlan)
            ?? AccountPreferences.read(
                AccountPreferenceCatalog.vaultCheckoutAttemptPlan)
        if case .value(let raw) = planPresence {
            guard let storedPlan = VaultPlan(rawValue: raw) else {
                return compatibility == nil ? nil : Pending(
                    attemptId: id, plan: .pro)
            }
            plan = storedPlan
        } else if compatibility == nil {
            return nil
        } else {
            plan = .pro
        }
        return Pending(attemptId: id, plan: plan)
    }

    public func clear() {
        _ = clear(generation: 0)
    }

    @discardableResult
    public func clear(
        generation: UInt64
    ) -> AccountPreferenceWriteResult {
        _ = generation
        let result: AccountPreferenceWriteResult
        if let compatibility {
            result = compatibility.clearLegacyCheckoutAttempt()
        } else {
            result = AccountPreferences.clearCheckoutAttempt(generation: generation)
        }
        mutations.advance()
        return result
    }
}

// MARK: - The funnel state machine

/// Every screen the funnel can show. The trigger carries the attempted action so it can
/// be preserved + resumed after provisioning (design: "Preserve the attempted action").
public enum VaultFunnelState: Equatable, Sendable {
    /// No funnel on screen — the free app. `entitlement` decides routing.
    case idle
    /// "This lives in your Vault" — paid intent hit while the Vault is off.
    case trigger(VaultAction)
    /// "Turn on your Vault" — the intro / on-device→Vault framing.
    case intro
    /// Native pricing rows; `selected` is the chosen plan.
    case plans(selected: VaultPlan)
    /// The CTA fired: persisting the attempt + opening the external browser.
    case opening(plan: VaultPlan)
    /// "Checking your payment…" — durable, server-reconciled (a dismissal lands here).
    case checkingPayment
    /// "Setting up your Vault." — payment confirmed, the cell is provisioning.
    case settingUp
    /// The bounded foreground wait elapsed. Provisioning still continues server-side.
    case settingUpDelayed
    /// "Your Vault is live." — connected to the cell (CellConfig carried for the app).
    case live(CellConfig)
    /// A TERMINAL, ESCAPABLE stop. Renders what went wrong plus a way out — the state
    /// that did not exist when a paying user was held on "Checking your payment…"
    /// indefinitely.
    case failed(VaultProvisionFailure)
}

/// Drives the Vault funnel: routing, browser hand-off, and reconcile. Holds the seams and
/// the durable attempt store. `@MainActor ObservableObject` so the SwiftUI screens observe
/// `state`; driven identically from the hermetic Brine steps (via MainActor.run).
@MainActor
public final class VaultFunnelModel: ObservableObject {
    @Published public private(set) var state: VaultFunnelState = .idle
    /// The connected Vault brain, set the moment provisioning reports ready — the app
    /// hands this to the capture pipeline / chat exactly like the desktop door.
    @Published public private(set) var connectedVault: CellBackend?

    /// Current entitlement, derived from whether a Vault is connected/paired.
    public var entitlement: VaultEntitlement { connectedVault == nil ? .off : .live }

    private let service: VaultSignupService
    private let browser: VaultCheckoutBrowser
    private let cellStore: CellStore
    private let attempts: VaultCheckoutAttemptStore
    /// A checkout already persisted when this model was created belongs to an earlier
    /// app session. Foreground reconciliation must refresh its Settings status without
    /// reopening the funnel over the free app. An attempt created during this model's
    /// lifetime is an active checkout and continues to drive the visible state machine.
    private let attemptMutationGenerationAtLaunch: Int
    private let idToken: @Sendable () -> String?
    /// An ASYNC token seam that may REFRESH before answering.
    ///
    /// The synchronous `idToken` above reads a cached snapshot that nothing refreshes.
    /// Google id_tokens expire after an hour, so every Vault reconcile made more than an
    /// hour after sign-in was signed with a dead token and rejected 401 — the actual
    /// cause of the owner being stuck. `FoundryAuth.currentIdToken()` has always known
    /// how to refresh; the funnel simply was not asking it. nil ⇒ fall back to the
    /// cached value, so existing call sites and tests are unaffected.
    private let refreshingIdToken: (@Sendable () async -> String?)?

    /// The bearer to sign a reconcile with: refreshed when a refreshing seam is wired,
    /// else the cached snapshot.
    private func freshIdToken() async -> String? {
        if let refreshingIdToken { return await refreshingIdToken() ?? idToken() }
        return idToken()
    }
    /// The App Store storefront country code (StoreKit `Storefront`, read via a thin adapter
    /// at the app edge). Gates the purchase path — track T-STOREFRONT.
    private let storefrontCountryCode: @Sendable () -> String?
    /// The base for the canonical checkout URL when the service doesn't return one.
    private let checkoutBase: URL
    /// The deep-link return callback the browser redirects to.
    private let returnCallback: URL
    @Published public private(set) var lastProvisioningState: VaultFunnelState?

    public var presentation: VaultFunnelPresentation {
        presentation(for: state)
    }

    /// Durable, non-modal status for Settings. Unlike `presentation`, this survives
    /// leaving the flow and is refreshed by background reconciliation.
    public var statusPresentation: VaultFunnelPresentation {
        presentation(for: lastProvisioningState ?? (connectedVault == nil ? .idle : state))
    }

    private func presentation(for state: VaultFunnelState) -> VaultFunnelPresentation {
        switch state {
        case .settingUp:
            return .init(title: "Setting up your Vault",
                         body: "Payment confirmed. Provisioning continues in the background.",
                         showsProgress: true, primaryAction: .leaveProvisioning)
        case .settingUpDelayed:
            return .init(title: "This is taking longer than expected",
                         body: "You can keep using FoundryX. We'll email you when your Vault is ready.",
                         showsProgress: false, primaryAction: .leaveProvisioning)
        case .failed(let reason):
            return .init(title: reason.headline, body: reason.explanation,
                         showsProgress: false, primaryAction: .leaveProvisioning)
        case .live:
            return .init(title: "Your Vault is live",
                         body: "Your private Vault is ready.", showsProgress: false,
                         primaryAction: .enterVault)
        default:
            return .init(title: "", body: "", showsProgress: false, primaryAction: .none)
        }
    }

    /// Whether the paid Vault purchase path may be shown on this device, gated by the App
    /// Store storefront (US-first; unknown → fail closed). Non-eligible / unknown storefronts
    /// get sign-in only, never the plans/checkout CTA (App-Review-clean).
    public var purchaseAllowed: Bool {
        VaultStorefrontGate.purchaseAllowed(storefrontCountryCode: storefrontCountryCode())
    }

    public init(service: VaultSignupService,
                browser: VaultCheckoutBrowser,
                cellStore: CellStore,
                attempts: VaultCheckoutAttemptStore = VaultCheckoutAttemptStore(),
                checkoutBase: URL = URL(string: "https://goforgeit.com/vault/start")!,
                returnCallback: URL = URL(string: "foundryx://vault/return")!,
                idToken: @escaping @Sendable () -> String? = { nil },
                refreshingIdToken: (@Sendable () async -> String?)? = nil,
                storefrontCountryCode: @escaping @Sendable () -> String? = { nil }) {
        self.service = service
        self.browser = browser
        self.cellStore = cellStore
        self.attempts = attempts
        self.attemptMutationGenerationAtLaunch = attempts.mutationGeneration
        self.checkoutBase = checkoutBase
        self.returnCallback = returnCallback
        self.idToken = idToken
        self.refreshingIdToken = refreshingIdToken
        self.storefrontCountryCode = storefrontCountryCode
    }

    // MARK: entry + routing

    /// A paid-intent action fired. Routes to the trigger (Vault off) or returns the
    /// vault route (Vault live). Returns the route so the caller can perform the action
    /// when it's live; drives the funnel onto the trigger when it's off.
    @discardableResult
    public func intent(_ action: VaultAction) -> VaultRoute {
        let route = VaultRouter.route(action: action, entitlement: entitlement)
        if case .trigger(let a) = route { state = .trigger(a) }
        return route
    }

    /// Trigger → intro ("Set up your Vault").
    public func beginSetup() { state = .intro }

    /// Identity boundaries invalidate every account-derived funnel value. Reload
    /// the durable pairing under the new scope, clear A's transient funnel state,
    /// and derive entitlement only from the complete pairing now visible to B.
    public func resetForIdentityTransition() {
        state = .idle
        connectedVault = nil
        cellStore.reloadForIdentityTransition()
        deriveConnectedVault()
    }

    /// Re-derive an id-token pairing when the token for the active account arrives
    /// after the identity boundary itself.
    public func refreshForAvailableToken(expectedGeneration: UInt64) {
        guard expectedGeneration == CaptureAccountScope.identityGeneration else {
            return
        }
        if let config = cellStore.config, case .idToken = config.auth {
            connectedVault = nil
        }
        deriveConnectedVault()
    }

    public func clearUnavailableIdentityToken(expectedGeneration: UInt64) {
        guard expectedGeneration == CaptureAccountScope.identityGeneration,
              let config = cellStore.config,
              case .idToken = config.auth else { return }
        connectedVault = nil
    }

    private func deriveConnectedVault() {
        guard let config = cellStore.config,
              let target = try? CellBackend.resolveTarget(
                config: config,
                idToken: idToken()) else { return }
        connectedVault = CellBackend(target: target)
    }

    /// The Settings entry affordance (track T-IOS-VAULT-ENTRY): launch the activation funnel
    /// from the low-collision "Your Vault" row. Off ⇒ begin setup (→ intro); live ⇒ a no-op
    /// (the row reflects the connected Vault — there is nothing to turn on). Entitlement-aware
    /// so the same row never dead-ends nor re-triggers a paid user.
    public func activateFromSettings() {
        guard entitlement == .off else { return }
        // Storefront-gated (track T-STOREFRONT): only launch the purchase funnel where the
        // App Store storefront allows it. A blocked/unknown storefront is sign-in only — the
        // Settings row presents sign-in itself, so this is a no-op (never the plans path).
        if attempts.load(generation: CaptureAccountScope.identityGeneration) != nil,
           let lastProvisioningState {
            state = lastProvisioningState
            return
        }
        guard purchaseAllowed else { return }
        beginSetup()
    }

    /// Intro → native pricing (Pro pre-selected). Purchase-gated: a storefront that disallows
    /// buying here never reaches the plans screen (defense in depth behind the entry gate).
    public func seePlans() {
        guard purchaseAllowed else { return }
        state = .plans(selected: .recommendedDefault)
    }

    /// Select a plan row on the plans screen.
    public func selectPlan(_ plan: VaultPlan) {
        guard case .plans = state else { return }
        state = .plans(selected: plan)
    }

    /// Dismiss the funnel (Not now) — back to the free app, action not performed.
    public func dismiss() { state = .idle }

    /// Leave the full-screen provisioning status without cancelling server work or
    /// clearing the paid checkout attempt. Settings can reopen the last observed status.
    public func leaveProvisioning() {
        switch state {
        case .settingUp, .settingUpDelayed, .failed:
            lastProvisioningState = state
            state = .idle
        default: dismiss()
        }
    }

    /// Called by the screen after its bounded foreground wait. This changes only what is
    /// communicated; it does not alter entitlement or provisioning.
    public func provisioningWaitDidExpire() {
        guard state == .settingUp else { return }
        state = .settingUpDelayed
        lastProvisioningState = state
    }

    public func reportProvisioningFailure(_ reason: VaultProvisionFailure) {
        let failure = VaultFunnelState.failed(reason)
        lastProvisioningState = failure
        if state != .idle { state = failure }
    }

    /// ABANDON a checkout that is going nowhere: clear the durable attempt and return to
    /// the app.
    ///
    /// `dismiss()` alone was never an exit — it sets `.idle`, but the next foreground
    /// finds the still-durable attempt and puts the user straight back into
    /// "Checking your payment…". Nothing but a SUCCESSFUL connect ever cleared an
    /// attempt, so a failed provision meant every launch, forever, with no button to
    /// press. This is that button.
    public func abandonCheckout(generation: UInt64 = CaptureAccountScope.identityGeneration) {
        attempts.clear(generation: generation)
        state = .idle
    }

    // MARK: browser hand-off

    /// The plans CTA. Persist the checkout attempt FIRST (return-recon model), then open
    /// the external browser. Whether the browser completes with a return URL or the user
    /// dismisses it, we land in "Checking payment" and let reconcile decide — the server
    /// is authoritative, so a dismissed sheet is never a failure.
    public func continueToCheckout(plan: VaultPlan) async {
        await continueToCheckout(
            plan: plan,
            generation: CaptureAccountScope.identityGeneration)
    }

    public func continueToCheckout(
        plan: VaultPlan,
        generation: UInt64
    ) async {
        // Storefront-gated (track T-STOREFRONT): never open external checkout where the App
        // Store storefront disallows purchasing — fail closed, the last line of defense.
        guard purchaseAllowed else { return }
        state = .opening(plan: plan)
        let attempt: VaultCheckoutAttempt
        do {
            attempt = try await service.createCheckoutAttempt(plan: plan, idToken: idToken())
        } catch {
            // Couldn't even register the attempt — return to plans so the user can retry.
            state = .plans(selected: plan)
            return
        }
        // Persist BEFORE opening the browser so reconcile works even if we're killed.
        _ = attempts.save(
            attemptId: attempt.id,
            plan: plan,
            generation: generation)

        let url = attempt.checkoutURL ?? canonicalCheckoutURL(plan: plan, attemptId: attempt.id)
        let returned = (try? await browser.open(url)) ?? nil
        // Either path is durable: move to Checking payment and reconcile.
        state = .checkingPayment
        if let returned {
            await handleReturn(url: returned, generation: generation)
        } else {
            await reconcileOnForeground(generation: generation)
        }
    }

    /// The canonical `goforgeit.com/vault/start` URL when the service didn't supply one.
    private func canonicalCheckoutURL(plan: VaultPlan, attemptId: String) -> URL {
        var comps = URLComponents(url: checkoutBase, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "plan", value: plan.rawValue),
            URLQueryItem(name: "attempt", value: attemptId),
            URLQueryItem(name: "return", value: returnCallback.absoluteString),
        ]
        return comps?.url ?? checkoutBase
    }

    // MARK: return + reconcile (server-authoritative)

    /// The return deep link (`foundryx://vault/return?ticket=…`). Convenience only: it
    /// triggers an immediate reconcile via the opaque single-use ticket. If the ticket
    /// yields nothing verified yet, fall through to the durable foreground reconcile.
    public func handleReturn(url: URL) async {
        await handleReturn(
            url: url,
            generation: CaptureAccountScope.identityGeneration)
    }

    public func handleReturn(
        url: URL,
        generation: UInt64
    ) async {
        guard let ticket = Self.ticket(from: url) else {
            await reconcileOnForeground(generation: generation)
            return
        }
        let status = (try? await service.exchangeReturn(ticket: ticket, idToken: idToken())) ?? .pending
        await apply(status, generation: generation)
        if status == .pending {
            await reconcileOnForeground(generation: generation)
        }
    }

    /// Called on EVERY app foreground/launch. If a checkout attempt is pending, ask the
    /// server for the authoritative status and advance the durable states. No attempt ⇒
    /// no-op (a returning free user is never dragged into the funnel).
    public func reconcileOnForeground() async {
        await reconcileOnForeground(
            generation: CaptureAccountScope.identityGeneration)
    }

    public func reconcileOnForeground(
        generation: UInt64
    ) async {
        guard let pending = attempts.load(generation: generation) else {
            return
        }
        // Preserve the honest state machine for a checkout active in this app session.
        // Relaunches deliberately remain idle: their inherited attempt is reconciled into
        // `lastProvisioningState` for Settings and never presents the sheet uninvited.
        if case .idle = state,
           attempts.mutationGeneration != attemptMutationGenerationAtLaunch {
            state = .checkingPayment
        }
        do {
            let status = try await service.reconcile(
                attemptId: pending.attemptId, idToken: await freshIdToken())
            await apply(status, generation: generation)
        } catch VaultSignupError.unauthorized {
            // The server rejected our bearer. This is NOT a blip to sit on: an expired
            // id_token cannot fix itself by waiting, and the old code retried it silently
            // on every foreground forever.
            reportProvisioningFailure(.signInExpired)
            // Tell the SESSION, not just this screen: a rejected bearer means the whole
            // app is signed out, and the remedy is the front door.
            AuthExpiryRouter.shared.authRejected(generation: generation)
        } catch VaultSignupError.provisioning(let reason) {
            let lower = reason.lowercased()
            reportProvisioningFailure(lower.contains("already exists") || lower.contains("cell already exists")
                                      ? .alreadyExists : .server(reason))
        } catch {
            // A genuine network blip: keep the durable waiting state and retry next
            // foreground. This is the ONLY error class that should be invisible.
            return
        }
    }

    /// Apply a server-authoritative status to the funnel + entitlement.
    private func apply(
        _ status: VaultProvisionStatus,
        generation: UInt64
    ) async {
        switch status {
        case .pending:
            // Not verified yet — hold "Checking payment" unless we've already advanced.
            if isWaiting { state = .checkingPayment }
        case .provisioning:
            lastProvisioningState = .settingUp
            if state != .idle { state = .settingUp }
        case .ready(let cellURL, let handoff):
            connect(
                cellURL: cellURL,
                handoff: handoff,
                generation: generation)
        case .failed(let reason):
            // Keep the paid attempt. A failure is status, not cancellation; retaining it
            // allows Settings re-entry and a later server recovery without another charge.
            reportProvisioningFailure(reason)
        }
    }

    /// True while we're in a durable waiting state (so a later `.pending` reconcile
    /// doesn't yank a `settingUp` back to `checkingPayment`).
    private var isWaiting: Bool {
        switch state {
        case .checkingPayment, .opening: return true
        default: return false
        }
    }

    // MARK: hand-off to CellBackend

    /// The Vault is live: pair the cell + build the CellBackend the whole app drives, and
    /// clear the completed checkout attempt. The bearer is the door handoff the cell minted
    /// (never seen in any URL). Failure to build a valid target holds the durable state so
    /// a retry can recover, rather than dead-ending.
    private func connect(
        cellURL: String,
        handoff: String,
        generation: UInt64
    ) {
        let config = CellConfig(url: cellURL, auth: .bearer(handoff))
        do {
            let backend = try CellBackend(cellURL: cellURL, bearer: handoff)
            guard cellStore.pair(config) else {
                state = .settingUp
                return
            }
            connectedVault = backend
            _ = attempts.clear(generation: generation)
            lastProvisioningState = .live(config)
            if state != .idle { state = .live(config) }
        } catch {
            // A malformed cell URL/bearer from the server — stay in setting-up; reconcile
            // will try again. Fail loud in logs, not by dropping the user out of the funnel.
            state = .settingUp
        }
    }

    /// Extract the opaque ticket from a return URL (`?ticket=…`).
    public nonisolated static func ticket(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "ticket" })?.value
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
