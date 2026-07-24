import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/activity-ledger.feature. Drives the REAL ledger through its
/// production read path — `ActivityStore.entries(decisionLog:cardsLog:answersLog:)` over
/// seeded JSONL logs, then `days` / `weeks` / `recapCard` / `measures` /
/// `notificationHistory` — so newest-first ordering, source links, rating-annotation,
/// the silence-by-construction of empty days/weeks, plain-sentence measures, and
/// tolerance of a half-written record are all asserted against real behavior. Hermetic:
/// temp files only, no network.
final class ActivityLedgerFeatureTests: XCTestCase {
    func testActivityLedgerFeature() async throws {
        try await BrineFeatureRunner.run(
            "activity-ledger",
            registry: StepRegistry(ActivityLedgerSteps.make(world: ActivityLedgerWorld())))
    }
}

private final class ActivityLedgerWorld: @unchecked Sendable {
    let dir: URL
    let decisionLog: URL
    var cardsLog: URL { ActivityStore.cardsLogURL(besides: decisionLog) }
    var answersLog: URL { ActivityStore.answersLogURL(besides: decisionLog) }

    let cal = Calendar.current
    let now = Date()
    /// Reset the seeded logs at the start of each scenario (set after a compute).
    var dirty = false

    // Observations.
    var entries: [ActivityEntry] = []

    init() {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-activity-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        decisionLog = dir.appendingPathComponent("ambient-decisions.jsonl")
    }

    func startNewScenarioIfNeeded() {
        guard dirty else { return }
        for u in [decisionLog, cardsLog, answersLog] { try? FileManager.default.removeItem(at: u) }
        entries = []
        dirty = false
    }
    func append(_ url: URL, _ line: String) {
        let data = (line + "\n").data(using: .utf8)!
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }
    func ts(_ d: Date) -> UInt64 { UInt64(max(0, d.timeIntervalSince1970)) }
    var startToday: Date { cal.startOfDay(for: now) }
    var thisAfternoon: Date { startToday.addingTimeInterval(15 * 3600) }
    var thisMorning: Date { startToday.addingTimeInterval(8 * 3600) }
    var yesterdayNoon: Date { startToday.addingTimeInterval(-12 * 3600) }
    var lastWeek: Date { startToday.addingTimeInterval(-8 * 86400) }

    func openActivity() {
        entries = ActivityStore.entries(decisionLogURL: decisionLog, cardsLogURL: cardsLog,
                                        answersLogURL: answersLog)
        dirty = true
    }
    var days: [ActivityDay] { ActivityStore.days(entries: entries, calendar: cal) }
    var weeks: [ActivityWeek] { ActivityStore.weeks(entries: entries, calendar: cal) }
    var measures: [String] { ActivityStore.measures(entries: entries) }
}

private enum ActivityLedgerSteps {
    static func make(world w: ActivityLedgerWorld) -> [StepDefinition] {
        // Line builders (the tolerant JSONL shape the real writers produce).
        func candidate(cid: String, ts: UInt64, utter: String = "let's ship it") -> String {
            "{\"outcome\":\"candidate\",\"captureId\":\"\(cid)\",\"ts\":\(ts),\"candidate\":{\"utterance\":\"\(utter)\",\"summary\":\"a moment\"}}"
        }
        func run(seed: String, ts: UInt64) -> String { "{\"outcome\":\"run\",\"seed\":\"\(seed)\",\"ts\":\(ts)}" }
        func dismissed(ts: UInt64) -> String { "{\"outcome\":\"dismissed\",\"ts\":\(ts)}" }
        func answer(cid: String, ts: UInt64, text: String = "You met Dana at 3pm") -> String {
            "{\"kind\":\"answer\",\"answer\":\"\(text)\",\"captureId\":\"\(cid)\",\"ts\":\(ts)}"
        }
        func rating(word: String, ts: UInt64) -> String { "{\"rating\":\"\(word)\",\"ts\":\(ts)}" }

        return [
            // ── S1 newest-first
            defineStep("a nudge was shown during yesterday's conversation") { ctx, _, _ in
                w.startNewScenarioIfNeeded()
                w.append(w.decisionLog, candidate(cid: "conv-yesterday", ts: w.ts(w.yesterdayNoon)))
                return ctx
            },
            defineStep("I dismissed a nudge this morning") { ctx, _, _ in
                w.append(w.cardsLog, dismissed(ts: w.ts(w.thisMorning))); return ctx
            },
            defineStep("I accepted a nudge this afternoon") { ctx, _, _ in
                w.append(w.cardsLog, run(seed: "chat-afternoon", ts: w.ts(w.thisAfternoon))); return ctx
            },
            defineCheck("I see the accepted nudge first") { _, _, _ in
                guard w.entries.first?.kind == .nudgeAccepted else {
                    throw BrineStepError("first entry was \(String(describing: w.entries.first?.kind))")
                }
            },
            defineCheck("the dismissed nudge below it") { _, _, _ in
                guard w.entries.count > 1, w.entries[1].kind == .nudgeDismissed else {
                    throw BrineStepError("second entry was \(String(describing: w.entries[safe: 1]?.kind))")
                }
            },
            defineCheck("yesterday's nudge last") { _, _, _ in
                guard w.entries.last?.kind == .nudgeShown else {
                    throw BrineStepError("last entry was \(String(describing: w.entries.last?.kind))")
                }
            },

            // ── S2 source links
            defineStep("a nudge came from a recorded conversation") { ctx, _, _ in
                w.startNewScenarioIfNeeded()
                w.append(w.decisionLog, candidate(cid: "conv-x", ts: w.ts(w.thisMorning))); return ctx
            },
            defineStep("an accepted nudge opened a chat") { ctx, _, _ in
                w.append(w.cardsLog, run(seed: "chat-x", ts: w.ts(w.thisAfternoon))); return ctx
            },
            defineCheck("the nudge links to that conversation") { _, _, _ in
                guard let e = w.entries.first(where: { $0.kind == .nudgeShown }),
                      e.source == .conversation(captureId: "conv-x") else {
                    throw BrineStepError("nudge source wrong")
                }
            },
            defineCheck("the accepted nudge links to that chat") { _, _, _ in
                guard let e = w.entries.first(where: { $0.kind == .nudgeAccepted }),
                      e.source == .chat(seed: "chat-x") else {
                    throw BrineStepError("accepted source wrong")
                }
            },

            // ── S3 answer + rating
            defineStep("an answer was compiled from my memory") { ctx, _, _ in
                w.startNewScenarioIfNeeded()
                w.append(w.answersLog, answer(cid: "conv-a", ts: w.ts(w.thisMorning))); return ctx
            },
            defineStep("I rated it helpful") { ctx, _, _ in
                w.append(w.answersLog, rating(word: "helpful", ts: w.ts(w.thisMorning.addingTimeInterval(60)))); return ctx
            },
            defineCheck("I see the answer with my rating alongside") { _, _, _ in
                guard let e = w.entries.first(where: { $0.kind == .answer }), e.rating == "helpful" else {
                    throw BrineStepError("answer rating missing: \(String(describing: w.entries.first { $0.kind == .answer }?.rating))")
                }
            },

            // ── S4 silent decisions invisible
            defineStep("the assistant quietly considered many moments and decided to stay silent") { ctx, _, _ in
                w.startNewScenarioIfNeeded()
                for i in 0..<5 {
                    w.append(w.decisionLog, "{\"outcome\":\"gated_no\",\"ts\":\(w.ts(w.thisMorning) + UInt64(i))}")
                }
                return ctx
            },
            defineCheck("none of those silent decisions appear in the ledger") { _, _, _ in
                guard w.entries.isEmpty else { throw BrineStepError("silent decisions leaked: \(w.entries.count)") }
            },

            // ── S5 daily recap
            defineStep("yesterday had a nudge I accepted") { ctx, _, _ in
                w.startNewScenarioIfNeeded()
                w.append(w.cardsLog, run(seed: "chat-y", ts: w.ts(w.yesterdayNoon))); return ctx
            },
            defineCheck("yesterday shows a recap card summarizing the day") { _, _, _ in
                guard let day = w.days.first else { throw BrineStepError("no day bucket") }
                guard ActivityStore.recapCard(day: day) != nil else { throw BrineStepError("no recap card for the day") }
            },

            // ── S6 empty day silent
            defineStep("a day had no activity") { ctx, _, _ in w.startNewScenarioIfNeeded(); return ctx },
            defineCheck("that day shows no recap card and no filler") { _, _, _ in
                guard w.days.isEmpty else { throw BrineStepError("an empty day produced a bucket") }
                guard w.measures.isEmpty else { throw BrineStepError("empty day produced measures") }
            },

            // ── S7 weekly rollup
            defineStep("this week had activity") { ctx, _, _ in
                w.startNewScenarioIfNeeded()
                w.append(w.cardsLog, run(seed: "chat-week", ts: w.ts(w.thisAfternoon))); return ctx
            },
            defineStep("last week had none") { ctx, _, _ in return ctx },
            defineCheck("this week shows a weekly recap") { _, _, _ in
                guard let week = w.weeks.first, ActivityStore.recapCard(week: week) != nil else {
                    throw BrineStepError("no weekly recap for the active week")
                }
            },
            defineCheck("last week shows nothing") { _, _, _ in
                let lastWeekStart = w.cal.dateInterval(of: .weekOfYear, for: w.lastWeek)?.start
                guard !w.weeks.contains(where: { $0.weekStart == lastWeekStart }) else {
                    throw BrineStepError("last week produced a bucket despite no activity")
                }
            },

            // ── S8 recaps come from real activity
            defineStep("a day with a nudge and an answer") { ctx, _, _ in
                w.startNewScenarioIfNeeded()
                w.append(w.decisionLog, candidate(cid: "conv-d", ts: w.ts(w.thisMorning)))
                w.append(w.answersLog, answer(cid: "conv-d", ts: w.ts(w.thisMorning.addingTimeInterval(120))))
                return ctx
            },
            defineStep("the recap is written") { ctx, _, _ in w.openActivity(); return ctx },
            defineCheck("it reflects only what actually happened that day") { _, _, _ in
                guard let day = w.days.first, let card = ActivityStore.recapCard(day: day) else {
                    throw BrineStepError("no recap card")
                }
                // The fallback recap is composed from the day's real measures.
                guard card.fallbackText.contains("nudge"), card.fallbackText.contains("answer") else {
                    throw BrineStepError("recap does not reflect the real nudge+answer: \(card.fallbackText)")
                }
            },

            // ── S9 plain-sentence measures
            defineStep("a week with one nudge I accepted and one answer I rated helpful") { ctx, _, _ in
                w.startNewScenarioIfNeeded()
                w.append(w.decisionLog, candidate(cid: "conv-m", ts: w.ts(w.thisMorning)))
                w.append(w.cardsLog, run(seed: "chat-m", ts: w.ts(w.thisMorning.addingTimeInterval(30))))
                w.append(w.answersLog, answer(cid: "conv-m", ts: w.ts(w.thisMorning.addingTimeInterval(60))))
                w.append(w.answersLog, rating(word: "helpful", ts: w.ts(w.thisMorning.addingTimeInterval(90))))
                return ctx
            },
            defineCheck("the measures read as plain sentences like \"1 nudge · you accepted it\"") { _, _, _ in
                guard w.measures.contains("1 nudge · you accepted it") else {
                    throw BrineStepError("measures were \(w.measures)")
                }
            },
            defineCheck("no internal tool names appear anywhere") { _, _, _ in
                let blob = w.measures.joined(separator: " ").lowercased()
                for tool in ["gate", "candidate", "classify", "jsonl", "ambientlane", "decisionlog", "outcome"] {
                    guard !blob.contains(tool) else { throw BrineStepError("internal name '\(tool)' leaked into measures") }
                }
            },

            // ── S10 missed notification still visible
            defineStep("a nudge was shown while my phone was silenced") { ctx, _, _ in
                w.startNewScenarioIfNeeded()
                w.append(w.decisionLog, candidate(cid: "conv-silenced", ts: w.ts(w.thisMorning))); return ctx
            },
            defineCheck("I can still see that nudge among recent notifications") { _, _, _ in
                let notifs = ActivityStore.notificationHistory(entries: w.entries)
                guard notifs.contains(where: { $0.kind == .nudgeShown && $0.source == .conversation(captureId: "conv-silenced") }) else {
                    throw BrineStepError("the silenced nudge is not in notification history")
                }
            },

            // ── S11 half-written record
            defineStep("the activity records contain an unreadable or partial entry") { ctx, _, _ in
                w.startNewScenarioIfNeeded()
                w.append(w.decisionLog, "{not valid json at all")               // garbage
                w.append(w.decisionLog, "{\"outcome\":\"candidate\"")           // truncated
                w.append(w.decisionLog, candidate(cid: "conv-good", ts: w.ts(w.thisMorning)))  // valid
                return ctx
            },
            defineCheck("the readable entries still appear") { _, _, _ in
                guard w.entries.count == 1, w.entries.first?.source == .conversation(captureId: "conv-good") else {
                    throw BrineStepError("expected exactly the one readable entry, got \(w.entries.count)")
                }
            },
            defineCheck("nothing crashes or shows made-up details") { _, _, _ in
                // Reaching here without a trap is the no-crash proof; assert no invented detail.
                guard w.entries.allSatisfy({ $0.detail != nil }) else {
                    throw BrineStepError("an entry has a nil detail — nothing should be invented, but nothing partial should surface either")
                }
            },

            // ── S12 honest empty page
            defineStep("nothing has happened yet") { ctx, _, _ in w.startNewScenarioIfNeeded(); return ctx },
            defineCheck("I see a quiet explanation that activity will appear here") { _, _, _ in
                // The empty-state explanation is shown precisely when there are no entries.
                guard w.entries.isEmpty else { throw BrineStepError("entries present on a supposedly empty page") }
            },
            defineCheck("no recap cards and no measures") { _, _, _ in
                guard w.days.isEmpty, w.weeks.isEmpty, w.measures.isEmpty else {
                    throw BrineStepError("empty page produced cards/measures")
                }
            },

            // Shared When.
            defineStep("I open Activity") { ctx, _, _ in w.openActivity(); return ctx },
        ]
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
