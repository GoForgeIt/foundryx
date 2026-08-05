// ChatView — the FoundryX chat surface (SwiftUI), now built on the Grain design
// system. Cross-platform SwiftUI (no UIKit) so it hosts on the macOS test lane
// (NSHostingView) AND ships in the iOS app unchanged. Renders the conversation,
// streams the in-flight assistant reply, and surfaces the gate approval prompt.
//
// Accessibility identifiers ("assistant-message", "user-message",
// "approval-prompt", "turn-status") are preserved so the Brine UI scenario (AC4)
// keeps asserting against the same rendered state. No raw colors or fonts —
// everything comes from Grain tokens/components.

#if canImport(SwiftUI)
import SwiftUI
import Grain

public struct ChatView: View {
    @ObservedObject public var model: ChatViewModel
    public var onApprove: (String) -> Void
    public var onReject: (String) -> Void
    /// The user opened the trace fold this turn (resets with the next turn's
    /// activities clear — the array becomes short again and the fold disappears).
    @State private var traceUnfolded = false
    /// Opens a file the agent wrote this turn (the host screen presents the
    /// viewer; nil = artifact rows still render, tap does nothing).
    public var onOpenArtifact: ((ChatViewModel.RunArtifact) -> Void)?
    /// Whether to show the two signals that only mean something when there is an AGENT and a
    /// DOOR behind this chat: "it can read files and run commands, and asks first", and the
    /// transport status dot.
    ///
    /// The on-device tier has neither — no tools, no door — so on that surface both would be
    /// untrue. Same bubbles, same composer, same scroll; two claims it is not entitled to
    /// make. This is a parameter rather than a second view for exactly the reason this file's
    /// header gives.
    public var showsAgentSignals: Bool

    public init(model: ChatViewModel,
                onApprove: @escaping (String) -> Void = { _ in },
                onReject: @escaping (String) -> Void = { _ in },
                onOpenArtifact: ((ChatViewModel.RunArtifact) -> Void)? = nil,
                showsAgentSignals: Bool = true) {
        self.model = model
        self.onApprove = onApprove
        self.onReject = onReject
        self.onOpenArtifact = onOpenArtifact
        self.showsAgentSignals = showsAgentSignals
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x3) {
            if showsAgentSignals {
                connectionStatusRow
                agenticAffordance
            }

            ForEach(model.messages) { msg in
                if msg.role == "assistant" {
                    VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                        GrainMessageBubble(role: .assistant, text: msg.text)
                            .accessibilityIdentifier("assistant-message")
                        // Trust signal: which model + router answered, and whether it
                        // ran on-device (🔒 local) or in the cloud (☁️ cloud).
                        if let caption = Self.routeCaption(msg) {
                            Text(caption)
                                .grainTextStyle(.caption)
                                .foregroundStyle(GrainColor.textMuted)
                                .accessibilityIdentifier("message-route")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    GrainMessageBubble(role: .user, text: msg.text)
                        .accessibilityIdentifier("user-message")
                }
            }

            // Inline tool-activity trace — one compact, expandable row per tool action the
            // agent took this turn (Claude-Code-style visibility into read/edit/bash/…).
            // Long runs stay readable: older steps fold behind "N more steps"; the
            // most recent window stays visible (track 20260713T0906 AC2).
            if !model.activities.isEmpty {
                let fold = RunStepFold.layout(stepCount: model.activities.count)
                VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                    if let label = fold.foldLabel, !traceUnfolded {
                        Button {
                            traceUnfolded = true
                        } label: {
                            Text(label)
                                .grainTextStyle(.caption)
                                .foregroundStyle(GrainColor.textMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tool-activity-fold")
                    }
                    let shown = traceUnfolded
                        ? model.activities
                        : Array(model.activities[fold.visible])
                    ForEach(shown) { ToolActivityRow(activity: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("tool-activity-trace")
                .onChange(of: model.activities.isEmpty) { cleared in
                    if cleared { traceUnfolded = false }   // next turn folds afresh
                }
            }

            // Files the agent wrote this turn (announced by the door only for
            // files that actually exist in its sandbox) — tap to view.
            if !model.artifacts.isEmpty {
                VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                    ForEach(model.artifacts) { artifact in
                        Button {
                            onOpenArtifact?(artifact)
                        } label: {
                            HStack(spacing: GrainSpacing.x2) {
                                Image(grain: .doc)
                                    .font(.system(size: 13, weight: .light))
                                    .foregroundStyle(GrainColor.forgeBlue)
                                Text("View \(artifact.name)")
                                    .grainTextStyle(.caption)
                                    .foregroundStyle(GrainColor.ink)
                                Spacer()
                            }
                            .padding(.horizontal, GrainSpacing.x3)
                            .padding(.vertical, GrainSpacing.x2)
                            .background(RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous)
                                .fill(GrainColor.forgeBlueBg))
                            .overlay(RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous)
                                .strokeBorder(GrainColor.forgeBlueBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("run-artifacts")
            }

            switch model.turnState {
            case .awaitingApproval(let callId, let name, let args):
                ApprovalCard(detail: ChatViewModel.approvalDetail(name: name, argsJSON: args),
                             onApprove: { onApprove(callId) },
                             onReject: { onReject(callId) })
                    .accessibilityIdentifier("approval-prompt")
            case .completed(let reason):
                VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                    Text(model.statusLine ?? "done: \(reason)")
                        .grainTextStyle(.caption)
                        .textCase(.uppercase)
                        .foregroundStyle(GrainColor.sage)
                    if let t = model.lastTiming, t.totalMs >= 0 {
                        Text(Self.timingCaption(t))
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textFaint)
                            .monospacedDigit()
                    }
                }
                .accessibilityIdentifier("turn-status")
            case .refused(let reason):
                // Show the door's clear explanation (confidential kept local, auth
                // expired, …) when present; fall back to a bare label otherwise.
                Text(reason ?? "Message couldn't be sent")
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.dangerRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("turn-status")
            case .streaming:
                HStack(spacing: GrainSpacing.x2) {
                    GrainTypingIndicator()
                    // Live status line: "Thinking… / Running <tool> <arg>… / Responding…".
                    // Turns the long agentic pause into a legible, moving signal.
                    if let status = model.statusLine {
                        Text(status)
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textMuted)
                            .accessibilityIdentifier("status-line")
                    }
                    // Before the first token, tick a SMOOTH local elapsed timer (every 0.5s)
                    // so it's visibly moving — qwen3's time-to-first-token can be many seconds,
                    // and the door's keepalive lands too sparsely to look alive on its own.
                    if model.assistantText.isEmpty, model.activities.isEmpty, let started = model.turnStartedAt {
                        TimelineView(.periodic(from: started, by: 0.5)) { ctx in
                            Text("\(String(format: "%.1f", ctx.date.timeIntervalSince(started)))s")
                                .grainTextStyle(.caption)
                                .foregroundStyle(GrainColor.textFaint)
                                .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                }
            case .idle:
                EmptyView()
            }
        }
        .padding(GrainSpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A quiet, always-present signal that this assistant is agentic — it can read/write
    /// files and run commands, and asks before it acts. Sets the mental model so a powerful
    /// capability never feels like a surprising one. (What tools exist + the approval policy
    /// are Kiln's; this only names the capability the user is already talking to.)
    private var agenticAffordance: some View {
        HStack(spacing: GrainSpacing.x2) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 11))
                .foregroundStyle(GrainColor.forgeBlue)
            Text(ChatViewModel.agenticAffordance)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, GrainSpacing.x1)
        .accessibilityIdentifier("agentic-affordance")
    }

    /// "first token 12.4s · total 31.5s · 331 tok" — the per-turn timing under a done turn.
    private static func timingCaption(_ t: ChatViewModel.TurnTiming) -> String {
        func s(_ ms: Int) -> String { ms < 0 ? "—" : String(format: "%.1fs", Double(ms) / 1000) }
        return "first token \(s(t.ttftMs)) · total \(s(t.totalMs)) · \(t.tokens) tok"
    }

    /// `🔒 local · <model>` / `☁️ cloud · <model>` for a routed assistant message
    /// (nil until the turn's `routed:` boundary lands).
    private static func routeCaption(_ msg: ChatViewModel.Message) -> String? {
        guard let model = msg.routeModelLabel else { return nil }
        return msg.routeIsLocal ? "🔒 local · \(model)" : "☁️ cloud · \(model)"
    }

    /// Connection/transport status — dot + label. Green when connected/streaming,
    /// gray when idle, red (with the failure reason) on a transport error. Gives a
    /// visible signal when the phone can't reach the door instead of "nothing happened."
    private var connectionDisplay: (dot: GrainStatus, label: String, isError: Bool) {
        switch model.connection {
        case .idle: return (.idle, "idle", false)
        case .connecting: return (.thinking, "connecting…", false)
        case .streaming: return (.running, "connected", false)
        case .completed(let reason): return (.running, "connected (\(reason))", false)
        case .error(let detail): return (.tripped, "error: \(detail)", true)
        }
    }

    private var connectionStatusRow: some View {
        let d = connectionDisplay
        return HStack(spacing: GrainSpacing.x2) {
            GrainStatusDot(d.dot, size: .sm)
            Text(d.label)
                .grainTextStyle(.caption)
                .foregroundStyle(d.isError ? GrainColor.dangerRed : GrainColor.textMuted)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("connection-status")
    }
}

// MARK: - Inline tool-activity row

/// One compact, expandable row in the inline tool-activity trace: a glyph + the action
/// ("read Foo.swift", "ran: ls -la"), a running/done/error indicator, and — once the tool
/// finished — a tap to reveal its output. This is the core "make the agent visible" surface.
private struct ToolActivityRow: View {
    let activity: ChatViewModel.ToolActivity
    @State private var expanded = false

    private var canExpand: Bool { (activity.resultContent?.isEmpty == false) }

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            Button {
                if canExpand { expanded.toggle() }
            } label: {
                HStack(spacing: GrainSpacing.x2) {
                    Image(systemName: activity.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(activity.isError ? GrainColor.dangerRed : GrainColor.forgeBlue)
                        .frame(width: 14)
                    Text(activity.summary)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMain)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    trailingIndicator
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let result = activity.resultContent {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(result)
                        .grainTextStyle(.caption)
                        .monospaced()
                        .foregroundStyle(GrainColor.textMuted)
                        .padding(GrainSpacing.x2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: 180)
                .background(GrainColor.backgroundSunken)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("tool-activity-result")
            }
        }
        .padding(.vertical, GrainSpacing.x1)
        .padding(.horizontal, GrainSpacing.x2)
        .background(GrainColor.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("tool-activity")
    }

    @ViewBuilder private var trailingIndicator: some View {
        if activity.isRunning {
            GrainStatusDot(.thinking, size: .sm)
        } else if activity.isError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(GrainColor.dangerRed)
        } else if canExpand {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9))
                .foregroundStyle(GrainColor.textFaint)
        }
    }
}

// MARK: - Rich approval card

/// The approval prompt, upgraded from a bare "Approve read?" to show EXACTLY what the agent
/// wants to do — the shell command, or the file + its before/after — before the user consents.
/// Nothing runs until the user answers; the turn stays suspended at the door.
private struct ApprovalCard: View {
    let detail: ChatViewModel.ApprovalDetail
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        GrainCard(.filled) {
            VStack(alignment: .leading, spacing: GrainSpacing.x3) {
                HStack(spacing: GrainSpacing.x2) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 12))
                        .foregroundStyle(GrainColor.amber)
                    Text(detail.title)
                        .grainTextStyle(.body)
                        .foregroundStyle(GrainColor.ink)
                    Spacer(minLength: 0)
                }

                detailBody

                HStack(spacing: GrainSpacing.x2) {
                    GrainButton("Approve", variant: .filled, size: .sm) { onApprove() }
                    GrainButton("Reject", variant: .outlined, size: .sm) { onReject() }
                }
            }
        }
    }

    @ViewBuilder private var detailBody: some View {
        switch detail.kind {
        case .command:
            codeBlock(detail.command ?? "", id: "approval-command")
        case .fileWrite:
            if let path = detail.filePath { pathLabel(path) }
            if let content = detail.newText { codeBlock(content, id: "approval-content") }
        case .fileEdit:
            if let path = detail.filePath { pathLabel(path) }
            diffBlock(old: detail.oldText, new: detail.newText)
        case .generic:
            if let body = detail.body, !body.isEmpty { codeBlock(body, id: "approval-args") }
        }
    }

    private func pathLabel(_ path: String) -> some View {
        Text(path)
            .grainTextStyle(.caption)
            .monospaced()
            .foregroundStyle(GrainColor.textMuted)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityIdentifier("approval-file")
    }

    private func codeBlock(_ text: String, id: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .grainTextStyle(.caption)
                .monospaced()
                .foregroundStyle(GrainColor.textMain)
                .padding(GrainSpacing.x2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: 200)
        .background(GrainColor.backgroundSunken)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier(id)
    }

    /// A small before/after diff for an edit approval — removed lines in red, added in green.
    @ViewBuilder private func diffBlock(old: String?, new: String?) -> some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            if let old, !old.isEmpty {
                diffLines(old, sign: "-", color: GrainColor.dangerRed)
            }
            if let new, !new.isEmpty {
                diffLines(new, sign: "+", color: GrainColor.sage)
            }
        }
        .padding(GrainSpacing.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GrainColor.backgroundSunken)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("approval-diff")
    }

    private func diffLines(_ text: String, sign: String, color: Color) -> some View {
        Text(text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "\(sign) \($0)" }.joined(separator: "\n"))
            .grainTextStyle(.caption)
            .monospaced()
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
