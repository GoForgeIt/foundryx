// ActivityStore — the Activity surface's testable core (track 20260713T0905):
// "what has it done for me?" answered from what ACTUALLY happened. It reads the
// intelligence agent's JSONL logs READ-ONLY — the ambient decision log
// (ambient-decisions.jsonl, written by AmbientLane) and the card-outcome log
// (ambient-cards.jsonl, written by AmbientCardBroker) — and aggregates them into
// a newest-first ledger, day/week buckets, recap cards, and plain-sentence
// personal measures.
//
// Honesty rules (the spec's spine):
//   • Another agent owns the writers — this file NEVER writes, and it tolerates
//     missing files, half-written lines, and unknown shapes: a readable field is
//     rendered, a missing one is simply absent, an unreadable line is skipped.
//     Nothing is ever invented.
//   • Routine internal decisions (gated_no, skipped) stay invisible — they are
//     diagnostics, not things done FOR the user.
//   • Empty days/weeks produce NO recap card. Silence is a feature.
//   • Measures are plain sentences ("1 nudge · you accepted it"), never charts
//     or internal tool names.
//
// Recap synthesis goes behind the RecapSynthesizer seam: tests drive a
// deterministic double; the real engine is Apple Foundation Models (App target,
// availability-gated, same pattern as FoundationModelsTitler). Every recap card
// also carries a deterministic fallbackText composed from the actual entries, so
// a phone without the model still gets an honest recap.

import Foundation

// MARK: - Ledger entries

/// One user-visible thing the assistant did (or offered): a nudge and its fate,
/// an answer compiled from the user's memory, an agent run.
public struct ActivityEntry: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// The gate surfaced a moment and the user was nudged.
        case nudgeShown
        /// The user accepted a nudge (it opened a chat / ran).
        case nudgeAccepted
        /// The user dismissed a nudge.
        case nudgeDismissed
        /// An answer compiled from the user's own memory.
        case answer
        /// An agent run on the user's behalf.
        case agentRun
    }

    /// Where the entry came from, for the ledger's source link. `.none` when the
    /// record honestly carried no link — rendered without one, never guessed.
    public enum Source: Equatable, Sendable {
        case conversation(captureId: String)
        case chat(seed: String)
        case none
    }

    public let id: String
    /// Epoch seconds; 0 when the record carried no timestamp.
    public let ts: UInt64
    public let kind: Kind
    /// The human text of the moment (utterance/summary/answer/seed) — nil when
    /// the record had none.
    public let detail: String?
    /// The user's own rating word ("helpful"), when they gave one.
    public let rating: String?
    public let source: Source
    /// The surfaced candidate's raw utterance — the ACTION JOIN KEY (EXT1):
    /// present only on decision-line entries that carried a candidate, which is
    /// exactly the set of entries the Activity page can offer action options
    /// on. Card-outcome entries (accepted/dismissed) have no utterance — only a
    /// seed — and honestly offer none.
    public let utterance: String?

    public init(id: String, ts: UInt64, kind: Kind, detail: String?,
                rating: String?, source: Source, utterance: String? = nil) {
        self.id = id
        self.ts = ts
        self.kind = kind
        self.detail = detail
        self.rating = rating
        self.source = source
        self.utterance = utterance
    }

    /// The capture this entry can act against (nil ⇒ no action options).
    public var actionCaptureId: String? {
        guard utterance != nil, case .conversation(let cid) = source else { return nil }
        return cid
    }
}

// MARK: - Buckets

/// A calendar day that HAD activity. Empty days never become an ActivityDay.
public struct ActivityDay: Equatable, Sendable, Identifiable {
    public let day: Date
    /// Newest first.
    public let entries: [ActivityEntry]
    public var id: Date { day }

    public init(day: Date, entries: [ActivityEntry]) {
        self.day = day
        self.entries = entries
    }
}

/// A calendar week that HAD activity. Empty weeks never become an ActivityWeek.
public struct ActivityWeek: Equatable, Sendable, Identifiable {
    public let weekStart: Date
    /// Newest first.
    public let entries: [ActivityEntry]
    public var id: Date { weekStart }

    public init(weekStart: Date, entries: [ActivityEntry]) {
        self.weekStart = weekStart
        self.entries = entries
    }
}

// MARK: - Recap seam

public enum RecapPeriod: Equatable, Sendable {
    case day(Date)
    case week(Date)
}

/// Synthesizes a short human recap from a period's REAL entries. The engine is
/// on-device (Apple Foundation Models, App target); tests drive a deterministic
/// double. Unavailable ⇒ the card's deterministic fallbackText stands.
public protocol RecapSynthesizer: Sendable {
    var isAvailable: Bool { get }
    func recap(entries: [ActivityEntry], period: RecapPeriod) async throws -> String
}

/// A recap card for a day/week that had content. `fallbackText` is composed
/// deterministically from the actual entries; a synthesizer may replace it with
/// model prose, but the card exists (and is honest) without one.
public struct RecapCard: Equatable, Sendable, Identifiable {
    public let period: RecapPeriod
    public let fallbackText: String

    public var id: String {
        switch period {
        case .day(let d): return "day-\(UInt64(d.timeIntervalSince1970))"
        case .week(let d): return "week-\(UInt64(d.timeIntervalSince1970))"
        }
    }

    public init(period: RecapPeriod, fallbackText: String) {
        self.period = period
        self.fallbackText = fallbackText
    }
}

// MARK: - The store

public enum ActivityStore {

    /// The card-outcome log lives beside the decision log (AmbientCardBroker
    /// writes `ambient-cards.jsonl` into the same captures directory).
    public static func cardsLogURL(besides decisionLogURL: URL) -> URL {
        decisionLogURL.deletingLastPathComponent()
            .appendingPathComponent("ambient-cards.jsonl")
    }

    /// The app-event log (answers delivered, ratings given, agent runs) lives
    /// beside the other two. Written by AmbientNotifier (answers), the answer
    /// surface (ratings), and the chat run hook (agent runs).
    public static func answersLogURL(besides decisionLogURL: URL) -> URL {
        decisionLogURL.deletingLastPathComponent()
            .appendingPathComponent("ambient-answers.jsonl")
    }

    /// The full ledger, newest first. Both files are read-only and optional —
    /// a missing file simply contributes nothing.
    public static func entries(decisionLogURL: URL, cardsLogURL: URL) -> [ActivityEntry] {
        let decisions = readLines(at: decisionLogURL).enumerated().compactMap {
            classify($1, id: "decision#\($0)")
        }
        let cards = readLines(at: cardsLogURL).enumerated().compactMap {
            classify($1, id: "card#\($0)")
        }
        return (decisions + cards).sorted {
            $0.ts == $1.ts ? $0.id > $1.id : $0.ts > $1.ts
        }
    }

    /// The three-log ledger (features/ambient-answer-loop.feature): the two
    /// ambient logs plus the app-event log. Rating lines ANNOTATE the most
    /// recent answer at-or-before their time — they never become entries of
    /// their own, and a rating with no answer to land on is dropped (nothing
    /// is invented).
    public static func entries(decisionLogURL: URL, cardsLogURL: URL,
                               answersLogURL: URL) -> [ActivityEntry] {
        let base = entries(decisionLogURL: decisionLogURL, cardsLogURL: cardsLogURL)

        var events: [ActivityEntry] = []
        var ratings: [(ts: UInt64, word: String)] = []
        for (i, raw) in readLines(at: answersLogURL).enumerated() {
            if raw.kind == nil, raw.answer == nil, let r = raw.rating {
                // A feedback line from the answer surface: rating and/or note.
                let word = r == "not-useful" ? "not useful" : r
                if !word.isEmpty, word != "none" { ratings.append((raw.ts ?? 0, word)) }
            } else if let entry = classify(raw, id: "event#\(i)") {
                events.append(entry)
            }
        }
        for r in ratings {
            guard let idx = events.lastIndex(where: { $0.kind == .answer && $0.ts <= r.ts })
            else { continue }   // nowhere to land — dropped, not invented
            let e = events[idx]
            events[idx] = ActivityEntry(id: e.id, ts: e.ts, kind: e.kind,
                                        detail: e.detail, rating: r.word, source: e.source)
        }
        return (base + events).sorted {
            $0.ts == $1.ts ? $0.id > $1.id : $0.ts > $1.ts
        }
    }

    /// Days that HAD activity, newest first. No entries ⇒ no days ⇒ no cards:
    /// silence is a feature, guaranteed by construction.
    public static func days(entries: [ActivityEntry],
                            calendar: Calendar = .current) -> [ActivityDay] {
        bucket(entries: entries) { calendar.startOfDay(for: $0) }
            .map { ActivityDay(day: $0.0, entries: $0.1) }
    }

    /// Weeks that HAD activity, newest first.
    public static func weeks(entries: [ActivityEntry],
                             calendar: Calendar = .current) -> [ActivityWeek] {
        bucket(entries: entries) {
            calendar.dateInterval(of: .weekOfYear, for: $0)?.start
                ?? calendar.startOfDay(for: $0)
        }
        .map { ActivityWeek(weekStart: $0.0, entries: $0.1) }
    }

    /// The daily recap card — only ever built from a day that has content.
    public static func recapCard(day: ActivityDay) -> RecapCard? {
        guard !day.entries.isEmpty else { return nil }
        return RecapCard(period: .day(day.day),
                         fallbackText: fallbackRecap(entries: day.entries))
    }

    /// The weekly recap card — same honesty: no content, no card.
    public static func recapCard(week: ActivityWeek) -> RecapCard? {
        guard !week.entries.isEmpty else { return nil }
        return RecapCard(period: .week(week.weekStart),
                         fallbackText: fallbackRecap(entries: week.entries))
    }

    /// Personal measures as plain sentences — counts plus the user's OWN ratings,
    /// no charts, no internal tool names. Empty activity ⇒ no sentences.
    public static func measures(entries: [ActivityEntry]) -> [String] {
        var sentences: [String] = []

        let shown = entries.filter { $0.kind == .nudgeShown }.count
        let accepted = entries.filter { $0.kind == .nudgeAccepted }.count
        let dismissed = entries.filter { $0.kind == .nudgeDismissed }.count
        if shown > 0 {
            var parts = [shown == 1 ? "1 nudge" : "\(shown) nudges"]
            if accepted > 0 {
                parts.append(shown == 1 && accepted == 1 && dismissed == 0
                             ? "you accepted it" : "you accepted \(accepted)")
            }
            if dismissed > 0 {
                parts.append(shown == 1 && dismissed == 1 && accepted == 0
                             ? "you dismissed it" : "you dismissed \(dismissed)")
            }
            sentences.append(parts.joined(separator: " · "))
        } else if accepted + dismissed > 0 {
            // The fate logs survived but the shown record didn't — say only what
            // we know.
            var parts: [String] = []
            if accepted > 0 {
                parts.append(accepted == 1 ? "you accepted 1 nudge"
                                           : "you accepted \(accepted) nudges")
            }
            if dismissed > 0 {
                parts.append(dismissed == 1 ? "you dismissed 1 nudge"
                                            : "you dismissed \(dismissed) nudges")
            }
            sentences.append(parts.joined(separator: " · "))
        }

        let answers = entries.filter { $0.kind == .answer }
        if !answers.isEmpty {
            let n = answers.count
            var part = n == 1 ? "1 answer from your memory"
                              : "\(n) answers from your memory"
            let ratings = answers.compactMap(\.rating)
            if n == 1, let rating = ratings.first {
                part += " · you rated it \(rating)"
            } else if !ratings.isEmpty {
                part += ratings.count == 1 ? " · you rated 1"
                                           : " · you rated \(ratings.count)"
            }
            sentences.append(part)
        }

        let runs = entries.filter { $0.kind == .agentRun }.count
        if runs > 0 {
            sentences.append(runs == 1 ? "1 agent run" : "\(runs) agent runs")
        }

        return sentences
    }

    /// Recent notification-worthy events (nudges shown, answers delivered) —
    /// visible here even when the system banner was missed or silenced. Newest
    /// first.
    public static func notificationHistory(entries: [ActivityEntry],
                                           limit: Int = 10) -> [ActivityEntry] {
        Array(entries.filter { $0.kind == .nudgeShown || $0.kind == .answer }
            .prefix(max(0, limit)))
    }

    // MARK: - Internals

    /// The deterministic recap body: the period's measures joined into prose.
    private static func fallbackRecap(entries: [ActivityEntry]) -> String {
        let sentences = measures(entries: entries)
        return sentences.isEmpty ? "" : sentences.joined(separator: ". ") + "."
    }

    private static func bucket(
        entries: [ActivityEntry],
        key: (Date) -> Date
    ) -> [(Date, [ActivityEntry])] {
        var buckets: [Date: [ActivityEntry]] = [:]
        for entry in entries {
            let start = key(Date(timeIntervalSince1970: TimeInterval(entry.ts)))
            buckets[start, default: []].append(entry)
        }
        return buckets.sorted { $0.key > $1.key }.map { key, bucketed in
            (key, bucketed.sorted { $0.ts == $1.ts ? $0.id > $1.id : $0.ts > $1.ts })
        }
    }

    /// One JSONL line, every field optional — the tolerant superset of what the
    /// two writers produce today plus fields a richer writer may add (kind,
    /// answer, rating). Unknown extra fields are ignored by construction.
    private struct RawLine: Decodable {
        var ts: UInt64?
        var captureId: String?
        var outcome: String?
        var candidate: RawCandidate?
        var kind: String?
        var answer: String?
        var rating: String?
        var seed: String?
    }

    private struct RawCandidate: Decodable {
        var utterance: String?
        var summary: String?
    }

    private static func readLines(at url: URL) -> [RawLine] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? dec.decode(RawLine.self, from: Data($0))
        }
    }

    /// Map a tolerated line to a user-visible entry, or nil for the invisible
    /// ones (routine gate decisions, suppressed cards, unknown shapes).
    private static func classify(_ raw: RawLine, id: String) -> ActivityEntry? {
        let kind: ActivityEntry.Kind
        switch (raw.kind, raw.outcome) {
        case ("answer", _):
            kind = .answer
        case ("agent_run", _), ("agentRun", _):
            kind = .agentRun
        case (_, _) where raw.kind == nil && raw.answer != nil:
            kind = .answer
        case (nil, "candidate"):
            kind = .nudgeShown
        case (nil, "run"):
            kind = .nudgeAccepted
        case (nil, "dismissed"):
            // An owner-unverified suppression was never SHOWN to the user —
            // listing it as "you dismissed" would be a lie (see AmbientNotifier).
            if raw.seed?.hasPrefix("owner-unverified:") == true { return nil }
            kind = .nudgeDismissed
        default:
            // gated_no / skipped / anything unknown: not user-visible.
            return nil
        }

        let source: ActivityEntry.Source
        if let captureId = raw.captureId, !captureId.isEmpty {
            source = .conversation(captureId: captureId)
        } else if let seed = raw.seed, !seed.isEmpty {
            source = .chat(seed: seed)
        } else {
            source = .none
        }

        let summary = raw.candidate?.summary.flatMap { $0.isEmpty ? nil : $0 }
        let utterance = raw.candidate?.utterance.flatMap { $0.isEmpty ? nil : $0 }
        return ActivityEntry(
            id: id,
            ts: raw.ts ?? 0,
            kind: kind,
            detail: raw.answer ?? summary ?? utterance ?? raw.seed,
            rating: raw.rating,
            source: source,
            utterance: utterance)
    }
}
