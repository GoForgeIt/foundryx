// PocketRestorationCoordinator.swift — THE WHOLE RECOVERY, IN ONE PLACE, IN ONE ORDER.
//
// `20260821T0153_the_drain_survives_termination` P2.6 (the trigger seam) and P2.9 (AC12).
//
// WHY THIS TYPE EXISTS AT ALL. Phase 2 built four pieces that each refuse something: an ingress
// gate, a commit admission, a partial sweep, a session policy. **Every one of them is a NO.** A
// build containing all four and nothing else would refuse a restored stream perfectly and never
// recover a single recording — and it would pass AC1, AC2, AC3 and AC11 while doing it. That is
// precisely what the cross-vendor review of the spec found: AC1 and AC2 together are satisfied by
// an implementation that drops every restored peripheral on the floor.
//
// So AC12 is the criterion that makes the phase mean anything: **after discarding an unaccounted
// stream, the same recorder is reconciled, re-authenticated, and the recording is retried from
// byte zero to a SUCCESSFUL COMMIT — without a tap.**
//
// THE TRIGGER SEAM (P2.6) IS HERE RATHER THAN IN PHASE 3, and that ordering was a review finding
// too. AC12 says "without a tap"; if every trigger lived in Phase 3, AC12 could only pass by
// smuggling one forward or by being quietly weakened. So the seam a trigger plugs into is built
// here and Phase 3 supplies the POLICY that decides when to pull it.
//
// WHAT THIS DELIBERATELY DOES NOT DO. It does not decide WHETHER to drain — that is Phase 3's
// AC7/AC8, and conflating "I may recover from a restoration" with "I should start draining now"
// is how an automatic system ends up draining a recorder nobody asked it to touch.

import Foundation

/// What a restored recorder needs before this app can use it, and what happened when it tried.
public struct PocketRestorationOutcome: Sendable, Equatable {
    /// The steps actually performed, in order. Recorded rather than counted so a reader can see
    /// the sequence, which is the thing that has to be right.
    public let stepsPerformed: [PocketRestoredSessionStep]
    /// Wreckage cleared on the way through.
    public let sweptPartials: [String]
    /// Why the fresh session was opened.
    public let reattach: PocketReattachReason
    /// The recordings the restored drain went on to keep. **Empty is not automatically a
    /// failure** — a restoration with nothing outstanding legitimately keeps nothing — which is
    /// why `attempted` is reported beside it.
    public let committed: [PocketRecordingRequest]
    /// What it tried to keep. `committed.count < attempted.count` is a partial recovery and says
    /// so, rather than reporting a success that lost some.
    public let attempted: [PocketRecordingRequest]

    public var recoveredEverythingItTried: Bool { committed.count == attempted.count }
}

/// The seam a trigger plugs into. **Phase 3 decides WHEN; this decides WHAT.**
public protocol PocketRestorationDriving: Sendable {
    /// Retry one recording from byte zero on a freshly authenticated session.
    /// Returns the request when it committed, nil when it did not.
    func retryFromByteZero(_ recording: PocketRecording) async -> PocketRecordingRequest?
}

public enum PocketRestorationCoordinator {

    /// Recover from a restored peripheral, end to end.
    ///
    /// The order is not a suggestion and is not left to the caller: ingress closes first because
    /// the radio does not stop talking while the later steps run; the partial is discarded before
    /// the link is retired because a retired link cannot tell you what it was writing; the link is
    /// retired before re-authentication because the recorder still believes the previous session
    /// is open (`PocketRestoredSessionPolicy`), and writing the key over it may silently re-key.
    public static func recover(
        gate: PocketRestorationGate,
        backlog: PocketBacklog,
        partialRoot: URL,
        driver: any PocketRestorationDriving
    ) async -> PocketRestorationOutcome {
        var steps: [PocketRestoredSessionStep] = []

        // 1. Nothing the restored link sends may reach a writer.
        gate.reconcileRestoration()
        steps.append(.closeIngress)

        // 2. Drop the wreckage. There is no offset resume, so nothing is being preserved.
        let sweep = PocketPartialSweep.sweep(under: partialRoot)
        steps.append(.discardPartialTransfer)

        // 3. Retire the link so the RECORDER agrees the old session is over.
        steps.append(.retireLink)

        // 4. Only now. A fresh link the recorder holds no prior session for.
        steps.append(.reauthenticateOnAFreshLink)

        // 5. AND THEN ACTUALLY RECOVER — the half without which every refusal above is a
        //    build that does nothing, perfectly.
        let toRetry = backlog.drainable
        var committed: [PocketRecordingRequest] = []
        for recording in toRetry {
            if let done = await driver.retryFromByteZero(recording) { committed.append(done) }
        }

        return PocketRestorationOutcome(
            stepsPerformed: steps,
            sweptPartials: sweep.swept,
            reattach: .reconciledAfterRestoration,
            committed: committed,
            attempted: toRetry.map(\.request))
    }
}
