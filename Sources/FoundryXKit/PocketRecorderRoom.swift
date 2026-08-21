// PocketRecorderRoom.swift — A RECORDER WITH NO ROOM LEFT SAYS SO, AND OFFERS BOTH WAYS OUT.
//
// Nick's ruling, 2026-08-21: clearing ships BOTH automatically and manually, the choice is a
// per-recorder setting, and *"an error when the user tries to record and there's no space left,
// guiding them to clear space or turn on auto clearing."*
//
// ONE THING THIS CANNOT DO, and it is stated here rather than discovered later: **the Pocket
// records from its own button, autonomously.** No code in this app is in that path, so nothing
// here can refuse a press or show anything at the moment of one. A design that claimed to would
// be describing a hook that does not exist.
//
// So the guidance is delivered at the moments this app DOES control:
//
//   1. Turning this recorder on for capture — the app's own act, and the moment a person is
//      forming the expectation that pressing the button will work.
//   2. The recorder page — where somebody goes when a recording did not appear.
//
// AND THE THIRD STATE IS THE POINT. `notAsked` is not `roomRemaining(0)` and not `noRoomLeft`:
// a recorder nobody has checked must not be called full and must not be called empty. Every
// figure this app prints about a recorder goes through `PocketMeasuredFigures` first, and a
// reading that never arrived renders as the never-asked state with the action that would ask
// it. Collapsing "unknown" into either answer is how a page ends up telling somebody to clear
// space on a recorder that has plenty.

import Foundation

/// Whether the recorder can take another recording.
///
/// Three cases, and the third is load-bearing: **a recorder nobody asked is neither full nor
/// empty.** An optional `Bool` would have exactly the hole this closes — `nil` meaning both
/// "unknown" and "no", decided by whichever caller read it.
public enum PocketRecorderRoom: Sendable, Equatable {
    /// Nobody has asked, or the recorder answered nothing usable. **Not a failure**, and not a
    /// licence to say anything about how full it is.
    case notAsked
    /// It answered, and there is room. Carries how full it is so a surface that already prints
    /// that does not compute it a second way.
    case roomRemaining(percentFull: Int)
    /// It reported at least as much used as it has capacity. Nothing more will record.
    case noRoomLeft

    /// **The predicate a destructive-adjacent surface reads.** `notAsked ⇒ false` by
    /// construction: there is no arm of this that an unasked recorder satisfies, which is the
    /// same shape as `PocketRecordingPresence.isDurableElsewhere`.
    public var isFull: Bool { self == .noRoomLeft }

    /// Whether anything may be said about fullness at all. Distinct from `isFull` on purpose —
    /// "say nothing" and "say there is room" are different surfaces.
    public var wasAnswered: Bool { self != .notAsked }
}

/// What a person is told and offered when the recorder has no room left.
public enum PocketRecorderRoomPresentation {

    /// The headline. Says the consequence, not the measurement — "100% full" is a number, and
    /// *"it will not record anything more"* is what that number MEANS to somebody who is about
    /// to walk into a meeting relying on it.
    public static let fullHeadline = "This recorder is full."

    /// The consequence, stated plainly. **The recorder keeps its button and will still be
    /// pressed**; what it will not do is keep what it hears.
    public static let fullConsequence =
        "It will not record anything more until you make room."

    /// Route 1 — do it now, by hand.
    public static let makeRoomAction = "Make room now"

    /// Route 2 — the standing choice, so this does not happen again.
    public static let armAutoClearAction = "Clear recordings automatically once they're safe"

    /// What arming actually promises, stated beside the offer rather than after it is accepted.
    /// **It is not "delete everything"** — the same durability predicate governs the automatic
    /// path as the manual one, and this sentence is the only place a person learns that before
    /// choosing.
    public static let armAutoClearConsequence =
        "Recordings are removed from the recorder only once they're safely stored somewhere else."

    /// Said when capture is turned on for a recorder that has no room. The app cannot stop the
    /// recorder's own button, so this warns rather than claims to prevent.
    public static let fullOnCaptureEnable =
        "This recorder is full, so pressing its button won't record anything."

    /// THE OFFERS, over the population rather than as separate booleans a caller must remember
    /// to check. An already-armed recorder is NOT offered arming again — an offer that does
    /// nothing when taken is worse than no offer.
    ///
    /// - Returns: the actions to show, in order. **Empty when the recorder is not full**, and a
    ///   caller rendering an empty list draws nothing, which is the correct behaviour for a
    ///   recorder with room and for one nobody has checked.
    public static func offers(room: PocketRecorderRoom,
                              autoClear: PocketAutoClear) -> [String] {
        guard room.isFull else { return [] }
        return autoClear.isArmed ? [makeRoomAction] : [makeRoomAction, armAutoClearAction]
    }

    /// THE POPULATION. Every line this behaviour can render, so a claim about its copy is held
    /// over the whole set rather than over whichever string a test author remembered — the same
    /// discipline as `PocketRemoveFromRecorderPresentation.everyLine`.
    public static let everyLine: [String] = [
        fullHeadline, fullConsequence, makeRoomAction,
        armAutoClearAction, armAutoClearConsequence, fullOnCaptureEnable,
    ]
}
