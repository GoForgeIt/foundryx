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
    /// OPTIONAL (M5 R1b, gated, default OFF): route turns through the blind E2E relay
    /// instead of LAN-direct HTTP. When nil, the LAN-direct path is used unchanged.
    public let relay: RelayConfig?
    /// DORMANT (M5 R1c, default OFF): when true AND a relay is set, door turns multiplex
    /// over ONE persistent connection (DoorConnection) instead of a fresh connection per
    /// turn. Flip ON only in lockstep with a mux-capable desktop door; until then the
    /// proven per-turn RelayTransport path is used. Nothing reads this yet.
    public let useMux: Bool

    public init(baseURL: URL, bearer: String, relay: RelayConfig? = nil, useMux: Bool = false) {
        self.baseURL = baseURL
        self.bearer = bearer
        self.relay = relay
        self.useMux = useMux
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

/// The OPTIONAL finalize body the phone POSTs with `/foundryx/capture/{id}/finalize`,
/// carrying the conversation's real boundary metadata (F1, F9). Matches the door's
/// optional body `{started_at?, ended_at?, location?:{lat,long,label}}` — the door
/// persists it onto the manifest and threads it into the ingest envelope. Encoded
/// only when there's something to send (a nil meta → empty body → still valid).
public struct FinalizeBody: Encodable, Sendable {
    public let startedAt: UInt64?
    public let endedAt: UInt64?
    public let location: ConversationLocation?

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case location
    }

    public init(meta: ConversationMeta) {
        self.startedAt = meta.startedAt
        self.endedAt = meta.endedAt
        self.location = meta.location
    }
}

/// The door's status endpoint reply (`GET /foundryx/capture/{phone_id}/status`).
/// Stage-only in Phase A (title/transcript arrive in Phase B). `stage` is the
/// user-facing chip; `loreCaptureId` is present once the capture reaches Lore.
public struct CaptureStatusResponse: Decodable, Sendable, Equatable {
    public let stage: String
    public let loreCaptureId: String?
    public let transcribed: Bool
    /// The Kiln-generated title (Phase B) once the door has cached it — surfaced on
    /// the poll so the conversation CARD can show it without a separate /content call.
    public let title: String?
    public let summary: String?

    enum CodingKeys: String, CodingKey {
        case stage
        case loreCaptureId = "lore_capture_id"
        case transcribed
        case title
        case summary
    }

    public init(stage: String, loreCaptureId: String?, transcribed: Bool,
                title: String? = nil, summary: String? = nil) {
        self.stage = stage
        self.loreCaptureId = loreCaptureId
        self.transcribed = transcribed
        self.title = title
        self.summary = summary
    }
}

/// The door's transcript reply (`GET /foundryx/capture/{phone_id}/content`, Phase
/// B) — the conversation text Lore produced + when it was captured. `found` is
/// false (the door 404s with `{found:false}`) until Lore has transcribed it.
public struct CaptureContent: Decodable, Sendable, Equatable {
    public let transcript: String
    public let capturedAt: Int
    public let found: Bool
    /// Kiln-generated title/summary (Phase B). `nil` until generated; `summarizing`
    /// is true while the door is producing them in the background (the view shows a
    /// "Summarizing…" hint and re-fetches). `titleModel` records which LLM produced
    /// the title (the benchmark hook).
    public let title: String?
    public let summary: String?
    public let titleModel: String?
    public let summarizing: Bool

    enum CodingKeys: String, CodingKey {
        case transcript, capturedAt, found, title, summary, titleModel, summarizing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        capturedAt = try c.decodeIfPresent(Int.self, forKey: .capturedAt) ?? 0
        found = try c.decodeIfPresent(Bool.self, forKey: .found) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        titleModel = try c.decodeIfPresent(String.self, forKey: .titleModel)
        summarizing = try c.decodeIfPresent(Bool.self, forKey: .summarizing) ?? false
    }

    public init(transcript: String, capturedAt: Int, found: Bool,
                title: String? = nil, summary: String? = nil,
                titleModel: String? = nil, summarizing: Bool = false) {
        self.transcript = transcript
        self.capturedAt = capturedAt
        self.found = found
        self.title = title
        self.summary = summary
        self.titleModel = titleModel
        self.summarizing = summarizing
    }
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
                // Remote mode: the door's /foundryx/chat is behind the relay tunnel.
                // Run one E2E turn, then yield the parsed SSE events (the door streams
                // the same SSE body over the relay it would over LAN-direct HTTP).
                if let relay = self.target.relay?.interactive() {
                    do {
                        let httpBytes = RelayHTTP.rawRequest(
                            method: "POST", path: "/foundryx/chat", bearer: self.target.bearer,
                            extraHeaders: [:], contentType: "application/json",
                            accept: "text/event-stream", body: try JSONEncoder().encode(req))
                        log?.info("→ relay chat turn chat_id=\(req.chatId) org=\(req.org) (\(req.message.count) chars)")
                        let transport = RelayTransport(config: relay, session: self.session, log: log)
                        let frames = try await transport.roundTrip(requestBytes: httpBytes)
                        var buf = Data(); for f in frames { buf.append(f) }
                        let resp = try RelayHTTP.parseResponse(buf)
                        log?.info("← relay HTTP \(resp.status)")
                        if resp.status == 401 { throw DoorError.unauthorized }
                        guard resp.status == 200 else { throw DoorError.http(resp.status) }
                        var count = 0
                        let text = String(decoding: resp.body, as: UTF8.self)
                        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                            let line = String(rawLine)
                            guard line.hasPrefix("data:") else { continue }
                            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                            if payload.isEmpty || payload == "[DONE]" { continue }
                            let event = DoorEvent.parse(payload)
                            count += 1
                            log?.info("event \(DoorClient.summary(event))")
                            continuation.yield(event)
                            if case .done = event { break }
                        }
                        log?.info("✓ relay chat turn parsed \(count) event(s)")
                        continuation.finish()
                    } catch {
                        let ns = error as NSError
                        log?.error("✗ relay chat error: domain=\(ns.domain) code=\(ns.code) — \(ns.localizedDescription)")
                        continuation.finish(throwing: error)
                    }
                    return
                }
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

    /// Drain the turn to completion, returning all events in order. Routes through the
    /// blind E2E relay when `target.relay` is configured (M5 R1b, default OFF);
    /// otherwise uses the unchanged LAN-direct HTTP/SSE path.
    public func collect(_ req: ChatRequest) async throws -> [DoorEvent] {
        if target.relay != nil {
            return try await collectViaRelay(req)
        }
        var out: [DoorEvent] = []
        for try await event in events(for: req) { out.append(event) }
        return out
    }

    /// Build the raw HTTP/1.1 chat request as bytes (the relay carries opaque HTTP).
    private func rawChatHTTP(_ req: ChatRequest) throws -> Data {
        let body = try JSONEncoder().encode(req)
        let path = "/foundryx/chat"
        let host = target.baseURL.host.map { h -> String in
            if let p = target.baseURL.port { return "\(h):\(p)" }
            return h
        } ?? "door"
        var head = "POST \(path) HTTP/1.1\r\n"
        head += "Host: \(host)\r\n"
        head += "Authorization: Bearer \(target.bearer)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Accept: text/event-stream\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    /// The relay path: one E2E turn → decrypted reply frames → parse SSE `data:` events.
    private func collectViaRelay(_ req: ChatRequest) async throws -> [DoorEvent] {
        guard let relayConfig = target.relay?.interactive() else { return try await collect(req) }
        let transport = RelayTransport(config: relayConfig, session: session, log: log)
        let httpBytes = try rawChatHTTP(req)
        log?.info("→ relay chat turn chat_id=\(req.chatId) org=\(req.org) (\(req.message.count) chars)")
        let frames = try await transport.roundTrip(requestBytes: httpBytes)

        // Concatenate the decrypted reply frames and parse SSE `data:` lines (the door
        // streams the same SSE body over the relay it would over LAN-direct HTTP).
        var buffer = Data()
        for f in frames { buffer.append(f) }
        let text = String(decoding: buffer, as: UTF8.self)
        var events: [DoorEvent] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            let event = DoorEvent.parse(payload)
            events.append(event)
            if case .done = event { break }
        }
        log?.info("✓ relay chat turn parsed \(events.count) event(s)")
        return events
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
    public func finalize(captureId: String, meta: ConversationMeta? = nil) async throws {
        let body: Data? = try meta.map { try JSONEncoder().encode(FinalizeBody(meta: $0)) }
        log?.info("→ POST finalize capture=\(captureId)\(meta != nil ? " (+metadata)" : "")")
        // Remote mode: finalize the closed capture through the relay tunnel (the
        // door's /foundryx/capture/{id}/finalize is behind the tunnel, not on the
        // relay's nominal HTTP control port).
        if let relay = target.relay {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "POST",
                path: "/foundryx/capture/\(captureId)/finalize",
                contentType: meta != nil ? "application/json" : nil, body: body,
                session: session, log: log)
            if resp.status == 401 { throw DoorError.unauthorized }
            guard resp.status == 200 else {
                log?.warn("finalize capture=\(captureId) → HTTP \(resp.status) (will retry)")
                throw DoorError.http(resp.status)
            }
            log?.info("✓ finalize capture=\(captureId) accepted by door (relay)")
            return
        }
        let s = target.baseURL.absoluteString
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        guard let url = URL(string: "\(base)/foundryx/capture/\(captureId)/finalize") else {
            throw DoorError.transport("bad finalize url")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 60
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
        }
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

    /// Poll the door for a capture's pipeline stage (the phone→Lore join, F3),
    /// keyed by the PHONE's capture id — the door owns the lore-id mapping. Returns
    /// the stage + (once in Lore) the lore capture id. Phase A is stage-only.
    /// Throws on 401 / non-2xx so the caller can back off + retry.
    public func captureStatus(captureId: String) async throws -> CaptureStatusResponse {
        if let relay = target.relay {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "GET",
                path: "/foundryx/capture/\(captureId)/status",
                session: session, log: log)
            if resp.status == 401 { throw DoorError.unauthorized }
            guard resp.status == 200 else { throw DoorError.http(resp.status) }
            return try JSONDecoder().decode(CaptureStatusResponse.self, from: resp.body)
        }
        let s = target.baseURL.absoluteString
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        guard let url = URL(string: "\(base)/foundryx/capture/\(captureId)/status") else {
            throw DoorError.transport("bad status url")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 30
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else {
            throw DoorError.transport("non-HTTP response")
        }
        if http.statusCode == 401 { throw DoorError.unauthorized }
        guard http.statusCode == 200 else { throw DoorError.http(http.statusCode) }
        return try JSONDecoder().decode(CaptureStatusResponse.self, from: data)
    }

    /// Fetch a capture's TRANSCRIPT (Phase B), keyed by the PHONE's capture id —
    /// the door reads it from the local Lore engine. A 404 means Lore hasn't
    /// transcribed it yet → returned as `found:false` (a "still processing" state,
    /// NOT an error). Relay-aware: routes through the tunnel when configured.
    public func captureContent(captureId: String) async throws -> CaptureContent {
        let notReady = CaptureContent(transcript: "", capturedAt: 0, found: false)
        // Interactive channel: transcript fetch is a user-facing read, so it rides the
        // chat tunnel (own door pool), never queuing behind bulk capture sync.
        if let relay = target.relay?.interactive() {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "GET",
                path: "/foundryx/capture/\(captureId)/content",
                session: session, log: log)
            if resp.status == 401 { throw DoorError.unauthorized }
            if resp.status == 404 { return notReady }
            guard resp.status == 200 else { throw DoorError.http(resp.status) }
            return try JSONDecoder().decode(CaptureContent.self, from: resp.body)
        }
        let s = target.baseURL.absoluteString
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        guard let url = URL(string: "\(base)/foundryx/capture/\(captureId)/content") else {
            throw DoorError.transport("bad content url")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 30
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else {
            throw DoorError.transport("non-HTTP response")
        }
        if http.statusCode == 401 { throw DoorError.unauthorized }
        if http.statusCode == 404 { return notReady }
        guard http.statusCode == 200 else { throw DoorError.http(http.statusCode) }
        return try JSONDecoder().decode(CaptureContent.self, from: data)
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
