// PocketRecorderClearing.swift — TAKING A RECORDING OFF THE RECORDER, ON PURPOSE.
//
// Step 6 of the pocket delivery plan, under Nick's ruling of 2026-08-16:
//
//   "delete only is allowed after a recording has been pulled over and the user chooses to
//    delete or they can set a control to auto clear space after something has synced to
//    computer or vault"
//
// THE INVARIANT. Nothing leaves the recorder unless we can prove we already hold it somewhere
// else. Two paths and no third — an explicit tap on one recording, or an owner-armed automatic
// clear that is OFF BY DEFAULT, scoped to one recorder, and never retroactive.
//
// THIS FILE DOES NOT COMPUTE SAFETY. It READS the Step 5 predicate
// (`PocketRecordingPresence.isDurableElsewhere`, resolved once by `PocketShelfReadModel`) and
// hands it to `PocketDeleteConsent`'s failable factories, which are what refuse. Two answers to
// "is this safe" is how a recording gets lost, and the ruling names that failure explicitly.

import Foundation

// MARK: - Reading what the recorder answered

/// WHAT A RECORDER SAID WHEN IT WAS ASKED TO REMOVE A RECORDING.
///
/// THREE ANSWERS, NEVER TWO. `MCU&D&ERR` is a REFUSAL — measured on Nick's own recorder
/// (`PKT01_BLUE_26079bc5`, fw 1.6, 2026-08-16) against a file that cannot exist. A firmware
/// that discriminates is the whole reason "prove we hold it" is implementable: a device that
/// silently acknowledged everything could report a removal that never happened.
public enum PocketRemovalAnswer: String, Equatable, Sendable, CaseIterable {
    /// The recorder said yes. It does NOT mean the file is gone — see `PocketRemovalOutcome`.
    case acknowledged
    /// `MCU&D&ERR`. An explicit no.
    case theRecorderRefused
    /// Not an answer about a removal at all.
    case notAboutARemoval
}

/// THE FULL-FRAME MATCHER, AND THE FOUR-WAY COLLISION IT EXISTS FOR.
///
/// `MCU&D` is a strict prefix of THREE other frames this same firmware emits:
///
///     MCU&D            the acknowledgement
///     MCU&D&ERR        the refusal
///     MCU&DIRS&<date>  one day, while listing what the recorder holds
///     MCU&DIRS_SUM&005 the count that terminates that listing
///
/// A matcher written `response.hasPrefix("MCU&D")` answers `acknowledged` to all four, so a
/// recorder merely listing its days reads as five successful deletions, and its refusal reads
/// as a success. Nothing here prefix-matches: the frame is split at the protocol's own
/// delimiter and the opcode FIELD is compared whole, exactly as `PocketRecorderWire` does for
/// the outgoing direction.
public enum PocketRemovalAck {

    /// The argument `MCU&D&…` carries when the recorder is saying no. Measured, not guessed.
    public static let refusalArgument = "ERR"

    public static func read(_ frame: String) -> PocketRemovalAnswer {
        let fields = PocketRecorderWire.fields(of: frame)
        guard fields.count >= 2,
              fields[0] == "MCU",
              fields[1] == PocketRecorderWire.deleteOpcode else { return .notAboutARemoval }
        if fields.count >= 3, fields[2] == refusalArgument { return .theRecorderRefused }
        return .acknowledged
    }
}

// MARK: - What one removal errand established

/// THE OUTCOME OF ASKING A RECORDER TO REMOVE ONE RECORDING.
///
/// `removed` IS THE ONLY CASE THAT CLAIMS THE FILE IS GONE, and it is reached only by reading
/// the recorder's own shelf again on the SAME errand and finding it absent. The acknowledgement
/// is never enough: this opcode has been issued to real hardware exactly once, against a
/// sentinel that cannot exist, and a blind-acknowledging firmware is a documented shape of this
/// protocol family. A person who is told their recording was removed will not go looking for it.
public enum PocketRemovalOutcome: Equatable, Sendable {
    /// The recorder acknowledged AND its re-read shelf no longer lists the recording.
    /// `stillOnTheRecorder` is how many that day still holds — a fact the same re-read produced.
    case removed(stillOnTheRecorder: Int)
    /// `MCU&D&ERR`. The recorder said no, and that is reported as no.
    case theRecorderRefused
    /// It said yes and the recording is still on its shelf. NEVER reported as a removal.
    case stillListedAfterwards
    /// Solleva cannot prove it holds this recording anywhere else, so nothing was composed and
    /// no session was opened. The ruling's floor.
    case notProvenSafe
    /// There was no session to ask on.
    case unavailable(String)
    /// The session opened and the errand failed on the wire.
    case failed(PocketProtocolError)
}

// MARK: - The owner-armed automatic clear

/// A RECORDER'S AUTOMATIC CLEARING, WHICH IS OFF UNTIL ITS OWNER TURNS IT ON.
///
/// `armedAt` IS THE WHOLE TYPE, and it carries two facts in one field because they are the same
/// fact: whether this recorder is armed (`armedAt != nil`) and the instant it was armed, which
/// is what makes "never retroactive" checkable rather than aspirational. A `Bool` could say the
/// first and not the second, and an armed control with no instant would sweep the backlog the
/// moment it was switched on — which is precisely the behaviour the ruling forbids.
///
/// RECORDER-SCOPED, NOT GLOBAL. Stored on `RecordingDeviceRecord`, so arming the recorder you
/// carry daily does not arm the one holding something you have not filed yet.
public struct PocketAutoClear: Equatable, Sendable, Codable {

    /// When the owner armed this recorder. `nil` — the default, and the value every record
    /// already on disk decodes to — means OFF.
    public let armedAt: Date?

    public init(armedAt: Date?) { self.armedAt = armedAt }

    /// THE DEFAULT, NAMED. Off is not the absence of a value; it is a value.
    public static let off = PocketAutoClear(armedAt: nil)

    public var isArmed: Bool { armedAt != nil }

    /// WHY A RECORDING WAS OR WAS NOT CLEARED. Four answers, because a person asking "why is
    /// this still on my recorder" is owed the actual reason and not a silent no.
    public enum Decision: String, Equatable, Sendable, CaseIterable {
        case clears
        /// The owner never armed this recorder. The default state of every recorder.
        case thisRecorderIsNotArmed
        /// The recording synced BEFORE the control was armed. Arming is not retroactive: it
        /// does not reach back over a backlog whose safety nobody re-established at the time.
        case itSyncedBeforeYouArmedThisRecorder
        /// The same bar an explicit tap meets. An armed control is a standing choice, not a
        /// lower one.
        case notProvenSafe
    }

    /// - Parameter syncedAt: when the copy that makes this recording safe elsewhere landed.
    /// - Parameter presence: the Step 5 reading, READ and not recomputed.
    public func decision(syncedAt: Date, presence: PocketRecordingPresence) -> Decision {
        guard let armedAt else { return .thisRecorderIsNotArmed }
        guard syncedAt >= armedAt else { return .itSyncedBeforeYouArmedThisRecorder }
        // THE 2026-08-16 BAR, AND IT IS THIS PATH'S ALONE NOW. Read through the automatic
        // path's own name so a future ruling about the manual affordance cannot move it by
        // touching one shared expression — which is how the manual control came to be withheld
        // on the tier that needed it most.
        guard PocketRemoveFromRecorderPresentation.autoClearMayTake(presence) else {
            return .notProvenSafe
        }
        return .clears
    }
}

extension RecordingDeviceStore {

    /// The owner armed this recorder. One record, never a sweep over all of them — the contrast
    /// with `prefer(_:)`, which is exclusive on purpose and this deliberately is not.
    public func armAutoClear(_ identity: RecordingDeviceIdentity, at instant: Date) throws {
        try mutateRecord(identity) { $0.autoClearArmedAt = instant }
    }

    /// The owner turned it back off. The instant is DISCARDED, so re-arming later cannot
    /// inherit an older arming and reach back over everything that synced in between.
    public func disarmAutoClear(_ identity: RecordingDeviceIdentity) throws {
        try mutateRecord(identity) { $0.autoClearArmedAt = nil }
    }

    public func autoClear(for identity: RecordingDeviceIdentity) throws -> PocketAutoClear {
        guard let record = try records().first(where: { $0.identity == identity }) else {
            return .off
        }
        return PocketAutoClear(armedAt: record.autoClearArmedAt)
    }

    /// FAIL CLOSED. A scope that cannot be resolved, or a store that cannot be read, is OFF —
    /// never armed. The failure mode of guessing wrong in the other direction is a recording
    /// removed from the only device holding it.
    public static func autoClear(for identity: RecordingDeviceIdentity) -> PocketAutoClear {
        guard let store = current() else { return .off }
        return (try? store.autoClear(for: identity)) ?? .off
    }
}

// MARK: - The errand

#if canImport(CoreBluetooth)

/// ASK ONE RECORDER TO REMOVE ONE RECORDING.
///
/// Shaped exactly like `PocketBringOver.run` and `PocketRecorderCheck.run`: the refusal that can
/// be decided without a radio is decided BEFORE the radio, and the rest happens inside one
/// authenticated session.
public enum PocketRemoveFromRecorder {

    /// - Parameter presence: the Step 5 reading this shelf was drawn from. It is a REQUIRED
    ///   argument with no default, because a default here would be a decision about whether a
    ///   recording is safe, made by whoever forgot to pass it.
    /// - Parameter provenance: which of the ruling's two paths authorised this.
    public static func run(
        peripheralIdentifier id: UUID,
        advertisedName: String,
        recording: PocketRecording,
        presence: PocketRecordingPresence,
        provenance: PocketDeleteConsent.Provenance,
        attachment: RecordingDeviceAttachment = RecordingDeviceAttachment()
    ) async -> PocketRemovalOutcome {
        // BEFORE THE RADIO IS TOUCHED, and before a frame is composed. A recording whose safety
        // Solleva cannot demonstrate costs no session, no battery and no command — and the
        // census the promise is asserted over stays empty for it, which is what makes AC1 an
        // assertion about behaviour rather than about a string.
        guard let identity = try? PocketAuthenticatedIdentity(peripheralIdentifier: id.uuidString)
        else { return .unavailable(PocketRecorderCheckPresentation.notThisRecorderLine) }
        let key = PocketRecorderFileKey(identity: identity.recordingDeviceIdentity,
                                        date: recording.date,
                                        timestamp: recording.timestamp)
        guard let consent = consent(for: key, presence: presence, provenance: provenance) else {
            return .notProvenSafe
        }

        let result = await attachment.withAuthenticatedSession(
            peripheralIdentifier: id, advertisedName: advertisedName
        ) { client, _ in
            let outcome = await remove(client: client, recording: recording, consent: consent)
            // HOW FULL THE RECORDER IS, RE-READ ON THE SAME TRIP, AND ONLY WHEN SOMETHING
            // ACTUALLY LEFT.
            //
            // TWO THINGS THIS CLOSES AT ONCE. The page's free-space strip is the number the
            // owner is staring at WHILE trying to reclaim space, and it used to keep saying
            // whatever the last check said — so a successful removal changed the shelf and left
            // the one figure the person is watching frozen and wrong. And the delta across a
            // removal is the measurement the copy discipline in this file is explicitly waiting
            // on: until it is observed, nothing here may say "free up space". Reading it here
            // is the only place it can ever be taken, because it needs a session that has just
            // removed something.
            //
            // IT IS READ AFTER THE OUTCOME IS DECIDED, never before, and only on `.removed`.
            // `APP&SPACE` runs inside `protected(.information)`, which retires the whole
            // session on a timeout — asking first would trade a confirmed removal against a
            // number, which is the ordering mistake `PocketRecorderCheck` already records
            // making once. A reading that does not arrive changes nothing.
            if case .removed = outcome,
               let space = await PocketRecordingDeviceBridge.storageReading(client: client) {
                RecordingDeviceStore.recordObservedFacts(
                    identity: identity.recordingDeviceIdentity,
                    readings: [RecordingDeviceCapabilityKey.freeSpace.rawValue: space])
            }
            return outcome
        }
        switch result {
        case .ran(let outcome): return outcome
        case .unavailable(let attach):
            return .unavailable(
                PocketRecorderCheckPresentation.message(for: .unavailable(attach))
                    ?? PocketRecorderCheckPresentation.notThisRecorderLine)
        }
    }

    /// THE RULING'S TWO PATHS, AND THEY NO LONGER READ THE SAME PREDICATE.
    ///
    /// PATH 1 always returns a consent — Nick, 2026-08-18: *"we cannot hard block them from
    /// deleting."* The shelf's reading still does work here, but a different job: it picks which
    /// of the three frozen consequences the owner is told, through
    /// `PocketDeleteConsequence.ofRemoving`, which reads the presence and recomputes nothing.
    ///
    /// PATH 2 is unchanged and still failable on `isDurableElsewhere`, so an unattended clear
    /// cannot touch a recording whose safety the shelf did not state — including the `unknown` a
    /// place nobody asked about honestly reports.
    static func consent(for key: PocketRecorderFileKey,
                        presence: PocketRecordingPresence,
                        provenance: PocketDeleteConsent.Provenance) -> PocketDeleteConsent? {
        switch provenance {
        case .ownerChose:
            return PocketDeleteConsent.ownerChoseThisRecording(
                key, statingThat: .ofRemoving(presence))
        case .ownerArmedThisRecorder:
            return PocketDeleteConsent.ownerArmedThisRecorder(key, provenSafeBy: presence)
        }
    }

    private static func remove(client: PocketBLEClient,
                               recording: PocketRecording,
                               consent: PocketDeleteConsent) async -> PocketRemovalOutcome {
        do {
            return try await client.removeRecording(recording.request, ownerConsent: consent)
        } catch let error as PocketProtocolError {
            return .failed(error)
        } catch {
            return .failed(.transportFailure)
        }
    }
}

#endif

// MARK: - What a person reads

/// EVERY SENTENCE THIS BEHAVIOUR RENDERS. In the kit like every other device string, because
/// `swift test` cannot compile `App/` and a line invented in a SwiftUI body is a second,
/// unasserted implementation of the app's voice.
///
/// COPY DISCIPLINE, AND WHY IT IS A RULE RATHER THAN A PREFERENCE. Until the `APP&SPACE` delta
/// is actually OBSERVED across a removal, nothing here says "free up space". `APP&SPACE` is
/// readable — `MCU&SPA&058767&058992` on Nick's recorder, 2026-08-16 — but no removal has ever
/// been issued to a real file, so the delta is a number nobody has measured. The surface says
/// "remove it from the recorder", which is the thing that actually happens.
public enum PocketRemoveFromRecorderPresentation {

    /// The affordance. It EXISTS ONLY for a recording whose safety the shelf can state — see
    /// `isOffered(for:)`, which is the same predicate the consent factories read.
    public static let action = "Remove it from the recorder"

    /// WHILE IT IS HAPPENING, TO THIS ONE FILE. The page used to caption its spinner with
    /// `action` — a BUTTON's words ("Remove it from the recorder") standing in for a progress
    /// line, which reads as an instruction rather than as a report. It is also what a row shows
    /// while the errand is about that row, so it says "this recording" the way the transfer's
    /// own in-progress line does.
    public static let inProgressLine = "Taking this recording off the recorder…"

    /// THE TWO ANSWERS TO THE CONFIRMATION. They did not exist, which is part of why the
    /// confirmation itself had no call site: a sentence with no buttons is not a dialog.
    /// Named for the act rather than "OK", the same rule the mint consent follows.
    public static let confirmAction = "Take it off the recorder"
    public static let cancelConfirmAction = "Keep it on the recorder"

    /// THE CONFIRMATION, AND IT SAYS THE ONE THING TRUE OF EVERY REMOVAL.
    ///
    /// WHAT IT USED TO SAY, AND WHY THAT BECAME A LIE. It appended `keptLine(for:)` — *"Solleva
    /// has confirmed a copy on your computer."* — which was safe to say only while the durability
    /// guard made a removal impossible without one. Nick's 2026-08-18 ruling removed that guard
    /// from the manual path, so the same sentence would now be printed over a recording nothing
    /// else holds. A confirmation dialog that asserts a copy that does not exist is worse than no
    /// dialog: it is the app talking the owner into the deletion.
    ///
    /// WHERE THE CUSTODY STATEMENT WENT. To `PocketDeleteConsequence`, one band above, on the
    /// page — where it is resolved from THIS recording's own reading rather than from the tier.
    /// This band states irreversibility, which is true of all three consequences, and states it
    /// once. `keptLine(for:)` is deleted rather than kept-and-unused: a sentence nothing renders
    /// is a sentence somebody re-renders.
    ///
    /// The parameter stays so the surface that calls this does not have to change while the
    /// two tracks that own that file are in flight; nothing about the brain belongs in this
    /// sentence any more, and a brain-shaped custody claim is exactly what was removed.
    public static func confirmation(for brain: BrainChoice) -> String { confirmationLine }

    /// The confirmation's words, as a constant, so the population below and every assertion
    /// about it read the same string the alert reads.
    public static let confirmationLine =
        "This takes the recording off the recorder, and Solleva can't get it back."

    /// THE TAP THAT COULD NOT BE CARRIED OUT, AND IT SAYS SO.
    ///
    /// The row and the safety reading it was drawn from are published separately, and a check
    /// that reaches the recorder and then a check that FAILS leaves the page drawing rows from
    /// the old panel with no readings behind them. Every tap on the destructive button then
    /// returned early and set no message at all — a control that looks live, does nothing, and
    /// explains nothing. This file's neighbour states the standard: *"a bring-over that
    /// silently did nothing is indistinguishable from one that worked."*
    public static let cannotActOnThisNowLine =
        "Solleva can't act on that recording right now. Check the recorder again first."

    /// THE REFUSAL — AND AFTER 2026-08-18 IT BELONGS TO THE AUTOMATIC PATH ALONE.
    ///
    /// A manual removal can no longer produce it: `PocketDeleteConsent.ownerChoseThisRecording`
    /// refuses nothing. It is what the ARMED clear says when it declines to take a recording
    /// nobody has proven is anywhere else, which is the bar the ruling deliberately left in place
    /// for a delete no person is watching.
    public static let notProvenSafeLine =
        "Solleva hasn't confirmed a copy of this anywhere else yet, so it won't clear it off the "
        + "recorder on its own."

    /// The recorder said no. Its own answer, not an inference from silence.
    public static let recorderRefusedLine =
        "The recorder wouldn't remove that recording."

    /// It said yes and the recording is still there. The one outcome a blind acknowledgement
    /// would otherwise render as success.
    public static let stillListedLine =
        "The recorder said yes, but that recording is still on it."

    public static let removedLine = "Removed from the recorder."

    /// A phone-only brain has no second place to put a copy, so nothing can ever satisfy the
    /// AUTOMATIC predicate. It no longer withholds the manual control — Nick, 2026-08-18 — and
    /// this sentence is what the armed clear says about that tier, never what a tap is told.
    public static let nowhereElseLine =
        "There's nowhere other than this iPhone for a copy to go yet."

    // MARK: The owner-armed control

    public static let autoClearTitle = "Clear this recorder as recordings sync"

    /// WHAT ARMING IT SAYS, IN THE SENTENCE ITSELF — what "synced" is trusted to mean, and
    /// which destination satisfied it. `nil` for a brain with no second place: the control is
    /// not offered rather than offered-and-inert.
    public static func autoClearExplanation(for brain: BrainChoice) -> String? {
        switch brain {
        case .justMyPhone:
            return nil
        case .myComputer:
            return "Solleva will take a recording off this recorder once it has confirmed a "
                + "copy on your computer. Synced means confirmed, not started."
        case .foundryCloud:
            return "Solleva will take a recording off this recorder once it has confirmed a "
                + "copy in your Vault. Synced means confirmed, not started."
        }
    }

    /// What a person is told when the brain they are on cannot satisfy the predicate.
    public static let autoClearUnavailableLine =
        "Automatic clearing needs somewhere other than this iPhone to put a copy first."

    /// Turning it on does not reach back. Said out loud, because a person arming a control over
    /// a full recorder will reasonably expect the backlog to go.
    public static let autoClearNotRetroactiveLine =
        "This applies to recordings that sync from now on. Anything already here stays until "
        + "you choose it."

    /// WHETHER THE AFFORDANCE EXISTS AT ALL — AND IT NOW EXISTS WHENEVER THE RECORDER HAS THE
    /// RECORDING.
    ///
    /// WHAT THIS USED TO BE, AND WHY IT WAS THE DEFECT RATHER THAN THE GUARD. It was
    /// `presence.isDurableElsewhere`, matching the 2026-08-16 ruling *"the affordance does not
    /// exist for a recording we have not brought over."* On Nick's own recorder that predicate is
    /// false for all nineteen recordings and, on the phone-only tier, false FOREVER — so the one
    /// control that reclaims space was not drawn on the one tier most likely to need it. Nick,
    /// 2026-08-18: *"we cannot hard block them from deleting."*
    ///
    /// SO THE AFFORDANCE IS BACK AND THE PROOF MOVED, IT DID NOT VANISH. What the shelf can prove
    /// now decides the SENTENCE (`PocketDeleteConsequence.ofRemoving`), not the button. A row that
    /// offers this and a consent that refuses it still cannot disagree, because PATH 1's factory
    /// refuses nothing.
    ///
    /// IT IS STILL A PREDICATE AND NOT `true`. A recording the recorder is not holding cannot be
    /// taken off it, and a shelf that has not answered has not said it is there.
    public static func isOffered(for presence: PocketRecordingPresence) -> Bool {
        presence.onRecorder.answer == .yes
    }

    /// WHETHER THE UNATTENDED PATH MAY TOUCH THIS RECORDING. The 2026-08-16 predicate, kept
    /// under its own name because it still governs exactly one thing: the armed clear.
    ///
    /// It is a SEPARATE function from `isOffered(for:)` on purpose. They used to be one
    /// expression, and one ruling about the manual path silently moved the automatic one with it.
    /// Two names is what makes a future relaxation of one of them visible.
    public static func autoClearMayTake(_ presence: PocketRecordingPresence) -> Bool {
        presence.isDurableElsewhere
    }

    public static func message(for outcome: PocketRemovalOutcome) -> String {
        switch outcome {
        case .removed:              return removedLine
        case .theRecorderRefused:   return recorderRefusedLine
        case .stillListedAfterwards: return stillListedLine
        case .notProvenSafe:        return notProvenSafeLine
        case .unavailable(let line): return line
        case .failed:               return PocketRecorderCheckPresentation.inventoryFailedLine
        }
    }

    /// THE POPULATION. Every line this behaviour can render, so a claim about its copy is held
    /// over the whole set rather than over whichever string a test author remembered.
    public static var everyLine: [String] {
        var lines = [action, inProgressLine, confirmAction, cancelConfirmAction, notProvenSafeLine,
                     recorderRefusedLine, stillListedLine, cannotActOnThisNowLine,
                     removedLine, nowhereElseLine, autoClearTitle, confirmationLine,
                     autoClearUnavailableLine, autoClearNotRetroactiveLine]
        // THE THREE CONSEQUENCES ARE PART OF THIS SURFACE'S VOICE. They are what a person reads
        // immediately before the one gesture here that cannot be undone, so a copy claim held
        // over "every line this behaviour renders" that omitted them would be a claim over the
        // reassuring half.
        lines += PocketDeleteConsequence.everyLine
        for brain in BrainChoice.allCases {
            lines.append(confirmation(for: brain))
            if let explanation = autoClearExplanation(for: brain) { lines.append(explanation) }
        }
        return lines
    }
}
