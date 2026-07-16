import XCTest
import Foundation
import FoundryXKit

/// Door-free tests for the CAPTURE-SUBSTANCE GATE and OMI RECONNECT COALESCING — the two
/// guards that stop junk fragments from ever reaching Lore:
///
///   1. Min-substance upload gate — a capture with too little VOICED audio (a silent /
///      one-word blip, or a transient Omi reconnect stub) is DROPPED LOCALLY: it is never
///      finalized, never uploaded to the door, and never shown. A capture with a real bar
///      of voice (or an already-meaningful on-device transcript) uploads as before.
///
///   2. Reconnect coalescing — a brief Omi BLE drop HOLDS the open conversation for a short
///      grace window; a reconnect within it RESUMES the SAME captureId instead of minting a
///      new session and finalizing a stub. A drop that stays down past the window ends the
///      conversation normally.
///
/// All paths run through the manager's REAL lifecycle via a controllable source + injected
/// upload/finalize seams — no live door, no network, no hardware.
@MainActor
final class CaptureSubstanceGateTests: XCTestCase {

    /// A source the test drives directly (start/stop no-ops; the test fires the
    /// onFrame/onState closures CaptureManager installs).
    private final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    /// Records finalize + per-segment upload attempts so we can prove a fragment does
    /// NEITHER, and a real conversation does BOTH.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _finalizes: [String] = []
        private var _uploads = 0
        var finalizes: [String] { lock.lock(); defer { lock.unlock() }; return _finalizes }
        var uploads: Int { lock.lock(); defer { lock.unlock() }; return _uploads }
        func finalize(_ id: String) { lock.lock(); _finalizes.append(id); lock.unlock() }
        func upload() { lock.lock(); _uploads += 1; lock.unlock() }
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-substance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeManager(_ dir: URL, _ src: TestSource, _ rec: Recorder) async -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let m = CaptureManager(target: target, baseDir: dir, source: src,
                              finalize: { id, _ in rec.finalize(id) },
                              uploadSegment: { _, _, _ in rec.upload() })
        await m.hydration?.value
        return m
    }

    private func discardMarkerExists(_ dir: URL, _ captureId: String) -> Bool {
        FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(captureId, isDirectory: true)
                .appendingPathComponent(".discarded").path)
    }

    // MARK: pure decisions

    func testHasUploadSubstanceFrameBar() async {
        let bar = CaptureManager.minVoicedFramesToUpload
        // With NO on-device transcript, the raised voiced-frame bar is the only gate.
        XCTAssertTrue(CaptureManager.hasUploadSubstance(voicedFrames: bar, onDeviceTranscript: nil, durationSeconds: 3))
        XCTAssertTrue(CaptureManager.hasUploadSubstance(voicedFrames: bar + 500, onDeviceTranscript: "", durationSeconds: 5))
        // No transcript + below the (high) voiced bar → a fragment.
        XCTAssertFalse(CaptureManager.hasUploadSubstance(voicedFrames: bar - 1, onDeviceTranscript: nil, durationSeconds: 3))
        XCTAssertFalse(CaptureManager.hasUploadSubstance(voicedFrames: 5, onDeviceTranscript: "Thank you", durationSeconds: 2))
        XCTAssertFalse(CaptureManager.hasUploadSubstance(voicedFrames: 0, onDeviceTranscript: "   ", durationSeconds: 1))
    }

    /// THE FIX: when a transcript exists, content — not amplitude — decides. Ambient noise
    /// that cleared the level threshold for a long time but transcribes to nothing/filler is
    /// DROPPED, where the old amplitude-only gate uploaded it as a junk conversation.
    func testSubstantialVoicedAudioIsNeverDestroyedByAFillerPreview() async {
        let bar = CaptureManager.minVoicedFramesToUpload
        // PHILOSOPHY CHANGE (2026-07-15, omi-informed): the on-device transcript is the
        // LOW-QUALITY LIVE PREVIEW, not the authoritative Kiln transcript. Trusting it to
        // DISCARD destroyed a real ~4-min, 11,669-voiced-frame conversation. Following omi
        // (which never deletes voiced audio — low value becomes a restorable flag, only
        // truly-empty captures are dropped), SUBSTANTIAL VOICED AUDIO now always uploads,
        // even when the preview classifies it as filler. Genuine ambient noise is caught
        // downstream by Kiln's authoritative transcript, where a real transcript exists —
        // the harm of destroying a real conversation vastly outweighs an occasional noise
        // upload. (Was: `bar+1000 + filler → FALSE`; that rule caused the data loss.)
        XCTAssertTrue(CaptureManager.hasUploadSubstance(
            voicedFrames: bar + 1000, onDeviceTranscript: "thank you. okay. you.", durationSeconds: 45))
        // The specific regression: an 11,669-voiced-frame (~4 min) capture whose preview
        // read as filler is KEPT, not discarded.
        XCTAssertTrue(CaptureManager.hasUploadSubstance(
            voicedFrames: 11_669, onDeviceTranscript: "you. um. okay.", durationSeconds: 233))
        // Real speech of ANY length still clears it — content is what matters.
        XCTAssertTrue(CaptureManager.hasUploadSubstance(
            voicedFrames: 30, onDeviceTranscript: "can you grab milk on the way home", durationSeconds: 4))
        // A genuinely long capture with NO transcript (STT failed) is still kept.
        XCTAssertTrue(CaptureManager.hasUploadSubstance(
            voicedFrames: bar, onDeviceTranscript: nil, durationSeconds: 200))
        // Still dropped: thin captures — a filler preview AND sub-bar voiced audio (real
        // noise/ack fragments), the only case both signals agree is not worth keeping.
        XCTAssertFalse(CaptureManager.hasUploadSubstance(
            voicedFrames: 5, onDeviceTranscript: "thank you", durationSeconds: 2))
    }

    func testHasUploadSubstanceTranscriptSafetyValve() async {
        // A genuine brief exchange that under-voiced is KEPT when its on-device transcript
        // is already meaningful (passes the empty/filler filter).
        XCTAssertTrue(CaptureManager.hasUploadSubstance(
            voicedFrames: 10, onDeviceTranscript: "grab milk on the way home", durationSeconds: 4))
    }

    /// Launch hydration skips discarded junk fragments — the accumulation that overran the
    /// launch watchdog (SIGKILL) on a long-lived install. A real capture is still hydrated.
    func testLoadExistingSkipsDiscardedFragments() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let real = "omi-20260701-120000-realconv"
        let junk = "omi-20260701-110000-junkfrag"
        let realDir = dir.appendingPathComponent(real)
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: realDir.appendingPathComponent(CaptureWAL.segName(0)))
        let junkDir = dir.appendingPathComponent(junk)
        try fm.createDirectory(at: junkDir, withIntermediateDirectories: true)
        try Data().write(to: junkDir.appendingPathComponent(".discarded"))

        let mgr = await makeManager(dir, TestSource(), Recorder())   // init → loadExisting
        XCTAssertTrue(mgr.captures.contains { $0.captureId == real }, "a real capture is hydrated at launch")
        XCTAssertFalse(mgr.captures.contains { $0.captureId == junk }, "a discarded fragment is NOT hydrated")
    }

    /// DATA-LOSS REGRESSION (2026-07-13): a conversation whose audio (30d) and
    /// transcript text (14d) were pruned by RETENTION still holds its card
    /// tombstone (title + summary) and reads as 0-segment. Reconcile must NEVER
    /// discard it — the old rule (only isConfirmedInLore + hasCachedTranscript)
    /// deleted every phone-only conversation past the retention window (nothing
    /// is confirmed in Lore without a connected computer). A genuinely empty
    /// Omi-drop card (no tombstone at all) is still discarded.
    func testRetentionTombstoneSurvivesReconcileButEmptyCardIsDiscarded() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default

        // A real conversation, pruned to a tombstone: card kept, no audio, no
        // transcript, not in Lore, old start (aged past the stuck bar).
        let pruned = "omi-20250601-120000-boardmtg"
        try fm.createDirectory(at: dir.appendingPathComponent(pruned), withIntermediateDirectories: true)
        ConversationMetaStore.save(ConversationMeta(startedAt: 100, endedAt: 160),
                                   captureId: pruned, baseDir: dir)
        ConversationCardStore.merge(captureId: pruned, baseDir: dir,
                                    title: "Board meeting", summary: "Q3 review", stage: "ready")

        // A genuinely empty Omi-drop card: no card tombstone, no segments.
        let empty = "omi-20250601-110000-emptydrop"
        try fm.createDirectory(at: dir.appendingPathComponent(empty), withIntermediateDirectories: true)
        ConversationMetaStore.save(ConversationMeta(startedAt: 100, endedAt: nil),
                                   captureId: empty, baseDir: dir)

        let mgr = await makeManager(dir, TestSource(), Recorder())   // hydration → reconcile

        XCTAssertFalse(discardMarkerExists(dir, pruned),
                       "a retention tombstone (card kept) is NEVER discarded — the conversation survives")
        XCTAssertTrue(mgr.visibleCaptures.contains { $0.captureId == pruned },
                      "the pruned conversation stays browsable as title + summary")
        XCTAssertTrue(discardMarkerExists(dir, empty),
                      "a genuinely empty 0-segment card (no tombstone) is still discarded")
    }

    /// The suspended-session (reconnect-grace) end rule is driven by CONVERSATIONAL SILENCE,
    /// not disconnect wall-clock.
    ///
    /// Rationale (why this test was inverted from the old `now - suspendedAt >= 20s` window):
    /// this decision is evaluated by the main-runloop segment timer, which is SUSPENDED while
    /// the app is backgrounded. Under the OLD rule the whole background interval counted
    /// against the fixed 20s window, so the first foreground tick after an app-switch ended a
    /// still-live held conversation — and the next Omi reconnect began a FRESH capture id.
    /// That is the "going in/out of the app starts a new conversation each time" bug. A BLE
    /// disconnect is not conversational silence, so the hold now ends only after >= silenceGap
    /// (120s) of REAL voiced silence measured from the last voiced instant, with a short
    /// fallback for a hold that never heard voice and a 4h absolute backstop.
    func testShouldEndSuspendedSessionUsesVoicedSilenceNotDisconnectWallClock() async {
        let gap = SilenceSegmenter.defaultSilenceGap   // 120s
        let suspendedAt: TimeInterval = 1000

        // (a) The app-switch case that USED to split: disconnected 60s ago (well past the old
        //     20s window) but voice was heard only 10s ago → NOT a silence boundary → HELD, so
        //     a reconnect can resume the SAME captureId.
        let now = suspendedAt + 60
        XCTAssertFalse(CaptureManager.shouldEndSuspendedSession(
            lastVoicedAt: now - 10, suspendedAt: suspendedAt, now: now, silenceGap: gap),
            "recent voice (10s ago) means the disconnect is not a silence boundary — stay HELD")

        // (b) A real conversation boundary: >= silenceGap since the last voiced instant → END.
        let now2 = suspendedAt + 200
        XCTAssertTrue(CaptureManager.shouldEndSuspendedSession(
            lastVoicedAt: now2 - 130, suspendedAt: suspendedAt, now: now2, silenceGap: gap),
            "130s of voiced silence (> the 120s gap) is a genuine conversation boundary → end")
        XCTAssertTrue(CaptureManager.shouldEndSuspendedSession(
            lastVoicedAt: now2 - gap, suspendedAt: suspendedAt, now: now2, silenceGap: gap),
            "exactly silenceGap of voiced silence ends the held session")
        XCTAssertFalse(CaptureManager.shouldEndSuspendedSession(
            lastVoicedAt: now2 - (gap - 1), suspendedAt: suspendedAt, now: now2, silenceGap: gap),
            "just under the silence gap keeps the session held")

        // (c) Absolute 4h backstop: even with voice 1s ago, a session held past maxHold closes,
        //     so a truly abandoned hold can never linger open forever.
        let now3 = suspendedAt + CaptureManager.suspendedSessionMaxHold
        XCTAssertTrue(CaptureManager.shouldEndSuspendedSession(
            lastVoicedAt: now3 - 1, suspendedAt: suspendedAt, now: now3, silenceGap: gap),
            "the 4h absolute backstop force-closes a held session regardless of recent voice")

        // (d) No voiced audio EVER this session (lastVoicedAt == nil): there is nothing to
        //     continue, so fall back to the short reconnect timeout — not a full silence gap.
        let w = CaptureManager.reconnectGraceWindow
        XCTAssertFalse(CaptureManager.shouldEndSuspendedSession(
            lastVoicedAt: nil, suspendedAt: suspendedAt, now: suspendedAt + w - 0.5, silenceGap: gap),
            "a no-voice hold is not ended before the short reconnect timeout")
        XCTAssertTrue(CaptureManager.shouldEndSuspendedSession(
            lastVoicedAt: nil, suspendedAt: suspendedAt, now: suspendedAt + w, silenceGap: gap),
            "a no-voice hold ends at the short reconnect timeout (nothing to continue)")
    }

    // MARK: min-substance upload gate (integration)

    /// A conversation that closes (silence gap) with enough voice to SEGMENT but below the
    /// upload bar is DROPPED: never finalized, never uploaded, hidden — but kept on disk.
    func testSubStanceFragmentIsDroppedNotUploaded() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let rec = Recorder()
        let mgr = await makeManager(dir, src, rec)
        mgr.setSilenceGap(0)   // a silent frame right after voice closes the conversation

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let fragmentId = try XCTUnwrap(mgr.active).captureId

        // Enough voiced frames to CLOSE (≥ minVoicedFramesToClose) but well below the
        // upload bar — a borderline blip the gate must reject.
        let n = SilenceSegmenter.defaultMinVoicedFramesToClose + 20
        XCTAssertLessThan(n, CaptureManager.minVoicedFramesToUpload, "test premise: below the upload bar")
        for _ in 0..<n { src.onFrame?(RealOmiFrames.voiced()) }
        try XCTUnwrap(mgr.active).flushAndWait()
        src.onFrame?(RealOmiFrames.silent())   // exceeds the 0-gap → closes the conversation
        try await waitUntil { mgr.active?.captureId != fragmentId }

        // It was DISCARDED: a durable marker, no pending-finalize, hidden from the list.
        XCTAssertTrue(discardMarkerExists(dir, fragmentId), "a sub-substance fragment is marked discarded")
        XCTAssertFalse(mgr.visibleCaptures.contains { $0.captureId == fragmentId },
                       "a discarded fragment is not shown in the list")
        // Drain + finalize retries must NEVER upload or finalize the fragment.
        await mgr.drainPending()
        await mgr.retryPendingFinalizes()
        XCTAssertFalse(rec.finalizes.contains(fragmentId), "a fragment is never finalized")
        XCTAssertEqual(rec.uploads, 0, "a fragment's segments are never uploaded to the door")
        // But the audio is KEPT on disk (nothing deleted).
        let cdir = dir.appendingPathComponent(fragmentId, isDirectory: true)
        let opus = (try FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "opus" }.count
        XCTAssertGreaterThan(opus, 0, "the fragment's audio is retained locally, just not uploaded")
    }

    /// A conversation with a real bar of voice clears the gate → finalized + browsable.
    func testRealConversationClearsTheGateAndFinalizes() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let rec = Recorder()
        let mgr = await makeManager(dir, src, rec)
        mgr.setSilenceGap(0)

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let realId = try XCTUnwrap(mgr.active).captureId

        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) { src.onFrame?(RealOmiFrames.voiced()) }
        try XCTUnwrap(mgr.active).flushAndWait()
        src.onFrame?(RealOmiFrames.silent())
        try await waitUntil { mgr.active?.captureId != realId }

        XCTAssertFalse(discardMarkerExists(dir, realId), "a real conversation is NOT discarded")
        // ACK its segments then retry finalize → it advances to Lore, exactly as before.
        ackAllSegments(dir, realId)
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.finalizes, [realId], "a real conversation finalizes once, by its id")
    }

    // MARK: reconnect coalescing (integration)

    /// A transient Omi drop + reconnect within the grace window RESUMES the same
    /// conversation — no new captureId, no finalized stub.
    func testTransientReconnectResumesSameConversation() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let rec = Recorder()
        let mgr = await makeManager(dir, src, rec)

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let convo = try XCTUnwrap(mgr.active).captureId
        for _ in 0..<50 { src.onFrame?(RealOmiFrames.voiced()) }

        // BLE drops: the conversation is HELD open (not ended, not finalized, same id).
        src.onState?(.stopped)
        try await waitUntil { mgr.isAwaitingReconnect }
        XCTAssertEqual(mgr.active?.captureId, convo, "a transient drop holds the SAME conversation open")
        XCTAssertEqual(mgr.captures.count, 1, "no new capture is minted on the drop")

        // Reconnects quickly → resumes into the same conversation, no new session.
        src.onState?(.streaming)
        try await waitUntil { !mgr.isAwaitingReconnect }
        XCTAssertEqual(mgr.active?.captureId, convo, "a reconnect within grace resumes the SAME captureId")
        XCTAssertEqual(mgr.captures.count, 1, "reconnect did not mint a new conversation")
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload) { src.onFrame?(RealOmiFrames.voiced()) }

        // A grace-resolve now must NOT end it (the device reconnected).
        mgr.resolveReconnectGrace(now: Date().timeIntervalSince1970 + CaptureManager.reconnectGraceWindow + 1)
        XCTAssertEqual(mgr.active?.captureId, convo, "a resumed conversation is not ended by a stale grace")
        XCTAssertEqual(rec.finalizes, [], "no stub was finalized across the reconnect")
    }

    /// A drop that stays down past the grace window ends the conversation normally; with
    /// real content it finalizes (a genuine boundary is preserved).
    func testDisconnectPastGraceEndsAndFinalizesRealConversation() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let rec = Recorder()
        let mgr = await makeManager(dir, src, rec)

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let convo = try XCTUnwrap(mgr.active).captureId
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) { src.onFrame?(RealOmiFrames.voiced()) }
        try XCTUnwrap(mgr.active).flushAndWait()

        src.onState?(.stopped)                                  // BLE drops
        try await waitUntil { mgr.isAwaitingReconnect }
        XCTAssertEqual(mgr.active?.captureId, convo, "held open during the grace")
        // Grace elapses with no reconnect → the conversation ends.
        mgr.resolveReconnectGrace(now: Date().timeIntervalSince1970 + CaptureManager.reconnectGraceWindow + 1)
        try await waitUntil { mgr.active == nil }

        XCTAssertFalse(discardMarkerExists(dir, convo), "a real held conversation is finalized, not discarded")
        ackAllSegments(dir, convo)
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.finalizes, [convo], "a real conversation finalizes after the grace ends it")
    }

    // MARK: helpers

    private func ackAllSegments(_ dir: URL, _ captureId: String) {
        let cdir = dir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "opus" {
            try? Data().write(to: f.deletingPathExtension().appendingPathExtension("ack"), options: [.atomic])
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
