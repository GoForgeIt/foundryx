import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/conversation-recaps.feature. Drives the REAL recap engine —
/// `ConversationRecapEngine.build` over a `RecapConversation` pool, `ConversationRecap`
/// (count / narrative / typed+attributed insights / freshness), and
/// `ActivityRecapPresentation.make` (daily vs weekly eyebrow/heading, the "closes Sunday"
/// weekly line + update-week-to-date). No period without conversations gets a recap;
/// insights come only from what was said. Hermetic: an in-memory pool, no network.
final class ConversationRecapsFeatureTests: XCTestCase {
    func testConversationRecapsFeature() async throws {
        try await BrineFeatureRunner.run(
            "conversation-recaps",
            registry: StepRegistry(ConversationRecapsSteps.make(world: ConversationRecapsWorld())))
    }
}

private final class ConversationRecapsWorld: @unchecked Sendable {
    let cal = Calendar.current
    let now = Date()
    var pool: [RecapConversation] = []
    var recap: ConversationRecap?
    var presentation: ActivityRecapPresentation?

    var startToday: Date { cal.startOfDay(for: now) }
    var weekStart: Date { cal.dateInterval(of: .weekOfYear, for: now)?.start ?? startToday }
    var daySpan: RecapSpan { .day(startToday) }
    var weekSpan: RecapSpan { .week(weekStart) }
    var wtdSpan: RecapSpan { .weekToDate(start: weekStart, asOf: now) }

    func convo(_ id: String, _ title: String, _ summary: String, at: Date) -> RecapConversation {
        RecapConversation(captureId: id, title: title, summary: summary, at: at)
    }
    func buildDaily() async { recap = await ConversationRecapEngine.build(span: daySpan, from: pool, calendar: cal) }
    func buildWeekly() async {
        recap = await ConversationRecapEngine.build(span: weekSpan, from: pool, calendar: cal)
        presentation = recap.map { ActivityRecapPresentation.make(from: $0) }
    }
    func buildWeekToDate(updated: Bool = false) async {
        recap = await ConversationRecapEngine.build(span: wtdSpan, from: pool, calendar: cal)
        presentation = recap.map { ActivityRecapPresentation.make(from: $0, weekUpdated: updated) }
    }
}

private enum ConversationRecapsSteps {
    static func make(world w: ConversationRecapsWorld) -> [StepDefinition] {
        [
            // ── S1 no conversations, no recap
            defineStep("no conversations today") { ctx, _, _ in w.pool = []; return ctx },
            defineCheck("there is no daily recap") { _, _, _ in
                let r = await ConversationRecapEngine.build(span: w.daySpan, from: w.pool, calendar: w.cal)
                guard r == nil else { throw BrineStepError("an empty day produced a recap") }
            },

            // ── S2 daily recap covers the day (also reused by S6/S7)
            defineStep("three conversations finished processing today") { ctx, _, _ in
                w.pool = [
                    w.convo("c1", "Client call with Henderson", "We agreed on the Q3 scope.", at: w.startToday.addingTimeInterval(3600)),
                    w.convo("c2", "Dentist appointment", "Booked a cleaning for Thursday.", at: w.startToday.addingTimeInterval(7200)),
                    w.convo("c3", "Grocery list", "Milk, eggs, and bread.", at: w.startToday.addingTimeInterval(9000)),
                ]
                return ctx
            },
            defineStep("the daily recap is built") { ctx, _, _ in await w.buildDaily(); return ctx },
            defineCheck("it names how many conversations it covers") { _, _, _ in
                guard w.recap?.conversationCount == 3 else { throw BrineStepError("count was \(String(describing: w.recap?.conversationCount))") }
            },
            defineCheck("it has a narrative summary and insights") { _, _, _ in
                guard let r = w.recap, !r.narrative.isEmpty, !r.insights.isEmpty else {
                    throw BrineStepError("recap missing narrative/insights")
                }
            },

            // ── S3 rebuilt after each new conversation (also S8)
            defineStep("a daily recap covering two conversations") { ctx, _, _ in
                w.pool = [
                    w.convo("c1", "Morning standup", "Sprint plan for the week.", at: w.startToday.addingTimeInterval(3600)),
                    w.convo("c2", "Lunch with Dana", "Talked through the relay design.", at: w.startToday.addingTimeInterval(7200)),
                ]
                await w.buildDaily()
                guard w.recap?.conversationCount == 2 else { return ctx }
                return ctx
            },
            defineStep("a third conversation finishes processing") { ctx, _, _ in
                w.pool.append(w.convo("c3", "Design review", "Signed off on the card layout.", at: w.startToday.addingTimeInterval(10800)))
                await w.buildDaily()
                return ctx
            },
            defineCheck("the daily recap covers three conversations") { _, _, _ in
                guard w.recap?.conversationCount == 3 else { throw BrineStepError("count was \(String(describing: w.recap?.conversationCount))") }
            },
            defineCheck("its freshness reflects the newest conversation") { _, _, _ in
                guard let r = w.recap else { throw BrineStepError("no recap") }
                guard r.updatedAt == w.pool.map(\.at).max() else { throw BrineStepError("freshness is not the newest conversation") }
            },

            // ── S8 rebuild on a finished event + growing freshness line
            defineStep("a conversation finishes processing and a finished event is posted") { ctx, _, _ in
                w.pool.append(w.convo("c3", "Design review", "Signed off on the card layout.", at: w.startToday.addingTimeInterval(10800)))
                await w.buildDaily()
                return ctx
            },
            defineCheck("the daily recap covers three conversations without leaving the screen") { _, _, _ in
                guard w.recap?.conversationCount == 3 else { throw BrineStepError("count was \(String(describing: w.recap?.conversationCount))") }
            },
            defineCheck("its freshness line grows after each processed conversation") { _, _, _ in
                guard let line = w.recap?.freshnessLine(), line.contains("3 conversations") else {
                    throw BrineStepError("freshness line did not grow to 3: \(String(describing: w.recap?.freshnessLine()))")
                }
            },

            // ── S4 weekly rolls up the week (also S9)
            defineStep("conversations across several days this week") { ctx, _, _ in
                w.pool = [
                    w.convo("w1", "Kickoff", "Set the sprint goals.", at: w.weekStart.addingTimeInterval(3600)),
                    w.convo("w2", "Midweek sync", "Unblocked the relay work.", at: w.weekStart.addingTimeInterval(2 * 86400 + 3600)),
                    w.convo("w3", "Today's review", "Shipped the recap card.", at: w.now),
                ]
                return ctx
            },
            defineStep("the weekly recap is built") { ctx, _, _ in await w.buildWeekly(); return ctx },
            defineCheck("it covers all of the week's conversations") { _, _, _ in
                guard w.recap?.conversationCount == 3 else { throw BrineStepError("weekly count was \(String(describing: w.recap?.conversationCount))") }
            },

            // ── S5 week-to-date any time
            defineStep("conversations earlier this week and today") { ctx, _, _ in
                w.pool = [
                    w.convo("e1", "Monday plan", "Mapped the week.", at: w.weekStart.addingTimeInterval(3600)),
                    w.convo("e2", "Today", "A conversation just now.", at: w.now),
                ]
                return ctx
            },
            defineStep("a week-to-date recap is requested mid-week") { ctx, _, _ in await w.buildWeekToDate(); return ctx },
            defineCheck("it covers everything from the week's start through now") { _, _, _ in
                guard w.recap?.conversationCount == 2 else { throw BrineStepError("wtd count was \(String(describing: w.recap?.conversationCount))") }
            },

            // ── S6 insights come from the conversations
            defineStep("conversations about a client call and a dentist appointment") { ctx, _, _ in
                w.pool = [
                    w.convo("cc", "Client call with Henderson", "Agreed the Q3 scope on the client call.", at: w.startToday.addingTimeInterval(3600)),
                    w.convo("dd", "Dentist appointment", "Booked the dentist for Thursday.", at: w.startToday.addingTimeInterval(7200)),
                ]
                return ctx
            },
            defineCheck("the insights mention the client call and the dentist appointment") { _, _, _ in
                guard let r = w.recap else { throw BrineStepError("no recap") }
                let blob = (r.insights.map(\.text) + r.insights.map(\.sourceTitle) + [r.narrative]).joined(separator: " ").lowercased()
                guard blob.contains("client call"), blob.contains("dentist") else {
                    throw BrineStepError("insights don't mention both topics: \(r.insights.map(\.text))")
                }
            },
            defineCheck("no insight references a topic that was not discussed") { _, _, _ in
                guard let r = w.recap else { throw BrineStepError("no recap") }
                let titles = Set(w.pool.map { $0.title })
                // Deterministic insights are drawn from the real conversation subjects — each
                // insight's text is one of the discussed titles, attributed to its source.
                for ins in r.insights {
                    guard titles.contains(ins.text) else { throw BrineStepError("invented insight: \(ins.text)") }
                    guard titles.contains(ins.sourceTitle) else { throw BrineStepError("insight source not a real conversation: \(ins.sourceTitle)") }
                }
            },

            // ── S7 every insight typed + attributed
            defineCheck("every insight is labelled with one of the recap insight types") { _, _, _ in
                guard let r = w.recap, !r.insights.isEmpty else { throw BrineStepError("no insights") }
                let kinds = Set(RecapInsight.Kind.allCases)
                for ins in r.insights where !kinds.contains(ins.kind) {
                    throw BrineStepError("insight has an unknown type: \(ins.kind)")
                }
            },
            defineCheck("every insight names the conversation it came from") { _, _, _ in
                guard let r = w.recap else { throw BrineStepError("no recap") }
                for ins in r.insights where ins.sourceTitle.isEmpty {
                    throw BrineStepError("an insight has no source conversation")
                }
            },

            // ── S9 weekly updates at week end
            defineCheck("the weekly card says the final weekly recap closes Sunday") { _, _, _ in
                guard let p = w.presentation, p.freshnessLine.contains("closes Sunday") else {
                    throw BrineStepError("weekly freshness missing 'closes Sunday': \(String(describing: w.presentation?.freshnessLine))")
                }
            },
            defineCheck("the weekly card offers an update-week-to-date action") { _, _, _ in
                guard w.presentation?.showsUpdateWeekToDate == true else {
                    throw BrineStepError("weekly card does not offer update-week-to-date")
                }
            },

            // ── S10 request an update week to date
            defineStep("I request an update week to date on the weekly card") { ctx, _, _ in
                await w.buildWeekToDate(updated: true); return ctx
            },
            defineCheck("the weekly freshness line reads that the week to date was updated just now") { _, _, _ in
                guard let p = w.presentation, p.freshnessLine.contains("updated just now") else {
                    throw BrineStepError("wtd freshness was \(String(describing: w.presentation?.freshnessLine))")
                }
            },

            // ── S11 one card per period
            defineStep("a daily recap and a weekly recap both exist") { ctx, _, _ in
                w.pool = [
                    w.convo("d1", "Today one", "A daily conversation.", at: w.startToday.addingTimeInterval(3600)),
                    w.convo("wk", "Earlier this week", "A weekly conversation.", at: w.weekStart.addingTimeInterval(3600)),
                ]
                return ctx
            },
            defineCheck("the daily card shows a \"Daily recap\" eyebrow with a \"Today\" heading") { _, _, _ in
                let r = await ConversationRecapEngine.build(span: w.daySpan, from: w.pool, calendar: w.cal)
                guard let recap = r else { throw BrineStepError("no daily recap") }
                let p = ActivityRecapPresentation.make(from: recap)
                guard p.eyebrow == "Daily recap", p.heading == "Today" else {
                    throw BrineStepError("daily card eyebrow/heading was \(p.eyebrow)/\(p.heading)")
                }
            },
            defineCheck("the weekly card shows a \"Weekly recap\" eyebrow with a \"This week\" heading") { _, _, _ in
                let r = await ConversationRecapEngine.build(span: w.weekSpan, from: w.pool, calendar: w.cal)
                guard let recap = r else { throw BrineStepError("no weekly recap") }
                let p = ActivityRecapPresentation.make(from: recap)
                guard p.eyebrow == "Weekly recap", p.heading == "This week" else {
                    throw BrineStepError("weekly card eyebrow/heading was \(p.eyebrow)/\(p.heading)")
                }
            },
        ]
    }
}
