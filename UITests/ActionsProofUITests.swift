// ActionsProofUITests — the simulator interaction proof for the Actions-face
// options flow (track 20260715T1500 addendum): drives the REAL app over the
// demo-seeded library (`-MainPreview`) by accessibility identifier and attaches
// the proof screenshots (action list → options sheet → not-an-action comment →
// rejected state → act-in-chat composer prefill) to the .xcresult.

import XCTest

final class ActionsProofUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testActionOptionsFlow() throws {
        let app = XCUIApplication()
        // -RemoteChat mounts the computer-tier chat surface so the composer
        // prefill is visible in the simulator (the phone-tier surface hides its
        // composer behind the Apple Intelligence gate).
        app.launchArguments = ["-MainPreview", "-RemoteChat"]
        app.launch()

        // 1. Open the demo conversation that carries seeded action candidates.
        let card = app.staticTexts["Launch deck and relay numbers"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "demo conversation card")
        card.tap()

        // 2. Switch to the Actions face (re-tap once if the first tap landed
        // during the push transition).
        let actionsFace = app.buttons["face-actions"].firstMatch
        XCTAssertTrue(actionsFace.waitForExistence(timeout: 10), "Actions face switch")
        actionsFace.tap()

        let surfacedRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'action-row-surfaced'"))
        if !surfacedRows.firstMatch.waitForExistence(timeout: 4) {
            actionsFace.tap()
        }
        XCTAssertTrue(surfacedRows.firstMatch.waitForExistence(timeout: 10),
                      "surfaced action rows render")
        XCTAssertGreaterThanOrEqual(surfacedRows.count, 2, "both seeded actions render")
        shoot(app, "01-actions-list")

        // 3. Tap the first action → the options sheet.
        surfacedRows.element(boundBy: 0).tap()
        let notAnAction = app.buttons["not-an-action"].firstMatch
        XCTAssertTrue(notAnAction.waitForExistence(timeout: 5), "options sheet opens on tap")
        XCTAssertTrue(app.buttons["act-in-chat"].firstMatch.exists, "act-in-chat offered")
        XCTAssertTrue(app.buttons["refine-action"].firstMatch.exists, "refine offered")
        shoot(app, "02-options-sheet")

        // 4. Not an action, with a comment.
        notAnAction.tap()
        let comment = app.textFields["feedback-comment"].firstMatch
        XCTAssertTrue(comment.waitForExistence(timeout: 5), "comment entry appears")
        comment.tap()
        comment.typeText("That was just small talk, nothing to do")
        shoot(app, "03-not-an-action-comment")
        app.buttons["confirm-feedback"].firstMatch.tap()

        // 5. The row now reads "Not an action" (the status word folds into the
        // row button's accessibility label).
        let rejected = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'action-row-surfaced' AND label CONTAINS 'Not an action'"
        )).firstMatch
        XCTAssertTrue(rejected.waitForExistence(timeout: 5), "row state flips to Not an action")
        shoot(app, "04-rejected-state")

        // 6. Act on the second action in chat → composer prefilled, not sent.
        surfacedRows.element(boundBy: 1).tap()
        let act = app.buttons["act-in-chat"].firstMatch
        XCTAssertTrue(act.waitForExistence(timeout: 5), "options sheet on the second row")
        act.tap()

        let prefilled = app.textViews.matching(
            NSPredicate(format: "value CONTAINS 'this came up'")).firstMatch
        let prefilledField = app.textFields.matching(
            NSPredicate(format: "value CONTAINS 'this came up'")).firstMatch
        XCTAssertTrue(prefilled.waitForExistence(timeout: 10)
                        || prefilledField.waitForExistence(timeout: 5),
                      "chat composer is prefilled with the action's context")
        shoot(app, "05-chat-prefill")
    }
}
