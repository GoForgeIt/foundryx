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
    /// When the conversation happened — decides recent (auto-load) vs older
    /// (load on demand) transcript fetching.
    let conversationDate: Date?
    /// Phone-only tier → on-device stepper labels ("Saved on phone", etc.).
    var local: Bool = false
    /// The semantic-search seam. No embedding index exists on the phone today,
    /// so the default is nil and the meaning toggle is ABSENT (never a dead
    /// control). Inject a real, available index and the toggle appears.
    var meaningIndex: TranscriptMeaningIndex? = nil

    // MARK: faces
    @State private var face: DetailFace = .summary

    // MARK: content (same load pipeline as the previous detail)
    @State private var content: CaptureContent?
    @State private var cached: CachedTranscript?   // local fallback (pruned audio / offline)
    @State private var provisional: ConversationCardMeta?  // on-device provisional (pre-Kiln)
    @State private var loadError: String?
    @State private var loading = true
    @State private var didAttemptFetch = false
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

    private enum AudioState: Equatable { case idle, loading, playing, unavailable, failed(String) }

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

    private var summaryText: String? { content?.summary ?? cached?.summary }

    private var copyableTranscript: String? {
        if let diarized = diarizedTranscript, diarized.hasSegments {
            let text = diarized.plainText
            if !text.isEmpty { return text }
        }
        if let t = transcriptText, !t.isEmpty { return t }
        return nil
    }

    private var diarizedTranscript: SpeakerTranscript? {
        if let diarized = content?.diarized, diarized.hasSegments { return diarized }
        if let cached, !cached.segments.isEmpty {
            return SpeakerTranscript(speakers: cached.speakers, segments: cached.segments)
        }
        return nil
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

    // MARK: - body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                    metadataHeader
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
        .confirmationDialog("Delete conversation?", isPresented: $confirmDelete,
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
        .onAppear { loadFaceData() }
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
            HStack {
                listenRow
                Spacer(minLength: 0)
            }
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
            HStack(spacing: GrainSpacing.x2) {
                Image(grain: .spark)
                    .foregroundStyle(GrainColor.amber)
                Text(ConversationSummaryPresentation.openRelayAnswerLabel)
                    .grainTextStyle(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(GrainColor.forgeBlue)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
            }
            .frame(minHeight: GrainSpacing.x8)
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
            Text("Summarizing on your computer, check back shortly.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
        } else if transcriptText != nil {
            Text("No summary yet. The transcript face has the full conversation.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        } else if !loading {
            Text("Nothing to summarize yet. The summary appears once the conversation is processed.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        }
    }

    // MARK: - Actions face

    @ViewBuilder private var actionsFace: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x4) {
            if actions.isEmpty {
                Text(ConversationActionsPresentation.emptyStateText)
                    .grainTextStyle(.body)
                    .foregroundStyle(GrainColor.textMuted)
                    .padding(.vertical, GrainSpacing.x3)
                    .accessibilityIdentifier("actions-empty-state")
            } else {
                VStack(spacing: 0) {
                    Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
                    ForEach(actions.rows) { row in
                        actionRow(row)
                    }
                }
            }
            addActionControl
        }
    }

    private func actionRow(_ row: ConversationActionsPresentation.Row) -> some View {
        HStack(alignment: .top, spacing: GrainSpacing.x3) {
            ZStack {
                RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous)
                    .fill(actionTileBackground(row.state))
                Image(grain: actionIcon(row))
                    .grainTextStyle(.body)
                    .foregroundStyle(actionStateForeground(row.state))
            }
            .frame(width: GrainSpacing.x8, height: GrainSpacing.x8)

            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                Text(row.label)
                    .grainTextStyle(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(GrainColor.ink)
                if let meta = row.meta, !meta.isEmpty {
                    Text(meta)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: GrainSpacing.x2)
            Text(row.state.rawValue)
                .grainTextStyle(.caption)
                .fontWeight(.bold)
                .foregroundStyle(actionStateForeground(row.state))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, GrainSpacing.x3)
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

    private func actionIcon(_ row: ConversationActionsPresentation.Row) -> GrainIcon {
        if row.kind == .answer { return .spark }
        switch row.state {
        case .completed, .dismissed, .ready: return .check
        case .open: return .bolt
        }
    }

    private func actionStateForeground(_ state: ConversationActionsPresentation.Row.State) -> Color {
        switch state {
        case .completed, .ready: return GrainColor.sage
        case .open: return GrainColor.amber
        case .dismissed: return GrainColor.textFaint
        }
    }

    private func actionTileBackground(_ state: ConversationActionsPresentation.Row.State) -> Color {
        switch state {
        case .completed, .ready: return GrainColor.sage.opacity(0.12)
        case .open: return GrainColor.amber.opacity(0.12)
        case .dismissed: return GrainColor.borderFaint
        }
    }

    /// Build both presentation faces for THIS conversation from the intelligence
    /// lane's logs + the per-capture user-action store. Read-only joins over the
    /// REAL builders the brine step-defs assert on.
    private func loadFaceData() {
        let decisionLog = AmbientPrefs.decisionLogURL()
        let decisions = AmbientLane.readDecisions(at: decisionLog)
        let outcomes = ConversationActions.readOutcomes(
            at: ActivityStore.cardsLogURL(besides: decisionLog))
        let answers = ConversationAnswerLog.answers(
            at: ActivityStore.answersLogURL(besides: decisionLog), captureId: captureId)
        let userActions = UserActionStore.load(
            captureId: captureId, baseDir: CaptureWAL.documentsCaptures())
        linkedAnswer = answers.first
        actions = ConversationActionsPresentation.build(
            captureId: captureId, decisions: decisions, outcomes: outcomes,
            answers: answers, userActions: userActions)
    }

    // MARK: - Transcript face

    @ViewBuilder private var transcriptFace: some View {
        if let transcript = transcriptText {
            VStack(alignment: .leading, spacing: GrainSpacing.x3) {
                searchBar
                if showingProvisional {
                    Text("On-device transcript, finishing on your computer.")
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
                    SpeakerTranscriptSection(
                        target: target,
                        captureId: captureId,
                        transcript: diarized,
                        onChanged: { await fetchFromDoor() },
                        searchMatches: search.matches,
                        currentMatch: search.current
                    )
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
            Text("Loading transcript…")
                .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
        } else if didAttemptFetch, content?.found == false, loadError == nil {
            Text("Transcript still processing…")
                .grainTextStyle(.title).foregroundStyle(GrainColor.ink)
            Text("Your conversation is saved. The transcript shows up here once it's been processed on your computer.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            GrainButton("Check again", variant: .tonal, size: .sm) { Task { await fetchFromDoor() } }
        } else {
            Text("Transcript not loaded")
                .grainTextStyle(.title).foregroundStyle(GrainColor.ink)
            Text(isOlder
                 ? "This is an older conversation, so its transcript isn't stored on your phone. Load it from your computer."
                 : "Load this conversation's transcript from your computer.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            GrainButton("Load transcript", variant: .filled, size: .sm) { Task { await fetchFromDoor() } }
            if let loadError {
                Text("Couldn't load transcript: \(loadError)")
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

    @ViewBuilder private var listenRow: some View {
        switch audioState {
        case .idle:
            GrainButton("Listen", variant: .tonal, size: .sm) { Task { await playAudio() } }
        case .loading:
            Text("Loading audio…").grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        case .playing:
            GrainButton("Stop", variant: .text, size: .sm) { stopPlayback() }
        case .unavailable:
            Text("Audio not available").grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
        case .failed(let why):
            Text("Couldn't play audio: \(why)").grainTextStyle(.caption).foregroundStyle(GrainColor.amber)
        }
    }

    private var receiptSection: some View {
        DisclosureGroup(isExpanded: $receiptExpanded) {
            VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                receiptRow("Recording", receiptDuration)
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
            return "Recording duration unavailable"
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

    private var navTitle: String {
        if let t = content?.title, !t.isEmpty { return t }
        if let t = cached?.title, !t.isEmpty { return t }
        if let t = provisional?.title, !t.isEmpty { return t }
        guard let t = transcriptText, !t.isEmpty else { return "Conversation" }
        let words = t.split(whereSeparator: { $0 == " " || $0 == "\n" }).prefix(6).joined(separator: " ")
        return words.isEmpty ? "Conversation" : words
    }

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
        let base = CaptureWAL.documentsCaptures()
        cached = TranscriptCacheStore.load(captureId: captureId, baseDir: base)
        provisional = ConversationCardStore.load(captureId: captureId, baseDir: base)
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
        if cached == nil { loading = true }
        loadError = nil
        didAttemptFetch = true
        do {
            let fetched = try await DoorClient(target: target).captureContent(captureId: captureId)
            if cached == nil || contentDiffersFromCache(fetched) {
                content = fetched
                cacheIfReady(fetched)
            }
        } catch {
            if cached == nil { loadError = (error as NSError).localizedDescription }
        }
        loading = false
        refreshSearchAfterContentChange()
        if content?.summarizing == true, (content?.title ?? "").isEmpty {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let refreshed = try? await DoorClient(target: target).captureContent(captureId: captureId) {
                if cached == nil || contentDiffersFromCache(refreshed) {
                    content = refreshed
                    cacheIfReady(refreshed)
                    refreshSearchAfterContentChange()
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
        return c.transcript != cached.transcript || c.segments.count != cached.segments.count
    }

    private func cacheIfReady(_ c: CaptureContent?) {
        guard let c, c.found, !c.transcript.isEmpty else { return }
        let baseDir = CaptureWAL.documentsCaptures()
        let entry = CachedTranscript(transcript: c.transcript, title: c.title,
                                     summary: c.summary, segments: c.segments, speakers: c.speakers,
                                     fetchedAt: UInt64(max(0, Date().timeIntervalSince1970)))
        TranscriptCacheStore.save(entry, captureId: captureId, baseDir: baseDir)
        ConversationCardStore.merge(captureId: captureId, baseDir: baseDir,
                                    title: c.title, summary: c.summary, stage: nil)
        cached = entry
    }

    // MARK: - audio replay (same semantics as the previous detail)

    private func playAudio() async {
        audioState = .loading
        do {
            let cacheKey = await AudioReplayCache.shared.key(
                captureId: captureId, startMs: nil, endMs: nil)
            var wav = await AudioReplayCache.shared.get(cacheKey)
            if wav == nil {
                guard let bytes = try await DoorClient(target: target).captureAudio(captureId: captureId) else {
                    audioState = .unavailable   // 404: endpoint not ready / audio pruned
                    return
                }
                guard let converted = OggOpusReplay.wav(fromOggOpus: bytes) else {
                    audioState = .failed("undecodable audio")
                    return
                }
                await AudioReplayCache.shared.put(cacheKey, wav: converted)
                wav = converted
            }
            playbackOwnsSession = PlaybackSession.begin()
            let p = try AVAudioPlayer(data: wav!)
            player = p
            p.play()
            audioState = .playing
            Task {
                try? await Task.sleep(nanoseconds: UInt64((p.duration + 0.3) * 1_000_000_000))
                if player === p, !p.isPlaying { stopPlayback() }
            }
        } catch {
            PlaybackSession.end(changed: playbackOwnsSession)
            playbackOwnsSession = false
            audioState = .failed((error as NSError).localizedDescription)
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        if case .playing = audioState { audioState = .idle }
        PlaybackSession.end(changed: playbackOwnsSession)
        playbackOwnsSession = false
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
