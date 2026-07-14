import Foundation

/// The state of the "search your whole history" leg of Capture search (track
/// 20260714T1200 AC3). Local matches are computed separately (on-phone captures); this
/// covers the COMPUTER's Lore library, which the phone reaches through the door only
/// when connected. Kept a pure value + a pure async resolver so the merge/dedup and the
/// honest connection states are unit-testable without a live door.
public enum RemoteSearchState: Equatable, Sendable {
    /// No active query — show nothing (the resting list).
    case idle
    /// A query is in flight to the computer.
    case searching
    /// Hits from the computer's library that AREN'T already shown as local rows
    /// (deduped by captureId). May be empty — the computer has nothing more to add.
    case results([ConversationHit])
    /// Phone-only: no computer is connected, so search only sees what's on the phone.
    case notConnected
    /// A computer is connected but the door query failed — the library couldn't be read.
    case unreachable
}

/// Resolves the remote (computer/Lore) half of a full-history search.
public enum FullHistorySearch {
    /// Compute the remote-search state for `query`. An empty query is `.idle`. With no
    /// computer connected it's `.notConnected` (the phone honestly searches only local).
    /// Otherwise it runs `search` and returns the hits that AREN'T already local
    /// (deduped by captureId) — or `.unreachable` if the door threw. `search` is
    /// injected (normally `DoorClient.searchConversations`) so this is testable without
    /// a network.
    public static func remoteState(
        query: String,
        localIds: Set<String>,
        computerConnected: Bool,
        search: @Sendable (String) async throws -> [ConversationHit]
    ) async -> RemoteSearchState {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .idle }
        guard computerConnected else { return .notConnected }
        do {
            let hits = try await search(q)
            return .results(computerOnly(remoteHits: hits, localIds: localIds))
        } catch {
            return .unreachable
        }
    }

    /// Remote hits that aren't already shown as local rows (dedup by captureId), order
    /// preserved (the door returns newest-first).
    public static func computerOnly(
        remoteHits: [ConversationHit],
        localIds: Set<String>
    ) -> [ConversationHit] {
        remoteHits.filter { !localIds.contains($0.captureId) }
    }
}
