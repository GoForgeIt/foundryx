import XCTest
import Foundation
@testable import FoundryXKit

/// Newest-first ordering (track 20260626) + the off-main status poller (the lag fix).
final class CaptureOrderingTests: XCTestCase {

    private func tempDir(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Seed a visible capture (one ack'd segment) with a durable conversation start.
    private func seed(_ id: String, baseDir: URL, startedAt: UInt64) throws {
        let cdir = baseDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        let seg = cdir.appendingPathComponent(CaptureWAL.segName(0))
        try Data([1, 2, 3, 4]).write(to: seg)
        try Data().write(to: seg.deletingPathExtension().appendingPathExtension("ack"))
        ConversationMetaStore.save(ConversationMeta(startedAt: startedAt), captureId: id, baseDir: baseDir)
    }

    @MainActor
    func testVisibleCapturesAreNewestFirst() throws {
        let dir = try tempDir("order")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Note: the dir-name (capture id) sort and the start-time sort disagree here —
        // "aaa" sorts last by id but is the NEWEST conversation, so only a start-time
        // sort gives the right order.
        try seed("aaa-newer", baseDir: dir, startedAt: 2_000)
        try seed("zzz-older", baseDir: dir, startedAt: 1_000)

        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []))

        let order = mgr.visibleCaptures.map(\.captureId)
        XCTAssertEqual(order, ["aaa-newer", "zzz-older"], "newest conversation start first")
    }

    // MARK: the lag fix — the poller is no longer fully @MainActor

    /// A trivial off-the-main-actor fetcher.
    struct StubFetcher: CaptureStatusFetching {
        let stage: String
        func captureStatus(captureId: String) async throws -> CaptureStatusResponse {
            CaptureStatusResponse(stage: stage, loreCaptureId: stage == "in_lore" ? "lore-1" : nil,
                                  transcribed: stage != "stored", title: "Hello")
        }
    }

    func testPollerDrivesFromOffMainActor() async {
        // The poller is constructed + polled from a NON-main-actor context (this test
        // method isn't @MainActor); the fetch/decode run off-main and only the
        // published mutation hops to main. This wouldn't compile if the type were
        // still fully @MainActor.
        let poller = CaptureStatusPoller(captureId: "omi-z", client: StubFetcher(stage: "in_lore"),
                                         baseInterval: 0.01)
        let terminal = await poller.pollOnce()
        XCTAssertTrue(terminal, "in_lore + transcribed + title has delivered everything status polling can provide")
        let stage = await MainActor.run { poller.stage }
        let title = await MainActor.run { poller.title }
        let lore = await MainActor.run { poller.loreCaptureId }
        XCTAssertEqual(stage, .inLore)
        XCTAssertEqual(title, "Hello")
        XCTAssertEqual(lore, "lore-1")
    }
}
