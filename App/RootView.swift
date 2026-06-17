import SwiftUI

struct RootView: View {
    @State private var config = DoorConfigStore.load()
    @State private var showingConfig = DoorConfigStore.load() == nil

    var body: some View {
        NavigationStack {
            if let c = config {
                ChatScreen(config: c)
                    .navigationTitle("FoundryX")
                    .toolbar {
                        Button("Door") { showingConfig = true }
                    }
                    .sheet(isPresented: $showingConfig) {
                        ConnectionConfigView(initial: c) { saved in config = saved; showingConfig = false }
                    }
            } else {
                ConnectionConfigView(initial: nil) { saved in config = saved; showingConfig = false }
            }
        }
    }
}
