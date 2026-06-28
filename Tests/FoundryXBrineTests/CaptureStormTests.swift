import XCTest
import Foundation
import FoundryXKit

/// Regression tests for the capture-upload RETRY STORM that froze the phone: a
/// multi-day backlog of failing segment uploads (expired id_token → the door rejects
/// every POST) was retried in a tight loop at ~100-200 req/min, pegging the device.
///
/// The fixes under test:
///   1. a TRANSIENT upload failure backs off (exponential + jitter) instead of
///      re-firing every drain tick (no tight loop),
///   2. a 401/expired-token rejection STOPS uploads immediately and asks the app to
///      re-authenticate (never keeps firing with a known-expired token),
///   3. a stuck/old/oversized capture is ABANDONED (terminal) so it can't wedge the
///      drain forever.
/// All paths are driven through the manager's REAL drain via an injected per-segment
/// upload — no live door, no network.
@MainActor
final class CaptureStormTests: XCTestCase {

    /// A source the test drives directly (start/stop no-ops).
    private final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    /// Records upload attempts; can be made to throw a chosen error to exercise the
    /// transient-failure and expired-token paths.
    private final class UploadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _attempts = 0
        var error: Error?
        var attempts: Int { lock.lock(); defer { lock.unlock() }; return _attempts }
        func record() throws {
            lock.lock(); _attempts += 1; let e = error; lock.unlock()
            if let e { throw e }
        }
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-storm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func voiceFrame() -> Data { RealOmiFrames.voiced() }

    /// Drive a streaming session with ≥1 flushed (pending, un-ACK'd) segment on disk.
    private func startCaptureWithPendingSegment(_ mgr: CaptureManager, _ src: TestSource) async throws {
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        for _ in 0..<60 { src.onFrame?(voiceFrame()) }
        try XCTUnwrap(mgr.active).flushAndWait()
        try await waitUntil { (mgr.active?.status.pendingSegments ?? 0) > 0 }
    }

    // MARK: pure backoff / abandon decisions

    func testRetryDelayBacksOffExponentiallyWithCapAndJitter() {
        // Deterministic (jitter = 1): doubles from the base, then clamps at the ceiling.
        XCTAssertEqual(CaptureManager.retryDelay(forFailures: 0, jitter: 1), 0)
        XCTAssertEqual(CaptureManager.retryDelay(forFailures: 1, jitter: 1), CaptureManager.retryBaseDelay)
        XCTAssertEqual(CaptureManager.retryDelay(forFailures: 2, jitter: 1), CaptureManager.retryBaseDelay * 2)
        XCTAssertEqual(CaptureManager.retryDelay(forFailures: 3, jitter: 1), CaptureManager.retryBaseDelay * 4)
        // Monotonic non-decreasing and never above the ceiling — never a tight loop.
        var prev = 0.0
        for n in 1...50 {
            let d = CaptureManager.retryDelay(forFailures: n, jitter: 1)
            XCTAssertGreaterThanOrEqual(d, prev)
            XCTAssertLessThanOrEqual(d, CaptureManager.retryMaxDelay)
            prev = d
        }
        XCTAssertEqual(CaptureManager.retryDelay(forFailures: 50, jitter: 1), CaptureManager.retryMaxDelay)
        // Jitter stays within the documented ±25% band.
        let j = CaptureManager.retryDelay(forFailures: 4)
        let nominal = CaptureManager.retryBaseDelay * 8
        XCTAssertGreaterThanOrEqual(j, nominal * 0.75)
        XCTAssertLessThanOrEqual(j, nominal * 1.25)
    }

    func testShouldAbandonDecision() {
        // Healthy capture: never abandoned.
        XCTAssertFalse(CaptureManager.shouldAbandonCapture(failures: 0, ageSeconds: 0, totalSegments: 1))
        // Too many consecutive failures → abandon.
        XCTAssertTrue(CaptureManager.shouldAbandonCapture(
            failures: CaptureManager.maxUploadAttempts, ageSeconds: 0, totalSegments: 1))
        // An old, repeatedly-failing backlog item → abandon (but a fresh one isn't).
        XCTAssertTrue(CaptureManager.shouldAbandonCapture(
            failures: 1, ageSeconds: CaptureManager.maxBacklogAge, totalSegments: 1))
        XCTAssertFalse(CaptureManager.shouldAbandonCapture(
            failures: 0, ageSeconds: CaptureManager.maxBacklogAge, totalSegments: 1))
        // Absurd segment count → abandon regardless.
        XCTAssertTrue(CaptureManager.shouldAbandonCapture(
            failures: 0, ageSeconds: 0, totalSegments: CaptureManager.absurdSegmentCount))
    }

    // MARK: expired token → stop + re-auth (the user-requested behavior)

    func testExpiredTokenStopsRetryingAndRequestsReauth() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rec = UploadRecorder()
        rec.error = DoorError.unauthorized               // the door rejects the expired token
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "expired")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 uploadSegment: { _, _, _ in try rec.record() })
        var reauthRequests = 0
        mgr.onAuthExpired = { reauthRequests += 1 }

        try await startCaptureWithPendingSegment(mgr, src)

        await mgr.drainPending()
        XCTAssertGreaterThanOrEqual(rec.attempts, 1, "the upload was attempted")
        XCTAssertTrue(mgr.authExpired, "a 401 puts the manager into the expired state")
        XCTAssertEqual(reauthRequests, 1, "re-auth is requested exactly once")

        // The storm-stop: with a known-expired token, NO further uploads are fired.
        let after = rec.attempts
        await mgr.drainPending()
        await mgr.drainPending()
        XCTAssertEqual(rec.attempts, after, "uploads stop entirely once the token is known-expired")
        XCTAssertEqual(reauthRequests, 1, "re-auth is not re-requested in a loop")

        // After a fresh token re-arms the pipeline, uploads resume.
        mgr.clearAuthExpired()
        await mgr.drainPending()
        XCTAssertGreaterThan(rec.attempts, after, "uploads resume after re-auth clears the expired state")
    }

    // MARK: transient failure → backoff, not a tight loop

    func testTransientFailureBacksOffInsteadOfTightLooping() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rec = UploadRecorder()
        rec.error = DoorError.http(503)                  // door/Lore transiently down
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 uploadSegment: { _, _, _ in try rec.record() })

        try await startCaptureWithPendingSegment(mgr, src)

        await mgr.drainPending()
        let afterFirst = rec.attempts
        XCTAssertEqual(afterFirst, 1, "one failed attempt (sync stops on the first failure)")
        XCTAssertFalse(mgr.authExpired, "a transient failure does NOT trip the expired-token state")

        // Immediately drain again: the capture is in backoff (next-eligible is seconds
        // out), so it is NOT re-attempted — proving there is no tight retry loop.
        await mgr.drainPending()
        await mgr.drainPending()
        XCTAssertEqual(rec.attempts, afterFirst, "a backing-off capture is skipped, not hammered")
    }

    // MARK: stuck/old capture → abandoned (terminal), can't wedge the queue

    func testStuckOldCaptureIsAbandoned() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Pre-seed a 6-months-old backlog capture with one pending (un-ACK'd) segment.
        let oldId = "omi-20260101-120000-deadbeef"
        let cdir = dir.appendingPathComponent(oldId, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: cdir.appendingPathComponent("seg-000000000000.opus"))

        let rec = UploadRecorder()
        rec.error = DoorError.http(503)                  // keeps failing
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 uploadSegment: { _, _, _ in try rec.record() })

        // Drain #1: one failed attempt records a failure (now failures > 0 + ancient).
        await mgr.drainPending()
        let attemptsAfterFirst = rec.attempts
        XCTAssertGreaterThanOrEqual(attemptsAfterFirst, 1, "the old capture was attempted once")

        // Drain #2: the ancient, now-failed capture is abandoned (terminal) — a durable
        // marker is written and it is no longer attempted.
        await mgr.drainPending()
        let marker = cdir.appendingPathComponent(".abandoned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "a stuck/old capture is abandoned with a durable terminal marker")

        // Drain #3: an abandoned capture is never retried again.
        await mgr.drainPending()
        XCTAssertEqual(rec.attempts, attemptsAfterFirst, "an abandoned capture is no longer uploaded")
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
