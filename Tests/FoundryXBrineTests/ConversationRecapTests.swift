import XCTest
import Foundation
import FoundryXKit

/// Living conversation recaps (features/conversation-recaps.feature). The prose
/// engine is a seam; these pin the durable logic — bucketing, incremental
/// rebuild, weekly rollup, week-to-date, and the "never invented" deterministic
/// composition.
final class ConversationRecapTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2   // Monday
        return c
    }

    private func day(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)!
    }

    private func convo(_ id: String, _ title: String, _ summary: String, _ at: String) -> RecapConversation {
        RecapConversation(captureId: id, title: title, summary: summary, at: day(at))
    }

    // Scenario: a day with no conversations has no recap
    func testEmptyDayHasNoRecap() async {
        let start = cal.startOfDay(for: day("2026-07-14 09:00"))
        let recap = await ConversationRecapEngine.build(span: .day(start), from: [], calendar: cal)
        XCTAssertNil(recap, "silence is a feature")
    }

    // Scenario: the daily recap covers the day's conversations (count + narrative + insights)
    func testDailyRecapCoversTheDay() async {
        let start = cal.startOfDay(for: day("2026-07-14 00:00"))
        let pool = [
            convo("a", "Standup", "We agreed to ship Friday.", "2026-07-14 09:30"),
            convo("b", "Client call", "Henderson wants the brief by Tuesday.", "2026-07-14 14:00"),
            convo("c", "Dentist", "Rescheduled to next week.", "2026-07-14 17:00"),
            convo("z", "Yesterday", "Not today.", "2026-07-13 10:00"),   // different day
        ]
        let recap = await ConversationRecapEngine.build(span: .day(start), from: pool, calendar: cal)
        let r = try! XCTUnwrap(recap)
        XCTAssertEqual(r.conversationCount, 3, "only today's three")
        XCTAssertTrue(r.narrative.contains("3 conversations today"))
        XCTAssertFalse(r.insights.isEmpty)
        XCTAssertTrue(r.freshnessLine.contains("3 conversations"))
    }

    // Scenario: the daily recap is rebuilt after each new conversation (freshness reflects newest)
    func testDailyRecapRebuildsIncrementally() async {
        let start = cal.startOfDay(for: day("2026-07-14 00:00"))
        var pool = [
            convo("a", "Morning", "First.", "2026-07-14 09:00"),
            convo("b", "Noon", "Second.", "2026-07-14 12:00"),
        ]
        let two = await ConversationRecapEngine.build(span: .day(start), from: pool, calendar: cal)
        XCTAssertEqual(two?.conversationCount, 2)

        pool.append(convo("c", "Evening", "Third.", "2026-07-14 18:30"))
        let three = await ConversationRecapEngine.build(span: .day(start), from: pool, calendar: cal)
        XCTAssertEqual(three?.conversationCount, 3)
        XCTAssertEqual(three?.updatedAt, day("2026-07-14 18:30"), "freshness = newest conversation")
    }

    // Scenario: the weekly recap rolls up the week
    func testWeeklyRecapRollsUpTheWeek() async {
        let weekStart = day("2026-07-13 00:00")   // Monday
        let pool = [
            convo("a", "Mon", "M.", "2026-07-13 10:00"),
            convo("b", "Wed", "W.", "2026-07-15 10:00"),
            convo("c", "Fri", "F.", "2026-07-17 10:00"),
            convo("z", "NextMon", "Next week.", "2026-07-20 10:00"),   // outside the week
        ]
        let recap = await ConversationRecapEngine.build(span: .week(weekStart), from: pool, calendar: cal)
        XCTAssertEqual(recap?.conversationCount, 3, "the week's three, not next week's")
    }

    // Scenario: a week-to-date recap can be requested any time
    func testWeekToDateCoversStartThroughNow() async {
        let weekStart = day("2026-07-13 00:00")
        let asOf = day("2026-07-15 15:00")   // Wednesday afternoon
        let pool = [
            convo("a", "Mon", "M.", "2026-07-13 10:00"),
            convo("b", "WedAM", "W.", "2026-07-15 09:00"),
            convo("c", "WedPMnow", "now.", "2026-07-15 15:00"),   // exactly asOf → included
            convo("d", "Thu", "later this week.", "2026-07-16 10:00"),   // after asOf → excluded
        ]
        let recap = await ConversationRecapEngine.build(
            span: .weekToDate(start: weekStart, asOf: asOf), from: pool, calendar: cal)
        XCTAssertEqual(recap?.conversationCount, 3, "Mon..asOf inclusive, not Thursday")
    }

    // Scenario: insights come from the conversations, never invented
    func testInsightsTraceToRealConversations() async {
        let start = cal.startOfDay(for: day("2026-07-14 00:00"))
        let pool = [
            convo("a", "Client call", "Henderson brief due Tuesday.", "2026-07-14 10:00"),
            convo("b", "Dentist appointment", "Moved to next week.", "2026-07-14 16:00"),
        ]
        guard let r = await ConversationRecapEngine.build(span: .day(start), from: pool, calendar: cal) else {
            return XCTFail("expected a recap")
        }
        XCTAssertTrue(r.insights.contains("Client call"))
        XCTAssertTrue(r.insights.contains("Dentist appointment"))
        // Nothing outside the two subjects.
        for insight in r.insights {
            XCTAssertTrue(insight == "Client call" || insight == "Dentist appointment",
                          "no invented insight: \(insight)")
        }
    }

    // The composer seam replaces the prose when available; count/freshness stay real.
    func testComposerSeamReplacesProse() async {
        struct FixedComposer: RecapComposer {
            var isAvailable: Bool { true }
            func compose(_ c: [RecapConversation], span: RecapSpan) async -> (narrative: String, insights: [String])? {
                ("A warm model narrative.", ["model insight one", "model insight two"])
            }
        }
        let start = cal.startOfDay(for: day("2026-07-14 00:00"))
        let pool = [convo("a", "X", "y.", "2026-07-14 10:00")]
        let r = await ConversationRecapEngine.build(span: .day(start), from: pool,
                                                    composer: FixedComposer(), calendar: cal)
        XCTAssertEqual(r?.narrative, "A warm model narrative.")
        XCTAssertEqual(r?.insights, ["model insight one", "model insight two"])
        XCTAssertEqual(r?.conversationCount, 1, "count is always real, model or not")
    }
}

