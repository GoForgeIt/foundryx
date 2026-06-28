import XCTest
import Foundation
@testable import FoundryXKit

/// Door-free tests for the conversation-segmentation fixes (track 20260628T1654):
///  • the WALL-CLOCK silence boundary that fires even when the Omi stops sending frames
///    during silence (the root cause of one capture swallowing many conversations),
///  • the min-voiced-frames MERGE-FORWARD gate (a 1–2 word burst never spawns a tiny
///    capture — it absorbs into the next conversation),
///  • the runaway force-split backstop decision,
///  • the de-dup invariant that guarantees one list row per capture.
final class ConversationSegmentationTests: XCTestCase {

    // MARK: wall-clock silence (frames STOP during the gap — observe() never called)

    /// The bug: the segmenter only saw the gap when a frame arrived; the Omi BLE stream
    /// goes quiet (DTX) during silence, so `observe` was never called and the gap was
    /// never detected → conversations merged. `checkSilence` evaluates the gap on the
    /// wall clock alone, so a watchdog tick closes the conversation with NO frames.
    func testWallClockSilenceClosesWithoutFrames() {
        let seg = SilenceSegmenter(silenceGap: 2.0, silenceThreshold: 0.5, minVoicedFramesToClose: 3)
        // Conversation 1: enough voiced frames to stand alone.
        XCTAssertEqual(seg.observe(level: 0.9, at: 0.0), .opened)
        seg.observe(level: 0.9, at: 0.1)
        seg.observe(level: 0.9, at: 0.2)
        // Frames now STOP (no further observe calls). The watchdog ticks on wall time:
        XCTAssertNil(seg.checkSilence(at: 1.0), "gap not yet elapsed")
        XCTAssertEqual(seg.checkSilence(at: 2.5), .closed,
                       "the gap must close on wall-clock alone, even with zero frames arriving")
    }

    /// Same path through the production FrameRouter (the seam the watchdog actually
    /// drives): route real voiced packets, stop, advance the injected clock, and the
    /// router's `tickSilence` reports the boundary — no WAL / no frames during silence.
    func testFrameRouterTickSilenceClosesWhenFramesStop() {
        var now: TimeInterval = 0
        let seg = SilenceSegmenter(silenceGap: 2.0, silenceThreshold: 0.06, minVoicedFramesToClose: 5)
        let router = FrameRouter(segmenter: seg, clock: { now })
        let voiced = RealOmiFrames.voiced()
        for _ in 0..<6 { now += 0.02; router.route(voiced) }   // ≥5 voiced frames
        XCTAssertNil(router.tickSilence(), "gap not yet elapsed")
        now += 3.0                                             // frames have STOPPED
        XCTAssertEqual(router.tickSilence(), .closed,
                       "watchdog must segment the ambient stream when the source goes quiet")
    }

    // MARK: merge-forward (tiny bursts don't spawn their own capture)

    /// A burst with too little voiced content does NOT split on the gap — it stays open
    /// so the next utterance merges into the same conversation (Omi adjacent-fragment
    /// merge). Once enough voice accumulates, a later gap DOES close it.
    func testShortBurstMergesForward() {
        let seg = SilenceSegmenter(silenceGap: 2.0, silenceThreshold: 0.5, minVoicedFramesToClose: 10)
        XCTAssertEqual(seg.observe(level: 0.9, at: 0.0), .opened)   // tiny 3-frame burst
        seg.observe(level: 0.9, at: 0.02)
        seg.observe(level: 0.9, at: 0.04)
        XCTAssertNil(seg.observe(level: 0.0, at: 10.0), "too few voiced frames → no split")
        XCTAssertNil(seg.checkSilence(at: 100.0), "still merging forward, not a separate capture")
        // Next utterance continues the SAME conversation, accumulating real content.
        var t = 101.0
        for _ in 0..<12 { seg.observe(level: 0.9, at: t); t += 0.02 }
        XCTAssertEqual(seg.checkSilence(at: 200.0), .closed,
                       "the merged conversation closes once it has accumulated real voice")
    }

    // MARK: runaway force-split backstop

    func testForceSplitBackstop() {
        let start: TimeInterval = 1_000
        XCTAssertFalse(CaptureManager.shouldForceSplit(startedAt: start, totalSegments: 10, now: start + 60),
                       "a normal in-progress conversation is not force-split")
        XCTAssertTrue(CaptureManager.shouldForceSplit(startedAt: start, totalSegments: 10,
                                                      now: start + CaptureManager.maxConversationSeconds),
                      "past the duration backstop → force-split")
        XCTAssertTrue(CaptureManager.shouldForceSplit(startedAt: start,
                                                      totalSegments: CaptureManager.maxConversationSegments,
                                                      now: start + 1),
                      "past the segment backstop → force-split")
    }

    // MARK: de-dup (one row per capture)

    func testDeduplicatedByCaptureId() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-dedup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let dup1 = CaptureWAL(captureId: "omi-DUP", target: target, baseDir: dir)
        let dup2 = CaptureWAL(captureId: "omi-DUP", target: target, baseDir: dir)
        let other = CaptureWAL(captureId: "omi-OTHER", target: target, baseDir: dir)
        let out = CaptureManager.deduplicatedByCaptureId([dup1, dup2, other])
        XCTAssertEqual(out.map { $0.captureId }, ["omi-DUP", "omi-OTHER"],
                       "duplicate capture-ids collapse to one row, order preserved")
    }
}
