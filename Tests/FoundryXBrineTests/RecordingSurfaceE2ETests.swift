import XCTest
import Foundation
import AVFoundation
@testable import FoundryXKit

/// E2E over the LIVE RECORDING SURFACE the user actually touches — the gap the
/// logic-only suite missed (2026-07-23). The perf/hang wave kept every data-layer
/// test green while the surface regressed: "Listening" showed no transcript, the
/// elapsed timer was absent/desynced, and tapping the tile opened nothing. These
/// assert the PRESENTATION invariants that drive the hero tile, the elapsed clock,
/// the live transcript, and the RecordingScreen cover binding — exactly what breaks
/// when the display wiring regresses while the WAL/finalize layer stays correct.
@MainActor
final class RecordingSurfaceE2ETests: XCTestCase {

    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    final class FakeLiveTranscriber: LiveTranscribing, @unchecked Sendable {
        let transcript: AsyncStream<LiveTranscript>
        private let cont: AsyncStream<LiveTranscript>.Continuation
        init() { var c: AsyncStream<LiveTranscript>.Continuation!; transcript = AsyncStream { c = $0 }; cont = c }
        func start() async throws {}
        func append(_ pcm: AVAudioPCMBuffer) {}
        func finish() async -> String { cont.finish(); return "" }
        func emit(_ t: LiveTranscript) { cont.yield(t) }
    }
    final class Factory: @unchecked Sendable {
        private let lock = NSLock(); private var made: [FakeLiveTranscriber] = []
        func make() -> LiveTranscribing? { let f = FakeLiveTranscriber(); lock.lock(); made.append(f); lock.unlock(); return f }
        var last: FakeLiveTranscriber? { lock.lock(); defer { lock.unlock() }; return made.last }
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { return XCTFail("waitUntil timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The EXACT predicate CaptureScreen's RecordingScreen `.fullScreenCover` uses
    /// (CaptureScreen.swift ~259). A regression in the presentation gate surfaces here.
    private func recordingPageIsPresentable(_ m: CaptureManager) -> Bool {
        (m.isRecordingMic || m.active != nil) && !m.recordingScreenMinimized
    }

    private func makeManager(_ dir: URL, _ src: TestSource, _ factory: Factory) -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        return CaptureManager(target: target, baseDir: dir, source: src, finalize: { _, _ in },
                              liveTranscriber: { factory.make() })
    }

    func testTalkingOpensARenderableTappableTranscribingConversation() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-rec-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = TestSource()
        let factory = Factory()
        let mgr = makeManager(dir, src, factory)
        mgr.setSilenceGap(120)   // keep the conversation open — this is the "actively talking" state

        // 1. Omi connects and the user talks → a conversation OPENS (not stuck on "Listening").
        src.onState?(.streaming)
        _ = RealOmiFrames.openSession(src.onFrame)
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) { src.onFrame?(RealOmiFrames.voiced()) }
        try await waitUntil { mgr.active != nil }
        XCTAssertNotNil(mgr.active, "talking must OPEN a conversation, not sit on 'Listening' forever")

        // 2. The hero tile is the tappable, timer-showing recorder — not an inert 'Listening'.
        let slot = LiveHeroPresentation.slot(isShowingCapture: true,
                                             hasActiveSession: mgr.active != nil,
                                             isRecordingMic: mgr.isRecordingMic,
                                             isPaused: mgr.isPaused)
        guard case let .liveTile(tile) = slot else { return XCTFail("hero slot is not the live tile") }
        XCTAssertTrue(tile.hasRecorder, "the live tile must be tappable-through to the recorder")
        XCTAssertTrue(tile.showsElapsed, "the live tile must show the elapsed timer")

        // 3. The elapsed clock exists — the in-app readout AND the live tile read this SAME
        //    session clock, so there is one source of truth (no tile-vs-app timer desync).
        XCTAssertNotNil(mgr.recordingClock, "an active session must have a running elapsed clock")

        // 4. Tapping the tile (restoreRecordingScreen) makes the recording page presentable.
        mgr.restoreRecordingScreen()
        XCTAssertTrue(recordingPageIsPresentable(mgr),
                      "tapping the live tile must open the full recording page")

        // 5. Live transcription flows onto the surface the RecordingScreen renders.
        try await waitUntil { factory.last != nil }
        factory.last?.emit(LiveTranscript(finalizedText: "hello world", volatileTail: ""))
        try await waitUntil { !mgr.liveTranscript.isEmpty }
        XCTAssertFalse(mgr.liveTranscript.isEmpty, "the live transcript must render while recording")
    }

    /// Minimizing (chat under the cover) then tapping the tile again must re-present the
    /// recorder — the restore path the user hits when returning to a recording in progress.
    func testMinimizeThenRestoreRepresentsTheRecorder() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-rec-e2e-min-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = TestSource()
        let factory = Factory()
        let mgr = makeManager(dir, src, factory)
        mgr.setSilenceGap(120)

        src.onState?(.streaming)
        _ = RealOmiFrames.openSession(src.onFrame)
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) { src.onFrame?(RealOmiFrames.voiced()) }
        try await waitUntil { mgr.active != nil }

        XCTAssertTrue(recordingPageIsPresentable(mgr), "an open conversation presents the recorder")
        mgr.minimizeRecordingScreen()
        XCTAssertFalse(recordingPageIsPresentable(mgr), "minimize hides the cover to reveal chat")
        mgr.restoreRecordingScreen()
        XCTAssertTrue(recordingPageIsPresentable(mgr), "tapping the tile restores the recorder")
    }
}
