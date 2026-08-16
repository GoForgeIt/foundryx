// RecordingDevicesPageProofUITests — the SIMULATOR proof that the recording-devices page
// still renders after the presence work (track
// `pocket_presence_and_a_durability_predicate_that_survives_the_retention_sweep`).
//
// WHY IT DID NOT EXIST BEFORE, AND WHY IT DOES NOW. `DeviceScreen` is the surface the recorder
// shelf hangs off, and until this file there was NO simulator proof that it renders at all —
// `RecordingDeviceProofUITests` proves the device NAME on a conversation row, which is a
// different screen. The presence work changed `DeviceScreen`'s initialiser (it now takes the
// brain, so the shelf can say where a brought-over copy goes) and changed what every shelf row
// draws. A compile gate proves that type-checks; only a run proves the screen still appears.
//
// WHAT IT DELIBERATELY DOES NOT CLAIM. It does not render a recorder's SHELF: that needs an
// authenticated Bluetooth session, and a simulator has no radio. The shelf's own strings and
// its per-row presence are held by the app-hosted lane (`FoundryXAppScenarios`), which runs
// `PocketRecorderCheckModel` — the real model, in the real app process, on this same runtime —
// over a scripted radio. This file holds the half that lane cannot: the pixels.
import XCTest

final class RecordingDevicesPageProofUITests: XCTestCase {

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTheRecordingDevicesPageOpensAndRenders() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-OpenSettings"]
        app.launch()

        // The Settings row that leads to the one device list.
        let entry = app.staticTexts["Devices & connections"].firstMatch
        var swipes = 0
        while !entry.exists, swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 10),
                      "Settings offers no way into the device list")
        shoot(app, "01-settings-devices-row")

        entry.tap()

        // A NAVIGATION TITLE IS NOT ENOUGH ON ITS OWN — it can render over a body that threw.
        // So the page's own affordance is asserted too: it comes from the kit, it is the one
        // connect entry point, and it only exists if `DeviceScreen`'s body actually built.
        let title = app.navigationBars["Recording devices"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "tapping \"Devices & connections\" did not land on the device list")
        let connect = app.staticTexts["Connect a recording device"].firstMatch
        let connectButton = app.buttons["Connect a recording device"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5) || connectButton.exists,
                      "the device page rendered no connect affordance — its body did not build")
        shoot(app, "02-recording-devices-page")

        // THE CONTROL. The same query family must NOT match a title no screen has, or the
        // assertions above would pass on any screen at all.
        XCTAssertFalse(app.navigationBars["Recording devices that do not exist"].exists,
                       "the navigation-bar query matches a title nothing renders, so it "
                           + "cannot fail — this proof would pass on a blank screen")
    }
}
