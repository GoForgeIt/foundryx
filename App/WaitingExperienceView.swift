// WaitingExperienceView — the ONE shared SwiftUI component for every user-visible
// wait longer than ~1s (perf track WS-C). It binds a `WaitingExperienceModel` (the
// pure, unit-tested model in FoundryXKit) to Grain UI and does exactly what the model
// says: names the wait honestly, shows a REAL determinate bar only where the model
// has honest counts (sync), otherwise elapsed-aware phase text (never a fake bar), and
// rotates one genuinely-true tip every few seconds.
//
// Timing (elapsed + tip rotation) is driven entirely by a TimelineView — there is NO
// Timer, so nothing to invalidate and no retain cycle to leak. Reduce Motion is
// honored: the tip cross-fades (never slides) and the rotation animation is dropped.
//
// Two forms:
//   • default (card)  — recap generation, door fetch, transcription-pending, titling.
//   • `compact: true`  — the one-line sync/backfill banner (dot + text + thin bar).

import SwiftUI
import Grain

struct WaitingExperienceView: View {
    let model: WaitingExperienceModel
    var compact: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Captured once when the view first appears (stable across TimelineView redraws) —
    // the anchor the elapsed-aware phase text and tip rotation are measured from.
    @State private var start = Date()

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(start))
            if compact { compactBody(elapsed: elapsed) } else { cardBody(elapsed: elapsed) }
        }
    }

    // MARK: - Card form

    private func cardBody(elapsed: TimeInterval) -> some View {
        let copy = model.copy
        let tip = model.tip(elapsed: elapsed)
        return VStack(alignment: .leading, spacing: GrainSpacing.x3) {
            HStack(spacing: GrainSpacing.x2) {
                GrainSpinner(size: 16)
                Text(copy.headline)
                    .grainTextStyle(.title)
                    .foregroundStyle(GrainColor.ink)
            }
            Text(model.statusLine(elapsed: elapsed))
                .grainTextStyle(.body)
                .foregroundStyle(GrainColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let fraction = model.progress.fraction {
                GrainProgress(value: fraction)
            }
            Divider().overlay(GrainColor.borderFaint)
            tipView(tip.text)
        }
        .padding(GrainSpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GrainColor.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: GrainRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GrainRadius.card, style: .continuous)
                .strokeBorder(GrainColor.borderHairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(copy.headline). \(model.statusLine(elapsed: elapsed))")
    }

    // MARK: - Compact form (sync/backfill banner)

    private func compactBody(elapsed: TimeInterval) -> some View {
        let copy = model.copy
        let tip = model.tip(elapsed: elapsed)
        return VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            HStack(spacing: GrainSpacing.x2) {
                Circle()
                    .fill(model.progress.isDeterminate ? GrainColor.amber : GrainColor.sage)
                    .frame(width: GrainSpacing.x2, height: GrainSpacing.x2)
                Text(model.statusLine(elapsed: elapsed))
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
                Spacer(minLength: GrainSpacing.x2)
            }
            if let fraction = model.progress.fraction {
                GrainProgress(value: fraction)
            }
            tipView(tip.text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(copy.headline). \(model.statusLine(elapsed: elapsed))")
    }

    // MARK: - Rotating tip (subtle cross-fade; no timer)

    @ViewBuilder private func tipView(_ text: String) -> some View {
        Text(text)
            .grainTextStyle(.caption)
            .foregroundStyle(GrainColor.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .id(text)
            .transition(.opacity)
            .animation(reduceMotion ? nil : GrainMotion.slow, value: text)
    }
}
