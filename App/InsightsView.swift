import SwiftUI
import Grain

/// The "Insights" surface — the consumer payoff (Kevin): listen → surfaced insights →
/// toward a knowledge graph. THIN CLIENT: it renders an `InsightsDigest` the Door computes
/// (Lore/Anvil); it does NO analysis on-device. Each action item / highlight offers
/// "Ask in chat" (the capture→chat bridge) so an insight becomes a conversation.
struct InsightsView: View {
    let target: DoorTarget
    @ObservedObject var bridge: ChatBridge
    /// DEBUG/preview injection — when set, renders this instead of fetching.
    var injected: InsightsDigest? = nil

    @State private var digest: InsightsDigest?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                if let d = digest, !d.isEmpty {
                    loaded(d)
                } else if loading {
                    GrainLoadingState(title: "Gathering your insights…")
                        .padding(.top, GrainSpacing.x8)
                } else if let error {
                    GrainErrorState(title: "Couldn't load insights", message: error,
                                    retry: { Task { await load() } })
                        .padding(.top, GrainSpacing.x8)
                } else {
                    GrainEmptyState(
                        systemImage: "lightbulb",
                        title: "Insights will appear here",
                        message: "As you capture conversations, FoundryX surfaces your action items, highlights, and the people & topics that matter."
                    )
                    .padding(.top, GrainSpacing.x8)
                }
            }
            .padding(GrainSpacing.x4)
        }
        .grainBackground()
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder private func loaded(_ d: InsightsDigest) -> some View {
        if let h = d.headline, !h.isEmpty {
            Text(h).grainTextStyle(.title).foregroundStyle(GrainColor.ink)
        }
        if !d.actionItems.isEmpty { section("Action items", items: d.actionItems) }
        if !d.highlights.isEmpty { section("Highlights", items: d.highlights) }
        if !d.topics.isEmpty {
            VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                Text("People & topics").grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                topicChips(d.topics)
            }
        }
    }

    private func section(_ title: String, items: [InsightItem]) -> some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            Text(title).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            ForEach(items) { itemRow($0) }
        }
    }

    private func itemRow(_ item: InsightItem) -> some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            Text(item.text).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
            HStack(spacing: GrainSpacing.x2) {
                if let s = item.sourceTitle, !s.isEmpty {
                    Text(s).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint).lineLimit(1)
                }
                Spacer()
                Button {
                    bridge.askAbout(seedPrompt(for: item))
                } label: {
                    Text("Ask in chat").grainTextStyle(.caption).foregroundStyle(GrainColor.forgeBlue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).fill(GrainColor.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).strokeBorder(GrainColor.border, lineWidth: 1))
    }

    private func topicChips(_ topics: [InsightTopic]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: GrainSpacing.x2)],
                  alignment: .leading, spacing: GrainSpacing.x2) {
            ForEach(topics) { t in
                HStack(spacing: GrainSpacing.x1) {
                    Text(t.label).grainTextStyle(.caption).foregroundStyle(GrainColor.ink)
                    Text("\(t.mentions)").grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                }
                .padding(.horizontal, GrainSpacing.x2).padding(.vertical, GrainSpacing.x1)
                .background(Capsule().fill(GrainColor.surfaceElevated))
                .overlay(Capsule().strokeBorder(GrainColor.border, lineWidth: 1))
            }
        }
    }

    private func seedPrompt(for item: InsightItem) -> String {
        let from = item.sourceTitle.map { " (from my conversation “\($0)”)" } ?? ""
        return "About “\(item.text)”\(from):\n\nHelp me with this."
    }

    private func load() async {
        if let injected { digest = injected; loading = false; return }
        loading = true; error = nil
        // TODO(nick): GET /foundryx/insights once the endpoint + JSON shape are confirmed.
        // Thin client — this will just fetch + decode an InsightsDigest; no on-device
        // analysis. Until the endpoint is live, degrade cleanly to the empty state.
        digest = InsightsDigest()
        loading = false
    }
}
