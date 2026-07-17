// UsageTelemetry — the app reports HOW it is used, content-free, as a SIBLING to
// PerfTelemetry (features/usage-telemetry.feature). Where PerfTelemetry ships
// launch/hang/CPU numbers, this ships PRODUCT-USAGE: which pages are visited, how
// many minutes were recorded, how many conversations happened, how many
// intelligent actions were generated/acted-on, and how chat/Kiln was used.
//
// The absolute rule is CONTENT-FREE: every value that leaves the phone is a COUNT,
// a DURATION, or a controlled ENUM TOKEN. NEVER transcript/segment text, never a
// conversation title, a speaker name, a prompt/response, an ambient candidate's
// text, a feedback comment, or a file path. Two guards enforce this: the emitters
// only ever accept counts/tokens (never free text), and `UsageDiag.token` reduces
// EVERY string field name + `cats` value to the safe token grammar
// `^[A-Za-z0-9_.:-]+$` (≤64) — so even an accidental leak is stripped to a token.
//
// Delivered THROUGH Foundry: the app POSTs newline-delimited JSON to the door's
// `telemetry/usage` endpoint; the door appends it to the LOCAL foundryx telemetry
// rollup source, and Foundry's emitter delivers the rollup. The app never ships a
// rollup to our cloud directly.
//
// This file is the PURE, testable core (context + JSON serializer + a sink + the
// global emit bridge). The App-side wiring lives in PerfMetricsSubscriber.swift
// (alongside the perf sink), because the install id + endpoint need the app.

import Foundation

/// The stable context every usage event carries: which build, which install.
/// A sibling of `PerfContext` (same anonymous IDFV-first-8-hex install id).
public struct UsageContext: Sendable, Equatable {
    public let build: String
    /// A stable per-install anonymous id (identifierForVendor's first 8 hex on
    /// device) — segments events by install WITHOUT identifying the person.
    public let installId: String

    public init(build: String, installId: String) {
        self.build = build
        self.installId = installId
    }
}

/// Pure serializer — one place, so the wire shape the door re-parses (and appends
/// to the rollup) is pinned by tests. Every line is ONE content-free event.
public enum UsageDiag {
    /// The safe-token grammar for every field name + `cats` value: `^[A-Za-z0-9_.:-]+$`,
    /// capped at 64. This is the content-free guarantee — it runs the perf sanitizer
    /// FIRST (shared PII rules), then hard-strips anything outside the allow-set to
    /// `_`, so no free text (a transcript, a name, a comment) can ever survive as a
    /// value even if a caller passes one by mistake.
    public static func token(_ s: String) -> String {
        let base = PerfDiag.sanitize(s)   // reuse the shared perf sanitizer (space/@/;/\n)
        var out = String.UnicodeScalarView()
        for u in base.unicodeScalars {
            let ok = (u >= "A" && u <= "Z") || (u >= "a" && u <= "z")
                || (u >= "0" && u <= "9") || u == "_" || u == "." || u == ":" || u == "-"
            out.append(ok ? u : "_")
        }
        return String(String(out).prefix(64))
    }

    /// Serialize one content-free event to a single JSON line:
    /// `{"event_kind":"…","build":"…","dev":"…","cats":{…},"nums":{…}}`.
    /// Keys are sorted (deterministic for tests + stable server-side diffing).
    /// `cats` values + all keys are tokenized; `nums` are numbers only.
    public static func event(kind: String, cats: [String: String], nums: [String: Double],
                             ctx: UsageContext) -> String {
        var fields: [String] = []
        fields.append("\"event_kind\":\(quoted(token(kind)))")
        fields.append("\"build\":\(quoted(token(ctx.build)))")
        fields.append("\"dev\":\(quoted(token(ctx.installId)))")
        let catBody = cats.sorted { $0.key < $1.key }
            .map { "\(quoted(token($0.key))):\(quoted(token($0.value)))" }
            .joined(separator: ",")
        fields.append("\"cats\":{\(catBody)}")
        let numBody = nums.sorted { $0.key < $1.key }
            .map { "\(quoted(token($0.key))):\(number($0.value))" }
            .joined(separator: ",")
        fields.append("\"nums\":{\(numBody)}")
        return "{\(fields.joined(separator: ","))}"
    }

    /// Wrap an already-tokenized string in quotes (token() guarantees it needs no
    /// JSON escaping — no quotes, backslashes, or control chars survive tokenization).
    private static func quoted(_ token: String) -> String { "\"\(token)\"" }

    /// Render a number: whole values as integers (`90`, not `90.0`) so the wire is clean.
    private static func number(_ v: Double) -> String {
        if v.isFinite, v.rounded() == v, abs(v) < 1e15 { return String(Int(v)) }
        return String(v)
    }
}

/// Kit → app usage bridge. The App installs `emit` at launch (pointing at its
/// `UsageSink`); kit code (CaptureManager, ChatViewModel, AmbientLane, …) reports
/// content-free events through it WITHOUT importing UIKit. No-op until the app
/// installs the bridge. Set once, read from any thread.
public enum UsageHook {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _emit:
        (@Sendable (String, [String: String], [String: Double]) -> Void)?

    public static func install(
        _ f: @escaping @Sendable (String, [String: String], [String: Double]) -> Void
    ) {
        lock.lock(); _emit = f; lock.unlock()
    }

    /// Emit one content-free event (no-op until the app installs the bridge).
    public static func event(_ kind: String, cats: [String: String] = [:],
                             nums: [String: Double] = [:]) {
        lock.lock(); let f = _emit; lock.unlock()
        f?(kind, cats, nums)
    }

    // MARK: - Typed emitters (the ONLY way call sites emit — no free text can enter)

    /// A page/tab became visible. `page` is a controlled token (capture/activity/chat/settings).
    public static func page(_ page: String) {
        event("page", cats: ["page": page])
    }

    /// A capture SESSION ended. `source` is mic/omi; `kept` = did it pass the substance gate.
    public static func session(kind: String, source: String, durationSec: Int, kept: Bool) {
        event("session", cats: ["kind": kind, "source": source],
              nums: ["duration_sec": Double(max(0, durationSec)), "kept": kept ? 1 : 0])
    }

    /// A conversation boundary closed (counts + duration only — never the transcript).
    public static func conversation(kind: String, durationSec: Int, segmentCount: Int) {
        event("conversation", cats: ["kind": kind],
              nums: ["duration_sec": Double(max(0, durationSec)),
                     "segment_count": Double(max(0, segmentCount))])
    }

    /// A user action on the product (chat_convo_new, chat_convo_delete, run, dismissed,
    /// answered, rejected, refined). `outcome` is an optional controlled token.
    public static func action(_ action: String, outcome: String? = nil) {
        var cats = ["action": action]
        if let outcome { cats["outcome"] = outcome }
        event("action", cats: cats)
    }

    /// An on-device generation ran (ambient_candidate/recap/title/speaker_confirm).
    /// `ms` = wall time; `extraNums` carries ONLY counts (e.g. windowChars) — never text.
    public static func generation(kind: String, ms: Int? = nil,
                                  extraNums: [String: Double] = [:]) {
        var nums = extraNums
        if let ms { nums["ms"] = Double(max(0, ms)) }
        event("generation", cats: ["kind": kind], nums: nums)
    }

    /// A chat/Kiln turn completed. `model` is the target_id token; `route` is local/cloud.
    /// All timing/token fields are numbers — never the prompt or the response.
    public static func chat(model: String, route: String, ms: Int, ttftMs: Int,
                            genMs: Int, tokenCount: Int) {
        event("chat", cats: ["model": model, "route": route],
              nums: ["ms": Double(max(0, ms)), "ttft_ms": Double(max(0, ttftMs)),
                     "gen_ms": Double(max(0, genMs)), "token_count": Double(max(0, tokenCount))])
    }
}

/// Ships usage events to the FOUNDRY DOOR's bearer-gated `POST /foundryx/telemetry/usage`
/// route — the SAME base + auth as the capture upload path (`/foundryx/capture`), NOT
/// the perf `/diag/log` gateway base (that route is unauthenticated + on a different
/// host). The door appends each content-free line to the local foundryx telemetry
/// rollup source; Foundry's emitter delivers the rollup (the app never ships a rollup
/// to our cloud directly). Mirrors `CaptureWAL.upload`: relay-tunnel in remote mode,
/// LAN-direct otherwise. Batched, best-effort, fire-and-forget — never blocks the UI,
/// never fails loudly (an unauthenticated/early POST just 401s and is dropped).
///
/// The `DoorTarget` (base + bearer + relay) is only known AFTER sign-in, so it is set
/// via `setTarget` once `makeDoorTarget()` resolves — until then events batch and are
/// dropped on flush (best-effort; usage is not durable).
public final class UsageSink: @unchecked Sendable {
    /// The door path the receiver listens on (bearer-gated, capture base).
    public static let path = "/foundryx/telemetry/usage"
    private static let contentType = "application/x-ndjson"

    private let ctx: UsageContext
    private let lock = NSLock()
    private var pending: [String] = []
    private var target: DoorTarget?
    private let session: URLSession
    private let log: DoorLog?

    public init(ctx: UsageContext, target: DoorTarget? = nil,
                session: URLSession = .shared, log: DoorLog? = nil) {
        self.ctx = ctx
        self.target = target
        self.session = session
        self.log = log
    }

    public var context: UsageContext { ctx }

    /// Point the sink at the resolved door (post sign-in). Re-callable when the bearer
    /// refreshes after a token-expiry re-auth.
    public func setTarget(_ target: DoorTarget?) {
        lock.lock(); self.target = target; lock.unlock()
    }

    /// Record one content-free event. Batched; rides the next flush (usage is low-rate
    /// and best-effort — nothing here is urgent enough to flush per event).
    public func emit(_ kind: String, cats: [String: String] = [:],
                     nums: [String: Double] = [:], flush: Bool = false) {
        let line = UsageDiag.event(kind: kind, cats: cats, nums: nums, ctx: ctx)
        lock.lock(); pending.append(line); let batch = pending; let t = target
        if flush { pending = [] }
        lock.unlock()
        if flush { ship(batch, target: t) }
    }

    /// Ship whatever has accumulated (call on a timer + at background).
    public func flush() {
        lock.lock(); let batch = pending; let t = target; pending = []; lock.unlock()
        ship(batch, target: t)
    }

    /// The exact newline-delimited JSON body for a batch (one event per line, trailing
    /// newline). Exposed so tests can pin the wire shape without a live door.
    public static func body(for batch: [String]) -> Data? {
        guard !batch.isEmpty else { return nil }
        return (batch.joined(separator: "\n") + "\n").data(using: .utf8)
    }

    private func ship(_ batch: [String], target: DoorTarget?) {
        guard let target, let body = UsageSink.body(for: batch) else { return }
        // Fire-and-forget in a detached task (the relay round-trip is async). Errors +
        // non-200s are swallowed — usage is best-effort and must never disturb the UI.
        let session = self.session
        let log = self.log
        Task.detached {
            if let relay = target.relay {
                _ = try? await RelayHTTP.roundTrip(
                    relay: relay, bearer: target.bearer, method: "POST",
                    path: UsageSink.path, contentType: UsageSink.contentType,
                    body: body, session: session, log: log, useMux: target.useMux)
            } else {
                let s = target.baseURL.absoluteString
                let base = s.hasSuffix("/") ? String(s.dropLast()) : s
                guard let url = URL(string: "\(base)\(UsageSink.path)") else { return }
                var r = URLRequest(url: url)
                r.httpMethod = "POST"
                r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
                r.setValue(UsageSink.contentType, forHTTPHeaderField: "Content-Type")
                r.httpBody = body
                r.timeoutInterval = 15
                _ = try? await session.data(for: r)
            }
        }
    }
}
