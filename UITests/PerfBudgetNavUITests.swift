// PerfBudgetNavUITests — the DRIVER for sim-perf's nav-budget phase (track
// 20260717T0759 AC6). It does NOT assert timing itself: it drives the real app —
// stress-seeded to N=128 with real segment files — through the normal-nav motions
// (tab cycles, a record start), while the app's own instrumentation emits
// `tab-switch` / `record-start` / `nav-stall` perf spans to the unified log
// (`-PerfLog`). scripts/sim-perf.sh reads those spans back and enforces:
//
//     tab-switch   < 100 ms      record-start < 200 ms      nav-stall: NONE
//
// Splitting driver (XCUITest) from judge (harness script) keeps the budgets in ONE
// place, next to the hydrate/first-paint budgets, and keeps this test deterministic —
// it only asserts the drive succeeded (tabs present, recording surface presents).
//
// MIC: the harness pre-grants microphone (`simctl privacy … grant microphone`) so the
// record start is app latency, not a permission prompt. See RecordingProofUITests for
// the alert-monitor belt-and-suspenders pattern reused here.

import XCTest

final class PerfBudgetNavUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNormalNavDriveEmitsBudgetSpans() throws {
        let app = XCUIApplication()
        // Same stress profile as the launch phase: 128 captures, ~156 avg segment files
        // (skewed — a few 1000-4000-segment heavies), perf spans mirrored to the log.
        app.launchArguments = ["-MainPreview", "-PerfLog",
                               "-StressSeed", "128", "-StressSegs", "156"]

        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            for label in ["Allow While Using App", "Allow", "OK"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); return true }
            }
            return false
        }

        app.launch()

        // Land on Capture; generous timeout — first launch pays the synthetic seeding.
        let captureTab = app.buttons["Capture"].firstMatch
        XCTAssertTrue(captureTab.waitForExistence(timeout: 90), "app launched to the tab bar")
        captureTab.tap()

        // Let hydration land + the (5s-delayed) nav-stall watchdog arm, so the cycles
        // below run against the FULL 128-capture library under stall surveillance.
        RunLoop.current.run(until: Date().addingTimeInterval(7))

        // Two full tab cycles = 8 `tab-switch` spans against the hydrated library.
        for lap in 1...2 {
            for name in ["Activity", "Chat", "Settings", "Capture"] {
                let tab = app.buttons[name].firstMatch
                XCTAssertTrue(tab.waitForExistence(timeout: 10), "\(name) tab present")
                tab.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            }
            if lap == 1 { shoot(app, "nav-lap1-capture") }
        }

        // One real record start → the surface must present (record-start span emits).
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
        shoot(app, "nav-record-started")

        // Settle so the async span emits + the log line flushes before termination.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }
}
