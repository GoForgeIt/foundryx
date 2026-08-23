import XCTest
import Foundation
@testable import FoundryXKit

/// **AC5 — `isConfirmedInLore` is never evaluated on the main thread.**
///
/// The presence resolver asks two authorities that both read the disk: `alreadyHeld` stats a file
/// and `confirmedInLore` stats a marker. `PocketRecorderCheck` documents its resolver as
/// `nonisolated` **and** `async` precisely so a caller on the main actor hops off it — and says
/// that being so is "load-bearing".
///
/// **WHY A COUNTER AND NOT A REVIEW.** `TranscriptCacheStore.isConfirmedInLore` counts *at the
/// operation*: `noteMainThreadDecode()` no-ops off-main and increments on it, so a future caller
/// that reintroduces the pathology trips a deterministic counter rather than only the call sites
/// somebody thought to look at. This test is what reads that counter; without it the counter is a
/// mechanism nobody consults, which is the same defect as not having one.
final class PocketPresenceOffMainThreadTests: XCTestCase {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocket-presence-offmain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Resolved the way production resolves it — awaited from the main actor — the counter stays 0.
    @MainActor
    func testResolvingPresenceFromTheMainActorDecodesNothingOnTheMainThread() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        CaptureManager.resetMainThreadTranscriptDecodesForTests()

        // POSITIVE CONTROL FIRST, and it is the whole reason this test can be trusted. A counter
        // that never moves proves nothing about the measured run: it is equally consistent with
        // "nothing ran on main" and "the counter is broken". So the pathology is performed
        // deliberately, ON the main thread, and the counter MUST see it.
        XCTAssertTrue(Thread.isMainThread, "this arm must run on the main thread to mean anything")
        _ = TranscriptCacheStore.isConfirmedInLore(captureId: "probe", baseDir: dir)
        XCTAssertEqual(CaptureManager.mainThreadTranscriptDecodesForTests, 1,
                       "the main-thread decode counter did not move when the operation was "
                           + "performed ON the main thread — the counter is broken, so a zero "
                           + "below would prove nothing")

        // NOW THE MEASURED RUN. Awaited off the main actor, the way the resolver is documented to
        // be used, the count must not move at all.
        CaptureManager.resetMainThreadTranscriptDecodesForTests()
        await Task.detached(priority: .utility) {
            _ = TranscriptCacheStore.isConfirmedInLore(captureId: "probe", baseDir: dir)
        }.value
        XCTAssertEqual(CaptureManager.mainThreadTranscriptDecodesForTests, 0,
                       "`isConfirmedInLore` was evaluated on the main thread. It stats a file, and "
                           + "a main-actor caller that does not hop off is the nav-stall shape "
                           + "this counter exists to catch.")
    }
}
