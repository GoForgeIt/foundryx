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
// - PRODUCTION (track 20260717T0900 WS-A): now started in EVERY build by
//   `PerfTelemetry.start()` (armed ~5s after launch so launch cost isn't counted), UNLESS
//   `-PerfLog` is present (the harness owns one). Emissions are rate-limited by
//   StallReportBudget, and — when it catches the target thread mid-stall — a live backtrace
//   is sampled (MainThreadStackSampler) and shipped as `stallstack` lines so the blocked
//   site is named from the user's own device, not just its duration.

import Foundation

public final class MainThreadStallWatchdog: @unchecked Sendable {
    private let thresholdMs: Int
    private let pingInterval: TimeInterval
    private let target: DispatchQueue
    private let emit: @Sendable (Int) -> Void

    /// When a ping is still stuck AND this much time has elapsed since it was posted, the
    /// target thread is blocked RIGHT NOW — the moment to sample its backtrace (once per
    /// stall). 0 disables live stack capture (the harness/legacy watchdog with no sampler).
    private let captureThresholdMs: Int
    /// Called (on the control queue) with the elapsed-so-far ms when a live stack should be
    /// captured. The production wiring samples the target thread and ships `stallstack`
    /// lines; nil = no stack capture. Injectable so the trigger is unit-tested without a
    /// real sampler.
    private let onStack: (@Sendable (Int) -> Void)?
    /// Monotonic nanoseconds; injectable for deterministic tests.
    private let now: @Sendable () -> UInt64

    /// Serial control queue: owns `timer` + `awaitingPing` + `postedNanos` +
    /// `sampledThisStall` + `paused` + `generation`.
    private let control = DispatchQueue(label: "foundryx.stall-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var awaitingPing = false
    private var postedNanos: UInt64 = 0
    private var sampledThisStall = false
    /// True while the app is backgrounded (P1-1): iOS SUSPENDS the process but the
    /// mach uptime clock keeps advancing, so a ping in flight at suspension would
    /// "measure" the whole background gap on resume — a bogus multi-second stall —
    /// and tick() would sample an innocently-resuming main thread. Paused = no new
    /// pings, no stack captures.
    private var paused = false
    /// Bumped by pause(): any ping posted under an older generation is DISCARDED when
    /// it finally lands, so a suspension gap can never be emitted as a stall.
    private var generation: UInt64 = 0

    public init(thresholdMs: Int = 250,
                pingInterval: TimeInterval = 0.1,
                target: DispatchQueue = .main,
                captureThresholdMs: Int = 0,
                onStack: (@Sendable (Int) -> Void)? = nil,
                now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                emit: @escaping @Sendable (Int) -> Void = { PerfHook.span("nav-stall", ms: $0) }) {
        self.thresholdMs = thresholdMs
        self.pingInterval = pingInterval
        self.target = target
        self.captureThresholdMs = captureThresholdMs
        self.onStack = onStack
        self.now = now
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
            generation &+= 1   // discard any ping still in flight
        }
    }

    /// Suspend surveillance across an app-background gap (P1-1). The heartbeat keeps
    /// ticking (cheap) but posts nothing, captures nothing, and any ping already in
    /// flight is generation-invalidated — so the multi-second/minute suspension gap the
    /// mach clock still counts can never surface as a fake `nav-stall` span or a
    /// misattributed stall stack (which would also burn a session stack-capture slot).
    public func pause() {
        control.async { [self] in
            paused = true
            awaitingPing = false
            sampledThisStall = false
            generation &+= 1
        }
    }

    /// Resume surveillance after foregrounding: clean slate, next tick posts fresh.
    public func resume() {
        control.async { [self] in paused = false }
    }

    /// One heartbeat. If the previous ping is STILL stuck in the target queue, the target
    /// thread is blocked right now: sample its backtrace once (when the stall has already
    /// lasted ≥ captureThresholdMs) — this is the only moment we can see WHERE it is blocked,
    /// because the stuck ping won't run until the stall ends. Otherwise post a fresh ping;
    /// the stuck ping itself measures the whole stall duration when it finally runs.
    private func tick() {
        guard !paused else { return }
        if awaitingPing {
            guard let onStack, captureThresholdMs > 0, !sampledThisStall else { return }
            let elapsedMs = Int((now() &- postedNanos) / 1_000_000)
            if elapsedMs >= captureThresholdMs {
                sampledThisStall = true
                onStack(elapsedMs)
            }
            return
        }
        awaitingPing = true
        sampledThisStall = false
        let posted = now()
        postedNanos = posted
        let gen = generation
        target.async { [weak self] in
            guard let self else { return }
            let delayMs = Int((self.now() &- posted) / 1_000_000)
            // Validity is decided on the control queue: a pause()/stop() since this ping
            // was posted bumped `generation`, meaning the "delay" includes a suspension
            // gap (or the watchdog was retired) — discard instead of emitting a fake stall.
            self.control.async {
                guard gen == self.generation else { return }
                self.awaitingPing = false
                self.sampledThisStall = false
                if delayMs >= self.thresholdMs { self.emit(delayMs) }
            }
        }
    }
}
