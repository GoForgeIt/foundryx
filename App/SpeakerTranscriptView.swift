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
    /// Optimistic hook: fired the instant the door acknowledges a confirm so the detail
    /// can flip the in-memory speaker for that slot before the authoritative re-fetch.
    var onConfirmed: (ConfirmOutcome) -> Void = { _ in }
    /// Transcript-search highlights (track 20260713T0904): matches whose `row`
    /// indexes `transcript.turns`. Empty = no search active — the defaults keep
    /// every existing call site (and its behavior) unchanged.
    var searchMatches: [TranscriptMatch] = []
    /// The match the search cursor is on — emphasized stronger than the rest.
    var currentMatch: TranscriptMatch? = nil
    /// True while a recording is active — the tag sheet disables voice-sample playback.
    var isRecording: Bool = false

    /// Per-slot confirm phases — the tap-to-outcome state machine every inline
    /// "Confirm: <name>" affordance renders (in-flight / confirmed / failed).
    /// OWNED BY THE PARENT detail (not this view): the detail swaps between this
    /// section and the Grain rows on search-toggle, and an in-flight/failed phase
    /// must survive that swap (adversarial review P2/#4).
    @ObservedObject var confirmController: SpeakerConfirmController

    /// Per-conversation sync state — drives the subtle pending glyph + revert notices
    /// (local-first track 20260717T1600). Owned by the parent detail.
    @ObservedObject var syncModel: SpeakerSyncModel

    /// True while THIS surface's tag sheet is presenting — the parent reads it so a late
    /// propagation-offer banner doesn't double-surface an offer the sheet already owns
    /// (review P2#2). Owned by the parent so it survives the search-toggle surface swap.
    @Binding var sheetPresenting: Bool

    @State private var tagging: SpeakerTagTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if transcript.hasUnconfirmedInferred {
                ReviewSpeakersBanner(count: transcript.inferredSlots.count) {
                    // Jump straight into the first tentative speaker to review it. No
                    // specific turn was tapped ⇒ the sheet uses the slot's representative
                    // (longest) sample.
                    if let slot = transcript.inferredSlots.first {
                        tagging = SpeakerTagTarget(speaker: transcript.speaker(for: slot))
                    }
                }
                .padding(.bottom, GrainSpacing.x3)
            }
            Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
            ForEach(Array(transcript.turns.enumerated()), id: \.element.id) { index, turn in
                SpeakerTurnRow(
                    turn: turn,
                    transcript: transcript,
                    // Play the TAPPED turn's own clip (the selected piece), not the
                    // slot's longest utterance elsewhere in the conversation.
                    onTapSpeaker: {
                        tagging = SpeakerTagTarget(
                            speaker: transcript.speaker(for: turn.slot),
                            sampleWindow: transcript.voiceSampleWindow(forTurn: turn))
                    },
                    onConfirmInferred: { await confirmInferred(slot: turn.slot) },
                    confirmPhase: confirmController.phase(for: turn.slot),
                    isPendingSync: syncModel.isPending(turn.slot),
                    revertNotice: syncModel.notices[turn.slot],
                    highlightRanges: searchMatches.filter { $0.row == index }.map(\.range),
                    currentRange: currentMatch.flatMap { $0.row == index ? $0.range : nil }
                )
                // Explicit id so the detail's search can scroll next/previous
                // straight to a turn (matches the ForEach identity).
                .id(turn.id)
            }
        }
        .sheet(item: $tagging) { tagTarget in
            SpeakerTagSheet(
                target: target,
                captureId: captureId,
                speaker: tagTarget.speaker,
                displayLabel: transcript.displayLabel(for: tagTarget.speaker.slot),
                // The tapped turn's clip; fall back to the slot's representative sample
                // when opened without a specific turn (the review-speakers jump).
                sampleWindow: tagTarget.sampleWindow ?? transcript.voiceSampleWindow(for: tagTarget.speaker.slot),
                onChanged: { await onChanged() },
                onConfirmed: onConfirmed,
                isRecording: isRecording
            )
            .onAppear { sheetPresenting = true }
            .onDisappear { sheetPresenting = false }
        }
    }

    /// Bare confirm of an inferred match (the inline "Confirm" affordance) — the
    /// controller runs the LOCAL-FIRST flow and drives the phase the affordance renders:
    /// in-flight within one frame → "Saved" check. The intent is durably queued and the
    /// background ship reconciles via the synced notification (or stays quietly pending).
    private func confirmInferred(slot: String) async {
        await confirmController.confirm(
            captureId: captureId, slot: slot,
            ship: ConfirmShip.make(target: target, captureId: captureId, slot: slot),
            onConfirmed: onConfirmed)   // optimistic: show the saved name instantly
    }
}

// MARK: - shared confirm plumbing (inline affordances)

/// A subtle "waiting to sync to your computer" glyph — a small cloud-with-arrow next to a
/// speaker name while its local save hasn't reached the Mac yet (local-first track
/// 20260717T1600). Clears on the ACK (queue-change notification). Deliberately quiet: a
/// faint icon, never a status word — the save already succeeded locally.
struct SpeakerSyncPendingGlyph: View {
    var body: some View {
        Image(systemName: "icloud.and.arrow.up")
            .grainTextStyle(.caption)
            .foregroundStyle(GrainColor.textFaint)
            .accessibilityLabel("Waiting to sync to your computer")
            .accessibilityIdentifier("speaker-sync-pending")
    }
}

/// The inline confirm affordance, rendered from its phase — ONE control shared by the
/// legacy attributed rows and the Grain rows so the states can never drift. LOCAL-FIRST
/// (track 20260717T1600): the save succeeds on the phone instantly, so there is no failure
/// state here — a sync that can't reach the Mac stays quietly pending (the glyph), never a
/// scary error.
///   idle      → "Confirm: <name>" + "Not them"
///   inFlight  → spinner + "Saving…" (the durable local save; a within-a-frame beat)
///   confirmed → a brief check "Saved <name>" (the label itself flips in place)
struct InlineConfirmControls: View {
    let phase: SpeakerConfirmPhase
    let name: String
    let onConfirm: () -> Void
    let onNotThem: () -> Void

    var body: some View {
        Group {
            switch phase {
            case .idle:
                HStack(spacing: GrainSpacing.x2) {
                    GrainButton("Confirm: \(name)", variant: .tonal, size: .sm, action: onConfirm)
                    GrainButton("Not them", variant: .text, size: .sm, action: onNotThem)
                }
            case .inFlight:
                HStack(spacing: GrainSpacing.x2) {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                }
                .frame(minHeight: GrainSpacing.x8)
                .accessibilityIdentifier("confirm-inflight")
            case .confirmed:
                HStack(spacing: GrainSpacing.x2) {
                    Image(grain: .check).foregroundStyle(GrainColor.sage)
                    Text("Saved \(name)")
                        .grainTextStyle(.caption).fontWeight(.semibold)
                        .foregroundStyle(GrainColor.sage)
                }
                .frame(minHeight: GrainSpacing.x8)
                .accessibilityIdentifier("confirm-success")
            }
        }
        .animation(.easeInOut(duration: 0.15), value: phase)
    }
}

/// One speaker turn: a colour-coded label header + the turn's text. Inferred speakers
/// render ghosted with a confidence hint and an inline confirm / not-them affordance.
struct SpeakerTurnRow: View {
    let turn: SpeakerTurn
    let transcript: SpeakerTranscript
    let onTapSpeaker: () -> Void
    let onConfirmInferred: () async -> Void
    /// This slot's confirm lifecycle (in-flight / confirmed) — drives the inline
    /// affordance so a tap always answers within a frame.
    var confirmPhase: SpeakerConfirmPhase = .idle
    /// True while this slot's local save hasn't reached the Mac yet — shows the subtle
    /// sync glyph next to the name (local-first track 20260717T1600).
    var isPendingSync: Bool = false
    /// A transient revert notice for this slot (a rare 4xx rejection), else nil.
    var revertNotice: String? = nil
    /// Search-match character ranges within `turn.text` (empty = no search).
    var highlightRanges: [Range<Int>] = []
    /// The current match's range, when it lives in this turn.
    var currentRange: Range<Int>? = nil

    private var speaker: CaptureSpeaker { transcript.speaker(for: turn.slot) }
    private var accent: Color { SpeakerPalette.accent(transcript.colorIndex(for: turn.slot)) }
    private var label: String { transcript.displayLabel(for: turn.slot) }

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            // Speaker label — tappable to open the tag/confirm sheet.
            Button(action: onTapSpeaker) {
                HStack(spacing: GrainSpacing.x2) {
                    Circle().fill(accent)
                        .frame(width: GrainSpacing.x2, height: GrainSpacing.x2)
                    Text(label)
                        .grainTextStyle(.caption)
                        .foregroundStyle(speaker.isAnonymous ? GrainColor.textMuted : accent)
                        .fontWeight(.semibold)
                    if isPendingSync { SpeakerSyncPendingGlyph() }
                    if speaker.isInferred,
                       SpeakerConfidence.tier(for: speaker.inferScore) == .strong {
                        Text(tentativeHint)
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textFaint)
                            .italic()
                    } else if speaker.isAnonymous {
                        Image(grain: .pencil)
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textFaint)
                    }
                }
            }
            .buttonStyle(.plain)

            if let revertNotice {
                Text(revertNotice)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("speaker-sync-reverted")
            }

            // Turn text — ghosted while the speaker is only a tentative (inferred)
            // match; search matches render highlighted (current match strongest).
            Text(TranscriptHighlighter.attributed(
                turn.text, ranges: highlightRanges, current: currentRange))
                .grainTextStyle(.body)
                .foregroundStyle(GrainColor.ink)
                // Ghost only a STRONG (name-revealing) tentative match; a weak slot
                // presents at full weight like an anonymous speaker.
                .opacity((speaker.isInferred && speaker.revealedName != nil) ? 0.6 : 1.0)
                .textSelection(.enabled)
                .padding(.leading, GrainSpacing.x4)

            // Inline confirm affordance for an inferred match — confirm or "not them".
            // Also rendered while a phase is still resolving/lingering (e.g. the brief
            // "Confirmed" check after the optimistic flip made the speaker confirmed).
            // Only a STRONG inferred match offers an inline "Confirm <name>"; a weak
            // slot reveals no name (revealedName == nil) and presents like an anonymous
            // one — the tap-to-tag path is its affordance.
            if speaker.isInferred, let name = speaker.revealedName {
                InlineConfirmControls(
                    phase: confirmPhase,
                    name: name,
                    onConfirm: { Task { await onConfirmInferred() } },
                    onNotThem: onTapSpeaker)
                .padding(.leading, GrainSpacing.x4)
            } else if confirmPhase != .idle {
                InlineConfirmControls(
                    phase: confirmPhase,
                    name: speaker.revealedName ?? label,
                    onConfirm: { Task { await onConfirmInferred() } },
                    onNotThem: onTapSpeaker)
                .padding(.leading, GrainSpacing.x4)
            }
        }
        .padding(.vertical, GrainSpacing.x3)
        .overlay(alignment: .bottom) {
            Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
        }
    }

    /// The inline hint beside a STRONG inferred name. A raw cosine is NEVER rendered as
    /// a percentage (see SpeakerConfidence); weak matches don't reach here — they show
    /// "Speaker N" with no hint.
    private var tentativeHint: String {
        SpeakerConfidence.inlineStrongHint
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

/// A tiny async-safe box so the tag sheet can PEEK the background ship's outcome after the
/// flash window without blocking on it — if the ACK hasn't landed, `value` is nil and the
/// sheet dismisses (the ship completes independently, surfacing any late offer via the
/// synced notification).
private actor ConfirmOutcomeBox {
    private(set) var value: ConfirmOutcome?
    func set(_ v: ConfirmOutcome?) { value = v }
}

// MARK: - Tag / confirm / correct sheet

/// What the tag sheet is opened FOR: the speaker slot to name, plus the EXACT clip
/// "Hear this voice" should play. Opened from a tapped transcript turn ⇒ `sampleWindow`
/// is THAT turn's clip — the piece the user was looking at (BUG b232: the sample used to
/// always play the slot's globally-longest utterance, so it "didn't play the selected
/// piece"). Opened WITHOUT a specific turn (the review-speakers jump) ⇒ `sampleWindow`
/// is nil and the sheet falls back to the slot's representative (longest) sample. A fresh
/// `id` per open so tapping a different turn of the SAME speaker re-presents the new clip.
struct SpeakerTagTarget: Identifiable {
    let speaker: CaptureSpeaker
    let sampleWindow: (startMs: Int, endMs: Int)?
    let id = UUID()
    init(speaker: CaptureSpeaker, sampleWindow: (startMs: Int, endMs: Int)? = nil) {
        self.speaker = speaker
        self.sampleWindow = sampleWindow
    }
}

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
    /// Optimistic hook: fired the instant the door acknowledges a confirm so the detail
    /// can flip the in-memory speaker for that slot before the authoritative re-fetch.
    var onConfirmed: (ConfirmOutcome) -> Void = { _ in }
    /// True while a recording is active — voice-sample playback is DISABLED then (it must
    /// never fight the mic for the audio session). Defaults false so non-recording call
    /// sites are unchanged.
    var isRecording: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var busy = false
    @State private var offer: ConfirmOutcome?
    @State private var applied = false
    /// Which affordance is in flight — its button becomes a spinner row within one
    /// frame of the tap (never a dead, merely-disabled button). The local save lands
    /// almost immediately (durable enqueue), so this is a brief "Saving…" beat.
    private enum PendingAction { case confirmInferred, saveName }
    @State private var pendingAction: PendingAction?
    /// Success flash: "Saved <name>" shown briefly before the sheet dismisses ITSELF (the
    /// "did it work?" beat Nick asked for) — local-first, so it never claims the Mac
    /// confirmed. If the background sync ACKs with an apply-to-past offer within the flash
    /// window, the sheet transitions to the offer instead of dismissing.
    @State private var flashConfirmedName: String?

    /// Voice-sample playback: idle → loading → playing; a `failure` carries the honest
    /// outcome (pruned audio vs unreachable computer vs a real failure). Sheet-local —
    /// closing stops it.
    private enum SampleState: Equatable { case idle, loading, playing, failure(AudioPlaybackPresentation.Outcome) }
    @State private var sampleState: SampleState = .idle
    @State private var samplePlayer: AVAudioPlayer?
    /// Whether playVoiceSample() flipped the shared session to .playback (and so must
    /// release it when the sample stops). False when a recording owned the session.
    @State private var sampleOwnsSession = false

    var body: some View {
        GrainSheetContainer(title: "Tag speaker", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                if let offer, !offer.offeredCaptures.isEmpty, !applied {
                    offerSection(offer)
                } else if applied {
                    appliedSection
                } else if let confirmedName = flashConfirmedName {
                    confirmedFlashSection(confirmedName)
                } else {
                    editSection
                }
            }
            .padding(GrainSpacing.x4)
        }
        .onAppear { name = speaker.name ?? "" }
        .onDisappear {
            samplePlayer?.stop()
            samplePlayer = nil
            PlaybackSession.end(changed: sampleOwnsSession)
            sampleOwnsSession = false
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

        // Only a STRONG inferred match (revealedName != nil) offers "Confirm <name>".
        // A weak inferred slot reveals no name and falls through to the tag flow below,
        // presenting exactly like an anonymous speaker (no name leak, name field only).
        if speaker.isInferred, let inferred = speaker.revealedName {
            Text(scoreCaption(inferred))
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            if pendingAction == .confirmInferred {
                sheetInFlightRow("Saving…")
            } else {
                GrainButton("Confirm \(inferred)", variant: .filled, size: .regular) {
                    Task { await confirm(name: nil) }   // bare confirm of the inferred match
                }
                .disabled(busy)
            }
            Divider().background(GrainColor.borderHairline)
            Text("Not them? Name this speaker instead:")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        } else if speaker.isAnonymous || speaker.isInferred {
            Text("This voice isn't named yet. Who is it?")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        } else {
            Text("Rename or reassign this speaker.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        }

        GrainTextField("Name", text: $name, label: "Speaker name")
        Text("Type a new name to create a person, or an existing person's name to assign this voice to them.")
            .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)

        if pendingAction == .saveName {
            sheetInFlightRow("Saving…")
        } else {
            GrainButton(saveTitle, variant: .filled, size: .regular) {
                Task { await confirm(name: name.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var saveTitle: String { speaker.isConfirmed ? "Save changes" : "Save name" }

    /// The in-flight beat: the tapped button becomes a spinner row within one frame.
    private func sheetInFlightRow(_ label: String) -> some View {
        HStack(spacing: GrainSpacing.x2) {
            ProgressView().controlSize(.small)
            Text(label).grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
        }
        .frame(minHeight: GrainSpacing.x8)
        .accessibilityIdentifier("sheet-confirm-inflight")
    }

    /// The success flash shown just before the sheet dismisses itself — local-first, so
    /// it says "Saved" (the change is on the phone now), never "Confirmed" (which would
    /// claim the Mac applied it).
    @ViewBuilder private func confirmedFlashSection(_ confirmedName: String) -> some View {
        HStack(spacing: GrainSpacing.x2) {
            Image(grain: .check).foregroundStyle(GrainColor.sage)
            Text("Saved \(confirmedName)")
                .grainTextStyle(.title).foregroundStyle(GrainColor.ink)
        }
        .accessibilityIdentifier("sheet-confirm-success")
        Text("Syncing to your computer — this voice will be recognized in future conversations.")
            .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
    }

    // ── "Hear this voice" ────────────────────────────────────────────────────

    /// Playback must never steal the audio session from a live recording — while one is
    /// active, "Hear this voice" is disabled (the passed-in flag OR a record engine
    /// already owning the shared session).
    private var isPlaybackBlocked: Bool { isRecording || PlaybackSession.recordOwnsSession }

    @ViewBuilder private var voiceSampleRow: some View {
        if case .playing = sampleState {
            GrainButton("Stop", variant: .outlined, size: .regular) {
                samplePlayer?.stop()
                samplePlayer = nil
                sampleState = .idle
                PlaybackSession.end(changed: sampleOwnsSession)
                sampleOwnsSession = false
            }
        } else if let reason = AudioPlaybackPresentation.playbackDisabledReason(isRecording: isPlaybackBlocked) {
            Text(reason).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
        } else {
            switch sampleState {
            case .idle:
                GrainButton("▶ Hear this voice", variant: .outlined, size: .regular) {
                    Task { await playVoiceSample() }
                }
                #if DEBUG
                // Proof hook (b232): expose the EXACT clip window this sheet will fetch so
                // the simulator proof can assert the tapped line's clip is selected — not
                // the slot's longest utterance. DEBUG-only; never in a shipped build.
                .accessibilityIdentifier(sampleWindow.map {
                    "hear-voice-window-\($0.startMs)-\($0.endMs)"
                } ?? "hear-voice-window-none")
                #endif
            case .loading:
                HStack(spacing: GrainSpacing.x2) {
                    ProgressView().controlSize(.small)
                    Text("Fetching voice sample…")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                }
            case .failure(let outcome):
                sampleFailureLabel(outcome)
            case .playing:
                EmptyView()   // handled above
            }
        }
    }

    /// Honest, non-technical copy for a voice-sample failure — pruned audio (faint) reads
    /// distinctly from an unreachable computer (muted); a real failure smolders amber.
    @ViewBuilder private func sampleFailureLabel(_ outcome: AudioPlaybackPresentation.Outcome) -> some View {
        let copy = AudioPlaybackPresentation.copy(for: outcome)
        let tint: Color = {
            switch outcome {
            case .unavailable: return GrainColor.textFaint
            case .unreachable: return GrainColor.textMuted
            case .failed:      return GrainColor.amber
            }
        }()
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            Text(copy.title).grainTextStyle(.caption).foregroundStyle(tint)
            if let subtitle = copy.subtitle {
                Text(subtitle).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }
        }
    }

    /// Fetch the speaker's sample window from the door (a few seconds of Ogg-Opus,
    /// sliced desktop-side) and play it. 404 → unavailable (pruned audio); a decode
    /// failure → failed. The sheet stays fully usable for naming either way.
    private func playVoiceSample() async {
        guard let window = sampleWindow else { return }
        // Never start playback while a recording owns the session (the row already shows
        // the disabled reason; this is the tap-time guard).
        guard !isPlaybackBlocked else { return }
        sampleState = .loading
        do {
            // Cache (app-session, ≤1 day) → replaying a sample never re-downloads.
            let cacheKey = await AudioReplayCache.shared.key(
                captureId: captureId, startMs: window.startMs, endMs: window.endMs)
            var wav = await AudioReplayCache.shared.get(cacheKey)
            if wav == nil {
                guard let data = try await DoorClient(target: target).captureAudio(
                    captureId: captureId, startMs: window.startMs, endMs: window.endMs)
                else {
                    sampleState = .failure(.unavailable)
                    return
                }
                // Ogg-Opus → WAV on-device (AVAudioPlayer can't decode Opus).
                guard let converted = OggOpusReplay.wav(fromOggOpus: data) else {
                    sampleState = .failure(.failed)
                    return
                }
                await AudioReplayCache.shared.put(cacheKey, wav: converted)
                wav = converted
            }
            // Playback needs the audio session (else iOS plays silently) — but must
            // never STEAL it from a live phone-mic recording (that churns routes
            // against the record engine).
            sampleOwnsSession = PlaybackSession.begin()
            let player = try AVAudioPlayer(data: wav!)
            let windowSeconds = Double(window.endMs - window.startMs) / 1000.0
            // LEGACY-DOOR fallback: a door predating range support ignores the
            // query and returns the WHOLE recording — seek into the window so the
            // sample still plays THIS speaker, and stop after the window elapses.
            if player.duration > windowSeconds * 2 + 1 {
                player.currentTime = Double(window.startMs) / 1000.0
            }
            player.play()
            samplePlayer = player
            sampleState = .playing
            // Stop when the sample window (or the clip) ends — poll the player; no
            // delegate plumbing needed for a few-second sample.
            let playSeconds = min(max(player.duration - player.currentTime, 0), windowSeconds)
            Task {
                try? await Task.sleep(nanoseconds: UInt64((playSeconds + 0.3) * 1_000_000_000))
                if samplePlayer === player {
                    player.stop()
                    sampleState = .idle
                    samplePlayer = nil
                    PlaybackSession.end(changed: sampleOwnsSession)
                    sampleOwnsSession = false
                }
            }
        } catch {
            PlaybackSession.end(changed: sampleOwnsSession)
            sampleOwnsSession = false
            sampleState = .failure(AudioPlaybackPresentation.failurePresentation(for: error))
        }
    }

    // After a confirm that matched PAST captures — offer to apply, never auto-applied.
    @ViewBuilder private func offerSection(_ outcome: ConfirmOutcome) -> some View {
        Text("Confirmed \(outcome.speakerName)")
            .grainTextStyle(.title).foregroundStyle(GrainColor.ink)
        let n = outcome.offeredCaptures.count
        Text("This voice also matches \(n) past \(n == 1 ? "conversation" : "conversations"). Apply \(outcome.speakerName) to \(n == 1 ? "it" : "them")?")
            .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
        if busy {
            sheetInFlightRow("Applying…")
        } else {
            HStack(spacing: GrainSpacing.x2) {
                GrainButton("Apply to \(n)", variant: .filled, size: .regular) {
                    Task { await applyOffer(outcome) }
                }
                GrainButton("Not now", variant: .text, size: .regular) { dismiss() }
            }
        }
    }

    @ViewBuilder private var appliedSection: some View {
        Text("Applied").grainTextStyle(.title).foregroundStyle(GrainColor.ink)
        Text("Updated the matching past conversations.")
            .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
        GrainButton("Done", variant: .filled, size: .regular) { dismiss() }
    }

    private func scoreCaption(_ inferred: String) -> String {
        // NEVER render the raw cosine as a percentage: strong → "Might be <name>",
        // weak → a neutral "Unknown speaker" prompt (SpeakerConfidence owns the copy).
        SpeakerConfidence.sheetCopy(name: inferred, score: speaker.inferScore)
    }

    /// Confirm/correct: `name == nil` is a bare confirm of the inferred match; a
    /// non-empty name confirms for that name (merge-or-create).
    ///
    /// LOCAL-FIRST contract (track 20260717T1600): the tap becomes a brief "Saving…" beat
    /// while the intent is durably enqueued, then flips this slot to confirmed on the
    /// phone, flashes "Saved <name>", and the sheet dismisses ITSELF — regardless of
    /// connectivity. The sync rides in the background (the queue's drain re-ships it if the
    /// Mac is unreachable). If the background ship ACKs with an apply-to-past OFFER within
    /// the flash window, the sheet transitions to the offer instead of dismissing (the fast
    /// -network offer flow). A rare rejection / auth-expiry is handled globally (the drain's
    /// re-auth seam, a gentle in-conversation revert) — never an error dialog here.
    private func confirm(name: String?) async {
        guard !busy else { return }   // re-entrancy: one save at a time
        busy = true
        pendingAction = (name == nil) ? .confirmInferred : .saveName
        let base = CaptureWAL.documentsCaptures()
        let slot = speaker.slot
        // P1 (review): a TYPED name is name-only — never ride the slot's old speakerId,
        // because Lore's confirm resolves speakerId OVER name and would silently confirm
        // the OLD speaker (poisoning the durable queue + reverting the typed name on ACK).
        // A bare confirm (no typed name) still ships the known speakerId. ONE decision,
        // shared with the tests, so the sheet and its coverage can't drift.
        let intent = SpeakerConfirmIntent.make(typedName: name, speaker: speaker)
        let shipName = intent.name
        let speakerId = intent.speakerId

        // Durable FIRST, OFF the main actor. The returned ts guards the background ship's
        // later dequeue against a newer rename.
        let ts = await Task.detached {
            SpeakerConfirmQueue.enqueue(captureId: captureId, slot: slot,
                                        name: shipName, speakerId: speakerId, baseDir: base)
        }.value

        // Instant LOCAL success — flip this slot to confirmed and flash "Saved <name>".
        let shown = (shipName?.isEmpty == false) ? shipName!
            : (speaker.name ?? displayLabel)
        onConfirmed(ConfirmOutcome(captureId: captureId, slotLabel: slot, status: "confirmed",
                                   speakerId: speakerId ?? "", speakerName: shipName ?? "",
                                   offeredCaptures: []))
        pendingAction = nil
        busy = false
        flashConfirmedName = shown

        // Background sync — does its own ts-guarded dequeue, write-through, and posts the
        // synced/rejected notification. Runs independently of the sheet's lifetime.
        let ship = ConfirmShip.make(target: target, captureId: captureId,
                                    slot: slot, name: shipName, speakerId: speakerId)
        let outcomeBox = ConfirmOutcomeBox()
        Task {
            let outcome = await SpeakerConfirmFlow.backgroundShip(
                captureId: captureId, slot: slot, name: shipName, speakerId: speakerId,
                ts: ts, baseDir: base, ship: ship)
            await outcomeBox.set(outcome)
        }

        // Hold the flash for its window, then either surface a fast-network offer or
        // dismiss. If the ACK hasn't landed by now, the sheet dismisses and any later
        // offer surfaces non-modally in the open conversation (the synced notification).
        try? await Task.sleep(nanoseconds: 600_000_000)
        if let landed = await outcomeBox.value, !landed.offeredCaptures.isEmpty {
            onConfirmed(landed)   // adopt the canonical name/id the Mac resolved
            offer = landed
        } else {
            dismiss()
        }
    }

    /// Apply the confirmed speaker to the offered past captures (looped confirm by
    /// speakerId — the assign-to-existing path).
    private func applyOffer(_ outcome: ConfirmOutcome) async {
        busy = true
        defer { busy = false }
        // The current slot was already confirmed by `confirm()`; keep the optimistic
        // in-memory reflection in sync (idempotent) before applying to past captures.
        onConfirmed(outcome)
        let client = DoorClient(target: target)
        let base = CaptureWAL.documentsCaptures()
        let speakerId = outcome.speakerId
        let offered = outcome.offeredCaptures

        // (a)+(b) Enqueue ALL intents in ONE atomic write, OFF the main actor. Was a
        // per-capture enqueue+remove (each a full-file read+rewrite on the MainActor →
        // O(N²)) that made "apply as me" across many past conversations crawl.
        let intents = offered.map { (captureId: $0.captureId, slot: $0.slotLabel, speakerId: Optional(speakerId)) }
        await Task.detached { SpeakerConfirmQueue.enqueueAll(intents, baseDir: base) }.value

        // (c) Ship the confirms CONCURRENTLY with a bounded task group (≤6 in flight;
        // DoorClient is Sendable), collecting the ones that succeeded. `busy` already
        // shows progress.
        let succeeded = await withTaskGroup(
            of: (captureId: String, slot: String)?.self
        ) { group -> [(captureId: String, slot: String)] in
            let maxInFlight = 6
            func ship(_ o: OfferedCapture) -> @Sendable () async -> (captureId: String, slot: String)? {
                {
                    let ok = (try? await client.confirmSpeaker(
                        captureId: o.captureId, slot: o.slotLabel, speakerId: speakerId)) != nil
                    return ok ? (captureId: o.captureId, slot: o.slotLabel) : nil
                }
            }
            var next = 0
            while next < offered.count && next < maxInFlight {
                group.addTask(operation: ship(offered[next])); next += 1
            }
            var done: [(captureId: String, slot: String)] = []
            while let result = await group.next() {
                if let r = result { done.append(r) }
                if next < offered.count { group.addTask(operation: ship(offered[next])); next += 1 }
            }
            return done
        }

        // (d) Drop the SUCCEEDED intents in ONE batched write; failures stay queued for
        // the capture drain to retry.
        if !succeeded.isEmpty {
            await Task.detached { SpeakerConfirmQueue.removeAll(succeeded, baseDir: base) }.value
        }
        await onChanged()
        applied = true
    }
}
