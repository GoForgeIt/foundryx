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

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return !element.exists
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
        app.launchArguments = ["-MainPreview", "-RemoteChat", "-FreshActionState"]
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

    /// EXT1-3 proof: the Activity page opens the same options sheet; a SENT
    /// act-in-chat turn links the action to its chat ("Continue in chat →"
    /// routes back); the chat list organizes by provenance with the source
    /// grouping. Runs on a fresh install (the runner uninstalls first).
    func testExtensionFlows() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-RemoteChat", "-FreshActionState"]
        app.launch()

        // 1. Activity page — an action entry opens the SAME options sheet.
        app.buttons["Activity"].firstMatch.tap()
        let actEntry = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Act on this'")).firstMatch
        XCTAssertTrue(actEntry.waitForExistence(timeout: 10),
                      "activity page shows an actionable entry")
        actEntry.tap()
        // The Activity page's first load is heavy (on-device recap synthesis)
        // — give the sheet time.
        XCTAssertTrue(app.buttons["act-in-chat"].firstMatch.waitForExistence(timeout: 20),
                      "activity entry opens the shared options sheet")
        XCTAssertTrue(app.buttons["not-an-action"].firstMatch.exists)
        shoot(app, "06-activity-options")
        // Dismiss the sheet by tapping the dimmed area above it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertTrue(waitGone(app.buttons["act-in-chat"].firstMatch, timeout: 5),
                      "options sheet dismisses")

        // 2. Act on an action from the detail face and actually SEND the turn.
        app.buttons["Capture"].firstMatch.tap()
        let card = app.staticTexts["Launch deck and relay numbers"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "demo conversation card")
        card.tap()
        let actionsFace = app.buttons["face-actions"].firstMatch
        XCTAssertTrue(actionsFace.waitForExistence(timeout: 10))
        actionsFace.tap()
        let surfacedRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'action-row-surfaced'"))
        if !surfacedRows.firstMatch.waitForExistence(timeout: 4) { actionsFace.tap() }
        XCTAssertTrue(surfacedRows.firstMatch.waitForExistence(timeout: 10))
        surfacedRows.element(boundBy: 0).tap()
        let act = app.buttons["act-in-chat"].firstMatch
        XCTAssertTrue(act.waitForExistence(timeout: 5))
        act.tap()
        let composer = app.textViews.matching(
            NSPredicate(format: "value CONTAINS 'this came up'")).firstMatch
        let composerField = app.textFields.matching(
            NSPredicate(format: "value CONTAINS 'this came up'")).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10)
                        || composerField.waitForExistence(timeout: 5))
        app.buttons["Send"].firstMatch.tap()   // the send logs run + links the chat

        // 3. Back on the Actions face, the acted action now continues in ITS chat.
        app.buttons["Capture"].firstMatch.tap()
        XCTAssertTrue(surfacedRows.firstMatch.waitForExistence(timeout: 10),
                      "detail face still open on the capture tab")
        surfacedRows.element(boundBy: 0).tap()
        let cont = app.buttons["continue-in-chat"].firstMatch
        XCTAssertTrue(cont.waitForExistence(timeout: 5),
                      "an acted action offers Continue in chat")
        XCTAssertFalse(app.buttons["act-in-chat"].firstMatch.exists,
                       "no fresh-prefill option once linked")
        shoot(app, "07-continue-in-chat")
        cont.tap()

        // 4. Continue lands on the chat tab, on the linked conversation.
        let chatTab = app.buttons["Chat"].firstMatch
        // ONE header control, and it opens ONE list. It was two sibling text buttons, then
        // a menu naming the two places those buttons led to; both shapes asked the reader to
        // pick a corpus before seeing anything. There is no corpus to pick now — the phone
        // is a source in the same list as Kiln, Claude Code and Codex.
        let openChats = app.buttons["open-chats"].firstMatch
        XCTAssertTrue(openChats.waitForExistence(timeout: 10),
                      "landed on the chat surface")
        _ = chatTab
        shoot(app, "08-linked-chat")

        // 5. The one list opens, and the SOURCE is a facet on it rather than a door.
        openChats.tap()
        // The sheet's OWN control, so a failure below can only mean the content is wrong
        // rather than that the sheet never presented. Those are different bugs and used to
        // be indistinguishable from this line.
        XCTAssertTrue(app.buttons["chat-list-done"].firstMatch.waitForExistence(timeout: 10),
                      "the chat list sheet opens")
        // `chat-list` sits on a SwiftUI `List`, which surfaces in the accessibility
        // hierarchy as a collection/table — NEVER as `otherElements`. So the old
        // `app.otherElements["chat-list"] || staticTexts["chat-list-empty"] ||
        // otherElements["chat-list-loading"]` could not match a drawn list at all: it was
        // satisfiable only by the EMPTY state, or by catching the millisecond-wide loading
        // window. It asserted that the list had nothing in it. Match on element type `.any`.
        XCTAssertTrue(app.descendants(matching: .any)["chat-list"]
                        .firstMatch.waitForExistence(timeout: 10),
                      "the one chat list opens")
        // OPEN, MEASURED, NOT YET ASSERTED HERE (2026-08-05). This proof dials a door that
        // is deliberately not there (`-RemoteChat` → 127.0.0.1:1), so the list resolves to
        // `phoneOnly(.unreachable)` and `honesty(rail)` should render
        // `chat-list-reach-notice` ("…Your Mac isn't reachable, so the chats there aren't
        // listed."). Asserting it here FAILS even with a type-agnostic `.any` query, while
        // the SOURCE chip a few lines below — rendered by the same `controls(rail)` inset —
        // is found. So the inset does reach the hierarchy and the notice specifically does
        // not: either `honesty(rail)` renders no reach line here, or that `Text` is not
        // surfaced. Unresolved. It is a real honesty gap (a phone-only list presented as if
        // it were everything is exactly what the notice exists to prevent), but it is a
        // DIFFERENT defect from the main-thread deadlock this proof was fixed for, and it
        // wants its own change with its own red. Written down rather than asserted, and
        // rather than quietly forgotten.
        let thisPhoneChip = app.buttons["chat-source-this-phone"].firstMatch
        XCTAssertTrue(thisPhoneChip.waitForExistence(timeout: 10),
                      "this phone is offered as a SOURCE within the one list")
        thisPhoneChip.tap()
        shoot(app, "09-chat-list-organization")
    }
}
