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

/// WHAT IS ABOUT TO BE LOST, IN THE OWNER'S TERMS. Four, and they are frozen.
///
/// The first three are the states of *"what is the best custody this recording has today"*, which
/// is the question Nick's ruling reframed the predicate around — not *"is the phone durable"*.
///
/// THE FOURTH EXISTS BECAUSE THREE WERE MEASURED TO LIE, and the measurement was cross-vendor
/// adversarial review on 2026-08-19, not an opinion. `PocketRecordingPresence` carries THREE
/// answers per place — `yes`, `no` and `unknown` — so `(safeElsewhere, onThisPhone)` has NINE
/// states, and the first draft of this type mapped all nine onto three sentences. Four of the
/// nine came out as categorical claims about places nobody had asked:
///
///   (unknown, yes)     → "This leaves one copy, on this iPhone."       ← an unasked elsewhere
///   (unknown, no)      → "Solleva doesn't hold a copy…"                ← an unasked elsewhere
///   (unknown, unknown) → "Solleva doesn't hold a copy…"                ← neither was asked
///   (no,      unknown) → "Solleva doesn't hold a copy…"                ← an unasked phone
///
/// "One copy" and "doesn't hold a copy" are COUNTS. A count over a place nobody queried is not a
/// cautious answer, it is a wrong one — and this whole file exists because the app told an owner
/// something about custody that was not true. The rule is now: A CATEGORICAL CLAIM ONLY WHERE
/// BOTH PLACES ANSWERED. Everything else gets the fourth case, which says so and warns hardest.
///
/// IT IS NOT AN EMPTY CASE AND IT IS NOT A FALLBACK. `.nobodyHasCheckedWhereElseItIs` is a
/// SUBSTANTIVE state with its own sentence — the compile-time detector Nick's ruling turns on is
/// that this type has no `.unspecified`, no `.none`, no `ExpressibleByNilLiteral` and no
/// default-constructible arm, and a fourth named state breaks none of those.
///
/// THIS REFUTES `tracks/20260817T1730_…` AMENDMENT 1's AC20, which freezes the set at THREE.
/// That AC was written on 2026-08-18, before the nine states were enumerated. The frozen set is
/// FOUR, the reason is above, and the AC is the thing that changes — not the code, quietly.
public enum PocketDeleteConsequence: String, Sendable, Equatable, CaseIterable {

    /// Something that is not the recorder has a CONFIRMED copy. Nothing is lost by removing it.
    case aCopyIsAlreadySomewhereElse

    /// This phone is holding the bytes and nothing else is. One copy survives, and it is on a
    /// handset that can be dropped in a river. BOTH places answered.
    case thisPhoneWillHoldTheOnlyCopy

    /// Solleva holds nothing. The recorder is the only place this recording exists, and taking
    /// it off ends it. This is the sentence that must never be softened, and it is reachable
    /// ONLY when both places were asked and both said no.
    case nothingElseHoldsIt

    /// A PLACE WAS NEVER ASKED, so no count is available. The honest sentence, and the hardest
    /// warning — because "we do not know" is not "we know it is fine".
    case nobodyHasCheckedWhereElseItIs

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
        case .nobodyHasCheckedWhereElseItIs:
            return "Solleva hasn't checked whether anything else has a copy of this. Taking it "
                + "off the recorder could be the end of it."
        }
    }

    /// THE VAULT, OFFERED WHERE IT IS TRUE AND NOWHERE ELSE.
    ///
    /// Nick: *"we can definitely still suggest to them WITHOUT that suggestion getting in the way
    /// of their actual work."* So it is a sentence beside the consequence, at the moment the
    /// consequence is true — never a gate, never a disabled button, and never on a screen where
    /// the recording is already safe. `nil` is the answer for the case where a copy already
    /// exists: a Vault upsell there would be an advertisement rather than a fact.
    ///
    /// A REVIEW ASKED FOR `.nobodyHasCheckedWhereElseItIs` TO BE DROPPED FROM THIS LIST, AND IT
    /// WAS TRIED AND REVERTED. The argument (cross-vendor, 2026-08-20) was that the suggestion's
    /// premise is "this will be the only copy", which under an unasked `safeElsewhere` has not
    /// been established — so the sentence would rest on a fact the app has, one line above, just
    /// said it does not have.
    ///
    /// IT DOES NOT REST ON THAT FACT. Read the sentence: *"A Vault would keep a copy of this for
    /// you."* It is a statement about what a Vault DOES, not a claim about where this recording
    /// currently is — and it is true in all four states. The reason `.aCopyIsAlreadySomewhereElse`
    /// gets `nil` is RELEVANCE, not falsity: an upsell beside a recording that is already safe is
    /// an advertisement. Beside a recording whose custody nobody has checked, the same sentence
    /// is both true and useful, and Nick's ruling is explicit that the suggestion should be
    /// there: *"we can definitely still suggest to them."*
    ///
    /// The change was made, and two scenarios that encode the shipped rule went RED and refused
    /// it — `A recording Solleva has never checked on is mine to delete too` and `What I am told
    /// I am losing is different in each of the three cases`. Recorded here rather than left as a
    /// silent revert, so the next reviewer to notice the asymmetry finds the reasoning instead
    /// of re-litigating it.
    public var vaultSuggestion: String? {
        switch self {
        case .aCopyIsAlreadySomewhereElse:
            return nil
        case .thisPhoneWillHoldTheOnlyCopy, .nothingElseHoldsIt,
             .nobodyHasCheckedWhereElseItIs:
            return "A Vault would keep a copy of this for you."
        }
    }

    /// WHICH OF THE THREE THIS RECORDING IS IN, READ OFF THE SHELF'S OWN READING.
    ///
    /// It reads `PocketRecordingPresence` and recomputes nothing: the readings were resolved once
    /// by `PocketShelfReadModel.presences`, and a second computation of "where is this" is how a
    /// screen comes to contradict itself.
    ///
    /// A CATEGORICAL CLAIM ONLY WHERE BOTH PLACES ANSWERED. That single rule is what makes this
    /// function total over the nine states without any of them producing a count nobody measured.
    ///
    /// `unknown` is never a yes — but it is never a NO either, and that second half is what the
    /// first draft of this function got wrong. Falling through an unasked place into
    /// `.nothingElseHoldsIt` looked like the cautious direction and reads, to an owner, as a
    /// statement of fact: *"Solleva doesn't hold a copy of this recording."* Over-warning is only
    /// safe when the warning is TRUE.
    public static func ofRemoving(_ presence: PocketRecordingPresence) -> PocketDeleteConsequence {
        // A CONFIRMED COPY ELSEWHERE SETTLES IT ON ITS OWN. Whatever the phone answers, and
        // whether or not it was asked, something that is not the recorder is holding this.
        if presence.safeElsewhere.answer == .yes { return .aCopyIsAlreadySomewhereElse }
        // EVERY OTHER CATEGORICAL SENTENCE NEEDS BOTH ANSWERS.
        guard presence.safeElsewhere.answer == .no,
              presence.onThisPhone.answer != .unknown else {
            return .nobodyHasCheckedWhereElseItIs
        }
        return presence.onThisPhone.answer == .yes
            ? .thisPhoneWillHoldTheOnlyCopy
            : .nothingElseHoldsIt
    }

    /// Every line this type can render, so a claim about its copy is held over the POPULATION
    /// rather than over whichever case a test author remembered.
    public static var everyLine: [String] {
        allCases.map(\.sentence) + allCases.compactMap(\.vaultSuggestion)
    }
}
