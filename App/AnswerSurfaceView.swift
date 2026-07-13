// AnswerSurfaceView — the ambient-answer surface (track 20260713T0906 AC1,
// fullflow v8 "answer" scene). An ambient lookup's answer opens here: the answer
// text, the SOURCES CONSULTED chips (the user's own conversations — never
// "citations"), small Helpful/Not-useful toggles that start UNSELECTED, a
// free-text note, and "Continue in Chat" which seeds a FRESH session with the
// answer through the same AmbientCardBroker route accepted ambient cards use
// (ChatScreen already consumes the seed and sends it as the first turn).
//
// ENTRY POINT (for the ambient-cards track — AmbientCards.swift is not edited
// here): present `AnswerSurfaceView(answer:onDone:)` when a lookup notification
// carrying an answer is tapped. Feedback outcomes append to
// ambient-answers.jsonl (the council's rating signal).

import SwiftUI
import Grain
// (FoundryXKit types are same-module — the App target compiles Sources/FoundryXKit directly)

struct AnswerSurfaceView: View {
    let answer: AmbientAnswer
    /// Called when the surface is finished (Done or after Continue in Chat).
    var onDone: () -> Void = {}
    /// Injectable seed route (previews/tests). Default: the ambient-card broker —
    /// navigates to the chat tab and starts a seeded session.
    var onContinueInChat: ((String) -> Void)?

    @State private var feedback = AnswerFeedback()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                header
                answerCard
                feedbackRow
                GrainTextField(AnswerCopy.notePlaceholder, text: $feedback.note)
                    .accessibilityIdentifier("answer-note")
                GrainButton(AnswerCopy.continueInChat, variant: .filled) {
                    continueInChat()
                }
                .accessibilityIdentifier("answer-continue-in-chat")
                GrainButton(AnswerCopy.done, variant: .ghost) { finish() }
                    .accessibilityIdentifier("answer-done")
            }
            .padding(GrainSpacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .grainBackground()
    }

    // MARK: pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            HStack(spacing: GrainSpacing.x1) {
                Image(grain: .spark)
                    .font(.system(size: 11))
                Text(AnswerCopy.kicker.uppercased())
            }
            .grainTextStyle(.caption)
            .foregroundStyle(GrainColor.amber)
            Text(answer.title)
                .grainTextStyle(.title)
                .foregroundStyle(GrainColor.ink)
        }
    }

    private var answerCard: some View {
        GrainCard(.filled) {
            VStack(alignment: .leading, spacing: GrainSpacing.x3) {
                Text(answer.text)
                    .grainTextStyle(.body)
                    .foregroundStyle(GrainColor.textMain)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("answer-text")
                if !answer.sources.isEmpty {
                    VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                        Text(AnswerCopy.sourcesLabel.uppercased())
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textFaint)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: GrainSpacing.x2) {
                                ForEach(answer.sources) { source in
                                    GrainChip(source.chipText, variant: .amber)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("answer-sources")
                }
            }
        }
    }

    /// Small toggles, UNSELECTED by default — the system never rates itself.
    private var feedbackRow: some View {
        HStack(spacing: GrainSpacing.x2) {
            ratingToggle(AnswerCopy.helpful, .helpful, id: "answer-helpful")
            ratingToggle(AnswerCopy.notUseful, .notUseful, id: "answer-not-useful")
            Text("· \(AnswerCopy.feedbackHint)")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)
            Spacer(minLength: 0)
        }
    }

    private func ratingToggle(_ label: String, _ value: AnswerRating, id: String) -> some View {
        let selected = feedback.rating == value
        return Button {
            feedback.toggle(value)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? GrainColor.forgeBlue : GrainColor.textMuted)
                .padding(.horizontal, GrainSpacing.x3)
                .padding(.vertical, GrainSpacing.x1)
                .background(Capsule().fill(selected ? GrainColor.forgeBlueBg : Color.clear))
                .overlay(Capsule().strokeBorder(
                    selected ? GrainColor.forgeBlueBorder : GrainColor.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: actions

    private func continueInChat() {
        logFeedback(outcome: "continue-in-chat")
        let seed = answer.chatSeed(note: feedback.note)
        if let onContinueInChat {
            onContinueInChat(seed)
        } else {
            AmbientCardBroker.shared.run(seed: seed)
        }
        onDone()
    }

    private func finish() {
        logFeedback(outcome: "done")
        onDone()
    }

    /// One JSONL line per answer with any feedback content — the council's
    /// rating signal ("tunes when it speaks up"). Same append pattern as
    /// ambient-cards.jsonl.
    private func logFeedback(outcome: String) {
        guard feedback.hasContent else { return }
        let url = CaptureWAL.documentsCaptures().appendingPathComponent("ambient-answers.jsonl")
        let line = (try? JSONSerialization.data(withJSONObject: [
            "ts": Int(Date().timeIntervalSince1970),
            "outcome": outcome,
            "rating": feedback.rating.rawValue,
            "note": String(feedback.note.prefix(300)),
            "answer_title": String(answer.title.prefix(120)),
        ])) ?? Data()
        guard !line.isEmpty else { return }
        var out = line
        out.append(UInt8(ascii: "\n"))
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: out)
        } else {
            try? out.write(to: url)
        }
    }
}
