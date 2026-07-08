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

public struct StatsConversationSnapshot: Sendable, Equatable {
    public let captureId: String
    public let meta: ConversationMeta?
    public let transcript: CachedTranscript?

    public init(captureId: String, meta: ConversationMeta?, transcript: CachedTranscript?) {
        self.captureId = captureId
        self.meta = meta
        self.transcript = transcript
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
            totalSpeakersIdentified: countDistinctSpeakers(in: conversations),
            totalWords: conversations.reduce(0) { $0 + wordCount($1.transcript?.transcript ?? "") },
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

    private static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private static func countDistinctSpeakers(in conversations: [StatsConversationSnapshot]) -> Int {
        var identities = Set<String>()
        for conversation in conversations {
            guard let transcript = conversation.transcript else { continue }
            let knownSlots = Set(transcript.speakers.map(\.slot))
            for speaker in transcript.speakers {
                identities.insert(identity(for: speaker, captureId: conversation.captureId))
            }
            for segment in transcript.segments where !segment.speaker.isEmpty && !knownSlots.contains(segment.speaker) {
                identities.insert("slot:\(conversation.captureId):\(segment.speaker)")
            }
        }
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
