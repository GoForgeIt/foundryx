// ForegroundRestoreProofUITests — the app-lifecycle gap.
//
// WHY THIS FILE EXISTS
// --------------------
// Thirteen UI proof suites existed and NOT ONE of them backgrounded the app. Every flow was
// asserted inside a single uninterrupted foreground session, so every failure mode that needs
// a lifecycle transition was invisible. Nick hit exactly that on device (2026-07-27):
//
//   "when i change focus to another app then come back then the 'listening' deal at the top
//    stops showing the pause and when i click on it nothing happens also it's not showing the
//    live transcript anymore"
//
// The card shell survives; the CONTROLS and the LIVE CONTENT do not. That is the signature of
// a view that rebuilds without re-attaching its publishers — the hero's control state and the
// live transcript are subscriptions, not durable reads, so a dropped subscription renders an
// empty shell over a WAL that still has the content.
//
// Switching apps is the most common thing a real user does and was the least covered thing in
// the suite. This proof closes that: it backgrounds the app mid-conversation, comes back, and
// asserts the surface is still USABLE — not merely present.

import XCTest

final class ForegroundRestoreProofUITests: XCTestCase {

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func elapsedSeconds(_ app: XCUIApplication) -> Int? {
        let label = app.staticTexts["recording-elapsed"].firstMatch
        guard label.exists else { return nil }
        let parts = label.label.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    private func waitElapsed(_ app: XCUIApplication, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = elapsedSeconds(app) { return s }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return nil
    }

    /// Background the app while a conversation is live, come back, and require the listening
    /// surface to still WORK: pause is offered, the tile opens the recording page, and the
    /// elapsed clock is still advancing. Each assertion is one of the three things Nick lost.
    func testListeningSurfaceSurvivesBackgroundingAndStaysUsable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-SyntheticOmi"]
        app.launch()

        let captureTab = app.buttons["Capture"].firstMatch
        XCTAssertTrue(captureTab.waitForExistence(timeout: 60), "app launched to the tab bar")
        captureTab.tap()

        // Premise: ambient speech opens a conversation, exactly as AmbientRecordingProof does.
        let heroPause = app.buttons["live-hero-pause"].firstMatch
        XCTAssertTrue(heroPause.waitForExistence(timeout: 45),
                      "premise: talking to the Omi opens a conversation (hero live tile)")
        let beforeElapsed = waitElapsed(app, timeout: 10)
        shoot(app, "01-live-before-backgrounding")

        // THE LIFECYCLE TRANSITION — the thing no other proof does.
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "app came back to the foreground")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shoot(app, "02-after-returning")

        // 1. The PAUSE control must still be offered. Nick: "stops showing the pause".
        //    A live conversation the user cannot pause is a consent problem, not a cosmetic one.
        let heroPauseAfter = app.buttons["live-hero-pause"].firstMatch
        if !heroPauseAfter.waitForExistence(timeout: 15) {
            add(XCTAttachment(string:
                "any 'Listening' text: \(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Listening'")).count)\n"
                + "recording-elapsed exists: \(app.staticTexts["recording-elapsed"].firstMatch.exists)\n"
                + "=== full tree ===\n" + app.debugDescription))
            shoot(app, "DIAG-no-pause-after-foreground")
        }
        XCTAssertTrue(heroPauseAfter.exists,
                      "after returning from another app the listening tile MUST still offer Pause "
                      + "(field bug: the pause control disappeared)")

        // 2. Tapping it must still OPEN the recording page. Nick: "when i click on it nothing happens".
        heroPauseAfter.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
        let minimize = app.buttons["minimize-recording"].firstMatch
        XCTAssertTrue(minimize.waitForExistence(timeout: 15),
                      "after returning, tapping the listening tile MUST still open the full recording "
                      + "page (field bug: tapping did nothing)")
        shoot(app, "03-recording-page-after-foreground")

        // 3. The session must still be LIVE, not a frozen shell. The clock still ticks.
        let afterElapsed = waitElapsed(app, timeout: 10)
        XCTAssertNotNil(afterElapsed,
                        "the recording page still shows an elapsed readout after backgrounding")
        if let before = beforeElapsed, let after = afterElapsed {
            XCTAssertGreaterThanOrEqual(
                after, before,
                "the SAME conversation continues across the app switch — a smaller elapsed value "
                + "means the session was silently restarted underneath the surface")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        let ticked = elapsedSeconds(app)
        XCTAssertNotNil(ticked)
        XCTAssertGreaterThan(ticked ?? 0, afterElapsed ?? 0,
                             "the elapsed clock still ticks after returning — the conversation is "
                             + "genuinely still recording, not a frozen card")
    }

    /// The live transcript is the other thing that vanished. It must render while recording AND
    /// still be there after an app switch — a dropped subscription must not read as "no words".
    func testLiveTranscriptRendersAndSurvivesBackgrounding() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-SyntheticOmi", "-SyntheticTranscript"]
        app.launch()

        let captureTab = app.buttons["Capture"].firstMatch
        XCTAssertTrue(captureTab.waitForExistence(timeout: 60), "app launched to the tab bar")
        captureTab.tap()

        let heroPause = app.buttons["live-hero-pause"].firstMatch
        XCTAssertTrue(heroPause.waitForExistence(timeout: 45), "premise: a conversation is open")
        heroPause.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["minimize-recording"].firstMatch.waitForExistence(timeout: 15),
                      "premise: the full recording page is open")

        // The live transcript must appear on the recording page while recording.
        // `-SyntheticOmi` opens the REAL ambient conversation and `-SyntheticTranscript`
        // substitutes only the LiveTranscriber word producer. RecordingScreen, its binding,
        // and the foreground restoration path remain the production path.
        let transcript = app.staticTexts["live-transcript"].firstMatch
        if !transcript.waitForExistence(timeout: 60) {
            add(XCTAttachment(string: "=== full tree ===\n" + app.debugDescription))
            shoot(app, "DIAG-no-live-transcript")
        }
        XCTAssertTrue(transcript.exists,
                      "the recording page shows the LIVE transcript while recording "
                      + "(field bug: no transcript on the recording page)")

        // PREMISE, asserted separately so the failure is legible: words must actually
        // appear BEFORE the app switch. Without this, "blank after foregrounding" is
        // indistinguishable from "blank the whole time", and the test would blame the
        // wrong defect. `-SyntheticTranscript` emits deterministic words through the
        // LiveTranscribing stream; give the real binding time to render them.
        let wordsDeadline = Date().addingTimeInterval(45)
        while transcript.label.isEmpty, Date() < wordsDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        if transcript.label.isEmpty {
            add(XCTAttachment(string: "=== full tree ===\n" + app.debugDescription))
            shoot(app, "DIAG-transcript-never-had-words")
        }
        XCTAssertFalse(transcript.label.isEmpty,
                       "PREMISE: the live transcript renders WORDS while recording. If this fails, "
                       + "the defect is that no transcript ever renders — not that it is lost on "
                       + "foregrounding.")
        let before = transcript.label
        shoot(app, "01-transcript-before-backgrounding")

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "app came back to the foreground")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shoot(app, "02-transcript-after-returning")

        let after = app.staticTexts["live-transcript"].firstMatch
        XCTAssertTrue(after.waitForExistence(timeout: 20),
                      "after returning from another app the live transcript MUST still render "
                      + "(field bug: 'it's not showing the live transcript anymore')")
        XCTAssertFalse(after.label.isEmpty,
                       "the restored transcript is not blank — the words already captured are "
                       + "still shown, not lost with the dropped subscription")
        XCTAssertTrue(
            after.label.hasPrefix(before),
            "the restored transcript retains the words captured before the app switch "
            + "instead of restarting from empty")

        // The replacement LiveTranscriber must remain wired to the same RecordingScreen
        // binding after foregrounding. A non-empty retained snapshot alone proves restore,
        // but not that new speech can still grow it.
        let growthDeadline = Date().addingTimeInterval(20)
        while after.label.count <= before.count, Date() < growthDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertGreaterThan(
            after.label.count, before.count,
            "the same conversation's live transcript continues GROWING with new speech "
            + "after returning to the app")
    }
}
