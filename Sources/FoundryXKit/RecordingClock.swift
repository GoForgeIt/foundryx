import Foundation

/// RecordingClock — the elapsed-time truth for a recording session.
///
/// THE LAW (track 20260717T0630, upholding cb6662e): the anchor is the RECORDING
/// SESSION — what the user perceives as "recording since I hit record" — NOT the
/// conversation. FoundryX rolls the conversation internally on a silence gap
/// (`endSession(); beginSession()` mints a NEW WAL with a fresh `startedAt`); those
/// internal rolls MUST be invisible to the user, so they PRESERVE this clock. Only
/// EXPLICIT boundaries reset it: Stop (phone-mic `.stopped`/`.failed`), End-current /
/// manual split (`splitConversation`), and the reconnect-grace expiry that finally
/// ends a held session with no new one beginning.
///
/// The clock is OWNED by `CaptureManager` and DERIVED — never stored — in views, so a
/// view re-present (minimize → restore, a fresh `fullScreenCover`) cannot reset it or
/// lose its pause bookkeeping.
///
/// Pause-aware: `elapsed(now:)` excludes paused spans, so the readout freezes while
/// paused (the audio does) and resumes without a jump — it shows time actually
/// recorded, not wall-clock since start.
public struct RecordingClock: Equatable, Sendable {
    /// When this recording session began (wall clock).
    public let startedAt: Date
    /// Total time already spent paused, accumulated across COMPLETED pause spans.
    public private(set) var pausedAccumulated: TimeInterval
    /// When the CURRENT pause began, or nil while running.
    public private(set) var pauseBeganAt: Date?

    /// Create a clock. `paused: true` starts it in the paused state (its live pause
    /// span begins at `now`) — for a session observed/resumed while already paused.
    public init(startedAt: Date, paused: Bool = false, now: Date = Date()) {
        self.startedAt = startedAt
        self.pausedAccumulated = 0
        self.pauseBeganAt = paused ? now : nil
    }

    /// Whether the clock is currently paused (its readout is frozen).
    public var isPaused: Bool { pauseBeganAt != nil }

    /// Begin a pause span at `at`. Idempotent — pausing while already paused is a no-op
    /// (keeps the original pause origin, so re-entrant pauses never lose deductions).
    public mutating func pause(at: Date) {
        guard pauseBeganAt == nil else { return }
        pauseBeganAt = at
    }

    /// End the current pause span at `at`, folding its duration into
    /// `pausedAccumulated`. Idempotent — resuming while already running is a no-op.
    public mutating func resume(at: Date) {
        guard let began = pauseBeganAt else { return }
        pausedAccumulated += max(0, at.timeIntervalSince(began))
        pauseBeganAt = nil
    }

    /// Seconds actually recorded as of `now`: wall-clock since start MINUS all paused
    /// spans (completed + the live one), floored at 0 (never negative).
    public func elapsed(now: Date) -> TimeInterval {
        let livePause = pauseBeganAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return max(0, now.timeIntervalSince(startedAt) - pausedAccumulated - livePause)
    }
}
