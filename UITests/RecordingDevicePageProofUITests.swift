// RecordingDevicePageProofUITests — the SIMULATOR proof for the four surfaces this wave
// changed on ONE recorder's own page.
//
// WHY IT EXISTS. Four user-facing changes shipped across Steps 1, 5 and 7 with no screenshot
// between them, and every builder said so honestly: the readings strip, the reset gate's cost
// line and button, the Forget confirmation's cost sentence, and the deletion promise under the
// section note. The standing rule is that no UI change ships without simulator proof, and the
// stated reason for the gap — "the shelf needs an authenticated Bluetooth session, and a
// simulator has no radio" — is true of the SHELF and false of these four. They render off a
// device the account merely REMEMBERS. `DemoSeed.seedRememberedRecorder` is what makes one
// exist under `-MainPreview`.
//
// IT MATTERS THAT IT IS THIS PAGE. The Forget confirmation is where the most expensive defect
// in the wave lived: with nothing checked, it told the owner "Solleva already has every
// recording this recorder listed" immediately before destroying the key that reaches them. A
// photograph of that alert is exactly the instrument that would have caught it, which is why
// this file asserts on the alert's TEXT and not merely on its existence.
//
// WHAT IT STILL DOES NOT CLAIM. It does not render a recorder's shelf rows: those need a real
// session. Their strings and per-row presence are held by the app-hosted lane, which runs the
// real `PocketRecorderCheckModel` in the real app process on this same iOS runtime.
import XCTest

final class RecordingDevicePageProofUITests: XCTestCase {

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Open Settings → Devices & connections → the one remembered recorder.
    private func openRecorderPage() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-OpenSettings"]
        app.launch()

        let entry = app.staticTexts["Devices & connections"].firstMatch
        var swipes = 0
        while !entry.exists, swipes < 10 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(entry.waitForExistence(timeout: 10),
                      "Settings offers no way into the device list")
        entry.tap()

        XCTAssertTrue(app.navigationBars["Recording devices"].firstMatch
                          .waitForExistence(timeout: 10),
                      "tapping \"Devices & connections\" did not land on the device list")

        // THE SEEDED RECORDER'S ROW. If this is missing the seeder did not run, and every
        // assertion below would be about a page nobody reached.
        let row = app.staticTexts["PKT01_BLUE_26079bc5"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "no remembered recorder on the device list — `DemoSeed` did not seed one, "
                          + "so this proof has nothing to photograph")
        row.tap()
        return app
    }

    /// THE STRIP OF FACTS, AND THE ABSENCE OF THE RETIRED PROMISE.
    func testTheRecorderPageDrawsItsReadingsAndHasRetiredTheOldPromise() throws {
        let app = try openRecorderPage()

        // THE READINGS STRIP. Every label renders; nothing has been read, so each offers the
        // action that would read it rather than a dash or a plausible zero.
        for label in ["Battery", "Storage", "Firmware"] {
            XCTAssertTrue(app.staticTexts[label].firstMatch.waitForExistence(timeout: 10),
                          "the readings strip did not draw \"\(label)\" — its body did not build")
        }

        // THE PROMISE ITSELF IS NOT ASSERTED HERE, AND I AM NOT PRETENDING OTHERWISE.
        // `PocketRecorderCheckPresentation.sectionNote` renders under the SHELF — inside
        // `if let detail = check.detail` — so it needs a listing, and a simulator has no radio.
        // Its text is held by the app-hosted lane, which runs the real model in the real app
        // process on this runtime. What IS checkable here without a radio is the half that
        // matters most: the RETIRED promise must not be anywhere on this page.
        //
        // The old sentence was a description of a missing feature, and it was about to become
        // untrue the moment a person was allowed to ask for a deletion.
        XCTAssertFalse(
            app.staticTexts
                .containing(NSPredicate(format: "label CONTAINS %@",
                                        "never deletes anything from your recorder"))
                .firstMatch.exists,
            "the retired promise — that Solleva cannot delete at all — is still on this page")

        shoot(app, "01-recorder-page-readings-and-promise")

        // THE CONTROL. The same query family must not match text no screen renders, or every
        // assertion above would pass on a blank page.
        XCTAssertFalse(app.staticTexts["Battery level of a recorder that does not exist"].exists,
                       "the staticTexts query matches a label nothing renders, so this proof "
                           + "cannot fail")
    }

    /// THE TWO DESTRUCTIVE SURFACES, ON A RECORDER NOBODY HAS CHECKED.
    ///
    /// This is the state every freshly opened page is in, and it is the state the cost line got
    /// wrong: `[]` presences fell into "zero cost" and printed a reassurance.
    func testForgettingAnUncheckedRecorderSaysItHasNotCheckedIt() throws {
        let app = try openRecorderPage()

        // THE RESET GATE states the same thing, in the same terms, before the alert does.
        let notChecked = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@",
                                    "hasn't checked what this recorder is holding"))
            .firstMatch
        var swipes = 0
        while !notChecked.exists, swipes < 8 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(notChecked.waitForExistence(timeout: 10),
                      "the reset gate does not say Solleva has not checked this recorder")
        shoot(app, "02-reset-gate-on-an-unchecked-recorder")

        // AND THE RESET IS STILL OFFERED. A stale or absent reading moves what is asked first,
        // never what the owner is allowed to do with their own recorder.
        let checkFirst = app.buttons["Check the recorder first"].firstMatch
        XCTAssertTrue(checkFirst.exists && checkFirst.isEnabled,
                      "the owner's own reset disabled itself on an unchecked recorder")

        // THE FORGET CONFIRMATION — the surface the defect lived on.
        // NAMED FROM THE KIT'S OWN CONSTANT, not from a remembered string. My first attempt
        // asked for "Forget this device", the affordance is "Forget this recorder", and the
        // XCTSkip I had written as a guard turned that miss into a silent pass — the exact
        // instrument failure this whole file exists to be an instrument against. There is no
        // skip here now: a page with no Forget affordance is a red.
        let forget = app.buttons["Forget this recorder"].firstMatch
        swipes = 0
        while !forget.exists, swipes < 8 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(forget.waitForExistence(timeout: 10),
                      "the recorder page offers no Forget affordance, so the confirmation this "
                          + "test exists to photograph cannot be reached")
        forget.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10),
                      "Forget destroyed the key with no confirmation at all")
        shoot(app, "03-forget-confirmation-on-an-unchecked-recorder")

        let body = alert.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: "\n")
        XCTAssertTrue(body.contains("hasn't checked what this recorder is holding"),
                      "the Forget confirmation reads \"\(body)\" — on a recorder nobody has "
                          + "checked it must say it has not checked")
        // THE DEFECT, NAMED. This exact sentence used to render here, as a statement of fact,
        // about a recorder Solleva had never spoken to.
        XCTAssertFalse(body.contains("already has every recording this recorder listed"),
                       "the Forget confirmation told the owner Solleva already holds everything "
                           + "this recorder listed, immediately before destroying the key that "
                           + "reaches it — over a shelf nobody read")

        // THE CONTROL. The alert genuinely carries text this query can read; without this the
        // negative assertion above would pass on an alert whose body was empty.
        XCTAssertFalse(body.isEmpty,
                       "the confirmation's body read as empty text, so the assertion that it "
                           + "does not contain a false reassurance proves nothing")
    }
}
