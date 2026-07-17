// StallReportBudget — a pure, testable rate limiter for the production main-thread
// stall sensor (track 20260717T0900 WS-A). The live stall watchdog runs in EVERY build
// now (PerfMetricsSubscriber.start), so its emissions MUST be bounded: a device stuck in
// a pathological hang loop can't be allowed to flood `/diag/log` with one span every tick.
//
// Two independent budgets are cut from this one type:
//   • nav-stall spans:      ≤1 per 5s, ≤60 per session
//   • stall-STACK captures: ≤1 per 30s, ≤5 per session (a sampled backtrace is heavier)
//
// The clock is injectable so the min-interval + session-cap logic is unit-tested with a
// controllable clock — no wall-clock dependence. Thread-safe (the watchdog admits from
// its control queue AND the target queue), so it's a reference type behind a lock.
import Foundation

public final class StallReportBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let minIntervalNanos: UInt64
    private let maxPerSession: Int
    private let clock: @Sendable () -> UInt64

    private var started = false
    private var lastAdmit: UInt64 = 0
    private var used = 0

    /// - Parameters:
    ///   - minInterval: minimum seconds between two admitted reports (0 = no spacing).
    ///   - maxPerSession: hard cap of admitted reports for the process lifetime.
    ///   - clock: monotonic nanoseconds (default: DispatchTime uptime — immune to wall-clock changes).
    public init(minInterval: TimeInterval,
                maxPerSession: Int,
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.minIntervalNanos = UInt64(max(0, minInterval) * 1_000_000_000)
        self.maxPerSession = maxPerSession
        self.clock = clock
    }

    /// Try to consume one unit of budget. Returns true iff a report may be emitted NOW
    /// (session cap not hit AND at least `minInterval` since the last admitted report).
    /// Consumes only on success — a denied call costs nothing.
    public func admit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used >= maxPerSession { return false }
        let now = clock()
        if started && (now &- lastAdmit) < minIntervalNanos { return false }
        started = true
        lastAdmit = now
        used += 1
        return true
    }

    /// How many reports have been admitted this session (for tests / diagnostics).
    public var consumed: Int {
        lock.lock(); defer { lock.unlock() }
        return used
    }
}
