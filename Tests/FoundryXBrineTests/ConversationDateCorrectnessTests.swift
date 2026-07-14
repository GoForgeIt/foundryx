import XCTest
import Foundation
@testable import FoundryXKit

/// Conversation DATE correctness (track 20260628T1609). The list must group + label by
/// the conversation's REAL START in the device-local timezone — never a processing/
/// re-ingest time and never app-launch time. Plus the generic-title disambiguation.
final class ConversationDateCorrectnessTests: XCTestCase {

    private func tempDir(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-date-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Seed a VISIBLE capture (one ack'd segment) — optionally WITHOUT a meta sidecar,
    /// so the date must be recovered from the card / capture-id, never launch time.
    private func seedVisible(_ id: String, baseDir: URL, meta startedAt: UInt64? = nil) throws {
        let cdir = baseDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        let seg = cdir.appendingPathComponent(CaptureWAL.segName(0))
        try Data([1, 2, 3, 4]).write(to: seg)
        try Data().write(to: seg.deletingPathExtension().appendingPathExtension("ack"))
        if let s = startedAt {
            ConversationMetaStore.save(ConversationMeta(startedAt: s), captureId: id, baseDir: baseDir)
        }
    }

    // MARK: AC1 — an evening-local instant buckets to its LOCAL day, not the UTC day

    func testEveningLocalGroupsUnderYesterdayNotUTCToday() {
        // Device timezone: PDT (UTC-7). A conversation at 2026-06-25 20:25 LOCAL is
        // 2026-06-26 03:25 UTC — i.e. a different calendar day in UTC.
        let pdt = TimeZone(identifier: "America/Los_Angeles")!
        var local = Calendar(identifier: .gregorian)
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = pdt
        local.firstWeekday = 1

        let start = local.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 20, minute: 25))!
        let now = local.date(from: DateComponents(year: 2026, month: 6, day: 26, hour: 12, minute: 0))!

        // The device-local calendar (what the list uses via Calendar.current) → Yesterday.
        XCTAssertEqual(ConversationGrouping.sectionTitle(for: start, now: now, calendar: local),
                       "Yesterday", "an evening-local start belongs to its LOCAL day")

        // Proof of the bug we're guarding against: a UTC calendar would mis-bucket it.
        var utc = local
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(ConversationGrouping.sectionTitle(for: start, now: now, calendar: utc),
                       "Today", "the same instant is wrongly 'Today' under a UTC calendar")
    }

    // MARK: AC2 — the date is the real start; re-ingest must NOT move it to Today

    @MainActor
    func testReingestedOldCaptureKeepsItsOriginalDate() async throws {
        let dir = try tempDir("reingest")
        defer { try? FileManager.default.removeItem(at: dir) }

        // A weeks-old capture with NO meta sidecar; its id encodes the real start
        // (2026-06-01 10:15:00 UTC). Before the fix this dated to app-launch time.
        let id = "omi-20260601-101500-aa11bb22"
        try seedVisible(id, baseDir: dir, meta: nil)
        let expected = CaptureIdTime.startedAt(fromCaptureId: id)!   // the id instant
        XCTAssertGreaterThan(expected, 0)

        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []))
        await mgr.hydration?.value
        let wal = try XCTUnwrap(mgr.visibleCaptures.first { $0.captureId == id })

        let before = mgr.conversationStartDate(wal).timeIntervalSince1970
        XCTAssertEqual(before, TimeInterval(expected), accuracy: 1,
                       "a meta-less capture dates to its capture-id start, NOT launch time")
        // It must be weeks in the past — definitively not 'today'.
        XCTAssertGreaterThan(Date().timeIntervalSince1970 - before, 7 * 24 * 3600,
                             "the conversation is weeks old, not Today")

        // Re-ingest: a door/Lore poll merges a title, bumping the card's PROCESSING
        // timestamp (updated_at) — the kind of event that used to move the date.
        ConversationCardStore.merge(captureId: id, baseDir: dir,
                                    title: "Some Meeting", summary: "notes", stage: "in_lore")

        // The durable start is unchanged, and a FRESH manager (re-reads disk) agrees.
        let card = try XCTUnwrap(ConversationCardStore.load(captureId: id, baseDir: dir))
        XCTAssertEqual(card.startedAt, expected, "card start is the original id start")
        XCTAssertGreaterThan(card.updatedAt, expected, "updated_at bumped to ~now (a processing time)")

        let mgr2 = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []))
        await mgr2.hydration?.value
        let wal2 = try XCTUnwrap(mgr2.visibleCaptures.first { $0.captureId == id })
        XCTAssertEqual(mgr2.conversationStartDate(wal2).timeIntervalSince1970,
                       TimeInterval(expected), accuracy: 1,
                       "re-ingest (updated_at bump) did NOT move the conversation date")
    }

    // MARK: AC3 — every card write stamps a durable start; re-ingest can't overwrite it

    func testCardWriteStampsDurableStartFromCaptureId() throws {
        let dir = try tempDir("stamp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-20260610-091500-cccc4444"
        let idStart = CaptureIdTime.startedAt(fromCaptureId: id)!

        // A door poll seeds the card with ONLY a title (no start of its own).
        ConversationCardStore.merge(captureId: id, baseDir: dir, title: "Hello")
        let seeded = try XCTUnwrap(ConversationCardStore.load(captureId: id, baseDir: dir))
        XCTAssertEqual(seeded.startedAt, idStart, "a card write derives a durable start from the id")

        // recordStart is idempotent + re-ingest-safe: a later (processing-time) start
        // never overwrites the durable one.
        let changed = ConversationCardStore.recordStart(captureId: id, baseDir: dir,
                                                        startedAt: UInt64(Date().timeIntervalSince1970))
        XCTAssertFalse(changed, "recordStart never overwrites an existing durable start")
        let after = try XCTUnwrap(ConversationCardStore.load(captureId: id, baseDir: dir))
        XCTAssertEqual(after.startedAt, idStart, "the durable start is unchanged by a later write")
    }

    func testRecordStartPrefersMetaStartOverId() throws {
        let dir = try tempDir("metastart")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-20260610-091500-dddd5555"
        let authoritative: UInt64 = 1_717_000_000   // distinct from the id-derived value
        XCTAssertTrue(ConversationCardStore.recordStart(captureId: id, baseDir: dir, startedAt: authoritative))
        let card = try XCTUnwrap(ConversationCardStore.load(captureId: id, baseDir: dir))
        XCTAssertEqual(card.startedAt, authoritative, "an explicit meta start wins over the id timestamp")
    }

    // MARK: capture-id parsing

    func testCaptureIdTimeParsing() {
        // 2026-06-25 20:25:00 UTC.
        let secs = CaptureIdTime.startedAt(fromCaptureId: "omi-20260625-202500-deadbeef")
        let expected = utcCal().date(from: DateComponents(year: 2026, month: 6, day: 25,
                                                          hour: 20, minute: 25, second: 0))!
            .timeIntervalSince1970
        XCTAssertEqual(secs.map { TimeInterval($0) }, expected)
        XCTAssertNil(CaptureIdTime.startedAt(fromCaptureId: "no-timestamp-here"))
        XCTAssertNil(CaptureIdTime.startedAt(fromCaptureId: "omi-99999999-999999-x"),
                     "a non-date stamp does not parse")
    }

    private func utcCal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // MARK: AC4 — generic/duplicate titles render distinctly

    func testGenericTitlesGetTimeAppended() {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let fmt: (Date) -> String = { _ in "8:25 PM" }
        XCTAssertEqual(ConversationTitleDisplay.display(title: "Thank you", start: start, timeString: fmt),
                       "Thank you · 8:25 PM")
        XCTAssertEqual(ConversationTitleDisplay.display(title: "Okay", start: start, timeString: fmt),
                       "Okay · 8:25 PM")
        // A specific, content-bearing title is unchanged.
        XCTAssertEqual(ConversationTitleDisplay.display(title: "Quarterly planning sync",
                                                        start: start, timeString: fmt),
                       "Quarterly planning sync")
    }

    func testTwoDuplicateGenericTitlesRenderDistinctly() {
        let a = Date(timeIntervalSince1970: 1_750_000_000)
        let b = Date(timeIntervalSince1970: 1_750_003_600)   // +1h
        let fmt: (Date) -> String = { d in d == a ? "8:25 PM" : "9:25 PM" }
        let da = ConversationTitleDisplay.display(title: "Thank you", start: a, timeString: fmt)
        let db = ConversationTitleDisplay.display(title: "Thank you", start: b, timeString: fmt)
        XCTAssertNotEqual(da, db, "two same-titled near-silent captures must read distinctly")
    }

    func testIsGenericClassification() {
        XCTAssertTrue(ConversationTitleDisplay.isGeneric("Thank you."))
        XCTAssertTrue(ConversationTitleDisplay.isGeneric("OK"))
        XCTAssertTrue(ConversationTitleDisplay.isGeneric("  "))
        XCTAssertTrue(ConversationTitleDisplay.isGeneric("Hi there"))   // ≤2 words, ≤12 chars
        XCTAssertFalse(ConversationTitleDisplay.isGeneric("Project kickoff meeting"))
    }
}
