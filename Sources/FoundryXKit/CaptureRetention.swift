// CaptureRetention — the phone-side audio retention policy + the local transcript
// cache (track 20260626). The phone keeps every Opus segment durably (the WAL never
// deletes); this adds a bounded retention pass: after ~30 days, prune the local
// audio for a conversation BUT keep its transcript — and ONLY prune audio that is
// confirmed durably in Lore. Audio that isn't safely stored is NEVER deleted.
//
// Two durable on-disk artifacts under <docs>/foundryx-captures/<capture_id>/:
//   transcript.json   — the cached transcript (+ title/summary/fetchedAt), written
//                        when the detail view fetches a capture's content. Survives
//                        audio pruning and offline relaunch (the readable tombstone).
//   .lore-confirmed    — a marker proving the capture reached Lore (written alongside
//                        the transcript cache, since a transcript can only exist if
//                        Lore transcribed the audio).
//
// The prune DECISION is a pure, unit-tested function (`shouldPruneAudio`); the
// CaptureManager gathers its inputs from disk and performs the file deletion.

import Foundation

/// The cached transcript (the readable tombstone that outlives the local audio).
public struct CachedTranscript: Codable, Sendable, Equatable {
    public let transcript: String
    public let title: String?
    public let summary: String?
    /// When the phone fetched this from the door (unix seconds).
    public let fetchedAt: UInt64

    public init(transcript: String, title: String?, summary: String?, fetchedAt: UInt64) {
        self.transcript = transcript
        self.title = title
        self.summary = summary
        self.fetchedAt = fetchedAt
    }
}

/// Durable read/write of a capture's `transcript.json` + the `.lore-confirmed`
/// marker. Mirrors `ConversationMetaStore`: a tiny file-backed store composing with
/// the existing WAL directory layout.
public enum TranscriptCacheStore {
    static func transcriptURL(captureId: String, baseDir: URL) -> URL {
        baseDir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent("transcript.json")
    }

    static func confirmedMarkerURL(captureId: String, baseDir: URL) -> URL {
        baseDir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent(".lore-confirmed")
    }

    /// Load a capture's cached transcript, or `nil` if none was ever cached.
    public static func load(captureId: String, baseDir: URL) -> CachedTranscript? {
        let url = transcriptURL(captureId: captureId, baseDir: baseDir)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedTranscript.self, from: data)
    }

    /// Durably cache a transcript (atomic write) AND stamp the `.lore-confirmed`
    /// marker — a cached transcript proves the audio reached + was transcribed by
    /// Lore. Creates the capture dir if needed.
    public static func save(_ t: CachedTranscript, captureId: String, baseDir: URL) {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(t) {
            try? data.write(to: transcriptURL(captureId: captureId, baseDir: baseDir), options: [.atomic])
        }
        try? Data().write(to: confirmedMarkerURL(captureId: captureId, baseDir: baseDir), options: [.atomic])
    }

    /// True once a transcript has been cached for this capture (the readable tombstone).
    public static func hasCachedTranscript(captureId: String, baseDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: transcriptURL(captureId: captureId, baseDir: baseDir).path)
    }

    /// True once we've durably confirmed this capture reached Lore.
    public static func isConfirmedInLore(captureId: String, baseDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: confirmedMarkerURL(captureId: captureId, baseDir: baseDir).path)
    }
}

/// The audio retention policy. The prune decision is a pure function so the policy is
/// unit-tested independently of the file system.
public enum CaptureRetention {
    /// Keep local audio for ~30 days before it's eligible for pruning.
    public static let audioRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Whether a capture's local audio may be pruned. Audio is pruned ONLY when it's
    /// both confirmed durably in Lore AND has a locally cached transcript (so nothing
    /// readable is ever lost), AND its newest segment is older than the retention
    /// window. Audio that isn't safely stored is NEVER deleted.
    public static func shouldPruneAudio(newestSegmentAge: TimeInterval,
                                        confirmedInLore: Bool,
                                        hasCachedTranscript: Bool) -> Bool {
        guard confirmedInLore, hasCachedTranscript else { return false }
        return newestSegmentAge > audioRetention
    }
}
