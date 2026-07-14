// AmbientSignalShipper — ship the on-device ambient GATE/CARD signal to the user's
// own DESKTOP door (track 20260710T2030 v3.3), STRIPPED of raw conversation text.
//
// PRIVACY CONTRACT (hard rule from Nick): only DERIVED/GENERATED data leaves the
// phone — the suggested `action` (the gate's one-line summary), the `outcome`, the
// route, latency, and window SIZE. The RAW conversation text NEVER ships: the
// candidate `utterance`, the transcript `window`, and the card `seed` (which EMBEDS
// the utterance, "…this came up: <utterance>…") are DROPPED at the redaction map and
// are structurally unrepresentable in the wire record below. See spec §v3.3.
//
// The shipper reads NEW lines from `ambient-decisions.jsonl` (the gate flight
// recorder) and `ambient-cards.jsonl` (card run/dismiss outcomes) since a persisted
// byte-offset watermark (`.ambient-signal-shipped`), maps each to the redacted
// AmbientSignalRecord, and POSTs a batch to the door (`POST /foundryx/ambient/log`).
// It advances the watermark ONLY on a 200 — an OLD door without the endpoint (404)
// is a no-op (watermark held, retried when the desktop updates). Best-effort: never
// throws to the caller, never blocks capture.

import Foundation

// MARK: - The redacted wire record

/// The one redacted signal record shared by the door, the phone, and the Temper
/// scorer (spec §v3.3). It can hold ONLY derived/generated fields — there is no
/// `utterance`, `window`, or `seed` field, so raw conversation text cannot be
/// encoded even by mistake. Nil optionals are OMITTED by the encoder (never raw
/// text; `route`/`owner_verified`/`answer_found` are simply absent on phone signal).
public struct AmbientSignalRecord: Codable, Equatable, Sendable {
    public let ts: UInt64
    /// `gate` = a phone gate decision · `card` = a phone card outcome. (`router` is
    /// the door's own producer — the phone never emits it.)
    public let source: String
    /// `gated_no` | `candidate` | `skipped` (gate) · `run` | `dismissed` (card).
    public let outcome: String
    /// DERIVED (door router only) — always nil on phone signal.
    public let route: String?
    /// DERIVED/GENERATED — the gate's one-line suggested-action summary. Loggable
    /// per Nick ("generated from us"); this is NOT the heard utterance.
    public let action: String?
    public let confidence: Double?
    /// Door-owned owner-gate verdict — always nil on phone signal.
    public let ownerVerified: Bool?
    /// WHETHER lore answered — never the answer text. Door-owned; nil on phone.
    public let answerFound: Bool?
    public let latencyMs: UInt64?
    /// SIZE of the evaluated window only — never its content.
    public let windowChars: Int?
    public let skipReason: String?

    enum CodingKeys: String, CodingKey {
        case ts, source, outcome, route, action, confidence
        case ownerVerified = "owner_verified"
        case answerFound = "answer_found"
        case latencyMs = "latency_ms"
        case windowChars = "window_chars"
        case skipReason = "skip_reason"
    }

    public init(ts: UInt64, source: String, outcome: String, route: String? = nil,
                action: String? = nil, confidence: Double? = nil,
                ownerVerified: Bool? = nil, answerFound: Bool? = nil,
                latencyMs: UInt64? = nil, windowChars: Int? = nil,
                skipReason: String? = nil) {
        self.ts = ts; self.source = source; self.outcome = outcome; self.route = route
        self.action = action; self.confidence = confidence; self.ownerVerified = ownerVerified
        self.answerFound = answerFound; self.latencyMs = latencyMs
        self.windowChars = windowChars; self.skipReason = skipReason
    }
}

/// One raw card-outcome line as AmbientCardBroker writes it (`{ts, outcome, seed}`).
/// Decoded ONLY so the seed can be DROPPED — the seed embeds the utterance and never
/// ships. The redaction map (`redact(card:)`) reads `ts`/`outcome` and ignores `seed`.
public struct AmbientCardLine: Decodable, Sendable {
    public let ts: UInt64
    public let outcome: String
    /// Present in the on-disk line, but INTENTIONALLY never mapped into the wire
    /// record — it embeds the raw utterance.
    public let seed: String?
}

// MARK: - The shipper

public actor AmbientSignalShipper {
    /// POST a batch to the door. Returns `true` on 200 (advance the watermark),
    /// `false` on 404 (old door without the endpoint — hold the watermark, retry
    /// later), and THROWS on transport/other failure (also holds the watermark).
    public typealias Sender = @Sendable ([AmbientSignalRecord]) async throws -> Bool

    private let decisionsURL: URL
    private let cardsURL: URL
    private let watermarkURL: URL
    private let isEnabled: @Sendable () -> Bool
    private let send: Sender

    public init(decisionsURL: URL, cardsURL: URL, watermarkURL: URL,
                isEnabled: @escaping @Sendable () -> Bool,
                send: @escaping Sender) {
        self.decisionsURL = decisionsURL
        self.cardsURL = cardsURL
        self.watermarkURL = watermarkURL
        self.isEnabled = isEnabled
        self.send = send
    }

    // MARK: redaction map (the privacy boundary)

    /// Map a gate decision to the redacted wire record. Keeps the DERIVED summary
    /// (`action`), confidence, latency, and window SIZE; DROPS the raw `utterance`
    /// (there is no field to put it in). Static + pure so it's trivially testable.
    public static func redact(decision d: AmbientDecision) -> AmbientSignalRecord {
        AmbientSignalRecord(
            ts: d.ts,
            source: "gate",
            outcome: d.outcome.rawValue,
            route: nil,
            action: d.candidate?.summary,          // DERIVED — allowed; NOT the utterance
            confidence: d.candidate?.confidence,
            ownerVerified: nil,
            answerFound: nil,
            latencyMs: d.latencyMs,
            windowChars: d.windowChars,             // SIZE only
            skipReason: d.skipReason)
    }

    /// Map a card outcome to the redacted wire record — outcome only. The `seed`
    /// embeds the utterance and is NOT separable into a clean derived action, so it
    /// is dropped entirely (no `action`, no seed).
    public static func redact(card c: AmbientCardLine) -> AmbientSignalRecord {
        AmbientSignalRecord(
            ts: c.ts,
            source: "card",
            outcome: c.outcome,
            route: nil,
            action: nil,
            confidence: nil,
            ownerVerified: nil,
            answerFound: nil,
            latencyMs: nil,
            windowChars: nil,
            skipReason: nil)
    }

    // MARK: cadence entrypoint

    /// Best-effort ship, gated on the ambient opt-in. Enabled OFF ⇒ no-op (no read,
    /// no ship). Swallows every error — capture must never be affected.
    public func shipIfEnabled() async {
        guard isEnabled() else { return }
        try? await shipPending()
    }

    // MARK: watermark-bounded ship

    /// Read NEW complete lines from both logs since the watermark, redact, and POST a
    /// single batch. Advances the watermark to the end of the consumed lines ONLY on a
    /// 200 (or when the only new lines were unparseable garbage — so garbage can't
    /// wedge the stream). Idempotent: a second pass ships only lines appended since.
    public func shipPending() async throws {
        var wm = readWatermark()
        let (decLines, decNewOffset) = Self.newLines(from: decisionsURL, offset: wm.decisions)
        let (cardLines, cardNewOffset) = Self.newLines(from: cardsURL, offset: wm.cards)

        // Nothing appended since last pass — cheap early out (the common case).
        guard decNewOffset > wm.decisions || cardNewOffset > wm.cards else { return }

        var records: [AmbientSignalRecord] = []
        let dec = JSONDecoder()
        for line in decLines {
            if let d = try? dec.decode(AmbientDecision.self, from: line) {
                records.append(Self.redact(decision: d))
            }
        }
        for line in cardLines {
            if let c = try? dec.decode(AmbientCardLine.self, from: line) {
                records.append(Self.redact(card: c))
            }
        }

        // New bytes existed but decoded to nothing (corrupt/partial-rotated lines):
        // advance past them so they're not re-read forever. No network.
        guard !records.isEmpty else {
            wm.decisions = decNewOffset; wm.cards = cardNewOffset
            writeWatermark(wm)
            return
        }

        // POST the batch. Advance ONLY on an accepted (200). A 404 (old door) leaves
        // the watermark untouched so the SAME lines re-ship once the desktop updates;
        // a throw (transport) likewise holds and retries next cadence tick.
        let accepted = try await send(records)
        guard accepted else { return }
        wm.decisions = decNewOffset; wm.cards = cardNewOffset
        writeWatermark(wm)
    }

    // MARK: line reader

    /// Persisted byte-offset watermark per log (end of the last shipped complete line).
    struct Watermark: Codable { var decisions: Int = 0; var cards: Int = 0 }

    private func readWatermark() -> Watermark {
        guard let data = try? Data(contentsOf: watermarkURL),
              let wm = try? JSONDecoder().decode(Watermark.self, from: data) else {
            return Watermark()
        }
        return wm
    }

    private func writeWatermark(_ wm: Watermark) {
        guard let data = try? JSONEncoder().encode(wm) else { return }
        try? data.write(to: watermarkURL, options: .atomic)
    }

    /// Read the COMPLETE (newline-terminated) lines of `url` starting at byte `offset`,
    /// returning them plus the new offset (past the last complete line). A trailing
    /// partial line (no `\n` yet — the writer is mid-append) is left for next pass. A
    /// truncated/rotated file (offset past EOF) restarts from 0.
    static func newLines(from url: URL, offset: Int) -> (lines: [Data], newOffset: Int) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return ([], offset) }
        let start = offset <= data.count ? offset : 0
        let bytes = [UInt8](data.subdata(in: start..<data.count))
        var lines: [Data] = []
        var cur: [UInt8] = []
        var consumed = 0
        for (idx, b) in bytes.enumerated() {
            if b == UInt8(ascii: "\n") {
                lines.append(Data(cur))
                cur.removeAll(keepingCapacity: true)
                consumed = idx + 1
            } else {
                cur.append(b)
            }
        }
        return (lines, start + consumed)
    }
}
