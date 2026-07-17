import SwiftUI
import Grain

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

    /// The front-door rendition for the `.signInGate` destination (track
    /// 20260715T1502 re-cut, Nick 2026-07-16: the welcome IS the front door — the
    /// old SignInView connection page never gates, on any path).
    private var frontDoorSurface: WelcomeFrontDoor.Surface {
        WelcomeFrontDoor.surface(signedIn: remote.email != nil,
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
        // DEV-only visual harness: `-MainPreview` mounts the real tabs in phone-only
        // mode (no auth, no door) over the demo cards DemoSeed dropped on disk, so every
        // screen can be screenshot-verified against the prototype. No effect normally.
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
        // DEV-only: `-Screen waiting <kind>` mounts one honest-wait state (WS-C) for
        // screenshot-verification — kind ∈ recap|title|transcription|door|sync.
        if ProcessInfo.processInfo.arguments.contains("-Screen"),
           ProcessInfo.processInfo.arguments.contains("waiting") {
            return AnyView(WaitingExperienceProof(
                kind: WaitingExperienceProof.kind(from: ProcessInfo.processInfo.arguments)))
        }
        // The welcome front door leads until the user enters (enterApp); an
        // opted-out user short-circuits inside RootGate — no gate of any kind.
        let dest = RootGate.destination(signedIn: remote.email != nil,
                                        splashElapsed: enteredApp,
                                        brain: brains.choice,
                                        hostResolved: remote.makeDoorTarget() != nil,
                                        letStraightIn: WelcomePrefs.letStraightIn())
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
                            onTap: { p in Task { await remote.signIn(p) } })
                        : nil)
            case .computerBrain:
                if let target = remote.makeDoorTarget() {
                    MainTabs(target: target, remote: remote, brains: brains, local: false,
                             vaultFunnel: vaultFunnel, accountDeletion: accountDeletion, showingAccount: $showingAccount)
                        // A resolved-host change OR a refreshed bearer (after a token-expiry
                        // re-auth) rebuilds the tabs (+ their clients) so every door request
                        // uses the fresh id_token — never a stale, expired one.
                        .id((target.relay?.tunnelId ?? "remote") + "#" + target.bearer.suffix(12))
                        // Point the content-free usage sink at THIS resolved door (base +
                        // fresh bearer) so product-usage reaches POST /foundryx/telemetry/usage.
                        // The `.id` above re-mounts on a bearer refresh, so this re-fires with
                        // the fresh target.
                        .onAppear { PerfTelemetry.shared.setUsageTarget(target) }
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
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingFlowView(baseDir: CaptureWAL.documentsCaptures(),
                               skipWelcome: onboardingSkipsWelcome) {
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

    /// The post-sign-in first-run ladder (B2): migrate, then render the ONE pure
    /// decision (WelcomeFrontDoor.firstRunPresentation — tested in the kit): the
    /// full onboarding flow (skipping its welcome step when the gate already was
    /// the welcome), the standalone persona welcome, or nothing.
    private func presentFirstRunSurfacesIfNeeded() {
        // Called from both enterApp() and the dest onChange — never re-decide
        // over an already-presented surface (implement-review F3).
        if showingOnboarding || showingWelcome { return }
        OnboardingPrefs.migrateIfPriorUse(baseDir: CaptureWAL.documentsCaptures())
        switch WelcomeFrontDoor.firstRunPresentation(
            letStraightIn: WelcomePrefs.letStraightIn(),
            onboardingCompleted: OnboardingPrefs.completed,
            welcomeSeen: WelcomePrefs.seen()) {
        case .onboarding(let skipWelcome):
            onboardingSkipsWelcome = skipWelcome
            showingOnboarding = true
        case .standaloneWelcome:
            showingWelcome = true
        case .none:
            break
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

    /// First-frame deferral (TARGET 2 — launch first-frame cost). The TabView otherwise
    /// builds ALL four tab roots up front; only the Capture tab is on screen at launch,
    /// so Activity/Chat/Settings (each an N-scaling body over the same library) are dead
    /// weight on the critical path. This flips true right AFTER first draw (a `.task`),
    /// at which point the other tabs build off the critical path. A tab is ALSO built the
    /// instant it becomes `router.selected`, so a deep link / notification / intent that
    /// routes straight to a tab before the flag flips still renders it immediately.
    @State private var deferredTabsReady = false

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
                // Deferred off the first-frame path (TARGET 2); still builds the instant
                // Activity is selected (deep link / intent), so routing is unaffected.
                if deferredTabsReady || router.selected == .activity {
                    ActivityView(
                        decisionLogURL: AmbientPrefs.decisionLogURL(),
                        recapPool: manager.recapConversationPool(),
                        onOpenChat: { seed in AmbientCardBroker.shared.run(seed: seed) },
                        local: local
                    )
                    .toolbar {
                        NavigationLink("Stats") { StatsView(summary: manager.statsSummary) }
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
                        } else {
                            ChatScreen(target: target, store: chats, log: log)
                        }
                    } else {
                        Color.clear
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
        // CONTENT-FREE usage: which surface the user is on. The tab's rawValue is already
        // a safe enum token (capture/activity/chat/settings) — never any content.
        .onChange(of: router.selected) { tab in UsageHook.page(tab.rawValue) }
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
            syncOmiConnection()
            // EXT2: let action↔chat links validate against the LIVE chat store
            // (dead links are pruned at render, never routed to). Weak — the
            // hook must not outlive a re-mounted tab tree's store.
            AmbientCardBroker.shared.isChatAlive = { [weak chats] id in
                chats?.conversation(id) != nil
            }
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
