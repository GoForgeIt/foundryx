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
    /// The conversation's NAME (the Kiln-generated title).
    public var title: String?
    /// The conversation's DESCRIPTION (the Kiln-generated summary).
    public var summary: String?
    /// Last known door pipeline stage string (advisory — the live poller is canonical
    /// while a card is on screen; this just gives a sensible value before the poll).
    public var stage: String?
    /// When this record was last updated (unix seconds).
    public var updatedAt: UInt64

    public init(title: String? = nil, summary: String? = nil, stage: String? = nil, updatedAt: UInt64 = 0) {
        self.title = title
        self.summary = summary
        self.stage = stage
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case title, summary, stage
        case updatedAt = "updated_at"
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

    /// Durably persist (atomic write). Creates the capture dir if needed.
    public static func save(_ card: ConversationCardMeta, captureId: String, baseDir: URL) {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(card) else { return }
        try? data.write(to: cardURL(captureId: captureId, baseDir: baseDir), options: [.atomic])
    }

    /// Merge incoming facts into the durable card record: each non-empty incoming
    /// field overwrites (never clobbers an existing value with nil/empty). Writes only
    /// when something actually changed. Returns true if the record was updated — so a
    /// caller can refresh the UI/list only on a real change.
    @discardableResult
    public static func merge(captureId: String,
                             baseDir: URL,
                             title: String? = nil,
                             summary: String? = nil,
                             stage: String? = nil) -> Bool {
        var card = load(captureId: captureId, baseDir: baseDir) ?? ConversationCardMeta()
        var changed = false
        if let t = title, !t.isEmpty, t != card.title { card.title = t; changed = true }
        if let s = summary, !s.isEmpty, s != card.summary { card.summary = s; changed = true }
        if let st = stage, !st.isEmpty, st != card.stage { card.stage = st; changed = true }
        guard changed else { return false }
        card.updatedAt = UInt64(max(0, Date().timeIntervalSince1970))
        save(card, captureId: captureId, baseDir: baseDir)
        return true
    }
}
