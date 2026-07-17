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
}
