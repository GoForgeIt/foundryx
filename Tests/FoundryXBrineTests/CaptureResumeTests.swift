import XCTest
import Foundation
import BrineSwiftCore
import FoundryXKit

/// Resumable-upload tests for LARGE recordings (the user's "don't lose large
/// recordings" requirement). A multi-hour Omi capture is thousands of segments; if an
/// interrupted/relaunched sync restarted from seq 0 it would re-upload everything and
/// never finish (the real `omi-20260623-202901-66651093` churn). These prove the WAL
/// resumes from a durable UPLOAD WATERMARK — the highest contiguously-ACK'd seq —
/// uploading only segments AFTER it, making MONOTONIC forward progress across retries
/// and app-restarts (a fresh WAL on the same dir), then reaching pending == 0.
///
/// All door-free: the WAL's per-segment upload is injected, no network.
final class CaptureResumeTests: ProcessGlobalStateTestCase {

    func testResumeRecordingFeature() async throws {
        let url = URL(fileURLWithPath: #filePath)
        var root = url
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let text = try String(contentsOf: root.appendingPathComponent("features/resume-recording.feature"))
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        let world = ResumeRecordingWorld()
        let registry = StepRegistry(ResumeRecordingSteps.make(world: world))

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry,
                                             resources: [], collector: { collected.append($0) })

        var failures: [String] = []
        for ev in collected {
            guard case .object(let o) = ev,
                  case .string("scenario_end")? = o["type"],
                  case .string(let status)? = o["status"], status != "passed" else { continue }
            let name: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(name): \(err)")
        }
        XCTAssertTrue(failures.isEmpty, "resume-recording scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
    }

    /// Thread-safe recorder of the seqs the (injected) upload was asked to send.
    private final class SeqRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var seqs: [UInt64] = []
        var failAfter: Int = .max          // throw a TRANSIENT error after this many sends
        var failSeq: UInt64?
        func send(_ seq: UInt64) throws {
            lock.lock(); seqs.append(seq); let n = seqs.count; let cap = failAfter; lock.unlock()
            if seq == failSeq { throw DoorError.http(503) }
            if n > cap { throw DoorError.http(503) }   // door transiently down
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return seqs.count }
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func target() -> DoorTarget {
        DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
    }

    /// Write `n` segment files (seq 0…n-1) into a capture dir, and `.ack` siblings for
    /// the first `ackedThrough + 1` of them (−1 ⇒ none) — the durable resume point an
    /// interrupted or pre-existing upload would leave on disk.
    private func seedSegments(dir: URL, captureId: String, n: Int, ackedThrough: Int) throws {
        let cdir = dir.appendingPathComponent(captureId, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        for seq in 0..<n {
            let name = String(format: "seg-%012llu", UInt64(seq))
            try Data([UInt8(seq & 0xff), 1, 2, 3]).write(to: cdir.appendingPathComponent("\(name).opus"))
            if seq <= ackedThrough {
                try Data().write(to: cdir.appendingPathComponent("\(name).ack"))
            }
        }
    }

    /// Drain a WAL to completion (each `sync()` ships up to `maxSegmentsPerSync`).
    private func drainToDone(_ wal: CaptureWAL) async {
        var out = await wal.sync()
        var guardLoops = 0
        while out == .progressed, guardLoops < 10_000 { out = await wal.sync(); guardLoops += 1 }
    }

    // A pre-existing capture with the first N segments already ACK'd resumes from N+1,
    // never re-sending 0…N — the watermark is DERIVED from the on-disk `.ack` markers.
    func testResumesFromWatermarkNotZero() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-resume-watermark"
        try seedSegments(dir: dir, captureId: id, n: 10, ackedThrough: 4)   // 0…4 ACK'd

        let rec = SeqRecorder()
        let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir,
                             upload: { seq, _ in try rec.send(seq) })

        XCTAssertEqual(wal.uploadWatermark(), 4, "watermark derived from on-disk acks (contiguous run 0…4)")

        await drainToDone(wal)

        XCTAssertEqual(rec.seqs.sorted(), [5, 6, 7, 8, 9], "resumes AFTER the watermark — never re-sends 0…4")
        XCTAssertEqual(wal.uploadWatermark(), 9, "watermark advances to the last segment")
        XCTAssertEqual(wal.snapshot().pendingSegments, 0, "the large capture fully uploads")
    }

    // An interrupted sync PERSISTS progress (the watermark advances over the ACK'd
    // prefix), and a fresh WAL (an app-restart) advances from there — not from 0.
    func testInterruptedSyncPersistsProgressAndNextRunAdvances() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-resume-interrupted"
        try seedSegments(dir: dir, captureId: id, n: 10, ackedThrough: -1)   // nothing ACK'd yet

        // First run fails transiently on seq 3 → seqs 0,1,2 ACK'd, 3 fails.
        let rec1 = SeqRecorder(); rec1.failSeq = 3
        let wal1 = CaptureWAL(captureId: id, target: target(), baseDir: dir,
                              upload: { seq, _ in try rec1.send(seq) })
        let out1 = await wal1.sync()
        XCTAssertEqual(out1, .failed, "a transient door error stops the pass (not poison)")
        XCTAssertTrue(Set(rec1.seqs).isSuperset(of: [0, 1, 2, 3]), "attempted through the failing seq")
        // The anti-storm invariant is: a single pass NEVER re-sends a segment and never
        // dispatches more than the capture has. HOW FAR past the failing seq it dispatches
        // before halting depends on the platform task scheduler (macOS halts within ~2×
        // the concurrency window; iOS's eager scheduler may dispatch the whole wave) — and
        // either way in-flight is still capped by maxConcurrentSegmentUploads, so it's not
        // an FD storm. Assert the real invariant, not the macOS-scheduler-specific count.
        XCTAssertEqual(Set(rec1.seqs).count, rec1.seqs.count, "no segment is re-sent within a pass")
        XCTAssertLessThanOrEqual(rec1.seqs.count, 10, "bounded by the capture's segment count")
        XCTAssertEqual(wal1.uploadWatermark(), 2, "progress persisted: watermark advanced over 0,1,2")

        // Relaunch: a brand-new WAL on the same dir resumes from the persisted watermark.
        let rec2 = SeqRecorder()
        let wal2 = CaptureWAL(captureId: id, target: target(), baseDir: dir,
                              upload: { seq, _ in try rec2.send(seq) })
        XCTAssertEqual(wal2.uploadWatermark(), 2, "the fresh WAL loads the persisted watermark")

        await drainToDone(wal2)

        XCTAssertTrue(rec2.seqs.allSatisfy { $0 >= 3 }, "the next run advances past the watermark, no re-sends")
        XCTAssertTrue(rec2.seqs.contains(3), "the failed sequence is retried after relaunch")
        XCTAssertEqual(wal2.snapshot().pendingSegments, 0, "the capture completes across the interruption")
    }

    // A missing/corrupt local segment file is permanent poison — the WAL reports it so
    // the owner can retire the capture (keeping the audio that remains).
    func testMissingLocalSegmentIsPoison() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-resume-poison"
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        // A segment whose .opus file is unreadable: write an entry the scanner sees, then
        // make the path a DIRECTORY (so Data(contentsOf:) throws) to simulate corruption.
        let seg = cdir.appendingPathComponent("seg-000000000000.opus")
        try FileManager.default.createDirectory(at: seg, withIntermediateDirectories: true)

        let wal = CaptureWAL(captureId: id, target: target(), baseDir: dir,
                             upload: { _, _ in })   // upload would succeed — but the read fails first
        let out = await wal.sync()
        guard case .poisoned = out else { return XCTFail("expected .poisoned, got \(out)") }
        // The (corrupt) segment is still on disk — poison never deletes audio.
        XCTAssertTrue(FileManager.default.fileExists(atPath: seg.path), "poison keeps the data on disk")
    }

    @MainActor
    func testResumeReopensSameCaptureAndContinuesSegmentSequence() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let captureId = "omi-20260708-081100-resume"
        try seedSegments(dir: dir, captureId: captureId, n: 2, ackedThrough: 1)
        ConversationMetaStore.save(ConversationMeta(startedAt: 1_800_000_000, endedAt: 1_800_000_120),
                                   captureId: captureId, baseDir: dir)

        let src = ResumeRecordingWorld.TestSource()
        let mgr = ResumeRecordingWorld.makeManager(dir: dir, source: src)

        XCTAssertTrue(mgr.canResumeRecording(captureId: captureId))
        XCTAssertTrue(mgr.resumeRecording(captureId: captureId))
        XCTAssertEqual(mgr.active?.captureId, captureId)
        XCTAssertNil(ConversationMetaStore.load(captureId: captureId, baseDir: dir)?.endedAt,
                     "resuming reopens the existing conversation metadata")

        for _ in 0..<60 { src.onFrame?(RealOmiFrames.voiced()) }
        try await ResumeRecordingWorld.waitUntil { mgr.active?.snapshot().totalSegments ?? 0 > 2 }

        let files = try FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent(captureId, isDirectory: true),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertTrue(files.contains("seg-000000000002.opus"),
                      "new resume audio continues after the existing segment sequence")
    }

    @MainActor
    func testEndingResumedCaptureFinalizesSameIdAndStartsFreshNextCapture() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let captureId = "omi-20260708-081200-resume"
        try seedSegments(dir: dir, captureId: captureId, n: 1, ackedThrough: 0)
        ConversationMetaStore.save(ConversationMeta(startedAt: 1_800_000_000, endedAt: 1_800_000_060),
                                   captureId: captureId, baseDir: dir)

        let rec = ResumeRecordingWorld.FinalizeRecorder()
        let src = ResumeRecordingWorld.TestSource()
        let mgr = ResumeRecordingWorld.makeManager(dir: dir, source: src, finalize: { id, _ in rec.record(id) })
        XCTAssertTrue(mgr.resumeRecording(captureId: captureId))
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) { src.onFrame?(RealOmiFrames.voiced()) }
        try XCTUnwrap(mgr.active).flushAndWait()

        mgr.splitConversation()
        try await ResumeRecordingWorld.waitUntil { mgr.active != nil && mgr.active?.captureId != captureId }
        let next = try XCTUnwrap(mgr.active?.captureId)

        ResumeRecordingWorld.ackAllSegments(dir, captureId)
        await mgr.retryPendingFinalizes()

        XCTAssertEqual(rec.calls, [captureId], "the resumed conversation re-finalizes by the same id")
        XCTAssertNotEqual(next, captureId, "New opens a fresh conversation after ending the resumed one")
        // endedAt is stamped in endSession's detached Task, AFTER an async location fix
        // (currentLocation()), so it lands slightly after the split returns. Await it
        // rather than racing the assertion — on macOS the fix resolves fast enough that a
        // sync check happened to pass; the iOS-sim location provider is slower.
        try await ResumeRecordingWorld.waitUntil {
            ConversationMetaStore.load(captureId: captureId, baseDir: dir)?.endedAt != nil
        }
    }

    @MainActor
    func testPrunedAudioAndActiveCaptureBlockResume() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pruned = "omi-20260708-081300-pruned"
        ConversationMetaStore.save(ConversationMeta(startedAt: 1_800_000_000, endedAt: 1_800_000_060),
                                   captureId: pruned, baseDir: dir)
        let src = ResumeRecordingWorld.TestSource()
        let mgr = ResumeRecordingWorld.makeManager(dir: dir, source: src)

        XCTAssertFalse(mgr.canResumeRecording(captureId: pruned), "audio-pruned captures are not resumable")
        XCTAssertFalse(mgr.resumeRecording(captureId: pruned))

        let saved = "omi-20260708-081400-saved"
        try seedSegments(dir: dir, captureId: saved, n: 1, ackedThrough: 0)
        src.onState?(.streaming)
        try await ResumeRecordingWorld.waitUntil { mgr.active != nil }
        let activeId = try XCTUnwrap(mgr.active?.captureId)

        XCTAssertFalse(mgr.resumeRecording(captureId: saved), "one capture source records at a time")
        XCTAssertEqual(mgr.active?.captureId, activeId)
    }

    // MARK: resume-same-id across reconnect / relaunch (07-16 over-split fix)

    /// Set every `seg-*.opus` mtime of a capture, to fake how recently its audio landed —
    /// the axis `resumableCaptureId` measures against the silence gap.
    private func setSegmentMTimes(dir: URL, captureId: String, to date: Date) {
        let cdir = dir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "opus" {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: f.path)
        }
    }

    /// Write the durable source tag `beginSession` stamps (new-build captures) — so a
    /// resume candidate is recognised as an ambient/Omi (or phone-mic) capture.
    private func tagSource(dir: URL, captureId: String, _ kind: CaptureSourceKind) throws {
        try Data(kind.rawValue.utf8).write(to: dir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent(".capture-source"), options: [.atomic])
    }

    /// Write a bare marker file (e.g. `.ended-deliberately`) into a capture dir.
    private func writeMarker(dir: URL, captureId: String, _ name: String) throws {
        try Data().write(to: dir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent(name), options: [.atomic])
    }

    // The pure candidate selector: only the fresh, unmarked, in-gap capture is resumable —
    // `.deleted`, `.discarded`, confirmed-in-Lore, `.abandoned`, and older-than-gap captures
    // are all skipped (a stale/terminal capture must never be resumed into).
    func testResumableCandidateSelectionSkipsTerminalStaleAndConfirmed() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let gap: TimeInterval = 120

        func seed(_ id: String, ageSecs: TimeInterval, marker: String? = nil) throws {
            try seedSegments(dir: dir, captureId: id, n: 1, ackedThrough: 0)
            setSegmentMTimes(dir: dir, captureId: id, to: now.addingTimeInterval(-ageSecs))
            if let marker {
                try Data().write(to: dir.appendingPathComponent(id, isDirectory: true)
                    .appendingPathComponent(marker), options: [.atomic])
            }
        }
        try seed("fresh", ageSecs: 30)                        // in-gap + unmarked ⇒ THE candidate
        try seed("stale", ageSecs: 600)                       // older than the 120s gap ⇒ a real boundary
        try seed("deleted", ageSecs: 20, marker: ".deleted")
        try seed("discarded", ageSecs: 20, marker: ".discarded")
        try seed("confirmed", ageSecs: 20, marker: ".lore-confirmed")
        try seed("abandoned", ageSecs: 20, marker: ".abandoned")
        // Review P2 regression cases: however fresh the audio, a reconnect must never
        // reopen a conversation the user/segmenter deliberately ended, hijack a phone-mic
        // recording, or resume a legacy (untagged) capture that already carries an end.
        try seed("endedDelib", ageSecs: 20)                   // deliberate boundary (endSession)
        try tagSource(dir: dir, captureId: "endedDelib", .omi)
        try writeMarker(dir: dir, captureId: "endedDelib", ".ended-deliberately")
        try seed("micStopped", ageSecs: 20)                   // an explicit phone-mic recording
        try tagSource(dir: dir, captureId: "micStopped", .phoneMic)
        try writeMarker(dir: dir, captureId: "micStopped", ".needs-finalize")
        try seed("legacyEnded", ageSecs: 20)                  // pre-tag capture with ANY end
        ConversationMetaStore.save(ConversationMeta(startedAt: UInt64(now.timeIntervalSince1970) - 90,
                                                    endedAt: UInt64(now.timeIntervalSince1970) - 25),
                                   captureId: "legacyEnded", baseDir: dir)

        XCTAssertEqual(CaptureManager.resumableCaptureId(baseDir: dir, now: now, silenceGap: gap),
                       "fresh", "only the fresh, unmarked, in-gap capture is resumable")

        try FileManager.default.removeItem(at: dir.appendingPathComponent("fresh", isDirectory: true))
        XCTAssertNil(CaptureManager.resumableCaptureId(baseDir: dir, now: now, silenceGap: gap),
                     "no fresh unmarked in-gap capture → a new conversation is minted")
    }

    // The 07-16 timeline: a meeting's capture died mid-stream (iOS watchdog kill — no
    // endSession), and Omi buffered catch-up audio kept landing under the SAME id. A
    // reconnect/relaunch 30s after the newest segment RESUMES the same conversation (no
    // new id); a reconnect 10 minutes after the newest segment is a real boundary and
    // mints a NEW conversation.
    @MainActor
    func testReconnectWithinGapResumesSameId_relaunchAfterGapMintsNew() async throws {
        // ——— Reconnect INSIDE the silence gap → resume the same id. ———
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let meeting = "omi-20260716-145612-meeting"
        try seedSegments(dir: dir, captureId: meeting, n: 6, ackedThrough: 5)
        // An orphan-reconcile froze endedAt +12s after start, but the newest catch-up
        // segment is only ~30s old — well inside the 120s silence gap.
        let start = UInt64(Date().timeIntervalSince1970) - 40
        ConversationMetaStore.save(ConversationMeta(startedAt: start, endedAt: start + 12),
                                   captureId: meeting, baseDir: dir)
        try tagSource(dir: dir, captureId: meeting, .omi)   // a new-build ambient capture
        setSegmentMTimes(dir: dir, captureId: meeting, to: Date().addingTimeInterval(-30))

        let src = ResumeRecordingWorld.TestSource()
        let mgr = ResumeRecordingWorld.makeManager(dir: dir, source: src)
        mgr.setSilenceGap(120)
        await mgr.hydration?.value

        src.onState?(.streaming)   // the pendant reconnects / the app relaunches
        try await ResumeRecordingWorld.waitUntil { mgr.active != nil }
        XCTAssertEqual(mgr.active?.captureId, meeting,
                       "a reconnect 30s after the newest segment RESUMES the same conversation — no split")
        XCTAssertEqual(mgr.captures.filter { $0.captureId == meeting }.count, 1,
                       "the resumed capture reuses its hydrated row — no duplicate")

        // ——— The newest audio is 10 minutes old (past the gap) → a NEW conversation. ———
        let dir2 = try tempDir(); defer { try? FileManager.default.removeItem(at: dir2) }
        let earlier = "omi-20260716-133000-earlier"
        try seedSegments(dir: dir2, captureId: earlier, n: 4, ackedThrough: 3)
        setSegmentMTimes(dir: dir2, captureId: earlier, to: Date().addingTimeInterval(-600))
        let base = UInt64(Date().timeIntervalSince1970)
        ConversationMetaStore.save(ConversationMeta(startedAt: base - 700, endedAt: base - 600),
                                   captureId: earlier, baseDir: dir2)

        let src2 = ResumeRecordingWorld.TestSource()
        let mgr2 = ResumeRecordingWorld.makeManager(dir: dir2, source: src2)
        mgr2.setSilenceGap(120)
        await mgr2.hydration?.value

        // Past the gap there is no resumable candidate → speech-gated: streaming ARMS,
        // and a real speech onset mints the NEW conversation.
        src2.onState?(.streaming)
        RealOmiFrames.openSession(src2.onFrame)
        try await ResumeRecordingWorld.waitUntil { mgr2.active != nil }
        XCTAssertNotEqual(mgr2.active?.captureId, earlier,
                          "10 minutes after the newest segment is a real boundary — the next speech mints a NEW conversation")
    }

    // Resuming clears a half-shipped finalize marker (so it can't race the resumed
    // session) and reopens the meta (the stale early end is cleared); the eventual real
    // end then overwrites it and is never before the capture's own newest audio.
    @MainActor
    func testResumeClearsPendingFinalizeAndEndOverwritesStaleEnd() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-20260716-150556-fragment"
        try seedSegments(dir: dir, captureId: id, n: 3, ackedThrough: 2)
        setSegmentMTimes(dir: dir, captureId: id, to: Date().addingTimeInterval(-20))
        let start = UInt64(Date().timeIntervalSince1970) - 30
        ConversationMetaStore.save(ConversationMeta(startedAt: start, endedAt: start + 8),
                                   captureId: id, baseDir: dir)
        try tagSource(dir: dir, captureId: id, .omi)   // ambient capture, orphan-stamped end
        let needsFinalize = dir.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(".needs-finalize")
        try Data().write(to: needsFinalize, options: [.atomic])

        let src = ResumeRecordingWorld.TestSource()
        // A FAILING finalize so the 5s drain timer can't clear the marker out from under
        // the assertion — only the resume path should clear it here.
        let mgr = ResumeRecordingWorld.makeManager(dir: dir, source: src,
                                                   finalize: { _, _ in throw DoorError.http(503) })
        mgr.setSilenceGap(120)
        await mgr.hydration?.value

        src.onState?(.streaming)
        try await ResumeRecordingWorld.waitUntil { mgr.active?.captureId == id }
        XCTAssertFalse(FileManager.default.fileExists(atPath: needsFinalize.path),
                       "resume clears the pending-finalize marker so it can't race the resumed session")
        XCTAssertNil(ConversationMetaStore.load(captureId: id, baseDir: dir)?.endedAt,
                     "resuming reopens the conversation — the stale early end is cleared")

        // More audio arrives, then the conversation really ends → the real end overwrites.
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) { src.onFrame?(RealOmiFrames.voiced()) }
        mgr.active?.flushAndWait()
        mgr.splitConversation()
        try await ResumeRecordingWorld.waitUntil {
            ConversationMetaStore.load(captureId: id, baseDir: dir)?.endedAt != nil
        }
        let end = try XCTUnwrap(ConversationMetaStore.load(captureId: id, baseDir: dir)?.endedAt)
        XCTAssertGreaterThan(end, start + 8, "the eventual real end overwrites the stale early endedAt")
        if let newest = CaptureManager.newestSegmentMTimeOnDisk(id, baseDir: dir) {
            XCTAssertGreaterThanOrEqual(end + 2, UInt64(max(0, newest.timeIntervalSince1970)),
                                        "the recorded end is not before the capture's own newest audio")
        }
    }

    // The candidate scan is BOUNDED (review P1): among many directories it inspects only
    // the newest few, sorts newest-first by the id's embedded start time, and picks the
    // newest qualifying ambient capture — skipping a still-newer phone-mic recording.
    func testResumableScanIsBoundedAndNewestFirst() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()

        // 30 older, deliberately-ended ambient captures (noise the scan must not need to reach).
        for i in 0..<30 {
            let id = String(format: "omi-20260716-12%02d00-old%02d", i % 60, i)
            try seedSegments(dir: dir, captureId: id, n: 1, ackedThrough: 0)
            setSegmentMTimes(dir: dir, captureId: id, to: now.addingTimeInterval(-40))
            try tagSource(dir: dir, captureId: id, .omi)
            try writeMarker(dir: dir, captureId: id, ".ended-deliberately")
        }
        // The NEWEST capture is a phone-mic recording → must be skipped by the source gate.
        let mic = "omi-20260716-150500-mic"
        try seedSegments(dir: dir, captureId: mic, n: 1, ackedThrough: 0)
        setSegmentMTimes(dir: dir, captureId: mic, to: now.addingTimeInterval(-10))
        try tagSource(dir: dir, captureId: mic, .phoneMic)
        // The next-newest is the ambient capture to resume.
        let ambient = "omi-20260716-150400-ambient"
        try seedSegments(dir: dir, captureId: ambient, n: 200, ackedThrough: 199)   // many segments
        setSegmentMTimes(dir: dir, captureId: ambient, to: now.addingTimeInterval(-20))
        try tagSource(dir: dir, captureId: ambient, .omi)

        XCTAssertEqual(CaptureManager.resumableCaptureId(baseDir: dir, now: now, silenceGap: 120),
                       ambient, "newest-first, source-gated → the newest ambient capture is resumed")

        // The by-name shortcut returns the newest segment's mtime without statting all 200.
        let mtime = try XCTUnwrap(CaptureManager.newestSegmentMTimeByName(ambient, baseDir: dir))
        XCTAssertEqual(mtime.timeIntervalSince1970, now.addingTimeInterval(-20).timeIntervalSince1970,
                       accuracy: 1.5, "newest-segment-by-name reads the highest-seq file's mtime")
    }

    // Source + boundary gates (review P2): a phone-mic recording is never resumed by an
    // Omi reconnect; a deliberately-ended capture is never resumed; an orphan-stamped Omi
    // capture IS resumed; and a legacy untagged capture is resumable only when it never
    // got any end (endedAt == nil).
    func testResumableCandidateSourceAndBoundaryGates() throws {
        let now = Date()
        func fresh(_ dir: URL, _ id: String) throws {
            try seedSegments(dir: dir, captureId: id, n: 1, ackedThrough: 0)
            setSegmentMTimes(dir: dir, captureId: id, to: now.addingTimeInterval(-20))
        }

        // (1) phone-mic, freshly stopped (<120s), even with an orphan-shaped state → skipped.
        let d1 = try tempDir(); defer { try? FileManager.default.removeItem(at: d1) }
        try fresh(d1, "omi-20260716-150000-mic")
        try tagSource(dir: d1, captureId: "omi-20260716-150000-mic", .phoneMic)
        XCTAssertNil(CaptureManager.resumableCaptureId(baseDir: d1, now: now, silenceGap: 120),
                     "an Omi reconnect never resumes a phone-mic recording (shared omi- prefix)")

        // (2) ambient but DELIBERATELY ended (silence roll / manual stop) → skipped.
        let d2 = try tempDir(); defer { try? FileManager.default.removeItem(at: d2) }
        try fresh(d2, "omi-20260716-150000-rolled")
        try tagSource(dir: d2, captureId: "omi-20260716-150000-rolled", .omi)
        try writeMarker(dir: d2, captureId: "omi-20260716-150000-rolled", ".ended-deliberately")
        XCTAssertNil(CaptureManager.resumableCaptureId(baseDir: d2, now: now, silenceGap: 120),
                     "a deliberately-ended conversation is never resumed")

        // (3) ambient, ORPHAN-stamped end (endedAt set, no deliberate marker) → resumed.
        let d3 = try tempDir(); defer { try? FileManager.default.removeItem(at: d3) }
        let orphan = "omi-20260716-150000-orphan"
        try fresh(d3, orphan)
        try tagSource(dir: d3, captureId: orphan, .omi)
        ConversationMetaStore.save(ConversationMeta(startedAt: UInt64(now.timeIntervalSince1970) - 60,
                                                    endedAt: UInt64(now.timeIntervalSince1970) - 48),
                                   captureId: orphan, baseDir: d3)
        XCTAssertEqual(CaptureManager.resumableCaptureId(baseDir: d3, now: now, silenceGap: 120),
                       orphan, "an orphan-stamped Omi capture (catch-up audio still arriving) IS resumed")

        // (4) LEGACY untagged with an end set → skipped (can't tell orphan from deliberate).
        let d4 = try tempDir(); defer { try? FileManager.default.removeItem(at: d4) }
        let legacyEnded = "omi-20260716-150000-legacyend"
        try fresh(d4, legacyEnded)
        ConversationMetaStore.save(ConversationMeta(startedAt: UInt64(now.timeIntervalSince1970) - 60,
                                                    endedAt: UInt64(now.timeIntervalSince1970) - 48),
                                   captureId: legacyEnded, baseDir: d4)
        XCTAssertNil(CaptureManager.resumableCaptureId(baseDir: d4, now: now, silenceGap: 120),
                     "a legacy untagged capture with an end is treated conservatively — not resumed")

        // (5) LEGACY untagged, never ended (a true orphan) → resumed.
        let d5 = try tempDir(); defer { try? FileManager.default.removeItem(at: d5) }
        let legacyOrphan = "omi-20260716-150000-legacyorphan"
        try fresh(d5, legacyOrphan)
        XCTAssertEqual(CaptureManager.resumableCaptureId(baseDir: d5, now: now, silenceGap: 120),
                       legacyOrphan, "a legacy untagged true orphan (endedAt == nil) is resumed")
    }
}

@MainActor
private final class ResumeRecordingWorld: @unchecked Sendable {
    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    final class FinalizeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ id: String) { lock.lock(); _calls.append(id); lock.unlock() }
    }

    var dir: URL!
    var source: TestSource!
    var manager: CaptureManager!
    var savedId: String?
    var activeBeforeResume: String?
    var finalizer = FinalizeRecorder()

    func reset() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-resume-brine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = TestSource()
        savedId = nil
        activeBeforeResume = nil
        finalizer = FinalizeRecorder()
        manager = Self.makeManager(dir: dir, source: source, finalize: { [finalizer] id, _ in finalizer.record(id) })
    }

    static func makeManager(dir: URL,
                            source: TestSource,
                            finalize: (@Sendable (String, ConversationMeta?) async throws -> Void)? = nil) -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: source,
                              finalize: finalize ?? { _, _ in },
                              // Door-free (this suite injects the upload, never the network): return
                              // nil = old-door 404 → the resync handshake memoises and does NO network
                              // fetch, so a drain never dials the dead 127.0.0.1:1 and stalls the waits.
                              fetchSegments: { _ in nil })
        #if os(iOS)
        mgr.micPermissionOverrideForTests = true  // sim can't drive the real permission prompt
        #endif
        return mgr
    }

    func seedSavedConversation(id: String = "omi-20260708-081500-saved", segments: Int = 1) throws {
        savedId = id
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        for seq in 0..<segments {
            let name = String(format: "seg-%012llu.opus", UInt64(seq))
            try CaptureWAL.encodeSegment([RealOmiFrames.voiced()])
                .write(to: cdir.appendingPathComponent(name), options: [.atomic])
            try Data().write(to: cdir.appendingPathComponent(name).deletingPathExtension().appendingPathExtension("ack"),
                             options: [.atomic])
        }
        ConversationMetaStore.save(ConversationMeta(startedAt: 1_800_000_000, endedAt: 1_800_000_060),
                                   captureId: id, baseDir: dir)
        if manager.active == nil {
            manager = Self.makeManager(dir: dir, source: source, finalize: { [finalizer] id, _ in finalizer.record(id) })
        }
    }

    func seedPrunedConversation() throws {
        savedId = "omi-20260708-081600-pruned"
        ConversationMetaStore.save(ConversationMeta(startedAt: 1_800_000_000, endedAt: 1_800_000_060),
                                   captureId: savedId!, baseDir: dir)
        manager = Self.makeManager(dir: dir, source: source, finalize: { [finalizer] id, _ in finalizer.record(id) })
    }

    func captureAudio(frames: Int = 60) async throws {
        for _ in 0..<frames { source.onFrame?(RealOmiFrames.voiced()) }
        try await Self.waitUntil { self.manager.active?.snapshot().streaming == true }
        manager.active?.flushAndWait()
    }

    static func ackAllSegments(_ dir: URL, _ captureId: String) {
        let cdir = dir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "opus" {
            try? Data().write(to: f.deletingPathExtension().appendingPathExtension("ack"), options: [.atomic])
        }
    }

    /// Block until the manager's async hydration (the startup-hang fix: on-disk
    /// discovery moved off the init thread) has landed, so a scenario never races the
    /// background scan/sweep against its own resume/capture actions.
    func awaitHydration() async {
        let h = await MainActor.run { manager.hydration }
        await h?.value
    }

    static func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { throw ResumeRecordingStepError("waitUntil timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static func waitUntilAsync(timeout: TimeInterval = 3, _ cond: @Sendable () async -> Bool) async throws {
        let start = Date()
        while !(await cond()) {
            if Date().timeIntervalSince(start) > timeout { throw ResumeRecordingStepError("waitUntil timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct ResumeRecordingStepError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private enum ResumeRecordingSteps {
    static func make(world w: ResumeRecordingWorld) -> [StepDefinition] {
        [
            defineStep("I have a saved conversation with local audio") { ctx, _, _ in
                try await MainActor.run { try w.reset(); try w.seedSavedConversation() }
                await w.awaitHydration()
                return ctx
            },
            defineStep("I have resumed a saved conversation with local audio") { ctx, _, _ in
                try await MainActor.run { try w.reset(); try w.seedSavedConversation() }
                await w.awaitHydration()   // hydrate before resuming, or the background scan races the resume
                try await MainActor.run {
                    guard let id = w.savedId, w.manager.resumeRecording(captureId: id) else {
                        throw ResumeRecordingStepError("resume did not start")
                    }
                }
                return ctx
            },
            defineStep("I have a saved conversation whose local audio was pruned") { ctx, _, _ in
                try await MainActor.run { try w.reset(); try w.seedPrunedConversation() }
                await w.awaitHydration()
                return ctx
            },
            defineStep("I am already recording a conversation") { ctx, _, _ in
                try await MainActor.run {
                    try w.reset()
                    w.source.onState?(.streaming)
                    RealOmiFrames.openSession(w.source.onFrame)   // speech onset opens the conversation
                }
                await w.awaitHydration()
                try await ResumeRecordingWorld.waitUntilAsync {
                    await MainActor.run { w.manager.active != nil }
                }
                await MainActor.run { w.activeBeforeResume = w.manager.active?.captureId }
                return ctx
            },
            defineStep("I have another saved conversation with local audio") { ctx, _, _ in
                try await MainActor.run { try w.seedSavedConversation(id: "omi-20260708-081700-other") }
                return ctx
            },
            defineStep("I resume recording from that conversation") { ctx, _, _ in
                try await MainActor.run {
                    guard let id = w.savedId, w.manager.resumeRecording(captureId: id) else {
                        throw ResumeRecordingStepError("resume did not start")
                    }
                }
                return ctx
            },
            defineStep("new audio is captured") { ctx, _, _ in
                try await w.captureAudio()
                return ctx
            },
            defineStep("I start a new conversation") { ctx, _, _ in
                let id = try await MainActor.run { () throws -> String in
                    guard let id = w.savedId else { throw ResumeRecordingStepError("missing saved id") }
                    for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) {
                        w.source.onFrame?(RealOmiFrames.voiced())
                    }
                    w.manager.active?.flushAndWait()
                    w.manager.splitConversation()
                    return id
                }
                try await ResumeRecordingWorld.waitUntilAsync {
                    await MainActor.run { w.manager.active != nil && w.manager.active?.captureId != id }
                }
                await MainActor.run {
                    ResumeRecordingWorld.ackAllSegments(w.dir, id)
                    Task { await w.manager.retryPendingFinalizes() }
                }
                try await ResumeRecordingWorld.waitUntilAsync {
                    await MainActor.run { w.finalizer.calls == [id] }
                }
                return ctx
            },
            defineStep("I try to resume recording from the saved conversation") { ctx, _, _ in
                await MainActor.run {
                    if let id = w.savedId { _ = w.manager.resumeRecording(captureId: id) }
                }
                return ctx
            },
            defineCheck("the same conversation is active") { _, _, _ in
                let ok = await MainActor.run { w.manager.active?.captureId == w.savedId }
                guard ok else { throw ResumeRecordingStepError("saved conversation is not active") }
            },
            defineCheck("the new audio is appended after the existing audio") { _, _, _ in
                try await MainActor.run {
                    guard let id = w.savedId else { throw ResumeRecordingStepError("missing saved id") }
                    let snap = w.manager.active?.snapshot()
                    guard (snap?.totalSegments ?? 0) > 1 else { throw ResumeRecordingStepError("no appended segment") }
                    let path = w.dir.appendingPathComponent(id, isDirectory: true)
                        .appendingPathComponent("seg-000000000001.opus")
                    guard FileManager.default.fileExists(atPath: path.path) else {
                        throw ResumeRecordingStepError("appended seq 1 missing")
                    }
                }
            },
            defineCheck("no duplicate conversation is created") { _, _, _ in
                try await MainActor.run {
                    guard let id = w.savedId else { throw ResumeRecordingStepError("missing saved id") }
                    let matching = w.manager.captures.filter { $0.captureId == id }
                    guard matching.count == 1 else { throw ResumeRecordingStepError("expected one row, got \(matching.count)") }
                }
            },
            defineCheck("the resumed conversation is finalized again") { _, _, _ in
                try await MainActor.run {
                    guard let id = w.savedId, w.finalizer.calls == [id] else {
                        throw ResumeRecordingStepError("finalize calls \(w.finalizer.calls), expected saved id")
                    }
                }
            },
            defineCheck("the next active conversation is fresh") { _, _, _ in
                try await MainActor.run {
                    guard let id = w.savedId, let active = w.manager.active?.captureId, active != id else {
                        throw ResumeRecordingStepError("active conversation is not fresh")
                    }
                }
            },
            defineCheck("I cannot resume recording from that conversation") { _, _, _ in
                try await MainActor.run {
                    guard let id = w.savedId else { throw ResumeRecordingStepError("missing saved id") }
                    guard !w.manager.canResumeRecording(captureId: id), !w.manager.resumeRecording(captureId: id) else {
                        throw ResumeRecordingStepError("pruned capture was resumable")
                    }
                }
            },
            defineCheck("the current recording remains active") { _, _, _ in
                let ok = await MainActor.run { w.manager.active?.captureId == w.activeBeforeResume }
                guard ok else { throw ResumeRecordingStepError("active recording changed") }
            },
            defineCheck("the saved conversation is not reopened") { _, _, _ in
                let ok = await MainActor.run { w.manager.active?.captureId != w.savedId }
                guard ok else { throw ResumeRecordingStepError("saved conversation reopened despite active recording") }
            },
        ]
    }
}
