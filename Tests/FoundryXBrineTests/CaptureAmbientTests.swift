import XCTest
import Foundation
import FoundryXKit

/// Door-free state-machine test for AMBIENT capture (no door fixture → no
/// kiln-session conflict with a live Foundry.app). Drives a real CaptureManager +
/// CaptureWAL on a temp dir via a controllable source, asserting: capture
/// auto-starts when the source streams (no Record button), pause() stops feeding
/// the WAL, resume() resumes, and disconnect ends the session.
@MainActor
final class CaptureAmbientTests: XCTestCase {

    /// A source the test drives directly (start/stop are no-ops; the test invokes
    /// the onFrame/onState closures CaptureManager installs).
    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    func testAmbientAutoStartPauseResumeLifecycle() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-ambient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = TestSource()
        // Door is never dialed (we assert on-disk WAL segments, not sync).
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src)

        func frames(_ n: Int, _ b: UInt8) { for _ in 0..<n { src.onFrame?(Data(repeating: b, count: 40)) } }

        // 1. AMBIENT auto-start: streaming → a session begins (no manual Record).
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let wal = try XCTUnwrap(mgr.active)

        // frames flow into the WAL while active+unpaused
        frames(60, 1); wal.flushAndWait()
        let afterStart = wal.snapshot().totalSegments
        XCTAssertGreaterThan(afterStart, 0, "ambient capture should WAL frames while streaming")

        // 2. PAUSE stops feeding the WAL (device stays 'connected' — source unchanged)
        mgr.pause()
        XCTAssertTrue(mgr.isPaused)
        frames(60, 2); wal.flushAndWait()
        XCTAssertEqual(wal.snapshot().totalSegments, afterStart, "paused frames must NOT be WAL'd")

        // 3. RESUME feeds again
        mgr.resume()
        XCTAssertFalse(mgr.isPaused)
        frames(60, 3); wal.flushAndWait()
        XCTAssertGreaterThan(wal.snapshot().totalSegments, afterStart, "resumed frames must be WAL'd")

        // 4. DISCONNECT holds the session open for the reconnect grace (a transient BLE
        //    drop must NOT immediately end the conversation). Only once the grace elapses
        //    with no reconnect does the session end.
        src.onState?(.stopped)
        try await waitUntil { mgr.isAwaitingReconnect }
        XCTAssertNotNil(mgr.active, "a bare disconnect holds the conversation open for reconnect grace")
        mgr.resolveReconnectGrace(now: Date().timeIntervalSince1970 + CaptureManager.reconnectGraceWindow + 1)
        try await waitUntil { mgr.active == nil }
        XCTAssertNil(mgr.active)
        XCTAssertEqual(mgr.captures.count, 1, "the ended session stays on the device")
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - Phone-mic × Omi reconnect-grace interaction (the "recording but nothing
// records" bug, 2026-07-12): the mic's .streaming must never be mistaken for an Omi
// reconnect, and a held Omi session must never eat the mic's frames.
extension CaptureAmbientTests {

    func testMicRecordingWhileOmiHeldForReconnectStartsAFreshUnpausedSession() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-mic-grace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let omi = TestSource()
        let mic = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "t")
        let mgr = CaptureManager(target: target, baseDir: dir, source: omi, micSource: mic,
                                 finalize: { _, _ in })

        // Omi conversation starts, streams, then BLE drops → held for reconnect grace.
        omi.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let omiCaptureId = mgr.active?.captureId
        omi.onState?(.stopped)
        try await waitUntil { mgr.isAwaitingReconnect }

        // User hits Record (phone mic). The guard must ALLOW it despite the held
        // session, and the mic's .streaming must start a FRESH UNPAUSED session —
        // never resume the held (paused) Omi capture (the "recording but nothing
        // records" bug: the mic's frames fed the paused Omi pipeline and were eaten).
        await MainActor.run { mgr.startMicRecording() }
        XCTAssertTrue(mgr.isRecordingMic, "record allowed while a session is merely held")
        mic.onState?(.streaming)
        try await waitUntil { !mgr.isAwaitingReconnect && mgr.active?.captureId != omiCaptureId
                              && mgr.active != nil }
        XCTAssertFalse(mgr.isPaused, "a new recording is never born paused")
        let wal = try XCTUnwrap(mgr.active, "a FRESH mic session is open")

        // The mic's frames land in the NEW session's WAL.
        for _ in 0..<60 { mic.onFrame?(Data(repeating: 2, count: 40)) }
        wal.flushAndWait()
        XCTAssertGreaterThan(wal.snapshot().totalSegments, 0, "mic frames are WAL'd, not eaten")
    }
}
