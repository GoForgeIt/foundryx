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
        case refused
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

    @Published public private(set) var messages: [Message] = []
    @Published public private(set) var turnState: TurnState = .idle
    @Published public private(set) var lastBoundary: String?
    @Published public private(set) var connection: ConnectionState = .idle

    public init() {}

    /// Drive the connection indicator from the app's stream loop.
    public func setConnection(_ state: ConnectionState) { connection = state }

    /// Append the user's outgoing message and open an empty assistant message to stream into.
    public func beginUserTurn(_ text: String) {
        messages.append(Message(role: "user", text: text))
        messages.append(Message(role: "assistant", text: ""))
        turnState = .streaming
    }

    /// Fold one DoorEvent into the rendered state. Pure + synchronous so it's trivially
    /// testable and the iOS app can call it from its stream loop on the main actor.
    public func apply(_ event: DoorEvent) {
        switch event {
        case .session:
            break
        case .assistantDelta(let t):
            appendAssistant(t)
        case .boundary(let label):
            lastBoundary = label
            if let targetId = Self.parseRoutedTarget(label) { stampRoute(targetId) }
        case .toolCall, .toolResult:
            break
        case .approvalRequest(let callId, let name, let args):
            turnState = .awaitingApproval(callId: callId, name: name, args: args)
        case .done(let reason):
            turnState = (reason == "refused") ? .refused : .completed(reason: reason)
        case .other:
            break
        }
    }

    public func applyAll(_ events: [DoorEvent]) { for e in events { apply(e) } }

    /// The text of the in-flight / last assistant message — what the bubble renders.
    public var assistantText: String {
        messages.last(where: { $0.role == "assistant" })?.text ?? ""
    }

    private func appendAssistant(_ t: String) {
        if case .streaming = turnState {} else { turnState = .streaming }
        if let idx = messages.lastIndex(where: { $0.role == "assistant" }) {
            messages[idx].text += t
        } else {
            messages.append(Message(role: "assistant", text: t))
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
