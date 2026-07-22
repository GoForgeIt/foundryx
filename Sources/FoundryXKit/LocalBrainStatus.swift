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

    public init() {}

    /// True once setup has failed and is waiting on the user (never a spinner).
    public var isFailed: Bool { if case .failed = phase { return true }; return false }

    /// Whether the failure banner should offer a retry control.
    public var canRetry: Bool { retryAction != nil }

    /// The retry control's label.
    public var retryLabel: String { "Try again" }

    /// Human copy for the banner (nil ⇒ show nothing).
    public var bannerText: String? {
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
    // `.failed` is STICKY: a late in-flight progress report from the attempt that just
    // timed out must never overwrite the honest failure with a spinner again. Only a
    // new attempt (`beginAttempt`) or an actual success clears it.
    public func setDownloading(_ fraction: Double) {
        guard !isFailed else { return }
        phase = .downloading(min(max(fraction, 0), 1))
    }
    public func setLoading() {
        guard !isFailed else { return }
        phase = .loading
    }
    public func setReady() { phase = .ready; retryAction = nil }
    public func setFailed(_ why: String, retry: (() -> Void)? = nil) {
        phase = .failed(why)
        retryAction = retry
    }

    /// A fresh setup attempt (first run, or the user tapping "Try again") — clears any
    /// prior failure so progress can be reported again.
    public func beginAttempt() {
        retryAction = nil
        phase = .downloading(0)
    }
}
