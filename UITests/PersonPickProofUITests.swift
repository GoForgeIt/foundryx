// PersonPickProofUITests — the simulator interaction proof for the "pick an existing
// person" tag flow (track 20260717T1700_pick_existing_person). Drives the REAL app over
// the demo-seeded library (`-MainPreview`, omi-demo-2 carries the inferred "Nick") with
// the deterministic `-PersonsProof` directory stub, and attaches screenshots of the
// pick-first flow Nick asked for:
//   • the pick-list of EXISTING people (choose one, don't retype) with the voiceprint-
//     hinted person floated up + annotated "likely" — but nothing pre-selected;
//   • autocomplete narrowing to the person you mean as you type;
//   • the "Create new person" FALLBACK appearing only when nothing matches;
//   • picking an existing person binding it (the "Saved <name>" beat);
//   • the OFFLINE degrade to typing a name when the computer is unreachable.
//
// This is the visual proof that tagging binds to an existing entity at the point of entry
// instead of minting a duplicate on every variant spelling.

import XCTest

final class PersonPickProofUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return !element.exists
    }

    private func launch(persons: String, confirm: String = "ok") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-Screen", "detail",
                               "-Capture", "omi-demo-2", "-Face", "transcript",
                               "-PersonsProof", persons, "-ConfirmProof", confirm]
        app.launch()
        return app
    }

    /// Open the tag sheet for the inferred speaker: the inline affordance's "Not them"
    /// routes to the tag sheet (same path SpeakerConfirmProofUITests uses).
    private func openSheet(_ app: XCUIApplication) {
        let notThem = app.buttons["Not them"]
        XCTAssertTrue(notThem.waitForExistence(timeout: 15), "the inferred slot's affordance renders")
        notThem.tap()
        XCTAssertTrue(app.staticTexts["Tag speaker"].waitForExistence(timeout: 5), "tag sheet opens")
    }

    // ── pick-list + voiceprint hint (annotate + sort, pre-select NOTHING) ──

    func testPickListSurfacesExistingPeopleWithLikelyHintButSelectsNothing() throws {
        let app = launch(persons: "seeded")
        openSheet(app)

        // The existing people are offered as a searchable pick-list — choose one, don't retype.
        XCTAssertTrue(app.buttons["person-row-e-nick"].waitForExistence(timeout: 5),
                      "Nick Rinard is offered from the existing people")
        XCTAssertTrue(app.buttons["person-row-e-dana"].exists, "Dana Lee is offered")
        XCTAssertTrue(app.buttons["person-row-e-greg"].exists, "Greg Rinard is offered")

        // The slot's inferred voiceprint match surfaces "Nick Rinard" as LIKELY — a gentle
        // nudge that annotates + sorts, but pre-selects nothing (no "Saved" until a tap).
        XCTAssertTrue(app.staticTexts["person-likely-e-nick"].exists,
                      "the likely person is annotated from the voiceprint hint")
        XCTAssertFalse(app.staticTexts["Saved Nick Rinard"].exists,
                       "the hint must NOT bind anyone until the human chooses")
        shoot(app, "01-pick-list-with-likely-hint")
        app.terminate()
    }

    // ── autocomplete + create-new fallback ──

    func testTypingAutocompletesAndCreateNewIsTheFallback() throws {
        let app = launch(persons: "seeded")
        openSheet(app)

        let search = app.textFields["Search people or add a name"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the pick-list search field renders")
        search.tap()
        search.typeText("da")
        // Autocomplete narrows to the person you mean — "Do you mean Dana Lee?".
        XCTAssertTrue(app.buttons["person-row-e-dana"].waitForExistence(timeout: 5),
                      "typing narrows to Dana Lee")
        XCTAssertFalse(app.buttons["person-row-e-greg"].exists, "non-matches drop away")
        shoot(app, "02-autocomplete-match")

        // Clear, then type a name that matches NOBODY → the create-new fallback appears.
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        search.typeText("Zoe Vega")
        XCTAssertTrue(app.buttons["person-create-new"].waitForExistence(timeout: 5),
                      "create-new is offered only when nothing matches")
        XCTAssertFalse(app.buttons["person-row-e-nick"].exists,
                       "no existing person matches, so none are offered")
        shoot(app, "03-create-new-fallback")
        app.terminate()
    }

    // ── picking an existing person BINDS it (dedup at entry) ──

    func testPickingExistingPersonBindsItInstantly() throws {
        let app = launch(persons: "seeded", confirm: "ok")
        openSheet(app)
        let nick = app.buttons["person-row-e-nick"]
        XCTAssertTrue(nick.waitForExistence(timeout: 5))
        if !nick.isHittable { app.swipeUp() }
        nick.tap()
        // Binding an existing person saves instantly (local-first): the sheet accepts it and
        // dismisses ITSELF (never waits on the wire), then the slot shows the bound person —
        // proof the tag attached to the EXISTING "Nick Rinard", not a retyped duplicate.
        XCTAssertTrue(waitGone(app.staticTexts["Tag speaker"], timeout: 6),
                      "picking an existing person accepts the bind and self-dismisses")
        XCTAssertTrue(app.staticTexts["Nick Rinard"].waitForExistence(timeout: 5),
                      "the slot is now bound to the existing person Nick Rinard")
        shoot(app, "04-picked-existing-person-bound")
        app.terminate()
    }

    // ── offline: the pick-list degrades to typing a name ──

    func testOfflineDegradesToTypingAName() throws {
        let app = launch(persons: "offline")
        openSheet(app)
        // The computer is unreachable → no pick-list; fall back to typing a name (the
        // local-first save still lands and syncs later).
        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 5),
                      "offline degrades to a type-a-name field")
        XCTAssertFalse(app.buttons["person-row-e-nick"].exists,
                       "no pick-list is offered when the directory can't be fetched")
        shoot(app, "05-offline-degrade-type-a-name")
        app.terminate()
    }
}
