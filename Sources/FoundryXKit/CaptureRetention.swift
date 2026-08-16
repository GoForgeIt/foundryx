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
    /// Speaker-diarized turns from the door's `/content` response. Stored with the
    /// transcript so reopening a conversation does not regress to "flat text first,
    /// speaker bubbles later" while the background refresh catches up.
    public let segments: [TranscriptSegment]
    /// Per-capture speaker slots paired with `segments`; empty for legacy / flat
    /// captures. Defaults during decode keep old transcript.json files readable.
    public let speakers: [CaptureSpeaker]
    /// Deepgram paragraphs for flat transcripts, persisted so reopen can render the
    /// structured transcript immediately instead of flashing a single wall of text.
    public let paragraphs: [TranscriptParagraph]
    /// When the phone fetched this from the door (unix seconds).
    public let fetchedAt: UInt64

    enum CodingKeys: String, CodingKey {
        case transcript, title, summary, segments, speakers, paragraphs, fetchedAt
    }

    public init(transcript: String, title: String?, summary: String?,
                segments: [TranscriptSegment] = [], speakers: [CaptureSpeaker] = [],
                paragraphs: [TranscriptParagraph] = [],
                fetchedAt: UInt64) {
        self.transcript = transcript
        self.title = title
        self.summary = summary
        self.segments = segments
        self.speakers = speakers
        self.paragraphs = paragraphs
        self.fetchedAt = fetchedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        speakers = try c.decodeIfPresent([CaptureSpeaker].self, forKey: .speakers) ?? []
        paragraphs = try c.decodeIfPresent([TranscriptParagraph].self, forKey: .paragraphs) ?? []
        fetchedAt = try c.decodeIfPresent(UInt64.self, forKey: .fetchedAt) ?? 0
    }
}

/// Shared cache freshness predicate for `/content` responses. A speaker rename can
/// change only `speakers`, so comparing segment count alone would discard fresh names.
public enum CaptureContentCachePolicy {
    public static func contentDiffers(_ c: CaptureContent, from cached: CachedTranscript?) -> Bool {
        guard let cached else { return true }
        return c.transcript != cached.transcript
            || c.segments != cached.segments
            || c.speakers != cached.speakers
            || c.paragraphs != cached.paragraphs
            || c.title != cached.title
            || c.summary != cached.summary
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
    /// `markConfirmed` distinguishes a transcript that PROVES Lore ingested the
    /// audio (the door path, default) from one produced ON-PHONE by the local
    /// brain (track 20260705T1100) — a local transcript must NOT claim
    /// Lore-confirmed, or the connect-a-brain seed would skip the capture.
    public static func save(_ t: CachedTranscript, captureId: String, baseDir: URL,
                            markConfirmed: Bool = true) {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(t) {
            try? data.write(to: transcriptURL(captureId: captureId, baseDir: baseDir), options: [.atomic])
        }
        guard markConfirmed else {
            CaptureEventLog.append(.transcriptSet, captureId: captureId,
                                   payload: ["source": "on_phone"], baseDir: baseDir)
            return
        }
        try? Data().write(to: confirmedMarkerURL(captureId: captureId, baseDir: baseDir), options: [.atomic])
        // Append-only event log (track 20260705T1100): the authoritative transcript
        // landing is a conversation fact — appended once (callers gate on
        // hasCachedTranscript before saving).
        CaptureEventLog.append(.transcriptSet, captureId: captureId,
                               payload: ["source": "authoritative"], baseDir: baseDir)
    }

    /// Write-through a confirmed speaker into the on-disk cached transcript (local-first
    /// track 20260717T1600) — so once the queued confirm has shipped and its pending
    /// overlay is gone, the name still renders WITHOUT waiting for a door re-fetch (no
    /// revert flicker on relaunch). Flips the slot to `.confirmed` (same semantics as the
    /// pending overlay / `applyConfirmedSpeaker`), appending a speaker record if the slot
    /// had none. No-op when no cache exists (nothing to write through). Writes directly
    /// (no `.lore-confirmed` re-stamp / event-log append — that's the fetch path's job).
    /// Off the main actor.
    public static func confirmSpeaker(captureId: String, slot: String, name: String?,
                                      speakerId: String?, baseDir: URL) {
        guard let cached = load(captureId: captureId, baseDir: baseDir) else { return }
        var speakers = cached.speakers
        if let i = speakers.firstIndex(where: { $0.slot == slot }) {
            let sp = speakers[i]
            speakers[i] = CaptureSpeaker(
                slot: sp.slot, status: .confirmed,
                name: (name?.isEmpty == false) ? name : sp.name,
                inferScore: sp.inferScore,
                inferredSpeakerId: sp.inferredSpeakerId,
                confirmedSpeakerId: (speakerId?.isEmpty == false) ? speakerId : sp.confirmedSpeakerId)
        } else {
            speakers.append(CaptureSpeaker(
                slot: slot, status: .confirmed,
                name: (name?.isEmpty == false) ? name : nil,
                inferScore: nil, inferredSpeakerId: nil,
                confirmedSpeakerId: (speakerId?.isEmpty == false) ? speakerId : nil))
        }
        let merged = CachedTranscript(
            transcript: cached.transcript, title: cached.title, summary: cached.summary,
            segments: cached.segments, speakers: speakers, paragraphs: cached.paragraphs,
            fetchedAt: cached.fetchedAt)
        if let data = try? JSONEncoder().encode(merged) {
            try? data.write(to: transcriptURL(captureId: captureId, baseDir: baseDir), options: [.atomic])
        }
    }

    /// True once a transcript has been cached for this capture (the readable tombstone).
    ///
    /// GATE INTEGRITY (track `residual_on_main_actor_work`): this is a `fileExists` — a
    /// synchronous stat. It was read ONCE PER RENDERED ROW (the card's "Ready" chip + the
    /// on-sight cache guard), which is per-row disk on the main actor. It is legitimate
    /// OFF the main actor (`loadSidecar`, the retention sweep) and a bug ON it, so it is
    /// counted at the operation itself — exactly like the transcript decode in
    /// `CaptureManager.loadSidecar` — and the gate no-ops off-main.
    public static func hasCachedTranscript(captureId: String, baseDir: URL) -> Bool {
        CaptureManager.noteMainThreadDecode()
        return FileManager.default.fileExists(atPath: transcriptURL(captureId: captureId, baseDir: baseDir).path)
    }

    /// True once we've durably confirmed this capture reached Lore.
    ///
    /// GATE INTEGRITY (track `pocket_presence_and_a_durability_predicate`): this is the SAME
    /// shape as `hasCachedTranscript` above — a `fileExists`, a synchronous stat — and it had
    /// no main-thread gate at all. It is now asked ONCE PER LISTED RECORDING by the recorder
    /// shelf's presence resolution, so an unmeasured main-actor caller would be per-row disk on
    /// the main thread, which is the pathology this app has already paid for twice. It is
    /// legitimate OFF the main actor (the retention sweep, `loadSidecar`,
    /// `PocketCaptureDurability`) and a bug ON it, so it is counted AT THE OPERATION — the gate
    /// no-ops off-main, and any future caller that reintroduces it on main trips the
    /// deterministic counter rather than only the callers anybody thought to look at.
    public static func isConfirmedInLore(captureId: String, baseDir: URL) -> Bool {
        CaptureManager.noteMainThreadDecode()
        return FileManager.default.fileExists(atPath: confirmedMarkerURL(captureId: captureId, baseDir: baseDir).path)
    }

    /// Prune ONLY the cached transcript TEXT (`transcript.json`), keeping the
    /// `.lore-confirmed` marker and every other sidecar (meta.json, card.json) so the
    /// conversation stays browsable (name + description) and the transcript is still
    /// loadable on demand from the door. Used by the ~14-day transcript retention pass.
    public static func pruneTranscriptText(captureId: String, baseDir: URL) {
        try? FileManager.default.removeItem(at: transcriptURL(captureId: captureId, baseDir: baseDir))
    }
}

/// The retention policy. The prune decisions are pure functions so the policy is
/// unit-tested independently of the file system.
///
/// Three durable tiers per conversation:
///   • metadata (meta.json + card.json: when/where + name/description) — kept FOREVER,
///     so EVERY conversation from all time is browsable.
///   • transcript text (transcript.json) — cached for ~14 days, then pruned. Older
///     conversations load their transcript ON DEMAND from the door.
///   • local audio (seg-*.opus) — kept ~30 days once safely in Lore, then pruned.
public enum CaptureRetention {
    /// Keep local audio for ~30 days before it's eligible for pruning.
    public static let audioRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Keep the full transcript TEXT cached locally for ~14 days. Past this, the text
    /// is pruned (the lightweight name/description metadata is kept) and the transcript
    /// is fetched on demand when the conversation is opened.
    public static let transcriptRetention: TimeInterval = 14 * 24 * 60 * 60

    /// A conversation is "recent" (within the transcript-cache window) when it's no
    /// older than `transcriptRetention`. Recent conversations have their transcript
    /// fetched + cached proactively (offline/instant); older ones load on demand.
    public static func isRecentForTranscriptCache(conversationAge: TimeInterval) -> Bool {
        conversationAge <= transcriptRetention
    }

    /// Whether a conversation's cached transcript TEXT may be pruned: only once it is
    /// older than the transcript-cache window. The durable metadata (name/description)
    /// is always kept, and the transcript stays loadable on demand from the door.
    public static func shouldPruneTranscript(conversationAge: TimeInterval) -> Bool {
        conversationAge > transcriptRetention
    }

    /// Whether a capture's local audio may be pruned. Audio is pruned ONLY when it's
    /// confirmed durably in Lore AND a durable readable tombstone survives locally
    /// (the cached transcript OR — once that's been pruned at 14d — the lightweight
    /// name/description card metadata), AND its newest segment is older than the audio
    /// window. Audio that isn't safely in Lore is NEVER deleted; nothing browsable is
    /// ever lost (the conversation remains in the list, and Lore can re-serve its
    /// transcript + audio on demand).
    public static func shouldPruneAudio(newestSegmentAge: TimeInterval,
                                        confirmedInLore: Bool,
                                        hasReadableTombstone: Bool) -> Bool {
        guard confirmedInLore, hasReadableTombstone else { return false }
        return newestSegmentAge > audioRetention
    }
}
