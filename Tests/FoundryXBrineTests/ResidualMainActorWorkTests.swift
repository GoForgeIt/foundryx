import XCTest
import Foundation
@testable import FoundryXKit

/// GREEN acceptance for the track `20260722T1244_residual_on_main_actor_work`.
///
/// `HangReproTests` pins the LIBRARY-side stalls (rebuild, sort, recap pool). These tests pin
/// the residual per-render / per-TICK main-actor work that survived them:
///
///  A. **The 12 Hz meter tick.** `pushLiveState` wrote the App-Group widget snapshot and hinted
///     `WidgetCenter.reloadAllTimelines()` BEFORE its throttle guard, and `makeWidgetSnapshot`
///     → `lastFinishedConversation()` scanned `visibleCaptures` calling the un-memoized
///     `cardMeta` per row. Net: a main-actor disk WRITE plus an N-row sidecar scan, twelve
///     times a second, for the whole duration of every recording.
///  B/D. **Per rendered row.** A row reads its title/summary (`cardMeta`) and its "Ready" chip
///     (`hasCachedTranscript`) — a `card.json` decode and a `fileExists` PER ROW PER RENDER.
///  C. **Grouping.** The list re-sorted an already-sorted list and allocated a `DateFormatter`
///     per row/section on the render path.
///
/// The instruments are the same deterministic counters the sibling tracks use — no wall-clock
/// budgets here, so nothing can flake into green.
///
/// Isolation is NON-NEGOTIABLE: every test uses a FRESH tempDir — the real `~/.foundry` /
/// `~/.lore` are never touched.
@MainActor
final class ResidualMainActorWorkTests: XCTestCase {

    private static let libraryN = 175

    private final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-residual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Seed a realistic library: meta + card + a cached transcript per capture, newest first.
    @discardableResult
    private func seedLibrary(dir: URL, count: Int) -> [String] {
        var ids: [String] = []
        let now = UInt64(max(0, Date().timeIntervalSince1970))
        for i in 0..<count {
            let id = String(format: "omi-cap-%05d", i)
            ids.append(id)
            let started = now - UInt64((i + 1) * 600)
            ConversationMetaStore.save(ConversationMeta(startedAt: started, endedAt: started + 480),
                                       captureId: id, baseDir: dir)
            ConversationCardStore.save(
                ConversationCardMeta(title: "Conversation \(i)",
                                     summary: "A real summary sentence for conversation \(i).",
                                     stage: "in_lore"),
                captureId: id, baseDir: dir)
            TranscriptCacheStore.save(
                CachedTranscript(transcript: "We reviewed the launch plan and agreed on a date. " +
                                             "Sarah owns the numbers and sends the deck tonight.",
                                 title: "Conversation \(i)",
                                 summary: "A real summary sentence for conversation \(i).",
                                 fetchedAt: 100),
                captureId: id, baseDir: dir)
        }
        return ids
    }

    private func makeManager(dir: URL, source: TestSource) async -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let m = CaptureManager(target: target, baseDir: dir, source: source,
                               finalize: { _, _ in }, deleteCapture: { _ in },
                               fetchContent: { _ in nil })
        m.setSilenceGap(9_999)     // no auto-segmenting — the recording under test stays open
        await m.hydration?.value   // warm the memos OFF main, like a real launch
        return m
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// QUIESCENCE — required before any `decodes == 0` measurement.
    ///
    /// `await hydration?.value` means "hydration finished", NOT "every memo is warm":
    /// hydration schedules per-capture off-main sidecar warms, and any still in flight leave
    /// their capture's memo cold, so `cardMeta` / `hasCachedTranscript` legitimately fall
    /// through to disk and the counter is non-zero. That is a TEST race, not a regression —
    /// measuring through it is how this suite flaked. Wait for the memos to land first.
    private func waitForWarmMemos(_ mgr: CaptureManager, atLeast count: Int) async throws {
        try await waitUntil(timeout: 10) { mgr.warmSidecarMemoCountForTests >= count }
    }

    // MARK: A — the 12 Hz meter tick (spec addendum)

    /// N meter ticks during a LIVE recording, over a full library, must do ZERO main-actor
    /// disk reads and drive AT MOST the throttled number of widget pushes (a widget push is
    /// an App-Group file write + a WidgetKit reload hint).
    ///
    /// Before this track: 175 `card.json` decodes AND one widget write + reload PER TICK —
    /// i.e. ~12 writes/second and ~2100 decodes/second while recording.
    func testMeterTicksDuringRecordingDoNoMainActorDiskAndThrottleWidgetPushes() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        seedLibrary(dir: dir, count: Self.libraryN)
        let src = TestSource()
        let mgr = await makeManager(dir: dir, source: src)
        XCTAssertGreaterThanOrEqual(mgr.visibleCaptures.count, Self.libraryN - 2,
                                    "the library hydrated and is visible")
        // Quiesce BEFORE the recording starts, so the measurement window below cannot pick
        // up a hydration warm that was still in flight (see `waitForWarmMemos`).
        try await waitForWarmMemos(mgr, atLeast: mgr.visibleCaptures.count)

        // A REAL live recording (speech onset opens the conversation), so `isCapturing` is
        // true and the tick takes the `pushLiveState(.throttledUpdate)` branch it takes on a
        // device — not a synthetic flag.
        src.onState?(.streaming)
        RealOmiFrames.openSession(src.onFrame)
        try await waitUntil { mgr.active != nil }
        XCTAssertTrue(mgr.isCapturing, "premise: a conversation is actually being recorded")

        // Let the session's own start-transition push settle before measuring.
        try await Task.sleep(nanoseconds: 100_000_000)
        // The REAL 12 Hz timer is running (beginSession started it), so the measurement
        // window below covers genuine production ticks as well as the explicit ones.
        XCTAssertTrue(mgr.meterIsRunningForTests, "premise: the real 12 Hz meter timer is running")

        let explicitTicks = 120   // 10 seconds' worth, driven synchronously
        let window: TimeInterval = 6
        CaptureManager.resetMainThreadTranscriptDecodesForTests()
        CaptureManager.resetWidgetPushesForTests()
        let t0 = Date()
        for _ in 0..<explicitTicks { mgr.tickMeterForTests() }
        let burstMs = Date().timeIntervalSince(t0) * 1000
        try await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))   // ~72 real ticks

        let elapsed = Date().timeIntervalSince(t0)
        let decodes = CaptureManager.mainThreadTranscriptDecodesForTests
        let pushes = CaptureManager.widgetPushesForTests
        let realTicks = Int(window * 12)
        // The throttle is time-based: the honest ceiling is one push per throttle window of
        // REAL elapsed time, plus the one the window is allowed to open with.
        let allowedPushes = Int(elapsed / CaptureManager.liveActivityThrottle) + 1
        print("RESIDUAL A: \(explicitTicks) explicit ticks in " +
              "\(String(format: "%.1f", burstMs))ms + ~\(realTicks) real 12 Hz ticks over " +
              "\(String(format: "%.1f", elapsed))s → decodes=\(decodes) " +
              "widgetPushes=\(pushes) (allowed \(allowedPushes)) N=\(Self.libraryN)")

        XCTAssertTrue(mgr.isCapturing, "premise: still recording for the whole window")
        XCTAssertEqual(decodes, 0,
                       "a meter tick must not read a card/transcript off disk on the main " +
                       "actor — ~\(explicitTicks + realTicks) ticks did \(decodes) reads")
        XCTAssertLessThanOrEqual(pushes, allowedPushes,
                                 "the widget snapshot write + reload hint must sit BEHIND the " +
                                 "throttle — ~\(explicitTicks + realTicks) ticks drove " +
                                 "\(pushes) pushes")
        // …and a throttle, not a MUTE: the tile still tracks a live recording, at the Live
        // Activity's cadence rather than the meter's.
        XCTAssertGreaterThanOrEqual(pushes, 1,
                                    "the widget must still be refreshed while recording — " +
                                    "\(pushes) pushes in \(String(format: "%.1f", elapsed))s")
    }

    /// The throttle is a throttle, not an off switch: a LIFECYCLE transition still pushes the
    /// widget immediately (the tile must not lag a start/stop by up to the throttle window).
    func testLifecycleTransitionPushesTheWidgetImmediately() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        seedLibrary(dir: dir, count: 3)
        let src = TestSource()
        let mgr = await makeManager(dir: dir, source: src)

        CaptureManager.resetWidgetPushesForTests()
        src.onState?(.streaming)
        RealOmiFrames.openSession(src.onFrame)
        try await waitUntil { mgr.active != nil }
        XCTAssertGreaterThanOrEqual(CaptureManager.widgetPushesForTests, 1,
                                    "starting a conversation refreshes the widget at once")

        // …and back-to-back throttled ticks right after it add nothing.
        let after = CaptureManager.widgetPushesForTests
        for _ in 0..<24 { mgr.tickMeterForTests() }
        XCTAssertEqual(CaptureManager.widgetPushesForTests, after,
                       "throttled ticks inside the window add no widget pushes")
    }

    // MARK: B/D — zero disk per rendered row

    /// The two per-row reads the conversation card makes — its title/summary (`cardMeta`) and
    /// its "Ready" chip (`hasCachedTranscript`) — over EVERY visible row, must read nothing
    /// off disk on the main actor. Before this track that was one `card.json` decode plus one
    /// `fileExists` per row, on every body pass.
    func testRenderingEveryRowReadsZeroDiskOnMain() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        seedLibrary(dir: dir, count: Self.libraryN)
        let mgr = await makeManager(dir: dir, source: TestSource())
        let rows = mgr.visibleCaptures
        XCTAssertGreaterThanOrEqual(rows.count, Self.libraryN - 2)
        // Let hydration's off-main warms LAND before measuring — see `waitForWarmMemos`.
        try await waitForWarmMemos(mgr, atLeast: rows.count)

        CaptureManager.resetMainThreadTranscriptDecodesForTests()
        var titles = 0, ready = 0
        for wal in rows {
            if (mgr.cardMeta(for: wal.captureId)?.title?.isEmpty == false) { titles += 1 }
            if mgr.hasCachedTranscript(wal.captureId) { ready += 1 }
        }
        let decodes = CaptureManager.mainThreadTranscriptDecodesForTests
        print("RESIDUAL B/D: \(rows.count) rows rendered, titles=\(titles) ready=\(ready) decodes=\(decodes)")

        XCTAssertEqual(titles, rows.count, "every row still resolves its durable title")
        XCTAssertEqual(ready, rows.count, "every row still resolves its Ready chip")
        XCTAssertEqual(decodes, 0,
                       "a rendered row must read ZERO bytes off disk on the main actor — " +
                       "\(rows.count) rows did \(decodes) reads")
    }

    /// The memo must not go stale-forever: a card written BEHIND the manager's back (the
    /// status poller's merge is exactly this) is visible to the very next read. This is the
    /// contract that makes the memoization safe — it is a cache, not a snapshot.
    func testCardWrittenBehindTheManagerIsVisibleImmediately() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        seedLibrary(dir: dir, count: 3)
        let mgr = await makeManager(dir: dir, source: TestSource())
        let id = "omi-cap-00000"
        XCTAssertEqual(mgr.cardMeta(for: id)?.title, "Conversation 0")

        ConversationCardStore.merge(captureId: id, baseDir: dir,
                                    title: "The real Kiln title", summary: "A real summary.",
                                    stage: "in_lore")
        mgr.invalidateSidecar(id)   // the seam every out-of-manager writer calls
        XCTAssertEqual(mgr.cardMeta(for: id)?.title, "The real Kiln title",
                       "a card written behind the manager's back is never served stale")

        // …and once the off-main re-warm lands, the answer comes from MEMORY again — the
        // disk fallback is bounded by WRITES, it does not become the steady state.
        try await waitUntil {
            CaptureManager.resetMainThreadTranscriptDecodesForTests()
            _ = mgr.cardMeta(for: id)
            return CaptureManager.mainThreadTranscriptDecodesForTests == 0
        }
        XCTAssertEqual(mgr.cardMeta(for: id)?.title, "The real Kiln title",
                       "and the settled, memory-served answer is the fresh one")
    }

    /// The SAME contract for the capture that is being recorded RIGHT NOW — the case the
    /// test above does not reach, and the one where it is easiest to get wrong.
    ///
    /// The ACTIVE capture's sidecar re-warm is THROTTLED (`liveSidecarRewarmInterval`, 5s):
    /// a second invalidation inside the window does not start a re-read, it schedules one for
    /// the end of the window AND discards the warm already in flight. That leaves the memo
    /// WARM but known-stale, so a freshness rule that only asks "is a re-read in flight?"
    /// would happily serve a card the manager was just told is out of date — for up to five
    /// seconds, on the one conversation whose card is actively being written (the status
    /// poller merges the door's title/summary into it while it records).
    func testActiveCaptureCardIsNeverServedStaleWhileItsRewarmIsThrottled() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        seedLibrary(dir: dir, count: 3)
        let src = TestSource()
        let mgr = await makeManager(dir: dir, source: src)

        src.onState?(.streaming)
        RealOmiFrames.openSession(src.onFrame)
        try await waitUntil { mgr.active != nil }
        let liveId = try XCTUnwrap(mgr.active?.captureId)
        XCTAssertTrue(mgr.isCapturing, "premise: this capture is the LIVE one")

        ConversationCardStore.save(ConversationCardMeta(title: "Provisional title",
                                                        summary: "First pass."),
                                   captureId: liveId, baseDir: dir)
        // Get the memo into the WARM-and-fresh state for the live capture. `beginSession` has
        // already opened a re-warm window, so this invalidation may itself be throttled —
        // hence a timeout comfortably longer than `liveSidecarRewarmInterval`.
        mgr.invalidateSidecar(liveId)
        try await waitUntil(timeout: 15) {
            CaptureManager.resetMainThreadTranscriptDecodesForTests()
            let title = mgr.cardMeta(for: liveId)?.title
            return title == "Provisional title"
                && CaptureManager.mainThreadTranscriptDecodesForTests == 0
        }

        // Now the poller merges the door's real title, behind the manager's back, and
        // invalidates INSIDE the throttle window — the throttled branch.
        ConversationCardStore.merge(captureId: liveId, baseDir: dir,
                                    title: "The live door title", summary: "Merged.",
                                    stage: "in_lore")
        mgr.invalidateSidecar(liveId)
        XCTAssertTrue(mgr.warmSidecarMemoCountForTests > 0,
                      "premise: the memo is still WARM (the throttled branch does not drop it)")
        XCTAssertEqual(mgr.cardMeta(for: liveId)?.title, "The live door title",
                       "the LIVE capture's card must not be served stale while its re-warm " +
                       "waits out the throttle window")

        // …and the same rule for the other memo-served per-row fact.
        TranscriptCacheStore.save(
            CachedTranscript(transcript: "A real transcript landed for the live capture.",
                             title: "The live door title", summary: "Merged.", fetchedAt: 100),
            captureId: liveId, baseDir: dir)
        mgr.invalidateSidecar(liveId)
        XCTAssertTrue(mgr.hasCachedTranscript(liveId),
                      "a transcript cached for the LIVE capture is visible to the very next read")
    }

    /// The memory win of `rebuild_is_byte_independent_and_disk_free` must survive the
    /// memoization: the memo may NOT retain a conversation's transcript text. A card whose
    /// provisional body is a full transcript is kept only as a bounded head.
    func testMemoDoesNotRetainProvisionalTranscriptText() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let long = String(repeating: "We reviewed the launch plan and agreed on the date. ", count: 500)
        XCTAssertGreaterThan(long.count, 20_000, "premise: a genuinely large provisional body")
        ConversationCardStore.seedProvisional(captureId: "omi-BIG", baseDir: dir,
                                              transcript: long, title: "Launch review")
        let mgr = await makeManager(dir: dir, source: TestSource())
        // The BOUNDED head is what the MEMO serves; a cold memo legitimately falls through to
        // disk and returns the full body. Wait for the warm before asserting on the bound.
        try await waitForWarmMemos(mgr, atLeast: 1)

        let head = try XCTUnwrap(mgr.cardMeta(for: "omi-BIG")?.provisionalTranscript)
        XCTAssertLessThanOrEqual(head.count, CaptureManager.CardFacts.provisionalHeadChars,
                                 "the memo keeps a BOUNDED head, never the whole transcript")
        XCTAssertTrue(long.hasPrefix(head), "and the head is a true prefix of the real body")
        // The full body is still there for the paths that genuinely need it (detail view,
        // search) — memoizing the head loses nothing, it just keeps it off the render path.
        XCTAssertEqual(ConversationCardStore.load(captureId: "omi-BIG", baseDir: dir)?
            .provisionalTranscript?.count, long.count)
    }

    // MARK: C — grouping

    /// Removing the redundant re-sort must not change ANYTHING the list shows. Over a real
    /// hydrated library, the presorted grouping is identical to the sorting one: same section
    /// titles, in the same order, with the same rows in each.
    func testPresortedGroupingIsIdenticalToSortingGrouping() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Spread the library over ~4 months so it spans every bucket kind: today, yesterday,
        // weekday, "Last week", "N weeks ago", and month names.
        let now = UInt64(max(0, Date().timeIntervalSince1970))
        for i in 0..<120 {
            let id = String(format: "omi-cap-%05d", i)
            let started = now - UInt64(i * 26 * 3600)   // ~26h apart
            ConversationMetaStore.save(ConversationMeta(startedAt: started, endedAt: started + 480),
                                       captureId: id, baseDir: dir)
            ConversationCardStore.save(
                ConversationCardMeta(title: "Conversation \(i)", summary: "Summary \(i)."),
                captureId: id, baseDir: dir)
            TranscriptCacheStore.save(
                CachedTranscript(transcript: "We reviewed the launch plan and agreed on a date.",
                                 title: "Conversation \(i)", summary: "Summary \(i).", fetchedAt: 100),
                captureId: id, baseDir: dir)
        }
        let mgr = await makeManager(dir: dir, source: TestSource())
        let rows = mgr.visibleCaptures
        XCTAssertGreaterThanOrEqual(rows.count, 118, "the spread library hydrated")

        let at = Date()
        let sorted = ConversationGrouping.group(rows, now: at) { mgr.conversationStartDate($0) }
        let presorted = ConversationGrouping.groupPresorted(rows, now: at) { mgr.conversationStartDate($0) }

        XCTAssertGreaterThan(sorted.count, 4, "premise: the library really spans several buckets")
        XCTAssertEqual(presorted.map(\.title), sorted.map(\.title),
                       "section titles and their order are unchanged")
        XCTAssertEqual(presorted.map { $0.items.map(\.captureId) },
                       sorted.map { $0.items.map(\.captureId) },
                       "membership and row order within every section are unchanged")
        XCTAssertEqual(presorted.flatMap { $0.items.map(\.captureId) }, rows.map(\.captureId),
                       "and the flattened list is exactly the list the manager published")
    }

    /// No `DateFormatter` is allocated per row or per section on a render path: grouping a
    /// large, bucket-spanning library moves the allocation count by at most the number of
    /// distinct (format, calendar) pairs — two — no matter how many rows are grouped.
    func testGroupingAllocatesNoDateFormatterPerRow() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        struct Item: Sendable { let date: Date }
        let items = (0..<400).map { Item(date: now.addingTimeInterval(-Double($0) * 26 * 3600)) }

        // Warm whatever this calendar needs, then prove a SECOND pass allocates nothing.
        _ = ConversationGrouping.groupPresorted(items, now: now, calendar: cal) { $0.date }
        let before = ConversationGrouping.formatterAllocationsForTests
        let sections = ConversationGrouping.groupPresorted(items, now: now, calendar: cal) { $0.date }
        let after = ConversationGrouping.formatterAllocationsForTests
        print("RESIDUAL C: grouped \(items.count) rows into \(sections.count) sections, " +
              "formatter allocations \(before)→\(after)")

        XCTAssertGreaterThan(sections.count, 4, "premise: the input really spans several buckets")
        XCTAssertEqual(after, before,
                       "grouping \(items.count) rows allocated \(after - before) DateFormatters — " +
                       "a formatter must never be built per row or per section")
    }
}
