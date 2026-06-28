import XCTest
import Foundation
import FoundryXKit

/// Door-free state-machine tests for the DURABLE pause/listen intent
/// (track 20260628T1657). Capture's pause flag must survive a full app restart: a
/// user who paused the Omi and relaunched must come back paused — not silently
/// auto-capturing on reconnect. A relaunch is simulated by constructing a FRESH
/// CaptureManager (the same UserDefaults-backed store a real relaunch reads).
///
/// Mirrors `CaptureAmbientTests`: a controllable `TestSource` whose `.streaming`
/// state stands in for an Omi (re)connect, asserting on-disk WAL segments.
@MainActor
final class CapturePersistenceTests: XCTestCase {

    /// A source the test drives directly (start/stop are no-ops; the test invokes
    /// the onFrame/onState closures CaptureManager installs).
    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    private let desiredStateKey = "foundryx.capture.omi-desired-state"

    override func setUp() {
        super.setUp()
        // Isolate from any leaked global state (CaptureSettings uses UserDefaults.standard).
        UserDefaults.standard.removeObject(forKey: desiredStateKey)
    }

    override func tearDown() {
        // Never leave a non-default intent behind to pollute other tests' managers.
        UserDefaults.standard.removeObject(forKey: desiredStateKey)
        super.tearDown()
    }

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
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }

        mgr.pause()
        XCTAssertEqual(CaptureSettings.omiCaptureDesiredState, .paused)
        // Durable, not just in-memory: an independent raw read sees it.
        XCTAssertEqual(UserDefaults.standard.string(forKey: desiredStateKey), "paused")

        mgr.resume()
        XCTAssertEqual(CaptureSettings.omiCaptureDesiredState, .listening)
        XCTAssertEqual(UserDefaults.standard.string(forKey: desiredStateKey), "listening")
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
        try await waitUntil { mgr.active != nil }
        let wal = try XCTUnwrap(mgr.active)
        frames(src, 80, 1); wal.flushAndWait()
        XCTAssertGreaterThan(wal.snapshot().totalSegments, 0,
                             "a listening reconnect resumes capture automatically")
    }

    // AC4 — first-ever launch (no stored value) defaults to listening + captures.
    func testFirstLaunchDefaultsToListening() async throws {
        UserDefaults.standard.removeObject(forKey: desiredStateKey)   // never-set
        XCTAssertEqual(CaptureSettings.omiCaptureDesiredState, .listening)
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = makeManager(src, dir: dir)

        XCTAssertFalse(mgr.isPaused, "first launch defaults to listening (today's behavior)")

        src.onState?(.streaming)
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
