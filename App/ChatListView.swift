import SwiftUI
import Grain

// ONE list of chats — this phone's and the Mac's, together.
//
// Nick, 2026-08-05: "why are there two lists? Shouldn't the phone chats just be another
// source in the full computer list? So they should all be one with the same ui to search
// through them all?"
//
// So there is no "Kiln library" screen and no phone-only chat drawer any more; there is a
// list, and where a chat came from is a FACET of a row (`ChatProvenance`), not a door onto a
// different screen. This is still a THIN RENDERER: every grouping, collapse, ordering,
// merge and honesty decision lives in `ChatCorpus` / `KilnLibraryPresentation` /
// `KilnLibrary` / `KilnChatOrg` (pure, Brine-driven). Nothing here re-decides any of it.

/// Loads both halves of the corpus and holds the derived rail. `ObservableObject`, never
/// `@Observable` — the package floor is iOS 16.
@MainActor
final class ChatListStore: ObservableObject {

    @Published private(set) var state: KilnLibraryPresentation.State = .idle
    @Published var lens: KilnLibraryPresentation.Lens = KilnLibraryPresentation.defaultMergedLens
    @Published var sort: KilnLibraryPresentation.Sort = KilnLibraryPresentation.defaultSort
    @Published var query = ""
    /// The source facet in force. `nil` = every source, which is the DEFAULT view.
    @Published var provenance: ChatProvenance?
    @Published var collapsed: Set<String> = ["z:archive"]
    /// A door search is in flight for a query the held rows do not yet answer.
    @Published private(set) var searchPending = false

    /// The Mac's rows as last read, plus the org document, so a lens/sort/facet change
    /// re-derives the rail WITHOUT another door round trip. Re-fetching on every keystroke
    /// would make the desktop's instant regrouping feel like a network operation.
    private var macRows: [LibraryChatRow] = []
    private var org: OrgState = KilnChatOrg.empty
    private var totalOnMac = 0
    private var macReach: MacReach = .reachable
    /// The free text the door was last asked for. A query whose free text differs is a
    /// question the held rows cannot answer, and the list says so until the answer lands.
    private var loadedFreeText = ""
    private var searchTask: Task<Void, Never>?

    /// This phone's own chats — the same live store the chat screen renders and sends into.
    private let chats: ChatConversationStore
    private let target: DoorTarget
    private let log: DoorLog?
    private let accountBinding: CaptureAccountScope.AccountBinding
    private let computerConnected: Bool

    init(chats: ChatConversationStore,
         target: DoorTarget, log: DoorLog?,
         accountBinding: CaptureAccountScope.AccountBinding,
         computerConnected: Bool) {
        self.chats = chats
        self.target = target
        self.log = log
        self.accountBinding = accountBinding
        self.computerConnected = computerConnected
    }

    var isLoading: Bool { if case .loading = state { return true }; return false }

    /// The free-text half of the typed query — what the DOOR can answer. The typed terms
    /// (`s:` / `a:` / `#`) are structural and stay on this side.
    private var freeText: String {
        KilnLibraryPresentation.parseFilter(query).text.joined(separator: " ")
    }

    /// This phone's chats, already narrowed by the free text, as library rows. Read LIVE
    /// each time, so a chat started or renamed a moment ago is in the list without a fetch.
    private var phoneRows: [LibraryChatRow] {
        PhoneChatSource.rows(
            PhoneChatSource.matching(
                chats.conversations,
                terms: KilnLibraryPresentation.parseFilter(query).text))
    }

    func load() async {
        let asked = freeText
        state = .loading
        let client = DoorClient(target: target, log: log)
        let binding = accountBinding
        let (lens, sort, query, provenance) = (self.lens, self.sort, self.query, self.provenance)
        let phone = phoneRows

        // Captured out of the load closure so a reprojection can regroup without refetching.
        let captured = LoadCapture()

        let resolved = await KilnLibraryPresentation.resolve(
            computerConnected: computerConnected,
            phoneRows: phone,
            lens: lens, sort: sort, query: query, provenance: provenance,
            nowMs: Date().timeIntervalSince1970 * 1000,
            load: {
                // The library is the answer; the org document is a convenience over it. If
                // the grouping read fails we still show the conversations, ungrouped —
                // losing the library because a curation file could not be read would be the
                // tail wagging the dog. A library failure still THROWS, which now degrades
                // to "this phone's chats, and we SAY the Mac is missing" — never an empty
                // list, and never a phone-only list presented as everything.
                //
                // The free text rides to the DOOR (`q=`), which searches the Mac's whole
                // corpus including message content — not the 200 rows this phone happens to
                // be holding. That is what makes one search span both origins.
                async let page = client.kilnLibrary(limit: 200, query: asked)
                async let org = try? client.kilnChatOrg()
                let loaded = KilnLibraryPresentation.Load(
                    page: try await page, org: await org ?? KilnChatOrg.empty)
                await captured.keep(loaded)
                return loaded
            })

        // Every completion that touches UI must still be the account that started it.
        // A signed-out-and-back-in mid-fetch must not paint another account's library.
        let kept = await captured.taken
        CaptureAccountScope.perform(as: binding) { _ in
            self.macRows = kept?.page.chats ?? []
            self.org = kept?.org ?? KilnChatOrg.empty
            self.totalOnMac = kept?.page.total ?? 0
            self.macReach = Self.reach(of: resolved, connected: self.computerConnected)
            self.loadedFreeText = asked
            self.searchPending = false
            self.state = resolved
        }
    }

    /// What `resolve` concluded about the Mac, read back off the state it produced. Kept as
    /// one function so the store never forms a second opinion about reachability.
    private static func reach(of state: KilnLibraryPresentation.State,
                              connected: Bool) -> MacReach {
        switch state {
        case .loaded(let rail): return rail.macReach
        case .unreachable(let line): return .unreachable(line)
        case .notConnected: return .noComputer
        case .idle, .loading: return connected ? .reachable : .noComputer
        }
    }

    /// Re-derive from what we already hold. Pure and instant — no door call.
    ///
    /// The phone's rows are re-read LIVE, so this also picks up a chat started since the
    /// last fetch. The coverage it reports is honest about the door not having been asked
    /// the current question yet.
    func reproject() {
        guard case .loaded = state else { return }
        let pending = freeText != loadedFreeText
        let coverage: ChatListCoverage = {
            if !macReach.isReachable {
                return .thisPhoneOnly(reason: KilnLibraryCopy.reason(macReach))
            }
            if pending { return .pending }
            return ChatListCoverage.make(shownFromMac: macRows.count, totalOnMac: totalOnMac)
        }()
        let phone = phoneRows
        state = .loaded(KilnLibraryPresentation.rail(
            rows: ChatCorpus.merge(phone: phone, mac: macReach.isReachable ? macRows : []),
            org: org, lens: lens, sort: sort, query: query, provenance: provenance,
            // The phone's rows were just narrowed by `PhoneChatSource.matching`, which looks
            // inside the conversation — so they are always pre-matched, and re-applying the
            // free text here would drop every chat that matched on something SAID rather
            // than on its title. The Mac's rows carry that claim only while the door has
            // actually been asked the CURRENT free text; a query that has moved on falls
            // back to matching them here — narrower, and honest, until the answer lands.
            preMatchedIds: Set(phone.map(\.id)).union(
                pending || !macReach.isReachable ? [] : macRows.map(\.id)),
            macReach: macReach, coverage: coverage,
            nowMs: Date().timeIntervalSince1970 * 1000,
            totalRows: totalOnMac))
        searchPending = pending
    }

    /// The query changed. Reproject NOW so typing feels instant, and ask the door for the
    /// whole corpus behind it — debounced, because a fetch per keystroke is a fetch per
    /// keystroke. Until that answer lands the list says it is still searching.
    func queryChanged() {
        reproject()
        searchTask?.cancel()
        guard freeText != loadedFreeText else { searchPending = false; return }
        searchPending = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.load()
        }
    }

    func toggle(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    /// Is this row one of THIS PHONE's chats — selectable and typed into locally, rather
    /// than opened as a chat resident on the Mac? Asked of the local store by id, never of
    /// the origin alone: the Mac's library also carries `origin: "foundryx"` rows for chats
    /// this phone started and has since deleted, and those are not local to open.
    func localConversation(_ id: String) -> ChatConversationStore.Conversation? {
        chats.conversation(id)
    }

    func select(_ id: String) { chats.select(id) }

    func newChat() { chats.newConversation() }

    func deleteLocal(_ id: String) {
        chats.delete(id)
        // A deleted chat must never be routed back to (EXT2 honesty).
        ActionChatLinkStore.removeLinks(toChatId: id, baseDir: CaptureWAL.documentsCaptures())
        reproject()
    }
}

/// A one-slot mailbox for the page the injected `load` closure fetched, so the store can keep
/// the RAW rows for reprojection without `resolve` having to hand them back.
private actor LoadCapture {
    private(set) var taken: KilnLibraryPresentation.Load?
    func keep(_ loaded: KilnLibraryPresentation.Load) { taken = loaded }
}

/// THE chat list. Opened from the Chat tab's header — deliberately NOT a fifth tab:
/// `features/app-shell.feature` asserts exactly four, and there is a recorded product
/// decision against adding one.
struct ChatListView: View {
    @ObservedObject var chats: ChatConversationStore
    let target: DoorTarget
    let log: DoorLog
    let accountBinding: CaptureAccountScope.AccountBinding
    let computerConnected: Bool
    var onDismiss: () -> Void

    @StateObject private var store: ChatListStore
    @State private var opened: LibraryChatRow?

    init(chats: ChatConversationStore,
         target: DoorTarget, log: DoorLog,
         accountBinding: CaptureAccountScope.AccountBinding,
         computerConnected: Bool,
         onDismiss: @escaping () -> Void) {
        self.chats = chats
        self.target = target
        self.log = log
        self.accountBinding = accountBinding
        self.computerConnected = computerConnected
        self.onDismiss = onDismiss
        _store = StateObject(wrappedValue: ChatListStore(
            chats: chats, target: target, log: log, accountBinding: accountBinding,
            computerConnected: computerConnected))
    }

    var body: some View {
        NavigationStack {
            content
                // ONE list, so its name is the thing itself. "All chats" was a bare
                // quantifier that neither said what was in it nor distinguished it from the
                // other list that used to exist — and there is no other list now.
                .navigationTitle(KilnLibraryCopy.listTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("New") { store.newChat(); onDismiss() }
                            .accessibilityIdentifier("new-chat")
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onDismiss)
                            .accessibilityIdentifier("chat-list-done")
                    }
                }
        }
        .task { await store.load() }
        .sheet(item: $opened) { row in
            KilnConversationView(
                row: row, target: target, log: log,
                accountBinding: accountBinding,
                onDismiss: { opened = nil },
                onPickedUp: { Task { await store.load() } })
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            // A door fetch can outlast a spinner's welcome; the waiting experience says what
            // is happening and where the data is going.
            WaitingExperienceView(model: WaitingExperienceModel(kind: .doorFetch, onDevice: false))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .grainBackground()
                .accessibilityIdentifier("chat-list-loading")

        case .notConnected:
            // Reached only when there is NOTHING else to show — this phone's own chats are
            // rows in this list, so any chat at all means the list draws with a banner
            // instead of this screen.
            GrainEmptyState(
                systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                title: "No computer is connected",
                message: "Open Solleva on your Mac and sign in with the same account to reach "
                    + "the chats you have there.")
                .accessibilityIdentifier("chat-list-not-connected")

        case .unreachable(let message):
            // DELIBERATELY a different view AND different words from the empty state. The
            // door answers 502/503 rather than an empty list precisely so this distinction
            // can survive to the screen.
            GrainErrorState(
                title: "Couldn't reach Kiln",
                message: message,
                retry: { Task { await store.load() } })
                .accessibilityIdentifier("chat-list-unreachable")

        case .loaded(let rail):
            if rail.isEmpty && !rail.filtering && rail.provenance == nil {
                VStack(spacing: GrainSpacing.x2) {
                    honesty(rail)
                    GrainEmptyState(
                        systemImage: "bubble.left.and.bubble.right",
                        title: KilnLibraryCopy.emptyTitle,
                        message: KilnLibraryCopy.emptyMessage)
                        .accessibilityIdentifier("chat-list-empty")
                }
            } else {
                railList(rail)
            }
        }
    }

    private func railList(_ rail: KilnLibraryPresentation.Rail) -> some View {
        List {
            // Render order, top to bottom: Loops → Inbox → lens body → History.
            if !rail.loops.isEmpty {
                zone("LOOPS", key: "z:loops", nodes: rail.loops, rail: rail)
            }
            if !rail.inbox.isEmpty {
                zone("INBOX", key: "z:inbox", nodes: rail.inbox, rail: rail)
            }
            ForEach(rail.groups) { group in
                zone(group.label.uppercased(), key: group.key, nodes: group.nodes,
                     rail: rail, depth: group.depth, tint: .muted)
            }
            if !rail.archived.isEmpty {
                zone("HISTORY", key: "z:archive", nodes: rail.archived, rail: rail, tint: .muted)
            }
        }
        .listStyle(.plain)
        .grainBackground()
        .safeAreaInset(edge: .top) { controls(rail) }
        .refreshable { await store.load() }
        .accessibilityIdentifier("chat-list")
    }

    @ViewBuilder
    private func zone(
        _ title: String, key: String, nodes: [ChatNode],
        rail: KilnLibraryPresentation.Rail,
        depth: [String: Int] = [:],
        tint: GrainEyebrowTint = .forge
    ) -> some View {
        // While filtering, EVERY zone force-expands — a collapsed History must never hide a
        // search match.
        let open = rail.isOpen(key, collapsed: store.collapsed)
        Section {
            if open {
                ForEach(nodes) { node in
                    row(node, rail: rail, indent: depth[node.id] ?? 0)
                        .swipeActions(edge: .trailing) {
                            // Only this phone's own chats are the phone's to delete.
                            if store.localConversation(node.id) != nil {
                                Button(role: .destructive) {
                                    store.deleteLocal(node.id)
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                }
            }
        } header: {
            Button { store.toggle(key) } label: {
                HStack(spacing: GrainSpacing.x2) {
                    GrainSectionEyebrow(title, tint: tint)
                    Text("\(nodes.count)")
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                    Spacer(minLength: 0)
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(GrainColor.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(rail.filtering)
            .accessibilityIdentifier("chat-zone-\(key)")
        }
    }

    private func row(_ node: ChatNode, rail: KilnLibraryPresentation.Rail, indent: Int) -> some View {
        let source = ChatProvenance(node)
        let notice = KilnConversationNotice.make(node.row)
        let local = store.localConversation(node.id)
        return Button {
            // A chat this phone holds is SELECTED — the chat screen behind this sheet is
            // already the thing that renders it. Everything else opens the Mac-resident
            // conversation. Same list, same row, one tap either way.
            if local != nil {
                store.select(node.id)
                onDismiss()
            } else {
                opened = node.row
            }
        } label: {
            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                HStack(spacing: GrainSpacing.x2) {
                    GrainBadge(source.shortTag, variant: notice.imported ? .secondary : .info)
                    Text(node.title)
                        .grainTextStyle(.body)
                        .foregroundStyle(GrainColor.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // A row standing for many firings MUST say so, or the collapse is
                    // invisible and the row misrepresents itself.
                    if let badge = KilnLibraryCopy.seriesBadge(node) {
                        GrainBadge(badge, variant: .warning)
                            .accessibilityIdentifier("kiln-series-badge")
                    }
                    if local?.id == chats.activeId {
                        Image(systemName: "checkmark").foregroundStyle(GrainColor.sage)
                    }
                }
                if let preview = node.row.lastMessagePreview, !preview.isEmpty {
                    Text(preview)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                        .lineLimit(2)
                }
                HStack(spacing: GrainSpacing.x2) {
                    if notice.offersPickUp {
                        GrainChip("Can pick up", systemImage: "arrow.uturn.left", variant: .sage)
                    }
                    if notice.sourceLine != nil {
                        GrainChip("Source gone", systemImage: "questionmark.folder", variant: .amber)
                    }
                    if notice.partialMarker != nil {
                        GrainChip("Partial", systemImage: "exclamationmark.triangle", variant: .amber)
                    }
                    // Honest about the limit: the phone can SAY there is subagent work but
                    // cannot open it (`/sessions/:id/children` is not proxied by the door).
                    if let note = KilnLibraryCopy.subagentNote(node, parentIds: rail.parentIds) {
                        GrainChip(note, systemImage: "arrow.triangle.branch")
                            .accessibilityIdentifier("kiln-subagent-note")
                    }
                }
            }
            .padding(.leading, CGFloat(indent) * GrainSpacing.x4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat-list-row")
    }

    /// Everything the list is obliged to SAY about itself before it is believed: whether the
    /// Mac is in it, how much of the Mac is in it, and whether a facet is hiding rows.
    @ViewBuilder
    private func honesty(_ rail: KilnLibraryPresentation.Rail) -> some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            if let line = KilnLibraryCopy.reachLine(rail.macReach) {
                Text(line)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.amber)
                    .accessibilityIdentifier("chat-list-reach-notice")
            }
            if let line = KilnLibraryCopy.coverageLine(
                rail.coverage, searching: rail.filtering || store.searchPending) {
                Text(line)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .accessibilityIdentifier("chat-list-coverage")
            }
            if let line = KilnLibraryCopy.provenanceLine(rail.provenance) {
                HStack(spacing: GrainSpacing.x2) {
                    Text(line)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                    Button("Show every source") {
                        store.provenance = nil
                        store.reproject()
                    }
                    .grainTextStyle(.caption)
                    .accessibilityIdentifier("chat-source-clear")
                }
                .accessibilityIdentifier("chat-list-provenance-notice")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GrainSpacing.x4)
    }

    private func controls(_ rail: KilnLibraryPresentation.Rail) -> some View {
        VStack(spacing: GrainSpacing.x2) {
            GrainTextField("Search every chat — try s:archived or a:claude", text: $store.query)
                .accessibilityIdentifier("chat-list-search")
                .onChange(of: store.query) { _ in store.queryChanged() }
            honesty(rail)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: GrainSpacing.x2) {
                    // The SOURCE facet — this phone / Kiln / Claude Code / Codex. A facet
                    // over one list, never a door onto another one. Only sources actually
                    // present get a chip, so no chip filters to nothing.
                    ForEach(rail.sourcesPresent, id: \.self) { source in
                        Button {
                            store.provenance = store.provenance == source ? nil : source
                            store.reproject()
                        } label: {
                            GrainChip(source.label, systemImage: source.symbol,
                                      variant: store.provenance == source ? .blue : .default)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(source.accessibilityIdentifier)
                    }
                    if !rail.sourcesPresent.isEmpty { Divider().frame(height: 16) }
                    ForEach(KilnLibraryPresentation.Lens.allCases, id: \.self) { lens in
                        Button {
                            store.lens = lens
                            store.reproject()
                        } label: {
                            GrainChip(lens.label, variant: store.lens == lens ? .blue : .default)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("kiln-lens-\(lens.rawValue)")
                    }
                    Divider().frame(height: 16)
                    ForEach(KilnLibraryPresentation.Sort.allCases, id: \.self) { sort in
                        Button {
                            store.sort = sort
                            store.reproject()
                        } label: {
                            GrainChip(sort.label, variant: store.sort == sort ? .sage : .default)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("kiln-sort-\(sort.rawValue)")
                    }
                }
                .padding(.horizontal, GrainSpacing.x4)
            }
        }
        .padding(.vertical, GrainSpacing.x2)
        .background(GrainColor.surface)
    }
}
