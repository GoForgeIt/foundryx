// ActionOptionsSheet — what tapping an Actions-face row opens (track
// 20260715T1500 addendum): the three ways to act on a surfaced action.
//
//   • Act on it in chat — seeds the chat composer with the action's context
//     (the same template an accepted ambient card uses) and lands on the chat
//     tab; the row then reads Completed.
//   • Refine this action — a comment on what the action SHOULD be; persists as
//     `refined` feedback the action spotter learns from, shown on the row as
//     "Your note". The row's state is untouched.
//   • Not an action — rejects it (optional comment on why); persists as
//     `rejected` feedback and flips the row to "Not an action".
//
// Only rows the SPOTTER surfaced take reject/refine (they're its labeled
// training signal); every actionable row takes act-in-chat. All persistence is
// owned by the caller (ConversationFacesView) — this sheet is pure options UI.

import SwiftUI
import Grain

struct ActionOptionsSheet: View {
    let row: ConversationActionsPresentation.Row
    /// EXT2 — the action already has a live chat: route back to it. When
    /// installed, it REPLACES the fresh act-in-chat option.
    var onContinue: (() -> Void)? = nil
    /// Send the row's seed to chat. Installed only when the row has one.
    let onAct: (() -> Void)?
    /// Reject with an optional comment (surfaced rows only).
    let onReject: ((String) -> Void)?
    /// Refine with a comment (surfaced rows only).
    let onRefine: ((String) -> Void)?
    /// Promote a "Heard from others" action into the main list. Installed only
    /// when the row was opened from that group.
    var onPromote: (() -> Void)? = nil

    private enum Mode { case options, reject, refine }
    @State private var mode: Mode = .options
    @State private var comment = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x4) {
            header
            switch mode {
            case .options: options
            case .reject: commentEntry(
                prompt: "Why isn't this an action? A note helps Intelligent Action learn — or skip it.",
                confirmLabel: "Mark as not an action",
                allowsEmpty: true) { onReject?($0) }
            case .refine: commentEntry(
                prompt: "What should this action be? Your note helps Intelligent Action learn.",
                confirmLabel: "Save note",
                allowsEmpty: false) { onRefine?($0) }
            }
            Spacer(minLength: 0)
        }
        .padding(GrainSpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .grainBackground()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            Text(row.label)
                .grainTextStyle(.body)
                .fontWeight(.semibold)
                .foregroundStyle(GrainColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let attribution = row.attribution {
                Text(attribution.displayText)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.forgeBlue)
            }
            if let meta = row.meta, !meta.isEmpty {
                Text(meta)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var options: some View {
        VStack(spacing: GrainSpacing.x2) {
            // Nothing offerable (a hand-added action on a phone tier whose chat
            // can't compose) — say so honestly instead of a dead, empty sheet.
            if onContinue == nil && onAct == nil && onReject == nil && onRefine == nil
                && onPromote == nil {
                Text("Nothing to do here yet — chat isn't available on this phone.")
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if onContinue != nil {
                GrainButton("Continue in chat →", variant: .filled, size: .regular) {
                    onContinue?()
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("continue-in-chat")
            }
            if onAct != nil {
                GrainButton("Act on it in chat", variant: .filled, size: .regular) {
                    onAct?()
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("act-in-chat")
            }
            if onPromote != nil {
                // A "Heard from others" action the user claims as their own.
                GrainButton("Move to my actions", variant: .outlined, size: .regular) {
                    onPromote?()
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("promote-action")
            }
            if onRefine != nil {
                GrainButton("Refine this action", variant: .outlined, size: .regular) {
                    mode = .refine
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("refine-action")
            }
            if onReject != nil {
                GrainButton("Not an action", variant: .outlined, size: .regular) {
                    mode = .reject
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("not-an-action")
            }
        }
    }

    /// The comment step shared by reject (optional comment) and refine
    /// (required comment): a prompt, a field, confirm + back.
    private func commentEntry(prompt: String, confirmLabel: String,
                              allowsEmpty: Bool,
                              commit: @escaping (String) -> Void) -> some View {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: GrainSpacing.x3) {
            Text(prompt)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Add a comment", text: $comment, axis: .vertical)
                .textFieldStyle(.plain)
                .grainTextStyle(.body)
                .foregroundStyle(GrainColor.ink)
                .lineLimit(2...5)
                .padding(GrainSpacing.x3)
                .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                    .fill(GrainColor.surface))
                .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                    .strokeBorder(GrainColor.border, lineWidth: 1))
                .accessibilityIdentifier("feedback-comment")
            HStack(spacing: GrainSpacing.x2) {
                GrainButton("Back", variant: .outlined, size: .regular) {
                    mode = .options
                }
                GrainButton(confirmLabel, variant: .filled, size: .regular) {
                    commit(trimmed)
                    dismiss()
                }
                .disabled(!allowsEmpty && trimmed.isEmpty)
                .accessibilityIdentifier("confirm-feedback")
            }
        }
    }
}
