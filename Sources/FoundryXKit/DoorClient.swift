// DoorClient.swift — FoundryX's real networking core: the authenticated HTTP/SSE
// client for the local Foundry "3a door" (gateway → kiln-session). Production-shaped
// and reused by the M3 iOS app; exercised here by the Swift Brine runner against a
// REAL door. No mocks.
//
// Door contract (3a, foundry): POST {base}/foundryx/chat with `Authorization: Bearer`,
// body {message, platform, chat_id, org, sensitivity?} → SSE stream of runtime events.
// Unauthenticated → 401 before any session/inference.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the door lives + the bearer token to present.
public struct DoorTarget: Sendable {
    /// Base URL, e.g. http://127.0.0.1:14288 — the `/foundryx/chat` path is appended.
    public let baseURL: URL
    public let bearer: String
    public init(baseURL: URL, bearer: String) {
        self.baseURL = baseURL
        self.bearer = bearer
    }
}

/// One outbound chat turn. `sensitivity` defaults to "public" server-side when nil.
public struct ChatRequest: Encodable, Sendable {
    public let message: String
    public let platform: String
    public let chatId: String
    public let org: String
    public let sensitivity: String?

    public init(message: String, platform: String, chatId: String, org: String, sensitivity: String? = nil) {
        self.message = message
        self.platform = platform
        self.chatId = chatId
        self.org = org
        self.sensitivity = sensitivity
    }

    enum CodingKeys: String, CodingKey {
        case message, platform, org, sensitivity
        case chatId = "chat_id"
    }
}

/// The runtime SSE events the door relays (the kiln-session event stream).
public enum DoorEvent: Equatable, Sendable {
    case session(sessionId: String)
    case assistantDelta(text: String)
    case toolCall(callId: String, name: String, args: String)
    case toolResult(callId: String, content: String, isError: Bool)
    case boundary(label: String)
    case approvalRequest(callId: String, name: String, args: String)
    case done(reason: String)
    case other(type: String, raw: String)

    /// Parse one SSE `data:` payload (a runtime event JSON) into a typed event.
    public static func parse(_ payload: String) -> DoorEvent {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return .other(type: "?", raw: payload)
        }
        func str(_ k: String) -> String { (obj[k] as? String) ?? "" }
        func args(_ k: String) -> String {
            guard let v = obj[k] else { return "" }
            if let s = v as? String { return s }
            if let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) { return s }
            return ""
        }
        switch type {
        case "session": return .session(sessionId: str("session_id"))
        case "assistant_delta": return .assistantDelta(text: str("text"))
        case "tool_call": return .toolCall(callId: str("call_id"), name: str("name"), args: args("args"))
        case "tool_result": return .toolResult(callId: str("call_id"), content: str("content"), isError: (obj["is_error"] as? Bool) ?? false)
        case "boundary": return .boundary(label: str("label"))
        case "approval_request": return .approvalRequest(callId: str("call_id"), name: str("name"), args: args("args"))
        case "done": return .done(reason: str("reason"))
        default: return .other(type: type, raw: payload)
        }
    }
}

public enum DoorError: Error, Equatable, Sendable {
    case unauthorized          // 401 — rejected before any session/inference
    case http(Int)
    case transport(String)
}

/// The authenticated door client. `events(for:)` streams the turn; `collect(_:)` is a
/// convenience that drains to completion (used by tests + simple callers).
public final class DoorClient: @unchecked Sendable {
    private let target: DoorTarget
    private let session: URLSession
    private let log: DoorLog?

    public init(target: DoorTarget,
                session: URLSession = URLSession(configuration: .ephemeral),
                log: DoorLog? = nil) {
        self.target = target
        self.session = session
        self.log = log
    }

    /// A short one-line summary of a DoorEvent for the log.
    static func summary(_ e: DoorEvent) -> String {
        switch e {
        case .session(let sid): return "session \(sid.prefix(8))"
        case .assistantDelta(let t): return "assistant_delta (\(t.count) chars)"
        case .toolCall(_, let name, _): return "tool_call \(name)"
        case .toolResult(_, _, let isErr): return "tool_result\(isErr ? " (error)" : "")"
        case .boundary(let label): return "boundary: \(label)"
        case .approvalRequest(_, let name, _): return "approval_request \(name)"
        case .done(let reason): return "done: \(reason)"
        case .other(let type, _): return "other: \(type)"
        }
    }

    private func chatRequest(_ req: ChatRequest) throws -> URLRequest {
        var r = URLRequest(url: target.baseURL.appendingPathComponent("foundryx/chat"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 60
        r.httpBody = try JSONEncoder().encode(req)
        return r
    }

    /// Stream the turn's SSE events. Throws `DoorError.unauthorized` on 401 (before any
    /// event), `.http`/`.transport` on other failures. Terminates after `done`.
    public func events(for req: ChatRequest) -> AsyncThrowingStream<DoorEvent, Error> {
        AsyncThrowingStream { continuation in
            let log = self.log
            let task = Task {
                do {
                    let request = try self.chatRequest(req)
                    log?.info("→ POST \(request.url?.absoluteString ?? "?") chat_id=\(req.chatId) org=\(req.org) (\(req.message.count) chars)")
                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        log?.error("✗ non-HTTP response")
                        throw DoorError.transport("non-HTTP response")
                    }
                    log?.info("← HTTP \(http.statusCode)")
                    if http.statusCode == 401 {
                        log?.error("✗ 401 unauthorized — bad or missing bearer token")
                        throw DoorError.unauthorized
                    }
                    guard http.statusCode == 200 else {
                        log?.error("✗ HTTP \(http.statusCode) (expected 200)")
                        throw DoorError.http(http.statusCode)
                    }
                    var count = 0
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }   // SSE data frames only
                        let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty || payload == "[DONE]" { continue }
                        let event = DoorEvent.parse(payload)
                        count += 1
                        log?.info("event \(DoorClient.summary(event))")
                        continuation.yield(event)
                        if case .done = event { break }
                    }
                    log?.info("✓ stream finished (\(count) events)")
                    continuation.finish()
                } catch {
                    // The 3a door streams SSE with `Connection: close` and drops the socket at
                    // end-of-turn; URLSession can surface that as -1005 (network connection lost)
                    // even after all events (incl. `done`) were delivered. Treat it as a graceful
                    // end so the collected events stand — only a genuine pre/mid-stream failure
                    // (auth, HTTP error, timeout) propagates.
                    let ns = error as NSError
                    if ns.code == NSURLErrorNetworkConnectionLost {
                        log?.warn("-1005 NetworkConnectionLost — treating as graceful end (door closed socket after the turn)")
                        continuation.finish()
                    } else {
                        // This is the failure that used to vanish silently — surface it loudly.
                        log?.error("✗ stream error: domain=\(ns.domain) code=\(ns.code) — \(ns.localizedDescription)")
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Drain the turn to completion, returning all events in order.
    public func collect(_ req: ChatRequest) async throws -> [DoorEvent] {
        var out: [DoorEvent] = []
        for try await event in events(for: req) { out.append(event) }
        return out
    }

    /// Finalize a closed conversation: tell the door to assemble the stored
    /// capture's segments and ingest them to Lore (`POST /foundryx/capture/{id}/finalize`,
    /// bearer-gated). Call this ONLY after the capture's segments are all ACK'd
    /// (durably on the desktop), else there's nothing for the door to assemble.
    ///
    /// Resilient by contract: any non-2xx (door down → transport error; Lore down
    /// → the door returns 502/503) throws, so the caller leaves the capture
    /// un-finalized and retries on the next sync / app-foreground (the door-side
    /// finalize + the door's own retry-sweep are both idempotent, so a retry never
    /// double-ingests). A 200 means the door advanced the capture to Lore.
    public func finalize(captureId: String) async throws {
        let s = target.baseURL.absoluteString
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        guard let url = URL(string: "\(base)/foundryx/capture/\(captureId)/finalize") else {
            throw DoorError.transport("bad finalize url")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 60
        log?.info("→ POST finalize capture=\(captureId)")
        let (_, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else {
            throw DoorError.transport("non-HTTP response")
        }
        if http.statusCode == 401 { throw DoorError.unauthorized }
        guard http.statusCode == 200 else {
            log?.warn("finalize capture=\(captureId) → HTTP \(http.statusCode) (will retry)")
            throw DoorError.http(http.statusCode)
        }
        log?.info("✓ finalize capture=\(captureId) accepted by door")
    }

    /// Relay a gate decision to the door's approvals endpoint
    /// (`POST /foundryx/chat/{session}/approvals/{call}` — answers a suspended turn).
    /// `decision` is "once" | "always" | "reject"; the suspended /chat SSE then resumes.
    public func answerApproval(sessionId: String, callId: String,
                               decision: String, feedback: String? = nil) async throws {
        let s = target.baseURL.absoluteString
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        guard let url = URL(string: "\(base)/foundryx/chat/\(sessionId)/approvals/\(callId)") else {
            throw DoorError.transport("bad approvals url")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
        var payload: [String: String] = ["decision": decision]
        if let f = feedback { payload["feedback"] = f }
        r.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await session.data(for: r)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 { throw DoorError.unauthorized }
    }
}
