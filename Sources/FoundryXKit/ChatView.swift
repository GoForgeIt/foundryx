// ChatView — the FoundryX chat surface (SwiftUI). Cross-platform SwiftUI (no UIKit) so
// it hosts on the macOS test lane (NSHostingView) AND ships in the iOS app unchanged.
// Renders the conversation, streams the in-flight assistant reply, and surfaces the gate
// approval prompt. The M3 iOS app reuses this verbatim.

#if canImport(SwiftUI)
import SwiftUI

public struct ChatView: View {
    @ObservedObject public var model: ChatViewModel
    public var onApprove: (String) -> Void
    public var onReject: (String) -> Void

    public init(model: ChatViewModel,
                onApprove: @escaping (String) -> Void = { _ in },
                onReject: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.onApprove = onApprove
        self.onReject = onReject
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.messages) { msg in
                Text(msg.text)
                    .accessibilityIdentifier(msg.role == "assistant" ? "assistant-message" : "user-message")
            }

            switch model.turnState {
            case .awaitingApproval(let callId, let name, _):
                HStack {
                    Text("Approve \(name)?")
                    Button("Approve") { onApprove(callId) }
                    Button("Reject") { onReject(callId) }
                }
                .accessibilityIdentifier("approval-prompt")
            case .completed(let reason):
                Text("done: \(reason)").accessibilityIdentifier("turn-status")
            case .refused:
                Text("refused").accessibilityIdentifier("turn-status")
            case .streaming, .idle:
                EmptyView()
            }
        }
        .padding()
        .frame(width: 320)
    }
}
#endif
