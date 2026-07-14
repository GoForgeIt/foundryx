// ConversationMeta — the durable per-conversation metadata sidecar (Phase A of the
// conversation-cards track 20260620T1532). Distinct from the CaptureWAL's segment
// state: this records the human-legible facts about a conversation that the card
// shows (when + where) and the door needs at ingest (so Lore titles with context).
//
// On-disk layout: <docs>/foundryx-captures/<capture_id>/meta.json
//   { "started_at": <unix secs>, "ended_at": <unix secs?>,
//     "location": { "lat": .., "long": .., "label": ".." }? }
//
// Written at conversation START (started_at, beginSession) and END (ended_at +
// location, endSession), durably (atomic write) so it survives a relaunch. The
// finalize body the phone POSTs to the door is built from this record (F1, F9);
// the door persists it onto its manifest and threads it into the ingest envelope.
//
// Honest degradation (F5): location is OPTIONAL — a background-started conversation
// with no fix simply has no `location`, and the card shows time only.

import Foundation

/// A location fix sampled at a conversation boundary, reverse-geocoded to a place
/// label when one is available. Matches the door's `location:{lat,long,label}` DTO.
public struct ConversationLocation: Codable, Sendable, Equatable {
    public let lat: Double
    public let long: Double
    public let label: String?

    public init(lat: Double, long: Double, label: String?) {
        self.lat = lat
        self.long = long
        self.label = label
    }
}

/// The durable conversation metadata. All times are unix seconds (the door's wire
/// unit). `endedAt`/`location` are optional (a conversation that's still open, or a
/// boundary with no location fix).
public struct ConversationMeta: Codable, Sendable, Equatable {
    public var startedAt: UInt64
    public var endedAt: UInt64?
    public var location: ConversationLocation?

    public init(startedAt: UInt64, endedAt: UInt64? = nil, location: ConversationLocation? = nil) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.location = location
    }

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case location
    }

    /// Conversation duration in seconds, once it has closed.
    public var durationSeconds: UInt64? {
        guard let end = endedAt, end >= startedAt else { return nil }
        return end - startedAt
    }
}

/// Durable read/write of a capture's `meta.json` sidecar. A tiny file-backed store
/// (no actor — the CaptureManager that drives it is `@MainActor`, and writes are
/// atomic) so it composes with the existing WAL directory layout.
public enum ConversationMetaStore {
    static func metaURL(captureId: String, baseDir: URL) -> URL {
        baseDir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent("meta.json")
    }

    /// Load a capture's metadata, or `nil` if none was ever written (older captures).
    public static func load(captureId: String, baseDir: URL) -> ConversationMeta? {
        let url = metaURL(captureId: captureId, baseDir: baseDir)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ConversationMeta.self, from: data)
    }

    /// Durably persist (atomic write). Creates the capture dir if needed.
    public static func save(_ meta: ConversationMeta, captureId: String, baseDir: URL) {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL(captureId: captureId, baseDir: baseDir), options: [.atomic])
    }

    /// Stamp the conversation START (idempotent — only writes if absent, so a
    /// re-open never clobbers an existing record).
    public static func recordStart(captureId: String, baseDir: URL, at startedAt: UInt64) {
        if load(captureId: captureId, baseDir: baseDir) != nil { return }
        save(ConversationMeta(startedAt: startedAt), captureId: captureId, baseDir: baseDir)
    }

    /// Re-open an existing conversation for additional recording. Preserves the original
    /// start/location and clears only the end bound; if older metadata is missing, seeds
    /// an open record so the resumed capture has a durable sidecar.
    public static func recordOpen(captureId: String, baseDir: URL, at fallbackStartedAt: UInt64) {
        var meta = load(captureId: captureId, baseDir: baseDir)
            ?? ConversationMeta(startedAt: fallbackStartedAt)
        meta.endedAt = nil
        save(meta, captureId: captureId, baseDir: baseDir)
    }

    /// Stamp the conversation END (+ an optional location fix), preserving the
    /// existing start. If no record exists (shouldn't happen), seeds one.
    public static func recordEnd(captureId: String,
                                 baseDir: URL,
                                 at endedAt: UInt64,
                                 location: ConversationLocation?) {
        var meta = load(captureId: captureId, baseDir: baseDir)
            ?? ConversationMeta(startedAt: endedAt)
        meta.endedAt = endedAt
        if let location { meta.location = location }   // never overwrite a fix with nil
        save(meta, captureId: captureId, baseDir: baseDir)
    }
}

/// Unix seconds now — the door's wire unit for conversation times.
func nowUnixSecs() -> UInt64 {
    UInt64(max(0, Date().timeIntervalSince1970))
}
