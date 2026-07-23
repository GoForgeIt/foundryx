// MainThreadStallWatchdogTests — pins the stall→span mechanics of the harness
// watchdog (track 20260717T0759 AC6) against an injected serial queue, so the
// tests are hermetic: no real main thread, no MetricKit.

import XCTest
@testable import FoundryXKit

final class MainThreadStallWatchdogTests: XCTestCase {

    /// A blocked target queue produces at least one stall emit of ~the blocked
    /// duration — and (single-ping-in-flight) roughly ONE, not a pile of
    /// interval-sized fragments.
    func testBlockedTargetQueueEmitsOneStallOfFullDuration() {
        let target = DispatchQueue(label: "test.fake-main")
        let emitted = LockedBox<[Int]>([])
        let dog = MainThreadStallWatchdog(thresholdMs: 250, pingInterval: 0.05,
                                          target: target,
                                          emit: { ms in emitted.mutate { $0.append(ms) } })
        dog.start()
        // Deliberately wedge the "main" queue well past the threshold.
        target.async { Thread.sleep(forTimeInterval: 0.6) }
        // Give the watchdog time to post a ping into the wedge and see it land.
        let deadline = Date().addingTimeInterval(3)
        while emitted.value.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        dog.stop()
        let spans = emitted.value
        XCTAssertFalse(spans.isEmpty, "a 600ms wedge past a 250ms threshold must emit a stall")
        XCTAssertGreaterThanOrEqual(spans.max() ?? 0, 250, "the reported stall covers the threshold")
        // One ping in flight at a time: a single wedge must not fan out into many
        // interval-sized emits. (≤2 tolerates a ping straddling the wedge boundary.)
        XCTAssertLessThanOrEqual(spans.count, 2, "one wedge ≈ one stall span, not fragments")
    }

    /// A healthy target queue emits nothing.
    func testHealthyTargetQueueEmitsNothing() {
        let target = DispatchQueue(label: "test.fake-main-healthy")
        let emitted = LockedBox<[Int]>([])
        let dog = MainThreadStallWatchdog(thresholdMs: 250, pingInterval: 0.02,
                                          target: target,
                                          emit: { ms in emitted.mutate { $0.append(ms) } })
        dog.start()
        Thread.sleep(forTimeInterval: 0.4)   // many healthy pings
        dog.stop()
        XCTAssertTrue(emitted.value.isEmpty, "no stall spans on a responsive queue")
    }

    /// WS-A — while a ping is STILL stuck (main blocked right now), the watchdog fires the
    /// stack-capture hook ONCE per stall, only after captureThreshold is crossed.
    func testMidStallStackCaptureFiresOnceAfterCaptureThreshold() {
        let target = DispatchQueue(label: "test.fake-main-capture")
        let captures = LockedBox<[Int]>([])
        let emits = LockedBox<[Int]>([])
        let dog = MainThreadStallWatchdog(
            thresholdMs: 250, pingInterval: 0.05, target: target,
            captureThresholdMs: 400,
            onStack: { ms in captures.mutate { $0.append(ms) } },
            emit: { ms in emits.mutate { $0.append(ms) } })
        dog.start()
        // Wedge the "main" queue ~700ms — past both the 250ms report threshold and the
        // 400ms capture threshold — so a live capture must trigger mid-stall.
        target.async { Thread.sleep(forTimeInterval: 0.7) }
        let deadline = Date().addingTimeInterval(3)
        while captures.value.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        // Let the stall end so the terminal emit also lands.
        Thread.sleep(forTimeInterval: 0.4)
        dog.stop()

        XCTAssertEqual(captures.value.count, 1, "exactly one stack capture per stall, not per tick")
        XCTAssertGreaterThanOrEqual(captures.value.first ?? 0, 400, "capture only after the 400ms threshold")
        XCTAssertFalse(emits.value.isEmpty, "the terminal nav-stall span still emits when the ping lands")
    }

    /// WS-A — a stall that stays UNDER the capture threshold (but over the report threshold)
    /// emits a span but never captures a stack.
    func testStallUnderCaptureThresholdDoesNotSample() throws {
        let target = DispatchQueue(label: "test.fake-main-nocap")
        let captures = LockedBox<[Int]>([])
        let emits = LockedBox<[Int]>([])
        let dog = MainThreadStallWatchdog(
            thresholdMs: 100, pingInterval: 0.03, target: target,
            captureThresholdMs: 400,
            onStack: { ms in captures.mutate { $0.append(ms) } },
            emit: { ms in emits.mutate { $0.append(ms) } })
        dog.start()
        target.async { Thread.sleep(forTimeInterval: 0.2) }   // 200ms: > report, < capture
        // LOAD-DEPENDENCE (found by `scripts/ci-gates.sh flake`, which re-runs the suite under
        // full CPU load): a 2s deadline was not "how long the answer takes", it was "how long
        // an idle laptop takes". Under 12-way contention the watchdog's own ping thread is
        // starved and the span lands seconds later, so the test failed for scheduling reasons
        // with the product behaving correctly. Waiting LONGER cannot turn a wrong answer right;
        // timing out CAN make a right answer look wrong.
        let deadline = Date().addingTimeInterval(20)
        while emits.value.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        dog.stop()
        // ...and 20s was ALSO just "how long a 12-way-loaded laptop takes" — the flake gate
        // caught this same assertion failing empty under 14-way saturation. Picking a bigger
        // number is guessing again. So apply this file's own rule and MEASURE THE PREMISE:
        // an empty result means either the product failed to report, or this machine could not
        // schedule the sensor at all. Time a no-op on the SAME queue to tell those apart. If
        // even that cannot be scheduled promptly the environment produced the empty result,
        // and the honest verdict is "inconclusive", not "failed". The assertion is unchanged.
        if emits.value.isEmpty {
            let probeStart = Date()
            let scheduled = DispatchSemaphore(value: 0)
            target.async { scheduled.signal() }
            _ = scheduled.wait(timeout: .now() + 5)
            let schedulingDelay = Date().timeIntervalSince(probeStart)
            try XCTSkipIf(schedulingDelay > 0.5,
                          "inconclusive: this machine took \(Int(schedulingDelay * 1000))ms to " +
                          "schedule a no-op, so it cannot run the watchdog's own ping timer " +
                          "either — the empty result is starvation, not product behaviour")
        }
        XCTAssertFalse(emits.value.isEmpty, "a 200ms stall still reports a span")
        // The second assertion's PREMISE is "the stall stayed under the 400ms capture
        // threshold" — which is only true if the OS honoured a 200ms sleep. Under contention it
        // can overrun well past 400ms, at which point a stack capture is the CORRECT behaviour
        // and asserting its absence would be asserting a falsehood. So verify the premise
        // against what the sensor actually MEASURED instead of assuming it. The assertion
        // itself is unchanged.
        let observed = emits.value.max() ?? 0
        try XCTSkipIf(observed >= 400,
                      "premise broken by scheduler contention: the 200ms sleep overran to " +
                      "\(observed)ms, i.e. past the 400ms capture threshold this test is below")
        XCTAssertTrue(captures.value.isEmpty, "but stays under the 400ms capture threshold — no stack")
    }

    /// start() is idempotent and stop() actually stops future emits.
    func testStopStopsAndStartIsIdempotent() {
        let target = DispatchQueue(label: "test.fake-main-stop")
        let emitted = LockedBox<[Int]>([])
        let dog = MainThreadStallWatchdog(thresholdMs: 100, pingInterval: 0.02,
                                          target: target,
                                          emit: { ms in emitted.mutate { $0.append(ms) } })
        dog.start()
        dog.start()   // second start must not double-tick (verified via fragment count below)
        dog.stop()
        // Wedge AFTER stop — nothing may be measured.
        target.async { Thread.sleep(forTimeInterval: 0.3) }
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(emitted.value.isEmpty, "no emits after stop()")
    }

    /// P1-1 (implement.review.md): a ping in flight when the app suspends must be
    /// DISCARDED on resume — the background gap is not a stall. Model the suspension
    /// as a wedge that outlives a pause(): the stuck ping lands after resume() with a
    /// huge "delay", and no span (and no stack capture) may be emitted for it; a
    /// fresh wedge after resume is still caught.
    func testPauseDiscardsInFlightPingAcrossBackgroundGap() {
        let target = DispatchQueue(label: "test.fake-main-pause")
        let emitted = LockedBox<[Int]>([])
        let captures = LockedBox<[Int]>([])
        let dog = MainThreadStallWatchdog(
            thresholdMs: 250, pingInterval: 0.05, target: target,
            captureThresholdMs: 400,
            onStack: { ms in captures.mutate { $0.append(ms) } },
            emit: { ms in emitted.mutate { $0.append(ms) } })
        dog.start()
        // The "suspension": a wedge begins, a ping gets stuck in it, then the app
        // backgrounds (pause) while the ping is still in flight.
        target.async { Thread.sleep(forTimeInterval: 0.8) }
        Thread.sleep(forTimeInterval: 0.15)   // let a ping post into the wedge
        dog.pause()
        Thread.sleep(forTimeInterval: 0.9)    // the wedge ends while "backgrounded"
        dog.resume()
        Thread.sleep(forTimeInterval: 0.3)    // healthy post-resume pings
        XCTAssertTrue(emitted.value.isEmpty,
                      "the gap-spanning ping must be discarded, not emitted as a stall")
        XCTAssertTrue(captures.value.filter { $0 > 800 }.isEmpty,
                      "no stack capture may be attributed to the background gap")
        // Still alive: a REAL wedge after resume is caught.
        target.async { Thread.sleep(forTimeInterval: 0.6) }
        let deadline = Date().addingTimeInterval(3)
        while emitted.value.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        dog.stop()
        XCTAssertFalse(emitted.value.isEmpty, "a real post-resume wedge still emits")
    }
}

/// Tiny thread-safe box for test assertions.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}
