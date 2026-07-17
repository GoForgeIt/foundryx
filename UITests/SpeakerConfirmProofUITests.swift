// SpeakerConfirmProofUITests — the simulator interaction proof for speaker-confirm
// feedback (track 20260717T0900_speaker_confirm_feedback). Drives the REAL app over
// the demo-seeded library (`-MainPreview`, omi-demo-2 carries the inferred "Nick")
// with the deterministic `-ConfirmProof` door stub, and attaches screenshots of:
//   inline confirm: idle → in-flight → confirmed check
//   inline confirm failure: honest copy + Retry (intent kept on the phone)
//   tag sheet: open → in-flight → confirmed flash → SELF-DISMISS
//   tag sheet failure: honest error, sheet STAYS OPEN
// This is the visual proof of the b230 complaints: a tap always answers within a
// frame, success is seen, failure is honest, and the sheet closes itself on success.

import XCTest

final class SpeakerConfirmProofUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

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

    private func launchTranscript(proof: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-Screen", "detail",
                               "-Capture", "omi-demo-2", "-Face", "transcript",
                               "-ConfirmProof", proof]
        app.launch()
        return app
    }

    // ── inline "Confirm: Nick" ────────────────────────────────────────────────

    func testInlineConfirmShowsInFlightThenConfirmed() throws {
        let app = launchTranscript(proof: "ok-slow")
        let confirm = app.buttons["Confirm: Nick"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "inline confirm affordance renders")
        shoot(app, "01-inline-idle")

        confirm.tap()
        // Within a frame the affordance is a spinner + "Confirming Nick…".
        XCTAssertTrue(app.staticTexts["Confirming Nick…"].waitForExistence(timeout: 2),
                      "tap answers immediately with an in-flight state")
        shoot(app, "02-inline-inflight")

        // The stub acknowledges after 1.5s → the confirmed check + the label flips.
        XCTAssertTrue(app.staticTexts["Confirmed Nick"].waitForExistence(timeout: 5),
                      "success is SEEN, not silent")
        shoot(app, "03-inline-confirmed")
        app.terminate()
    }

    func testInlineConfirmFailureIsHonestWithRetry() throws {
        let app = launchTranscript(proof: "fail")
        let confirm = app.buttons["Confirm: Nick"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Confirming Nick…"].waitForExistence(timeout: 2))
        // The stub fails after 1.5s → honest copy + Retry, never a silent nothing.
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5),
                      "failure offers a retry")
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "saved on your phone")
            ).firstMatch.exists,
            "failure copy says where the change lives")
        shoot(app, "04-inline-failure-retry")
        app.terminate()
    }

    // ── the tag-speaker sheet ────────────────────────────────────────────────

    func testSheetConfirmShowsProgressThenDismissesItself() throws {
        let app = launchTranscript(proof: "ok-slow")
        let notThem = app.buttons["Not them"]
        XCTAssertTrue(notThem.waitForExistence(timeout: 10))
        notThem.tap()   // opens the tag sheet for the inferred speaker

        let sheetTitle = app.staticTexts["Tag speaker"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5), "tag sheet opens")
        shoot(app, "05-sheet-open")

        app.buttons["Confirm Nick"].tap()
        XCTAssertTrue(app.staticTexts["Confirming Nick…"].waitForExistence(timeout: 2),
                      "the tapped button becomes a spinner within a frame")
        shoot(app, "06-sheet-inflight")

        // Success flash, then the sheet closes ITSELF (no offer in the stub outcome).
        XCTAssertTrue(app.staticTexts["Confirmed Nick"].waitForExistence(timeout: 5),
                      "the confirmed beat is shown before dismissal")
        shoot(app, "07-sheet-confirmed-flash")
        XCTAssertTrue(waitGone(sheetTitle, timeout: 5), "the sheet dismisses itself on success")
        shoot(app, "08-sheet-self-dismissed")
        app.terminate()
    }

    func testSheetFailureStaysOpenWithHonestError() throws {
        let app = launchTranscript(proof: "fail")
        let notThem = app.buttons["Not them"]
        XCTAssertTrue(notThem.waitForExistence(timeout: 10))
        notThem.tap()

        let sheetTitle = app.staticTexts["Tag speaker"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5))
        app.buttons["Confirm Nick"].tap()
        XCTAssertTrue(app.staticTexts["Confirming Nick…"].waitForExistence(timeout: 2))

        // The stub fails → the sheet STAYS OPEN with the honest error (the old code
        // silently dismissed, which read exactly like success).
        let deadline = Date().addingTimeInterval(6)
        var sawError = false
        while Date() < deadline, !sawError {
            sawError = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "saved on your phone")
            ).firstMatch.exists
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(sawError, "failure surfaces the honest error")
        XCTAssertTrue(sheetTitle.exists, "the sheet stays open on failure")
        XCTAssertTrue(app.buttons["Confirm Nick"].exists, "the primary button doubles as the retry")
        shoot(app, "09-sheet-failure-stays-open")
        app.terminate()
    }
}
