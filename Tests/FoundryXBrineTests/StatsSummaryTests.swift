import XCTest
import Foundation
@testable import FoundryXKit

final class StatsSummaryTests: XCTestCase {
    func testBuildsAggregateFromMetasAndCachedTranscripts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 12)))
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9)))
        let tuesday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 10)))
        let old = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 15)))

        let summary = StatsSummary.build(
            from: [
                StatsConversationSnapshot(
                    captureId: "c1",
                    meta: ConversationMeta(startedAt: UInt64(monday.timeIntervalSince1970),
                                           endedAt: UInt64(monday.timeIntervalSince1970) + 1800),
                    transcript: CachedTranscript(
                        transcript: "one two three four",
                        title: nil,
                        summary: nil,
                        segments: [
                            TranscriptSegment(seq: 0, text: "one two", speaker: "speaker_0"),
                            TranscriptSegment(seq: 1, text: "three four", speaker: "speaker_1"),
                        ],
                        speakers: [
                            CaptureSpeaker(slot: "speaker_0", status: .confirmed,
                                           name: "Alice", confirmedSpeakerId: "spk_alice"),
                            CaptureSpeaker(slot: "speaker_1", status: .anonymous),
                        ],
                        fetchedAt: 1)
                ),
                StatsConversationSnapshot(
                    captureId: "c2",
                    meta: ConversationMeta(startedAt: UInt64(tuesday.timeIntervalSince1970),
                                           endedAt: UInt64(tuesday.timeIntervalSince1970) + 3600),
                    transcript: CachedTranscript(
                        transcript: "five six seven",
                        title: nil,
                        summary: nil,
                        segments: [
                            TranscriptSegment(seq: 0, text: "five", speaker: "speaker_0"),
                            TranscriptSegment(seq: 1, text: "six seven", speaker: "speaker_1"),
                        ],
                        speakers: [
                            CaptureSpeaker(slot: "speaker_0", status: .confirmed,
                                           name: "Alice", confirmedSpeakerId: "spk_alice"),
                            CaptureSpeaker(slot: "speaker_1", status: .inferred,
                                           name: "Bob", inferredSpeakerId: "spk_bob"),
                        ],
                        fetchedAt: 2)
                ),
                StatsConversationSnapshot(
                    captureId: "c3",
                    meta: ConversationMeta(startedAt: UInt64(old.timeIntervalSince1970),
                                           endedAt: UInt64(old.timeIntervalSince1970) + 900),
                    transcript: nil
                ),
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(summary.totalConversations, 3)
        XCTAssertEqual(summary.totalDurationSeconds, 6300)
        XCTAssertEqual(summary.averageDurationSeconds, 2100)
        XCTAssertEqual(summary.totalWords, 7)
        XCTAssertEqual(summary.totalSpeakersIdentified, 3)
        XCTAssertEqual(summary.hoursThisWeek, 1.5, accuracy: 0.001)
        XCTAssertEqual(summary.conversationsPerDay.count, 14)
        XCTAssertEqual(summary.conversationsPerDay.suffix(3).map(\.conversationCount), [1, 1, 0])
    }
}
