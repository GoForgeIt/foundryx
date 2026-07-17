#if DEBUG || PERF_HARNESS
import Foundation
// (FoundryXKit types are same-module — the App target compiles Sources/FoundryXKit directly)

/// DEV-only visual-proof seeding: on `-MainPreview`, drop a handful of realistic
/// conversation cards on disk so the Capture home / Activity / detail screens render
/// with real content in the simulator and can be screenshot-verified against the
/// prototype. No effect in a normal launch.
enum DemoSeed {
    /// Large-library perf harness: `-StressSeed <N>` drops N synthetic conversation
    /// cards on disk (same stores the real pipeline uses) so a cold launch hydrates a
    /// big timeline. Pairs with the `capture-hydrate` + `capture-list-first-paint`
    /// perf spans to measure the exact "load-to-zero" hang class at 100/300/1000 on a
    /// chosen simulated iPhone. No effect on a normal launch.
    static func seedStressIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-StressSeed"),
              i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else { return }
        // `-StressSegs <avgPerCapture>` (default 0 → unchanged): also seed realistic segment
        // files + partial .ack markers so the harness can exercise the launch WARM stat-storm
        // class (capture-status-warm) — the old seed wrote card/meta/transcript but ZERO
        // segments, so sim-perf could never see it (warm 89ms in sim vs 180s on device).
        var segAvg = 0
        if let j = args.firstIndex(of: "-StressSegs"), j + 1 < args.count { segAvg = Int(args[j + 1]) ?? 0 }
        let base = CaptureWAL.documentsCaptures()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let now = Int(Date().timeIntervalSince1970)
        var totalSegs = 0
        for k in 0..<n {
            let id = "stress-\(String(format: "%05d", k))"
            let dir = base.appendingPathComponent(id, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Spread back in time so the list orders newest-first like a real library.
            let start = UInt64(max(0, now - (k + 1) * 600))
            ConversationMetaStore.save(
                ConversationMeta(startedAt: start, endedAt: start + 300),
                captureId: id, baseDir: base)
            ConversationCardStore.save(
                ConversationCardMeta(
                    title: "Conversation \(k)",
                    summary: "Synthetic stress-seed card number \(k): a realistic-length summary sentence so hydration and first-paint see representative row content.",
                    stage: "in_lore"),
                captureId: id, baseDir: base)
            TranscriptCacheStore.save(
                CachedTranscript(
                    transcript: "This is stress-seed conversation \(k). We covered a handful of topics and agreed on the next steps and who owns what by when, with enough words to be a realistic transcript body for hydration.",
                    title: "Conversation \(k)", summary: "",
                    segments: [], speakers: [], fetchedAt: UInt64(max(0, now))),
                captureId: id, baseDir: base)
            if segAvg > 0 { totalSegs += seedSegments(dir: dir, index: k, count: n, avg: segAvg) }
        }
        NSLog("perf-harness: stress-seeded \(n) captures (\(totalSegs) segment files, avg \(segAvg)/capture) at \(base.path)")
    }

    /// Seed one capture's WAL segment files (`seg-<seq>.opus`) + a partial contiguous `.ack`
    /// prefix, mirroring a real backlogged library: a SKEWED distribution where ~1 in 20
    /// captures is a heavy backlogged conversation (1000–4000 segments) and the rest are light.
    /// The total across the library tracks `avg × count` (e.g. N=128 avg≈156 → ~20k). Returns
    /// the number of segment files written. Content is a tiny fixed payload — the warm scan
    /// stats the file SIZE + `.ack` presence, it never decodes the frames.
    private static func seedSegments(dir: URL, index k: Int, count n: Int, avg: Int) -> Int {
        let fm = FileManager.default
        // Idempotent across relaunches (the nav phase relaunches the same install):
        // if this capture already has its seg-0 on disk, the segment set is seeded.
        if fm.fileExists(atPath: dir.appendingPathComponent("seg-000000000000.opus").path) {
            return 0
        }
        // A few heavy captures hold most of the backlog; the rest are short.
        let isHeavy = (k % 20 == 0)
        let segCount: Int
        if isHeavy {
            // 1000…4000, deterministic per index so runs are reproducible.
            segCount = 1000 + ((k * 37) % 3001)
        } else {
            // Light: a small spread anchored on the requested average so -StressSegs scales it.
            segCount = max(3, (avg / 4) + (k % 11))
        }
        // ACK a contiguous prefix (~70%) so the watermark derives realistically and a pending
        // tail remains — exactly the partial-sync state a real launch re-derives.
        let ackThrough = (segCount * 7) / 10
        let body = CaptureWAL.encodeSegment([Data([0xDE, 0xAD, 0xBE, 0xEF])])   // tiny fixed frame
        for seq in 0..<segCount {
            let name = String(format: "seg-%012llu", UInt64(seq))
            let segURL = dir.appendingPathComponent("\(name).opus")
            try? body.write(to: segURL)
            if seq < ackThrough {
                try? Data().write(to: dir.appendingPathComponent("\(name).ack"))
            }
        }
        return segCount
    }

    /// `-PerfLog`: mirror every PerfHook span to the unified log (NSLog) so the
    /// sim-perf harness can read `capture-hydrate` / `capture-list-first-paint` /
    /// door-fetch timings from `simctl spawn log` without needing the relay sink.
    static func installPerfLogIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-PerfLog") else { return }
        PerfHook.install { name, ms in NSLog("perf-span %@ ms=%d", name, ms) }
        // nav-stall watchdog (track 20260717T0759 AC6): live main-thread stall spans so
        // the sim-perf nav phase can gate "zero stalls >250ms during normal nav". Armed
        // a beat AFTER launch settles — the synthetic stress seeding + first hydration
        // swap are launch cost (covered by the hydrate/first-paint budgets), not nav.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { stallWatchdog.start() }
    }

    /// Harness-only main-thread stall sensor (see installPerfLogIfRequested). Retained
    /// for the process lifetime once armed.
    private static let stallWatchdog = MainThreadStallWatchdog()

    /// `-FreshActionState` (UI-proof determinism): wipe the action pipeline's
    /// mutable stores + the chat list so every proof run starts from the same
    /// state regardless of what an earlier test in the same install did. Runs
    /// BEFORE any store is constructed (app init). No effect in normal launches.
    static func resetActionStateIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-FreshActionState") else { return }
        let base = CaptureWAL.documentsCaptures()
        for name in ["ambient-cards.jsonl", "action-feedback.jsonl",
                     ActionChatLinkStore.filename] {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: ChatConversationStore.defaultStorageURL())
    }

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

        // T2 AC1 repro (the headline bug): a card that DOES show a summary, whose cached
        // content carries NO summary. Before the card fallback, opening this showed the
        // dead "No summary yet." — now the detail reads the summary the card already has.
        do {
            let id = "omi-demo-5"
            let dir = base.appendingPathComponent(id, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let start = UInt64(max(0, now - 1_900_000))   // older (>14d) terminal card
            ConversationMetaStore.save(
                ConversationMeta(startedAt: start, endedAt: start + 900),
                captureId: id, baseDir: base)
            // Card HAS the summary (this is what the home list shows).
            ConversationCardStore.save(
                ConversationCardMeta(
                    title: "Budget review with Priya",
                    summary: "Agreed to shift 10% of Q3 spend into growth; Priya sends the revised plan Monday.",
                    stage: "in_lore"),
                captureId: id, baseDir: base)
            // Cached content has a transcript but an EMPTY summary → the detail must fall
            // back to the card's summary (AC1) instead of "No summary yet."
            TranscriptCacheStore.save(
                CachedTranscript(
                    transcript: "We walked through the Q3 budget and decided to move ten percent of spend into growth. Priya will send the revised plan on Monday.",
                    title: "Budget review with Priya", summary: "",
                    segments: [], speakers: [], fetchedAt: UInt64(max(0, now))),
                captureId: id, baseDir: base)
        }

        // T2 AC2 repro: a transcript but NO summary anywhere (card + cache both empty).
        // Opening it synthesizes a summary on-device (or, where Foundation Models is
        // unavailable, honestly points at the transcript) — never a blank dead tab.
        do {
            let id = "omi-demo-6"
            let dir = base.appendingPathComponent(id, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let start = UInt64(max(0, now - 5_400))
            ConversationMetaStore.save(
                ConversationMeta(startedAt: start, endedAt: start + 600),
                captureId: id, baseDir: base)
            ConversationCardStore.save(
                ConversationCardMeta(title: "Coffee with Marcus", summary: nil, stage: "in_lore"),
                captureId: id, baseDir: base)
            TranscriptCacheStore.save(
                CachedTranscript(
                    transcript: "Marcus is thinking about leaving the agency to start something on his own. We talked through runway, the first two hires, and whether to raise or bootstrap the idea.",
                    title: "Coffee with Marcus", summary: "",
                    segments: [], speakers: [], fetchedAt: UInt64(max(0, now))),
                captureId: id, baseDir: base)
        }

        // Actions-face proof (track 20260715T1500 addendum): candidate decisions
        // for omi-demo-1, written through the SAME log the ambient lane writes
        // (ambient-decisions.jsonl), so the detail's Actions face renders real-
        // shaped rows in the simulator. Idempotent: skipped once present.
        let decisionLog = base.appendingPathComponent("ambient-decisions.jsonl")
        let seedMark = "send Sarah the numbers section"
        let existing = (try? String(contentsOf: decisionLog, encoding: .utf8)) ?? ""
        if !existing.contains(seedMark) {
            let candidates: [(UInt64, String, String)] = [
                (UInt64(max(0, now - 3_500)),
                 "Remind me to send Sarah the numbers section tonight",
                 "Set a reminder to send Sarah the numbers section tonight"),
                (UInt64(max(0, now - 3_460)),
                 "We should get the relay figures into the deck before Thursday",
                 "Add the relay figures to the launch deck before Thursday"),
            ]
            for (ts, utterance, summary) in candidates {
                let line = (try? JSONSerialization.data(withJSONObject: [
                    "ts": ts, "captureId": "omi-demo-1", "windowChars": 480,
                    "outcome": "candidate",
                    "candidate": ["utterance": utterance, "summary": summary,
                                  "confidence": 0.86],
                    "latencyMs": 210,
                ])) ?? Data()
                guard !line.isEmpty else { continue }
                var out = line
                out.append(UInt8(ascii: "\n"))
                if let h = try? FileHandle(forWritingTo: decisionLog) {
                    defer { try? h.close() }
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: out)
                } else {
                    try? out.write(to: decisionLog)
                }
            }
        }
    }
}
#endif
