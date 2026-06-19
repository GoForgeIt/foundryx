import XCTest
import Foundation
import FoundryXKit

/// Door-free unit test for silence-gap auto-segmentation (req 9). Feeds a synthetic
/// level sequence (loud → silence longer than the gap → loud) into the segmenter
/// and asserts it closes one conversation + opens the next — the boundary the
/// CaptureManager turns into a rotated capture, with no pause/stop and no real
/// 2-minute wait (the clock is the timestamps we pass in).
final class SilenceSegmenterTests: XCTestCase {

    func testLoudSilenceLoudClosesThenOpens() {
        let seg = SilenceSegmenter(silenceGap: 2.0, silenceThreshold: 0.5)
        var events: [SegmentEvent] = []
        func feed(_ level: Float, _ t: TimeInterval) { if let e = seg.observe(level: level, at: t) { events.append(e) } }

        // Conversation 1: voice → opens.
        feed(0.9, 0.0)   // first voice → .opened
        feed(0.8, 0.5)   // still talking
        // Silence begins; gap not yet exceeded (measured from last voice @0.5).
        feed(0.1, 1.0)   // 0.5s quiet
        feed(0.1, 2.0)   // 1.5s quiet
        feed(0.1, 2.4)   // 1.9s quiet — still under 2.0, no close
        XCTAssertEqual(events, [.opened], "must not close before the gap elapses")
        // Gap exceeded → close conversation 1.
        feed(0.1, 2.6)   // 2.1s quiet ≥ gap → .closed
        // More silence stays closed (no spurious re-close).
        feed(0.1, 3.0)
        feed(0.1, 60.0)
        // Conversation 2: voice resumes → opens the next.
        feed(0.95, 65.0) // → .opened

        XCTAssertEqual(events, [.opened, .closed, .opened],
                       "loud → silence>gap → loud should close one conversation and open the next")
    }

    /// A gap shorter than the threshold never segments (one continuous conversation).
    func testBriefPausesDoNotSegment() {
        let seg = SilenceSegmenter(silenceGap: 120, silenceThreshold: 0.5)
        var events: [SegmentEvent] = []
        func feed(_ l: Float, _ t: TimeInterval) { if let e = seg.observe(level: l, at: t) { events.append(e) } }
        feed(0.9, 0)
        feed(0.1, 5)     // 5s pause
        feed(0.1, 30)    // 30s pause — well under 120s
        feed(0.9, 31)    // talking again
        feed(0.1, 200)   // long quiet from t=31 → 169s ≥ 120 → close
        XCTAssertEqual(events, [.opened, .closed], "only the gap that exceeds the threshold segments")
    }

    /// `noteActive` (used on resume) rebaselines the quiet clock so a deliberate
    /// pause isn't mistaken for a silence gap.
    func testNoteActiveRebaselinesAfterPause() {
        let seg = SilenceSegmenter(silenceGap: 2.0, silenceThreshold: 0.5)
        XCTAssertEqual(seg.observe(level: 0.9, at: 0.0), .opened)
        // Simulate a 100s pause, then resume → rebaseline at t=100.
        seg.noteActive(at: 100.0)
        // 1.5s of quiet after resume — must NOT close (gap measured from 100, not 0).
        XCTAssertNil(seg.observe(level: 0.1, at: 101.5))
        // Now exceed the gap from the resume baseline.
        XCTAssertEqual(seg.observe(level: 0.1, at: 102.5), .closed)
    }

    /// The frame-size level proxy: tiny DTX/silence frames read ~0, full frames ~1.
    func testOpusFrameLevelProxy() {
        XCTAssertLessThan(opusFrameLevel(Data(repeating: 0, count: 3)), 0.05, "DTX/silence frame ≈ 0")
        XCTAssertGreaterThan(opusFrameLevel(Data(repeating: 0, count: 80)), 0.9, "full speech frame ≈ 1")
        let mid = opusFrameLevel(Data(repeating: 0, count: 45))
        XCTAssertGreaterThan(mid, 0.3); XCTAssertLessThan(mid, 0.7)
    }
}
