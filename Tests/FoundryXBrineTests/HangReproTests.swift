import XCTest
import Foundation
@testable import FoundryXKit

/// RED REPRODUCTION of the ~175-conversation nav-stall (up to 6.6s `nav-stall` telemetry).
///
/// Root mechanism (code-confirmed): `CaptureManager.rebuildVisibleCaptures()` (@MainActor)
/// does O(N) work over all captures, and when a memo is COLD it does SYNCHRONOUS per-capture
/// disk I/O ON THE MAIN ACTOR. On a live device, ongoing writes (segment append, drain ACK,
/// finalize, status-poller card merge) invalidate the sidecar/meta memos, so the next rebuild
/// cold-misses and pays:
///   • driver #3 — `sidecar(for:)` cold miss → `loadSidecar` = a full `transcript.json`
///     decode (+ `card.json` + fileExists stats) on main.
///   • driver #4 — the sort comparator's cold `startTimeCache` → `durableStart` =
///     `meta.json`/`card.json` decode on main (bypasses the meta memo).
///   • driver #2 — `recapConversationPool()` (eager at RootView) → per-capture, deliberately
///     UN-MEMOIZED `cardMeta` = `card.json` decode on main.
///
/// The production perf harness never reproduces this because it drives a STATIC, pre-warmed,
/// read-only library. These tests are FAITHFUL: they seed a HEAVY on-disk library through the
/// REAL stores, warm the caches off-main via real hydration, then leave the relevant memos
/// COLD (a real invalidation, mirroring a live write batch) before measuring on @MainActor.
///
/// Isolation is NON-NEGOTIABLE: every test uses a FRESH tempDir for `baseDir` — real
/// `~/.foundry` / `~/.lore` are never touched (a prior incident wiped real audio from a
/// mis-scoped test).
///
/// These assertions are expected to be RED (this is a diagnosis-validation harness, not a
/// fix): the deterministic decode-counter proves the disk-on-main pathology without depending
/// on wall-clock, and the ms budgets show the stall.
@MainActor
final class HangReproTests: XCTestCase {

    // Library sized to the reported stall onset; K = a plausible live-write invalidation batch.
    private static let libraryN = 175
    private static let coldK = 40
    // REALISTIC SKEW — mirrors DemoSeed and a real ambient library: most conversations are
    // ordinary, ~1 in 20 is a long meeting. Sizing EVERY capture as a 500-paragraph monster
    // inflates the numbers and proves nothing about the real device, so we don't.
    private static let lightSegments = 120, lightParagraphs = 25      // ~30KB transcript.json
    private static let heavySegments = 1200, heavyParagraphs = 300    // ~300KB — a long meeting
    private static let heavyEvery = 20
    private static func shape(_ i: Int) -> (segs: Int, paras: Int) {
        i % heavyEvery == 0 ? (heavySegments, heavyParagraphs) : (lightSegments, lightParagraphs)
    }

    /// A source the test drives directly (start/stop no-ops). Mirrors the other suites.
    private final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    /// Thread-safe accumulator for the PerfHook span-cost diagnostic.
    private final class SpanBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _t = 0
        var total: Int { lock.lock(); defer { lock.unlock() }; return _t }
        func add(_ ms: Int) { lock.lock(); _t += ms; lock.unlock() }
    }

    /// A FRESH, isolated temp dir — NEVER the real `~/.foundry` / `~/.lore`.
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-hangrepro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeManager(dir: URL) async -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let m = CaptureManager(target: target, baseDir: dir, source: TestSource(),
                               finalize: { _, _ in }, deleteCapture: { _ in },
                               fetchContent: { _ in nil })
        await m.hydration?.value   // warm the sidecar/meta memos OFF main, like a real launch
        return m
    }

    private func measureMainActorMs(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }

    // MARK: heavy seeding (REAL store APIs; heavy enough that a decode is non-trivial)

    /// A few realistic sentences the segments/paragraphs cycle through, so the transcript is
    /// genuine, meaningful prose (isBrowsable keeps it visible) and the on-disk JSON is large.
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

    /// A HEAVY on-disk transcript for one capture: `segmentsPerCapture` diarized segments and
    /// `paragraphsPerCapture` paragraphs of real text, so a decode is genuinely non-trivial.
    private func heavyTranscript(index: Int) -> CachedTranscript {
        let n = Self.sentences.count
        let shape = Self.shape(index)
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(shape.segs)
        for s in 0..<shape.segs {
            segments.append(TranscriptSegment(
                seq: s, startMs: s * 4000, endMs: s * 4000 + 3500,
                text: Self.sentences[(s + index) % n], speaker: "speaker_\(s % 4)"))
        }
        var paragraphs: [TranscriptParagraph] = []
        paragraphs.reserveCapacity(shape.paras)
        for p in 0..<shape.paras {
            paragraphs.append(TranscriptParagraph(
                start: Double(p) * 8, end: Double(p) * 8 + 7,
                speaker: "speaker_\(p % 4)", text: Self.sentences[(p * 3 + index) % n]))
        }
        let speakers = (0..<4).map {
            CaptureSpeaker(slot: "speaker_\($0)", status: .confirmed,
                           name: "Speaker \($0)", confirmedSpeakerId: "spk-\($0)")
        }
        let full = segments.map(\.text).joined(separator: " ")
        return CachedTranscript(transcript: full,
                                title: "Heavy conversation \(index)",
                                summary: "A long, real conversation with many segments and paragraphs.",
                                segments: segments, speakers: speakers, paragraphs: paragraphs,
                                fetchedAt: 100)
    }

    /// Seed `count` captures, each with a HEAVY `transcript.json` + `card.json` + `meta.json`
    /// written through the REAL stores. Newest-first ordering by a spread `startedAt`. Returns
    /// the ids in seeded order.
    @discardableResult
    private func seedHeavyLibrary(dir: URL, count: Int) -> [String] {
        var ids: [String] = []
        ids.reserveCapacity(count)
        // RECENT starts (spread over the last ~N×600s) so the heavy transcript.json survives
        // hydration's retention sweep — an OLD (>14d) confirmed conversation is pruned to a
        // card/meta tombstone (transcript text removed), which would defeat the heavy-decode repro.
        let now = UInt64(max(0, Date().timeIntervalSince1970))
        let t0 = DispatchTime.now().uptimeNanoseconds
        for i in 0..<count {
            let id = String(format: "omi-cap-%05d", i)   // id 0 = newest (largest startedAt)
            ids.append(id)
            let started = now - UInt64((i + 1) * 600)
            ConversationMetaStore.save(
                ConversationMeta(startedAt: started, endedAt: started + 480),
                captureId: id, baseDir: dir)
            ConversationCardStore.save(
                ConversationCardMeta(
                    title: "Heavy conversation \(i)",
                    summary: "Synthetic heavy-library card \(i) with a realistic summary sentence.",
                    stage: "in_lore"),
                captureId: id, baseDir: dir)
            TranscriptCacheStore.save(heavyTranscript(index: i), captureId: id, baseDir: dir)
        }
        let seedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        let heavies = (0..<count).filter { $0 % Self.heavyEvery == 0 }.count
        let bytes = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .reduce(0) { acc, d in
                acc + ((try? Data(contentsOf: d.appendingPathComponent("transcript.json")).count) ?? 0)
            }) ?? 0
        print("REPRO seed: \(count) captures (skewed: \(heavies) heavy @\(Self.heavySegments)segs, " +
              "\(count - heavies) light @\(Self.lightSegments)segs) = " +
              "\(bytes / 1024)KB transcripts total, written in \(String(format: "%.0f", seedMs))ms")
        return ids
    }

    func testDiagEncodeHeavyTranscript() throws {
        let t = heavyTranscript(index: 0)
        do {
            let data = try JSONEncoder().encode(t)
            print("DIAG encode OK: \(data.count) bytes, segs=\(t.segments.count) paras=\(t.paragraphs.count)")
        } catch {
            print("DIAG encode FAILED: \(error)")
            throw error
        }
    }

    // MARK: Test A — cold-memo rebuild (driver #3)

    /// After a WARM hydration a rebuild is 0 decodes (the CQRS invariant holds). Then a live
    /// write batch invalidates K sidecar memos; the next rebuild cold-misses K captures and
    /// does K synchronous `loadSidecar` transcript decodes ON MAIN — over the stall budget.
    func testColdMemoRebuildIsDiskOnMainAndOverBudget() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let ids = seedHeavyLibrary(dir: dir, count: Self.libraryN)
        let mgr = await makeManager(dir: dir)

        XCTAssertGreaterThanOrEqual(mgr.visibleCaptures.count, Self.libraryN - 2,
                                    "the heavy library hydrated and is visible")

        // FIDELITY PREMISE: a fully-warm rebuild does ZERO main-actor decodes.
        CaptureManager.resetMainThreadTranscriptDecodesForTests()
        mgr.rebuildVisibleCapturesForTests()
        XCTAssertEqual(CaptureManager.mainThreadTranscriptDecodesForTests, 0,
                       "premise: with warm memos the rebuild does ZERO disk-on-main (CQRS holds)")

        // Simulate a live write batch: K captures' sidecars were just invalidated. This is the
        // REAL invalidation seam every writer calls (status poller card merge, finalize,
        // ensureRecentTranscriptCached) — not a raw dict clear.
        let cold = Array(ids.prefix(Self.coldK))
        for id in cold { mgr.invalidateSidecar(id) }

        // DIAGNOSTIC: sum the per-cold-decode span cost inside the test binary.
        let spanTotal = SpanBox()
        PerfHook.install { name, ms in if name == "rebuild-cold-sidecar" { spanTotal.add(ms) } }
        let cdir = dir.appendingPathComponent(cold[0])
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: cdir.path)) ?? []
        print("REPRO A diag: dir=\(cdir.path) contents=\(listing)")
        for f in listing {
            // PROJECT RULE (N5): file size comes from `resourceValues(forKeys:)`, NEVER
            // `attributesOfItem[.size]` — the attributes call is the startup-hang footgun the
            // `foundryx_startup_hang_fix` track banned outright, diagnostics included.
            let fsz = (try? cdir.appendingPathComponent(f)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            print("REPRO A diag:   \(f) = \(fsz ?? 0) bytes")
        }
        let szURL = cdir.appendingPathComponent("transcript.json")
        let sz = (try? Data(contentsOf: szURL).count) ?? -1
        print("REPRO A diag: transcript.json Data(contentsOf:)=\(sz) bytes")

        CaptureManager.resetMainThreadTranscriptDecodesForTests()
        let ms = measureMainActorMs { mgr.rebuildVisibleCapturesForTests() }
        let decodes = CaptureManager.mainThreadTranscriptDecodesForTests
        print("REPRO A: rebuild=\(String(format: "%.1f", ms))ms decodes=\(decodes) " +
              "cold-sidecar-span-sum=\(spanTotal.total)ms " +
              "(invalidated K=\(Self.coldK) of N=\(Self.libraryN))")
        PerfHook.install { _, _ in }

        XCTAssertEqual(decodes, 0,
                       "CQRS: a rebuild must do ZERO synchronous main-actor decodes — " +
                       "RED: cold memos forced \(decodes) transcript decodes on main")
        XCTAssertLessThan(ms, 250,
                          "a rebuild must stay under the 250ms stall budget — " +
                          "RED: cold disk-on-main took \(String(format: "%.1f", ms))ms")
    }

    // MARK: Test B — recapConversationPool (driver #2)

    /// `recapConversationPool()` (eager at RootView) reads the deliberately-un-memoized
    /// `cardMeta` per visible capture, so at N=175 one pass is N synchronous `card.json`
    /// decodes ON MAIN. This is always cold (never memoized) — no invalidation needed.
    func testRecapPoolIsDiskOnMainAtLibrarySize() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = seedHeavyLibrary(dir: dir, count: Self.libraryN)
        let mgr = await makeManager(dir: dir)
        XCTAssertGreaterThanOrEqual(mgr.visibleCaptures.count, Self.libraryN - 2)

        CaptureManager.resetMainThreadTranscriptDecodesForTests()
        var pool: [RecapConversation] = []
        let ms = measureMainActorMs { pool = mgr.recapConversationPool() }
        let decodes = CaptureManager.mainThreadTranscriptDecodesForTests
        print("REPRO B: recapPool=\(String(format: "%.1f", ms))ms decodes=\(decodes) " +
              "pool=\(pool.count) (N=\(Self.libraryN))")

        // GREEN (track `residual_on_main_actor_work`). This assertion was wrapped in a STRICT
        // `XCTExpectFailure` while the per-row `card.json` decode was owned by that track and
        // still un-memoized (175 decodes here). The wrapper existed precisely so that the
        // moment the memoization landed the test would fail with "expected failure did not
        // occur" — the designed signal that the fix arrived. It landed: `cardMeta` is now
        // served from the per-capture sidecar memo (warmed off-main at hydration), so a recap
        // pass over a warm library reads ZERO bytes on the main actor. The wrapper is gone;
        // the assertion and its value are UNCHANGED.
        XCTAssertEqual(decodes, 0,
                       "recapConversationPool must not decode card.json on main — " +
                       "un-memoized cardMeta did \(decodes) decodes on main")
        XCTAssertLessThan(ms, 100,
                          "the recap pool must stay under 100ms — " +
                          "RED: \(String(format: "%.1f", ms))ms")
    }

    // MARK: Test C — first post-hydration sort (driver #4)

    /// The sort comparator's cold `startTimeCache` → `durableStart` decodes `meta.json`/
    /// `card.json` off disk ON MAIN — the previously-uninstrumented gap between
    /// `capture-sidecar-seed` and `capture-startup-finish`. Post-hydration the cache is warm,
    /// so we drop it (test seam) to re-pay the first-sort cold cost in isolation (the sidecar
    /// memo stays warm, so this measures the durableStart disk reads alone).
    func testFirstPostHydrationSortColdCost() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = seedHeavyLibrary(dir: dir, count: Self.libraryN)
        let mgr = await makeManager(dir: dir)

        mgr.invalidateStartTimeCacheForTests()
        CaptureManager.resetMainThreadTranscriptDecodesForTests()
        let ms = measureMainActorMs { mgr.rebuildVisibleCapturesForTests() }
        let decodes = CaptureManager.mainThreadTranscriptDecodesForTests
        print("REPRO C: firstSort=\(String(format: "%.1f", ms))ms decodes=\(decodes) " +
              "(durableStart cold ×N=\(Self.libraryN))")

        // GREEN SPEC (track `rebuild_is_byte_independent_and_disk_free`, acceptance): this
        // assertion was `decodes > 0` while the harness was a RED diagnosis of driver #4.
        // The fix seeds `startTimeCache` off-main at hydration and resolves `durableStart`
        // from the warm `metaCache` / the sidecar memo's cached card start, so even a
        // DROPPED start cache re-resolves from MEMORY. The assertion is INVERTED to the
        // acceptance criterion (0 decodes, <100ms) — strengthened, never relaxed; the seed
        // (N=175, the skewed 7.9MB corpus) and the invalidation seam are untouched.
        XCTAssertEqual(decodes, 0,
                       "CQRS: the first post-hydration sort must resolve every durable start " +
                       "from MEMORY — RED: \(decodes) main-actor decodes")
        XCTAssertLessThan(ms, 100,
                          "the first post-hydration sort must stay under 100ms — " +
                          "RED: \(String(format: "%.1f", ms))ms")
    }

    // MARK: Test D — the GENUINE cold-miss gate (review S6)

    /// Test A's seam stopped being a real exercise of `sidecar(for:)`'s cold-miss path the
    /// moment `invalidateSidecar` began KEEPING the last-known memo: the measured rebuild
    /// reads a still-warm memo, so `decodes == 0` is true by construction and the assertion
    /// can no longer fail for the reason it exists. This test restores the gate. It puts the
    /// manager in the state Test A only *appears* to test — captures with NO memo entry AT
    /// ALL during a rebuild — and asserts the rebuild still reads ZERO bytes off disk on the
    /// main actor. That is the actual CQRS invariant: `sidecar(for:)`'s miss branch must
    /// answer from the placeholder and re-warm OFF-main, never `loadSidecar` inline.
    ///
    /// It then asserts the R3 recovery contract: once the off-main warms land, membership is
    /// exactly what it was before the memo was dropped (no permanently-lost rows).
    func testColdMissRebuildReadsNoDiskOnMain() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let ids = seedHeavyLibrary(dir: dir, count: Self.libraryN)
        let mgr = await makeManager(dir: dir)

        let membershipBefore = mgr.visibleCaptures.map(\.captureId)
        XCTAssertGreaterThanOrEqual(membershipBefore.count, Self.libraryN - 2,
                                    "the heavy library hydrated and is visible")
        XCTAssertEqual(mgr.warmSidecarMemoCountForTests, membershipBefore.count,
                       "premise: hydration warmed a memo for every capture")

        // THE COLD-MISS STATE: no memo entry at all for K captures — the state a rebuild must
        // survive without touching disk on the main actor.
        let cold = Array(ids.prefix(Self.coldK))
        mgr.dropSidecarMemoForTests(cold)
        XCTAssertEqual(mgr.warmSidecarMemoCountForTests, membershipBefore.count - Self.coldK,
                       "premise: K memos are genuinely GONE (not merely marked stale)")

        CaptureManager.resetMainThreadTranscriptDecodesForTests()
        let ms = measureMainActorMs { mgr.rebuildVisibleCapturesForTests() }
        let decodes = CaptureManager.mainThreadTranscriptDecodesForTests
        print("REPRO D: coldMissRebuild=\(String(format: "%.1f", ms))ms decodes=\(decodes) " +
              "(NO memo entry for K=\(Self.coldK) of N=\(Self.libraryN))")

        XCTAssertEqual(decodes, 0,
                       "CQRS: a rebuild that COLD-MISSES the sidecar memo must still do ZERO " +
                       "synchronous main-actor decodes — it did \(decodes)")
        XCTAssertLessThan(ms, 250,
                          "a cold-miss rebuild must stay under the 250ms stall budget — " +
                          "\(String(format: "%.1f", ms))ms")

        // R3 recovery: the off-main re-warms the cold miss scheduled must restore every row.
        for _ in 0..<200 where mgr.warmSidecarMemoCountForTests < membershipBefore.count {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        mgr.rebuildVisibleCapturesForTests()
        XCTAssertEqual(mgr.visibleCaptures.map(\.captureId), membershipBefore,
                       "R3: once the off-main warms land, membership is restored exactly")
    }
}
