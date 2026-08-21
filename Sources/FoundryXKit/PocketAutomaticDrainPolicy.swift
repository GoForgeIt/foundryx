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

    /// Why the armed clear is not taking a recording the drain just brought over.
    ///
    /// Never a bare omission from a list: "it was not offered" and "it was not offered because
    /// nowhere else has answered yes" are different facts, and only the second can be shown to a
    /// person or acted on.
    public enum PocketAutoClearRefusal: Sendable, Equatable {
        /// The owner has not armed this recorder. The default, and not a failure.
        case recorderIsNotArmed
        /// **THE SAFETY PREDICATE.** Nowhere other than the recorder has answered `yes`. An
        /// unasked place is not a copy anybody holds, so `unknown` lands here too.
        case notProvenToBeAnywhereElse

        public var line: String {
            switch self {
            case .recorderIsNotArmed:
                return "automatic clearing is off for this recorder"
            case .notProvenToBeAnywhereElse:
                return "it is not proven to be anywhere other than the recorder"
            }
        }
    }

    /// What the armed clear decided about one recording. Both arms carry the request, so a
    /// caller can render the kept ones as easily as the cleared ones.
    public enum PocketAutoClearDecision: Sendable, Equatable {
        case clear(PocketRecordingRequest)
        case keep(PocketRecordingRequest, because: PocketAutoClearRefusal)
    }

    /// AC15, **RESOLVED BY NICK 2026-08-21: automatic AND manual, the owner chooses.**
    ///
    /// This used to return `[]` unconditionally — automatic pulling with manual clearing —
    /// as a deliberate, flagged scope reduction while an unattended drain had never run
    /// unattended without incident. Nick's ruling supersedes it: both paths ship, the choice
    /// is a per-recorder setting, and a person who cannot record because the recorder is full
    /// is told so and offered both ways out.
    ///
    /// **WHAT DID NOT CHANGE, AND MUST NOT.** The safety predicate is the same one the manual
    /// path has always used — `PocketRemoveFromRecorderPresentation.autoClearMayTake`, i.e.
    /// `presence.isDurableElsewhere`. Arming a recorder does NOT lower the bar for removal; it
    /// only removes the requirement that a person tap each one. Nick's standing rule is intact:
    /// *nothing leaves the recorder unless we can prove we hold it somewhere else.*
    ///
    /// **TWO GATES, BOTH REQUIRED.** Armed, and provably elsewhere. Reading `autoClear` first
    /// is not an optimisation — an unarmed recorder must not have its presence consulted at
    /// all, so that a bug in presence resolution cannot express itself as a deletion on a
    /// recorder whose owner never opted in.
    ///
    /// - Parameter presence: resolved per recording by the caller. Injected rather than fetched
    ///   so a test can choose the state; a policy that fetches its own inputs cannot be driven.
    public static func clearDecisions(
        broughtOverAutomatically: [PocketRecordingRequest],
        autoClear: PocketAutoClear,
        presence: (PocketRecordingRequest) -> PocketRecordingPresence
    ) -> [PocketAutoClearDecision] {
        guard autoClear.isArmed else {
            return broughtOverAutomatically.map { .keep($0, because: .recorderIsNotArmed) }
        }
        return broughtOverAutomatically.map { request in
            PocketRemoveFromRecorderPresentation.autoClearMayTake(presence(request))
                ? .clear(request)
                : .keep(request, because: .notProvenToBeAnywhereElse)
        }
    }

    /// The recordings the armed clear may take. A thin read over `clearDecisions`, kept so the
    /// common call site does not restate the filter — and deliberately NOT the primary API, so
    /// a caller that wants to say why something was kept has somewhere to get it.
    public static func clearCandidates(
        broughtOverAutomatically: [PocketRecordingRequest],
        autoClear: PocketAutoClear,
        presence: (PocketRecordingRequest) -> PocketRecordingPresence
    ) -> [PocketRecordingRequest] {
        clearDecisions(broughtOverAutomatically: broughtOverAutomatically,
                       autoClear: autoClear,
                       presence: presence)
            .compactMap { if case .clear(let r) = $0 { return r } else { return nil } }
    }
}
