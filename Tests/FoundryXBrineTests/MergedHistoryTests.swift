import XCTest
@testable import FoundryXKit

/// L3.1/L3.2 — merging what the phone holds with what the second place holds, and saying which
/// is which.
///
/// The rules under test are the ones the spec spent five review rounds getting right:
///  * residence comes from FRESHNESS (`observedAt`), never from mere response membership and
///    never from `.lore-confirmed`, which is retained past deletion by design;
///  * merged rows are in TRUE TIME ORDER, not grouped by source;
///  * dedup keeps the richer row rather than the remote stub.
final class MergedHistoryTests: XCTestCase {

    private func hit(_ id: String, capturedAt: Int64?, observedAt: Int64?) -> ConversationHit {
        ConversationHit(
            captureId: id, title: "T-\(id)", dateLabel: "2026-08-25", snippet: "s",
            capturedAt: capturedAt, observedAt: observedAt
        )
    }

    func testARowHeldInBothPlacesSaysSo() {
        let merged = MergedHistory.merge(
            local: [LocalRow(captureId: "a", capturedAt: 100)],
            remote: [hit("a", capturedAt: 100, observedAt: 1_000)],
            now: 1_000, freshWithin: 600
        )
        XCTAssertEqual(merged.count, 1, "a row in both places appears once")
        XCTAssertEqual(merged[0].residence, .bothPlaces)
    }

    func testARowOnlyThePhoneHoldsSaysSo() {
        let merged = MergedHistory.merge(
            local: [LocalRow(captureId: "a", capturedAt: 100)],
            remote: [], now: 1_000, freshWithin: 600
        )
        XCTAssertEqual(merged[0].residence, .phoneOnly)
    }

    func testARowOnlyTheSecondPlaceHoldsSaysSo() {
        let merged = MergedHistory.merge(
            local: [],
            remote: [hit("b", capturedAt: 100, observedAt: 1_000)],
            now: 1_000, freshWithin: 600
        )
        XCTAssertEqual(merged[0].residence, .secondPlaceOnly)
    }

    /// ⚠ THE ARM THE SPEC GOT WRONG TWICE. Residence is CURRENT, not ever. An observation
    /// older than the declared window cannot support "still held", so the row reads UNKNOWN
    /// rather than present — the same reason an absent run id reads unknown rather than
    /// running. Reporting it as held would tell the owner a deleted transcript is safe.
    func testAStaleObservationReadsUnknownRatherThanHeld() {
        let merged = MergedHistory.merge(
            local: [LocalRow(captureId: "a", capturedAt: 100)],
            remote: [hit("a", capturedAt: 100, observedAt: 10)],   // 990s ago
            now: 1_000, freshWithin: 600
        )
        XCTAssertEqual(merged[0].residence, .unknown,
                       "a stale observation must not read as currently held")
    }

    /// PAIRED with the above: without a time at all there is nothing to be fresh, so an
    /// older second place that sends no `observedAt` must not have its rows read as held.
    func testAHitWithNoObservationTimeReadsUnknown() {
        let merged = MergedHistory.merge(
            local: [],
            remote: [hit("b", capturedAt: 100, observedAt: nil)],
            now: 1_000, freshWithin: 600
        )
        XCTAssertEqual(merged[0].residence, .unknown)
    }

    /// AC13 — true time order across BOTH sources, not 200 remote rows beneath 300 local ones.
    func testMergedRowsInterleaveByTimeAcrossSources() {
        let merged = MergedHistory.merge(
            local: [LocalRow(captureId: "old-local", capturedAt: 100),
                    LocalRow(captureId: "new-local", capturedAt: 400)],
            remote: [hit("mid-remote", capturedAt: 250, observedAt: 1_000)],
            now: 1_000, freshWithin: 600
        )
        XCTAssertEqual(merged.map(\.captureId), ["new-local", "mid-remote", "old-local"],
                       "rows must interleave by capture time, not group by source")
    }

    /// AC2 — dedup keeps the LOCAL row, which carries metadata and working actions, rather
    /// than replacing it with the remote stub.
    func testDedupKeepsTheLocalRowNotTheRemoteStub() {
        let merged = MergedHistory.merge(
            local: [LocalRow(captureId: "a", capturedAt: 100)],
            remote: [hit("a", capturedAt: 100, observedAt: 1_000)],
            now: 1_000, freshWithin: 600
        )
        XCTAssertTrue(merged[0].isLocal, "the local row is kept; the remote stub is not swapped in")
    }
}
