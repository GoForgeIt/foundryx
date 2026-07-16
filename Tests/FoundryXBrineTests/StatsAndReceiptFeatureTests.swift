import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/stats-and-receipt.feature.
///
/// The "library stats" scenario runs against the REAL `StatsSummary.build` seam
/// (conversation count, hours, average length, speakers, words, the 14-day per-day trend,
/// hours-this-week) over the same 3-conversation seed StatsSummaryTests unit-checks.
/// Hermetic + offline — no network.
///
/// GAP: the "conversation receipt shows what processed the conversation" scenario is NOT
/// executed. FoundryXKit has no receipt seam — the real receipt (recording duration,
/// "Deepgram in the cloud", speakers on-device, $0 device cost) is rendered inline in the
/// App target's `ConversationFacesView`, which the SPM/Kit test target cannot reach. Rather
/// than assert against a strawman model created only for the test, the scenario is filtered
/// out of the run and reported honestly by `testConversationReceipt_unimplemented`.
final class StatsAndReceiptFeatureTests: XCTestCase {

    /// The receipt scenario has no Kit-level seam. Surfaced as an explicit skip (gap).
    func testConversationReceipt_unimplemented() throws {
        throw XCTSkip("unimplemented: no FoundryXKit receipt seam — the conversation receipt " +
                      "(duration / 'Deepgram in the cloud' / speakers on-device / $0 device cost) " +
                      "is rendered inline in the App target's ConversationFacesView, unreachable " +
                      "from the Kit test target. Wiring it honestly needs a ConversationReceipt " +
                      "model the real detail view consumes.")
    }

    func testStatsAndReceiptFeature() async throws {
        let world = StatsWorld()
        let registry = StepRegistry(StatsSteps.make(world: world))

        // Run every scenario EXCEPT the un-seamed conversation-receipt one.
        let parsed = parseFeatureText(try Self.featureText())
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")
        var features = parsed.features
        features[0].scenarios = features[0].scenarios.filter {
            $0.name != "conversation receipt shows what processed the conversation"
        }

        var collected: [JSONValue] = []
        let result = try await Resources.run(features, registry: registry,
                                             resources: [], collector: { collected.append($0) })
        var failures: [String] = []
        for ev in collected {
            guard case .object(let o) = ev,
                  case .string("scenario_end")? = o["type"],
                  case .string(let status)? = o["status"], status != "passed" else { continue }
            let nm: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(nm): \(err)")
        }
        XCTAssertTrue(failures.isEmpty, "stats-and-receipt scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
        XCTAssertEqual(result.passed, features[0].scenarios.count, "all wired scenarios should pass")
    }

    private static func featureText() throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appendingPathComponent("features/stats-and-receipt.feature"))
    }
}

private final class StatsWorld: @unchecked Sendable {
    var summary: StatsSummary?

    /// Deterministic clock so week/day bucketing is exact (matches StatsSummaryTests).
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()
    lazy var now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 12))!

    func snapshots() -> [StatsConversationSnapshot] {
        let monday = calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9))!
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 10))!
        let old = calendar.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 15))!
        return [
            StatsConversationSnapshot(
                captureId: "c1",
                meta: ConversationMeta(startedAt: UInt64(monday.timeIntervalSince1970),
                                       endedAt: UInt64(monday.timeIntervalSince1970) + 1800),
                transcript: CachedTranscript(
                    transcript: "one two three four", title: nil, summary: nil,
                    segments: [
                        TranscriptSegment(seq: 0, text: "one two", speaker: "speaker_0"),
                        TranscriptSegment(seq: 1, text: "three four", speaker: "speaker_1"),
                    ],
                    speakers: [
                        CaptureSpeaker(slot: "speaker_0", status: .confirmed,
                                       name: "Alice", confirmedSpeakerId: "spk_alice"),
                        CaptureSpeaker(slot: "speaker_1", status: .anonymous),
                    ],
                    fetchedAt: 1)),
            StatsConversationSnapshot(
                captureId: "c2",
                meta: ConversationMeta(startedAt: UInt64(tuesday.timeIntervalSince1970),
                                       endedAt: UInt64(tuesday.timeIntervalSince1970) + 3600),
                transcript: CachedTranscript(
                    transcript: "five six seven", title: nil, summary: nil,
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
                    fetchedAt: 2)),
            StatsConversationSnapshot(
                captureId: "c3",
                meta: ConversationMeta(startedAt: UInt64(old.timeIntervalSince1970),
                                       endedAt: UInt64(old.timeIntervalSince1970) + 900),
                transcript: nil),
        ]
    }
}

private enum StatsSteps {
    static func make(world w: StatsWorld) -> [StepDefinition] {
        [
            defineStep("I have locally browsable conversations with metadata, transcripts, and speaker segments") { ctx, _, _ in
                w.summary = nil
                return ctx
            },
            defineStep("I open Your library from the capture surface") { ctx, _, _ in
                w.summary = StatsSummary.build(from: w.snapshots(), now: w.now, calendar: w.calendar)
                return ctx
            },
            defineCheck("I see the total conversations in my local library") { _, _, _ in
                guard w.summary?.totalConversations == 3 else {
                    throw BrineStepError("totalConversations = \(w.summary?.totalConversations ?? -1), expected 3")
                }
            },
            defineCheck("I see the total hours recorded") { _, _, _ in
                guard w.summary?.totalDurationSeconds == 6300 else {
                    throw BrineStepError("totalDurationSeconds = \(w.summary?.totalDurationSeconds ?? 0), expected 6300")
                }
            },
            defineCheck("I see the average conversation length") { _, _, _ in
                guard w.summary?.averageDurationSeconds == 2100 else {
                    throw BrineStepError("averageDurationSeconds = \(w.summary?.averageDurationSeconds ?? 0), expected 2100")
                }
            },
            defineCheck("I see the total speakers identified") { _, _, _ in
                guard w.summary?.totalSpeakersIdentified == 3 else {
                    throw BrineStepError("totalSpeakersIdentified = \(w.summary?.totalSpeakersIdentified ?? -1), expected 3")
                }
            },
            defineCheck("I see the total words") { _, _, _ in
                guard w.summary?.totalWords == 7 else {
                    throw BrineStepError("totalWords = \(w.summary?.totalWords ?? -1), expected 7")
                }
            },
            defineCheck("I see conversations per day for the recent trend") { _, _, _ in
                guard let perDay = w.summary?.conversationsPerDay, perDay.count == 14 else {
                    throw BrineStepError("conversationsPerDay count = \(w.summary?.conversationsPerDay.count ?? -1), expected 14")
                }
                guard perDay.contains(where: { $0.conversationCount > 0 }) else {
                    throw BrineStepError("expected at least one day with recorded conversations")
                }
            },
            defineCheck("I see hours recorded this week") { _, _, _ in
                guard let hours = w.summary?.hoursThisWeek, abs(hours - 1.5) < 0.001 else {
                    throw BrineStepError("hoursThisWeek = \(w.summary?.hoursThisWeek ?? -1), expected 1.5")
                }
            },
        ]
    }
}
