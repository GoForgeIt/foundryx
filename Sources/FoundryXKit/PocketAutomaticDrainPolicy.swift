// PocketAutomaticDrainPolicy.swift — WHETHER TO START A DRAIN NOBODY ASKED FOR.
//
// `20260821T0153_the_drain_survives_termination` Phase 3: AC7, AC8, AC15, AC16, AC17.
//
// EVERY OTHER PIECE OF THIS TRACK ANSWERS "HOW". This one answers "whether", and it is the only
// place in the drain where the app acts without a person present. That asymmetry is the whole
// design: **every refusal here is cheap and every wrongful start is not.** A drain that declines
// to run costs a delay. A drain that runs when it should not opens somebody's recorder over a
// radio they did not ask to use, on a phone whose battery they are watching.
//
// SO THE SHAPE IS: ONE REASON TO GO, AND ANY REASON NOT TO WINS. `mayStart` returns the first
// refusal it finds rather than a bool, because "no" and "no, because the owner stopped everything"
// are different answers and only the second can be rendered to a person or acted on by a caller.
//
// AND THE ONE THAT IS A PRODUCT DECISION, NOT A TECHNICAL ONE (AC15): **an automatic drain
// contributes no candidates to the owner-armed auto-clear.** Nick asked for pulling and clearing
// together. Clearing is irreversible and `autoClear` today is reachable only from the screen-owned
// completion path, over a screen-memory candidate set — so composing an unattended drain with an
// unattended delete puts a Tier-3 action behind a process nobody is watching. Automatic pulling,
// manual clearing, until the drain has run unattended for a while without incident. That is a
// deliberate scope reduction against the stated outcome and is flagged as one in the spec.

import Foundation

/// Why an automatic drain is not starting. Never a bare `false`.
public enum PocketAutomaticDrainRefusal: Sendable, Equatable {
    /// The recorder has never been paired with this phone. **Never drain a device the owner has
    /// not adopted** — a recorder in range is not a recorder that is yours.
    case recorderNotPaired
    /// The owner's stop-everything intent is set, and it outranks everything here.
    case ownerStoppedEverything
    /// Nothing is waiting. Not a failure; the ordinary resting state.
    case backlogEmpty
    /// The backlog could not be read. **Fails closed**, inheriting `autoClear`'s reasoning:
    /// guessing wrong the other way drains from an intent nobody can see.
    case backlogUnreadable(because: String)
    /// Somebody else holds the radio — the owner, or a restoration recovery.
    case radioBusy(PocketRadioClaimant)
    /// The recorder reports a session this phone did not open. **Refuse, do not race** (AC16):
    /// two phones draining one recorder is a state nobody designed for, and the loser corrupts
    /// nothing only by luck.
    case anotherPhoneIsDraining
    /// The device is conserving power. A drain is work that can wait; a phone that dies cannot.
    case lowPowerMode

    public var line: String {
        switch self {
        case .recorderNotPaired: return "this recorder has not been set up on this phone"
        case .ownerStoppedEverything: return "you stopped everything"
        case .backlogEmpty: return "there is nothing waiting to come over"
        case .backlogUnreadable(let why): return "the list of what is waiting could not be read: \(why)"
        case .radioBusy(let who): return "the recorder is busy with \(who)"
        case .anotherPhoneIsDraining: return "another phone is already talking to this recorder"
        case .lowPowerMode: return "the phone is in low power mode"
        }
    }
}

/// Everything the decision needs, gathered by the caller so this type reads no globals — a policy
/// that fetches its own inputs is a policy that cannot be tested against a state you choose.
public struct PocketAutomaticDrainConditions: Sendable {
    public let recorderIsPaired: Bool
    public let backlog: PocketBacklogReadout
    public let radioHeldBy: PocketRadioClaimant?
    public let recorderReportsForeignSession: Bool
    public let lowPowerModeEnabled: Bool

    public init(recorderIsPaired: Bool,
                backlog: PocketBacklogReadout,
                radioHeldBy: PocketRadioClaimant?,
                recorderReportsForeignSession: Bool,
                lowPowerModeEnabled: Bool) {
        self.recorderIsPaired = recorderIsPaired
        self.backlog = backlog
        self.radioHeldBy = radioHeldBy
        self.recorderReportsForeignSession = recorderReportsForeignSession
        self.lowPowerModeEnabled = lowPowerModeEnabled
    }
}

public enum PocketAutomaticDrainPolicy {

    /// May a drain start on its own right now?
    ///
    /// - Returns: nil to start, or the FIRST refusal. Ordered so the cheapest and most decisive
    ///   checks come first — an unpaired recorder is not worth reading a backlog for.
    public static func refusal(_ c: PocketAutomaticDrainConditions) -> PocketAutomaticDrainRefusal? {
        guard c.recorderIsPaired else { return .recorderNotPaired }
        if c.recorderReportsForeignSession { return .anotherPhoneIsDraining }
        if let who = c.radioHeldBy { return .radioBusy(who) }
        if c.lowPowerModeEnabled { return .lowPowerMode }

        switch c.backlog {
        case .unreadable(let why): return .backlogUnreadable(because: why)
        case .none: return .backlogEmpty
        case .backlog(let b):
            if b.stopEverything { return .ownerStoppedEverything }
            if b.drainable.isEmpty { return .backlogEmpty }
            return nil
        }
    }

    /// AC15. **An automatic drain contributes NO candidates to the owner-armed clear.**
    ///
    /// Not a bug and not an oversight: clearing removes a recording from the only device holding
    /// it, and an unattended drain composed with an unattended delete is a Tier-3 action nobody
    /// is watching. A recording brought over automatically is kept and left on the recorder; the
    /// owner clears it from a screen, as they do today.
    public static func clearCandidates(broughtOverAutomatically: [PocketRecordingRequest])
        -> [PocketRecordingRequest] {
        []
    }
}
