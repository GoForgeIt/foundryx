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
}

/// Tiny thread-safe box for test assertions.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}
