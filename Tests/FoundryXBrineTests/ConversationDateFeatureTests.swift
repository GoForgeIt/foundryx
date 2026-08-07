import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/conversation-date.feature — the list groups + labels each
/// conversation by its REAL start in the device-local timezone, never a processing/
/// re-ingest time, and renders duplicate generic titles distinctly. Drives the SAME
/// real seams the unit ConversationDateCorrectnessTests exercise (ConversationGrouping,
/// CaptureIdTime, ConversationCardStore, CaptureManager.conversationStartDate,
/// ConversationTitleDisplay) — hermetic (DoorTarget at a dead port, no network).
final class ConversationDateFeatureTests: XCTestCase {
    func testConversationDateFeature() async throws {
        try await BrineFeatureRunner.run("conversation-date",
                                         registry: StepRegistry(ConversationDateSteps.make(world: ConversationDateWorld())))
    }
}

private final class ConversationDateWorld: @unchecked Sendable {
    var dir: URL!

    // AC1 (evening-local bucketing)
    var localBucket: String?
    var utcBucket: String?

    // AC2 (re-ingest keeps the original date)
    var reingestId = "omi-20260601-101500-aa11bb22"
    var reingestExpected: UInt64?
    var reingestDisplayed: TimeInterval?

    // AC3 (durable card start)
    var stampId = "omi-20260610-091500-cccc4444"
    var stampIdStart: UInt64?
    var stampCardStart: UInt64?
    var stampRecordStartChanged: Bool?

    // AC4 (duplicate generic titles)
    var titleA: String?
    var titleB: String?
    var specificRender: String?

    func freshDir() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-date-feature-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A VISIBLE capture (one ack'd segment), optionally without a meta sidecar.
    func seedVisible(_ id: String, meta startedAt: UInt64? = nil) throws {
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        let seg = cdir.appendingPathComponent(CaptureWAL.segName(0))
        try Data([1, 2, 3, 4]).write(to: seg)
        try Data().write(to: seg.deletingPathExtension().appendingPathExtension("ack"))
        if let s = startedAt {
            ConversationMetaStore.save(ConversationMeta(startedAt: s), captureId: id, baseDir: dir)
        }
    }

    @MainActor
    func makeManager() -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []))
        #if os(iOS)
        mgr.micPermissionOverrideForTests = true
        #endif
        return mgr
    }
}

private enum ConversationDateSteps {
    private static func pdtCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "en_US_POSIX")
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.firstWeekday = 1
        return c
    }

    static func make(world w: ConversationDateWorld) -> [StepDefinition] {
        // Reusable "now" reference for the local-bucketing scenario.
        let local = pdtCalendar()
        let start = local.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 20, minute: 25))!
        let now = local.date(from: DateComponents(year: 2026, month: 6, day: 26, hour: 12, minute: 0))!

        return [
            // Background (single-line step; the wrapped continuation is dropped by the parser).
            defineStep("a conversation's real start is recovered from, in order, its meta start,") { ctx, _, _ in ctx },

            // MARK: AC1 — evening-local buckets to its LOCAL day
            defineStep("a conversation whose real start is yesterday evening in the device's timezone") { ctx, _, _ in ctx },
            defineStep("that same instant falls on the next calendar day in UTC") { ctx, _, _ in
                var utc = local
                utc.timeZone = TimeZone(identifier: "UTC")!
                guard local.component(.day, from: start) != utc.component(.day, from: start) else {
                    throw BrineStepError("the instant does not straddle a UTC day boundary")
                }
                return ctx
            },
            defineStep("the list buckets it with the device-local calendar") { ctx, _, _ in
                w.localBucket = ConversationGrouping.sectionTitle(for: start, now: now, calendar: local)
                var utc = local
                utc.timeZone = TimeZone(identifier: "UTC")!
                w.utcBucket = ConversationGrouping.sectionTitle(for: start, now: now, calendar: utc)
                return ctx
            },
            defineCheck("it groups under \"Yesterday\"") { _, _, _ in
                guard w.localBucket == "Yesterday" else {
                    throw BrineStepError("device-local bucket was \(w.localBucket ?? "nil"), expected Yesterday")
                }
            },
            defineCheck("it would have wrongly grouped under \"Today\" if bucketed in UTC") { _, _, _ in
                guard w.utcBucket == "Today" else {
                    throw BrineStepError("UTC bucket was \(w.utcBucket ?? "nil"), expected Today")
                }
            },

            // MARK: AC2 — re-ingest keeps the original date
            defineStep("a capture started weeks ago that has no meta sidecar") { ctx, _, _ in
                try w.freshDir()
                try w.seedVisible(w.reingestId, meta: nil)
                return ctx
            },
            defineStep("its capture id encodes that original start") { ctx, _, _ in
                guard let s = CaptureIdTime.startedAt(fromCaptureId: w.reingestId), s > 0 else {
                    throw BrineStepError("capture id did not encode a start")
                }
                w.reingestExpected = s
                return ctx
            },
            defineStep("the capture is re-ingested today and its card processing timestamp bumps") { ctx, _, _ in
                ConversationCardStore.merge(captureId: w.reingestId, baseDir: w.dir,
                                            title: "Some Meeting", summary: "notes", stage: "in_lore")
                let mgr = await MainActor.run { w.makeManager() }
                let h = await MainActor.run { mgr.hydration }
                await h?.value
                w.reingestDisplayed = try await MainActor.run { () throws -> TimeInterval in
                    guard let wal = mgr.visibleCaptures.first(where: { $0.captureId == w.reingestId }) else {
                        throw BrineStepError("re-ingested capture not visible")
                    }
                    return mgr.conversationStartDate(wal).timeIntervalSince1970
                }
                return ctx
            },
            defineCheck("the conversation's displayed date is still its original start") { _, _, _ in
                guard let shown = w.reingestDisplayed, let expected = w.reingestExpected,
                      abs(shown - TimeInterval(expected)) <= 1 else {
                    throw BrineStepError("displayed \(w.reingestDisplayed ?? -1) != original \(w.reingestExpected ?? 0)")
                }
            },
            defineCheck("it does NOT move to \"Today\"") { _, _, _ in
                guard let shown = w.reingestDisplayed,
                      Date().timeIntervalSince1970 - shown > 7 * 24 * 3600 else {
                    throw BrineStepError("the conversation date is not weeks in the past")
                }
            },

            // MARK: AC3 — a card write stamps a durable start
            defineStep("a door poll seeds a conversation's card with only a title") { ctx, _, _ in
                try w.freshDir()
                w.stampIdStart = CaptureIdTime.startedAt(fromCaptureId: w.stampId)
                ConversationCardStore.merge(captureId: w.stampId, baseDir: w.dir, title: "Hello")
                return ctx
            },
            defineCheck("the card is stamped with a durable start derived from the capture id") { _, _, _ in
                guard let card = ConversationCardStore.load(captureId: w.stampId, baseDir: w.dir),
                      card.startedAt == w.stampIdStart else {
                    throw BrineStepError("card start was not derived from the capture id")
                }
            },
            defineCheck("a later processing-time write never overwrites that durable start") { _, _, _ in
                let changed = ConversationCardStore.recordStart(captureId: w.stampId, baseDir: w.dir,
                                                                startedAt: UInt64(Date().timeIntervalSince1970))
                guard !changed else { throw BrineStepError("recordStart overwrote the durable start") }
                guard let card = ConversationCardStore.load(captureId: w.stampId, baseDir: w.dir),
                      card.startedAt == w.stampIdStart else {
                    throw BrineStepError("the durable start changed after a later write")
                }
            },

            // MARK: AC4 — duplicate generic titles render distinctly
            defineStep("two different near-silent captures both titled \"Thank you\"") { ctx, _, _ in
                let a = Date(timeIntervalSince1970: 1_750_000_000)
                let b = Date(timeIntervalSince1970: 1_750_003_600)   // +1h
                let fmt: (Date) -> String = { d in d == a ? "8:25 PM" : "9:25 PM" }
                w.titleA = ConversationTitleDisplay.display(title: "Thank you", start: a, timeString: fmt)
                w.titleB = ConversationTitleDisplay.display(title: "Thank you", start: b, timeString: fmt)
                w.specificRender = ConversationTitleDisplay.display(title: "Quarterly planning sync",
                                                                    start: a, timeString: fmt)
                return ctx
            },
            defineStep("they render in the list") { ctx, _, _ in ctx },
            defineCheck("each shows its start time appended so they are visually distinct") { _, _, _ in
                guard let a = w.titleA, let b = w.titleB, a != b,
                      a.contains("·"), b.contains("·") else {
                    throw BrineStepError("duplicate generic titles did not render distinctly: \(w.titleA ?? "nil") / \(w.titleB ?? "nil")")
                }
            },
            defineCheck("a specific, content-bearing title renders unchanged") { _, _, _ in
                guard w.specificRender == "Quarterly planning sync" else {
                    throw BrineStepError("a specific title was modified: \(w.specificRender ?? "nil")")
                }
            },
        ]
    }
}
