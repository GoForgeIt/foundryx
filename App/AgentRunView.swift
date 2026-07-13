// AgentRunView — the agent-run card (track 20260713T0906 AC2, fullflow v8
// "agentRun"/"runsum" scenes). A run reads as step tiles (tool action + one-line
// outcome) as they happen; more than four steps fold the older ones behind
// "N more steps" (tap to unfold); a finished run shows its findings summary and
// a follow-up field that continues the run's session; hosted runs state their
// venue and trial count plainly ("Run 1 of 10 · runs on Foundry Cloud").
//
// Data-driven (RunStepTile / RunStepFold / RunVenue from FoundryXKit) with an
// AgentRunCard wrapper that binds the SAME ChatViewModel the chat trace uses —
// the card and the inline trace never disagree.
//
// ENTRY POINT (integration): ChatScreen can host `AgentRunCard(model:title:...)`
// for a run-seeded conversation; `onFollowUp` should feed the screen's existing
// send path so the follow-up continues the run's session.

import SwiftUI
import Grain
// (FoundryXKit types are same-module — the App target compiles Sources/FoundryXKit directly)

struct AgentRunView: View {
    /// What the run is doing, e.g. "Remind me to send Sarah the deck Friday".
    let title: String
    /// Provenance caption, e.g. "from \u{201C}Launch deck\u{2026}\u{201D}". Optional.
    var originLabel: String? = nil
    /// Hosted-run honesty line (RunVenue.hostedLine). nil for on-device runs.
    var hostedLine: String? = nil
    /// The run's steps, oldest first.
    let steps: [RunStepTile]
    /// True once the run's turn completed.
    let isFinished: Bool
    /// The findings summary a finished run shows (the run's final message).
    var findings: String? = nil
    /// Sends a follow-up that continues the run's session.
    var onFollowUp: (String) -> Void = { _ in }

    @State private var unfolded = false
    @State private var followUp = ""

    var body: some View {
        GrainCard(.filled) {
            VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                Text(title)
                    .grainTextStyle(.body)
                    .foregroundStyle(GrainColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let originLabel {
                    Text(originLabel)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                }
                if let hostedLine {
                    Text(hostedLine)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.forgeBlue)
                        .accessibilityIdentifier("run-venue")
                }
                stepsSection
                if isFinished { summarySection }
            }
        }
    }

    // MARK: steps + fold

    private var layout: RunStepFold.Layout { RunStepFold.layout(stepCount: steps.count) }

    private var visibleSteps: [RunStepTile] {
        unfolded ? steps : Array(steps[layout.visible])
    }

    @ViewBuilder private var stepsSection: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                if let label = layout.foldLabel, !unfolded {
                    Button {
                        unfolded = true
                    } label: {
                        HStack(spacing: GrainSpacing.x1) {
                            Image(grain: .check).font(.system(size: 10))
                            Text(label)
                        }
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("run-step-fold")
                }
                ForEach(visibleSteps) { StepTileRow(tile: $0) }
            }
            .accessibilityIdentifier("run-steps")
        }
    }

    // MARK: finished-run summary + follow-up

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            if let findings, !findings.isEmpty {
                Text(findings)
                    .grainTextStyle(.body)
                    .foregroundStyle(GrainColor.textMain)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("run-findings")
            }
            HStack(spacing: GrainSpacing.x2) {
                GrainTextField("Ask a follow-up…", text: $followUp)
                    .onSubmit(sendFollowUp)
                GrainButton("Send", variant: .tonal, size: .sm) { sendFollowUp() }
            }
            .accessibilityIdentifier("run-follow-up")
        }
        .padding(.top, GrainSpacing.x2)
        .overlay(alignment: .top) {
            Rectangle().fill(GrainColor.borderHairline).frame(height: 1)
        }
    }

    private func sendFollowUp() {
        let text = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        followUp = ""
        onFollowUp(text)
    }
}

/// One step tile: tool glyph, action line, one-line outcome (or a live dot
/// while the step is still running).
private struct StepTileRow: View {
    let tile: RunStepTile

    var body: some View {
        HStack(alignment: .top, spacing: GrainSpacing.x2) {
            Image(systemName: tile.symbol)
                .font(.system(size: 11))
                .foregroundStyle(tile.isError ? GrainColor.dangerRed : GrainColor.forgeBlue)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.title)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let outcome = tile.outcome {
                    Text(outcome)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("run-step-outcome")
                }
            }
            Spacer(minLength: 0)
            if tile.isRunning {
                GrainStatusDot(.thinking, size: .sm)
            } else if tile.isError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(GrainColor.dangerRed)
            }
        }
        .padding(.vertical, GrainSpacing.x1)
        .padding(.horizontal, GrainSpacing.x2)
        .background(GrainColor.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("run-step")
    }
}

/// Live binding over the SAME ChatViewModel the chat surface streams into:
/// steps are the turn's tool activities, "finished" is the completed turn state,
/// and the findings are the run's final assistant message.
struct AgentRunCard: View {
    @ObservedObject var model: ChatViewModel
    let title: String
    var originLabel: String? = nil
    var hostedLine: String? = nil
    var onFollowUp: (String) -> Void = { _ in }

    private var isFinished: Bool {
        if case .completed = model.turnState { return true }
        return false
    }

    var body: some View {
        AgentRunView(
            title: title,
            originLabel: originLabel,
            hostedLine: hostedLine,
            steps: model.activities.map(RunStepTile.init),
            isFinished: isFinished,
            findings: isFinished ? model.assistantText : nil,
            onFollowUp: onFollowUp)
    }
}
