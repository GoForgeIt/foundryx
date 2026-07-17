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

    /// Serializes every read-modify-write cycle on the queue file. The interactive
    /// confirm flow and the 5s drain routinely run on DIFFERENT executors
    /// (`Task.detached`) against the same file — without this, an interleaved
    /// read→filter→rewrite could silently drop another writer's intent (a rename
    /// vanishing from the durable queue). `.atomic` only prevents torn files, not
    /// lost updates. (Adversarial review P2/#3, track 20260717T0900.)
    private static let ioQueue = DispatchQueue(label: "foundryx.speaker-confirm-queue")

    /// The pending confirms (oldest first). Malformed lines are skipped, never fatal.
    public static func pending(baseDir: URL) -> [Entry] {
        ioQueue.sync { pendingLocked(baseDir: baseDir) }
    }

    private static func pendingLocked(baseDir: URL) -> [Entry] {
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
        ioQueue.sync {
            var entries = pendingLocked(baseDir: baseDir)
                .filter { !($0.captureId == captureId && $0.slot == slot) }
            entries.append(Entry(captureId: captureId, slot: slot, name: name, speakerId: speakerId, ts: now))
            write(entries, baseDir: baseDir)
        }
        UsageHook.generation(kind: "speaker_confirm")   // content-free: a count, never the name
    }

    /// Durably record MANY intents in ONE read + ONE atomic write (latest-wins per slot,
    /// name defaults to nil — the assign-to-existing / bulk-apply path). Calling `enqueue`
    /// per capture is O(file) each → O(N²) for a bulk apply; this collapses it to a single
    /// rewrite so "apply to N past conversations" doesn't hammer the disk N times.
    public static func enqueueAll(_ entries: [(captureId: String, slot: String, speakerId: String?)],
                                  baseDir: URL,
                                  now: UInt64 = UInt64(max(0, Date().timeIntervalSince1970))) {
        guard !entries.isEmpty else { return }
        ioQueue.sync {
            let incoming = Set(entries.map(Self.key))
            var kept = pendingLocked(baseDir: baseDir).filter { !incoming.contains(key($0.captureId, $0.slot)) }
            for e in entries {
                kept.append(Entry(captureId: e.captureId, slot: e.slot, name: nil, speakerId: e.speakerId, ts: now))
            }
            write(kept, baseDir: baseDir)
        }
    }

    /// Drop the queued intent for a slot (called once it has shipped).
    public static func remove(captureId: String, slot: String, baseDir: URL) {
        ioQueue.sync {
            let remaining = pendingLocked(baseDir: baseDir)
                .filter { !($0.captureId == captureId && $0.slot == slot) }
            write(remaining, baseDir: baseDir)
        }
    }

    /// Drop MANY queued intents in ONE read + ONE atomic write (the batch counterpart to
    /// `remove` — for a bulk apply whose confirms all shipped). Keys not present are ignored.
    public static func removeAll(_ keys: [(captureId: String, slot: String)], baseDir: URL) {
        guard !keys.isEmpty else { return }
        ioQueue.sync {
            let drop = Set(keys.map { key($0.captureId, $0.slot) })
            let remaining = pendingLocked(baseDir: baseDir).filter { !drop.contains(key($0.captureId, $0.slot)) }
            write(remaining, baseDir: baseDir)
        }
    }

    /// A collision-safe dedupe key for a (captureId, slot) pair (control-char separator
    /// can't appear in a captureId or slot label).
    private static func key(_ captureId: String, _ slot: String) -> String { "\(captureId)\u{1}\(slot)" }
    private static func key(_ e: (captureId: String, slot: String, speakerId: String?)) -> String {
        key(e.captureId, e.slot)
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
