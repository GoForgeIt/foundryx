import XCTest
@testable import FoundryXKit

/// L3.5 / AC8 — captures past the launch bound are REACHABLE, not merely disclosed.
///
/// `maxCapturesToLoad = 300` is deliberate and STAYS: hydrating every folder at launch overran
/// the iOS launch watchdog and got the app SIGKILL'd. AC8's first draft said the bound must be
/// "reachable-or-stated" and the review called that authorized truncation-by-disclaimer — a
/// sentence is not a way in. This is the way in: the same newest-first order, windowed.
final class LocalCapturePagingTests: XCTestCase {

    /// Timestamp-prefixed ids, newest first when sorted descending — the real shape.
    private let names = ["omi-005", "omi-004", "omi-003", "omi-002", "omi-001"]

    func testTheFirstPageIsTheNewest() {
        let page = LocalCapturePaging.page(names: names, after: nil, limit: 2)
        XCTAssertEqual(page.ids, ["omi-005", "omi-004"])
        XCTAssertEqual(page.nextAfter, "omi-004", "the cursor is the last id handed out")
    }

    func testFollowingTheCursorReachesEveryCaptureExactlyOnce() {
        var seen: [String] = []
        var after: String? = nil
        for _ in 0..<10 {
            let page = LocalCapturePaging.page(names: names, after: after, limit: 2)
            seen.append(contentsOf: page.ids)
            guard let next = page.nextAfter else { break }
            after = next
        }
        XCTAssertEqual(seen, names, "every capture, in order, exactly once")
    }

    /// PAIRED — the last page must say it is the last, or the caller walks forever.
    func testTheLastPageCarriesNoCursor() {
        let page = LocalCapturePaging.page(names: names, after: "omi-002", limit: 5)
        XCTAssertEqual(page.ids, ["omi-001"])
        XCTAssertNil(page.nextAfter, "nothing remains, so no cursor")
    }

    /// The launch bound is UNCHANGED — this adds a way past it, it does not lift it.
    func testTheLaunchBoundIsStillTheDefaultFirstPage() {
        XCTAssertEqual(CaptureManager.maxCapturesToLoad, 300,
                       "lifting this is what got the app SIGKILL'd; paging must not change it")
    }

    /// An unknown cursor yields nothing rather than silently restarting at the top — a
    /// restart would re-serve page one forever and read as progress.
    func testAnUnknownCursorReturnsNothingRatherThanRestarting() {
        let page = LocalCapturePaging.page(names: names, after: "omi-999", limit: 2)
        XCTAssertTrue(page.ids.isEmpty)
        XCTAssertNil(page.nextAfter)
    }
}
