import XCTest
@testable import FoundryXKit

/// StallReportBudget (track 20260717T0900 WS-A) — the pure rate limiter that keeps the
/// production stall sensor from flooding `/diag/log`. Clock is injected so the min-interval
/// + session-cap logic is pinned with zero wall-clock dependence.
final class StallReportBudgetTests: XCTestCase {

    /// A controllable monotonic clock (nanoseconds).
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: UInt64
        init(_ start: UInt64 = 0) { t = start }
        func read() -> UInt64 { lock.lock(); defer { lock.unlock() }; return t }
        func advance(seconds: Double) { lock.lock(); t &+= UInt64(seconds * 1_000_000_000); lock.unlock() }
    }

    // Min-interval: after one admit, a second within the window is denied; past it, admitted.
    func testMinIntervalSpacing() {
        let clock = Clock()
        let budget = StallReportBudget(minInterval: 5, maxPerSession: 60, clock: clock.read)
        XCTAssertTrue(budget.admit(), "first report is always admitted")
        XCTAssertFalse(budget.admit(), "a second report immediately after is spaced out")
        clock.advance(seconds: 4.9)
        XCTAssertFalse(budget.admit(), "still inside the 5s window")
        clock.advance(seconds: 0.2)                 // now 5.1s since last admit
        XCTAssertTrue(budget.admit(), "past the 5s window: admitted again")
    }

    // Session cap: no more than maxPerSession admits ever, even with the clock wide open.
    func testSessionCap() {
        let clock = Clock()
        let budget = StallReportBudget(minInterval: 0, maxPerSession: 60, clock: clock.read)
        for _ in 0..<60 { XCTAssertTrue(budget.admit()) }
        XCTAssertFalse(budget.admit(), "the 61st report is denied by the session cap")
        clock.advance(seconds: 3600)
        XCTAssertFalse(budget.admit(), "the cap is for the whole session, not per-window")
        XCTAssertEqual(budget.consumed, 60)
    }

    // A denied call costs no budget — only successful admits consume.
    func testDeniedCallsDoNotConsume() {
        let clock = Clock()
        let budget = StallReportBudget(minInterval: 10, maxPerSession: 5, clock: clock.read)
        XCTAssertTrue(budget.admit())
        for _ in 0..<20 { _ = budget.admit() }      // all denied (inside window)
        XCTAssertEqual(budget.consumed, 1, "denied calls did not eat into the session cap")
    }

    // The stack-capture budget shape: ≤1 per 30s, ≤5 per session.
    func testStackBudgetShape() {
        let clock = Clock()
        let budget = StallReportBudget(minInterval: 30, maxPerSession: 5, clock: clock.read)
        var admits = 0
        for _ in 0..<10 {
            if budget.admit() { admits += 1 }
            clock.advance(seconds: 31)              // clear the spacing each iteration
        }
        XCTAssertEqual(admits, 5, "spacing satisfied, the session cap of 5 still bounds it")
    }
}
