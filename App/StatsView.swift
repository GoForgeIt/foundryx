import SwiftUI
import Grain

struct StatsView: View {
    let summary: StatsSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                    Text("Your library")
                        .grainTextStyle(.title)
                        .foregroundStyle(GrainColor.ink)
                    Text("Local conversations on this phone")
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                          alignment: .leading,
                          spacing: GrainSpacing.x3) {
                    StatTile(label: "Conversations", value: "\(summary.totalConversations)")
                    StatTile(label: "Hours recorded", value: hours(summary.totalDurationSeconds))
                    StatTile(label: "Avg length", value: duration(summary.averageDurationSeconds))
                    StatTile(label: "Speakers", value: "\(summary.totalSpeakersIdentified)")
                    StatTile(label: "Words", value: integer(summary.totalWords))
                    StatTile(label: "This week", value: weekHours(summary.hoursThisWeek))
                }

                VStack(alignment: .leading, spacing: GrainSpacing.x3) {
                    Text("Recent trend")
                        .grainTextStyle(.body)
                        .foregroundStyle(GrainColor.ink)
                    if summary.conversationsPerDay.isEmpty {
                        Text("No conversations yet")
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textFaint)
                    } else {
                        VStack(spacing: GrainSpacing.x2) {
                            ForEach(summary.conversationsPerDay) { day in
                                TrendRow(day: day, maxCount: maxTrendCount)
                            }
                        }
                    }
                }
                .padding(GrainSpacing.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                    .fill(GrainColor.surfaceElevated))
                .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                    .strokeBorder(GrainColor.border, lineWidth: 1))
            }
            .padding(GrainSpacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .grainBackground()
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var maxTrendCount: Int {
        max(1, summary.conversationsPerDay.map(\.conversationCount).max() ?? 1)
    }

    private func hours(_ seconds: UInt64) -> String {
        let value = Double(seconds) / 3600
        return value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private func weekHours(_ hours: Double) -> String {
        hours >= 10 ? String(format: "%.0f h", hours) : String(format: "%.1f h", hours)
    }

    private func duration(_ seconds: UInt64) -> String {
        guard seconds > 0 else { return "0m" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes))m" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    private func integer(_ n: Int) -> String {
        Self.numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

private struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(GrainColor.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
            .fill(GrainColor.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
            .strokeBorder(GrainColor.border, lineWidth: 1))
    }
}

private struct TrendRow: View {
    let day: StatsDailyTrend
    let maxCount: Int

    var body: some View {
        HStack(spacing: GrainSpacing.x2) {
            Text(Self.dayFormatter.string(from: day.day))
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .frame(width: 42, alignment: .leading)
            GeometryReader { proxy in
                let width = proxy.size.width * CGFloat(day.conversationCount) / CGFloat(maxCount)
                ZStack(alignment: .leading) {
                    Capsule().fill(GrainColor.borderHairline)
                    Capsule().fill(day.conversationCount > 0 ? GrainColor.forgeBlue : GrainColor.borderHairline)
                        .frame(width: max(day.conversationCount > 0 ? 4 : 0, width))
                }
            }
            .frame(height: 8)
            Text("\(day.conversationCount)")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)
                .monospacedDigit()
                .frame(width: 22, alignment: .trailing)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()
}
