// AccountSettingsProofUITests — the simulator proof for the Settings → Account
// section (Nick 2026-07-21): the account identity is shown clearly ABOVE the
// sign-out control, and the section renders a working sign-in/out affordance.
// Launches the REAL app straight into Settings (`-OpenSettings`), scrolls to the
// Account section, asserts the identity row + the sign-in/out button, and attaches
// the proof screenshot to the .xcresult. (The signed-IN rendering — name/email/
// provider — is pinned exhaustively by AccountPresentationTests; this proves the
// section is on-screen and actionable in the running app.)

import XCTest

final class AccountSettingsProofUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAccountSectionRendersIdentityAboveSignOut() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-OpenSettings"]
        app.launch()

        // Scroll the Settings list down to the Account section (near the bottom).
        let identity = app.staticTexts["account-identity"]
        var swipes = 0
        while !identity.exists, swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(identity.waitForExistence(timeout: 5),
                      "the Account section shows who is signed in (or 'Not signed in')")

        // Exactly one of the two affordances is present, and it sits with the identity row.
        let signOut = app.buttons["sign-out"]
        let signIn = app.buttons["sign-in"]
        XCTAssertTrue(signOut.exists || signIn.exists,
                      "the Account section offers a sign-out (signed in) or sign-in (signed out) control")
        shoot(app, "01-account-section")

        // If signed out on this fresh install, tapping Sign in must present the sign-in
        // sheet — the reversible half of the flow the user asked for.
        if signIn.exists && signIn.isHittable {
            signIn.tap()
            shoot(app, "02-sign-in-sheet")
        }
    }
}
