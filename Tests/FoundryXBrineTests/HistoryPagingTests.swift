import XCTest
@testable import FoundryXKit

/// L3.4 / AC12 — the REMAINDER is reachable, not merely counted.
///
/// Spec review round 4 named the pair as its blocking defect: `total` counted and a banner
/// disclosed, while NEITHER reached. Layer 1 now hands back a cursor; this is the half that
/// follows it. Pure paging logic, injected fetch, so it is provable without a door.
final class HistoryPagingTests: XCTestCase {

    private func page(_ ids: [String], next: String?) -> ConversationPageResult {
        ConversationPageResult(
            conversations: ids.map {
                ConversationHit(captureId: $0, title: "T-\($0)", dateLabel: "2026-08-26", snippet: "s")
            },
            total: 5,
            nextCursor: next
        )
    }

    func testFollowingTheCursorReachesEveryRow() async throws {
        let pages: [String?: ConversationPageResult] = [
            nil: page(["a", "b"], next: "c1"),
            "c1": page(["c", "d"], next: "c2"),
            "c2": page(["e"], next: nil),
        ]
        let all = try await HistoryPaging.everything(pageLimit: 2) { cursor in
            pages[cursor] ?? self.page([], next: nil)
        }
        XCTAssertEqual(all.map(\.captureId), ["a", "b", "c", "d", "e"])
    }

    /// PAIRED — the bound that keeps a broken cursor from hanging instead of failing.
    /// A cursor that ignores its input re-serves page one forever; an unbounded walk would
    /// never finish, and a test that never finishes is not a failing test, it is an absent one.
    func testACursorThatNeverAdvancesIsRefusedRatherThanLoopingForever() async {
        do {
            _ = try await HistoryPaging.everything(pageLimit: 2, maxPages: 4) { _ in
                self.page(["a"], next: "always-the-same")
            }
            XCTFail("a non-advancing cursor must be refused, not followed forever")
        } catch let error as HistoryPaging.PagingError {
            guard case .didNotTerminate(let pages) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(pages, 4, "it refuses AT the bound and names how far it got")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A single complete page must NOT be reported as truncated.
    func testOnePageWithNoCursorIsTheWholeHistory() async throws {
        let all = try await HistoryPaging.everything(pageLimit: 50) { _ in
            self.page(["a", "b"], next: nil)
        }
        XCTAssertEqual(all.count, 2)
    }

    /// An EMPTY page carrying a cursor is a lie the caller must not follow silently.
    func testAnEmptyPageWithACursorIsRefused() async {
        do {
            _ = try await HistoryPaging.everything(pageLimit: 2) { _ in
                self.page([], next: "more")
            }
            XCTFail("an empty page promising more must be refused")
        } catch let error as HistoryPaging.PagingError {
            guard case .emptyPagePromisedMore = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
