import SwiftUI

struct RootView: View {
    @State private var config = DoorConfigStore.load()
    @State private var showingConfig = DoorConfigStore.load() == nil

    var body: some View {
        if let c = config {
            MainTabs(config: c, showingConfig: $showingConfig)
                .id(c.url + c.bearer)   // a door change rebuilds the tabs (+ their clients)
                .sheet(isPresented: $showingConfig) {
                    ConnectionConfigView(initial: c) { saved in config = saved; showingConfig = false }
                }
        } else {
            ConnectionConfigView(initial: nil) { saved in config = saved; showingConfig = false }
        }
    }
}

/// Owns the ONE DeviceManager + CaptureManager so the Capture and Device tabs share
/// a single BLE link + capture pipeline (a second DeviceManager would spin a rival
/// CBCentralManager). Chat is independent.
private struct MainTabs: View {
    let config: DoorConfig
    @Binding var showingConfig: Bool

    @StateObject private var device: DeviceManager
    @StateObject private var manager: CaptureManager

    init(config: DoorConfig, showingConfig: Binding<Bool>) {
        self.config = config
        _showingConfig = showingConfig
        let log = DoorLog()
        let dm = DeviceManager(log: log)
        let target = DoorTarget(baseURL: config.doorURL, bearer: config.bearer)
        _device = StateObject(wrappedValue: dm)
        _manager = StateObject(wrappedValue: CaptureManager(target: target, log: log, source: dm))
    }

    var body: some View {
        TabView {
            NavigationStack {
                ChatScreen(config: config)
                    .navigationTitle("FoundryX")
                    .toolbar { Button("Door") { showingConfig = true } }
            }
            .tabItem { Label("Chat", systemImage: "message") }

            NavigationStack {
                CaptureScreen(device: device, manager: manager)
                    .navigationTitle("Capture")
                    .toolbar { Button("Door") { showingConfig = true } }
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
