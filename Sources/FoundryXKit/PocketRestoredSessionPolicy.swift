// PocketRestoredSessionPolicy.swift — WHAT TO DO WITH A LINK THE RECORDER STILL BELIEVES IN.
//
// `20260821T0153_the_drain_survives_termination` P2.4 / AC11.
//
// THE ASYMMETRY THAT MAKES THIS NECESSARY. iOS restores the TRANSPORT: the peripheral is still
// connected and its characteristics are still subscribed. What it does not restore is the
// application session — `APP&SK&<key>` was written by a process that no longer exists, and the
// `PocketBLEClient` that tracked it is gone. So the two ends disagree, and they disagree in the
// worst direction: **the recorder believes a session is open and the app knows nothing about it.**
//
// WHY RE-AUTHENTICATING OVER THE RESTORED LINK IS NOT THE ANSWER. The hardware permits ONE
// authenticated session at a time — `RecordingDeviceAttachment` is single-use for exactly this
// reason, and its own comment warns that "a second `APP&SK&` write against a recorder that already
// holds a key may silently re-key" (`RecordingDeviceAttachment.swift:64`). Writing the key again
// over a link the recorder already associates with a live session is the one move whose failure
// mode is silent.
//
// SO THE POLICY IS: RETIRE THE LINK FIRST. Disconnecting is what makes the recorder agree that
// the old session is over — and it is cheap, because the protocol has no offset resume
// (`PocketTransferJob.swift:17,20`), so nothing is being preserved by keeping the connection. The
// bytes already in flight are unaccountable anyway; P2.1 refuses them at ingress and P2.2 refuses
// to commit them.
//
// THE ORDER IS THE DESIGN, and it is stated as a sequence a caller cannot get wrong by being
// careful — a caller that has to remember an order is a caller that will eventually forget it.

import Foundation

/// What must happen to a restored link before this app may use the recorder again.
///
/// Deliberately an ordered list rather than a set of flags: "disconnect, then re-authenticate" and
/// "re-authenticate, then disconnect" are made of the same two facts and only one of them works.
public enum PocketRestoredSessionStep: Sendable, Equatable {
    /// Stop accepting anything the restored link delivers. First, because every later step takes
    /// time and the radio does not stop talking while it runs.
    case closeIngress
    /// Drop the partial transaction. Nothing is recoverable from it: there is no offset resume.
    case discardPartialTransfer
    /// Disconnect. This is what makes the RECORDER agree the old session is over — the app's
    /// opinion alone does not end a session the other end still believes in.
    case retireLink
    /// Only now: connect afresh and write the key. A new link the recorder has no prior session
    /// for is the only safe place to authenticate.
    case reauthenticateOnAFreshLink
}

public enum PocketRestoredSessionPolicy {

    /// THE SEQUENCE, in the only order that works.
    public static let sequence: [PocketRestoredSessionStep] = [
        .closeIngress,
        .discardPartialTransfer,
        .retireLink,
        .reauthenticateOnAFreshLink,
    ]

    /// May this app open an authenticated session right now?
    ///
    /// - Parameter completed: the steps already performed, in the order they were performed.
    /// - Returns: nil when the session may be opened, or the step that must happen first.
    ///
    /// **Reports the FIRST unsatisfied step rather than a bare no**, because "you may not open a
    /// session" and "you have not disconnected yet" are different facts, and only the second tells
    /// a caller what to do.
    public static func blockingStep(afterCompleting completed: [PocketRestoredSessionStep])
        -> PocketRestoredSessionStep? {
        for step in sequence where step != .reauthenticateOnAFreshLink {
            guard completed.contains(step) else { return step }
        }
        // AND THE ORDER, NOT ONLY THE SET. Performing every step in the wrong order leaves the
        // recorder having been asked to re-key over a link it still associated with the previous
        // session — the silent failure this whole file exists to avoid.
        let required = sequence.filter { $0 != .reauthenticateOnAFreshLink }
        let performed = completed.filter { required.contains($0) }
        guard performed == required else { return performed.first(where: { $0 != required[0] }) }
        return nil
    }

    /// Whether a restored link is safe to authenticate on. Never true for a link this process did
    /// not open — that is the whole point.
    public static func maySkipReconciliation(linkWasOpenedByThisProcess: Bool) -> Bool {
        linkWasOpenedByThisProcess
    }
}
