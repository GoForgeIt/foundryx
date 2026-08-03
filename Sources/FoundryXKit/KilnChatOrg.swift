// KilnChatOrg.swift — the MANUAL-ORGANIZATION document the Kiln desktop persists for the
// conversation rail, and the derived views the phone renders from it. A faithful port of
// `chatOrg.ts` (ORG_VERSION 1).
//
// CONTAINMENT MODEL. A chat's PROJECT membership (owned by the sessions store) and its
// MANUAL-GROUP membership (owned by this document) are INDEPENDENT axes over one node set —
// never a nesting, never a mutual exclusion. The Inbox is exactly the set with NEITHER a
// project NOR a manual group. Archive is the existing `archived` flag, a third orthogonal
// state, reused — never a parallel store.
//
// WHAT IS NOT IN THE DOCUMENT (do not expect it, do not invent it): folder nesting,
// collapsed state, lens selection, archived, project membership.
//
// The phone READS this document; it does not write it. Curation stays a desktop gesture for
// now, which is why only the parse + the derived views are ported.

import Foundation

/// A user-made manual group — a curation bucket a chat can be filed into.
public struct KilnGroupDef: Equatable, Sendable, Identifiable {
    /// Stable, opaque group id — the membership key. Never the label (a rename must not
    /// re-home its members).
    public let id: String
    public let name: String
    /// A Grain color-token name for the group's tag, or `nil` for no tag.
    public let color: String?
    /// Manual ordering rank among groups (ascending).
    public let rank: Int
    /// A bound Lore space id. Carried through so a later slice can light up the chip.
    public let loreSpace: String?

    public init(id: String, name: String, color: String? = nil, rank: Int, loreSpace: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.rank = rank
        self.loreSpace = loreSpace
    }
}

/// The whole manual-organization document for one org. Membership / pins / colors are keyed
/// by chat id so a chat keeps its curation across list reloads.
public struct OrgState: Equatable, Sendable {
    public var groups: [KilnGroupDef]
    /// chatId → groupId. Absence ⇒ ungrouped.
    public var membership: [String: String]
    /// chatId → true. Absence ⇒ not pinned. Pinned sorts ahead of unpinned within a zone.
    public var pins: [String: Bool]
    /// chatId → Grain color-token name. Absence ⇒ no tag.
    public var colors: [String: String]
    /// chatId → manual rank within its zone (ascending, sparse floats). Absence ⇒ recency.
    public var order: [String: Double]
    /// Document schema version, so a future migration can detect an older shape.
    public var version: Int

    public init(
        groups: [KilnGroupDef] = [],
        membership: [String: String] = [:],
        pins: [String: Bool] = [:],
        colors: [String: String] = [:],
        order: [String: Double] = [:],
        version: Int = KilnChatOrg.version
    ) {
        self.groups = groups
        self.membership = membership
        self.pins = pins
        self.colors = colors
        self.order = order
        self.version = version
    }
}

public enum KilnChatOrg {

    public static let version = 1

    /// A workspace with no groups. This is what a NEVER-PERSISTED document resolves to, and
    /// it is a legitimate success — not a failure, and not an unreachable library.
    public static let empty = OrgState()

    /// Parse a persisted document back into org state.
    ///
    /// TOLERANT BY CONSTRUCTION: a missing document, an empty string, malformed JSON, or a
    /// partial shape all resolve to a clean, fully-formed EMPTY state rather than throwing. A
    /// corrupt curation file must never brick the library — the conversations are the point,
    /// the grouping is a convenience. Only well-typed fields are adopted; a group with a
    /// non-String or empty `id` is dropped; `name` defaults to the id; `rank` defaults to the
    /// array index.
    ///
    /// This runs over a DOUBLE-ENCODED blob written by a different language, which is exactly
    /// why it is parsed with `JSONSerialization` and hand-typed rather than a `Decodable`
    /// whose first surprise is a throw.
    public static func parseOrg(_ doc: String?) -> OrgState {
        guard let doc, !doc.isEmpty,
              let data = doc.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let o = raw as? [String: Any]
        else { return empty }

        var groups: [KilnGroupDef] = []
        if let rawGroups = o["groups"] as? [Any] {
            var index = 0
            for entry in rawGroups {
                guard let g = entry as? [String: Any] else { continue }
                guard let id = g["id"] as? String, !id.isEmpty else { continue }
                groups.append(KilnGroupDef(
                    id: id,
                    name: (g["name"] as? String) ?? id,
                    color: g["color"] as? String,
                    rank: intValue(g["rank"]) ?? index,
                    loreSpace: g["loreSpace"] as? String))
                index += 1
            }
        }

        return OrgState(
            groups: groups,
            membership: stringMap(o["membership"]),
            pins: pinMap(o["pins"]),
            colors: stringMap(o["colors"]),
            order: numberMap(o["order"]),
            version: intValue(o["version"]) ?? version)
    }

    private static func stringMap(_ v: Any?) -> [String: String] {
        guard let dict = v as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, val) in dict { if let s = val as? String { out[k] = s } }
        return out
    }

    private static func numberMap(_ v: Any?) -> [String: Double] {
        guard let dict = v as? [String: Any] else { return [:] }
        var out: [String: Double] = [:]
        for (k, val) in dict {
            // `true`/`false` bridge to NSNumber in JSONSerialization; a bool is not a rank.
            if let n = val as? NSNumber, !(n is NSNull),
               CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite {
                out[k] = n.doubleValue
            }
        }
        return out
    }

    private static func pinMap(_ v: Any?) -> [String: Bool] {
        guard let dict = v as? [String: Any] else { return [:] }
        var out: [String: Bool] = [:]
        for (k, val) in dict {
            if let n = val as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID(), n.boolValue {
                out[k] = true
            }
        }
        return out
    }

    private static func intValue(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.intValue
    }

    // ── Derived views (pure) — what the rail actually reads ───────────────────

    public static func groupOf(_ state: OrgState, _ chatId: String) -> String? {
        state.membership[chatId]
    }

    public static func isPinned(_ state: OrgState, _ chatId: String) -> Bool {
        state.pins[chatId] == true
    }

    public static func colorOf(_ state: OrgState, _ chatId: String) -> String? {
        state.colors[chatId]
    }

    /// Is a single node an Inbox member? (active ∧ no project ∧ no group ∧ not a loop.)
    ///
    /// The Inbox is what you have not filed YET. Two clauses carry measured weight:
    ///
    /// * `projectId` is the DERIVED project, INCLUDING the synthetic `import-cwd:` one — so
    ///   an imported conversation with a source working directory is never in the Inbox. It
    ///   has a home; it is filed under where it ran.
    /// * `loopId` deliberately keeps recurring-job firings out. On a real library, 2,242 of
    ///   9,897 Inbox rows were automated firings against 26 chats actually held in Kiln — so
    ///   the one thing the Inbox exists to surface was the hardest thing to find in it.
    ///   Nobody is going to file a scheduled firing, and they arrive forever.
    public static func isInbox(_ node: ChatNode, _ state: OrgState) -> Bool {
        node.state == .active
            && node.projectId == nil
            && node.loopId == nil
            && groupOf(state, node.id) == nil
    }

    /// The INBOX set, newest first — the rail's default reading order.
    public static func inboxNodes(_ nodes: [ChatNode], _ state: OrgState) -> [ChatNode] {
        nodes.filter { isInbox($0, state) }
            .sorted { recencyKey($0) > recencyKey($1) }
    }

    /// Recency in ms, with `0` for a missing or unparsable timestamp — such a node sinks.
    public static func recencyKey(_ n: ChatNode) -> Double {
        KilnTimestamp.millis(n.lastActivity) ?? 0
    }

    /// Sort a zone's nodes: PINNED first, then the user's manual order when set, then
    /// recency (newest first). A node with no manual rank sinks below any node that HAS one
    /// but stays above older recency — so an unordered zone is still sensible.
    ///
    /// Ported verbatim from `chatOrg.ts:296-308`, including the "both have an order AND they
    /// differ" guard: two nodes sharing a rank fall through to recency rather than to an
    /// arbitrary order.
    public static func sortZone(_ nodes: [ChatNode], _ state: OrgState) -> [ChatNode] {
        nodes.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            let pa = isPinned(state, a.id) ? 0 : 1
            let pb = isPinned(state, b.id) ? 0 : 1
            if pa != pb { return pa < pb }
            let oa = state.order[a.id]
            let ob = state.order[b.id]
            if let oa, let ob, oa != ob { return oa < ob }
            if oa != nil, ob == nil { return true }
            if oa == nil, ob != nil { return false }
            let ra = recencyKey(a), rb = recencyKey(b)
            if ra != rb { return ra > rb }
            // Swift's sort is not stable; the incoming index keeps it total and
            // reproducible where the desktop relies on Array.prototype.sort's stability.
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
