// LocalBrainSetup — bounded, honest preparation of the on-device brain
// (track 20260722T1244, "Setting up you…" banner that never clears).
//
// The on-device STT model (~150 MB) is fetched on first need. Before this track the
// fetch had NO timeout: a stalled download (flaky network, backgrounded app, slow
// server) left the "Setting up your private on-device brain…" banner up forever —
// no error, no retry, and no way for the user to tell "still downloading" from
// "permanently wedged".
//
// The fix is a STALL watchdog, not a wall-clock one. A big model on a slow link can
// legitimately take many minutes, and killing that would be its own lie. What is
// never legitimate is progress that stops ADVANCING. So:
//
//   * every byte that actually lands advances a `ProgressHeartbeat`;
//   * the watchdog only fails when the heartbeat has not advanced for `stallTimeout`;
//   * the engine build (which emits no progress at all) gets its own `buildTimeout`.
//
// On failure the status flips to `.failed` WITH a retry action, so the UI shows an
// honest error and a working "Try again" — no app restart. Everything is injectable
// (clock, sleep, download, build) so the timeout is unit-tested in milliseconds
// instead of waiting out a real 150 MB fetch. Lives in FoundryXKit (not the App
// target) so `swift test` drives it without ever building WhisperKit.

import Foundation

// MARK: - Policy

/// How long the setup is allowed to be *stuck* (not how long it is allowed to take).
public struct BrainSetupPolicy: Sendable, Equatable {
    /// Fail if the download's progress has not ADVANCED for this long.
    public var stallTimeout: TimeInterval
    /// Fail if building/warming the engine (which reports no progress) exceeds this.
    public var buildTimeout: TimeInterval
    /// How often the watchdog checks the heartbeat.
    public var pollInterval: TimeInterval

    public init(stallTimeout: TimeInterval = 60,
                buildTimeout: TimeInterval = 180,
                pollInterval: TimeInterval = 2) {
        self.stallTimeout = stallTimeout
        self.buildTimeout = buildTimeout
        self.pollInterval = pollInterval
    }

    public static let `default` = BrainSetupPolicy()
}

// MARK: - Errors

/// The two honest ways setup can time out. Both carry the numbers the banner shows,
/// so the user is never told a vague "something went wrong".
public enum BrainSetupError: Error, Equatable, LocalizedError {
    /// The download stopped advancing for `idle` seconds, stuck at `fraction` (0…1).
    case downloadStalled(idle: TimeInterval, fraction: Double)
    /// The engine build ran past its bound.
    case buildTimedOut(after: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .downloadStalled(let idle, let fraction):
            let pct = Int((min(max(fraction, 0), 1) * 100).rounded())
            return "the download stopped at \(pct)% and hasn't moved for \(Int(idle))s"
        case .buildTimedOut(let after):
            return "preparing the model took longer than \(Int(after))s"
        }
    }
}

// MARK: - Progress heartbeat

/// A thread-safe "when did progress last actually ADVANCE" clock. Repeating the same
/// fraction is NOT progress — that's exactly what a stalled transfer looks like — so
/// only a strictly larger fraction resets the heartbeat.
///
/// Deliberately a lock-backed class rather than an actor: the download progress
/// callback is a synchronous, arbitrary-thread closure, and hopping to an actor there
/// would reorder beats against the failure report.
public final class ProgressHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private var lastAdvance: TimeInterval
    private var best: Double = 0

    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        self.lastAdvance = clock()
    }

    /// Record real progress. Ignored unless it is strictly ahead of the best seen.
    public func advance(to fraction: Double) {
        let f = min(max(fraction, 0), 1)
        lock.lock(); defer { lock.unlock() }
        guard f > best else { return }
        best = f
        lastAdvance = clock()
    }

    /// Seconds since progress last advanced.
    public var idle: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return max(0, clock() - lastAdvance)
    }

    /// The furthest fraction actually observed.
    public var fraction: Double {
        lock.lock(); defer { lock.unlock() }
        return best
    }
}

// MARK: - First-outcome box

/// Whichever of {the work, the watchdog} settles first wins. `@unchecked Sendable`
/// carrier so a generic value + an `any Error` can cross the actor hop.
private struct Outcome<T>: @unchecked Sendable {
    let value: T?
    let error: (any Error)?
}

private actor FirstOutcome<T> {
    private var settled: Outcome<T>?
    private var waiter: CheckedContinuation<Outcome<T>, Never>?

    func settle(_ outcome: Outcome<T>) {
        guard settled == nil else { return }
        settled = outcome
        if let w = waiter { waiter = nil; w.resume(returning: outcome) }
    }

    func awaitOutcome() async -> Outcome<T> {
        if let settled { return settled }
        return await withCheckedContinuation { c in waiter = c }
    }
}

// MARK: - Watchdog

public enum BrainSetupWatchdog {
    /// Run `operation`, failing with `onStall(...)` if `heartbeat` goes `timeout`
    /// seconds without advancing.
    ///
    /// The loser is CANCELLED but never awaited: a downloader that ignores
    /// cancellation must not be able to hold the user's UI hostage — the point of the
    /// whole change is that the banner clears in bounded time.
    public static func run<T: Sendable>(
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        heartbeat: ProgressHeartbeat,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
        onStall: @escaping @Sendable (TimeInterval, Double) -> any Error,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = FirstOutcome<T>()

        let work = Task {
            do { await box.settle(Outcome(value: try await operation(), error: nil)) }
            catch { await box.settle(Outcome(value: nil, error: error)) }
        }
        let watch = Task {
            while !Task.isCancelled {
                try await sleep(pollInterval)
                if Task.isCancelled { return }
                let idle = heartbeat.idle
                if idle >= timeout {
                    await box.settle(Outcome(value: nil, error: onStall(idle, heartbeat.fraction)))
                    return
                }
            }
        }

        let outcome = await box.awaitOutcome()
        watch.cancel()
        if let error = outcome.error {
            work.cancel()
            throw error
        }
        // `value` is non-nil whenever `error` is nil (the box only ever holds one).
        return outcome.value!
    }

    /// The default injectable sleep.
    public static let realSleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

// MARK: - Preparer

/// Owns the on-device brain's setup lifecycle: download (stall-bounded) → build
/// (time-bounded) → ready, reporting every phase onto `LocalBrainStatus`, and on
/// failure installing a retry action that runs the whole thing again in-process.
public actor LocalBrainPreparer {

    /// The two injectable steps. `download` reports fraction 0…1 as bytes actually
    /// land; `build` warms the engine from what was downloaded.
    public struct Steps: Sendable {
        public var download: @Sendable (_ onProgress: @escaping @Sendable (Double) -> Void) async throws -> Void
        public var build: @Sendable () async throws -> Void

        public init(download: @escaping @Sendable (_ onProgress: @escaping @Sendable (Double) -> Void) async throws -> Void,
                    build: @escaping @Sendable () async throws -> Void) {
            self.download = download
            self.build = build
        }
    }

    private let steps: Steps
    private let policy: BrainSetupPolicy
    private let status: LocalBrainStatus?
    private let clock: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var isReady = false
    private var inFlight: Task<Void, any Error>?

    public init(steps: Steps,
                policy: BrainSetupPolicy = .default,
                status: LocalBrainStatus? = nil,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = BrainSetupWatchdog.realSleep) {
        self.steps = steps
        self.policy = policy
        self.status = status
        self.clock = clock
        self.sleep = sleep
    }

    public var ready: Bool { isReady }

    /// Prepare the brain. Idempotent: a second call while one is in flight joins it,
    /// and a call after success is a no-op.
    public func prepare() async throws {
        if isReady {
            await report { $0.setReady() }
            return
        }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.runOnce() }
        inFlight = task
        do {
            try await task.value
            inFlight = nil
        } catch {
            inFlight = nil
            throw error
        }
    }

    /// What the banner's "Try again" invokes. Same path as `prepare()` — no restart.
    public func retry() async throws { try await prepare() }

    private func runOnce() async throws {
        let heartbeat = ProgressHeartbeat(clock: clock)
        await report { $0.beginAttempt() }
        let sink = status
        do {
            try await BrainSetupWatchdog.run(
                timeout: policy.stallTimeout,
                pollInterval: policy.pollInterval,
                heartbeat: heartbeat,
                sleep: sleep,
                onStall: { idle, fraction in
                    BrainSetupError.downloadStalled(idle: idle, fraction: fraction)
                },
                operation: { [steps] in
                    try await steps.download { fraction in
                        heartbeat.advance(to: fraction)
                        Task { @MainActor in sink?.setDownloading(fraction) }
                    }
                })

            await report { $0.setLoading() }

            // The build reports no progress, so its heartbeat never advances: the same
            // watchdog then degenerates into a plain bound of `buildTimeout`.
            let buildBeat = ProgressHeartbeat(clock: clock)
            try await BrainSetupWatchdog.run(
                timeout: policy.buildTimeout,
                pollInterval: policy.pollInterval,
                heartbeat: buildBeat,
                sleep: sleep,
                onStall: { idle, _ in BrainSetupError.buildTimedOut(after: idle) },
                operation: { [steps] in try await steps.build() })

            isReady = true
            await report { $0.setReady() }
        } catch {
            let why = error.localizedDescription
            await report { [weak self] s in
                s.setFailed(why, retry: { Task { try? await self?.retry() } })
            }
            throw error
        }
    }

    private func report(_ body: @escaping @MainActor (LocalBrainStatus) -> Void) async {
        guard let status else { return }
        await MainActor.run { body(status) }
    }
}
