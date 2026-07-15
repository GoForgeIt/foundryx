// AgentRunFinding — how a FINISHED tool-using turn reads in the shipped chat
// (track 20260714T1800 §7, fullflow2 `renderRun` findings block, :2352). A
// completed run is not a bare "DONE" row: it folds into a Finding card — a
// headline ("Done. report.md is ready."), the run's findings body, its steps
// (older ones folded via RunStepFold), and a sources-consulted line. Pure and
// testable; App/AgentRunView.swift + ChatScreen render it over the SAME
// ChatViewModel the chat trace streams into.

import Foundation

public struct AgentRunFinding: Equatable, Sendable {
    /// "Done. report.md is ready." (or a plain "Done." when the run wrote nothing).
    public let headline: String
    /// The findings body — the run's final assistant message. Nil when empty.
    public let body: String?
    /// "Sources consulted · Architecture call · Launch deck · 2 notes".
    public let sourcesLine: String
    /// The run's steps, oldest first (the card folds older ones).
    public let steps: [RunStepTile]

    /// The >4-step fold layout the card renders with.
    public var fold: RunStepFold.Layout { RunStepFold.layout(stepCount: steps.count) }

    /// The wiring gate ChatScreen uses: a Finding card exists only for a
    /// COMPLETED turn that actually used tools. Streaming turns keep the live
    /// trace; plain answers stay plain bubbles.
    public static func make(from model: ChatViewModel) -> AgentRunFinding? {
        guard case .completed = model.turnState, !model.activities.isEmpty else { return nil }
        return make(steps: model.activities.map(RunStepTile.init),
                    findings: model.assistantText,
                    artifacts: model.artifacts.map(\.name))
    }

    public static func make(steps: [RunStepTile], findings: String,
                            artifacts: [String] = []) -> AgentRunFinding? {
        guard !steps.isEmpty else { return nil }
        let trimmed = findings.trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = artifacts.first.map { "Done. \($0) is ready." } ?? "Done."
        return AgentRunFinding(headline: headline,
                               body: trimmed.isEmpty ? nil : trimmed,
                               sourcesLine: sourcesLine(steps: steps),
                               steps: steps)
    }

    /// What the run consulted, stated plainly: the first search step's outcome
    /// when there was one ("Sources consulted · Architecture call · …"), else
    /// an honest step count ("Sources consulted · 5 steps").
    public static func sourcesLine(steps: [RunStepTile]) -> String {
        let label = AnswerCopy.sourcesLabel
        if let search = steps.first(where: { $0.symbol.lowercased().contains("magnifying") }),
           let outcome = search.outcome, !outcome.isEmpty, outcome != "done" {
            return "\(label) · \(outcome)"
        }
        return "\(label) · \(steps.count) step\(steps.count == 1 ? "" : "s")"
    }

    public init(headline: String, body: String?, sourcesLine: String, steps: [RunStepTile]) {
        self.headline = headline
        self.body = body
        self.sourcesLine = sourcesLine
        self.steps = steps
    }
}
