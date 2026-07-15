import SwiftUI
import Grain

// M5 R1b: login-gated, remote-managed. You must sign in (Google/Microsoft) and
// have a designated desktop host before entering the app — there are no manual
// door controls; the connection is always the resolved remote door over the
// blind relay, authenticated by your sign-in id_token (the door verifies it).
struct RootView: View {
    @StateObject private var remote = RemoteSession()
    @State private var showingAccount = false
    // On a FRESH launch, let the branded sign-in screen sit for ~2s before
    // auto-advancing into the app (so an already-signed-in user still sees it).
    // This .task runs once at launch; foregrounding an already-open app does NOT
    // re-run it, so we never bounce back to the gate mid-session.
    @State private var splashElapsed = false
    @State private var showingOnboarding = false
    /// B2 (track 20260714T1800): the persona welcome, ONCE post-sign-in, on its
    /// own flag — established installs (onboarding migrated to "completed") still
    /// see it once after the update; "Set up later" dismisses it forever.
    @State private var showingWelcome = false
    /// T5 (track 20260715T1502): once the connect-welcome gate's action fires, the
    /// established user has entered — flips the gate off so the app opens and the
    /// welcome never repeats.
    @State private var enteredApp = false

    @StateObject private var brains = BrainStore()

    /// The Vault activation funnel (track T-IOS-FUNNEL): paid-intent trigger → browser
    /// hand-off → server reconciliation → live Vault. Presented over the app whenever its
    /// state leaves `.idle`; reconciled on every foreground so a dismissed browser still
    /// completes. The entitlement router (`vaultFunnel.intent`) is what Vault-only actions
    /// call to route to the trigger (Vault off) or straight through (Vault live).
    @StateObject private var vaultFunnel = VaultFunnelModel.live()
    /// In-app account deletion (track T-STOREFRONT) — Apple-required, three scopes.
    @StateObject private var accountDeletion = AccountDeletionModel.live()
    @Environment(\.scenePhase) private var scenePhase

    /// T5: an established, signed-in, non-opted-out user sees the persona welcome AS
    /// the post-sign-in connect gate (with live status) until they enter the app.
    /// False for a signed-out user, a fresh install (not yet onboarded), an opted-out
    /// user, and after entry — so every other entry path is untouched.
    private var connectWelcomeActive: Bool {
        remote.email != nil
            && !WelcomePrefs.letStraightIn()
            && OnboardingPrefs.completed
            && !enteredApp
    }

    /// T5: the live connection line for the connect-welcome pill, from remote.status.
    private var connectionNote: WelcomeConnectStatus? {
        switch remote.status {
        case .resolving:
            return WelcomeConnectStatus(text: "Connecting to your computer…", settled: false)
        case .connected:
            let suffix = remote.email.map { " · \($0)" } ?? ""
            return WelcomeConnectStatus(text: "Connected" + suffix, settled: true)
        case .noHost:
            return WelcomeConnectStatus(text: "On your phone", settled: true)
        case .error:
            return WelcomeConnectStatus(text: "Couldn't reach your computer", settled: false)
        default:
            return nil
        }
    }

    /// T5: the connect-welcome's action — enter the app exactly once. Marking it seen
    /// FIRST guarantees presentFirstRunSurfacesIfNeeded() (and the dest onChange) can
    /// never re-present the legacy post-entry welcome (AC4).
    private func enterApp() {
        WelcomePrefs.markSeen()
        enteredApp = true
        splashElapsed = true
        presentFirstRunSurfacesIfNeeded()
    }

    var body: some View {
        // DEV-only visual harness: `-WelcomePreview` launch arg shows the persona
        // welcome directly (chooser flips expert/individual/firm), bypassing auth
        // so the design can be screenshot-verified in the simulator. No effect in
        // normal launches.
        if ProcessInfo.processInfo.arguments.contains("-WelcomePreview") {
            return AnyView(PersonaWelcomeStep(onStart: {}, onSkip: {}))
        }
        // DEV-only visual harness: `-MainPreview` mounts the real tabs in phone-only
        // mode (no auth, no door) over the demo cards DemoSeed dropped on disk, so every
        // screen can be screenshot-verified against the prototype. No effect normally.
        if ProcessInfo.processInfo.arguments.contains("-MainPreview") {
            return AnyView(MainTabs(
                target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "local"),
                remote: remote, brains: brains, local: true,
                vaultFunnel: vaultFunnel, accountDeletion: accountDeletion, showingAccount: .constant(false)))
        }
        // DEV-only: `-Screen answer` mounts the answer/decision-brief with demo data
        // (no manager needed) for screenshot-verification.
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
        let dest = RootGate.destination(signedIn: remote.email != nil,
                                        splashElapsed: splashElapsed,
                                        brain: brains.choice,
                                        hostResolved: remote.makeDoorTarget() != nil,
                                        letStraightIn: WelcomePrefs.letStraightIn())
        return AnyView(bodyContent(dest))
    }

    @ViewBuilder private func bodyContent(_ dest: RootDestination) -> some View {
        Group {
            switch dest {
            case .signInGate:
                // T5 (track 20260715T1502): an established, non-opted-out user meets
                // the cool persona welcome — carrying the live connection status — as
                // the connect gate, instead of the bare SignInView. "Take me in" enters;
                // "Skip the welcome" persists the opt-out and enters.
                if connectWelcomeActive {
                    PersonaWelcomeStep(
                        onStart: enterApp,
                        onSkip: { WelcomePrefs.setLetStraightIn(true); enterApp() },
                        connect: connectionNote)
                } else {
                    // The forced identity login (track 20260705T1100 decision #5) +
                    // the branded launch splash.
                    SignInView(remote: remote, onDone: { }, dismissable: false)
                }
            case .computerBrain:
                if let target = remote.makeDoorTarget() {
                    MainTabs(target: target, remote: remote, brains: brains, local: false,
                             vaultFunnel: vaultFunnel, accountDeletion: accountDeletion, showingAccount: $showingAccount)
                        // A resolved-host change OR a refreshed bearer (after a token-expiry
                        // re-auth) rebuilds the tabs (+ their clients) so every door request
                        // uses the fresh id_token — never a stale, expired one.
                        .id((target.relay?.tunnelId ?? "remote") + "#" + target.bearer.suffix(12))
                        .sheet(isPresented: $showingAccount) {
                            SignInView(remote: remote) { showingAccount = false }
                        }
                }
            case .phoneBrain:
                // The phone-only tier: whole without a brain (zero content egress).
                MainTabs(target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!,
                                            bearer: "local"),
                         remote: remote, brains: brains, local: true,
                         vaultFunnel: vaultFunnel, accountDeletion: accountDeletion, showingAccount: $showingAccount)
                    .id("local-brain")
                    .sheet(isPresented: $showingAccount) {
                        SignInView(remote: remote) { showingAccount = false }
                    }
            }
        }
        // The Vault funnel rides over every destination: a paid-intent trigger, the browser
        // hand-off, and the durable return states. Dismisses to `.idle` (back to the app).
        .fullScreenCover(isPresented: Binding(
            get: { vaultFunnel.state != .idle },
            set: { if !$0 { vaultFunnel.dismiss() } })) {
            VaultFunnelView(model: vaultFunnel)
        }
        // Server reconciliation is the mechanism (design law): reconcile entitlement on every
        // foreground so a checkout finished/abandoned in the browser still resolves. Keep the
        // id_token box fresh for the reconcile/checkout Bearer.
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                VaultAuthTokenBox.shared.token = remote.idToken
                // Refresh the App Store storefront (T-STOREFRONT) so the purchase gate reflects
                // the current country before the funnel or the Settings Vault row is shown.
                Task { await VaultStorefrontBox.shared.refresh() }
                Task { await vaultFunnel.reconcileOnForeground() }
            }
        }
        .onChange(of: remote.idToken) { VaultAuthTokenBox.shared.token = $0 }
        // The return deep link is convenience only (it triggers an immediate reconcile).
        .onOpenURL { url in
            if url.scheme == "foundryx", url.host == "vault" {
                Task { await vaultFunnel.handleReturn(url: url) }
            }
        }
        .task { await remote.restore() }
        .task { await VaultStorefrontBox.shared.refresh() }
        .task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // T5 (track 20260715T1502): while the persona welcome IS the connect
            // gate (established, non-opted-out user), do NOT auto-advance — the
            // welcome's own action (enterApp) advances instead, so it's seen once.
            guard !connectWelcomeActive else { return }
            splashElapsed = true
            // Already signed in from a restored session: the destination never
            // *changes*, so check the first-run gate here too. Existing installs
            // (any recordings on disk) are migrated to "onboarded" silently.
            if remote.email != nil { presentFirstRunSurfacesIfNeeded() }
        }
        // First-run onboarding (runs ONCE, after the first sign-in): teach the owner's
        // voice + the ambient opt-in. Dismissing counts as done — never re-prompts;
        // both steps stay reachable from Settings. B2: migration suppresses ONLY
        // that onboarding — the persona welcome rides its own foundryx.welcome.seen
        // flag and still shows once for established installs.
        .onChange(of: dest) { d in
            if d != .signInGate { presentFirstRunSurfacesIfNeeded() }
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingFlowView(baseDir: CaptureWAL.documentsCaptures()) {
                showingOnboarding = false
            }
        }
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

    /// The post-sign-in first-run ladder (B2): migrate, then EITHER the full
    /// onboarding flow (fresh installs — it opens with the welcome) OR the
    /// standalone persona welcome (established installs that haven't seen it).
    private func presentFirstRunSurfacesIfNeeded() {
        OnboardingPrefs.migrateIfPriorUse(baseDir: CaptureWAL.documentsCaptures())
        // Honor "take me straight in" — no welcome ceremony when the user turned it off.
        if WelcomePrefs.letStraightIn() { return }
        let onboardingWillPresent =
            OnboardingGate.shouldPresent(signedIn: true, completed: OnboardingPrefs.completed)
        if onboardingWillPresent {
            showingOnboarding = true
        } else if WelcomeGate.shouldPresent(signedIn: true,
                                            onboardingWillPresent: false,
                                            welcomeSeen: WelcomePrefs.seen()) {
            showingWelcome = true
        }
    }
}

/// Routes intent-driven navigation (Action Button / Siri / Control Center) onto
/// the tab bar from anywhere in the process (track 20260705T1100, Phase 5).
/// The tab set IS the tested AppTab presentation (track 20260714T1800 §1, T1
/// 20260715T1457): Capture → Activity → Chat → Settings, Capture first.
@MainActor
final class TabRouter: ObservableObject {
    typealias Tab = AppTab
    @Published var selected: Tab = AppTab.launch
    @Published var showActionChooser = false
}

/// Owns the ONE DeviceManager + CaptureManager so Capture + Device tabs share a
/// single BLE link + capture pipeline. All tabs talk to the resolved remote door
/// `target` (relay tunnel + id_token bearer). Chat is independent.
private struct MainTabs: View {
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

    @StateObject private var device: DeviceManager
    @StateObject private var battery: BatteryMonitor
    @StateObject private var manager: CaptureManager
    @StateObject private var sources: CaptureSourceRegistry
    @StateObject private var log: DoorLog
    // The durable, resumable chat conversation list — owned here so it persists across
    // tab switches and app foregrounding (its own Application Support JSON file).
    @StateObject private var chats = ChatConversationStore(storageURL: ChatConversationStore.defaultStorageURL())
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

    init(target: DoorTarget, remote: RemoteSession, brains: BrainStore, local: Bool,
         vaultFunnel: VaultFunnelModel, accountDeletion: AccountDeletionModel,
         showingAccount: Binding<Bool>) {
        self.target = target
        self.remote = remote
        self.brains = brains
        self.local = local
        self.vaultFunnel = vaultFunnel
        self.accountDeletion = accountDeletion
        _showingAccount = showingAccount
        let log = DoorLog()
        // Ship the phone's BLE/audio/capture/chat log to the relay diag sink so
        // it's observable server-side (no copying logs off the device).
        log.setRemoteSink(RemoteConfig.fromBundle()?.gatewayHTTPURL.appendingPathComponent("diag/log"))
        let dm = DeviceManager(log: log)
        _log = StateObject(wrappedValue: log)
        _device = StateObject(wrappedValue: dm)
        _battery = StateObject(wrappedValue: BatteryMonitor())
        // Live on-device transcription preview (Feature 1). The factory builds the
        // SpeechAnalyzer transcriber on iOS 26+, falling back to SFSpeechRecognizer on
        // iOS 16–25; it's additive + ephemeral (Kiln stays authoritative).
        let status = LocalBrainStatus()
        _brainStatus = StateObject(wrappedValue: status)
        let mgr: CaptureManager
        if local {
            // "Just my phone" (track 20260705T1100): the SAME capture pipeline, but
            // finalize runs through the on-device brain — WhisperKit STT + Foundation
            // Models title/summary — and segments self-ack (durable = on this phone).
            // The STT reports download/load into `status` for the setup banner.
            let stt = WhisperKitSTT(status: status)
            localSTT = stt
            let backend = LocalBackend(baseDir: CaptureWAL.documentsCaptures(),
                                       stt: stt,
                                       titler: makeSystemTitler())
            mgr = CaptureManager(
                target: target, backend: backend, log: log, source: dm,
                micSource: MicFrameSource(log: log),
                liveTranscriber: LiveTranscription.defaultFactory(),
                localMode: true)
        } else {
            localSTT = nil
            mgr = CaptureManager(
                target: target, log: log, source: dm,
                // The phone's own mic as a second capture source (Record button when the
                // Omi is disconnected) — flows through the identical Opus/WAL/finalize path.
                micSource: MicFrameSource(log: log),
                liveTranscriber: LiveTranscription.defaultFactory())
        }
        // Ambient-intelligence Tier-1 lane (track 20260710T2030 v3): OPT-IN default-NO
        // gate over the LIVE transcript (the SpeechAnalyzer preview already streaming —
        // no re-transcription) while recording, about every 10s. Wired only where the
        // OS has Foundation Models (the gate); the lane re-reads the user toggle per
        // call, so Settings flips apply immediately. A surfaced candidate posts a
        // local notification (Tier-3 preview slice).
        if let gate = makeSystemGate(agentName: {
            UserDefaults.standard.string(forKey: AmbientPrefs.agentNameKey)
        }) {
            mgr.ambientLane = AmbientLane(
                gate: gate,
                isEnabled: { UserDefaults.standard.bool(forKey: AmbientPrefs.enabledKey) },
                decisionLogURL: AmbientPrefs.decisionLogURL())
            // Tier 2: route the candidate through the door (lookup answers come from
            // the user's OWN memory — lore search + local compile) and notify with the
            // routed outcome. Door unreachable / phone-only tier → an honest local
            // notification of the raw moment (never silence, never a fake answer).
            mgr.onAmbientCandidate = { [weak mgr] candidate in
                let window = mgr?.liveTranscript.displayText ?? ""
                let captureId = mgr?.active?.captureId ?? ""
                // OWNER GATE payload: when the window addresses the named agent,
                // ship the last ~10s of captured audio so the door can verify WHO
                // spoke (lore identify vs the confirmed enrolled corpus) before any
                // agent card is offered.
                let agentName = UserDefaults.standard.string(forKey: AmbientPrefs.agentNameKey)
                let mentionsAgent = agentName.map {
                    !$0.isEmpty && (window.range(of: $0, options: .caseInsensitive) != nil
                        || candidate.utterance.range(of: $0, options: .caseInsensitive) != nil)
                } ?? false
                Task.detached(priority: .utility) {
                    var audioB64: String?
                    if mentionsAgent, !captureId.isEmpty {
                        let frames = LocalBackend.loadFrames(
                            captureId: captureId, baseDir: CaptureWAL.documentsCaptures())
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
                    AmbientNotifier.post(candidate: candidate, outcome: outcome,
                                         captureId: captureId.isEmpty ? nil : captureId)
                }
            }
            // Skip the OS notification prompt under the screen-proof harness so it never
            // covers a screenshot (no effect on a normal launch).
            if !ProcessInfo.processInfo.arguments.contains("-MainPreview") {
                AmbientNotifier.requestAuthorizationIfNeeded()
            }
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
                isEnabled: { UserDefaults.standard.bool(forKey: AmbientPrefs.enabledKey) },
                send: { records in try await DoorClient(target: target).ambientLog(records: records) })
        }
        // When a capture upload is rejected as token-expired (401), refresh the id_token
        // once / surface login — instead of the phone retry-looping with a dead token.
        mgr.onAuthExpired = { [weak remote] in Task { @MainActor in await remote?.handleAuthExpired() } }
        // Wire the interactive Live Activity buttons (App Intents) to this live manager.
        // The intent's perform() runs in the app process and routes through this broker.
        let router = TabRouter()
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
        let reg = CaptureSourceRegistry(phoneMicAvailable: mgr.phoneMicAvailable)
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
        _sources = StateObject(wrappedValue: reg)
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
                    CaptureScreen(device: device, manager: manager, sources: sources, target: target, local: local)
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
                ActivityView(
                    decisionLogURL: AmbientPrefs.decisionLogURL(),
                    recapPool: manager.recapConversationPool(),
                    onOpenChat: { seed in AmbientCardBroker.shared.run(seed: seed) }
                )
                .toolbar {
                    NavigationLink("Stats") { StatsView(summary: manager.statsSummary) }
                }
            }
            .tabItem { Label(AppTab.activity.label, systemImage: AppTab.activity.systemImage) }
            .tag(TabRouter.Tab.activity)

            NavigationStack {
                Group {
                    if local {
                        LocalChatScreen(baseDir: CaptureWAL.documentsCaptures(), remote: remote)
                    } else {
                        ChatScreen(target: target, store: chats, log: log)
                    }
                }
                .navigationTitle("FoundryX")
            }
            .tabItem { Label(AppTab.chat.label, systemImage: AppTab.chat.systemImage) }
            .tag(TabRouter.Tab.chat)

            // Settings as a first-class bottom-nav tab (Nick 2026-07-15, T1
            // 20260715T1457 — supersedes the sheet). Keeps every settings row; Device
            // management lives HERE as a "Devices & connections" page (one management
            // home, not a competing Device tab) — connection STATUS stays glanceable on
            // the Capture home.
            NavigationStack {
                SettingsScreen(brains: brains, remote: remote,
                               device: device, manager: manager, sources: sources,
                               vaultFunnel: vaultFunnel, accountDeletion: accountDeletion)
                    .navigationTitle(SettingsSheetPresentation.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label(AppTab.settings.label, systemImage: AppTab.settings.systemImage) }
            .tag(TabRouter.Tab.settings)
        }
        // The Action Button's "Ask me" chooser (Phase 5, decision #4).
        .confirmationDialog("FoundryX", isPresented: $router.showActionChooser) {
            Button("Start recording") {
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
        .onAppear {
            syncOmiConnection()
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
            // Start the model fetch the moment the phone tier appears — so the
            // download runs (visibly) during first-run exploration, not silently on
            // the first "stop recording". Best-effort; the banner shows progress.
            if local, let stt = localSTT {
                Task { await stt.prewarm() }
            }
        }
        // The recording pill (track 20260713T0903): leaving the capture tab never
        // stops a recording — a quiet pill shows the ticking elapsed time, taps back
        // to the instrument, and can end the conversation right here.
        .overlay(alignment: .top) {
            if RecordingPillState.visible(
                recordingActive: manager.active != nil,
                onCaptureTab: router.selected == .capture) {
                RecordingPill(manager: manager) { router.selected = .capture }
            }
        }
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
    @ViewBuilder private func brainSetupBanner(_ text: String) -> some View {
        HStack(spacing: GrainSpacing.x2) {
            ProgressView()
            Text(text).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            Spacer()
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.vertical, GrainSpacing.x2)
        .background(GrainColor.surfaceElevated)
        .overlay(alignment: .bottom) { Rectangle().fill(GrainColor.borderHairline).frame(height: 1) }
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
        if let wal = manager.active {
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
                    ElapsedLabel(since: wal.status.startedAt, paused: phase == .paused)
                    Button("End") { _ = manager.endCurrentConversation() }
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.dangerRed)
                        .buttonStyle(.plain)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(presentation.word) capture")
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
