// LocalBrainStatus — the observable readiness of the on-device brain (track
// 20260705T1100, model-download UX). WhisperKit fetches its model (~150 MB) on
// first need; without a visible state the first finalize just hangs and looks
// broken. This drives a "setting up your private on-device brain" banner
// (framed per the spec: model weights are the ONLY bytes coming in, nothing out).

import Foundation

@MainActor
public final class LocalBrainStatus: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle                 // nothing needed yet
        case downloading(Double)  // fraction 0…1
        case loading              // weights in, warming the model
        case ready
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle

    /// Set alongside `.failed` — the banner's "Try again" (track 20260722T1244).
    /// Non-nil ⇒ the failure is recoverable in-process, with no app restart.
    @Published public private(set) var retryAction: (() -> Void)?

    /// The ATTEMPT EPOCH (track 20260722T1244 review, B1). Every setup attempt gets a
    /// monotonically increasing id from `beginAttempt()`. Reports carry the epoch they
    /// were produced under and are DROPPED unless they belong to the current attempt.
    ///
    /// Why an epoch and not "ignore progress while failed": a stalled attempt is
    /// CANCELLED but never awaited (see `BrainSetupWatchdog.run`), so its downloader can
    /// still be alive and still emitting progress long after the user retried. Without an
    /// epoch, one late `setDownloading` from that zombie puts the spinner back on top of a
    /// `.ready` brain — with nothing running to ever clear it. Filtering by phase cannot
    /// fix that (ordering across executors is not guaranteed); filtering by ATTEMPT can.
    public private(set) var attempt: Int = 0

    public init() {}

    /// True once this attempt has settled — `.ready` and `.failed` are BOTH terminal.
    /// A settled attempt is never silently turned back into a spinner; only a NEW attempt
    /// (`beginAttempt()`) reopens the state.
    private var isSettled: Bool {
        switch phase {
        case .ready, .failed: return true
        default: return false
        }
    }

    /// `nil` epoch = an unstamped caller (tests, direct UI drives) — always current.
    private func isCurrent(_ epoch: Int?) -> Bool {
        guard let epoch else { return true }
        return epoch == attempt
    }

    /// True once setup has failed and is waiting on the user (never a spinner).
    public var isFailed: Bool { if case .failed = phase { return true }; return false }

    /// Whether the failure banner should offer a retry control.
    public var canRetry: Bool { retryAction != nil }

    /// The retry control's label.
    public var retryLabel: String { "Try again" }

    /// Human copy for the banner (nil ⇒ show nothing).
    public var bannerText: String? { Self.bannerText(for: phase) }

    /// The same mapping as a PURE function of a phase, so a test can judge the banner the
    /// user would have seen at EVERY transition, not just the one left at the end.
    public nonisolated static func bannerText(for phase: Phase) -> String? {
        switch phase {
        case .idle, .ready: return nil
        case .downloading(let f):
            return "Setting up your private on-device brain… \(Int(f * 100))%"
        case .loading:
            return "Setting up your private on-device brain…"
        case .failed(let why):
            return "On-device brain setup failed: \(why)"
        }
    }

    /// True while the model is being fetched/warmed — the banner is visible.
    public var isPreparing: Bool {
        switch phase {
        case .downloading, .loading: return true
        default: return false
        }
    }

    // Called (on the main actor) by the STT engine as setup proceeds.
    //
    // BOTH terminal states are STICKY, and every report may carry its attempt epoch:
    //
    //  * `.failed` sticky — a late progress report from the attempt that just timed out
    //    must never overwrite the honest failure with a spinner again;
    //  * `.ready` sticky — the mirror bug: attempt 1 stalls → `.failed` → user retries →
    //    attempt 2 succeeds → `.ready`, and THEN attempt 1's zombie downloader emits one
    //    more progress callback. Without this the spinner comes back with no retry button
    //    and nothing running to clear it — the exact hang this track exists to kill;
    //  * stale EPOCH dropped — the general form of the above, and the only thing that
    //    holds when the orderings race (progress hops through `Task { @MainActor }` while
    //    the preparer's `setReady` hops through `MainActor.run` from a different executor).
    //
    // Only a new attempt (`beginAttempt`) reopens a settled state.
    public func setDownloading(_ fraction: Double, epoch: Int? = nil) {
        guard isCurrent(epoch), !isSettled else { return }
        phase = .downloading(min(max(fraction, 0), 1))
    }
    public func setLoading(epoch: Int? = nil) {
        guard isCurrent(epoch), !isSettled else { return }
        phase = .loading
    }
    public func setReady(epoch: Int? = nil) {
        guard isCurrent(epoch) else { return }
        phase = .ready
        retryAction = nil
    }
    public func setFailed(_ why: String, retry: (() -> Void)? = nil, epoch: Int? = nil) {
        guard isCurrent(epoch) else { return }
        phase = .failed(why)
        retryAction = retry
    }

    /// A fresh setup attempt (first run, or the user tapping "Try again"). Clears any
    /// prior failure, bumps the epoch (so every report from the PREVIOUS attempt is dead
    /// on arrival), and returns the new epoch for the caller to stamp its reports with.
    ///
    /// It deliberately does NOT enter a visible setup state. An already-present, healthy
    /// model needs no work at all, and flashing "Setting up… 0%" at it contradicts the
    /// spec ("I see no setup banner at all"). The banner appears only once the preparer
    /// knows the setup is actually doing something (see `BrainSetupPolicy.revealDelay`).
    @discardableResult
    public func beginAttempt() -> Int {
        attempt += 1
        retryAction = nil
        phase = .idle
        return attempt
    }
}
