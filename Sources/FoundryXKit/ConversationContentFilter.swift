// ConversationContentFilter — hides empty / near-silent / filler captures from the
// conversation list (track 20260628T1654). Near-silent ambient audio transcribes to
// Whisper/STT silence artifacts ("Thank you", "Okay", ".", "but") — useless cards that
// pollute the timeline. We port Omi's empty-conversation gates
// (`foundryx-hearth/research/20260628_omi_segmentation_learnings.md` §3):
//
//   • zero meaningful content                → always drop
//   • sparse content AND a SHORT (<120s) clip → drop (Omi's "higher bar" for short)
//   • long / clearly-real content             → keep
//
// Pure + tested; the data is never deleted, just not rendered. All thresholds are
// tunable constants.

import Foundation

public enum ConversationContentFilter {
    /// Whisper/STT silence artifacts + ultra-generic acknowledgments a near-silent
    /// capture transcribes to. Compared after lowercasing + punctuation stripping.
    /// Tunable. (Omi's discard-prompt lists "okay/hmm/yeah sure/sorry/hello" etc.)
    public static let fillerWords: Set<String> = [
        "thank", "thanks", "you", "thankyou", "okay", "ok", "yeah", "yep", "yes",
        "no", "nope", "so", "but", "and", "the", "uh", "um", "umm", "hmm", "mhm",
        "bye", "hi", "hey", "hello", "sorry", "please", "watching", "for", "to",
    ]
    /// Distinct MEANINGFUL words a transcript needs to count as a real conversation.
    /// 2 keeps genuine brief exchanges ("grab milk") while dropping "Thank you". Tunable.
    public static let minMeaningfulWords = 2
    /// Conversations shorter than this get Omi's "higher bar": sparse content is dropped.
    /// Longer ones are kept even if sparse (likely real speech under-captured). Tunable.
    public static let shortConversationCeiling: TimeInterval = 120
    /// Minimum word length to be considered a content word (drops "a", "I", "is"…).
    public static let minWordLength = 3

    /// Whether a conversation with this transcript + duration is worth showing.
    /// `durationSeconds == nil` (unknown / not-yet-finalized) is treated leniently — a
    /// known-short clip is required before the sparse-content bar applies.
    public static func isMeaningful(transcript: String?, durationSeconds: TimeInterval? = nil) -> Bool {
        guard let raw = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false   // empty / whitespace → never show
        }
        let words = meaningfulWords(in: raw)
        if words.isEmpty { return false }                      // pure filler/acks → always drop
        if words.count >= minMeaningfulWords { return true }   // real content → keep
        // Exactly one meaningful word (borderline): drop only when the clip is short.
        if let d = durationSeconds, d < shortConversationCeiling { return false }
        return true                                            // long / unknown-length → keep
    }

    /// The DISTINCT content words in `text`: lowercased, punctuation-stripped, dropping
    /// fillers + words shorter than `minWordLength`. De-duped so "thank you thank you"
    /// can't inflate the count.
    public static func meaningfulWords(in text: String) -> Set<String> {
        var out = Set<String>()
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let w = String(token)
            guard w.count >= minWordLength, !fillerWords.contains(w) else { continue }
            out.insert(w)
        }
        return out
    }
}
