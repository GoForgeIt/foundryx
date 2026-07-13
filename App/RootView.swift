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

    @StateObject private var brains = BrainStore()

    var body: some View {
        let dest = RootGate.destination(signedIn: remote.email != nil,
                                        splashElapsed: splashElapsed,
                                        brain: brains.choice,
                                        hostResolved: remote.makeDoorTarget() != nil)
        Group {
            switch dest {
            case .signInGate:
                // The forced identity login (track 20260705T1100 decision #5) +
                // the branded launch splash.
                SignInView(remote: remote, onDone: { }, dismissable: false)
            case .computerBrain:
                if let target = remote.makeDoorTarget() {
                    MainTabs(target: target, remote: remote, brains: brains, local: false,
                             showingAccount: $showingAccount)
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
                         showingAccount: $showingAccount)
                    .id("local-brain")
                    .sheet(isPresented: $showingAccount) {
                        SignInView(remote: remote) { showingAccount = false }
                    }
            }
        }
        .task { await remote.restore() }
        .task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            splashElapsed = true
            // Already signed in from a restored session: the destination never
            // *changes*, so check the first-run gate here too. Existing installs
            // (any recordings on disk) are migrated to "onboarded" silently.
            OnboardingPrefs.migrateIfPriorUse(baseDir: CaptureWAL.documentsCaptures())
            if remote.email != nil,
               OnboardingGate.shouldPresent(signedIn: true, completed: OnboardingPrefs.completed) {
                showingOnboarding = true
            }
        }
        // First-run onboarding (runs ONCE, after the first sign-in): teach the owner's
        // voice + the ambient opt-in. Dismissing counts as done — never re-prompts;
        // both steps stay reachable from Settings.
        .onChange(of: dest) { d in
            if d != .signInGate {
                OnboardingPrefs.migrateIfPriorUse(baseDir: CaptureWAL.documentsCaptures())
                if OnboardingGate.shouldPresent(signedIn: true, completed: OnboardingPrefs.completed) {
                    showingOnboarding = true
                }
            }
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingFlowView(baseDir: CaptureWAL.documentsCaptures()) {
                showingOnboarding = false
            }
        }
        // The Night Shift register IS the app's identity (track 20260713T2100):
        // FoundryX renders dark everywhere — the same night the welcome, the
        // prototypes, and the brand wear. Grain's dynamic tokens resolve to
        // their night values under this scheme; light/cream stays available to
        // other Grain consumers.
        .preferredColorScheme(.dark)
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
}

/// Routes intent-driven navigation (Action Button / Siri / Control Center) onto
/// the tab bar from anywhere in the process (track 20260705T1100, Phase 5).
@MainActor
final class TabRouter: ObservableObject {
    enum Tab: Hashable { case chat, capture, device, settings }
    @Published var selected: Tab = .capture
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
         showingAccount: Binding<Bool>) {
        self.target = target
        self.remote = remote
        self.brains = brains
        self.local = local
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
            AmbientNotifier.requestAuthorizationIfNeeded()
        }
        // When a capture upload is rejected as token-expired (401), refresh the id_token
        // once / surface login — instead of the phone retry-looping with a dead token.
        mgr.onAuthExpired = { [weak remote] in Task { @MainActor in await remote?.handleAuthExpired() } }
        // Wire the interactive Live Activity buttons (App Intents) to this live manager.
        // The intent's perform() runs in the app process and routes through this broker.
        let router = TabRouter()
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
        TabView(selection: $router.selected) {
            NavigationStack {
                Group {
                    if local {
                        LocalChatScreen(baseDir: CaptureWAL.documentsCaptures(), remote: remote)
                    } else {
                        ChatScreen(target: target, store: chats, log: log)
                    }
                }
                .navigationTitle("FoundryX")
                .toolbar { Button("Account") { showingAccount = true } }
            }
            .tabItem { Label("Chat", systemImage: "message") }
            .tag(TabRouter.Tab.chat)

            NavigationStack {
                VStack(spacing: 0) {
                    // Phone tier: the model-download banner sits above capture so the
                    // first recording's ~150 MB fetch is visible, not a silent hang.
                    if local, let text = brainStatus.bannerText {
                        brainSetupBanner(text)
                    }
                    CaptureScreen(device: device, manager: manager, sources: sources, target: target, local: local)
                }
                .navigationTitle("Capture")
                .toolbar { Button("Account") { showingAccount = true } }
            }
            .tabItem { Label("Capture", systemImage: "waveform") }
            .tag(TabRouter.Tab.capture)

            NavigationStack {
                DeviceScreen(device: device, battery: battery, manager: manager, sources: sources)
                    .navigationTitle("Device")
                    .toolbar { Button("Account") { showingAccount = true } }
            }
            .tabItem { Label("Device", systemImage: "antenna.radiowaves.left.and.right") }
            .tag(TabRouter.Tab.device)

            NavigationStack {
                SettingsScreen(brains: brains, remote: remote)
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
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
        // Keep the registry's Omi liveness in step with the BLE link from a SINGLE,
        // always-mounted place (not just the Device tab's onChange, which doesn't fire
        // unless that tab is on screen). This is what makes the active-source policy
        // correct — so toggling the Omi off actually hands off + drops it, and a transient
        // reconnect is reflected — regardless of which tab is visible.
        .onChange(of: device.connectionState) { _ in syncOmiConnection() }
        .onAppear {
            syncOmiConnection()
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
            HStack(spacing: GrainSpacing.x2) {
                RecordingRingView(meter: manager.meter, paused: manager.isPaused)
                    .frame(width: 22, height: 22)
                ElapsedLabel(since: wal.status.startedAt)
                Button("End") { _ = manager.endCurrentConversation() }
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.dangerRed)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, GrainSpacing.x3)
            .padding(.vertical, GrainSpacing.x1)
            .background(Capsule().fill(GrainColor.surfaceElevated))
            .overlay(Capsule().strokeBorder(GrainColor.border, lineWidth: 1))
            .onTapGesture { onOpen() }
            .padding(.top, GrainSpacing.x1)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording in progress")
        }
    }
}
