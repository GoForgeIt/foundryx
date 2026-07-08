import SwiftUI
import Grain

// NOTE: no `import FoundryXKit` — the app target compiles Sources/FoundryXKit
// directly into this same module (see project.yml), so ConversationProgress et al.
// are already in scope; importing a non-existent module breaks the Xcode build.

/// A horizontal "where is this conversation in the pipeline" stepper, shown on the
/// conversation detail view so the user SEES progress (Recorded → Saved →
/// Transcribing → Ready) instead of staring at a spinner wondering if it's stuck.
///
/// Each step reads its state from the pure, unit-tested `ConversationProgress.state(of:)`
/// — done (filled check), active (pulsing accent), pending (dim), or failed (amber).
/// The connectors between steps fill in as steps complete. The whole thing collapses
/// to nothing once `.ready` is reached AND the caller decides it's uninteresting
/// (that's the caller's call — this view always renders what it's given).
struct ConversationStepper: View {
    let progress: ConversationProgress
    /// Phone-only tier → "Saved on phone" / "Transcribing on phone" labels.
    var local: Bool = false

    private let steps = ConversationProgress.Step.allCases

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element) { idx, step in
                stepColumn(step)
                if idx < steps.count - 1 {
                    connector(after: step)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: one step (dot + label)

    @ViewBuilder
    private func stepColumn(_ step: ConversationProgress.Step) -> some View {
        let state = progress.state(of: step)
        VStack(spacing: GrainSpacing.x1) {
            dot(state)
            Text(step.label(local: local))
                .grainTextStyle(.caption)
                .foregroundStyle(labelColor(state))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func dot(_ state: ConversationProgress.StepState) -> some View {
        ZStack {
            Circle().fill(fill(state)).frame(width: 20, height: 20)
            switch state {
            case .done:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            case .failed:
                Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            case .active:
                // A gently pulsing ring so the CURRENT step reads as "working now".
                Circle().stroke(GrainColor.sage, lineWidth: 2).frame(width: 20, height: 20)
                    .scaleEffect(pulse ? 1.25 : 1.0)
                    .opacity(pulse ? 0.0 : 1.0)
                    .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
                Circle().fill(GrainColor.sage).frame(width: 8, height: 8)
            case .pending:
                Circle().fill(GrainColor.textFaint.opacity(0.4)).frame(width: 8, height: 8)
            }
        }
        .onAppear { pulse = true }
    }

    @State private var pulse = false

    private func connector(after step: ConversationProgress.Step) -> some View {
        // The connector is "done" (accent) only when the step BEFORE it is done.
        let filled = progress.state(of: step) == .done
        return Rectangle()
            .fill(filled ? GrainColor.sage.opacity(0.7) : GrainColor.textFaint.opacity(0.25))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .offset(y: 9)   // align with the 20pt dots' centers
    }

    // MARK: styling

    private func fill(_ state: ConversationProgress.StepState) -> Color {
        switch state {
        case .done: return GrainColor.sage
        case .active: return .clear
        case .pending: return GrainColor.surfaceElevated
        case .failed: return GrainColor.amber
        }
    }

    private func labelColor(_ state: ConversationProgress.StepState) -> Color {
        switch state {
        case .done, .active: return GrainColor.ink
        case .pending: return GrainColor.textFaint
        case .failed: return GrainColor.amber
        }
    }

    private var accessibilitySummary: String {
        let names = steps.map { step -> String in
            let s = progress.state(of: step)
            let mark = s == .done ? "done" : s == .active ? "in progress" : s == .failed ? "failed" : "pending"
            return "\(step.label(local: local)): \(mark)"
        }
        return "Conversation progress. " + names.joined(separator: ", ")
    }
}
