import XCTest
import Foundation
import FoundryXKit

/// Activity: ledger, recaps, personal measures (features/activity-ledger.feature,
/// track 20260713T0905). ActivityStore reads the intelligence agent's JSONL logs
/// READ-ONLY — the ambient decision log (ambient-decisions.jsonl) and the card
/// outcome log (ambient-cards.jsonl) — and aggregates them into ledger entries,
/// day/week buckets, recap cards, and plain-sentence measures. It tolerates
/// missing files, partial lines, and unknown shapes without crashing or inventing.
final class ActivityLedgerTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private var decisionsURL: URL { dir.appendingPathComponent("ambient-decisions.jsonl") }
    private var cardsURL: URL { dir.appendingPathComponent("ambient-cards.jsonl") }

    private func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// A decision-log line as AmbientLane actually writes it (outcome=candidate).
    private func candidateLine(ts: UInt64, captureId: String = "c1",
                               utterance: String = "I'll have to look that up",
                               summary: String = "look it up") -> String {
        """
        {"ts":\(ts),"captureId":"\(captureId)","windowChars":40,"outcome":"candidate","candidate":{"utterance":"\(utterance)","summary":"\(summary)","confidence":0.8},"latencyMs":12}
        """
    }

    /// A card-outcome line as AmbientCardBroker actually writes it.
    private func cardLine(ts: UInt64, outcome: String, seed: String = "Please help") -> String {
        """
        {"ts":\(ts),"outcome":"\(outcome)","seed":"\(seed)"}
        """
    }

    private func entries() -> [ActivityEntry] {
        ActivityStore.entries(decisionLogURL: decisionsURL, cardsLogURL: cardsURL)
    }

    // MARK: - The ledger

    // Scenario: the ledger lists what happened, newest first
    func testLedgerListsEventsNewestFirst() throws {
        try write([candidateLine(ts: 100)], to: decisionsURL)
        try write([cardLine(ts: 150, outcome: "dismissed"),
                   cardLine(ts: 200, outcome: "run")], to: cardsURL)

        let all = entries()
        XCTAssertEqual(all.map(\.kind), [.nudgeAccepted, .nudgeDismissed, .nudgeShown])
        XCTAssertEqual(all.map(\.ts), [200, 150, 100], "newest first")
    }

    // Scenario: each entry links to its source
    func testEntriesLinkToTheirSource() throws {
        try write([candidateLine(ts: 100, captureId: "conv-42")], to: decisionsURL)
        try write([cardLine(ts: 200, outcome: "run", seed: "Please look into the relay")],
                  to: cardsURL)

        let all = entries()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].source, .chat(seed: "Please look into the relay"),
                       "an accepted nudge links to the chat it opened")
        XCTAssertEqual(all[1].source, .conversation(captureId: "conv-42"),
                       "a shown nudge links to its conversation")
    }

    // Scenario: an answer shows my own rating
    func testAnswerCarriesTheUsersRating() throws {
        // A richer line another writer may append: tolerated, surfaced honestly.
        try write([
            """
            {"ts":300,"captureId":"c7","kind":"answer","answer":"You decided to keep the relay blind.","rating":"helpful"}
            """,
        ], to: decisionsURL)

        let all = entries()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].kind, .answer)
        XCTAssertEqual(all[0].detail, "You decided to keep the relay blind.")
        XCTAssertEqual(all[0].rating, "helpful")
    }

    // An answer nobody rated renders without one — never an invented rating.
    func testUnratedAnswerHasNoRating() throws {
        try write([
            """
            {"ts":300,"kind":"answer","answer":"The meeting moved to Tuesday."}
            """,
        ], to: decisionsURL)

        let all = entries()
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(all[0].rating)
    }

    // Scenario: routine internal decisions stay invisible
    func testGatedNoAndSkippedLinesStayInvisible() throws {
        try write([
            """
            {"ts":10,"captureId":"c1","windowChars":40,"outcome":"gated_no","latencyMs":3}
            """,
            """
            {"ts":11,"captureId":"c1","windowChars":40,"outcome":"skipped","skipReason":"gate_unavailable","latencyMs":0}
            """,
            candidateLine(ts: 12),
        ], to: decisionsURL)

        let all = entries()
        XCTAssertEqual(all.map(\.kind), [.nudgeShown], "only the surfaced nudge is user-visible")
    }

    // A suppressed owner-unverified card was never shown to the user — showing it
    // as "you dismissed" would be a lie, so it stays invisible.
    func testOwnerUnverifiedSuppressionsStayInvisible() throws {
        try write([cardLine(ts: 50, outcome: "dismissed",
                            seed: "owner-unverified: turn off the lights")], to: cardsURL)
        XCTAssertTrue(entries().isEmpty)
    }

    // Scenario: a half-written record never breaks the page
    func testUnknownOrPartialLinesNeverCrash() throws {
        try write([
            "this is not json at all",
            "",
            "{\"ts\":5}",
            "{\"ts\":6,\"outcome\":\"some_future_outcome\"}",
            "{\"ts\":7,\"outcome\":\"candidate\"}",
            candidateLine(ts: 90),
        ], to: decisionsURL)
        try write(["{\"broken", cardLine(ts: 95, outcome: "run")], to: cardsURL)

        let all = entries()
        XCTAssertEqual(all.map(\.kind), [.nudgeAccepted, .nudgeShown, .nudgeShown],
                       "readable entries survive; unreadable ones are skipped, not invented")
        // The bare candidate line (no payload, no captureId) still appears — honestly,
        // with no detail and no link, never with made-up ones.
        let bare = all[2]
        XCTAssertNil(bare.detail)
        XCTAssertEqual(bare.source, .none)
    }

    // Scenario: no activity at all is an honest empty page
    func testMissingLogsMeanAnEmptyLedger() {
        XCTAssertTrue(entries().isEmpty)
        XCTAssertTrue(ActivityStore.days(entries: []).isEmpty)
        XCTAssertTrue(ActivityStore.weeks(entries: []).isEmpty)
        XCTAssertTrue(ActivityStore.measures(entries: []).isEmpty)
    }

    // MARK: - Recaps

    private func ts(daysAgo: Int, calendar: Calendar = .current) -> UInt64 {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
        return UInt64(calendar.startOfDay(for: day).timeIntervalSince1970) + 3600
    }

    // Scenario: a day with activity gets a daily recap
    // Scenario: an empty day stays silent
    func testDailyRecapOnlyWhenTheDayHasContent() throws {
        try write([candidateLine(ts: ts(daysAgo: 1))], to: decisionsURL)

        let days = ActivityStore.days(entries: entries())
        XCTAssertEqual(days.count, 1, "only days WITH activity exist — silence is a feature")
        XCTAssertNotNil(ActivityStore.recapCard(day: days[0]))
        // No entries → no day bucket → no card, ever.
        XCTAssertTrue(ActivityStore.days(entries: []).isEmpty)
    }

    // Scenario: the week rolls up only when there is something to say
    func testWeeklyRecapSameHonesty() throws {
        try write([candidateLine(ts: ts(daysAgo: 0))], to: decisionsURL)

        let weeks = ActivityStore.weeks(entries: entries())
        XCTAssertEqual(weeks.count, 1, "only weeks with activity produce a card")
        XCTAssertNotNil(ActivityStore.recapCard(week: weeks[0]))
        XCTAssertTrue(ActivityStore.weeks(entries: []).isEmpty)
    }

    // Scenario: recaps come from my own activity
    func testRecapUsesTheSynthesizerSeam() async throws {
        try write([candidateLine(ts: ts(daysAgo: 0))], to: decisionsURL)
        try write([cardLine(ts: ts(daysAgo: 0) + 60, outcome: "run")], to: cardsURL)

        let days = ActivityStore.days(entries: entries())
        let card = try XCTUnwrap(ActivityStore.recapCard(day: days[0]))

        // The deterministic fallback reflects only what actually happened.
        XCTAssertTrue(card.fallbackText.contains("1 nudge"), card.fallbackText)

        // The model seam: a synthesizer receives the day's real entries.
        let double = FixedRecapSynthesizer(text: "You caught one loose end today.")
        let text = try await double.recap(entries: days[0].entries, period: card.period)
        XCTAssertEqual(text, "You caught one loose end today.")
        XCTAssertEqual(double.seen.count, days[0].entries.count,
                       "the synthesizer sees exactly the day's entries, nothing else")
    }

    // MARK: - Measures

    // Scenario: measures are plain sentences
    func testMeasuresArePlainSentences() throws {
        try write([
            candidateLine(ts: 100),
            """
            {"ts":110,"kind":"answer","answer":"Tuesday.","rating":"helpful"}
            """,
        ], to: decisionsURL)
        try write([cardLine(ts: 120, outcome: "run")], to: cardsURL)

        let sentences = ActivityStore.measures(entries: entries())
        XCTAssertEqual(sentences, [
            "1 nudge · you accepted it",
            "1 answer from your memory · you rated it helpful",
        ])
        for s in sentences {
            XCTAssertFalse(s.lowercased().contains("temper"), "internal tool names never leak")
        }
    }

    func testMeasuresCountPlurally() throws {
        try write([candidateLine(ts: 100), candidateLine(ts: 101), candidateLine(ts: 102)],
                  to: decisionsURL)
        try write([cardLine(ts: 103, outcome: "run"),
                   cardLine(ts: 104, outcome: "dismissed")], to: cardsURL)

        XCTAssertEqual(ActivityStore.measures(entries: entries()),
                       ["3 nudges · you accepted 1 · you dismissed 1"])
    }

    // MARK: - Notifications history

    // Scenario: a missed notification is still visible
    func testNotificationHistoryShowsRecentNudgesAndAnswers() throws {
        try write([
            candidateLine(ts: 100),
            """
            {"ts":110,"kind":"answer","answer":"Tuesday."}
            """,
        ], to: decisionsURL)
        try write([cardLine(ts: 120, outcome: "dismissed")], to: cardsURL)

        let history = ActivityStore.notificationHistory(entries: entries(), limit: 10)
        XCTAssertEqual(history.map(\.kind), [.answer, .nudgeShown],
                       "notification-worthy events only, newest first — visible even if the banner was missed")
    }
}

/// Deterministic RecapSynthesizer double: returns a fixed text and records what
/// it was shown (so tests can pin the seam's contract).
private final class FixedRecapSynthesizer: RecapSynthesizer, @unchecked Sendable {
    let text: String
    private(set) var seen: [ActivityEntry] = []

    init(text: String) { self.text = text }

    var isAvailable: Bool { true }

    func recap(entries: [ActivityEntry], period: RecapPeriod) async throws -> String {
        seen = entries
        return text
    }
}
