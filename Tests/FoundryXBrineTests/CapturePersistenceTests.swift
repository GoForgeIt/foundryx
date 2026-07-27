import XCTest
import Foundation
@testable import FoundryXKit   // isListeningForSpeechForTests (the speech-gated listening seam)

/// Door-free state-machine tests for the DURABLE pause/listen intent
/// (track 20260628T1657). Capture's pause flag must survive a full app restart: a
/// user who paused the Omi and relaunched must come back paused — not silently
/// auto-capturing on reconnect. A relaunch is simulated by constructing a FRESH
    /// CaptureManager (the same account-scoped preference store a real relaunch reads).
///
/// Mirrors `CaptureAmbientTests`: a controllable `TestSource` whose `.streaming`
/// state stands in for an Omi (re)connect, asserting on-disk WAL segments.
@MainActor
final class CapturePersistenceTests: ProcessGlobalStateTestCase {

    /// A source the test drives directly (start/stop are no-ops; the test invokes
    /// the onFrame/onState closures CaptureManager installs).
    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    // Isolation from the process-global capture preference cache is inherited from
    // `ProcessGlobalStateTestCase`: it hands each test a private account owner and restores
    // process state afterwards.
    private let desiredStateKey = "foundryx.capture.omi-desired-state"

    private func makeManager(_ src: TestSource, dir: URL) -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        return CaptureManager(target: target, baseDir: dir, source: src)
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func frames(_ src: TestSource, _ n: Int, _ b: UInt8) {
        for _ in 0..<n { src.onFrame?(Data(repeating: b, count: 40)) }
    }

    // AC1 — toggling pause/resume writes the durable intent (independently readable).
    func testTogglePersistsDesiredState() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = makeManager(src, dir: dir)

        mgr.pause()
        XCTAssertEqual(CaptureSettings.omiCaptureDesiredState, .paused)
        XCTAssertNil(
            UserDefaults.standard.object(forKey: desiredStateKey),
            "an account choice must not be written to the unscoped phone domain")

        mgr.resume()
        XCTAssertEqual(CaptureSettings.omiCaptureDesiredState, .listening)
        XCTAssertNil(UserDefaults.standard.object(forKey: desiredStateKey))
    }

    // AC2 — a persisted `paused` intent survives a relaunch: a fresh manager starts
    // paused and a reconnect records NO audio until the user resumes.
    func testPausedSurvivesRelaunchNoAutoCapture() async throws {
        CaptureSettings.omiCaptureDesiredState = .paused   // the pre-restart choice
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = makeManager(src, dir: dir)               // the "relaunch"

        XCTAssertTrue(mgr.isPaused, "a relaunch with a paused intent must start paused")

        // Omi reconnects → a session begins, but stays paused (no frames captured).
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let wal = try XCTUnwrap(mgr.active)
        XCTAssertTrue(mgr.isPaused, "reconnect must NOT silently start capturing")
        XCTAssertFalse(mgr.isCapturing)

        frames(src, 80, 1); wal.flushAndWait()
        XCTAssertEqual(wal.snapshot().totalSegments, 0,
                       "a paused reconnect must write no audio to the WAL")
    }

    // AC5 — resuming after a paused relaunch records into the already-connected session.
    func testResumeAfterPausedRelaunchStartsCapturing() async throws {
        CaptureSettings.omiCaptureDesiredState = .paused
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = makeManager(src, dir: dir)
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let wal = try XCTUnwrap(mgr.active)
        frames(src, 80, 1); wal.flushAndWait()
        XCTAssertEqual(wal.snapshot().totalSegments, 0)

        mgr.resume()
        frames(src, 80, 2); wal.flushAndWait()
        XCTAssertGreaterThan(wal.snapshot().totalSegments, 0,
                             "after resume, frames are recorded into the open session")
    }

    // AC3 — a persisted `listening` intent survives a relaunch: a fresh manager is not
    // paused and a reconnect resumes capture automatically.
    func testListeningSurvivesRelaunchResumes() async throws {
        CaptureSettings.omiCaptureDesiredState = .listening
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = makeManager(src, dir: dir)

        XCTAssertFalse(mgr.isPaused, "a relaunch with a listening intent must not be paused")

        src.onState?(.streaming)
        RealOmiFrames.openSession(src.onFrame)   // speech onset opens the conversation
        try await waitUntil { mgr.active != nil }
        let wal = try XCTUnwrap(mgr.active)
        frames(src, 80, 1); wal.flushAndWait()
        XCTAssertGreaterThan(wal.snapshot().totalSegments, 0,
                             "a listening reconnect resumes capture on the next speech")
    }

    // An account that explicitly chose LISTENING restores that choice.
    // Speech-gated: streaming ARMS a listening window with NO conversation open; a real
    // speech onset opens the session and then ambient frames record.
    func testExplicitListeningChoiceArmsCapture() async throws {
        XCTAssertEqual(CaptureSettings.omiCaptureDesiredState, .listening)
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = makeManager(src, dir: dir)

        XCTAssertFalse(
            mgr.isPaused,
            "the account's explicit listening choice restores as not paused")

        // Streaming with no one speaking → LISTENING: armed, metering, NO conversation.
        src.onState?(.streaming)
        try await waitUntil { mgr.isListeningForSpeechForTests }
        XCTAssertNil(mgr.active, "listening means armed with no conversation until voice is heard")

        // Real voice trips the speech-onset gate → the session opens and frames record.
        RealOmiFrames.openSession(src.onFrame)
        try await waitUntil { mgr.active != nil }
        let wal = try XCTUnwrap(mgr.active)
        frames(src, 80, 1); wal.flushAndWait()
        XCTAssertGreaterThan(wal.snapshot().totalSegments, 0)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
