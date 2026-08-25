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
            // ⚠ AC5b — VISUALLY DISTINCT FROM LANDED, and distinguishable from the
            // rendered row ALONE. Muted rather than sage, and the words say where it is:
            // "Saved here" is true, "Saved <name>" would imply the Mac has it. Before this
            // phase existed the row flipped straight to the sage check, so a confirmation
            // that never reached the Mac looked exactly like one that did — and an owner
            // cannot re-do work they were told succeeded.
            case .pendingSync:
                HStack(spacing: GrainSpacing.x2) {
                    Image(grain: .check).foregroundStyle(GrainColor.textMuted)
                    Text("Saved here · not on your Mac yet")
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                }
                .frame(minHeight: GrainSpacing.x8)
                .accessibilityIdentifier("confirm-pending")
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
    /// The capture's space — a hard identity separator (entity-dedup Decision 8). The pick
    /// list is scoped to it so a confirm never binds/merges across spaces. The phone has no
    /// per-capture space model yet, so this defaults to the FoundryX "personal" space; a
    /// future caller can pass the capture's real space without touching either call site.
    var space: String = "personal"

    @Environment(\.dismiss) private var dismiss
    /// The single text field's value — the pick-list search query AND, when nothing
    /// matches, the create-new / offline name. Starts EMPTY: the voiceprint hint
    /// pre-selects nothing, so we never seed it with the inferred guess.
    @State private var query: String = ""
    /// The existing durable people to pick from (track 20260717T1700). Fetched on open,
    /// scoped to `space`; a confirm binds one of these by `entityId` instead of minting a dupe.
    @State private var persons: [KnownPerson] = []
    /// Directory load state: `loaded` shows the pick-list; `offline` degrades to typing a
    /// name (the door is unreachable — the local-first save still lands and syncs later).
    private enum PersonsLoad: Equatable { case loading, loaded, offline }
    @State private var personsLoad: PersonsLoad = .loading
    @State private var busy = false
    @State private var offer: ConfirmOutcome?
    @State private var applied = false
    /// Which affordance is in flight — its button becomes a spinner row within one
    /// frame of the tap (never a dead, merely-disabled button). The local save lands
    /// almost immediately (durable enqueue), so this is a brief "Saving…" beat.
    private enum PendingAction { case confirmInferred, saveName, pickPerson }
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
        .task { await loadPersons() }
        .onDisappear {
            samplePlayer?.stop()
            samplePlayer = nil
            PlaybackSession.end(changed: sampleOwnsSession)
            sampleOwnsSession = false
        }
    }

    // The main edit surface: confirm an inferred match, or PICK an existing person to bind
    // (dedup at entry) — with create-new only as the fallback. The old free-text "type a
    // name" field minted a duplicate person on every variant spelling; here the human-confirm
    // authority CHOOSES an existing durable person (binding its opaque entityId) instead
    // (track 20260717T1700, entity-dedup finding).
    @ViewBuilder private var editSection: some View {
        Text(displayLabel).grainTextStyle(.title).foregroundStyle(GrainColor.ink)

        // Hear the voice you're about to name — plays this speaker's longest
        // utterance. Only offered when the slot has timestamped segments.
        if sampleWindow != nil {
            voiceSampleRow
        }

        // Only a STRONG inferred match (revealedName != nil) offers a bare "Confirm <name>"
        // (binds the slot's known speakerId). A weak inferred slot reveals no name and falls
        // straight to the pick-list below, presenting exactly like an anonymous speaker.
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
            Text("Not them? Choose who it is:")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        } else if speaker.isAnonymous || speaker.isInferred {
            Text("This voice isn't named yet. Who is it?")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        } else {
            Text("Reassign this speaker to a person.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        }

        // PICK-FIRST when the computer is reachable; degrade to typing a name when it isn't.
        switch personsLoad {
        case .offline:            offlineNameSurface
        case .loading, .loaded:   pickPersonSurface
        }
    }

    private var saveTitle: String { speaker.isConfirmed ? "Save changes" : "Save name" }

    // MARK: pick-first surface

    /// The searchable pick-list of EXISTING people (track 20260717T1700). Typing
    /// filters/autocompletes ("Do you mean Nick Rinard?"); the voiceprint-hinted person is
    /// floated to the top and annotated "likely" — but PRE-SELECTS NOTHING (human authority).
    /// Tapping a person binds their `entityId`; "Create new person" appears only as the
    /// fallback when the typed name matches nobody.
    @ViewBuilder private var pickPersonSurface: some View {
        GrainTextField("Search people or add a name", text: $query, label: "Find a person")
            .accessibilityIdentifier("person-search")

        if pendingAction == .pickPerson || pendingAction == .saveName {
            sheetInFlightRow("Saving…")
        } else if personsLoad == .loading {
            sheetInFlightRow("Finding your people…")
        } else {
            let hint = PersonPicker.hintEntityId(inferredName: speaker.revealedName, in: persons)
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = trimmed.isEmpty
                ? PersonPicker.ordered(persons: persons, hintEntityId: hint)   // hinted first
                : PersonPicker.filter(query, in: persons)                       // autocomplete

            if persons.isEmpty {
                Text("No saved people yet — type a name to add the first one.")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            } else if matches.isEmpty {
                Text("No match — create the person below.")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }

            if !matches.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(matches) { person in
                            personRow(person, isLikely: person.entityId == hint)
                            Rectangle().fill(GrainColor.borderHairline).frame(height: 1)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }

            // Create-new is the EXCEPTION — only when the typed name matches no one.
            if PersonPicker.showCreateNew(query: query, in: persons) {
                createNewRow(trimmed)
            }
        }
    }

    /// One pick-list row for an existing person — tapping BINDS them by `entityId`. The
    /// voiceprint-hinted person carries a gentle "likely" note (the hint), never a selection.
    private func personRow(_ person: KnownPerson, isLikely: Bool) -> some View {
        Button {
            Task { await confirmPicked(person) }
        } label: {
            HStack(spacing: GrainSpacing.x3) {
                GrainAvatar(initials: personInitials(person.displayName), size: .sm,
                            tint: isLikely ? GrainColor.forgeBlue : GrainColor.sage)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.displayName)
                        .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                    if isLikely {
                        Text("likely — matches this voice")
                            .grainTextStyle(.caption).foregroundStyle(GrainColor.forgeBlue)
                            .accessibilityIdentifier("person-likely-\(person.entityId)")
                    } else if let sub = personSubtitle(person) {
                        Text(sub).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }
            .padding(.vertical, GrainSpacing.x3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityIdentifier("person-row-\(person.entityId)")
    }

    /// The create-new FALLBACK row — creates a brand-new person by the typed name (name-only,
    /// no entityId). Shown only when nothing matched, so it never competes with a pick.
    private func createNewRow(_ typed: String) -> some View {
        Button {
            Task { await confirm(name: typed) }
        } label: {
            HStack(spacing: GrainSpacing.x3) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .foregroundStyle(GrainColor.sage)
                Text("Create new person: \(typed)")
                    .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                Spacer()
            }
            .padding(.vertical, GrainSpacing.x3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityIdentifier("person-create-new")
    }

    /// Offline degrade: the computer is unreachable, so we can't offer a pick-list — fall
    /// back to typing a name. The local-first save still lands instantly and syncs when the
    /// computer is reachable again (never the "couldn't connect" error).
    @ViewBuilder private var offlineNameSurface: some View {
        GrainTextField("Name", text: $query, label: "Speaker name")
            .accessibilityIdentifier("person-offline-name")
        Text("Can't reach your computer — type a name and it saves here, syncing when you reconnect.")
            .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
        if pendingAction == .saveName {
            sheetInFlightRow("Saving…")
        } else {
            GrainButton(saveTitle, variant: .filled, size: .regular) {
                Task { await confirm(name: query.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            .disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func personInitials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init)
        let s = letters.joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    /// A subtle subtitle for a non-hinted row — the person's other known spellings, so a
    /// user recognizes "Nick" is the same entity as "Nicholas".
    private func personSubtitle(_ person: KnownPerson) -> String? {
        guard !person.aliases.isEmpty else { return nil }
        return "also " + person.aliases.prefix(2).joined(separator: ", ")
    }

    /// Fetch the existing people for the pick-list, scoped to the capture's `space`. A
    /// door 404 (old desktop without the route) yields an empty list — still a usable
    /// type-to-create surface; a transport failure / unreachable computer degrades to the
    /// offline name field. DEBUG `-PersonsProof` substitutes deterministic data for the
    /// simulator proof (precedent: `-ConfirmProof`).
    private func loadPersons() async {
        #if DEBUG
        if let seeded = PersonProof.seeded() { persons = seeded; personsLoad = .loaded; return }
        if PersonProof.forceOffline { personsLoad = .offline; return }
        #endif
        // Race the fetch against a wall-clock deadline: a HUNG relay leg (the b230
        // lost-response class — the mux turn resolves only on a reply/disconnect, no
        // timeout) would otherwise strand the sheet on "Finding your people…" forever with
        // no offline degrade. A nil result (unreachable OR deadline) → the type-a-name
        // fallback, so the offline promise holds even when the relay silently hangs.
        let target = self.target, space = self.space
        let fetched = await PersonDirectoryFetch.withDeadline(12) {
            try? await DoorClient(target: target).persons(space: space)
        }
        if let fetched {
            persons = fetched
            personsLoad = .loaded
        } else {
            personsLoad = .offline
        }
    }

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
            // A voice sample is always a door fetch — it is a SLICE of a capture, and no
            // recorder ever handed this phone a slice — so this arm is unreachable here. It is
            // spelled out anyway rather than defaulted, so adding a fourth outcome makes
            // somebody decide what this row does with it.
            case .heldButUnreadable: return GrainColor.amber
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
        // P1 (review): a TYPED name is name-only — never ride the slot's old speakerId,
        // because Lore's confirm resolves speakerId OVER name and would silently confirm
        // the OLD speaker (poisoning the durable queue + reverting the typed name on ACK).
        // A bare confirm (no typed name) still ships the known speakerId. ONE decision,
        // shared with the tests, so the sheet and its coverage can't drift.
        let intent = SpeakerConfirmIntent.make(typedName: name, speaker: speaker)
        let action: PendingAction =
            (name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            ? .confirmInferred : .saveName
        await performConfirm(name: intent.name, speakerId: intent.speakerId,
                             entityId: nil, action: action)
    }

    /// PICK an existing durable person (track 20260717T1700): bind this slot to that
    /// person's `entityId` — dedup at the point of entry. Ships the person's display name
    /// too (for the label), never the slot's stale speakerId.
    private func confirmPicked(_ person: KnownPerson) async {
        let intent = SpeakerConfirmIntent.pick(person: person)
        await performConfirm(name: intent.name, speakerId: intent.speakerId,
                             entityId: intent.entityId, action: .pickPerson)
    }

    /// The ONE local-first confirm body every path funnels through (bare confirm / pick an
    /// existing person / create-new). `entityId` binds an existing person when a pick, else
    /// nil. See `confirm(name:)` for the full local-first contract.
    private func performConfirm(name shipName: String?, speakerId: String?,
                                entityId: String?, action: PendingAction) async {
        guard !busy else { return }   // re-entrancy: one save at a time
        busy = true
        pendingAction = action
        let base = CaptureWAL.documentsCaptures()
        let slot = speaker.slot

        // Durable FIRST, OFF the main actor. The returned ts guards the background ship's
        // later dequeue against a newer rename. `entityId` is durable so an OFFLINE pick
        // still ships its bind when the drain retries.
        let ts = await Task.detached {
            SpeakerConfirmQueue.enqueue(captureId: captureId, slot: slot,
                                        name: shipName, speakerId: speakerId,
                                        entityId: entityId, baseDir: base)
        }.value

        // Instant LOCAL success — flip this slot to confirmed and flash "Saved <name>". The
        // optimistic speakerId is the slot's real speakerId (bare confirm) or empty for a
        // pick/create — NEVER the entity_id aliased as a speakerId (a type confusion the
        // synced-notification reconcile would otherwise briefly expose). The name drives the
        // label; the real speakerId/entityId land on the ACK write-through.
        let shown = (shipName?.isEmpty == false) ? shipName!
            : (speaker.name ?? displayLabel)
        onConfirmed(ConfirmOutcome(captureId: captureId, slotLabel: slot, status: "confirmed",
                                   speakerId: speakerId ?? "",
                                   speakerName: shipName ?? "", offeredCaptures: []))
        pendingAction = nil
        busy = false
        flashConfirmedName = shown

        // Background sync — does its own ts-guarded dequeue, write-through, and posts the
        // synced/rejected notification. Runs independently of the sheet's lifetime.
        let ship = ConfirmShip.make(target: target, captureId: captureId,
                                    slot: slot, name: shipName, speakerId: speakerId,
                                    entityId: entityId)
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

/// Races an async fetch against a wall-clock deadline WITHOUT a task group — a group can't
/// return until its children finish, so a non-cancellable relay hang would defeat a
/// group-based race (the exact reason SpeakerConfirmFlow.withDeadline is unstructured). On
/// deadline the caller resumes with nil and the orphaned fetch is cancelled best-effort;
/// its late result is discarded. Used so the pick-list degrades to offline on a hung relay.
enum PersonDirectoryFetch {
    static func withDeadline(_ seconds: Double,
                             _ op: @escaping @Sendable () async -> [KnownPerson]?) async -> [KnownPerson]? {
        let gate = ResumeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<[KnownPerson]?, Never>) in
            let work = Task { let r = await op(); await gate.resume(cont, r) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
                await gate.resume(cont, nil)
                work.cancel()
            }
        }
    }

    /// Single-resume gate — whichever of fetch/deadline finishes first wins; the loser is
    /// discarded (never a double resume).
    private actor ResumeOnce {
        private var done = false
        func resume(_ cont: CheckedContinuation<[KnownPerson]?, Never>, _ value: [KnownPerson]?) {
            guard !done else { return }
            done = true
            cont.resume(returning: value)
        }
    }
}

#if DEBUG
/// Simulator-proof seam for the pick-list (`-PersonsProof <mode>`), mirroring
/// `-ConfirmProof` / `-AudioProof`. Substitutes deterministic person data (or forces the
/// offline degrade) so `SpeakerAttributionProofUITests`-style proofs can screenshot the
/// pick-first flow without a live door. NEVER active outside DEBUG.
///   • `seeded`  — a small deterministic directory (Nick Rinard w/ "Nick"/"Nicholas"
///                 aliases, Greg Rinard, Dana Lee, Priya Patel) so the proof shows the
///                 pick-list, autocomplete, and the voiceprint hint.
///   • `offline` — the fetch is treated as unreachable (the type-a-name degrade proof).
enum PersonProof {
    static var mode: String? {
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-PersonsProof"), i + 1 < a.count { return a[i + 1] }
        return nil
    }
    static var forceOffline: Bool { mode == "offline" }
    static func seeded() -> [KnownPerson]? {
        guard mode == "seeded" else { return nil }
        return [
            KnownPerson(entityId: "e-nick", displayName: "Nick Rinard",
                        aliases: ["Nick", "Nicholas"], lastSeenMs: 9_000),
            KnownPerson(entityId: "e-dana", displayName: "Dana Lee", lastSeenMs: 7_500),
            KnownPerson(entityId: "e-greg", displayName: "Greg Rinard", lastSeenMs: 6_000),
            KnownPerson(entityId: "e-priya", displayName: "Priya Patel", lastSeenMs: 4_000),
        ]
    }
}
#endif
