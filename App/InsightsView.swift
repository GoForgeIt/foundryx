import SwiftUI
import Grain

/// The "Insights" surface — the consumer payoff (Kevin): listen → surfaced insights →
/// toward a knowledge graph. THIN CLIENT: it renders an `InsightsDigest` the Door computes
/// (Lore/Anvil) and COUNTS/FORMATS a `TodayRecap` off disk; it does NO analysis on-device.
/// Each action item / highlight offers "Ask in chat" (the capture→chat bridge) and, when it
/// links back to a conversation, deep-links into that conversation's transcript. A "Today at
/// the Foundry" recap sits at the very top whenever today has captures; a quiet, opt-in
/// "Evening recap" notification setting sits at the bottom.
struct InsightsView: View {
    let target: DoorTarget
    @ObservedObject var bridge: ChatBridge
    /// DEBUG/preview injection — when set, renders this digest instead of fetching.
    var injected: InsightsDigest? = nil
    /// DEBUG/preview injection — today's on-disk recap. When set, skips the disk load.
    var injectedRecap: TodayRecap? = nil

    @State private var digest: InsightsDigest?
    @State private var recap: TodayRecap = .empty
    @State private var loading = true
    @State private var error: String?

    // Evening recap settings (UserDefaults-backed; opt-in, default 20:00 — see
    // EveningRecapScheduler). Off by default so we only ask for notification permission
    // when the user turns it on.
    @AppStorage(EveningRecapScheduler.enabledKey) private var eveningEnabled = false
    @AppStorage(EveningRecapScheduler.minutesKey) private var eveningMinutes = EveningRecapScheduler.defaultMinutes

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                if !recap.items.isEmpty { recapSection }   // Today at the Foundry — always on top
                content
                eveningRecapSettings                       // quiet, opt-in, at the bottom
            }
            .padding(GrainSpacing.x4)
        }
        .grainBackground()
        .task { await load(); await EveningRecapScheduler.reschedule() }
        .onAppear { Task { await EveningRecapScheduler.reschedule() } }
        .refreshable { await load() }
    }

    // MARK: main content — the real digest, or the sample/loading/error states

    @ViewBuilder private var content: some View {
        if let d = digest, !d.isEmpty {
            loaded(d)
        } else if loading && recap.items.isEmpty {
            GrainLoadingState(title: "Gathering your insights…")
                .padding(.top, GrainSpacing.x8)
        } else if let error, recap.items.isEmpty {
            GrainErrorState(title: "Couldn't load insights", message: error,
                            retry: { Task { await load() } })
                .padding(.top, GrainSpacing.x8)
        } else if !recap.items.isEmpty {
            // Real recap up top, but no digest yet — still offer the way into the graph.
            graphEntryLink
        } else {
            // Nothing real yet: a clearly-labeled SAMPLE so the surface shows its shape.
            sampleState
        }
    }

    // MARK: Today at the Foundry — the on-disk recap (thin client: count + format only)

    private var recapSection: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            Text("Today at the Foundry").grainTextStyle(.title).foregroundStyle(GrainColor.ink)
            Text(recapCountLine).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            ForEach(recap.items) { item in
                NavigationLink {
                    ConversationDetailView(target: target, bridge: bridge, captureId: item.id,
                                           timeRange: detailTimeRange(item), place: nil,
                                           conversationDate: item.startedAt)
                } label: {
                    recapRow(item)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("recap-row")
            }
        }
    }

    /// "N conversations · M min" — minutes dropped when no conversation had a derivable
    /// duration (honest degradation).
    private var recapCountLine: String {
        let n = recap.conversationCount
        let convo = "\(n) conversation\(n == 1 ? "" : "s")"
        if let m = recap.totalMinutes { return "\(convo) · \(m) min" }
        return convo
    }

    private func recapRow(_ item: TodayRecap.Item) -> some View {
        HStack(spacing: GrainSpacing.x2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).grainTextStyle(.body).foregroundStyle(GrainColor.ink).lineLimit(1)
                Text(rowTime(item)).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(GrainColor.textFaint)
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).fill(GrainColor.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).strokeBorder(GrainColor.border, lineWidth: 1))
    }

    /// The row subtitle: the time of day (+ minutes when derivable).
    private func rowTime(_ item: TodayRecap.Item) -> String {
        var s = Self.timeFmt.string(from: item.startedAt)
        if let m = item.minutes { s += " · \(m) min" }
        return s
    }

    /// The fuller time range passed to the detail view's header (date · time · minutes).
    private func detailTimeRange(_ item: TodayRecap.Item) -> String {
        var s = "\(Self.dayFmt.string(from: item.startedAt)) · \(Self.timeFmt.string(from: item.startedAt))"
        if let m = item.minutes { s += " · \(m) min" }
        return s
    }

    private static let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
    private static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f }()

    // MARK: loaded digest

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
        graphEntryLink
    }

    private func section(_ title: String, items: [InsightItem]) -> some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            Text(title).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            ForEach(items) { itemRow($0) }
        }
    }

    /// One insight row. When it carries a source captureId, the whole row deep-links into
    /// the conversation's transcript; the inner "Ask in chat" button stays independently
    /// tappable (`.buttonStyle(.plain)` keeps it a distinct control inside the link label).
    @ViewBuilder private func itemRow(_ item: InsightItem) -> some View {
        if let cap = item.captureId, !cap.isEmpty {
            NavigationLink {
                ConversationDetailView(target: target, bridge: bridge, captureId: cap,
                                       timeRange: "", place: nil, conversationDate: nil)
            } label: {
                itemCard(item, linked: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("insight-link")
        } else {
            itemCard(item, linked: false)
        }
    }

    private func itemCard(_ item: InsightItem, linked: Bool) -> some View {
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
                // The chevron marks the row as a link into the conversation (deep-link spine).
                if linked {
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(GrainColor.textFaint)
                }
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

    /// Entry point into the full knowledge graph (connections + per-entity conversations).
    /// Rendered in the loaded, recap-only, AND sample states so there's ALWAYS a way in —
    /// including when the digest is empty (deep-link spine: graph entry unconditional).
    private var graphEntryLink: some View {
        NavigationLink {
            KnowledgeGraphView(target: target, bridge: bridge)
        } label: {
            HStack(spacing: GrainSpacing.x2) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(GrainColor.forgeBlue)
                Text("Explore your knowledge graph").grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(GrainColor.textFaint)
            }
            .padding(GrainSpacing.x3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).fill(GrainColor.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).strokeBorder(GrainColor.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: sample state — no real digest yet, shown under an unmistakable SAMPLE banner

    private var sampleState: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x4) {
            sampleBanner
            loaded(.sample)
        }
    }

    private var sampleBanner: some View {
        HStack(spacing: GrainSpacing.x2) {
            Image(systemName: "sparkles").foregroundStyle(GrainColor.amber)
            Text("SAMPLE — your first insights are being forged")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.amber)
            Spacer()
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).fill(GrainColor.amber.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).strokeBorder(GrainColor.amber.opacity(0.4), lineWidth: 1))
        .accessibilityIdentifier("insights-sample-banner")
    }

    // MARK: evening recap — a quiet, opt-in nightly notification (bottom of the surface)

    private var eveningRecapSettings: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            Divider().background(GrainColor.borderHairline)
            Toggle(isOn: $eveningEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Evening recap").grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                    Text("A nightly notification with your day, distilled.")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                }
            }
            .tint(GrainColor.forgeBlue)
            .accessibilityIdentifier("evening-recap-toggle")
            .onChange(of: eveningEnabled) { on in
                // Permission is requested ONLY on the first toggle-on; toggle-off just cancels.
                Task {
                    if on { await EveningRecapScheduler.requestAuthorizationAndReschedule() }
                    else { EveningRecapScheduler.cancel() }
                }
            }
            if eveningEnabled {
                DatePicker("Time", selection: eveningTimeBinding, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
                    .tint(GrainColor.forgeBlue)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
                    .onChange(of: eveningMinutes) { _ in Task { await EveningRecapScheduler.reschedule() } }
            }
        }
        .padding(.top, GrainSpacing.x6)
    }

    /// Bridge the stored minutes-since-midnight to the DatePicker's Date binding.
    private var eveningTimeBinding: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: eveningMinutes / 60, minute: eveningMinutes % 60,
                                  second: 0, of: Date()) ?? Date()
        } set: { newValue in
            let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            eveningMinutes = (c.hour ?? 20) * 60 + (c.minute ?? 0)
        }
    }

    private func seedPrompt(for item: InsightItem) -> String {
        let from = item.sourceTitle.map { " (from my conversation “\($0)”)" } ?? ""
        return "About “\(item.text)”\(from):\n\nHelp me with this."
    }

    private func load() async {
        // Recap: the pure on-disk loader (thin client — count + format only). Injected in
        // previews; otherwise loaded off the main actor so its disk I/O never janks scroll.
        if let injectedRecap {
            recap = injectedRecap
        } else {
            recap = await Task.detached { TodayRecap.load() }.value
        }
        if let injected { digest = injected; loading = false; return }
        loading = true; error = nil
        // TODO(nick): GET /foundryx/insights once the endpoint + JSON shape are confirmed.
        // Thin client — this will just fetch + decode an InsightsDigest; no on-device
        // analysis. Until the endpoint is live, degrade cleanly to the sample/empty state.
        digest = InsightsDigest()
        loading = false
    }
}
