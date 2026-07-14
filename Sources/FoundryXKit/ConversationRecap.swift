// ConversationRecap — a living recap of what the user talked about
// (features/conversation-recaps.feature). The DAILY recap is a narrative +
// insights over the day's conversations, rebuilt each time a new conversation
// finishes processing (so it grows through the day). The WEEKLY recap is the
// same richness across the week, refreshed at end-of-week and on demand
// (week-to-date). A recap exists only for a period that had conversations, and
// is composed from what was ACTUALLY said (titles + summaries) — never invented.
//
// The narrative/insight PROSE is produced by a RecapComposer seam (Apple
// Foundation Models in the app, a deterministic double in tests). Even with no
// model, a genuinely useful recap stands: the deterministic composer threads the
// conversation summaries into a narrative and lifts each conversation's subject
// into an insight — so nothing is fabricated.

import Foundation

/// One conversation's contribution to a recap: what the app knows about it.
public struct RecapConversation: Equatable, Sendable {
    public let captureId: String
    public let title: String
    public let summary: String
    /// When it was captured (for day/week bucketing + freshness).
    public let at: Date

    public init(captureId: String, title: String, summary: String, at: Date) {
        self.captureId = captureId
        self.title = title
        self.summary = summary
        self.at = at
    }
}

public enum RecapSpan: Equatable, Sendable {
    case day(Date)          // start-of-day
    case week(Date)         // start-of-week
    /// A mid-week "so far" view: week start through `asOf`.
    case weekToDate(start: Date, asOf: Date)
}

/// A built recap: the narrative + insights over a period's conversations.
public struct ConversationRecap: Equatable, Sendable, Identifiable {
    public let span: RecapSpan
    /// Multi-sentence narrative of the period.
    public let narrative: String
    /// A few insights (connections, follow-ups, subjects) drawn from the
    /// conversations — each references something actually discussed.
    public let insights: [String]
    /// How many conversations this covers.
    public let conversationCount: Int
    /// The newest conversation's time — drives the "updated after N" freshness line.
    public let updatedAt: Date

    public var id: String {
        switch span {
        case .day(let d): return "day-\(UInt64(d.timeIntervalSince1970))"
        case .week(let d): return "week-\(UInt64(d.timeIntervalSince1970))"
        case .weekToDate(let s, _): return "wtd-\(UInt64(s.timeIntervalSince1970))"
        }
    }

    /// The freshness line shown under the recap.
    public var freshnessLine: String {
        let n = conversationCount
        return "Updated after \(n) conversation\(n == 1 ? "" : "s")"
    }
}

/// Produces the narrative + insights prose from a period's conversations. The
/// app backs this with Apple Foundation Models; tests use a deterministic
/// double. `isAvailable == false` ⇒ the deterministic composition stands.
public protocol RecapComposer: Sendable {
    var isAvailable: Bool { get }
    /// Return (narrative, insights). Composed from the conversations only.
    func compose(_ conversations: [RecapConversation], span: RecapSpan) async -> (narrative: String, insights: [String])?
}

extension CaptureManager {
    /// The conversations the recaps draw on: every browsable capture that has a
    /// title or summary (its content), with its start time. Conversations still
    /// processing (no title/summary yet) don't contribute until they finish —
    /// which is exactly the "rebuilt after each conversation is processed"
    /// behavior (a new finished conversation appears in the pool).
    public func recapConversationPool() -> [RecapConversation] {
        visibleCaptures.compactMap { wal in
            let card = cardMeta(for: wal.captureId)
            let title = (card?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = (card?.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !summary.isEmpty else { return nil }
            return RecapConversation(captureId: wal.captureId, title: title,
                                     summary: summary, at: conversationStartDate(wal))
        }
    }
}

public enum ConversationRecapEngine {

    /// The conversations that belong to a span, from a pool. Pure bucketing.
    public static func conversations(in span: RecapSpan, from pool: [RecapConversation],
                                     calendar: Calendar = .current) -> [RecapConversation] {
        let range = dateRange(for: span, calendar: calendar)
        return pool.filter { range.contains($0.at) }.sorted { $0.at < $1.at }
    }

    /// Build the recap for a span, or nil when the period had no conversations
    /// (silence is a feature). Uses `composer` when available, else the
    /// deterministic composition — either way `count`/`updatedAt` are real.
    public static func build(span: RecapSpan, from pool: [RecapConversation],
                             composer: RecapComposer? = nil,
                             calendar: Calendar = .current) async -> ConversationRecap? {
        let convos = conversations(in: span, from: pool, calendar: calendar)
        guard !convos.isEmpty else { return nil }

        let composed: (narrative: String, insights: [String])
        if let composer, composer.isAvailable,
           let c = await composer.compose(convos, span: span) {
            composed = c
        } else {
            composed = deterministic(convos, span: span)
        }
        return ConversationRecap(
            span: span,
            narrative: composed.narrative,
            insights: composed.insights,
            conversationCount: convos.count,
            updatedAt: convos.map(\.at).max() ?? Date(timeIntervalSince1970: 0))
    }

    /// A genuinely useful recap with NO model: thread the conversation summaries
    /// into a narrative, and lift each conversation's subject into an insight.
    /// Never invents a topic — every sentence traces to a real conversation.
    static func deterministic(_ convos: [RecapConversation], span: RecapSpan)
        -> (narrative: String, insights: [String]) {
        let n = convos.count
        let opener: String
        switch span {
        case .day: opener = n == 1 ? "One conversation today." : "\(n) conversations today."
        case .week, .weekToDate: opener = "\(n) conversation\(n == 1 ? "" : "s") this week."
        }
        // Narrative: opener + each conversation's summary (falling back to title),
        // as sentences. Bounded so it stays readable.
        let sentences = convos.prefix(8).map { c -> String in
            let body = c.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let t = c.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { return body.hasSuffix(".") ? body : body + "." }
            return t.isEmpty ? "An untitled conversation." : "\(t)."
        }
        let narrative = ([opener] + sentences).joined(separator: " ")
        // Insights: one per conversation subject (title preferred), deduped.
        var seen = Set<String>()
        let insights = convos.compactMap { c -> String? in
            let subject = c.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = subject.lowercased()
            guard !subject.isEmpty, seen.insert(key).inserted else { return nil }
            return subject
        }
        return (narrative, Array(insights.prefix(6)))
    }

    /// Start-of-today and start-of-this-week spans for "now" — the two recaps the
    /// Activity view shows. Week starts on the calendar's firstWeekday.
    public static func currentSpans(now: Date = Date(), calendar: Calendar = .current)
        -> (day: RecapSpan, week: RecapSpan) {
        let dayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? dayStart
        return (.day(dayStart), .week(weekStart))
    }

    /// The date interval a span covers.
    static func dateRange(for span: RecapSpan, calendar: Calendar) -> Range<Date> {
        switch span {
        case .day(let start):
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return start..<end
        case .week(let start):
            let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
            return start..<end
        case .weekToDate(let start, let asOf):
            // Inclusive of `asOf` (a tick past, so "through now" includes now).
            return start..<asOf.addingTimeInterval(1)
        }
    }
}
