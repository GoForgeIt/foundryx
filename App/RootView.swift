import SwiftUI

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

    var body: some View {
        #if DEBUG
        // UI preview: launch with FOUNDRYX_UI_PREVIEW=1 (Open) or =private to skip sign-in and
        // render the chat surface against an in-memory store + stub door — for local screenshots
        // of UI work without a live host. DEBUG-only.
        if let preview = ProcessInfo.processInfo.environment["FOUNDRYX_UI_PREVIEW"] {
            switch preview {
            case "nohost":
                return AnyView(SignInView(remote: .preview(status: .noHost, email: "you@goforgeit.com"),
                                          onDone: {}, dismissable: false))
            case "error":
                return AnyView(SignInView(remote: .preview(status: .error("HTTP 502 from relay"), email: "you@goforgeit.com"),
                                          onDone: {}, dismissable: false))
            default:
                return AnyView(UIPreviewRoot())
            }
        }
        #endif
        return AnyView(gatedBody)
    }

    private var gatedBody: some View {
        Group {
            if let target = remote.makeDoorTarget(), splashElapsed {
                MainTabs(target: target, remote: remote, showingAccount: $showingAccount)
                    // A resolved-host change OR a refreshed bearer (after a token-expiry
                    // re-auth) rebuilds the tabs (+ their clients) so every door request
                    // uses the fresh id_token — never a stale, expired one.
                    .id((target.relay?.tunnelId ?? "remote") + "#" + target.bearer.suffix(12))
                    .sheet(isPresented: $showingAccount) {
                        SignInView(remote: remote) { showingAccount = false }
                    }
            } else {
                // Sign-in gate: not signed in, no host yet, or the launch splash.
                SignInView(remote: remote, onDone: { }, dismissable: false)
            }
        }
        .task { await remote.restore() }
        .task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            splashElapsed = true
        }
    }
}

/// Owns the ONE DeviceManager + CaptureManager so Capture + Device tabs share a
/// single BLE link + capture pipeline. All tabs talk to the resolved remote door
/// `target` (relay tunnel + id_token bearer). Chat is independent.
private struct MainTabs: View {
    let target: DoorTarget
    let remote: RemoteSession
    @Binding var showingAccount: Bool

    @StateObject private var device: DeviceManager
    @StateObject private var manager: CaptureManager
    @StateObject private var sources: CaptureSourceRegistry
    @StateObject private var log: DoorLog
    // The durable, resumable chat conversation list — owned here so it persists across
    // tab switches and app foregrounding (its own Application Support JSON file).
    @StateObject private var chats = ChatConversationStore(storageURL: ChatConversationStore.defaultStorageURL())
    // The capture→chat bridge: "Ask in chat" from a transcript seeds a chat + switches tabs.
    @StateObject private var bridge = ChatBridge()

    init(target: DoorTarget, remote: RemoteSession, showingAccount: Binding<Bool>) {
        self.target = target
        self.remote = remote
        _showingAccount = showingAccount
        let log = DoorLog()
        // Ship the phone's BLE/audio/capture/chat log to the relay diag sink so
        // it's observable server-side (no copying logs off the device).
        log.setRemoteSink(RemoteConfig.fromBundle()?.gatewayHTTPURL.appendingPathComponent("diag/log"))
        let dm = DeviceManager(log: log)
        _log = StateObject(wrappedValue: log)
        _device = StateObject(wrappedValue: dm)
        // Live on-device transcription preview (Feature 1). The factory builds the
        // SpeechAnalyzer transcriber on iOS 26+, falling back to SFSpeechRecognizer on
        // iOS 16–25; it's additive + ephemeral (Kiln stays authoritative).
        let mgr = CaptureManager(
            target: target, log: log, source: dm,
            // The phone's own mic as a second capture source (Record button when the
            // Omi is disconnected) — flows through the identical Opus/WAL/finalize path.
            micSource: MicFrameSource(log: log),
            liveTranscriber: LiveTranscription.defaultFactory())
        // When a capture upload is rejected as token-expired (401), refresh the id_token
        // once / surface login — instead of the phone retry-looping with a dead token.
        mgr.onAuthExpired = { [weak remote] in Task { @MainActor in await remote?.handleAuthExpired() } }
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
        // selection bound to the bridge so "Ask in chat" can jump to the Chat tab (.tag 0).
        TabView(selection: $bridge.selectedTab) {
            NavigationStack {
                ChatScreen(target: target, store: chats, log: log, bridge: bridge)
                    .navigationTitle("FoundryX")
                    .toolbar { Button("Account") { showingAccount = true } }
            }
            .tabItem { Label("Chat", systemImage: "message") }
            .tag(0)

            NavigationStack {
                CaptureScreen(device: device, manager: manager, sources: sources, target: target, bridge: bridge)
                    .navigationTitle("Capture")
                    .toolbar { Button("Account") { showingAccount = true } }
            }
            .tabItem { Label("Capture", systemImage: "waveform") }
            .tag(1)

            NavigationStack {
                DeviceScreen(device: device, manager: manager, sources: sources)
                    .navigationTitle("Device")
                    .toolbar { Button("Account") { showingAccount = true } }
            }
            .tabItem { Label("Device", systemImage: "antenna.radiowaves.left.and.right") }
            .tag(2)
        }
        // Keep the registry's Omi liveness in step with the BLE link from a SINGLE,
        // always-mounted place (not just the Device tab's onChange, which doesn't fire
        // unless that tab is on screen). This is what makes the active-source policy
        // correct — so toggling the Omi off actually hands off + drops it, and a transient
        // reconnect is reflected — regardless of which tab is visible.
        .onChange(of: device.connectionState) { _ in syncOmiConnection() }
        .onAppear { syncOmiConnection() }
    }

    /// Mirror the live BLE connection state onto the registry's Omi row.
    private func syncOmiConnection() {
        if case .connected = device.connectionState { sources.setOmiConnected(true) }
        else { sources.setOmiConnected(false) }
    }
}

#if DEBUG
/// DEBUG-only host for screenshotting the chat UI without sign-in (see RootView). Owns its
/// objects via @StateObject so `body` re-evaluation can't reset them. Seeds the Private posture
/// when launched with FOUNDRYX_UI_PREVIEW=private.
private struct UIPreviewRoot: View {
    @StateObject private var store = ChatConversationStore()
    @StateObject private var log = DoorLog()
    @StateObject private var bridge = ChatBridge()
    private let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:14288")!, bearer: "preview")

    var body: some View {
        NavigationStack {
            ChatScreen(target: target, store: store, log: log, bridge: bridge)
                .navigationTitle("FoundryX")
        }
        .onAppear {
            switch ProcessInfo.processInfo.environment["FOUNDRYX_UI_PREVIEW"] {
            case "private":
                if !store.activeId.isEmpty {
                    store.setSensitivity(ChatConversationStore.Sensitivity.private, for: store.activeId)
                }
            case "seed":
                // Exercise the capture→chat bridge: a seeded "Ask in chat" prompt.
                bridge.askAbout("About my conversation “Lantis kickoff call” (Mon, Jun 29 · 10:41–11:13 AM · 32 min):\n\nWe agreed to a 90-day pilot on the intake workflow; Justin to send the SOW by Friday; Nick to scope PHI routing.\n\nWhat are the key takeaways and any action items?")
            default:
                break
            }
        }
    }
}
#endif
