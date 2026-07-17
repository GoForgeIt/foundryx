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

    @State private var tagging: CaptureSpeaker?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if transcript.hasUnconfirmedInferred {
                ReviewSpeakersBanner(count: transcript.inferredSlots.count) {
                    // Jump straight into the first tentative speaker to review it.
                    if let slot = transcript.inferredSlots.first {
                        tagging = transcript.speaker(for: slot)
                    }
                }
                .padding(.bottom, GrainSpacing.x3)
            }
            Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
            ForEach(Array(transcript.turns.enumerated()), id: \.element.id) { index, turn in
                SpeakerTurnRow(
                    turn: turn,
                    transcript: transcript,
                    onTapSpeaker: { tagging = transcript.speaker(for: turn.slot) },
                    onConfirmInferred: { await confirmInferred(slot: turn.slot) },
                    highlightRanges: searchMatches.filter { $0.row == index }.map(\.range),
                    currentRange: currentMatch.flatMap { $0.row == index ? $0.range : nil }
                )
                // Explicit id so the detail's search can scroll next/previous
                // straight to a turn (matches the ForEach identity).
                .id(turn.id)
            }
        }
        .sheet(item: $tagging) { speaker in
            SpeakerTagSheet(
                target: target,
                captureId: captureId,
                speaker: speaker,
                displayLabel: transcript.displayLabel(for: speaker.slot),
                sampleWindow: transcript.voiceSampleWindow(for: speaker.slot),
                onChanged: { await onChanged() },
                onConfirmed: onConfirmed,
                isRecording: isRecording
            )
        }
    }

    /// Bare confirm of an inferred match (the inline "Confirm" affordance) — confirms
    /// the slot's existing inferred speaker without renaming.
    private func confirmInferred(slot: String) async {
        let base = CaptureWAL.documentsCaptures()
        let capId = captureId
        // Durable first, but OFF the main actor — the queue's file read+rewrite must never
        // hang the tap. Await so the intent is on disk before the door call.
        await Task.detached { SpeakerConfirmQueue.enqueue(captureId: capId, slot: slot, baseDir: base) }.value
        if let outcome = try? await DoorClient(target: target).confirmSpeaker(captureId: captureId, slot: slot) {
            await Task.detached { SpeakerConfirmQueue.remove(captureId: capId, slot: slot, baseDir: base) }.value
            onConfirmed(outcome)   // optimistic: show the confirmed name instantly
        }
        // Reconcile the authoritative content in the background — don't hold the tap on a
        // full captureContent re-fetch round-trip.
        Task { await onChanged() }
    }
}

/// One speaker turn: a colour-coded label header + the turn's text. Inferred speakers
/// render ghosted with a confidence hint and an inline confirm / not-them affordance.
struct SpeakerTurnRow: View {
    let turn: SpeakerTurn
    let transcript: SpeakerTranscript
    let onTapSpeaker: () -> Void
    let onConfirmInferred: () async -> Void
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
                    if speaker.isInferred {
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

            // Turn text — ghosted while the speaker is only a tentative (inferred)
            // match; search matches render highlighted (current match strongest).
            Text(TranscriptHighlighter.attributed(
                turn.text, ranges: highlightRanges, current: currentRange))
                .grainTextStyle(.body)
                .foregroundStyle(GrainColor.ink)
                .opacity(speaker.isInferred ? 0.6 : 1.0)
                .textSelection(.enabled)
                .padding(.leading, GrainSpacing.x4)

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
        .padding(.vertical, GrainSpacing.x3)
        .overlay(alignment: .bottom) {
            Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
        }
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
    @State private var error: String?
    @State private var offer: ConfirmOutcome?
    @State private var applied = false

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
        // Durable FIRST: record the intent to disk so a hub blip can never lose it — but
        // OFF the main actor so the queue's file read+rewrite never hangs the sheet. Await
        // so the intent is on disk before the door call (a crash between them must not lose it).
        let base = CaptureWAL.documentsCaptures()
        let capId = captureId
        let slot = speaker.slot
        await Task.detached { SpeakerConfirmQueue.enqueue(captureId: capId, slot: slot, name: name, baseDir: base) }.value
        do {
            let outcome = try await DoorClient(target: target)
                .confirmSpeaker(captureId: captureId, slot: speaker.slot, name: name)
            await Task.detached { SpeakerConfirmQueue.remove(captureId: capId, slot: slot, baseDir: base) }.value  // shipped → dequeue
            onConfirmed(outcome)   // optimistic: flip this slot to confirmed instantly
            if outcome.offeredCaptures.isEmpty {
                // Nothing more the user must see → dismiss IMMEDIATELY; reconcile the
                // authoritative content in the background (was: await a full re-fetch
                // round-trip BEFORE dismissing — the painfully slow "confirm" UX).
                dismiss()
                Task { await onChanged() }
            } else {
                // The offer sheet needs the confirmed state on screen — reconcile first,
                // then surface the apply-to-past-conversations offer.
                await onChanged()
                offer = outcome
            }
        } catch {
            // Hub unreachable: the confirm stays QUEUED and ships on the next drain —
            // don't lose it, and don't freeze the user behind a scary error. Close now,
            // reconcile in the background.
            dismiss()
            Task { await onChanged() }
        }
    }

    /// Apply the confirmed speaker to the offered past captures (looped confirm by
    /// speakerId — the assign-to-existing path).
    private func applyOffer(_ outcome: ConfirmOutcome) async {
        busy = true; error = nil
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
