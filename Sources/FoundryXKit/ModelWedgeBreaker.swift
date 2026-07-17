// ModelWedgeBreaker — a session-scoped circuit breaker guarding the on-device model
// (Apple Foundation Models) against runaway CPU (track WS-C, 2026-07-17).
//
// Background: since the T1 `withPerfTimeout` redesign (PerfTelemetry.swift) the CALLER of a
// title/summary turn is correctly unblocked at the 20s deadline — but a non-cooperative wedged
// `LanguageModelSession.respond` keeps running in a DETACHED task, burning CPU until it finishes
// on its own (~86s measured: `fm-title-orphan-done ms=86136/88706`; a 90s MetricKit CPU-exception
// on build 232 matches this class). SummaryBackfill already stops ITS pass on the first wedge, but
// every OTHER call site (capture-finalize titling, fill-on-open, recap) can each spawn a fresh 86s
// runaway — unbounded per session.
//
// This breaker makes a wedged model cost ONE runaway, not one per call site: the first wedge trips
// it OPEN for a cool-down, during which turns are refused instantly (no new detached task). After
// the cool-down a single HALF-OPEN probe decides — succeed → CLOSE (normal), wedge → re-OPEN.
//
// PURE + testable: one lock, an injectable monotonic clock, NO PerfHook/Foundation-Models import.
// The App-side titler consults it and owns the span emission; this type owns only the state machine
// and a throttle hint so the refusal span stays low-volume.

import Foundation

/// Thrown at the top of an on-device model turn when the wedge breaker is OPEN — a fast, typed
/// refusal so a wedged Foundation Models turn is never re-entered. Callers treat it like any other
/// transient title/summary failure (skip the card, keep the transcript). It is NOT a `PerfTimeout`,
/// so a refusal never itself trips the breaker.
public struct ModelWedgedError: Error, Sendable, Equatable {
    /// Milliseconds left in the open cool-down (0 once the breaker is half-open).
    public let cooldownRemainingMs: Int
    public init(cooldownRemainingMs: Int) { self.cooldownRemainingMs = cooldownRemainingMs }
}

/// Thread-safe session-scoped circuit breaker for the on-device model.
///
/// Transitions (single lock; injectable monotonic clock so tests are deterministic):
///   CLOSED               → `admit()` = `.proceed`; a turn runs normally.
///   `tripWedge()`        → OPEN for `cooldown`; every `admit()` is `.refused` instantly.
///   after the cool-down  → HALF-OPEN: the FIRST `admit()` = `.probe`; concurrent admits are
///                          `.refused(remainingMs: 0)` while that single probe is in flight.
///   probe succeeds → `recordSuccess()` → CLOSED.
///   probe wedges   → `tripWedge()`      → OPEN again for a fresh cool-down.
///   probe fails transiently → `releaseProbe()` → still HALF-OPEN; the next admit probes again
///                          (a non-wedge error must not strand the breaker half-open forever).
public final class ModelWedgeBreaker: @unchecked Sendable {

    /// What an `admit()` decided.
    public enum Admission: Equatable, Sendable {
        /// Proceed with a normal turn (breaker CLOSED).
        case proceed
        /// Proceed as the single half-open probe turn (the caller MUST report the outcome:
        /// `recordSuccess()`, `tripWedge()`, or `releaseProbe()`).
        case probe
        /// Refused: the breaker is open, or a probe is already in flight. `remainingMs` is the
        /// cool-down left (0 while half-open). `emitSpan` is the throttled once-a-minute hint —
        /// true at most once per `refusalThrottle` so the refusal span stays low-volume.
        case refused(remainingMs: Int, emitSpan: Bool)
    }

    private enum State { case closed; case open(until: TimeInterval) }

    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private let cooldown: TimeInterval
    private let refusalThrottle: TimeInterval

    private var state: State = .closed
    private var probeInFlight = false
    private var lastRefusalSpanAt: TimeInterval?

    /// - Parameters:
    ///   - cooldownSeconds: how long the breaker stays OPEN after a wedge (default 10 minutes).
    ///   - refusalThrottleSeconds: minimum gap between refusal-span hints (default 60s).
    ///   - clock: a monotonic seconds source; injected in tests. Production uses `systemUptime`
    ///            (monotonic, immune to wall-clock changes).
    public init(cooldownSeconds: TimeInterval = 600,
                refusalThrottleSeconds: TimeInterval = 60,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.cooldown = cooldownSeconds
        self.refusalThrottle = refusalThrottleSeconds
        self.clock = clock
    }

    /// Decide whether the next on-device turn may run.
    public func admit() -> Admission {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .closed:
            return .proceed
        case .open(let until):
            let now = clock()
            if now < until {
                return .refused(remainingMs: msBetween(now, until), emitSpan: throttledRefusalLocked(now))
            }
            // Cool-down elapsed → HALF-OPEN. Allow exactly one probe at a time.
            if probeInFlight {
                return .refused(remainingMs: 0, emitSpan: throttledRefusalLocked(now))
            }
            probeInFlight = true
            return .probe
        }
    }

    /// A turn wedged (surfaced as a `PerfTimeout`). Open the breaker for a fresh cool-down.
    /// Returns the cool-down remaining (the full cool-down) so the caller can emit the trip span.
    @discardableResult
    public func tripWedge() -> Int {
        lock.lock(); defer { lock.unlock() }
        state = .open(until: clock() + cooldown)
        probeInFlight = false
        return msFromSeconds(cooldown)
    }

    /// A turn succeeded. Close the breaker (normal).
    public func recordSuccess() {
        lock.lock(); defer { lock.unlock() }
        state = .closed
        probeInFlight = false
    }

    /// A probe turn ended with a non-wedge, non-success transient failure: free the single-probe
    /// slot WITHOUT closing, so the breaker stays half-open and the next `admit()` probes again.
    public func releaseProbe() {
        lock.lock(); defer { lock.unlock() }
        probeInFlight = false
    }

    /// Test/observability read: is the breaker currently refusing turns (open, cool-down live, or a
    /// probe already in flight)? Does NOT consume the probe slot or the refusal-span throttle.
    public var isRefusing: Bool {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .closed: return false
        case .open(let until): return clock() < until || probeInFlight
        }
    }

    // MARK: - helpers (call with the lock held)

    /// True at most once per `refusalThrottle` — keeps the refusal span low-volume.
    private func throttledRefusalLocked(_ now: TimeInterval) -> Bool {
        if let last = lastRefusalSpanAt, now - last < refusalThrottle { return false }
        lastRefusalSpanAt = now
        return true
    }

    private func msBetween(_ a: TimeInterval, _ b: TimeInterval) -> Int {
        Int((max(0, b - a) * 1000).rounded())
    }
    private func msFromSeconds(_ s: TimeInterval) -> Int { Int((max(0, s) * 1000).rounded()) }
}
