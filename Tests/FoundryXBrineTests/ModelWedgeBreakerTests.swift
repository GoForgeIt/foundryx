import XCTest
import Foundation
import FoundryXKit

/// ModelWedgeBreaker — the session-scoped circuit breaker that stops a wedged on-device model
/// (Apple Foundation Models) from spawning a fresh ~86s CPU runaway at every call site (track
/// WS-C, 2026-07-17). Pure + deterministic: an injected monotonic clock drives every transition,
/// so open / refuse-while-open / half-open-single-probe / probe-success-closes / probe-wedge-reopens
/// / concurrent-probe are pinned WITHOUT any real time passing or any FoundationModels dependency.
final class ModelWedgeBreakerTests: XCTestCase {

    /// A mutable, injectable monotonic clock (seconds). Serial-only in these tests.
    private final class Clock: @unchecked Sendable {
        var now: TimeInterval
        init(_ start: TimeInterval = 0) { now = start }
        var read: @Sendable () -> TimeInterval { { [self] in now } }
    }

    private func makeBreaker(_ clock: Clock,
                             cooldown: TimeInterval = 600,
                             throttle: TimeInterval = 60) -> ModelWedgeBreaker {
        ModelWedgeBreaker(cooldownSeconds: cooldown, refusalThrottleSeconds: throttle, clock: clock.read)
    }

    // A fresh breaker is CLOSED — a turn proceeds normally.
    func testClosedProceedsByDefault() {
        let breaker = makeBreaker(Clock())
        XCTAssertEqual(breaker.admit(), .proceed)
        XCTAssertFalse(breaker.isRefusing)
    }

    // tripWedge OPENs the breaker: the very next admit is refused, with the full cool-down remaining.
    func testWedgeOpensAndRefuses() {
        let clock = Clock()
        let breaker = makeBreaker(clock, cooldown: 600)

        let remaining = breaker.tripWedge()
        XCTAssertEqual(remaining, 600_000, "trip reports the full 10-minute cool-down remaining")
        XCTAssertTrue(breaker.isRefusing)

        guard case .refused(let ms, _) = breaker.admit() else {
            return XCTFail("a turn while OPEN must be refused")
        }
        XCTAssertEqual(ms, 600_000, "refusal reports the remaining cool-down")
    }

    // Refuse-while-open: EVERY admit inside the cool-down is refused — the model is never called.
    func testRefusesEveryTurnWhileOpen() {
        let clock = Clock()
        let breaker = makeBreaker(clock, cooldown: 600)
        breaker.tripWedge()

        for step in 1...5 {
            clock.now = TimeInterval(step) * 60   // 1…5 minutes in — still inside the 10-min cool-down
            guard case .refused = breaker.admit() else {
                return XCTFail("still inside the cool-down at \(step)m — must refuse")
            }
        }
        // The remaining ms shrinks as the deadline approaches.
        clock.now = 300   // 5 minutes in → 5 minutes left
        guard case .refused(let ms, _) = breaker.admit() else { return XCTFail("must refuse") }
        XCTAssertEqual(ms, 300_000)
    }

    // Half-open single probe: once the cool-down elapses the FIRST admit is a probe (0 ms remaining).
    func testHalfOpenAllowsOneProbeAfterCooldown() {
        let clock = Clock()
        let breaker = makeBreaker(clock, cooldown: 600)
        breaker.tripWedge()

        clock.now = 600   // exactly at the cool-down edge
        XCTAssertEqual(breaker.admit(), .probe, "cool-down elapsed → one probe is allowed")
    }

    // Probe SUCCESS closes the breaker: turns proceed normally again.
    func testProbeSuccessClosesBreaker() {
        let clock = Clock()
        let breaker = makeBreaker(clock, cooldown: 600)
        breaker.tripWedge()

        clock.now = 601
        XCTAssertEqual(breaker.admit(), .probe)
        breaker.recordSuccess()

        XCTAssertFalse(breaker.isRefusing)
        XCTAssertEqual(breaker.admit(), .proceed, "a healthy probe restores normal operation")
    }

    // Probe WEDGE re-opens the breaker for a fresh full cool-down.
    func testProbeWedgeReopensBreaker() {
        let clock = Clock()
        let breaker = makeBreaker(clock, cooldown: 600)
        breaker.tripWedge()

        clock.now = 601
        XCTAssertEqual(breaker.admit(), .probe)
        let remaining = breaker.tripWedge()          // the probe wedged too
        XCTAssertEqual(remaining, 600_000)

        // A fresh cool-down measured from `now` (601): a turn at 1000s (399s later) still refuses.
        clock.now = 1000
        guard case .refused(let ms, _) = breaker.admit() else {
            return XCTFail("the probe wedged → re-open; still refusing")
        }
        XCTAssertEqual(ms, 201_000, "601+600=1201 deadline, 1000 now → 201s left")
    }

    // Concurrent probe attempts allow only ONE: the second admit (before the probe reports back)
    // is refused with 0 ms remaining; a probe is not double-spawned.
    func testConcurrentProbeAttemptsAllowOnlyOne() {
        let clock = Clock()
        let breaker = makeBreaker(clock, cooldown: 600)
        breaker.tripWedge()

        clock.now = 700
        XCTAssertEqual(breaker.admit(), .probe, "first admit after cool-down gets the probe")
        guard case .refused(let ms, _) = breaker.admit() else {
            return XCTFail("a second concurrent admit must be refused while the probe is in flight")
        }
        XCTAssertEqual(ms, 0, "half-open refusal carries 0 ms remaining")
    }

    // releaseProbe (a probe that failed with a non-wedge transient error) keeps the breaker
    // half-open: the NEXT admit probes again, rather than stranding the breaker forever.
    func testReleaseProbeKeepsHalfOpenForRetry() {
        let clock = Clock()
        let breaker = makeBreaker(clock, cooldown: 600)
        breaker.tripWedge()

        clock.now = 700
        XCTAssertEqual(breaker.admit(), .probe)
        breaker.releaseProbe()                 // transient (non-wedge) failure — free the slot

        XCTAssertEqual(breaker.admit(), .probe, "still half-open → the next admit probes again")
    }

    // The refusal-span hint is throttled to at most once per minute; the FIRST refusal always emits.
    func testRefusalSpanThrottledToOncePerMinute() {
        let clock = Clock()
        let breaker = makeBreaker(clock, cooldown: 600, throttle: 60)
        breaker.tripWedge()

        clock.now = 10
        guard case .refused(_, let first) = breaker.admit() else { return XCTFail("refuse") }
        XCTAssertTrue(first, "the first refusal emits its span")

        clock.now = 20   // 10s later — inside the 60s throttle
        guard case .refused(_, let second) = breaker.admit() else { return XCTFail("refuse") }
        XCTAssertFalse(second, "a refusal within the throttle window is silent")

        clock.now = 80   // 70s after the first — throttle elapsed
        guard case .refused(_, let third) = breaker.admit() else { return XCTFail("refuse") }
        XCTAssertTrue(third, "a refusal past the throttle window emits again")
    }

    // A healthy model is unaffected: repeated success keeps the breaker closed and proceeding.
    func testHealthyModelStaysClosed() {
        let breaker = makeBreaker(Clock())
        for _ in 0..<5 {
            XCTAssertEqual(breaker.admit(), .proceed)
            breaker.recordSuccess()
        }
        XCTAssertFalse(breaker.isRefusing)
    }
}
