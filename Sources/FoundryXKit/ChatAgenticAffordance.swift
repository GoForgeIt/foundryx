import Foundation

public extension ChatViewModel {
    /// The quiet, always-present signal (shown in the chat composer, above the input) that
    /// this chat is AGENTIC — the assistant runs Kiln's full Mode-B loop and can read,
    /// write & edit files and run commands, gated by ask-first approval. This is the SINGLE
    /// source of truth for that copy: `ChatView.agenticAffordance` renders exactly this
    /// string, so the user can tell — before typing — that the assistant can act on their
    /// machine (features/chat-agentic-legibility.feature, scenario 1).
    static var agenticAffordance: String {
        "Agent — reads & writes files, runs commands. Asks before it acts."
    }
}
