import XCTest
@testable import FoundryXKit

/// **THE DOOR NOW COUNTS THE WINDOWS, AND THE BAND MUST ONLY DRAW WHAT IT COUNTED.**
///
/// P11's AC1 shipped with `transcript = .inProgress(nil)` hard-coded, because the door sent no
/// window counts and *"a bar drawn from a number nobody measured is the defect this whole surface
/// exists to remove"*. Lore now counts them (`transcribe_chunk`: one row per finished window,
/// `chunk_count` for the total) and the door forwards them.
///
/// Every test below is a way that plumbing could turn an ABSENCE into a ZERO.
final class TranscribeWindowsReachTheBandTests: XCTestCase {

    private func reading(_ w: CaptureStatusResponse.TranscribeWindowsPayload?)
        -> TranscriptReadiness {
        CaptureStatusPoller.journey(stage: .transcribing, transcribed: false,
                                    title: nil, droppedReason: nil,
                                    transcribeWindows: w).transcript
    }

    /// The counts arrive and are carried through unchanged.
    func testCountedWindowsBecomeAReadingTheBandCanDraw() {
        guard case let .inProgress(got) = reading(.init(windowsDone: 3, windowCount: 20)) else {
            return XCTFail("a transcribing capture with counted windows was not .inProgress")
        }
        XCTAssertEqual(got, TranscribeWindowsReading(windowsDone: 3, windowCount: 20))
    }

    /// **THE ORDINARY CASE, AND THE ONE THAT MUST NOT REGRESS.** A recording under Lore's 600 s
    /// threshold is transcribed whole and has no windows; one that has not started has none yet.
    /// Both must stay `nil` — the band draws no bar, rather than 0%.
    func testNoCountsStillMeansNoBar() {
        guard case let .inProgress(got) = reading(nil) else {
            return XCTFail("a transcribing capture with no counts was not .inProgress")
        }
        XCTAssertNil(got, "an absent window reading became a drawable one; the band would show "
                          + "0% for work nobody measured")
    }

    /// A zero denominator is not a fraction, so it is not a reading.
    func testAZeroWindowCountIsRefused() {
        guard case let .inProgress(got) = reading(.init(windowsDone: 0, windowCount: 0)) else {
            return XCTFail("not .inProgress")
        }
        XCTAssertNil(got)
    }

    /// **DISAGREEING COUNTS ARE REFUSED, NOT CLAMPED.** `done > count` means the two numbers
    /// disagree; pinning the bar at 100% while work continues is the same lie as 0% for
    /// unmeasured work, so the honest reading is no reading.
    func testCountsThatExceedTheirTotalAreRefusedRatherThanClamped() {
        guard case let .inProgress(got) = reading(.init(windowsDone: 21, windowCount: 20)) else {
            return XCTFail("not .inProgress")
        }
        XCTAssertNil(got, "a windowsDone greater than windowCount produced a reading; a bar "
                          + "pinned at 100% while work continues is invented progress")
    }

    /// A finished transcript is `.done` regardless of what the counts say — the counts describe
    /// progress, and progress is not the verdict.
    func testATranscribedCaptureIsDoneWhateverTheCountsSay() {
        let r = CaptureStatusPoller.journey(stage: .transcribing, transcribed: true,
                                            title: nil, droppedReason: nil,
                                            transcribeWindows: .init(windowsDone: 1,
                                                                     windowCount: 20)).transcript
        XCTAssertEqual(r, .done)
    }

    /// **THE DERIVATION MUST BE REACHED BY PRODUCTION, NOT ONLY BY THIS TEST.**
    ///
    /// P11's band twice failed to land because nothing drew it, and landing a derivation nothing
    /// calls is the same defect wearing different clothes. A source scan is the only thing that
    /// can see the wiring, so it is asserted here rather than assumed.
    func testThePollerActuallyPassesTheCountsToTheDerivation() throws {
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FoundryXKit/CaptureStatusPoller.swift")
        let text = try String(contentsOf: src, encoding: .utf8)

        // EXISTENCE FIRST: if the file moved, this scan proves nothing and must fail loudly
        // rather than pass over an empty string.
        XCTAssertTrue(text.contains("static func journey("),
                      "CaptureStatusPoller.swift did not contain the derivation this test scans "
                      + "for; the scan examined the wrong file and would pass vacuously")

        XCTAssertTrue(text.contains("transcribeWindows: resp.transcribeWindows"),
                      "the poller calls journey() without passing resp.transcribeWindows, so the "
                      + "door's counts never reach the band and this whole change is unreachable")
    }
}
