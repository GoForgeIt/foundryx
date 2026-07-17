import XCTest
import Foundation
@testable import FoundryXKit

/// TARGET 1 (WS-B perf) blast-radius: `SummaryBackfill.run` fires up to 12 titler calls
/// per pass. With a WEDGED model (a 20s+ non-cooperative turn that surfaces as
/// `PerfTimeout`) that used to pin the CPU for minutes and re-fire on every list appear.
/// The pass must STOP on the first `PerfTimeout` (the model is wedged — do not call it 11
/// more times) and must NOT burn the one-time marker (so it re-runs once the model recovers).
final class SummaryBackfillWedgeTests: XCTestCase {

    /// Counts calls; throws `PerfTimeout` (a wedged model) on every call.
    private final class WedgingTitler: LocalTitleSummary, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        var available = true
        var isAvailable: Bool { available }
        private func bump() { lock.lock(); calls += 1; lock.unlock() }   // sync helper: lock off the async path
        func titleAndSummary(for transcript: String) async throws -> (title: String, summary: String) {
            bump()
            throw PerfTimeout(name: "fm-title", ms: 20_000)
        }
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("summary-backfill-wedge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Scenario: a wedged model stops the pass after ONE call and leaves the marker unwritten.
    func testWedgedModelStopsPassAndDoesNotWriteMarker() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 12 unsummarized cards, each with an on-phone transcript (so each is fillable).
        let ids = (0..<12).map { "cap-\($0)" }
        for id in ids {
            ConversationCardStore.save(
                ConversationCardMeta(title: "T\(id)", summary: nil, stage: "in_lore"),
                captureId: id, baseDir: dir)
        }
        let titler = WedgingTitler()

        let filled = await SummaryBackfill.run(
            captureIds: ids,
            baseDir: dir,
            titler: titler,
            transcript: { _ in "a real transcript body long enough to summarize" },
            cardSummary: { id in ConversationCardStore.load(captureId: id, baseDir: dir)?.summary })

        XCTAssertEqual(filled, 0, "a wedged model fills nothing")
        XCTAssertEqual(titler.calls, 1,
                       "STOP on the first wedge — do NOT call the wedged model 11 more times")

        let marker = dir.appendingPathComponent("summary-backfill.v1.done")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the one-time marker must stay UNWRITTEN so the pass re-runs once the model recovers")
    }
}
