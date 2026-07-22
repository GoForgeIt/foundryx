import XCTest
import Foundation
@testable import FoundryXKit

/// GREEN acceptance for the track `20260722T1244_rebuild_is_byte_independent_and_disk_free`.
///
/// `HangReproTests` pins the two measured stalls (cold-memo rebuild, first post-hydration
/// sort) at ONE library size. These tests pin the two PROPERTIES that keep them fixed:
///
///  1. **Bytes-independence** — the rebuild is no longer O(total transcript bytes). A ~10×
///     larger transcript corpus must not cost ~10× more per rebuild. This is the property
///     that stops an ambient recorder degrading every day it succeeds: transcript bytes only
///     ever grow, so a rebuild that is linear in them is a permanent, worsening stall.
///  2. **No flicker (R3)** — because a rebuild may no longer read disk on the main actor, an
///     invalidated sidecar is re-warmed OFF-main. A conversation must never appear, vanish
///     and reappear while those warm values land: list membership must be STABLE across the
///     invalidation, the immediate rebuild, and every rebuild after the warms settle.
///
/// Isolation is NON-NEGOTIABLE: every test uses a FRESH tempDir — the real `~/.foundry` /
/// `~/.lore` are never touched.
@MainActor
final class RebuildBytesIndependenceTests: XCTestCase {

    private static let libraryN = 175
    private static let coldK = 40

    /// Baseline corpus — the SAME realistic skew `HangReproTests` seeds (9 heavy @1200 segs
    /// + 166 light @120 segs ≈ 7.9MB of transcripts).
    private static let baselineShape = (heavySegments: 1200, heavyParagraphs: 300,
                                        lightSegments: 120, lightParagraphs: 25, heavyEvery: 20)
    /// ~10× corpus — EVERY conversation is a long meeting, at ~1.4× the heavy size
    /// (175 × ~455KB ≈ 78MB ≈ 10× the baseline's 7.9MB).
    private static let bigShape = (heavySegments: 1700, heavyParagraphs: 400,
                                   lightSegments: 1700, lightParagraphs: 400, heavyEvery: 1)

    private final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    private static let sentences: [String] = [
        "We reviewed the launch plan and agreed on the release date for next Thursday.",
        "The relay numbers looked strong, though the tail latency still needs another pass.",
        "Sarah owns the numbers section and will send the revised deck by tonight.",
        "Let's protect Thursday morning for the deep-work block on the pricing model.",
        "The inspection is Friday, and after that we can lock the house timeline.",
        "I'll call the lender this afternoon and make sure the paperwork is ready to go.",
        "A usage-based tier could unlock the mid-market, so it's worth modeling this week.",
        "Data-integration friction and stakeholder comms took most of the hour again.",
        "We decided to shift ten percent of Q3 spend into growth and revisit in a month.",
        "Book the venue for the launch by Friday and confirm the headcount with catering.",
    ]

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-bytesindep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeManager(dir: URL) async -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let m = CaptureManager(target: target, baseDir: dir, source: TestSource(),
                               finalize: { _, _ in }, deleteCapture: { _ in },
                               fetchContent: { _ in nil })
        await m.hydration?.value
        return m
    }

    private func measureMainActorMs(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }

    private func transcript(index: Int, shape: (heavySegments: Int, heavyParagraphs: Int,
                                                lightSegments: Int, lightParagraphs: Int,
                                                heavyEvery: Int)) -> CachedTranscript {
        let n = Self.sentences.count
        let heavy = index % shape.heavyEvery == 0
        let segs = heavy ? shape.heavySegments : shape.lightSegments
        let paras = heavy ? shape.heavyParagraphs : shape.lightParagraphs
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(segs)
        for s in 0..<segs {
            segments.append(TranscriptSegment(
                seq: s, startMs: s * 4000, endMs: s * 4000 + 3500,
                text: Self.sentences[(s + index) % n], speaker: "speaker_\(s % 4)"))
        }
        var paragraphs: [TranscriptParagraph] = []
        paragraphs.reserveCapacity(paras)
        for p in 0..<paras {
            paragraphs.append(TranscriptParagraph(
                start: Double(p) * 8, end: Double(p) * 8 + 7,
                speaker: "speaker_\(p % 4)", text: Self.sentences[(p * 3 + index) % n]))
        }
        let speakers = (0..<4).map {
            CaptureSpeaker(slot: "speaker_\($0)", status: .confirmed,
                           name: "Speaker \($0)", confirmedSpeakerId: "spk-\($0)")
        }
        return CachedTranscript(transcript: segments.map(\.text).joined(separator: " "),
                                title: "Conversation \(index)",
                                summary: "A long, real conversation with many segments.",
                                segments: segments, speakers: speakers, paragraphs: paragraphs,
                                fetchedAt: 100)
    }

    @discardableResult
    private func seed(dir: URL, count: Int,
                      shape: (heavySegments: Int, heavyParagraphs: Int,
                              lightSegments: Int, lightParagraphs: Int, heavyEvery: Int)) -> [String] {
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
                                     summary: "Synthetic library card \(i) with a realistic summary.",
                                     stage: "in_lore"),
                captureId: id, baseDir: dir)
            TranscriptCacheStore.save(transcript(index: i, shape: shape), captureId: id, baseDir: dir)
        }
        return ids
    }

    private func transcriptBytes(in dir: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .reduce(0) { acc, d in
                acc + ((try? Data(contentsOf: d.appendingPathComponent("transcript.json")).count) ?? 0)
            }) ?? 0
    }

    /// Measure the SAME cold-memo rebuild `HangReproTests` Test A measures, at one corpus size.
    private func rebuildMs(shape: (heavySegments: Int, heavyParagraphs: Int,
                                   lightSegments: Int, lightParagraphs: Int, heavyEvery: Int),
                           label: String) async throws -> (ms: Double, bytes: Int) {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let ids = seed(dir: dir, count: Self.libraryN, shape: shape)
        let bytes = transcriptBytes(in: dir)
        let mgr = await makeManager(dir: dir)
        XCTAssertGreaterThanOrEqual(mgr.visibleCaptures.count, Self.libraryN - 2,
                                    "\(label): the library hydrated and is visible")
        // A live write batch: K sidecars just changed on disk (the real invalidation seam).
        for id in ids.prefix(Self.coldK) { mgr.invalidateSidecar(id) }
        CaptureManager.resetMainThreadTranscriptDecodesForTests()
        // Take the BEST of 3 — this compares two corpus sizes, so scheduler noise on a busy
        // CI box must not decide the verdict; the shape of the curve is what's under test.
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 { best = min(best, measureMainActorMs { mgr.rebuildVisibleCapturesForTests() }) }
        XCTAssertEqual(CaptureManager.mainThreadTranscriptDecodesForTests, 0,
                       "\(label): a rebuild does ZERO synchronous main-actor decodes")
        print("BYTES-INDEP \(label): rebuild=\(String(format: "%.1f", best))ms " +
              "corpus=\(bytes / 1024)KB (N=\(Self.libraryN))")
        return (best, bytes)
    }

    /// THE property: ~10× the transcript bytes must NOT cost ~10× the rebuild. Before this
    /// track, 94MB took 4212ms against 7.9MB's 379ms (11.9× data → 11.1× time) — dead-linear
    /// in bytes. The rebuild now reads cached counts, so the curve must be flat: the big
    /// corpus stays within ~2× of the baseline (with a small absolute floor so a sub-10ms
    /// measurement can't fail on scheduler noise alone).
    func testRebuildIsIndependentOfTranscriptBytes() async throws {
        let small = try await rebuildMs(shape: Self.baselineShape, label: "baseline")
        let big = try await rebuildMs(shape: Self.bigShape, label: "10x")

        XCTAssertGreaterThan(Double(big.bytes) / Double(max(1, small.bytes)), 8.0,
                             "test premise: the big corpus really is ~10× the transcript bytes")
        let budget = max(2.0 * small.ms, 25.0)
        XCTAssertLessThan(big.ms, budget,
                          "the rebuild must be independent of transcript bytes — " +
                          "\(String(format: "%.1f", big.ms))ms at \(big.bytes / 1024)KB vs " +
                          "\(String(format: "%.1f", small.ms))ms at \(small.bytes / 1024)KB " +
                          "(budget \(String(format: "%.1f", budget))ms)")
    }

    /// R3 — invalidating memos MID-LIST must not churn the list. The invalidated captures'
    /// sidecars are re-read OFF the main actor, so the rebuild that runs in between renders
    /// from the LAST-KNOWN snapshot: membership is identical immediately, and still identical
    /// once every warm value has landed. No conversation appears, vanishes, then reappears.
    func testInvalidatedMemosMidListKeepStableMembership() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let ids = seed(dir: dir, count: 60, shape: Self.baselineShape)
        let mgr = await makeManager(dir: dir)
        let before = mgr.visibleCaptures.map(\.captureId)
        XCTAssertGreaterThanOrEqual(before.count, 58, "the library hydrated and is visible")

        // Invalidate every 3rd capture — a live write batch scattered THROUGH the list, not
        // at one end, so a membership wobble would show as a gap mid-scroll.
        CaptureManager.resetMainThreadTranscriptDecodesForTests()   // counter is process-global
        for (i, id) in ids.enumerated() where i % 3 == 0 { mgr.invalidateSidecar(id) }

        // The very next rebuild — the one a live write triggers — must be identical.
        mgr.rebuildVisibleCapturesForTests()
        XCTAssertEqual(mgr.visibleCaptures.map(\.captureId), before,
                       "membership is unchanged the instant the memos are invalidated " +
                       "(no vanish while the fresh values are read off-main)")

        // …and identical again after every off-main re-warm has landed and re-rendered.
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 25_000_000)
            XCTAssertEqual(mgr.visibleCaptures.map(\.captureId), before,
                           "membership never wobbles while warm values land")
        }
        mgr.rebuildVisibleCapturesForTests()
        XCTAssertEqual(mgr.visibleCaptures.map(\.captureId), before,
                       "membership is identical once every warm sidecar has landed")
        XCTAssertEqual(CaptureManager.mainThreadTranscriptDecodesForTests, 0,
                       "and none of it read a transcript off disk on the main actor")
    }

    /// The warm values really do land (the stale-read window closes): a transcript written
    /// behind the manager's back, followed by the ordinary invalidation, changes membership
    /// WITHOUT any main-actor disk read — proving the off-main re-warm + re-render works and
    /// the no-flicker rule isn't just "never update".
    func testOffMainRewarmEventuallyAppliesTheFreshValue() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // A filler-only card → hidden at hydration.
        ConversationCardStore.seedProvisional(captureId: "omi-LATE", baseDir: dir,
                                              transcript: "Thank you.", title: "Thank you")
        let mgr = await makeManager(dir: dir)
        XCTAssertFalse(mgr.visibleCaptures.contains { $0.captureId == "omi-LATE" },
                       "a near-silent filler capture starts hidden")

        // A real transcript lands on disk, then the ordinary invalidation fires.
        TranscriptCacheStore.save(
            CachedTranscript(transcript: "Let's review the launch plan and choose a release date.",
                             title: "Launch", summary: nil, fetchedAt: 100),
            captureId: "omi-LATE", baseDir: dir)
        CaptureManager.resetMainThreadTranscriptDecodesForTests()
        mgr.invalidateSidecar("omi-LATE")

        let deadline = Date().addingTimeInterval(3)
        while !mgr.visibleCaptures.contains(where: { $0.captureId == "omi-LATE" }) {
            if Date() > deadline { XCTFail("the off-main re-warm never applied"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(CaptureManager.mainThreadTranscriptDecodesForTests, 0,
                       "the fresh value arrived WITHOUT a synchronous main-actor decode")
    }
}
