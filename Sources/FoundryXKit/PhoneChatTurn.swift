import Foundation

// One turn, into a chat this phone owns.
//
// This is the ONLY place a phone chat turn is run, and it is here rather than in a view
// for the same reason `KilnRemoteTurn` is: a turn is a contract a scenario must be able to
// drive through the real `DoorClient`, the real `ChatViewModel` and the real
// `ChatConversationStore` — not a claim about a button.
//
// It is here in particular because ENDING a turn is the part that broke. Writing the
// finished thread back into the durable list is account-scoped work that itself does
// account-scoped work (`ChatConversationStore.persist`), and while that composition lived
// inside a SwiftUI view the only thing that could see it was a UI proof. It is
// `features/chat-turn-always-ends.feature` that sees it now.

/// Running one turn in a chat this phone started.
public enum PhoneChatTurn {

    /// Run one turn to completion.
    ///
    /// The turn ALWAYS ends. Either the door's reply lands in the thread, or the honest
    /// sentence about why there isn't one does — and then the finished thread is written
    /// into the durable list under the account that started the turn. A caller may hand
    /// the composer back the moment this returns, unconditionally: the composer is SCREEN
    /// state, not account state, so an account that moved on mid-turn must not be able to
    /// leave it spinning forever.
    ///
    /// - Parameters:
    ///   - binding: the account that started the turn. Every touch of the model and of the
    ///     durable list is gated on it still being current, so a completion arriving after
    ///     an identity change cannot write into the account that replaced it.
    ///   - onEvent: observed for the events a caller needs out of the stream (the session
    ///     id). Runs inside the account gate, alongside the model update.
    @MainActor
    public static func run(
        text: String,
        chatId: String,
        store: ChatConversationStore,
        model: ChatViewModel,
        client: DoorClient,
        as binding: CaptureAccountScope.AccountBinding,
        log: DoorLog? = nil,
        onEvent: (DoorEvent) -> Void = { _ in }
    ) async {
        model.beginUserTurn(text)
        model.setConnection(.connecting)
        let req = store.chatRequest(text: text, for: chatId)
        var sawEvent = false
        // The account was superseded mid-stream: stop, and leave the durable list alone.
        // The turn still ENDS — the caller gets its composer back either way.
        var superseded = false
        do {
            for try await ev in client.events(for: req) {
                let admitted = CaptureAccountScope.perform(as: binding) { _ in
                    if !sawEvent {
                        sawEvent = true
                        model.setConnection(.streaming)
                    }
                    if case .done(let reason) = ev {
                        model.setConnection(.completed(reason: reason))
                    }
                    model.apply(ev)
                    onEvent(ev)
                    return true
                } == true
                guard admitted else { superseded = true; break }
            }
            if !superseded, !sawEvent {
                // The thread stays calm; the engineering truth goes to the log.
                log?.warn(ChatSendFailure.emptyReplyLogDetail)
                model.setConnection(.error(detail: ChatSendFailure.emptyReply))
                model.apply(.error(code: "", reason: ChatSendFailure.emptyReply))
            }
        } catch {
            // Calm human copy in the thread; the code/domain detail is DoorLog-only.
            let calm = ChatSendFailure.calmMessage(for: error)
            log?.error("turn failed: \(ChatSendFailure.logDetail(for: error))")
            model.setConnection(.error(detail: calm))
            model.apply(.error(code: "", reason: calm))
        }
        guard !superseded else { return }
        record(model.snapshot(), into: store, chatId: chatId, as: binding)
    }

    /// Write the finished thread back into the durable list — only if the reader is still
    /// in the conversation it belongs to (they may have switched away mid-stream), and only
    /// under the account that started the turn.
    ///
    /// - Returns: whether the turn was recorded. `false` means the account that started it
    ///   is no longer current, or the reader had moved on; it never means "the app is
    ///   stuck", and the caller must hand the composer back regardless.
    @discardableResult
    public static func record(
        _ messages: [ChatConversationStore.StoredMessage],
        into store: ChatConversationStore,
        chatId: String,
        as binding: CaptureAccountScope.AccountBinding
    ) -> Bool {
        CaptureAccountScope.perform(as: binding) { _ in
            guard store.activeId == chatId else { return false }
            store.setMessages(messages, for: chatId)
            return true
        } == true
    }
}
