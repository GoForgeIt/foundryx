import Foundation

/// One page of the second place's conversation list: the rows, plus what the ENVELOPE said.
///
/// `total` and `nextCursor` are optional because the phone and the door version independently.
/// An absent `total` means UNKNOWN — never zero, which would report "the second place holds
/// nothing", indistinguishable from a genuinely empty history.
public struct ConversationPageResult: Equatable, Sendable {
    public let conversations: [ConversationHit]
    public let total: Int?
    public let nextCursor: String?
    public init(conversations: [ConversationHit], total: Int? = nil, nextCursor: String? = nil) {
        self.conversations = conversations
        self.total = total
        self.nextCursor = nextCursor
    }
}

/// Following the second place's cursor to exhaustion.
///
/// AC12 asks that the remainder be REACHABLE, not merely announced — spec review round 4 named
/// the counted-and-disclosed-but-never-reached pair as its blocking defect. This is the
/// reaching half.
public enum HistoryPaging {

    public enum PagingError: Error, Equatable {
        /// The cursor never went nil within the bound. A cursor that ignores its input
        /// re-serves page one forever; without a bound the walk HANGS instead of failing, and
        /// a caller that never returns is worse than one that returns an error.
        case didNotTerminate(pagesFollowed: Int)
        /// A page returned no rows while still promising more. Following it would spin, and
        /// treating it as the end would silently drop whatever it claimed was behind it —
        /// so it is neither followed nor ignored.
        case emptyPagePromisedMore
    }

    /// Walk every page, in order, deduped by `captureId`.
    ///
    /// - `maxPages`: the termination bound. Generous by default — this exists to convert a
    ///   broken cursor from a HANG into a NAMED failure, not to cap real histories.
    public static func everything(
        pageLimit: Int,
        maxPages: Int = 200,
        fetch: (String?) async throws -> ConversationPageResult
    ) async throws -> [ConversationHit] {
        var out: [ConversationHit] = []
        var seen: Set<String> = []
        var cursor: String? = nil
        var pages = 0

        while pages < maxPages {
            let page = try await fetch(cursor)
            pages += 1

            if page.conversations.isEmpty, page.nextCursor != nil {
                throw PagingError.emptyPagePromisedMore
            }
            for hit in page.conversations where seen.insert(hit.captureId).inserted {
                out.append(hit)
            }
            guard let next = page.nextCursor, !next.isEmpty else { return out }
            cursor = next
        }
        throw PagingError.didNotTerminate(pagesFollowed: pages)
    }
}
