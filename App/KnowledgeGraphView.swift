import SwiftUI
import Grain

/// The knowledge-graph surface — entities (people / projects / topics / places) the user's
/// conversations are about. THIN CLIENT: renders a `KnowledgeGraph` the Door computes
/// (Lore/Anvil); no on-device analysis. Tap an entity → its connections + the conversations
/// it came from, with "Ask in chat" to explore it.
struct KnowledgeGraphView: View {
    let target: DoorTarget
    @ObservedObject var bridge: ChatBridge
    var injected: KnowledgeGraph? = nil

    @State private var graph: KnowledgeGraph?
    @State private var loading = true
    @State private var error: String?

    /// Display order + titles for the entity kinds.
    private static let kindOrder: [(kind: String, title: String)] = [
        ("person", "People"), ("project", "Projects"), ("topic", "Topics"), ("place", "Places")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                if let g = graph, !g.isEmpty {
                    ForEach(Self.kindOrder, id: \.kind) { group in
                        let nodes = g.nodes.filter { $0.kind == group.kind }
                            .sorted { $0.mentions > $1.mentions }
                        if !nodes.isEmpty { section(group.title, nodes: nodes) }
                    }
                } else if loading {
                    GrainLoadingState(title: "Building your graph…").padding(.top, GrainSpacing.x8)
                } else if let error {
                    GrainErrorState(title: "Couldn't load your graph", message: error,
                                    retry: { Task { await load() } }).padding(.top, GrainSpacing.x8)
                } else {
                    GrainEmptyState(
                        systemImage: "point.3.connected.trianglepath.dotted",
                        title: "Your knowledge graph is forming",
                        message: "As you capture conversations, the people, projects, and topics that matter connect up here."
                    ).padding(.top, GrainSpacing.x8)
                }
            }
            .padding(GrainSpacing.x4)
        }
        .grainBackground()
        .navigationTitle("Knowledge graph")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func section(_ title: String, nodes: [GraphNode]) -> some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            Text(title).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            ForEach(nodes) { node in
                NavigationLink {
                    GraphNodeDetailView(target: target, node: node, bridge: bridge)
                } label: {
                    nodeRow(node)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func nodeRow(_ node: GraphNode) -> some View {
        HStack(spacing: GrainSpacing.x2) {
            Image(systemName: KnowledgeGraphView.glyph(node.kind)).foregroundStyle(GrainColor.forgeBlue)
            Text(node.label).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
            Spacer()
            Text("\(node.mentions)").grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint).monospacedDigit()
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(GrainColor.textFaint)
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).fill(GrainColor.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).strokeBorder(GrainColor.border, lineWidth: 1))
    }

    static func glyph(_ kind: String) -> String {
        switch kind {
        case "person": return "person.fill"
        case "project": return "folder.fill"
        case "place": return "mappin.and.ellipse"
        default: return "number"
        }
    }

    private func load() async {
        if let injected { graph = injected; loading = false; return }
        loading = true; error = nil
        // TODO(nick): GET /foundryx/graph once the endpoint + JSON shape are confirmed
        // (see deliverables/F_nick-backend-asks.md §4). Thin client — fetch + decode a
        // KnowledgeGraph; no on-device analysis. Until then, degrade to the empty state.
        graph = KnowledgeGraph()
        loading = false
    }
}

/// One entity's detail: its connections to other entities, the conversations it appeared
/// in, and an "Ask in chat" to explore everything known about it.
struct GraphNodeDetailView: View {
    /// The resolved door target — lets an "Appears in" row deep-link into the
    /// conversation's transcript (ConversationDetailView fetches by capture id).
    let target: DoorTarget
    let node: GraphNode
    @ObservedObject var bridge: ChatBridge

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                HStack(spacing: GrainSpacing.x2) {
                    Image(systemName: KnowledgeGraphView.glyph(node.kind)).foregroundStyle(GrainColor.forgeBlue)
                    Text(node.label).grainTextStyle(.title).foregroundStyle(GrainColor.ink)
                }
                Text("\(node.kind.capitalized) · came up \(node.mentions) time\(node.mentions == 1 ? "" : "s")")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)

                GrainButton("Ask about \(node.label)", variant: .filled, size: .sm) {
                    bridge.askAbout("What do I know about “\(node.label)”? Summarize across my conversations and note any follow-ups.")
                }

                if !node.related.isEmpty {
                    VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                        Text("Connected to").grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: GrainSpacing.x2)],
                                  alignment: .leading, spacing: GrainSpacing.x2) {
                            ForEach(node.related) { e in
                                HStack(spacing: GrainSpacing.x1) {
                                    Text(e.label).grainTextStyle(.caption).foregroundStyle(GrainColor.ink)
                                    Text("\(e.weight)").grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                                }
                                .padding(.horizontal, GrainSpacing.x2).padding(.vertical, GrainSpacing.x1)
                                .background(Capsule().fill(GrainColor.surfaceElevated))
                                .overlay(Capsule().strokeBorder(GrainColor.border, lineWidth: 1))
                            }
                        }
                    }
                }

                if !node.conversations.isEmpty {
                    VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                        Text("Appears in").grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                        // Each reference deep-links into the conversation's transcript —
                        // GraphConversationRef.id is the captureId, .when the time range.
                        ForEach(node.conversations) { c in
                            NavigationLink {
                                ConversationDetailView(target: target, bridge: bridge,
                                                       captureId: c.id, timeRange: c.when ?? "",
                                                       place: nil, conversationDate: nil)
                            } label: {
                                conversationRefRow(c)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("graph-conversation-link")
                        }
                    }
                }
            }
            .padding(GrainSpacing.x4)
        }
        .grainBackground()
        .navigationTitle(node.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One "Appears in" conversation card — title + when, with a chevron marking it as a
    /// tappable link into the transcript.
    private func conversationRefRow(_ c: GraphConversationRef) -> some View {
        HStack(spacing: GrainSpacing.x2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).grainTextStyle(.body).foregroundStyle(GrainColor.ink).lineLimit(1)
                if let w = c.when { Text(w).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(GrainColor.textFaint)
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).fill(GrainColor.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).strokeBorder(GrainColor.border, lineWidth: 1))
    }
}
