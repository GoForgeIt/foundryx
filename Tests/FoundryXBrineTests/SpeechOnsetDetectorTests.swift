import XCTest
@testable import FoundryXKit

/// Speech-gated conversation start: the Omi stays "Listening," but a conversation
/// only opens when there's actual sustained speech — no empty "Untitled
/// conversation" cards for silence or one-off noise (Nick 2026-07-21).
final class SpeechOnsetDetectorTests: XCTestCase {
    private func feed(_ d: inout SpeechOnsetDetector, voiced: Bool, _ n: Int) -> Bool {
        var fired = false
        for _ in 0..<n { if d.observe(voiced: voiced) { fired = true } }
        return fired
    }

    func testSilenceNeverOpens() {
        var d = SpeechOnsetDetector()
        XCTAssertFalse(feed(&d, voiced: false, 5000), "pure silence must never open a conversation")
    }

    func testSustainedSpeechOpensOnce() {
        var d = SpeechOnsetDetector(framesToOpen: 10, resetAfterSilentFrames: 20)
        // First 9 voiced frames: not yet.
        XCTAssertFalse(feed(&d, voiced: true, 9))
        // The 10th crosses the bar.
        XCTAssertTrue(d.observe(voiced: true))
        // It fires exactly once — no re-fire while speech continues.
        XCTAssertFalse(feed(&d, voiced: true, 100))
    }

    func testShortTransientDoesNotOpen() {
        var d = SpeechOnsetDetector(framesToOpen: 10, resetAfterSilentFrames: 20)
        // A 4-frame burst (a slam/cough) then quiet → the run decays, no onset.
        XCTAssertFalse(feed(&d, voiced: true, 4))
        XCTAssertFalse(feed(&d, voiced: false, 100))
        XCTAssertFalse(feed(&d, voiced: true, 4))
        XCTAssertFalse(feed(&d, voiced: false, 100))
    }

    func testBriefDipsInsideSpeechStillOpen() {
        var d = SpeechOnsetDetector(framesToOpen: 10, resetAfterSilentFrames: 20)
        // Natural phrase: voice, a short intra-word gap (< reset), more voice — the run
        // survives the dip and reaches the bar.
        XCTAssertFalse(feed(&d, voiced: true, 6))
        XCTAssertFalse(feed(&d, voiced: false, 5))   // dip shorter than resetAfterSilentFrames
        XCTAssertTrue(feed(&d, voiced: true, 5))      // 6 + 5 = 11 ≥ 10
    }

    func testLongGapResetsTheRun() {
        var d = SpeechOnsetDetector(framesToOpen: 10, resetAfterSilentFrames: 20)
        XCTAssertFalse(feed(&d, voiced: true, 6))
        XCTAssertFalse(feed(&d, voiced: false, 25))  // gap ≥ reset → run zeroed
        XCTAssertFalse(feed(&d, voiced: true, 6))     // only 6 again → still below the bar
    }

    func testResetReArmsForNextWindow() {
        var d = SpeechOnsetDetector(framesToOpen: 10, resetAfterSilentFrames: 20)
        XCTAssertTrue(feed(&d, voiced: true, 10))
        XCTAssertFalse(feed(&d, voiced: true, 50), "already fired")
        d.reset()
        XCTAssertFalse(feed(&d, voiced: true, 9))
        XCTAssertTrue(d.observe(voiced: true), "re-armed window opens again on fresh sustained speech")
    }
}
