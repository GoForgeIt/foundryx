// GapRecoveryWindow — the gap-recovery window, modelled as data
// (track 20260725T2306_device_agnostic_recording_source, task T3).
//
// THE DISTINCTION THIS FILE EXISTS TO KEEP. When the link returns, the device may still be
// holding audio recorded while it was away. Three situations look alike from the transport
// and are completely different to the person who was talking:
//
//   * we pulled it back                            -> `.recovered`
//   * we did NOT pull it back this time, and the
//     device still has it for the next reconnect   -> `.nothingToRecover`   (NOT a loss)
//   * it is gone                                   -> `.unrecoverable`      (a loss)
//
// The shipped sync engine already distinguishes them internally — `failed` deliberately
// issues no ring advance so "the device keeps its unread cache for next reconnect" — but
// nothing published that distinction, so any surface would have had to guess. Guessing
// wrong in the safe-looking direction ("couldn't recover your audio") tells a person their
// conversation is lost when it is sitting on the device.
//
// EVERY CLOSE IS DATA. The window is a value type whose `Close` enum enumerates the ways it
// can end, so "how many call sites close the window" is not a number anyone maintains, and
// no call site can invent an outcome of its own. Two rules the plan fixes:
//
//   * at most ONE outcome per opened window;
//   * exactly one only for a window tagged AT OPEN as following an interrupted capture —
//     a window that interrupted nothing has nothing to say and says nothing.
//
// Whether a drop interrupted an active capture is a fact `CaptureManager` owns.
// `DeviceManager` reports transport facts and must never infer it.

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

    /// True only when audio was actually lost. `.nothingToRecover` is deliberately NOT a
    /// loss: the span is still on the device.
    public var isLoss: Bool {
        if case .unrecoverable = self { return true }
        return false
    }
}

/// A published gap outcome, WITH the account whose audio it is about.
///
/// THE SCOPE IS PART OF THE FACT, not decoration (track T5, carried hazard N7). The outcome is
/// published from `didDisconnect`, which also runs during an account-exposure close — and the
/// close gates the source state while leaving the gap outcome ungated. A consumer handed a
/// bare `GapRecoveryOutcome` has no way to notice, and would render one account's recording
/// history into whichever account happens to be on screen. Carrying the scope the window was
/// OPENED under makes that impossible to miss: the renderer cannot get the sentence without
/// first being handed the account it belongs to.
public struct GapRecoveryReport: Equatable, Sendable {
    public let outcome: GapRecoveryOutcome
    /// The account scope current when the window opened. `nil` when none was resolvable —
    /// a first-class answer, not an absence to paper over.
    public let accountScope: String?

    public init(outcome: GapRecoveryOutcome, accountScope: String?) {
        self.outcome = outcome
        self.accountScope = accountScope
    }
}

/// How a conversation interrupted by the drop continues once the link returns.
public enum GapCaptureContinuation: Equatable, Sendable {
    case resumeSame(captureId: String)
    /// A replacement conversation was proposed while an interrupted one is still carried.
    /// Refused: the gap must not split one conversation into two.
    case refuseReplacement(carrying: String, proposed: String)
    case openFresh
}

/// What a transport event MEANS for the gap window.
///
/// These are pure so the funnel's decisions are drivable without a radio. The alternative —
/// deciding inline in a CoreBluetooth delegate method — is what let a discarded `error` turn
/// "we could not read this device's services" into "this device does not keep audio", a
/// permanent-loss claim, with no test able to see the difference.
enum GapWindowTrigger {

    /// A service-discovery RESULT.
    ///
    /// A discovery that FAILED tells us nothing about whether the device stores audio: its
    /// service list is empty because the read did not happen, not because the device has no
    /// storage. Treating those two as the same fact is the false-loss direction this whole
    /// task exists to prevent, so a failed discovery is `.storageUnavailable` (retriable,
    /// not a loss) and `.deviceHasNoStorage` is reserved for a discovery that SUCCEEDED and
    /// genuinely returned no storage service.
    /// The four cells of `{error nil, non-nil} x {storage seen, not seen}`:
    ///
    ///   nil      x seen      -> nil, the characteristic path continues
    ///   non-nil  x seen      -> nil, ALSO continues (see below)
    ///   nil      x not seen  -> `.deviceHasNoStorage`, an honest loss
    ///   non-nil  x not seen  -> `.storageUnavailable`, retriable, not a loss
    ///
    /// SEEING THE SERVICE WINS OVER THE ERROR. `didDiscoverServices` has already issued
    /// `discoverCharacteristics` for a storage service it found, and `maybeBeginGapSync`
    /// needs the hold still open to use them. Closing here because a *different* service
    /// failed would tear that down and forfeit a recovery that was about to happen — the
    /// code would be starting characteristic discovery for the storage service and
    /// declaring the storage unreachable in the same breath. If the characteristics never
    /// arrive, the decision deadline already releases the hold with its own honest cause.
    static func closeCause(discoveryError: String?,
                           sawStorageService: Bool) -> GapRecoveryWindow.Close? {
        if sawStorageService { return nil }
        if let discoveryError { return .storageUnavailable(reason: discoveryError) }
        return .deviceHasNoStorage
    }

    // A link drop needs no parameter. `OmiOfflineSyncEngine.linkDropped()` publishes
    // SYNCHRONOUSLY through `gapSyncFinished` before the drop handler runs, so by then the
    // window is already closed and the window's own at-most-one rule makes this close a
    // no-op. An `engineWasRunning` argument therefore selected between two branches that
    // are indistinguishable in every reachable state — a discrimination that could not be
    // tested because it does not exist. Removed rather than left as a decorative claim.
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
        /// The device exposes no offline storage at all, so it never recorded the gap.
        case deviceHasNoStorage
        /// The device HAS storage but we could not talk to it this time.
        case storageUnavailable(reason: String)
        /// Any other close before an engine ran (superseded, torn down, budget released).
        case closedWithoutEngine(reason: String)
    }

    /// The conversation the drop interrupted, as reported by the owner of capture state.
    /// `nil` means the drop interrupted nothing.
    public let interruptedCaptureId: String?
    /// The account whose audio this window is about, captured AT OPEN — not at close. By the
    /// time it closes the exposed account may already have changed, which is precisely the
    /// case the scope exists to catch.
    public let accountScopeAtOpen: String?
    public private(set) var isOpen: Bool
    public private(set) var published: GapRecoveryOutcome?

    public init(interruptedCaptureId: String?, accountScopeAtOpen: String? = nil) {
        self.interruptedCaptureId = interruptedCaptureId
        self.accountScopeAtOpen = accountScopeAtOpen
        self.isOpen = true
        self.published = nil
    }

    public var followsInterruptedCapture: Bool { interruptedCaptureId != nil }

    /// Close the window. Returns the outcome to publish, or `nil` when there is nothing
    /// honest to say: a window that interrupted no conversation, or one already closed.
    public mutating func close(_ cause: Close) -> GapRecoveryOutcome? {
        guard isOpen else { return nil }          // at most one outcome per opened window
        isOpen = false
        guard followsInterruptedCapture else { return nil }   // nothing interrupted, nothing to say
        let outcome: GapRecoveryOutcome
        switch cause {
        case .engineFinished(let ending):
            outcome = Self.outcome(for: ending)
        case .linkDroppedBeforeEngine:
            outcome = .nothingToRecover(
                reason: "the link went away before this audio could be requested, so the "
                    + "device still has it for the next reconnect")
        case .decisionDeadlinePassed:
            outcome = .nothingToRecover(
                reason: "this device did not offer its stored audio in time, so it still "
                    + "has it for the next reconnect")
        case .deviceHasNoStorage:
            // Not a failure to COLLECT — a failure to have recorded. This device keeps no
            // audio while it is disconnected, so the gap was never captured and is gone.
            // Calling that "still on the device" would be the opposite lie.
            outcome = .unrecoverable(
                reason: "this device does not keep audio while it is disconnected, so "
                    + "nothing was recorded during the gap")
        case .storageUnavailable(let reason):
            outcome = .nothingToRecover(
                reason: "this device's stored audio could not be reached (\(reason)), so it "
                    + "still has it for the next reconnect")
        case .closedWithoutEngine(let reason):
            outcome = .nothingToRecover(
                reason: "this audio was never requested (\(reason)), so the device still "
                    + "has it for the next reconnect")
        }
        published = outcome
        return outcome
    }

    /// The engine's ending, translated into what the user is told.
    public static func outcome(for ending: OmiOfflineSyncEngine.Outcome) -> GapRecoveryOutcome {
        switch ending {
        case .nothingToSync:
            return .nothingBuffered
        case .synced(let records, let frames):
            // A transfer that carried no frames recovered nothing, and saying "recovered"
            // about zero audio is the same lie in the other direction.
            return frames > 0 ? .recovered(records: records, frames: frames) : .nothingBuffered
        case .aborted(let records, let frames, let reason):
            // The engine advanced ONLY over what it consumed, so the remainder is still on
            // the device — partial recovery, not loss.
            return .partiallyRecovered(records: records, frames: frames, reason: reason)
        case .failed(let why):
            // Nothing was consumed and NO advance was issued: the device keeps its unread
            // cache for the next reconnect. This is the case that must never read as loss.
            return .nothingToRecover(
                reason: "this audio could not be collected (\(why)), so the device still "
                    + "has it for the next reconnect")
        case .unsupportedProtocol(let why):
            // The device cannot replay what it recorded while away. That audio is gone.
            return .unrecoverable(
                reason: "this device cannot send back audio it recorded while disconnected "
                    + "(\(why))")
        }
    }

    /// Whether the conversation carried through the gap is resumed, or a proposed
    /// replacement is refused.
    public func continuation(forProposedCaptureId proposed: String?) -> GapCaptureContinuation {
        guard let carried = interruptedCaptureId else { return .openFresh }
        guard let proposed else { return .resumeSame(captureId: carried) }
        // A gap must not split one conversation into two: while an interrupted identity is
        // carried, a DIFFERENT proposed conversation is refused rather than opened.
        return proposed == carried
            ? .resumeSame(captureId: carried)
            : .refuseReplacement(carrying: carried, proposed: proposed)
    }
}
