// PocketReattachReason.swift — WHY THE RADIO CAME BACK, SAID OUT LOUD.
//
// `20260821T0153_the_drain_survives_termination` P2.5 / AC10, and it also closes the open half of
// the predecessor track's AC12.
//
// THE DEFECT THIS PREVENTS HAS ALREADY HAPPENED HERE. On 2026-07-14 a flap investigation cost
// eight app restarts before anyone established that the re-attaches being chased were CONSEQUENCES
// of something else, not a radio misbehaving on its own. A re-attach with no stated cause is
// indistinguishable from a flap, and a reader who cannot tell them apart will go looking for a
// hardware fault that does not exist.
//
// `PocketTransferQueue` returns `.reattachNow` from FIVE different places — an owner's stop, a
// stall inside the retry budget, a stall past it, a dropped link, and a session that failed to
// authenticate — and the value carries nothing about which. The queue knows why in every case; it
// simply had nowhere to put the answer.
//
// AND THE ONE THAT MATTERS MOST IS RE-AUTHENTICATION. After a restoration the app writes
// `APP&SK&` again on a fresh link (P2.4). If that write is refused, the honest report is A REFUSAL
// — the recorder declining a key — and the dishonest one is a disconnect, because a refusal names
// a cause somebody can act on ("this recorder holds somebody else's key") while a disconnect sends
// them to look at the radio.

import Foundation

/// Why a session ended and another was opened.
///
/// Every case names a cause the queue already knew. None of them is "unknown": a re-attach whose
/// reason cannot be stated is a bug in whoever constructed it, not a state of the world.
public enum PocketReattachReason: Sendable, Equatable {
    /// The owner stopped one recording. The rest of the queue continues — stop-one is not
    /// stop-all, and the fresh session exists to serve the remainder.
    case ownerStoppedOneRecording
    /// The link was up and the recorder went quiet past the idle deadline. One immediate re-ask
    /// on a fresh session is the reference implementation's own first move.
    case recorderWentQuiet(attempt: Int, of: Int)
    /// The device left — out of range, powered off, or claimed by another phone.
    case linkDropped(attempt: Int, of: Int)
    /// The retry budget for this recording is spent. The re-attach serves the NEXT recording, not
    /// another go at this one, and saying so is the difference between "gave up" and "still
    /// trying".
    case budgetSpentMovingOn
    /// A restored session was reconciled and this is the fresh link P2.4 requires.
    case reconciledAfterRestoration
    /// `APP&SK&` was written and the recorder refused it. **A REFUSAL, NOT A DISCONNECT** — the
    /// recorder answered, and what it answered was no.
    case reauthenticationRefused

    /// One line for the command record. Written so that reading three of them in a row tells a
    /// person what the recorder is doing, which is the whole point.
    public var line: String {
        switch self {
        case .ownerStoppedOneRecording:
            return "new session: the previous one ended because you stopped a recording"
        case .recorderWentQuiet(let n, let of):
            return "new session: the recorder went quiet (attempt \(n) of \(of))"
        case .linkDropped(let n, let of):
            return "new session: the recorder left (attempt \(n) of \(of))"
        case .budgetSpentMovingOn:
            return "new session: out of attempts for that recording, moving to the next"
        case .reconciledAfterRestoration:
            return "new session: the previous link was restored by the system and retired"
        case .reauthenticationRefused:
            return "new session refused: the recorder declined this phone's key"
        }
    }

    /// A stable token for the command path, so a parser downstream can count causes without
    /// matching prose. Distinct per case for the same reason the outcome tokens are: folding
    /// several causes into one word is how "it didn't work" becomes unanswerable.
    public var token: String {
        switch self {
        case .ownerStoppedOneRecording: return "reattach:owner-stopped"
        case .recorderWentQuiet: return "reattach:went-quiet"
        case .linkDropped: return "reattach:link-dropped"
        case .budgetSpentMovingOn: return "reattach:budget-spent"
        case .reconciledAfterRestoration: return "reattach:restored"
        case .reauthenticationRefused: return "reattach:key-refused"
        }
    }

    /// **Whether this re-attach was caused by something the app or the owner did**, as opposed to
    /// the recorder behaving badly. The 2026-07-14 investigation existed because nobody could
    /// answer this question from the record.
    public var isConsequenceOfSomethingElse: Bool {
        switch self {
        case .ownerStoppedOneRecording, .budgetSpentMovingOn, .reconciledAfterRestoration:
            return true
        case .recorderWentQuiet, .linkDropped, .reauthenticationRefused:
            return false
        }
    }
}
