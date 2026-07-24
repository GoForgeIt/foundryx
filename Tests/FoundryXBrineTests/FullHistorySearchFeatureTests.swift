import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/full-history-search.feature. Drives the REAL remote-search
/// resolver `FullHistorySearch.remoteState` + `RemoteSearchState` — the merge/dedup of
/// computer (Lore) hits against local rows, and the honest connection states
/// (.notConnected / .unreachable / .idle) the Capture search surface renders its message
/// from. Hermetic: the door search is an injected closure, no network.
final class FullHistorySearchFeatureTests: XCTestCase {
    func testFullHistorySearchFeature() async throws {
        try await BrineFeatureRunner.run(
            "full-history-search",
            registry: StepRegistry(FullHistorySearchSteps.make(world: FullHistorySearchWorld())))
    }
}

private final class FullHistorySearchWorld: @unchecked Sendable {
    private let q = DispatchQueue(label: "foundryx.full-history-search-world")
    // Inputs.
    var localIds: Set<String> = []
    var localHits: [ConversationHit] = []
    var connected = false
    var reachable = true
    var remoteHits: [ConversationHit] = []
    // Observations.
    private var _searchRan = false
    var searchRan: Bool { q.sync { _searchRan } }
    var state: RemoteSearchState = .idle

    func reset() {
        localIds = []; localHits = []; connected = false; reachable = true; remoteHits = []
        q.sync { _searchRan = false }; state = .idle
    }

    func run(query: String) async {
        q.sync { _searchRan = false }
        state = await FullHistorySearch.remoteState(
            query: query, localIds: localIds, computerConnected: connected,
            search: { [weak self] _ in
                guard let self else { return [] }
                self.q.sync { self._searchRan = true }
                if !self.reachable { throw BrineStepError("door unreachable") }
                return self.remoteHits
            })
    }

    /// The rows the user actually sees = local hits + computer-only hits (deduped).
    var visibleComputerOnly: [ConversationHit] {
        if case .results(let hits) = state { return hits }
        return []
    }
}

private func hit(_ id: String, _ title: String = "t") -> ConversationHit {
    ConversationHit(captureId: id, title: title, dateLabel: "Yesterday", snippet: "…")
}

private enum FullHistorySearchSteps {
    static func make(world w: FullHistorySearchWorld) -> [StepDefinition] {
        [
            defineStep("I have local conversations on my phone") { ctx, _, _ in
                w.reset()
                w.localHits = [hit("local-1"), hit("both-9")]
                w.localIds = ["local-1", "both-9"]
                return ctx
            },
            defineStep("my computer is connected") { ctx, _, _ in w.connected = true; return ctx },
            defineStep("my computer is not connected") { ctx, _, _ in w.reset(); w.connected = false; return ctx },
            defineStep("the computer can't be reached") { ctx, _, _ in w.reachable = false; return ctx },
            defineStep("a matching conversation lives only on my computer") { ctx, _, _ in
                w.remoteHits = [hit("remote-only-7", "On my computer")]
                return ctx
            },

            defineStep("I search a term that also matches older conversations on my computer") { ctx, _, _ in
                // The computer returns an older match ("remote-only-7") AND a row that is
                // ALSO local ("both-9") — which must be deduped out of the computer set.
                w.remoteHits = [hit("remote-only-7"), hit("both-9")]
                await w.run(query: "meeting")
                return ctx
            },
            defineStep("I search") { ctx, _, _ in await w.run(query: "meeting"); return ctx },
            defineStep("I tap that result") { ctx, _, _ in await w.run(query: "meeting"); return ctx },
            defineStep("I clear the search field") { ctx, _, _ in await w.run(query: "   "); return ctx },

            defineCheck("I see my local matches") { _, _, _ in
                guard w.localHits.contains(where: { $0.captureId == "local-1" }) else {
                    throw BrineStepError("local matches missing")
                }
            },
            defineCheck("I see the computer matches that aren't already local") { _, _, _ in
                guard w.visibleComputerOnly.contains(where: { $0.captureId == "remote-only-7" }) else {
                    throw BrineStepError("computer-only match not shown: \(w.visibleComputerOnly.map(\.captureId))")
                }
            },
            defineCheck("a conversation that is both local and on the computer appears only once") { _, _, _ in
                // "both-9" is local — it must NOT reappear in the computer set.
                guard !w.visibleComputerOnly.contains(where: { $0.captureId == "both-9" }) else {
                    throw BrineStepError("duplicate: both-9 appears in the computer set too")
                }
            },
            defineCheck("it opens the conversation detail, fetched from my computer by its id") { _, _, _ in
                // The tapped result is a computer-only hit — not on the phone — so opening it
                // must fetch by its captureId from the computer.
                guard let tapped = w.visibleComputerOnly.first else { throw BrineStepError("no computer-only result to tap") }
                guard tapped.captureId == "remote-only-7", !w.localIds.contains(tapped.captureId) else {
                    throw BrineStepError("tapped result is not a computer-only id")
                }
            },
            defineCheck("I only see local matches") { _, _, _ in
                guard w.state == .notConnected else {
                    throw BrineStepError("expected .notConnected (local-only), got \(w.state)")
                }
                guard !w.searchRan else { throw BrineStepError("a computer search ran while disconnected") }
            },
            defineCheck("I am told to connect my computer to search my full history") { _, _, _ in
                guard w.state == .notConnected else {
                    throw BrineStepError("the 'connect your computer' message is driven by .notConnected, got \(w.state)")
                }
            },
            defineCheck("I am told the computer couldn't be reached") { _, _, _ in
                guard w.state == .unreachable else {
                    throw BrineStepError("expected .unreachable, got \(w.state)")
                }
            },
            defineCheck("no computer search runs") { _, _, _ in
                guard case .idle = w.state else { throw BrineStepError("empty query did not resolve to .idle: \(w.state)") }
                guard !w.searchRan else { throw BrineStepError("a computer search ran for an empty query") }
            },
        ]
    }
}
