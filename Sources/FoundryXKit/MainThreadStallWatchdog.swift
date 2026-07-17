// MainThreadStallWatchdog — the harness-mode "no main-thread stall in normal nav"
// sensor (track 20260717T0759, AC6).
//
// MetricKit's hang diagnostics are device-only and arrive on a ~daily cadence — a CI
// simulator run can't gate on them. This watchdog makes main-thread stalls observable
// LIVE: a utility-QoS heartbeat posts a ping onto the target (main) queue every
// `pingInterval`; when a ping lands later than `thresholdMs` after it was posted, the
// main thread was blocked that long and a `nav-stall` perf span is emitted with the
// observed delay. sim-perf's nav phase launches the app with `-PerfLog`, drives real
// tab switches + a record start, and FAILS the budget when any `nav-stall` span
// appears — "zero main-thread stalls > threshold during normal nav" as a regression
// gate, not a hope.
//
// Design notes:
// - ONE ping in flight at a time: while the main thread is blocked, ticks are skipped
//   instead of queueing — a 900ms stall reports as ONE ~900ms span, not nine 100ms ones.
// - The emit closure + target queue are injectable so the stall→span mechanics are
//   unit-tested against a private serial queue with a deliberate block — no wall-clock
//   dependence on the real main thread in `swift test`.
// - NOT enabled in production: `DemoSeed.installPerfLogIfRequested` starts it only when
//   the `-PerfLog` harness flag is present (DEBUG builds). The production stall signal
//   remains MetricKit (PerfMetricsSubscriber), which has zero steady-state overhead.

import Foundation

public final class MainThreadStallWatchdog: @unchecked Sendable {
    private let thresholdMs: Int
    private let pingInterval: TimeInterval
    private let target: DispatchQueue
    private let emit: @Sendable (Int) -> Void

    /// Serial control queue: owns `timer` + `awaitingPing`.
    private let control = DispatchQueue(label: "foundryx.stall-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var awaitingPing = false

    public init(thresholdMs: Int = 250,
                pingInterval: TimeInterval = 0.1,
                target: DispatchQueue = .main,
                emit: @escaping @Sendable (Int) -> Void = { PerfHook.span("nav-stall", ms: $0) }) {
        self.thresholdMs = thresholdMs
        self.pingInterval = pingInterval
        self.target = target
        self.emit = emit
    }

    public func start() {
        control.async { [self] in
            guard timer == nil else { return }   // idempotent
            let t = DispatchSource.makeTimerSource(queue: control)
            t.schedule(deadline: .now() + pingInterval, repeating: pingInterval,
                       leeway: .milliseconds(10))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        control.async { [self] in
            timer?.cancel()
            timer = nil
            awaitingPing = false
        }
    }

    /// One heartbeat: post a ping unless the previous one is still stuck in the target
    /// queue (blocked main) — the stuck ping itself measures the whole stall when it
    /// finally runs.
    private func tick() {
        guard !awaitingPing else { return }
        awaitingPing = true
        let posted = DispatchTime.now().uptimeNanoseconds
        target.async { [weak self] in
            guard let self else { return }
            let delayMs = Int((DispatchTime.now().uptimeNanoseconds &- posted) / 1_000_000)
            self.control.async { self.awaitingPing = false }
            if delayMs >= self.thresholdMs { self.emit(delayMs) }
        }
    }
}
