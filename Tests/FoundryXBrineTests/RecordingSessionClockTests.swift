import XCTest
import Foundation
import FoundryXKit

/// CaptureManager-level tests for the SESSION-OWNED recording clock (track
/// 20260717T0630, Bug 1). The manager owns `recordingClock`; views only DERIVE from it.
/// These prove the law end-to-end through the real capture lifecycle:
///   • an ambient / phone-mic session start STAMPS the clock;
///   • minimize → restore leaves it UNTOUCHED (the minimize→restore continuity the bug
///     was about — a fresh view present cannot reset it);
///   • an internal silence-gap roll PRESERVES it (the anchor is the recording session,
///     not the conversation);
///   • an explicit split / End-current RESETS it (a new anchor);
///   • phone-mic stop CLEARS it;
///   • pause() / resume() are reflected in the clock.
///
/// All door-free, driven by a controllable source — the same seams the substance-gate /
/// resume tests use (no new production seam invented).
@MainActor
final class RecordingSessionClockTests: XCTestCase {

    /// A source the test drives directly (start/stop no-ops; the test fires the
    /// onFrame/onState closures CaptureManager installs).
    private final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-sessionclock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeManager(_ dir: URL, source: TestSource, micSource: TestSource? = nil) async -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let m = CaptureManager(target: target, baseDir: dir, source: source, micSource: micSource,
                               finalize: { _, _ in },
                               fetchSegments: { _ in nil })
        #if os(iOS)
        m.micPermissionOverrideForTests = true   // the sim can't drive the real permission prompt
        #endif
        await m.hydration?.value
        return m
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: (a) session start stamps the clock

    func testAmbientSessionStartStampsClock() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir, source: src)
        XCTAssertNil(mgr.recordingClock, "no clock before any session")

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        XCTAssertNotNil(mgr.recordingClock, "an ambient session start stamps the session clock")
    }

    func testMicSessionStartStampsClock() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let omi = TestSource(); let mic = TestSource()
        let mgr = await makeManager(dir, source: omi, micSource: mic)
        XCTAssertNil(mgr.recordingClock)

        mgr.startMicRecording()   // beginMicRecording stamps synchronously (never born paused)
        XCTAssertNotNil(mgr.recordingClock, "a phone-mic recording start stamps the session clock")
        XCTAssertEqual(mgr.recordingClock?.isPaused, false, "a fresh mic recording is never born paused")
    }

    // MARK: (b) minimize → restore leaves the clock untouched

    func testMinimizeRestorePreservesClock() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir, source: src)
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let before = mgr.recordingClock

        mgr.minimizeRecordingScreen()
        mgr.restoreRecordingScreen()
        XCTAssertEqual(mgr.recordingClock, before,
                       "minimize → restore must NOT touch the clock (a re-present holds no timer)")
    }

    // MARK: (c) an internal silence-gap roll PRESERVES the clock

    func testInternalSilenceRollPreservesClock() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir, source: src)
        mgr.setSilenceGap(0)   // a silent frame right after voice closes → an internal roll

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let firstId = try XCTUnwrap(mgr.active).captureId
        let anchor = try XCTUnwrap(mgr.recordingClock?.startedAt)

        // Enough voiced frames to CLOSE (≥ minVoicedFramesToClose), then a silent frame
        // past the 0-gap rolls the conversation: endSession(); beginSession().
        for _ in 0..<(SilenceSegmenter.defaultMinVoicedFramesToClose + 20) { src.onFrame?(RealOmiFrames.voiced()) }
        mgr.active?.flushAndWait()
        src.onFrame?(RealOmiFrames.silent())
        try await waitUntil { mgr.active?.captureId != firstId }

        XCTAssertNotNil(mgr.recordingClock, "the clock survives an internal roll")
        XCTAssertEqual(mgr.recordingClock?.startedAt, anchor,
                       "an internal silence-gap roll PRESERVES the session anchor (invisible to the user)")
    }

    // MARK: (d) explicit split / End-current RESETS the clock

    func testManualSplitResetsClock() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir, source: src)
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let firstId = try XCTUnwrap(mgr.active).captureId
        let anchor = try XCTUnwrap(mgr.recordingClock?.startedAt)

        try await Task.sleep(nanoseconds: 30_000_000)   // let wall-clock advance so a fresh anchor is observably later
        mgr.splitConversation()
        try await waitUntil { mgr.active != nil && mgr.active?.captureId != firstId }

        let fresh = try XCTUnwrap(mgr.recordingClock?.startedAt)
        XCTAssertGreaterThan(fresh, anchor, "a manual split RESETS the clock to a fresh anchor")
    }

    func testEndCurrentConversationResetsClock() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir, source: src)
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let firstId = try XCTUnwrap(mgr.active).captureId
        let anchor = try XCTUnwrap(mgr.recordingClock?.startedAt)

        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(mgr.endCurrentConversation())
        try await waitUntil { mgr.active != nil && mgr.active?.captureId != firstId }

        let fresh = try XCTUnwrap(mgr.recordingClock?.startedAt)
        XCTAssertGreaterThan(fresh, anchor, "End-current (routes through split) RESETS the clock")
    }

    // MARK: (e) phone-mic stop clears the clock

    func testMicStopClearsClock() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let omi = TestSource(); let mic = TestSource()
        let mgr = await makeManager(dir, source: omi, micSource: mic)
        mgr.startMicRecording()
        mic.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        XCTAssertNotNil(mgr.recordingClock)

        mic.onState?(.stopped)
        try await waitUntil { mgr.recordingClock == nil }
        XCTAssertNil(mgr.recordingClock, "an explicit phone-mic stop CLEARS the session clock")
        XCTAssertFalse(mgr.isRecordingMic)
    }

    // MARK: (e2) deleting the LIVE recording clears the clock (review M1)

    func testDeleteActiveConversationClearsClockSoNextSessionAnchorsFresh() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir, source: src)
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let firstId = try XCTUnwrap(mgr.active).captureId
        let anchor = try XCTUnwrap(mgr.recordingClock?.startedAt)

        mgr.deleteConversation(firstId)
        XCTAssertNil(mgr.recordingClock,
                     "deleting the live recording is an explicit end — the clock must clear")

        // The Omi re-streams → a NEW session must anchor FRESH, not inherit the stale
        // clock through beginSession's stamp-only-if-nil guard.
        try await Task.sleep(nanoseconds: 30_000_000)
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let fresh = try XCTUnwrap(mgr.recordingClock?.startedAt)
        XCTAssertGreaterThan(fresh, anchor, "the re-streamed session anchors a fresh clock")
    }

    // MARK: (f) pause() / resume() reflect in the clock

    func testPauseResumeReflectedInClock() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir, source: src)
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        XCTAssertEqual(mgr.recordingClock?.isPaused, false)

        mgr.pause()
        XCTAssertEqual(mgr.recordingClock?.isPaused, true, "pause() freezes the session clock")
        let frozen = try XCTUnwrap(mgr.recordingClock).elapsed(now: Date())
        try await Task.sleep(nanoseconds: 40_000_000)
        let stillFrozen = try XCTUnwrap(mgr.recordingClock).elapsed(now: Date())
        XCTAssertEqual(stillFrozen, frozen, accuracy: 0.05, "elapsed holds steady while paused")

        mgr.resume()
        XCTAssertEqual(mgr.recordingClock?.isPaused, false, "resume() unfreezes the clock")
    }
}
