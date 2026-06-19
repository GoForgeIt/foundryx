import SwiftUI

struct RootView: View {
    @State private var config = DoorConfigStore.load()
    @State private var showingConfig = DoorConfigStore.load() == nil

    var body: some View {
        if let c = config {
            TabView {
                NavigationStack {
                    ChatScreen(config: c)
                        .navigationTitle("FoundryX")
                        .toolbar { Button("Door") { showingConfig = true } }
                }
                .tabItem { Label("Chat", systemImage: "message") }

                NavigationStack {
                    CaptureScreen(config: c)
                        .navigationTitle("Capture")
                        .toolbar { Button("Door") { showingConfig = true } }
                }
                .tabItem { Label("Capture", systemImage: "waveform") }
            }
            .id(c.url + c.bearer)   // a door change rebuilds both surfaces (+ their clients)
            .sheet(isPresented: $showingConfig) {
                ConnectionConfigView(initial: c) { saved in config = saved; showingConfig = false }
            }
        } else {
            ConnectionConfigView(initial: nil) { saved in config = saved; showingConfig = false }
        }
    }
}
