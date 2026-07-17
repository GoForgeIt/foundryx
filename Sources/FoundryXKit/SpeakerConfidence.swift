// SpeakerConfidence — the single source of truth for how the phone talks about a
// TENTATIVE (inferred) speaker match.
//
// Why this exists: a slot's `inferScore` is a raw WeSpeaker COSINE similarity, not a
// calibrated probability. On this recorder's calibration corpus, two DIFFERENT voices
// scored 0.899–0.968 raw — so rendering "91%" as a confidence was actively dishonest
// and drove bad confirm decisions. The Mac side is moving to margin-calibrated matching
// (the real gate); the phone must (a) NEVER render a cosine as a percentage, and
// (b) only surface an inferred NAME when the raw evidence is at least strong.
//
// This enum owns both the numeric tiering and every user-facing string, so there is
// exactly ONE place a percentage could ever have crept in — and it never does.
public enum SpeakerConfidence {

    /// Below this raw cosine an inferred NAME is not shown (the slot renders as
    /// "Speaker N"). This is deliberately only a stale-data backstop: on the calibration
    /// corpus false matches ran 0.899–0.968 raw, so 0.85 does NOT actually separate
    /// same-voice from different-voice. The Mac's margin rule is the real gate; this
    /// floor exists so pre-calibration (stale) inferences on the phone can't leak a
    /// low-cosine name into any rendering.
    public static let strongFloor: Double = 0.85

    /// How much to trust an inferred match's raw score. `.weak` never renders the name.
    public enum Tier: Sendable, Equatable {
        case strong
        case weak
    }

    /// Map a raw inferScore to a tier. `nil` (no score) is `.weak` — an inference with
    /// no evidence is treated as unproven, so it never shows a name.
    public static func tier(for score: Double?) -> Tier {
        guard let score, score >= strongFloor else { return .weak }
        return .strong
    }

    // MARK: - Copy (single source of truth — NO percentages anywhere)

    /// The inline hint shown beside a STRONG inferred name in the transcript
    /// (replaces the old "tentative · 91%"). Just an honest, calibration-free word.
    public static let inlineStrongHint = "suggested"

    /// The tag-sheet caption for a STRONG inferred match — offers the name to confirm
    /// without ever claiming a numeric confidence.
    public static func strongSheetCopy(name: String) -> String {
        "Might be \(name) — confirm to teach recognition."
    }

    /// The tag-sheet caption for a WEAK inferred match or an anonymous slot — the phone
    /// won't name the voice, so it asks the user to tag it.
    public static let weakSheetCopy = "Unknown speaker — tag a name to teach recognition."

    /// The sheet caption for a slot given its inferred name (if any) and its score.
    /// Strong → offers the name; weak/anonymous → the neutral "unknown speaker" copy.
    public static func sheetCopy(name: String?, score: Double?) -> String {
        if let name, !name.isEmpty, tier(for: score) == .strong {
            return strongSheetCopy(name: name)
        }
        return weakSheetCopy
    }
}
