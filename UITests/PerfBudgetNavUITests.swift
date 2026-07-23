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
        // Same stress profile as the launch phase: 175 captures (the reported stall onset —
        // NOT the old 128, which sat under the device's real library size), ~156 avg segment files
        // (skewed — a few 1000-4000-segment heavies), perf spans mirrored to the log.
        // `-SyntheticMic` (track 20260722T1601's seam, widened to PERF_HARNESS here): the
        // simulator's AVAudioEngine input node reports a degenerate `rate=0.0 ch=0` format, so
        // the real MicFrameSource correctly refuses and the recording surface can NEVER present
        // in a simulator. Without this the record-start leg of this drive failed for a reason
        // that had nothing to do with performance — "recording surface presents" was red on
        // every run, so the record-start budget it exists to feed was never actually measured.
        app.launchArguments = ["-MainPreview", "-PerfLog", "-SyntheticMic",
                               "-StressSeed", "175", "-StressSegs", "156"]

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

    /// The DEEP-nav drive (b232 residual-stall hunt): the tab cycle above never touches
    /// the three surfaces users actually live in — the capture-list SCROLL, the
    /// transcript page, and the speaker sheet. This drives all three against a heavier
    /// seed (-StressSegs 512 ≈ the backlogged-library warm storm) with the -PerfLog
    /// stall watchdog live, so any >250ms main-thread stall on those paths emits a
    /// `nav-stall` span the harness FAILS on. Same driver/judge split: this test only
    /// asserts the drive succeeded.
    func testDeepNavDriveListTranscriptAndSpeakerSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-PerfLog",
                               "-StressSeed", "175", "-StressSegs", "512"]
        app.launch()

        let captureTab = app.buttons["Capture"].firstMatch
        XCTAssertTrue(captureTab.waitForExistence(timeout: 120), "app launched to the tab bar")
        captureTab.tap()
        // Hydration + the 5s-delayed stall-watchdog arm: everything below runs under
        // stall surveillance against the full seeded library.
        RunLoop.current.run(until: Date().addingTimeInterval(8))

        // 1. Capture-list scroll storm (row build/recycle is a per-frame main-thread cost).
        for _ in 1...4 { app.swipeUp(velocity: .fast) }
        for _ in 1...4 { app.swipeDown(velocity: .fast) }
        shoot(app, "deep-list-scrolled")

        // 2. The transcript page: open whatever seeded conversation is HITTABLE after the
        //    storm (position-independent — the stress rows all carry a cached transcript).
        //    firstMatch alone can resolve to a virtualized row above the viewport.
        let rows = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Conversation "))
        var row: XCUIElement?
        for _ in 1...3 {
            let candidates = rows.allElementsBoundByIndex.prefix(8)
            row = candidates.first(where: { $0.isHittable })
            if row != nil { break }
            app.swipeDown(velocity: .fast)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        guard let row else { return XCTFail("no hittable conversation row after the storm") }
        row.tap()
        let transcriptPill = app.buttons["Transcript"].firstMatch
        XCTAssertTrue(transcriptPill.waitForExistence(timeout: 10), "detail opened (face picker)")

        // 3. Face switches — each rebuilds a face's view tree on the main thread.
        for name in ["Transcript", "Actions", "Summary", "Transcript"] {
            let pill = app.buttons[name].firstMatch
            if pill.exists { pill.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        app.swipeUp()
        app.swipeDown()
        shoot(app, "deep-transcript-face")

        // 4. Back to the list so the pop cost is measured too.
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }

        // Settle so trailing spans flush to the unified log before termination.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }

    /// THE CHURN-INTERLEAVED DRIVE (track 20260722T1244 — the CQRS hole).
    ///
    /// Every other drive in this file navigates a STATIC, pre-warmed, read-only library: pure
    /// QUERY side. The device pathology is a rebuild that runs a beat AFTER a COMMAND
    /// invalidated the read-model memos. This drive runs the commands — `-StressChurn` writes
    /// real segment appends, drain ACKs, status-poller card merges and finalizes against the
    /// seeded library every 200ms — WHILE navigating at N=175 on the skewed-heavy
    /// distribution. `scripts/sim-perf.sh` reads the resulting spans back and FAILS on any
    /// `nav-stall` over the ceiling (250ms — the production sensor's own threshold).
    ///
    /// SENSOR MECHANICS (spec R5): the `MainThreadStallWatchdog` is armed +5s after launch and
    /// rate-limited to ≤1 sample / 5s, ≤60 / session. The churn therefore starts at +6s and the
    /// drive below runs ~45s of continuous navigation under churn — long enough to clear the
    /// arm and to give a dozen sampling windows. A shorter drive could pass by never sampling.
    ///
    /// Same driver/judge split as the rest of the file: this test only asserts the drive
    /// happened; the budgets live in one place, in the harness script.
    func testChurnInterleavedNavDriveEmitsNoStalls() throws {
        let app = XCUIApplication()
        // S9 (review): the library size is the HARNESS's to choose. `scripts/sim-perf.sh` passes
        // it as `TEST_RUNNER_FX_STRESS_N`; the app announces the size it actually seeded
        // (`perf-harness: stress-seed n=…`) and the harness FAILS if it differs from the N the
        // run asked for — so a propagation failure is red, never a silent fallback to 175.
        let stressN = ProcessInfo.processInfo.environment["FX_STRESS_N"] ?? "175"
        // `-SyntheticMic` (S8): the churn drive starts a REAL recording, so `manager.active` is
        // non-nil for the whole drive and `invalidateSidecar`'s LIVE/throttled branch — the
        // highest-traffic write path during recording, and the one the "stale card up to 5s"
        // defect actually lived in — is exercised every tick. The simulator's AVAudioEngine
        // input reports a degenerate format, so without the synthetic source no recording can
        // ever start there and that branch stays uncovered.
        app.launchArguments = ["-MainPreview", "-PerfLog", "-SyntheticMic",
                               "-StressSeed", stressN, "-StressSegs", "156",
                               "-StressChurn", "200"]
        app.launch()

        let captureTab = app.buttons["Capture"].firstMatch
        XCTAssertTrue(captureTab.waitForExistence(timeout: 180), "app launched to the tab bar")
        captureTab.tap()

        // Hydration + the +5s watchdog arm + the +6s churn arm.
        RunLoop.current.run(until: Date().addingTimeInterval(9))

        // Start a recording and minimise it, so the nav laps below run with a LIVE capture
        // under continuous churn. The harness asserts a minimum `churn-write-live` span count,
        // so a recording that fails to start makes the gate red rather than quietly reducing
        // coverage back to the query-only case.
        let recordCTA = app.buttons["record-cta"].firstMatch
        if recordCTA.waitForExistence(timeout: 20) {
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
            if minimize.waitForExistence(timeout: 20) { minimize.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            shoot(app, "churn-recording-live")
        }

        // ~45s of interleaved navigation under continuous write traffic. Each lap touches the
        // three surfaces a cold-miss rebuild can stall: the tab switch (whole list rebuild),
        // the capture-list scroll (row build/recycle), and a detail open/close (recap pool +
        // sidecar reads). Nothing here asserts timing — the app's own sensor does.
        let deadline = Date().addingTimeInterval(45)
        var laps = 0
        while Date() < deadline {
            laps += 1
            for name in ["Activity", "Chat", "Settings", "Capture"] {
                let tab = app.buttons[name].firstMatch
                if tab.exists { tab.tap() }
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            }
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            if laps == 1 { shoot(app, "churn-lap1") }
        }
        XCTAssertGreaterThanOrEqual(laps, 3, "the churn drive ran multiple nav laps")
        shoot(app, "churn-final")

        // Settle so trailing spans flush to the unified log before termination.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
    }

    /// The SPEAKER-SHEET leg of the deep-nav hunt, driven deterministically via the
    /// `-Screen detail` harness (same seam SpeakerConfirmProofUITests uses) so it can't
    /// depend on list scroll position. The watchdog (-PerfLog, armed +5s) surveils the
    /// sheet present/dismiss — the b232 complaint's third surface.
    func testDeepNavSpeakerSheetUnderStallWatch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-PerfLog", "-Screen", "detail",
                               "-Capture", "omi-demo-2", "-Face", "transcript"]
        app.launch()

        // The detail opens on the Summary face; switch to Transcript so the diarized
        // (speaker-labeled) rows render, then let the stall watchdog arm (+5s).
        let transcriptPill = app.buttons["Transcript"].firstMatch
        XCTAssertTrue(transcriptPill.waitForExistence(timeout: 20), "detail opened (face picker)")
        transcriptPill.tap()
        // The speaker row is a COMBINED accessibility element (isButton trait) whose
        // label begins with the speaker's display name — not a bare "Dana" static text.
        let danaRow = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Dana"))
            .firstMatch
        XCTAssertTrue(danaRow.waitForExistence(timeout: 10), "diarized transcript renders")
        RunLoop.current.run(until: Date().addingTimeInterval(6))

        // Open the speaker sheet (tap a diarized turn row), settle, dismiss.
        danaRow.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shoot(app, "deep-speaker-sheet")
        app.swipeDown()   // dismiss the sheet
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        // Settle so trailing spans flush to the unified log before termination.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }
}
