// RecorderPageProofUITests — the simulator proof for the RECORDER PAGE.
//
// WHY IT DID NOT EXIST, AND WHY IT DOES NOW
// -----------------------------------------
// `phase_uiproof` photographs the recording surface, the Omi ambient flow, the foreground
// restore, the actions list, the deletion choice, the vault funnel, the place restore and the
// device LIST. It has never photographed the page a person opens to look at what their recorder
// is holding — because reaching it in life needs a remembered record-then-sync recorder in the
// account's store, a Bluetooth radio, and the recorder on the desk. So the one screen in this
// app that cannot be reached without hardware was also the one screen no build could see, and
// "never ship UI without simulator proof" was, right there, a habit rather than a gate.
//
// Mounted via the registered `-Screen recorder <state>` seam, for the same reason
// `-Screen deletionChoice` exists: the real path needs state a simulator cannot produce, and
// adding a radio bypass to reach one screen would be a worse trade than mounting the screen.
//
// WHAT THIS PROVES, AND WHAT IT DOES NOT
// --------------------------------------
// It proves the shipped `RecordingDevicePageView` BUILT AND RENDERED in each of its states, and
// it leaves a picture of each one in the build. It does not prove any of it is correct — the
// values in the picture are `RecordingDevicePage` / `PocketRecorderCheckPresentation` /
// `StoredFileDevicePresentation` outputs, and Brine holds those. Pixels and presentation are
// different claims and this file makes only the first.
//
// THE STATE NAMES ARE DUPLICATED HERE ON PURPOSE, and the duplication is held: a UI test target
// cannot import the app, so it cannot read `RecorderPageProofState`. `RecorderPageRenderedFeature
// Tests` derives the states from that enum and fails if this list drifts from it, which is the
// only arrangement where the copy cannot rot silently.

import XCTest

final class RecorderPageProofUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The advertised name of the fixture recorder — Nick's own unit, the one these frames were
    /// read off. It is the page's navigation title, and it renders from nothing else, so it is
    /// how this test knows it photographed the recorder page rather than the app's front door.
    private static let deviceName = "PKT01_BLUE_26079bc5"

    /// THE THREE ROWS THE FIXTURE SEEDS, ADDRESSED THE WAY THE RECORDER ADDRESSES THEM.
    ///
    /// These are `RecorderPageProofFixture.recordings` spelled as `<date>/<timestamp>` — the
    /// identifier the row carries. Duplicated here for the same reason the state names are: a
    /// UI test target cannot import the app.
    ///
    /// The first two are on the recorder and nowhere Solleva has proved; the third is the one
    /// the fixture marks safe elsewhere. So the two directions of the safety gate are two
    /// different rows on one screen, and each is asserted on its own page.
    private static let unprovenRowID = "2026-08-11/PH260811175026"
    private static let provenRowID = "2026-08-07/20260807093015"
    private static let removeAction = "Remove it from the recorder"

    /// A row, however the accessibility tree happens to type a combined element.
    private func row(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let button = app.buttons[identifier].firstMatch
        if button.exists { return button }
        return app.otherElements[identifier].firstMatch
    }

    /// THE OPEN SHEET, AS A CONTAINER TO ASK QUESTIONS OF.
    ///
    /// MEASURED, NOT PRECAUTIONARY. iOS keeps the presenting page in the accessibility tree
    /// underneath a sheet. The first version of this test asked the APPLICATION whether
    /// "Bring over" was on screen while the page about a recording this phone already holds was
    /// open, and it was — because the SHELF's own bring-over control was still there behind it.
    /// The assertion measured the wrong element and reported it as a defect in the page. Every
    /// claim about what the opened page offers is scoped here.
    private func sheet(_ app: XCUIApplication) -> XCUIElement {
        // SwiftUI decides for itself what element type a modified `ScrollView` becomes, and it
        // is not the same answer on every OS. The identifier is the claim; the type is not.
        let anywhere = app.descendants(matching: .any)
            .matching(identifier: "recording-detail-sheet").firstMatch
        if anywhere.exists { return anywhere }
        return app.otherElements["recording-detail-sheet"].firstMatch
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Launch one state of the recorder page and prove the page — not a fallback — is on screen.
    @discardableResult
    private func open(_ state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-Screen", "recorder", state]
        app.launch()

        let title = app.navigationBars[Self.deviceName].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 60),
                      "-Screen recorder \(state) did not land on the recorder page")

        // THE PAGE'S BODY ACTUALLY BUILT. A navigation title can render over a body that threw,
        // so the status line — which comes from `RecordingDevicePage.resolve` and exists on no
        // other screen — is asserted too.
        XCTAssertTrue(app.staticTexts["recording-device-status"].waitForExistence(timeout: 10),
                      "the recorder page rendered a title over a body that did not build")
        return app
    }

    // MARK: - the three states

    func testTheRecorderPageRendersInEveryStateItCanBeIn() throws {
        // NEVER ASKED. The shelf draws nothing until the owner asks, and the action that asks
        // is on screen.
        let resting = open("neverAsked")
        XCTAssertTrue(resting.buttons["Connect and check now"].firstMatch.exists,
                      "the resting recorder page offers no way to ask the recorder anything")
        XCTAssertFalse(resting.staticTexts["On the recorder"].firstMatch.exists,
                       "the shelf drew itself before the owner asked for it")
        shoot(resting, "recorder-page-01-never-asked")
        resting.terminate()

        // ERRAND RUNNING. The radio is busy and the page says which errand it is — not
        // "Syncing", not "Downloading", because nothing is coming over.
        let running = open("errandRunning")
        XCTAssertTrue(running.staticTexts["Checking the recorder…"].firstMatch
                        .waitForExistence(timeout: 10),
                      "the running errand is not named on screen")
        shoot(running, "recorder-page-02-errand-running")
        running.terminate()

        // SHELF ANSWERED. What the recorder is holding, with both custody labels — one file
        // this phone can prove it holds, and the rest only on the recorder.
        let answered = open("shelfAnswered")
        XCTAssertTrue(answered.staticTexts["On the recorder"].firstMatch
                        .waitForExistence(timeout: 10),
                      "the answered shelf has no section on screen")
        XCTAssertTrue(answered.buttons["Bring over"].firstMatch.exists
                        || answered.staticTexts["Bring over"].firstMatch.exists,
                      "the answered shelf offers nothing to bring over")
        // EVERY ROW IS SOMETHING A PERSON CAN PRESS.
        //
        // THE DEFECT THIS REPLACES, and it was measured on Nick's own unit. The row's only
        // interactive element was "Remove it from the recorder", drawn behind
        // `PocketRemoveFromRecorderPresentation.isOffered` — false for all nineteen of his
        // recordings, because nothing has ever been brought off that recorder. So the shipped
        // page had nineteen rows and not one thing a finger could do. This asserts the row
        // itself, addressed by the recorder's own name for the file.
        let unproven = row(answered, Self.unprovenRowID)
        let proven = row(answered, Self.provenRowID)
        XCTAssertTrue(unproven.waitForExistence(timeout: 10),
                      "the row for \(Self.unprovenRowID) is not something the accessibility "
                        + "tree offers as a control — a row nobody can press is a readout")
        XCTAssertTrue(proven.exists,
                      "the row for \(Self.provenRowID) is not a control")
        // AND THE DESTRUCTIVE CONTROL IS NOT ON THE LIST AT ALL ANY MORE. It belongs to the
        // page about one recording; leaving it here as well would be two ways to do the one
        // gesture that cannot be undone.
        XCTAssertEqual(answered.buttons.matching(identifier: Self.removeAction).count, 0,
                       "the removal is still drawn on the list of recordings")
        shoot(answered, "recorder-page-03-shelf-answered")

        // THE CONTROL. The same query family must NOT match text no screen renders, or every
        // assertion above would pass on a blank page.
        XCTAssertFalse(answered.navigationBars["PKT01_BLUE_NOT_A_RECORDER"].exists,
                       "the navigation-bar query matches a title nothing renders, so this "
                           + "proof cannot fail")
        answered.terminate()
    }

    // MARK: - the page about one recording

    /// A ROW IS SOMETHING YOU PRESS, AND WHAT IT OPENS IS ABOUT THAT ONE RECORDING.
    ///
    /// IT IS ITS OWN LAUNCH, AND THAT IS NOT TIDINESS. Measured: appended to the end of the
    /// three-state proof, this sequence took the run past ~20 seconds on one app instance, and
    /// at that point the mounted page was replaced by the app's sign-in screen — the row tap
    /// landed, the sheet opened, and by the time the next query ran the surface underneath had
    /// gone. The dump in the failure said so in full. A proof whose verdict depends on how fast
    /// the machine got through the assertions before it is not a gate, so this one starts from
    /// its own launch and does its work first.
    func testARowOpensThePageAboutThatOneRecording() throws {
        let answered = open("shelfAnswered")
        XCTAssertTrue(row(answered, Self.provenRowID).waitForExistence(timeout: 20),
                      "the answered shelf drew no row to press")

        // THE PAGE ABOUT ONE RECORDING — the recording the fixture marks safe elsewhere.
        row(answered, Self.provenRowID).tap()
        XCTAssertTrue(sheet(answered).waitForExistence(timeout: 10),
                      "pressing a row opened nothing. What is on screen:\n"
                        + answered.debugDescription)
        let opened = sheet(answered)
        XCTAssertTrue(opened.staticTexts["Where this recording is"].firstMatch.exists,
                      "the opened page does not head the three places")
        XCTAssertTrue(opened.staticTexts.matching(
                        NSPredicate(format: "label BEGINSWITH %@", "On the recorder:")).count > 0,
                      "the page about one recording does not state where it is")
        // THE GATE, DIRECTION ONE: this recording IS proven elsewhere, so the removal is here.
        XCTAssertTrue(opened.buttons[Self.removeAction].firstMatch.exists,
                      "the recording the fixture marks safe elsewhere is not offered removal — "
                        + "the affordance is unreachable")
        // …and the transfer is NOT, because this phone already holds it.
        XCTAssertFalse(opened.buttons["Bring over"].firstMatch.exists,
                       "a recording this phone already holds is offered a second transfer")
        XCTAssertTrue(opened.staticTexts[
            "Solleva already has this recording, so there\'s nothing to bring over."]
                        .firstMatch.exists,
                      "the withheld transfer is withheld in silence")
        shoot(answered, "recorder-page-04-one-recording-proven-elsewhere")

        // AND IT ASKS FIRST. Tapping used to compose the removal immediately, while FORGET —
        // which destroys a key and no audio — sat behind an alert.
        opened.buttons[Self.removeAction].firstMatch.tap()
        XCTAssertTrue(answered.buttons["Take it off the recorder"].firstMatch
                        .waitForExistence(timeout: 10),
                      "the destructive tap did not ask first — the confirmation written to "
                        + "guard it has no call site")
        shoot(answered, "recorder-page-05-removal-confirmation")
        answered.buttons["Keep it on the recorder"].firstMatch.tap()
        // THE CLOSE IS IN THE NAVIGATION BAR, WHICH IS NOT INSIDE THE SCROLLING BODY. Scoping
        // this one to the sheet element found no match — the toolbar is the sheet's sibling in
        // the tree, not its child.
        answered.buttons["Done"].firstMatch.tap()

        // THE GATE, DIRECTION TWO, ON A DIFFERENT ROW OF THE SAME SCREEN. A proof where every
        // row answers the same way cannot tell a working predicate from a deleted `if`.
        XCTAssertTrue(row(answered, Self.unprovenRowID).waitForExistence(timeout: 10),
                      "the sheet did not close, so the second row cannot be opened")
        row(answered, Self.unprovenRowID).tap()
        XCTAssertTrue(sheet(answered).waitForExistence(timeout: 10),
                      "the second row opened nothing")
        let second = sheet(answered)
        XCTAssertTrue(second.staticTexts["Where this recording is"].firstMatch.exists,
                      "the second row's page does not head the three places")
        XCTAssertFalse(second.buttons[Self.removeAction].firstMatch.exists,
                       "a recording Solleva has not proved it holds anywhere else is offered "
                        + "removal — Nick's ruling is that the affordance does not exist for a "
                        + "recording we have not brought over")
        XCTAssertTrue(second.staticTexts[
            "Solleva hasn't confirmed a copy of this anywhere else yet, so it won't take it "
            + "off the recorder."].firstMatch.exists,
                      "the withheld action is withheld in silence, which is the half of the "
                        + "row's rule that was missing")
        XCTAssertTrue(second.buttons["Bring over"].firstMatch.exists,
                      "the owner cannot ask for THIS recording, which is the whole gap")
        shoot(answered, "recorder-page-06-one-recording-not-proven-elsewhere")
        answered.buttons["Done"].firstMatch.tap()

        // THE CONTROL. The row query must NOT match an identifier no row carries, or "every
        // row is a control" cannot fail.
        XCTAssertFalse(row(answered, "2026-01-01/00000000000000").exists,
                       "the row query matches an identifier no row carries, so \"every row is "
                        + "a control\" cannot fail")
        answered.terminate()
    }

    /// THE CONTROLS COME BEFORE THE LIST, MEASURED ON A REAL RENDER.
    func testEveryControlIsDrawnAboveTheListOfRecordings() throws {
        let answered = open("shelfAnswered")
        // THE ANCHOR IS THE ROW ITSELF, and it had to become one. This test used to measure
        // against "Remove it from the recorder", which lived INSIDE a row — a perfectly good
        // anchor while it existed, and it existed only for a recording Solleva had proved it
        // holds elsewhere. The row is now the control, addressed by the recorder's own name for
        // the file, so the anchor is present for EVERY recording rather than for the one the
        // fixture happens to mark safe.
        let firstRow = row(answered, Self.unprovenRowID)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20),
                      "the answered shelf drew no row, so there is no list to be above")

        // MEASURED ON A REAL RENDER RATHER THAN READ OUT OF THE SOURCE.
        //
        // `RecorderPageLayout` decides the order and Brine holds it, but a decision the page
        // walks is still only a decision until something LOOKS. This is the look: every control
        // that acts on what the recorder is holding must be drawn above the first row of the
        // list of it.
        //
        // WHY A FRAME COMPARISON AND NOT `isHittable`. A control can be on screen because the
        // simulator is tall and the fixture has three rows — Nick's recorder had nineteen. A
        // viewport test would pass on the old layout on this hardware and fail on his, which is
        // the opposite of a gate. Y-ORDER IS SIZE-INDEPENDENT.
        let bringOverButton = answered.buttons["Bring over"].firstMatch
        if bringOverButton.exists && firstRow.exists {
            XCTAssertLessThan(bringOverButton.frame.maxY, firstRow.frame.minY,
                              "the bring-over control is drawn at y=\(bringOverButton.frame.minY)"
                                + " and a row of the list at y=\(firstRow.frame.minY) — the "
                                + "control is INSIDE or BELOW the list, so how far a person "
                                + "scrolls to reach it is decided by how full their recorder is")
        } else {
            XCTFail("the answered page renders no bring-over button and no row button, so the "
                        + "order of the two cannot be measured and this proof cannot fail")
        }
        shoot(answered, "recorder-page-07-controls-above-the-list")

        // AND A PICTURE OF THE LIST ITSELF, which is now below the fold precisely BECAUSE the
        // controls are above it.
        var swipes = 0
        while !row(answered, Self.provenRowID).isHittable, swipes < 6 {
            answered.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row(answered, Self.provenRowID).isHittable,
                      "the list of recordings could not be reached by scrolling at all, so no "
                          + "picture of a row can be taken and this proof cannot fail")
        shoot(answered, "recorder-page-08-the-list-of-recordings")
        answered.terminate()
    }
}
