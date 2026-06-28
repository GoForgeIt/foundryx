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
        Group {
            if let target = remote.makeDoorTarget(), splashElapsed {
                MainTabs(target: target, showingAccount: $showingAccount)
                    // A resolved-host change rebuilds the tabs (+ their clients).
                    .id(target.relay?.tunnelId ?? "remote")
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
    @Binding var showingAccount: Bool

    @StateObject private var device: DeviceManager
    @StateObject private var manager: CaptureManager
    @StateObject private var log: DoorLog
    // The durable, resumable chat conversation list — owned here so it persists across
    // tab switches and app foregrounding (its own Application Support JSON file).
    @StateObject private var chats = ChatConversationStore(storageURL: ChatConversationStore.defaultStorageURL())

    init(target: DoorTarget, showingAccount: Binding<Bool>) {
        self.target = target
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
        _manager = StateObject(wrappedValue: CaptureManager(
            target: target, log: log, source: dm,
            // The phone's own mic as a second capture source (Record button when the
            // Omi is disconnected) — flows through the identical Opus/WAL/finalize path.
            micSource: MicFrameSource(log: log),
            liveTranscriber: LiveTranscription.defaultFactory()))
    }

    var body: some View {
        TabView {
            NavigationStack {
                ChatScreen(target: target, store: chats, log: log)
                    .navigationTitle("FoundryX")
                    .toolbar { Button("Account") { showingAccount = true } }
            }
            .tabItem { Label("Chat", systemImage: "message") }

            NavigationStack {
                CaptureScreen(device: device, manager: manager, target: target)
                    .navigationTitle("Capture")
                    .toolbar { Button("Account") { showingAccount = true } }
            }
            .tabItem { Label("Capture", systemImage: "waveform") }

            NavigationStack {
                DeviceScreen(device: device, manager: manager)
                    .navigationTitle("Omi Device")
                    .toolbar { Button("Account") { showingAccount = true } }
            }
            .tabItem { Label("Device", systemImage: "antenna.radiowaves.left.and.right") }
        }
    }
}
