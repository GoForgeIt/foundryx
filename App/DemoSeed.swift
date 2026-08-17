#if DEBUG || PERF_HARNESS
import Foundation
// (FoundryXKit types are same-module — the App target compiles Sources/FoundryXKit directly)

/// DEV-only visual-proof seeding: on `-MainPreview`, drop a handful of realistic
/// conversation cards on disk so the Capture home / Activity / detail screens render
/// with real content in the simulator and can be screenshot-verified against the
/// prototype. No effect in a normal launch.
enum DemoSeed {
    /// The recorder the `-MainPreview` library's newest conversation carries. Deliberately a
    /// name nothing else in the app can produce, so a UI proof asserting it on screen is
    /// asserting the seeded device record and not a coincidence.
    static let proofRecorderName = "Proof Recorder Alpha"

    /// The remembered record-then-sync recorder the `-MainPreview` harness stands up, so the
    /// owner-armed clearing control has a page to render on. A UUID because the page's
    /// `hardwareToken` is a peripheral identifier and `PocketAuthenticatedIdentity` parses it.
    static let proofPocketToken = "d0c8f8a2-1f2b-4a3e-9c77-6b1e5f0a2c31"
    static let proofPocketName = "Proof Pocket Blue"

    /// Large-library perf harness: `-StressSeed <N>` drops N synthetic conversation
    /// cards on disk (same stores the real pipeline uses) so a cold launch hydrates a
    /// big timeline. Pairs with the `capture-hydrate` + `capture-list-first-paint`
    /// perf spans to measure the exact "load-to-zero" hang class at 100/300/1000 on a
    /// chosen simulated iPhone. No effect on a normal launch.
    static func seedStressIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-StressSeed"),
              i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else {
            // SELF-CLEANING (track 20260722T1244 part 2/9): the stress seed used to be purely
            // ADDITIVE and never cleaned, so a 128-capture perf run left 128 synthetic cards
            // in the simulator container that the NEXT UITest — which never asked for them —
            // then had to navigate around. That is a real cross-suite flake we hit. A launch
            // that does NOT ask for a stress library now gets none: the seeded rows are
            // removed before any store is read. Only ever touches `stress-*` ids this seeder
            // wrote; real captures and the `-MainPreview` demo cards are untouched.
            purgeStressSeed(keeping: 0)
            return
        }
        // `-StressSegs <avgPerCapture>` (default 0 → unchanged): also seed realistic segment
        // files + partial .ack markers so the harness can exercise the launch WARM stat-storm
        // class (capture-status-warm) — the old seed wrote card/meta/transcript but ZERO
        // segments, so sim-perf could never see it (warm 89ms in sim vs 180s on device).
        var segAvg = 0
        if let j = args.firstIndex(of: "-StressSegs"), j + 1 < args.count { segAvg = Int(args[j + 1]) ?? 0 }
        // The EFFECTIVE library size, announced to the log. `sim-perf.sh` reads this back and
        // fails if it does not match the N the run asked for (review S9): the churn phase used
        // to hardcode 175 and silently ignore the script's N argument, so `sim-perf.sh … 500`
        // reported churn numbers for a 175-capture library under a "N=500" heading.
        NSLog("perf-harness: stress-seed n=%d segs=%d", n, segAvg)
        let base = CaptureWAL.documentsCaptures()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // A SMALLER seed than last run's must actually shrink the library, otherwise the
        // measured N is "whatever the largest run in this container ever asked for" and the
        // budgets silently drift. Rows with index >= n are removed.
        purgeStressSeed(keeping: n)
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

    /// Remove every stress-seeded capture whose index is >= `keeping` (0 = remove them all).
    /// The seeder owns the `stress-<5 digits>` id space exclusively, so this can never delete
    /// a real capture or a `-MainPreview` demo card.
    private static func purgeStressSeed(keeping: Int) {
        let fm = FileManager.default
        let base = CaptureWAL.documentsCaptures()
        guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { return }
        var removed = 0
        for name in names where name.hasPrefix("stress-") {
            guard let idx = Int(name.dropFirst("stress-".count)) else { continue }
            if idx >= keeping {
                try? fm.removeItem(at: base.appendingPathComponent(name, isDirectory: true))
                removed += 1
            }
        }
        if removed > 0 {
            NSLog("perf-harness: purged \(removed) stale stress-seed captures (keeping \(keeping))")
        }
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
        // Mirror pre-formatted stack lines (stall/hang/cpu) to NSLog too, so the sim harness
        // can grep the live stall-stack proof (`-StallDemo`) without a relay endpoint.
        PerfHook.installLines { lines in for l in lines { NSLog("perf-line %@", l) } }
        // nav-stall watchdog (track 20260717T0759 AC6 → 20260717T0900 WS-A): live main-thread
        // stall spans AND a sampled `stallstack` naming the blocked site. Armed a beat AFTER
        // launch settles — the synthetic stress seeding + first hydration swap are launch cost
        // (covered by the hydrate/first-paint budgets), not nav.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { stallWatchdog.start() }
    }

    /// Harness main-thread stall sensor (see installPerfLogIfRequested). The FULL production
    /// wiring (sampler + budgets + stall-stack emission) so a `-PerfLog`/`-StallDemo` sim run
    /// exercises the real path end-to-end. Retained for the process lifetime once armed.
    private static let stallWatchdog = PerfTelemetry.makeStallWatchdog(ctx: PerfTelemetry.currentContext())

    /// `-StallDemo`: DEBUG/PERF_HARNESS proof seam. ~8s after launch, deliberately block the
    /// main thread ~600ms so the live stall watchdog + cross-thread sampler + emission path
    /// can be proven end-to-end in the simulator. Pair with `-PerfLog` to mirror the resulting
    /// `nav-stall` span + `stallstack`/`stallimg` lines to NSLog for grepping. No effect
    /// on a normal launch.
    static func installStallDemoIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-StallDemo") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            NSLog("perf-harness: -StallDemo blocking main thread ~600ms")
            usleep(600_000)   // ~600ms block; the watchdog (armed at 5s) catches it mid-stall
        }
    }

    /// `-FreshActionState` (UI-proof determinism): wipe the action pipeline's
    /// mutable stores + the chat list so every proof run starts from the same
    /// state regardless of what an earlier test in the same install did. Runs
    /// BEFORE any store is constructed (app init). No effect in normal launches.
    ///
    /// THE PLACE IS PART OF THAT STATE. `app-placement.json` is durable and lives in the
    /// same account root, and the simulator's app container survives between tests in a
    /// lane — so a proof that launches after `PlaceRestoreProofUITests` used to be RESTORED
    /// into whatever place that suite left behind, instead of landing on the conversation
    /// list it asserts about. That is how `RecordingDeviceProofUITests` came to fail with
    /// "the demo conversation card never appeared" in the `uiproof` lane while passing in
    /// 10s on its own: not flakiness, and not a product defect — an order dependence on
    /// state a neighbour wrote. A proof must establish its own preconditions, so this
    /// forgets the place too.
    static func resetActionStateIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-FreshActionState") else { return }
        let base = CaptureWAL.documentsCaptures()
        for name in ["ambient-cards.jsonl", "action-feedback.jsonl",
                     ActionChatLinkStore.filename, ActionPromotionStore.filename] {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: ChatConversationStore.defaultStorageURL())
        // `clear` drops the memoised read as well as the file, so nothing that already
        // looked can answer from cache.
        AppPlacementStore.clear(inAccountRoot: base)
    }

    /// A REMEMBERED RECORDER, SO THE RECORDER PAGE CAN BE PHOTOGRAPHED.
    ///
    /// WHAT THIS UNBLOCKS. The recorder page's readings strip, its reset gate, its Forget
    /// confirmation and the deletion promise under its section note ALL render with no radio at
    /// all — they need only a device this account remembers. Until this seeder existed there
    /// was no way to reach that page in a simulator, so four user-facing surfaces changed with
    /// no simulator proof, one of which (the Forget confirmation) was reassuring people about a
    /// recorder nobody had checked. A screenshot of that alert is what would have caught it.
    ///
    /// IT SEEDS NO READINGS ON PURPOSE. This is the state a person is in the first time they
    /// open the page — nothing checked, every reading absent — which is precisely the state the
    /// cost line used to lie about. `RecordingDevicePageProofUITests` photographs it.
    ///
    /// SELF-CLEANING, for the reason the capture seeding below self-cleans: the simulator's app
    /// container survives between runs, so a record written by an earlier launch would let this
    /// proof pass while reading the PREVIOUS run's state.
    private static func seedRememberedRecorder() {
        guard let store = RecordingDeviceStore.current() else { return }
        try? store.replaceAll([])
        _ = try? store.upsert(RecordingDeviceRecord(
            identity: RecordingDeviceIdentity(
                shape: .filePull,
                hardwareToken: "8f14e45f-ceea-467a-9f7b-1c2d3e4f5a6b"),
            displayName: "PKT01_BLUE_26079bc5"))
    }

    static func seedIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-MainPreview") else { return }
        seedRememberedRecorder()
        let base = CaptureWAL.documentsCaptures()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // A deterministic demo starts with NO pending speaker-confirms — otherwise a prior
        // dev-harness/proof launch's durable local-first save (speaker-confirms.jsonl in the
        // sim container) would carry over and render the seeded tentative speaker as already
        // confirmed. Dev-harness only (never runs outside -MainPreview); clears the whole
        // queue so each launch is a clean slate for the local-first proof.
        try? FileManager.default.removeItem(at: base.appendingPathComponent("speaker-confirms.jsonl"))
        // SELF-CLEANING, for exactly the reason `seedStressIfRequested` self-cleans (review
        // round 13, H13-1). This seeder is purely ADDITIVE and the simulator's app container
        // SURVIVES between runs, so a `.capture-device.json` written by an earlier launch is
        // still readable by this one. `RecordingDeviceProofUITests` therefore passed with the
        // `CaptureDeviceSidecar.write(…)` below deleted outright — it was reading the PREVIOUS
        // run's device record, and the proof's ability to fail had become a property of the
        // machine rather than of the code. Every demo capture's device record is removed before
        // this launch seeds its own, so what the proof reads is what this launch wrote. Only
        // ever touches the `omi-demo-*` ids this seeder owns; real captures are untouched.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        where name.hasPrefix("omi-demo-") {
            try? FileManager.default.removeItem(
                at: base.appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent(CaptureDeviceSidecar.fileName))
        }
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
            } else if id == "omi-demo-1" {
                // Speaker-attribution proof (features/action-speaker-attribution
                // .feature): the seeded action candidates below are spoken by ME
                // (two) and by Sarah (one), so the Actions face shows "You said"
                // rows plus a collapsed "Heard from others (1)" group.
                segments = [
                    TranscriptSegment(
                        seq: 0, startMs: 0, endMs: 9_400,
                        text: "Okay, the deck is nearly there. Remind me to send Sarah the numbers section tonight.",
                        speaker: "speaker_0"),
                    TranscriptSegment(
                        seq: 1, startMs: 9_900, endMs: 16_300,
                        text: "Sounds good. I'll get the venue booked by Friday for the launch.",
                        speaker: "speaker_1"),
                    TranscriptSegment(
                        seq: 2, startMs: 17_000, endMs: 24_200,
                        text: "We should get the relay figures into the deck before Thursday.",
                        speaker: "speaker_0"),
                ]
                speakers = [
                    CaptureSpeaker(
                        slot: "speaker_0", status: .confirmed, name: "Nick Rinard (me)",
                        confirmedSpeakerId: "demo-owner"),
                    CaptureSpeaker(
                        slot: "speaker_1", status: .confirmed, name: "Sarah",
                        confirmedSpeakerId: "demo-sarah"),
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

        // WHICH DEVICE RECORDED IT — the fact this whole device-agnostic track exists to put
        // on screen (track 20260725T2306, review round 12 H12-2).
        //
        // WHY THE SEED IS HERE. Until this, `conversation-device` appeared in ZERO of the
        // UI-proof files and `DemoSeed` wrote no `.capture-device.json`, so the two facts the
        // track delivers — the recorder named on the conversation row, and named again in the
        // detail header — had no gate that could observe them. Both were held by source-text
        // searches, and two mutations proved what that is worth: deleting the row's `.task`
        // (so `attribution` stays nil forever) and passing `attribution: nil` at the detail
        // push site each left the whole suite green. `RecordingDeviceProofUITests` reds on
        // both, because it reads the rendered screen. This is the state it reads.
        //
        // The NEWEST demo card carries it, so the proof finds it without scrolling.
        CaptureDeviceSidecar.write(
            CaptureDeviceContext(
                identity: RecordingDeviceIdentity(shape: .bleStream,
                                                  hardwareToken: "demo-proof-recorder"),
                displayName: proofRecorderName,
                accountScope: CaptureAccountScope.currentAccountBinding()?.scope ?? "demo"),
            captureId: "omi-demo-1", baseDir: base)

        // A REMEMBERED RECORD-THEN-SYNC RECORDER, so the one control the delete ruling calls
        // "owner-armed" can be READ ON A SCREEN.
        //
        // WHY IT HAS TO BE SEEDED. `DeviceScreen`'s automatic-clearing control is a per-recorder
        // setting, and a recorder's page exists only because the ACCOUNT STORE holds a record
        // for it. A simulator has no Bluetooth radio, so nothing can pair one — and without a
        // record there is no page, so the control that decides whether recordings leave a
        // recorder had no simulator proof of any kind. Every prior claim about it was a source
        // read or a hostless scenario, and this repository has already measured twice what a
        // source read is worth against a view that stopped rendering.
        //
        // ARMED STATE IS NOT SEEDED, on purpose. The record is written with the store's own
        // default, which is `autoClearArmedAt == nil` — OFF. That is the fact the proof reads,
        // and seeding it either way would be the harness answering the question.
        let proofPocket = RecordingDeviceIdentity(shape: .filePull,
                                                  hardwareToken: proofPocketToken)
        // SELF-CLEANING FIRST, and here it is load-bearing rather than tidy. The simulator's
        // container survives between runs and `recordUserPair` UPSERTS — it preserves the
        // record's existing fields — so a launch in which somebody armed this recorder would
        // leave it armed for every launch afterwards, and a proof asserting "off by default"
        // would be reading the last run's toggle. Removing the record makes the default the
        // STORE's, which is the thing under test.
        try? RecordingDeviceStore.current()?.remove(proofPocket)
        RecordingDeviceStore.recordUserPair(identity: proofPocket,
                                            displayName: proofPocketName)

        // WHICH BRAIN THE HARNESS IS ON, because the recorder page renders a DIFFERENT and
        // equally load-bearing thing on each: `.justMyPhone` has nowhere other than this phone
        // to put a copy, so nothing can ever satisfy the safety predicate and the automatic
        // clearing control is NOT OFFERED — it says why instead. Both branches are true
        // behaviour and both needed pixels, so the harness can stand up either.
        //
        // AN EXPLICIT HARNESS ARGUMENT, in the family this app already uses (`-MainPreview`,
        // `-FreshActionState`, `-OpenSettings`) and never an environment variable read at some
        // depth.
        //
        // IT IS WRITTEN IN BOTH DIRECTIONS, WHICH IS THE H13-1 LESSON AND NOT TIDINESS. The
        // brain choice is DURABLE and the simulator's container survives between runs, so a
        // launch that armed `.myComputer` would leave every later `-MainPreview` launch on it —
        // and the proof for the phone-only branch would then be reading the previous run's
        // state rather than this one's. Selecting explicitly either way makes what the screen
        // renders a property of THIS launch's arguments.
        BrainStore().select(
            ProcessInfo.processInfo.arguments.contains("-ProofPairedComputer")
                ? .myComputer : .justMyPhone)

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
        // The venue line is the NEWEST seed — using it as the mark upgrades an
        // install seeded by an older build (candidate cards dedupe by utterance,
        // so re-appending the first two is harmless).
        let seedMark = "venue booked by Friday"
        let existing = (try? String(contentsOf: decisionLog, encoding: .utf8)) ?? ""
        if !existing.contains(seedMark) {
            let candidates: [(UInt64, String, String)] = [
                (UInt64(max(0, now - 3_500)),
                 "Remind me to send Sarah the numbers section tonight",
                 "Set a reminder to send Sarah the numbers section tonight"),
                (UInt64(max(0, now - 3_460)),
                 "We should get the relay figures into the deck before Thursday",
                 "Add the relay figures to the launch deck before Thursday"),
                // Spoken by SARAH in the diarized transcript above — the
                // "Heard from others" proof row.
                (UInt64(max(0, now - 3_420)),
                 "I'll get the venue booked by Friday for the launch",
                 "Book the venue for the launch by Friday"),
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
