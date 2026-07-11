// SpeakerTranscript — the phone-side model for Lore's speaker-diarized transcript
// (track: diarized_speakers_backend, Lore 0.5.53). A capture now carries ORDERED
// speaker-attributed segments + per-capture speaker SLOTS, each slot in one of three
// identity states:
//
//   • anonymous — an unnamed voice ("Speaker N"); tap to name.
//   • inferred  — a TENTATIVE match to a known speaker (with a confidence score) that
//                 does NOT propagate until the user confirms it. Rendered ghosted with
//                 a "Confirm: <name>?" affordance.
//   • confirmed — a named voice the user has confirmed; solid, propagation-enabled.
//
// This file is the PURE layer (no SwiftUI): the wire models + the segment→turn
// grouping + the stable per-slot numbering/colour index. The views (App/) render it.
//
// The wire shape mirrors Lore's `GET /api/admin/captures/:id/diarization`
// (`{segments, speakers}`, camelCase), which the door forwards on its
// `GET /foundryx/capture/:id/content` reply (see CaptureContent).

import Foundation

/// One ordered transcript segment, attributed to a per-capture speaker SLOT (e.g.
/// `speaker_0`). `startMs`/`endMs` are optional (some diarizers omit timing).
public struct TranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public let seq: Int
    public let startMs: Int?
    public let endMs: Int?
    public let text: String
    /// The per-capture slot label this segment belongs to (Lore's `speaker` field).
    public let speaker: String

    public var id: Int { seq }

    enum CodingKeys: String, CodingKey {
        case seq, startMs, endMs, text, speaker
    }

    public init(seq: Int, startMs: Int? = nil, endMs: Int? = nil,
                text: String, speaker: String) {
        self.seq = seq
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speaker = speaker
    }
}

/// A per-capture speaker slot's identity state (the read-path `speakers` entry).
public enum SpeakerStatus: String, Codable, Sendable, Equatable {
    case anonymous
    case inferred
    case confirmed

    /// Parse the wire string; anything unknown is treated as anonymous (safe default —
    /// an unrecognised state never claims a name nor propagates).
    public init(wire: String) {
        self = SpeakerStatus(rawValue: wire) ?? .anonymous
    }
}

/// A per-capture speaker slot + its identity state. `name` is the inferred name (when
/// `inferred`) or the confirmed name (when `confirmed`); `nil` when anonymous.
public struct CaptureSpeaker: Codable, Sendable, Equatable, Identifiable {
    public let slot: String
    public let status: SpeakerStatus
    /// The inferred (tentative) or confirmed name, per `status`. `nil` when anonymous.
    public let name: String?
    /// Voiceprint cosine score for an INFERRED match (0…1); `nil` otherwise.
    public let inferScore: Double?
    public let inferredSpeakerId: String?
    public let confirmedSpeakerId: String?

    public var id: String { slot }

    public var isInferred: Bool { status == .inferred }
    public var isConfirmed: Bool { status == .confirmed }
    public var isAnonymous: Bool { status == .anonymous }

    enum CodingKeys: String, CodingKey {
        case slot, status, name, inferScore, inferredSpeakerId, confirmedSpeakerId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slot = try c.decode(String.self, forKey: .slot)
        status = SpeakerStatus(wire: try c.decodeIfPresent(String.self, forKey: .status) ?? "anonymous")
        name = try c.decodeIfPresent(String.self, forKey: .name)
        inferScore = try c.decodeIfPresent(Double.self, forKey: .inferScore)
        inferredSpeakerId = try c.decodeIfPresent(String.self, forKey: .inferredSpeakerId)
        confirmedSpeakerId = try c.decodeIfPresent(String.self, forKey: .confirmedSpeakerId)
    }

    public init(slot: String, status: SpeakerStatus, name: String? = nil,
                inferScore: Double? = nil, inferredSpeakerId: String? = nil,
                confirmedSpeakerId: String? = nil) {
        self.slot = slot
        self.status = status
        self.name = name
        self.inferScore = inferScore
        self.inferredSpeakerId = inferredSpeakerId
        self.confirmedSpeakerId = confirmedSpeakerId
    }
}

/// A run of CONSECUTIVE segments from the same speaker slot, folded into one turn —
/// the unit the conversation view renders (one labelled, colour-coded block).
public struct SpeakerTurn: Sendable, Equatable, Identifiable {
    /// The slot label all this turn's segments share.
    public let slot: String
    public let segments: [TranscriptSegment]

    /// Stable identity = the first segment's seq (segments are ordered + unique).
    public var id: Int { segments.first?.seq ?? 0 }

    /// The turn's text — its segments joined with spaces, trimmed.
    public var text: String {
        segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public var startMs: Int? { segments.first?.startMs }
    public var endMs: Int? { segments.last?.endMs }

    public init(slot: String, segments: [TranscriptSegment]) {
        self.slot = slot
        self.segments = segments
    }

    /// Group ordered segments into speaker turns: consecutive segments sharing a slot
    /// fold into one turn; a slot change starts a new turn. Segments are sorted by
    /// `seq` first so an out-of-order wire payload still groups correctly.
    public static func group(_ segments: [TranscriptSegment]) -> [SpeakerTurn] {
        let ordered = segments.sorted { $0.seq < $1.seq }
        var turns: [SpeakerTurn] = []
        var current: [TranscriptSegment] = []
        for seg in ordered {
            if let last = current.last, last.speaker != seg.speaker {
                turns.append(SpeakerTurn(slot: last.speaker, segments: current))
                current = []
            }
            current.append(seg)
        }
        if let last = current.last {
            turns.append(SpeakerTurn(slot: last.speaker, segments: current))
        }
        return turns
    }
}

/// The full diarized view of a capture: its speakers (keyed by slot) + the ordered
/// segments grouped into turns. Owns the STABLE per-slot numbering ("Speaker 1") and
/// colour index so a slot looks the same everywhere it appears.
public struct SpeakerTranscript: Sendable, Equatable {
    public let speakers: [CaptureSpeaker]
    public let segments: [TranscriptSegment]
    public let turns: [SpeakerTurn]

    /// Slots in stable display order (the order speakers first SPEAK; any slot that has
    /// no segment falls back to the speakers-list order). Drives "Speaker N" + colour.
    public let orderedSlots: [String]

    private let bySlot: [String: CaptureSpeaker]

    public init(speakers: [CaptureSpeaker], segments: [TranscriptSegment]) {
        self.speakers = speakers
        self.segments = segments
        self.turns = SpeakerTurn.group(segments)

        // Stable order: first appearance in the transcript, then any speakers that
        // never produced a segment, in their listed order.
        var seen = Set<String>()
        var order: [String] = []
        for seg in segments.sorted(by: { $0.seq < $1.seq }) where !seen.contains(seg.speaker) {
            seen.insert(seg.speaker); order.append(seg.speaker)
        }
        for sp in speakers where !seen.contains(sp.slot) {
            seen.insert(sp.slot); order.append(sp.slot)
        }
        self.orderedSlots = order
        self.bySlot = Dictionary(speakers.map { ($0.slot, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// True when there are diarized segments to render as speaker turns.
    public var hasSegments: Bool { !segments.isEmpty }

    /// The speaker record for a slot (synthesised as anonymous if a segment references
    /// a slot with no speakers-list entry — the view can always render something).
    public func speaker(for slot: String) -> CaptureSpeaker {
        bySlot[slot] ?? CaptureSpeaker(slot: slot, status: .anonymous)
    }

    /// The stable 1-based display number for a slot ("Speaker 1"). Falls back to a high
    /// number for an unknown slot so it never collides with a known one.
    public func displayNumber(for slot: String) -> Int {
        (orderedSlots.firstIndex(of: slot) ?? orderedSlots.count) + 1
    }

    /// The stable 0-based colour index for a slot (the view maps it onto a palette).
    public func colorIndex(for slot: String) -> Int {
        orderedSlots.firstIndex(of: slot) ?? orderedSlots.count
    }

    /// The label to show for a slot: the confirmed/inferred name when present, else
    /// "Speaker N". Anonymous + inferred-without-name both fall back to the number.
    public func displayLabel(for slot: String) -> String {
        let sp = speaker(for: slot)
        if let name = sp.name, !name.isEmpty, sp.status != .anonymous {
            return name
        }
        return "Speaker \(displayNumber(for: slot))"
    }

    /// The ms window of `slot`'s LONGEST timestamped utterance — the clip that
    /// "Hear this voice" plays so the user can recognize a speaker before naming
    /// them. Longest = the clearest, most identifiable stretch of that voice.
    /// Capped at `maxDurationMs` so the fetched slice stays small; `nil` when the
    /// slot has no timestamped segments (the sheet then offers no playback —
    /// never a broken button). Pure (no UI/network) so it's unit-testable.
    public func voiceSampleWindow(
        for slot: String, maxDurationMs: Int = 10_000
    ) -> (startMs: Int, endMs: Int)? {
        let timed: [(Int, Int)] = segments
            .filter { $0.speaker == slot }
            .compactMap { seg in
                guard let s = seg.startMs, let e = seg.endMs, e > s else { return nil }
                return (s, e)
            }
        guard let longest = timed.max(by: { ($0.1 - $0.0) < ($1.1 - $1.0) }) else {
            return nil
        }
        return (longest.0, min(longest.1, longest.0 + maxDurationMs))
    }

    /// Slots that carry an UNCONFIRMED inferred match — the backlog the "review
    /// speakers" affordance works through (tentative labels awaiting confirm/reject).
    public var inferredSlots: [String] {
        orderedSlots.filter { speaker(for: $0).isInferred }
    }

    /// Whether this capture has any tentative (inferred, unconfirmed) speaker to review.
    public var hasUnconfirmedInferred: Bool { !inferredSlots.isEmpty }

    /// The whole transcript as plain, paste-ready text — one labelled block per speaker
    /// turn ("Speaker 1: …" / "Alice: …", using the same `displayLabel` the UI shows),
    /// turns in spoken order, blank-line separated. This is what the Copy action puts on
    /// the clipboard for a diarized conversation. Pure (no UI) so it's unit-testable.
    public var plainText: String {
        turns
            .map { turn in
                let body = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(displayLabel(for: turn.slot)): \(body)"
            }
            .filter { !$0.hasSuffix(": ") }   // drop turns that folded to empty text
            .joined(separator: "\n\n")
    }
}
