import Foundation

public struct StatsDailyTrend: Sendable, Equatable, Identifiable {
    public let day: Date
    public let conversationCount: Int

    public var id: Date { day }

    public init(day: Date, conversationCount: Int) {
        self.day = day
        self.conversationCount = conversationCount
    }
}

/// One conversation's contribution to the library stats, as COUNTS — never raw text.
///
/// Track `rebuild_is_byte_independent_and_disk_free`: `StatsSummary.build` used to re-split
/// and re-scan every conversation's whole transcript on every list rebuild, which made the
/// rebuild O(total transcript bytes) — i.e. the app got slower every day it succeeded. The
/// derived facts (`wordCount`, the distinct-speaker identity keys) are now computed ONCE, off
/// the main actor, when a capture's sidecar memo is warmed; `build` is an integer reduce.
public struct StatsConversationSnapshot: Sendable, Equatable {
    public let captureId: String
    public let meta: ConversationMeta?
    /// Whitespace-delimited word count of the conversation's cached transcript text.
    public let wordCount: Int
    /// The distinct speaker-identity keys this conversation contributes (already
    /// capture-qualified where the identity is only slot-local). De-duped ACROSS
    /// conversations by `build`, exactly as the old per-transcript scan did.
    public let speakerIdentities: [String]

    public init(captureId: String, meta: ConversationMeta?,
                wordCount: Int, speakerIdentities: [String]) {
        self.captureId = captureId
        self.meta = meta
        self.wordCount = wordCount
        self.speakerIdentities = speakerIdentities
    }

    /// Convenience for callers that still hold a decoded transcript (tests, one-off tools):
    /// derives the same counts the off-main sidecar warm derives.
    public init(captureId: String, meta: ConversationMeta?, transcript: CachedTranscript?) {
        self.init(captureId: captureId,
                  meta: meta,
                  wordCount: StatsSummary.wordCount(transcript?.transcript ?? ""),
                  speakerIdentities: transcript.map {
                      StatsSummary.speakerIdentities(in: $0, captureId: captureId)
                  } ?? [])
    }
}

public struct StatsSummary: Sendable, Equatable {
    public let totalConversations: Int
    public let totalDurationSeconds: UInt64
    public let averageDurationSeconds: UInt64
    public let totalSpeakersIdentified: Int
    public let totalWords: Int
    public let conversationsPerDay: [StatsDailyTrend]
    public let hoursThisWeek: Double

    public static let empty = StatsSummary(
        totalConversations: 0,
        totalDurationSeconds: 0,
        averageDurationSeconds: 0,
        totalSpeakersIdentified: 0,
        totalWords: 0,
        conversationsPerDay: [],
        hoursThisWeek: 0
    )

    public init(totalConversations: Int,
                totalDurationSeconds: UInt64,
                averageDurationSeconds: UInt64,
                totalSpeakersIdentified: Int,
                totalWords: Int,
                conversationsPerDay: [StatsDailyTrend],
                hoursThisWeek: Double) {
        self.totalConversations = totalConversations
        self.totalDurationSeconds = totalDurationSeconds
        self.averageDurationSeconds = averageDurationSeconds
        self.totalSpeakersIdentified = totalSpeakersIdentified
        self.totalWords = totalWords
        self.conversationsPerDay = conversationsPerDay
        self.hoursThisWeek = hoursThisWeek
    }

    public static func build(from conversations: [StatsConversationSnapshot],
                             now: Date = Date(),
                             calendar: Calendar = .current,
                             trendDays: Int = 14) -> StatsSummary {
        guard !conversations.isEmpty else {
            return StatsSummary(totalConversations: 0,
                                totalDurationSeconds: 0,
                                averageDurationSeconds: 0,
                                totalSpeakersIdentified: 0,
                                totalWords: 0,
                                conversationsPerDay: dailyTrend(counts: [:], now: now,
                                                                calendar: calendar,
                                                                trendDays: trendDays),
                                hoursThisWeek: 0)
        }

        let durations = conversations.compactMap { $0.meta?.durationSeconds }
        let totalDuration = durations.reduce(UInt64(0), +)
        let averageDuration = durations.isEmpty ? 0 : totalDuration / UInt64(durations.count)

        var dayCounts: [Date: Int] = [:]
        var weeklyDuration: UInt64 = 0
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        for conversation in conversations {
            guard let startedAt = conversation.meta?.startedAt else { continue }
            let started = Date(timeIntervalSince1970: TimeInterval(startedAt))
            dayCounts[calendar.startOfDay(for: started), default: 0] += 1
            if let week, week.contains(started), let duration = conversation.meta?.durationSeconds {
                weeklyDuration += duration
            }
        }

        return StatsSummary(
            totalConversations: conversations.count,
            totalDurationSeconds: totalDuration,
            averageDurationSeconds: averageDuration,
            // Integer reduce over CACHED counts — no transcript text is split, lowercased
            // or traversed here (the byte-independence requirement).
            totalSpeakersIdentified: countDistinctSpeakers(in: conversations),
            totalWords: conversations.reduce(0) { $0 + $1.wordCount },
            conversationsPerDay: dailyTrend(counts: dayCounts, now: now,
                                            calendar: calendar, trendDays: trendDays),
            hoursThisWeek: Double(weeklyDuration) / 3600
        )
    }

    private static func dailyTrend(counts: [Date: Int],
                                   now: Date,
                                   calendar: Calendar,
                                   trendDays: Int) -> [StatsDailyTrend] {
        let count = max(1, trendDays)
        let today = calendar.startOfDay(for: now)
        return stride(from: count - 1, through: 0, by: -1).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return StatsDailyTrend(day: day, conversationCount: counts[day] ?? 0)
        }
    }

    /// Whitespace-delimited word count. Called ONCE per conversation off the main actor (at
    /// sidecar warm), never on a render/rebuild path.
    public static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// The distinct speaker-identity keys a decoded transcript contributes: every entry in
    /// the speaker array, PLUS any segment slot the speaker array doesn't mention. Computed
    /// ONCE per conversation off the main actor (at sidecar warm) — byte-identical to the old
    /// per-rebuild scan, but paid once instead of on every rebuild.
    public static func speakerIdentities(in transcript: CachedTranscript, captureId: String) -> [String] {
        var identities = Set<String>()
        let knownSlots = Set(transcript.speakers.map(\.slot))
        for speaker in transcript.speakers {
            identities.insert(identity(for: speaker, captureId: captureId))
        }
        for segment in transcript.segments
        where !segment.speaker.isEmpty && !knownSlots.contains(segment.speaker) {
            identities.insert("slot:\(captureId):\(segment.speaker)")
        }
        return Array(identities)
    }

    private static func countDistinctSpeakers(in conversations: [StatsConversationSnapshot]) -> Int {
        var identities = Set<String>()
        for conversation in conversations { identities.formUnion(conversation.speakerIdentities) }
        return identities.count
    }

    private static func identity(for speaker: CaptureSpeaker, captureId: String) -> String {
        if let id = speaker.confirmedSpeakerId, !id.isEmpty { return "confirmed:\(id)" }
        if let id = speaker.inferredSpeakerId, !id.isEmpty { return "inferred:\(id)" }
        if let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !name.isEmpty, speaker.status != .anonymous {
            return "name:\(name)"
        }
        return "slot:\(captureId):\(speaker.slot)"
    }
}
