import SwiftUI
import Grain

// Kiln's SHARED conversation library, on the phone.
//
// "I can be running a conversation in Claude Code, pick it up in Kiln, pick it back up in
// Claude Code, and then if I wanted to pick it up in FoundryX." Until this surface, the phone
// could only see chats it itself created. This is a THIN RENDERER: every grouping, collapse,
// ordering and honesty decision lives in `KilnLibraryPresentation` / `KilnLibrary` /
// `KilnChatOrg` (pure, Brine-driven). Nothing here re-decides any of it.

/// Loads the library and holds the derived rail. `ObservableObject`, never `@Observable` —
/// the package floor is iOS 16.
@MainActor
final class KilnLibraryStore: ObservableObject {

    @Published private(set) var state: KilnLibraryPresentation.State = .idle
    @Published var lens: KilnLibraryPresentation.Lens = KilnLibraryPresentation.defaultLens
    @Published var sort: KilnLibraryPresentation.Sort = KilnLibraryPresentation.defaultSort
    @Published var query = ""
    @Published var collapsed: Set<String> = ["z:archive"]

    /// The rows and org as last read, so a lens/sort/filter change re-derives the rail
    /// WITHOUT another door round trip. Re-fetching on every keystroke would make the
    /// desktop's instant regrouping feel like a network operation.
    private var rows: [LibraryChatRow] = []
    private var org: OrgState = KilnChatOrg.empty
    private var totalRows = 0

    private let target: DoorTarget
    private let log: DoorLog?
    private let accountBinding: CaptureAccountScope.AccountBinding
    private let computerConnected: Bool

    init(target: DoorTarget, log: DoorLog?,
         accountBinding: CaptureAccountScope.AccountBinding,
         computerConnected: Bool) {
        self.target = target
        self.log = log
        self.accountBinding = accountBinding
        self.computerConnected = computerConnected
    }

    var isLoading: Bool { if case .loading = state { return true }; return false }

    func load() async {
        guard computerConnected else {
            state = .notConnected
            return
        }
        state = .loading
        let client = DoorClient(target: target, log: log)
        let binding = accountBinding
        let (lens, sort, query) = (self.lens, self.sort, self.query)

        let resolved = await KilnLibraryPresentation.resolve(
            computerConnected: true, lens: lens, sort: sort, query: query,
            nowMs: Date().timeIntervalSince1970 * 1000,
            load: {
                // The library is the answer; the org document is a convenience over it. If
                // the grouping read fails we still show the conversations, ungrouped —
                // losing the library because a curation file could not be read would be the
                // tail wagging the dog. A library failure still THROWS and becomes
                // `.unreachable`, never an empty list.
                async let page = client.kilnLibrary(limit: 200)
                async let org = try? client.kilnChatOrg()
                return KilnLibraryPresentation.Load(
                    page: try await page, org: await org ?? KilnChatOrg.empty)
            })

        // Every completion that touches UI must still be the account that started it.
        // A signed-out-and-back-in mid-fetch must not paint another account's library.
        CaptureAccountScope.perform(as: binding) { _ in
            if case .loaded(let rail) = resolved {
                self.rows = rail.allNodes.map(\.row)
                self.totalRows = rail.totalRows
            }
            self.state = resolved
        }
    }

    /// Re-derive from what we already hold. Pure and instant — no door call.
    func reproject() {
        guard case .loaded = state else { return }
        state = .loaded(KilnLibraryPresentation.rail(
            rows: rows, org: org, lens: lens, sort: sort, query: query,
            nowMs: Date().timeIntervalSince1970 * 1000, totalRows: totalRows))
    }

    /// Cache the raw rows + org so `reproject` can regroup without a fetch.
    func remember(rows: [LibraryChatRow], org: OrgState, total: Int) {
        self.rows = rows
        self.org = org
        self.totalRows = total
    }

    func toggle(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }
}

/// The library sheet. Opened from the Chat tab's header — deliberately NOT a fifth tab:
/// `features/app-shell.feature` asserts exactly four, and there is a recorded product
/// decision against adding one.
struct KilnLibraryView: View {
    let target: DoorTarget
    let log: DoorLog
    let accountBinding: CaptureAccountScope.AccountBinding
    let computerConnected: Bool
    var onDismiss: () -> Void

    @StateObject private var store: KilnLibraryStore
    @State private var opened: LibraryChatRow?

    init(target: DoorTarget, log: DoorLog,
         accountBinding: CaptureAccountScope.AccountBinding,
         computerConnected: Bool,
         onDismiss: @escaping () -> Void) {
        self.target = target
        self.log = log
        self.accountBinding = accountBinding
        self.computerConnected = computerConnected
        self.onDismiss = onDismiss
        _store = StateObject(wrappedValue: KilnLibraryStore(
            target: target, log: log, accountBinding: accountBinding,
            computerConnected: computerConnected))
    }

    var body: some View {
        NavigationStack {
            content
                // The destination confirms the door that was chosen. "All chats" was another
                // bare quantifier — it neither said whose chats these are nor distinguished
                // this sheet from the phone-local one.
                .navigationTitle(ChatScope.onYourMac.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDismiss)
                            .accessibilityIdentifier("kiln-library-done")
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
                .accessibilityIdentifier("kiln-library-loading")

        case .notConnected:
            GrainEmptyState(
                systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                title: "No computer is connected",
                message: "Open Foundry on your Mac and sign in with the same account to reach "
                    + "the chats you have there.")
                .accessibilityIdentifier("kiln-library-not-connected")

        case .unreachable(let message):
            // DELIBERATELY a different view AND different words from the empty state. The
            // door answers 502/503 rather than an empty list precisely so this distinction
            // can survive to the screen.
            GrainErrorState(
                title: "Couldn't reach Kiln",
                message: message,
                retry: { Task { await store.load() } })
                .accessibilityIdentifier("kiln-library-unreachable")

        case .loaded(let rail):
            if rail.isEmpty && !rail.filtering {
                GrainEmptyState(
                    systemImage: "bubble.left.and.bubble.right",
                    title: KilnLibraryCopy.emptyTitle,
                    message: KilnLibraryCopy.emptyMessage)
                    .accessibilityIdentifier("kiln-library-empty")
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
        .safeAreaInset(edge: .top) { controls }
        .refreshable { await store.load() }
        .accessibilityIdentifier("kiln-library-list")
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
            .accessibilityIdentifier("kiln-zone-\(key)")
        }
    }

    private func row(_ node: ChatNode, rail: KilnLibraryPresentation.Rail, indent: Int) -> some View {
        let tag = KilnLibrary.sourceTag(node.source)
        let notice = KilnConversationNotice.make(node.row)
        return Button { opened = node.row } label: {
            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                HStack(spacing: GrainSpacing.x2) {
                    GrainBadge(tag.short, variant: notice.imported ? .secondary : .info)
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
        .accessibilityIdentifier("kiln-library-row")
    }

    private var controls: some View {
        VStack(spacing: GrainSpacing.x2) {
            GrainTextField("Filter — try s:archived or a:claude", text: $store.query)
                .accessibilityIdentifier("kiln-library-filter")
                .onChange(of: store.query) { _ in store.reproject() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: GrainSpacing.x2) {
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
