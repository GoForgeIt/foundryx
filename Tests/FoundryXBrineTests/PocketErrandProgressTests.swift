// THE SPINNER BELONGS TO THE RECORDING THE OWNER TAPPED.
//
// NICK, ON HIS OWN UNIT: "if I could click on an individual recording and click bring over, it
// should show me the loading screen right there rather than taking me back to the home screen,
// and then if I do go back to the home screen, well, it is loading, it should show the loading
// spinner on the specific recording that I clicked to bring over not just at the top."
//
// THE DEFECT UNDERNEATH IT. The recorder page's model had one in-flight flag per KIND of
// errand and not one of them had a subject, so nothing in the app could answer "which of these
// nineteen recordings is moving?". A page-level spinner was the only honest thing it could
// draw, and the sheet the owner tapped had to close itself to show them one.
//
// These hold the decision. The wiring — that the model publishes the subject and clears it on
// every exit — is held in the app-hosted lane, which is the only place `App/` executes.
//
// THE MUTATIONS THESE ANSWER TO:
//   * make `progress` compare nothing and return `.thisRecording` whenever an errand runs, and
//     "another recording's transfer does not spin this row" goes red;
//   * make it return `.idle` for an errand about a different recording and "a second tap is
//     refused with a sentence" goes red;
//   * flip `leavesThePageOpen` for `.bringItOver` and the page that Nick asked to stay open
//     closes again.

import XCTest
@testable import FoundryXKit

final class PocketErrandProgressTests: XCTestCase {

    private let mine = "2026-08-11/20260811153632"
    private let theirs = "2026-08-07/20260807142852"

    private func bringingOver(_ id: String) -> PocketErrandInFlight {
        PocketErrandInFlight(subject: PocketErrandCommand.bringOverSubject, recordingId: id)
    }

    // MARK: - Which row spins

    func testNothingSpinsWhenNoErrandIsRunning() {
        XCTAssertEqual(PocketErrandProgressPresentation.progress(nil, for: mine), .idle)
    }

    /// THE ONE NICK ASKED FOR.
    func testTheRecordingBeingBroughtOverIsTheOneThatSpins() {
        let progress = PocketErrandProgressPresentation.progress(bringingOver(mine), for: mine)

        XCTAssertTrue(progress.isThisRecording,
                      "the recording the owner tapped is not the one showing progress, so the "
                          + "only place a spinner can honestly go is the top of the page")
        XCTAssertEqual(progress.line, PocketBringOverPresentation.inProgressLine)
    }

    /// AND THE OTHER EIGHTEEN DO NOT. A row that spins for somebody else's transfer is a lie
    /// about where the bytes are going.
    func testAnotherRecordingsTransferDoesNotSpinThisRow() {
        let progress = PocketErrandProgressPresentation.progress(bringingOver(theirs), for: mine)

        XCTAssertFalse(progress.isThisRecording)
        XCTAssertEqual(progress,
                       .elsewhere(PocketErrandProgressPresentation
                        .anotherRecordingLine(subject: PocketErrandCommand.bringOverSubject)))
    }

    /// A CHECK IS ABOUT THE RECORDER, NOT ABOUT ANY ONE RECORDING, so no row spins for it —
    /// and it is still not `idle`, because every row's readings are being replaced while it runs.
    func testReadingTheShelfSpinsNoRowAndStillBlocksAnAction() {
        let progress = PocketErrandProgressPresentation.progress(
            PocketErrandInFlight(subject: PocketErrandCommand.shelfSubject), for: mine)

        XCTAssertFalse(progress.isThisRecording)
        XCTAssertEqual(progress.line, PocketRecorderCheckPresentation.checkingLine)
        XCTAssertTrue(progress.blocksAnAction)
    }

    /// A removal names itself rather than borrowing the transfer's sentence: what is happening
    /// to this file is the one thing the owner is watching for.
    func testARemovalSaysItIsARemoval() {
        let progress = PocketErrandProgressPresentation.progress(
            PocketErrandInFlight(subject: PocketErrandCommand.removalSubject, recordingId: mine),
            for: mine)

        XCTAssertEqual(progress, .thisRecording(PocketRemoveFromRecorderPresentation.inProgressLine))
        XCTAssertNotEqual(progress.line, PocketBringOverPresentation.inProgressLine)
    }

    // MARK: - What a busy radio says instead of greying out

    /// ONE RADIO, ONE ERRAND. Every state but idle blocks a second tap — and every one of them
    /// has a sentence, because a control that greys out without saying why is the defect this
    /// whole surface has spent the week closing.
    func testEveryBusyStateBlocksAnActionAndSaysWhy() {
        var busy: [PocketErrandProgress] = []
        for subject in PocketErrandCommand.everySubject {
            busy.append(PocketErrandProgressPresentation.progress(
                PocketErrandInFlight(subject: subject, recordingId: mine), for: mine))
            busy.append(PocketErrandProgressPresentation.progress(
                PocketErrandInFlight(subject: subject, recordingId: theirs), for: mine))
            busy.append(PocketErrandProgressPresentation.progress(
                PocketErrandInFlight(subject: subject), for: mine))
        }
        XCTAssertEqual(busy.count, 9, "the population is not the one this claim is about")
        for state in busy {
            XCTAssertTrue(state.blocksAnAction, "\(state) let a second errand be asked for")
            XCTAssertFalse(state.line?.isEmpty ?? true,
                           "\(state) blocks an action and says nothing about why")
        }
        XCTAssertFalse(PocketErrandProgress.idle.blocksAnAction)
        XCTAssertNil(PocketErrandProgress.idle.line)
    }

    /// A subject this file has never heard of is still a busy radio. It says so, and it does
    /// not guess which errand it is.
    func testAnUnknownErrandIsStillABusyRadio() {
        let progress = PocketErrandProgressPresentation.progress(
            PocketErrandInFlight(subject: "something-new", recordingId: theirs), for: mine)

        XCTAssertEqual(progress,
                       .elsewhere(PocketErrandProgressPresentation.busyWithThisRecorderLine))
    }

    /// THE POPULATION, held the way every other Pocket surface's copy is: no empty line, no
    /// brand from another product, and nothing promising a measurement nobody has taken.
    func testEveryLineIsSayableAndPromisesNothingUnmeasured() {
        let lines = PocketErrandProgressPresentation.everyLine
        XCTAssertGreaterThanOrEqual(lines.count, 8)
        for line in lines {
            XCTAssertFalse(line.isEmpty)
            XCTAssertFalse(line.contains("FoundryX"), "\(line) uses the internal name")
            for forbidden in ["free up space", "frees up", "make room", "reclaim"] {
                XCTAssertFalse(line.lowercased().contains(forbidden),
                               "\(line) promises \"\(forbidden)\", which nobody has measured")
            }
        }
    }

    // MARK: - The page about one recording

    /// Nick asked to be shown the progress WHERE HE TAPPED, so the page stays.
    func testAskingForATransferLeavesThePageAboutThatRecordingOpen() {
        XCTAssertTrue(PocketRecordingDetailAction.bringItOver.leavesThePageOpen,
                      "the page about one recording still sends the owner back to the list to "
                          + "watch a spinner that does not say which recording it is about")
    }

    /// And a removal still closes it: the page would be about a recording that is not there.
    func testARemovalStillClosesThePageAboutThatRecording() {
        XCTAssertFalse(PocketRecordingDetailAction.removeFromRecorder.leavesThePageOpen)
    }

    /// The rule is total over the actions this page can offer.
    func testEveryActionHasAnAnswer() {
        XCTAssertEqual(PocketRecordingDetailAction.allCases.count, 2)
    }
}
