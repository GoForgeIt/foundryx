// AgentRunView: the agent-run card (track 20260713T0906 AC2, fullflow v8
// "agentRun"/"runsum" scenes). A run reads as step tiles (tool action + one-line
// outcome) as they happen; more than four steps fold the older ones behind
// "N more steps" (tap to unfold); a finished run shows its findings summary and
// a follow-up field that continues the run's session; hosted runs state their
// venue and trial count plainly ("Run 1 of 10 · runs on Foundry Cloud").
//
// Data-driven (RunStepTile / RunStepFold / RunVenue from FoundryXKit) with an
// AgentRunCard wrapper that binds the SAME ChatViewModel the chat trace uses;
// the card and the inline trace never disagree.
//
// ENTRY POINT (integration): ChatScreen can host `AgentRunCard(model:title:...)`
// for a run-seeded conversation; `onFollowUp` should feed the screen's existing
// send path so the follow-up continues the run's session.

import SwiftUI
import Grain
// (FoundryXKit types are same-module; the App target compiles Sources/FoundryXKit directly)

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
    /// The finding headline a finished run leads with ("Done. report.md is ready.").
    var findingHeadline: String? = nil
    /// The findings summary a finished run shows (the run's final message).
    var findings: String? = nil
    /// Sends a follow-up that continues the run's session.
    var onFollowUp: (String) -> Void = { _ in }

    @State private var unfolded = false
    @State private var followUp = ""

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x3) {
            if let hostedLine {
                venueLine(hostedLine)
            }

            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                Text(title)
                    .grainTextStyle(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(GrainColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let originLabel {
                    Text(originLabel)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                }
            }

            stepsSection
            if isFinished { summarySection }
        }
        .padding(GrainSpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                .fill(GrainColor.surfaceElevated)
        )
        .overlay {
            RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                .strokeBorder(GrainColor.borderFaint, lineWidth: 1)
        }
    }

    private func venueLine(_ text: String) -> some View {
        HStack(spacing: GrainSpacing.x2) {
            Image(grain: .bolt)
            Text(text)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .grainTextStyle(.caption)
        .fontWeight(.bold)
        .foregroundStyle(GrainColor.forgeBlue)
        .padding(.horizontal, GrainSpacing.x3)
        .padding(.vertical, GrainSpacing.x2)
        .background(
            RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous)
                .fill(GrainColor.forgeBlueBg)
        )
        .overlay {
            RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous)
                .strokeBorder(GrainColor.forgeBlueBorder, lineWidth: 1)
        }
        .accessibilityIdentifier("run-venue")
    }

    // MARK: steps + fold

    private var layout: RunStepFold.Layout { RunStepFold.layout(stepCount: steps.count) }

    private var visibleSteps: [RunStepTile] {
        unfolded ? steps : Array(steps[layout.visible])
    }

    @ViewBuilder private var stepsSection: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let label = layout.foldLabel, !unfolded {
                    Button {
                        unfolded = true
                    } label: {
                        HStack(spacing: GrainSpacing.x1) {
                            Image(grain: .check)
                            Text(label)
                            Spacer(minLength: 0)
                        }
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                        .frame(minHeight: GrainSpacing.x8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("run-step-fold")
                }
                ForEach(visibleSteps.indices, id: \.self) { index in
                    StepTileRow(
                        tile: visibleSteps[index],
                        isLast: index == visibleSteps.count - 1
                    )
                }
            }
            .accessibilityIdentifier("run-steps")
        }
    }

    // MARK: finished-run summary + follow-up

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x3) {
            if findingHeadline != nil || findings?.isEmpty == false {
                VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                    Text("Finding")
                        .grainTextStyle(.caption)
                        .fontWeight(.bold)
                        .textCase(.uppercase)
                        .foregroundStyle(GrainColor.sage)
                    if let findingHeadline {
                        Text(findingHeadline)
                            .grainTextStyle(.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(GrainColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("run-finding-headline")
                    }
                    if let findings, !findings.isEmpty {
                        Text(findings)
                            .grainTextStyle(.body)
                            .foregroundStyle(GrainColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("run-findings")
                    }
                    // What the run consulted, stated plainly (the user's own
                    // conversations — never "citations").
                    Text(AgentRunFinding.sourcesLine(steps: steps))
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                        .padding(.top, GrainSpacing.x1)
                        .accessibilityIdentifier("run-sources")
                }
            }

            HStack(spacing: GrainSpacing.x2) {
                Image(grain: .chat)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
                TextField("Ask a follow-up…", text: $followUp)
                    .textFieldStyle(.plain)
                    .grainTextStyle(.body)
                    .foregroundStyle(GrainColor.ink)
                    .onSubmit(sendFollowUp)
                GrainButton("Send", variant: .tonal, size: .sm) { sendFollowUp() }
            }
            .padding(.leading, GrainSpacing.x3)
            .padding(.trailing, GrainSpacing.x1)
            .padding(.vertical, GrainSpacing.x1)
            .frame(minHeight: GrainSpacing.x8 + GrainSpacing.x2)
            .background(
                RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                    .fill(GrainColor.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                    .strokeBorder(GrainColor.border, lineWidth: 1)
            }
            .accessibilityIdentifier("run-follow-up")
        }
        .padding(.top, GrainSpacing.x3)
        .overlay(alignment: .top) {
            Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
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
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: GrainSpacing.x3) {
            ZStack {
                RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous)
                    .fill(tileBackground)
                Image(grain: tileIcon)
                    .grainTextStyle(.caption)
                    .foregroundStyle(tileForeground)
            }
            .frame(width: GrainSpacing.x8, height: GrainSpacing.x8)
            .overlay {
                RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous)
                    .strokeBorder(tileBorder, lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                Text(tile.title)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let outcome = tile.outcome {
                    Text(outcome)
                        .grainTextStyle(.caption)
                        .foregroundStyle(tile.isError ? GrainColor.amber : GrainColor.textFaint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("run-step-outcome")
                }
            }
            .padding(.top, GrainSpacing.x1)

            Spacer(minLength: 0)
        }
        .padding(.bottom, isLast ? 0 : GrainSpacing.x2)
        .overlay(alignment: .topLeading) {
            if !isLast {
                Rectangle()
                    .fill(GrainColor.borderFaint)
                    .frame(width: 1)
                    .padding(.leading, GrainSpacing.x4)
                    .padding(.top, GrainSpacing.x8)
            }
        }
        .accessibilityIdentifier("run-step")
    }

    private var tileForeground: Color {
        if tile.isError { return GrainColor.amber }
        if tile.isRunning { return GrainColor.forgeBlue }
        return GrainColor.sage
    }

    private var tileBackground: Color {
        if tile.isError { return GrainColor.amber.opacity(0.14) }
        if tile.isRunning { return GrainColor.forgeBlueBg }
        return GrainColor.sage.opacity(0.14)
    }

    private var tileBorder: Color {
        tile.isRunning ? GrainColor.forgeBlueBorder : GrainColor.borderFaint
    }

    private var tileIcon: GrainIcon {
        let symbol = tile.symbol.lowercased()
        if symbol.contains("search") || symbol.contains("magnifying") { return .search }
        if symbol.contains("doc") || symbol.contains("note") || symbol.contains("text") { return .doc }
        if symbol.contains("pencil") || symbol.contains("write") || symbol.contains("edit") { return .pencil }
        if symbol.contains("calendar") || symbol.contains("clock") { return .calendar }
        if symbol.contains("chat") || symbol.contains("bubble") || symbol.contains("message") { return .chat }
        if symbol.contains("wave") || symbol.contains("activity") { return .waveform }
        if symbol.contains("mic") { return .mic }
        if symbol.contains("device") || symbol.contains("iphone") { return .device }
        if symbol.contains("check") { return .check }
        if symbol.contains("play") { return .play }
        return .gear
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
        // The finding presentation is pure + tested (AgentRunFinding); this
        // wrapper just binds it to the live model.
        let finding = AgentRunFinding.make(from: model)
        AgentRunView(
            title: title,
            originLabel: originLabel,
            hostedLine: hostedLine,
            steps: finding?.steps ?? model.activities.map(RunStepTile.init),
            isFinished: isFinished,
            findingHeadline: finding?.headline,
            findings: finding?.body,
            onFollowUp: onFollowUp)
    }
}
