import XCTest
import Foundation
import Combine
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
        XCTAssertTrue(r.freshnessLine().contains("3 conversations"))
        // Daily freshness advertises that the recap grows through the day.
        XCTAssertTrue(r.freshnessLine().hasPrefix("Grows after each processed conversation"))
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
        let sources = r.insights.map(\.sourceTitle)
        XCTAssertTrue(sources.contains("Client call"))
        XCTAssertTrue(sources.contains("Dentist appointment"))
        // Every insight traces to one of the two real conversations — never invented.
        for insight in r.insights {
            XCTAssertTrue(insight.sourceTitle == "Client call" || insight.sourceTitle == "Dentist appointment",
                          "no invented insight source: \(insight.sourceTitle)")
        }
    }

    // Scenario: every insight carries a type and its source conversation
    func testEveryInsightIsTypedAndAttributed() async {
        let start = cal.startOfDay(for: day("2026-07-14 00:00"))
        let pool = [
            convo("a", "Standup", "We agreed to ship Friday.", "2026-07-14 09:30"),
            convo("b", "Client call", "Henderson wants the brief by Tuesday.", "2026-07-14 14:00"),
            convo("c", "Dentist", "Rescheduled to next week.", "2026-07-14 17:00"),
        ]
        guard let r = await ConversationRecapEngine.build(span: .day(start), from: pool, calendar: cal) else {
            return XCTFail("expected a recap")
        }
        XCTAssertFalse(r.insights.isEmpty)
        let allowed = Set(RecapInsight.Kind.allCases)
        let titles = Set(pool.map(\.title))
        for insight in r.insights {
            XCTAssertTrue(allowed.contains(insight.kind), "typed from the fixed set")
            XCTAssertFalse(insight.text.isEmpty, "prose is non-empty")
            XCTAssertTrue(titles.contains(insight.sourceTitle), "attributed to a real conversation")
            XCTAssertTrue(insight.provenance.hasPrefix("from "), "provenance names the source")
        }
    }

    // The deterministic labeler classifies the prototype's own insight lines (pure heuristic).
    func testLabelerClassifiesPrototypeInsightLines() {
        let day = RecapSpan.day(Date())
        let week = RecapSpan.week(Date())
        func kind(_ t: String, _ span: RecapSpan = .day(Date())) -> RecapInsight.Kind {
            ConversationRecapEngine.label(forText: t, source: nil, span: span)
        }
        XCTAssertEqual(kind("Keep the blind Noise relay for the launch."), .decision)
        XCTAssertEqual(kind("Send the template, add Mom's appointment, and hold Thursday evening."), .followUp)
        XCTAssertEqual(kind("The relay call already answers the appendix questions raised this morning."), .connection)
        XCTAssertEqual(kind("Sarah owns the appendix; Dana is coordinating the weekend."), .people)
        XCTAssertEqual(kind("Privacy came up in five conversations, more than any other theme.", week), .trend)
        _ = day
    }

    // Scenario: selecting a period shows exactly one recap card (eyebrow + heading)
    func testPresentationEyebrowAndHeading() async {
        let start = cal.startOfDay(for: day("2026-07-14 00:00"))
        let weekStart = day("2026-07-13 00:00")
        let pool = [convo("a", "Standup", "We agreed to ship Friday.", "2026-07-14 10:00")]
        let daily = await ConversationRecapEngine.build(span: .day(start), from: pool, calendar: cal)
        let weekly = await ConversationRecapEngine.build(span: .week(weekStart), from: pool, calendar: cal)
        let dp = ActivityRecapPresentation.make(from: try! XCTUnwrap(daily))
        let wp = ActivityRecapPresentation.make(from: try! XCTUnwrap(weekly))
        XCTAssertEqual(dp.eyebrow, "Daily recap")
        XCTAssertEqual(dp.heading, "Today")
        XCTAssertFalse(dp.showsUpdateWeekToDate)
        XCTAssertEqual(wp.eyebrow, "Weekly recap")
        XCTAssertEqual(wp.heading, "This week")
        XCTAssertTrue(wp.showsUpdateWeekToDate)
    }

    // Scenario: the weekly recap updates at week end (close copy + distinct ad-hoc action)
    func testWeeklyCardStatesCloseAndOffersUpdate() async {
        let weekStart = day("2026-07-13 00:00")
        let pool = [
            convo("a", "Mon", "M.", "2026-07-13 10:00"),
            convo("b", "Wed", "W.", "2026-07-15 10:00"),
        ]
        let weekly = await ConversationRecapEngine.build(span: .week(weekStart), from: pool, calendar: cal)
        let p = ActivityRecapPresentation.make(from: try! XCTUnwrap(weekly))
        XCTAssertTrue(p.freshnessLine.contains("Final weekly recap closes Sunday."))
        XCTAssertTrue(p.showsUpdateWeekToDate, "the update-week-to-date action is distinct from the close")
    }

    // Scenario: I can ask for a week-to-date update (freshness flips to updated just now)
    func testWeekToDateUpdateFlipsFreshness() async {
        let weekStart = day("2026-07-13 00:00")
        let asOf = day("2026-07-15 15:00")
        let pool = [convo("a", "Mon", "M.", "2026-07-13 10:00"),
                    convo("b", "Wed", "W.", "2026-07-15 10:00")]
        let wtd = await ConversationRecapEngine.build(
            span: .weekToDate(start: weekStart, asOf: asOf), from: pool, calendar: cal)
        let updated = ActivityRecapPresentation.make(from: try! XCTUnwrap(wtd), weekUpdated: true)
        XCTAssertTrue(updated.freshnessLine.contains("Week to date updated just now"))
        XCTAssertTrue(updated.freshnessLine.contains("Final weekly recap closes Sunday."))
    }

    // Scenario: the daily recap rebuilds when a conversation finishes processing
    @MainActor
    func testDailyRebuildsOnConversationFinishedNotification() async {
        // A pool the model reads live; appending simulates a new finished conversation.
        var pool = [
            convo("a", "Morning", "First.", "2026-07-14 09:00"),
            convo("b", "Noon", "Second.", "2026-07-14 12:00"),
        ]
        // Use a fixed "now" via a UTC calendar; the model reads Date() for spans, so
        // seed the pool on TODAY's date so the day span captures them.
        let today = Calendar.current.startOfDay(for: Date())
        func at(_ hour: Int, _ id: String, _ title: String) -> RecapConversation {
            RecapConversation(captureId: id, title: title, summary: "\(title) summary.",
                              at: today.addingTimeInterval(TimeInterval(hour * 3600)))
        }
        pool = [at(1, "a", "Morning"), at(2, "b", "Noon")]
        let model = ActivityRecapModel(poolProvider: { pool }, composer: nil)
        await model.rebuildAll()
        XCTAssertEqual(model.daily?.conversationCount, 2)

        // A third conversation finishes; the finished event rebuilds the daily recap live.
        let exp = expectation(description: "daily grows to three on the finished event")
        let cancellable = model.$daily.sink { pres in
            if pres?.conversationCount == 3 { exp.fulfill() }
        }
        pool.append(at(3, "c", "Evening"))
        NotificationCenter.default.post(name: .foundryxConversationFinalized,
                                        object: nil, userInfo: ["captureId": "c"])
        await fulfillment(of: [exp], timeout: 3.0)
        cancellable.cancel()
        XCTAssertEqual(model.daily?.conversationCount, 3, "rebuilt without leaving the screen")
        XCTAssertTrue(model.daily?.freshnessLine.hasPrefix("Grows after each processed conversation") ?? false)
    }

    // T3 AC3/AC4: a pool signature is stable for the same set, order-independent,
    // and changes on any add or content edit.
    func testPoolSignatureStableAndChangeSensitive() {
        let start = cal.startOfDay(for: day("2026-07-14 00:00"))
        let span = RecapSpan.day(start)
        let a = convo("a", "One", "first.", "2026-07-14 09:00")
        let b = convo("b", "Two", "second.", "2026-07-14 12:00")
        let s1 = ConversationRecapEngine.poolSignature(for: span, from: [a, b], calendar: cal)
        let s2 = ConversationRecapEngine.poolSignature(for: span, from: [b, a], calendar: cal)
        XCTAssertEqual(s1, s2, "same set ⇒ same signature regardless of input order")
        let c = convo("c", "Three", "third.", "2026-07-14 15:00")
        XCTAssertNotEqual(
            s1, ConversationRecapEngine.poolSignature(for: span, from: [a, b, c], calendar: cal),
            "an added conversation changes the signature")
        let bEdited = convo("b", "Two", "second, edited.", "2026-07-14 12:00")
        XCTAssertNotEqual(
            s1, ConversationRecapEngine.poolSignature(for: span, from: [a, bEdited], calendar: cal),
            "an edited summary changes the signature")
    }

    // T3 AC3/AC4: recaps persist to a cache and render instantly on the next visit;
    // inference re-runs only when the conversation set changed.
    @MainActor
    func testRecapCachePersistsRendersInstantlyAndGatesInference() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recap-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let today = Calendar.current.startOfDay(for: Date())
        func at(_ hour: Int, _ id: String, _ title: String) -> RecapConversation {
            RecapConversation(captureId: id, title: title, summary: "\(title) summary.",
                              at: today.addingTimeInterval(TimeInterval(hour * 3600 + 3600)))
        }
        let pool = [at(1, "a", "Morning"), at(2, "b", "Noon")]

        // Cold cache: the first model builds and persists.
        let composer1 = CountingComposer()
        let model1 = ActivityRecapModel(poolProvider: { pool }, composer: composer1,
                                        cacheBaseDir: dir, observesFinalized: false)
        XCTAssertNil(model1.daily, "cold cache: nothing to render yet")
        await model1.rebuildAll()
        XCTAssertEqual(model1.daily?.conversationCount, 2)
        XCTAssertGreaterThan(composer1.calls, 0, "cold build runs inference")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: RecapCacheStore.fileURL(baseDir: dir).path), "cache file written")

        // AC3: a second model over the SAME pool renders instantly from cache in
        // init — before any rebuild. AC4: rebuild does NOT re-run inference.
        let composer2 = CountingComposer()
        let model2 = ActivityRecapModel(poolProvider: { pool }, composer: composer2,
                                        cacheBaseDir: dir, observesFinalized: false)
        XCTAssertEqual(model2.daily?.conversationCount, 2, "AC3: daily instant from cache")
        XCTAssertEqual(model2.weekly?.conversationCount, 2, "AC3: weekly instant from cache")
        await model2.rebuildAll()
        XCTAssertEqual(composer2.calls, 0, "AC4: unchanged set does not re-run inference")

        // AC4: a changed set refreshes — inference re-runs and the count grows.
        let grownPool = pool + [at(3, "c", "Evening")]
        let composer3 = CountingComposer()
        let model3 = ActivityRecapModel(poolProvider: { grownPool }, composer: composer3,
                                        cacheBaseDir: dir, observesFinalized: false)
        await model3.rebuildAll()
        XCTAssertGreaterThan(composer3.calls, 0, "AC4: a changed set refreshes")
        XCTAssertEqual(model3.daily?.conversationCount, 3)
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
        // The composer's PROSE is preserved; the engine adds the type + provenance.
        XCTAssertEqual(r?.insights.map(\.text), ["model insight one", "model insight two"])
        XCTAssertEqual(r?.insights.allSatisfy { $0.sourceTitle == "X" }, true, "attributed to the real convo")
        XCTAssertEqual(r?.conversationCount, 1, "count is always real, model or not")
    }
}

/// A composer that always answers and counts how many times it was invoked —
/// so a test can assert inference re-runs only when the pool changed (AC4).
private final class CountingComposer: RecapComposer, @unchecked Sendable {
    /// Invocations are serial in these tests (each rebuild is awaited before the
    /// next), so a plain counter is sufficient.
    private(set) var calls = 0
    var isAvailable: Bool { true }
    func compose(_ conversations: [RecapConversation], span: RecapSpan)
        async -> (narrative: String, insights: [String])? {
        calls += 1
        return ("A model narrative.", ["model insight"])
    }
}

