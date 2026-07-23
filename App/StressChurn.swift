// StressChurn — the COMMAND-side drive for the perf gate (track
// 20260722T1244_churn_interleaved_cqrs_perf_gate).
//
// WHY THIS EXISTS
// ---------------
// Every perf gate we had — `scripts/sim-perf.sh`, `PerfBudgetNavUITests`, `WarmFloodTests` —
// exercised only the QUERY side of the capture read model: list rebuild and warm reads over a
// STATIC, pre-warmed, read-only library. None of them ever ran a WRITE that *invalidates* the
// read-model caches (`sidecarCache`, `metaCache`, `startTimeCache`, `.status-cache.json`).
// The device pathology is precisely the other case: a rebuild that runs a beat AFTER a command
// invalidated the memos, cold-missing into synchronous disk I/O on the main actor. A 6.6-second
// freeze shipped through a green gate because of that hole.
//
// This driver closes it. Under `-StressChurn [intervalMs]` (DEBUG / PERF_HARNESS only) it runs
// continuous, REAL write traffic against the stress-seeded library while the UITest navigates:
//
//   1. segment append          — a new `seg-<seq>.opus` lands in a capture's WAL directory and
//                                the durable `.status-cache.json` is invalidated (exactly what
//                                `CaptureWAL` does at every segment mutation).
//   2. drain ACK               — `.ack` markers appear for a contiguous prefix, moving the
//                                synced watermark under the reader.
//   3. status-poller card merge— a fresh `card.json` is written and the capture's sidecar memo
//                                is invalidated through the REAL seam
//                                (`CaptureManager.invalidateSidecar`), not a raw dict clear.
//   4. finalize                — a fresh `transcript.json` is written and the sidecar memo is
//                                invalidated, i.e. the heaviest decode a cold miss could face.
//
// FIDELITY: the disk work runs OFF the main actor (a background queue), like every real writer;
// only the invalidation lands on the main actor, like every real writer. Production behaviour is
// untouched — the whole file is compiled out of a plain Release build, and it is inert unless
// the launch argument is present.
//
// SENSOR MECHANICS: `MainThreadStallWatchdog` is armed +5s after launch and is rate-limited
// (≤1 sample / 5s, ≤60 / session). The churn therefore starts AFTER the arm delay and keeps
// running for the whole drive, so a stall has both time to happen and room to be sampled.
#if DEBUG || PERF_HARNESS
import Foundation

enum StressChurn {

    /// Default tick period. Fast enough that a rebuild is nearly always racing a fresh
    /// invalidation; slow enough that the churn itself is not the thing being measured.
    static let defaultIntervalMs = 200

    /// How many captures each tick touches. A real live library invalidates a handful of
    /// sidecars per write batch (status poll + drain ACK + the live capture), not one.
    private static let windowSize = 8

    @MainActor private static var timer: Timer?
    @MainActor private static var tick = 0
    private static let io = DispatchQueue(label: "foundryx.stress-churn", qos: .utility)

    /// True when the process was launched with `-StressChurn`.
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-StressChurn")
    }

    /// Arm the churn drive if `-StressChurn` is present. `manager` is the live CaptureManager
    /// whose read model the churn invalidates — the same object the list renders from.
    @MainActor
    static func installIfRequested(manager: CaptureManager) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-StressChurn") else { return }
        var intervalMs = defaultIntervalMs
        if i + 1 < args.count, let v = Int(args[i + 1]), v > 0 { intervalMs = v }
        // Start AFTER the stall watchdog arms (+5s), so every stall the churn provokes is
        // under surveillance. Starting earlier would spend churn on an unarmed sensor.
        let armDelay: TimeInterval = 6
        NSLog("perf-harness: -StressChurn armed (every %dms, starting in %.0fs)", intervalMs, armDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + armDelay) {
            let t = Timer.scheduledTimer(withTimeInterval: Double(intervalMs) / 1000.0,
                                         repeats: true) { _ in
                MainActor.assumeIsolated { churnOnce(manager: manager) }
            }
            // .common so the churn keeps writing while a scroll gesture is tracking — the
            // exact moment the list is most sensitive to a cold-miss rebuild.
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// One interleaved write batch. Disk OFF main; invalidation ON main — like the real writers.
    @MainActor
    private static func churnOnce(manager: CaptureManager) {
        let base = CaptureWAL.documentsCaptures()
        let ids = stressIds(base: base)
        guard !ids.isEmpty else { return }
        let n = tick; tick += 1
        // A rotating window, so over a 40s drive the churn sweeps the whole library rather
        // than hammering the same eight rows into permanent warmth.
        let window = (0..<windowSize).map { ids[(n * windowSize + $0) % ids.count] }
        // The FINALIZE leg is the expensive one (a whole transcript.json rewrite) — one per
        // tick, mirroring reality (conversations finalize one at a time).
        let finalizeId = ids[(n * 3) % ids.count]
        // S8 (review): `invalidateSidecar` has a SECOND branch — the LIVE capture's throttled
        // path (CaptureManager.swift:1703), which is the highest-traffic write path while a
        // recording is running and is where the "stale card up to 5s" defect actually lived.
        // The churn never reached it as long as nothing was recording. Whenever the drive DOES
        // hold an active capture (the churn UITest starts one), that id joins the window, so
        // the throttled/coalesced branch is exercised every tick. Only the INVALIDATION is
        // extended to the live capture — the synthetic write legs stay on the `stress-*`
        // library, because appending fake segments to a genuinely recording capture would be
        // corrupting real data rather than simulating a writer.
        let activeId = manager.active?.captureId
        // A plain monotonic stamp rather than a `PerfSpan`: this value crosses two concurrency
        // domains (the io queue, then back to the main actor), and a UInt64 is trivially
        // Sendable where a struct holding a clock closure is not.
        let startedAt = DispatchTime.now().uptimeNanoseconds

        io.async {
            // PROOF-OF-LIFE (review B3): count the write legs that ACTUALLY landed on disk.
            // The gate used to infer "the churn ran" from `tab-switch` spans — evidence that
            // NAVIGATION happened, which the UITest emits whether or not a single command ever
            // ran. Dropping `installIfRequested`, renaming the seed prefix out from under
            // `stressIds`, or a timer that never fires all left the drive emitting tab
            // switches, seeing zero stalls, and PASSING. Now the churn emits its own countable
            // span per completed batch, and only when real bytes were written.
            var legs = 0
            for id in window {
                let dir = base.appendingPathComponent(id, isDirectory: true)
                if appendSegmentAndAck(dir: dir, tick: n) { legs += 1 }
                if writeCardMerge(id: id, baseDir: base, tick: n) { legs += 1 }
            }
            if writeFinalizedTranscript(id: finalizeId, baseDir: base, tick: n) { legs += 1 }
            Task { @MainActor in
                // THE SEAM UNDER TEST: the same invalidation every production writer calls.
                for id in window { manager.invalidateSidecar(id) }
                manager.invalidateSidecar(finalizeId)
                if let activeId { manager.invalidateSidecar(activeId) }   // the LIVE branch
                guard legs > 0 else { return }   // no disk work → no evidence, deliberately
                let ms = Int((DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000)
                PerfHook.span("churn-write", ms: ms)
                // A separate, distinctly-named span the harness can count to prove the LIVE
                // branch was reached — an active capture in the window is the only way in.
                if activeId != nil { PerfHook.span("churn-write-live", ms: ms) }
            }
        }
    }

    // MARK: the four write legs

    /// Segment append + drain ACK. Appends one new `seg-<seq>.opus` beyond the highest seq on
    /// disk, ACKs an older pending segment, and invalidates the durable status cache — which
    /// is exactly what `CaptureWAL` does at every segment mutation.
    /// Returns TRUE only if the new segment actually reached disk — the gate counts landed
    /// write legs, so a leg that silently no-ops (missing directory, failed write) must not
    /// be able to masquerade as evidence that the command side ran.
    @discardableResult
    private static func appendSegmentAndAck(dir: URL, tick: Int) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return false }
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let seqs = names.compactMap { name -> UInt64? in
            guard name.hasPrefix("seg-"), name.hasSuffix(".opus") else { return nil }
            return UInt64(name.dropFirst(4).dropLast(5))
        }
        let next = (seqs.max() ?? 0) + 1
        let body = CaptureWAL.encodeSegment([Data([0xDE, 0xAD, 0xBE, 0xEF])])
        let newName = String(format: "seg-%012llu", next)
        let newURL = dir.appendingPathComponent("\(newName).opus")
        var wrote = false
        do { try body.write(to: newURL); wrote = true } catch { wrote = false }
        // Drain ACK: mark the OLDEST still-unacked segment synced, so the watermark advances
        // under the reader exactly as a successful upload would.
        for seq in seqs.sorted() {
            let n = String(format: "seg-%012llu", seq)
            let ack = dir.appendingPathComponent("\(n).ack")
            if !fm.fileExists(atPath: ack.path) { try? Data().write(to: ack); break }
        }
        // Every segment mutation invalidates the durable status cache (the WAL's own rule),
        // so the next warm pass must rescan — the partially-invalidated state the re-warm
        // budget is supposed to be measured against.
        CaptureWAL.invalidateStatusCache(captureDir: dir)
        return wrote
    }

    /// Status-poller card merge: the door answered with a sharper title/stage, so `card.json`
    /// is rewritten underneath the read model. Returns TRUE when `card.json` is on disk after
    /// the save (the gate counts landed legs, never attempted ones).
    @discardableResult
    private static func writeCardMerge(id: String, baseDir: URL, tick: Int) -> Bool {
        ConversationCardStore.save(
            ConversationCardMeta(
                title: "Conversation \(id.suffix(5)) · churn \(tick)",
                summary: "Churn-merged card \(tick): the status poller answered with a sharper "
                    + "summary while the list was being navigated.",
                stage: tick % 3 == 0 ? "transcribing" : "in_lore"),
            captureId: id, baseDir: baseDir)
        return justWritten(baseDir.appendingPathComponent(id, isDirectory: true)
                             .appendingPathComponent("card.json"))
    }

    /// True when `url` exists AND was modified in the last few seconds — i.e. THIS tick's
    /// write really landed, not a file some earlier run left behind. The churn gate's minimum
    /// span count is only as honest as this predicate.
    private static func justWritten(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(m) < 5
    }

    /// Finalize: a whole fresh `transcript.json`, i.e. the heaviest thing a cold sidecar miss
    /// could be asked to decode. Segment/paragraph counts mirror the skewed seed's LIGHT shape
    /// so the drive stays representative rather than pathological.
    @discardableResult
    private static func writeFinalizedTranscript(id: String, baseDir: URL, tick: Int) -> Bool {
        let sentences = [
            "We reviewed the launch plan and agreed on the release date for next Thursday.",
            "The relay numbers looked strong, though the tail latency still needs another pass.",
            "Sarah owns the numbers section and will send the revised deck by tonight.",
            "Let's protect Thursday morning for the deep-work block on the pricing model.",
        ]
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(120)
        for s in 0..<120 {
            segments.append(TranscriptSegment(seq: s, startMs: s * 4000, endMs: s * 4000 + 3500,
                                              text: sentences[(s + tick) % sentences.count],
                                              speaker: "speaker_\(s % 4)"))
        }
        var paragraphs: [TranscriptParagraph] = []
        paragraphs.reserveCapacity(25)
        for p in 0..<25 {
            paragraphs.append(TranscriptParagraph(start: Double(p) * 8, end: Double(p) * 8 + 7,
                                                  speaker: "speaker_\(p % 4)",
                                                  text: sentences[(p + tick) % sentences.count]))
        }
        TranscriptCacheStore.save(
            CachedTranscript(transcript: segments.map(\.text).joined(separator: " "),
                             title: "Conversation \(id.suffix(5))",
                             summary: "Finalized during the churn drive.",
                             segments: segments,
                             speakers: (0..<4).map {
                                 CaptureSpeaker(slot: "speaker_\($0)", status: .confirmed,
                                                name: "Speaker \($0)", confirmedSpeakerId: "spk-\($0)")
                             },
                             paragraphs: paragraphs,
                             fetchedAt: UInt64(max(0, Date().timeIntervalSince1970))),
            captureId: id, baseDir: baseDir)
        return justWritten(baseDir.appendingPathComponent(id, isDirectory: true)
                             .appendingPathComponent("transcript.json"))
    }

    // MARK: seeded-library discovery

    @MainActor private static var cachedIds: [String] = []
    /// The stress-seeded capture ids on disk (cached — the set is fixed for a launch).
    @MainActor private static func stressIds(base: URL) -> [String] {
        if !cachedIds.isEmpty { return cachedIds }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        cachedIds = names.filter { $0.hasPrefix("stress-") }.sorted()
        return cachedIds
    }
}
#endif
