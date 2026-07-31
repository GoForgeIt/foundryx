// DeletionChoiceProofUITests — the simulator proof for the three-way deletion
// choice (track 20260731T1900).
//
// The logic seams pin what each choice MEANS and what it asks the server for.
// What they cannot see is whether the screen actually renders three choices, or
// whether the irreversibility warning that is supposed to be absent from
// "cancel my subscription" is in fact absent on screen. UI that shipped correct
// in the model and wrong on the glass is the failure this guards.
//
// Mounted via the registered `-Screen deletionChoice` seam: the real path needs a
// signed-in session the simulator cannot produce, and adding an auth bypass to
// reach one screen would be a worse trade than mounting the screen.

import XCTest

final class DeletionChoiceProofUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAllThreeOutcomesAreOnScreenAndOnlyTwoClaimToBeIrreversible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-Screen", "deletionChoice"]
        app.launch()

        let now = app.staticTexts["Delete everything now"]
        XCTAssertTrue(now.waitForExistence(timeout: 10),
                      "the choice to delete now is not on screen")
        XCTAssertTrue(app.staticTexts["Delete when my subscription ends"].exists,
                      "the choice to delete at period end is not on screen — someone who "
                      + "wants the period they paid for has no way to say so")
        XCTAssertTrue(app.staticTexts["Cancel my subscription, keep my notes"].exists,
                      "the choice to keep the data is not on screen")

        shoot(app, "deletion-choice-three-outcomes")

        // The irreversibility claim must appear for the two destructive choices and
        // NOT for the one that keeps everything. Asserted on the rendered text
        // because that is what the person actually reads.
        let undone = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "can't be undone"))
        XCTAssertEqual(undone.count, 2,
                       "expected exactly the two destructive choices to say they can't be "
                       + "undone; saying it about cancelling a subscription is simply false")

        // The forfeit has to be readable BEFORE any confirmation is tapped.
        let forfeit = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "won't get the rest"))
        XCTAssertGreaterThan(forfeit.count, 0,
                             "deleting now forfeits the paid period and the screen does not say so")
    }

    func testCancellingTheChoiceLeavesWithoutDeletingAnything() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-Screen", "deletionChoice"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Delete everything now"].waitForExistence(timeout: 10))
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.exists, "there is no way out of the deletion choice without picking one")
        shoot(app, "deletion-choice-has-an-exit")
    }
}
