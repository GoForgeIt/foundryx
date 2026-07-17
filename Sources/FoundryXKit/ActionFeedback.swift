// ActionFeedback — the durable feedback the user gives on a surfaced action so
// the action-identification pipeline can LEARN (track 20260715T1500 addendum).
//
// Two feedback kinds, straight from the Actions-face options sheet:
//   • rejected — "Not an action": the spotter surfaced something that wasn't
//     one. The comment (optional) says why.
//   • refined  — the action was real but imprecise; the comment (required by
//     the UI) says what it should have been.
//
// Storage: ONE global `action-feedback.jsonl` beside the pipeline's other logs
// (`ambient-decisions.jsonl`, `ambient-cards.jsonl`) in the captures dir — a
// well-defined, append-only store any consumer (the Mac-side router, a future
// shipper) can read. Records carry the captureId + utterance join keys.
//
// PRIVACY: the utterance and the user's comment are RAW/user text — they stay
// on the phone. Only the rejected/refined OUTCOME WORD ships to the desktop,
// via the existing ambient-cards.jsonl → AmbientSignalShipper redaction path
// (the seed field is dropped at the redaction map, spec §v3.3).

import Foundation

/// One piece of user feedback on a surfaced action, one JSONL line.
public struct ActionFeedbackRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The user says this was not an action ("Not an action").
        case rejected
        /// The user refined what the action should have been.
        case refined
    }

    /// Unix seconds when the user gave the feedback.
    public let ts: UInt64
    /// The conversation the action surfaced from.
    public let captureId: String
    /// The actionable line as heard — the join key back to the candidate.
    public let utterance: String
    /// The gate's one-line action summary at feedback time.
    public let summary: String
    public let kind: Kind
    /// The user's words: why it's not an action / what it should have been.
    /// Empty is allowed for `rejected` (a rejection needs no essay).
    public let comment: String

    public init(ts: UInt64 = UInt64(max(0, Date().timeIntervalSince1970)),
                captureId: String, utterance: String, summary: String,
                kind: Kind, comment: String) {
        self.ts = ts
        self.captureId = captureId
        self.utterance = utterance
        self.summary = summary
        self.kind = kind
        self.comment = comment
    }
}

/// Append-only JSONL store for action feedback. Tolerant reads (garbage lines
/// skipped, missing file reads as none), append-then-fsync-free writes matching
/// the pipeline's other logs.
public enum ActionFeedbackStore {
    public static let filename = "action-feedback.jsonl"

    public static func url(baseDir: URL) -> URL {
        baseDir.appendingPathComponent(filename)
    }

    /// Append one record. Creates the file (and dir) on first write.
    public static func append(_ record: ActionFeedbackRecord, baseDir: URL) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: baseDir,
                                                 withIntermediateDirectories: true)
        var line = data
        line.append(UInt8(ascii: "\n"))
        let target = url(baseDir: baseDir)
        if let handle = try? FileHandle(forWritingTo: target) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: target)
        }
    }

    /// Every record, oldest first. Garbage lines are skipped; a missing file
    /// reads as no feedback.
    public static func load(baseDir: URL) -> [ActionFeedbackRecord] {
        guard let data = try? Data(contentsOf: url(baseDir: baseDir)) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(ActionFeedbackRecord.self, from: Data($0))
        }
    }

    /// One conversation's feedback, oldest first.
    public static func load(captureId: String, baseDir: URL) -> [ActionFeedbackRecord] {
        load(baseDir: baseDir).filter { $0.captureId == captureId }
    }

    /// The latest refinement comment the user left on this utterance — what the
    /// Actions face shows as "Your note". Nil when never refined (or the
    /// refinements were empty).
    public static func latestRefinement(
        forUtterance utterance: String, in records: [ActionFeedbackRecord]
    ) -> String? {
        records.last {
            $0.kind == .refined && $0.utterance == utterance && !$0.comment.isEmpty
        }?.comment
    }
}
