// PocketRecorderDeleteGate.swift — THE PROMISE, AS A GATE INSTEAD OF AN ABSENCE.
//
// WHAT THIS REPLACES, AND WHY THE THING IT REPLACES WAS WRONG. The 2026-08-15 design proposed a
// test that "enumerates every command this client can compose and asserts none of them is a
// delete verb". Two defects, both fatal:
//
//   1. IT ASSERTS AN ABSENCE, AND AN ABSENCE IS SATISFIED BY AN EMPTY CODEBASE. A negative
//      predicate over a population nobody checked is non-empty passes on a recorder Solleva
//      never spoke to. Every prohibition in this repository is paired with an existence
//      assertion over the SAME population for exactly this reason, and this file is what makes
//      that population readable.
//   2. THE ABSENCE IS ALREADY FALSE. The recorder's delete is `APP&D&<date>&<timestamp>`,
//      answered `MCU&D` — a SINGLE-LETTER opcode, decoded from an HCI capture of the vendor app
//      and public since 2026-08-07. Every grep this repository ran for `DEL` missed it, and the
//      client COMPOSES its commands (`write("APP&\(command)")`), so no literal existed to grep
//      for either. Shipping a gate asserting that verb cannot exist would have permanently
//      locked out a wire form we already hold, on the strength of a belief that was wrong.
//
// THE PROMISE THAT IS ACTUALLY TRUE, ruled by Nick on 2026-08-16: nothing leaves the recorder
// unless we can prove we already hold it somewhere else. Two paths and no third — a person
// chooses it for a recording whose safety we can demonstrate, or a person ARMS an automatic
// clear that is off by default. So the gate this file ships is not "no delete verb exists". It
// is: NO CODE PATH COMPOSES A DELETE FOR A RECORDING NOBODY CHOSE. That is the stronger test —
// it cannot be satisfied by deleting code, only by the behaviour being right.
//
// WHAT IS IN HERE AND WHAT IS DELIBERATELY NOT. The consent type and the gate are here. THE
// VERB IS NOT: nothing in this repository composes `APP&D&…`, and the bytes have never been
// issued to a real recorder — the decode is third-party and the upstream PR carrying it has
// zero review comments. One non-destructive probe naming a file that cannot exist settles it,
// and that probe comes before any owner-facing delete.
//
// THE COLLISION THIS FILE EXISTS TO NOT HAVE. `MCU&D` is a PREFIX of `MCU&DIRS&<date>`, which is
// what a recorder answers when it lists the days it holds. A matcher written as
// `response.hasPrefix("MCU&D")` therefore reads EVERY directory listing as a successful
// deletion. Nothing here prefix-matches: a frame is split at the protocol's own delimiter and
// the opcode FIELD is compared whole.

import Foundation

// MARK: - The wire, read by field rather than by prefix

/// THE `&`-DELIMITED CONTROL PROTOCOL, PARSED THE ONLY WAY THAT IS SAFE.
///
/// A frame is `<actor>&<opcode>[&<argument>…]` — `APP&U&2026-03-28&20260328001919` going out,
/// `MCU&DIRS&2026-03-28` coming back. The opcode is field ONE, and it is compared whole.
public enum PocketRecorderWire {

    /// The recorder's delete opcode. ONE LETTER, which is why every search for `DEL` missed it.
    public static let deleteOpcode = "D"

    /// A frame's fields, at the protocol's own delimiter. Empty subsequences are KEPT, so a
    /// malformed frame stays malformed instead of quietly shifting its own arguments left.
    public static func fields(of frame: String) -> [String] {
        frame.split(separator: "&", omittingEmptySubsequences: false).map(String.init)
    }

    /// The opcode field, or nil when the frame carries none.
    public static func opcode(of frame: String) -> String? {
        let fields = fields(of: frame)
        guard fields.count >= 2, !fields[1].isEmpty else { return nil }
        return fields[1]
    }

    /// WHETHER THIS FRAME IS ABOUT REMOVING A RECORDING — in either direction.
    ///
    /// `APP&D&<date>&<timestamp>` (the request) and `MCU&D` (the acknowledgement) both answer
    /// yes; `APP&LIST_DIRS` and `MCU&DIRS&2026-03-28` both answer no, which is the whole reason
    /// this is a field comparison and not `hasPrefix("MCU&D")`.
    public static func namesADeletion(_ frame: String) -> Bool {
        opcode(of: frame) == deleteOpcode
    }
}

// MARK: - Consent

/// A DELETION MAY NOT HAPPEN BY ACCIDENT, AND THE TYPE SYSTEM IS WHERE THAT IS ENFORCED.
///
/// Deliberately the same shape as `PocketMintConsent`, for the same reason: a recorder is the
/// only place some recordings exist, and an operation that can lose one may not be reachable by
/// omission, by a default argument, or by a caller that happened to pass `true`. There is no
/// public initialiser, and the two factories are named for the two things the owner has to have
/// done — the ruling's two paths, and no third. A code path that wants a deletion has to hold
/// one of these, and the only way to get one is to say, in code, which path authorised it.
///
/// IT NAMES ONE RECORDING. Consent is not a mode. A value of this type authorises the removal of
/// the single file it carries and nothing else, so a path that obtained consent for one
/// recording cannot spend it on another.
///
/// IT DOES NOT COMPUTE SAFETY — IT REQUIRES IT. This distinction is the whole design, and the
/// first version of this file got it wrong: it enforced CONSENT and advertised PROOF. Whether
/// Solleva can prove it already holds this recording somewhere else is a question with exactly
/// one answer in this app — the Presence row's `PocketRecordingPresence.isDurableElsewhere`,
/// resolved once by `PocketShelfReadModel.presences` and drawn on the shelf. This type does not
/// recompute it (two answers to "is this safe" is how a recording gets lost) but it will not
/// come into existence without being SHOWN it. The factories are failable and return nil for
/// any reading that does not say yes, which includes every reading nobody asked for.
///
/// WHY FAILABLE RATHER THAN A CHECK AT THE CALL SITE. Nick's ruling is *"nothing is ever
/// removed from the recorder unless we can prove we already hold it somewhere else."* A call
/// site that must remember to check is a rule that holds until somebody forgets; a factory that
/// cannot return a value is a rule that holds because the alternative does not compile.
public struct PocketDeleteConsent: Sendable, Equatable {

    /// WHICH OF THE RULING'S TWO PATHS AUTHORISED THIS, kept because they are genuinely
    /// different acts and the ledger is the audit trail for both. "This person chose this
    /// recording" and "this person armed this recorder, and this recording later met the bar"
    /// are not the same sentence, and a ledger that files them under one name cannot answer the
    /// only question anybody will ever ask it: which of the two removed my recording.
    public enum Provenance: String, Sendable, Equatable, CaseIterable {
        /// Path 1 — an explicit tap on this recording.
        case ownerChose
        /// Path 2 — the owner-armed automatic clear, off by default and recorder-scoped.
        case ownerArmedThisRecorder
    }

    /// The one recording this consent authorises the removal of.
    public let file: PocketRecorderFileKey
    /// Which path authorised it.
    public let provenance: Provenance

    /// PATH 1. The owner was shown this recording, was told it would be removed from the
    /// recorder, and chose it — AND the shelf's own reading says we already hold it elsewhere.
    ///
    /// - Parameter provenSafeBy: the reading the row was drawn from. nil is returned unless it
    ///   says yes, so `unknown` — a place nobody asked about — can never authorise a removal.
    public static func ownerChoseThisRecording(
        _ file: PocketRecorderFileKey,
        provenSafeBy presence: PocketRecordingPresence
    ) -> PocketDeleteConsent? {
        guard presence.isDurableElsewhere else { return nil }
        return PocketDeleteConsent(file: file, provenance: .ownerChose)
    }

    /// PATH 2. The owner turned on this recorder's automatic clear, and this recording has since
    /// synced. The SAME predicate, deliberately — an armed control is a standing choice, not a
    /// lower bar, and the ruling says so: *"never retroactive to recordings whose safety we
    /// cannot currently demonstrate."*
    public static func ownerArmedThisRecorder(
        _ file: PocketRecorderFileKey,
        provenSafeBy presence: PocketRecordingPresence
    ) -> PocketDeleteConsent? {
        guard presence.isDurableElsewhere else { return nil }
        return PocketDeleteConsent(file: file, provenance: .ownerArmedThisRecorder)
    }

    private init(file: PocketRecorderFileKey, provenance: Provenance) {
        self.file = file
        self.provenance = provenance
    }

    /// Whether this consent authorises the frame about to be composed. Both the day and the
    /// instant must match: a recorder names its files by `(date, timestamp)`, so a comparison
    /// on the date alone would let one day's consent remove every recording made that day.
    func authorises(frame: String) -> Bool {
        let fields = PocketRecorderWire.fields(of: frame)
        guard fields.count >= 4, fields[1] == PocketRecorderWire.deleteOpcode else { return false }
        return fields[2] == file.date && fields[3] == file.timestamp
    }
}

// MARK: - The census

/// ONE COMMAND THIS APP COMPOSED FOR A RECORDER, AND WHAT BECAME OF IT.
public struct PocketRecorderComposedCommand: Sendable, Equatable {

    /// What happened to a frame after it was composed. All three are recorded, because the
    /// invariant is about what the code COMPOSES — a deletion that was refused before it
    /// reached the radio is still a code path that composed one, and hiding it would leave the
    /// gate unable to see the thing it exists to see.
    public enum Disposition: String, Sendable, Equatable {
        /// Written to the recorder's command characteristic.
        case putOnTheWire
        /// Composed, then refused by the gate: a deletion nobody chose.
        case refusedBecauseNobodyChoseIt
        /// Composed and allowed, and the radio would not take it.
        case couldNotBeSent
    }

    public let frame: String
    public let disposition: Disposition

    public init(frame: String, disposition: Disposition) {
        self.frame = frame
        self.disposition = disposition
    }

    public var namesADeletion: Bool { PocketRecorderWire.namesADeletion(frame) }
}

/// EVERY COMMAND THIS APP COMPOSES FOR A RECORDER, IN ORDER.
///
/// This is the population the promise is asserted over. Without it "Solleva issued no delete"
/// was a sentence in a comment and a constant equal to zero — a claim no mutation could falsify,
/// asserted in four suites, none of which could have noticed a real one.
///
/// It is process-wide because the invariant is process-wide: a delete composed by any client,
/// on any session, for any recorder, is the thing that must not happen. Reads are taken relative
/// to a `mark`, so a caller measures ITS OWN window and concurrent sessions cannot make the
/// window empty.
///
/// BOUNDED, AND HONEST ABOUT IT. A long-lived app must not accumulate this forever, so the ring
/// keeps the most recent `bound` frames and counts what it dropped — which keeps `since(_:)`
/// arithmetic correct rather than silently sliding.
public actor PocketRecorderCommandLedger {

    public static let shared = PocketRecorderCommandLedger()

    /// A position in the stream of composed commands.
    public struct Mark: Sendable, Equatable {
        fileprivate let position: Int
        fileprivate init(position: Int) { self.position = position }
    }

    private var recent: [PocketRecorderComposedCommand] = []
    private var dropped = 0
    private let bound: Int

    public init(bound: Int = 4_096) { self.bound = max(1, bound) }

    /// Where the stream is now. Everything a caller goes on to do is `composed(since:)` this.
    public func mark() -> Mark { Mark(position: dropped + recent.count) }

    public func record(_ command: PocketRecorderComposedCommand) {
        recent.append(command)
        if recent.count > bound {
            let excess = recent.count - bound
            recent.removeFirst(excess)
            dropped += excess
        }
    }

    /// Every command composed since `mark`. Frames the ring has already dropped are gone, so
    /// this is the most recent window rather than a lie about the whole history.
    public func composed(since mark: Mark) -> [PocketRecorderComposedCommand] {
        let offset = max(0, mark.position - dropped)
        guard offset < recent.count else { return [] }
        return Array(recent[offset...])
    }
}

// MARK: - The gate

/// THE ONE PLACE A COMMAND FOR A RECORDER IS ADMITTED OR REFUSED.
///
/// `PocketBLEClient.write(_:ownerConsent:)` is the single composer in this app, and it consults
/// this before anything reaches the radio. Everything except a deletion is admitted unchanged;
/// a deletion is admitted only when it is covered by an owner's consent naming that exact
/// recording.
public enum PocketRecorderCommandGate {

    public enum Refusal: String, Sendable, Equatable {
        /// A delete was composed for a recording no person chose.
        case nobodyChoseThisRecording
        /// A delete was composed while holding consent for a DIFFERENT recording.
        case consentNamesAnotherRecording
    }

    public enum Admission: Sendable, Equatable {
        case admitted
        case refused(Refusal)
    }

    /// Decide, and record the decision. Recording happens here rather than at the call site so
    /// a refusal cannot be composed and then quietly dropped without the census seeing it.
    public static func admit(frame: String,
                             ownerConsent: PocketDeleteConsent?,
                             into ledger: PocketRecorderCommandLedger = .shared) async -> Admission {
        guard PocketRecorderWire.namesADeletion(frame) else { return .admitted }
        if let ownerConsent, ownerConsent.authorises(frame: frame) { return .admitted }
        let refusal: Refusal = ownerConsent == nil
            ? .nobodyChoseThisRecording
            : .consentNamesAnotherRecording
        await ledger.record(.init(frame: frame, disposition: .refusedBecauseNobodyChoseIt))
        return .refused(refusal)
    }
}
