// ChatSurface — THE chat surface. One of them.
//
// A chat is a scrolling column of bubbles that lands on the newest thing said, with a
// composer under it. That was true of the phone's own chats and it is true of the chats on
// the Mac, and for a while the app had two answers to it: `ChatScreen` wrapped `ChatView` in
// a scroller with a composer, and `KilnConversationView` grew its own eyebrow-and-paragraph
// transcript with a button where the composer belongs. Two surfaces meant two behaviours —
// one scrolled to the bottom, one didn't; one let you type, one didn't; one looked like the
// product and one didn't — and the second one is what shipped for the Mac's chats.
//
// So the scroller, the landing position, the held-back older turns and the composer live
// HERE, once, and both screens render through it. Adding a third rendering of a chat means
// deleting a scenario first.

#if canImport(SwiftUI)
import SwiftUI
import Grain
#if canImport(UIKit)
import UIKit
#endif

public struct ChatSurface<Accessory: View>: View {

    /// The turns held back above the window, and how to build the next page of them.
    /// `nil` ⇒ everything there is to build is built.
    public struct Earlier {
        public let label: String
        public let action: () -> Void
        public init(label: String, action: @escaping () -> Void) {
            self.label = label
            self.action = action
        }
    }

    @ObservedObject private var model: ChatViewModel
    @Binding private var input: String
    private let placeholder: String
    private let isSending: Bool
    private let earlier: Earlier?
    private let onSend: () -> Void
    private let onApprove: (String) -> Void
    private let onReject: (String) -> Void
    private let onOpenArtifact: ((ChatViewModel.RunArtifact) -> Void)?
    /// False on a surface with no agent and no door behind it — see `ChatView`.
    private let showsAgentSignals: Bool
    private let accessory: () -> Accessory

    public init(model: ChatViewModel,
                input: Binding<String>,
                placeholder: String,
                isSending: Bool,
                earlier: Earlier? = nil,
                onSend: @escaping () -> Void,
                onApprove: @escaping (String) -> Void = { _ in },
                onReject: @escaping (String) -> Void = { _ in },
                onOpenArtifact: ((ChatViewModel.RunArtifact) -> Void)? = nil,
                showsAgentSignals: Bool = true,
                @ViewBuilder accessory: @escaping () -> Accessory) {
        self.model = model
        self._input = input
        self.placeholder = placeholder
        self.isSending = isSending
        self.earlier = earlier
        self.onSend = onSend
        self.onApprove = onApprove
        self.onReject = onReject
        self.onOpenArtifact = onOpenArtifact
        self.showsAgentSignals = showsAgentSignals
        self.accessory = accessory
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // Older turns are HELD, not built. The affordance sits above the window
                    // because that is where the turns it builds will appear.
                    if let earlier {
                        Button(action: earlier.action) {
                            Text(earlier.label)
                                .grainTextStyle(.caption)
                                .foregroundStyle(GrainColor.forgeBlue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, GrainSpacing.x3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat-show-earlier")
                    }

                    ChatView(model: model,
                             onApprove: onApprove,
                             onReject: onReject,
                             onOpenArtifact: onOpenArtifact,
                             showsAgentSignals: showsAgentSignals)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    accessory()
                }
                .scrollDismissesKeyboard(.interactively)
                .contentShape(Rectangle())
                .onTapGesture { hideKeyboard() }
                // Every chat app opens where you left off. The old Mac-chat screen had no
                // scroll of any kind, so a chat of thousands of turns opened at the first
                // thing anyone had said and there was no getting to the bottom of it.
                .onAppear { land(proxy, animated: false) }
                .onChange(of: model.messages.count) { _ in land(proxy, animated: true) }
            }
            GrainComposer(placeholder, text: $input, isSending: isSending, onSend: onSend)
        }
        .accessibilityIdentifier("chat-surface")
    }

    /// Land on the newest turn.
    private func land(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let newest = model.messages.last?.id else { return }
        if animated {
            withAnimation(GrainMotion.fast) { proxy.scrollTo(newest, anchor: .bottom) }
        } else {
            proxy.scrollTo(newest, anchor: .bottom)
        }
    }

    private func hideKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

extension ChatSurface where Accessory == EmptyView {
    public init(model: ChatViewModel,
                input: Binding<String>,
                placeholder: String,
                isSending: Bool,
                earlier: Earlier? = nil,
                onSend: @escaping () -> Void,
                onApprove: @escaping (String) -> Void = { _ in },
                onReject: @escaping (String) -> Void = { _ in },
                onOpenArtifact: ((ChatViewModel.RunArtifact) -> Void)? = nil,
                showsAgentSignals: Bool = true) {
        self.init(model: model, input: input, placeholder: placeholder,
                  isSending: isSending, earlier: earlier, onSend: onSend,
                  onApprove: onApprove, onReject: onReject,
                  onOpenArtifact: onOpenArtifact, showsAgentSignals: showsAgentSignals,
                  accessory: { EmptyView() })
    }
}
#endif
