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
    /// Approve the pending tool JUST this once (door decision "once").
    public var onApproveOnce: (String) -> Void
    /// Approve + stop asking for this tool (door decision "always").
    public var onApproveAlways: (String) -> Void
    /// Reject the pending tool (door decision "reject").
    public var onReject: (String) -> Void
    /// Re-send the failed turn's user text (the "tap to retry" chip).
    public var onRetry: () -> Void

    public init(model: ChatViewModel,
                onApproveOnce: @escaping (String) -> Void = { _ in },
                onApproveAlways: @escaping (String) -> Void = { _ in },
                onReject: @escaping (String) -> Void = { _ in },
                onRetry: @escaping () -> Void = {}) {
        self.model = model
        self.onApproveOnce = onApproveOnce
        self.onApproveAlways = onApproveAlways
        self.onReject = onReject
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x3) {
            connectionStatusRow

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

            // What the agent DID this turn — so a tool-running turn isn't a silent gap.
            if !model.toolRuns.isEmpty {
                VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                    ForEach(model.toolRuns) { run in
                        HStack(spacing: GrainSpacing.x2) {
                            Image(systemName: run.isError ? "xmark.circle" : (run.done ? "checkmark.circle" : "gearshape.2"))
                                .font(.system(size: 12))
                                .foregroundStyle(run.isError ? GrainColor.dangerRed : (run.done ? GrainColor.sage : GrainColor.textMuted))
                            Text(run.done ? "Ran \(run.name)" : "Running \(run.name)…")
                                .grainTextStyle(.caption)
                                .foregroundStyle(GrainColor.textMuted)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("tool-activity")
            }

            switch model.turnState {
            case .awaitingApproval(let callId, let name, let args):
                GrainCard(.filled) {
                    VStack(alignment: .leading, spacing: GrainSpacing.x3) {
                        // Show WHAT will run + its arguments — never ask for a blind approval.
                        Text("Run \(name)?")
                            .grainTextStyle(.body)
                            .foregroundStyle(GrainColor.ink)
                        if let preview = Self.argsPreview(args) {
                            Text(preview)
                                .grainTextStyle(.caption)
                                .foregroundStyle(GrainColor.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        // Honest delivery: while the answer is in flight the buttons become
                        // "Sending…"; the door's resumed stream then advances the turn and
                        // hides this card. A final failure restores the buttons + inline copy.
                        switch model.approvalDelivery {
                        case .sending:
                            HStack(spacing: GrainSpacing.x2) {
                                GrainSpinner(size: 16)
                                Text("Sending…")
                                    .grainTextStyle(.caption)
                                    .foregroundStyle(GrainColor.textMuted)
                            }
                        case .idle, .failed:
                            VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                                if case .failed = model.approvalDelivery {
                                    Text("Couldn’t send — try again")
                                        .grainTextStyle(.caption)
                                        .foregroundStyle(GrainColor.dangerRed)
                                }
                                // "Allow once" is the safe primary; "Reject" sits beside it.
                                HStack(spacing: GrainSpacing.x2) {
                                    GrainButton("Allow once", variant: .filled, size: .sm) { onApproveOnce(callId) }
                                        .accessibilityIdentifier("approval-once")
                                    GrainButton("Reject", variant: .outlined, size: .sm) { onReject(callId) }
                                }
                                // "Always allow" is the standing grant — spelled out so it's
                                // never a surprise which tool stops asking.
                                VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                                    GrainButton("Always allow", variant: .tonal, size: .sm) { onApproveAlways(callId) }
                                        .accessibilityIdentifier("approval-always")
                                    Text("Won’t ask again for \(name)")
                                        .grainTextStyle(.caption)
                                        .foregroundStyle(GrainColor.textMuted)
                                }
                            }
                        }
                    }
                }
                .accessibilityIdentifier("approval-prompt")
            case .completed(let reason):
                VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                    Text("done: \(reason)")
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
            case .failed(let reason):
                // The turn didn't send (transport / auth / no reply). Humane copy above a
                // one-tap retry chip that re-sends the same user text (raw detail is logged).
                VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                    Text(reason)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.dangerRed)
                        .fixedSize(horizontal: false, vertical: true)
                    GrainButton("Didn’t send — tap to retry", variant: .tonal, size: .sm) { onRetry() }
                        .accessibilityIdentifier("retry-turn")
                }
                .accessibilityIdentifier("turn-status")
            case .streaming:
                HStack(spacing: GrainSpacing.x2) {
                    GrainTypingIndicator()
                    // Before the first token, tick a SMOOTH local elapsed timer (every 0.5s)
                    // so it's visibly moving — qwen3's time-to-first-token can be many seconds,
                    // and the door's keepalive lands too sparsely to look alive on its own.
                    if model.assistantText.isEmpty, let started = model.turnStartedAt {
                        TimelineView(.periodic(from: started, by: 0.5)) { ctx in
                            Text("thinking… \(String(format: "%.1f", ctx.date.timeIntervalSince(started)))s")
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

    /// A compact, human-scannable preview of a tool's args for the approval prompt
    /// (nil when there's nothing meaningful to show).
    private static func argsPreview(_ args: String) -> String? {
        let t = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != "{}", t != "null" else { return nil }
        return t.count > 240 ? String(t.prefix(240)) + "…" : t
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
#endif
