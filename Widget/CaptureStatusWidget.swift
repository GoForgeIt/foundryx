// CaptureStatusWidget — the home / lock-screen "live tile". A TimelineProvider-backed
// WidgetKit widget that reads the App-Group `CaptureWidgetSnapshot` the app writes on
// capture transitions, and shows: current capture status (recording / paused / idle +
// source) and the last finished conversation (title + relative time).
//
// The app pushes fresh state by calling `WidgetCenter.reloadAllTimelines()` on every
// capture transition; the timeline below is the fallback cadence between those reloads.

import SwiftUI
import WidgetKit

struct CaptureStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: CaptureWidgetSnapshot
}

struct CaptureStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> CaptureStatusEntry {
        CaptureStatusEntry(date: Date(), snapshot: .idle)
    }

    func getSnapshot(in context: Context, completion: @escaping (CaptureStatusEntry) -> Void) {
        completion(CaptureStatusEntry(date: Date(), snapshot: CaptureWidgetSnapshotStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CaptureStatusEntry>) -> Void) {
        let snap = CaptureWidgetSnapshotStore.read()
        let entry = CaptureStatusEntry(date: Date(), snapshot: snap)
        // Reload on the app's explicit `reloadAllTimelines()` calls; otherwise refresh
        // on a calm cadence so a relative-time string ("3 min ago") doesn't go stale.
        let next = Date().addingTimeInterval(snap.isRecording ? 60 : 15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct CaptureStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CaptureStatusEntry

    private var snap: CaptureWidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangularAccessory
        case .accessoryInline:      inlineAccessory
        default:                    homeTile
        }
    }

    // MARK: home-screen (small/medium) tile

    private var homeTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: statusIcon).foregroundStyle(statusColor)
                Text(statusLine).font(.subheadline.weight(.semibold))
                Spacer()
            }
            if snap.isRecording, let started = snap.startedAt {
                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("Last conversation").font(.caption2).foregroundStyle(.secondary)
                if let title = snap.lastFinishedTitle {
                    Text(title).font(.footnote.weight(.medium)).lineLimit(2)
                    if let at = snap.lastFinishedAt {
                        Text(at, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("None yet").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(4)
    }

    // MARK: lock-screen accessory presentations

    private var rectangularAccessory: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: statusIcon)
                Text(statusLine).font(.caption.weight(.semibold))
            }
            if snap.isRecording, let started = snap.startedAt {
                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                    .font(.caption2.monospacedDigit())
            } else if let title = snap.lastFinishedTitle {
                Text(title).font(.caption2).lineLimit(1)
            }
        }
    }

    private var inlineAccessory: some View {
        Label(snap.isRecording ? "Capturing — \(snap.sourceLabel)"
              : (snap.lastFinishedTitle ?? "Solleva idle"),
              systemImage: statusIcon)
    }

    // MARK: derived presentation

    private var statusIcon: String {
        if snap.isRecording { return "record.circle.fill" }
        if snap.isPaused { return "pause.circle.fill" }
        return snap.sourceSymbol
    }
    private var statusColor: Color {
        if snap.isRecording { return .red }
        if snap.isPaused { return .orange }
        return .secondary
    }
    private var statusLine: String {
        if snap.isRecording { return "Capturing — \(snap.sourceLabel)" }
        if snap.isPaused { return "Paused — \(snap.sourceLabel)" }
        return "Idle — \(snap.sourceLabel)"
    }
}

struct CaptureStatusWidget: Widget {
    let kind = "FoundryXCaptureStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CaptureStatusProvider()) { entry in
            // `containerBackground` is the iOS 17+ required widget background API; on 16
            // the system supplies the default material, so we only apply it where present.
            if #available(iOS 17.0, *) {
                CaptureStatusWidgetView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                CaptureStatusWidgetView(entry: entry)
                    .padding()
            }
        }
        .configurationDisplayName("Capture Status")
        .description("Shows whether Solleva is capturing and your last conversation.")
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        var fams: [WidgetFamily] = [.systemSmall, .systemMedium]
        fams.append(contentsOf: [.accessoryRectangular, .accessoryInline])
        return fams
    }
}
