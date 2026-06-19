// AudioFrameSource — the source of Opus audio frames that feed the capture WAL.
// Two impls: OmiBleSource (the real Omi wearable over CoreBluetooth) and
// ReplaySource (canned frames, so the WAL → door pipeline is testable without
// hardware). The capture pipeline depends only on this protocol, never on BLE.

import Foundation

/// A start/stop source that emits Opus frames (one `Data` per BLE notification /
/// replay item). `onFrame` is invoked for every frame; `onState` reports liveness.
public protocol AudioFrameSource: AnyObject {
    /// Called once per Opus frame. May fire on a background thread.
    var onFrame: ((Data) -> Void)? { get set }
    /// Called when the source's liveness changes (so the UI can show "Recording").
    var onState: ((AudioSourceState) -> Void)? { get set }
    func start()
    func stop()
}

public enum AudioSourceState: Equatable, Sendable {
    case idle
    case scanning
    case streaming       // connected + frames flowing
    case stopped
    case failed(String)
}

/// Feeds a fixed list of Opus frames — the test/replay source. Drives the exact
/// same WAL path the real Omi stream does, with no Bluetooth.
public final class ReplaySource: AudioFrameSource, @unchecked Sendable {
    public var onFrame: ((Data) -> Void)?
    public var onState: ((AudioSourceState) -> Void)?

    private let frames: [Data]
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "foundryx.replay-source")
    private var cancelled = false

    /// `interval` 0 = emit all frames synchronously on `start()` (fast tests);
    /// > 0 = emit one frame per interval (simulates a live stream).
    public init(frames: [Data], interval: TimeInterval = 0) {
        self.frames = frames
        self.interval = interval
    }

    public func start() {
        cancelled = false
        onState?(.streaming)
        if interval <= 0 {
            for f in frames where !cancelled { onFrame?(f) }
            onState?(.stopped)
        } else {
            queue.async { [weak self] in
                guard let self else { return }
                for f in self.frames {
                    if self.cancelled { break }
                    self.onFrame?(f)
                    Thread.sleep(forTimeInterval: self.interval)
                }
                self.onState?(.stopped)
            }
        }
    }

    public func stop() {
        cancelled = true
        onState?(.stopped)
    }
}
