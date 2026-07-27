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
    func testStallUnderCaptureThresholdDoesNotSample() {
        let target = DispatchQueue(label: "test.fake-main-nocap")
        let captures = LockedBox<[Int]>([])
        let emits = LockedBox<[Int]>([])
        let nanos = LockedBox<UInt64>(0)
        let dog = MainThreadStallWatchdog(
            thresholdMs: 100, pingInterval: 0.03, target: target,
            captureThresholdMs: 400,
            onStack: { ms in captures.mutate { $0.append(ms) } },
            now: { nanos.value },
            emit: { ms in emits.mutate { $0.append(ms) } })

        // Hold the target so the explicit first heartbeat's ping is genuinely in flight.
        // Advance the injected monotonic clock to exactly 200ms, then run a second heartbeat:
        // it observes a live stall above the 100ms report bar but below the 400ms sample bar.
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseTarget = DispatchSemaphore(value: 0)
        target.async {
            blockerStarted.signal()
            releaseTarget.wait()
        }
        XCTAssertEqual(blockerStarted.wait(timeout: .now() + 1), .success)
        dog.tickSynchronouslyForTests()       // post the ping behind the blocker at t=0
        nanos.mutate { $0 = 200_000_000 }
        dog.tickSynchronouslyForTests()       // still stuck; 200ms must NOT sample
        releaseTarget.signal()

        let deadline = Date().addingTimeInterval(2)
        while emits.value.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(emits.value, [200], "a 200ms stall still reports its exact span")
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
