import XCTest
import Foundation
import FoundryXKit

/// Door-free state-machine test for finalize-on-conversation-close (M4). When a
/// silence gap closes a conversation, the CaptureManager must — once the closed
/// capture's segments are durably on the desktop (ACK'd) — POST finalize to the
/// door so the capture advances to the Lore inbox. The DoorClient.finalize call is
/// injected at the boundary (no live Foundry.app door is touched), so we assert it
/// fires exactly once per closed capture, with the right capture id, AFTER the
/// segments are ACK'd — and that a failed finalize stays retryable.
@MainActor
final class CaptureFinalizeTests: XCTestCase {

    /// A source the test drives directly (start/stop no-ops).
    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    /// Records finalize calls; can be made to fail to exercise the retry path.
    final class FinalizeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var shouldFail = false
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ id: String) throws {
            lock.lock(); _calls.append(id); let fail = shouldFail; lock.unlock()
            if fail { throw DoorError.http(502) }
        }
    }

    /// A loud frame (large → level ≈ 1, counts as voice) vs a silent frame (tiny →
    /// level ≈ 0, counts as silence) — drives the segmenter's open/close boundary.
    private func voiceFrame() -> Data { Data(repeating: 0xAB, count: 80) }
    private func silentFrame() -> Data { Data(repeating: 0, count: 3) }

    /// Mark every on-disk segment of a capture as ACK'd (door-free) by writing the
    /// `.ack` sibling the WAL uses to mean "durably on the desktop."
    private func ackAllSegments(_ dir: URL, _ captureId: String) {
        let cdir = dir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "opus" {
            let ack = f.deletingPathExtension().appendingPathExtension("ack")
            try? Data().write(to: ack, options: [.atomic])
        }
    }

    func testSilenceGapCloseFinalizesOncePerCapture() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-finalize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rec = FinalizeRecorder()
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { id in try rec.record(id) })

        // silenceGap 0 → a silence frame right after voice closes the conversation
        // deterministically (the gap is measured from last voice; 0 ≥ 0). No clock
        // injection / real 2-minute wait needed.
        mgr.setSilenceGap(0)

        // Source streams → ambient capture auto-starts.
        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let firstCapture = try XCTUnwrap(mgr.active).captureId

        // Voice opens the conversation; feed enough frames to write ≥1 segment.
        for _ in 0..<60 { src.onFrame?(voiceFrame()) }
        try XCTUnwrap(mgr.active).flushAndWait()

        // A silent frame now exceeds the (zero) gap → conversation closes + the next
        // opens. The closed capture is firstCapture; a new active capture replaces it.
        src.onFrame?(silentFrame())
        try await waitUntil { mgr.active?.captureId != firstCapture }

        // Segments are durably on the desktop (door-free ACK), then retry finalize.
        ackAllSegments(dir, firstCapture)
        await mgr.retryPendingFinalizes()

        XCTAssertEqual(rec.calls, [firstCapture],
                       "closing a conversation finalizes the CLOSED capture exactly once, with its id")

        // Idempotent: a second retry must NOT re-finalize the already-finalized one.
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [firstCapture], "a finalized capture is not finalized again")
    }

    func testFinalizeDeferredUntilSegmentsAreAckd() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-finalize-defer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rec = FinalizeRecorder()
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { id in try rec.record(id) })
        mgr.setSilenceGap(0)

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let firstCapture = try XCTUnwrap(mgr.active).captureId
        for _ in 0..<60 { src.onFrame?(voiceFrame()) }
        try XCTUnwrap(mgr.active).flushAndWait()
        src.onFrame?(silentFrame())
        try await waitUntil { mgr.active?.captureId != firstCapture }

        // Segments NOT yet ACK'd → finalize must be deferred (door has nothing to
        // assemble until the audio is durably on the desktop).
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [], "finalize must wait until segments are ACK'd")

        // Now ACK + retry → it fires.
        ackAllSegments(dir, firstCapture)
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [firstCapture], "finalize fires once segments are ACK'd")
    }

    func testFailedFinalizeStaysRetryable() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-finalize-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rec = FinalizeRecorder()
        rec.shouldFail = true              // door/Lore down at close
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { id in try rec.record(id) })
        mgr.setSilenceGap(0)

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let firstCapture = try XCTUnwrap(mgr.active).captureId
        for _ in 0..<60 { src.onFrame?(voiceFrame()) }
        try XCTUnwrap(mgr.active).flushAndWait()
        src.onFrame?(silentFrame())
        try await waitUntil { mgr.active?.captureId != firstCapture }
        ackAllSegments(dir, firstCapture)

        // First attempt fails — capture must NOT be dropped (mirrors WAL retry).
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [firstCapture], "the failed attempt happened")

        // Door recovers; the next retry succeeds (the capture was still pending).
        rec.shouldFail = false
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [firstCapture, firstCapture],
                       "a failed finalize stays retryable and succeeds on the next tick")

        // And now it's cleared — no further attempts.
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [firstCapture, firstCapture], "no retry after success")
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
