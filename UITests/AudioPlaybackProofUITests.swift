// AudioPlaybackProofUITests — the simulator interaction proof for the b232 audio-playback
// fixes. Drives the REAL app over the demo library (`-MainPreview`, capture `omi-demo-2`)
// and attaches screenshots of:
//   BUG 1 — the tag-sheet voice sample plays the TAPPED line's own clip. In omi-demo-2,
//           "Dana" speaks twice: an early line (0–8200ms) and a later, LONGER line
//           (17900–27800ms). Tapping the early line samples 0–8200; tapping the later
//           line samples 17900–27800. The old bug always sampled the slot's LONGEST
//           utterance (17900–27800) whichever line you tapped — so it "didn't play the
//           selected piece". The sheet's "Hear this voice" button carries a DEBUG
//           accessibility id naming the exact clip window, so the proof can ASSERT it.
//   GAP 2 — the whole-conversation "Listen" control is a real transport: Stop + a
//           scrubber + an "elapsed / total" readout (driven here by `-AudioProof playing`).
//
// DEBUG-only hooks (`-MainPreview`, `-AudioProof`, the `hear-voice-window-*` id) never
// ship — they exist so the simulator can prove the behavior deterministically.

import XCTest

final class AudioPlaybackProofUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchDetail(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-Screen", "detail", "-Capture", "omi-demo-2"] + extra
        app.launch()
        return app
    }

    /// Tap the transcript row whose combined label contains `text` (GrainSpeakerRow folds
    /// name + time + words into one accessibility element; the row's tap opens the sheet).
    private func tapRow(_ app: XCUIApplication, containing text: String) {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 12), "transcript row '\(text)' renders")
        match.tap()
    }

    // ── BUG 1: the sample follows the SELECTED line ───────────────────────────

    func testVoiceSampleOfEarlyTappedLine() throws {
        let app = launchDetail(["-Face", "transcript"])
        tapRow(app, containing: "inspection is Friday")   // Dana's EARLY line (0–8200ms)
        XCTAssertTrue(app.staticTexts["Tag speaker"].waitForExistence(timeout: 5), "tag sheet opens")
        XCTAssertTrue(app.buttons["hear-voice-window-0-8200"].waitForExistence(timeout: 5),
                      "the sample is the TAPPED line's clip (0–8200ms)")
        XCTAssertFalse(app.buttons["hear-voice-window-17900-27800"].exists,
                       "it must NOT fall back to the slot's longest utterance (17900–27800ms)")
        shoot(app, "01-sample-of-early-tapped-line")
        app.terminate()
    }

    func testVoiceSampleOfLaterTappedLine() throws {
        let app = launchDetail(["-Face", "transcript"])
        tapRow(app, containing: "closing before the end")   // Dana's LATER line (17900–27800ms)
        XCTAssertTrue(app.staticTexts["Tag speaker"].waitForExistence(timeout: 5), "tag sheet opens")
        XCTAssertTrue(app.buttons["hear-voice-window-17900-27800"].waitForExistence(timeout: 5),
                      "the OTHER line samples ITS OWN clip (17900–27800ms) — the sample follows the tap")
        shoot(app, "02-sample-of-later-tapped-line")
        app.terminate()
    }

    // ── GAP 2: whole-conversation playback, with progress ─────────────────────

    func testWholeConversationPlaybackShowsScrubberAndElapsed() throws {
        let app = launchDetail(["-AudioProof", "playing"])
        let scrubber = app.sliders["listen-scrubber"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 12),
                      "the whole-conversation scrubber renders while playing")
        XCTAssertTrue(app.staticTexts["listen-elapsed"].waitForExistence(timeout: 5),
                      "an elapsed / total readout shows how far into the conversation playback is")
        XCTAssertTrue(app.buttons["Stop"].exists, "Stop is available")
        shoot(app, "03-whole-conversation-playing-progress")
        app.terminate()
    }
}
