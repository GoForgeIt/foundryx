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
        // THE DESTRUCTIVE AFFORDANCE, PHOTOGRAPHED, AND ITS GATE PROVEN IN BOTH DIRECTIONS.
        //
        // The fixture seeds THREE recordings and marks exactly ONE of them safe elsewhere. So
        // the count is the assertion: "Remove it from the recorder" must appear once — not
        // three times (the gate is not reading the predicate) and not zero (the gate is
        // refusing everything, which a deleted button also achieves). Until this shipped,
        // `PocketRemoveFromRecorderPresentation.isOffered` — the function enforcing the
        // ruling's "the affordance does not exist for a recording we have not brought over" —
        // had no test anywhere and its only call site was a bare `if` in a SwiftUI body.
        let removeAction = "Remove it from the recorder"
        XCTAssertTrue(answered.buttons[removeAction].firstMatch.waitForExistence(timeout: 10)
                        || answered.staticTexts[removeAction].firstMatch.exists,
                      "no row offers to be taken off the recorder, on a shelf whose fixture "
                        + "marks one recording safe elsewhere — the affordance is unreachable")
        let offered = answered.buttons.matching(identifier: removeAction).count
                    + answered.staticTexts.matching(identifier: removeAction).count
        XCTAssertEqual(offered, 1,
                       "\(offered) of the three seeded rows offer the removal. Exactly one is "
                        + "marked safe elsewhere, so any other number means the affordance is "
                        + "not reading the safety predicate it is supposed to be gated on")
        shoot(answered, "recorder-page-03-shelf-answered")

        // AND THE CONFIRMATION IT NOW OPENS. Tapping used to compose the removal immediately,
        // while FORGET — which destroys a key and no audio — sat behind an alert.
        let removeButton = answered.buttons[removeAction].firstMatch
        if removeButton.exists {
            removeButton.tap()
            XCTAssertTrue(answered.buttons["Take it off the recorder"].firstMatch
                            .waitForExistence(timeout: 10),
                          "the destructive tap did not ask first — the confirmation written to "
                            + "guard it has no call site")
            shoot(answered, "recorder-page-04-removal-confirmation")
            answered.buttons["Keep it on the recorder"].firstMatch.tap()
        }

        // THE CONTROL. The same query family must NOT match text no screen renders, or every
        // assertion above would pass on a blank page.
        XCTAssertFalse(answered.navigationBars["PKT01_BLUE_NOT_A_RECORDER"].exists,
                       "the navigation-bar query matches a title nothing renders, so this "
                           + "proof cannot fail")
        answered.terminate()
    }

    /// THE CONTROLS COME BEFORE THE LIST, MEASURED ON A REAL RENDER.
    func testEveryControlIsDrawnAboveTheListOfRecordings() throws {
        let answered = open("shelfAnswered")
        let removeAction = "Remove it from the recorder"
        // Wait for the shelf itself, so the frames below are measured on a laid-out page.
        XCTAssertTrue(answered.buttons[removeAction].firstMatch.waitForExistence(timeout: 20),
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
        // the opposite of a gate. Y-ORDER IS SIZE-INDEPENDENT: the removal button lives INSIDE
        // a shelf row, so "the bring-over sits above it" is exactly the claim, at any length.
        // Measured against the old layout, where `bringOver` was written after the row
        // `ForEach`: this assertion is the one that fails.
        let bringOverButton = answered.buttons["Bring over"].firstMatch
        let rowButton = answered.buttons[removeAction].firstMatch
        if bringOverButton.exists && rowButton.exists {
            XCTAssertLessThan(bringOverButton.frame.maxY, rowButton.frame.minY,
                              "the bring-over control is drawn at y=\(bringOverButton.frame.minY)"
                                + " and a row of the list at y=\(rowButton.frame.minY) — the "
                                + "control is INSIDE or BELOW the list, so how far a person "
                                + "scrolls to reach it is decided by how full their recorder is")
        } else {
            XCTFail("the answered page renders no bring-over button and no row button, so the "
                        + "order of the two cannot be measured and this proof cannot fail")
        }
        shoot(answered, "recorder-page-05-controls-above-the-list")

        // AND A PICTURE OF THE LIST ITSELF, which is now below the fold precisely BECAUSE the
        // controls are above it. Without this the one band this change reshaped hardest — the
        // row, which went from four stacked lines about where a recording is to one — would
        // ship in no photograph at all, which is the exact hole this whole proof exists to
        // close.
        var swipes = 0
        while !answered.buttons[removeAction].firstMatch.isHittable, swipes < 6 {
            answered.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(answered.buttons[removeAction].firstMatch.isHittable,
                      "the list of recordings could not be reached by scrolling at all, so no "
                          + "picture of a row can be taken and this proof cannot fail")
        shoot(answered, "recorder-page-06-the-list-of-recordings")
        answered.terminate()
    }
}
