import XCTest
import Foundation
import FoundryXKit

/// Regression (impl-review MAJOR, track 20260716T2031): a lane-surfaced ambient candidate
/// must reach the recording surface ONLY while it still belongs to the active capture.
/// The lane's `consider()` runs detached and slow (an on-device LLM, ~1–5s), so a candidate
/// can return AFTER the user ended the recording, or after the session rolled to a new
/// conversation — it must be dropped, never bled onto the wrong/next conversation.
@MainActor
final class RecordingCandidateLifecycleTests: SignedOutListeningCaptureTestCase {

    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-cand-\(UUID().uuidString)", isDirectory: true)
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

    func testCandidateDroppedForNonActiveCaptureAndAfterEnd() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let omi = TestSource(); let mic = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: omi, micSource: mic,
                                 finalize: { _, _ in })
        #if os(iOS)
        mgr.micPermissionOverrideForTests = true
        #endif

        mgr.startMicRecording()
        mic.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let capA = try XCTUnwrap(mgr.active).captureId

        // A candidate mined FROM the active capture appears on the surface.
        mgr.noteRecordingCandidate(
            AmbientCandidate(utterance: "send the deck", summary: "Send Sarah the deck", confidence: 0.9),
            forCapture: capA)
        XCTAssertEqual(mgr.recordingCandidates.count, 1, "a candidate for the active capture appears")

        // A candidate mined from a DIFFERENT (rolled / previous) capture is dropped —
        // it never appears on this conversation's surface.
        mgr.noteRecordingCandidate(
            AmbientCandidate(utterance: "stale one", summary: "from a previous conversation", confidence: 0.9),
            forCapture: "some-other-capture-id")
        XCTAssertEqual(mgr.recordingCandidates.count, 1, "a candidate for a NON-active capture is dropped")

        // End the recording; a candidate that arrives LATE (the detached lane finally
        // returns) for the now-ended capture must never surface on the next recording.
        mgr.stopMicRecording()
        mic.onState?(.stopped)
        try await waitUntil { mgr.active == nil }
        mgr.noteRecordingCandidate(
            AmbientCandidate(utterance: "late arrival", summary: "the slow lane finally returned", confidence: 0.9),
            forCapture: capA)
        XCTAssertTrue(mgr.recordingCandidates.isEmpty,
                      "a candidate arriving after the recording ended never appears")
    }
}
