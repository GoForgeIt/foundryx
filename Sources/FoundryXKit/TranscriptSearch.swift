// TranscriptSearch — the pure layer behind the conversation detail's three faces
// and its in-transcript search (track 20260713T0904, features/conversation-detail.feature).
//
//   • DetailFace — the three faces a conversation opens into (Summary / Actions /
//     Transcript), in display order.
//   • TranscriptSearch — case/diacritic-insensitive substring matching over
//     transcript rows, returning per-row character ranges the view highlights.
//   • TranscriptSearchState — the match cursor: count, "n of m" label, wrapping
//     next/previous navigation.
//   • TranscriptMeaningIndex — the HONEST semantic-search seam. There is no
//     embedding index on the phone today; the meaning toggle exists ONLY when a
//     real index is injected and reports itself available. Never a dead control,
//     never a fake result.
//
// No SwiftUI here — the views (App/ConversationFacesView.swift) render this.

import Foundation

// MARK: - The three faces

/// The faces a conversation detail opens into, in display order. Summary first.
public enum DetailFace: String, CaseIterable, Sendable, Identifiable {
    case summary, actions, transcript

    public var id: String { rawValue }

    /// The face switcher's label.
    public var title: String {
        switch self {
        case .summary: return "Summary"
        case .actions: return "Actions"
        case .transcript: return "Transcript"
        }
    }
}

// MARK: - Text search

/// One search hit: a character-offset range within one transcript row's text.
/// Character offsets (not String.Index) so the match is value-typed and testable;
/// the view converts offsets back into the row string it renders.
public struct TranscriptMatch: Equatable, Sendable {
    /// Index into the searched rows (for a diarized transcript: the turn index;
    /// for a flat transcript: 0).
    public let row: Int
    /// Character-offset range of the matched substring within that row's text.
    public let range: Range<Int>

    public init(row: Int, range: Range<Int>) {
        self.row = row
        self.range = range
    }
}

public enum TranscriptSearch {
    /// All case- and diacritic-insensitive substring matches of `query` across
    /// `rows`, in reading order (row by row, left to right). An empty or
    /// whitespace-only query matches nothing (clearing the field clears the
    /// highlights).
    public static func matches(query: String, in rows: [String]) -> [TranscriptMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var out: [TranscriptMatch] = []
        for (rowIndex, row) in rows.enumerated() {
            var from = row.startIndex
            while from < row.endIndex,
                  let r = row.range(of: q, options: [.caseInsensitive, .diacriticInsensitive],
                                    range: from..<row.endIndex) {
                out.append(TranscriptMatch(
                    row: rowIndex,
                    range: row.distance(from: row.startIndex, to: r.lowerBound)
                        ..< row.distance(from: row.startIndex, to: r.upperBound)))
                // Advance past this hit; guard against a zero-width range so a
                // degenerate match can never loop forever.
                from = r.upperBound > from ? r.upperBound : row.index(after: from)
            }
        }
        return out
    }

    /// Slice a match's text back out of its row — the verification/preview helper.
    /// `nil` when the match doesn't fit the rows it claims (stale state).
    public static func text(of match: TranscriptMatch, in rows: [String]) -> String? {
        guard rows.indices.contains(match.row) else { return nil }
        let row = rows[match.row]
        guard match.range.lowerBound >= 0, match.range.upperBound <= row.count,
              match.range.lowerBound < match.range.upperBound else { return nil }
        let lo = row.index(row.startIndex, offsetBy: match.range.lowerBound)
        let hi = row.index(row.startIndex, offsetBy: match.range.upperBound)
        return String(row[lo..<hi])
    }
}

/// The search cursor the detail view drives: which match is current, the
/// "n of m" position label, and wrapping next/previous. Inert when empty —
/// next/previous on zero matches do nothing.
public struct TranscriptSearchState: Equatable, Sendable {
    public let matches: [TranscriptMatch]
    /// 0-based index of the current match; `nil` when there are no matches.
    public private(set) var currentIndex: Int?

    public init(matches: [TranscriptMatch]) {
        self.matches = matches
        self.currentIndex = matches.isEmpty ? nil : 0
    }

    public var count: Int { matches.count }

    /// The match the view scrolls to and emphasizes.
    public var current: TranscriptMatch? {
        currentIndex.map { matches[$0] }
    }

    /// "2 of 7" while there are matches; "No matches" when the query found none.
    public var positionLabel: String {
        guard let i = currentIndex else { return "No matches" }
        return "\(i + 1) of \(count)"
    }

    /// Step forward, wrapping past the last match back to the first.
    public mutating func next() {
        guard let i = currentIndex, count > 0 else { return }
        currentIndex = (i + 1) % count
    }

    /// Step backward, wrapping before the first match back to the last.
    public mutating func previous() {
        guard let i = currentIndex, count > 0 else { return }
        currentIndex = (i + count - 1) % count
    }
}

// MARK: - Meaning search (the honest seam)

/// A nearest-passage result from a semantic index: the row it points at and its
/// similarity score (0…1).
public struct MeaningMatch: Equatable, Sendable {
    public let row: Int
    public let score: Double

    public init(row: Int, score: Double) {
        self.row = row
        self.score = score
    }
}

/// The semantic-search seam. A REAL index (on-device embeddings, or the connected
/// brain's) conforms and reports availability; the detail view offers the meaning
/// toggle only through `TranscriptSearchCapability`. No conformance ships on the
/// phone today — so today the toggle is absent everywhere, honestly.
public protocol TranscriptMeaningIndex: Sendable {
    /// Whether the index can actually answer for this conversation right now.
    var isAvailable: Bool { get }
    /// The `limit` nearest passages to `query`, best first.
    func nearestPassages(to query: String, limit: Int) async throws -> [MeaningMatch]
}

public enum TranscriptSearchCapability {
    /// Whether the meaning toggle exists at all: only when a real index is
    /// injected AND it reports itself available. Absent index, absent toggle —
    /// never a dead control, never a fake result.
    public static func meaningSearchOffered(_ index: TranscriptMeaningIndex?) -> Bool {
        index?.isAvailable ?? false
    }
}
