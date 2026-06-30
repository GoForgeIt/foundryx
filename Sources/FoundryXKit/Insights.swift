import Foundation

/// A surfaced-insights digest — what FoundryX RENDERS on the Insights surface.
///
/// COMPUTED server-side (Lore/Anvil — Nick's domain); the phone is a THIN CLIENT that only
/// fetches + displays, never analyzes. The Door endpoint and exact JSON shape are TBD with
/// Nick; this is the phone's stable RENDERING CONTRACT — when the endpoint lands, map its
/// real fields onto these types (and the view doesn't change).
public struct InsightsDigest: Codable, Equatable, Sendable {
    /// One-line "your day" summary.
    public var headline: String?
    /// Things to do, surfaced from conversations.
    public var actionItems: [InsightItem]
    /// Notable moments / decisions worth remembering.
    public var highlights: [InsightItem]
    /// Knowledge-graph teaser: recurring people / projects / themes.
    public var topics: [InsightTopic]

    public init(headline: String? = nil, actionItems: [InsightItem] = [],
                highlights: [InsightItem] = [], topics: [InsightTopic] = []) {
        self.headline = headline
        self.actionItems = actionItems
        self.highlights = highlights
        self.topics = topics
    }

    public var isEmpty: Bool {
        (headline?.isEmpty ?? true) && actionItems.isEmpty && highlights.isEmpty && topics.isEmpty
    }
}

/// One surfaced item (an action item or a highlight), optionally linked back to the
/// conversation it came from.
public struct InsightItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var sourceTitle: String?
    public var captureId: String?

    public init(id: String, text: String, sourceTitle: String? = nil, captureId: String? = nil) {
        self.id = id; self.text = text; self.sourceTitle = sourceTitle; self.captureId = captureId
    }
}

/// A knowledge-graph node teaser: a recurring person / project / theme and how often it
/// came up. The full graph is server-side; this is the phone's lightweight surfacing of it.
public struct InsightTopic: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var mentions: Int

    public init(id: String, label: String, mentions: Int) {
        self.id = id; self.label = label; self.mentions = mentions
    }
}

#if DEBUG
public extension InsightsDigest {
    /// Sample digest for headless screenshots (Kevin-flavored). NOT shipped data.
    static var sample: InsightsDigest {
        InsightsDigest(
            headline: "3 follow-ups and 2 decisions from today's 4 conversations.",
            actionItems: [
                InsightItem(id: "a1", text: "Send the Lantis SOW by Friday", sourceTitle: "Lantis kickoff call"),
                InsightItem(id: "a2", text: "Book the dentist for the 12th", sourceTitle: "Call with Mom"),
                InsightItem(id: "a3", text: "Reply to Sarah about the venue deposit", sourceTitle: "Wedding planning")
            ],
            highlights: [
                InsightItem(id: "h1", text: "Agreed to a 90-day pilot focused on the intake workflow.", sourceTitle: "Lantis kickoff call"),
                InsightItem(id: "h2", text: "Decided to push the launch to mid-July.", sourceTitle: "Standup")
            ],
            topics: [
                InsightTopic(id: "t1", label: "Lantis", mentions: 6),
                InsightTopic(id: "t2", label: "Wedding", mentions: 4),
                InsightTopic(id: "t3", label: "Sarah", mentions: 3),
                InsightTopic(id: "t4", label: "Launch", mentions: 3)
            ]
        )
    }
}
#endif
