// AgentRunPresentation — pure legibility logic for agent-run cards (track
// 20260713T0906 AC2, fullflow v8 "agentRun"/"agentCard"/"runsum" scenes). A run
// reads as step tiles (tool name + one-line outcome) as they happen; more than
// four steps fold the older ones behind "N more steps"; hosted runs state their
// venue and trial count plainly. All pure + testable; App/AgentRunView.swift
// renders it over the SAME ChatViewModel activities the chat trace uses.

import Foundation

/// The >4-step fold: which steps stay visible and what the fold row says.
public enum RunStepFold {
    /// How many of the most recent steps stay visible before folding kicks in.
    public static let windowSize = 4

    public struct Layout: Equatable, Sendable {
        /// How many older steps are folded away (0 = no fold).
        public let foldedCount: Int
        /// The index range of steps that stay visible (always the most recent).
        public let visible: Range<Int>

        /// "N more steps" — nil when nothing is folded.
        public var foldLabel: String? {
            foldedCount > 0 ? RunStepFold.label(foldedCount) : nil
        }
    }

    /// Fold `stepCount` steps: up to `window` steps show unfolded; beyond that
    /// the OLDER steps fold and the most recent `window` stay visible.
    public static func layout(stepCount: Int, window: Int = windowSize) -> Layout {
        let count = max(stepCount, 0)
        guard count > window else {
            return Layout(foldedCount: 0, visible: 0..<count)
        }
        let folded = count - window
        return Layout(foldedCount: folded, visible: folded..<count)
    }

    /// "3 more steps" / "1 more step".
    public static func label(_ n: Int) -> String {
        "\(n) more step\(n == 1 ? "" : "s")"
    }
}

/// One step tile on a run card: the tool action ("ran: ls -la") + a one-line
/// outcome once the tool finished. Built straight from the chat trace's
/// ToolActivity so the run card and the inline trace never disagree.
public struct RunStepTile: Equatable, Sendable, Identifiable {
    public let id: String
    /// The action line — tool verb + primary argument ("read Foo.swift").
    public let title: String
    /// One-line outcome; nil while the step is still running.
    public let outcome: String?
    /// SF Symbol name for the tool glyph.
    public let symbol: String
    public let isError: Bool

    public var isRunning: Bool { outcome == nil }

    public init(id: String, title: String, outcome: String?,
                symbol: String = "wrench.and.screwdriver", isError: Bool = false) {
        self.id = id
        self.title = title
        self.outcome = outcome
        self.symbol = symbol
        self.isError = isError
    }

    public init(activity: ChatViewModel.ToolActivity) {
        self.id = activity.id
        let summary = activity.summary
        self.title = summary.isEmpty ? activity.name : summary
        self.outcome = activity.isRunning ? nil : Self.outcomeLine(activity.resultContent)
        self.symbol = activity.symbol
        self.isError = activity.isError
    }

    /// The one-line outcome: the first non-blank line of the tool result,
    /// capped at `cap` characters. An empty (but present) result reads "done";
    /// nil (still running) stays nil.
    public static func outcomeLine(_ result: String?, cap: Int = 120) -> String? {
        guard let result else { return nil }
        let line = result
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        if line.isEmpty { return "done" }
        if line.count > cap { return String(line.prefix(cap)) + "…" }
        return line
    }
}

/// Hosted-run honesty: where the run executes and which trial this is,
/// stated plainly — "Run 1 of 10 · runs on Foundry Cloud".
public enum RunVenue {
    public static func hostedLine(run: Int, of total: Int, venue: String) -> String {
        "Run \(run) of \(total) · runs on \(venue)"
    }
}
