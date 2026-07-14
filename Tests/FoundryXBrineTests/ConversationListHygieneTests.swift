import XCTest
import Foundation
@testable import FoundryXKit

/// Manager-level, door-free tests for conversation-list hygiene (track 20260628T1654):
///  • empty / near-silent / filler captures are HIDDEN from the visible list (data kept),
///  • a closed conversation always has `ended_at` set (real bounds) after finalize.
@MainActor
final class ConversationListHygieneTests: XCTestCase {

    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-hygiene-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeManager(baseDir: URL, source: AudioFrameSource) async -> CaptureManager {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let m = CaptureManager(target: target, baseDir: baseDir, source: source,
                              finalize: { _, _ in }, fetchContent: { _ in nil })
        await m.hydration?.value
        return m
    }

    /// Two finalized captures on disk — one with a real provisional transcript, one with
    /// pure filler ("Thank you."). Only the real one renders.
    func testFillerCapturesAreHiddenFromList() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        ConversationCardStore.seedProvisional(captureId: "omi-REAL", baseDir: dir,
                                              transcript: "Let's review the launch plan and pick a release date.",
                                              title: "Launch plan")
        ConversationCardStore.seedProvisional(captureId: "omi-FILLER", baseDir: dir,
                                              transcript: "Thank you.", title: "Thank you")

        let mgr = await makeManager(baseDir: dir, source: TestSource())
        let ids = Set(mgr.visibleCaptures.map { $0.captureId })
        XCTAssertTrue(ids.contains("omi-REAL"), "a real conversation is shown")
        XCTAssertFalse(ids.contains("omi-FILLER"), "a near-silent filler capture is hidden")
    }

    /// A manual split finalizes the current conversation; its durable metadata must carry
    /// `ended_at` (real bounds) — the same recordEnd path every clean/forced finalize uses.
    func testClosedConversationHasEndedAt() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = TestSource()
        let mgr = await makeManager(baseDir: dir, source: src)
        mgr.setSilenceGap(9_999)   // auto-segmenter quiet — the split is ours

        src.onState?(.streaming)
        try await waitUntil { mgr.active != nil }
        let closedId = try XCTUnwrap(mgr.active).captureId
        // Enough voice to clear the min-substance upload bar (else the split section is
        // dropped as a junk fragment and never gets a durable ended_at bound).
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) { src.onFrame?(RealOmiFrames.voiced()) }

        mgr.splitConversation()
        // recordEnd runs in endSession's async Task — wait for the durable bound.
        try await waitUntil { ConversationMetaStore.load(captureId: closedId, baseDir: dir)?.endedAt != nil }
        let meta = try XCTUnwrap(ConversationMetaStore.load(captureId: closedId, baseDir: dir))
        XCTAssertNotNil(meta.endedAt, "a finalized conversation must have ended_at set (real bounds)")
        XCTAssertGreaterThanOrEqual(meta.endedAt ?? 0, meta.startedAt)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out waiting for condition"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
