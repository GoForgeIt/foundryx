import XCTest
@testable import FoundryXKit

/// L3.3 / AC4 — unreachable is NAMED and RECOVERABLE.
///
/// The plan's first draft said "preserve `.unreachable`" and called that the retry. The review
/// refused it, correctly: `.unreachable` is a STATE, not a control. A banner that names the
/// condition and offers no way out leaves the owner staring at a permanent apology while their
/// history sits one working request away.
@MainActor
final class UnreachableRetryTests: XCTestCase {

    func testAnUnreachableSecondPlaceIsRetryable() {
        XCTAssertTrue(RemoteSearchState.unreachable.isRetryable,
                      "unreachable is the whole reason a retry exists")
    }

    /// PAIRED. Without this, `isRetryable` could return true for everything and the UI would
    /// offer a retry on a resting list — an affordance that does nothing is worse than none,
    /// because it teaches the owner the control is decorative.
    func testStatesThatCannotBeRetriedSaySo() {
        XCTAssertFalse(RemoteSearchState.idle.isRetryable)
        XCTAssertFalse(RemoteSearchState.searching.isRetryable)
        XCTAssertFalse(RemoteSearchState.results([]).isRetryable)
        XCTAssertFalse(RemoteSearchState.notConnected.isRetryable,
                       "no computer is connected — retrying reaches nothing, so offering it lies")
    }

    /// The retry must actually RE-ASK, and land on the answer the second attempt gives.
    func testRetryingAfterAFailureReachesTheSecondPlace() async {
        // A locked counter, not a captured var: the search closure is @Sendable and runs
        // concurrently, so a bare `var` is a data race the compiler refuses.
        let attempts = RetryCounter()
        let hit = ConversationHit(captureId: "a", title: "T", dateLabel: "2026-08-26", snippet: "s")
        let search: @Sendable (String) async throws -> [ConversationHit] = { _ in
            if attempts.bump() == 1 { throw URLError(.notConnectedToInternet) }
            return [hit]
        }
        let first = await FullHistorySearch.remoteState(
            query: "q", localIds: [], computerConnected: true, search: search)
        XCTAssertEqual(first, .unreachable)
        XCTAssertTrue(first.isRetryable)

        let second = await FullHistorySearch.remoteState(
            query: "q", localIds: [], computerConnected: true, search: search)
        XCTAssertEqual(second, .results([hit]), "the retry lands on the second attempt's answer")
        XCTAssertFalse(second.isRetryable, "a landed result is not retryable")
        XCTAssertEqual(attempts.count, 2, "the retry actually re-asked rather than replaying the first")
    }
}


/// A counter safe to touch from a @Sendable closure.
private final class RetryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}
