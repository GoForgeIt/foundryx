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
        return isMeaningful(meaningfulWordCount: meaningfulWordCount(in: raw),
                            durationSeconds: durationSeconds)
    }

    /// The SAME verdict, taken over an already-computed distinct-meaningful-word count.
    /// This is the byte-independent seam (track `rebuild_is_byte_independent_and_disk_free`):
    /// the count is derived ONCE off the main actor when a capture's sidecar is warmed, and
    /// the list rebuild then re-decides membership from an `Int` instead of re-scanning every
    /// conversation's whole transcript on every rebuild.
    public static func isMeaningful(meaningfulWordCount count: Int,
                                    durationSeconds: TimeInterval?) -> Bool {
        if count == 0 { return false }                      // pure filler/acks → always drop
        if count >= minMeaningfulWords { return true }      // real content → keep
        // Exactly one meaningful word (borderline): drop only when the clip is short.
        if let d = durationSeconds, d < shortConversationCeiling { return false }
        return true                                            // long / unknown-length → keep
    }

    /// How many DISTINCT content words `text` holds, stopping as soon as `cap` distinct ones
    /// are seen. `isMeaningful` only ever needs to distinguish 0 / 1 / "≥ minMeaningfulWords",
    /// so the cap turns an unconditional full-transcript scan into an early exit (a 300KB
    /// meeting transcript settles in its first few words).
    public static func meaningfulWordCount(in text: String,
                                           cappedAt cap: Int = minMeaningfulWords) -> Int {
        guard cap > 0 else { return 0 }
        var seen = Set<String>()
        var token = ""
        // Streamed token-by-token rather than `text.lowercased().split(…)`: the whole-string
        // lowercase copy + split array is what made this O(total transcript bytes). Here the
        // work stops at the cap, and only the small token is ever lowercased.
        func consider() -> Bool {
            defer { token.removeAll(keepingCapacity: true) }
            guard token.count >= minWordLength else { return false }
            let w = token.lowercased()
            guard !fillerWords.contains(w) else { return false }
            seen.insert(w)
            return seen.count >= cap
        }
        for ch in text {
            if ch.isLetter || ch.isNumber { token.append(ch) }
            else if !token.isEmpty, consider() { return seen.count }
        }
        if !token.isEmpty { _ = consider() }
        return seen.count
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
