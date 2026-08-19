// KilnLibraryPresentation.swift — lenses, sorting, the typed filter, the zone partition, and
// the honest load states for Kiln's shared conversation library on the phone.
//
// A faithful port of the desktop rail's view logic (`chatLibraryModel.ts` lens/sort/filter
// section + `ChatLibrary.tsx:283-302`). Pure: the SwiftUI layer is a thin renderer over
// `Rail`, so Brine drives every grouping decision with no UI.

import Foundation

public enum KilnLibraryPresentation {

    // ─────────────────────────────────────────────────────────────────────────
    // Lenses and sorts
    // ─────────────────────────────────────────────────────────────────────────

    /// FIVE-plus views over ONE node set, not five data paths.
    public enum Lens: String, CaseIterable, Equatable, Sendable {
        /// EVERYTHING, most recent first, in one run — no project buckets and no Inbox zone.
        ///
        /// Added for the merged list, and it is the thing Nick actually asked for: "they
        /// should all be one". Under the Project lens a chat started on this phone has no
        /// project, so it lands in the INBOX zone above a project-grouped body — which draws
        /// the phone's chats as their own block at the top of the screen and reproduces the
        /// two-list shape the merge exists to end. Archived chats still go to History; being
        /// in one list is not a reason to put last spring back in front of you.
        case recent
        case project, time, tree, state, manual

        public var label: String {
            switch self {
            case .recent: return "Recent"
            case .project: return "Project"
            case .time: return "Time"
            case .tree: return "Tree"
            case .state: return "State"
            case .manual: return "Manual"
            }
        }

        /// Does this lens draw the INBOX zone above its body? `.recent` and `.state` render
        /// every active node in the body themselves, so drawing it too would double them.
        var showsInbox: Bool { self != .recent && self != .state }

        /// Does this lens keep archived chats OUT of the body, in History? `.state` IS the
        /// archived presentation (Active/Archived buckets), so it owns them.
        var showsHistory: Bool { self != .state }
    }

    /// `project` is FIRST among the desktop's lenses and is ITS default — a product decision
    /// the desktop's Brine suite asserts. Changing it here silently desynchronises the two
    /// surfaces, so it stays.
    public static let defaultLens: Lens = .project

    /// What the PHONE's one list opens on. A different surface with a different job: the
    /// desktop rail is a filing cabinet, this is "all my chats, newest first".
    public static let defaultMergedLens: Lens = .recent

    /// How the rail orders conversations WITHIN whatever grouping the lens produces.
    public enum Sort: String, CaseIterable, Equatable, Sendable {
        case recent, created, title

        public var label: String {
            switch self {
            case .recent: return "Last interacted"
            case .created: return "Created"
            case .title: return "Title"
            }
        }
    }

    /// `recent` is the DEFAULT: the rail is a recency surface. Ordering by CREATION time is
    /// exactly the defect that made a freshly imported years-old transcript jump to the top
    /// (an import writes `started_at = now` while carrying the real `last_message_at`).
    public static let defaultSort: Sort = .recent

    /// A conversation's REAL last-interaction time, in ms. `nil` = no measurable time; such
    /// a node sorts LAST, never first.
    public static func lastInteractedAt(_ n: ChatNode) -> Double? {
        KilnTimestamp.millis(n.row.lastMessageAt ?? n.row.startedAt)
    }

    /// When the session row was created. For an IMPORTED row this is the IMPORT time.
    public static func createdAt(_ n: ChatNode) -> Double? {
        KilnTimestamp.millis(n.row.startedAt)
    }

    /// Stand-in for JS `String.localeCompare`, deterministic and locale-free: case-insensitive
    /// first (so "apple" sorts before "Banana", as the desktop's collation does), then a raw
    /// comparison so distinct strings never compare equal.
    static func localeCompare(_ a: String, _ b: String) -> Int {
        let ci = a.compare(b, options: [.caseInsensitive])
        if ci != .orderedSame { return ci == .orderedAscending ? -1 : 1 }
        if a == b { return 0 }
        return a < b ? -1 : 1
    }

    /// Order the node set. Pure; returns a new array and never mutates the input.
    ///
    /// Applied ONCE over the WHOLE node set BEFORE any lens or filter (matching
    /// `ChatLibrary.tsx`), so a group's internal order is the global order restricted — never
    /// a second, differently-keyed sort. Nulls SINK; ties break on `id` so the order is TOTAL,
    /// which is what keeps a scrolling list from shuffling under itself.
    public static func sortNodes(_ nodes: [ChatNode], _ sort: Sort) -> [ChatNode] {
        switch sort {
        case .recent: return byTimestampDesc(nodes, key: lastInteractedAt)
        case .created: return byTimestampDesc(nodes, key: createdAt)
        case .title:
            return nodes.sorted { a, b in
                let t = localeCompare(a.title, b.title)
                if t != 0 { return t < 0 }
                return localeCompare(a.id, b.id) < 0
            }
        }
    }

    private static func byTimestampDesc(
        _ nodes: [ChatNode], key: (ChatNode) -> Double?
    ) -> [ChatNode] {
        nodes.sorted { a, b in
            let av = key(a), bv = key(b)
            if av == bv { return localeCompare(a.id, b.id) < 0 }
            if av == nil { return false }
            if bv == nil { return true }
            if av! != bv! { return av! > bv! }
            return localeCompare(a.id, b.id) < 0
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Typed filter
    // ─────────────────────────────────────────────────────────────────────────

    /// A parsed filter query. All present terms must match (AND).
    public struct ParsedFilter: Equatable, Sendable {
        /// `s:<state>` — matched as a PREFIX of the node's state ("s:act" matches "active").
        public var state: String?
        /// `a:<agent>` — substring of the node's agent/model, case-insensitive.
        public var agent: String?
        /// `#<pr>` — a PR/issue number that must appear in the title.
        public var pr: String?
        /// Bare words — each must appear somewhere in the node's searchable text.
        public var text: [String]

        public var isEmpty: Bool { state == nil && agent == nil && pr == nil && text.isEmpty }
    }

    /// Parse the typed filter mini-language:
    ///   `s:<state>` lifecycle state · `a:<agent>` the answering model · `#<pr>` a PR number
    ///   in the title · anything else is free text, AND-ed across title/project/source/agent.
    /// Later occurrences of a typed key win; unknown `k:v` pairs fall through to free text.
    public static func parseFilter(_ query: String) -> ParsedFilter {
        var out = ParsedFilter(state: nil, agent: nil, pr: nil, text: [])
        for raw in query.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }) {
            let token = String(raw)
            if token.isEmpty { continue }
            if token.hasPrefix("s:") { out.state = String(token.dropFirst(2)).lowercased() }
            else if token.hasPrefix("a:") { out.agent = String(token.dropFirst(2)).lowercased() }
            else if token.hasPrefix("#"), token.count > 1 { out.pr = String(token.dropFirst()) }
            else { out.text.append(token.lowercased()) }
        }
        return out
    }

    /// The free-text haystack: everything a user might reasonably type.
    static func haystack(_ n: ChatNode) -> String {
        [n.title, n.projectName ?? "", n.source, n.agent ?? "", n.state.rawValue]
            .joined(separator: " ").lowercased()
    }

    /// - `freeTextAlreadyApplied`: this node arrived ALREADY narrowed by the door's own
    ///   full-text search, so the free-text terms must NOT be re-applied here. The door
    ///   searches message CONTENT; this side's haystack is title/project/source/agent only.
    ///   Re-applying it would silently DROP every row the door matched on the strength of
    ///   something said inside the conversation — measured: `q=deletion` returns 1,053 rows,
    ///   many titled things like "CW-FoundryX" that no title match would ever keep. The
    ///   typed terms (`s:` / `a:` / `#`) are structural, the door does not understand them,
    ///   and they still apply.
    public static func matchesFilter(
        _ n: ChatNode, _ f: ParsedFilter, freeTextAlreadyApplied: Bool = false
    ) -> Bool {
        if let s = f.state, !n.state.rawValue.hasPrefix(s) { return false }
        if let a = f.agent, !(n.agent ?? "").lowercased().contains(a) { return false }
        if let pr = f.pr, !n.title.contains(pr) { return false }
        if freeTextAlreadyApplied { return true }
        let hay = haystack(n)
        return f.text.allSatisfy { hay.contains($0) }
    }

    /// Narrow the node set by a raw query string. An empty query is the identity.
    ///
    /// `preMatchedIds` names the nodes the DOOR already matched against its own full-text
    /// index (see `matchesFilter`). Everything else is matched here.
    public static func filterNodes(
        _ nodes: [ChatNode], _ query: String, preMatchedIds: Set<String> = []
    ) -> [ChatNode] {
        let f = parseFilter(query)
        if f.isEmpty { return nodes }
        return nodes.filter {
            matchesFilter($0, f, freeTextAlreadyApplied: preMatchedIds.contains($0.id))
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lens grouping
    // ─────────────────────────────────────────────────────────────────────────

    /// A rendered group: stable key, label, ordering rank, and its member nodes.
    public struct NodeGroup: Equatable, Sendable, Identifiable {
        public let key: String
        public let label: String
        public let rank: Int
        public let nodes: [ChatNode]
        /// Tree lens only — per-node indent depth, keyed by node id.
        public let depth: [String: Int]

        public var id: String { key }

        public init(key: String, label: String, rank: Int, nodes: [ChatNode], depth: [String: Int] = [:]) {
            self.key = key
            self.label = label
            self.rank = rank
            self.nodes = nodes
            self.depth = depth
        }
    }

    /// Apply a lens to the (already sorted, already filtered) node set. Nodes keep their
    /// incoming order.
    ///
    /// The desktop threads a `ManualView` of three closures into this; here the `OrgState`
    /// is passed directly, because closures are neither `Equatable` nor `Sendable` and the
    /// three closures are all derivable from the state anyway. Structural difference only —
    /// the grouping decisions are identical. `nil` means "no org loaded at all" and degrades
    /// the manual lens to one honest "Unsorted" bucket, exactly as the desktop does.
    public static func groupByLens(
        _ nodes: [ChatNode],
        lens: Lens,
        org: OrgState?,
        nowMs: Double
    ) -> [NodeGroup] {
        switch lens {
        case .recent: return recentGroups(nodes)
        case .project: return projectGroups(nodes)
        case .time: return timeGroups(nodes, nowMs: nowMs)
        case .tree: return treeGroups(nodes)
        case .state: return stateGroups(nodes)
        case .manual: return manualGroups(nodes, org: org)
        }
    }

    /// Groups sort by `rank`, then label. Bucket ORDER of first appearance is preserved
    /// within a rank tie only through the label comparison, matching the desktop.
    private static func bucket(
        _ nodes: [ChatNode],
        _ keyOf: (ChatNode) -> (key: String, label: String, rank: Int)
    ) -> [NodeGroup] {
        var order: [String] = []
        var byKey: [String: (label: String, rank: Int, nodes: [ChatNode])] = [:]
        for n in nodes {
            let k = keyOf(n)
            if byKey[k.key] == nil {
                byKey[k.key] = (k.label, k.rank, [])
                order.append(k.key)
            }
            byKey[k.key]!.nodes.append(n)
        }
        return order.map { key in
            let g = byKey[key]!
            return NodeGroup(key: key, label: g.label, rank: g.rank, nodes: g.nodes)
        }.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return localeCompare(a.label, b.label) < 0
        }
    }

    /// Recent lens — ONE group holding every node it is given, in the order it is given
    /// them (the global sort, which defaults to last-interacted descending). No bucketing at
    /// all: this is the merged list's default, and its whole claim is that a chat from this
    /// phone and a chat from Claude Code sit next to each other purely by when they happened.
    static func recentGroups(_ nodes: [ChatNode]) -> [NodeGroup] {
        [NodeGroup(key: "r:all", label: "Recent", rank: 0, nodes: nodes)]
    }

    /// Project lens — one group per project, project-less chats sinking to the
    /// bottom. An imported conversation lands under its SYNTHETIC `import-cwd:` project.
    static func projectGroups(_ nodes: [ChatNode]) -> [NodeGroup] {
        bucket(nodes) { n in
            if let name = n.projectName, let pid = n.projectId {
                return (key: "p:\(pid)", label: name, rank: 0)
            }
            return (key: "p:none", label: "No project", rank: 1)
        }
    }

    /// Time lens — recency buckets over the REAL last interaction. Boundaries are calendar-day
    /// aligned to the LOCAL day so "Today" means today, not "the last 24 hours"; a
    /// conversation with no recorded interaction lands in Older rather than being passed off
    /// as recent. Only non-empty buckets render.
    static func timeGroups(_ nodes: [ChatNode], nowMs: Double) -> [NodeGroup] {
        let dayMs = 24.0 * 60 * 60 * 1000
        let dayStart = KilnTimestamp.startOfLocalDay(nowMs)
        let weekStart = dayStart - 6 * dayMs
        let monthStart = dayStart - 29 * dayMs
        return bucket(nodes) { n in
            guard let t = lastInteractedAt(n) else {
                return (key: "tb:older", label: "Older", rank: 3)
            }
            if t >= dayStart { return (key: "tb:today", label: "Today", rank: 0) }
            if t >= weekStart { return (key: "tb:week", label: "This week", rank: 1) }
            if t >= monthStart { return (key: "tb:month", label: "This month", rank: 2) }
            return (key: "tb:older", label: "Older", rank: 3)
        }
    }

    /// State lens — active first, then archived.
    static func stateGroups(_ nodes: [ChatNode]) -> [NodeGroup] {
        bucket(nodes) { n in
            n.state == .active
                ? (key: "s:active", label: "Active", rank: 0)
                : (key: "s:archived", label: "Archived", rank: 1)
        }
    }

    /// Manual lens — the user's own persisted groups.
    ///
    /// EVERY user group renders, INCLUDING an EMPTY one. On the desktop an empty group must
    /// stay a visible drop target (a group that vanished could never receive its first
    /// member); on the phone it stays a visible destination and an honest statement that the
    /// group exists. Chats with no membership fall into a trailing "Unsorted" bucket.
    static func manualGroups(_ nodes: [ChatNode], org: OrgState?) -> [NodeGroup] {
        guard let org else {
            return bucket(nodes) { _ in (key: "m:unsorted", label: "Unsorted", rank: 0) }
        }
        var rankOf: [String: Int] = [:]
        for g in org.groups { rankOf[g.id] = g.rank }
        var byGroup: [String: [ChatNode]] = [:]
        var unsorted: [ChatNode] = []
        for n in nodes {
            if let gid = KilnChatOrg.groupOf(org, n.id), rankOf[gid] != nil {
                byGroup[gid, default: []].append(n)
            } else {
                unsorted.append(n)
            }
        }
        var out: [NodeGroup] = []
        let ordered = org.groups.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return localeCompare(a.name, b.name) < 0
        }
        for g in ordered {
            out.append(NodeGroup(
                key: "m:\(g.id)", label: g.name, rank: g.rank,
                nodes: KilnChatOrg.sortZone(byGroup[g.id] ?? [], org)))
        }
        if !unsorted.isEmpty {
            out.append(NodeGroup(
                key: "m:unsorted", label: "Unsorted", rank: Int.max,
                nodes: KilnChatOrg.sortZone(unsorted, org)))
        }
        return out
    }

    /// Tree lens — FORK LINEAGE, and labeled as such.
    ///
    /// `parent_chat_id` is written ONLY by `fork_chat`. It is fork lineage, NOT a subagent
    /// edge: the true subagent edge is `parent_task_session_id`, whose children are dropped
    /// from the top level entirely and would need `GET /sessions/:id/children` to expand. So
    /// this lens renders the ONE relationship the library read actually carries and NAMES it
    /// "Fork lineage" rather than pretending to be a subagent tree. Never conflate the two.
    ///
    /// A parent outside the current FILTERED set can't be shown, so such a node roots itself
    /// — a match is never hidden under an absent ancestor.
    static func treeGroups(_ nodes: [ChatNode]) -> [NodeGroup] {
        var byId: [String: ChatNode] = [:]
        for n in nodes { byId[n.id] = n }
        var childrenOf: [String: [ChatNode]] = [:]
        var roots: [ChatNode] = []
        for n in nodes {
            if let p = kilnTruthy(n.forkParentId), byId[p] != nil {
                childrenOf[p, default: []].append(n)
            } else {
                roots.append(n)
            }
        }
        var ordered: [ChatNode] = []
        var depth: [String: Int] = [:]
        // Depth-first flatten so a fork renders directly beneath the chat it came from.
        // The `depth` map doubles as the cycle guard, exactly as the desktop's does.
        func walk(_ n: ChatNode, _ d: Int) {
            if depth[n.id] != nil { return }
            depth[n.id] = d
            ordered.append(n)
            for c in childrenOf[n.id] ?? [] { walk(c, d + 1) }
        }
        for r in roots { walk(r, 0) }
        let anyForks = ordered.contains { (depth[$0.id] ?? 0) > 0 }
        return [NodeGroup(
            key: "t:lineage",
            label: anyForks ? "Fork lineage" : "Fork lineage (no forks yet)",
            rank: 0, nodes: ordered, depth: depth)]
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The zone partition — what the phone actually draws, top to bottom
    // ─────────────────────────────────────────────────────────────────────────

    /// One fully-derived rendering of the library. Render order is Loops → Inbox → lens body
    /// → History/Archive.
    public struct Rail: Equatable, Sendable {
        /// The Loops zone. ALWAYS EMPTY today, and honestly so: the desktop feeds it from a
        /// separate loops source that the door does not proxy. Recurring firings still
        /// collapse to one series row in the body, which is the part that matters.
        public let loops: [ChatNode]
        public let inbox: [ChatNode]
        public let groups: [NodeGroup]
        public let archived: [ChatNode]
        /// True while a filter is typed — every zone force-expands so a match is never hidden.
        public let filtering: Bool
        /// Rows that SPAWNED subagent children. The phone cannot expand them; it says so.
        public let parentIds: Set<String>
        /// How many top-level rows the library read produced, before filtering.
        public let totalNodes: Int
        /// How many rows the server says exist in total (`LibraryPage.total`).
        public let totalRows: Int
        /// Whether the Mac's half of the corpus could be listed at all. NOT reachable ⇒ the
        /// list is this phone's chats only and MUST say so — see `KilnLibraryCopy.reachLine`.
        public let macReach: MacReach
        /// How much of the corpus this list stands for. Never silent about a partial answer.
        public let coverage: ChatListCoverage
        /// The source facet in force, or `nil` for every source. A row hidden by a facet is
        /// hidden by a control the reader can see (`KilnLibraryCopy.provenanceLine`).
        public let provenance: ChatProvenance?
        /// The sources actually present in the unfiltered node set — the chips to offer.
        public let sourcesPresent: [ChatProvenance]

        public init(
            loops: [ChatNode] = [], inbox: [ChatNode] = [], groups: [NodeGroup] = [],
            archived: [ChatNode] = [], filtering: Bool = false,
            parentIds: Set<String> = [], totalNodes: Int = 0, totalRows: Int = 0,
            macReach: MacReach = .reachable,
            coverage: ChatListCoverage = .complete,
            provenance: ChatProvenance? = nil,
            sourcesPresent: [ChatProvenance] = []
        ) {
            self.loops = loops
            self.inbox = inbox
            self.groups = groups
            self.archived = archived
            self.filtering = filtering
            self.parentIds = parentIds
            self.totalNodes = totalNodes
            self.totalRows = totalRows
            self.macReach = macReach
            self.coverage = coverage
            self.provenance = provenance
            self.sourcesPresent = sourcesPresent
        }

        /// Nothing at all to show — genuinely empty, which is a DIFFERENT fact from "the
        /// door could not ask".
        public var isEmpty: Bool { loops.isEmpty && inbox.isEmpty && archived.isEmpty
            && groups.allSatisfy { $0.nodes.isEmpty } }

        /// Every node the rail renders, in reading order.
        public var allNodes: [ChatNode] { loops + inbox + groups.flatMap(\.nodes) + archived }

        /// A section is open while FILTERING regardless of what the user collapsed — a
        /// collapsed History zone must never hide a search match.
        public func isOpen(_ key: String, collapsed: Set<String>) -> Bool {
            filtering || !collapsed.contains(key)
        }
    }

    /// Build the rail. Ported from `ChatLibrary.tsx:283-302`.
    ///
    /// The State lens IS the archived presentation (Active/Archived buckets), so it shows
    /// every node in its body and SUPPRESSES the Inbox/History zones to avoid double-render.
    public static func rail(
        rows: [LibraryChatRow],
        projects: [KilnProjectRow] = [],
        org: OrgState,
        lens: Lens = defaultLens,
        sort: Sort = defaultSort,
        query: String = "",
        provenance: ChatProvenance? = nil,
        preMatchedIds: Set<String> = [],
        macReach: MacReach = .reachable,
        coverage: ChatListCoverage = .complete,
        nowMs: Double,
        totalRows: Int = 0
    ) -> Rail {
        let nodes = KilnLibrary.toNodes(rows: rows, projects: projects)
        let sorted = sortNodes(nodes, sort)
        let matched = filterNodes(sorted, query, preMatchedIds: preMatchedIds)
        // The source facet narrows AFTER the query, and the chips are derived from the
        // UNFACETED set — so choosing "Claude Code" can never make the chip that would take
        // you back disappear.
        let visible = provenance.map { p in matched.filter { ChatProvenance($0) == p } } ?? matched

        let activeNodes = visible.filter { $0.state == .active }
        let archivedNodes = visible.filter { $0.state == .archived }
        let inbox = lens.showsInbox ? KilnChatOrg.inboxNodes(activeNodes, org) : []
        let inboxIds = Set(inbox.map(\.id))
        let bodyNodes = lens.showsHistory
            ? activeNodes.filter { !inboxIds.contains($0.id) }
            : visible
        let bodyGroups = groupByLens(bodyNodes, lens: lens, org: org, nowMs: nowMs)

        return Rail(
            loops: [],
            inbox: inbox,
            groups: bodyGroups,
            archived: lens.showsHistory ? archivedNodes : [],
            filtering: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            parentIds: KilnLibrary.parentSessionIds(rows),
            totalNodes: nodes.count,
            totalRows: totalRows,
            macReach: macReach,
            coverage: coverage,
            provenance: provenance,
            sourcesPresent: ChatProvenance.present(in: nodes))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Honest load states
    // ─────────────────────────────────────────────────────────────────────────

    /// What the library surface is showing.
    ///
    /// `.loaded([])` and `.unreachable` are DIFFERENT STATES and must render differently —
    /// that separation is the entire reason the door answers 502/503 instead of an empty
    /// list. An empty list reads as "you have no conversations"; the truth in those cases is
    /// "the door could not ask", and the phone owns the last mile of not lying about it.
    public enum State: Equatable, Sendable {
        case idle
        case loading
        /// A real answer from Kiln. May LEGITIMATELY be empty.
        case loaded(Rail)
        /// No computer is bound to this account at all.
        case notConnected
        /// 502/503 or a transport failure. The string is user-facing copy from
        /// `DoorFailureMessage` — never a status code, never an NSError domain.
        case unreachable(String)
    }

    /// Everything one library read needs to produce a rail.
    public struct Load: Sendable {
        public let page: LibraryPage
        public let org: OrgState
        public let projects: [KilnProjectRow]
        public init(page: LibraryPage, org: OrgState, projects: [KilnProjectRow] = []) {
            self.page = page
            self.org = org
            self.projects = projects
        }
    }

    /// Resolve the ONE list's state. `load` is injected (normally the two `DoorClient` reads)
    /// so this is testable without a network.
    ///
    /// A THROW NEVER BECOMES AN EMPTY RAIL, and — since the phone is a SOURCE and not a
    /// second list — a throw never becomes a blank screen either. Three outcomes:
    ///
    ///   * the Mac answered  ⇒ `.loaded`, both sources merged, coverage stated;
    ///   * the Mac failed and this phone HAS chats ⇒ `.loaded` with the phone's chats and
    ///     `macReach = .unreachable`, so the list shows what it honestly has AND says the
    ///     Mac's chats are missing from it. Showing them silently, as if that were
    ///     everything, is the exact lie the 502/503 contract exists to prevent;
    ///   * the Mac failed and there is nothing else to show ⇒ `.unreachable`. There is no
    ///     honest list to draw, so the failure IS the screen.
    ///
    /// `phoneRows` must already be narrowed by the free-text half of `query`
    /// (`PhoneChatSource.matching`) — the door narrows its own rows and this side cannot
    /// re-apply free text to them without dropping content matches. See `matchesFilter`.
    public static func resolve(
        computerConnected: Bool,
        /// WHICH BRAIN this account resolved to. Required, no default: the coverage and
        /// reach sentences this builds name the second place out loud, and a default here
        /// would name a Mac for a Vault owner.
        destination: CaptureDestination,
        phoneRows: [LibraryChatRow] = [],
        lens: Lens = defaultLens,
        sort: Sort = defaultSort,
        query: String = "",
        provenance: ChatProvenance? = nil,
        nowMs: Double,
        load: @Sendable () async throws -> Load
    ) async -> State {
        func phoneOnly(_ reach: MacReach) -> State {
            .loaded(rail(
                rows: phoneRows, org: KilnChatOrg.empty,
                lens: lens, sort: sort, query: query, provenance: provenance,
                preMatchedIds: Set(phoneRows.map(\.id)), macReach: reach,
                coverage: .thisPhoneOnly(
                    reason: KilnLibraryCopy.reason(reach, destination: destination)),
                nowMs: nowMs, totalRows: phoneRows.count))
        }

        guard computerConnected else {
            guard !phoneRows.isEmpty else { return .notConnected }
            return phoneOnly(.noComputer)
        }
        do {
            let loaded = try await load()
            let mac = loaded.page.chats
            return .loaded(rail(
                rows: ChatCorpus.merge(phone: phoneRows, mac: mac),
                projects: loaded.projects, org: loaded.org,
                lens: lens, sort: sort, query: query, provenance: provenance,
                // EVERY row here was already matched by a full-text search of its own
                // source: the Mac's by the door's index, the phone's by
                // `PhoneChatSource.matching`. Both look INSIDE the conversation; this
                // side's haystack is title/project/source/agent. Re-applying the free text
                // here would therefore throw away exactly the rows that matched on
                // something SAID — which is most of them.
                preMatchedIds: Set(mac.map(\.id)).union(phoneRows.map(\.id)),
                macReach: .reachable,
                coverage: ChatListCoverage.make(
                    shownFromMac: mac.count, totalOnMac: loaded.page.total),
                nowMs: nowMs, totalRows: loaded.page.total))
        } catch {
            let line = (error as? KilnLibraryError).map {
                DoorFailureMessage.make(kilnLibraryFailure: $0, destination: destination).line
            } ?? DoorFailureMessage.make(doorTransportFailure: error,
                                         destination: destination).line
            guard !phoneRows.isEmpty else { return .unreachable(line) }
            return phoneOnly(.unreachable(line))
        }
    }
}
