import XCTest
@testable import FoundryXKit

/// The pure hysteresis machine behind the capture-screen sync strip (WS-B). These drive
/// `SyncBarPresenter` directly with a synthetic clock, proving the debounce (appear
/// delay) and the anti-flicker minimum-show contract across the tricky sequences.
final class SyncBarPresenterTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // MARK: Appear delay (debounce)

    func testStartsSettled() {
        let p = SyncBarPresenter()
        XCTAssertEqual(p.presentation, .settled)
    }

    func testDoesNotShowBeforeAppearDelay() {
        var p = SyncBarPresenter()
        XCTAssertEqual(p.step(syncing: true, now: at(0)), .settled)
        XCTAssertEqual(p.step(syncing: true, now: at(1.0)), .settled)   // <1.5s
        XCTAssertEqual(p.step(syncing: true, now: at(1.5)), .settled)   // exactly 1.5 ⇒ not yet
    }

    func testShowsOnceContinuouslyActivePastAppearDelay() {
        var p = SyncBarPresenter()
        _ = p.step(syncing: true, now: at(0))
        XCTAssertEqual(p.step(syncing: true, now: at(1.6)), .syncing)   // strictly past 1.5s
    }

    func testBriefSyncNeverShows() {
        var p = SyncBarPresenter()
        XCTAssertEqual(p.step(syncing: true, now: at(0)), .settled)
        XCTAssertEqual(p.step(syncing: true, now: at(0.8)), .settled)
        XCTAssertEqual(p.step(syncing: false, now: at(0.9)), .settled)  // stopped before delay
        // Even if it comes back later, the clock restarts — a single brief blip is invisible.
        XCTAssertEqual(p.step(syncing: false, now: at(3.0)), .settled)
    }

    func testAppearDelayResetsOnFlap() {
        var p = SyncBarPresenter()
        _ = p.step(syncing: true, now: at(0))
        _ = p.step(syncing: true, now: at(1.2))     // almost there…
        _ = p.step(syncing: false, now: at(1.3))    // …but it dropped, resetting the clock
        _ = p.step(syncing: true, now: at(1.4))     // new run starts here
        // 1.0s into the NEW run — still under the appear delay, so nothing shows.
        XCTAssertEqual(p.step(syncing: true, now: at(2.4)), .settled)
        // Past the delay measured from the new run's start ⇒ now it shows.
        XCTAssertEqual(p.step(syncing: true, now: at(3.1)), .syncing)
    }

    // MARK: Minimum show (anti-flicker)

    func testHoldsForMinimumShowAfterCompletion() {
        var p = SyncBarPresenter()
        _ = p.step(syncing: true, now: at(0))
        XCTAssertEqual(p.step(syncing: true, now: at(2.0)), .syncing)   // shown at t=2.0
        // Drain finishes immediately; must hold for ≥3s from when it showed.
        XCTAssertEqual(p.step(syncing: false, now: at(2.0)), .syncing)
        XCTAssertEqual(p.step(syncing: false, now: at(4.0)), .syncing)  // +2.0s < 3s
        XCTAssertEqual(p.step(syncing: false, now: at(4.99)), .syncing) // +2.99s < 3s
        XCTAssertEqual(p.step(syncing: false, now: at(5.0)), .settled)  // +3.0s ⇒ settle
    }

    func testCompletionExactlyAtShowStillHoldsFullWindow() {
        var p = SyncBarPresenter()
        _ = p.step(syncing: true, now: at(0))
        _ = p.step(syncing: true, now: at(1.6))                        // shown at 1.6
        XCTAssertEqual(p.step(syncing: false, now: at(1.6)), .syncing) // finished at show time
        XCTAssertEqual(p.step(syncing: false, now: at(4.5)), .syncing) // 2.9s later, still held
        XCTAssertEqual(p.step(syncing: false, now: at(4.6)), .settled) // 3.0s later, settled
    }

    func testResumingDuringMinimumShowKeepsShowing() {
        var p = SyncBarPresenter()
        _ = p.step(syncing: true, now: at(0))
        _ = p.step(syncing: true, now: at(2.0))                        // shown
        _ = p.step(syncing: false, now: at(2.5))                       // brief pause
        XCTAssertEqual(p.step(syncing: true, now: at(2.8)), .syncing)  // resumed ⇒ stays shown
        // Still syncing well past the original window — obviously stays shown.
        XCTAssertEqual(p.step(syncing: true, now: at(9.0)), .syncing)
        // And when it finally finishes, the min-show is anchored to the ORIGINAL show.
        XCTAssertEqual(p.step(syncing: false, now: at(9.0)), .settled) // long past 3s from show
    }

    // MARK: Rapid flap sequences

    func testRapidFlapNeverShows() {
        var p = SyncBarPresenter()
        var everShown = false
        for i in 0..<20 {
            let now = at(Double(i) * 0.2)
            let syncing = (i % 2 == 0)               // on/off every 0.2s — never continuous 1.5s
            if p.step(syncing: syncing, now: now) == .syncing { everShown = true }
        }
        XCTAssertFalse(everShown, "a rapidly flapping sync should never surface the bar")
    }

    func testSustainedAfterFlapShowsAndHoldsOnce() {
        var p = SyncBarPresenter()
        // Some noise…
        _ = p.step(syncing: true, now: at(0))
        _ = p.step(syncing: false, now: at(0.3))
        _ = p.step(syncing: true, now: at(0.6))
        _ = p.step(syncing: false, now: at(0.9))
        // …then a real, sustained drain from t=1.0.
        _ = p.step(syncing: true, now: at(1.0))
        XCTAssertEqual(p.step(syncing: true, now: at(2.6)), .syncing)   // 1.6s continuous ⇒ shown
        XCTAssertEqual(p.step(syncing: false, now: at(2.6)), .syncing)  // holds…
        XCTAssertEqual(p.step(syncing: false, now: at(5.6)), .settled)  // …3s later, settles
    }

    // MARK: Layout + copy contracts (single source of truth)

    func testStripHeightIsConstantAcrossPresentations() {
        XCTAssertEqual(SyncStripLayout.height(for: .syncing),
                       SyncStripLayout.height(for: .settled))
        XCTAssertEqual(SyncStripLayout.height(for: .syncing), SyncStripLayout.totalHeight)
    }

    func testSettledCopyIsTierAware() {
        XCTAssertEqual(SyncStripCopy.allSaved(local: true), "All voice notes saved")
        XCTAssertEqual(SyncStripCopy.allSaved(local: false), "All voice notes saved to computer")
    }
}
