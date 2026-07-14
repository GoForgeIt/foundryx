import XCTest
import Foundation
import FoundryXKit

/// Full-history search — the remote (computer/Lore) half of Capture search (track
/// 20260714T1200 AC3). Each test maps to a scenario in features/full-history-search.feature.
/// The door search is injected, so the merge/dedup + honest connection states are proven
/// without a network.
final class FullHistorySearchTests: XCTestCase {

    private func hit(_ id: String, _ title: String = "t") -> ConversationHit {
        ConversationHit(captureId: id, title: title, dateLabel: "2024-01-01", snippet: "s")
    }

    // Scenario: Connected — computer results join local results, deduped.
    func testConnectedMergesComputerResultsAndDedupesLocal() async {
        let local: Set<String> = ["omi-a", "omi-b"]
        // The door returns a mix: omi-b is ALSO local (dedup), omi-c/omi-d are new.
        // Precompute the hits so the @Sendable search closure captures values, not self.
        let doorHits = [hit("omi-b"), hit("omi-c"), hit("omi-d")]
        let state = await FullHistorySearch.remoteState(
            query: "bargain", localIds: local, computerConnected: true,
            search: { _ in doorHits })
        XCTAssertEqual(state, .results([hit("omi-c"), hit("omi-d")]),
                       "local dupes drop; computer-only hits remain, newest order preserved")
    }

    // Dedup helper directly (a conversation both local + on the computer appears once).
    func testComputerOnlyDropsLocalDuplicates() {
        let only = FullHistorySearch.computerOnly(
            remoteHits: [hit("omi-a"), hit("omi-x"), hit("omi-b")],
            localIds: ["omi-a", "omi-b"])
        XCTAssertEqual(only.map(\.captureId), ["omi-x"])
    }

    // Scenario: Not connected — local only, honestly said. The search closure fails the
    // test if ever called (no computer → no door query).
    func testNotConnectedReportsNotConnectedAndNeverSearches() async {
        let state = await FullHistorySearch.remoteState(
            query: "anything", localIds: [], computerConnected: false,
            search: { _ in XCTFail("no computer → no door query"); return [] })
        XCTAssertEqual(state, .notConnected)
    }

    // Scenario: Connected but unreachable — honest failure.
    func testUnreachableWhenTheDoorThrows() async {
        let state = await FullHistorySearch.remoteState(
            query: "x", localIds: [], computerConnected: true,
            search: { _ in throw DoorError.transport("computer asleep") })
        XCTAssertEqual(state, .unreachable)
    }

    // Scenario: Empty query searches nothing remote.
    func testEmptyQueryIsIdleAndNeverSearches() async {
        let state = await FullHistorySearch.remoteState(
            query: "   ", localIds: [], computerConnected: true,
            search: { _ in XCTFail("empty query → no search"); return [] })
        XCTAssertEqual(state, .idle)
    }

    // Connected with matches present but all already local → an empty (honest) result,
    // NOT notConnected: the computer WAS searched, it just had nothing to add.
    func testConnectedButAllLocalYieldsEmptyResults() async {
        let doorHits = [hit("omi-a")]
        let state = await FullHistorySearch.remoteState(
            query: "x", localIds: ["omi-a"], computerConnected: true,
            search: { _ in doorHits })
        XCTAssertEqual(state, .results([]))
    }
}
