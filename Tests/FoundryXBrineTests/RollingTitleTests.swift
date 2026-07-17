import XCTest
import Foundation
import AVFoundation
import FoundryXKit

/// The rolling live title reads the WHOLE conversation so far — not the last few
/// seconds (features/recording-instrument.feature, "the name reflects the whole
/// conversation, not the last words"; track 20260717T1015).
///
/// Root cause pinned here: the live transcribers bound `finalizedText` to a rolling
/// 80-word tail, and the old title took the first 6 words of that tail — i.e. what
/// was said ~80 words ago, sliding forward. These tests pin the replacement: a
/// bounded whole-conversation `titleContext` (head + rolling tail), a whole-text
/// salience heuristic, the anti-flicker arbiter, and the manager-owned `liveTitle`.
final class RollingTitleTests: XCTestCase {

    // MARK: RollingTitleContext — the bounded whole-conversation accumulator

    func testContextKeepsTheHeadAndTheTail() {
        var ctx = RollingTitleContext()
        ctx.ingest(final: "We are planning the kitchen renovation budget for the spring")
        // Push way past the head+tail budgets with filler paragraphs.
        for i in 0..<400 {
            ctx.ingest(final: "then we talked more about paint samples and floor tiles number \(i)")
        }
        ctx.ingest(final: "so the contractor timeline needs permits before June")
        let text = ctx.text
        XCTAssertTrue(text.contains("kitchen renovation budget"),
                      "the conversation's HEAD survives — the whole point of the fix")
        XCTAssertTrue(text.contains("contractor timeline needs permits"),
                      "the newest words survive too")
        XCTAssertLessThanOrEqual(
            text.count, RollingTitleContext.headBudget + RollingTitleContext.tailBudget + 256,
            "the context is bounded — O(1) in session length")
    }

    func testContextReplaceAllBoundsLongText() {
        var ctx = RollingTitleContext()
        let head = "Quarterly budget review for the hardware team"
        let filler = Array(repeating: "some ordinary middle words about various agenda items", count: 300)
            .joined(separator: " ")
        let tail = "and finally the offsite is in Denver this year"
        ctx.replaceAll(head + " " + filler + " " + tail)
        XCTAssertTrue(ctx.text.contains("Quarterly budget review"))
        XCTAssertTrue(ctx.text.contains("offsite is in Denver"))
        XCTAssertLessThanOrEqual(
            ctx.text.count, RollingTitleContext.headBudget + RollingTitleContext.tailBudget + 256)
    }

    // MARK: WholeConversationTitle — the cheap whole-text heuristic

    func testNoTitleUntilEnoughSaid() {
        XCTAssertNil(WholeConversationTitle.heuristic(from: ""))
        XCTAssertNil(WholeConversationTitle.heuristic(from: "So um yeah okay"))
    }

    func testShortConversationTitlesFromFirstSubstantiveWords() {
        // Early on, the opening words name it — but fillers are skipped.
        let t = WholeConversationTitle.heuristic(
            from: "okay so um let's plan the launch for the October release and split the work")
        let title = try! XCTUnwrap(t)
        XCTAssertFalse(title.lowercased().hasPrefix("okay"), "leading filler is not a name")
        XCTAssertTrue(title.lowercased().contains("launch"),
                      "the first substantive utterance names a young conversation")
    }

    func testLongConversationTitleReflectsTheWholeText() {
        // A conversation that OPENS on the kitchen-renovation budget, wanders, and
        // ends on contractor timelines. The old last-segment title would only ever
        // see the tail; the whole-text heuristic must keep the early salient topic.
        var text = "The kitchen renovation budget is the big topic today, the kitchen budget matters. "
        // A long wandering middle of one-off words (no term recurs) — realistic
        // chatter that must not out-rank the conversation's recurring topics.
        text += (0..<200).map { "chatterword\($0)" }.joined(separator: " ") + " "
        text += "The contractor said the timeline depends on permits, the contractor timeline and permits again."
        let title = try! XCTUnwrap(WholeConversationTitle.heuristic(from: text))
        let lower = title.lowercased()
        XCTAssertTrue(lower.contains("kitchen") || lower.contains("budget"),
                      "an early salient topic survives into the title: \(title)")
        XCTAssertTrue(lower.contains("contractor") || lower.contains("timeline") || lower.contains("permits"),
                      "a late salient topic is represented too: \(title)")
        XCTAssertLessThanOrEqual(title.split(separator: " ").count, 6, "titles stay short")
    }

    func testHeuristicIsDeterministic() {
        let text = "Planning the offsite agenda with the platform team about budget and hiring "
            + "and the budget again and hiring plans for the platform group"
        XCTAssertEqual(WholeConversationTitle.heuristic(from: text),
                       WholeConversationTitle.heuristic(from: text))
    }

    // MARK: LiveTitleArbiter — a settled title does not jitter

    func testFirstCandidateIsAccepted() {
        let s = LiveTitleArbiter.merged(current: nil, candidateText: "Kitchen Renovation Budget",
                                        tier: .heuristic)
        XCTAssertEqual(s?.text, "Kitchen Renovation Budget")
    }

    func testSimilarSameTierCandidateKeepsTheCurrentTitle() {
        let current = LiveTitleState(text: "Kitchen Renovation Budget Timeline", tier: .heuristic)
        let s = LiveTitleArbiter.merged(current: current,
                                        candidateText: "Kitchen Renovation Budget Permits",
                                        tier: .heuristic)
        XCTAssertEqual(s, current, "one word of drift is not a new name — no flicker")
    }

    func testMeaningfullyDifferentSameTierCandidateReplaces() {
        let current = LiveTitleState(text: "Kitchen Renovation Budget", tier: .heuristic)
        let s = LiveTitleArbiter.merged(current: current,
                                        candidateText: "Contractor Permits Timeline June",
                                        tier: .heuristic)
        XCTAssertEqual(s?.text, "Contractor Permits Timeline June",
                       "a genuinely different conversation earns a new name")
    }

    func testModelTitleReplacesHeuristicAndNeverTheReverse() {
        let heuristic = LiveTitleState(text: "Kitchen Budget Contractor Timeline", tier: .heuristic)
        let upgraded = LiveTitleArbiter.merged(current: heuristic,
                                               candidateText: "Kitchen renovation planning",
                                               tier: .model)
        XCTAssertEqual(upgraded?.tier, .model, "the smarter on-device title wins")
        XCTAssertEqual(upgraded?.text, "Kitchen renovation planning")
        let after = LiveTitleArbiter.merged(current: upgraded,
                                            candidateText: "Totally Different Heuristic Words",
                                            tier: .heuristic)
        XCTAssertEqual(after, upgraded, "a heuristic never overwrites a model title")
    }

    func testEmptyCandidateNeverClearsATitle() {
        let current = LiveTitleState(text: "Kitchen Budget", tier: .model)
        XCTAssertEqual(LiveTitleArbiter.merged(current: current, candidateText: "  ", tier: .model),
                       current)
        XCTAssertNil(LiveTitleArbiter.merged(current: nil, candidateText: "", tier: .heuristic))
    }

    // MARK: external tier outranks the on-device placeholder (track 20260717T1500)

    func testExternalTitleReplacesBothHeuristicAndModel() {
        // The external (Fireworks-via-door) refresh is the sharpest tier: it takes over
        // from the instant on-device placeholder even when the placeholder is model-tier.
        let placeholder = LiveTitleState(text: "Kitchen renovation planning", tier: .model)
        let sharpened = LiveTitleArbiter.merged(current: placeholder,
                                                candidateText: "Kitchen remodel budget and permits",
                                                tier: .external)
        XCTAssertEqual(sharpened?.tier, .external, "the external title outranks the on-device model")
        XCTAssertEqual(sharpened?.text, "Kitchen remodel budget and permits")
        // …and neither a later heuristic nor a later on-device model can downgrade it.
        let afterHeuristic = LiveTitleArbiter.merged(current: sharpened,
                                                     candidateText: "Totally Different Words Here",
                                                     tier: .heuristic)
        XCTAssertEqual(afterHeuristic, sharpened, "a heuristic never overwrites an external title")
        let afterModel = LiveTitleArbiter.merged(current: sharpened,
                                                 candidateText: "A Different On Device Guess",
                                                 tier: .model)
        XCTAssertEqual(afterModel, sharpened, "the on-device model never overwrites an external title")
    }

    func testExternalRefreshOnlyReplacesWhenMeaningfullyDifferent() {
        // Once an external title is settled, another external refresh must not jitter it
        // for a near-identical result (anti-flicker: same tier → similarity gate).
        let settled = LiveTitleState(text: "Kitchen remodel budget and permits", tier: .external)
        let similar = LiveTitleArbiter.merged(current: settled,
                                              candidateText: "Kitchen remodel budget permits timeline",
                                              tier: .external)
        XCTAssertEqual(similar, settled, "a near-identical external refresh does not rewrite the title")
        let different = LiveTitleArbiter.merged(current: settled,
                                                candidateText: "Vacation flights to Lisbon in June",
                                                tier: .external)
        XCTAssertEqual(different?.text, "Vacation flights to Lisbon in June",
                       "a genuinely different external title earns the replacement")
    }

    // MARK: the exponential backoff schedule (pure)

    func testBackoffScheduleDoublesFromOneMinuteAndCapsAtThirty() {
        let b = LiveTitleBackoff.default   // firstDelay 60s, x2, ceiling 1800s
        XCTAssertEqual(b.delay(afterRefreshes: 0), 60, "first refresh at ~1 min")
        XCTAssertEqual(b.delay(afterRefreshes: 1), 120, "then +2 min")
        XCTAssertEqual(b.delay(afterRefreshes: 2), 240, "then +4 min")
        XCTAssertEqual(b.delay(afterRefreshes: 3), 480, "then +8 min")
        XCTAssertEqual(b.delay(afterRefreshes: 4), 960, "then +16 min")
        XCTAssertEqual(b.delay(afterRefreshes: 5), 1800, "then capped at 30 min (not 32)")
        XCTAssertEqual(b.delay(afterRefreshes: 6), 1800, "and stays capped")
        XCTAssertEqual(b.delay(afterRefreshes: 20), 1800, "still capped far out")
    }

    func testBackoffNeverExceedsCeilingEvenWithATinyFirstDelay() {
        let b = LiveTitleBackoff(firstDelay: 5, multiplier: 3, ceiling: 20)
        XCTAssertEqual(b.delay(afterRefreshes: 0), 5)
        XCTAssertEqual(b.delay(afterRefreshes: 1), 15)
        XCTAssertEqual(b.delay(afterRefreshes: 2), 20, "min(45, 20)")
        XCTAssertEqual(b.delay(afterRefreshes: -3), 5, "negative clamps to the first delay")
    }

    // MARK: the manager owns ONE live title for both surfaces

    @MainActor
    final class Fixtures {
        final class TestSource: AudioFrameSource, @unchecked Sendable {
            var onFrame: ((Data) -> Void)?
            var onState: ((AudioSourceState) -> Void)?
            func start() {}
            func stop() {}
        }

        final class FakeLiveTranscriber: LiveTranscribing, @unchecked Sendable {
            let transcript: AsyncStream<LiveTranscript>
            private let cont: AsyncStream<LiveTranscript>.Continuation
            init() {
                var c: AsyncStream<LiveTranscript>.Continuation!
                transcript = AsyncStream { c = $0 }
                cont = c
            }
            func start() async throws {}
            func append(_ pcm: AVAudioPCMBuffer) {}
            func finish() async -> String { cont.finish(); return "" }
            func emit(_ t: LiveTranscript) { cont.yield(t) }
        }

        /// A deterministic on-device titler standing in for Foundation Models.
        final class FakeTitler: LocalTitleSummary, @unchecked Sendable {
            let title: String
            private let lock = NSLock()
            private var _calls = 0
            var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
            init(title: String) { self.title = title }
            var isAvailable: Bool { true }
            private func bump() { lock.lock(); _calls += 1; lock.unlock() }
            func titleAndSummary(for transcript: String) async throws -> (title: String, summary: String) {
                bump()
                return (title, "summary")
            }
        }

        /// Hands out a FRESH transcriber per conversation (a split/roll makes a new one)
        /// and remembers the latest, so a test can pump the current conversation.
        final class FakeFactory: @unchecked Sendable {
            private let lock = NSLock()
            private var made: [FakeLiveTranscriber] = []
            func make() -> FakeLiveTranscriber { let f = FakeLiveTranscriber(); lock.lock(); made.append(f); lock.unlock(); return f }
            var last: FakeLiveTranscriber? { lock.lock(); defer { lock.unlock() }; return made.last }
        }

        /// A stand-in for the door's external live-title route: records every call
        /// (captureId, history, seq) and either returns a sharpened title or throws
        /// (offline). Thread-safe so it can back the `@Sendable` closure seam.
        final class ExternalRecorder: @unchecked Sendable {
            struct Call: Sendable { let captureId: String; let history: String; let seq: Int }
            private let lock = NSLock()
            private var _calls: [Call] = []
            private let reply: String?
            private let fails: Bool
            init(reply: String?, fails: Bool = false) { self.reply = reply; self.fails = fails }
            var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
            var count: Int { lock.lock(); defer { lock.unlock() }; return _calls.count }
            func closure() -> @Sendable (String, String, Int) async throws -> String? {
                { [self] captureId, history, seq in
                    lock.withLock { _calls.append(Call(captureId: captureId, history: history, seq: seq)) }
                    if fails { throw DoorError.transport("offline") }
                    return reply
                }
            }
        }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ cond: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out waiting"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-rolling-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A finalized snapshot carrying the whole-conversation context (what the real
    /// transcribers now publish alongside the bounded display tail).
    private func finalSnap(_ context: String) -> LiveTranscript {
        LiveTranscript(finalizedText: LiveTranscriptBuffer.boundedTail(context),
                       volatileTail: "", titleContext: context)
    }

    @MainActor
    func testManagerLiveTitleTracksTheWholeConversationAndUpgradesToModel() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = Fixtures.TestSource()
        let fake = Fixtures.FakeLiveTranscriber()
        let titler = Fixtures.FakeTitler(title: "Kitchen renovation planning")
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        // Cadence collapsed for the test: every final may refresh, model gate open.
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { _, _ in },
                                 liveTranscriber: { fake },
                                 liveTitler: titler,
                                 liveTitleCadence: LiveTitleCadence(
                                     heuristicMinNewWords: 1, modelMinWords: 4,
                                     modelMinNewWords: 1, modelRefreshSeconds: 0))

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        XCTAssertNil(mgr.liveTitle, "nothing said yet → no name")

        // A young conversation: the heuristic names it from the whole context.
        let young = "okay so the kitchen renovation budget is our topic today for planning"
        fake.emit(finalSnap(young))
        try await waitUntil { mgr.liveTitle != nil }
        XCTAssertTrue(mgr.liveTitle!.lowercased().contains("kitchen"),
                      "the title comes from the whole conversation context")

        // The (fake) on-device titler then upgrades it — and it sticks: a later
        // heuristic-worthy final may not overwrite the model title.
        try await waitUntil { mgr.liveTitle == "Kitchen renovation planning" }
        let grown = young + " " + Array(repeating: "totally different closing topic about permits",
                                        count: 12).joined(separator: " ")
        fake.emit(finalSnap(grown))
        try await Task.sleep(nanoseconds: 150_000_000)
        // Still model-tier text (the fake titler always returns the same title, and
        // heuristics can't downgrade it).
        XCTAssertEqual(mgr.liveTitle, "Kitchen renovation planning")
    }

    @MainActor
    func testLiveTitleClearsWhenTheConversationEnds() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = Fixtures.TestSource()
        let fake = Fixtures.FakeLiveTranscriber()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { _, _ in },
                                 liveTranscriber: { fake },
                                 liveTitleCadence: LiveTitleCadence(
                                     heuristicMinNewWords: 1, modelMinWords: 999,
                                     modelMinNewWords: 999, modelRefreshSeconds: 3600))

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        fake.emit(finalSnap("planning the quarterly platform budget with the whole team today"))
        try await waitUntil { mgr.liveTitle != nil }

        mgr.endCurrentConversation()
        try await waitUntil { mgr.liveTitle == nil }
    }

    // MARK: two-tier live title — instant placeholder + external backoff refresh

    /// firstDelay 0 so the external refresh fires on the first eligible finalized
    /// snapshot: the heuristic placeholder appears instantly, then the external
    /// (Fireworks-via-door) refresh SHARPENS it — and the door receives the WHOLE
    /// conversation history, not just the recent words.
    @MainActor
    func testExternalRefreshSharpensTheInstantPlaceholderWithWholeHistory() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = Fixtures.TestSource()
        let fake = Fixtures.FakeLiveTranscriber()
        let recorder = Fixtures.ExternalRecorder(reply: "Fireworks Sharpened Title")
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { _, _ in },
                                 liveTranscriber: { fake },
                                 liveTitler: nil,   // heuristic-only placeholder (isolate external)
                                 liveTitleExternal: recorder.closure(),
                                 liveTitleBackoff: LiveTitleBackoff(firstDelay: 0, multiplier: 2, ceiling: 1))

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }

        let context = "okay so the kitchen renovation budget is our topic today for planning cabinets and counters"
        fake.emit(finalSnap(context))
        // The instant placeholder appears (heuristic, no network), then the external wins.
        try await waitUntil { mgr.liveTitle != nil }
        try await waitUntil { mgr.liveTitle == "Fireworks Sharpened Title" }

        let firstCall = try XCTUnwrap(recorder.calls.first)
        XCTAssertEqual(firstCall.seq, 0, "the first live-title request carries seq 0")
        XCTAssertTrue(firstCall.history.lowercased().contains("kitchen renovation budget"),
                      "the door receives the WHOLE conversation history, not just recent words")
        XCTAssertFalse(mgr.active?.captureId.isEmpty ?? true)
        XCTAssertEqual(firstCall.captureId, mgr.active?.captureId, "keyed by the phone capture id")
    }

    /// Door unreachable / offline: the external refresh throws, the on-device (here
    /// heuristic) title STANDS, and after the failure budget the door stops being asked.
    @MainActor
    func testOfflineKeepsTheOnDeviceTitleAndStopsAskingAfterFailures() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = Fixtures.TestSource()
        let fake = Fixtures.FakeLiveTranscriber()
        let recorder = Fixtures.ExternalRecorder(reply: nil, fails: true)
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { _, _ in },
                                 liveTranscriber: { fake },
                                 liveTitler: nil,
                                 liveTitleExternal: recorder.closure(),
                                 liveTitleBackoff: LiveTitleBackoff(firstDelay: 0, multiplier: 2, ceiling: 1))

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }

        // Emit a growing conversation so each new snapshot is an eligible tick.
        var context = "planning the quarterly platform budget with the whole team today for the offsite"
        for i in 0..<6 {
            context += " and then topic\(i) and detail\(i) about the roadmap and hiring plans"
            fake.emit(finalSnap(context))
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        // Offline still gets a title (the heuristic placeholder), never blank.
        let title = try XCTUnwrap(mgr.liveTitle, "offline must still produce an on-device title")
        XCTAssertFalse(title.isEmpty)
        // The door was asked at most the failure budget, then abandoned — not hammered.
        try await waitUntil { recorder.count >= 3 }
        let settled = recorder.count
        // A couple more snapshots must NOT drive more calls (external disabled for the session).
        context += " one more closing wrap up about the launch timeline and the next steps"
        fake.emit(finalSnap(context))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(recorder.count, settled, "a down door is abandoned, not hammered")
        XCTAssertLessThanOrEqual(settled, 3, "external stops after the failure budget")
    }

    /// The backoff never spends a call on silence: after a successful refresh, a
    /// re-emitted snapshot with NO new words does not trigger another external call.
    @MainActor
    func testExternalSkipsATickWithNoNewWords() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = Fixtures.TestSource()
        let fake = Fixtures.FakeLiveTranscriber()
        let recorder = Fixtures.ExternalRecorder(reply: "Sharpened One")
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { _, _ in },
                                 liveTranscriber: { fake },
                                 liveTitler: nil,
                                 liveTitleExternal: recorder.closure(),
                                 liveTitleBackoff: LiveTitleBackoff(firstDelay: 0, multiplier: 2, ceiling: 1))

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }

        let context = "planning the quarterly platform budget with the whole team today for the offsite agenda"
        fake.emit(finalSnap(context))
        try await waitUntil { recorder.count == 1 }
        // Re-emit the SAME context (no new finalized words) — must not spend another call.
        fake.emit(finalSnap(context))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(recorder.count, 1, "no new words → no external call (never spend on silence)")
        // Genuinely new words → a new refresh is allowed.
        fake.emit(finalSnap(context + " and now a completely new closing topic about vacation flights"))
        try await waitUntil { recorder.count == 2 }
    }

    /// A genuinely NEW conversation (manual split) re-arms the backoff and re-targets:
    /// the external refresh fires again for the new capture id with a fresh seq — and
    /// it is never left stuck "in flight" across the transcriber swap (regression guard).
    @MainActor
    func testNewConversationReArmsExternalAndReTargets() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = Fixtures.TestSource()
        let factory = Fixtures.FakeFactory()
        let recorder = Fixtures.ExternalRecorder(reply: "Sharpened Title")
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: src,
                                 finalize: { _, _ in },
                                 liveTranscriber: { factory.make() },
                                 liveTitler: nil,
                                 liveTitleExternal: recorder.closure(),
                                 liveTitleBackoff: LiveTitleBackoff(firstDelay: 0, multiplier: 2, ceiling: 1))

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil && factory.last != nil }
        let convo1 = try XCTUnwrap(mgr.active?.captureId)
        let sentence = "planning the quarterly platform budget with the whole team today for the offsite agenda"
        factory.last!.emit(finalSnap(sentence))
        try await waitUntil { recorder.count == 1 }
        XCTAssertEqual(recorder.calls[0].seq, 0)
        XCTAssertEqual(recorder.calls[0].captureId, convo1)

        // Manual split → a brand-new conversation (new transcriber + capture id).
        mgr.splitConversation()
        try await waitUntil { mgr.active?.captureId != nil && mgr.active?.captureId != convo1 }
        let convo2 = try XCTUnwrap(mgr.active?.captureId)
        factory.last!.emit(finalSnap("a totally separate discussion about the vacation flights to Lisbon in June"))
        // External is NOT stuck in-flight across the swap: it fires again, re-armed.
        try await waitUntil { recorder.count == 2 }
        XCTAssertEqual(recorder.calls[1].captureId, convo2, "the external refresh re-targets the new conversation")
        XCTAssertEqual(recorder.calls[1].seq, 0, "a fresh conversation resets the request sequence")
    }
}
