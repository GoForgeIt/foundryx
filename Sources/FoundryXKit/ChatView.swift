// ChatView — the FoundryX chat surface (SwiftUI), now built on the Grain design
// system. Cross-platform SwiftUI (no UIKit) so it hosts on the macOS test lane
// (NSHostingView) AND ships in the iOS app unchanged. Renders the conversation,
// streams the in-flight assistant reply, and surfaces the gate approval prompt.
//
// Accessibility identifiers ("assistant-message", "user-message",
// "approval-prompt", "turn-status") are preserved so the Brine UI scenario (AC4)
// keeps asserting against the same rendered state. No raw colors or fonts —
// everything comes from Grain tokens/components.

#if canImport(SwiftUI)
import SwiftUI
import Grain

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
        VStack(alignment: .leading, spacing: GrainSpacing.x3) {
            ForEach(model.messages) { msg in
                GrainMessageBubble(role: msg.role == "assistant" ? .assistant : .user, text: msg.text)
                    .accessibilityIdentifier(msg.role == "assistant" ? "assistant-message" : "user-message")
            }

            switch model.turnState {
            case .awaitingApproval(let callId, let name, _):
                GrainCard(.filled) {
                    VStack(alignment: .leading, spacing: GrainSpacing.x3) {
                        Text("Approve \(name)?")
                            .grainTextStyle(.body)
                            .foregroundStyle(GrainColor.ink)
                        HStack(spacing: GrainSpacing.x2) {
                            GrainButton("Approve", variant: .filled, size: .sm) { onApprove(callId) }
                            GrainButton("Reject", variant: .outlined, size: .sm) { onReject(callId) }
                        }
                    }
                }
                .accessibilityIdentifier("approval-prompt")
            case .completed(let reason):
                Text("done: \(reason)")
                    .grainTextStyle(.caption)
                    .textCase(.uppercase)
                    .foregroundStyle(GrainColor.sage)
                    .accessibilityIdentifier("turn-status")
            case .refused:
                Text("refused")
                    .grainTextStyle(.caption)
                    .textCase(.uppercase)
                    .foregroundStyle(GrainColor.dangerRed)
                    .accessibilityIdentifier("turn-status")
            case .streaming:
                HStack { GrainTypingIndicator(); Spacer(minLength: 0) }
            case .idle:
                EmptyView()
            }
        }
        .padding(GrainSpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
