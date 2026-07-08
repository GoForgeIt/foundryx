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
        }
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
        // When a capture upload is rejected as token-expired (401), refresh the id_token
        // once / surface login — instead of the phone retry-looping with a dead token.
        mgr.onAuthExpired = { [weak remote] in Task { @MainActor in await remote?.handleAuthExpired() } }
        // Wire the interactive Live Activity buttons (App Intents) to this live manager.
        // The intent's perform() runs in the app process and routes through this broker.
        let router = TabRouter()
        _router = StateObject(wrappedValue: router)
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
