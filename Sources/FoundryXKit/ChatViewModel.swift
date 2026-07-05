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

    /// One tool action the agent took during a turn — a `tool_call` (read/write/edit/bash/
    /// search/MCP), later completed by its matching `tool_result`. This is what the inline
    /// activity trace renders so the "long pause" reads as a visible agent working, the way
    /// Claude Code shows every read/edit/bash. The loop + tool catalog are Kiln's; this only
    /// surfaces them.
    public struct ToolActivity: Identifiable, Equatable, Sendable {
        public let id: String            // the tool call id (kiln `id`)
        public let name: String          // tool name: read / write / edit / bash / grep / …
        public let args: String          // raw args JSON (drives the row summary + expansion)
        /// The tool's output — nil while the call is still running (no `tool_result` yet).
        public var resultContent: String?
        public var isError: Bool

        public init(id: String, name: String, args: String,
                    resultContent: String? = nil, isError: Bool = false) {
            self.id = id; self.name = name; self.args = args
            self.resultContent = resultContent; self.isError = isError
        }

        /// Still awaiting its `tool_result`.
        public var isRunning: Bool { resultContent == nil }
        /// SF Symbol glyph for the row (native, adaptive — no emoji).
        public var symbol: String { ChatViewModel.toolSymbol(name) }
        /// Human verb for the action, tensed by whether it's finished ("read" vs "reading").
        public var verb: String { ChatViewModel.toolVerb(name, done: !isRunning) }
        /// The concise primary argument shown on the row — a file basename, a command, a
        /// search pattern — extracted from `args` by tool kind.
        public var primaryArg: String { ChatViewModel.primaryArg(name: name, argsJSON: args) }
        /// "read Foo.swift" / "ran: ls -la" — the one-line row label.
        public var summary: String {
            let a = primaryArg
            if name.lowercased().contains("bash") || name.lowercased() == "run" || name.lowercased() == "shell" {
                return a.isEmpty ? verb : "\(verb): \(a)"
            }
            return a.isEmpty ? verb : "\(verb) \(a)"
        }
    }

    /// The concrete action an `approval_request` is asking the user to consent to, parsed
    /// from the tool name + args so the card can show *exactly what will run* (the command,
    /// or the file + its before/after) instead of a bare "Approve read?".
    public struct ApprovalDetail: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case command, fileEdit, fileWrite, generic }
        public var kind: Kind
        public var title: String            // "Run command" / "Edit Foo.swift" / …
        public var command: String?         // .command
        public var filePath: String?        // .fileEdit / .fileWrite
        public var oldText: String?         // .fileEdit
        public var newText: String?         // .fileEdit / .fileWrite (content)
        public var body: String?            // .generic — pretty-printed args
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
    /// The current turn's inline tool-activity trace, in the order the agent took each
    /// action. Cleared at the start of each user turn; folded from `toolCall`/`toolResult`.
    @Published public private(set) var activities: [ToolActivity] = []
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
    /// The text of the last user turn — lets the chat surface re-send it verbatim on a
    /// failed-turn retry without the composer having to retain it.
    @Published public private(set) var lastUserText: String = ""
    /// Delivery state of the current approval decision (buttons → sending → failed).
    @Published public private(set) var approvalDelivery: ApprovalDelivery = .idle

    public init() {}

    /// Drive the connection indicator from the app's stream loop.
    public func setConnection(_ state: ConnectionState) { connection = state }

    /// Append the user's outgoing message and open an empty assistant message to stream into.
    public func beginUserTurn(_ text: String) {
        messages.append(Message(role: "user", text: text))
        messages.append(Message(role: "assistant", text: ""))
        lastUserText = text
        turnState = .streaming
        activities = []
        thinkingMs = 0
        lastTiming = nil
        lastErrorReason = nil
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

    /// Pull the failed turn's user text back for a retry, removing the WHOLE failed turn
    /// (the user bubble AND any partially-streamed assistant text after it) so the re-send
    /// leaves neither a duplicate user message nor an orphaned partial reply. Resets to
    /// idle. Returns nil when there's nothing to retry (the turn didn't fail / had no text).
    public func takeRetryText() -> String? {
        guard case .failed = turnState else { return nil }
        if let idx = messages.lastIndex(where: { $0.role == "user" }) {
            messages.removeSubrange(idx...)
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
            // The agent invoked a tool — open a running row in the inline trace. If we
            // somehow saw this id already (retransmit), refresh it in place.
            if let idx = activities.firstIndex(where: { $0.id == callId }) {
                activities[idx] = ToolActivity(id: callId, name: name, args: args)
            } else {
                activities.append(ToolActivity(id: callId, name: name, args: args))
            }
        case .toolResult(let callId, let content, let isError):
            // The tool returned — close its row (stops "running", carries the output for
            // expansion). A result with no prior call (mid-stream join) still shows a row.
            if let idx = activities.firstIndex(where: { $0.id == callId }) {
                activities[idx].resultContent = content
                activities[idx].isError = isError
            } else {
                activities.append(ToolActivity(id: callId, name: "tool", args: "",
                                               resultContent: content, isError: isError))
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
        activities = []
        thinkingMs = 0
        turnStartedAt = nil
        lastTiming = nil
        approvalDelivery = .idle
    }

    // MARK: - Derived legibility state (pure, testable)

    /// Steps taken this turn — one per tool action (a proxy for agentic-loop iterations),
    /// what "Done (N steps)" reports. Zero for a plain answer with no tool use.
    public var stepCount: Int { activities.count }

    /// The live status line: what the agent is doing right now. Drives the "Thinking… /
    /// Running <tool>… / Waiting for your approval / Done (N steps)" banner.
    public var statusLine: String? {
        switch turnState {
        case .idle, .refused, .failed:
            // .failed renders its own humane copy + retry chip — no status line on top.
            return nil
        case .awaitingApproval:
            return "Waiting for your approval"
        case .completed:
            let n = stepCount
            return n > 0 ? "Done (\(n) step\(n == 1 ? "" : "s"))" : "Done"
        case .streaming:
            if let running = activities.last(where: { $0.isRunning }) {
                // The row summary already reads naturally ("reading foo.rs", "running: ls") —
                // capitalize it into a status ("Reading foo.rs…", "Running: ls…").
                return Self.capitalizingFirst(running.summary) + "…"
            }
            return assistantText.isEmpty ? "Thinking…" : "Responding…"
        }
    }

    /// Uppercase only the first character (leaves the rest — filenames, commands — intact).
    static func capitalizingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    /// Parse an `approval_request`'s tool name + args JSON into the concrete action it's
    /// asking to run — the command, or the file + its before/after — so the approval card
    /// shows exactly what will happen before the user consents.
    public static func approvalDetail(name: String, argsJSON: String) -> ApprovalDetail {
        let obj = (argsJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        func s(_ keys: [String]) -> String? {
            for k in keys { if let v = obj[k] as? String, !v.isEmpty { return v } }
            return nil
        }
        let lname = name.lowercased()
        if lname.contains("bash") || lname == "run" || lname == "shell" || lname == "exec" {
            return ApprovalDetail(kind: .command, title: "Run command",
                                  command: s(["command", "cmd", "script"]) ?? argsJSON)
        }
        if lname.contains("edit") || lname == "str_replace" || lname == "replace" {
            let path = s(["file_path", "path", "filename", "file"])
            return ApprovalDetail(kind: .fileEdit,
                                  title: "Edit \(path.map(baseName) ?? "file")",
                                  filePath: path,
                                  oldText: s(["old_string", "old_str", "old", "before"]),
                                  newText: s(["new_string", "new_str", "new", "after"]))
        }
        if lname.contains("write") || lname == "create" || lname == "create_file" {
            let path = s(["file_path", "path", "filename", "file"])
            return ApprovalDetail(kind: .fileWrite,
                                  title: "Write \(path.map(baseName) ?? "file")",
                                  filePath: path,
                                  newText: s(["content", "contents", "text", "body"]))
        }
        // Generic tool (MCP call, search, …) — show the tool + pretty-printed args.
        return ApprovalDetail(kind: .generic, title: "Run \(name)",
                              body: prettyArgs(obj, fallback: argsJSON))
    }

    // MARK: - Tool presentation helpers (pure, testable)

    /// SF Symbol for a tool row by tool name (adaptive, native — no emoji).
    static func toolSymbol(_ name: String) -> String {
        switch classify(name) {
        case .read:   return "doc.text"
        case .write:  return "square.and.pencil"
        case .edit:   return "pencil"
        case .bash:   return "terminal"
        case .search: return "magnifyingglass"
        case .list:   return "folder"
        case .other:  return "wrench.and.screwdriver"
        }
    }

    /// Human verb for a tool action, tensed by completion ("read" vs "reading").
    static func toolVerb(_ name: String, done: Bool) -> String {
        switch classify(name) {
        case .read:   return done ? "read" : "reading"
        case .write:  return done ? "wrote" : "writing"
        case .edit:   return done ? "edited" : "editing"
        case .bash:   return done ? "ran" : "running"
        case .search: return done ? "searched" : "searching"
        case .list:   return done ? "listed" : "listing"
        case .other:  return name
        }
    }

    /// The concise primary argument to show on a tool row — a file basename, a command,
    /// a search pattern — chosen by tool kind, parsed from the args JSON.
    static func primaryArg(name: String, argsJSON: String) -> String {
        guard let data = argsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        func s(_ keys: [String]) -> String? {
            for k in keys { if let v = obj[k] as? String, !v.isEmpty { return v } }
            return nil
        }
        switch classify(name) {
        case .bash:
            return s(["command", "cmd", "script"]) ?? ""
        case .search:
            return s(["pattern", "query", "regex"]) ?? ""
        case .read, .write, .edit, .list:
            return s(["file_path", "path", "filename", "file"]).map(baseName)
                ?? s(["pattern", "query"]) ?? ""
        case .other:
            return s(["file_path", "path", "command", "query", "pattern"]).map { baseName($0) } ?? ""
        }
    }

    private enum ToolKind { case read, write, edit, bash, search, list, other }
    private static func classify(_ name: String) -> ToolKind {
        let n = name.lowercased()
        if n.contains("bash") || n == "run" || n == "shell" || n == "exec" { return .bash }
        if n.contains("edit") || n == "str_replace" || n == "replace" { return .edit }
        if n.contains("write") || n == "create" { return .write }
        if n.contains("read") || n == "cat" || n == "view" || n == "open" { return .read }
        if n.contains("grep") || n.contains("search") || n.contains("find") { return .search }
        if n.contains("glob") || n.contains("ls") || n.contains("list") || n.contains("dir") { return .list }
        return .other
    }

    /// Last path component of a file path (unchanged if it isn't one).
    static func baseName(_ path: String) -> String {
        let comps = path.split(separator: "/")
        return comps.last.map(String.init) ?? path
    }

    /// Pretty-print an args object as `key: value` lines; falls back to the raw JSON.
    private static func prettyArgs(_ obj: [String: Any], fallback: String) -> String {
        guard !obj.isEmpty else { return fallback }
        return obj.keys.sorted().map { k in
            let v = obj[k]
            let sv: String
            if let s = v as? String { sv = s }
            else if let d = try? JSONSerialization.data(withJSONObject: v as Any),
                    let s = String(data: d, encoding: .utf8) { sv = s }
            else { sv = String(describing: v ?? "") }
            return "\(k): \(sv)"
        }.joined(separator: "\n")
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
