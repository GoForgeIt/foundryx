import XCTest
import Foundation
@testable import FoundryXKit

/// Tests for the refined capture Live Activity (Dynamic Island + lock screen):
///  1. The RECORDING-ACTIVE vs PAUSED vs LISTENING/IDLE phase model — the fix for the
///     "in a conversation while paused/idle" bug. Proven through the REAL CaptureManager
///     (door-free) + the pure `CaptureLiveStatus.phase` derivation.
///  2. Live transcript truncation + coarse level stepping for the small surfaces.
///  3. The interactive-button wiring: the SAME broker→manager mapping RootView installs
///     for the two App Intents (End Current, Pause/Resume).
@MainActor
final class CaptureLiveActivityTests: ProcessGlobalStateTestCase {

    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    private func makeManager(_ dir: URL,
                             finalize: (@Sendable (String, ConversationMeta?) async throws -> Void)? = nil)
        -> (CaptureManager, TestSource) {
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src, finalize: finalize)
        mgr.setSilenceGap(9_999)   // never auto-segment — phases/splits must be ours
        return (mgr, src)
    }

    private func tempDir(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-la-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: 1. phase model (the bug fix)

    /// Pure derivation: armed session + recent voice ⇒ recording-active; paused ⇒ paused;
    /// armed but silent past the window ⇒ idle (LISTENING), NOT recording. This is the
    /// exact logic that stops the "live 30-min conversation while paused/idle" claim.
    func testPhaseDerivationDistinguishesActivePausedIdle() {
        let w = CaptureLiveStatus.activeVoiceWindow
        // Recording-active: recent voice, not paused.
        XCTAssertEqual(CaptureLiveStatus.phase(hasActiveSession: true, isPaused: false,
                                               lastVoicedAt: 100, now: 100 + w - 1), .recordingActive)
        // Paused: an open session but paused → never "recording", regardless of voice.
        XCTAssertEqual(CaptureLiveStatus.phase(hasActiveSession: true, isPaused: true,
                                               lastVoicedAt: 100, now: 100), .paused)
        // Idle (LISTENING): armed session but voice is older than the window → NOT recording.
        XCTAssertEqual(CaptureLiveStatus.phase(hasActiveSession: true, isPaused: false,
                                               lastVoicedAt: 100, now: 100 + w + 1), .idle)
        // Idle: armed session but no voice at all yet.
        XCTAssertEqual(CaptureLiveStatus.phase(hasActiveSession: true, isPaused: false,
                                               lastVoicedAt: nil, now: 100), .idle)
        // Idle: no session at all.
        XCTAssertEqual(CaptureLiveStatus.phase(hasActiveSession: false, isPaused: false,
                                               lastVoicedAt: 100, now: 100), .idle)
    }

    /// Through the REAL manager: recording voice ⇒ recording-active; a silence longer than
    /// the active-voice window ⇒ idle (the timer would freeze); pause ⇒ paused.
    func testManagerPhaseReflectsRealCaptureActivity() async throws {
        let dir = try tempDir("phase")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (mgr, src) = makeManager(dir)

        src.onState?(.streaming)
        RealOmiFrames.openSession(src.onFrame)   // speech onset opens the conversation
        try await waitUntil { mgr.active != nil }

        // No voice through the live path yet → LISTENING (idle), NOT a live conversation.
        XCTAssertEqual(mgr.liveActivityPhase(), .idle, "armed but no voice ⇒ listening, not recording")

        // Voiced frames arrive → RECORDING-ACTIVE.
        for _ in 0..<40 { src.onFrame?(RealOmiFrames.voiced()) }
        let voicedAt = try XCTUnwrap(mgr.lastVoicedInstant(), "a voiced frame stamps the instant")
        XCTAssertEqual(mgr.liveActivityPhase(now: voicedAt + 1), .recordingActive)

        // Extended silence past the window while STILL armed → back to LISTENING (idle):
        // the timer must NOT keep running (the reported bug).
        let past = voicedAt + CaptureLiveStatus.activeVoiceWindow + 1
        XCTAssertEqual(mgr.liveActivityPhase(now: past), .idle,
                       "an extended silence while armed reads as listening, not a live conversation")

        // Pause → PAUSED regardless of recent voice.
        mgr.pause()
        XCTAssertEqual(mgr.liveActivityPhase(now: voicedAt + 1), .paused)
        // Resume → LISTENING until voice resumes (not immediately "recording").
        mgr.resume()
        XCTAssertEqual(mgr.liveActivityPhase(now: past), .idle)
    }

    // MARK: 2. transcript truncation + coarse level

    func testTranscriptTruncationKeepsTailAndCollapsesWhitespace() {
        XCTAssertEqual(CaptureLiveStatus.truncatedTranscript("", maxChars: 20), "")
        XCTAssertEqual(CaptureLiveStatus.truncatedTranscript("hello   world\n", maxChars: 20), "hello world")
        let long = "the quick brown fox jumps over the lazy dog again and again"
        let out = CaptureLiveStatus.truncatedTranscript(long, maxChars: 20)
        XCTAssertLessThanOrEqual(out.count, 20)
        XCTAssertTrue(out.hasPrefix("…"), "clipped transcript is ellipsis-prefixed")
        XCTAssertTrue(long.hasSuffix(String(out.dropFirst())), "the TAIL (newest words) is kept")
    }

    func testCoarseLevelStepIsBucketedAndClamped() {
        XCTAssertEqual(CaptureLiveStatus.levelStep(fromLevel: 0.0), 0)
        XCTAssertEqual(CaptureLiveStatus.levelStep(fromLevel: 1.0), CaptureLiveStatus.levelSteps)
        XCTAssertEqual(CaptureLiveStatus.levelStep(fromLevel: 2.0), CaptureLiveStatus.levelSteps, "clamped")
        XCTAssertEqual(CaptureLiveStatus.levelStep(fromLevel: -1.0), 0, "clamped")
        // Louder audio ⇒ at least as many lit bars as quieter audio.
        XCTAssertGreaterThanOrEqual(CaptureLiveStatus.levelStep(fromLevel: 0.9),
                                    CaptureLiveStatus.levelStep(fromLevel: 0.2))
    }

    // MARK: 2b. indicator style — phase → anvil tint + pulse (the state-colored anvil)

    /// The state→color/pulse rule that drives the anvil brand mark on EVERY Live Activity
    /// surface. Pure + UI-free (no SwiftUI): recording ⇒ red + pulse; paused ⇒ blue, steady;
    /// idle ⇒ neutral, steady. This is the unit-testable core of Task 1.
    func testIndicatorTintAndPulsePerPhase() {
        // recording-active: RED, and the ONLY phase that pulses.
        XCTAssertEqual(CaptureActivityPhase.recordingActive.indicatorTint, .recording)
        XCTAssertTrue(CaptureActivityPhase.recordingActive.indicatorPulses)

        // paused: BLUE, steady (no pulse).
        XCTAssertEqual(CaptureActivityPhase.paused.indicatorTint, .paused)
        XCTAssertFalse(CaptureActivityPhase.paused.indicatorPulses)

        // idle / listening: NEUTRAL, steady (no pulse).
        XCTAssertEqual(CaptureActivityPhase.idle.indicatorTint, .neutral)
        XCTAssertFalse(CaptureActivityPhase.idle.indicatorPulses)

        // Only recording pulses — the property that keeps the animation battery-gated.
        let pulsing = [CaptureActivityPhase.recordingActive, .paused, .idle].filter { $0.indicatorPulses }
        XCTAssertEqual(pulsing, [.recordingActive])
    }

    // MARK: 3. interactive-button wiring (App Intent broker → manager)

    /// The broker handler RootView installs: .endCurrent → endCurrentConversation(),
    /// .togglePause → togglePause(). We install the SAME mapping and drive it via a
    /// broker-shaped action enum, proving the button actions reach the right manager verbs.
    private enum Action { case endCurrent, togglePause }
    private func installHandler(_ mgr: CaptureManager) -> (Action) -> Bool {
        return { action in
            switch action {
            case .endCurrent:  return mgr.endCurrentConversation()
            case .togglePause: mgr.togglePause(); return true
            }
        }
    }

    func testEndCurrentButtonFinalizesAndStartsNew() async throws {
        let dir = try tempDir("end")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = FinalizeRecorder()
        let (mgr, src) = makeManager(dir, finalize: { id, _ in rec.record(id) })
        let perform = installHandler(mgr)

        src.onState?(.streaming)
        RealOmiFrames.openSession(src.onFrame)   // speech onset opens the conversation
        try await waitUntil { mgr.active != nil }
        let first = try XCTUnwrap(mgr.active).captureId
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) { src.onFrame?(RealOmiFrames.voiced()) }
        try XCTUnwrap(mgr.active).flushAndWait()

        XCTAssertTrue(perform(.endCurrent), "End Current acts while a conversation is open")
        try await waitUntil { mgr.active != nil && mgr.active?.captureId != first }
        let second = try XCTUnwrap(mgr.active).captureId
        XCTAssertNotEqual(first, second, "End Current begins a NEW conversation")

        ackAllSegments(dir, first)
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [first], "the ended conversation is finalized once, by its id")
    }

    func testEndCurrentButtonIsNoOpWithNoActiveCapture() async throws {
        let dir = try tempDir("end-noop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = FinalizeRecorder()
        let (mgr, _) = makeManager(dir, finalize: { id, _ in rec.record(id) })
        let perform = installHandler(mgr)

        XCTAssertFalse(perform(.endCurrent), "End Current is a no-op when nothing is recording")
        XCTAssertNil(mgr.active)
        XCTAssertEqual(rec.calls, [])
    }

    func testPauseResumeButtonToggles() async throws {
        let dir = try tempDir("pause")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (mgr, src) = makeManager(dir)
        let perform = installHandler(mgr)

        src.onState?(.streaming)
        RealOmiFrames.openSession(src.onFrame)   // speech onset opens the conversation
        try await waitUntil { mgr.active != nil }
        XCTAssertFalse(mgr.isPaused)

        XCTAssertTrue(perform(.togglePause))
        XCTAssertTrue(mgr.isPaused, "Pause button pauses capture")
        XCTAssertEqual(mgr.liveActivityPhase(), .paused)

        XCTAssertTrue(perform(.togglePause))
        XCTAssertFalse(mgr.isPaused, "Resume button resumes capture")
    }

    // MARK: shared helpers

    final class FinalizeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ id: String) { lock.lock(); _calls.append(id); lock.unlock() }
    }

    private func ackAllSegments(_ dir: URL, _ captureId: String) {
        let cdir = dir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "opus" {
            try? Data().write(to: f.deletingPathExtension().appendingPathExtension("ack"), options: [.atomic])
        }
    }
}
