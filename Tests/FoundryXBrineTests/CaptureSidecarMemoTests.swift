import XCTest
import Foundation
@testable import FoundryXKit

/// Workstream B (track 20260717T0448): the list-rebuild reads a per-capture sidecar MEMO
/// seeded off-main at hydration, NOT synchronous disk I/O on the main actor. These tests
/// pin: (a) the rebuild reads memory not disk, (b) every write path invalidates precisely,
/// (c) membership parity on a mixed library, (d) the seed + startup-finish perf spans fire.
@MainActor
final class CaptureSidecarMemoTests: XCTestCase {

    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Ensure a capture DIR exists so hydration picks it up (even with 0 segments).
    private func makeCaptureDir(_ id: String, in base: URL) throws {
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent(id, isDirectory: true), withIntermediateDirectories: true)
    }

    private func makeManager(baseDir: URL, source: AudioFrameSource,
                             fetchContent: (@Sendable (String) async -> CaptureContent?)? = nil) async -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let m = CaptureManager(target: target, baseDir: baseDir, source: source,
                               finalize: { _, _ in }, deleteCapture: { _ in },
                               fetchContent: fetchContent ?? { _ in nil })
        await m.hydration?.value
        return m
    }

    // AC4(a) — the rebuild reads the MEMO, not disk: delete a sidecar file WITHOUT an
    // invalidation event, force a rebuild, and membership/stats are UNCHANGED.
    func testRebuildReadsMemoNotDisk() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A capture visible ONLY because of its cached transcript text (0 segments): if a
        // rebuild ever re-read disk after we delete the file, it would fall to "no text +
        // not worth showing + no tombstone" and VANISH.
        try makeCaptureDir("omi-A", in: dir)
        TranscriptCacheStore.save(
            CachedTranscript(transcript: "Let's finalize the launch plan and pick a release date.",
                             title: "Launch", summary: nil, speakers: [
                                CaptureSpeaker(slot: "0", status: .confirmed, name: "Nick",
                                               confirmedSpeakerId: "spk-nick")],
                             fetchedAt: 100),
            captureId: "omi-A", baseDir: dir)

        let mgr = await makeManager(baseDir: dir, source: TestSource())
        XCTAssertTrue(mgr.visibleCaptures.contains { $0.captureId == "omi-A" }, "A shows via its cached transcript")
        let wordsBefore = mgr.statsSummary.totalWords
        let speakersBefore = mgr.statsSummary.totalSpeakersIdentified
        XCTAssertGreaterThan(wordsBefore, 0)
        XCTAssertEqual(speakersBefore, 1)

        // Delete the transcript.json DIRECTLY — no invalidation event.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("omi-A/transcript.json"))
        mgr.rebuildVisibleCapturesForTests()

        XCTAssertTrue(mgr.visibleCaptures.contains { $0.captureId == "omi-A" },
                      "membership is stable — the rebuild read the warm memo, not the (now-missing) file")
        XCTAssertEqual(mgr.statsSummary.totalWords, wordsBefore, "word stats unchanged (memo)")
        XCTAssertEqual(mgr.statsSummary.totalSpeakersIdentified, speakersBefore, "speaker stats unchanged (memo)")
    }

    // AC4(b) — the proactive transcript-cache write path invalidates: a capture with no
    // text (hidden) becomes visible after ensureRecentTranscriptCached fetches + caches.
    func testTranscriptCacheWriteInvalidates() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeCaptureDir("omi-B", in: dir)   // empty: 0 segments, no transcript, no card

        let content = CaptureContent(transcript: "Discussed the quarterly roadmap in real depth.",
                                     capturedAt: 0, found: true, title: "Roadmap")
        let mgr = await makeManager(baseDir: dir, source: TestSource(),
                                    fetchContent: { _ in content })
        XCTAssertFalse(mgr.visibleCaptures.contains { $0.captureId == "omi-B" },
                       "an empty 0-segment capture is hidden before any transcript")

        mgr.ensureRecentTranscriptCached("omi-B")
        try await waitUntil { mgr.visibleCaptures.contains { $0.captureId == "omi-B" } }
        XCTAssertTrue(mgr.visibleCaptures.contains { $0.captureId == "omi-B" },
                      "after the cache write invalidated the memo, the rebuild reflects the new transcript")
    }

    // AC4(b) — delete invalidates + removes from the list.
    func testDeleteInvalidatesAndHides() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeCaptureDir("omi-C", in: dir)
        TranscriptCacheStore.save(
            CachedTranscript(transcript: "A real, substantive conversation about the plan.",
                             title: "Plan", summary: nil, fetchedAt: 100),
            captureId: "omi-C", baseDir: dir)
        let mgr = await makeManager(baseDir: dir, source: TestSource())
        XCTAssertTrue(mgr.visibleCaptures.contains { $0.captureId == "omi-C" })

        mgr.deleteConversation("omi-C")
        XCTAssertFalse(mgr.visibleCaptures.contains { $0.captureId == "omi-C" },
                       "a deleted capture leaves the visible list (memo invalidated)")
    }

    // AC4(c) — membership PARITY on a mixed library: filler hidden, card-tombstoned shown,
    // 0-segment empty hidden. (Streaming-shown is covered by CaptureVisibilityTests.)
    func testMixedLibraryMembershipParity() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // REAL — meaningful cached transcript → shown.
        try makeCaptureDir("omi-REAL", in: dir)
        TranscriptCacheStore.save(
            CachedTranscript(transcript: "Let's review the launch plan and choose a firm release date.",
                             title: "Launch", summary: nil, fetchedAt: 100),
            captureId: "omi-REAL", baseDir: dir)
        // FILLER — near-silent provisional card → hidden.
        ConversationCardStore.seedProvisional(captureId: "omi-FILLER", baseDir: dir,
                                              transcript: "Thank you.", title: "Thank you")
        // CARD-ONLY tombstone (audio + text pruned, name/summary survive) → shown.
        try makeCaptureDir("omi-CARD", in: dir)
        ConversationCardStore.merge(captureId: "omi-CARD", baseDir: dir,
                                    title: "Old chat", summary: "A summary that outlived its text")
        // EMPTY — a dir with nothing (0 segments, no text, no card) → hidden.
        try makeCaptureDir("omi-EMPTY", in: dir)

        let mgr = await makeManager(baseDir: dir, source: TestSource())
        let ids = Set(mgr.visibleCaptures.map { $0.captureId })
        XCTAssertTrue(ids.contains("omi-REAL"), "a meaningful conversation shows")
        XCTAssertTrue(ids.contains("omi-CARD"), "a card-only tombstone stays browsable")
        XCTAssertFalse(ids.contains("omi-FILLER"), "a near-silent filler capture is hidden")
        XCTAssertFalse(ids.contains("omi-EMPTY"), "an empty 0-segment capture is hidden")
    }

    // AC5 — the off-main sidecar seed span + the startup-finish (R4) span both fire, and the
    // seed span does NOT collide with the capture-hydrate budget grep.
    func testHydrationEmitsSeedAndFinishSpans() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeCaptureDir("omi-S1", in: dir)
        try makeCaptureDir("omi-S2", in: dir)

        let box = SpanBox()
        PerfHook.install { name, ms in box.record(name, ms) }
        defer { PerfHook.install { _, _ in } }

        let mgr = await makeManager(baseDir: dir, source: TestSource())
        _ = mgr
        let names = box.names()
        XCTAssertTrue(names.contains { $0.hasPrefix("capture-sidecar-seed-n") },
                      "the off-main sidecar seed emits its own span")
        XCTAssertTrue(names.contains { $0.hasPrefix("capture-startup-finish-n") },
                      "the startup main-actor tail (R4) is measured")
        XCTAssertFalse(names.contains { $0.hasPrefix("capture-sidecar-seed") && $0.contains("hydrate") },
                       "the seed span is distinct from capture-hydrate* (budget-grep rule)")
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out waiting for condition"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Thread-safe span collector for the PerfHook seam (spans arrive off the main actor).
final class SpanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var spans: [(String, Int)] = []
    func record(_ name: String, _ ms: Int) { lock.lock(); spans.append((name, ms)); lock.unlock() }
    func names() -> [String] { lock.lock(); defer { lock.unlock() }; return spans.map(\.0) }
}
