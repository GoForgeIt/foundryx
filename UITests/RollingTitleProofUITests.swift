// RollingTitleProofUITests — the simulator proof that the recording screen's
// ROLLING title derives from the WHOLE conversation so far, not the last few
// seconds (track 20260717T1015; features/recording-instrument.feature "the name
// reflects the whole conversation, not the last words").
//
// It drives a REAL phone-mic recording under `-RollingTitleDemo`: the scripted
// live transcriber replays a known conversation (opens on the kitchen-renovation
// BUDGET, drifts to contractor PERMITS) through the real pipeline — pump →
// whole-context heuristic → arbiter → published `liveTitle` → this screen. The
// proof: the title APPEARS from the opening words, EVOLVES as the conversation
// grows, and the evolved name still carries the conversation's OPENING topic —
// exactly what the old last-80-words-window title could not do.
//
// MIC IN THE SIMULATOR (track 20260722T1601): the simulator's AVAudioEngine input node
// reports a degenerate `rate=0.0 ch=0` format, so the real `MicFrameSource` fails with
// "no microphone input available" and the recording surface never presents there.
// `-SyntheticMic` (DEBUG-only) feeds real Opus packets through the SAME capture pipeline
// so this proof runs end-to-end; the transcript itself still comes from the scripted
// transcriber, exactly as before.

import XCTest

final class RollingTitleProofUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func title(_ app: XCUIApplication) -> String? {
        let label = app.staticTexts["recording-title"].firstMatch
        return label.exists ? label.label : nil
    }

    func testRollingTitleDerivesFromTheWholeConversation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-RollingTitleDemo", "-SyntheticMic"]

        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }

        app.launch()

        let captureTab = app.buttons["Capture"].firstMatch
        if captureTab.waitForExistence(timeout: 15) { captureTab.tap() }

        // Start a recording — the scripted transcriber begins replaying finals.
        let recordCTA = app.buttons["record-cta"].firstMatch
        XCTAssertTrue(recordCTA.waitForExistence(timeout: 15), "record CTA present")
        recordCTA.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            for label in ["Allow While Using App", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                break
            }
        }
        let minimize = app.buttons["minimize-recording"].firstMatch
        XCTAssertTrue(minimize.waitForExistence(timeout: 20), "recording surface presents")

        // 1. The title appears once enough was said — from the OPENING topic.
        let titleLabel = app.staticTexts["recording-title"].firstMatch
        XCTAssertTrue(titleLabel.waitForExistence(timeout: 15),
                      "a provisional title appears from the spoken words")
        let early = try XCTUnwrap(title(app))
        shoot(app, "01-early-title")

        // 2. Let the conversation move well past its opening (the script drifts to
        // contractor permits; the 80-word display tail has fully slid off the
        // opening by the end).
        RunLoop.current.run(until: Date().addingTimeInterval(18))
        let evolved = try XCTUnwrap(title(app), "the title is still present late in the conversation")
        shoot(app, "02-evolved-title")

        // 3. The WHOLE-conversation proof: the evolved name still carries the
        // conversation's opening topic even though the recent words are all
        // contractor/permits — the old last-segment title could not do this.
        let lower = evolved.lowercased()
        XCTAssertTrue(lower.contains("kitchen") || lower.contains("budget") || lower.contains("renovation"),
                      "the evolved title keeps the opening topic: \(evolved)")
        XCTAssertTrue(lower.contains("contractor") || lower.contains("permits") || lower.contains("timeline"),
                      "the evolved title reflects where the conversation went: \(evolved)")
        // And it EVOLVED from the early name (updates based on the whole
        // conversation to that point).
        XCTAssertNotEqual(early, evolved, "the title updates as the conversation grows")

        // 4. Two-tier proof (track 20260717T1500): the EXTERNAL refresh (scripted
        // Fireworks stand-in) has sharpened the instant on-device placeholder on the
        // backoff — the evolved title is the external one, which the simulator's lack
        // of Apple Intelligence means could only come from the external tier.
        shoot(app, "03-external-sharpen")
        let externalTitles = ["Kitchen Renovation Budget Plan", "Kitchen Reno: Budget and Permits"]
        XCTAssertTrue(externalTitles.contains(evolved),
                      "the external refresh sharpened the live title on the backoff: \(evolved)")

        // Leave the simulator clean.
        let endAndSave = app.buttons["End and save"].firstMatch
        if endAndSave.waitForExistence(timeout: 5) { endAndSave.tap() }
    }
}
