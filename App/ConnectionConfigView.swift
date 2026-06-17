import SwiftUI

struct ConnectionConfigView: View {
    @State private var urlText: String
    @State private var token: String
    var onSave: (DoorConfig) -> Void

    init(initial: DoorConfig?, onSave: @escaping (DoorConfig) -> Void) {
        _urlText = State(initialValue: initial?.url ?? "http://127.0.0.1:14288")
        _token = State(initialValue: initial?.bearer ?? "")
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("Local Foundry door") {
                TextField("Door URL", text: $urlText)
                    .textContentType(.URL).autocorrectionDisabled()
                SecureField("Bearer token", text: $token)
            }
            Button("Save & Connect") {
                guard let c = DoorConfig(url: urlText, bearer: token) else { return }
                DoorConfigStore.save(c)
                onSave(c)
            }
            .disabled(URL(string: urlText) == nil || token.isEmpty)
        }
        .navigationTitle("Connect")
    }
}
