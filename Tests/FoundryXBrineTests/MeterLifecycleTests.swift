import XCTest
import Foundation
@testable import FoundryXKit

/// CaptureManager-level tests for the SESSION-AWARE meter lifecycle (track 20260717T0630,
/// Bug 2). The live audio meter (`meter.levels`) is published only by the 12 Hz
/// `meterTimer`, which used to be started by `CaptureScreen.onAppear` and stopped by its
/// `onDisappear`. Presenting the full-screen RecordingScreen as a `fullScreenCover` fires
/// the presenting CaptureScreen's `onDisappear` — so an unconditional stop there flattened
/// the recording ring / pill ring / Live Activity level the instant recording began (every
/// phone-mic recording read as "nothing's happening").
///
/// The fix moves the decision into the manager (testable): a live capture is ALWAYS
/// metered (`beginSession` / `resumeRecording` start it); `captureSurfaceDidDisappear`
/// stops it ONLY when idle. These prove that state machine end-to-end through the real
/// capture lifecycle, door-free, on the same controllable-source seams the session-clock
/// tests use.
@MainActor
final class MeterLifecycleTests: XCTestCase {

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
            .appendingPathComponent("foundryx-meterlifecycle-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: (a) beginSession starts the meter

    func testBeginSessionStartsMeter() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir, source: src)

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        XCTAssertTrue(mgr.meterIsRunningForTests,
                      "a live ambient session must be metered — beginSession starts the meter")
    }

    // MARK: (b) surface disappear during a LIVE session keeps the meter running (the bug)

    func testCaptureSurfaceDisappearDuringLiveSessionKeepsMeterRunning() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir, source: src)
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        XCTAssertTrue(mgr.meterIsRunningForTests)

        // Presenting the full-screen RecordingScreen fires the capture surface's
        // onDisappear. The meter MUST keep running (the flat-ring regression).
        mgr.captureSurfaceDidDisappear()
        XCTAssertTrue(mgr.meterIsRunningForTests,
                      "captureSurfaceDidDisappear during a live session must NOT stop the meter")
    }

    // MARK: (c) surface disappear when idle stops the meter

    func testCaptureSurfaceDisappearWhenIdleStopsMeter() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir, source: src)
        mgr.startMeter()   // the capture surface appeared (no session yet)
        XCTAssertTrue(mgr.meterIsRunningForTests)
        XCTAssertNil(mgr.active)
        XCTAssertFalse(mgr.isRecordingMic)

        mgr.captureSurfaceDidDisappear()
        XCTAssertFalse(mgr.meterIsRunningForTests,
                       "with no live session the meter stops when the capture surface disappears")
    }

    // MARK: (d) phone-mic path: running while live, stopped once idle again

    func testPhoneMicMeterRunsThenStopsAfterStopAndSurfaceGone() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let omi = TestSource(); let mic = TestSource()
        let mgr = await makeManager(dir, source: omi, micSource: mic)

        mgr.startMicRecording()
        mic.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        XCTAssertTrue(mgr.isRecordingMic)
        XCTAssertTrue(mgr.meterIsRunningForTests, "a live phone-mic session is metered")

        // Surface disappears mid-recording (cover presents) → still metered.
        mgr.captureSurfaceDidDisappear()
        XCTAssertTrue(mgr.meterIsRunningForTests,
                      "phone-mic recording keeps metering when the capture surface disappears")

        // Stop the mic → session ends → now the surface disappearing stops the meter.
        mic.onState?(.stopped)
        try await waitUntil { mgr.active == nil && !mgr.isRecordingMic }
        mgr.captureSurfaceDidDisappear()
        XCTAssertFalse(mgr.meterIsRunningForTests,
                       "once the mic stops and the surface is gone, the meter stops (idle)")
    }

    // MARK: (e) session ends to idle WHILE the surface is away → meter stops by itself
    // (adversarial review M1: without the end-boundary stop, nothing ever fires
    // captureSurfaceDidDisappear again and the 12 Hz timer runs forever.)

    func testMicStopWhileSurfaceAwayStopsMeterWithoutAnotherDisappear() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let omi = TestSource(); let mic = TestSource()
        let mgr = await makeManager(dir, source: omi, micSource: mic)

        mgr.startMicRecording()
        mic.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        // The user minimized and wandered off the capture tab: the surface disappeared
        // while the session was live (meter correctly kept running)...
        mgr.captureSurfaceDidDisappear()
        XCTAssertTrue(mgr.meterIsRunningForTests)

        // ...then the session ends to idle out there (interruption / stop). No further
        // surface callback will ever come — the end boundary itself must stop the meter.
        mic.onState?(.stopped)
        try await waitUntil { mgr.active == nil && !mgr.isRecordingMic }
        XCTAssertFalse(mgr.meterIsRunningForTests,
                       "a session ending to idle stops the meter WITHOUT another surface disappear")
    }

    func testReconnectGraceExpiryStopsMeter() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(dir, source: src)
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        mgr.captureSurfaceDidDisappear()   // off the capture surface, session live
        XCTAssertTrue(mgr.meterIsRunningForTests)

        // Omi drops → held for reconnect-grace; the grace expires with no reconnect.
        src.onState?(.stopped)
        try await waitUntil { mgr.isAwaitingReconnect }   // the hold is set asynchronously
        mgr.resolveReconnectGrace(now: Date().timeIntervalSinceReferenceDate
                                        + SilenceSegmenter.defaultSilenceGap + 1)
        XCTAssertNil(mgr.active, "the grace expiry ends the held session")
        XCTAssertFalse(mgr.meterIsRunningForTests,
                       "the grace-expiry end stops the meter (no surface callback will come)")
    }
}
