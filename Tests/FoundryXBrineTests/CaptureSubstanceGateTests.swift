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

    private func makeManager(_ dir: URL, _ src: TestSource, _ rec: Recorder) -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        return CaptureManager(target: target, baseDir: dir, source: src,
                              finalize: { id, _ in rec.finalize(id) },
                              uploadSegment: { _, _, _ in rec.upload() })
    }

    private func discardMarkerExists(_ dir: URL, _ captureId: String) -> Bool {
        FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(captureId, isDirectory: true)
                .appendingPathComponent(".discarded").path)
    }

    // MARK: pure decisions

    func testHasUploadSubstanceFrameBar() {
        let bar = CaptureManager.minVoicedFramesToUpload
        // At/above the voiced-frame bar → real, regardless of transcript.
        XCTAssertTrue(CaptureManager.hasUploadSubstance(voicedFrames: bar, onDeviceTranscript: nil, durationSeconds: 3))
        XCTAssertTrue(CaptureManager.hasUploadSubstance(voicedFrames: bar + 500, onDeviceTranscript: "", durationSeconds: 5))
        // Below the bar with no / filler transcript → a fragment.
        XCTAssertFalse(CaptureManager.hasUploadSubstance(voicedFrames: bar - 1, onDeviceTranscript: nil, durationSeconds: 3))
        XCTAssertFalse(CaptureManager.hasUploadSubstance(voicedFrames: 5, onDeviceTranscript: "Thank you", durationSeconds: 2))
        XCTAssertFalse(CaptureManager.hasUploadSubstance(voicedFrames: 0, onDeviceTranscript: "   ", durationSeconds: 1))
    }

    func testHasUploadSubstanceTranscriptSafetyValve() {
        // A genuine brief exchange that under-voiced is KEPT when its on-device transcript
        // is already meaningful (passes the empty/filler filter).
        XCTAssertTrue(CaptureManager.hasUploadSubstance(
            voicedFrames: 10, onDeviceTranscript: "grab milk on the way home", durationSeconds: 4))
    }

    func testShouldEndSuspendedSession() {
        let w = CaptureManager.reconnectGraceWindow
        XCTAssertFalse(CaptureManager.shouldEndSuspendedSession(suspendedAt: 100, now: 100 + w - 0.5, window: w))
        XCTAssertTrue(CaptureManager.shouldEndSuspendedSession(suspendedAt: 100, now: 100 + w, window: w))
        XCTAssertTrue(CaptureManager.shouldEndSuspendedSession(suspendedAt: 100, now: 100 + w + 60, window: w))
    }

    // MARK: min-substance upload gate (integration)

    /// A conversation that closes (silence gap) with enough voice to SEGMENT but below the
    /// upload bar is DROPPED: never finalized, never uploaded, hidden — but kept on disk.
    func testSubStanceFragmentIsDroppedNotUploaded() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let rec = Recorder()
        let mgr = makeManager(dir, src, rec)
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
        let mgr = makeManager(dir, src, rec)
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
        let mgr = makeManager(dir, src, rec)

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
        let mgr = makeManager(dir, src, rec)

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
