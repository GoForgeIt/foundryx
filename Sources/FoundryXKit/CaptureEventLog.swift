// CaptureEventLog — the phone's APPEND-ONLY conversation event log (onboarding track
// 20260705T1100, locked decision #3). Every conversation fact the phone learns —
// capture started/finalized, transcript, title, summary — is appended here as one
// JSONL line, and NOTHING is ever rewritten or deleted. This is the day-1 design
// for "connect a brain later": seeding a desktop/cell brain is a REPLAY of this log
// (additive, never a conflicting writer), so migration is designed in, never
// retrofitted. The per-capture sidecars (card.json / meta.json / transcript.json)
// stay the mutable read models; THIS file is the durable history.
//
// On-disk: <baseDir>/events.jsonl        (baseDir = the foundryx-captures dir)
//   { "seq": 1, "ts": <unix>, "kind": "capture_started", "capture_id": "…", "payload": {…} }
//
// Writes are serialized on one queue and each line lands in a single append, so
// concurrent emitters can never interleave mid-line.

import Foundation

/// One appended conversation fact. `seq` is strictly increasing within a log —
/// replay order is total and stable.
public struct CaptureEvent: Codable, Sendable, Equatable {
    public let seq: UInt64
    public let ts: UInt64
    public let kind: String
    public let captureId: String
    public let payload: [String: String]

    enum CodingKeys: String, CodingKey {
        case seq, ts, kind
        case captureId = "capture_id"
        case payload
    }
}

/// The event kinds Phase 1 emits. A raw String in the record so future phases
/// (speaker events, brain-seed markers) extend without a schema break.
public enum CaptureEventKind: String, Sendable {
    case captureStarted = "capture_started"
    case captureFinalized = "capture_finalized"
    case transcriptSet = "transcript_set"
    case titleSet = "title_set"
    case summarySet = "summary_set"
}

/// Append-only JSONL store. Mirrors the ConversationCardStore/TranscriptCacheStore
/// file-store pattern (static funcs + baseDir), deliberately exposing NO mutation or
/// deletion API — append-only by construction.
public enum CaptureEventLog {
    /// Serializes appends + seq allocation across threads.
    private static let queue = DispatchQueue(label: "com.goforgeit.foundryx.capture-event-log")
    /// Last allocated seq per log file path (recovered from disk on first touch).
    /// Safe: only ever read/written inside `queue.sync`.
    nonisolated(unsafe) private static var lastSeq: [String: UInt64] = [:]

    static func logURL(baseDir: URL) -> URL {
        baseDir.appendingPathComponent("events.jsonl")
    }

    /// Append one event. Never throws — like the sidecar stores, persistence here is
    /// best-effort and must never take down the capture path.
    public static func append(_ kind: CaptureEventKind,
                              captureId: String,
                              payload: [String: String] = [:],
                              baseDir: URL) {
        queue.sync {
            let url = logURL(baseDir: baseDir)
            let seq = nextSeqLocked(url: url)
            let event = CaptureEvent(
                seq: seq,
                ts: UInt64(max(0, Date().timeIntervalSince1970)),
                kind: kind.rawValue,
                captureId: captureId,
                payload: payload
            )
            guard var line = try? JSONEncoder().encode(event) else { return }
            line.append(0x0A)
            try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            if let handle = FileHandle(forWritingAtPath: url.path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)          // one write per line — atomic append
            } else {
                try? line.write(to: url, options: [.atomic]) // first event creates the log
            }
            lastSeq[url.path] = seq
        }
    }

    /// Replay the whole log in append order. Tolerant: a torn/corrupt line is skipped,
    /// never fatal — the log must stay readable forever.
    public static func events(baseDir: URL) -> [CaptureEvent] {
        let url = logURL(baseDir: baseDir)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(CaptureEvent.self, from: Data(line.utf8))
        }
    }

    /// Next seq for this log — cached after first touch, recovered by scanning the
    /// existing file once (so a relaunch continues the sequence, never restarts it).
    private static func nextSeqLocked(url: URL) -> UInt64 {
        if let cached = lastSeq[url.path] { return cached + 1 }
        let recovered = events(baseDir: url.deletingLastPathComponent()).last?.seq ?? 0
        return recovered + 1
    }
}
