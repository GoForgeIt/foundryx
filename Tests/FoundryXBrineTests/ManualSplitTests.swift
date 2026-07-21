import XCTest
import Foundation
import FoundryXKit

/// Door-free state-machine test for MANUAL conversation segmentation (Feature 2).
/// `splitConversation()` is the hand-triggered version of the silence-gap boundary:
/// it finalizes the CURRENT capture (sent for transcription via the existing finalize
/// path) and immediately begins a NEW conversation, without waiting for the auto split.
/// We assert: the closed capture finalizes exactly once (with its id, after ACK), a new
/// active capture replaces it, and the new conversation keeps recording (no dropped
/// audio). Mirrors CaptureFinalizeTests' injected-boundary approach (no live door).
@MainActor
final class ManualSplitTests: XCTestCase {

    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    final class FinalizeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ id: String) { lock.lock(); _calls.append(id); lock.unlock() }
    }

    private func ackAllSegments(_ dir: URL, _ captureId: String) {
        let cdir = dir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "opus" {
            try? Data().write(to: f.deletingPathExtension().appendingPathExtension("ack"), options: [.atomic])
        }
    }

    func testManualSplitFinalizesCurrentAndStartsNew() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rec = FinalizeRecorder()
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { id, _ in rec.record(id) })
        // A LONG silence gap so the auto-segmenter never fires — the split must be ours.
        mgr.setSilenceGap(9_999)

        src.onState?(.streaming)
        RealOmiFrames.openSession(src.onFrame)   // speech onset opens the conversation
        try await waitUntil { mgr.active != nil }
        let firstCapture = try XCTUnwrap(mgr.active).captureId

        // Record enough voice to clear the min-substance upload bar (else the split
        // section is dropped as a junk fragment instead of finalized).
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) { src.onFrame?(RealOmiFrames.voiced()) }
        try XCTUnwrap(mgr.active).flushAndWait()

        // MANUAL split: finalize the current section + begin a new one immediately.
        mgr.splitConversation()
        try await waitUntil { mgr.active != nil && mgr.active?.captureId != firstCapture }
        let secondCapture = try XCTUnwrap(mgr.active).captureId
        XCTAssertNotEqual(firstCapture, secondCapture, "split begins a NEW conversation")

        // The closed section reaches Lore via the existing finalize path (after ACK).
        ackAllSegments(dir, firstCapture)
        await mgr.retryPendingFinalizes()
        XCTAssertEqual(rec.calls, [firstCapture], "the split section is finalized once, by its id")

        // No dropped audio: the NEW conversation keeps recording cleanly.
        for _ in 0..<60 { src.onFrame?(RealOmiFrames.voiced()) }
        try XCTUnwrap(mgr.active).flushAndWait()
        XCTAssertGreaterThan(try XCTUnwrap(mgr.active).snapshot().totalSegments, 0,
                             "the new conversation records without dropping audio")
        XCTAssertEqual(mgr.active?.captureId, secondCapture, "still the same new conversation")
    }

    func testSplitWithNoActiveCaptureIsNoOp() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-split-noop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rec = FinalizeRecorder()
        let src = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { id, _ in rec.record(id) })

        // No source streaming → no active capture → split does nothing.
        mgr.splitConversation()
        XCTAssertNil(mgr.active, "split with nothing recording is a no-op")
        XCTAssertEqual(rec.calls, [], "no finalize when there's nothing to split")
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
