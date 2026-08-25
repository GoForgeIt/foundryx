import Foundation

/// Where a conversation currently lives, as the list is entitled to state it.
///
/// ⚠ `bothPlaces` means CURRENTLY, not EVER — and that distinction is the whole point.
/// The phone's local `.lore-confirmed` marker is "the CEILING, preserved through both retention
/// passes": it is retained after deletion by design, so it proves a capture ONCE reached the
/// second place and can never mean "still there". Reading it as residence would tell the owner
/// a DELETED transcript is safe, which is exactly inverted from the question this whole feature
/// exists to answer.
public enum RowResidence: String, Equatable, Sendable {
    /// Held on this phone; the second place did not return it.
    case phoneOnly
    /// Held on this phone AND freshly observed in the second place.
    case bothPlaces
    /// Held only in the second place — nothing on this phone would survive losing it.
    case secondPlaceOnly
    /// The second place could not be asked, or its answer is too old to support a claim.
    /// A REAL answer, not a missing one: an absence must never be rendered as a presence.
    case unknown
}

/// A conversation this phone holds, as the merge needs to see it.
public struct LocalRow: Equatable, Sendable {
    public let captureId: String
    /// Unix seconds. Absent rows sort last rather than to the epoch.
    public let capturedAt: Int64?
    public init(captureId: String, capturedAt: Int64?) {
        self.captureId = captureId
        self.capturedAt = capturedAt
    }
}

/// One row of the merged history, carrying where it lives.
public struct MergedRow: Equatable, Sendable, Identifiable {
    public let captureId: String
    public let residence: RowResidence
    public let capturedAt: Int64?
    /// True when this phone holds it — so the list renders the LOCAL row, with its metadata
    /// and its working actions, rather than the remote stub of the same id.
    public let isLocal: Bool
    public var id: String { captureId }
}

/// Merging what this phone holds with what the second place holds.
public enum MergedHistory {

    /// Merge, dedup by `captureId`, and order by real capture time across BOTH sources.
    ///
    /// - `freshWithin`: the DECLARED staleness window. It is a parameter and not a constant
    ///   here because an undeclared threshold is one any number satisfies; the caller states it
    ///   once and every row is judged against the same rule.
    public static func merge(
        local: [LocalRow],
        remote: [ConversationHit],
        now: Int64,
        freshWithin: Int64
    ) -> [MergedRow] {
        // Freshness decides residence — never response membership. A hit being IN this
        // response is a PAST observation; without a time on it there is nothing to be fresh,
        // so an older second place that sends no `observedAt` yields `unknown`, not `held`.
        var freshRemote: Set<String> = []
        var staleRemote: Set<String> = []
        var remoteById: [String: ConversationHit] = [:]
        for hit in remote {
            remoteById[hit.captureId] = hit
            if let seen = hit.observedAt, now - seen <= freshWithin, now - seen >= 0 {
                freshRemote.insert(hit.captureId)
            } else {
                staleRemote.insert(hit.captureId)
            }
        }

        var rows: [MergedRow] = local.map { row in
            let residence: RowResidence
            if freshRemote.contains(row.captureId) {
                residence = .bothPlaces
            } else if staleRemote.contains(row.captureId) {
                residence = .unknown
            } else {
                residence = .phoneOnly
            }
            return MergedRow(
                captureId: row.captureId,
                residence: residence,
                capturedAt: row.capturedAt,
                isLocal: true
            )
        }

        // Remote rows this phone does not hold. The local row WINS on a shared id — it carries
        // metadata and working actions the remote stub does not.
        let localIds = Set(local.map(\.captureId))
        for hit in remote where !localIds.contains(hit.captureId) {
            rows.append(
                MergedRow(
                    captureId: hit.captureId,
                    residence: freshRemote.contains(hit.captureId) ? .secondPlaceOnly : .unknown,
                    capturedAt: hit.capturedAt,
                    isLocal: false
                )
            )
        }

        // TRUE TIME ORDER across both sources. Grouping by source would put remote rows in a
        // block regardless of when they happened, which reads as an ordering while being none.
        // A row with no time sorts LAST rather than to the epoch — unknown is not "oldest".
        rows.sort { a, b in
            switch (a.capturedAt, b.capturedAt) {
            case let (x?, y?): return x == y ? a.captureId < b.captureId : x > y
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return a.captureId < b.captureId
            }
        }
        return rows
    }
}
