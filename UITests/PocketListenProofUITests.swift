// PocketListenProofUITests — THE SIMULATOR PROOF FOR STEP 9.
//
// WHAT IT READS. The REAL app, over a library `DemoSeed` seeded THIS launch: a `pkt-` capture
// whose original MP3 sits in this account's `pocket-recordings` custody with the receipt that
// ties it to the conversation. There is no door in this environment — nothing is listening on
// the demo target — so a recording that still asked a computer for its audio cannot play here
// at all. That is the point: the same simulator, the same absent computer, two conversations,
// two different outcomes.
//
// THE PAIRED CASE IS NOT DECORATION. `testAPhoneMadeRecordingStillNeedsTheComputer` is what
// stops the first test passing for the wrong reason. If Listen had simply stopped calling the
// door for EVERYTHING, or if the demo target happened to be reachable, that test goes red.
//
// The only hook it uses (`-MainPreview`, the demo library) is DEBUG-only and is compiled out
// of a shipping build by the leak gate. Navigation is the shipped route: tap the card.

import XCTest

final class PocketListenProofUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Every line of the three-places row, by the identifier the view sets on the stack.
    private func placeLines(_ app: XCUIApplication) -> [XCUIElement] {
        app.staticTexts.matching(identifier: "where-this-recording-is").allElementsBoundByIndex
    }

    /// OPEN A CONVERSATION THE WAY A PERSON DOES: launch, find its card in the list, tap it.
    ///
    /// NOT via the `-Screen detail -Capture <id>` deep link, which is what this proof was written
    /// against first. That link raises a `fullScreenCover` from `CaptureScreen.onAppear`, and it
    /// silently does nothing when the app comes up over a container a previous proof in the same
    /// lane left behind: both tests passed in isolation after an uninstall and both failed inside
    /// the uiproof lane with "the detail opened" — the app was up and idle, on the list, and no
    /// cover ever appeared. Tapping the card is the route the shipped app has, so it does not
    /// depend on which proof ran before this one.
    ///
    /// `-FreshActionState` IS LOAD-BEARING, and it is the same argument
    /// `RecordingDeviceProofUITests` carries for the same reason. `PlaceRestoreProofUITests` runs
    /// immediately before this suite in the uiproof lane and its whole subject is that the app
    /// COMES BACK to the tab and conversation you left — a durable `AppPlacementStore` record in
    /// a container that survives between runs. Without this reset the app relaunches onto that
    /// restored place and the conversation list is not on screen at all: measured, the card was
    /// missing for the full 45 s while the very next suite found the same card in 4.7 s.
    private func openConversation(titled title: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-FreshActionState"]
        app.launch()
        let card = app.staticTexts[title]
        XCTAssertTrue(card.waitForExistence(timeout: 45), "the card '\(title)' is in the list")
        card.tap()
        return app
    }

    /// THE OUTCOME OF THIS STEP, ON A SCREEN: a recording that came off a recorder plays with
    /// no computer reachable, and its row states all three places at once.
    func testARecordingFromARecorderPlaysWithNoComputerAndSaysWhereItIs() throws {
        let app = openConversation(titled: "Walk to the trailhead")

        XCTAssertTrue(app.buttons["Listen"].waitForExistence(timeout: 45), "the detail opened")
        // SwiftUI pushes an `accessibilityIdentifier` set on a stack down onto its CHILDREN, so
        // the row is five identified static texts rather than one identified container. The
        // count is asserted (not merely `> 0`) because that is what makes the paired case's
        // `== 0` on the same query mean something.
        XCTAssertEqual(placeLines(app).count, 5,
                       "the plays-here line, the three places and the kept-here line render "
                           + "for a recording that came off a recorder")

        // ALL THREE PLACES, EACH WITH ITS OWN AGE, and the one nobody asked about reading
        // `Unknown` rather than a confident `No`.
        XCTAssertTrue(app.staticTexts["On the recorder: Unknown - never checked"].exists,
                      "a place nobody asked about reads unknown, aged 'never checked'")
        XCTAssertTrue(app.staticTexts["On this iPhone: Yes - just now"].exists,
                      "the phone answered yes, just now")
        XCTAssertTrue(app.staticTexts["Safe elsewhere: Yes - just now"].exists,
                      "the confirmed-in-library recording reads safe elsewhere")
        // THE STANDING TRADE, ON THE SURFACE.
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "Freeing that space isn't")
            ).firstMatch.exists,
            "the row says Solleva keeps the original here and cannot free that space yet")
        shoot(app, "01-three-places-on-a-brought-over-recording")

        // AND IT PLAYS. No door exists in this environment; the scrubber appearing means the
        // bytes came off this phone.
        app.buttons["Listen"].tap()
        XCTAssertTrue(app.sliders["listen-scrubber"].waitForExistence(timeout: 15),
                      "the recorder's own file played from this phone, with no computer")
        XCTAssertFalse(app.staticTexts["Can't reach your computer"].exists,
                       "a recording on this iPhone was blamed on a computer that was never asked")
        XCTAssertFalse(app.staticTexts["Couldn't play this recording"].exists,
                       "the held file did not decode")
        shoot(app, "02-playing-from-this-phone-with-no-computer")
        app.terminate()
    }

    /// THE PAIRED CASE. A conversation this phone recorded still needs the computer, and in
    /// this environment there isn't one — so it says so. Without this, the test above would
    /// pass just as well if Listen had stopped calling the door for everything, or if the demo
    /// target were quietly reachable.
    func testAPhoneMadeRecordingStillNeedsTheComputer() throws {
        let app = openConversation(titled: "Launch deck and relay numbers")

        XCTAssertTrue(app.buttons["Listen"].waitForExistence(timeout: 45), "the detail opened")
        XCTAssertEqual(placeLines(app).count, 0,
                       "a conversation this phone made has one home, and no three-place row")

        app.buttons["Listen"].tap()
        let unreachable = app.staticTexts["Can't reach your computer"]
        let pruned = app.staticTexts["Audio no longer available"]
        XCTAssertTrue(unreachable.waitForExistence(timeout: 20) || pruned.exists,
                      "a phone-made recording still asks the computer, and says so when it "
                          + "cannot be reached")
        XCTAssertFalse(app.sliders["listen-scrubber"].exists,
                       "nothing played — there is no computer in this environment, which is "
                           + "what makes the pocket recording's playback meaningful")
        shoot(app, "03-a-phone-made-recording-still-needs-the-computer")
        app.terminate()
    }
}
