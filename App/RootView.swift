import SwiftUI

struct RootView: View {
    @State private var config = DoorConfigStore.load()
    @State private var showingConfig = DoorConfigStore.load() == nil
    @State private var showingRemote = false
    // Off-LAN remote session (M5 R1b): sign in → resolve the designated host →
    // hold the RelayConfig. nil relay = LAN-direct (unchanged).
    @StateObject private var remote = RemoteSession()

    var body: some View {
        Group {
            if let c = config {
                MainTabs(
                    config: c,
                    relay: remote.relay,
                    showingConfig: $showingConfig,
                    showingRemote: $showingRemote
                )
                // A door change OR a resolved relay rebuilds the tabs (+ their clients).
                .id(c.url + c.bearer + "|" + (remote.relay?.tunnelId ?? "lan"))
                .sheet(isPresented: $showingConfig) {
                    ConnectionConfigView(initial: c) { saved in config = saved; showingConfig = false }
                }
                .sheet(isPresented: $showingRemote) {
                    SignInView(remote: remote) { showingRemote = false }
                }
            } else {
                ConnectionConfigView(initial: nil) { saved in config = saved; showingConfig = false }
            }
        }
        .task { await remote.restore() }
    }
}

/// Owns the ONE DeviceManager + CaptureManager so the Capture and Device tabs share
/// a single BLE link + capture pipeline (a second DeviceManager would spin a rival
/// CBCentralManager). Chat is independent. When `relay` is set the door targets
/// route through the blind relay (off-LAN); nil = LAN-direct.
private struct MainTabs: View {
    let config: DoorConfig
    let relay: RelayConfig?
    @Binding var showingConfig: Bool
    @Binding var showingRemote: Bool

    @StateObject private var device: DeviceManager
    @StateObject private var manager: CaptureManager
    @StateObject private var log: DoorLog

    init(config: DoorConfig, relay: RelayConfig?, showingConfig: Binding<Bool>, showingRemote: Binding<Bool>) {
        self.config = config
        self.relay = relay
        _showingConfig = showingConfig
        _showingRemote = showingRemote
        let log = DoorLog()
        let dm = DeviceManager(log: log)
        let target = DoorTarget(baseURL: config.doorURL, bearer: config.bearer, relay: relay)
        _log = StateObject(wrappedValue: log)
        _device = StateObject(wrappedValue: dm)
        _manager = StateObject(wrappedValue: CaptureManager(target: target, log: log, source: dm))
    }

    var body: some View {
        TabView {
            NavigationStack {
                ChatScreen(config: config, relay: relay, log: log)
                    .navigationTitle("FoundryX")
                    .toolbar {
                        Button("Remote") { showingRemote = true }
                        Button("Door") { showingConfig = true }
                    }
            }
            .tabItem { Label("Chat", systemImage: "message") }

            NavigationStack {
                CaptureScreen(device: device, manager: manager)
                    .navigationTitle("Capture")
                    .toolbar {
                        Button("Remote") { showingRemote = true }
                        Button("Door") { showingConfig = true }
                    }
            }
            .tabItem { Label("Capture", systemImage: "waveform") }

            NavigationStack {
                DeviceScreen(device: device, manager: manager)
                    .navigationTitle("Omi Device")
                    .toolbar { Button("Door") { showingConfig = true } }
            }
            .tabItem { Label("Device", systemImage: "antenna.radiowaves.left.and.right") }
        }
    }
}
