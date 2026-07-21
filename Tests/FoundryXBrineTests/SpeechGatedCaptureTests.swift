import XCTest
import Foundation
@testable import FoundryXKit

/// End-to-end tests for the SPEECH-GATED ambient capture contract (Nick, 2026-07-21).
///
/// Ambient Omi `.streaming` no longer opens a conversation on its own — it ARMS a
/// listening window (meters the waveform, keeps a short pre-roll) and a conversation
/// opens ONLY after a confirmed speech onset (`SpeechOnsetDetector.defaultFramesToOpen`
/// voiced frames, tolerating brief dips). So silence and one-off noise never mint an
/// empty "Untitled conversation," and a silence gap returns to listening rather than
/// immediately opening a fresh empty card.
///
/// Drives the REAL CaptureManager door-free via a controllable source, mirroring the
/// harness in `CaptureSubstanceGateTests`.
@MainActor
final class SpeechGatedCaptureTests: XCTestCase {

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
            .appendingPathComponent("foundryx-speechgate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeManager(_ dir: URL, _ src: TestSource) async -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let m = CaptureManager(target: target, baseDir: dir, source: src, finalize: { _, _ in })
        await m.hydration?.value
        return m
    }

    /// Any per-capture `card.json` written under the base dir — proof a conversation
    /// card was minted (the thing speech-gating must NOT do on silence/noise).
    private func anyCardOnDisk(_ dir: URL) -> Bool {
        let subdirs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return subdirs.contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("card.json").path)
        }
    }

    /// Count of on-disk capture directories (a minted conversation writes exactly one).
    private func captureDirCount(_ dir: URL) -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return entries.filter { !$0.hasPrefix(".") }.count
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: 1 — connect + silence → LISTENING, never a conversation, no card

    func testStreamingWithoutSpeechStaysListeningAndWritesNoCard() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir, src)

        // The Omi connects → ARM (listen), no conversation.
        src.onState?(.streaming)
        try await waitUntil { mgr.isListeningForSpeechForTests }
        XCTAssertNil(mgr.active, "streaming alone opens no conversation")

        // Only silence for a good while — still listening, nothing recorded.
        for _ in 0..<300 { src.onFrame?(RealOmiFrames.silent()) }
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertNil(mgr.active, "silence never opens a conversation")
        XCTAssertTrue(mgr.isListeningForSpeechForTests, "the Omi is armed and listening")
        XCTAssertTrue(mgr.meterIsRunningForTests, "the 'Listening…' waveform still meters while armed")
        XCTAssertTrue(mgr.captures.isEmpty, "no capture is minted while only silence is heard")
        XCTAssertTrue(mgr.visibleCaptures.isEmpty, "nothing visible in the timeline")
        XCTAssertFalse(anyCardOnDisk(dir), "no card.json is ever written for a silent listening window")
        XCTAssertEqual(captureDirCount(dir), 0, "no capture directory is created")
    }

    // MARK: 2 — a short transient (a cough / door slam) does NOT open a conversation

    func testShortVoicedTransientStaysListening() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir, src)

        src.onState?(.streaming)
        try await waitUntil { mgr.isListeningForSpeechForTests }

        // A handful of voiced frames (below the onset bar) then quiet — a percussive blip.
        XCTAssertLessThan(4, SpeechOnsetDetector.defaultFramesToOpen, "premise: 4 is below the onset bar")
        for _ in 0..<4 { src.onFrame?(RealOmiFrames.cachedVoiced) }
        for _ in 0..<60 { src.onFrame?(RealOmiFrames.silent()) }
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertNil(mgr.active, "a short transient does not open a conversation")
        XCTAssertTrue(mgr.isListeningForSpeechForTests, "still listening after a transient")
        XCTAssertTrue(mgr.captures.isEmpty, "no capture minted by a one-off noise")
        XCTAssertFalse(anyCardOnDisk(dir), "a transient writes no card")
        XCTAssertEqual(captureDirCount(dir), 0, "a transient creates no capture directory")
    }

    // MARK: 3 — sustained voice opens a real, visible conversation

    func testSustainedVoiceOpensAVisibleConversation() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir, src)

        src.onState?(.streaming)
        try await waitUntil { mgr.isListeningForSpeechForTests }

        // ≥15 real voiced frames crosses the onset bar and opens the conversation.
        RealOmiFrames.openSession(src.onFrame)
        try await waitUntil { mgr.active != nil }

        let id = try XCTUnwrap(mgr.active).captureId
        XCTAssertFalse(mgr.isListeningForSpeechForTests, "opening a session leaves the listening state")
        XCTAssertTrue(mgr.captures.contains { $0.captureId == id }, "the opened conversation is a real capture")

        // Keep speaking → the live recording streams; the active capture surfaces in the
        // timeline (a visible capture appears).
        for _ in 0..<60 { src.onFrame?(RealOmiFrames.cachedVoiced) }
        try await waitUntil { mgr.active?.snapshot().streaming == true }
        mgr.rebuildVisibleCapturesForTests()
        XCTAssertTrue(mgr.visibleCaptures.contains { $0.captureId == id },
                      "the live conversation is visible in the timeline")
    }

    // MARK: 4 — a silence-gap close returns to listening; no empty card; next speech mints a fresh one

    func testSilenceGapClosesToListeningThenNextSpeechMintsFreshConversation() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir, src)
        mgr.setSilenceGap(0)   // a silent frame right after enough voice closes the conversation

        // A REAL conversation (clears the upload bar → it is KEPT, not discarded).
        src.onState?(.streaming)
        RealOmiFrames.openSession(src.onFrame)
        try await waitUntil { mgr.active != nil }
        let first = try XCTUnwrap(mgr.active).captureId
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) { src.onFrame?(RealOmiFrames.cachedVoiced) }
        try XCTUnwrap(mgr.active).flushAndWait()

        // Silence gap → the conversation CLOSES and we return to LISTENING (not a new card).
        src.onFrame?(RealOmiFrames.silent())
        try await waitUntil { mgr.active == nil }
        XCTAssertTrue(mgr.isListeningForSpeechForTests,
                      "a silence gap returns to listening, not straight into a new conversation")
        mgr.rebuildVisibleCapturesForTests()
        XCTAssertEqual(mgr.visibleCaptures.map(\.captureId), [first],
                       "no empty 'Untitled' card is left behind — only the real conversation exists")

        // The NEXT sustained voice opens a FRESH, distinct conversation.
        try await Task.sleep(nanoseconds: 20_000_000)
        RealOmiFrames.openSession(src.onFrame)
        try await waitUntil { mgr.active != nil }
        let second = try XCTUnwrap(mgr.active).captureId
        XCTAssertNotEqual(second, first, "the next speech onset mints a fresh, distinct conversation")
    }
}
