#if DEBUG
import Foundation
// (FoundryXKit types are same-module — the App target compiles Sources/FoundryXKit directly)

/// DEV-only visual-proof seeding: on `-MainPreview`, drop a handful of realistic
/// conversation cards on disk so the Capture home / Activity / detail screens render
/// with real content in the simulator and can be screenshot-verified against the
/// prototype. No effect in a normal launch.
enum DemoSeed {
    static func seedIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-MainPreview") else { return }
        let base = CaptureWAL.documentsCaptures()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let now = Int(Date().timeIntervalSince1970)
        // (id, title, summary, stage, startOffsetSeconds, durationSeconds)
        let demos: [(String, String, String, String, Int, Int)] = [
            ("omi-demo-1", "Launch deck and relay numbers",
             "Aligned on the deck; Sarah owns the numbers section by tonight.", "in_lore", -3_600, 720),
            ("omi-demo-2", "Walk with Dana",
             "Caught up on the move and the timeline for the house.", "transcribing", -7_200, 2_460),
            ("omi-demo-3", "Pricing thought after lunch",
             "A usage-based tier could unlock the mid-market — worth modeling.", "in_lore", -90_000, 480),
            ("omi-demo-4", "Sweet Green and data challenges",
             "Data-integration friction and stakeholder comms took most of the hour.", "in_lore", -100_000, 2_640),
        ]
        for (id, title, summary, stage, startOff, dur) in demos {
            let dir = base.appendingPathComponent(id, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let start = UInt64(max(0, now + startOff))
            ConversationMetaStore.save(
                ConversationMeta(startedAt: start, endedAt: start + UInt64(dur)),
                captureId: id, baseDir: base)
            ConversationCardStore.save(
                ConversationCardMeta(title: title, summary: summary, stage: stage),
                captureId: id, baseDir: base)
            let segments: [TranscriptSegment]
            let speakers: [CaptureSpeaker]
            if id == "omi-demo-2" {
                segments = [
                    TranscriptSegment(
                        seq: 0, startMs: 0, endMs: 8_200,
                        text: "The inspection is Friday, and after that we can lock the house timeline.",
                        speaker: "speaker_0"),
                    TranscriptSegment(
                        seq: 1, startMs: 8_700, endMs: 17_100,
                        text: "I can call the lender this afternoon and make sure the paperwork is ready.",
                        speaker: "speaker_1"),
                    TranscriptSegment(
                        seq: 2, startMs: 17_900, endMs: 27_800,
                        text: "Perfect. If that clears, let's plan on closing before the end of the month.",
                        speaker: "speaker_0"),
                    TranscriptSegment(
                        seq: 3, startMs: 30_200, endMs: 33_600,
                        text: "Excuse me, coming through on your left.",
                        speaker: "speaker_2"),
                ]
                speakers = [
                    CaptureSpeaker(
                        slot: "speaker_0", status: .confirmed, name: "Dana",
                        confirmedSpeakerId: "demo-dana"),
                    CaptureSpeaker(
                        slot: "speaker_1", status: .inferred, name: "Nick",
                        inferScore: 0.88, inferredSpeakerId: "demo-nick"),
                    CaptureSpeaker(slot: "speaker_2", status: .anonymous),
                ]
            } else {
                segments = []
                speakers = []
            }
            // A cached transcript so the detail's Summary + Transcript faces populate
            // (the faces read fetched content OR this local cache).
            TranscriptCacheStore.save(
                CachedTranscript(
                    transcript: segments.isEmpty
                        ? "\(title). \(summary) We agreed on the next steps and who owns what by when."
                        : segments.map(\.text).joined(separator: " "),
                    title: title, summary: summary, segments: segments, speakers: speakers,
                    fetchedAt: UInt64(max(0, now))),
                captureId: id, baseDir: base)
        }
    }
}
#endif
