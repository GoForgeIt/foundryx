// ConversationFacesView — the Night Shift conversation detail (track
// 20260713T0904, features/conversation-detail.feature): a conversation opens
// into THREE FACES — Summary (summary + metadata + receipt), Actions (the cards
// that surfaced during it, each with its outcome), Transcript (the diarized
// speaker transcript with in-transcript search).
//
// This is a re-arrangement of working functionality, not a rewrite: it binds to
// the SAME stores and flows the previous detail bound to — DoorClient /content,
// TranscriptCacheStore, ConversationCardStore, AudioReplayCache + PlaybackSession
// (Listen), SpeakerTranscriptSection (speaker labels, confirm-speaker, voice
// sample), ConversationStepper, transcript copy, delete.
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

    // MARK: actions face
    @State private var actionCards: [ConversationActionCard] = []

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

    private var stepperProgress: ConversationProgress? {
        if copyableTranscript != nil { return nil }
        let waiting = loading || (didAttemptFetch && content?.found == false)
        guard waiting else { return nil }
        if manager.statusPoller(for: captureId)?.stage == .failed { return .failed }
        return .transcribing
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
                VStack(alignment: .leading, spacing: GrainSpacing.x3) {
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
                            Label("Copy transcript", systemImage: "doc.on.doc")
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
        .onAppear { loadActionCards() }
        .onDisappear { stopPlayback() }
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

    @ViewBuilder private var metadataHeader: some View {
        Text(timeRange).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
        if let place {
            Text(place).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        }
    }

    /// The three-face switcher, Night Shift register: a quiet segmented capsule.
    private var facePicker: some View {
        HStack(spacing: GrainSpacing.x1) {
            ForEach(DetailFace.allCases) { f in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { face = f }
                } label: {
                    Text(f.title)
                        .grainTextStyle(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(face == f ? GrainColor.ink : GrainColor.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, GrainSpacing.x2)
                        .background(
                            RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous)
                                .fill(face == f ? GrainColor.surface : .clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("face-\(f.rawValue)")
            }
        }
        .padding(GrainSpacing.x1)
        .background(
            RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                .fill(GrainColor.backgroundSunken)
        )
    }

    // MARK: - Summary face

    @ViewBuilder private var summaryFace: some View {
        listenRow
        if let sp = stepperProgress {
            ConversationStepper(progress: sp, local: local)
                .padding(.vertical, GrainSpacing.x1)
        }
        if let summary = summaryText, !summary.isEmpty {
            Text(summary)
                .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
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
        Divider().background(GrainColor.borderHairline)
        receiptSection
    }

    // MARK: - Actions face

    @ViewBuilder private var actionsFace: some View {
        if actionCards.isEmpty {
            Text("Nothing actionable came up")
                .grainTextStyle(.title).foregroundStyle(GrainColor.ink)
            Text("When something worth doing surfaces during a conversation, its card lands here with what came of it.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
        } else {
            ForEach(actionCards) { card in
                actionCardRow(card)
            }
        }
    }

    private func actionCardRow(_ card: ConversationActionCard) -> some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            HStack(alignment: .top) {
                Image(grain: .bolt)
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(GrainColor.forgeBlue)
                Text(card.summary.isEmpty ? card.utterance : card.summary)
                    .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                Spacer(minLength: GrainSpacing.x2)
                GrainChip(card.outcome.label, variant: chipVariant(card.outcome))
            }
            if !card.summary.isEmpty, card.utterance != card.summary {
                Text("\u{201C}\(card.utterance)\u{201D}")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                    .italic()
            }
        }
        .padding(GrainSpacing.x3)
        .background(
            RoundedRectangle(cornerRadius: GrainRadius.card, style: .continuous)
                .fill(GrainColor.surfaceSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GrainRadius.card, style: .continuous)
                .strokeBorder(GrainColor.borderHairline, lineWidth: 1)
        )
    }

    private func chipVariant(_ outcome: ActionOutcome) -> GrainChipVariant {
        switch outcome {
        case .sentToChat: return .blue
        case .answered: return .sage
        case .dismissed: return .default
        case .pending: return .amber
        }
    }

    /// The cards for THIS conversation: candidate decisions from the ambient
    /// decision log joined to their outcomes in the card-outcome log. Read-only
    /// over the intelligence lane's files.
    private func loadActionCards() {
        let decisions = AmbientLane.readDecisions(at: AmbientPrefs.decisionLogURL())
        let outcomes = ConversationActions.readOutcomes(
            at: CaptureWAL.documentsCaptures()
                .appendingPathComponent(ConversationActions.outcomeLogFilename))
        actionCards = ConversationActions.cards(
            for: captureId, decisions: decisions, outcomes: outcomes)
    }

    // MARK: - Transcript face

    @ViewBuilder private var transcriptFace: some View {
        if let transcript = transcriptText {
            searchBar
            if showingProvisional {
                Text("On-device transcript, finishing on your computer.")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }
            HStack {
                Spacer()
                Button {
                    copyTranscript()
                } label: {
                    Label(didCopy ? "Copied" : "Copy",
                          systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .grainTextStyle(.caption)
                        .foregroundStyle(didCopy ? GrainColor.sage : GrainColor.textMuted)
                }
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
                    .id("flat-transcript")
            }
        } else if loading {
            Text("Loading transcript…")
                .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
        } else if didAttemptFetch, content?.found == false, loadError == nil {
            if let sp = stepperProgress {
                ConversationStepper(progress: sp, local: local)
                    .padding(.vertical, GrainSpacing.x1)
            }
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
            HStack(spacing: GrainSpacing.x2) {
                Image(grain: .search)
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(GrainColor.textMuted)
                TextField("Search the transcript", text: $query)
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
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, GrainSpacing.x3)
            .padding(.vertical, GrainSpacing.x2)
            .background(
                RoundedRectangle(cornerRadius: GrainRadius.input, style: .continuous)
                    .fill(GrainColor.backgroundSunken)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GrainRadius.input, style: .continuous)
                    .strokeBorder(GrainColor.borderHairline, lineWidth: 1)
            )

            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: GrainSpacing.x3) {
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
                    Spacer()
                    Button { search.previous() } label: {
                        Image(systemName: "chevron.up")
                            .foregroundStyle(search.count > 0 ? GrainColor.ink : GrainColor.textFaint)
                    }
                    .disabled(search.count == 0)
                    .accessibilityLabel("Previous match")
                    Button { search.next() } label: {
                        Image(systemName: "chevron.down")
                            .foregroundStyle(search.count > 0 ? GrainColor.ink : GrainColor.textFaint)
                    }
                    .disabled(search.count == 0)
                    .accessibilityLabel("Next match")
                }
            }

            // AC3 — the meaning toggle EXISTS only when a real index is available.
            if meaningOffered {
                HStack(spacing: GrainSpacing.x1) {
                    modeChip("Text", active: !meaningMode) { setMeaningMode(false) }
                    modeChip("Meaning", active: meaningMode) { setMeaningMode(true) }
                }
            }
        }
    }

    private func modeChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .grainTextStyle(.caption)
                .foregroundStyle(active ? GrainColor.forgeBlue : GrainColor.textMuted)
                .padding(.horizontal, GrainSpacing.x3)
                .padding(.vertical, GrainSpacing.x1)
                .background(Capsule().fill(active ? GrainColor.forgeBlueBg : .clear))
                .overlay(Capsule().strokeBorder(
                    active ? GrainColor.forgeBlueBorder : GrainColor.borderHairline, lineWidth: 1))
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
                Image(systemName: "receipt")
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
                .frame(width: 92, alignment: .leading)
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
            attr[ar].backgroundColor = GrainColor.amberBg
            attr[ar].foregroundColor = GrainColor.amber
        }
        if let current, let ar = attributedRange(current, in: attr, textCount: text.count) {
            attr[ar].backgroundColor = GrainColor.amber
            attr[ar].foregroundColor = GrainColor.background
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
