// ActivityView — the Activity surface (track 20260713T0905): one place answering
// "what has it done for me?". A newest-first ledger of nudges (shown, accepted,
// dismissed), answers from the user's own memory with their rating, and agent
// runs; a daily recap card when a day HAD content (never on empty days — silence
// is a feature); a weekly recap with the same honesty; personal measures in plain
// sentences; and recent notification-worthy events, visible even when the system
// banner was missed.
//
// Night Shift register: quiet night surface, one headline, sentences not charts,
// GrainMemoryRings as the watermark on anything synthesized from memory. All
// aggregation lives in ActivityStore (FoundryXKit, tested); this file is layout
// plus the Foundation Models recap adapter behind the RecapSynthesizer seam.
//
// Read-only over the intelligence agent's logs. Nothing here writes.
//
// MOUNT POINT (not wired here to avoid shared-nav edits): push from the capture
// header alongside the existing Stats link —
//   NavigationLink { ActivityView(decisionLogURL: AmbientPrefs.decisionLogURL()) }

import SwiftUI
import Grain
// (FoundryXKit types are same-module — the App target compiles Sources/FoundryXKit directly)

struct ActivityView: View {
    let decisionLogURL: URL
    var synthesizer: RecapSynthesizer? = makeSystemRecapSynthesizer()
    /// Source links: installed by the mounting screen (conversation detail / chat).
    /// Absent handlers render the entry without a link — honestly, not broken.
    var onOpenConversation: ((String) -> Void)? = nil
    var onOpenChat: ((String) -> Void)? = nil

    @State private var allEntries: [ActivityEntry] = []
    @State private var days: [ActivityDay] = []
    @State private var weekCard: RecapCard?
    @State private var weekEntries: [ActivityEntry] = []
    @State private var measures: [String] = []
    /// Model prose per recap card id; the deterministic fallback stands until
    /// (and unless) the on-device model replaces it.
    @State private var recapTexts: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                header
                if days.isEmpty {
                    emptyState
                } else {
                    measuresRow
                    notificationsRow
                    if let weekCard {
                        recapCard(weekCard, entries: weekEntries, label: "This week")
                    }
                    ForEach(days) { day in
                        daySection(day)
                    }
                }
            }
            .padding(GrainSpacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .grainBackground()
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            Text("What it has done for you")
                .grainTextStyle(.title)
                .foregroundStyle(GrainColor.ink)
            Text("Nudges, answers, and runs from your own conversations. Everything links back to where it came from.")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            Text("Nothing yet.")
                .grainTextStyle(.body)
                .foregroundStyle(GrainColor.ink)
            Text("When a conversation surfaces something worth acting on, it will appear here. Quiet days stay quiet.")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, GrainSpacing.x6)
    }

    /// Personal measures: plain sentences, no charts, no internal tool names.
    private var measuresRow: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            ForEach(measures, id: \.self) { sentence in
                Text(sentence)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
            }
        }
    }

    /// Recent notification-worthy events, visible even if the banner was missed.
    @ViewBuilder private var notificationsRow: some View {
        let recent = ActivityStore.notificationHistory(entries: allEntries, limit: 3)
        if !recent.isEmpty {
            Text("Recent nudges and answers appear below, even if you missed the notification.")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func daySection(_ day: ActivityDay) -> some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            Text(Self.dayLabel(day.day))
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)
            if let card = ActivityStore.recapCard(day: day) {
                recapCard(card, entries: day.entries, label: "Recap")
            }
            VStack(spacing: 0) {
                ForEach(day.entries) { entry in
                    entryRow(entry)
                    if entry.id != day.entries.last?.id {
                        Rectangle().fill(GrainColor.borderHairline).frame(height: 1)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                .fill(GrainColor.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                .strokeBorder(GrainColor.border, lineWidth: 1))
        }
    }

    // MARK: - Ledger rows

    private func entryRow(_ entry: ActivityEntry) -> some View {
        let linkable = linkAction(for: entry) != nil
        return Button {
            linkAction(for: entry)?()
        } label: {
            HStack(alignment: .top, spacing: GrainSpacing.x3) {
                Circle()
                    .fill(tint(for: entry.kind))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: GrainSpacing.x2) {
                        Text(label(for: entry.kind))
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textMuted)
                        if let rating = entry.rating {
                            Text("you rated it \(rating)")
                                .grainTextStyle(.caption)
                                .foregroundStyle(GrainColor.sage)
                        }
                        Spacer()
                        Text(Self.timeLabel(entry.ts))
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textFaint)
                    }
                    if let detail = entry.detail, !detail.isEmpty {
                        Text(detail)
                            .grainTextStyle(.body)
                            .foregroundStyle(GrainColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    if linkable {
                        Text(sourceLabel(for: entry.source))
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.forgeBlue)
                    }
                }
            }
            .padding(.horizontal, GrainSpacing.x4)
            .padding(.vertical, GrainSpacing.x3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!linkable)
    }

    /// The tap action for an entry's source link, when the mounting screen
    /// installed a handler for that source kind.
    private func linkAction(for entry: ActivityEntry) -> (() -> Void)? {
        switch entry.source {
        case .conversation(let captureId):
            guard let onOpenConversation else { return nil }
            return { onOpenConversation(captureId) }
        case .chat(let seed):
            guard let onOpenChat else { return nil }
            return { onOpenChat(seed) }
        case .none:
            return nil
        }
    }

    private func label(for kind: ActivityEntry.Kind) -> String {
        switch kind {
        case .nudgeShown: return "Nudged you"
        case .nudgeAccepted: return "You accepted a nudge"
        case .nudgeDismissed: return "You dismissed a nudge"
        case .answer: return "Answered from your memory"
        case .agentRun: return "Ran for you"
        }
    }

    private func tint(for kind: ActivityEntry.Kind) -> Color {
        switch kind {
        case .nudgeShown: return GrainColor.amber
        case .nudgeAccepted, .agentRun: return GrainColor.forgeBlue
        case .nudgeDismissed: return GrainColor.textFaint
        case .answer: return GrainColor.sage
        }
    }

    private func sourceLabel(for source: ActivityEntry.Source) -> String {
        switch source {
        case .conversation: return "From a conversation"
        case .chat: return "Open the chat"
        case .none: return ""
        }
    }

    // MARK: - Recap cards

    /// A recap card wears the memory rings: the mark of anything synthesized
    /// from the user's own memory. Deterministic fallback text until (and unless)
    /// the on-device model writes the prose.
    private func recapCard(_ card: RecapCard, entries: [ActivityEntry],
                           label: String) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                Text(label)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                Text(recapTexts[card.id] ?? card.fallbackText)
                    .grainTextStyle(.body)
                    .foregroundStyle(GrainColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, GrainSpacing.x8)
            }
            .padding(GrainSpacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            GrainMemoryRings(color: GrainColor.forgeBlue)
                .frame(width: 52, height: 52)
                .opacity(0.55)
                .padding(GrainSpacing.x3)
        }
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
            .fill(GrainColor.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
            .strokeBorder(GrainColor.forgeBlueBorder, lineWidth: 1))
        .task(id: card.id) {
            await synthesize(card, entries: entries)
        }
    }

    /// Ask the on-device model (behind the seam) to write the recap prose from
    /// the period's REAL entries. Unavailable or failing ⇒ the deterministic
    /// fallback stands; nothing is invented.
    private func synthesize(_ card: RecapCard, entries: [ActivityEntry]) async {
        guard let synthesizer, synthesizer.isAvailable,
              recapTexts[card.id] == nil else { return }
        guard let text = try? await synthesizer.recap(entries: entries,
                                                      period: card.period),
              !text.isEmpty else { return }
        recapTexts[card.id] = text
    }

    // MARK: - Loading

    private func reload() {
        let entries = ActivityStore.entries(
            decisionLogURL: decisionLogURL,
            cardsLogURL: ActivityStore.cardsLogURL(besides: decisionLogURL),
            answersLogURL: ActivityStore.answersLogURL(besides: decisionLogURL))
        allEntries = entries
        days = ActivityStore.days(entries: entries)
        measures = ActivityStore.measures(entries: entries)
        // The weekly rollup: only the CURRENT week, only when it has content.
        let calendar = Calendar.current
        if let week = ActivityStore.weeks(entries: entries, calendar: calendar).first,
           calendar.dateInterval(of: .weekOfYear, for: Date())?.start == week.weekStart {
            weekEntries = week.entries
            weekCard = ActivityStore.recapCard(week: week)
        } else {
            weekEntries = []
            weekCard = nil
        }
    }

    // MARK: - Formatting

    private static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return dayFormatter.string(from: day)
    }

    private static func timeLabel(_ ts: UInt64) -> String {
        guard ts > 0 else { return "" }
        return timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

// MARK: - The on-device recap engine

#if canImport(FoundationModels)
import FoundationModels

/// The REAL engine behind the RecapSynthesizer seam: Apple Foundation Models,
/// availability-gated, same pattern as FoundationModelsTitler. It is told ONLY
/// the period's actual entries and asked for two quiet sentences; a phone
/// without the model keeps the deterministic fallback text.
@available(iOS 26.0, macOS 26.0, *)
public final class FoundationModelsRecapSynthesizer: RecapSynthesizer, @unchecked Sendable {
    public init() {}

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func recap(entries: [ActivityEntry], period: RecapPeriod) async throws -> String {
        let span: String
        switch period {
        case .day: span = "day"
        case .week: span = "week"
        }
        let lines = entries.map { entry -> String in
            var line: String
            switch entry.kind {
            case .nudgeShown: line = "nudged the user"
            case .nudgeAccepted: line = "the user accepted a nudge"
            case .nudgeDismissed: line = "the user dismissed a nudge"
            case .answer: line = "answered from the user's memory"
            case .agentRun: line = "ran a task for the user"
            }
            if let detail = entry.detail, !detail.isEmpty {
                line += ": \(String(detail.prefix(200)))"
            }
            if let rating = entry.rating {
                line += " (the user rated it \(rating))"
            }
            return "- " + line
        }.joined(separator: "\n")

        let session = LanguageModelSession()
        let prompt = """
        You are writing a quiet 1-2 sentence recap of what a personal assistant \
        did for its user this \(span). Mention ONLY what is in the list below; do \
        not invent, pad, or praise. Plain, warm, specific. Reply with ONLY the \
        recap sentences.

        What happened:
        \(lines)
        """
        return try await session.respond(to: prompt).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

/// Wiring-time factory: the system recap engine where the OS has Foundation
/// Models, else nil — recap cards then keep their deterministic fallback text.
public func makeSystemRecapSynthesizer() -> RecapSynthesizer? {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
        return FoundationModelsRecapSynthesizer()
    }
    #endif
    return nil
}
