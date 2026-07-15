// SpeakerConfirmQueue — durable speaker-name confirms (track 20260710T2030 follow-up).
//
// Naming/confirming a speaker is a WRITE to the desktop (door → lore). If the hub is
// momentarily unreachable, the old code lost the change and surfaced a scary "couldn't
// reach the hub" error. This queue makes the confirm DURABLE: it is written to disk the
// instant the user acts, shipped through the door immediately when possible, and — if the
// hub is down — retried on the capture drain (the same ethos as pending finalizes/deletes).
// Nothing is ever lost to a blip; the user's intent survives offline.
//
// FoundryXKit (UI/OS-free): pure disk + a DoorClient it is handed.

import Foundation

public enum SpeakerConfirmQueue {
    /// One queued speaker confirm. De-duplicated by (captureId, slot) — the latest intent
    /// for a slot supersedes an earlier un-shipped one.
    public struct Entry: Codable, Equatable, Sendable {
        public let captureId: String
        public let slot: String
        public let name: String?
        public let speakerId: String?
        public let ts: UInt64
        public init(captureId: String, slot: String, name: String?, speakerId: String?, ts: UInt64) {
            self.captureId = captureId; self.slot = slot
            self.name = name; self.speakerId = speakerId; self.ts = ts
        }
    }

    static func url(baseDir: URL) -> URL {
        baseDir.appendingPathComponent("speaker-confirms.jsonl")
    }

    /// The pending confirms (oldest first). Malformed lines are skipped, never fatal.
    public static func pending(baseDir: URL) -> [Entry] {
        guard let text = try? String(contentsOf: url(baseDir: baseDir), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Entry.self, from: data)
        }
    }

    /// Durably record an intent (latest-wins per slot). Instant + offline-safe.
    public static func enqueue(captureId: String, slot: String, name: String? = nil,
                               speakerId: String? = nil, baseDir: URL,
                               now: UInt64 = UInt64(max(0, Date().timeIntervalSince1970))) {
        var entries = pending(baseDir: baseDir).filter { !($0.captureId == captureId && $0.slot == slot) }
        entries.append(Entry(captureId: captureId, slot: slot, name: name, speakerId: speakerId, ts: now))
        write(entries, baseDir: baseDir)
    }

    /// Drop the queued intent for a slot (called once it has shipped).
    public static func remove(captureId: String, slot: String, baseDir: URL) {
        let remaining = pending(baseDir: baseDir).filter { !($0.captureId == captureId && $0.slot == slot) }
        write(remaining, baseDir: baseDir)
    }

    private static func write(_ entries: [Entry], baseDir: URL) {
        let lines = entries.compactMap { e -> String? in
            guard let d = try? JSONEncoder().encode(e) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        let body = lines.joined(separator: "\n")
        if body.isEmpty {
            try? FileManager.default.removeItem(at: url(baseDir: baseDir))   // empty queue → no file
        } else {
            try? (body + "\n").data(using: .utf8)?.write(to: url(baseDir: baseDir), options: [.atomic])
        }
    }
}
