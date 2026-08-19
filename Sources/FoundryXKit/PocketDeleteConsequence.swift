// PocketDeleteConsequence.swift — WHAT THE OWNER LOSES, SAID BEFORE THE RECORDING GOES.
//
// NICK'S RULING, 2026-08-18, VERBATIM:
//
//   "We need to allow people to be able to delete a recording off of the pocket … we cannot hard
//    block them from deleting. But we can definitely still suggest to them without that
//    suggestion getting in the way of their actual work that a Vault would be more secure."
//
// THE SHIPPED BUILD WAS THE FAILURE HE DESCRIBES, and it was measured rather than guessed. On the
// phone-only tier `PocketRecordingPresence.isDurableElsewhere` is PERMANENTLY false — three
// independent legs make it so (`BrainChoice.uploadAckProvesAnotherPlace` is false for
// `.justMyPhone`; `PocketCaptureDurability.init` withdraws the stage floor on that tier;
// `LocalBackend` never writes the `.lore-confirmed` ceiling) — and BOTH delete factories were
// failable on it. So on the one tier where the recorder is most likely to fill up, a manual
// delete was refused ALWAYS, and the control that would have asked for one was not even drawn.
//
// A RECORDER THAT IS 99% FULL AND CANNOT BE EMPTIED IS A RECORDER THAT CANNOT RECORD. Refusing to
// delete is not the safe side of that trade; it is a different loss, and it is the one the owner
// did not choose.
//
// THE NEW RULE: A MANUAL DELETE IS ALWAYS COMPOSABLE. WHAT VARIES IS THE SENTENCE STATED FIRST.
// This file is that sentence, as a value, so `swift test` can hold every word of it — and so the
// factory that composes a removal cannot be called by somebody who has not decided what to tell
// the owner.
//
// WHAT THIS TYPE IS NOT. It is NOT a permission. Nothing reads it to decide whether a removal may
// happen; the ONLY thing it decides is what is said. That separation is the whole point of the
// ruling: the suggestion must not get in the way of the work.
//
// AND IT HAS NO EMPTY CASE. No `.unspecified`, no `.none`, no `ExpressibleByNilLiteral`, no
// default-constructible arm — so a call site that has not decided what to say has NOTHING to
// pass and does not compile. That is the detector, and it is a compile-time one, because a
// runtime enumeration of composed removals cannot observe a call the source never made.

import Foundation

/// WHAT IS ABOUT TO BE LOST, IN THE OWNER'S TERMS. Exactly three, and they are frozen.
///
/// The three are the three states of *"what is the best custody this recording has today"*, which
/// is the question Nick's ruling reframed the predicate around — not *"is the phone durable"*.
public enum PocketDeleteConsequence: String, Sendable, Equatable, CaseIterable {

    /// Something that is not the recorder has a CONFIRMED copy. Nothing is lost by removing it.
    case aCopyIsAlreadySomewhereElse

    /// This phone is holding the bytes and nothing else is. One copy survives, and it is on a
    /// handset that can be dropped in a river.
    case thisPhoneWillHoldTheOnlyCopy

    /// Solleva holds nothing. The recorder is the only place this recording exists, and taking
    /// it off ends it. This is the sentence that must never be softened.
    case nothingElseHoldsIt

    /// THE SENTENCE. Frozen here and never derived from the case name, so a test that compares
    /// against an independently written list is comparing against something.
    public var sentence: String {
        switch self {
        case .aCopyIsAlreadySomewhereElse:
            return "Solleva has confirmed a copy of this recording somewhere other than the "
                + "recorder."
        case .thisPhoneWillHoldTheOnlyCopy:
            return "This leaves one copy, on this iPhone."
        case .nothingElseHoldsIt:
            return "Solleva doesn't hold a copy of this recording. Taking it off the recorder "
                + "ends it."
        }
    }

    /// THE VAULT, OFFERED WHERE IT IS TRUE AND NOWHERE ELSE.
    ///
    /// Nick: *"we can definitely still suggest to them WITHOUT that suggestion getting in the way
    /// of their actual work."* So it is a sentence beside the consequence, at the moment the
    /// consequence is true — never a gate, never a disabled button, and never on a screen where
    /// the recording is already safe. `nil` is the answer for the case where a copy already
    /// exists: a Vault upsell there would be an advertisement rather than a fact.
    public var vaultSuggestion: String? {
        switch self {
        case .aCopyIsAlreadySomewhereElse:
            return nil
        case .thisPhoneWillHoldTheOnlyCopy, .nothingElseHoldsIt:
            return "A Vault would keep a copy of this for you."
        }
    }

    /// WHICH OF THE THREE THIS RECORDING IS IN, READ OFF THE SHELF'S OWN READING.
    ///
    /// It reads `PocketRecordingPresence` and recomputes nothing: the readings were resolved once
    /// by `PocketShelfReadModel.presences`, and a second computation of "where is this" is how a
    /// screen comes to contradict itself.
    ///
    /// `unknown` — a place nobody asked about — is NOT treated as a yes on either arm. So an
    /// unresolved shelf states the STRONGER consequence, which over-warns rather than
    /// under-warns. That direction is deliberate: this value cannot block anything, so the only
    /// cost of being wrong toward caution is a sentence, and the only cost of being wrong the
    /// other way is a recording.
    public static func ofRemoving(_ presence: PocketRecordingPresence) -> PocketDeleteConsequence {
        if presence.safeElsewhere.answer == .yes { return .aCopyIsAlreadySomewhereElse }
        if presence.onThisPhone.answer == .yes { return .thisPhoneWillHoldTheOnlyCopy }
        return .nothingElseHoldsIt
    }

    /// Every line this type can render, so a claim about its copy is held over the POPULATION
    /// rather than over whichever case a test author remembered.
    public static var everyLine: [String] {
        allCases.map(\.sentence) + allCases.compactMap(\.vaultSuggestion)
    }
}
