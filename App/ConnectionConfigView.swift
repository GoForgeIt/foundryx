import SwiftUI
import Grain

struct ConnectionConfigView: View {
    @State private var urlText: String
    @State private var token: String
    @StateObject private var saveModel = DoorConnectionSaveModel()
    var onSave: (DoorConfig) -> Void

    init(initial: DoorConfig?, onSave: @escaping (DoorConfig) -> Void) {
        _urlText = State(initialValue: initial?.url ?? "http://127.0.0.1:14288")
        _token = State(initialValue: initial?.bearer ?? "")
        self.onSave = onSave
    }

    private var isValid: Bool { URL(string: urlText) != nil && !token.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GrainSpacing.x6) {
                VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                    Text("Connect").grainTextStyle(.display).foregroundStyle(GrainColor.inkEmphasis)
                    Text("Point FoundryX at your local Foundry door.")
                        .grainTextStyle(.body).foregroundStyle(GrainColor.inkSecondary)
                }

                GrainCard(.elevated) {
                    VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                        Text("Local Foundry door")
                            .grainTextStyle(.caption).textCase(.uppercase)
                            .foregroundStyle(GrainColor.inkTertiary)
                        GrainTextField("http://127.0.0.1:14288", text: $urlText, label: "Door URL")
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("door-url-field")
                        GrainTextField("Bearer token", text: $token, label: "Token", secure: true)
                            .accessibilityIdentifier("door-token-field")
                    }
                }

                GrainButton("Save & Connect", variant: .filled, size: .lg) {
                    guard let c = DoorConfig(url: urlText, bearer: token) else { return }
                    saveModel.save(c, onSaved: onSave)
                }
                .frame(maxWidth: .infinity)
                .disabled(!isValid)
                .opacity(isValid ? 1 : 0.5)
                .accessibilityIdentifier("save-connect-button")

                if let errorMessage = saveModel.errorMessage {
                    Text(errorMessage)
                        .grainTextStyle(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("door-save-error")
                }
            }
            .padding(GrainSpacing.x6)
        }
        .grainBackground()
        .navigationTitle("Connect")
    }
}
