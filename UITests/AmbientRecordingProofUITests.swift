// AmbientRecordingProofUITests — the simulator interaction proof for the OMI AMBIENT
// capture path, and the direct regression guard for the 2026-07-23 field report
// ("shows Listening and a timer but no transcript and I can't click on it to show the
// recording").
//
// WHY THIS EXISTS. RecordingProofUITests proves the PHONE-MIC Record-button path, and it
// passes — which is exactly why the ambient break shipped green. The ambient path is a
// DIFFERENT flow with no button: the Omi streams, a SPEECH ONSET opens a conversation on
// its own, the hero "Listening" tile carries the live session, and TAPPING that tile is
// the only way into the full recording page. None of that had UI coverage. `-SyntheticOmi`
// (DEBUG/PERF-only, leak-gated) substitutes the ambient `source:` with a synthetic frame
// source feeding real voiced Opus packets, so speech onset, beginSession, the WAL, the
// session clock, the live-transcript pump and the hero tile all run for real in the sim —
// only the Omi radio is stood in for.
//
// This is the UI→pipeline→output E2E: launch → talk (synthetic) → conversation OPENS →
// hero tile is live → TAP → recording page presents → clock ticks (it IS recording).

import XCTest

final class AmbientRecordingProofUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// The m:ss elapsed readout by IDENTIFIER (`recording-elapsed`) — never a blind m:ss
    /// text match, which can latch a seeded card's static timestamp behind the cover.
    private func elapsedSeconds(_ app: XCUIApplication) -> Int? {
        let label = app.staticTexts["recording-elapsed"].firstMatch
        guard label.exists else { return nil }
        let parts = label.label.split(separator: ":")
        guard parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]) else { return nil }
        return m * 60 + s
    }
    private func waitElapsed(_ app: XCUIApplication, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = elapsedSeconds(app) { return s }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return elapsedSeconds(app)
    }

    func testAmbientSpeechOpensATappableRecordingConversation() throws {
        let app = XCUIApplication()
        // -MainPreview mounts the real tabs (phone-only, captureSource defaults to .omi so
        // startSource() starts the ambient source); -SyntheticOmi makes that source feed
        // real voiced Opus packets → speech onset opens a conversation with NO button tap.
        app.launchArguments = ["-MainPreview", "-SyntheticOmi"]
        app.launch()

        let captureTab = app.buttons["Capture"].firstMatch
        XCTAssertTrue(captureTab.waitForExistence(timeout: 60), "app launched to the tab bar")
        captureTab.tap()

        // 1. Ambient speech onset OPENS a conversation with no button tap — the hero live
        //    tile appears (its Pause control, `live-hero-pause`, exists only for an active
        //    session). This is the "Listening" surface the user is looking at.
        let heroPause = app.buttons["live-hero-pause"].firstMatch
        if !heroPause.waitForExistence(timeout: 45) {
            // Diagnostic: what IS on screen? (record CTA? a "Listening" caption? the live
            // tile without a recorder? nothing?) — so the failure is legible, not blind.
            shoot(app, "DIAG-no-hero-tile")
            add(XCTAttachment(string: "record-cta exists: \(app.buttons["record-cta"].firstMatch.exists)\n"
                + "record-block-reason: \(app.staticTexts["record-block-reason"].firstMatch.exists)\n"
                + "any 'Listening' text: \(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Listening'")).count)\n"
                + "recording-elapsed exists: \(app.staticTexts["recording-elapsed"].firstMatch.exists)\n"
                + "=== full tree ===\n" + app.debugDescription))
        }
        XCTAssertTrue(heroPause.exists,
                      "talking to the Omi must OPEN a conversation (hero live tile), not sit on Listening forever")
        shoot(app, "01-ambient-live-tile")

        // 2. TAP the hero tile — the exact action that did NOTHING in the field. Tap the
        //    LEADING edge so hit-testing can't resolve the trailing Pause child (which would
        //    pause instead of open). This must present the full recording page.
        heroPause.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
        let minimize = app.buttons["minimize-recording"].firstMatch
        XCTAssertTrue(minimize.waitForExistence(timeout: 15),
                      "tapping the Listening tile MUST open the full recording page (field bug: it opened nothing)")
        shoot(app, "02-recording-page-open")

        // 3. The recording page shows a TICKING elapsed clock — proof it is genuinely
        //    recording (field bug: "can't tell if anything is actually recording at all").
        let firstElapsed = waitElapsed(app, timeout: 10)
        XCTAssertNotNil(firstElapsed, "the recording page shows an m:ss elapsed readout")
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        let ticked = elapsedSeconds(app)
        XCTAssertNotNil(ticked)
        XCTAssertGreaterThan(ticked ?? 0, firstElapsed ?? 0,
                             "the elapsed clock ticks while recording — the ambient conversation is really live")
        shoot(app, "03-recording-clock-ticking")
    }
}
