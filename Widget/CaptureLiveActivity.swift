// CaptureLiveActivity — the Live Activity UI: the lock-screen / banner presentation and
// the Dynamic Island (compact / minimal / expanded). Renders `CaptureActivityAttributes`
// (the SHARED contract compiled into both the app and this extension). The APP requests/
// updates/ends the activity (CaptureLiveActivityController); this file is render-only.
//
// It distinguishes THREE phases (the fix for the "in a conversation while paused/idle"
// bug): RECORDING-ACTIVE (voiced audio now — the only phase with a running timer + live
// meter + transcript), PAUSED, and LISTENING/IDLE (armed but no active voice). It also
// hosts the TWO interactive buttons (iOS 17+ App Intents): End Current + Pause/Resume.
//
// Dynamic Island requires ALL THREE presentations (compact, minimal, expanded) — the
// system picks which to show. ActivityKit is iOS 16.1+; this whole widget is gated.

import SwiftUI
import WidgetKit

#if canImport(ActivityKit)
import ActivityKit
#if canImport(AppIntents)
import AppIntents
#endif

@available(iOS 16.1, *)
struct CaptureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CaptureActivityAttributes.self) { context in
            // Lock-screen / banner presentation.
            CaptureLockScreenView(state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "foundryx://capture"))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                // EXPANDED — long-press / live state.
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(state.phase == .recordingActive ? state.sourceLabel
                             : (state.phase == .paused ? "Paused" : "Listening"))
                            .font(.caption).foregroundStyle(.secondary)
                    } icon: {
                        // State-colored anvil (pulses while recording).
                        CaptureIndicator(phase: state.phase, size: 20)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.phase == .recordingActive, let started = state.startedAt {
                        // On-device live timer — no per-second activity update needed.
                        Text(timerInterval: started...Date.distantFuture, countsDown: false)
                            .font(.caption.monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 64)
                            .foregroundStyle(.white)
                    } else if let step = state.levelStep {
                        CaptureLevelBars(step: step)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        bottomStatusLine(state)
                        // Live transcript (truncated) while actively recording.
                        if state.phase == .recordingActive, !state.transcriptLine.isEmpty {
                            Text(state.transcriptLine)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(2).truncationMode(.head)
                        }
                        // Interactive buttons (iOS 17+). Non-interactive labels below that.
                        controlRow(state)
                    }
                }
            } compactLeading: {
                // Leading: the state-colored anvil — red+pulse while recording, steady
                // blue when paused, calm gray when listening. The whole point of the tiny
                // pill: color + motion carry the state where there's no room for text.
                CaptureIndicator(phase: state.phase, size: 16)
            } compactTrailing: {
                // Trailing: live elapsed while actively recording, else a compact level/idle bar.
                if state.phase == .recordingActive, let started = state.startedAt {
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                        .font(.caption2.monospacedDigit())
                        .frame(maxWidth: 44)
                        .foregroundStyle(.white)
                } else if let step = state.levelStep {
                    CaptureLevelBars(step: step, compact: true)
                }
            } minimal: {
                CaptureIndicator(phase: state.phase, size: 16)
            }
            .widgetURL(URL(string: "foundryx://capture"))
            .keylineTint(state.phase.indicatorTint.color)
        }
    }

    /// The bottom status line (expanded): capturing / paused / listening / last-conversation.
    @ViewBuilder
    private func bottomStatusLine(_ state: CaptureActivityAttributes.ContentState) -> some View {
        switch state.phase {
        case .recordingActive:
            HStack(spacing: 6) {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                Text("Capturing — \(state.sourceLabel)").font(.footnote).foregroundStyle(.white)
                Spacer()
                if let step = state.levelStep { CaptureLevelBars(step: step) }
            }
        case .paused:
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill").foregroundStyle(.blue)
                Text("Paused — \(state.sourceLabel)").font(.footnote).foregroundStyle(.white)
            }
        case .idle:
            if let title = state.lastFinishedTitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.footnote.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                    if let at = state.lastFinishedAt {
                        Text(at, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "ear").foregroundStyle(.secondary)
                    Text("Listening — \(state.sourceLabel)").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The interactive control row (End Current + Pause/Resume). iOS 17+ renders real
    /// buttons via App Intents; on iOS 16 it falls back to non-interactive icons.
    @ViewBuilder
    private func controlRow(_ state: CaptureActivityAttributes.ContentState) -> some View {
        // Buttons are only meaningful while a capture session exists (recording or paused).
        if state.phase == .recordingActive || state.phase == .paused {
            if #available(iOS 17.0, *) {
                HStack(spacing: 10) {
                    Button(intent: EndCurrentConversationIntent()) {
                        Label("End", systemImage: "stop.circle")
                            .font(.caption2)
                    }
                    .tint(.red)
                    Button(intent: ToggleCapturePauseIntent()) {
                        Label(state.phase == .paused ? "Resume" : "Pause",
                              systemImage: state.phase == .paused ? "play.circle" : "pause.circle")
                            .font(.caption2)
                    }
                    .tint(.yellow)
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            // iOS 16: no interactive Live Activity buttons — omit (the app UI is the control).
        }
    }

}

/// The lock-screen / banner body: phase-aware header + elapsed/level/transcript while
/// actively recording; paused / listening / last-conversation otherwise. Hosts the same
/// two interactive buttons.
@available(iOS 16.1, *)
struct CaptureLockScreenView: View {
    let state: CaptureActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(iconBackground)
                        .frame(width: 40, height: 40)
                    // State-colored anvil (pulses while actively recording).
                    CaptureIndicator(phase: state.phase, size: 22)
                }
                VStack(alignment: .leading, spacing: 3) {
                    header
                }
                Spacer()
                if state.phase == .recordingActive, let step = state.levelStep {
                    CaptureLevelBars(step: step)
                }
            }
            // Live transcript (truncated) while actively recording.
            if state.phase == .recordingActive, !state.transcriptLine.isEmpty {
                Text(state.transcriptLine)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.head)
            }
            // Interactive buttons on the lock screen (iOS 17+).
            if state.phase == .recordingActive || state.phase == .paused {
                if #available(iOS 17.0, *) {
                    HStack(spacing: 10) {
                        Button(intent: EndCurrentConversationIntent()) {
                            Label("End Current", systemImage: "stop.circle")
                        }
                        .tint(.red)
                        Button(intent: ToggleCapturePauseIntent()) {
                            Label(state.phase == .paused ? "Resume" : "Pause",
                                  systemImage: state.phase == .paused ? "play.circle" : "pause.circle")
                        }
                        .tint(.yellow)
                        Spacer()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var header: some View {
        switch state.phase {
        case .recordingActive:
            Text("Capturing — \(state.sourceLabel)")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            if let started = state.startedAt {
                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .paused:
            Text("Capture paused — \(state.sourceLabel)")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            Text("Tap Resume to keep capturing")
                .font(.caption).foregroundStyle(.secondary)
        case .idle:
            if let title = state.lastFinishedTitle {
                Text(title).font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white).lineLimit(1)
                if let at = state.lastFinishedAt {
                    Text("Last conversation • \(relative(at))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Listening — \(state.sourceLabel)")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text("Waiting for the next conversation")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // The soft disc behind the anvil, tinted to match the phase color (recording red /
    // paused blue / idle a faint neutral).
    private var iconBackground: Color {
        switch state.phase {
        case .recordingActive: return Color.red.opacity(0.18)
        case .paused:          return Color.blue.opacity(0.18)
        case .idle:            return Color.white.opacity(0.10)
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// A coarse, stepped level bar (0…`CaptureActivityAttributes` levelStep range) — a few
/// discrete bars, NOT a smooth VU meter (Live Activities are snapshot-rendered + updates
/// are throttled, so the level is a low-frequency pulse). `step` is the number of lit bars.
@available(iOS 16.1, *)
struct CaptureLevelBars: View {
    let step: Int
    var compact: Bool = false

    var body: some View {
        let bars = 3   // must match CaptureLiveStatus.levelSteps
        let lit = max(0, min(bars, step))
        HStack(spacing: compact ? 1.5 : 2.5) {
            ForEach(0..<bars, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < lit ? Color.red : Color.white.opacity(0.25))
                    .frame(width: compact ? 2.5 : 3.5,
                           height: compact ? CGFloat(5 + i * 3) : CGFloat(6 + i * 4))
            }
        }
    }
}
#endif
