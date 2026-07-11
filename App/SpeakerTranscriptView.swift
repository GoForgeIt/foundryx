// SpeakerTranscriptView — the conversation-detail UI for Lore's speaker-diarized
// transcripts (track: diarized_speakers_backend, Lore 0.5.53). Renders the transcript
// as colour-coded SPEAKER TURNS and lets the user tag / confirm / correct each speaker.
//
// Identity states (FoundryXKit.SpeakerStatus), each rendered distinctly:
//   • confirmed — solid: the name + the speaker's colour.
//   • inferred  — ghosted/tentative: a confidence hint + an inline "Confirm: <name>?"
//                 (confirm / not them). The match does NOT propagate until confirmed.
//   • anonymous — "Speaker N", tappable to name.
//
// Tapping a speaker opens SpeakerTagSheet (confirm / rename / assign / new speaker). On
// confirm the backend's "apply to N past conversations?" offer is surfaced — offered,
// never auto-applied.
//
// Pure grouping/model lives in FoundryXKit.SpeakerTranscript; this file is presentation
// + the confirm/correct calls through DoorClient.

import SwiftUI
import AVFoundation
import Grain

// MARK: - Speaker palette

/// A stable, visually-distinct colour per speaker SLOT. The slot's `colorIndex` (its
/// first-appearance order) maps onto this palette so a speaker looks the same in every
/// turn. Cycles if a conversation somehow has more speakers than palette entries.
enum SpeakerPalette {
    /// (accent, tint-background) pairs — the Grain accent colours, ordered for contrast
    /// between adjacent speakers.
    static let entries: [(accent: Color, tint: Color)] = [
        (GrainColor.forgeBlue, GrainColor.forgeBlueBg),
        (GrainColor.sage, GrainColor.sageBg),
        (GrainColor.amber, GrainColor.amberBg),
        (GrainColor.agentOrchestrator, GrainColor.agentOrchestratorBg),   // lavender
        (GrainColor.agentSpecialist, GrainColor.agentSpecialistBg),        // pink
        (GrainColor.agentWorker, GrainColor.agentWorkerBg),                // mint
        (GrainColor.dangerRed, GrainColor.dangerRedBg),
    ]

    static func accent(_ index: Int) -> Color { entries[index % entries.count].accent }
    static func tint(_ index: Int) -> Color { entries[index % entries.count].tint }
}

// MARK: - Transcript section (speaker turns)

/// The diarized transcript: a stack of speaker turns. Each turn shows its speaker label
/// (colour-coded) and, for an inferred speaker, an inline confirm affordance. Tapping a
/// speaker opens the tag/confirm/correct sheet.
struct SpeakerTranscriptSection: View {
    let target: DoorTarget
    let captureId: String
    let transcript: SpeakerTranscript
    /// Called after a successful confirm/correct so the detail view re-fetches content.
    let onChanged: () async -> Void

    @State private var tagging: CaptureSpeaker?

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x4) {
            if transcript.hasUnconfirmedInferred {
                ReviewSpeakersBanner(count: transcript.inferredSlots.count) {
                    // Jump straight into the first tentative speaker to review it.
                    if let slot = transcript.inferredSlots.first {
                        tagging = transcript.speaker(for: slot)
                    }
                }
            }
            ForEach(transcript.turns) { turn in
                SpeakerTurnRow(
                    turn: turn,
                    transcript: transcript,
                    onTapSpeaker: { tagging = transcript.speaker(for: turn.slot) },
                    onConfirmInferred: { await confirmInferred(slot: turn.slot) }
                )
            }
        }
        .sheet(item: $tagging) { speaker in
            SpeakerTagSheet(
                target: target,
                captureId: captureId,
                speaker: speaker,
                displayLabel: transcript.displayLabel(for: speaker.slot),
                sampleWindow: transcript.voiceSampleWindow(for: speaker.slot),
                onChanged: { await onChanged() }
            )
        }
    }

    /// Bare confirm of an inferred match (the inline "Confirm" affordance) — confirms
    /// the slot's existing inferred speaker without renaming.
    private func confirmInferred(slot: String) async {
        _ = try? await DoorClient(target: target).confirmSpeaker(captureId: captureId, slot: slot)
        await onChanged()
    }
}

/// One speaker turn: a colour-coded label header + the turn's text. Inferred speakers
/// render ghosted with a confidence hint and an inline confirm / not-them affordance.
struct SpeakerTurnRow: View {
    let turn: SpeakerTurn
    let transcript: SpeakerTranscript
    let onTapSpeaker: () -> Void
    let onConfirmInferred: () async -> Void

    private var speaker: CaptureSpeaker { transcript.speaker(for: turn.slot) }
    private var accent: Color { SpeakerPalette.accent(transcript.colorIndex(for: turn.slot)) }
    private var tint: Color { SpeakerPalette.tint(transcript.colorIndex(for: turn.slot)) }
    private var label: String { transcript.displayLabel(for: turn.slot) }

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            // Speaker label — tappable to open the tag/confirm sheet.
            Button(action: onTapSpeaker) {
                HStack(spacing: GrainSpacing.x2) {
                    Circle().fill(accent).frame(width: 10, height: 10)
                    Text(label)
                        .grainTextStyle(.caption)
                        .foregroundStyle(speaker.isAnonymous ? GrainColor.textMuted : accent)
                        .fontWeight(.semibold)
                    if speaker.isInferred {
                        Text(tentativeHint)
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textFaint)
                            .italic()
                    } else if speaker.isAnonymous {
                        Image(systemName: "pencil.circle")
                            .font(.caption)
                            .foregroundStyle(GrainColor.textFaint)
                    }
                }
            }
            .buttonStyle(.plain)

            // Turn text — ghosted while the speaker is only a tentative (inferred) match.
            Text(turn.text)
                .grainTextStyle(.body)
                .foregroundStyle(GrainColor.ink)
                .opacity(speaker.isInferred ? 0.6 : 1.0)
                .textSelection(.enabled)
                .padding(.leading, GrainSpacing.x4)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: GrainRadius.pill)
                        .fill(accent.opacity(speaker.isConfirmed ? 0.9 : 0.4))
                        .frame(width: 3)
                }

            // Inline confirm affordance for an inferred match — confirm or "not them".
            if speaker.isInferred, let name = speaker.name {
                HStack(spacing: GrainSpacing.x2) {
                    GrainButton("Confirm: \(name)", variant: .tonal, size: .sm) {
                        Task { await onConfirmInferred() }
                    }
                    GrainButton("Not them", variant: .text, size: .sm, action: onTapSpeaker)
                }
                .padding(.leading, GrainSpacing.x4)
            }
        }
        .padding(GrainSpacing.x3)
        .background(
            RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                .fill(tint.opacity(0.5))
        )
    }

    /// "tentative · 82%" — the inferred-match confidence hint.
    private var tentativeHint: String {
        if let score = speaker.inferScore {
            return "tentative · \(Int((score * 100).rounded()))%"
        }
        return "tentative"
    }
}

/// A lightweight "review speakers" entry shown when a conversation has unconfirmed
/// inferred (tentative) speakers — the backfilled-inference review affordance. The
/// richer review queue lives in Lore web; on the phone this is the in-context nudge.
struct ReviewSpeakersBanner: View {
    let count: Int
    let onReview: () -> Void

    var body: some View {
        Button(action: onReview) {
            HStack(spacing: GrainSpacing.x2) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(GrainColor.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 1 ? "1 speaker to review" : "\(count) speakers to review")
                        .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                    Text("Confirm or correct the tentative matches.")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(GrainColor.textFaint)
            }
            .padding(GrainSpacing.x3)
            .background(
                RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                    .fill(GrainColor.amberBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                    .strokeBorder(GrainColor.amberBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tag / confirm / correct sheet

/// Tag / confirm / correct a speaker slot. The flows (all through Lore's confirm state
/// machine via the door):
///   • Confirm <name>   — bare confirm of an inferred match (enables recognition).
///   • Name / rename     — confirm for a typed name; an existing name MERGES (assign to
///                          existing), a new name CREATES the speaker.
/// On confirm the backend's `offeredCaptures` ("apply to N past conversations?") is
/// surfaced; applying loops the confirm over the offered captures (never auto-applied).
struct SpeakerTagSheet: View {
    let target: DoorTarget
    let captureId: String
    let speaker: CaptureSpeaker
    let displayLabel: String
    /// The ms window of this speaker's longest utterance ("Hear this voice" plays
    /// it so the user can recognize the person before naming them). `nil` when the
    /// slot has no timestamped segments — then no playback control is shown.
    var sampleWindow: (startMs: Int, endMs: Int)? = nil
    let onChanged: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var busy = false
    @State private var error: String?
    @State private var offer: ConfirmOutcome?
    @State private var applied = false

    /// Voice-sample playback: idle → loading → playing; unavailable when the door
    /// 404s (audio pruned) or the bytes don't decode. Sheet-local — closing stops it.
    private enum SampleState: Equatable { case idle, loading, playing, unavailable, failed }
    @State private var sampleState: SampleState = .idle
    @State private var samplePlayer: AVAudioPlayer?

    var body: some View {
        GrainSheetContainer(title: "Tag speaker", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                if let offer, !offer.offeredCaptures.isEmpty, !applied {
                    offerSection(offer)
                } else if applied {
                    appliedSection
                } else {
                    editSection
                }
                if let error {
                    Text(error).grainTextStyle(.caption).foregroundStyle(GrainColor.dangerRed)
                }
            }
            .padding(GrainSpacing.x4)
        }
        .onAppear { name = speaker.name ?? "" }
        .onDisappear {
            samplePlayer?.stop()
            samplePlayer = nil
        }
    }

    // The main edit surface: confirm an inferred match and/or name the speaker.
    @ViewBuilder private var editSection: some View {
        Text(displayLabel).grainTextStyle(.title).foregroundStyle(GrainColor.ink)

        // Hear the voice you're about to name — plays this speaker's longest
        // utterance. Only offered when the slot has timestamped segments.
        if sampleWindow != nil {
            voiceSampleRow
        }

        if speaker.isInferred, let inferred = speaker.name {
            Text(scoreCaption(inferred))
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            GrainButton("Confirm \(inferred)", variant: .filled, size: .regular) {
                Task { await confirm(name: nil) }   // bare confirm of the inferred match
            }
            .disabled(busy)
            Divider().background(GrainColor.borderHairline)
            Text("Not them? Name this speaker instead:")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        } else if speaker.isAnonymous {
            Text("This voice isn't named yet. Who is it?")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        } else {
            Text("Rename or reassign this speaker.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        }

        GrainTextField("Name", text: $name, label: "Speaker name")
        Text("Type a new name to create a person, or an existing person's name to assign this voice to them.")
            .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)

        GrainButton(saveTitle, variant: .filled, size: .regular) {
            Task { await confirm(name: name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var saveTitle: String { speaker.isConfirmed ? "Save changes" : "Save name" }

    // ── "Hear this voice" ────────────────────────────────────────────────────

    @ViewBuilder private var voiceSampleRow: some View {
        switch sampleState {
        case .idle, .playing:
            GrainButton(
                sampleState == .playing ? "Stop" : "▶ Hear this voice",
                variant: .outlined, size: .regular
            ) {
                if sampleState == .playing {
                    samplePlayer?.stop()
                    samplePlayer = nil
                    sampleState = .idle
                } else {
                    Task { await playVoiceSample() }
                }
            }
        case .loading:
            HStack(spacing: GrainSpacing.x2) {
                ProgressView().controlSize(.small)
                Text("Fetching voice sample…")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            }
        case .unavailable:
            Text("Voice sample unavailable (audio no longer on the desktop).")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        case .failed:
            Text("Couldn't play the voice sample.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        }
    }

    /// Fetch the speaker's sample window from the door (a few seconds of Ogg-Opus,
    /// sliced desktop-side) and play it. 404 → unavailable (pruned audio); a decode
    /// failure → failed. The sheet stays fully usable for naming either way.
    private func playVoiceSample() async {
        guard let window = sampleWindow else { return }
        sampleState = .loading
        do {
            guard let data = try await DoorClient(target: target).captureAudio(
                captureId: captureId, startMs: window.startMs, endMs: window.endMs)
            else {
                sampleState = .unavailable
                return
            }
            let player = try AVAudioPlayer(data: data)
            player.play()
            samplePlayer = player
            sampleState = .playing
            // Flip back to idle when the clip ends (poll the player — no delegate
            // plumbing needed for a few-second sample).
            let clipSeconds = player.duration
            Task {
                try? await Task.sleep(nanoseconds: UInt64((clipSeconds + 0.3) * 1_000_000_000))
                if samplePlayer === player, player.isPlaying == false {
                    sampleState = .idle
                    samplePlayer = nil
                }
            }
        } catch {
            sampleState = .failed
        }
    }

    // After a confirm that matched PAST captures — offer to apply, never auto-applied.
    @ViewBuilder private func offerSection(_ outcome: ConfirmOutcome) -> some View {
        Text("Confirmed \(outcome.speakerName)")
            .grainTextStyle(.title).foregroundStyle(GrainColor.ink)
        let n = outcome.offeredCaptures.count
        Text("This voice also matches \(n) past \(n == 1 ? "conversation" : "conversations"). Apply \(outcome.speakerName) to \(n == 1 ? "it" : "them")?")
            .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
        HStack(spacing: GrainSpacing.x2) {
            GrainButton("Apply to \(n)", variant: .filled, size: .regular) {
                Task { await applyOffer(outcome) }
            }.disabled(busy)
            GrainButton("Not now", variant: .text, size: .regular) { dismiss() }
        }
    }

    @ViewBuilder private var appliedSection: some View {
        Text("Applied").grainTextStyle(.title).foregroundStyle(GrainColor.ink)
        Text("Updated the matching past conversations.")
            .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
        GrainButton("Done", variant: .filled, size: .regular) { dismiss() }
    }

    private func scoreCaption(_ inferred: String) -> String {
        if let s = speaker.inferScore {
            return "Tentatively matched to \(inferred) (\(Int((s * 100).rounded()))% confidence). Confirm to enable future recognition."
        }
        return "Tentatively matched to \(inferred). Confirm to enable future recognition."
    }

    /// Confirm/correct: `name == nil` is a bare confirm of the inferred match; a
    /// non-empty name confirms for that name (merge-or-create).
    private func confirm(name: String?) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let outcome = try await DoorClient(target: target)
                .confirmSpeaker(captureId: captureId, slot: speaker.slot, name: name)
            await onChanged()
            if outcome.offeredCaptures.isEmpty {
                dismiss()
            } else {
                offer = outcome   // surface the apply-to-past-conversations offer
            }
        } catch {
            self.error = (error as NSError).localizedDescription
        }
    }

    /// Apply the confirmed speaker to the offered past captures (looped confirm by
    /// speakerId — the assign-to-existing path).
    private func applyOffer(_ outcome: ConfirmOutcome) async {
        busy = true; error = nil
        defer { busy = false }
        let client = DoorClient(target: target)
        for offered in outcome.offeredCaptures {
            _ = try? await client.confirmSpeaker(
                captureId: offered.captureId, slot: offered.slotLabel,
                speakerId: outcome.speakerId)
        }
        await onChanged()
        applied = true
    }
}
