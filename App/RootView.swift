import SwiftUI

// M5 R1b: login-gated, remote-managed. You must sign in (Google/Microsoft) and
// have a designated desktop host before entering the app — there are no manual
// door controls; the connection is always the resolved remote door over the
// blind relay, authenticated by your sign-in id_token (the door verifies it).
struct RootView: View {
    @StateObject private var remote = RemoteSession()
    @State private var showingAccount = false
    // Readiness-gated splash: the branded gate holds for a MINIMUM ~0.6s "brand beat"
    // so an instant cached restore doesn't flash SignInView→tabs. The UPPER bound of
    // the gate — "until a door target exists or restore concludes" — is enforced by the
    // `if let target = makeDoorTarget()` guard in `gatedBody`: the tabs cannot appear
    // until there's a resolved target regardless of this flag. So this timer supplies
    // only the 0.6s floor. Net: signed-in + cached ⇒ tabs in ~0.6s; signed-out stays on
    // the gate. Runs once per launch; foregrounding an open app never re-runs it.
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
            // Brand beat only — the 0.6s floor. Restore publishes a cached target before
            // its first await, so `makeDoorTarget()` is typically non-nil well within this
            // window and the tabs appear the instant the beat ends.
            try? await Task.sleep(nanoseconds: 600_000_000)
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
        // Wire the interactive Live Activity buttons (App Intents) to this live manager.
        // The intent's perform() runs in the app process and routes through this broker.
        CaptureIntentBroker.shared.handler = { [weak mgr] action in
            guard let mgr else { return false }
            switch action {
            case .endCurrent:  return mgr.endCurrentConversation()
            case .togglePause: mgr.togglePause(); return true
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
        // selection bound to the bridge so "Ask in chat" can jump to the Chat tab (.tag 0).
        TabView(selection: $bridge.selectedTab) {
            NavigationStack {
                ChatScreen(target: target, store: chats, log: log, bridge: bridge)
                    .navigationTitle("FoundryX")
                    .toolbar { Button("Account") { showingAccount = true } }
            }
            .tabItem { Label("Chat", systemImage: "message") }
            .tag(0)

            // Insights — the consumer payoff (listen → surfaced insights → knowledge graph).
            // Placed second so it's prominent; tag(3) keeps the bridge's 0/1/2 mapping intact.
            NavigationStack {
                InsightsView(target: target, bridge: bridge)
                    .navigationTitle("Insights")
                    .toolbar { Button("Account") { showingAccount = true } }
            }
            .tabItem { Label("Insights", systemImage: "lightbulb") }
            .tag(3)

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
        .onAppear {
            syncOmiConnection()
            wireAskIntent()
        }
    }

    /// Wire the Siri "Ask FoundryX" broker to THIS tab set's ChatBridge (mirrors how
    /// `CaptureIntentBroker` is wired in `init`, but from `body` because `bridge` is a
    /// `@StateObject` property, not an init local). Re-runs on each appear so a target-swap
    /// rebuild rewires to the fresh bridge; setting the handler also flushes any question
    /// buffered before the tabs mounted (Siri cold launch). Weak so the process-wide broker
    /// never pins a torn-down bridge.
    private func wireAskIntent() {
        let bridge = self.bridge
        AskIntentBroker.shared.handler = { [weak bridge] question in bridge?.askAbout(question) }
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

    /// A ChatViewModel driven through synthetic Door events so the agentic rendering (tool
    /// activity + an args-aware approval) can be screenshotted without a live Door.
    @MainActor private static func agentDemoModel() -> ChatViewModel {
        let m = ChatViewModel()
        m.beginUserTurn("Summarize my Lantis call and add the SOW to my todos.")
        m.apply(.toolCall(callId: "c1", name: "search_conversations", args: "{\"query\":\"Lantis\"}"))
        m.apply(.toolResult(callId: "c1", content: "3 matches", isError: false))
        m.apply(.assistantDelta(text: "From your Lantis kickoff: you agreed to a 90-day pilot on the intake workflow, and you owe the SOW by Friday. Want me to add that to your todos?"))
        m.apply(.approvalRequest(callId: "c2", name: "add_todo", args: "{\"text\": \"Send the Lantis SOW\", \"due\": \"Friday\"}"))
        return m
    }

    /// A ChatViewModel showing a FAILED turn — the humane error + "tap to retry" chip.
    @MainActor private static func failedTurnModel() -> ChatViewModel {
        let m = ChatViewModel()
        m.beginUserTurn("Summarize my Lantis call and add the SOW to my todos.")
        m.failTurn(reason: "Can't reach your Foundry — check your connection")
        return m
    }

    var body: some View {
        NavigationStack {
            Group {
                switch ProcessInfo.processInfo.environment["FOUNDRYX_UI_PREVIEW"] {
                case "insights":
                    InsightsView(target: target, bridge: bridge, injected: .sample)
                        .navigationTitle("Insights")
                case "recap":
                    // Today-at-the-Foundry recap alone (digest empty ⇒ recap + graph entry).
                    InsightsView(target: target, bridge: bridge, injectedRecap: .sample)
                        .navigationTitle("Insights")
                case "graph":
                    KnowledgeGraphView(target: target, bridge: bridge, injected: .sample)
                case "chatagent":
                    ScrollView { ChatView(model: Self.agentDemoModel()) }
                        .grainBackground()
                        .navigationTitle("FoundryX")
                case "chatfail":
                    // Failed turn + "tap to retry" chip (transport error, humane copy).
                    ScrollView { ChatView(model: Self.failedTurnModel()) }
                        .grainBackground()
                        .navigationTitle("FoundryX")
                case "chips":
                    // Empty-state recall chips, injected (no on-disk captures in the sim).
                    ChatScreen(target: target, store: store, log: log, bridge: bridge,
                               injectedRecallChips: [
                                   RecallChip(id: "cap_1", captureId: "cap_1", title: "Lantis kickoff call", startedAt: Date()),
                                   RecallChip(id: "cap_2", captureId: "cap_2", title: "Call with Mom", startedAt: Date()),
                                   ChatScreen.agreedTodayChip,
                               ])
                        .navigationTitle("FoundryX")
                default:
                    ChatScreen(target: target, store: store, log: log, bridge: bridge)
                        .navigationTitle("FoundryX")
                }
            }
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
