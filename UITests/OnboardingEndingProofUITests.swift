// OnboardingEndingProofUITests — does the flow actually LEAD somewhere?
//
// OnboardingEndingFeatureTests proves the step ORDER and the destination preference, but
// it drives pure model types. It cannot prove the thing Nick actually hit: that after the
// last question the app leaves you somewhere with a next action, and that the Vault — the
// entry to cell provisioning — is offered in the flow rather than buried in Settings.
//
// This walks the real surface with `-MainPreview -Onboarding`, stepping through to the
// end and requiring each step to render. It also asserts the PREMISE separately from the
// claim at the first-note step: "the live transcript never appeared" and "recording never
// started" are different bugs, and a proof that cannot tell them apart sent me chasing
// the wrong one once already.

import XCTest

final class OnboardingEndingProofUITests: XCTestCase {

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Tap the BUTTON whose label contains `text`.
    ///
    /// Deliberately queries `app.buttons` rather than `descendants(matching: .any)`:
    /// the loose query happily matches a wrapping container whose combined label
    /// contains the text, and tapping a container is a silent no-op — the tap "succeeds"
    /// and nothing happens, which is exactly the false green that made the first run of
    /// this proof blame the recording path for a test bug.
    @discardableResult
    private func tap(_ app: XCUIApplication, button text: String,
                     timeout: TimeInterval = 30, required: Bool = true,
                     file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let match = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        guard match.waitForExistence(timeout: timeout), match.isHittable else {
            if required {
                add(XCTAttachment(string: "=== buttons when looking for '\(text)' ===\n"
                                  + app.buttons.debugDescription
                                  + "\n=== full tree ===\n" + app.debugDescription))
                shoot(app, "DIAG-missing-\(text)")
                XCTFail("no hittable button matched '\(text)'", file: file, line: line)
            }
            return false
        }
        match.tap()
        return true
    }

    func testOnboardingEndsWithANoteAndOffersTheVault() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-Onboarding", "-SyntheticMic", "-SyntheticTranscript"]
        app.launch()

        // Step through whatever precedes the ending. Each of these is optional in the
        // sense that the flow may open past it (skipWelcome), so probe rather than demand.
        for label in ["Continue", "Skip", "Not now"] {
            tap(app, button: label, timeout: 5, required: false)
        }
        shoot(app, "01-into-the-flow")

        // ── the ending must exist at all
        let firstNote = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'first voice note'")).firstMatch
        if !firstNote.waitForExistence(timeout: 30) {
            add(XCTAttachment(string: "=== full tree ===\n" + app.debugDescription))
            shoot(app, "DIAG-no-first-note-step")
        }
        XCTAssertTrue(firstNote.exists,
                      "onboarding reaches the first-voice-note step — before this change "
                      + "the flow ended on the ambient CONSENT screen and dropped the "
                      + "user on an empty library")
        shoot(app, "02-first-note-step")

        // ── recording starts (the PREMISE) …
        tap(app, button: "Start my first note")
        let stop = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] \"That's it\"")).firstMatch
        if !stop.waitForExistence(timeout: 30) {
            add(XCTAttachment(string: "=== tree after tapping start ===\n" + app.debugDescription))
            shoot(app, "DIAG-start-did-not-record")
        }
        XCTAssertTrue(stop.exists,
                      "PREMISE: tapping start actually entered the recording phase — if "
                      + "this fails, the transcript assertion below is meaningless")

        // … and the words reach the screen (the CLAIM). Separated deliberately: "never
        // recorded" and "recorded but showed nothing" are different defects.
        let transcript = app.otherElements["live-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 30),
                      "the live transcript surface renders while making the first note")
        shoot(app, "03-recording-with-transcript")

        stop.tap()
        shoot(app, "04-note-saved")

        // ── and the flow carries on to the ceiling, where the Vault is OFFERED
        tap(app, button: "Next")
        // The ask-it step may skip itself where the OS has no on-device model; either way
        // its Next/Skip leads on.
        for label in ["Next", "Skip"] where tap(app, button: label, timeout: 5, required: false) {
            break
        }
        shoot(app, "05-after-ask-it")

        // Query by identifier across ANY type: which element type a SwiftUI stack
        // surfaces as depends on its accessibility grouping, and pinning the type
        // makes the proof fail for a reason that has nothing to do with the product.
        let comparison = app.descendants(matching: .any)
            .matching(identifier: "tier-comparison").firstMatch
        XCTAssertTrue(comparison.waitForExistence(timeout: 30),
                      "the destination step shows what changes with a Vault")
        let vault = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] 'Set up my Vault'")).firstMatch
        XCTAssertTrue(vault.exists,
                      "cell provisioning is offered IN the flow — it was previously "
                      + "reachable only by digging through Settings, which is why a new "
                      + "user never found it")
        shoot(app, "06-destination-and-vault")
    }
}
