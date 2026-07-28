import SwiftUI
import Grain

/// Worked ambient-intelligence examples for the pre-consent onboarding step.
///
/// These use the same card component as live recording suggestions, but the whole
/// surface is labelled and disabled: action labels explain the real card affordance
/// without letting a preview enter the ambient lane or run anything.
struct AmbientPreviewCards: View {
    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            HStack(alignment: .firstTextBaseline, spacing: GrainSpacing.x2) {
                Text("Examples")
                    .grainTextStyle(.eyebrow)
                    .foregroundStyle(GrainColor.inkSecondary)
                Spacer(minLength: GrainSpacing.x2)
                Text("Illustrative only")
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
            }

            ForEach(AmbientPreviewExamples.all) { example in
                GrainSuggestionCard(
                    systemImage: example.systemImage,
                    tint: tint(for: example.kind),
                    eyebrow: example.eyebrow,
                    title: example.offer,
                    body: example.moment,
                    actionLabel: example.actionLabel,
                    onAction: {}
                )
                .disabled(true)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(example.exampleLabel). \(example.eyebrow). "
                        + "\(example.offer). Triggered by \(example.moment). "
                        + "\(example.actionLabel) is shown for illustration only.")
            }

            Text("These previews cannot be opened, saved, or run.")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tint(for kind: AmbientPreviewExample.Kind) -> GrainSuggestionTint {
        switch kind {
        case .agentDirected: return .agent
        case .memorySurface: return .memory
        }
    }
}
