import XCTest
@testable import FoundryXKit

/// **NO SURFACE MAY PROMISE THAT CLEARING A RECORDING MAKES ROOM.**
///
/// ## Measured, not reasoned
///
/// Probe P3, real hardware, 2026-08-22
/// (`evidence/pocket/PKT01_BLUE_26079bc5-fw1.6-20260822-space-and-shelf.md`):
///
///     >> APP&D&2026-08-20&20260820160218
///     << MCU&D                              acknowledged
///     >> APP&SPACE
///     << MCU&SPA&058766&058992              STILL 226 KB free — unmoved
///     >> APP&LIST&2026-08-20
///     << MCU&LIST&000                       the date is empty
///
/// A 2 KB recording left the shelf and **free space did not move by one kilobyte**. `APP&D`
/// unlinks; it does not reclaim.
///
/// ## Why this test exists rather than a comment
///
/// `PocketRecorderRoomPresentation.makeRoomAction` read **"Make room now"** for a day — written
/// the same morning, offered to an owner whose recorder was full, and unable to do the one thing
/// its words promised. Nothing caught it because nothing had asked the hardware.
///
/// A comment saying "don't promise space" is a rule a reviewer must remember. This is the rule as
/// something that fails.
final class ClearingNeverPromisesSpaceTests: XCTestCase {

    /// **EXISTENCE FIRST.** A prohibition swept over an empty population passes for free, and
    /// "no line promises space" is exactly the claim an empty list satisfies.
    func testThereAreLinesToJudge() {
        XCTAssertGreaterThanOrEqual(
            PocketRecorderRoomPresentation.everyLine.count, 5,
            "the copy population is too small to be the whole surface — a prohibition over it "
            + "would prove almost nothing")
        XCTAssertFalse(PocketRecorderRoomPresentation.phrasesThatPromiseSpace.isEmpty,
                       "no forbidden phrases are declared, so the scan below examines nothing")
    }

    /// The prohibition itself, over the whole population and every forbidden phrase.
    func testNoLinePromisesThatClearingMakesRoom() {
        for line in PocketRecorderRoomPresentation.everyLine {
            let lowered = line.lowercased()
            for phrase in PocketRecorderRoomPresentation.phrasesThatPromiseSpace {
                XCTAssertFalse(
                    lowered.contains(phrase),
                    """
                    a recorder-room line promises space that clearing cannot deliver:
                      line   : "\(line)"
                      phrase : "\(phrase)"
                    Measured 2026-08-22: APP&D unlinks and does not reclaim — 226 KB free before \
                    a delete, 226 KB after.
                    """)
            }
        }
    }

    /// **AND THE OFFER SHOWN TO A FULL RECORDER IS SUBJECT TO IT.** The prohibition above reads
    /// `everyLine`; this reads what `offers(…)` actually returns, so a line that reaches a person
    /// without being in the population still fails.
    func testTheOffersAFullRecorderShowsAreSubjectToTheSameRule() {
        let armed = PocketAutoClear(armedAt: Date(timeIntervalSince1970: 1_000_000))
        for autoClear in [PocketAutoClear.off, armed] {
            let offers = PocketRecorderRoomPresentation.offers(room: .noRoomLeft, autoClear: autoClear)
            XCTAssertFalse(offers.isEmpty, "a full recorder was offered nothing at all")
            for offer in offers {
                let lowered = offer.lowercased()
                for phrase in PocketRecorderRoomPresentation.phrasesThatPromiseSpace {
                    XCTAssertFalse(lowered.contains(phrase),
                                   "an offer shown to a FULL recorder promises space: \"\(offer)\"")
                }
            }
        }
    }

    /// The honest sentence is present and says the thing that is true.
    func testTheOwnerIsToldClearingWillNotFreeSpace() {
        let line = PocketRecorderRoomPresentation.fullNeedsMoreThanClearing.lowercased()
        XCTAssertTrue(line.contains("won't free space") || line.contains("will not free space"),
                      "the surface never tells a full recorder's owner that clearing will not "
                      + "free space, which is the one thing measurement established")
        XCTAssertFalse(line.contains("reset"),
                       "the copy names a remedy nobody has tested — APP&RESET has never been "
                       + "issued to this hardware, and naming it would repeat the error this "
                       + "correction fixes")
    }
}
