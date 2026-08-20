// CaptureJourneyStrip — the ladder that says what is happening to THIS recording.
//
// IT DECIDES NOTHING. Every state, every sentence, every number and the question of whether a bar
// may be drawn at all belong to `CaptureJourney` / `JourneyFigure` in the kit, because `swift test`
// cannot compile `App/` — a rule written in this file is a rule nothing in this repository can
// execute, which is exactly how three invented numbers got onto this surface. This view maps
// `step.state` to a glyph, `step.figure.showsBar` to a bar, and stops.
//
// In particular there is NO arithmetic here. If you find yourself wanting to divide two numbers in
// this file, the division belongs in `JourneyFigure`, where something can hold it.

import SwiftUI
import Grain
// (FoundryXKit types are same-module — the App target compiles Sources/FoundryXKit directly)

struct CaptureJourneyStrip: View {
    let journey: CaptureJourney

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            ForEach(journey.steps) { step in
                row(step)
            }
        }
        .padding(.vertical, GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("capture-journey")
    }

    @ViewBuilder
    private func row(_ step: CaptureJourney.Step) -> some View {
        HStack(alignment: .top, spacing: GrainSpacing.x2) {
            glyph(step.state)
                .frame(width: GrainSpacing.x4, height: GrainSpacing.x4)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                HStack(spacing: GrainSpacing.x2) {
                    Text(step.title)
                        .grainTextStyle(.body)
                        .foregroundStyle(titleColor(step.state))
                    Spacer(minLength: 0)
                    if !step.figure.line.isEmpty {
                        Text(step.figure.line)
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textMuted)
                            .monospacedDigit()
                    }
                }
                // THE BAR EXISTS ONLY WHERE THE KIT SAYS A DENOMINATOR DOES.
                if let fraction = step.figure.fraction {
                    GrainProgress(value: fraction)
                }
                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .grainTextStyle(.caption)
                        .foregroundStyle(step.state == .failed ? GrainColor.amber
                                                              : GrainColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func glyph(_ state: CaptureJourney.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(GrainColor.sage)
        case .working:
            ProgressView().controlSize(.mini)
        case .waiting:
            Circle().fill(GrainColor.textFaint.opacity(0.35))
                .frame(width: 8, height: 8)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(GrainColor.amber)
        }
    }

    private func titleColor(_ state: CaptureJourney.State) -> Color {
        switch state {
        case .done, .working: return GrainColor.ink
        case .waiting: return GrainColor.textFaint
        case .failed: return GrainColor.amber
        }
    }

    private var accessibilitySummary: String {
        let parts = journey.steps.map { step -> String in
            let figure = step.figure.line.isEmpty ? "" : ", \(step.figure.line)"
            return "\(step.title): \(step.state.rawValue)\(figure)"
        }
        // "voice note", not "recording" — features/voice-notes-language.feature retired the old
        // word for this thing, and this string is an accessibility LABEL, which that gate scans.
        return "Where this voice note is. " + parts.joined(separator: ". ")
    }
}
