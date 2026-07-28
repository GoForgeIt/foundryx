// GapRecoveryWindow — the gap-recovery window, modelled as data.
//
// T3 RED STUB (track 20260725T2306_device_agnostic_recording_source). The type surface is
// declared so `features/device-gap-recovery.feature` can be wired and RUN; every body is
// unimplemented so the scenarios fail on real assertions, not on a missing symbol.

import Foundation

/// What became of the audio the device held while the link was down.
public enum GapRecoveryOutcome: Equatable, Sendable {
    case recovered(records: Int, frames: Int)
    case partiallyRecovered(records: Int, frames: Int, reason: String)
    /// The device had nothing unread for the gap — nothing was missed.
    case nothingBuffered
    /// Not pulled THIS time; the device still holds it for the next reconnect. This is
    /// not a loss and must never be rendered as "not recoverable".
    case nothingToRecover(reason: String)
    /// The audio for the gap is gone.
    case unrecoverable(reason: String)

    /// True only when audio was actually lost.
    public var isLoss: Bool { false }   // T3 RED STUB
}

/// How a conversation interrupted by the drop continues once the link returns.
public enum GapCaptureContinuation: Equatable, Sendable {
    case resumeSame(captureId: String)
    /// A replacement conversation was proposed while an interrupted one is still carried.
    /// Refused: the gap must not split one conversation into two.
    case refuseReplacement(carrying: String, proposed: String)
    case openFresh
}

/// One opened gap-recovery window.
public struct GapRecoveryWindow: Equatable, Sendable {

    /// Every way a window can close. Adding a close path is a case here, which is what
    /// keeps "how many call sites close the window" from being a number anyone maintains.
    public enum Close: Equatable, Sendable {
        case engineFinished(OmiOfflineSyncEngine.Outcome)
        /// The link went away before the sync engine could be started at all.
        case linkDroppedBeforeEngine
        /// The storage service never materialised within the decision deadline.
        case decisionDeadlinePassed
        /// Any other close before an engine ran (superseded, torn down, budget released).
        case closedWithoutEngine(reason: String)
    }

    /// The conversation the drop interrupted, as reported by the owner of capture state.
    /// `nil` means the drop interrupted nothing.
    public let interruptedCaptureId: String?
    public private(set) var isOpen: Bool
    public private(set) var published: GapRecoveryOutcome?

    public init(interruptedCaptureId: String?) {
        self.interruptedCaptureId = interruptedCaptureId
        self.isOpen = true
        self.published = nil
    }

    public var followsInterruptedCapture: Bool { interruptedCaptureId != nil }

    /// Close the window. Returns the outcome to publish, or `nil` when there is nothing
    /// honest to say: a window that interrupted no conversation, or one already closed.
    public mutating func close(_ cause: Close) -> GapRecoveryOutcome? {
        _ = cause
        return nil   // T3 RED STUB
    }

    /// The engine's ending, translated into what the user is told.
    public static func outcome(for ending: OmiOfflineSyncEngine.Outcome) -> GapRecoveryOutcome {
        _ = ending
        return .nothingBuffered   // T3 RED STUB
    }

    /// Whether the conversation carried through the gap is resumed, or a proposed
    /// replacement is refused.
    public func continuation(forProposedCaptureId proposed: String?) -> GapCaptureContinuation {
        _ = proposed
        return .openFresh   // T3 RED STUB
    }
}
