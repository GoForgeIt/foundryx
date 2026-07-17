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
/// `requestedTarget` is the OPTIONAL per-turn model selection — a Kiln *target_id*
/// (e.g. "local-qwen3-8b", "claude-max"). nil ⇒ the field is omitted ⇒ Kiln's router
/// decides (the "Auto" default). The door forwards it to kiln-session as
/// `requested_target` on `/sessions/:id/messages`.
public struct ChatRequest: Encodable, Sendable {
    public let message: String
    public let platform: String
    public let chatId: String
    public let org: String
    public let sensitivity: String?
    public let requestedTarget: String?
    /// Chat provenance (EXT3, track 20260715T1500): "action" | "manual". The
    /// door's ChatReq is serde-tolerant, so an old desktop ignores these; a
    /// desktop that learns them can organize kiln sessions like the phone does.
    public let origin: String?
    public let originCaptureId: String?
    public let originCategory: String?

    public init(message: String, platform: String, chatId: String, org: String,
                sensitivity: String? = nil, requestedTarget: String? = nil,
                origin: String? = nil, originCaptureId: String? = nil,
                originCategory: String? = nil) {
        self.message = message
        self.platform = platform
        self.chatId = chatId
        self.org = org
        self.sensitivity = sensitivity
        self.requestedTarget = requestedTarget
        self.origin = origin
        self.originCaptureId = originCaptureId
        self.originCategory = originCategory
    }

    enum CodingKeys: String, CodingKey {
        case message, platform, org, sensitivity, origin
        case chatId = "chat_id"
        case requestedTarget = "requested_target"
        case originCaptureId = "origin_capture_id"
        case originCategory = "origin_category"
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
    /// Door heartbeat while the model works (notably during time-to-first-token):
    /// `ms` = elapsed since the turn started. Lets the UI show "thinking… Ns" so the
    /// user sees it's MOVING before the first token, and keeps the connection alive.
    case keepalive(ms: Int)
    /// End-of-turn timing summary (ms; -1 = phase didn't happen): how long until the
    /// route decision, the first token (TTFT), generation, and total + token count.
    case timing(routeMs: Int, ttftMs: Int, genMs: Int, totalMs: Int, tokens: Int)
    case done(reason: String)
    /// A clear, human-readable failure the door surfaced for a refused/blocked turn
    /// (e.g. confidential content kept local, auth expired). `code` is the raw router
    /// reason for branching; `reason` is the user-facing message.
    case error(code: String, reason: String)
    /// A file the agent wrote into its sandbox this turn (track 20260713T1500).
    /// The door announces it before `done`; fetch via RunArtifactRoute.
    case artifact(name: String, mime: String)
    case other(type: String, raw: String)

    /// Parse one SSE `data:` payload (a runtime event JSON) into a typed event.
    public static func parse(_ payload: String) -> DoorEvent {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return .other(type: "?", raw: payload)
        }
        func str(_ k: String) -> String { (obj[k] as? String) ?? "" }
        func str2(_ k1: String, _ k2: String) -> String {
            let a = str(k1); return a.isEmpty ? str(k2) : a
        }
        func int(_ k: String) -> Int { (obj[k] as? Int) ?? (obj[k] as? NSNumber)?.intValue ?? 0 }
        func args(_ k: String) -> String {
            guard let v = obj[k] else { return "" }
            if let s = v as? String { return s }
            if let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) { return s }
            return ""
        }
        switch type {
        case "session": return .session(sessionId: str("session_id"))
        case "assistant_delta": return .assistantDelta(text: str("text"))
        // kiln-runtime emits `tool_call`/`tool_result` keyed by `id`; `approval_request`
        // keys by `call_id`. Prefer `id`, fall back to `call_id` for resilience.
        case "tool_call": return .toolCall(callId: str2("id", "call_id"), name: str("name"), args: args("args"))
        case "tool_result": return .toolResult(callId: str2("id", "call_id"), content: str("content"), isError: (obj["is_error"] as? Bool) ?? false)
        case "boundary": return .boundary(label: str("label"))
        case "approval_request": return .approvalRequest(callId: str("call_id"), name: str("name"), args: args("args"))
        case "keepalive": return .keepalive(ms: int("ms"))
        case "timing": return .timing(routeMs: int("route_ms"), ttftMs: int("ttft_ms"),
                                      genMs: int("gen_ms"), totalMs: int("total_ms"), tokens: int("tokens"))
        case "done": return .done(reason: str("reason"))
        case "error": return .error(code: str("code"), reason: str("reason"))
        case "artifact": return .artifact(name: str("name"), mime: str("mime"))
        default: return .other(type: type, raw: payload)
        }
    }
}

public enum DoorError: Error, Equatable, Sendable {
    case unauthorized          // 401 — rejected before any session/inference
    case http(Int)
    case transport(String)
}

/// One selectable model for the chat header picker — a Kiln *target_id* (`id`) plus a
/// friendly `label`. The door enumerates these from the operator's `~/.kiln/config.json`
/// targets (`GET /foundryx/models`). Picking one sets `ChatRequest.requestedTarget = id`.
public struct ModelOption: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    enum CodingKeys: String, CodingKey { case id, label }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // Label is optional in the wire shape — fall back to the id.
        label = (try c.decodeIfPresent(String.self, forKey: .label)) ?? id
    }
}

/// The door's `GET /foundryx/models` reply: the operator's configured Kiln targets.
public struct ModelsResponse: Decodable, Sendable, Equatable {
    public let models: [ModelOption]
    public init(models: [ModelOption]) { self.models = models }
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
    /// Terminal drop reason from Lore (`silent_no_transcript` | `noise` |
    /// `junk_purge` | `key_lost`) when `stage == "failed"`. Lets the card show an
    /// honest, specific message ("No speech detected" / "Audio couldn't be
    /// recovered") instead of a generic — and for `key_lost`, misleading — "retry".
    public let droppedReason: String?

    enum CodingKeys: String, CodingKey {
        case stage
        case loreCaptureId = "lore_capture_id"
        case transcribed
        case title
        case summary
        case droppedReason
    }

    public init(stage: String, loreCaptureId: String?, transcribed: Bool,
                title: String? = nil, summary: String? = nil,
                droppedReason: String? = nil) {
        self.stage = stage
        self.loreCaptureId = loreCaptureId
        self.transcribed = transcribed
        self.title = title
        self.summary = summary
        self.droppedReason = droppedReason
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
    /// Speaker-diarized ORDERED segments (Lore 0.5.53). Empty when the capture was
    /// never diarized (a flat-transcript capture) OR until the door forwards them on
    /// `/content` (the companion foundry-repo door change). The view renders speaker
    /// turns when this is non-empty, else falls back to the flat `transcript`.
    public let segments: [TranscriptSegment]
    /// Per-capture speaker slots + their inferred/confirmed/anonymous state. Pairs with
    /// `segments`; empty for a non-diarized capture / pre-door-change reply.
    public let speakers: [CaptureSpeaker]
    /// Deepgram paragraph structure for non-diarized captures. Empty for legacy replies
    /// or when diarized `segments` are present.
    public let paragraphs: [TranscriptParagraph]

    /// The grouped, slot-aware view of the diarized transcript (segments → speaker
    /// turns + stable numbering/colour). Empty `segments` → `hasSegments` is false and
    /// the view uses the flat transcript.
    public var diarized: SpeakerTranscript {
        SpeakerTranscript(speakers: speakers, segments: segments)
    }

    enum CodingKeys: String, CodingKey {
        case transcript, capturedAt, found, title, summary, titleModel, summarizing
        case segments, speakers, paragraphs
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
        segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        speakers = try c.decodeIfPresent([CaptureSpeaker].self, forKey: .speakers) ?? []
        paragraphs = try c.decodeIfPresent([TranscriptParagraph].self, forKey: .paragraphs) ?? []
    }

    public init(transcript: String, capturedAt: Int, found: Bool,
                title: String? = nil, summary: String? = nil,
                titleModel: String? = nil, summarizing: Bool = false,
                segments: [TranscriptSegment] = [], speakers: [CaptureSpeaker] = [],
                paragraphs: [TranscriptParagraph] = []) {
        self.transcript = transcript
        self.capturedAt = capturedAt
        self.found = found
        self.title = title
        self.summary = summary
        self.titleModel = titleModel
        self.summarizing = summarizing
        self.segments = segments
        self.speakers = speakers
        self.paragraphs = paragraphs
    }
}

/// A past capture OFFERED for relabelling after a confirm — its voiceprint now matches
/// the just-confirmed speaker. Offered to the user, NEVER auto-applied (Lore's
/// propagation-on-confirm rule). Mirrors Lore's `OfferedCapture`.
public struct OfferedCapture: Decodable, Sendable, Equatable, Identifiable {
    public let captureId: String
    public let slotLabel: String
    public let score: Double

    public var id: String { "\(captureId)#\(slotLabel)" }

    public init(captureId: String, slotLabel: String, score: Double) {
        self.captureId = captureId
        self.slotLabel = slotLabel
        self.score = score
    }
}

/// The result of confirming/correcting a slot (door forwards Lore's `ConfirmOutcome`).
/// `offeredCaptures` is the "apply to N past conversations?" offer — surfaced, not
/// auto-applied.
public struct ConfirmOutcome: Decodable, Sendable, Equatable {
    public let captureId: String
    public let slotLabel: String
    public let status: String
    public let speakerId: String
    public let speakerName: String
    public let offeredCaptures: [OfferedCapture]

    enum CodingKeys: String, CodingKey {
        case captureId, slotLabel, status, speakerId, speakerName, offeredCaptures
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        captureId = try c.decodeIfPresent(String.self, forKey: .captureId) ?? ""
        slotLabel = try c.decodeIfPresent(String.self, forKey: .slotLabel) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "confirmed"
        speakerId = try c.decodeIfPresent(String.self, forKey: .speakerId) ?? ""
        speakerName = try c.decodeIfPresent(String.self, forKey: .speakerName) ?? ""
        offeredCaptures = try c.decodeIfPresent([OfferedCapture].self, forKey: .offeredCaptures) ?? []
    }

    public init(captureId: String, slotLabel: String, status: String,
                speakerId: String, speakerName: String,
                offeredCaptures: [OfferedCapture] = []) {
        self.captureId = captureId
        self.slotLabel = slotLabel
        self.status = status
        self.speakerId = speakerId
        self.speakerName = speakerName
        self.offeredCaptures = offeredCaptures
    }
}

/// One full-history search hit from the door (`GET /foundryx/conversations`). The door
/// derives it from the computer's Lore library; `captureId` is the PHONE's id so a tap
/// opens the existing three-face detail (which fetches `/content` by that id).
public struct ConversationHit: Decodable, Sendable, Identifiable, Equatable {
    public let captureId: String
    public let title: String
    public let dateLabel: String
    public let snippet: String
    public var id: String { captureId }
    public init(captureId: String, title: String, dateLabel: String, snippet: String) {
        self.captureId = captureId
        self.title = title
        self.dateLabel = dateLabel
        self.snippet = snippet
    }
}

/// The door's `/foundryx/conversations` response envelope.
struct ConversationSearchResponse: Decodable {
    let conversations: [ConversationHit]
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
        case .keepalive(let ms): return "keepalive (\(ms)ms)"
        case .timing(let r, let t, let g, let total, let n):
            return "timing route=\(r) ttft=\(t) gen=\(g) total=\(total)ms tokens=\(n)"
        case .done(let reason): return "done: \(reason)"
        case .error(let code, _): return "error: \(code)"
        case .artifact(let name, _): return "artifact: \(name)"
        case .other(let type, _): return "other: \(type)"
        }
    }

    /// Status code from an HTTP head ("HTTP/1.1 200 OK" → 200); 0 if unparseable.
    static func parseStatusLine(_ head: String) -> Int {
        guard let first = head.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first else { return 0 }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return 0 }
        return code
    }

    /// Parse the COMPLETE SSE `data:` lines out of a streaming body buffer, returning the
    /// parsed events, the trailing partial bytes to keep (a line may be split across mux
    /// frames), and whether a `done` event terminated the turn. Only whole lines (ending in
    /// `\n`) are consumed; the remainder carries forward to the next frame.
    static func drainSSELines(_ buf: Data) -> (events: [DoorEvent], remainder: Data, done: Bool) {
        guard let lastNL = buf.lastIndex(of: 0x0A) else { return ([], buf, false) }
        let complete = buf.subdata(in: buf.startIndex..<(lastNL + 1))
        let remainder = buf.subdata(in: (lastNL + 1)..<buf.endIndex)
        var events: [DoorEvent] = []
        var done = false
        let text = String(decoding: complete, as: UTF8.self)
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            let event = DoorEvent.parse(payload)
            events.append(event)
            if case .done = event { done = true; break }
        }
        return (events, remainder, done)
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
                    let httpBytes = RelayHTTP.rawRequest(
                        method: "POST", path: "/foundryx/chat", bearer: self.target.bearer,
                        extraHeaders: [:], contentType: "application/json",
                        accept: "text/event-stream", body: (try? JSONEncoder().encode(req)) ?? Data())
                    // Mux: STREAM the door's SSE frames as they arrive (deltas reach the UI
                    // live). Per-turn relay: one buffered round-trip, then replay (unchanged).
                    if self.target.useMux {
                        do {
                            log?.info("→ relay(mux,stream) chat chat_id=\(req.chatId) org=\(req.org) (\(req.message.count) chars)")
                            var buf = Data()
                            var headerParsed = false
                            var count = 0
                            for try await frame in DoorConnectionPool.shared.turnStream(config: relay, request: httpBytes, log: log) {
                                buf.append(frame)
                                if !headerParsed {
                                    guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { continue }
                                    let head = String(decoding: buf.subdata(in: buf.startIndex..<end.lowerBound), as: UTF8.self)
                                    let status = DoorClient.parseStatusLine(head)
                                    log?.info("← relay(mux) HTTP \(status)")
                                    if status == 401 { throw DoorError.unauthorized }
                                    guard status == 200 else { throw DoorError.http(status) }
                                    headerParsed = true
                                    buf = buf.subdata(in: end.upperBound..<buf.endIndex) // keep body only
                                }
                                let (events, remainder, done) = DoorClient.drainSSELines(buf)
                                buf = remainder
                                for e in events {
                                    count += 1
                                    log?.info("event \(DoorClient.summary(e))")
                                    continuation.yield(e)
                                }
                                if done { break }
                            }
                            log?.info("✓ relay(mux,stream) chat parsed \(count) event(s)")
                            continuation.finish()
                        } catch {
                            let ns = error as NSError
                            log?.error("✗ relay(mux) chat error: domain=\(ns.domain) code=\(ns.code) — \(ns.localizedDescription)")
                            continuation.finish(throwing: error)
                        }
                        return
                    }
                    do {
                        log?.info("→ relay chat turn chat_id=\(req.chatId) org=\(req.org) (\(req.message.count) chars)")
                        let frames = try await RelayTransport(config: relay, session: self.session, log: log)
                            .roundTrip(requestBytes: httpBytes)
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
        let httpBytes = try rawChatHTTP(req)
        log?.info("→ relay chat turn chat_id=\(req.chatId) org=\(req.org) (\(req.message.count) chars)")
        let frames = target.useMux
            ? try await DoorConnectionPool.shared.turn(config: relayConfig, request: httpBytes, log: log)
            : try await RelayTransport(config: relayConfig, session: session, log: log)
                .roundTrip(requestBytes: httpBytes)

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
                session: session, log: log, useMux: target.useMux)
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

    /// Delete a conversation everywhere (`DELETE /foundryx/capture/{id}`). The phone
    /// treats 200/404/410 as success so the operation is idempotent across retries and
    /// across a desktop that may already have removed the capture. Any other status (or
    /// transport failure) throws so the durable `.needs-delete` marker remains queued.
    public func deleteCapture(captureId: String) async throws {
        log?.info("→ DELETE capture=\(captureId)")
        if let relay = target.relay {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "DELETE",
                path: "/foundryx/capture/\(captureId)",
                session: session, log: log, useMux: target.useMux)
            if resp.status == 401 { throw DoorError.unauthorized }
            guard resp.status == 200 || resp.status == 404 || resp.status == 410 else {
                log?.warn("delete capture=\(captureId) → HTTP \(resp.status) (will retry)")
                throw DoorError.http(resp.status)
            }
            log?.info("✓ delete capture=\(captureId) accepted by door (relay)")
            return
        }
        let s = target.baseURL.absoluteString
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        guard let url = URL(string: "\(base)/foundryx/capture/\(captureId)") else {
            throw DoorError.transport("bad delete url")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "DELETE"
        r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 30
        let (_, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else {
            throw DoorError.transport("non-HTTP response")
        }
        if http.statusCode == 401 { throw DoorError.unauthorized }
        guard http.statusCode == 200 || http.statusCode == 404 || http.statusCode == 410 else {
            log?.warn("delete capture=\(captureId) → HTTP \(http.statusCode) (will retry)")
            throw DoorError.http(http.statusCode)
        }
        log?.info("✓ delete capture=\(captureId) accepted by door")
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
                session: session, log: log, useMux: target.useMux)
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
        try await PerfHook.timed("door-content") { try await self.captureContentUncounted(captureId: captureId) }
    }

    private func captureContentUncounted(captureId: String) async throws -> CaptureContent {
        let notReady = CaptureContent(transcript: "", capturedAt: 0, found: false)
        // Interactive channel: transcript fetch is a user-facing read, so it rides the
        // chat tunnel (own door pool), never queuing behind bulk capture sync.
        if let relay = target.relay?.interactive() {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "GET",
                path: "/foundryx/capture/\(captureId)/content",
                session: session, log: log, useMux: target.useMux)
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

    /// Full-history search (`GET /foundryx/conversations?q=&limit=`): ask the door for
    /// conversations from the computer's Lore library matching `query`. `captureId` on
    /// each hit is the PHONE's id, so tapping opens the existing three-face detail. An
    /// interactive read (rides the chat tunnel like the transcript fetch). A 404 — an
    /// old door without the endpoint — returns `[]` so the phone degrades to local-only
    /// search; a transport failure / non-2xx throws (the caller says "couldn't reach
    /// your computer"). An empty `query` asks the door for the recent list.
    public func searchConversations(query: String, limit: Int = 50) async throws -> [ConversationHit] {
        try await PerfHook.timed("door-conversations") {
            try await self.searchConversationsUncounted(query: query, limit: limit)
        }
    }

    private func searchConversationsUncounted(query: String, limit: Int) async throws -> [ConversationHit] {
        // Encode the term as a query VALUE (alphanumerics-only allow-set → spaces and
        // separators become %XX, which the door percent-decodes) so `&`/`=`/spaces in
        // the search never break the query string.
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let path = "/foundryx/conversations?q=\(q)&limit=\(limit)"
        if let relay = target.relay?.interactive() {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "GET",
                path: path, session: session, log: log, useMux: target.useMux)
            if resp.status == 401 { throw DoorError.unauthorized }
            if resp.status == 404 { return [] }
            guard resp.status == 200 else { throw DoorError.http(resp.status) }
            return try JSONDecoder().decode(ConversationSearchResponse.self, from: resp.body).conversations
        }
        let s = target.baseURL.absoluteString
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        guard let url = URL(string: "\(base)\(path)") else {
            throw DoorError.transport("bad conversations url")
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
        if http.statusCode == 404 { return [] }
        guard http.statusCode == 200 else { throw DoorError.http(http.statusCode) }
        return try JSONDecoder().decode(ConversationSearchResponse.self, from: data).conversations
    }

    /// Fetch a capture's assembled AUDIO for replay (`GET /foundryx/capture/{id}/audio`),
    /// keyed by the PHONE's capture id. Returns the raw audio bytes (Ogg-Opus, as the
    /// door assembles for Lore), or `nil` on a 404 — which means the audio isn't
    /// available (e.g. not assembled, or pruned on the desktop). Relay-aware: rides the
    /// interactive tunnel (a user-facing read) like the transcript fetch.
    ///
    /// NOTE: the desktop door's `/audio` endpoint is being added by a parallel change.
    /// Until it ships, this 404s and the caller surfaces "Audio not available" — no crash.
    ///
    /// `startMs`/`endMs` (both together) scope the reply to that window — the door
    /// slices the stored Opus to just the packets overlapping it, so "Hear this
    /// voice" ships a few seconds over the tunnel instead of the whole recording.
    /// A window wholly past the recording's end is a 404 → `nil`.
    public func captureAudio(
        captureId: String, startMs: Int? = nil, endMs: Int? = nil
    ) async throws -> Data? {
        var path = "/foundryx/capture/\(captureId)/audio"
        if let sMs = startMs, let eMs = endMs {
            path += "?start_ms=\(sMs)&end_ms=\(eMs)"
        }
        if let relay = target.relay?.interactive() {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "GET",
                path: path,
                session: session, log: log, useMux: target.useMux)
            if resp.status == 401 { throw DoorError.unauthorized }
            if resp.status == 404 { return nil }
            guard resp.status == 200 else { throw DoorError.http(resp.status) }
            return resp.body
        }
        let s = target.baseURL.absoluteString
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        guard let url = URL(string: "\(base)\(path)") else {
            throw DoorError.transport("bad audio url")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 60
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else {
            throw DoorError.transport("non-HTTP response")
        }
        if http.statusCode == 401 { throw DoorError.unauthorized }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw DoorError.http(http.statusCode) }
        return data
    }

    /// The resync handshake (capture-sync AC1): ask the door which segment seqs it
    /// ALREADY stores durably for a capture (`GET /foundryx/capture/{id}/segments` →
    /// `{"seqs":[..]}`), so the drain can bulk-mark those ACK'd locally instead of
    /// re-uploading audio the desktop holds (lost ACKs after a tunnel drop). Returns
    /// `nil` on a 404 — an OLD door without the endpoint (or a capture the door has
    /// never seen): the caller behaves exactly as today (full drain, no error).
    /// Relay-aware dual-path like captureAudio; rides the BULK capture channel
    /// (`target.relay`, same as segment uploads/finalize) so the handshake reflects
    /// the same tunnel health as the drain it gates.
    public func captureSegments(captureId: String) async throws -> [UInt64]? {
        struct SegmentsResponse: Decodable { let seqs: [UInt64] }
        let path = "/foundryx/capture/\(captureId)/segments"
        if let relay = target.relay {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "GET",
                path: path,
                session: session, log: log, useMux: target.useMux)
            if resp.status == 401 { throw DoorError.unauthorized }
            if resp.status == 404 { return nil }
            guard resp.status == 200 else { throw DoorError.http(resp.status) }
            return try JSONDecoder().decode(SegmentsResponse.self, from: resp.body).seqs
        }
        let s = target.baseURL.absoluteString
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        guard let url = URL(string: "\(base)\(path)") else {
            throw DoorError.transport("bad segments url")
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
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw DoorError.http(http.statusCode) }
        return try JSONDecoder().decode(SegmentsResponse.self, from: data).seqs
    }

    /// Route an ambient-gate candidate through the door's Tier-2 router
    /// (`POST /foundryx/ambient/candidate`): the door classifies it
    /// (lookup/todo/playbook/agent) and, for lookups, answers from the user's OWN
    /// memory (lore search + local-model compile) — so the phone's notification can
    /// carry the actual answer. Read-only server-side; nothing executes. Relay-aware
    /// like chat; throws on transport failure so the caller can fall back to a plain
    /// local notification.
    public func ambientCandidate(
        captureId: String, utterance: String, summary: String,
        confidence: Double, window: String, windowAudioB64: String? = nil
    ) async throws -> AmbientRouteOutcome {
        struct Req: Encodable {
            let captureId: String, utterance: String, summary: String
            let confidence: Double, window: String
            let windowAudioB64: String?
            let grade: Bool
        }
        let payload = try JSONEncoder().encode(Req(
            captureId: captureId, utterance: utterance, summary: summary,
            confidence: confidence, window: window, windowAudioB64: windowAudioB64,
            grade: AmbientPrefs.fullContextGrading()))
        if let relay = target.relay?.interactive() {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "POST",
                path: "/foundryx/ambient/candidate",
                contentType: "application/json", body: payload,
                session: session, log: log, useMux: target.useMux)
            if resp.status == 401 { throw DoorError.unauthorized }
            guard resp.status == 200 else { throw DoorError.http(resp.status) }
            return try JSONDecoder().decode(AmbientRouteOutcome.self, from: resp.body)
        }
        let s = target.baseURL.absoluteString
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        guard let url = URL(string: "\(base)/foundryx/ambient/candidate") else {
            throw DoorError.transport("bad ambient url")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = payload
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 90
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else {
            throw DoorError.transport("non-HTTP response")
        }
        if http.statusCode == 401 { throw DoorError.unauthorized }
        guard http.statusCode == 200 else { throw DoorError.http(http.statusCode) }
        return try JSONDecoder().decode(AmbientRouteOutcome.self, from: data)
    }

    /// Ship a batch of REDACTED ambient-signal records to the door's visibility sink
    /// (`POST /foundryx/ambient/log`, bearer-gated): the door appends them to a
    /// Mac-local `ambient-signal.jsonl` the Temper scorer reads (track v3.3). The
    /// records carry ONLY derived data (action/outcome/route/latency/window-SIZE) —
    /// NEVER raw conversation text. Relay-aware dual-path + bearer like ambientCandidate.
    /// Returns `true` on 200 (caller advances its shipped-watermark), `false` on 404
    /// (an OLD door without the endpoint — caller HOLDS the watermark and retries once
    /// the desktop updates). Throws on transport/other failure (also held + retried).
    public func ambientLog(records: [AmbientSignalRecord]) async throws -> Bool {
        guard !records.isEmpty else { return true }
        let payload = try JSONEncoder().encode(records)   // a JSON array of records
        if let relay = target.relay?.interactive() {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "POST",
                path: "/foundryx/ambient/log",
                contentType: "application/json", body: payload,
                session: session, log: log, useMux: target.useMux)
            if resp.status == 401 { throw DoorError.unauthorized }
            if resp.status == 404 { return false }   // old door — no-op, hold watermark
            guard resp.status == 200 else { throw DoorError.http(resp.status) }
            return true
        }
        let s = target.baseURL.absoluteString
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        guard let url = URL(string: "\(base)/foundryx/ambient/log") else {
            throw DoorError.transport("bad ambient log url")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = payload
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 30
        let (_, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else {
            throw DoorError.transport("non-HTTP response")
        }
        if http.statusCode == 401 { throw DoorError.unauthorized }
        if http.statusCode == 404 { return false }   // old door — no-op, hold watermark
        guard http.statusCode == 200 else { throw DoorError.http(http.statusCode) }
        return true
    }

    /// Confirm or correct a capture's speaker SLOT (door forwards Lore's
    /// `POST /api/admin/captures/:id/speakers/:slot/confirm`). The state machine:
    ///   * `speakerId`  → confirm the slot for that EXISTING speaker (assign).
    ///   * `name`       → confirm/correct for a speaker by name, CREATING if new
    ///                    (rename + brand-new-speaker paths).
    ///   * neither      → confirm the slot's existing INFERRED match (bare confirm).
    /// On confirm the match flips to `confirmed` (enabling future recognition) and the
    /// reply's `offeredCaptures` is the "apply to N past conversations?" offer.
    /// Relay-aware: rides the interactive tunnel (a user-facing write), like the
    /// transcript fetch.
    public func confirmSpeaker(captureId: String, slot: String,
                               speakerId: String? = nil,
                               name: String? = nil) async throws -> ConfirmOutcome {
        var bodyObj: [String: String] = [:]
        if let speakerId, !speakerId.isEmpty { bodyObj["speakerId"] = speakerId }
        if let name, !name.isEmpty { bodyObj["name"] = name }
        let body = try JSONSerialization.data(withJSONObject: bodyObj)
        let path = "/foundryx/capture/\(captureId)/speakers/\(slot)/confirm"

        if let relay = target.relay?.interactive() {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "POST",
                path: path, contentType: "application/json", body: body,
                session: session, log: log, useMux: target.useMux)
            if resp.status == 401 { throw DoorError.unauthorized }
            guard resp.status == 200 else { throw DoorError.http(resp.status) }
            return try JSONDecoder().decode(ConfirmOutcome.self, from: resp.body)
        }
        let s = target.baseURL.absoluteString
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        guard let url = URL(string: "\(base)\(path)") else {
            throw DoorError.transport("bad confirm url")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        r.timeoutInterval = 30
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else {
            throw DoorError.transport("non-HTTP response")
        }
        if http.statusCode == 401 { throw DoorError.unauthorized }
        guard http.statusCode == 200 else { throw DoorError.http(http.statusCode) }
        return try JSONDecoder().decode(ConfirmOutcome.self, from: data)
    }

    /// Request an EXTERNAL live re-title for an IN-PROGRESS conversation (track
    /// 20260717T1500). During recording the phone is the only node holding the
    /// transcript text, so it ORIGINATES the refresh: POST the whole-conversation
    /// `history` (the bounded head+tail the phone maintains) plus a monotonic `seq`
    /// (so the door can apply only the latest); the door runs it through an EXTERNAL
    /// model (Fireworks) and returns a sharpened `{title}`. Relay-aware — works
    /// off-LAN over the R1b tunnel like the transcript fetch — and bearer-gated.
    ///
    /// GRACEFUL by contract: returns `nil` (never throws) when the door doesn't
    /// support the route yet (404 — an old desktop) or returns no usable title, so
    /// the phone simply keeps its on-device placeholder. Transport / 401 / 5xx THROW
    /// so the caller treats it as offline and holds the on-device title — offline
    /// still gets a title.
    public func liveTitle(captureId: String, history: String, seq: Int) async throws -> String? {
        struct Body: Encodable { let history: String; let seq: Int }
        struct Reply: Decodable { let title: String? }
        let body = try JSONEncoder().encode(Body(history: history, seq: seq))
        let path = "/foundryx/capture/\(captureId)/live-title"
        if let relay = target.relay?.interactive() {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "POST",
                path: path, contentType: "application/json", body: body,
                session: session, log: log, useMux: target.useMux)
            if resp.status == 401 { throw DoorError.unauthorized }
            if resp.status == 404 { return nil }   // old door — no live-title route
            guard resp.status == 200 else { throw DoorError.http(resp.status) }
            let title = (try? JSONDecoder().decode(Reply.self, from: resp.body))?.title
            return title?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let s = target.baseURL.absoluteString
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        guard let url = URL(string: "\(base)\(path)") else {
            throw DoorError.transport("bad live-title url")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        r.timeoutInterval = 20
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else {
            throw DoorError.transport("non-HTTP response")
        }
        if http.statusCode == 401 { throw DoorError.unauthorized }
        if http.statusCode == 404 { return nil }   // old door — no live-title route
        guard http.statusCode == 200 else { throw DoorError.http(http.statusCode) }
        let title = (try? JSONDecoder().decode(Reply.self, from: data))?.title
        return title?.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Fetch the operator's configured Kiln targets for the model picker
    /// (`GET /foundryx/models`). Relay-aware: rides the interactive tunnel (a
    /// user-facing read) like the transcript fetch. Returns an empty list (never
    /// throws) when the door doesn't yet expose the route (404) or has no targets —
    /// the picker then just offers "Auto (router)".
    public func models() async throws -> [ModelOption] {
        try await PerfHook.timed("door-models") { try await self.modelsUncounted() }
    }

    private func modelsUncounted() async throws -> [ModelOption] {
        if let relay = target.relay?.interactive() {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "GET",
                path: "/foundryx/models",
                session: session, log: log, useMux: target.useMux)
            if resp.status == 401 { throw DoorError.unauthorized }
            if resp.status == 404 { return [] }
            guard resp.status == 200 else { throw DoorError.http(resp.status) }
            return (try? JSONDecoder().decode(ModelsResponse.self, from: resp.body))?.models ?? []
        }
        let s = target.baseURL.absoluteString
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        guard let url = URL(string: "\(base)/foundryx/models") else {
            throw DoorError.transport("bad models url")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 15
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else {
            throw DoorError.transport("non-HTTP response")
        }
        if http.statusCode == 401 { throw DoorError.unauthorized }
        if http.statusCode == 404 { return [] }
        guard http.statusCode == 200 else { throw DoorError.http(http.statusCode) }
        return (try? JSONDecoder().decode(ModelsResponse.self, from: data))?.models ?? []
    }
}
