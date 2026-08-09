import SwiftUI
import Grain

@MainActor
private final class RootAccountStores: ObservableObject {
    @Published private(set) var brains = BrainStore()

    func resetBrainForIdentityTransition() {
        brains = BrainStore()
    }

}

// M5 R1b: login-gated, remote-managed. You must sign in (Google/Microsoft) and
// have a designated desktop host before entering the app — there are no manual
// door controls; the connection is always the resolved remote door over the
// blind relay, authenticated by your sign-in id_token (the door verifies it).
struct RootView: View {
    @StateObject private var remote = RemoteSession()
    @State private var showingAccount = false
    @State private var showingOnboarding = false
    /// Whether the presented onboarding flow skips its internal welcome step
    /// (set at present-time from WelcomeFrontDoor.firstRunPresentation — the
    /// welcome-as-gate already played the ceremony, never twice).
    @State private var onboardingSkipsWelcome = false
    /// B2 (track 20260714T1800): the persona welcome, ONCE post-sign-in, on its
    /// own flag — established installs (onboarding migrated to "completed") still
    /// see it once after the update; "Set up later" dismisses it forever.
    @State private var showingWelcome = false
    /// T5 (track 20260715T1502): once the connect-welcome gate's action fires, the
    /// established user has entered — flips the gate off so the app opens and the
    /// welcome never repeats.
    @State private var enteredApp = false

    @StateObject private var accountStores = RootAccountStores()
    @StateObject private var cells = CellStore()
    @StateObject private var identityCoordinator = AccountIdentityCoordinator()

    /// The Vault activation funnel (track T-IOS-FUNNEL): paid-intent trigger → browser
    /// hand-off → server reconciliation → live Vault. Presented over the app whenever its
    /// state leaves `.idle`; reconciled on every foreground so a dismissed browser still
    /// completes. The entitlement router (`vaultFunnel.intent`) is what Vault-only actions
    /// call to route to the trigger (Vault off) or straight through (Vault live).
    @StateObject private var vaultFunnel = VaultFunnelModel.live()
    /// In-app account deletion (track T-STOREFRONT) — Apple-required, three scopes.
    @StateObject private var accountDeletion = AccountDeletionModel.live(
        record: DeletionRecorder.shared.record)
    @Environment(\.scenePhase) private var scenePhase

    private var brains: BrainStore { accountStores.brains }

    /// The front-door rendition for the `.signInGate` destination (track
    /// 20260715T1502 re-cut, Nick 2026-07-16: the welcome IS the front door — the
    /// old SignInView connection page never gates, on any path).
    private var frontDoorSurface: WelcomeFrontDoor.Surface {
        WelcomeFrontDoor.surface(signedIn: remote.isSignedIn,
                                 letStraightIn: WelcomePrefs.letStraightIn(),
                                 entered: enteredApp)
    }

    /// The connect-welcome's action — enter the app exactly once. Marking it seen
    /// FIRST guarantees presentFirstRunSurfacesIfNeeded() (and the dest onChange) can
    /// never re-present the legacy post-entry welcome (AC4) — firstRunPresentation
    /// with welcomeSeen == true never returns .standaloneWelcome.
    private func enterApp() {
        WelcomePrefs.markSeen()
        enteredApp = true
        presentFirstRunSurfacesIfNeeded()
    }

    var body: some View {
        // DEV-only visual harness: `-WelcomePreview` launch arg shows the persona
        // welcome directly (chooser flips expert/individual/firm), bypassing auth
        // so the design can be screenshot-verified in the simulator. Variants
        // (track 20260715T1502 AC5 — the sim harness can't seed a signed-in
        // session, so each front-door rendition is directly renderable):
        //   `-WelcomePreview signin`     the signed-out front door (provider buttons)
        //   `-WelcomePreview connecting` the connect gate, still resolving (amber)
        //   `-WelcomePreview connect`    the connect gate, settled (sage, Connected)
        // No effect in normal launches.
        //
        // COMPILED OUT OF A SHIPPING BUILD (leak gate). Same class as `-MainPreview`: a launch
        // argument that renders a front-door surface while BYPASSING AUTH has no business
        // existing in a shipping binary, whether or not anyone knows the flag. It survived only
        // because the old `strings`-based scan cannot see a ≤15-byte Swift literal.
        #if DEBUG || PERF_HARNESS
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-WelcomePreview") {
            let variant = i + 1 < args.count ? args[i + 1] : ""
            switch variant {
            case "signin":
                return AnyView(PersonaWelcomeStep(
                    onStart: {}, onSkip: {},
                    signIn: WelcomeSignInActions(providers: [.apple, .google, .microsoft],
                                                 statusText: nil, onTap: { _ in })))
            case "connecting":
                return AnyView(PersonaWelcomeStep(
                    onStart: {}, onSkip: {},
                    connect: WelcomeFrontDoor.connectStatus(.resolving, email: nil)))
            case "connect":
                return AnyView(PersonaWelcomeStep(
                    onStart: {}, onSkip: {},
                    connect: WelcomeFrontDoor.connectStatus(.connected(host: "mac"),
                                                            email: "nick@example.com")))
            default:
                return AnyView(PersonaWelcomeStep(onStart: {}, onSkip: {}))
            }
        }
        #endif
        // DEV-only visual harness: `-MainPreview` mounts the real tabs in phone-only
        // mode (no auth, no door) over the demo cards DemoSeed dropped on disk, so every
        // screen can be screenshot-verified against the prototype. No effect normally.
        //
        // COMPILED OUT OF A SHIPPING BUILD (leak gate, review B2). This branch mounts the whole
        // app with NO auth and NO door on a launch argument — exactly the class of seam
        // `scripts/ci-gates.sh leak` has always claimed to ban. It shipped anyway because the
        // old `strings`-based detection cannot see a ≤15-byte Swift literal, so `-MainPreview`
        // scored zero hits in Release and the gate printed "clean". A normal launch is
        // byte-for-byte unaffected either way; the argument path simply no longer exists in
        // the shipping configuration.
        #if DEBUG || PERF_HARNESS
        if ProcessInfo.processInfo.arguments.contains("-MainPreview") {
            // `-RemoteChat`: mount the computer-tier chat surface (composer always
            // present) so the act-in-chat prefill can be screenshot-verified in the
            // simulator, where the phone-tier surface hides its composer behind the
            // Apple Intelligence gate. Dev-harness only; no effect normally.
            return AnyView(MainTabs(
                target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "local"),
                remote: remote, brains: brains,
                local: !ProcessInfo.processInfo.arguments.contains("-RemoteChat"),
                vaultFunnel: vaultFunnel, accountDeletion: accountDeletion, showingAccount: .constant(false)))
        }
        #endif
        // DEV-only: `-Screen answer` mounts the answer/decision-brief with demo data
        // (no manager needed) for screenshot-verification.
        //
        // COMPILED OUT OF A SHIPPING BUILD (leak gate) — same class as `-MainPreview` and
        // `-WelcomePreview`: a launch argument that mounts a surface with seeded data, ahead of
        // the real destination logic. `#endif` closes after the `-Screen waiting` variant below.
        #if DEBUG || PERF_HARNESS
        if ProcessInfo.processInfo.arguments.contains("-Screen"),
           ProcessInfo.processInfo.arguments.contains("answer") {
            let demo = AmbientAnswer(
                title: "Blind Noise relay for launch",
                text: """
                Recommendation
                Choose the blind Noise relay for the July launch.

                Why
                - Preserves end-to-end encryption.
                - Adds about 40 ms.
                - Gives the server no visibility.

                Source
                Architecture call, June 30. Three related conversations confirm the constraint.
                """)
            return AnyView(AnswerSurfaceView(answer: demo, onDone: {}))
        }
        // DEV-only: `-Screen waiting <kind>` mounts one honest-wait state (WS-C) for
        // screenshot-verification — kind ∈ recap|title|transcription|door|sync.
        if ProcessInfo.processInfo.arguments.contains("-Screen"),
           ProcessInfo.processInfo.arguments.contains("waiting") {
            return AnyView(WaitingExperienceProof(
                kind: WaitingExperienceProof.kind(from: ProcessInfo.processInfo.arguments)))
        }
        // DEV-only: `-Screen deletionChoice` mounts the three-way deletion choice for
        // screenshot verification. Reached in the real app only from Settings →
        // Delete account → "Delete your account everywhere", which needs a signed-in
        // session the simulator has no way to produce — so the screen is mounted
        // directly rather than adding an auth-bypass seam to reach it.
        if ProcessInfo.processInfo.arguments.contains("-Screen"),
           ProcessInfo.processInfo.arguments.contains("deletionChoice") {
            return AnyView(DeletionOutcomeChoiceView(onPick: { _ in }, onCancel: {}))
        }
        #endif
        // The welcome front door leads until the user enters (enterApp); an
        // opted-out user short-circuits inside RootGate — no gate of any kind.
        let dest = RootGate.destination(signedIn: remote.isSignedIn,
                                        splashElapsed: enteredApp,
                                        brain: brains.choice,
                                        hostResolved: remote.makeDoorTarget() != nil,
                                        letStraightIn: WelcomePrefs.letStraightIn(),
                                        cellPaired: cells.isPaired)
        return AnyView(bodyContent(dest))
    }

    @ViewBuilder private func bodyContent(_ dest: RootDestination) -> some View {
        Group {
            switch dest {
            case .signInGate:
                // Track 20260715T1502 (re-cut, Nick 2026-07-16): the welcome IS the
                // front door — ONE call site, parameterized by rendition (plan-review
                // F2: same SwiftUI identity, so sign-in → connect-gate morphs in
                // place instead of remounting). Signed out ⇒ the provider buttons
                // live ON the welcome; signed in ⇒ the live connect pill + "Take me
                // in" / "Skip the welcome". The old SignInView never gates — even
                // the logically-unreachable `.none` fallback renders the welcome.
                PersonaWelcomeStep(
                    onStart: enterApp,
                    onSkip: { WelcomePrefs.setLetStraightIn(true); enterApp() },
                    connect: frontDoorSurface == .welcomeConnectGate
                        ? WelcomeFrontDoor.connectStatus(remote.status, email: remote.email)
                        : nil,
                    signIn: frontDoorSurface == .welcomeSignIn
                        ? WelcomeSignInActions(
                            providers: remote.isConfigured ? remote.providers : [],
                            statusText: WelcomeFrontDoor.signInCaption(remote.status),
                            onTap: { p in Task { await remote.signIn(p) } },
                            onRetryCleanup: WelcomeFrontDoor.showsCleanupRetry(remote.status)
                                ? { Task { await remote.retryInterruptedDeletionSignIn() } }
                                : nil)
                        : nil)
            case .computerBrain:
                if let target = remote.makeDoorTarget() {
                    MainTabs(target: target, remote: remote, brains: brains, local: false,
                             vaultFunnel: vaultFunnel, accountDeletion: accountDeletion, showingAccount: $showingAccount,
                             showingOnboarding: $showingOnboarding,
                             onboardingSkipsWelcome: onboardingSkipsWelcome)
                        // A resolved-host change OR a refreshed bearer (after a token-expiry
                        // re-auth) rebuilds the tabs (+ their clients) so every door request
                        // uses the fresh id_token — never a stale, expired one.
                        //
                        // AND THAT REBUILD IS WHY THE PLACE IS WRITTEN DOWN. This `.id` change
                        // destroys every `@StateObject` under it, `TabRouter` included, so a
                        // token refresh on return lands you on the launch tab with no suspend
                        // and no termination involved. `MainTabs` restores from
                        // `AppPlacementStore` on mount, which covers this path and the cold
                        // launch with the same mechanism. The key is composed by
                        // `MainTabsIdentity` so a test can assert that a refreshed bearer really
                        // does change it (features/app-place-restore.feature).
                        .id(MainTabsIdentity.computerKey(
                            tunnelId: target.relay?.tunnelId,
                            bearer: target.bearer,
                            generation: remote.identityRevision))
                        // Point the content-free usage sink at THIS resolved door (base +
                        // fresh bearer) so product-usage reaches POST /foundryx/telemetry/usage.
                        // The `.id` above re-mounts on a bearer refresh, so this re-fires with
                        // the fresh target.
                        .onAppear { PerfTelemetry.shared.setUsageTarget(target) }
                        .sheet(isPresented: $showingAccount) {
                            SignInView(remote: remote) { showingAccount = false }
                        }
                }
            case .cellBrain:
                // Rung 3: a hosted Foundry CELL over its direct public HTTPS door.
                // Same MainTabs as the computer brain, but the target is the cell's
                // URL + resolved grant (id_token or pasted bearer) — no relay.
                if let cfg = cells.config,
                   let target = try? CellBackend.resolveTarget(
                    config: cfg,
                    idToken: identityCoordinator.currentToken?.value) {
                    MainTabs(target: target, remote: remote, brains: brains, local: false,
                             vaultFunnel: vaultFunnel, accountDeletion: accountDeletion,
                             showingAccount: $showingAccount,
                             showingOnboarding: $showingOnboarding,
                             onboardingSkipsWelcome: onboardingSkipsWelcome)
                        // A re-pair (new URL/grant) or a refreshed id_token rebuilds
                        // the tabs so every door request uses the fresh bearer.
                        .id(MainTabsIdentity.cellKey(url: cfg.url, bearer: target.bearer,
                                                     generation: remote.identityRevision))
                        .sheet(isPresented: $showingAccount) {
                            SignInView(remote: remote) { showingAccount = false }
                        }
                }
            case .phoneBrain:
                // The phone-only tier: whole without a brain (zero content egress).
                MainTabs(target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!,
                                            bearer: "local"),
                         remote: remote, brains: brains, local: true,
                         vaultFunnel: vaultFunnel, accountDeletion: accountDeletion, showingAccount: $showingAccount,
                             showingOnboarding: $showingOnboarding,
                             onboardingSkipsWelcome: onboardingSkipsWelcome)
                    .id(MainTabsIdentity.phoneKey(generation: remote.identityRevision))
                    .sheet(isPresented: $showingAccount) {
                        SignInView(remote: remote) { showingAccount = false }
                    }
            }
        }
        // Vault setup is an explicitly opened sheet, never a launch-time gate over the
        // phone-only app. Background reconciliation updates Settings without presenting it.
        .sheet(isPresented: Binding(
            get: { vaultFunnel.state != .idle },
            set: { if !$0 { vaultFunnel.dismiss() } })) {
            VaultFunnelView(model: vaultFunnel, onSignInAgain: { showingAccount = true })
        }
        // Server reconciliation is the mechanism (design law): reconcile entitlement on every
        // foreground so a checkout finished/abandoned in the browser still resolves. Keep the
        // id_token box fresh for the reconcile/checkout Bearer.
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                VaultAuthTokenBox.shared.token =
                    identityCoordinator.currentToken?.value
                // Refresh the App Store storefront (T-STOREFRONT) so the purchase gate reflects
                // the current country before the funnel or the Settings Vault row is shown.
                Task { await VaultStorefrontBox.shared.refresh() }
                Task { await vaultFunnel.reconcileOnForeground() }
            }
        }
        .onChange(of: remote.boundIdToken) { boundToken in
            identityCoordinator.tokenDidChange(
                boundToken,
                generation: remote.identityRevision)
        }
        // The return deep link is convenience only (it triggers an immediate reconcile).
        .onOpenURL { url in
            if url.scheme == "foundryx", url.host == "vault" {
                Task { await vaultFunnel.handleReturn(url: url) }
            }
        }
        .task {
            // ONE place turns a rejected sign-in into a signed-out app. Every surface used
            // to discover 401s locally and render its own message while the app carried on
            // as if signed in — so a dead session looked like a different bug on whichever
            // screen you were standing on.
            AuthExpiryRouter.shared.onExpired = {
                remote.signOut()
                enteredApp = false          // back through the front door, not into the tabs
            }
            identityCoordinator.bind(
                onIdentityTransition: { _ in
                    resetAccountDerivedState()
                    AuthExpiryRouter.shared.identityChanged()
                },
                onRestoreCompleted: { _ in },
                onTokenAvailable: { token in
                    VaultAuthTokenBox.shared.token = token?.value
                    if let token {
                        vaultFunnel.refreshForAvailableToken(
                            expectedGeneration: token.generation)
                        // Browser return can beat identity restoration by one task turn.
                        // The first status check then honestly records "couldn't check";
                        // retry as soon as the credential becomes available so a paid
                        // checkout converges without requiring another app foreground.
                        Task {
                            await vaultFunnel.reconcileOnForeground(
                                generation: token.generation)
                        }
                    } else {
                        vaultFunnel.clearUnavailableIdentityToken(
                            expectedGeneration:
                                CaptureAccountScope.identityGeneration)
                    }
                },
                onCompatibilityStoreRefresh: { refresh in
                    // The completed-restore callback remains the single refresh
                    // boundary. Task 6 owners already read the installed scoped
                    // snapshot, so no second account reset is needed here.
                    _ = refresh.generation
                })
            identityCoordinator.start()
            await remote.restore()
            identityCoordinator.restoreCompleted(
                generation: remote.identityRevision)
            identityCoordinator.tokenDidChange(
                remote.boundIdToken,
                generation: remote.identityRevision)
        }
        .onDisappear { identityCoordinator.stop() }
        .task { await VaultStorefrontBox.shared.refresh() }
        // The fixed 2 s splash task is GONE (track 20260715T1502 re-cut): the
        // welcome front door replaces the branded splash for gated users (its own
        // action advances — enterApp), and an opted-out user goes straight in with
        // zero delay. No path paints the old SignInView while waiting.
        // First-run onboarding (runs ONCE, after the first sign-in): teach the owner's
        // voice + the ambient opt-in. Dismissing counts as done — never re-prompts;
        // both steps stay reachable from Settings. B2: migration suppresses ONLY
        // that onboarding — the persona welcome rides its own foundryx.welcome.seen
        // flag and still shows once for established installs.
        .onChange(of: dest) { d in
            if d != .signInGate { presentFirstRunSurfacesIfNeeded() }
        }
        // (The onboarding cover itself is presented by MainTabs — it needs that view's
        // CaptureManager for the first-note step. RootView still owns WHEN it fires.)
        // The standalone persona welcome (B2) for installs whose onboarding is
        // already done: shows once before the tabs; both actions mark it seen
        // (inside PersonaWelcomeStep) and it stays reachable from Settings →
        // "Welcome & who it's for".
        .fullScreenCover(isPresented: $showingWelcome) {
            PersonaWelcomeStep(onStart: { showingWelcome = false },
                               onSkip: { showingWelcome = false })
        }
        // One design, two renditions (Nick 2026-07-13): the app FOLLOWS the
        // device — Grain's light rendition by day, the Night Shift register
        // when the device goes dark. No forced scheme anywhere; the dynamic
        // tokens carry both.
        // Pre-picker installs that already pair with a desktop stay on the computer
        // brain (migration safety) — adopted exactly once, never overriding an
        // explicit later choice.
        .onChange(of: remote.status) { st in
            if case .connected = st, !brains.hasExplicitChoice {
                brains.select(.myComputer)
            }
        }
        // Phase 7: choosing the computer brain replay-seeds it — every phone-only
        // conversation is re-queued for the door drain (additive; Lore-confirmed
        // captures untouched).
        .onChange(of: brains.choice) { c in
            if c == .myComputer {
                let n = BrainSeeder.rearmForDoorSeed(baseDir: CaptureWAL.documentsCaptures())
                if n > 0 { print("[brain-seed] re-queued \(n) local conversation(s) for the door") }
            }
        }
    }

    /// The post-sign-in first-run ladder (B2): migrate, then render the ONE pure
    /// decision (WelcomeFrontDoor.firstRunPresentation — tested in the kit): the
    /// full onboarding flow (skipping its welcome step when the gate already was
    /// the welcome), the standalone persona welcome, or nothing.
    private func presentFirstRunSurfacesIfNeeded() {
        // Called from both enterApp() and the dest onChange — never re-decide
        // over an already-presented surface (implement-review F3).
        if showingOnboarding || showingWelcome { return }
        OnboardingPrefs.migrateIfPriorUse(baseDir: CaptureWAL.documentsCaptures())
        switch WelcomeFrontDoor.firstRunPresentationForCurrentOwner() {
        case .onboarding(let skipWelcome):
            onboardingSkipsWelcome = skipWelcome
            showingOnboarding = true
        case .standaloneWelcome:
            showingWelcome = true
        case .none:
            break
        }
    }

    private func resetAccountDerivedState() {
        VaultAuthTokenBox.shared.token = nil
        cells.reloadForIdentityTransition()
        accountStores.resetBrainForIdentityTransition()
        vaultFunnel.resetForIdentityTransition()
        AmbientCardBroker.shared.clearForIdentityTransition()
        AmbientNotifier.clearForIdentityTransition()
    }
}

/// Routes intent-driven navigation (Action Button / Siri / Control Center) onto
/// the tab bar from anywhere in the process (track 20260705T1100, Phase 5).
/// The tab set IS the tested AppTab presentation (track 20260714T1800 §1, T1
/// 20260715T1457): Capture → Activity → Chat → Settings, Capture first.
@MainActor
final class TabRouter: ObservableObject {
    typealias Tab = AppTab
    @Published var selected: Tab = AppTab.launch {
        didSet {
            // `tab-switch` span (track 20260717T0759 AC6): the main-thread cost of a
            // tab change, from the selection write through the runloop turn that
            // commits the destination's view build — the user-felt switch latency.
            // Budget-gated in sim-perf's nav phase (<100ms).
            guard oldValue != selected else { return }
            let span = PerfSpan(name: "tab-switch")
            DispatchQueue.main.async { PerfHook.span("tab-switch", ms: span.elapsedMs()) }
        }
    }
    @Published var showActionChooser = false
}

/// Owns the ONE DeviceManager + CaptureManager so Capture + Device tabs share a
/// single BLE link + capture pipeline. All tabs talk to the resolved remote door
/// `target` (relay tunnel + id_token bearer). Chat is independent.
private struct MainTabs: View {
    @Environment(\.scenePhase) private var scenePhase
    let target: DoorTarget
    let remote: RemoteSession
    let brains: BrainStore
    /// Phone-only tier: capture finalizes through LocalBackend (WhisperKit +
    /// Foundation Models), chat is the local whole-library surface, and nothing
    /// ever dials a door.
    let local: Bool
    /// The Vault activation funnel, threaded down to Settings' "Your Vault" entry row
    /// (track T-IOS-VAULT-ENTRY). Owned by RootView; MainTabs only passes it through.
    let vaultFunnel: VaultFunnelModel
    /// In-app account deletion (track T-STOREFRONT), threaded to Settings' Account section.
    /// Owned by RootView; MainTabs only passes it through.
    let accountDeletion: AccountDeletionModel
    @Binding var showingAccount: Bool
    /// First-run onboarding. RootView decides WHEN (it owns the sign-in/destination
    /// logic); the cover is presented HERE because the ending's first-note step drives
    /// the real capture path, and `manager` is a StateObject of this view — not of
    /// RootView.
    @Binding var showingOnboarding: Bool
    let onboardingSkipsWelcome: Bool
    /// DEV-only: `-Onboarding` forces the first-run flow up over `-MainPreview`, so the
    /// ending (first note → ask it → destination) can be UI-proved without a real
    /// sign-in. RootView owns the real trigger; this is a second, local one because the
    /// preview path passes `.constant(false)` for the binding.
    ///
    /// COMPILED OUT OF A SHIPPING BUILD and listed in `ci-gates.sh` LEAK_SEAM_ARGS on day
    /// one — that file's own rule: "a seam nobody is checking for is a seam that comes
    /// back."
    @State private var forcedOnboarding = false

    @StateObject private var device: DeviceManager
    @StateObject private var battery: BatteryMonitor
    @StateObject private var manager: CaptureManager
    @StateObject private var sources: CaptureSourceRegistry
    @StateObject private var log: DoorLog
    // The durable, resumable chat conversation list — owned here so it persists across
    // tab switches and app foregrounding, bound to this MainTabs account generation.
    @StateObject private var chats: ChatConversationStore
    /// The immutable owner/root this entire tab tree started under. Delayed work uses
    /// this binding and is dropped if the identity generation changes.
    private let accountBinding: CaptureAccountScope.AccountBinding?
    @StateObject private var router = TabRouter()
    /// The ambient broker: pendingSeed (chat) + pendingAnswer (answer surface).
    @ObservedObject private var broker = AmbientCardBroker.shared
    // Phone-tier only: on-device brain readiness for the "setting up your private
    // on-device brain" banner (the model download UX). Held so the STT engine can
    // report into it. Unused (`.idle`) in computer mode.
    @StateObject private var brainStatus = LocalBrainStatus()
    /// The phone-tier STT engine (nil in computer mode) — kept so we can prewarm it
    /// on entry rather than on the first finalize.
    private let localSTT: WhisperKitSTT?

    /// First-frame deferral (TARGET 2 — launch first-frame cost). The TabView otherwise
    /// builds ALL four tab roots up front; only the Capture tab is on screen at launch,
    /// so Activity/Chat/Settings (each an N-scaling body over the same library) are dead
    /// weight on the critical path. This flips true right AFTER first draw (a `.task`),
    /// at which point the other tabs build off the critical path. A tab is ALSO built the
    /// instant it becomes `router.selected`, so a deep link / notification / intent that
    /// routes straight to a tab before the flag flips still renders it immediately.
    @State private var deferredTabsReady = false
    /// Launch, permission sheets, and other transient interruptions can all produce an
    /// `.active` transition without suspending Speech. Restart live transcription only
    /// after this tab tree observed a real background, otherwise a second `.active` can
    /// retire the just-installed replacement before it receives PCM.
    @State private var liveTranscriptionWasBackgrounded = false

    // MARK: keeping the person's place (features/app-place-restore.feature)

    /// The transcript this tab tree was asked to REOPEN on mount, from the durable place.
    /// Drives one programmatic push into the Capture tab's detail; cleared when that
    /// detail is dismissed. Deliberately separate from `openCaptureId` below — a single
    /// piece of state doing both jobs makes the rows' own `NavigationLink` re-trigger the
    /// programmatic push and double-stack the detail.
    @State private var restoreCaptureId: String?
    /// The transcript that is open RIGHT NOW, reported by the detail itself as it appears
    /// and disappears. This is what gets written down.
    @State private var openCaptureId: String?
    /// Whether the ONE chat list sheet — this phone's chats and the Mac's, merged — is open
    /// over the Chat tab; restored on mount, and reported back so it is written down.
    @State private var chatListOpen: Bool
    /// What the person is told when their place could NOT be kept as saved (deleted
    /// conversation, unreachable computer, a different account). `nil` when it was kept.
    @State private var placementNotice: String?
    /// Set once the restored place has been applied, so the persist hooks below can never
    /// overwrite a saved place with the launch tab during the first frames of the mount.
    @State private var placementRestored = false
    /// The chat the saved place named, kept so `.onAppear` can ask the LIVE chat store
    /// whether it still exists (free) instead of re-reading the chat file at init.
    private let savedChatId: String?

    init(target: DoorTarget, remote: RemoteSession, brains: BrainStore, local: Bool,
         vaultFunnel: VaultFunnelModel, accountDeletion: AccountDeletionModel,
         showingAccount: Binding<Bool>,
         showingOnboarding: Binding<Bool> = .constant(false),
         onboardingSkipsWelcome: Bool = false) {
        self.target = target
        self.remote = remote
        self.brains = brains
        self.local = local
        self.vaultFunnel = vaultFunnel
        self.accountDeletion = accountDeletion
        _showingAccount = showingAccount
        _showingOnboarding = showingOnboarding
        self.onboardingSkipsWelcome = onboardingSkipsWelcome
        let accountBinding = CaptureAccountScope.currentAccountBinding()
        self.accountBinding = accountBinding
        _chats = StateObject(wrappedValue: ChatConversationStore(
            storageURL: accountBinding.map {
                ChatConversationStore.storageURL(inAccountRoot: $0.root)
            },
            binding: accountBinding))
        // WHERE THE PERSON WAS (features/app-place-restore.feature). Resolved HERE, in the
        // one place that runs again for every way the place can be lost: a cold launch after
        // iOS reclaimed the app, and the `.id`-driven rebuild of this whole tree when the
        // door bearer refreshes. Both end in this init, so both are covered by reading it.
        //
        // The existence check is a `fileExists` against the account root, NOT the in-memory
        // library — that list has not hydrated yet at init, and asking it would report every
        // conversation as deleted for the first second of every launch. The chat's existence
        // is checked in `.onAppear` against the live store instead, so init stays at one
        // memoised read plus (at most) one stat.
        let savedPlacement = accountBinding.flatMap {
            AppPlacementStore.load(inAccountRoot: $0.root)
        }
        let restored = AppPlacementRestore.resolve(
            saved: savedPlacement,
            generation: accountBinding?.generation ?? CaptureAccountScope.identityGeneration,
            doorTier: !local,
            captureExists: { id in
                guard let root = accountBinding?.root else { return false }
                return AppPlacementStore.captureExists(id, inAccountRoot: root)
            },
            // Deferred to `.onAppear`, where the live chat store answers for free.
            chatExists: { _ in true })
        self.savedChatId = restored.placement.openChatId
        _restoreCaptureId = State(initialValue: restored.placement.openCaptureId)
        _chatListOpen = State(initialValue: restored.placement.chatListOpen)
        _placementNotice = State(initialValue: restored.notice)
        let log = DoorLog()
        // Ship the phone's BLE/audio/capture/chat log to the relay diag sink so
        // it's observable server-side (no copying logs off the device).
        log.setRemoteSink(RemoteConfig.fromBundle()?.gatewayHTTPURL.appendingPathComponent("diag/log"))
        // Same sink, own transport: deletion records ship IMMEDIATELY, because a
        // successful "delete everywhere" erases the library and signs the person
        // out — a batched line can die in that gap.
        DeletionRecorder.shared.setEndpoint(
            RemoteConfig.fromBundle()?.gatewayHTTPURL.appendingPathComponent("diag/log"))
        // The SHARED DeviceManager: a background bluetooth-restoration launch may
        // already own the BLE link (FoundryXAppDelegate) — two centrals with one
        // restore identifier are undefined, so the UI adopts the same instance. Any
        // restoration spool flushes + detaches BEFORE CaptureManager takes the
        // frame/state callbacks; resume-same-id then continues its capture.
        let dm = DeviceManager.shared(log: log)
        #if DEBUG || PERF_HARNESS
        // `-SyntheticOmi`: report the (synthetic) Omi as CONNECTED so the ambient capture
        // UI presents its live tile — `isShowingCapture`/`sourcePresentation` gate on
        // `device.connectionState`, which a synthetic frame source alone never sets.
        if ProcessInfo.processInfo.arguments.contains("-SyntheticOmi") {
            dm.forceConnectionStateForTests(.connected("Synthetic Omi"))
        }
        #endif
        FoundryXAppDelegate.handOffRestorationToApp(
            accountBinding: accountBinding)
        _log = StateObject(wrappedValue: log)
        _device = StateObject(wrappedValue: dm)
        _battery = StateObject(wrappedValue: BatteryMonitor())
        // Live on-device transcription preview (Feature 1). The factory builds the
        // SpeechAnalyzer transcriber on iOS 26+, falling back to SFSpeechRecognizer on
        // iOS 16–25; it's additive + ephemeral (Kiln stays authoritative).
        let status = LocalBrainStatus()
        _brainStatus = StateObject(wrappedValue: status)
        #if DEBUG
        // DEV-only screen-proof hook (`-BrainSetupFailed`, track 20260722T1244): force the
        // on-device brain into the FAILED state so the honest-failure banner — warning
        // glyph, the reason, and a working "Try again" — can be screenshot-verified in the
        // simulator without stalling a real 150 MB download. Tapping retry clears the
        // failure, shows recovery progress, and lands on ready (banner gone), which is the
        // whole point of the control. No effect in release builds or normal launches.
        if ProcessInfo.processInfo.arguments.contains("-BrainSetupFailed") {
            status.setFailed("the download stopped at 35% and hasn't moved for 60s",
                             retry: { [weak status] in
                                 guard let status else { return }
                                 let epoch = status.beginAttempt()
                                 status.setDownloading(0.6, epoch: epoch)
                                 Task { @MainActor in
                                     try? await Task.sleep(nanoseconds: 4_000_000_000)
                                     status.setReady(epoch: epoch)
                                 }
                             })
        }
        #endif
        // ONE on-device titler serves both the post-recording pipeline (LocalBackend)
        // and the LIVE rolling title's debounced refreshes (track 20260717T1015).
        let systemTitler = makeSystemTitler()
        // The live-transcriber factory — or, under the DEBUG `-RollingTitleDemo`
        // proof harness, a scripted transcriber that replays a known conversation
        // through the REAL pipeline (title heuristic + arbiter + published title).
        var liveFactory = LiveTranscription.defaultFactory()
        // The EXTERNAL live-title refresh (track 20260717T1500): nil ⇒ the door path
        // (door branch) or off (local). The DEBUG proof harness overrides it with a
        // scripted external + a fast backoff so the two-tier sharpen is screenshottable.
        var scriptedExternal: (@Sendable (String, String, Int) async throws -> String?)?
        var liveBackoff = LiveTitleBackoff.default
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-RollingTitleDemo") {
            liveFactory = ScriptedLiveTranscriber.factory()
            scriptedExternal = ScriptedExternalTitle.closure()
            liveBackoff = LiveTitleBackoff(firstDelay: 4, multiplier: 2, ceiling: 20)
        }
        #endif
        #if DEBUG || PERF_HARNESS
        // UI-proof seam (`-SyntheticTranscript`): replace ONLY LiveTranscriber with a
        // deterministic PCM-driven word producer. The ambient source, CaptureManager
        // publisher, RecordingScreen binding/rendering, and foreground restoration all
        // remain real, so the proof catches a restored blank shell instead of bypassing it.
        if ProcessInfo.processInfo.arguments.contains("-SyntheticTranscript") {
            liveFactory = SyntheticTranscriptLiveTranscriber.factory()
        }
        #endif
        // The phone's own mic as a second capture source (Record button when the Omi is
        // disconnected) — flows through the identical Opus/WAL/finalize path.
        //
        // DEV-only screen-proof hook (`-SyntheticMic`, track 20260722T1601): the iOS
        // simulator's AVAudioEngine input node reports a degenerate `rate=0.0 ch=0`
        // format even with microphone privacy granted, so `MicFrameSource` (correctly)
        // fails with "no microphone input available" and the recording surface can never
        // present there. Under the launch argument ONLY, substitute a synthetic frame
        // source that feeds real 48k/960 Opus packets into the SAME pipeline, so the
        // simulator proofs exercise the real capture path without mic hardware. No
        // effect in release builds or on a normal launch.
        #if DEBUG || PERF_HARNESS
        let syntheticMic = ProcessInfo.processInfo.arguments.contains("-SyntheticMic")
        let mic: AudioFrameSource = syntheticMic
            ? SyntheticMicFrameSource(log: log)
            : MicFrameSource(log: log)
        #else
        let mic: AudioFrameSource = MicFrameSource(log: log)
        #endif
        // `-SyntheticOmi` (DEBUG/PERF only, same leak-gated class as `-SyntheticMic`):
        // substitute the AMBIENT source (`source:`, normally the Omi over BLE) with a
        // synthetic frame source that emits `.streaming` + real voiced Opus packets. This
        // lets the simulator drive the AMBIENT capture path end-to-end — a speech onset
        // opens a conversation with NO button tap, then the hero "Listening" tile, the
        // live transcript and the tap-through to the recording page all run for real. That
        // path had ZERO UI coverage before (only the phone-mic Record button did), which
        // is how the 2026-07-23 "records but can't open / no transcript" regression shipped.
        #if DEBUG || PERF_HARNESS
        let ambientSource: AudioFrameSource =
            ProcessInfo.processInfo.arguments.contains("-SyntheticOmi")
            ? SyntheticMicFrameSource(log: log)
            : dm
        #else
        let ambientSource: AudioFrameSource = dm
        #endif
        let mgr: CaptureManager
        if local {
            // "Just my phone" (track 20260705T1100): the SAME capture pipeline, but
            // finalize runs through the on-device brain — WhisperKit STT + Foundation
            // Models title/summary — and segments self-ack (durable = on this phone).
            // The STT reports download/load into `status` for the setup banner.
            let stt = WhisperKitSTT(status: status)
            localSTT = stt
            let backend = LocalBackend(baseDir: accountBinding?.root
                                           ?? CaptureWAL.documentsCaptures(),
                                       stt: stt,
                                       titler: systemTitler)
            mgr = CaptureManager(
                target: target, backend: backend, log: log, source: ambientSource,
                micSource: mic,
                attachToSourcesImmediately: false,
                liveTranscriber: liveFactory,
                liveTitler: systemTitler,
                // Production local mode: external OFF (nil) — the on-device title stands
                // offline. Only the DEBUG proof harness injects a scripted external here.
                liveTitleExternal: scriptedExternal,
                liveTitleBackoff: liveBackoff,
                localMode: true)
        } else {
            localSTT = nil
            mgr = CaptureManager(
                target: target, log: log, source: ambientSource,
                micSource: mic,
                attachToSourcesImmediately: false,
                liveTranscriber: liveFactory,
                // On-device Foundation Models stays the INSTANT placeholder + offline
                // fallback; the door refresh SHARPENS it externally on the backoff.
                liveTitler: systemTitler,
                // Phone-originated EXTERNAL live re-title (track 20260717T1500): the door
                // runs the whole-conversation history through Fireworks. Relay-aware, so
                // it works off-LAN; unreachable/old door → the on-device title stands.
                // (The DEBUG proof harness swaps in a scripted external.)
                liveTitleExternal: scriptedExternal ?? { captureId, history, seq in
                    try await DoorClient(target: target).liveTitle(
                        captureId: captureId, history: history, seq: seq)
                },
                liveTitleBackoff: liveBackoff)
        }
        #if DEBUG || PERF_HARNESS
        // The synthetic source has no hardware to ask permission for, and the simulator
        // test runner cannot drive the AVAudioApplication prompt — so use the manager's
        // EXISTING permission test hatch (the same one MeterLifecycleTests uses) to force
        // the granted branch. Only ever set under `-SyntheticMic`.
        if syntheticMic { mgr.micPermissionOverrideForTests = true }
        #endif
        #if DEBUG || PERF_HARNESS
        // PERF-GATE hook (`-StressChurn`, track 20260722T1244): interleave REAL write traffic
        // (segment append, drain ACK, status-poller card merge, finalize) with navigation so
        // the list rebuild is measured AFTER a command invalidated the read-model caches —
        // the CQRS hole every previous gate left open. Inert without the launch argument, and
        // compiled out of a plain Release build entirely.
        StressChurn.installIfRequested(manager: mgr)
        #endif
        // WHICH DEVICE this manager records from. Resolved HERE, at the composition root,
        // by the same Kit factory the background-restoration bootstrap uses — so both
        // capture-creation sites write the same device record and neither is asked to
        // discover an identity it does not possess. A blocked resolution writes no record
        // at all rather than a placeholder.
        // ASK WHAT IS RECORDING, not what is remembered. A phone-mic conversation made while
        // an Omi is paired is a HANDSET recording; attributing it to the Omi writes a false
        // recorder into the archive permanently. The manager HANDS IN what is recording (it
        // is the authority on that), so this closure has nothing to reach back for and
        // nothing to default — see `CaptureManager.captureDeviceContext`.
        mgr.captureDeviceContext = { recording in
            let binding = CaptureAccountScope.currentAccountBinding()
            return OmiRestorationComposition.resolveDeviceContext(
                binding: binding,
                // The ACCOUNT-SCOPED store answers which device is active, chosen only among
                // what the transport currently has attached (T5, S05). The legacy
                // device-global pairing is now an input to that store's migration, not the
                // answer itself.
                activeDevice: OmiRestorationComposition.activeExternalDevice(
                    binding: binding, attached: dm.saved),
                recording: recording)
        }
        // N7: WHICH ACCOUNT a gap-recovery outcome belongs to. `onGapRecoveryOutcome` is NOT
        // gated by the account-exposure close while `onState` IS, so an outcome can arrive
        // after the account door has shut. Pushing the scope the window opened under is what
        // lets `GapRecoveryRendering.decide` withhold it instead of rendering one person's
        // recording history into the next person's timeline.
        // AND IT FOLLOWS THE ACCOUNT (M3). Taking the scope once here — from a `let` captured
        // in `init` — went stale the moment the account changed: `DeviceManager` is a process
        // singleton that outlives this view tree, a launch while signed out pushed `nil`
        // forever, and a sign-out tears this tree down without rebuilding it. The manager
        // installs its own identity observer; there is nothing here to remember.
        // THE BINDING IS HANDED OVER, NOT RE-RESOLVED (review round 12, L12-3). This `init`
        // runs on every body pass of the view that builds `MainTabs`, and it already resolved
        // `accountBinding` above — a process-wide lock, an on-disk admission-registry read and
        // a cross-process widget publish. Passing what we have keeps that at one per pass.
        // `nil` here is not a claim that there is no account: it means we have nothing to hand
        // over, and the manager resolves it itself.
        dm.followAccountScopeChanges(startingFrom: accountBinding?.scope)
        dm.onGapRecoveryOutcome = { report in
            switch GapRecoveryRendering.decide(
                report, currentScope: CaptureAccountScope.currentAccountBinding()?.scope) {
            case .show(let line):
                log.info("gap recovery: \(line)")
            case .withheld(let reason):
                log.info("gap recovery: withheld — \(reason)")
            }
        }
        // Omi hardware button: a DOUBLE-click pauses/resumes the current recording — the
        // same action as the on-screen Pause. Fires only if the paired Omi firmware exposes
        // the button service (see DeviceManager.OmiUUID.buttonService).
        dm.onButtonDoubleClick = { [weak mgr] in Task { @MainActor in mgr?.togglePause() } }
        // Ambient-intelligence Tier-1 lane (track 20260710T2030 v3): OPT-IN default-NO
        // gate over the LIVE transcript (the SpeechAnalyzer preview already streaming —
        // no re-transcription) while recording, about every 10s. Wired only where the
        // OS has Foundation Models (the gate); the lane re-reads the user toggle per
        // call, so Settings flips apply immediately. A surfaced candidate posts a
        // local notification (Tier-3 preview slice).
        if let gate = makeSystemGate(agentName: {
            AmbientPrefs.agentName()
        }) {
            mgr.ambientLane = AmbientLane(
                gate: gate,
                isEnabled: { AmbientPrefs.enabled() },
                decisionLogURL: AmbientPrefs.decisionLogURL())
            // Tier 2: route the candidate through the door (lookup answers come from
            // the user's OWN memory — lore search + local compile) and notify with the
            // routed outcome. Door unreachable / phone-only tier → an honest local
            // notification of the raw moment (never silence, never a fake answer).
            mgr.onAmbientCandidate = { [weak mgr] candidate in
                guard let workBinding = accountBinding,
                      workBinding.isCurrent else { return }
                let window = mgr?.liveTranscript.displayText ?? ""
                let captureId = mgr?.active?.captureId ?? ""
                // OWNER GATE payload: when the window addresses the named agent,
                // ship the last ~10s of captured audio so the door can verify WHO
                // spoke (lore identify vs the confirmed enrolled corpus) before any
                // agent card is offered.
                let agentName = AmbientPrefs.agentName()
                let mentionsAgent = agentName.map {
                    !$0.isEmpty && (window.range(of: $0, options: .caseInsensitive) != nil
                        || candidate.utterance.range(of: $0, options: .caseInsensitive) != nil)
                } ?? false
                Task.detached(priority: .utility) {
                    var audioB64: String?
                    if mentionsAgent, !captureId.isEmpty {
                        let frames = LocalBackend.loadFrames(
                            captureId: captureId, baseDir: workBinding.root)
                        if !frames.isEmpty {
                            audioB64 = CaptureWAL.encodeSegment(Array(frames.suffix(500)))
                                .base64EncodedString()
                        }
                    }
                    let outcome: AmbientRouteOutcome?
                    if local {
                        outcome = nil   // phone-only tier: no door to route through
                    } else {
                        outcome = try? await DoorClient(target: target).ambientCandidate(
                            captureId: captureId,
                            utterance: candidate.utterance,
                            summary: candidate.summary,
                            confidence: candidate.confidence,
                            window: window,
                            windowAudioB64: audioB64)
                    }
                    guard workBinding.isCurrent else { return }
                    AmbientNotifier.post(candidate: candidate, outcome: outcome,
                                         captureId: captureId.isEmpty ? nil : captureId,
                                         binding: workBinding)
                }
            }
            // Skip the OS notification prompt under the screen-proof harness so it never
            // covers a screenshot (no effect on a normal launch). The shipping build asks
            // unconditionally — the harness suppression is compiled out entirely (leak gate).
            #if DEBUG || PERF_HARNESS
            if !ProcessInfo.processInfo.arguments.contains("-MainPreview") {
                AmbientNotifier.requestAuthorizationIfNeeded()
            }
            #else
            AmbientNotifier.requestAuthorizationIfNeeded()
            #endif
        }
        // Ship the on-device ambient GATE/CARD signal (redacted — DERIVED action +
        // outcome only, NEVER the utterance/window/seed) to the desktop door on the
        // drain cadence (track v3.3). Computer mode ONLY: the local-only tier has no
        // door, so the shipper is left nil and nothing ever ships. The shipper
        // self-gates on the ambient opt-in and is best-effort (never blocks capture).
        if !local {
            mgr.ambientSignalShipper = AmbientSignalShipper(
                decisionsURL: AmbientPrefs.decisionLogURL(),
                cardsURL: ActivityStore.cardsLogURL(besides: AmbientPrefs.decisionLogURL()),
                watermarkURL: AmbientPrefs.signalWatermarkURL(),
                isEnabled: { AmbientPrefs.enabled() },
                send: { records in try await DoorClient(target: target).ambientLog(records: records) })
        }
        // When a capture upload is rejected as token-expired (401), refresh the id_token
        // once / surface login — instead of the phone retry-looping with a dead token.
        mgr.onAuthExpired = { [weak remote] in Task { @MainActor in await remote?.handleAuthExpired() } }
        // Wire the interactive Live Activity buttons (App Intents) to this live manager.
        // The intent's perform() runs in the app process and routes through this broker.
        let router = TabRouter()
        // Land on the tab the person left, not the launch tab. Set BEFORE the router
        // becomes a `@StateObject`, so this is the tree's first selection rather than a
        // visible jump from Capture to wherever they were.
        router.selected = restored.placement.tab
        #if DEBUG
        // Screen-proof: `-Tab <capture|activity|chat|device>` selects the initial tab so
        // each screen can be screenshot without a tap (simctl can't tap the tab bar).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-Tab"), i + 1 < args.count,
           let t = AppTab(rawValue: args[i + 1]) {
            router.selected = t
        }
        #endif
        _router = StateObject(wrappedValue: router)
        // An accepted ambient card ([Run]) lands on the chat tab; ChatScreen consumes
        // the broker's pendingSeed and starts the seeded kiln conversation there.
        AmbientCardBroker.shared.onNavigate = { [weak router] in router?.selected = .chat }
        CaptureIntentBroker.shared.handler = { [weak mgr, weak router] action in
            guard let mgr else { return false }
            switch action {
            case .endCurrent:  return mgr.endCurrentConversation()
            case .togglePause: mgr.togglePause(); return true
            // Quick-start surfaces (Phase 5, decision #4): Action Button / Control
            // Center / Siri land here with the app foregrounded by the intent.
            case .startRecording:
                router?.selected = .capture
                mgr.startMicRecording()
                return true
            case .openChat:
                router?.selected = .chat
                return true
            case .askChooser:
                router?.showActionChooser = true
                return true
            }
        }
        _manager = StateObject(wrappedValue: mgr)
        // The extensible capture-source registry (track 20260628T1702): per-source
        // toggles + add-source (BT mic / Apple Watch). Its single ACTIVE source is
        // pushed onto the existing capture lifecycle via `selectCaptureSource`, so the
        // single-stream WAL path is unchanged.
        let reg = CaptureSourceRegistry(
            phoneMicAvailable: mgr.phoneMicAvailable,
            accountBinding: accountBinding,
            deviceManager: dm)
        // The registry drives the AMBIENT (Omi) capture kind only. The phone mic is a
        // MANUAL record source (the Record button) — a TRANSIENT Omi disconnect must NOT
        // auto-switch ambient capture to the phone mic NOR tear down the Omi's
        // auto-reconnect (selectCaptureSource(.phoneMic) calls source.stop(), which would
        // cancel the in-flight reconnect → the Omi never comes back = zero frames). So
        // only an Omi activation flows to selectCaptureSource; the Omi's on/off lifecycle
        // is owned by the enabled toggle below.
        reg.onActiveSourceChanged = { [weak mgr] kind in
            if kind == .omi { mgr?.selectCaptureSource(.omi) }
        }
        // The per-source ENABLED toggle owns the Omi's BLE link: off ⇒ drop + un-arm
        // auto-reconnect (truly leaves the capture surface); on ⇒ resume the connect flow.
        reg.onSourceEnabledChanged = { [weak dm] category, on in
            if category == .omi { dm?.setEnabled(on) }
        }
        // WHICH ROUTE, when the phone-mic path is really a Bluetooth recorder (T5, S01). The
        // registry owns the active source and is only built here, so the wiring lives here
        // rather than beside the rest of the capture composition. Without it, every
        // conversation made with a Bluetooth audio-route recorder is attributed to "Phone" —
        // the device the user connected never appears against its own recordings.
        mgr.activeAudioRoute = { [weak reg] in
            guard let reg,
                  let active = reg.activeSourceId,
                  let source = reg.sources.first(where: { $0.id == active }),
                  source.category == .bluetoothMic,
                  let uid = source.routeUID else { return nil }
            return (token: uid, displayName: source.displayName)
        }
        _sources = StateObject(wrappedValue: reg)
        if let accountBinding {
            let preferences = CaptureSettings.snapshot(
                binding: accountBinding)
            _ = mgr.installCapturePreferenceSnapshot(preferences)
            _ = reg.installCapturePreferenceSnapshot(preferences)
        }
    }

    var body: some View {
        // Prototype `bottomNav` (track 20260714T1800 §1, T1 20260715T1457): Capture →
        // Activity → Chat → Settings, Capture first. Settings is a first-class bottom-nav
        // tab now (Nick 2026-07-15, superseding the "Settings as a sheet" decision);
        // Device management still lives INSIDE Settings.
        TabView(selection: $router.selected) {
            NavigationStack {
                VStack(spacing: 0) {
                    // Phone tier: the model-download banner sits above capture so the
                    // first recording's ~150 MB fetch is visible, not a silent hang.
                    if local, let text = brainStatus.bannerText {
                        brainSetupBanner(text)
                    }
                    CaptureScreen(device: device, manager: manager, sources: sources,
                                  target: target, local: local,
                                  reopenCaptureId: $restoreCaptureId,
                                  openCaptureId: $openCaptureId)
                }
                // The screen renders its OWN "Capture" header (title + status + search),
                // matching the prototype — so the nav bar carries no second large
                // "Capture" title and no header gear (Settings is a tab now).
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label(AppTab.capture.label, systemImage: AppTab.capture.systemImage) }
            .tag(TabRouter.Tab.capture)

            // Activity is FIRST-CLASS (§6): the same destination CaptureScreen
            // used to bury behind a NavigationLink, one tap from anywhere.
            NavigationStack {
                // Deferred off the first-frame path (TARGET 2); still builds the instant
                // Activity is selected (deep link / intent), so routing is unaffected.
                //
                // DELIBERATELY *NOT* narrowed to `router.selected == .activity` (track
                // `residual_on_main_actor_work`): flipping this whole branch between
                // `ActivityView` and `Color.clear` changes the branch's VIEW IDENTITY, so
                // leaving the tab would TEAR DOWN `ActivityView` — destroying its
                // `@StateObject ActivityRecapModel`, its scroll position and Today|This week
                // selection, popping any pushed `StatsView`, and dropping its
                // `.foundryxConversationFinalized` observer. Chat and Settings below stay
                // mounted for exactly this reason. The expense was never the VIEW existing —
                // it was `recapConversationPool()`, an O(N) library scan, being evaluated as
                // an eager argument on every body pass. That is fixed at the seam instead:
                // it is passed as a PROVIDER, invoked only when the recap model actually
                // rebuilds (which also fixes a latent bug — an eagerly-passed array was
                // captured into `@StateObject` on the first body pass, possibly before
                // hydration, freezing an empty pool forever).
                if deferredTabsReady || router.selected == .activity {
                    ActivityView(
                        decisionLogURL: AmbientPrefs.decisionLogURL(),
                        recapPoolProvider: { manager.recapConversationPool() },
                        onOpenChat: { seed in AmbientCardBroker.shared.run(seed: seed) },
                        local: local
                    )
                    .toolbar {
                        // LAZY destination: `NavigationLink`'s destination is built eagerly
                        // with the link itself, so `StatsView(summary:)` was constructed on
                        // every body pass for a screen nobody had opened. To be precise, that
                        // construction is CHEAP — `statsSummary` is a stored `@Published`
                        // value, not a computed scan — so this is hygiene on the render path
                        // (and insurance against the destination growing costlier), not a
                        // measured win like the recap pool above.
                        NavigationLink("Stats") { LazyView { StatsView(summary: manager.statsSummary) } }
                    }
                } else {
                    Color.clear
                }
            }
            .tabItem { Label(AppTab.activity.label, systemImage: AppTab.activity.systemImage) }
            .tag(TabRouter.Tab.activity)

            NavigationStack {
                Group {
                    if deferredTabsReady || router.selected == .chat {
                        if local {
                            LocalChatScreen(baseDir: CaptureWAL.documentsCaptures(), remote: remote)
                        } else if let accountBinding {
                            ChatScreen(
                                target: target,
                                store: chats,
                                accountBinding: accountBinding,
                                log: log,
                                showingChatList: $chatListOpen)
                        } else {
                            Color.clear
                        }
                    } else {
                        Color.clear
                    }
                }
                .navigationTitle("Solleva")
            }
            .tabItem { Label(AppTab.chat.label, systemImage: AppTab.chat.systemImage) }
            .tag(TabRouter.Tab.chat)

            // Settings as a first-class bottom-nav tab (Nick 2026-07-15, T1
            // 20260715T1457 — supersedes the sheet). Keeps every settings row; Device
            // management lives HERE as a "Devices & connections" page (one management
            // home, not a competing Device tab) — connection STATUS stays glanceable on
            // the Capture home.
            NavigationStack {
                if deferredTabsReady || router.selected == .settings {
                    SettingsScreen(brains: brains, remote: remote,
                                   device: device, manager: manager, sources: sources,
                                   vaultFunnel: vaultFunnel, accountDeletion: accountDeletion)
                        .navigationTitle(SettingsSheetPresentation.title)
                        .navigationBarTitleDisplayMode(.inline)
                } else {
                    Color.clear
                }
            }
            .tabItem { Label(AppTab.settings.label, systemImage: AppTab.settings.systemImage) }
            .tag(TabRouter.Tab.settings)
        }
        // Flip the deferral flag right AFTER first draw so Activity/Chat/Settings build
        // off the launch critical path (TARGET 2). `.task` runs post-appearance; a tab
        // selected before this fires still builds via the per-tab `router.selected` gate.
        .task { deferredTabsReady = true }
        // First-run onboarding (runs ONCE after the first sign-in). Presented here rather
        // than in RootView because the ending drives the REAL capture path: the first
        // voice note is an actual note in the actual library, and "Set up my Vault" is
        // the entry to cell provisioning — previously reachable only by digging through
        // Settings.
        #if DEBUG || PERF_HARNESS
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-Onboarding") { forcedOnboarding = true }
        }
        #endif
        .fullScreenCover(isPresented: Binding(
            get: { showingOnboarding || forcedOnboarding },
            set: { if !$0 { showingOnboarding = false; forcedOnboarding = false } })) {
            OnboardingFlowView(baseDir: CaptureWAL.documentsCaptures(),
                               skipWelcome: onboardingSkipsWelcome,
                               manager: manager,
                               brains: brains,
                               onChooseVault: { vaultFunnel.beginSetup() }) {
                showingOnboarding = false
            }
        }
        // The Action Button's "Ask me" chooser (Phase 5, decision #4).
        .confirmationDialog("Solleva", isPresented: $router.showActionChooser) {
                Button("Start a note") {
                router.selected = .capture
                manager.startMicRecording()
            }
            Button("Open chat") { router.selected = .chat }
        }
        .onOpenURL { url in
            if url.scheme == "foundryx", url.host == "capture" {
                router.selected = .capture
            }
        }
        // Keep the registry's Omi liveness in step with the BLE link from a SINGLE,
        // always-mounted place (not just the Device tab's onChange, which doesn't fire
        // unless that tab is on screen). This is what makes the active-source policy
        // correct — so toggling the Omi off actually hands off + drops it, and a transient
        // reconnect is reflected — regardless of which tab is visible.
        .onChange(of: device.connectionState) { _ in syncOmiConnection() }
        // iOS may retire Speech's live-result publisher while the process is suspended
        // even though the capture/WAL session remains open. Re-attach it from this single,
        // always-mounted owner on foreground; the manager carries the already-rendered
        // words into the replacement so RecordingScreen never restores as a blank shell.
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                liveTranscriptionWasBackgrounded = true
            } else if phase == .active, liveTranscriptionWasBackgrounded {
                liveTranscriptionWasBackgrounded = false
                manager.restoreLiveTranscriptionAfterForeground()
            }
            // Leaving the app is the last honest moment to write the place down. Every
            // individual change is written as it happens (below) — this is the backstop for
            // anything that changed inside a surface we do not observe.
            if phase != .active { savePlacement() }
        }
        // CONTENT-FREE usage: which surface the user is on. The tab's rawValue is already
        // a safe enum token (capture/activity/chat/settings) — never any content.
        .onChange(of: router.selected) { tab in
            UsageHook.page(tab.rawValue)
            // A deliberate move off the Capture tab abandons a restore that has not landed
            // yet (the push waits for the library to hydrate); nobody wants a transcript
            // arriving under them a second after they walked away from it.
            if tab != .capture { restoreCaptureId = nil }
            savePlacement()
        }
        .onChange(of: openCaptureId) { _ in savePlacement() }
        .onChange(of: chatListOpen) { _ in savePlacement() }
        .onChange(of: chats.activeId) { _ in savePlacement() }
        // Land on the chat tab whenever the card broker carries a seed (an accepted
        // card's [Run]) OR a composer prefill (the Actions face's "Act on it in
        // chat"). Driven off the PUBLISHED values against the live @StateObject
        // router — the init-time onNavigate closure captures the router created in
        // THAT body evaluation, which a re-evaluated init discards, silently
        // stranding navigation on the origin tab.
        .onReceive(AmbientCardBroker.shared.$pendingSeed) { seed in
            if seed != nil { router.selected = .chat }
        }
        .onReceive(AmbientCardBroker.shared.$pendingPrefill) { seed in
            if seed != nil { router.selected = .chat }
        }
        // An already-acted action's "Continue in chat →" (EXT2).
        .onReceive(AmbientCardBroker.shared.$pendingOpenChatId) { id in
            if id != nil { router.selected = .chat }
        }
        .onAppear {
            // Only the StateObject SwiftUI actually accepted may claim the process-shared
            // audio source. MainTabs.init can run speculatively on ordinary parent redraws;
            // eager candidates used to steal these callbacks and replay `.streaming`,
            // minting one segmentless capture id per discarded manager.
            let exposureCoordinator =
                FoundryXAppDelegate.accountExposureCoordinator
            manager.registerAccountExposures(with: exposureCoordinator)
            sources.registerAccountExposure(with: exposureCoordinator)
            manager.activateSourceOwnership()
            // After a background-restoration launch the Omi may ALREADY be streaming.
            // Replay only after the accepted owner has claimed the callbacks.
            device.replayState()
            syncOmiConnection()
            // EXT2: let action↔chat links validate against the LIVE chat store
            // (dead links are pruned at render, never routed to). Weak — the
            // hook must not outlive a re-mounted tab tree's store.
            AmbientCardBroker.shared.isChatAlive = { [weak chats] id in
                chats?.conversation(id) != nil
            }
            // The last half of the place resolution: the chat the saved place named. Asked
            // of the LIVE store (already loaded by now) rather than the file, so init did
            // not have to read the chat list a second time. `ChatConversationStore` re-points
            // `activeId` off a deleted chat by itself — this exists so we SAY so instead of
            // silently landing somewhere else.
            if placementNotice == nil, let savedChatId, chats.conversation(savedChatId) == nil {
                placementNotice = AppPlacementFallback.chatGone.notice
            }
            // From here on, changes are the person's, so they are safe to write down.
            placementRestored = true
            savePlacement()
            #if DEBUG
            // Screen-proof: land on the Settings tab on launch so it can be screenshot.
            if ProcessInfo.processInfo.arguments.contains("-OpenSettings") { router.selected = .settings }
            // Pill-proof: `-CapturePhase <phase>` seeds a throwaway active session (so the
            // recording pill renders) and lands on a non-capture tab (where it shows).
            if ProcessInfo.processInfo.arguments.contains("-CapturePhase") {
                manager.seedPreviewSession(
                    target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "local"))
                router.selected = .activity
            }
            #endif
        }
        // Start the model fetch when the phone tier appears — visible during
        // first-run exploration rather than silent on the first "stop recording".
        // A short grace + view-lifetime cancellation (.task, not onAppear's fire-
        // and-forget) keeps a TRANSIENT phone-tier mount — a straight-in launch
        // while the computer brain resolves (track 20260715T1502) — from kicking
        // a ~150 MB model download on every launch; a real phone-tier stay still
        // prewarms after the grace, and the first finalize loads regardless.
        .task {
            guard local, let stt = localSTT else { return }
            #if DEBUG
            // The `-BrainSetupFailed` screen proof seeds the FAILED state; a real prewarm
            // would immediately open a new attempt and paint over it. Harness-only.
            if ProcessInfo.processInfo.arguments.contains("-BrainSetupFailed") { return }
            #endif
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await stt.prewarm()
        }
        // The recording pill (track 20260713T0903): leaving the capture tab never
        // stops a recording — a quiet pill shows the ticking elapsed time, taps back
        // to the instrument, and can end the conversation right here.
        .overlay(alignment: .top) {
            // Capture-tab suppression (track 20260717T0600 T1 follow-up): on the Capture
            // tab the hero slot IS the live recording tile, so the pill would be a second,
            // redundant representation of the same recording. Call-site guard only — the
            // shared visibility rule (and the pill on every other tab) is untouched.
            if router.selected != .capture,
               RecordingPillState.visible(
                recordingActive: manager.active != nil || manager.isRecordingMic,
                onCaptureTab: router.selected == .capture,
                minimized: manager.recordingScreenMinimized) {
                RecordingPill(manager: manager) {
                    // Re-present the full-screen surface AND keep the historical
                    // navigate-to-capture (the recording lives on the capture tab).
                    manager.restoreRecordingScreen()
                    router.selected = .capture
                }
            }
        }
        // Why your place is not the place you left, when it isn't.
        .overlay(alignment: .top) {
            if let placementNotice { placementNoticeBanner(placementNotice) }
        }
        // The opt-in performance overlay (track 20260717T0600 T3): perf-span/hang pills,
        // gated behind Settings → DIAGNOSTICS (DEFAULT OFF); renders nothing when off and
        // never blocks taps to content underneath. Layered above the recording pill.
        .overlay(alignment: .top) { PerfOverlayView() }
        // A tapped answer notification opens the full answer surface
        // (features/ambient-answer-loop.feature).
        .sheet(isPresented: Binding(
            get: { broker.pendingAnswer != nil },
            set: { if !$0 { broker.pendingAnswer = nil } })) {
            if let answer = broker.pendingAnswer {
                AnswerSurfaceView(answer: answer, onDone: { broker.pendingAnswer = nil })
            }
        }
    }

    /// The "setting up your private on-device brain" banner (model download UX).
    /// Once setup has FAILED (a stalled download hitting its stall timeout — track
    /// 20260722T1244) the spinner is replaced by an honest error + a working "Try
    /// again", so the banner can never be an indefinite spinner.
    @ViewBuilder private func brainSetupBanner(_ text: String) -> some View {
        HStack(spacing: GrainSpacing.x2) {
            if brainStatus.isFailed {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(GrainColor.textMuted)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
            }
            Text(text).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            Spacer()
            if let retry = brainStatus.retryAction {
                // This is the ONE control that unwedges a user whose brain setup failed,
                // so it gets a real 44pt target (S7) — a bare `.caption` Text in a
                // `.plain` button is ~11pt tall and easy to miss.
                Button(action: retry) {
                    Text(brainStatus.retryLabel)
                        .grainTextStyle(.caption)
                        .padding(.horizontal, GrainSpacing.x2)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(GrainColor.textMain)
                .accessibilityIdentifier("brain-setup-retry")
            }
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.vertical, GrainSpacing.x2)
        .background(GrainColor.surfaceElevated)
        .overlay(alignment: .bottom) { Rectangle().fill(GrainColor.borderHairline).frame(height: 1) }
        // The banner is an identifiable REGION, so the simulator proof can tell the
        // failed rendition (warning glyph + reason + Try again) from the spinner one.
        // `.contain` keeps the text and the retry button individually queryable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(brainStatus.isFailed ? "brain-setup-banner-failed"
                                                      : "brain-setup-banner-preparing")
    }

    /// Write down where the person is, so coming back continues instead of restarting.
    ///
    /// Account-scoped and generation-stamped: a place is written only under the binding
    /// this tab tree started with, and only while that binding is still the current one —
    /// so a write racing an account switch can never leave one person's place in another's
    /// folder. Unchanged places are dropped by the store, so the frequent publishers wired
    /// to this cost nothing.
    private func savePlacement() {
        guard placementRestored,
              let accountBinding, accountBinding.isCurrent else { return }
        AppPlacementStore.save(
            AppPlacement(tab: router.selected,
                         openCaptureId: openCaptureId,
                         openChatId: chats.activeId.isEmpty ? nil : chats.activeId,
                         chatListOpen: chatListOpen,
                         generation: accountBinding.generation,
                         doorTier: !local),
            inAccountRoot: accountBinding.root)
    }

    /// The one line the person gets when their place could NOT be kept — the conversation
    /// was deleted, the computer is unreachable, this is a different account. It names what
    /// is gone instead of quietly landing them somewhere and letting them wonder. Dismissed
    /// by tapping, and by itself after a few seconds.
    @ViewBuilder private func placementNoticeBanner(_ text: String) -> some View {
        Text(text)
            .grainTextStyle(.caption)
            .foregroundStyle(GrainColor.textMain)
            .padding(.horizontal, GrainSpacing.x3)
            .padding(.vertical, GrainSpacing.x2)
            .background(Capsule().fill(GrainColor.surfaceElevated))
            .overlay(Capsule().strokeBorder(GrainColor.border, lineWidth: 1))
            .padding(.top, GrainSpacing.x1)
            .padding(.horizontal, GrainSpacing.x4)
            .accessibilityIdentifier("placement-notice")
            .onTapGesture { placementNotice = nil }
            .task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                placementNotice = nil
            }
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Mirror the live BLE connection state onto the registry's Omi row.
    private func syncOmiConnection() {
        if case .connected = device.connectionState { sources.setOmiConnected(true) }
        else { sources.setOmiConnected(false) }
    }
}

/// The quiet recording pill: mini ring + ticking elapsed + End. Visible only
/// while recording away from the capture tab (RecordingPillState); tapping the
/// body returns to the instrument, End finalizes through the normal path.
private struct RecordingPill: View {
    @ObservedObject var manager: CaptureManager
    let onOpen: () -> Void

    var body: some View {
        if manager.active != nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let phase = displayedPhase()
                let presentation = RecordingPillPresentation.make(from: phase)

                HStack(spacing: GrainSpacing.x2) {
                    RecordingRingView(meter: manager.meter, paused: phase == .paused)
                        .frame(width: 22, height: 22)
                    HStack(spacing: GrainSpacing.x1) {
                        Circle()
                            .fill(presentation.tone.recordingPillColor)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(presentation.word)
                            .grainTextStyle(.caption)
                            .foregroundStyle(presentation.tone.recordingPillColor)
                    }
                    SessionElapsedLabel(clock: manager.recordingClock)
                    Button("End") { _ = manager.endCurrentConversation() }
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.dangerRed)
                        .buttonStyle(.plain)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(presentation.word) capture")
                .accessibilityIdentifier("recording-pill")
            }
            .padding(.horizontal, GrainSpacing.x3)
            .padding(.vertical, GrainSpacing.x1)
            .background(Capsule().fill(GrainColor.surfaceElevated))
            .overlay(Capsule().strokeBorder(GrainColor.border, lineWidth: 1))
            .onTapGesture { onOpen() }
            .padding(.top, GrainSpacing.x1)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func displayedPhase() -> CaptureActivityPhase {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-CapturePhase"),
           arguments.indices.contains(index + 1) {
            switch arguments[index + 1].lowercased() {
            case "listening": return .idle
            case "recording": return .recordingActive
            case "paused": return .paused
            default: break
            }
        }
        #endif

        // CaptureManager records voice instants using Apple's reference-date clock;
        // normalize that signal before comparing it with the requested Unix `now`.
        let lastVoicedAt = manager.lastVoicedInstant().map {
            Date(timeIntervalSinceReferenceDate: $0).timeIntervalSince1970
        }
        return CaptureLiveStatus.phase(
            hasActiveSession: manager.active != nil,
            isPaused: manager.isPaused,
            lastVoicedAt: lastVoicedAt,
            now: Date().timeIntervalSince1970)
    }
}

private extension CaptureIndicatorTint {
    var recordingPillColor: Color {
        switch self {
        case .recording: return GrainColor.dangerRed
        case .paused: return GrainColor.forgeBlue
        case .neutral: return GrainColor.textMuted
        }
    }
}

// `LazyView` — the deferred destination wrapper both this file's Stats link and the
// conversation row's detail push depend on — now lives in `Sources/FoundryXKit/LazyView.swift`,
// which the app target compiles into this same module. It moved so that a test can CONSTRUCT
// it and prove it defers, instead of a gate searching this file for the string "LazyView"
// (review round 13, M13-2: an eager impostor of the same name survived every gate).
