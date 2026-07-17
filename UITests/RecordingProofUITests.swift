// RecordingProofUITests — the simulator interaction proof for phone-mic recording
// (track 20260717T0630). It drives a REAL phone-mic recording in the simulator (the
// `-MainPreview` harness mounts the real tabs with a real `MicFrameSource`, so the mic,
// Opus, WAL, live-transcript and METER pipeline all run for real), and proves the two
// correctness fixes end-to-end with attached screenshots:
//
//   • Bug 1 (session-owned clock): the elapsed readout ticks while recording, and a
//     minimize → wait → restore shows the CONTINUED time (strictly greater, NOT reset).
//   • Bug 2 (session-aware meter): the recording surface presents and stays live; the
//     ring is DRAWING (its levels can't be read through XCUITest, so this test does not
//     overclaim the ring energy — it attaches the screenshots as the visual evidence and
//     asserts the surface presents + the timer advances, which is the strongest honest
//     signal available at the UI-test layer). The meter-lifecycle state machine itself is
//     proven directly in MeterLifecycleTests (Tests/FoundryXBrineTests).
//
// MIC PRIVACY: the recording only begins once mic permission is granted. This test both
// registers a UIInterruptionMonitor to accept the system prompt AND relies on the runner
// having pre-granted it. The reliable path is to grant before launching:
//
//     xcrun simctl privacy booted grant microphone com.goforgeit.foundryx
//
// (bundle id from project.yml → FoundryX target PRODUCT_BUNDLE_IDENTIFIER). Without a
// grant the record CTA silently no-ops and the recording surface never presents.

import XCTest

final class RecordingProofUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The m:ss elapsed readout on the recording surface — read by IDENTIFIER
    /// (`recording-elapsed`, the ring-center SessionElapsedLabel), never by an app-wide
    /// m:ss text match: seeded cards behind the cover render static timestamps that a
    /// blind `firstMatch` can latch onto (and a timestamp never ticks).
    private func elapsedSeconds(_ app: XCUIApplication) -> Int? {
        let label = app.staticTexts["recording-elapsed"].firstMatch
        guard label.exists else { return nil }
        let parts = label.label.split(separator: ":")
        guard parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]) else { return nil }
        return m * 60 + s
    }

    /// Wait until an m:ss readout is on screen, returning its parsed seconds.
    private func waitElapsed(_ app: XCUIApplication, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = elapsedSeconds(app) { return s }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return elapsedSeconds(app)
    }

    func testPhoneMicRecordingTimerAndSurface() throws {
        let app = XCUIApplication()
        // -MainPreview mounts the real tabs (phone-only) with a real MicFrameSource, over
        // demo-seeded cards — so the record CTA is on the Capture surface and tapping it
        // drives a genuine mic recording.
        app.launchArguments = ["-MainPreview"]

        // Accept the mic-permission system alert if it appears (belt-and-suspenders with the
        // simctl pre-grant documented above).
        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }

        app.launch()

        // Land on the Capture tab (the record CTA lives there).
        let captureTab = app.buttons["Capture"].firstMatch
        if captureTab.waitForExistence(timeout: 15) { captureTab.tap() }

        // 1. Start a real phone-mic recording.
        let recordCTA = app.buttons["record-cta"].firstMatch
        XCTAssertTrue(recordCTA.waitForExistence(timeout: 15), "record CTA present on the Capture surface")
        recordCTA.tap()
        // Service the mic-permission alert TARGETED (never a blind app.tap() — that taps
        // the center of whatever is up and can trigger an unintended action): if the
        // springboard alert appears, tap its allow button directly.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            for label in ["Allow While Using App", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                break
            }
        }

        // 2. The full-screen recording surface presents (its minimize control is unique to it).
        let minimize = app.buttons["minimize-recording"].firstMatch
        XCTAssertTrue(minimize.waitForExistence(timeout: 20),
                      "the full-screen recording surface presents on record (mic granted)")

        // 3. The elapsed readout is ticking — read it, wait ~8s, assert it advanced.
        let firstElapsed = waitElapsed(app, timeout: 10)
        XCTAssertNotNil(firstElapsed, "the recording surface shows an m:ss elapsed readout")
        shoot(app, "01-recording-fresh")
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        let tickedElapsed = elapsedSeconds(app)
        XCTAssertNotNil(tickedElapsed)
        XCTAssertGreaterThan(tickedElapsed ?? 0, firstElapsed ?? 0,
                             "the elapsed clock ticks while recording (Bug 1: session clock advances)")

        // 4. Minimize — recording keeps running. On the CAPTURE tab the hero live tile is
        // the way back (track 20260717T0600 T1 suppresses the pill there as redundant);
        // the persistent pill owns every OTHER tab — so wander to Activity, where the
        // pill must appear. This is also the truer cross-tab repro of the reported bug.
        let preMinimize = tickedElapsed ?? 0
        minimize.tap()
        let activityTab = app.buttons["Activity"].firstMatch
        XCTAssertTrue(activityTab.waitForExistence(timeout: 10), "Activity tab reachable while minimized")
        activityTab.tap()
        // The pill's combined accessibility element inherits the button trait from its
        // "End" child, so it surfaces as a Button (not Other).
        let pill = app.buttons["recording-pill"].firstMatch
        if !pill.waitForExistence(timeout: 12) {
            // Diagnostic: dump what IS on screen so a pill-visibility regression is legible.
            add(XCTAttachment(string: app.debugDescription))
        }
        XCTAssertTrue(pill.exists,
                      "the recording pill appears off the capture tab while minimized (recording continues)")
        shoot(app, "02-minimized-pill")

        // 5. Wait minimized (below the silence gap), then restore via the pill BODY.
        // Tap the pill's LEADING edge explicitly: the combined element's center can drift
        // toward the trailing "End" child as the elapsed text widens, and hit-testing
        // resolves the real End button — which would END the recording instead of restore.
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        pill.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()

        // 6. Restored surface shows the CONTINUED elapsed (>= pre-minimize + ~8s), not reset.
        XCTAssertTrue(minimize.waitForExistence(timeout: 15), "the recording surface re-presents on restore")
        let restoredElapsed = waitElapsed(app, timeout: 10)
        XCTAssertNotNil(restoredElapsed, "the restored surface shows the elapsed readout")
        XCTAssertGreaterThanOrEqual(restoredElapsed ?? 0, preMinimize + 8,
                                    "restore shows CONTINUED elapsed, not a reset clock (Bug 1)")
        shoot(app, "03-restored-continued")

        // 7. End and save — leave the simulator clean.
        let endAndSave = app.buttons["End and save"].firstMatch
        if endAndSave.waitForExistence(timeout: 5) {
            endAndSave.tap()
        } else {
            app.buttons["End recording"].firstMatch.tap()
        }
    }
}
