// BrainSetupFailureProofUITests — the SIMULATOR proof for the on-device brain's honest
// failure state (track 20260722T1244, features/local-brain-setup.feature "a download that
// stops making progress fails honestly instead of spinning forever").
//
// The unit + Brine tests prove the STATE machine: a stalled download flips to `.failed`
// with a working retry. They cannot prove the state is actually RENDERED — that the user
// sees a warning instead of a spinner, that "Try again" is on screen and tappable, and
// that tapping it clears the failure. That is what this does, on a real simulator, with
// screenshots attached.
//
// It drives the REAL app under the DEBUG-only `-BrainSetupFailed` launch argument, which
// seeds the brain status into the failed state (the repo's established proof convention:
// `-MainPreview`, `-OpenSettings`, `-RollingTitleDemo`, …). Nothing here changes release
// behaviour — the hook is inside `#if DEBUG` — and no 150 MB download is ever stalled for
// real to get the picture.

import XCTest

final class BrainSetupFailureProofUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFailedBrainSetupShowsAnHonestBannerWithAWorkingRetry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-BrainSetupFailed"]
        app.launch()

        let captureTab = app.buttons["Capture"].firstMatch
        if captureTab.waitForExistence(timeout: 20) { captureTab.tap() }

        // 1. The FAILED rendition: the warning glyph branch (not the spinner branch), the
        //    reason, and the retry control — all on screen.
        let failedBanner = app.otherElements["brain-setup-banner-failed"].firstMatch
        XCTAssertTrue(failedBanner.waitForExistence(timeout: 20),
                      "the failed setup banner renders (warning glyph, not a spinner)")
        XCTAssertFalse(app.otherElements["brain-setup-banner-preparing"].exists,
                       "a failed setup must not still render as the indefinite spinner")

        let reason = app.staticTexts["On-device brain setup failed: "
                                     + "the download stopped at 35% and hasn't moved for 60s"].firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 10),
                      "the banner says what went wrong and how far it got")

        let retry = app.buttons["brain-setup-retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "a failure with no way out is a dead end")
        XCTAssertEqual(retry.label, "Try again")
        // S7: the one control that unwedges the user is a real 44pt target, not an 11pt
        // line of caption text.
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44,
                                    "the retry control needs a tappable hit area: \(retry.frame)")
        shoot(app, "01-brain-setup-failed")

        // 2. Tapping it actually does something: the failure clears and setup resumes.
        retry.tap()
        let recovering = app.staticTexts["Setting up your private on-device brain… 60%"].firstMatch
        XCTAssertTrue(recovering.waitForExistence(timeout: 10),
                      "tapping Try again starts a fresh attempt")
        XCTAssertFalse(app.otherElements["brain-setup-banner-failed"].exists,
                       "the failure is cleared once a new attempt is running")
        shoot(app, "02-brain-setup-retrying")

        // 3. And it ENDS: the banner goes away entirely rather than spinning forever.
        let deadline = Date().addingTimeInterval(20)
        while recovering.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(recovering.exists, "the banner must END, not spin forever")
        XCTAssertFalse(app.otherElements["brain-setup-banner-preparing"].exists,
                       "a ready brain shows no banner at all")
        XCTAssertFalse(app.buttons["brain-setup-retry"].exists,
                       "a ready brain offers no retry")
        shoot(app, "03-brain-setup-ready")
    }
}
