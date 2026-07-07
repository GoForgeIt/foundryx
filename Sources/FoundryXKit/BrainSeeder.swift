// BrainSeeder — connect-a-brain migration (track 20260705T1100, Phase 7).
// Upgrading is a REPLAY, never a rewrite: every conversation captured phone-only
// still has its WAL segments on disk (the local brain fake-ACKs uploads but never
// deletes). Re-arming a capture for the door drain = drop its .ack markers + the
// upload watermark and re-mark it .needs-finalize; the EXISTING drain + finalize
// machinery then uploads the audio to the door and Lore ingests + enriches in
// place (diarization backfill). Captures Lore already confirmed are left alone —
// additive, never a conflicting writer.

import Foundation

public enum BrainSeeder {
    /// Re-arm every non-Lore-confirmed local conversation for the door drain.
    /// Idempotent: a second call re-arms nothing new once Lore confirms them.
    /// Returns the number of captures re-armed.
    @discardableResult
    public static func rearmForDoorSeed(baseDir: URL) -> Int {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil)) ?? []
        var rearmed = 0
        for dir in dirs where dir.hasDirectoryPath {
            let id = dir.lastPathComponent
            guard !TranscriptCacheStore.isConfirmedInLore(captureId: id, baseDir: baseDir) else { continue }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            let segs = files.filter { $0.pathExtension == "opus" }
            guard !segs.isEmpty else { continue }   // nothing to seed
            for f in files where f.pathExtension == "ack" {
                try? FileManager.default.removeItem(at: f)
            }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(".upload-watermark"))
            try? Data().write(to: dir.appendingPathComponent(".needs-finalize"), options: [.atomic])
            CaptureEventLog.append(.brainSeedRearmed, captureId: id, baseDir: baseDir)
            rearmed += 1
        }
        return rearmed
    }
}
