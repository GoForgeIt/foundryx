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
    /// WHICH BRAINS, ON BEING CONNECTED, RE-ARM THE AUDIO THE PHONE KEPT.
    ///
    /// It lives here rather than inline in `App/RootView.swift` because `App/` is compiled
    /// by no test target: a boundary that cannot be executed cannot be falsified, and this
    /// is the boundary that decides whether a stranded recording is ever offered a
    /// destination again.
    /// It asks `uploadAckProvesAnotherPlace` rather than naming brains, so a fourth brain
    /// cannot be added and silently left out of the one path that recovers stranded audio.
    /// It used to name `.myComputer` alone: an owner who connected a VAULT re-armed
    /// nothing, and every recording his phone had self-ACK'd stayed stranded behind a
    /// watermark that had already moved past it.
    public static func rearmsOnConnecting(_ choice: BrainChoice) -> Bool {
        choice.uploadAckProvesAnotherPlace
    }

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
            // Both markers: a `.ack` written by the pre-fix phone-only drain (a claim
            // about a place that never held the bytes) and a `.held` written by this one
            // (an honest note that only this phone did). Neither survives a re-arm.
            for f in files where f.pathExtension == "ack" || f.pathExtension == "held" {
                try? FileManager.default.removeItem(at: f)
            }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(".upload-watermark"))
            // The SHARED marker helper, not a second spelling of the literal — renaming the
            // marker must break this file loudly rather than stop re-arming silently.
            CaptureManager.markNeedsFinalizeOnDisk(id, baseDir: baseDir)
            CaptureEventLog.append(.brainSeedRearmed, captureId: id, baseDir: baseDir)
            rearmed += 1
        }
        return rearmed
    }
}
