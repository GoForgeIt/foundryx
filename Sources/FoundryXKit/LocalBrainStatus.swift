// LocalBrainStatus — the observable readiness of the on-device brain (track
// 20260705T1100, model-download UX). WhisperKit fetches its model (~150 MB) on
// first need; without a visible state the first finalize just hangs and looks
// broken. This drives a "setting up your private on-device brain" banner
// (framed per the spec: model weights are the ONLY bytes coming in, nothing out).

import Foundation

@MainActor
public final class LocalBrainStatus: ObservableObject {
    public enum Phase: Equatable {
        case idle                 // nothing needed yet
        case downloading(Double)  // fraction 0…1
        case loading              // weights in, warming the model
        case ready
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle

    public init() {}

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
    public func setDownloading(_ fraction: Double) {
        phase = .downloading(min(max(fraction, 0), 1))
    }
    public func setLoading() { phase = .loading }
    public func setReady() { phase = .ready }
    public func setFailed(_ why: String) { phase = .failed(why) }
}
