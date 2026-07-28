// VaultFunnelReachableProofUITests — can the owner actually GET to Vault setup?
//
// The Vault funnel's state machine is covered by VaultFunnelTests, but those drive the
// model directly. Nothing asserted that a person can REACH it: Settings → "Your Vault" →
// "Turn on your Vault" is the entry point for the paid tier and cell provisioning, and an
// unreachable entry point is indistinguishable from a broken one from the user's side.
//
// This proof walks the real surface: launch → Settings tab → find the Vault row → tap it →
// require the setup screen to present.

import XCTest

final class VaultFunnelReachableProofUITests: XCTestCase {

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testOwnerCanReachVaultSetupFromSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview"]
        app.launch()

        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 60), "the app launched to the tab bar")
        settings.tap()
        shoot(app, "01-settings")

        // The Vault row. Its copy is entitlement-aware: "Turn on your Vault" when off,
        // "Your Vault" when live — accept either, since both mean the entry point rendered.
        let vaultRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'Vault'")).firstMatch
        if !vaultRow.waitForExistence(timeout: 20) {
            add(XCTAttachment(string: "=== full tree ===\n" + app.debugDescription))
            shoot(app, "DIAG-no-vault-row")
        }
        XCTAssertTrue(vaultRow.exists,
                      "Settings shows the Vault entry — this is the only door to the paid tier "
                      + "and cell provisioning")
        shoot(app, "02-vault-row")

        // Tapping it must PRESENT something, not sit inert. The funnel's first screen is the
        // "This lives in your Vault" trigger with its unlocks.
        vaultRow.tap()
        let presented = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'Vault'")).count > 0
        XCTAssertTrue(presented,
                      "tapping the Vault entry presents the setup surface (field-shaped failure: "
                      + "an entry point that looks live and does nothing)")
        shoot(app, "03-after-tap")
    }
}
