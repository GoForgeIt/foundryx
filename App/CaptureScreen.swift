import SwiftUI
import AVFoundation
import Grain
#if canImport(UIKit)
import UIKit
#endif

/// Clip-playback use of the SHARED AVAudioSession. The phone-mic record engine
/// (MicFrameSource) holds the session as `.playAndRecord` while recording — flipping
/// it to `.playback` mid-record (build 138 did this unconditionally) yanks the input
/// route out from under the live engine and churns route-change notifications against
/// it (a driver of the engine-restart storm). So: only take `.playback` when no record
/// engine owns the session, and release the session again when playback ends.
enum PlaybackSession {
    /// True when the shared session is configured for recording — playback must not
    /// steal it. (An AVAudioPlayer still plays fine through `.playAndRecord`.)
    static var recordOwnsSession: Bool {
        AVAudioSession.sharedInstance().category == .playAndRecord
    }

    /// Prepare the session for clip playback. Returns whether the category was
    /// changed — the caller must pass that to `end(changed:)` when playback stops.
    @discardableResult
    static func begin() -> Bool {
        guard !recordOwnsSession else { return false }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        return true
    }

    /// Release the session after playback IF `begin()` took it — and only when a
    /// record engine hasn't claimed the session in the meantime (never deactivate
    /// underneath a live recording).
    static func end(changed: Bool) {
        guard changed, !recordOwnsSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

private extension ConversationProgress {
    /// The Grain status dot energy for this chip: live capture pulses warm, the
    /// working states pulse (thinking), Ready breathes at rest (idle), failure smolders.
    var statusDot: GrainStatus {
        switch self {
        case .recording: return .running
        case .savedOnPhone, .savedToComputer, .transcribing: return .thinking
        case .ready: return .idle
        case .failed: return .tripped
        }
    }
}

/// The capture surface. When no Omi is connected it's a connect/pairing flow
/// (scan → pick a device → connect, persisted + auto-reconnecting). Once
/// connected, capture is AMBIENT — it runs automatically; the header shows the
/// device + a Pause/Resume control. Below: the Omi-style timeline (each capture
/// Recording → Saved on phone → Saved to computer) + a global "your data is safe"
/// sync indicator so nothing ever feels lost into the phone.
/// The instrument's ring at 12 Hz: observes ONLY the meter model, so its tick
/// invalidates just this small view (the law the old MeterStrip obeyed). The
/// caption beside it stays a human word (Listening / Recording / Paused).
struct RecordingRingView: View {
    @ObservedObject var meter: CaptureManager.AudioMeterModel
    let paused: Bool

    var body: some View {
        GrainVoiceRing(
            energy: RecordingRingModel.energy(
                meterLevel: Double(meter.levels.last ?? 0), paused: paused),
            order: RecordingRingModel.order
        )
        .accessibilityLabel(paused ? "Paused" : "Listening")
    }
}

/// The instrument's caption — a human state only (the ring already shows the
/// level). The old frames/bytes diagnostics were build telemetry; they live in
/// the logs now, never on a consumer surface.
struct MeterCaption: View {
    let paused: Bool
    let isRecordingMic: Bool

    var body: some View {
        Text(MeterCaptionText.caption(paused: paused, isRecordingMic: isRecordingMic))
            .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
    }
}

/// The ticking elapsed readout (1 Hz), monospaced so it never wobbles.
struct ElapsedLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let s = max(0, Int(timeline.date.timeIntervalSince(since)))
            Text(String(format: "%d:%02d", s / 60, s % 60))
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                .monospacedDigit()
        }
    }
}

/// Activity's parameter wiring, extracted from the old buried Capture
/// NavigationLink so the top-level Activity TAB (spec §1/§6, track
/// 20260714T1800) mounts the SAME configured surface: the ambient decision
/// log, the manager's recap pool, chat handoff via the ambient broker, and the
/// old Stats readout one tap deeper (subsumed, not lost).
enum CaptureActivityWiring {
    @MainActor static func activityView(manager: CaptureManager) -> some View {
        ActivityView(
            decisionLogURL: AmbientPrefs.decisionLogURL(),
            recapPool: manager.recapConversationPool(),
            onOpenChat: { seed in AmbientCardBroker.shared.run(seed: seed) }
        )
        .toolbar {
            NavigationLink("Stats") { StatsView(summary: manager.statsSummary) }
        }
    }
}

struct CaptureScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    // Shared with the Device tab (owned by MainTabs) so both surfaces see one BLE
    // link + one capture pipeline.
    @ObservedObject var device: DeviceManager
    @ObservedObject var manager: CaptureManager
    /// The capture-source registry — so a source toggled OFF on the device page is
    /// removed from this surface (and not auto-started here).
    @ObservedObject var sources: CaptureSourceRegistry
    /// The resolved door target — lets a tapped card open its transcript (Phase B).
    let target: DoorTarget
    /// Phone-only tier: labels stay on-device ("Saved on phone", not "…to computer").
    var local: Bool = false
    @State private var pendingDeleteId: String?
    #if DEBUG
    @State private var deepDetail = false   // screen-proof: `-Screen detail`
    #endif

    // MARK: find + organize (track 20260713T0902, features/capture-home.feature)
    /// The user's categories, stored beside the captures they organize.
    @StateObject private var categories: ConversationCategoryStore
    /// Search over what the phone holds (titles + cached transcripts) — open/closed
    /// + query live in the durable, tested find state ("Search all" opens it).
    @StateObject private var find = CaptureFindState()
    /// nil = no search active; else the ids that matched (computed off-main).
    @State private var searchMatches: Set<String>?
    /// The computer/Lore half of search (track 20260714T1200): resolved from the door
    /// when connected, deduped against the local matches above.
    @State private var remoteState: RemoteSearchState = .idle
    /// Selected category filter chip id (nil = All).
    @State private var categoryFilter: String?
    @State private var newCategoryName = ""
    @State private var showingNewCategory = false
    /// The category being renamed (nil = not renaming) + its edited name.
    @State private var renamingCategory: ConversationCategory?
    @State private var renameText = ""
    /// The on-device model behind auto-filing (nil where unavailable — honest).
    private let tagger = makeSystemCategoryTagger()

    init(device: DeviceManager, manager: CaptureManager, sources: CaptureSourceRegistry,
         target: DoorTarget, local: Bool = false) {
        self.device = device
        self.manager = manager
        self.sources = sources
        self.target = target
        self.local = local
        _categories = StateObject(wrappedValue: manager.makeCategoryStore())
    }

    /// Whether the Omi is still an enabled capture source (device-page toggle). When off,
    /// the capture page neither auto-starts nor shows the Omi scan affordance.
    private var omiEnabled: Bool { sources.isEnabled(CaptureSourceDescriptor.omiId) }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Live transcript ABOVE the voice-recording animation (Feature 4): a tight
            // 1-clear + 1-fading window that slides up and dissolves under the header.
            // Ephemeral, on-device preview; Kiln's transcript remains authoritative.
            if isShowingCapture {
                // The instrument (track 20260713T0903): the SAME ring from welcome +
                // enrollment, now recording — pause left, ring + ticking elapsed right,
                // provisional title from what has actually been said.
                recordingInstrument
                if !manager.liveTranscript.isEmpty {
                    LiveTranscriptTicker(transcript: manager.liveTranscript)
                        .padding(.horizontal, GrainSpacing.x4)
                        .padding(.top, GrainSpacing.x2)
                }
            }
            syncBar
            // The calm "Record a conversation" CTA card (prototype 08 Capture home) —
            // hidden while the live instrument is up (recording IS the surface then).
            if !isShowingCapture {
                recordCTA
            }
            if manager.visibleCaptures.isEmpty {
                // Keep the header search affordance honest even before the first
                // capture: opening it still reveals the same local search field.
                if find.searchOpen { findBar }
                emptyState
            } else {
                recentHeadline
                findBar
                conversationList
            }
        }
        .grainBackground()
        #if DEBUG
        // DEV screen-proof deep-links (real manager + target): `-Screen detail` opens a
        // conversation's three-face detail; `-Screen recording` starts the instrument.
        .onAppear {
            let a = ProcessInfo.processInfo.arguments
            if a.contains("-Screen"), a.contains("detail") { deepDetail = true }
            if a.contains("-Screen"), a.contains("recording") { manager.startMicRecording() }
        }
        .fullScreenCover(isPresented: $deepDetail) {
            // `-Capture <id>` picks which demo card's detail to open (default omi-demo-1);
            // omi-demo-2 carries the seeded diarized (speaker-labeled) transcript.
            let a = ProcessInfo.processInfo.arguments
            let cid: String = a.firstIndex(of: "-Capture").flatMap { i in
                a.indices.contains(i + 1) ? a[i + 1] : nil
            } ?? "omi-demo-1"
            NavigationStack {
                ConversationFacesView(
                    target: target, manager: manager, captureId: cid,
                    timeRange: "Tue, Jul 14 · 4:16 PM–4:28 PM · 12 min",
                    place: "Office", conversationDate: Date(), local: true)
            }
        }
        #endif
        // Search sweeps local disk (cached transcripts) AND, when the computer is
        // connected, the FULL history in Lore (track 20260714T1200) — off-main, newest
        // state wins. The computer results are deduped against the local matches.
        .task(id: find.query) {
            let q = find.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { searchMatches = nil; remoteState = .idle; return }
            let ids = manager.visibleCaptures.map(\.captureId)
            let titles = Dictionary(uniqueKeysWithValues: ids.map {
                ($0, manager.cardMeta(for: $0)?.title)
            })
            let mgr = manager
            let matched = await Task.detached(priority: .userInitiated) {
                Set(ConversationSearch.filter(
                    ids: ids, query: q,
                    title: { titles[$0] ?? nil },
                    transcript: { mgr.searchText(for: $0) }))
            }.value
            guard find.query.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
            searchMatches = matched
            // Reach the computer's whole library (phone-only tier → notConnected note).
            remoteState = .searching
            let localTarget = target
            let connected = !local
            let rs = await FullHistorySearch.remoteState(
                query: q, localIds: Set(ids), computerConnected: connected,
                search: { try await DoorClient(target: localTarget).searchConversations(query: $0) })
            if find.query.trimmingCharacters(in: .whitespacesAndNewlines) == q { remoteState = rs }
        }
        .alert("Rename category", isPresented: Binding(
            get: { renamingCategory != nil },
            set: { if !$0 { renamingCategory = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let cat = renamingCategory, !name.isEmpty {
                    categories.rename(categoryId: cat.id, to: name)
                }
                renamingCategory = nil
            }
            Button("Cancel", role: .cancel) { renamingCategory = nil }
        }
        .alert("New category", isPresented: $showingNewCategory) {
            TextField("Name", text: $newCategoryName)
            Button("Create") {
                let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { categoryFilter = categories.create(name: name).id }
                newCategoryName = ""
            }
            Button("Cancel", role: .cancel) { newCategoryName = "" }
        } message: {
            Text("Categories are yours: rename or delete them any time. Deleting one never deletes its conversations.")
        }
        // AC3 — bounded, one-time on-device summary backfill for the visible list so
        // older terminal cards show a summary line instead of title-only. Keyed on the
        // visible count so it fires once the list has actually loaded (not on the empty
        // first paint); the marker inside makes it a true one-shot. Never blocks paint.
        .task(id: manager.visibleCaptures.count) {
            let ids = manager.visibleCaptures.map(\.captureId)
            let mgr = manager
            await SummaryBackfill.run(
                captureIds: ids,
                baseDir: CaptureWAL.documentsCaptures(),
                titler: makeSystemTitler(),
                transcript: { mgr.searchText(for: $0) },
                cardSummary: { mgr.cardMeta(for: $0)?.summary })
        }
        // Power on the Omi only when it's still an enabled source; always drive the meter.
        .onAppear { if omiEnabled { manager.startSource() }; manager.startMeter() }
        .onDisappear { manager.stopMeter() }
        .confirmationDialog("Delete conversation?",
                            isPresented: Binding(
                                get: { pendingDeleteId != nil },
                                set: { if !$0 { pendingDeleteId = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteId { manager.deleteConversation(id) }
                pendingDeleteId = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteId = nil }
        } message: {
            Text("Removes it from your phone, your computer, and your library.")
        }
    }

    // MARK: record CTA — the calm "Record a conversation" card (prototype :2202)

    /// Mic circle + headline + the on-phone reassurance line. Tapping starts the
    /// existing phone-mic recording path.
    private var recordCTA: some View {
        GrainRecordCTA(
            title: CaptureHomeCopy.recordTitle,
            subtitle: CaptureHomeCopy.recordSubtitle(local: local),
            onRecord: { manager.startMicRecording() }
        )
        .accessibilityHidden(true)
        .overlay {
            // Grain's orb owns its native action; retain the app's existing
            // full-row hit target with a single sibling control above it.
            Button { manager.startMicRecording() } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CaptureHomeCopy.recordTitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!manager.phoneMicAvailable)
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.top, GrainSpacing.x2)
    }

    // MARK: "Recent on this phone" headline + Search all (prototype :2203)

    private var recentHeadline: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                GrainSectionEyebrow(CaptureHomeCopy.recentHeadline)
                Text(CaptureHomeCopy.conversationCount(manager.visibleCaptures.count))
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }
            Spacer()
            // "Search all" = the same full-history search the header icon opens.
            Button(CaptureHomeCopy.searchAll) {
                withAnimation(.easeOut(duration: 0.2)) { find.openSearchAll() }
            }
            .grainTextStyle(.caption)
            .foregroundStyle(GrainColor.forgeBlue)
            .buttonStyle(.plain)
            .accessibilityLabel("Search all conversations")
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.top, GrainSpacing.x3)
    }

    // MARK: find + organize bar (search + category chips)

    private var findBar: some View {
        VStack(spacing: GrainSpacing.x2) {
            if find.searchOpen {
                HStack(spacing: GrainSpacing.x2) {
                    Image(grain: .search)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(GrainColor.textFaint)
                    TextField("Search people, words, or places", text: $find.query)
                        .textFieldStyle(.plain)
                        .grainTextStyle(.body)
                        .foregroundStyle(GrainColor.ink)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, GrainSpacing.x3)
                .frame(minHeight: GrainSpacing.x8 + GrainSpacing.x2)
                .background(
                    RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                        .fill(GrainColor.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                        .strokeBorder(GrainColor.borderFaint, lineWidth: 1)
                )
            }
            chips
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.top, find.searchOpen ? GrainSpacing.x2 : GrainSpacing.x1)
        .padding(.bottom, GrainSpacing.x2)
    }

    /// All + the user's categories + "+" (create). Deleting is on the chip's
    /// context menu; conversations are never deleted with a category.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GrainSpacing.x2) {
                chip(label: "All", selected: categoryFilter == nil) { categoryFilter = nil }
                ForEach(categories.categories) { cat in
                    chip(label: cat.name, selected: categoryFilter == cat.id) {
                        categoryFilter = categoryFilter == cat.id ? nil : cat.id
                    }
                    .contextMenu {
                        Button("Rename") {
                            renamingCategory = cat
                            renameText = cat.name
                        }
                        Button("Delete \"\(cat.name)\"", role: .destructive) {
                            if categoryFilter == cat.id { categoryFilter = nil }
                            categories.delete(categoryId: cat.id)
                        }
                    }
                }
                chip(label: "+", selected: false) { showingNewCategory = true }
                    .accessibilityLabel("New category")
                editChip
            }
        }
    }

    /// The discoverable Edit affordance (prototype :2208): rename or delete a
    /// category without knowing about the chips' long-press menu. Deleting a
    /// category never deletes conversations.
    private var editChip: some View {
        Menu {
            ForEach(categories.categories) { cat in
                Menu(cat.name) {
                    Button("Rename") {
                        renamingCategory = cat
                        renameText = cat.name
                    }
                    Button("Delete", role: .destructive) {
                        if categoryFilter == cat.id { categoryFilter = nil }
                        categories.delete(categoryId: cat.id)
                    }
                }
            }
        } label: {
            Text("Edit")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .lineLimit(1)
                .padding(.horizontal, GrainSpacing.x3)
                .padding(.vertical, GrainSpacing.x1)
                .overlay(Capsule().strokeBorder(GrainColor.borderFaint, lineWidth: 1))
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Rename or delete category")
    }

    private func chip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .grainTextStyle(.caption)
                .foregroundStyle(selected ? selectedChipForeground : GrainColor.textMuted)
                .lineLimit(1)
                .padding(.horizontal, GrainSpacing.x3)
                .padding(.vertical, GrainSpacing.x1)
                .background(Capsule().fill(selected ? GrainColor.forgeBlue : .clear))
                .overlay(Capsule().strokeBorder(
                    selected ? GrainColor.forgeBlue : GrainColor.borderFaint, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The prototype's selected filters use warm white ink in both appearances.
    /// Grain's light surface and dark ink are the matching adaptive tokens.
    private var selectedChipForeground: Color {
        colorScheme == .dark ? GrainColor.ink : GrainColor.surface
    }

    /// Search + category filters applied over the manager's visible list.
    private var filteredCaptures: [CaptureWAL] {
        var items = manager.visibleCaptures
        if let matches = searchMatches {
            items = items.filter { matches.contains($0.captureId) }
        }
        if let filterId = categoryFilter {
            let ids = Set(categories.captureIds(in: filterId, from: items.map(\.captureId)))
            items = items.filter { ids.contains($0.captureId) }
        }
        return items
    }

    // MARK: conversation list — grouped into dated sections (Feature 5)

    /// The timeline, grouped newest-first into Today / Yesterday / weekday / "Last week"
    /// / "N weeks ago" / month sections. The grouping is the pure, tested
    /// `ConversationGrouping`; `visibleCaptures` is already date-desc, so sections stay
    /// in order. LazyVStack keeps off-screen cards (and their pollers) inert.
    private var conversationList: some View {
        let sections = ConversationGrouping.group(filteredCaptures, now: Date()) {
            manager.conversationStartDate($0)
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Section {
                        ForEach(section.items, id: \.captureId) { wal in
                            conversationRow(wal)
                                .padding(.bottom, GrainSpacing.x2)
                        }
                    } header: {
                        searchSectionHeader(section.title)
                    }
                }
                remoteResultsSection
            }
            .padding(.horizontal, GrainSpacing.x4)
            .padding(.bottom, GrainSpacing.x6)
        }
    }

    private func searchSectionHeader(_ title: String) -> some View {
        Text(title)
            .grainTextStyle(.caption)
            .foregroundStyle(GrainColor.textFaint)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, GrainSpacing.x3)
            .padding(.bottom, GrainSpacing.x2)
            .background(GrainColor.surface)
    }

    /// The computer/Lore half of search (track 20260714T1200 AC3): shown only while a
    /// query is active. Computer-only hits render as their own "From your computer"
    /// section (each opens the same three-face detail, fetched by id — AC4); the
    /// connection states are said honestly.
    @ViewBuilder private var remoteResultsSection: some View {
        let q = find.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if find.searchOpen, !q.isEmpty {
            switch remoteState {
            case .idle, .searching:
                EmptyView()
            case .results(let hits) where !hits.isEmpty:
                Section {
                    ForEach(hits) { hit in
                        remoteHitRow(hit).padding(.bottom, GrainSpacing.x2)
                    }
                } header: {
                    searchSectionHeader("From your computer")
                }
            case .results:
                EmptyView()   // the computer had nothing more to add
            case .notConnected:
                searchNote("Connect your computer to search your full history.")
            case .unreachable:
                searchNote("Couldn't reach your computer.")
            }
        }
    }

    /// A conversation that lives only on the computer — tapping fetches its detail from
    /// the door by id (the three-face detail already handles a Lore-resident capture).
    private func remoteHitRow(_ hit: ConversationHit) -> some View {
        NavigationLink {
            ConversationFacesView(
                target: target,
                manager: manager,
                captureId: hit.captureId,
                timeRange: hit.dateLabel,
                place: nil,
                conversationDate: nil,
                local: false)
        } label: {
            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                Text(hit.title.isEmpty ? "Untitled conversation" : hit.title)
                    .grainTextStyle(.body)
                    .foregroundStyle(GrainColor.ink)
                    .lineLimit(1)
                if !hit.snippet.isEmpty {
                    Text(hit.snippet)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                        .lineLimit(2)
                }
                if !hit.dateLabel.isEmpty {
                    Text(hit.dateLabel)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(GrainSpacing.x3)
            .background(RoundedRectangle(cornerRadius: 14).fill(GrainColor.surface))
        }
        .buttonStyle(.plain)
    }

    private func searchNote(_ text: String) -> some View {
        Text(text)
            .grainTextStyle(.caption)
            .foregroundStyle(GrainColor.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, GrainSpacing.x3)
    }

    /// One tappable conversation card → its transcript detail.
    private func conversationRow(_ wal: CaptureWAL) -> some View {
        NavigationLink {
            // The three-face detail (track 20260713T0904): Summary / Actions /
            // Transcript + text search; same parameters, same stores underneath.
            ConversationFacesView(
                target: target,
                manager: manager,
                captureId: wal.captureId,
                timeRange: manager.conversationMeta(for: wal.captureId)
                    .map { CaptureCardPresentation.timeRangeString(meta: $0, fallback: wal.status.startedAt) }
                    ?? CaptureCardPresentation.timeRangeString(meta: nil, fallback: wal.status.startedAt),
                place: manager.conversationMeta(for: wal.captureId)?.location?.label,
                conversationDate: manager.conversationMeta(for: wal.captureId)
                    .map { Date(timeIntervalSince1970: TimeInterval($0.startedAt)) }
                    ?? wal.status.startedAt
            )
        } label: {
            if let poller = manager.statusPoller(for: wal.captureId) {
                CaptureCard(
                    wal: wal,
                    meta: manager.conversationMeta(for: wal.captureId),
                    card: manager.cardMeta(for: wal.captureId),
                    poller: poller,
                    hasCachedTranscript: manager.hasCachedTranscript(wal.captureId),
                    // Cache RECENT (~14d) transcripts on sight (no-op for older / already-cached).
                    onSight: { manager.ensureRecentTranscriptCached(wal.captureId) },
                    local: local,
                    categoryName: categories.category(for: wal.captureId)?.name,
                    categoryAutoFiled: categories.acceptsAutoSuggestion(for: wal.captureId),
                    loadWaveform: { [weak manager] in
                        WaveformThumb.profile(sizes: manager?.segmentSizes(for: wal.captureId) ?? [],
                                              buckets: 24)
                    }
                )
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            // File under… — the user's filing always wins and is remembered.
            Menu("File under") {
                ForEach(categories.categories) { cat in
                    Button(cat.name) {
                        categories.assign(captureId: wal.captureId, to: cat.id, byUser: true)
                    }
                }
                if categories.category(for: wal.captureId) != nil {
                    Button("Remove from category", role: .destructive) {
                        categories.unassign(captureId: wal.captureId)
                    }
                }
            }
        }
        // Auto-file where the on-device model can — only while the user hasn't.
        .task { await autoTagIfNeeded(wal.captureId) }
        .swipeActions {
            Button(role: .destructive) { pendingDeleteId = wal.captureId } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// One shot per on-screen row: if unfiled and never user-filed, ask the
    /// on-device model to file it. No model → nothing happens (honest).
    private func autoTagIfNeeded(_ captureId: String) async {
        guard let tagger,
              categories.category(for: captureId) == nil,
              categories.acceptsAutoSuggestion(for: captureId) else { return }
        let title = manager.cardMeta(for: captureId)?.title
        let mgr = manager
        let transcript = await Task.detached(priority: .utility) {
            mgr.searchText(for: captureId)
        }.value
        guard let name = await tagger.suggest(title: title, transcript: transcript,
                                              from: categories.categories),
              let cat = categories.categories.first(where: { $0.name == name }) else { return }
        categories.assign(captureId: captureId, to: cat.id, byUser: false)
    }

    // MARK: the recording instrument (track 20260713T0903)

    /// Pause left · provisional title center · ring + ticking elapsed right.
    /// The ring subview observes ONLY manager.meter (12 Hz) — its tick never
    /// invalidates this screen's body (same law the old MeterStrip obeyed).
    private var recordingInstrument: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            HStack(spacing: GrainSpacing.x3) {
                if manager.active != nil || manager.isRecordingMic {
                    GrainButton(manager.isPaused ? "Resume" : "Pause",
                                variant: manager.isPaused ? .filled : .tonal, size: .sm) {
                        manager.togglePause()
                    }
                }
                Spacer()
                if let wal = manager.active {
                    ElapsedLabel(since: wal.status.startedAt)
                }
                RecordingRingView(meter: manager.meter, paused: manager.isPaused)
                    .frame(width: 34, height: 34)
            }
            // The provisional name, from what has actually been said — appears
            // only once enough was said, and never rewrites itself (no layout jump).
            if let title = ProvisionalLiveTitle.title(from: manager.liveTranscript.finalizedText) {
                Text(title)
                    .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                    .lineLimit(1)
            }
            MeterCaption(paused: manager.isPaused, isRecordingMic: manager.isRecordingMic)
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.top, GrainSpacing.x2)
    }

    // MARK: header — ambient control when connected, else the auto-connect status + the
    // inline "Connect your Omi" affordance (source connection is automatic + self-healing;
    // the user never hand-drives a BLE scan — that lives in the Device page's source mgmt).

    /// The pure capture-page banner state: the live Omi link projected through the
    /// device-page enabled toggle (a disabled Omi short-circuits to `.omiDisabled`).
    private var sourcePresentation: CaptureSourcePresentation {
        .resolve(connection: device.connectionState, omiEnabled: omiEnabled, isPaused: manager.isPaused)
    }

    @ViewBuilder private var header: some View {
        let p = sourcePresentation
        if p.isConnected {
            ambientHeader(name: p.connectedName ?? "Omi", presentation: p)
        } else {
            connectHeader(p)
        }
    }

    /// Whether the live capture surface (meter + transcript) should show: the Omi is
    /// connected (listening or paused), or the phone mic is actively recording.
    private var isShowingCapture: Bool {
        if sourcePresentation.isConnected { return true }
        return manager.isRecordingMic
    }

    /// Search lives in the Capture title bar in the approved composition. Closing
    /// it keeps the original behavior of clearing the local query and results.
    private var headerSearchButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { find.toggleSearch() }
        } label: {
            Image(grain: .search)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(find.searchOpen ? GrainColor.forgeBlue : GrainColor.textMuted)
                .frame(width: GrainSpacing.x8 + GrainSpacing.x2,
                       height: GrainSpacing.x8 + GrainSpacing.x2)
                .background(Circle().fill(GrainColor.surface.opacity(find.searchOpen ? 1 : 0)))
                .overlay(Circle().strokeBorder(
                    GrainColor.borderFaint.opacity(find.searchOpen ? 1 : 0), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(find.searchOpen ? "Close conversation search" : "Search all conversations")
        .accessibilityValue(find.searchOpen ? "Open" : "Closed")
    }

    // MARK: connect header — auto-connect STATUS + the inline "Connect your Omi" affordance

    /// The capture header shown when the Omi isn't connected. ONE clean headline row
    /// per the prototype top bar ("Capture" + quiet icon actions — the record path
    /// lives on the CTA card below, not up here). Source connection is automatic +
    /// self-healing, so the connecting / reconnecting / searching states read as
    /// ambient STATUS (a spinner + a line) — the user does NOT drive a scan. A clean
    /// nothing-connected idle (or Bluetooth-off) surfaces the inline "Connect your
    /// Omi" affordance. Discovered Omis fold in below only for first-time pairing.
    private func connectHeader(_ p: CaptureSourcePresentation) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: GrainSpacing.x2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capture").grainTextStyle(.title).foregroundStyle(GrainColor.ink)
                    HStack(spacing: GrainSpacing.x1) {
                        if p.isAutoConnecting { ProgressView().controlSize(.mini).tint(GrainColor.forgeBlue) }
                        Text(p.statusLine)
                            .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: GrainSpacing.x2)
                headerSearchButton
            }
            .padding(.horizontal, GrainSpacing.x4)
            .padding(.vertical, GrainSpacing.x2)
            // Keep connection setup available without crowding the title-bar actions.
            if p.showsConnectAffordance {
                HStack {
                    GrainButton("Connect your Omi", variant: .filled, size: .sm) { device.start() }
                    Spacer()
                }
                .padding(.horizontal, GrainSpacing.x4)
                .padding(.bottom, GrainSpacing.x2)
            }
            // First-time pairing only: a scan turned up Omis — tap yours to connect.
            // (Routine reconnect is automatic; this never asks the user to drive a scan.)
            if !device.discovered.isEmpty { discoveredList }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(GrainColor.borderFaint).frame(height: 1) }
    }

    /// The compact, inline list of Omis a scan has discovered. Tapping one connects.
    private var discoveredList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(device.discovered) { dev in
                Button { device.connect(dev) } label: {
                    HStack(spacing: GrainSpacing.x2) {
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(GrainColor.forgeBlue)
                        Text(dev.name).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                        Spacer()
                        Text("\(dev.rssi) dBm").grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                    }
                    .padding(.horizontal, GrainSpacing.x4)
                    .padding(.vertical, GrainSpacing.x2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The connected/ambient header: the active source + live state and the single
    /// record/pause control. Connection management (Disconnect / Forget / re-pair) lives
    /// on the Device page now — this surface is purely "start/stop recording".
    private func ambientHeader(name: String, presentation p: CaptureSourcePresentation) -> some View {
        HStack(spacing: GrainSpacing.x2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Capture").grainTextStyle(.title).foregroundStyle(GrainColor.ink)
                HStack(spacing: GrainSpacing.x1) {
                    GrainStatusDot(p.isCapturing ? .running : .stopped, size: .sm)
                    Text("\(name) · \(p.statusLine)")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: GrainSpacing.x2)
            // Manual conversation split (Feature 2): finalize the current section +
            // start a fresh conversation now, without waiting for the silence gap.
            // Only meaningful while actively capturing (not paused).
            if manager.isCapturing {
                GrainButton("New", variant: .tonal, size: .sm) { manager.splitConversation() }
            }
            headerSearchButton
            // (The record/pause control moved onto the recording instrument strip —
            // one control, beside the ring it commands.)
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.vertical, GrainSpacing.x2)
        .overlay(alignment: .bottom) { Rectangle().fill(GrainColor.borderFaint).frame(height: 1) }
    }

    // MARK: global "your data is safe" signal

    private var syncBar: some View {
        HStack(spacing: GrainSpacing.x2) {
            if let message = syncMessage {
                Circle().fill(anyWorkPending ? GrainColor.amber : GrainColor.sage)
                    .frame(width: GrainSpacing.x2, height: GrainSpacing.x2)
                Text(message).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            } else if !manager.captures.isEmpty {
                Circle().fill(GrainColor.sage)
                    .frame(width: GrainSpacing.x2, height: GrainSpacing.x2)
                Text(local ? "All conversations saved" : "All captures saved to computer")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.top, GrainSpacing.x2)
        .padding(.bottom, GrainSpacing.x1)
    }

    private var anyWorkPending: Bool {
        manager.processingConversationCount > 0 || manager.hasPending
    }

    /// The processing banner: conversation-level progress FIRST ("N conversations
    /// processing" — the thing the user actually cares about), then the segment-upload
    /// detail. `nil` when there's genuinely nothing in flight.
    private var syncMessage: String? {
        var parts: [String] = []
        let convos = manager.processingConversationCount
        if convos > 0 {
            parts.append("\(convos) conversation\(convos == 1 ? "" : "s") processing")
        }
        let n = manager.pendingSegments
        if n > 0 {
            if case .failed = manager.sourceState {
                parts.append("\(n) segment\(n == 1 ? "" : "s") waiting to sync, will retry")
            } else {
                let suffix = manager.drainActive ? " · syncing…" : ""
                parts.append("\(n) segment\(n == 1 ? "" : "s") saved on phone\(suffix)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: GrainSpacing.x3) {
            Spacer()
            Image(grain: .waveform)
                .font(.system(size: GrainSpacing.x8 + GrainSpacing.x2, weight: .light))
                .foregroundStyle(GrainColor.textFaint)
            Text("No conversations yet").grainTextStyle(.title).foregroundStyle(GrainColor.ink)
            // Phone-only tier: no computer, no required Omi — record with the mic and
            // everything is transcribed + stays on-device. Computer tier keeps the
            // ambient-Omi + sync story.
            Text(local
                 ? "Tap record to capture your first conversation. It’s transcribed and titled right here on your phone. Nothing ever leaves this device."
                 : "Connect your Omi above, or tap record. Capture runs ambiently while your Omi is connected. Audio is held on your phone and synced to your computer; nothing leaves your devices.")
                .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
                .multilineTextAlignment(.center).padding(.horizontal, GrainSpacing.x6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// One capture's card — observes its WAL (segment sync) AND its door status poller
/// (the Lore-pipeline stage chip). Shows the conversation's start–end–duration + the
/// place label when present (Phase A: time + place + stage; title/transcript land in
/// Phase B). Time-only when no location fix was captured.
private struct CaptureCard: View {
    @ObservedObject var wal: CaptureWAL
    let meta: ConversationMeta?
    /// The durable, all-time name/description tombstone (seeds the card before the
    /// live poll returns, and after the transcript text has been pruned).
    let card: ConversationCardMeta?
    @ObservedObject var poller: CaptureStatusPoller
    /// Whether a transcript has been cached locally (Ready / pruned tombstone).
    let hasCachedTranscript: Bool
    /// Cache this conversation's transcript on sight if it's recent (~14d) + uncached.
    let onSight: () -> Void
    /// Phone-only tier: on-device labels (no "computer").
    var local: Bool = false
    /// The category it's filed under (inline pill beside the title; nil = unfiled).
    var categoryName: String?
    /// Whether the on-device model filed it (renders as "<category>, auto").
    var categoryAutoFiled: Bool = false
    /// Real segment sizes → the row's waveform thumbnail (loaded lazily; empty =
    /// audio pruned or not yet loaded — no waveform is drawn, never a fake one).
    var loadWaveform: (@Sendable () -> [Double])? = nil
    @State private var waveform: [Double] = []

    /// EVERYTHING the card shows, as pure tested data (track 20260714T1800): title,
    /// summary, one human status word, the quiet meta line, the category pill. The
    /// presentation has no field for sync statistics or raw errors — a card cannot
    /// leak what its data cannot carry.
    private var presentation: CaptureCardPresentation {
        CaptureCardPresentation.make(
            status: wal.status,
            meta: meta,
            card: card,
            pollerStage: poller.stage,
            pollerTitle: poller.title,
            pollerSummary: poller.summary,
            droppedReason: poller.droppedReason,
            hasCachedTranscript: hasCachedTranscript,
            local: local,
            categoryName: categoryName,
            categoryAutoFiled: categoryAutoFiled,
            waveform: waveform)
    }

    var body: some View {
        let p = presentation
        GrainConversationCard(
            title: p.title,
            categoryLabel: p.categoryLabel,
            summaryLine: p.summaryLine,
            meta: p.metaLine,
            statusWord: p.statusWord,
            status: statusTone(for: p),
            waveform: p.waveform,
            onTap: nil
        )
        // Drive the door→Lore status poll while the card is on screen; stop when it
        // scrolls off (the poller itself also stops at a terminal stage, F11). Also
        // cache a recent conversation's transcript on sight (offline/instant later).
        .onAppear { poller.start(); onSight() }
        .onDisappear { poller.stop() }
        // The waveform derives from real segment sizes on disk — one lazy read.
        .task {
            guard waveform.isEmpty, let loadWaveform else { return }
            let profile = await Task.detached(priority: .utility) { loadWaveform() }.value
            waveform = profile
        }
    }

    private func statusTone(for presentation: CaptureCardPresentation) -> GrainStatusTone {
        switch presentation.progress {
        case .ready, .savedToComputer:
            return .ready
        case .savedOnPhone:
            return presentation.statusWord == "Saved on this phone" ? .ready : .attention
        case .recording, .transcribing:
            return .attention
        case .failed:
            return .failed
        }
    }
}

/// Deepgram paragraph rendering for flat transcripts. Diarized captures use
/// `SpeakerTranscriptSection`; this keeps non-diarized transcripts readable without
/// inventing speaker turns.
private struct ParagraphTranscriptSection: View {
    let paragraphs: [TranscriptParagraph]

    private var chapters: [Chapter] { Chapter.group(paragraphs) }

    var body: some View {
        if chapters.count > 1 {
            VStack(alignment: .leading, spacing: GrainSpacing.x3) {
                ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                    DisclosureGroup {
                        ParagraphBlock(paragraphs: chapter.paragraphs)
                            .padding(.top, GrainSpacing.x2)
                    } label: {
                        HStack(spacing: GrainSpacing.x2) {
                            Text("Chapter \(index + 1)")
                                .grainTextStyle(.caption)
                                .foregroundStyle(GrainColor.ink)
                            Text(Self.timestamp(chapter.startMs))
                                .grainTextStyle(.caption)
                                .foregroundStyle(GrainColor.textFaint)
                        }
                    }
                    .padding(GrainSpacing.x3)
                    .background(
                        RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                            .fill(GrainColor.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                            .strokeBorder(GrainColor.borderHairline, lineWidth: 1)
                    )
                }
            }
        } else {
            ParagraphBlock(paragraphs: paragraphs)
        }
    }

    private static func timestamp(_ ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct ParagraphBlock: View {
    let paragraphs: [TranscriptParagraph]

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x3) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .grainTextStyle(.body)
                    .foregroundStyle(GrainColor.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The live, on-device transcription window (Feature 4). A TIGHT 1-clear + 1-fading
/// glimpse positioned ABOVE the recording meter: the newest words sit sharp at the
/// bottom, the line above starts to fade, and as new text streams in it animates up and
/// out — dissolving under the capture header (a top-edge fade mask). Only ~1–2 lines
/// inline; the full transcript lives in the conversation's detail view. The still-
/// settling VOLATILE tail is dimmer/italic and snaps when the recognizer finalizes (the
/// "guess then fix" feel). Ephemeral preview; Kiln's transcript remains authoritative.
private struct LiveTranscriptTicker: View {
    let transcript: LiveTranscript

    // ~2 lines tall — one clear line + one fading above it.
    private let height: CGFloat = 40

    /// The ticker only shows ~2 lines, so it renders just the most-recent words. This cap
    /// is also a HARD SAFETY BOUND: the full session transcript grows without limit during
    /// continuous capture, and rendering one styled run per word past a few hundred words
    /// overflowed the main-thread stack (build-89/90 SIGSEGV). The authoritative full
    /// transcript lives in Lore/Kiln, not here.
    private static let maxLiveWords = 48

    /// Word-level styled text (Feature 2): finalized words at full opacity, the trailing
    /// volatile word(s) dimmed with the NEWEST word the faintest + italic, each snapping
    /// to full opacity as the recognizer finalizes it. Driven by the pure, tested
    /// `LiveTranscript.renderedSegments()`. Built as a SINGLE `AttributedString` (one run
    /// per word) rather than folding `Text + Text` — the latter nests a
    /// `ConcatenatedTextStorage` per word whose resolve recurses once per level and blows
    /// the stack on long transcripts; a single attributed string resolves flat.
    private var styledText: Text {
        let segments = transcript.renderedSegments(maxWords: Self.maxLiveWords)
        var attributed = AttributedString()
        for (i, seg) in segments.enumerated() {
            var run = AttributedString((i == 0 ? "" : " ") + seg.text)
            run.foregroundColor = GrainColor.ink.opacity(seg.opacity)
            if seg.volatile { run.inlinePresentationIntent = .emphasized }   // italic tail
            attributed.append(run)
        }
        return Text(attributed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: GrainSpacing.x1) {
                // A soft pulsing dot marks this as the LIVE / provisional layer.
                Circle().fill(GrainColor.forgeBlue.opacity(0.7)).frame(width: 5, height: 5)
                Text("Live · on-device")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    styledText
                        .grainTextStyle(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .id("liveTail")
                        // Anchor newest text to the bottom of the window.
                        .frame(minHeight: height, alignment: .bottom)
                }
                .frame(height: height)
                .scrollDisabled(true)
                // Slide the newest words up into view AS they stream — no debounce on the
                // text itself (it re-renders on every snapshot). A SNAPPY (80 ms) scroll so
                // the freshest words are SEEN the instant they arrive (Feature 1 latency).
                .onChange(of: transcript.displayText) { _ in
                    withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo("liveTail", anchor: .bottom) }
                }
            }
            // Top-edge fade: the older line dissolves under the header as it scrolls up.
            .mask(
                LinearGradient(
                    gradient: Gradient(colors: [.clear, .black]),
                    startPoint: .top, endPoint: .center)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
