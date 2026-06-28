// ConversationCardCache — the lightweight, ALL-TIME metadata tombstone for the
// conversation list (track 20260627). Distinct from the two heavier sidecars:
//   meta.json        — when + where (ConversationMeta: start/end/location)
//   transcript.json  — the full transcript text (CachedTranscript), bounded to ~14d
//   card.json        — THIS file: just the human-legible NAME + DESCRIPTION + last
//                      known stage, so EVERY conversation shows a title + summary on
//                      its card even after its transcript text has been pruned.
//
// On-disk: <docs>/foundryx-captures/<capture_id>/card.json
//   { "title": "…"?, "summary": "…"?, "stage": "in_lore"?, "updated_at": <unix> }
//
// Populated from the door's /status poll (title + summary, F-cards) and from a
// transcript fetch (which also carries title/summary). It is NEVER pruned — it is
// the durable "we know this conversation exists, and here's what it's about" record
// that keeps the whole timeline browsable offline, even for old conversations whose
// transcript text is no longer cached (those load on demand from the door).

import Foundation

/// The durable, lightweight per-conversation card metadata (the all-time tombstone).
/// Every field is optional so a card can be seeded incrementally (stage first, then
/// title, then summary) as the door reports more.
public struct ConversationCardMeta: Codable, Sendable, Equatable {
    /// The conversation's NAME (the Kiln-generated title, OR a provisional on-device one).
    public var title: String?
    /// The conversation's DESCRIPTION (the Kiln-generated summary).
    public var summary: String?
    /// Last known door pipeline stage string (advisory — the live poller is canonical
    /// while a card is on screen; this just gives a sensible value before the poll).
    public var stage: String?
    /// The on-device PROVISIONAL transcript body, persisted at finalize so the
    /// conversation shows readable content INSTANTLY (track 20260628) — before, and
    /// resilient to a slow/failed, Kiln transcription. Overridden by the Kiln transcript
    /// once it lands (the detail view prefers door/cached content over this).
    public var provisionalTranscript: String?
    /// True while the card's title/body are the on-device PROVISIONAL content (not yet
    /// the authoritative Kiln title/summary). Cleared the moment real Kiln content
    /// merges in, so the card can render a "Processing…" affordance until then.
    public var isProvisional: Bool
    /// When this record was last updated (unix seconds). A PROCESSING timestamp — it
    /// bumps on every re-ingest/poll. NEVER use it for the conversation's date.
    public var updatedAt: UInt64
    /// The conversation's durable REAL START (unix seconds) — the stable tombstone of
    /// "when this conversation actually happened" (track 20260628T1609). Stamped once
    /// from the capture's true start (meta start, else the capture-id timestamp) and
    /// NEVER moved by a re-ingest, so a conversation keeps its date forever. This is
    /// the date the list groups + labels by when no `meta.json` is present.
    public var startedAt: UInt64?

    public init(title: String? = nil, summary: String? = nil, stage: String? = nil,
                provisionalTranscript: String? = nil, isProvisional: Bool = false,
                updatedAt: UInt64 = 0, startedAt: UInt64? = nil) {
        self.title = title
        self.summary = summary
        self.stage = stage
        self.provisionalTranscript = provisionalTranscript
        self.isProvisional = isProvisional
        self.updatedAt = updatedAt
        self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case title, summary, stage
        case provisionalTranscript = "provisional_transcript"
        case isProvisional = "is_provisional"
        case updatedAt = "updated_at"
        case startedAt = "started_at"
    }

    // Tolerate old card.json files written before the provisional fields existed:
    // the new fields default to nil/false so pre-existing cards decode unchanged.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        provisionalTranscript = try c.decodeIfPresent(String.self, forKey: .provisionalTranscript)
        isProvisional = try c.decodeIfPresent(Bool.self, forKey: .isProvisional) ?? false
        updatedAt = try c.decodeIfPresent(UInt64.self, forKey: .updatedAt) ?? 0
        startedAt = try c.decodeIfPresent(UInt64.self, forKey: .startedAt)
    }
}

/// Durable read/write of a capture's `card.json`. Mirrors `ConversationMetaStore` /
/// `TranscriptCacheStore`: a tiny file-backed store composing with the WAL dir layout.
public enum ConversationCardStore {
    static func cardURL(captureId: String, baseDir: URL) -> URL {
        baseDir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent("card.json")
    }

    /// Load a capture's card metadata, or `nil` if none was ever written.
    public static func load(captureId: String, baseDir: URL) -> ConversationCardMeta? {
        let url = cardURL(captureId: captureId, baseDir: baseDir)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ConversationCardMeta.self, from: data)
    }

    /// True once any card metadata has been written (the durable tombstone exists).
    public static func exists(captureId: String, baseDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: cardURL(captureId: captureId, baseDir: baseDir).path)
    }

    /// Durably persist (atomic write). Creates the capture dir if needed. Every write
    /// guarantees the durable REAL START is stamped: if the card has no `startedAt`
    /// yet, derive it from the capture-id's UTC timestamp — so even a card seeded by a
    /// door poll (which carries only processing-time fields) gets a stable, re-ingest-
    /// proof conversation date. An existing `startedAt` is NEVER overwritten here.
    public static func save(_ card: ConversationCardMeta, captureId: String, baseDir: URL) {
        var card = card
        if card.startedAt == nil, let idStart = CaptureIdTime.startedAt(fromCaptureId: captureId) {
            card.startedAt = idStart
        }
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(card) else { return }
        try? data.write(to: cardURL(captureId: captureId, baseDir: baseDir), options: [.atomic])
    }

    /// Durably stamp the conversation's REAL START on the card (track 20260628T1609).
    /// Called at conversation start with the authoritative meta start (preferred over
    /// the id-derived value). Idempotent + re-ingest-safe: it NEVER overwrites an
    /// existing `startedAt`, so a conversation's date can never drift to a later
    /// processing time. Returns true only if a new start was stamped.
    @discardableResult
    public static func recordStart(captureId: String, baseDir: URL, startedAt: UInt64) -> Bool {
        guard startedAt > 0 else { return false }
        var card = load(captureId: captureId, baseDir: baseDir) ?? ConversationCardMeta()
        guard card.startedAt == nil else { return false }
        card.startedAt = startedAt
        save(card, captureId: captureId, baseDir: baseDir)
        return true
    }

    /// Merge AUTHORITATIVE facts (the Kiln-derived title/summary, or a door stage) into
    /// the durable card record: each non-empty incoming field overwrites (never clobbers
    /// an existing value with nil/empty). A real title or summary landing here clears the
    /// `isProvisional` flag — Kiln content has OVERRIDDEN the on-device provisional
    /// content in place (track 20260628). Writes only when something actually changed.
    /// Returns true if the record was updated — so a caller can refresh the UI/list only
    /// on a real change.
    @discardableResult
    public static func merge(captureId: String,
                             baseDir: URL,
                             title: String? = nil,
                             summary: String? = nil,
                             stage: String? = nil) -> Bool {
        var card = load(captureId: captureId, baseDir: baseDir) ?? ConversationCardMeta()
        var changed = false
        // A real (Kiln) title/summary takes over a provisional card: overwrite even a
        // provisional title, and drop the provisional flag.
        if let t = title, !t.isEmpty, t != card.title { card.title = t; changed = true }
        if let s = summary, !s.isEmpty, s != card.summary { card.summary = s; changed = true }
        if let st = stage, !st.isEmpty, st != card.stage { card.stage = st; changed = true }
        let hasAuthoritative = (title.map { !$0.isEmpty } ?? false) || (summary.map { !$0.isEmpty } ?? false)
        if hasAuthoritative && card.isProvisional { card.isProvisional = false; changed = true }
        guard changed else { return false }
        card.updatedAt = UInt64(max(0, Date().timeIntervalSince1970))
        save(card, captureId: captureId, baseDir: baseDir)
        return true
    }

    /// Seed the durable card with the on-device PROVISIONAL content at finalize (track
    /// 20260628), so the conversation shows readable content INSTANTLY in the list —
    /// before, and resilient to a slow/failed, Kiln transcription. Sets a provisional
    /// title (caller passes the first words / "Processing…") plus the on-device
    /// transcript body, and marks the card provisional. It will NOT downgrade a card that
    /// already carries an AUTHORITATIVE (non-provisional) title — a real Kiln title that
    /// somehow already landed always wins. Returns true if the record was written.
    @discardableResult
    public static func seedProvisional(captureId: String,
                                       baseDir: URL,
                                       transcript: String?,
                                       title: String?) -> Bool {
        var card = load(captureId: captureId, baseDir: baseDir) ?? ConversationCardMeta()
        // Don't clobber an already-authoritative title (Kiln content already won).
        if let existing = card.title, !existing.isEmpty, !card.isProvisional { return false }
        var changed = false
        if let t = title, !t.isEmpty, t != card.title { card.title = t; changed = true }
        if let body = transcript, !body.isEmpty, body != card.provisionalTranscript {
            card.provisionalTranscript = body; changed = true
        }
        if !card.isProvisional { card.isProvisional = true; changed = true }
        guard changed else { return false }
        card.updatedAt = UInt64(max(0, Date().timeIntervalSince1970))
        save(card, captureId: captureId, baseDir: baseDir)
        return true
    }
}

/// Builds a short provisional TITLE from the on-device transcript body: the first few
/// words, else a calm "Processing…" placeholder when nothing was heard. Pure + tested.
public enum ProvisionalTitle {
    public static let placeholder = "Processing…"

    public static func from(transcript: String?, wordLimit: Int = 6) -> String {
        guard let t = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return placeholder
        }
        let words = t.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        let head = words.prefix(wordLimit).joined(separator: " ")
        return head.isEmpty ? placeholder : (words.count > wordLimit ? head + "…" : head)
    }
}
