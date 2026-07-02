// ChatViewModel — the FoundryX chat surface state, fed by DoorEvents from the real
// door. The M3 iOS app binds this to its SwiftUI ChatView; the Brine UI scenario hosts
// the same view model + view to assert real rendered state from a real streamed turn.
//
// ObservableObject (not @Observable) keeps this buildable on the package's macOS 13
// floor; the iOS app uses the same type unchanged.

import Foundation

public final class ChatViewModel: ObservableObject {
    public struct Message: Identifiable, Equatable {
        public let id = UUID()
        public let role: String          // "user" | "assistant"
        public var text: String
        /// Router target_id that handled this (assistant) message, e.g.
        /// "local-qwen3-8b" — stamped from the door's `routed:` boundary. nil until routed.
        public var routedVia: String?

        /// True when the routing target ran on-device (target_id prefixed "local").
        public var routeIsLocal: Bool { (routedVia ?? "").hasPrefix("local") }
        /// Friendly model label for display — the target_id with a leading
        /// "local-"/"cloud-" stripped (falls back to the raw id).
        public var routeModelLabel: String? {
            guard let r = routedVia else { return nil }
            for p in ["local-", "cloud-"] where r.hasPrefix(p) { return String(r.dropFirst(p.count)) }
            return r
        }
    }

    public enum TurnState: Equatable {
        case idle
        case streaming
        case awaitingApproval(callId: String, name: String, args: String)
        case completed(reason: String)
        /// The turn was refused/blocked. `reason` is the door's clear, human-readable
        /// explanation (confidential kept local, auth expired, …) when one was surfaced.
        case refused(reason: String?)
        /// The turn FAILED to send/stream (transport error, auth, no reply). `reason` is
        /// humane, user-facing copy (the raw detail is logged, never shown). Distinct from
        /// `.refused` (the door answered with a deliberate block) — a failure is recoverable
        /// via the "tap to retry" chip, which re-sends the same user text.
        case failed(reason: String)
    }

    /// Whether the current/last turn failed to send — the chat surface skips persisting a
    /// failed turn (the message "didn't send", so it isn't recorded; retry re-sends it live).
    public var didTurnFail: Bool {
        if case .failed = turnState { return true }
        return false
    }

    /// Delivery state of an approval DECISION — the approval card is honest about whether
    /// the answer actually reached the door (it used to be fire-and-forget). Drives the
    /// "Sending…" state and a recoverable "Couldn't send — try again" on final failure.
    public enum ApprovalDelivery: Equatable {
        case idle        // buttons shown, awaiting the user's decision
        case sending     // the answer is in flight (retrying with backoff)
        case failed      // every retry exhausted — restore the buttons + inline error
    }

    /// Door connection/transport state — distinct from `turnState` (which tracks the
    /// in-flight turn). This is what the status indicator renders, and it surfaces
    /// transport failures (cannot-connect / ATS / timeout) that otherwise vanish.
    public enum ConnectionState: Equatable {
        case idle
        case connecting
        case streaming
        case completed(reason: String)
        case error(detail: String)
    }

    /// End-of-turn timing the door reports (ms; -1 = phase didn't happen).
    public struct TurnTiming: Equatable, Sendable {
        public let routeMs: Int, ttftMs: Int, genMs: Int, totalMs: Int, tokens: Int
    }

    @Published public private(set) var messages: [Message] = []
    @Published public private(set) var turnState: TurnState = .idle
    @Published public private(set) var lastBoundary: String?
    @Published public private(set) var connection: ConnectionState = .idle
    /// Elapsed ms (from the door's keepalive) while waiting on the FIRST token — drives a
    /// "thinking… Ns" hint so the user sees it's moving. 0 once tokens stream / between turns.
    @Published public private(set) var thinkingMs: Int = 0
    /// When the current turn was sent — lets the UI tick a SMOOTH local "thinking… Ns"
    /// timer (every second) instead of jumping only when a sparse door keepalive lands.
    /// Set on send; cleared the moment the first token arrives or the turn ends.
    @Published public private(set) var turnStartedAt: Date?
    /// The last completed turn's timing summary (for a subtle "took Ns · first token Ns" line).
    @Published public private(set) var lastTiming: TurnTiming?
    /// The clear failure reason the door surfaced for the current/last turn (set by an
    /// `error` event, which the door emits just before a refused `done`). Drives the
    /// refusal message instead of a bare "refused". Cleared at the start of each turn.
    @Published public private(set) var lastErrorReason: String?
    /// Tools the agent ran (or is running) this turn — surfaced so the user SEES what the
    /// agent did, not just its text. Cleared at the start of each user turn.
    @Published public private(set) var toolRuns: [ToolRun] = []
    /// The text of the last user turn — lets the chat surface re-send it verbatim on a
    /// failed-turn retry without the composer having to retain it.
    @Published public private(set) var lastUserText: String = ""
    /// Delivery state of the current approval decision (buttons → sending → failed).
    @Published public private(set) var approvalDelivery: ApprovalDelivery = .idle

    /// One agent tool invocation, for display: a name + args, marked done/failed when the
    /// matching result lands.
    public struct ToolRun: Identifiable, Equatable, Sendable {
        public var id: String        // callId
        public var name: String
        public var args: String
        public var done: Bool
        public var isError: Bool
    }

    public init() {}

    /// Drive the connection indicator from the app's stream loop.
    public func setConnection(_ state: ConnectionState) { connection = state }

    /// Append the user's outgoing message and open an empty assistant message to stream into.
    public func beginUserTurn(_ text: String) {
        messages.append(Message(role: "user", text: text))
        messages.append(Message(role: "assistant", text: ""))
        lastUserText = text
        turnState = .streaming
        thinkingMs = 0
        lastTiming = nil
        lastErrorReason = nil
        toolRuns = []
        approvalDelivery = .idle
        turnStartedAt = now()
    }

    /// Drive the approval card's delivery state from the app's answer loop.
    public func setApprovalDelivery(_ state: ApprovalDelivery) { approvalDelivery = state }

    /// Mark the in-flight turn as FAILED (a stream/transport error). Drops the phantom
    /// empty assistant bubble we opened for the reply — a failed turn must never render
    /// (or persist) a blank assistant message — and stops the "thinking…" timer. The user
    /// bubble stays put so the "tap to retry" chip can re-send it verbatim.
    public func failTurn(reason: String) {
        if let idx = messages.lastIndex(where: { $0.role == "assistant" }), messages[idx].text.isEmpty {
            messages.remove(at: idx)
        }
        turnState = .failed(reason: reason)
        thinkingMs = 0
        turnStartedAt = nil
    }

    /// Pull the failed turn's user text back for a retry, removing its now-orphaned user
    /// bubble so the re-send doesn't leave a duplicate, and resetting to idle. Returns nil
    /// when there's nothing to retry (the turn didn't fail / had no text).
    public func takeRetryText() -> String? {
        guard case .failed = turnState else { return nil }
        if let idx = messages.lastIndex(where: { $0.role == "user" }) {
            messages.remove(at: idx)
        }
        turnState = .idle
        return lastUserText.isEmpty ? nil : lastUserText
    }

    /// Injectable clock so tests are deterministic (production = real Date).
    var now: () -> Date = { Date() }

    /// Fold one DoorEvent into the rendered state. Pure + synchronous so it's trivially
    /// testable and the iOS app can call it from its stream loop on the main actor.
    public func apply(_ event: DoorEvent) {
        switch event {
        case .session:
            break
        case .assistantDelta(let t):
            thinkingMs = 0; turnStartedAt = nil   // first token arrived → drop the "thinking…" hint
            appendAssistant(t)
        case .boundary(let label):
            lastBoundary = label
            if let targetId = Self.parseRoutedTarget(label) { stampRoute(targetId) }
        case .keepalive(let ms):
            // Door heartbeat while the model works. Show elapsed only until tokens stream.
            if assistantText.isEmpty { thinkingMs = ms }
        case .timing(let r, let t, let g, let total, let n):
            lastTiming = TurnTiming(routeMs: r, ttftMs: t, genMs: g, totalMs: total, tokens: n)
        case .toolCall(let callId, let name, let args):
            // Surface the action the agent is taking (was invisible). Dedup by callId.
            if !toolRuns.contains(where: { $0.id == callId }) {
                toolRuns.append(ToolRun(id: callId, name: name, args: args, done: false, isError: false))
            }
        case .toolResult(let callId, _, let isError):
            if let i = toolRuns.firstIndex(where: { $0.id == callId }) {
                toolRuns[i].done = true
                toolRuns[i].isError = isError
            }
        case .approvalRequest(let callId, let name, let args):
            approvalDelivery = .idle   // a fresh gate always opens with its buttons
            turnState = .awaitingApproval(callId: callId, name: name, args: args)
        case .error(_, let reason):
            // The door surfaced a clear failure (emitted just before a refused `done`).
            // Hold the reason so the `done` can render it instead of a bare "refused".
            lastErrorReason = reason.isEmpty ? nil : reason
            turnState = .refused(reason: lastErrorReason)
        case .done(let reason):
            thinkingMs = 0; turnStartedAt = nil
            turnState = (reason == "refused") ? .refused(reason: lastErrorReason)
                                              : .completed(reason: reason)
        case .other:
            break
        }
    }

    public func applyAll(_ events: [DoorEvent]) { for e in events { apply(e) } }

    /// Load a conversation's persisted history into the live view (used when switching
    /// chats). Resets the in-flight turn state — we're rendering a settled conversation.
    public func load(from stored: [ChatConversationStore.StoredMessage]) {
        messages = stored.map { Message(role: $0.role, text: $0.text, routedVia: $0.routedVia) }
        turnState = .idle
        thinkingMs = 0
        turnStartedAt = nil
        lastTiming = nil
        approvalDelivery = .idle
    }

    /// Snapshot the current rendered messages back into durable form (persisted into the
    /// ChatConversationStore at end-of-turn). A failed turn must NEVER persist the blank
    /// assistant bubble we opened for its (never-arriving) reply — strip a trailing EMPTY
    /// assistant message defensively (`failTurn` already drops it from the live view).
    public func snapshot() -> [ChatConversationStore.StoredMessage] {
        var msgs = messages
        if case .failed = turnState, let last = msgs.last, last.role == "assistant", last.text.isEmpty {
            msgs.removeLast()
        }
        return msgs.map { .init(role: $0.role, text: $0.text, routedVia: $0.routedVia) }
    }

    /// The text of the in-flight / last assistant message — what the bubble renders.
    public var assistantText: String {
        messages.last(where: { $0.role == "assistant" })?.text ?? ""
    }

    private func appendAssistant(_ t: String) {
        if case .streaming = turnState {} else { turnState = .streaming }
        if let idx = messages.lastIndex(where: { $0.role == "assistant" }) {
            // Models (qwen3) often lead with "\n\n" — while the bubble is still empty,
            // drop leading whitespace so the reply doesn't render with a blank gap on top.
            let wasEmpty = messages[idx].text.isEmpty
            var combined = messages[idx].text + t
            if wasEmpty { combined = String(combined.drop(while: { $0.isWhitespace })) }
            messages[idx].text = combined
        } else {
            messages.append(Message(role: "assistant", text: String(t.drop(while: { $0.isWhitespace }))))
        }
    }

    /// Parse a `routed: <target_id>` boundary label → the target_id (nil if not a route).
    static func parseRoutedTarget(_ label: String) -> String? {
        let prefix = "routed:"
        guard label.hasPrefix(prefix) else { return nil }
        let tid = label.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return tid.isEmpty ? nil : tid
    }

    /// Stamp the routing target_id onto the current (last) assistant message.
    private func stampRoute(_ targetId: String) {
        if let idx = messages.lastIndex(where: { $0.role == "assistant" }) {
            messages[idx].routedVia = targetId
        }
    }
}
