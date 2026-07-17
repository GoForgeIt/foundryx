import XCTest
import Foundation
import FoundryXKit

/// Pure derivation tests for `RecordingClock` — the session-owned, pause-aware elapsed
/// clock (track 20260717T0630). No manager, no views: just the value type's math.
final class RecordingClockTests: XCTestCase {

    // MARK: elapsed derivation

    func testElapsedIsWallClockSinceStartWhenNeverPaused() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let clock = RecordingClock(startedAt: t0)
        XCTAssertEqual(clock.elapsed(now: t0), 0, accuracy: 0.0001)
        XCTAssertEqual(clock.elapsed(now: t0.addingTimeInterval(42)), 42, accuracy: 0.0001)
    }

    // MARK: pause freezes elapsed

    func testPauseFreezesElapsed() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        var clock = RecordingClock(startedAt: t0)
        clock.pause(at: t0.addingTimeInterval(10))   // paused at 10s
        // While paused, elapsed holds at the pause instant no matter how far now advances.
        XCTAssertEqual(clock.elapsed(now: t0.addingTimeInterval(10)), 10, accuracy: 0.0001)
        XCTAssertEqual(clock.elapsed(now: t0.addingTimeInterval(30)), 10, accuracy: 0.0001)
        XCTAssertEqual(clock.elapsed(now: t0.addingTimeInterval(120)), 10, accuracy: 0.0001)
        XCTAssertTrue(clock.isPaused)
    }

    // MARK: resume continues without a jump

    func testResumeContinuesWithoutJump() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        var clock = RecordingClock(startedAt: t0)
        clock.pause(at: t0.addingTimeInterval(10))    // recorded 10s so far
        clock.resume(at: t0.addingTimeInterval(40))   // paused for 30s
        XCTAssertFalse(clock.isPaused)
        // At 50s wall-clock, 30s were paused → 20s actually recorded (no jump back to 50).
        XCTAssertEqual(clock.elapsed(now: t0.addingTimeInterval(50)), 20, accuracy: 0.0001)
        // Advancing after resume ticks up normally.
        XCTAssertEqual(clock.elapsed(now: t0.addingTimeInterval(55)), 25, accuracy: 0.0001)
        XCTAssertEqual(clock.pausedAccumulated, 30, accuracy: 0.0001)
    }

    func testMultiplePauseSpansAccumulate() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var clock = RecordingClock(startedAt: t0)
        clock.pause(at: t0.addingTimeInterval(5));  clock.resume(at: t0.addingTimeInterval(15))  // +10 paused
        clock.pause(at: t0.addingTimeInterval(20)); clock.resume(at: t0.addingTimeInterval(23))  // +3 paused
        XCTAssertEqual(clock.pausedAccumulated, 13, accuracy: 0.0001)
        // 30s wall-clock − 13s paused = 17s recorded.
        XCTAssertEqual(clock.elapsed(now: t0.addingTimeInterval(30)), 17, accuracy: 0.0001)
    }

    // MARK: idempotence

    func testDoublePauseKeepsOriginalOrigin() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var clock = RecordingClock(startedAt: t0)
        clock.pause(at: t0.addingTimeInterval(10))
        clock.pause(at: t0.addingTimeInterval(25))   // a second pause must NOT move the origin
        clock.resume(at: t0.addingTimeInterval(30))  // paused span = 30 − 10 = 20
        XCTAssertEqual(clock.pausedAccumulated, 20, accuracy: 0.0001)
        XCTAssertEqual(clock.elapsed(now: t0.addingTimeInterval(30)), 10, accuracy: 0.0001)
    }

    func testDoubleResumeIsNoOp() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var clock = RecordingClock(startedAt: t0)
        clock.pause(at: t0.addingTimeInterval(10))
        clock.resume(at: t0.addingTimeInterval(20))  // +10 paused
        clock.resume(at: t0.addingTimeInterval(40))  // already running → no-op, no extra deduction
        XCTAssertEqual(clock.pausedAccumulated, 10, accuracy: 0.0001)
        XCTAssertEqual(clock.elapsed(now: t0.addingTimeInterval(40)), 30, accuracy: 0.0001)
    }

    // MARK: born paused

    func testBornPausedFreezesFromZero() {
        let t0 = Date(timeIntervalSinceReferenceDate: 100)
        var clock = RecordingClock(startedAt: t0, paused: true, now: t0)
        XCTAssertTrue(clock.isPaused)
        XCTAssertEqual(clock.elapsed(now: t0.addingTimeInterval(50)), 0, accuracy: 0.0001)
        clock.resume(at: t0.addingTimeInterval(50))   // 50s all paused
        XCTAssertEqual(clock.elapsed(now: t0.addingTimeInterval(60)), 10, accuracy: 0.0001)
    }

    // MARK: never negative

    func testElapsedNeverNegative() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let clock = RecordingClock(startedAt: t0)
        // A clock queried BEFORE its start (clock skew) reads 0, never negative.
        XCTAssertEqual(clock.elapsed(now: t0.addingTimeInterval(-30)), 0, accuracy: 0.0001)
    }
}
