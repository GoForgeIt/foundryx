// THE PART OF "THE SPINNER IS ON THE ROW I TAPPED" THAT ONLY THE SOURCE CAN HOLD.
//
// `swift test` cannot compile `App/`, so the SwiftUI body that draws a shelf row is out of
// reach of every behavioural assertion in this target. What is IN reach is whether that body
// asks the kit or decides for itself — which is the whole reason the decision was moved to
// `PocketErrandProgressPresentation` in the first place.
//
// These are deliberately narrow. They do not check that a spinner appears; the app-hosted lane
// checks the model that would drive one, and the kit tests check the rule. They check that the
// page cannot go back to a global busy flag and a self-closing sheet without a red.

import XCTest
import Foundation
@testable import FoundryXKit

final class RecorderPageProgressGateTests: XCTestCase {

    private func deviceScreen() throws -> (raw: String, code: String) {
        let path = AppSourceTree.repoRoot.appendingPathComponent("App/DeviceScreen.swift")
        let raw = try String(contentsOf: path, encoding: .utf8)
        // Non-vacuity: these gates are about the page that draws the shelf and the sheet about
        // one recording. If either is gone, they are holding the wrong file.
        XCTAssertTrue(raw.contains("PocketRecordingDetailSheet"),
                      "App/DeviceScreen.swift no longer holds the page about one recording — "
                          + "these gates are checking a file that is not the subject any more")
        return (raw, AppSourceTree.code(of: raw))
    }

    /// BOTH SURFACES ASK THE SAME QUESTION OF THE SAME RULE — the shelf row and the page about
    /// one recording. Two of them, because one is Nick's "not just at the top" and the other is
    /// his "show me the loading screen right there", and a page that asked on only one of them
    /// would have closed exactly half of this.
    ///
    /// MATCHED AS A PATTERN, NOT AS A LITERAL. The first draft of this gate looked for
    /// `PocketErrandProgressPresentation.progress(` verbatim and was blind to the row's call,
    /// which wraps after the type name — so it passed while one of the two surfaces did not
    /// consult the rule at all. A gate that a line break defeats is a gate.
    func testBothRecorderSurfacesAskTheKitWhichRecordingIsMoving() throws {
        let source = try deviceScreen()
        // BOTH SPELLINGS OF THE SAME QUESTION. The band above the list asks `bandProgress`,
        // which is `progress` minus the one answer the panel headline already owns; a pattern
        // that saw only the bare name would count two surfaces and call the third a defect.
        let asks = try NSRegularExpression(
            pattern: #"PocketErrandProgressPresentation\s*\.\s*(band)?[pP]rogress\("#)
        let ns = source.code as NSString
        let found = asks.numberOfMatches(in: source.code,
                                         range: NSRange(location: 0, length: ns.length))
        XCTAssertGreaterThanOrEqual(found, 3,
                                    "only \(found) surface(s) ask which recording is moving. "
                                        + "There are THREE that draw progress on this page — "
                                        + "the shelf row, the page about one recording, and the "
                                        + "band above the list — and each has to ask, or it is "
                                        + "deciding for itself in a SwiftUI body nothing here "
                                        + "can execute")
    }

    /// THE BAND ABOVE THE LIST IS THE ONE NICK WAS LOOKING AT when he said "not just at the
    /// top", AND IT WAS THE ONE LEFT ON A GLOBAL BOOL.
    ///
    /// That band's button offers `PocketBringOver.offered`'s pick — the smallest file on the
    /// newest day. Its spinner read `if check.isBringingOver`, which is true for ANY transfer,
    /// so asking for a different recording from that recording's own page made this band say
    /// "Bringing this recording over…" underneath a button about a file nothing was happening
    /// to. One radio is one errand, so exactly one of the three surfaces may claim to be
    /// working, and which one is not a question a Bool can answer.
    func testTheBandAboveTheListSaysWhichRecordingIsMoving() throws {
        let source = try deviceScreen()
        XCTAssertFalse(source.code.contains("if check.isBringingOver {"),
                       "the bring-over band still draws its spinner from a global busy flag, so "
                           + "it claims the recording it OFFERS is the one coming over whenever "
                           + "any transfer is running")
        XCTAssertFalse(source.code.contains("PocketBringOverPresentation.inProgressLine"),
                       "the page picks the in-progress sentence itself instead of taking the "
                           + "one `PocketErrandProgressPresentation` hands it, which is how two "
                           + "surfaces end up saying different things about one errand")
    }

    /// THE GLOBAL BUSY FLAG IS GONE. Three ORed booleans is exactly the state that could not
    /// say which of nineteen recordings a spinner was about.
    func testThePageAboutOneRecordingIsNotHandedAGlobalBusyFlag() throws {
        let source = try deviceScreen()
        XCTAssertFalse(
            source.code.contains("check.isChecking || check.isBringingOver || check.isRemoving"),
            "the page about one recording is told only that SOMETHING is busy, so it disables "
                + "its own actions for another recording's errand and can say nothing about "
                + "which")
    }

    /// ONE RADIO, ONE ERRAND — AND THIS PAGE SAID SO IN WORDS WHILE OFFERING A SECOND ONE.
    ///
    /// MEASURED IN THE SOURCE. Five functions on this model start an errand, and they did not
    /// agree about what stops one. `run` (the shelf check) and the bring-over funnel guarded
    /// `!isChecking, !isBringingOver` and said NOTHING about a removal; the two removal paths
    /// and the fast sync guarded all three. So with a removal in flight the band above the list
    /// drew its own sentence — "Solleva is taking another recording off this recorder. It can
    /// only do one at a time." — directly underneath a "Bring it over" button that
    /// `.disabled(check.isBringingOver || check.isChecking)` left ENABLED. The control
    /// contradicted the sentence beneath it, and the tap was taken.
    ///
    /// WHY THAT IS F7 AND NOT A SEPARATE BUG. `beginErrand` assigns `inFlight`, which is the
    /// one place this page records WHICH recording an errand is about. A second errand
    /// overwrites it, so the removal's row stops spinning mid-removal, the transfer's row
    /// starts, and the single `finishErrand` that follows writes ONE `errand.stop` carrying the
    /// wrong subject and the wrong `about=`. The live log is then left holding a start that
    /// never stopped and a stop that never started, for two different recordings — the exact
    /// pairing F7 added `about=` to make readable.
    ///
    /// SO THE ADMISSION IS ONE RULE IN THE KIT, asked by every entry point and by the control
    /// that offers one, rather than three booleans each caller ORs from memory.
    func testNoControlOnThisPageStartsASecondErrandWhileOneIsInFlight() throws {
        let source = try deviceScreen()

        // (a) NO ENTRY POINT DECIDES FOR ITSELF. Any `guard !is…` here is a caller re-deriving
        // "is the radio free" from flags it happens to remember, which is how two of the five
        // came to omit the removal.
        let ownGuard = try NSRegularExpression(
            pattern: #"guard\s+![^\n]*\bis(Checking|BringingOver|Removing)\b[^\n]*"#)
        let ns = source.code as NSString
        let owned = ownGuard.matches(in: source.code,
                                     range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
        XCTAssertEqual(owned, [],
                       "an errand entry point still decides for itself whether the radio is "
                           + "free, from busy flags it ORs by hand: \(owned). Two of the five "
                           + "omitted the removal, so a tap during one started a second errand "
                           + "and took over the first one's `inFlight` identity")

        // (b) NO CONTROL DECIDES FOR ITSELF EITHER, and this is matched as a PATTERN over
        // every `.disabled(` on the page rather than as the one spelling that was there.
        //
        // THE FIRST DRAFT OF THIS WAS THE LITERAL `check.isBringingOver || check.isChecking`,
        // and running it is what found the FOURTH control: the FAST SYNC button carried the
        // same two flags with a capability check ORed on the end, so a reading missed it and
        // the gate did not. A reordered OR would have defeated the literal the same way.
        //
        // The two halves are different questions and only one of them is here. Whether the
        // radio is free is this rule; whether a fast sync can run on this build at all
        // (`fastSyncCanRun`) is a capability and stays where it is.
        let ownControl = try NSRegularExpression(
            pattern: #"\.disabled\([^)]*check\.is(Checking|BringingOver|Removing)"#)
        let controls = ownControl.matches(in: source.code,
                                          range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
        XCTAssertEqual(controls, [],
                       "a control on this page is enabled by busy flags it ORs by hand: "
                           + "\(controls). During a REMOVAL those spellings leave the button "
                           + "live — underneath a band whose own sentence says the recorder can "
                           + "only do one thing at a time — and the tap either starts a second "
                           + "errand or is dropped in silence by an entry point that does "
                           + "refuse it")

        // (c) AND THE RULE IS ACTUALLY ASKED, at least once for every place an errand begins.
        // The population is READ OFF THE FILE rather than typed here, so a sixth entry point
        // cannot be added with no admission at all.
        let starts = try NSRegularExpression(pattern: #"(?<!func )beginErrand\("#)
        let beginnings = starts.numberOfMatches(in: source.code,
                                                range: NSRange(location: 0, length: ns.length))
        XCTAssertGreaterThan(beginnings, 0,
                             "no errand is started on this page at all, so this gate is about "
                                 + "nothing")
        let asks = try NSRegularExpression(
            pattern: #"PocketErrandProgressPresentation\s*\.\s*admitsANewErrand\("#)
        let asked = asks.numberOfMatches(in: source.code,
                                         range: NSRange(location: 0, length: ns.length))
        XCTAssertGreaterThanOrEqual(asked, beginnings,
                                    "\(beginnings) place(s) start an errand and only \(asked) "
                                        + "ask whether one may start. An entry point with no "
                                        + "admission takes over the identity of the errand "
                                        + "already running")
    }

    /// NICK'S ASK, held where it is decidable: the sheet consults the rule instead of closing
    /// itself the instant a transfer is asked for.
    func testAskingForATransferDoesNotCloseThePageItWasAskedFrom() throws {
        let source = try deviceScreen()
        XCTAssertTrue(source.code.contains("leavesThePageOpen"),
                      "the page about one recording does not consult the rule about whether it "
                          + "stays open, so whatever it does is a decision no test can read")

        let closesItself = try NSRegularExpression(
            pattern: #"onBringOver\([^)]*\)\s*onClose\(\)"#)
        let ns = source.code as NSString
        XCTAssertNil(closesItself.firstMatch(in: source.code,
                                            range: NSRange(location: 0, length: ns.length)),
                     "the sheet still closes itself the moment the transfer is asked for, which "
                         + "is the thing Nick asked to stop: \"it should show me the loading "
                         + "screen right there rather than taking me back to the home screen\"")
    }
}
