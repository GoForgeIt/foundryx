// RecorderClearingProofUITests — the SIMULATOR proof for Step 6's owner-armed control.
//
// WHAT IT HOLDS THAT NOTHING ELSE CAN. `PocketAutoClear` is decided in the kit and held by
// `features/pocket-remove-from-the-recorder.feature`; that suite proves the DECISION and can
// prove nothing about whether a person can see or reach the control. The control lives in
// `App/DeviceScreen.swift`, which `swift test` cannot compile, and this repository has already
// measured twice what a source-text search is worth against a view that stopped rendering
// (`RecordingDeviceProofUITests`' MUT-R12-C and MUT-R12-D each deleted the rendering outright
// and left the whole suite green).
//
// WHAT IT DELIBERATELY DOES NOT CLAIM. It does not remove anything from a recorder. A removal
// needs an authenticated Bluetooth session, and a simulator has no radio; the wire, the
// refusal, the re-read that confirms it and the four-way `MCU&D` collision are all held by the
// hostless suite over a scripted recorder. This file holds the half that lane cannot: that the
// setting is on a screen, that it says what "synced" means and where the copy went, and that it
// is OFF when nobody has armed it.

import XCTest

final class RecorderClearingProofUITests: XCTestCase {

    /// `DemoSeed.proofPocketName` — the remembered record-then-sync recorder the harness
    /// stands up. Nothing else in the app produces this string.
    private let seededPocket = "Proof Pocket Blue"

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func text(in app: XCUIApplication, containing needle: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", needle))
            .firstMatch
    }

    /// Open the seeded recorder's page and leave the app there.
    @discardableResult
    private func openTheRecorderPage(_ app: XCUIApplication) -> XCUIApplication {
        let entry = app.staticTexts["Devices & connections"].firstMatch
        var swipes = 0
        while !entry.exists, swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 15),
                      "Settings offers no way into the device list")
        entry.tap()

        let pocket = text(in: app, containing: seededPocket)
        XCTAssertTrue(pocket.waitForExistence(timeout: 15),
                      "the remembered recorder is not on the device list, so its page cannot "
                          + "be reached and the control cannot be proven at all")
        shoot(app, "01-device-list-with-remembered-recorder")
        pocket.tap()
        return app
    }

    /// THE TIER THAT HAS SOMEWHERE ELSE TO PUT A COPY.
    func testTheOwnerArmedClearingControlIsOnTheRecorderPageAndIsOff() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-OpenSettings", "-ProofPairedComputer"]
        app.launch()
        openTheRecorderPage(app)

        // THE CONTROL ITSELF. `PocketRemoveFromRecorderPresentation.autoClearTitle`.
        let control = text(in: app, containing: "Clear this recorder as recordings sync")
        var scrolls = 0
        while !control.exists, scrolls < 12 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(control.waitForExistence(timeout: 10),
                      "the recorder page renders no automatic-clearing control — the setting "
                          + "the delete ruling calls owner-armed is unreachable")

        // IT IS OFF. The store's default, read on the screen rather than asserted in a struct.
        let toggle = app.switches.firstMatch
        XCTAssertTrue(toggle.exists, "the control is not a switch anybody can operate")
        XCTAssertEqual(toggle.value as? String, "0",
                       "a recorder nobody armed draws its automatic clearing as ON — the "
                           + "ruling's default is OFF, and a default that is wrong on screen "
                           + "is wrong wherever else it is right")

        // AND THE SENTENCE SAYS WHAT SYNCED MEANS AND WHERE THE COPY WENT.
        XCTAssertTrue(text(in: app, containing: "Synced means confirmed, not started").exists,
                      "the control does not say what \"synced\" is trusted to mean")
        XCTAssertTrue(text(in: app, containing: "This applies to recordings that sync from now on")
                        .exists,
                      "nothing on screen says the control is not retroactive")
        shoot(app, "02-owner-armed-clearing-off-by-default")

        // THE CONTROL FOR THE CONTROL. The same query family must NOT match a sentence no
        // screen renders, or every assertion above is satisfied by anything at all.
        XCTAssertFalse(text(in: app, containing: "Clear this recorder as recordings evaporate")
                        .exists,
                       "the label query matches a string nothing renders, so this proof "
                           + "could not fail")
        // AND THE COPY DISCIPLINE, ON THE RENDERED SCREEN. No removal has ever been issued to
        // a real file, so no `APP&SPACE` delta has been observed, so nothing here promises one.
        for forbidden in ["free up space", "frees up", "make room", "reclaim"] {
            XCTAssertFalse(text(in: app, containing: forbidden).exists,
                           "the recorder page promises \"\(forbidden)\" — a number nobody "
                               + "has measured")
        }
    }

    /// THE TIER THAT DOES NOT. On a phone-only brain nothing ever becomes safe anywhere else,
    /// so a toggle would be a control that can never fire — and a control that can never fire
    /// is worse than an absence, because a person will arm it and wait. The page says why
    /// instead, and this reads that off the screen.
    func testAPhoneWithNowhereElseToPutACopyIsNotOfferedTheControl() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-OpenSettings"]
        app.launch()
        openTheRecorderPage(app)

        let reason = text(in: app, containing:
                            "Automatic clearing needs somewhere other than this iPhone")
        var scrolls = 0
        while !reason.exists, scrolls < 12 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(reason.waitForExistence(timeout: 10),
                      "the phone-only tier renders neither the control nor a reason it is "
                          + "absent — a blank space where a setting should be")
        // AND NO TOGGLE, which is the half that matters: offered-and-inert is the failure.
        XCTAssertFalse(text(in: app, containing: "Clear this recorder as recordings sync").exists,
                       "a brain with nowhere to put a copy is offered a control that cannot "
                           + "ever clear anything")
        shoot(app, "03-phone-only-says-why-there-is-no-control")
    }
}
