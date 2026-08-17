// OnboardingEndingViews — the three steps that replaced the dead end.
//
// The flow used to stop on the ambient CONSENT step and drop the user on an empty
// library (Nick, 2026-07-28: "it doesn't point me toward how to get started… As a user I
// feel stuck like I don't know what to do next"). It now ends on a win, a demonstration,
// and an honest choice:
//
//   firstNote    make a real voice note, words appearing while you speak
//   askIt        ask a question about what you just said, answered on this phone
//   destination  what changes if your notes live somewhere bigger
//
// The order is the design. Having just FELT "ask about this note", the user meets "ask
// across everything you've ever said" as the same gesture made larger — not as a feature
// list. That ordering is enforced by OnboardingFlowPlan and asserted in
// features/onboarding-first-note-and-destination.feature; it is not decoration.
//
// The steps drive the REAL capture path (`CaptureManager.startMicRecording`), so the
// first note is an actual note in the actual library — not a simulation that leaves the
// user with nothing after onboarding closes.

import SwiftUI
import Grain
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - The on-device answerer

#if canImport(FoundationModels)
/// Answers a question about ONE note using Apple Foundation Models. Same posture as
/// `FoundationModelsTitler`: behind the shared wedge breaker, hard-bounded in time, and
/// content-free in telemetry.
@available(iOS 26.0, macOS 26.0, *)
struct SystemNoteAnswerer: NoteAnswering {
    func answer(question: String, aboutNote transcript: String) async throws -> String {
        let bounded = String(transcript.prefix(6_000))
        return try await withPerfTimeout("fm-note-answer", ms: 20_000) {
            let session = LanguageModelSession()
            let prompt = """
            Answer the question using ONLY the voice note below. If the note does not \
            contain the answer, say so plainly in one sentence. Reply with ONLY the \
            answer, in one or two sentences.

            Voice note:
            \(bounded)

            Question: \(question)
            """
            return try await session.respond(to: prompt)
                .content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
#endif

/// The system answerer where the OS has Foundation Models, else nil — the ask-it step
/// then skips itself rather than showing a broken demonstration on hardware that cannot
/// deliver it.
func makeSystemNoteAnswerer() -> NoteAnswering? {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) { return SystemNoteAnswerer() }
    #endif
    return nil
}

// MARK: - Step 4: make your first voice note

struct OnboardingFirstNoteStep: View {
    @ObservedObject var manager: CaptureManager
    /// The fast-moving live surface (transcript). Observed directly rather than through
    /// the manager so the several-times-a-second publishes reach this view without
    /// invalidating anything behind it — same reasoning as `RecordingScreen`.
    @ObservedObject var live: CaptureManager.LiveCaptureModel
    /// Hands the finished note's text forward so the next step can ask about it.
    let onNext: (String) -> Void
    let onSkip: () -> Void

    private enum Phase: Equatable { case intro, recording, done }
    @State private var phase: Phase = .intro
    @State private var captured = ""

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x4) {
            Text("Make your first voice note")
                .grainTextStyle(.title).foregroundStyle(GrainColor.ink)
            Text("Say whatever's on your mind — a plan, a reminder, a thought you don't want to lose. About fifteen seconds is plenty.")
                .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)

            switch phase {
            case .intro:
                Spacer()
                GrainButton("Start my first note", variant: .filled, size: .regular) { start() }

            case .recording:
                // The words appear as they are spoken. This is the whole point of the
                // step: proof the thing works, before anything is asked of the user.
                ScrollView {
                    Text(live.transcript.displayText.isEmpty
                         ? "Listening…"
                         : live.transcript.displayText)
                        .grainTextStyle(.body)
                        .foregroundStyle(live.transcript.isEmpty ? GrainColor.textFaint : GrainColor.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(GrainSpacing.x4)
                .background(RoundedRectangle(cornerRadius: GrainRadius.card, style: .continuous).fill(GrainColor.forgeBlueBg))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("live-transcript")

                Spacer()
                GrainButton("That's it", variant: .filled, size: .regular) { stop() }

            case .done:
                Label("Saved to your notes", systemImage: "checkmark.circle.fill")
                    .grainTextStyle(.body).foregroundStyle(GrainColor.sage)
                if !captured.isEmpty {
                    Text(captured)
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                        .lineLimit(4)
                        .padding(GrainSpacing.x4)
                        .background(RoundedRectangle(cornerRadius: GrainRadius.card, style: .continuous).fill(GrainColor.forgeBlueBg))
                }
                Spacer()
                GrainButton("Next", variant: .filled, size: .regular) { onNext(captured) }
            }

            if phase != .done {
                GrainButton("Skip for now", variant: .text, size: .regular) {
                    if phase == .recording { manager.stopMicRecording() }
                    onSkip()
                }
                .padding(.bottom, GrainSpacing.x4)
            }
        }
        // Hold the screen for the WHOLE step, not just at start: the manager clears
        // `recordingScreenMinimized` again when the session actually establishes, so a
        // one-shot minimize gets overridden a beat later and the library's recorder
        // slams up over this flow.
        .onAppear { manager.suppressesRecordingSurface = true }
        .onDisappear {
            if phase == .recording { manager.stopMicRecording() }
            manager.suppressesRecordingSurface = false   // hand the screen back
        }
    }

    private func start() {
        phase = .recording
        manager.startMicRecording()
        // Belt and braces with the `suppressesRecordingSurface` hold above: minimize
        // covers the instant between start and the next render.
        manager.minimizeRecordingScreen()
    }

    private func stop() {
        // Snapshot BEFORE stopping: finalize tears the live surface down, and the next
        // step needs these words to have something to answer from.
        captured = live.transcript.displayText
        manager.stopMicRecording()
        phase = .done
    }
}

// MARK: - Step 5: ask it something

struct OnboardingAskItStep: View {
    /// What the user just said. Empty ⇒ they skipped the note, and this step has nothing
    /// to demonstrate.
    let noteText: String
    let answerer: NoteAnswering?
    let onNext: () -> Void

    @State private var question = ""
    @State private var answer: String?
    @State private var asking = false
    @State private var failed = false

    /// Openers that work against almost any note, so the user never faces a blank box.
    private var suggestions: [String] {
        ["What did I say I needed to do?",
         "What was that about?",
         "Did I mention a date?"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x4) {
            Text("Now ask it something")
                .grainTextStyle(.title).foregroundStyle(GrainColor.ink)
            Text("Your notes aren't just audio — you can talk to them. This answer comes from the model on your phone. Nothing leaves the device.")
                .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)

            if answer == nil && !asking {
                VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                    ForEach(suggestions, id: \.self) { s in
                        Button { ask(s) } label: {
                            HStack {
                                Text(s).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .foregroundStyle(GrainColor.forgeBlue)
                            }
                            .padding(GrainSpacing.x3)
                            .background(RoundedRectangle(cornerRadius: GrainRadius.control, style: .continuous).fill(GrainColor.forgeBlueBg))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .accessibilityIdentifier("ask-it-suggestions")
            }

            if asking {
                HStack(spacing: GrainSpacing.x2) {
                    ProgressView()
                    Text("Thinking on your phone…")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                }
            }

            if let answer {
                VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                    Text(question).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                    Text(answer).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                }
                .padding(GrainSpacing.x4)
                .background(RoundedRectangle(cornerRadius: GrainRadius.card, style: .continuous).fill(GrainColor.forgeBlueBg))
                .accessibilityIdentifier("ask-it-answer")
            }

            if failed {
                Text("This phone can't answer on its own yet — that's what a Vault is for. Keep going.")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            }

            Spacer()
            GrainButton(answer == nil && !failed ? "Skip" : "Next",
                        variant: answer == nil && !failed ? .outlined : .filled,
                        size: .regular) { onNext() }
                .padding(.bottom, GrainSpacing.x4)
        }
        .onAppear {
            // Nothing was recorded (or the OS has no on-device model) — there is no
            // demonstration to give, so don't stage a fake one.
            if noteText.isEmpty || answerer == nil { failed = true }
        }
    }

    private func ask(_ q: String) {
        guard let answerer, !noteText.isEmpty else { failed = true; return }
        question = q
        asking = true
        Task {
            defer { asking = false }
            do {
                let text = try await answerer.answer(question: q, aboutNote: noteText)
                await MainActor.run { answer = text }
            } catch {
                await MainActor.run { failed = true }
            }
        }
    }
}

// MARK: - Step 6: where your notes live

struct OnboardingDestinationStep: View {
    /// The REAL account-scoped brain preference. The destination choice IS `BrainChoice`
    /// — an earlier draft introduced a parallel `foundryx.note-destination` key and the
    /// account-preference source guard rejected it, correctly: a second preference for
    /// the same decision drifts, and an undeclared one leaks across accounts.
    @ObservedObject var brains: BrainStore
    /// Chose the Vault — the caller hands off to the Vault funnel (cell provisioning)
    /// rather than closing the flow.
    let onChooseVault: () -> Void
    /// Chose to stay local; the flow is finished.
    let onFinish: (BrainChoice) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                Text("Where your notes live")
                    .grainTextStyle(.title).foregroundStyle(GrainColor.ink)
                Text("You just asked a question about one note. Here's what changes if your notes live somewhere bigger.")
                    .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)

                // The comparison. Both columns are always answered — staying on the
                // phone is a real destination, not a deficiency (TierComparison.isHonest
                // is asserted by the feature).
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: GrainSpacing.x3) {
                        Text("On this phone")
                            .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("With your Vault")
                            .grainTextStyle(.caption).foregroundStyle(GrainColor.forgeBlue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.bottom, GrainSpacing.x2)

                    ForEach(Array(TierComparison.points.enumerated()), id: \.offset) { i, point in
                        HStack(alignment: .top, spacing: GrainSpacing.x3) {
                            Text(point.onThisPhone)
                                .grainTextStyle(i == 0 ? .body : .caption)
                                .foregroundStyle(i == 0 ? GrainColor.ink : GrainColor.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(point.withYourVault)
                                .grainTextStyle(i == 0 ? .body : .caption)
                                .foregroundStyle(i == 0 ? GrainColor.ink : GrainColor.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, GrainSpacing.x2)
                        if i < TierComparison.points.count - 1 {
                            Divider().overlay(GrainColor.hairline)
                        }
                    }
                }
                .padding(GrainSpacing.x4)
                .background(RoundedRectangle(cornerRadius: GrainRadius.card, style: .continuous).fill(GrainColor.forgeBlueBg))
                // `.contain` (not `.combine`) so the container is addressable by
                // identifier while every cell stays individually queryable — a bare
                // identifier on a stack surfaces as nothing at all.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("tier-comparison")

                // ONE alignment. This stack used to declare none, and a VStack with no
                // alignment centres its children — so three GrainButtons of three
                // different widths (GrainButtonStyle sets a height and horizontal padding
                // but never maxWidth, so each hugs its title) ended up centred relative to
                // each other inside a box that shrink-wrapped to the longest label and was
                // itself pinned to the leading edge. Nick: "centered in a left aligned
                // box". The screen is `.leading` throughout — title, blurb, comparison —
                // so the buttons are too, and the stack spans the column so a button's
                // leading edge lands on the same left edge as the title rather than on the
                // edge of the shrink-wrapped box.
                VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                    GrainButton(BrainChoice.foundryCloud.destinationLabel,
                                variant: .filled, size: .regular) {
                        brains.select(.foundryCloud)
                        onChooseVault()
                    }
                    GrainButton(BrainChoice.justMyPhone.destinationLabel,
                                variant: .outlined, size: .regular) {
                        brains.select(.justMyPhone)
                        onFinish(.justMyPhone)
                    }
                    GrainButton(BrainChoice.myComputer.destinationLabel,
                                variant: .text, size: .regular) {
                        brains.select(.myComputer)
                        onFinish(.myComputer)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, GrainSpacing.x4)
            }
        }
    }
}
