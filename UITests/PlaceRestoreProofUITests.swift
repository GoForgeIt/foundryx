// PlaceRestoreProofUITests — "it doesn't keep me on the page I was".
//
// WHY THIS FILE EXISTS
// --------------------
// Nick, on device (2026-08-04):
//
//   "anytime i refocus or go away from the app and come back it doesnt keep me on the page
//    i was — it takes me back to the list of conversations which is a huge pain in the
//    butt…. It should keep me where I was so i can continue whatever I was working on
//    whether that's looking at a specific transcript, being in the middle of a chat, etc"
//
// The one existing lifecycle proof (ForegroundRestoreProofUITests) backgrounds the app while
// RECORDING and asserts the recording survives. Nothing asserted that the PLACE survives —
// which tab you were on, and what you had open on it. Two different lifecycle events destroy
// it and only one of them is a suspend:
//
//   1. SUSPEND/RESUME — the process lives; SwiftUI state survives unless something remounts
//      the tab tree (RootView keys `MainTabs` on the door bearer + identity generation, so a
//      token refresh on return rebuilds every tab from scratch).
//   2. TERMINATION — iOS reclaims a backgrounded app that holds BLE + audio + a large
//      library. The relaunch is a COLD LAUNCH and lands on `AppTab.launch` (Capture — "the
//      list of conversations") with nothing open.
//
// Both are proved here, separately, so a pass/fail names which one is broken.

import XCTest

final class PlaceRestoreProofUITests: XCTestCase {

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launched() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview"]
        app.launch()
        XCTAssertTrue(app.buttons["Capture"].firstMatch.waitForExistence(timeout: 90),
                      "app launched to the tab bar")
        return app
    }

    /// The tab bar's selected item, read from the accessibility tree.
    private func selectedTab(_ app: XCUIApplication) -> String? {
        for label in ["Capture", "Activity", "Chats", "Settings"] {
            let button = app.tabBars.buttons[label].firstMatch
            if button.exists, button.isSelected { return label }
        }
        for label in ["Capture", "Activity", "Chats", "Settings"] {
            let button = app.buttons[label].firstMatch
            if button.exists, button.isSelected { return label }
        }
        return nil
    }

    private func tapTab(_ app: XCUIApplication, _ label: String) {
        let tab = app.tabBars.buttons[label].firstMatch
        if tab.exists { tab.tap() } else { app.buttons[label].firstMatch.tap() }
    }

    private func goHomeAndBack(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30),
                      "app came back to the foreground")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
    }

    /// Leaving the app and returning must land on the surface you left, not the
    /// conversation list. SUSPEND/RESUME path.
    func testTheTabISwitchedToSurvivesLeavingAndReturning() throws {
        let app = launched()

        tapTab(app, "Chats")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(selectedTab(app), "Chats", "premise: I am standing on the Chats tab")
        shoot(app, "01-on-chat-before-leaving")

        goHomeAndBack(app)
        shoot(app, "02-after-returning")

        XCTAssertEqual(selectedTab(app), "Chats",
                       "returning to the app MUST land where I was (Chats), not on the "
                       + "conversation list")
    }

    /// The same, across a TERMINATION — the app being reclaimed in the background is
    /// indistinguishable to the user from switching apps, and it is the common case on a
    /// phone running a BLE + audio + large-library app.
    func testTheTabISwitchedToSurvivesBeingReclaimedInTheBackground() throws {
        let app = launched()

        tapTab(app, "Chats")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(selectedTab(app), "Chats", "premise: I am standing on the Chats tab")

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.terminate()   // stands in for the jetsam a real phone performs unasked
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.launch()
        XCTAssertTrue(app.buttons["Capture"].firstMatch.waitForExistence(timeout: 90),
                      "app relaunched to the tab bar")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        shoot(app, "02-after-relaunch")

        XCTAssertEqual(selectedTab(app), "Chats",
                       "a background reclaim is not a reason to lose my place — coming back "
                       + "MUST land on Chats, not on the conversation list")
    }

    /// Open the demo library's first conversation and assert we are inside its detail.
    private func openATranscript(_ app: XCUIApplication) {
        tapTab(app, "Capture")
        // A seeded demo conversation, tapped by its title (same route
        // RecordingDeviceProofUITests uses to reach a detail).
        let row = app.staticTexts["Launch deck and relay numbers"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "premise: the conversation list has a conversation to open")
        row.tap()

        // The three-face detail's Transcript face is the tell that we're IN a transcript.
        let transcriptFace = app.buttons["face-transcript"].firstMatch
        if !transcriptFace.waitForExistence(timeout: 30) {
            add(XCTAttachment(string: "=== full tree ===\n" + app.debugDescription))
            shoot(app, "DIAG-no-detail")
        }
        XCTAssertTrue(transcriptFace.exists, "premise: a conversation's detail is open")
    }

    /// A transcript I had open must still be open when I come back — not the list it was
    /// pushed from. This is Nick's "looking at a specific transcript".
    func testAnOpenTranscriptSurvivesLeavingAndReturning() throws {
        let app = launched()
        openATranscript(app)
        shoot(app, "01-transcript-before-leaving")

        goHomeAndBack(app)
        shoot(app, "02-transcript-after-returning")

        XCTAssertTrue(app.buttons["face-transcript"].firstMatch.waitForExistence(timeout: 20),
                      "returning to the app MUST leave me inside the transcript I was reading, "
                      + "not back on the list it was pushed from")
    }

    /// The same transcript, across a reclaim — the case that has no in-memory state left to
    /// fall back on, so it can only pass if the place was written down.
    func testAnOpenTranscriptSurvivesBeingReclaimedInTheBackground() throws {
        let app = launched()
        openATranscript(app)
        shoot(app, "01-transcript-before-reclaim")

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.terminate()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.launch()
        XCTAssertTrue(app.buttons["Capture"].firstMatch.waitForExistence(timeout: 90),
                      "app relaunched to the tab bar")

        let transcriptFace = app.buttons["face-transcript"].firstMatch
        let reopened = transcriptFace.waitForExistence(timeout: 30)
        shoot(app, "02-transcript-after-relaunch")
        if !reopened {
            add(XCTAttachment(string: "=== full tree ===\n" + app.debugDescription))
        }
        XCTAssertTrue(reopened,
                      "the transcript I was reading MUST reopen after the app was reclaimed — "
                      + "a relaunch is not a reason to put me back on the list")
    }
}
