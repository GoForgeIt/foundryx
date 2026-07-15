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
        }
    }
}
#endif
