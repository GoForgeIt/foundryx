// SettingsDiagnosticsProofUITests — the simulator proof for the DIAGNOSTICS
// settings section (track 20260717T0600 T3): drives the REAL app (`-MainPreview
// -OpenSettings`), scrolls to the "Show performance overlay" toggle, and attaches
// screenshots of the default-OFF state and the flipped-ON state to the .xcresult.

import XCTest

final class SettingsDiagnosticsProofUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDiagnosticsToggleDefaultOffAndFlips() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-OpenSettings"]
        app.launch()

        // Scroll until the DIAGNOSTICS toggle is on screen.
        let toggle = app.switches["Show performance overlay"].firstMatch
        var swipes = 0
        while !(toggle.exists && toggle.isHittable), swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "DIAGNOSTICS toggle renders")

        // Default OFF (the whole point: no debug pills unbidden in user builds).
        XCTAssertEqual(toggle.value as? String, "0", "performance overlay defaults OFF")
        shoot(app, "01-diagnostics-toggle-default-off")

        // Flips ON without restart; flip back to leave the sim clean. Tap the knob
        // itself — in a List the row's label area can swallow a bare `tap()`.
        func flip(expecting expected: String) {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            let flipped = NSPredicate(format: "value == %@", expected)
            let wait = XCTNSPredicateExpectation(predicate: flipped, object: toggle)
            XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 5), .completed,
                           "toggle reaches \(expected)")
        }
        flip(expecting: "1")
        shoot(app, "02-diagnostics-toggle-on")
        flip(expecting: "0")
    }
}
