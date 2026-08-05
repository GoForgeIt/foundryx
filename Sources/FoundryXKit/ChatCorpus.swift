// ChatCorpus.swift — ONE list of chats, with the place a chat came from as a FACET.
//
// WHY THIS FILE EXISTS
// --------------------
// Nick, 2026-08-05:
//
//   "why are there two lists? Shouldn't the phone chats just be another source in the full
//    computer list? So they should all be one with the same ui to search through them all?"
//
// He is right, and this supersedes the fix that landed hours earlier. That change replaced
// two lookalike header buttons ("Chats" / "All") with one menu naming two PLACES — which
// made the split legible instead of removing it. The split was the defect. A harness is a
// SOURCE joined into one corpus: Kiln is a source, Claude Code is a source, Codex is a
// source, and THE PHONE IS JUST ANOTHER SOURCE.
//
// That is not a metaphor. Measured against the live door (2026-08-05, 2,748 rows):
//
//     origin=kiln 50 · claude-code 917 · codex-cli 1780 · foundryx 1
//
// A chat this phone starts already appears in the Mac's library as `origin: "foundryx"` the
// moment it takes a turn — kiln-session open-or-resumes by (platform, chat_id). So the two
// lists were never disjoint corpora at all; they were one corpus rendered twice, with an
// overlap nobody deduplicated. `merge` is what makes that overlap ONE row.
//
// WHAT IS HERE
//   * `ChatProvenance` — the facet: this phone / Kiln / Claude Code / Codex / anything else.
//   * `PhoneChatSource` — the adapter that turns this phone's own chats into library rows,
//     so the ONE rail (`KilnLibraryPresentation`) groups, sorts and filters them alongside
//     everything else with no second code path.
//   * `ChatCorpus.merge` — the union, deduplicated by id.
//   * `ChatListCoverage` + `MacReach` — what this list is allowed to CLAIM about itself.
//     A list that shows part of a corpus must say so; a search that could only reach one
//     origin must say so. Never let a partial result look complete.

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// The facet
// ─────────────────────────────────────────────────────────────────────────────

/// WHERE A CHAT CAME FROM. A facet over one list — never a door onto a separate list.
///
/// Built from the human source label `KilnLibrary.sourceLabel` already produces, so there is
/// exactly one place that decides what an `origin` string means. An unrecognised origin
/// becomes `.other` carrying its raw value: fail-loud, the same rule `sourceLabel` follows.
public enum ChatProvenance: Equatable, Hashable, Sendable {
    /// Started on this phone. `origin: "foundryx"`.
    case thisPhone
    case kiln
    case claudeCode
    case codex
    /// An origin nothing here recognises, carried verbatim rather than mislabelled.
    case other(String)

    /// Map a human source label (`KilnLibrary.sourceLabel`) onto the facet.
    public init(sourceLabel: String) {
        switch sourceLabel {
        case "FoundryX": self = .thisPhone
        case "Kiln": self = .kiln
        case "Claude Code": self = .claudeCode
        case "Codex": self = .codex
        default: self = .other(sourceLabel)
        }
    }

    /// The facet of a node, straight from the node's already-resolved source label.
    public init(_ node: ChatNode) { self.init(sourceLabel: node.source) }

    /// How the facet reads on a filter chip. Names a SOURCE — never a quantity.
    public var label: String {
        switch self {
        case .thisPhone: return "This phone"
        case .kiln: return "Kiln"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .other(let raw): return raw.isEmpty ? "Unknown" : raw
        }
    }

    /// The compact per-row badge — the same tag the library rows already wear.
    public var shortTag: String { KilnLibrary.sourceTag(sourceLabel).short }

    /// The label this facet corresponds to on a `ChatNode`.
    public var sourceLabel: String {
        switch self {
        case .thisPhone: return "FoundryX"
        case .kiln: return "Kiln"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .other(let raw): return raw
        }
    }

    public var symbol: String {
        switch self {
        case .thisPhone: return "iphone"
        case .kiln: return "flame"
        case .claudeCode: return "chevron.left.forwardslash.chevron.right"
        case .codex: return "terminal"
        case .other: return "bubble.left"
        }
    }

    /// Stable per-chip identifier for the UI + its proofs.
    public var accessibilityIdentifier: String {
        switch self {
        case .thisPhone: return "chat-source-this-phone"
        case .kiln: return "chat-source-kiln"
        case .claudeCode: return "chat-source-claude-code"
        case .codex: return "chat-source-codex"
        case .other(let raw):
            let slug = raw.lowercased()
                .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            return "chat-source-" + String(slug)
        }
    }

    /// Reading order for the chips: this phone first (it is the reader's own), then the
    /// harnesses in the order they became sources, then anything unrecognised, alphabetical.
    var rank: Int {
        switch self {
        case .thisPhone: return 0
        case .kiln: return 1
        case .claudeCode: return 2
        case .codex: return 3
        case .other: return 4
        }
    }

    /// The distinct sources actually present in a node set, in reading order. Derived from
    /// the nodes rather than hard-coded so a source that has no chats does not offer a chip
    /// that filters to nothing.
    public static func present(in nodes: [ChatNode]) -> [ChatProvenance] {
        var seen: [ChatProvenance] = []
        for n in nodes {
            let p = ChatProvenance(n)
            if !seen.contains(p) { seen.append(p) }
        }
        return seen.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return KilnLibraryPresentation.localeCompare(a.label, b.label) < 0
        }
    }

    // ── The rule that keeps a NAME from decaying back into a COUNT ────────────

    /// Words that COUNT rather than NAME. Kept from `ChatScope` (retired with the scope
    /// menu): a surface titled with one of these tells the reader nothing about what it
    /// holds, and beside a sibling it reads as one half of a filter pair. With the two-door
    /// split gone the rule still binds the ONE list's title and its header control.
    public static let bareQuantifiers = ["all", "everything", "other", "more", "rest"]

    /// Is `label` a bare quantifier — the exact defect the two-door era was made of?
    public static func isBareQuantifier(_ label: String) -> Bool {
        bareQuantifiers.contains(
            label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// The ONE header control that opens the ONE list.
///
/// Replaces `ChatScopeCopy`, which named a CHOICE between two corpora. There is no choice
/// to make any more, so the control does not ask one — it opens the list.
public enum ChatListCopy {
    /// Kept from the two-door era on purpose: `open-chats` is an existing UI-test contract,
    /// and changing an identifier at the same moment as the behaviour makes a behaviour
    /// change look like a rename.
    public static let controlAccessibilityIdentifier = "open-chats"
    public static let controlAccessibilityLabel = "Chats"
    public static let controlAccessibilityHint =
        "Opens every chat — the ones on this phone and the ones on your Mac, together"
}

// ─────────────────────────────────────────────────────────────────────────────
// This phone, as a source
// ─────────────────────────────────────────────────────────────────────────────

/// The adapter that makes this phone's own chats READ AS LIBRARY ROWS.
///
/// This is the whole trick. `ChatConversationStore.Conversation` and `LibraryChatRow` were
/// two shapes rendered by two screens; once the phone's chats are library rows, the ONE rail
/// already knows how to sort, group, filter and badge them, and there is no second list to
/// keep in step. `origin: "foundryx"` is not invented for the occasion — it is the origin
/// the store on the Mac ALREADY records for chats this phone started.
public enum PhoneChatSource {

    /// The origin a chat started on this phone carries, on the wire and here.
    public static let origin = "foundryx"

    /// ISO-8601 with a `Z`, the shape `KilnTimestamp.millis` parses — written by
    /// `KilnTimestamp.iso8601`, the exact inverse of the parser the rail sorts with, so a
    /// phone chat and a Mac chat are ordered against the same arithmetic.
    public static func timestamp(_ date: Date) -> String {
        KilnTimestamp.iso8601(millisSince1970: date.timeIntervalSince1970 * 1000)
    }

    /// One phone chat as a library row.
    ///
    /// `lastMessageAt` is the conversation's `updatedAt` — the SAME axis the rail's default
    /// sort reads (`last_message_at ?? started_at`), so a chat typed into on the phone a
    /// minute ago sorts above a Claude Code transcript from this morning, which is the whole
    /// point of one recency-ordered list.
    public static func row(_ c: ChatConversationStore.Conversation) -> LibraryChatRow {
        LibraryChatRow(
            id: c.id,
            title: c.title,
            model: c.modelTargetId,
            origin: origin,
            sensitivity: c.sensitivity,
            archived: 0,
            startedAt: timestamp(c.createdAt),
            org: "",
            lastMessagePreview: c.messages.last?.text,
            lastMessageAt: timestamp(c.updatedAt))
    }

    public static func rows(_ conversations: [ChatConversationStore.Conversation])
        -> [LibraryChatRow] {
        conversations.map(row)
    }

    /// The free text of a phone chat that a search has to be able to reach: its title AND
    /// its messages. The door full-text-searches the Mac's rows over their message CONTENT
    /// (measured: `q=deletion` matches 1,053 of 2,748 rows, including rows whose titles do
    /// not contain the word), so searching the phone's chats by title alone would make the
    /// two halves of one search behave differently.
    public static func searchText(_ c: ChatConversationStore.Conversation) -> String {
        ([c.title] + c.messages.map(\.text)).joined(separator: " ").lowercased()
    }

    /// Which of this phone's chats match `terms` (every term must appear — AND, as the
    /// rail's own free-text filter does). An empty term list matches everything.
    public static func matching(
        _ conversations: [ChatConversationStore.Conversation],
        terms: [String]
    ) -> [ChatConversationStore.Conversation] {
        guard !terms.isEmpty else { return conversations }
        return conversations.filter { c in
            let hay = searchText(c)
            return terms.allSatisfy { hay.contains($0.lowercased()) }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The union
// ─────────────────────────────────────────────────────────────────────────────

public enum ChatCorpus {

    /// The ONE row set: this phone's chats and the Mac's, deduplicated by id.
    ///
    /// THE OVERLAP IS REAL, not defensive. A chat started here appears in the Mac's library
    /// as `origin: "foundryx"` as soon as it takes a turn, because kiln-session
    /// open-or-resumes on the id this phone minted. Rendering both would show one
    /// conversation twice — the precise failure a merged list exists to end.
    ///
    /// The PHONE representation wins for a colliding id: it is the one that can be selected
    /// and typed into locally, and it carries the transcript this device already holds. It
    /// adopts the LATER of the two recency stamps, because the Mac may have seen a turn this
    /// phone has not (a chat continued on the desktop), and sorting it as stale would put it
    /// in the wrong place in the one list.
    public static func merge(phone: [LibraryChatRow], mac: [LibraryChatRow]) -> [LibraryChatRow] {
        guard !phone.isEmpty else { return mac }
        var byId: [String: LibraryChatRow] = [:]
        for p in phone { byId[p.id] = p }

        var out: [LibraryChatRow] = phone
        for m in mac {
            guard let local = byId[m.id] else { out.append(m); continue }
            // Same conversation, two views of it. Keep the local one; take the newer time.
            let localMs = KilnTimestamp.millis(local.lastMessageAt ?? local.startedAt)
            let macMs = KilnTimestamp.millis(m.lastMessageAt ?? m.startedAt)
            guard let macMs, localMs == nil || macMs > localMs! else { continue }
            let lifted = LibraryChatRow(
                id: local.id, title: local.title, model: local.model,
                projectId: local.projectId, origin: local.origin,
                sensitivity: local.sensitivity, archived: local.archived,
                startedAt: local.startedAt, org: local.org,
                lastMessagePreview: local.lastMessagePreview,
                lastMessageAt: m.lastMessageAt ?? m.startedAt)
            if let i = out.firstIndex(where: { $0.id == local.id }) { out[i] = lifted }
        }
        return out
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// What this list is allowed to claim about itself
// ─────────────────────────────────────────────────────────────────────────────

/// Whether the Mac's half of the corpus could be listed at all.
public enum MacReach: Equatable, Sendable {
    case reachable
    /// No computer is bound to this account.
    case noComputer
    /// A door/Kiln failure. The string is user-facing copy from `DoorFailureMessage`.
    case unreachable(String)

    public var isReachable: Bool { self == .reachable }
}

/// HOW MUCH OF THE CORPUS THIS LIST STANDS FOR.
///
/// The trap this closes is the same one the door answers 502/503 for rather than an empty
/// array: a partial answer rendered as if it were the whole one. Two partialities are real
/// here and neither is hypothetical —
///
///   * the phone holds at most 200 of the Mac's 2,748 rows, so an unsearched list is ALWAYS
///     a window onto the most recent slice;
///   * an unreachable Mac means a search reached one origin out of four.
///
/// Neither may render as silence.
public enum ChatListCoverage: Equatable, Sendable {
    /// Every chat in both corpora is standing in this list.
    case complete
    /// The Mac holds more than this list is showing — the `shown` most recent of `total`.
    case truncated(shownFromMac: Int, totalOnMac: Int)
    /// The Mac could not be listed or searched at all; this is this phone's chats only.
    case thisPhoneOnly(reason: String)
    /// The Mac's answer is still in flight.
    case pending

    /// Build the coverage a successful read implies. `total` is what the door says exists
    /// (already narrowed by `q` when a free-text search was sent), `shown` is what arrived.
    public static func make(shownFromMac shown: Int, totalOnMac total: Int) -> ChatListCoverage {
        shown >= total ? .complete : .truncated(shownFromMac: shown, totalOnMac: total)
    }
}
