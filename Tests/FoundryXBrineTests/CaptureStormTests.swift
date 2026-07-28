import XCTest
import Foundation
@testable import FoundryXKit

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
final class CaptureStormTests: SignedOutListeningCaptureTestCase {

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
        private let queue = DispatchQueue(label: "foundryx.upload-recorder")
        private var _attempts = 0
        private var _inFlight = 0
        private var _maxInFlight = 0
        var error: Error?
        var attempts: Int { queue.sync { _attempts } }
        var maxInFlight: Int { queue.sync { _maxInFlight } }
        func record() throws {
            let e = queue.sync { () -> Error? in
                _attempts += 1
                return error
            }
            if let e { throw e }
        }
        func recordSlowSuccess() async throws {
            queue.sync {
                _attempts += 1
                _inFlight += 1
                _maxInFlight = max(_maxInFlight, _inFlight)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
            queue.sync { _inFlight -= 1 }
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
        try await waitUntil { mgr.isListeningForSpeechForTests }
        RealOmiFrames.openSession(src.onFrame)   // speech onset opens the conversation
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

    func testNeverAbandonForSizeAgeOrTransientFailures() {
        // NEVER LOSE AUDIO: with no permanent poison, a capture is NEVER retired —
        // however large, old, or long-failing it is. It just keeps draining.
        XCTAssertFalse(CaptureManager.shouldAbandonCapture(permanentPoison: false))
        // Only genuine, segment-level PERMANENT poison retires a capture.
        XCTAssertTrue(CaptureManager.shouldAbandonCapture(permanentPoison: true))
    }

    func testPermanentVsTransientRejectionClassifier() {
        // Permanent, non-auth 4xx ⇒ poison (retrying can never succeed).
        for s in [400, 403, 404, 409, 413, 422] {
            XCTAssertTrue(CaptureWAL.isPermanentRejection(s), "HTTP \(s) is permanent")
        }
        // Transient (or handled-elsewhere) ⇒ keep retrying — never discard audio.
        XCTAssertFalse(CaptureWAL.isPermanentRejection(401), "401 is re-auth, handled separately")
        XCTAssertFalse(CaptureWAL.isPermanentRejection(408), "408 request-timeout is transient")
        XCTAssertFalse(CaptureWAL.isPermanentRejection(429), "429 rate-limit is transient")
        for s in [500, 502, 503, 504] {
            XCTAssertFalse(CaptureWAL.isPermanentRejection(s), "HTTP \(s) is transient")
        }
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
        await mgr.hydration?.value   // async hydration (startup-hang fix): discover on-disk backlog before asserting/draining
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
        await mgr.hydration?.value   // async hydration (startup-hang fix): discover on-disk backlog before asserting/draining

        try await startCaptureWithPendingSegment(mgr, src)

        await mgr.drainPending()
        let afterFirst = rec.attempts
        XCTAssertGreaterThanOrEqual(afterFirst, 1, "the failed backlog is attempted")
        XCTAssertLessThanOrEqual(afterFirst, CaptureWAL.maxConcurrentSegmentUploads,
                                 "one failed drain only spends the bounded in-flight batch")
        XCTAssertFalse(mgr.authExpired, "a transient failure does NOT trip the expired-token state")

        // Immediately drain again: the capture is in backoff (next-eligible is seconds
        // out), so it is NOT re-attempted — proving there is no tight retry loop.
        await mgr.drainPending()
        await mgr.drainPending()
        XCTAssertEqual(rec.attempts, afterFirst, "a backing-off capture is skipped, not hammered")
    }

    // MARK: successful backlog → continuous bounded drain

    func testReachableDoorContinuouslyDrainsLargeBacklogWithBoundedSegmentConcurrency() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-20260708-081100-throughput"
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        let backlog = CaptureWAL.maxSegmentsPerSync * 3
        for seq in 0..<backlog {
            try Data([1, 2, 3, 4]).write(
                to: cdir.appendingPathComponent(String(format: "seg-%012llu.opus", seq)))
        }

        let rec = UploadRecorder()
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 uploadSegment: { _, _, _ in try await rec.recordSlowSuccess() })
        await mgr.hydration?.value   // async hydration (startup-hang fix): discover on-disk backlog before asserting/draining

        XCTAssertEqual(mgr.captures.first?.snapshot().pendingSegments, backlog, "test starts with a real backlog")

        await mgr.drainPending()

        XCTAssertEqual(rec.attempts, backlog, "one drain invocation keeps going until the reachable backlog is empty")
        XCTAssertGreaterThan(rec.maxInFlight, 1, "segments upload concurrently instead of one at a time")
        XCTAssertLessThanOrEqual(rec.maxInFlight, CaptureWAL.maxConcurrentSegmentUploads,
                                 "segment concurrency stays inside the bounded upload limit")
        XCTAssertEqual(mgr.captures.first?.snapshot().pendingSegments, 0,
                       "all saved phone segments are ACK'd without waiting for later timer ticks")
    }

    // MARK: large/old/failing capture → KEEPS DRAINING (never abandoned)

    func testStuckOldLargeCaptureIsNeverAbandoned() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Pre-seed a 6-months-old backlog capture with several pending (un-ACK'd) segments.
        let oldId = "omi-20260101-120000-deadbeef"
        let cdir = dir.appendingPathComponent(oldId, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        for seq in 0..<5 {
            try Data([1, 2, 3, 4]).write(
                to: cdir.appendingPathComponent(String(format: "seg-%012llu.opus", seq)))
        }

        let rec = UploadRecorder()
        rec.error = DoorError.http(503)                  // door transiently down — keeps failing
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 uploadSegment: { _, _, _ in try rec.record() })
        await mgr.hydration?.value   // async hydration (startup-hang fix): discover on-disk backlog before asserting/draining

        // Many drains while the door is down: the ancient, repeatedly-failing capture is
        // NEVER abandoned — its audio must not be lost; it simply backs off and waits.
        for _ in 0..<50 { await mgr.drainPending() }
        let marker = cdir.appendingPathComponent(".abandoned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "a large/old/long-failing capture is NEVER abandoned (never lose audio)")
        XCTAssertFalse(mgr.authExpired, "a transient outage does not trip the expired-token state")
        // The audio is all still on disk (nothing discarded).
        let opus = (try FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "opus" }.count
        XCTAssertEqual(opus, 5, "every segment is retained on disk while the capture waits to drain")
    }

    // MARK: permanent poison → retired (terminal), but audio is KEPT

    func testPermanentRejectionRetiresCaptureButKeepsAudio() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rec = UploadRecorder()
        rec.error = DoorError.http(422)                  // permanent, non-auth 4xx ⇒ poison
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 uploadSegment: { _, _, _ in try rec.record() })
        await mgr.hydration?.value   // async hydration (startup-hang fix): discover on-disk backlog before asserting/draining

        try await startCaptureWithPendingSegment(mgr, src)
        let id = try XCTUnwrap(mgr.active).captureId
        let cdir = dir.appendingPathComponent(id, isDirectory: true)

        await mgr.drainPending()
        let attemptsAfter = rec.attempts
        XCTAssertGreaterThanOrEqual(attemptsAfter, 1, "the segment was attempted")

        // Retired with a durable marker carrying the reason — NOT a silent drop.
        let marker = cdir.appendingPathComponent(".abandoned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "a permanently-rejected capture is retired with a durable marker")
        // The audio is KEPT — poison retires the retry intent, never deletes the bytes.
        let opus = (try FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "opus" }.count
        XCTAssertGreaterThan(opus, 0, "audio segments are KEPT on poison — never deleted")

        // Never retried again.
        await mgr.drainPending()
        await mgr.drainPending()
        XCTAssertEqual(rec.attempts, attemptsAfter, "a retired capture is no longer uploaded")
    }

    private // Deadline is generous ON PURPOSE. The `flake` gate runs this suite a second time
    // under deliberately induced CPU load, where a capture session can be starved for
    // seconds. A 3s bound there tested the SCHEDULER, not the behaviour — it made the
    // flake gate fail ~70% of the time on a clean main, which trains everyone to ignore
    // the one gate whose job is catching real flakiness (track 20260726T0030).
    // The assertion is unchanged: the condition must still become true.
    func waitUntil(timeout: TimeInterval = 300, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
