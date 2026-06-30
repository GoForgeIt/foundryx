// CaptureLiveActivity — the Live Activity UI: the lock-screen / banner presentation and
// the Dynamic Island (compact / minimal / expanded). Renders `CaptureActivityAttributes`
// (the SHARED contract compiled into both the app and this extension). The APP requests/
// updates/ends the activity (CaptureLiveActivityController); this file is render-only.
//
// Dynamic Island requires ALL THREE presentations (compact, minimal, expanded) — the
// system picks which to show. ActivityKit is iOS 16.1+; this whole widget is gated.

import SwiftUI
import WidgetKit

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
struct CaptureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CaptureActivityAttributes.self) { context in
            // Lock-screen / banner presentation.
            CaptureLockScreenView(state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                // EXPANDED — long-press / live state.
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(state.isRecording ? state.sourceLabel
                             : (state.isPaused ? "Paused" : "Idle"))
                            .font(.caption).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: state.isRecording ? "waveform" : state.sourceSymbol)
                            .foregroundStyle(state.isRecording ? .red : .secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.isRecording, let started = state.startedAt {
                        // On-device live timer — no per-second activity update needed.
                        Text(timerInterval: started...Date.distantFuture, countsDown: false)
                            .font(.caption.monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 64)
                            .foregroundStyle(.white)
                    } else if let level = state.level {
                        CaptureLevelDots(level: level)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if state.isRecording {
                        HStack(spacing: 6) {
                            Image(systemName: "record.circle.fill").foregroundStyle(.red)
                            Text("Capturing — \(state.sourceLabel)")
                                .font(.footnote).foregroundStyle(.white)
                            Spacer()
                            if let level = state.level { CaptureLevelDots(level: level) }
                        }
                    } else if let title = state.lastFinishedTitle {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.footnote.weight(.medium))
                                .foregroundStyle(.white).lineLimit(1)
                            if let at = state.lastFinishedAt {
                                Text(at, style: .relative).font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("No conversations yet").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                // Leading: rec dot while recording, else the source icon.
                if state.isRecording {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                } else {
                    Image(systemName: state.sourceSymbol).foregroundStyle(.secondary)
                }
            } compactTrailing: {
                // Trailing: live elapsed while recording, else a compact level/idle dot.
                if state.isRecording, let started = state.startedAt {
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                        .font(.caption2.monospacedDigit())
                        .frame(maxWidth: 44)
                        .foregroundStyle(.white)
                } else if let level = state.level {
                    CaptureLevelDots(level: level, compact: true)
                }
            } minimal: {
                Image(systemName: state.isRecording ? "record.circle.fill" : state.sourceSymbol)
                    .foregroundStyle(state.isRecording ? .red : .secondary)
            }
            .keylineTint(.red)
        }
    }
}

/// The lock-screen / banner body: recording indicator + source + elapsed/level while
/// recording; the last finished conversation (title + relative time) when idle.
@available(iOS 16.1, *)
struct CaptureLockScreenView: View {
    let state: CaptureActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(state.isRecording ? Color.red.opacity(0.18) : Color.white.opacity(0.10))
                    .frame(width: 40, height: 40)
                Image(systemName: state.isRecording ? "waveform" : state.sourceSymbol)
                    .foregroundStyle(state.isRecording ? .red : .white)
            }
            VStack(alignment: .leading, spacing: 3) {
                if state.isRecording {
                    Text("Capturing — \(state.sourceLabel)")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    if let started = state.startedAt {
                        Text(timerInterval: started...Date.distantFuture, countsDown: false)
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } else if state.isPaused {
                    Text("Capture paused — \(state.sourceLabel)")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                } else if let title = state.lastFinishedTitle {
                    Text(title).font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white).lineLimit(1)
                    if let at = state.lastFinishedAt {
                        Text("Last conversation • \(relative(at))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("FoundryX").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text("No conversations yet").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if state.isRecording, let level = state.level {
                CaptureLevelDots(level: level)
            } else if state.isRecording {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
            }
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// A tiny 4-dot level meter (0…1) for the compact / inline level indicator.
@available(iOS 16.1, *)
struct CaptureLevelDots: View {
    let level: Double
    var compact: Bool = false

    var body: some View {
        let bars = 4
        let filled = Int((level.clamped01 * Double(bars)).rounded())
        HStack(spacing: compact ? 1.5 : 2.5) {
            ForEach(0..<bars, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < filled ? Color.red : Color.white.opacity(0.25))
                    .frame(width: compact ? 2 : 3,
                           height: compact ? CGFloat(4 + i * 2) : CGFloat(5 + i * 3))
            }
        }
    }
}

extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
#endif
