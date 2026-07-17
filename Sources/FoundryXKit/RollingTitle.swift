// RollingTitle — the live provisional title derives from the WHOLE conversation to
// the current point, not the last few seconds (track 20260717T1015,
// features/recording-instrument.feature "the name reflects the whole conversation").
//
// Why this exists: the live transcribers bound their display `finalizedText` to a
// rolling 80-word tail (LiveTranscriptBuffer — the build-89/90 stack-overflow fix),
// and the old title was the first 6 words of that tail. Past ~80 words that is a
// sliding window head: what was said ~80 words ago, rewriting itself as the window
// slides. The fix is a SEPARATE, bounded whole-conversation context the transcribers
// maintain for titling only (never word-by-word rendered), a cheap whole-text
// salience heuristic between on-device model refreshes, and an arbiter that keeps a
// settled title from jittering. All pure + tested; CaptureManager owns the cadence.
// The post-recording pipeline (Kiln / LocalBackend) remains authoritative.

import Foundation

/// A bounded whole-conversation text accumulator: the conversation's HEAD (frozen
/// once full) plus a rolling TAIL. O(1) memory in session length, yet the head —
/// which names most conversations — always survives. Titling-only: this string is
/// summarized/scanned, never rendered word-by-word (no render-stack re-risk).
public struct RollingTitleContext: Sendable, Equatable {
    /// Characters kept from the conversation's head (frozen once reached).
    public static let headBudget = 2_400
    /// Characters kept in the rolling tail once the head is full.
    public static let tailBudget = 2_400

    public private(set) var head = ""
    public private(set) var tail = ""

    public init() {}

    /// The whole-conversation context: head + newest tail. When truncation has
    /// happened the middle is simply absent — fine for salience and for a titling
    /// prompt (the head and the recent turns carry the name).
    public var text: String {
        if tail.isEmpty { return head }
        if head.isEmpty { return tail }
        return head + " " + tail
    }

    /// Append one FINALIZED piece (SpeechAnalyzer semantics: finals arrive as
    /// incremental sentences).
    public mutating func ingest(final piece: String) {
        let p = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        if head.count < Self.headBudget {
            head = head.isEmpty ? p : head + " " + p
        } else {
            tail = tail.isEmpty ? p : tail + " " + p
            if tail.count > Self.tailBudget {
                tail = Self.wordSuffix(tail, maxChars: Self.tailBudget)
            }
        }
    }

    /// Replace with a full re-recognized text (SFSpeech semantics: each final is the
    /// WHOLE utterance revised).
    public mutating func replaceAll(_ full: String) {
        let t = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= Self.headBudget + Self.tailBudget {
            head = t
            tail = ""
        } else {
            head = Self.wordPrefix(t, maxChars: Self.headBudget)
            tail = Self.wordSuffix(t, maxChars: Self.tailBudget)
        }
    }

    /// The longest whole-word prefix within `maxChars`.
    static func wordPrefix(_ s: String, maxChars: Int) -> String {
        guard s.count > maxChars else { return s }
        let cut = s.index(s.startIndex, offsetBy: maxChars)
        if let space = s[..<cut].lastIndex(of: " ") { return String(s[..<space]) }
        return String(s[..<cut])
    }

    /// The longest whole-word suffix within `maxChars`.
    static func wordSuffix(_ s: String, maxChars: Int) -> String {
        guard s.count > maxChars else { return s }
        let cut = s.index(s.endIndex, offsetBy: -maxChars)
        if let space = s[cut...].firstIndex(of: " ") {
            return String(s[s.index(after: space)...])
        }
        return String(s[cut...])
    }
}

/// The cheap between-model-refreshes heuristic: a name derived from ALL of the
/// conversation so far. A young conversation is named by its first substantive
/// words (fillers skipped); once there is enough text, the most salient terms
/// across the WHOLE context (stopword-filtered frequency, ordered by first
/// appearance) name it — so where the conversation STARTED keeps its place in the
/// name even as the transcript grows.
public enum WholeConversationTitle {
    /// Words required before any name is offered (parity with ProvisionalLiveTitle).
    public static let minimumWords = 8
    /// Words required before whole-text salience takes over from the opening words.
    public static let salienceMinimumWords = 24
    /// Words kept in an opening-words title.
    public static let openingWords = 6
    /// Salient terms in a salience title.
    public static let salientTerms = 4

    public static func heuristic(from context: String) -> String? {
        let words = context.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        let substantiveCount = words.lazy.filter { !Self.isStop(Self.normalize($0)) }.count
        guard words.count >= minimumWords, substantiveCount >= 2 else { return nil }
        if words.count >= salienceMinimumWords, let salient = salienceTitle(words) {
            return salient
        }
        return openingTitle(words)
    }

    /// The first substantive utterance: skip leading filler/function words, keep the
    /// next few words.
    static func openingTitle(_ words: [String]) -> String? {
        let opening = Array(words.drop(while: { isStop(normalize($0)) }))
        guard opening.count >= 2 else { return nil }
        let kept = opening.prefix(openingWords)
        let title = kept.joined(separator: " ")
        return opening.count > openingWords ? title + "…" : title
    }

    /// Top salient terms across the WHOLE context: stopword/filler-filtered term
    /// frequency, the winners re-ordered by first appearance so the name reads in
    /// conversation order ("Kitchen Budget Contractor Permits").
    static func salienceTitle(_ words: [String]) -> String? {
        var counts: [String: Int] = [:]
        var firstAt: [String: Int] = [:]
        var display: [String: String] = [:]
        for (i, raw) in words.enumerated() {
            let norm = normalize(raw)
            guard norm.count >= 3, !isStop(norm),
                  norm.rangeOfCharacter(from: .letters) != nil else { continue }
            counts[norm, default: 0] += 1
            if firstAt[norm] == nil {
                firstAt[norm] = i
                display[norm] = displayForm(raw)
            }
        }
        guard counts.count >= 3 else { return nil }
        // Terms that RECUR across the conversation name it better than one-off
        // words; fall back to all terms while the conversation is still young.
        let repeated = counts.filter { $0.value >= 2 }
        let pool = repeated.count >= 3 ? repeated : counts
        // Highest count wins; earlier first-appearance breaks ties (stability).
        let winners = pool.sorted {
            $0.value != $1.value ? $0.value > $1.value
                                 : (firstAt[$0.key] ?? 0) < (firstAt[$1.key] ?? 0)
        }.prefix(salientTerms).map(\.key)
        let ordered = winners.sorted { (firstAt[$0] ?? 0) < (firstAt[$1] ?? 0) }
        return ordered.compactMap { display[$0] }.joined(separator: " ")
    }

    /// Lowercased, punctuation-stripped comparison form.
    static func normalize(_ word: String) -> String {
        String(word.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }

    static func isStop(_ norm: String) -> Bool {
        norm.isEmpty || stopwords.contains(norm) || fillers.contains(norm)
    }

    /// The display form of a salient term: punctuation stripped; an all-lowercase
    /// token gets a leading capital, anything already cased ("FoundryX", "June")
    /// keeps its casing.
    static func displayForm(_ raw: String) -> String {
        let stripped = String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        guard !stripped.isEmpty else { return stripped }
        if stripped == stripped.lowercased() {
            return stripped.prefix(1).uppercased() + stripped.dropFirst()
        }
        return stripped
    }

    /// Conversational fillers — never part of a name, skipped as an opening.
    static let fillers: Set<String> = [
        "um", "uh", "erm", "hmm", "huh", "like", "okay", "ok", "so", "well", "yeah",
        "yes", "no", "right", "anyway", "basically", "actually", "literally", "alright",
        "hey", "hi", "hello", "gonna", "wanna", "kinda", "sorta", "just", "really",
    ]

    /// English function words (plus common contraction-normalized forms) excluded
    /// from salience counting.
    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "than", "that", "this",
        "these", "those", "there", "here", "it", "its", "is", "are", "was", "were",
        "be", "been", "being", "am", "do", "does", "did", "done", "doing", "have",
        "has", "had", "having", "will", "would", "can", "could", "should", "shall",
        "may", "might", "must", "of", "to", "in", "on", "at", "by", "for", "with",
        "from", "into", "onto", "over", "under", "about", "after", "before", "between",
        "through", "during", "against", "again", "further", "out", "off", "up", "down",
        "above", "below", "not", "nor", "only", "own", "same", "too", "very", "also",
        "i", "im", "ive", "id", "ill", "me", "my", "mine", "we", "were", "weve", "our",
        "ours", "us", "you", "your", "yours", "youre", "youve", "youll", "he", "him",
        "his", "hes", "she", "her", "hers", "shes", "they", "them", "their", "theirs",
        "theyre", "theyve", "what", "which", "who", "whom", "whose", "when", "where",
        "why", "how", "all", "any", "both", "each", "few", "more", "most", "other",
        "some", "such", "as", "because", "while", "until", "once", "now", "dont",
        "doesnt", "didnt", "cant", "couldnt", "wouldnt", "shouldnt", "isnt", "arent",
        "wasnt", "werent", "wont", "lets", "thats", "whats", "theres", "heres", "get",
        "got", "getting", "go", "going", "goes", "went", "one", "two", "thing",
        "things", "something", "anything", "everything", "nothing", "someone",
        "anyone", "everyone", "stuff", "bit", "lot", "kind", "sort", "way", "know",
        "think", "mean", "want", "need", "make", "say", "said", "see", "look", "back",
        "still", "even", "much", "many", "maybe", "sure", "good", "nice", "little",
        "big", "new", "next", "last", "first", "time", "today", "tomorrow", "yesterday",
    ]
}

/// One settled live title: its text plus the TIER it came from. Ranked worst→best:
/// the pure-Swift heuristic (instant, free) is the floor; the on-device Foundation
/// Models title (the instant placeholder's upgrade + the offline fallback) outranks
/// it; the phone-originated EXTERNAL refresh (Fireworks via the door, on the
/// exponential backoff — track 20260717T1500) is the sharpest and outranks both.
public struct LiveTitleState: Equatable, Sendable {
    public enum Tier: Int, Comparable, Sendable {
        case heuristic = 0
        case model = 1
        case external = 2
        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var text: String
    public var tier: Tier

    public init(text: String, tier: Tier) {
        self.text = text
        self.tier = tier
    }
}

/// The anti-flicker rule: once a good title exists it is only replaced when the
/// candidate is a TIER UPGRADE (model beats heuristic) or MEANINGFULLY different
/// (token-Jaccard similarity below the ceiling). A heuristic never overwrites a
/// model title; an empty candidate never clears anything.
public enum LiveTitleArbiter {
    /// Same-tier replacement requires similarity BELOW this (i.e. a real change).
    public static let replaceSimilarityCeiling = 0.5

    public static func merged(current: LiveTitleState?, candidateText: String,
                              tier: LiveTitleState.Tier) -> LiveTitleState? {
        let text = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return current }
        let candidate = LiveTitleState(text: text, tier: tier)
        guard let current else { return candidate }
        if tier > current.tier { return candidate }     // the smarter title wins
        if tier < current.tier { return current }       // never downgrade
        return similarity(current.text, text) < replaceSimilarityCeiling ? candidate : current
    }

    /// Token-set Jaccard similarity over normalized words (1.0 = same name).
    public static func similarity(_ a: String, _ b: String) -> Double {
        let ta = Set(a.split(separator: " ").map { WholeConversationTitle.normalize(String($0)) }
            .filter { !$0.isEmpty })
        let tb = Set(b.split(separator: " ").map { WholeConversationTitle.normalize(String($0)) }
            .filter { !$0.isEmpty })
        if ta.isEmpty && tb.isEmpty { return 1 }
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        return Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
    }
}

/// How often the live title refreshes. Heuristics are cheap (a scan of the bounded
/// context) and run on new FINALIZED words; the on-device model refresh is debounced
/// hard — never per-word, never concurrent, never on the main thread.
public struct LiveTitleCadence: Sendable, Equatable {
    /// New finalized words required between heuristic recomputes.
    public var heuristicMinNewWords: Int
    /// Context words required before the FIRST model refresh.
    public var modelMinWords: Int
    /// New words required between model refreshes.
    public var modelMinNewWords: Int
    /// Wall-clock seconds required between model refreshes.
    public var modelRefreshSeconds: TimeInterval

    public init(heuristicMinNewWords: Int, modelMinWords: Int,
                modelMinNewWords: Int, modelRefreshSeconds: TimeInterval) {
        self.heuristicMinNewWords = heuristicMinNewWords
        self.modelMinWords = modelMinWords
        self.modelMinNewWords = modelMinNewWords
        self.modelRefreshSeconds = modelRefreshSeconds
    }

    public static let `default` = LiveTitleCadence(
        heuristicMinNewWords: 8, modelMinWords: 30, modelMinNewWords: 25,
        modelRefreshSeconds: 45)
}

/// The EXPONENTIAL BACKOFF schedule for the phone-originated EXTERNAL live-title
/// refresh (track 20260717T1500, Nick-approved). The instant on-device placeholder
/// (heuristic + Foundation Models) names the conversation immediately and for free;
/// on this GEOMETRIC cadence the phone asks the door for an EXTERNAL (Fireworks)
/// re-title that SHARPENS it. The interval BEFORE each refresh doubles — ~1, 2, 4,
/// 8, 16 min… — capped at `ceiling` (the "between refreshes" cap), so a long
/// conversation refreshes at most every ceiling. Geometric spacing keeps external
/// spend sub-cent over a multi-hour conversation (≈6 calls in the first hour).
///
/// Pure + Sendable so the schedule is unit-tested independent of any clock; the
/// manager owns the wall-clock anchor and the "skip a tick with no new words" gate.
public struct LiveTitleBackoff: Sendable, Equatable {
    /// Delay from the conversation's start to the FIRST external refresh.
    public var firstDelay: TimeInterval
    /// Each subsequent interval multiplies the previous by this.
    public var multiplier: Double
    /// No interval is ever longer than this (the cap "between refreshes").
    public var ceiling: TimeInterval

    public init(firstDelay: TimeInterval, multiplier: Double, ceiling: TimeInterval) {
        self.firstDelay = firstDelay
        self.multiplier = multiplier
        self.ceiling = ceiling
    }

    /// Nick-approved default: first at ~1 min, then +2, +4, +8, +16 min… capped at
    /// 30 min between refreshes.
    public static let `default` = LiveTitleBackoff(firstDelay: 60, multiplier: 2, ceiling: 1_800)

    /// The delay to wait BEFORE the refresh that follows `completedRefreshes`
    /// already-fired refreshes. `0` ⇒ `firstDelay` (the first refresh); each further
    /// refresh doubles the previous interval, capped at `ceiling`. Negative inputs are
    /// clamped to the first delay.
    public func delay(afterRefreshes completedRefreshes: Int) -> TimeInterval {
        guard completedRefreshes > 0 else { return min(firstDelay, ceiling) }
        let raw = firstDelay * pow(multiplier, Double(completedRefreshes))
        return min(raw, ceiling)
    }
}
