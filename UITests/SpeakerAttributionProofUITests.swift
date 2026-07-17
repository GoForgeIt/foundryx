// SpeakerAttributionProofUITests — the simulator proof for action speaker
// attribution (features/action-speaker-attribution.feature): drives the REAL
// app over the demo-seeded library (`-MainPreview`, whose omi-demo-1 carries a
// diarized transcript where two seeded action lines are MINE and one is
// Sarah's) and attaches screenshots of: attribution on the action rows
// ("You said"), the collapsed "Heard from others" group (collapsed + expanded,
// "Sarah said"), the promote flow, and the Settings "Actions from others"
// toggle.

import XCTest

final class SpeakerAttributionProofUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAttributionRowsAndHeardFromOthers() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-FreshActionState"]
        app.launch()

        // 1. Open the demo conversation carrying attributed action candidates.
        let card = app.staticTexts["Launch deck and relay numbers"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "demo conversation card")
        card.tap()

        let actionsFace = app.buttons["face-actions"].firstMatch
        XCTAssertTrue(actionsFace.waitForExistence(timeout: 10), "Actions face switch")
        actionsFace.tap()

        let surfacedRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'action-row-surfaced'"))
        if !surfacedRows.firstMatch.waitForExistence(timeout: 4) { actionsFace.tap() }
        XCTAssertTrue(surfacedRows.firstMatch.waitForExistence(timeout: 10),
                      "surfaced action rows render")

        // 2. MY actions read "You said"; Sarah's is NOT in the main list.
        XCTAssertTrue(app.staticTexts["You said"].firstMatch.exists,
                      "owner attribution renders on the main list")
        let mainRowCount = surfacedRows.count
        XCTAssertEqual(mainRowCount, 2, "only MY actions sit in the main list")

        // 3. The collapsed "Heard from others" group, with the count.
        let others = app.buttons["heard-from-others"].firstMatch
        XCTAssertTrue(others.waitForExistence(timeout: 5),
                      "Heard from others group renders collapsed")
        XCTAssertTrue(others.label.contains("Heard from others (1)"),
                      "group label carries the count: \(others.label)")
        shoot(app, "01-actions-attributed-collapsed-others")

        // 4. Expand → Sarah's action, attributed by name.
        others.tap()
        XCTAssertTrue(app.staticTexts["Sarah said"].firstMatch.waitForExistence(timeout: 5),
                      "expanded group attributes the action to Sarah")
        shoot(app, "02-heard-from-others-expanded")

        // 5. Promote it → it moves into the main list and stays attributed.
        XCTAssertTrue(surfacedRows.count > mainRowCount, "expanded rows visible")
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'action-row-surfaced' AND label CONTAINS 'Sarah said'"
        )).firstMatch.tap()
        let promote = app.buttons["promote-action"].firstMatch
        XCTAssertTrue(promote.waitForExistence(timeout: 5),
                      "an others-group action offers Move to my actions")
        shoot(app, "03-promote-option")
        promote.tap()
        XCTAssertTrue(waitGone(others, timeout: 5),
                      "the emptied Heard from others group disappears")
        XCTAssertEqual(surfacedRows.count, 3, "promoted action joins the main list")
        XCTAssertTrue(app.staticTexts["Sarah said"].firstMatch.exists,
                      "the promoted action keeps its honest attribution")
        shoot(app, "04-promoted-into-main-list")
    }

    func testActionsFromOthersSetting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-OpenSettings"]
        app.launch()

        // The Intelligent Action section unfolds behind the ambient master
        // toggle — flip it on to reveal (and leave clean after).
        let ambient = app.switches["Act on conversations"].firstMatch
        var swipes = 0
        while !(ambient.exists && ambient.isHittable), swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(ambient.waitForExistence(timeout: 5), "ambient master toggle")
        let ambientWasOff = (ambient.value as? String) == "0"
        if ambientWasOff {
            ambient.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }

        let toggle = app.switches["actions-from-others"].firstMatch
        swipes = 0
        while !(toggle.exists && toggle.isHittable), swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Actions from others toggle renders")
        XCTAssertEqual(toggle.value as? String, "0",
                       "Actions from others defaults OFF (owner-first)")
        shoot(app, "05-setting-default-off")

        func flip(expecting expected: String) {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            let flipped = NSPredicate(format: "value == %@", expected)
            let wait = XCTNSPredicateExpectation(predicate: flipped, object: toggle)
            XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 5), .completed,
                           "toggle reaches \(expected)")
        }
        flip(expecting: "1")
        shoot(app, "06-setting-on")
        flip(expecting: "0")   // leave the sim clean
        if ambientWasOff {
            ambient.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return !element.exists
    }
}
