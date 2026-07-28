import XCTest
import Foundation
import AVFoundation
import FoundryXKit

/// Door-free tests for the live-conversation UX refinements (track 20260628):
///   • Feature 1 — instant conversation entry on stop: finalize PERSISTS the on-device
///     transcript as the card's provisional title + body, marked provisional, WITHOUT
///     stamping the Kiln "ready"/in-Lore tombstone; Kiln content later OVERRIDES it.
///   • Feature 5 — the pure time-bucketing of the conversation list.
///   • Feature 3 — the mic toggle drives the record/stop state.
@MainActor
final class ConversationUXRefinementTests: SignedOutListeningCaptureTestCase {

    // MARK: fakes (mirror the patterns in PhoneMicCaptureTests / LiveTranscriptionTests)

    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0
        func start() { startCount += 1 }
        func stop() { stopCount += 1 }
    }

    /// A controllable live transcriber: the test pushes snapshots into its stream and
    /// drives its lifecycle. `finish()` returns the last finalized text it was given.
    final class FakeLiveTranscriber: LiveTranscribing, @unchecked Sendable {
        let transcript: AsyncStream<LiveTranscript>
        private let cont: AsyncStream<LiveTranscript>.Continuation
        private let lock = NSLock()
        private var _final = ""
        init() {
            var c: AsyncStream<LiveTranscript>.Continuation!
            transcript = AsyncStream { c = $0 }
            cont = c
        }
        func start() async throws {}
        func append(_ pcm: AVAudioPCMBuffer) {}
        func finish() async -> String { readFinal() }
        func emit(_ t: LiveTranscript) {
            setFinal(t.finalizedText)
            cont.yield(t)
        }
        private func readFinal() -> String { lock.lock(); defer { lock.unlock() }; return _final }
        private func setFinal(_ s: String) { lock.lock(); _final = s; lock.unlock() }
    }

    final class FakeFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [FakeLiveTranscriber] = []
        func make() -> LiveTranscribing? { let f = FakeLiveTranscriber(); lock.lock(); made.append(f); lock.unlock(); return f }
        var last: FakeLiveTranscriber? { lock.lock(); defer { lock.unlock() }; return made.last }
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-ux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private // Deadline is generous ON PURPOSE. The `flake` gate runs this suite a second time
    // under deliberately induced CPU load, where a capture session can be starved for
    // seconds. A 3s bound there tested the SCHEDULER, not the behaviour — it made the
    // flake gate fail ~70% of the time on a clean main, which trains everyone to ignore
    // the one gate whose job is catching real flakiness (track 20260726T0030).
    // The assertion is unchanged: the condition must still become true.
    func waitUntil(timeout: TimeInterval = 300, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: AC1/AC3 — finalize persists the on-device transcript as provisional content

    func testStopPersistsOnDeviceTranscriptAsProvisionalCard() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let omi = TestSource(), mic = TestSource()
        let factory = FakeFactory()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: omi, micSource: mic,
                                 finalize: { _, _ in },
                                 liveTranscriber: { factory.make() })
        #if os(iOS)
        mgr.micPermissionOverrideForTests = true  // sim can't drive the real permission prompt
        #endif

        mgr.startMicRecording()
        mic.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let captureId = try XCTUnwrap(mgr.active).captureId

        // The user watches the on-device transcript stream by.
        let said = "Hello world this is a test"
        factory.last?.emit(LiveTranscript(finalizedText: said, volatileTail: ""))
        try await waitUntil { mgr.liveTranscript.displayText.contains("Hello world") }

        // Stop → the conversation must appear with readable provisional content NOW.
        mgr.stopMicRecording()
        mic.onState?(.stopped)
        try await waitUntil { mgr.active == nil }
        try await waitUntil { ConversationCardStore.load(captureId: captureId, baseDir: dir)?.isProvisional == true }

        let card = try XCTUnwrap(ConversationCardStore.load(captureId: captureId, baseDir: dir))
        XCTAssertTrue(card.isProvisional, "the card is marked provisional until Kiln lands")
        XCTAssertEqual(card.provisionalTranscript, said, "the on-device transcript is the card body")
        XCTAssertEqual(card.title, said, "the provisional title is the first words of the on-device text")

        // AC3: provisional content must NOT read as Kiln-ready / in-Lore.
        XCTAssertFalse(TranscriptCacheStore.hasCachedTranscript(captureId: captureId, baseDir: dir),
                       "provisional content is not the cached Kiln transcript")
        XCTAssertFalse(TranscriptCacheStore.isConfirmedInLore(captureId: captureId, baseDir: dir),
                       "provisional content does not stamp the in-Lore marker")
    }

    // MARK: AC2 — Kiln content overrides the provisional card in place

    func testKilnContentOverridesProvisionalInPlace() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-test-override"

        ConversationCardStore.seedProvisional(captureId: id, baseDir: dir,
                                              transcript: "raw on device words", title: "raw on device words")
        var card = try XCTUnwrap(ConversationCardStore.load(captureId: id, baseDir: dir))
        XCTAssertTrue(card.isProvisional)
        XCTAssertEqual(card.title, "raw on device words")

        // The door/Kiln poll returns the authoritative title + summary.
        ConversationCardStore.merge(captureId: id, baseDir: dir,
                                    title: "Project Sync", summary: "Discussed the launch plan.")
        card = try XCTUnwrap(ConversationCardStore.load(captureId: id, baseDir: dir))
        XCTAssertEqual(card.title, "Project Sync", "Kiln title overrides the provisional title")
        XCTAssertEqual(card.summary, "Discussed the launch plan.")
        XCTAssertFalse(card.isProvisional, "the provisional flag clears once Kiln content lands")
    }

    func testProvisionalNeverClobbersAuthoritativeTitle() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-test-noclobber"

        // Kiln content already present (non-provisional).
        ConversationCardStore.merge(captureId: id, baseDir: dir, title: "Real Title", summary: "Real summary")
        // A late provisional seed must not downgrade it.
        let changed = ConversationCardStore.seedProvisional(captureId: id, baseDir: dir,
                                                            transcript: "garble", title: "garble")
        XCTAssertFalse(changed, "seedProvisional is a no-op against an authoritative card")
        let card = try XCTUnwrap(ConversationCardStore.load(captureId: id, baseDir: dir))
        XCTAssertEqual(card.title, "Real Title")
        XCTAssertFalse(card.isProvisional)
    }

    func testProvisionalTitleFallsBackToProcessingPlaceholder() {
        XCTAssertEqual(ProvisionalTitle.from(transcript: nil), "Processing…")
        XCTAssertEqual(ProvisionalTitle.from(transcript: "   "), "Processing…")
        XCTAssertEqual(ProvisionalTitle.from(transcript: "one two three"), "one two three")
        XCTAssertEqual(ProvisionalTitle.from(transcript: "a b c d e f g h", wordLimit: 3), "a b c…")
    }

    // MARK: AC4 — conversation list time grouping

    private func uxCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 1   // Sunday-start weeks
        return cal
    }

    /// `now` = the LAST day (Saturday) of some week at noon, so the whole week sits
    /// "this week" and there is room for prior-day / prior-week buckets.
    private func saturdayNoon(_ cal: Calendar) -> Date {
        let seed = cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 12))!
        let weekStart = cal.dateInterval(of: .weekOfYear, for: seed)!.start
        return cal.date(byAdding: .day, value: 6, to: cal.date(bySettingHour: 12, minute: 0, second: 0, of: weekStart)!)!
    }

    func testTimeBucketing() {
        let cal = uxCalendar()
        let now = saturdayNoon(cal)
        func title(_ daysAgo: Int) -> String {
            let d = cal.date(byAdding: .day, value: -daysAgo, to: now)!
            return ConversationGrouping.sectionTitle(for: d, now: now, calendar: cal)
        }
        XCTAssertEqual(title(0), "Today")
        XCTAssertEqual(title(1), "Yesterday")
        // 3 days ago is still this week (Saturday − 3 = Wednesday) → its weekday name.
        let wed = cal.date(byAdding: .day, value: -3, to: now)!
        let wf = DateFormatter(); wf.calendar = cal; wf.locale = cal.locale; wf.dateFormat = "EEEE"
        XCTAssertEqual(title(3), wf.string(from: wed))
        XCTAssertEqual(title(7), "Last week")
        XCTAssertEqual(title(14), "2 weeks ago")
        XCTAssertEqual(title(21), "3 weeks ago")
        // ~6 weeks ago → month bucket.
        let old = cal.date(byAdding: .day, value: -42, to: now)!
        let mf = DateFormatter(); mf.calendar = cal; mf.locale = cal.locale; mf.dateFormat = "LLLL"
        XCTAssertEqual(title(42), mf.string(from: old))
    }

    func testGroupingProducesOrderedNonRepeatingSections() {
        let cal = uxCalendar()
        let now = saturdayNoon(cal)
        struct Item { let id: String; let date: Date }
        func at(_ daysAgo: Int) -> Date { cal.date(byAdding: .day, value: -daysAgo, to: now)! }
        // Unsorted input spanning several buckets, with two items in the same week-bucket.
        let items = [
            Item(id: "two-weeks", date: at(14)),
            Item(id: "today",     date: at(0)),
            Item(id: "two-weeks-b", date: at(15)),
            Item(id: "yesterday", date: at(1)),
        ]
        let sections = ConversationGrouping.group(items, now: now, calendar: cal) { $0.date }
        XCTAssertEqual(sections.map { $0.title }, ["Today", "Yesterday", "2 weeks ago"],
                       "sections are newest-first and each title appears once")
        XCTAssertEqual(sections.last?.items.map { $0.id }, ["two-weeks", "two-weeks-b"],
                       "same-bucket items stay together, newest-first")
    }

    // MARK: AC5 — the mic toggle drives record/stop state

    func testMicToggleDrivesRecordingState() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let omi = TestSource(), mic = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: omi, micSource: mic,
                                 finalize: { _, _ in })
        #if os(iOS)
        mgr.micPermissionOverrideForTests = true  // sim can't drive the real permission prompt
        #endif

        XCTAssertFalse(mgr.isRecordingMic)
        mgr.toggleMicRecording()                 // → record
        XCTAssertTrue(mgr.isRecordingMic)
        XCTAssertEqual(mic.startCount, 1)
        mic.onState?(.streaming)
        try await waitUntil { mgr.active != nil }

        mgr.toggleMicRecording()                 // → stop
        XCTAssertEqual(mic.stopCount, 1)
        mic.onState?(.stopped)
        try await waitUntil { mgr.active == nil }
        XCTAssertFalse(mgr.isRecordingMic)
    }
}
