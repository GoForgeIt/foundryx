// ConversationFacesView — the Night Shift conversation detail (track
// 20260713T0904 + 20260714T1800 realignment, features/conversation-detail.feature):
// a conversation opens into THREE FACES — Summary (narrative lede + "What
// mattered" bullets + the linked relay answer + receipt), Actions (the
// conversation's real surfaced items with human outcomes + "Add an action"),
// Transcript (the diarized speaker transcript with in-transcript search).
//
// This is a re-arrangement of working functionality, not a rewrite: it binds to
// the SAME stores and flows the previous detail bound to — DoorClient /content,
// TranscriptCacheStore, ConversationCardStore, AudioReplayCache + PlaybackSession
// (Listen), SpeakerTranscriptSection (speaker labels, confirm-speaker, voice
// sample), transcript copy, delete. The faces render from the PURE presentation
// models in FoundryXKit (ConversationSummaryPresentation /
// ConversationActionsPresentation) so the brine step-defs drive the real logic.
// Per the prototype, no processing stepper renders inside the detail.
//
// Search: pure matching lives in FoundryXKit.TranscriptSearch; this view feeds it
// the transcript rows and renders highlights + "n of m" + next/previous. MEANING
// search is honest: the toggle exists only when a real TranscriptMeaningIndex is
// injected and available (none ships on the phone today, so it is absent).
//
// The navigation swap-in (replacing the old detail as the row destination) is
// owned by CaptureScreen's owner; this view takes the same init parameters.

import SwiftUI
import AVFoundation
import Grain
// (FoundryXKit types are same-module — the App target compiles Sources/FoundryXKit directly)

struct ConversationFacesView: View {
    let target: DoorTarget
    @ObservedObject var manager: CaptureManager
    let captureId: String
    let timeRange: String
    let place: String?
    /// WHICH DEVICE RECORDED THIS. Resolved once, by the pushing screen, from the
    /// account-scoped capture root — never re-read inside a body pass. `nil` only until it
    /// has been read; an unnameable recorder still produces an attribution (with a
    /// diagnostic), because "Unknown device" on its own is a shrug.
    var attribution: CaptureAttribution? = nil
    /// When the conversation happened — decides recent (auto-load) vs older
    /// (load on demand) transcript fetching.
    let conversationDate: Date?
    /// WHERE THIS OWNER'S VOICE NOTES LAND — phone / computer / Vault. REQUIRED, with
    /// no default: a default here is a decision about where a user's audio went, made
    /// by whoever forgot to pass it. The predecessor (`var local: Bool = false`) was
    /// exactly that — every production route left it defaulted, so the waits rendered
    /// the Mac copy on all three tiers, including for a Vault owner with no Mac.
    let destination: CaptureDestination
    /// WHICH BRAIN IS ON, for the safety predicate this page draws its "safe elsewhere" row
    /// from. REQUIRED, with no default, for the same reason `PocketCaptureDurability` makes it
    /// required: a default here is a decision about whether a recording is safe, made by
    /// whoever forgot to pass it.
    ///
    /// IT IS NOT `destination`. The tier decides which WORDS a surface uses; this decides
    /// whether a segment upload-ack is evidence of a copy anywhere other than this handset. On
    /// the phone-only tier that ack is self-issued (`CaptureBackend` passes a closure that
    /// succeeds by doing nothing), so reading the tier as though it were the brain would answer
    /// "safe elsewhere: Yes" for a recording whose only copy is on this phone — the same
    /// predicate that arms the delete button.
    let brain: BrainChoice
    /// The semantic-search seam. No embedding index exists on the phone today,
    /// so the default is nil and the meaning toggle is ABSENT (never a dead
    /// control). Inject a real, available index and the toggle appears.
    var meaningIndex: TranscriptMeaningIndex? = nil

    // MARK: faces
    @State private var face: DetailFace = {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-Face"), i + 1 < a.count {
            switch a[i + 1] {
            case "actions": return .actions
            case "transcript": return .transcript
            default: break
            }
        }
        #endif
        return .summary
    }()

    // MARK: content (same load pipeline as the previous detail)
    @State private var content: CaptureContent?
    @State private var cached: CachedTranscript?   // local fallback (pruned audio / offline)
    @State private var provisional: ConversationCardMeta?  // on-device provisional (pre-Kiln)
    @State private var loadError: String?
    @State private var loading = true
    @State private var didAttemptFetch = false
    /// THE DOOR'S OWN READING OF WHERE THIS CAPTURE IS.
    ///
    /// Read because `/content` reporting `found:false` is NOT evidence that transcription is
    /// running. Those are two different facts and the screen used to conflate them — see the
    /// wait branch below.
    @State private var doorStage: RecordingJourneyReading?
    /// AC2 — the on-device summary synthesized from the transcript when no summary
    /// exists at any source. Persisted to the card once produced so the CARD fills too.
    @State private var synthesizedSummary: String?
    /// True while the on-device synth runs — drives an honest "Summarizing…" state so
    /// the Summary face is never a dead "No summary yet." tab while work is in flight.
    @State private var summarizing = false
    /// Set once a synth has been attempted this open, so a transcript the model yields
    /// nothing for doesn't re-run the expensive synth on every subsequent load-path call.
    @State private var synthAttempted = false
    /// THE GATE'S DECISIONS FOR THIS CAPTURE. Read once per load from the lane's own JSONL, so
    /// the Actions face can say WHICH kind of nothing it is holding.
    @State private var decisions: [AmbientDecision] = []
    /// The one-way name latch. An early name shows only until the settled one lands, and the
    /// settled one is never given back — see `ConversationNameOnTheRow`.
    @State private var nameOnTheRow = ConversationNameOnTheRow()
    @State private var confirmDelete = false
    @State private var didCopy = false
    @State private var receiptExpanded = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    // MARK: summary + actions faces (presentation-model backed)
    @State private var actions = ConversationActionsPresentation(rows: [])
    @State private var linkedAnswer: LinkedConversationAnswer?
    @State private var showRelayAnswer = false
    @State private var addingAction = false
    @State private var newActionTitle = ""
    /// The action row whose options sheet is open (track 20260715T1500 addendum).
    @State private var selectedAction: ConversationActionsPresentation.Row?
    /// True when `selectedAction` was tapped inside the "Heard from others"
    /// group — its sheet then also offers "Move to my actions".
    @State private var selectedFromOthers = false
    /// Whether the collapsed "Heard from others" group is expanded.
    @State private var othersExpanded = false

    // MARK: speaker-confirm phases (track 20260717T0900)
    /// ONE per-slot confirm state machine for this conversation, shared by BOTH
    /// transcript row surfaces (Grain rows + the search-active attributed rows) so an
    /// in-flight spinner or a sticky failure survives toggling search.
    @StateObject private var confirmController =
        SpeakerConfirmController(baseDir: CaptureWAL.documentsCaptures())

    // MARK: speaker sync state (local-first track 20260717T1600)
    /// Per-conversation sync state: which slots have a still-pending (un-synced) confirm
    /// (drives the subtle glyph + the pending overlay on the rendered transcript) and any
    /// transient revert notice. Bound to this capture in `.onAppear`.
    @StateObject private var syncModel = SpeakerSyncModel()
    /// A late propagation offer that ACK'd after the tag sheet dismissed — surfaced
    /// non-modally in the open conversation (Section H). Nil when there's nothing to offer.
    @State private var lateOffer: ConfirmOutcome?
    /// True while a tag sheet (either row surface) is presenting. When it is, the ACK's
    /// propagation offer is the SHEET's to surface (its flash window) — so the parent
    /// suppresses the late banner to avoid double-surfacing the same offer (review P2#2).
    @State private var tagSheetPresenting = false

    // MARK: transcript search
    @State private var query = ""
    @State private var search = TranscriptSearchState(matches: [])
    /// True while the meaning mode is selected (only reachable when the toggle
    /// exists, i.e. a real index is available).
    @State private var meaningMode = false
    @State private var meaningBusy = false

    // MARK: listen (audio replay)
    @State private var audioState: AudioState = .idle
    @State private var player: AVAudioPlayer?
    @State private var playbackOwnsSession = false
    /// Whole-conversation scrubber (GAP b232 "play the WHOLE conversation"): how far into
    /// the capture playback is, its total length, and whether the user is dragging the
    /// scrubber (the clock stops writing `playbackElapsed` while they drag so it doesn't
    /// fight the drag). Driven by a lightweight polling task on the AVAudioPlayer clock.
    @State private var playbackElapsed: Double = 0
    @State private var playbackDuration: Double = 0
    @State private var scrubbing = false
    @State private var clockTask: Task<Void, Never>?

    // MARK: listen — a recording that came off a recorder (Step 9)
    /// THE RECORDER'S OWN FILE, ON THIS PHONE, or nil for every recording this phone made
    /// itself. `PocketRecorderFileStore` keeps the MP3 a pocket recorder handed over and never
    /// removes it, so asking a computer for those bytes would put a person's own recording
    /// behind a Mac that might be asleep — which is the one thing carrying a recorder is for.
    /// Resolved OFF the main actor in `resolveHeldRecording()`.
    @State private var heldHere: URL?
    /// The three places this recording is, in the vocabulary `PocketPresence` defines. Nil
    /// until resolved, and never rendered for a conversation this phone recorded itself.
    @State private var placesHere: PocketRecordingPresence?

    private enum AudioState: Equatable { case idle, loading, playing, failure(AudioPlaybackPresentation.Outcome) }

    /// Playback must NEVER compete with a live recording (it would ride the
    /// `.playAndRecord`/`.measurement` session and steal the mic route). True while the
    /// phone mic is recording OR the shared session is already owned by a record engine
    /// — the gate that disables Listen (see `listenRow`) and short-circuits `playAudio`.
    private var isRecordingActive: Bool {
        manager.isRecordingMic || PlaybackSession.recordOwnsSession
    }

    // MARK: - derived content (identical semantics to the previous detail)

    private var isOlder: Bool {
        guard let d = conversationDate else { return false }
        return Date().timeIntervalSince(d) > CaptureRetention.transcriptRetention
    }

    private var transcriptText: String? {
        if let c = content, c.found, !c.transcript.isEmpty { return c.transcript }
        if let cached, !cached.transcript.isEmpty { return cached.transcript }
        if let p = provisional, p.isProvisional, let body = p.provisionalTranscript, !body.isEmpty { return body }
        return nil
    }

    private var showingProvisional: Bool {
        let hasAuthoritative = (content?.found == true && !(content?.transcript.isEmpty ?? true))
            || (cached.map { !$0.transcript.isEmpty } ?? false)
        return !hasAuthoritative && (provisional?.isProvisional == true)
            && !((provisional?.provisionalTranscript ?? "").isEmpty)
    }

    /// The summary the face shows, in fidelity order: authoritative door content,
    /// then the local cache, then the durable CARD tombstone (AC1 — the card already
    /// carries the summary the home list shows), then an on-device synth (AC2). Each
    /// source counts only when NON-EMPTY, so an empty string never wins over a real one.
    private var summaryText: String? {
        if let s = content?.summary, !s.isEmpty { return s }
        if let s = cached?.summary, !s.isEmpty { return s }
        if let s = provisional?.summary, !s.isEmpty { return s }
        if let s = synthesizedSummary, !s.isEmpty { return s }
        return nil
    }

    private var copyableTranscript: String? {
        if let diarized = diarizedTranscript, diarized.hasSegments {
            let text = diarized.plainText
            if !text.isEmpty { return text }
        }
        if let t = transcriptText, !t.isEmpty { return t }
        return nil
    }

    private var diarizedTranscript: SpeakerTranscript? {
        let base: SpeakerTranscript?
        if let diarized = content?.diarized, diarized.hasSegments {
            base = diarized
        } else if let cached, !cached.segments.isEmpty {
            base = SpeakerTranscript(speakers: cached.speakers, segments: cached.segments)
        } else {
            base = nil
        }
        guard let base else { return nil }
        // LOCAL-FIRST render truth (track 20260717T1600): overlay the still-pending confirms
        // so a just-saved name shows immediately, survives relaunch, and isn't clobbered by
        // a stale door re-fetch — until the Mac ACKs (then the queue entry, and the overlay,
        // are gone and the written-through cache carries the name).
        return syncModel.pending.isEmpty ? base : base.applyingPendingConfirms(syncModel.pending)
    }

    /// The rows the transcript search runs over: speaker turns when diarized,
    /// else the flat transcript as one row.
    private var searchRows: [String] {
        if let diarized = diarizedTranscript { return diarized.turns.map(\.text) }
        if let t = transcriptText { return [t] }
        return []
    }

    /// The meaning toggle exists ONLY when a real index is injected + available.
    private var meaningOffered: Bool {
        TranscriptSearchCapability.meaningSearchOffered(meaningIndex)
    }

    // MARK: - where this recording is

    /// WHETHER ANYTHING CAME OUT OF IT, joined in the kit from the gate's own decision log.
    private var ambientReading: AmbientReading {
        // THE FACE, NOT A COUNT OF PART OF IT. This passed `actions.rows.count`, which
        // excludes the "Heard from others" group — so a voice note whose only surfaced
        // item was said by somebody else read "Solleva read this voice note and found
        // nothing to act on" directly above that item. What counts as surfaced is now
        // `ConversationActionsPresentation.surfaced`, decided in the kit.
        AmbientReading.reading(hasTranscript: transcriptText != nil,
                               decisions: decisions,
                               actions: actions)
    }

    /// THE JOURNEY. Every input is something this phone measured, and the join itself lives in
    /// `CaptureJourneyReading.detail` so `swift test` can execute it — this property is a
    /// forwarding call and deliberately contains no rule of its own.
    ///
    /// `brain` (NOT `local`) decides the destination: `local` is a Bool that reads false on both
    /// the computer and the cell tiers, which is the crush that told a Vault owner with no
    /// computer that his voice notes were saved to one.
    private var journey: CaptureJourney {
        CaptureJourney.build(.detail(
            status: manager.captures.first { $0.status.id == captureId }?.status,
            brain: brain,
            // `heldHere` is the recorder's OWN file, on this phone. Its presence is evidence the
            // transfer FINISHED — `.arrived`, not "a transfer is happening" — and nothing in the
            // app measures the bytes as they come, so there is no `.measured` reading to pass.
            // Wiring a live one is the BLE client's seam, not this view's.
            transfer: heldHere != nil ? .arrived : RecorderTransfer.none,
            cardStage: provisional?.stage,
            content: content,
            hasTranscript: transcriptText != nil,
            separatedSpeakers: diarizedTranscript?.speakers.count ?? 0,
            hasSummary: summaryText != nil,
            synthesizingSummary: summarizing,
            decisions: decisions,
            actions: actions,
            // The door's terminal drop reason, read off the durable card tombstone the
            // poller persists it to — so a failed voice note's transcript step says WHY
            // instead of the generic line. This argument used to be a hardcoded nil
            // inside the join, which made the tested failure sentence unreachable.
            droppedReason: provisional?.droppedReason))
    }

    /// Re-take the name reading. Called whenever a transcript or a title could have changed; the
    /// latch inside `ConversationNameOnTheRow` is what makes calling it often harmless.
    private func refreshName() {
        nameOnTheRow.adopt(early: earlyName?.name, settled: settledTitle)
    }

    // MARK: - body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                    metadataHeader
                    // WHAT IS HAPPENING TO THIS RECORDING. Shown while any step is still
                    // unfinished and stepped aside once everything that can finish has — a
                    // ladder of ticks on a settled recording is furniture, not information.
                    if journey.current != nil {
                        CaptureJourneyStrip(journey: journey)
                    }
                    // THE NAME SAYS IT IS EARLY, for exactly as long as it is early. A rename
                    // somebody was told to expect is a rename; one they were not is a glitch.
                    if nameOnTheRow.isProvisional, let note = earlyName?.note {
                        Text(note)
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textFaint)
                            .accessibilityIdentifier("early-name-note")
                    }
                    facePicker
                    switch face {
                    case .summary: summaryFace
                    case .actions: actionsFace
                    case .transcript: transcriptFace
                    }
                }
                .padding(GrainSpacing.x4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: search.current) { current in
                scrollToCurrentMatch(current, proxy: proxy)
            }
        }
        .grainBackground()
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if copyableTranscript != nil {
                        Button {
                            copyTranscript()
                        } label: {
                            Label {
                                Text("Copy transcript")
                            } icon: {
                                Image(grain: .doc)
                            }
                        }
                    }
                    Button("Delete", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete voice note?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                manager.deleteConversation(captureId)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes it from your phone, your computer, and your library.")
        }
        .refreshable { await fetchFromDoor() }
        .task { await initialLoad() }
        .task { await loadDecisions() }
        // The two readings the name depends on, each of which can land minutes after the view
        // opened: the transcript (which makes an early name possible) and the settled title.
        .onChange(of: transcriptText) { _ in refreshName() }
        .onChange(of: settledTitle) { _ in refreshName() }
        .onAppear {
            loadFaceData()
            syncModel.bind(captureId: captureId, baseDir: CaptureWAL.documentsCaptures())
        }
        // The Mac ACK'd a queued confirm: adopt the canonical name/id and, if it matched
        // past conversations, surface the apply offer non-modally (local-first Section H).
        .onReceive(NotificationCenter.default.publisher(for: .foundryxSpeakerConfirmSynced)) { note in
            guard let outcome = note.userInfo?["outcome"] as? ConfirmOutcome,
                  outcome.captureId == captureId else { return }
            applyConfirmedSpeaker(outcome)
            if SpeakerLateOffer.shouldSurface(offeredCount: outcome.offeredCaptures.count,
                                              sheetPresenting: tagSheetPresenting) {
                lateOffer = outcome
            }
        }
        // The Mac rejected a queued confirm (rare 4xx): reconcile to server truth. The
        // gentle revert notice is shown by the row (driven by the sync model).
        .onReceive(NotificationCenter.default.publisher(for: .foundryxSpeakerConfirmRejected)) { note in
            guard (note.userInfo?["captureId"] as? String) == captureId else { return }
            Task { await fetchFromDoor() }
        }
        #if DEBUG
        // Deterministic screen-proof of the Listen row states without a live door:
        //   -AudioProof loading      → the "Loading audio…" state
        //   -AudioProof playing      → seeds the in-memory replay cache with a short
        //                              silent clip and plays it (the "Stop" state)
        //   -AudioProof unavailable  → "Audio no longer available" (pruned)
        //   -AudioProof unreachable  → "Can't reach your computer" (offline)
        // Visual-only; production behavior and the in-memory-only cache are unchanged.
        .onAppear { applyAudioProofIfRequested() }
        #endif
        .onDisappear { stopPlayback() }
        .sheet(isPresented: $showRelayAnswer) {
            if let answer = linkedAnswer {
                relayAnswerSheet(answer)
            }
        }
        .onChange(of: query) { newQuery in
            if meaningMode {
                runMeaningSearch(newQuery)
            } else {
                search = TranscriptSearchState(
                    matches: TranscriptSearch.matches(query: newQuery, in: searchRows))
            }
        }
    }

    // MARK: - header + face picker

    private var metadataHeader: some View {
        HStack(spacing: GrainSpacing.x2) {
            metadataTag(
                timeRange,
                foreground: GrainColor.forgeBlue,
                background: GrainColor.forgeBlueBg,
                border: GrainColor.forgeBlueBorder
            )
            if let place {
                metadataTag(
                    place,
                    foreground: GrainColor.textMuted,
                    background: GrainColor.surface,
                    border: GrainColor.borderFaint
                )
            }
            // THE RECORDER, NAMED BESIDE ITS OWN RECORDING. This is the surface the whole
            // device-agnostic track exists for: until it landed, the device on the row a user
            // tapped never appeared against anything it recorded. An unnameable recorder is
            // shown WITH its diagnostic rather than as a bare "Unknown device".
            if let attribution {
                metadataTag(
                    attribution.isKnown
                        ? attribution.deviceName
                        : "\(attribution.deviceName) — \(attribution.diagnostic ?? "")",
                    foreground: GrainColor.textMuted,
                    background: GrainColor.surface,
                    border: GrainColor.borderFaint
                )
                .accessibilityIdentifier("conversation-device")
            }
            Spacer(minLength: 0)
        }
    }

    private func metadataTag(
        _ text: String, foreground: Color, background: Color, border: Color
    ) -> some View {
        Text(text)
            .grainTextStyle(.caption)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, GrainSpacing.x2)
            .padding(.vertical, GrainSpacing.x1)
            .background(Capsule().fill(background))
            .overlay(Capsule().strokeBorder(border, lineWidth: 1))
    }

    private var selectedPillForeground: Color {
        colorScheme == .dark ? GrainColor.ink : GrainColor.surface
    }

    /// Three equal face choices, matching the approved standalone-pill control.
    private var facePicker: some View {
        HStack(spacing: GrainSpacing.x2) {
            ForEach(DetailFace.allCases) { f in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { face = f }
                } label: {
                    Text(f.title)
                        .grainTextStyle(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(face == f ? selectedPillForeground : GrainColor.textMuted)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: GrainSpacing.x8)
                        .background(Capsule().fill(face == f ? GrainColor.forgeBlue : .clear))
                        .overlay(Capsule().strokeBorder(
                            face == f ? GrainColor.forgeBlue : GrainColor.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("face-\(f.rawValue)")
                .accessibilityAddTraits(face == f ? .isSelected : [])
            }
        }
    }

    // MARK: - Summary face

    private var summaryFace: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x4) {
            // `listenRow` directly (no wrapping HStack + trailing Spacer): the idle
            // "Listen" button keeps its intrinsic size, and the PLAYING transport's
            // scrubber fills the row instead of fighting a Spacer for the width.
            listenRow
            whereThisRecordingIsRow
            VStack(alignment: .leading, spacing: GrainSpacing.x3) {
                summaryNarrative
                if !summaryBullets.isEmpty {
                    whatMatteredList
                }
            }
            .padding(.vertical, GrainSpacing.x3)
            .overlay(alignment: .top) {
                Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
            }
            if let answer = linkedAnswer {
                relayAnswerRow(answer)
            }
            receiptSection
        }
    }

    /// The "What mattered" bullets, derived from the summary text by the pure
    /// FoundryXKit builder the brine step-defs drive.
    private var summaryBullets: [String] {
        ConversationSummaryPresentation.bullets(fromSummary: summaryText)
    }

    private var whatMatteredList: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            Text(ConversationSummaryPresentation.whatMatteredLabel)
                .grainTextStyle(.caption)
                .fontWeight(.semibold)
                .textCase(.uppercase)
                .foregroundStyle(GrainColor.textMuted)
            VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                ForEach(Array(summaryBullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: GrainSpacing.x2) {
                        Text("\u{2022}")
                            .grainTextStyle(.body)
                            .foregroundStyle(GrainColor.forgeBlue)
                        Text(bullet)
                            .grainTextStyle(.body)
                            .foregroundStyle(GrainColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.top, GrainSpacing.x2)
    }

    /// The "Open the relay answer" text-action — present only when an ambient
    /// answer surfaced from THIS capture (never a dead control).
    private func relayAnswerRow(_ answer: LinkedConversationAnswer) -> some View {
        Button {
            showRelayAnswer = true
        } label: {
            GrainSuggestionCard(
                systemImage: "sparkles",
                tint: .memory,
                eyebrow: AnswerCopy.kicker,
                title: ConversationSummaryPresentation.openRelayAnswerLabel,
                body: answer.title
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("open-relay-answer")
    }

    private func relayAnswerSheet(_ answer: LinkedConversationAnswer) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GrainSpacing.x3) {
                    Text("From your memory")
                        .grainTextStyle(.caption)
                        .textCase(.uppercase)
                        .foregroundStyle(GrainColor.amber)
                    Text(answer.title)
                        .grainTextStyle(.title)
                        .foregroundStyle(GrainColor.ink)
                    Text(answer.text)
                        .grainTextStyle(.body)
                        .foregroundStyle(GrainColor.ink)
                        .textSelection(.enabled)
                }
                .padding(GrainSpacing.x4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .grainBackground()
            .navigationTitle("Relay answer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showRelayAnswer = false }
                }
            }
        }
    }

    @ViewBuilder private var summaryNarrative: some View {
        if let summary = summaryText, !summary.isEmpty {
            Text(summary)
                .grainTextStyle(.body)
                .fontWeight(.medium)
                .foregroundStyle(GrainColor.ink)
                .textSelection(.enabled)
        } else if content?.summarizing == true {
            // The BRAIN's pipeline (Mac or Vault) is authoritatively titling +
            // summarizing — that wins over the local fallback so we don't relabel
            // remote processing (WS-C). Name the brain the app actually resolved to.
            WaitingExperienceView(kind: .title, compact: true)
        } else if summarizing {
            // On-device titling + summary synth in flight (WS-C) — the PHONE is doing
            // this one, whatever the tier.
            WaitingExperienceView(kind: .onDeviceTitle, compact: true)
        } else if transcriptText != nil {
            Text("No summary yet. The transcript face has the full voice note.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        } else if !loading {
            Text("Nothing to summarize yet. The summary appears once the voice note is processed.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        }
    }

    // MARK: - Actions face

    @ViewBuilder private var actionsFace: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x4) {
            if actions.isEmpty {
                // WHICH KIND OF NOTHING. `ConversationActionsPresentation.emptyStateText` —
                // "Nothing surfaced from this voice note yet." — was shown to a recording with
                // no transcript, to one the gate read and found nothing in, and to one whose
                // gate never ran, so it could not answer Nick's "or if any ambient intelligence
                // came from it?" for three of its four meanings. `AmbientReading` reads the
                // lane's own decision log and says which it is.
                Text(ambientReading.line)
                    .grainTextStyle(.body)
                    .foregroundStyle(GrainColor.textMuted)
                    .padding(.vertical, GrainSpacing.x3)
                    .accessibilityIdentifier("actions-empty-state")
            } else {
                if actions.rows.isEmpty {
                    // Everything surfaced was said by OTHERS — say so instead of
                    // rendering an empty bordered block above the group.
                    Text("Nothing you said surfaced as an action.")
                        .grainTextStyle(.body)
                        .foregroundStyle(GrainColor.textMuted)
                        .padding(.vertical, GrainSpacing.x3)
                } else {
                    VStack(spacing: 0) {
                        Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
                        ForEach(actions.rows) { row in
                            actionRow(row)
                        }
                    }
                }
                heardFromOthersGroup
            }
            addActionControl
        }
        .sheet(item: $selectedAction) { row in
            actionOptionsSheet(row)
        }
    }

    /// The collapsed "Heard from others" group (features/
    /// action-speaker-attribution.feature): actions OTHER people said —
    /// detected and kept, one tap away, out of the main list. Absent when
    /// empty (or when the "Actions from others" setting puts everyone inline).
    @ViewBuilder private var heardFromOthersGroup: some View {
        if !actions.othersRows.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation { othersExpanded.toggle() }
                } label: {
                    HStack(spacing: GrainSpacing.x2) {
                        Text("\(ConversationActionsPresentation.othersGroupLabel) (\(actions.othersRows.count))")
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textMuted)
                        Spacer()
                        Image(systemName: othersExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                            .foregroundStyle(GrainColor.textFaint)
                    }
                    .padding(.vertical, GrainSpacing.x3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("heard-from-others")
                if othersExpanded {
                    Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
                    ForEach(actions.othersRows) { row in
                        actionRow(row, fromOthers: true)
                    }
                }
            }
        }
    }

    private func actionRow(_ row: ConversationActionsPresentation.Row,
                           fromOthers: Bool = false) -> some View {
        // Tapping ANY action row opens its options sheet — act on it in chat,
        // refine it, or mark it "Not an action" (track 20260715T1500 addendum).
        Button {
            selectedFromOthers = fromOthers
            selectedAction = row
        } label: {
            HStack(alignment: .top, spacing: GrainSpacing.x3) {
                ZStack {
                    RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous)
                        .fill(actionKindTint(row.kind).opacity(0.12))
                    Image(grain: actionIcon(row))
                        .grainTextStyle(.body)
                        .foregroundStyle(actionKindTint(row.kind))
                }
                .frame(width: GrainSpacing.x8, height: GrainSpacing.x8)

                VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                    Text(row.label)
                        .grainTextStyle(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(GrainColor.ink)
                        .multilineTextAlignment(.leading)
                    // WHO said it — "You said" / "<name> said" / "Unknown
                    // speaker" / the honest pending/unclear words.
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
                            .multilineTextAlignment(.leading)
                    }
                    if let note = row.note, !note.isEmpty {
                        Text("Your note: \(note)")
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.amber)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: GrainSpacing.x2)
                GrainStatusWord(
                    row.state.rawValue,
                    tone: actionStatusTone(row.state),
                    showsDot: false
                )
            }
            .padding(.vertical, GrainSpacing.x3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("action-row-\(row.id)")
        .overlay(alignment: .bottom) {
            Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
        }
    }

    /// The "Add an action" affordance: a quiet button that opens an inline
    /// field; the added action persists in the per-capture UserActionStore.
    @ViewBuilder private var addActionControl: some View {
        if addingAction {
            HStack(spacing: GrainSpacing.x2) {
                TextField("What needs doing?", text: $newActionTitle)
                    .textFieldStyle(.plain)
                    .grainTextStyle(.body)
                    .foregroundStyle(GrainColor.ink)
                    .submitLabel(.done)
                    .onSubmit { commitNewAction() }
                    .accessibilityIdentifier("new-action-title")
                GrainButton("Add", variant: .filled, size: .sm) { commitNewAction() }
            }
            .padding(GrainSpacing.x3)
            .background(
                RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                    .fill(GrainColor.surface))
            .overlay(
                RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                    .strokeBorder(GrainColor.border, lineWidth: 1))
        } else {
            GrainButton(ConversationActionsPresentation.addActionLabel,
                        variant: .outlined, size: .regular) {
                addingAction = true
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("add-an-action")
        }
    }

    private func commitNewAction() {
        UserActionStore.add(title: newActionTitle, captureId: captureId,
                            baseDir: CaptureWAL.documentsCaptures())
        newActionTitle = ""
        addingAction = false
        loadFaceData()
    }

    // MARK: action options (track 20260715T1500 addendum)

    /// The options sheet for a tapped action row — built by the SHARED
    /// ActionFeedbackFlow (EXT1: one component across every action surface):
    /// continue-in-chat (linked), act-in-chat (prefill), refine, not-an-action.
    private func actionOptionsSheet(_ row: ConversationActionsPresentation.Row) -> some View {
        ActionFeedbackFlow.sheet(row: row, captureId: captureId, destination: destination,
                                 inOthersGroup: selectedFromOthers) {
            loadFaceData()
        }
    }

    /// The Actions-face icon keys on the action's TYPE (`row.kind`), not its state:
    /// a surfaced nudge reads as a bolt, an answer from memory as a spark, a
    /// hand-added action as a pencil — so the row's ORIGIN is legible at a glance
    /// (AC1/AC2). The state still shows in the trailing status word.
    private func actionIcon(_ row: ConversationActionsPresentation.Row) -> GrainIcon {
        switch row.kind {
        case .surfaced: return .bolt
        case .answer: return .spark
        case .user: return .pencil
        }
    }

    /// The per-type tint that colors both the icon glyph and its tile (AC1): a
    /// surfaced item forge, an answer amber, a user-added action a neutral muted.
    private func actionKindTint(_ kind: ConversationActionsPresentation.Row.Kind) -> Color {
        switch kind {
        case .surfaced: return GrainColor.forgeBlue
        case .answer: return GrainColor.amber
        case .user: return GrainColor.textMuted
        }
    }

    private func actionStatusTone(
        _ state: ConversationActionsPresentation.Row.State
    ) -> GrainStatusTone {
        switch state {
        case .completed, .ready: return .ready
        case .open: return .attention
        case .dismissed, .notAnAction: return .neutral
        }
    }

    /// Build both presentation faces for THIS conversation from the intelligence
    /// lane's logs + the per-capture user-action store, via the SHARED
    /// ActionFeedbackFlow builder (one join across all surfaces). Read-only.
    private func loadFaceData() {
        let decisionLog = AmbientPrefs.decisionLogURL()
        let answers = ConversationAnswerLog.answers(
            at: ActivityStore.answersLogURL(besides: decisionLog), captureId: captureId)
        linkedAnswer = answers.first
        // Attribution prefers the in-memory diarized transcript (fresher than
        // disk mid-fetch); the shared builder falls back to the cache.
        actions = ActionFeedbackFlow.presentation(captureId: captureId,
                                                  transcript: diarizedTranscript)
        nameOnTheRow.adopt(early: earlyName?.name, settled: settledTitle)
    }

    /// THE GATE'S OWN RECORD FOR THIS CAPTURE — the evidence that separates "read and found
    /// nothing" from "never read" from "could not read".
    ///
    /// OFF THE MAIN ACTOR, DELIBERATELY. `readDecisions` reads and decodes the WHOLE decision
    /// JSONL, which grows one line per gated window for every capture on the phone. This app has
    /// already paid for a main-thread whole-file read on a detail open once (175 `card.json`
    /// loads at `RootView:627`, measured as a 6.6 s nav stall); a second one added by hand would
    /// be the same defect with a different file name.
    private func loadDecisions() async {
        let url = AmbientPrefs.decisionLogURL()
        let id = captureId
        let read = await Task.detached(priority: .utility) {
            AmbientLane.readDecisions(at: url).filter { $0.captureId == id }
        }.value
        decisions = read
    }

    // MARK: - Transcript face

    @ViewBuilder private var transcriptFace: some View {
        if let transcript = transcriptText {
            VStack(alignment: .leading, spacing: GrainSpacing.x3) {
                searchBar
                if showingProvisional {
                    Text(ConversationDetailCopy.provisionalTranscriptNote(
                        destination: destination))
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                }
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        copyTranscript()
                    } label: {
                        HStack(spacing: GrainSpacing.x1) {
                            Image(grain: didCopy ? .check : .doc)
                            Text(didCopy ? "Copied" : "Copy")
                        }
                        .grainTextStyle(.caption)
                        .foregroundStyle(didCopy ? GrainColor.sage : GrainColor.forgeBlue)
                        .padding(.horizontal, GrainSpacing.x2)
                        .frame(minHeight: GrainSpacing.x8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("copy-transcript")
                }
                if let diarized = diarizedTranscript {
                    if let lateOffer, !lateOffer.offeredCaptures.isEmpty {
                        lateOfferBanner(lateOffer)
                    }
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        GrainSpeakerTranscriptRows(
                            target: target,
                            captureId: captureId,
                            transcript: diarized,
                            onChanged: { await fetchFromDoor() },
                            onConfirmed: { outcome in applyConfirmedSpeaker(outcome) },
                            isRecording: isRecordingActive,
                            confirmController: confirmController,
                            syncModel: syncModel,
                            sheetPresenting: $tagSheetPresenting
                        )
                    } else {
                        // GrainSpeakerRow intentionally accepts plain words. Keep the
                        // existing attributed renderer while search is active so match
                        // highlights and next/previous scrolling remain unchanged.
                        SpeakerTranscriptSection(
                            target: target,
                            captureId: captureId,
                            transcript: diarized,
                            onChanged: { await fetchFromDoor() },
                            onConfirmed: { outcome in applyConfirmedSpeaker(outcome) },
                            searchMatches: search.matches,
                            currentMatch: search.current,
                            isRecording: isRecordingActive,
                            confirmController: confirmController,
                            syncModel: syncModel,
                            sheetPresenting: $tagSheetPresenting
                        )
                    }
                } else {
                    Text(TranscriptHighlighter.attributed(
                        transcript,
                        ranges: search.matches.filter { $0.row == 0 }.map(\.range),
                        current: search.current.flatMap { $0.row == 0 ? $0.range : nil }))
                        .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                        .textSelection(.enabled)
                        .padding(.vertical, GrainSpacing.x3)
                        .overlay(alignment: .top) {
                            Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
                        }
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
                        }
                        .id("flat-transcript")
                }
            }
        } else if loading {
            // Door fetch from the resolved brain (WS-C honest wait) — the copy names
            // the place actually answering: Mac, Vault, or this phone's own storage.
            WaitingExperienceView(kind: .doorFetch)
        } else if didAttemptFetch, content?.found == false, loadError == nil {
            // ⚠ `/content` SAYING `found:false` IS NOT EVIDENCE THAT TRANSCRIPTION IS RUNNING.
            //
            // This branch used to render the transcription wait on `found == false` alone, with
            // no reference to what the door said about the capture. So a capture the door
            // reports as `transcribed:true` whose content simply is not there — the live
            // capture's exact state — read "the transcript is still being produced", FOREVER.
            // That is the same shape as the four-day `summarizing: true` defect: an absence
            // presented as work in flight.
            //
            // Now the door's own reading decides. `.inProgress` and `.notStarted` are the two
            // states where a wait is TRUE. `.done` (content missing for another reason) and
            // `.failed` (it never will arrive) are not, and neither is an absent reading —
            // which falls back to the previous behaviour rather than inventing a stage.
            if doorStage?.transcript.isAWait ?? true {
                WaitingExperienceView(kind: .transcription)
            } else {
                Text("Transcript not loaded")
                    .grainTextStyle(.title).foregroundStyle(GrainColor.ink)
                Text(ConversationDetailCopy.loadTranscriptNote(isOlder: isOlder,
                                                               destination: destination))
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }
            GrainButton("Check again", variant: .tonal, size: .sm) { Task { await fetchFromDoor() } }
        } else {
            Text("Transcript not loaded")
                .grainTextStyle(.title).foregroundStyle(GrainColor.ink)
            Text(ConversationDetailCopy.loadTranscriptNote(isOlder: isOlder,
                                                           destination: destination))
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            GrainButton("Load transcript", variant: .filled, size: .sm) { Task { await fetchFromDoor() } }
            if let loadError {
                // `loadError` is already an honest, actionable sentence (DoorFailureMessage) —
                // it is NOT a transport string, so it needs no "Couldn't load transcript:"
                // prefix explaining that something failed. The user can see that.
                Text(loadError)
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.amber)
            }
        }
    }

    /// Search field + match count + next/previous. The text/meaning toggle is
    /// rendered ONLY when a real meaning index is available (AC3 honesty).
    @ViewBuilder private var searchBar: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            VStack(spacing: 0) {
                HStack(spacing: GrainSpacing.x2) {
                    Image(grain: .search)
                        .grainTextStyle(.body)
                        .foregroundStyle(GrainColor.textMuted)
                    TextField("Search this transcript", text: $query)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .grainTextStyle(.body)
                        .foregroundStyle(GrainColor.ink)
                        .accessibilityIdentifier("transcript-search")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(GrainColor.textFaint)
                                .frame(width: GrainSpacing.x8, height: GrainSpacing.x8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.leading, GrainSpacing.x3)
                .padding(.trailing, GrainSpacing.x1)
                .frame(minHeight: GrainSpacing.x8 + GrainSpacing.x2)

                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    HStack(spacing: GrainSpacing.x2) {
                        if meaningBusy {
                            ProgressView().controlSize(.small)
                            Text("Searching by meaning…")
                                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                        } else {
                            Text(search.positionLabel)
                                .grainTextStyle(.caption)
                                .foregroundStyle(search.count > 0 ? GrainColor.ink : GrainColor.textMuted)
                                .accessibilityIdentifier("match-count")
                        }
                        Spacer(minLength: GrainSpacing.x2)
                        searchNavigationButton(
                            systemName: "chevron.up",
                            accessibilityLabel: "Previous match",
                            enabled: search.count > 0
                        ) { search.previous() }
                        searchNavigationButton(
                            systemName: "chevron.down",
                            accessibilityLabel: "Next match",
                            enabled: search.count > 0
                        ) { search.next() }
                    }
                    .padding(.leading, GrainSpacing.x3)
                    .padding(.trailing, GrainSpacing.x1)
                    .padding(.vertical, GrainSpacing.x1)
                    .overlay(alignment: .top) {
                        Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                    .fill(GrainColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                    .strokeBorder(GrainColor.border, lineWidth: 1)
            )

            // AC3 — the meaning toggle EXISTS only when a real index is available.
            if meaningOffered {
                HStack(spacing: GrainSpacing.x1) {
                    modeChip("Text", active: !meaningMode) { setMeaningMode(false) }
                    modeChip("Meaning", active: meaningMode) { setMeaningMode(true) }
                }
            }
        }
    }

    private func searchNavigationButton(
        systemName: String,
        accessibilityLabel: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .grainTextStyle(.body)
                .foregroundStyle(enabled ? GrainColor.ink : GrainColor.textFaint)
                .frame(width: GrainSpacing.x8, height: GrainSpacing.x8)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private func modeChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .grainTextStyle(.caption)
                .foregroundStyle(active ? selectedPillForeground : GrainColor.textMuted)
                .padding(.horizontal, GrainSpacing.x3)
                .frame(minHeight: GrainSpacing.x8)
                .background(Capsule().fill(active ? GrainColor.forgeBlue : .clear))
                .overlay(Capsule().strokeBorder(
                    active ? GrainColor.forgeBlue : GrainColor.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func setMeaningMode(_ on: Bool) {
        guard meaningMode != on else { return }
        meaningMode = on
        if on {
            runMeaningSearch(query)
        } else {
            search = TranscriptSearchState(
                matches: TranscriptSearch.matches(query: query, in: searchRows))
        }
    }

    /// Nearest-passage search through the injected index: each returned row is
    /// emphasized whole (the passage, not a substring). Only reachable when the
    /// toggle exists, i.e. a real index answered `isAvailable`.
    private func runMeaningSearch(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = meaningIndex, meaningOffered, !trimmed.isEmpty else {
            search = TranscriptSearchState(matches: [])
            return
        }
        meaningBusy = true
        let rows = searchRows
        Task {
            let results = (try? await index.nearestPassages(to: trimmed, limit: 5)) ?? []
            let matches = results.compactMap { m -> TranscriptMatch? in
                guard rows.indices.contains(m.row), !rows[m.row].isEmpty else { return nil }
                return TranscriptMatch(row: m.row, range: 0..<rows[m.row].count)
            }
            await MainActor.run {
                search = TranscriptSearchState(matches: matches)
                meaningBusy = false
            }
        }
    }

    private func scrollToCurrentMatch(_ current: TranscriptMatch?, proxy: ScrollViewProxy) {
        guard let current else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            if let diarized = diarizedTranscript, diarized.turns.indices.contains(current.row) {
                proxy.scrollTo(diarized.turns[current.row].id, anchor: .center)
            } else {
                proxy.scrollTo("flat-transcript", anchor: .top)
            }
        }
    }

    // MARK: - listen / receipt (unchanged behavior)

    /// WHERE THIS RECORDING IS — ALL THREE PLACES AT ONCE, each with its own age, and a place
    /// nobody asked about reading `Unknown` rather than a confident `No`. Present ONLY for a
    /// recording that came off a recorder: every other conversation has exactly one home and a
    /// three-line answer about it would be noise.
    ///
    /// The strings are `PocketPresencePresentation`'s — Step 5's vocabulary, not a second one —
    /// and the last line names the thing Solleva deliberately does not do: Listen and reclaiming
    /// this local copy delete each other, Listen shipped, and a capability that is missing on
    /// purpose is said out loud instead of discovered as an absence.
    @ViewBuilder private var whereThisRecordingIsRow: some View {
        if let places = placesHere {
            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                Text(PocketLocalCopyPresentation.playsHereLine)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
                ForEach(Array(PocketPresencePresentation.lines(places, now: Date()).enumerated()),
                        id: \.offset) { _, line in
                    Text(PocketPresencePresentation.oneLine(line))
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                }
                Text(PocketLocalCopyPresentation.keptHereLine)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
            }
            .accessibilityIdentifier("where-this-recording-is")
        }
    }

    @ViewBuilder private var listenRow: some View {
        // Recording wins the audio session: while it's live, Listen is DISABLED with an
        // honest reason (never start new playback that would fight the mic). An already
        // playing clip is left to finish (the session guard prevents category theft).
        if case .playing = audioState {
            playingControls
        } else if let reason = AudioPlaybackPresentation.playbackDisabledReason(isRecording: isRecordingActive) {
            Text(reason).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
        } else {
            switch audioState {
            case .idle:
                GrainButton("Listen", variant: .tonal, size: .sm) { Task { await playAudio() } }
            case .loading:
                Text("Loading audio…").grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            case .playing:
                playingControls
            case .failure(let outcome):
                audioFailureLabel(outcome)
            }
        }
    }

    /// The WHOLE-conversation player, playing: Stop + a scrubber you can drag to any point
    /// + an "elapsed / total" readout. Fills the row so it reads as a real transport, not
    /// a bare Stop button (GAP b232 — "play/listen to the WHOLE conversation").
    @ViewBuilder private var playingControls: some View {
        HStack(spacing: GrainSpacing.x2) {
            GrainButton("Stop", variant: .text, size: .sm) { stopPlayback() }
            Slider(
                value: $playbackElapsed,
                in: 0...max(playbackDuration, 1),
                onEditingChanged: { editing in
                    scrubbing = editing
                    if !editing { player?.currentTime = playbackElapsed }   // seek on release
                }
            )
            .tint(GrainColor.forgeBlue)
            .accessibilityIdentifier("listen-scrubber")
            Text(AudioPlaybackPresentation.elapsed(
                currentSeconds: playbackElapsed, durationSeconds: playbackDuration))
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .monospacedDigit()
                .accessibilityIdentifier("listen-elapsed")
        }
    }

    /// Honest, non-technical copy for a playback failure — a pruned recording reads
    /// distinctly (soft, faint) from an unreachable computer (soft, muted); a real
    /// failure smolders amber. Never raw NSError text.
    @ViewBuilder private func audioFailureLabel(_ outcome: AudioPlaybackPresentation.Outcome) -> some View {
        let copy = AudioPlaybackPresentation.copy(for: outcome)
        let tint: Color = {
            switch outcome {
            case .unavailable: return GrainColor.textFaint
            case .unreachable: return GrainColor.textMuted
            case .failed:      return GrainColor.amber
            // The bytes are HERE and could not be decoded — a real fault in this app's own
            // container, so it smolders like `.failed` rather than reading as a soft absence.
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

    private var receiptSection: some View {
        DisclosureGroup(isExpanded: $receiptExpanded) {
            VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                receiptRow("Voice note", receiptDuration)
                receiptRow("Transcription", "Transcribed in the cloud (Deepgram)")
                receiptRow("Speakers", "Speakers found on-device (WeSpeaker)")
                receiptRow("Device cost", "$0 on your device")
            }
            .padding(.top, GrainSpacing.x2)
        } label: {
            HStack(spacing: GrainSpacing.x2) {
                Image(grain: .doc)
                    .foregroundStyle(GrainColor.textMuted)
                Text("Processing receipt")
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
            }
        }
        .grainTextStyle(.caption)
        .foregroundStyle(GrainColor.textMuted)
        .padding(.vertical, GrainSpacing.x1)
    }

    private func receiptRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GrainSpacing.x2) {
            Text(label)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)
                .frame(
                    width: GrainSpacing.x8 + GrainSpacing.x8 + GrainSpacing.x8,
                    alignment: .leading
                )
            Text(value)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var receiptDuration: String {
        guard let seconds = manager.conversationMeta(for: captureId)?.durationSeconds else {
            return "Voice note duration unavailable"
        }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
        }
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }

    // MARK: - title / copy

    /// The authoritative name, if one exists anywhere. Nil is what makes an early name eligible.
    private var settledTitle: String? {
        if let t = content?.title, !t.isEmpty { return t }
        if let t = cached?.title, !t.isEmpty { return t }
        if let t = provisional?.title, !t.isEmpty { return t }
        return nil
    }

    /// THE EARLY NAME, from the recording's opening window, the moment any transcript exists.
    ///
    /// It replaces a six-word prefix of the whole transcript that this view took as a title —
    /// which named a recording after wherever its first six words happened to fall, with no
    /// filler-skipping and no salience, and with nothing on screen saying it was provisional.
    private var earlyName: EarlyConversationName.Offer? {
        EarlyConversationName.offer(segments: diarizedTranscript?.segments ?? [],
                                    paragraphs: content?.paragraphs ?? [],
                                    flat: transcriptText)
    }

    private var navTitle: String { nameOnTheRow.name ?? "Voice note" }

    private func copyTranscript() {
        guard let text = copyableTranscript else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        didCopy = true
        Task { try? await Task.sleep(nanoseconds: 1_600_000_000); await MainActor.run { didCopy = false } }
    }

    // MARK: - load pipeline (same semantics as the previous detail)

    private func initialLoad() async {
        loadError = nil
        // BEFORE ANYTHING REACHES FOR THE DOOR. If this recording came off a recorder its
        // bytes are already on this phone, and the Listen row must know that before a person
        // can tap it.
        await resolveHeldRecording()
        let base = CaptureWAL.documentsCaptures()
        cached = TranscriptCacheStore.load(captureId: captureId, baseDir: base)
        provisional = ConversationCardStore.load(captureId: captureId, baseDir: base)
        // Kick the on-device summary synth off the loaded cache/card (AC2) — a no-op
        // when a summary already exists or no transcript is on the phone yet.
        maybeSynthesizeSummary()
        if cached != nil {
            loading = false
            // The cache renders instantly but may predate diarization / a fresher
            // title — refresh from the door in the background.
            await fetchFromDoor()
            return
        }
        if isOlder {
            loading = false   // older + uncached: load on demand
            return
        }
        await fetchFromDoor()
    }

    private func fetchFromDoor() async {
        guard let workBinding = CaptureAccountScope.currentAccountBinding() else {
            loading = false
            return
        }
        if cached == nil { loading = true }
        loadError = nil
        didAttemptFetch = true
        do {
            // THE STAGE, ALONGSIDE THE CONTENT. Best-effort on purpose: a capture whose
            // transcript loads fine must not fail because `/status` was unreachable. An absent
            // reading falls back to the old behaviour rather than inventing a stage.
            if let status = try? await DoorClient(target: target).captureStatus(captureId: captureId) {
                doorStage = RecordingJourneyReading.fromStatus(status)
            }
            let fetched = try await DoorClient(target: target).captureContent(captureId: captureId)
            if cached == nil || contentDiffersFromCache(fetched) {
                guard CaptureAccountScope.perform(
                    as: workBinding,
                    { binding in
                        content = fetched
                        cacheIfReady(fetched, binding: binding)
                        return true
                    }) == true else { return }
            }
        } catch {
            // Say the TRUE, actionable thing — never forward the transport string. A door
            // fetch that fails because the Mac's door isn't connected to the relay used to
            // render as "Could not connect to the server", which reads as "your network is
            // broken" and sent us hunting a phantom phone-connectivity bug for hours on a
            // phone whose network was perfect. Sign-in is now required to reach this screen
            // at all, so a transport failure here means exactly one thing: the computer is
            // not reachable. (DoorFailureMessage, tested.)
            if cached == nil {
                loadError = DoorFailureMessage.make(doorTransportFailure: error, destination: destination).line
            }
        }
        loading = false
        refreshSearchAfterContentChange()
        // Diarization may have just LANDED (or refreshed) — re-resolve WHO said
        // each surfaced action so others-uttered ones re-file out of the main
        // list now, not on the next open (the attribution reconcile).
        loadFaceData()
        // Door content may have just landed a transcript with no summary (AC2).
        maybeSynthesizeSummary()
        if content?.summarizing == true, (content?.title ?? "").isEmpty {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let refreshed = try? await DoorClient(target: target).captureContent(captureId: captureId) {
                if cached == nil || contentDiffersFromCache(refreshed) {
                    guard CaptureAccountScope.perform(
                        as: workBinding,
                        { binding in
                            content = refreshed
                            cacheIfReady(refreshed, binding: binding)
                            return true
                        }) == true else { return }
                    refreshSearchAfterContentChange()
                    loadFaceData()
                }
            }
        }
    }

    /// A content refresh can change the rows under an active search (new turns,
    /// fresher diarization) — recompute so highlights never point at stale rows.
    private func refreshSearchAfterContentChange() {
        guard !query.isEmpty else { return }
        if meaningMode {
            runMeaningSearch(query)
        } else {
            search = TranscriptSearchState(
                matches: TranscriptSearch.matches(query: query, in: searchRows))
        }
    }

    private func contentDiffersFromCache(_ c: CaptureContent) -> Bool {
        guard let cached else { return true }
        // A speaker confirm/rename changes ONLY the speaker slots (status/name), not the
        // transcript text or segment count — so those alone would discard a fresh confirm
        // and keep rendering the stale inferred label. Compare speakers too.
        return c.transcript != cached.transcript
            || c.segments.count != cached.segments.count
            || c.speakers != cached.speakers
    }

    /// Optimistic local adoption of a confirmed speaker — flips the in-memory `content`
    /// and `cached` slot to `.confirmed` with the outcome's name IMMEDIATELY, so every
    /// row keyed on that slot re-renders as that person without waiting on the door
    /// re-fetch. The re-fetch (`fetchFromDoor`) remains the authoritative reconcile.
    @MainActor
    private func applyConfirmedSpeaker(slot: String, name: String, speakerId: String) {
        func confirm(_ speakers: [CaptureSpeaker]) -> [CaptureSpeaker] {
            var updated = speakers
            if let i = updated.firstIndex(where: { $0.slot == slot }) {
                let sp = updated[i]
                updated[i] = CaptureSpeaker(
                    slot: sp.slot, status: .confirmed,
                    name: name.isEmpty ? sp.name : name,
                    inferScore: sp.inferScore,
                    inferredSpeakerId: sp.inferredSpeakerId,
                    confirmedSpeakerId: speakerId.isEmpty ? sp.confirmedSpeakerId : speakerId)
            } else {
                // Confirming an anonymous slot that had no speaker record yet — add one so
                // displayLabel resolves to the confirmed name (not "Speaker N").
                updated.append(CaptureSpeaker(
                    slot: slot, status: .confirmed,
                    name: name.isEmpty ? nil : name,
                    inferScore: nil, inferredSpeakerId: nil,
                    confirmedSpeakerId: speakerId.isEmpty ? nil : speakerId))
            }
            return updated
        }
        if let c = content {
            content = CaptureContent(
                transcript: c.transcript, capturedAt: c.capturedAt, found: c.found,
                title: c.title, summary: c.summary, titleModel: c.titleModel,
                summarizing: c.summarizing, segments: c.segments,
                speakers: confirm(c.speakers), paragraphs: c.paragraphs)
        }
        if let cc = cached {
            cached = CachedTranscript(
                transcript: cc.transcript, title: cc.title, summary: cc.summary,
                segments: cc.segments, speakers: confirm(cc.speakers),
                paragraphs: cc.paragraphs, fetchedAt: cc.fetchedAt)
        }
        // A confirm can newly identify the OWNER (or name another speaker) —
        // re-attribute the surfaced actions against the updated slots.
        loadFaceData()
    }

    /// Adapt a `ConfirmOutcome` to the optimistic slot update above. Called from the
    /// child confirm flows the instant the door acknowledges the confirm.
    @MainActor
    private func applyConfirmedSpeaker(_ outcome: ConfirmOutcome) {
        let slot = outcome.slotLabel
        guard !slot.isEmpty else { return }
        applyConfirmedSpeaker(slot: slot, name: outcome.speakerName, speakerId: outcome.speakerId)
    }

    /// A gentle, non-modal "apply this voice to N past conversations?" affordance shown in
    /// the open conversation when the Mac's ACK carried a propagation offer AFTER the tag
    /// sheet dismissed (local-first Section H). Applying is itself local-first: it durably
    /// enqueues the assign-to-existing confirms and lets the drain ship them.
    @ViewBuilder private func lateOfferBanner(_ outcome: ConfirmOutcome) -> some View {
        let n = outcome.offeredCaptures.count
        HStack(spacing: GrainSpacing.x2) {
            Image(systemName: "person.2.fill").foregroundStyle(GrainColor.forgeBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(outcome.speakerName) also matches \(n) past \(n == 1 ? "conversation" : "conversations")")
                    .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                Text("Apply \(outcome.speakerName) to \(n == 1 ? "it" : "them")?")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            }
            Spacer(minLength: GrainSpacing.x2)
            GrainButton("Apply", variant: .tonal, size: .sm) { applyLateOffer(outcome) }
            GrainButton("Not now", variant: .text, size: .sm) { lateOffer = nil }
        }
        .padding(GrainSpacing.x3)
        .background(
            RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                .fill(GrainColor.forgeBlueBg))
        .overlay(
            RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                .strokeBorder(GrainColor.forgeBlue.opacity(0.3), lineWidth: 1))
        .padding(.bottom, GrainSpacing.x3)
        .accessibilityIdentifier("speaker-late-offer")
    }

    /// Apply a late propagation offer, local-first: durably enqueue the assign-to-existing
    /// confirms for the offered past captures (the drain ships them in the background).
    private func applyLateOffer(_ outcome: ConfirmOutcome) {
        let base = CaptureWAL.documentsCaptures()
        let speakerId = outcome.speakerId
        let intents = outcome.offeredCaptures.map {
            (captureId: $0.captureId, slot: $0.slotLabel, speakerId: Optional(speakerId))
        }
        Task.detached { SpeakerConfirmQueue.enqueueAll(intents, baseDir: base) }
        lateOffer = nil
    }

    private func cacheIfReady(
        _ c: CaptureContent?,
        binding: CaptureAccountScope.AccountBinding
    ) {
        guard let c, c.found, !c.transcript.isEmpty else { return }
        let entry = CachedTranscript(transcript: c.transcript, title: c.title,
                                     summary: c.summary, segments: c.segments, speakers: c.speakers,
                                     fetchedAt: UInt64(max(0, Date().timeIntervalSince1970)))
        // Adopt the cache IN MEMORY immediately — the value is already in hand, so every
        // row keyed on it re-renders now without waiting on disk. The dominant hang was
        // doing the full-transcript JSONEncoder + atomic write (TranscriptCacheStore.save)
        // and the card merge SYNCHRONOUSLY on the @MainActor after every fetch/confirm
        // (0.9–1.5s per confirm). Push that disk work off the main actor; identical
        // semantics, just deferred (same entry, same merge args).
        cached = entry
        let capId = captureId
        let title = c.title
        let summary = c.summary
        Task.detached(priority: .utility) {
            guard CaptureAccountScope.perform(
                as: binding,
                { captured in
                    TranscriptCacheStore.save(
                        entry, captureId: capId, baseDir: captured.root)
                    ConversationCardStore.merge(
                        captureId: capId, baseDir: captured.root,
                        title: title, summary: summary, stage: nil)
                    return true
                }) == true else { return }
            // We just wrote transcript.json + card.json OUTSIDE the CaptureManager's sight;
            // tell it to invalidate its per-capture sidecar memo so the list's membership +
            // stats (distinct speakers) reflect this write (track 20260717T0448).
            await MainActor.run {
                CaptureAccountScope.perform(as: binding) { _ in
                    NotificationCenter.default.post(
                        name: .foundryxSidecarChanged,
                        object: nil,
                        userInfo: ["captureId": capId])
                }
            }
        }
    }

    /// AC2 — when NO summary exists at any source but a transcript does, synthesize one
    /// on-device (Apple Foundation Models) exactly ONCE, then persist it to the durable
    /// CARD so the home list fills too. Non-blocking: kicked from the content-load path
    /// in a Task so first paint is never held. A no-op where a summary already exists,
    /// where a synth is already running/done, or where the OS has no on-device model
    /// (the face then honestly points at the transcript rather than spinning forever).
    /// DISABLED (build 211 crash mitigation): on-device summary synthesis drove Apple's
    /// FoundationModels, whose aggregator crashes with an UNCATCHABLE Swift runtime trap
    /// (EXC_BREAKPOINT "Range requires lowerBound <= upperBound" in
    /// TranscriptWritingAggregator.transcriptEntriesSlice — incident 81C00A61). A trap can't
    /// be caught, so the only mitigation is to stop calling the model. The summary still
    /// resolves from the door/Kiln summary and the crash-safe card-summary fallback
    /// (`summaryText` → `provisional?.summary`); a conversation with a transcript but no
    /// summary anywhere shows the honest "No summary yet" state instead of risking the crash.
    private func maybeSynthesizeSummary() {
        // intentionally a no-op — see doc comment above.
    }

    // MARK: - audio replay (same semantics as the previous detail)

    /// WHERE THIS CONVERSATION'S AUDIO IS, AND WHAT ITS ROW SHOULD SAY — resolved OFF the main
    /// actor, because it is a directory walk plus a stat per confirmation marker and this is a
    /// screen appearing. `PocketLocalPlayback.heldFile` counts any main-thread read at the
    /// operation itself, so a future caller that drags this onto main trips a hard counter
    /// rather than quietly costing a person their first frame.
    private func resolveHeldRecording() async {
        let id = captureId
        let library = manager.captureLibraryRoot
        let stages = manager.captureStages()
        // HOISTED OUT OF THE DETACHED TASK, exactly like `library` and `stages` above: a
        // `Task.detached` that read `self.brain` would capture the view.
        let brain = self.brain
        let resolved = await Task.detached(priority: .userInitiated) {
            () -> (URL?, PocketRecordingPresence) in
            let root = CaptureAccountScope.privateURL(for: .pocketRecordings)
            let held = PocketLocalPlayback.heldFile(forCapture: id, in: root)
            guard held != nil else { return (nil, .nothingAsked) }
            // Step 5's predicate, READ and not recomputed: one answer to "is this safe".
            let durability = PocketCaptureDurability(baseDir: library, stages: stages,
                                                     brain: brain)
            return (held, PocketLocalPlayback.presence(forCapture: id,
                                                       heldFile: held,
                                                       // Nobody asked a recorder from here, and
                                                       // `unknown` says exactly that.
                                                       recorderListedAt: nil,
                                                       durability: durability,
                                                       askedAt: Date()))
        }.value
        heldHere = resolved.0
        placesHere = resolved.0 == nil ? nil : resolved.1
    }

    private func playAudio() async {
        // Never start playback while a recording owns the session — the row already shows
        // the disabled reason; this is the tap-time guard so nothing races the gate.
        guard !isRecordingActive else { return }
        audioState = .loading
        // THE RECORDER'S OWN FILE, PLAYED FROM HERE. No door, no cache, no network: the bytes
        // are in this app's container. The failure for a file we are holding is
        // `.heldButUnreadable` and never the computer's sentence — telling somebody to go wake
        // a Mac that was never asked is a lie they cannot act on.
        if let held = heldHere {
            guard let p = PocketLocalPlayback.player(forHeldFile: held) else {
                audioState = .failure(.heldButUnreadable)
                return
            }
            playbackOwnsSession = PlaybackSession.begin()
            player = p
            p.play()
            playbackDuration = p.duration
            playbackElapsed = 0
            scrubbing = false
            audioState = .playing
            startPlaybackClock(p)
            return
        }
        do {
            let cacheKey = await AudioReplayCache.shared.key(
                captureId: captureId, startMs: nil, endMs: nil)
            var wav = await AudioReplayCache.shared.get(cacheKey)
            if wav == nil {
                guard let bytes = try await DoorClient(target: target).captureAudio(captureId: captureId) else {
                    audioState = .failure(.unavailable)   // 404 / nil: pruned on the computer
                    return
                }
                guard let converted = OggOpusReplay.wav(fromOggOpus: bytes) else {
                    audioState = .failure(.failed)
                    return
                }
                await AudioReplayCache.shared.put(cacheKey, wav: converted)
                wav = converted
            }
            playbackOwnsSession = PlaybackSession.begin()
            let p = try AVAudioPlayer(data: wav!)
            player = p
            p.play()
            playbackDuration = p.duration
            playbackElapsed = 0
            scrubbing = false
            audioState = .playing
            startPlaybackClock(p)
        } catch {
            PlaybackSession.end(changed: playbackOwnsSession)
            playbackOwnsSession = false
            audioState = .failure(AudioPlaybackPresentation.failurePresentation(for: error))
        }
    }

    /// Poll the AVAudioPlayer clock into `playbackElapsed` so the scrubber tracks
    /// playback. One task per playback; cancelled by `stopPlayback`.
    ///
    /// Stopping is careful about WHY the player isn't playing (P2/P3 review):
    ///  • `started` gate — we only ever act on `!isPlaying` AFTER we've seen it playing,
    ///    so a `play()` that hasn't engaged within the first tick never false-stops at t=0.
    ///  • reached-the-end vs interrupted — at natural end `currentTime` sits at (or resets
    ///    to 0 past) the duration, so we tear down and return to idle. A `!isPlaying` with
    ///    the clock parked MID-clip is an audio-session interruption (a call, Siri, a route
    ///    change) — we do NOT tear a minutes-long playback down and lose the user's place;
    ///    we leave the transport frozen (the user can Stop) and end the poll.
    private func startPlaybackClock(_ p: AVAudioPlayer) {
        clockTask?.cancel()
        clockTask = Task {
            var started = false
            while !Task.isCancelled, player === p {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, player === p else { return }
                if p.isPlaying { started = true }
                if scrubbing { continue }   // the drag owns the value while the user scrubs
                playbackElapsed = min(p.currentTime, p.duration)
                if started, !p.isPlaying {
                    let reachedEnd = p.currentTime >= p.duration - 0.3 || p.currentTime < 0.1
                    if reachedEnd { stopPlayback() }   // else: interrupted — leave it frozen
                    return
                }
            }
        }
    }

    private func stopPlayback() {
        clockTask?.cancel()
        clockTask = nil
        player?.stop()
        player = nil
        playbackElapsed = 0
        playbackDuration = 0
        scrubbing = false
        if case .playing = audioState { audioState = .idle }
        PlaybackSession.end(changed: playbackOwnsSession)
        playbackOwnsSession = false
    }

    #if DEBUG
    /// Screen-proof only (`-AudioProof <state>`): drive a Listen row state deterministically
    /// in the simulator, where no real door serves `/audio`. Never runs outside DEBUG.
    private func applyAudioProofIfRequested() {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-AudioProof"), i + 1 < a.count else { return }
        switch a[i + 1] {
        case "loading":     audioState = .loading
        case "unavailable": audioState = .failure(.unavailable)
        case "unreachable": audioState = .failure(.unreachable)
        case "playing":
            Task {
                // Seed the in-memory cache so playAudio() resolves without the door.
                let key = await AudioReplayCache.shared.key(captureId: captureId, startMs: nil, endMs: nil)
                await AudioReplayCache.shared.put(key, wav: Self.debugSilentWav(seconds: 30))
                await playAudio()
            }
        default: break
        }
    }

    /// A tiny valid PCM WAV (silence) so AVAudioPlayer reaches `.playing` for the proof.
    private static func debugSilentWav(seconds: Int) -> Data {
        let sampleRate = 8000, channels = 1, bits = 16
        let frames = sampleRate * max(seconds, 1)
        let dataBytes = frames * channels * (bits / 8)
        var d = Data()
        func u32(_ v: Int) -> Data { var x = UInt32(v).littleEndian; return Data(bytes: &x, count: 4) }
        func u16(_ v: Int) -> Data { var x = UInt16(v).littleEndian; return Data(bytes: &x, count: 2) }
        d.append("RIFF".data(using: .ascii)!); d.append(u32(36 + dataBytes))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); d.append(u32(16)); d.append(u16(1)); d.append(u16(channels))
        d.append(u32(sampleRate)); d.append(u32(sampleRate * channels * (bits / 8)))
        d.append(u16(channels * (bits / 8))); d.append(u16(bits))
        d.append("data".data(using: .ascii)!); d.append(u32(dataBytes))
        d.append(Data(count: dataBytes))   // silence
        return d
    }
    #endif
}

/// Grain-backed diarized rows. Speaker management stays on the existing sheet and
/// confirmation route; only the row body comes from the design system.
private struct GrainSpeakerTranscriptRows: View {
    let target: DoorTarget
    let captureId: String
    let transcript: SpeakerTranscript
    let onChanged: () async -> Void
    /// Optimistic hook: fired the instant the door acknowledges a confirm, so the
    /// parent can flip the in-memory speaker for that slot before the re-fetch lands.
    let onConfirmed: (ConfirmOutcome) -> Void
    /// True while a recording is active — the tag sheet disables voice-sample playback.
    var isRecording: Bool = false

    /// Per-slot confirm phases — same state machine as SpeakerTranscriptSection.
    /// OWNED BY THE PARENT detail so an in-flight/confirmed phase survives the
    /// search-toggle swap between the two row surfaces (adversarial review P2/#4).
    @ObservedObject var confirmController: SpeakerConfirmController

    /// Per-conversation sync state — the pending glyph + revert notices (local-first).
    @ObservedObject var syncModel: SpeakerSyncModel

    /// True while this surface's tag sheet is presenting — the parent reads it so a late
    /// propagation-offer banner doesn't double-surface an offer the sheet already owns
    /// (review P2#2).
    @Binding var sheetPresenting: Bool

    @State private var tagging: SpeakerTagTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if transcript.hasUnconfirmedInferred {
                ReviewSpeakersBanner(count: transcript.inferredSlots.count) {
                    // No specific turn tapped ⇒ the sheet uses the slot's representative
                    // (longest) sample.
                    if let slot = transcript.inferredSlots.first {
                        tagging = SpeakerTagTarget(speaker: transcript.speaker(for: slot))
                    }
                }
                .padding(.bottom, GrainSpacing.x3)
            }

            ForEach(transcript.turns) { turn in
                speakerRow(turn)
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

    private func speakerRow(_ turn: SpeakerTurn) -> some View {
        let speaker = transcript.speaker(for: turn.slot)
        let pendingSync = syncModel.isPending(turn.slot)
        // Opening the tag sheet from THIS row plays THIS turn's own clip (the selected
        // piece), not the slot's longest utterance elsewhere in the conversation.
        let tapTarget = SpeakerTagTarget(
            speaker: speaker, sampleWindow: transcript.voiceSampleWindow(forTurn: turn))
        return VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            HStack(alignment: .top, spacing: GrainSpacing.x1) {
                GrainSpeakerRow(
                    speakerName: transcript.displayLabel(for: turn.slot),
                    speakerColor: speakerTint(for: turn.slot),
                    time: rowTime(turn, speaker: speaker),
                    words: turn.text
                )
                // GrainSpeakerRow takes a plain string; the subtle pending glyph rides
                // ADJACENT (never a status word baked into the name), aligned to the
                // name's baseline row.
                if pendingSync {
                    SpeakerSyncPendingGlyph().padding(.top, GrainSpacing.x2 + 1)
                }
            }
            // Ghost only a STRONG (name-revealing) tentative match; a weak slot presents
            // at full weight like an anonymous speaker (the reveal gate).
            .opacity((speaker.isInferred && speaker.revealedName != nil) ? 0.6 : 1)
            .textSelection(.enabled)
            .contentShape(Rectangle())
            .onTapGesture { tagging = tapTarget }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Edit speaker") { tagging = tapTarget }

            if let notice = syncModel.notices[turn.slot] {
                Text(notice)
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, GrainSpacing.x4)
                    .accessibilityIdentifier("speaker-sync-reverted")
            }

            // The inline confirm affordance renders from its phase (in-flight /
            // confirmed) — same shared control as the legacy rows, so a tap ALWAYS
            // answers within a frame. Kept visible while the transient confirmed check
            // lingers after the optimistic local flip. Weak inferred slots reveal no name
            // (revealedName == nil) and present like anonymous slots — tap-to-tag is the
            // affordance (the one honesty gate).
            if speaker.isInferred, let name = speaker.revealedName {
                InlineConfirmControls(
                    phase: confirmController.phase(for: turn.slot),
                    name: name,
                    onConfirm: { Task { await confirmInferred(slot: turn.slot) } },
                    onNotThem: { tagging = tapTarget })
                .padding(.leading, GrainSpacing.x4)
                .padding(.bottom, GrainSpacing.x2)
            } else if confirmController.phase(for: turn.slot) != .idle {
                InlineConfirmControls(
                    phase: confirmController.phase(for: turn.slot),
                    name: speaker.revealedName ?? transcript.displayLabel(for: turn.slot),
                    onConfirm: { Task { await confirmInferred(slot: turn.slot) } },
                    onNotThem: { tagging = tapTarget })
                .padding(.leading, GrainSpacing.x4)
                .padding(.bottom, GrainSpacing.x2)
            }
        }
    }

    private func speakerTint(for slot: String) -> GrainSpeakerTint {
        switch transcript.colorIndex(for: slot) % 3 {
        case 0: return .forge
        case 1: return .sage
        default: return .amber
        }
    }

    private func rowTime(_ turn: SpeakerTurn, speaker: CaptureSpeaker) -> String {
        var parts: [String] = []
        if let startMs = turn.startMs {
            let seconds = max(0, startMs / 1_000)
            parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        // Cosine is never rendered as a percentage (it is not a probability). A strong
        // inferred match shows the honest hint; a weak one presents like anonymous.
        if speaker.isInferred, speaker.revealedName != nil {
            parts.append(SpeakerConfidence.inlineStrongHint)
        }
        return parts.joined(separator: " · ")
    }

    /// The controller runs the LOCAL-FIRST confirm flow and drives the phase the
    /// affordance renders — in-flight within one frame, then a "Saved" check. The intent
    /// is durably queued; the background ship reconciles the canonical name/id via the
    /// synced notification (the parent observes it), or stays quietly pending offline.
    private func confirmInferred(slot: String) async {
        await confirmController.confirm(
            captureId: captureId, slot: slot,
            ship: ConfirmShip.make(target: target, captureId: captureId, slot: slot),
            onConfirmed: onConfirmed)   // optimistic: show the saved name instantly
    }
}

// MARK: - highlight rendering

/// Renders search matches into a row's text: every match gets the amber tint,
/// the CURRENT match reads solid so the eye lands where next/previous points.
/// Character offsets come from FoundryXKit.TranscriptMatch; out-of-range offsets
/// (stale state during a refresh) are dropped, never crash.
enum TranscriptHighlighter {
    static func attributed(_ text: String, ranges: [Range<Int>], current: Range<Int>?) -> AttributedString {
        var attr = AttributedString(text)
        for r in ranges {
            guard let ar = attributedRange(r, in: attr, textCount: text.count) else { continue }
            attr[ar].backgroundColor = GrainColor.amber.opacity(0.16)
            attr[ar].foregroundColor = GrainColor.amber
        }
        if let current, let ar = attributedRange(current, in: attr, textCount: text.count) {
            attr[ar].backgroundColor = GrainColor.amber
            attr[ar].foregroundColor = GrainColor.surface
        }
        return attr
    }

    private static func attributedRange(
        _ r: Range<Int>, in attr: AttributedString, textCount: Int
    ) -> Range<AttributedString.Index>? {
        guard r.lowerBound >= 0, r.upperBound <= textCount, r.lowerBound < r.upperBound else {
            return nil
        }
        let start = attr.characters.index(attr.startIndex, offsetBy: r.lowerBound)
        let end = attr.characters.index(start, offsetBy: r.count)
        return start..<end
    }
}
