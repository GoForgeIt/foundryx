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
/// caption keeps the honest listening/paused line + the frames diagnostic
/// ("are frames arriving?" — framesReceived stuck at 0 ⇒ the source isn't
/// notifying, not a ring bug).
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

/// The honest listening line + frames diagnostic, in its own meter-observing
/// subview (12 Hz tick stays contained, exactly like the ring).
struct MeterCaption: View {
    @ObservedObject var meter: CaptureManager.AudioMeterModel
    let paused: Bool
    let isRecordingMic: Bool

    var body: some View {
        Text(paused ? "Paused, not listening"
             : (isRecordingMic ? "Recording from phone mic" : "Listening")
             + " · frames \(meter.framesReceived) · last \(meter.lastFrameBytes)B")
            .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            .monospacedDigit()
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

    // MARK: find + organize (track 20260713T0902, features/capture-home.feature)
    /// The user's categories, stored beside the captures they organize.
    @StateObject private var categories: ConversationCategoryStore
    /// Search over what the phone holds (titles + cached transcripts).
    @State private var searchOpen = false
    @State private var query = ""
    /// nil = no search active; else the ids that matched (computed off-main).
    @State private var searchMatches: Set<String>?
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
            if manager.visibleCaptures.isEmpty {
                // Keep the header search affordance honest even before the first
                // capture: opening it still reveals the same local search field.
                if searchOpen { findBar }
                emptyState
            } else {
                findBar
                conversationList
            }
        }
        .grainBackground()
        // Search sweeps disk (cached transcripts) — off-main, newest state wins.
        // TODO(full-history): Extend these local matches with computer/Lore results
        // once the full-history search capability is available.
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { searchMatches = nil; return }
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
            if query.trimmingCharacters(in: .whitespacesAndNewlines) == q {
                searchMatches = matched
            }
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

    // MARK: find + organize bar (search + category chips)

    private var findBar: some View {
        VStack(spacing: GrainSpacing.x2) {
            if searchOpen {
                HStack(spacing: GrainSpacing.x2) {
                    Image(grain: .search)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(GrainColor.textFaint)
                    TextField("Search conversations on this phone", text: $query)
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
        .padding(.top, searchOpen ? GrainSpacing.x2 : GrainSpacing.x1)
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
            }
        }
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

    /// Activity (track 20260713T0905): the ledger + recaps + plain-word measures,
    /// with the old Stats readout one tap deeper (subsumed, not lost).
    private var activityDestination: some View {
        ActivityView(
            decisionLogURL: AmbientPrefs.decisionLogURL(),
            recapPool: manager.recapConversationPool(),
            onOpenChat: { seed in AmbientCardBroker.shared.run(seed: seed) }
        )
        .toolbar {
            NavigationLink("Stats") { StatsView(summary: manager.statsSummary) }
        }
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
                        Text(section.title)
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textFaint)
                            .textCase(.uppercase)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, GrainSpacing.x3)
                            .padding(.bottom, GrainSpacing.x2)
                            .background(GrainColor.surface)
                    }
                }
            }
            .padding(.horizontal, GrainSpacing.x4)
            .padding(.bottom, GrainSpacing.x6)
        }
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
                    .map { CaptureCard.timeRangeString(meta: $0, fallback: wal.status.startedAt) }
                    ?? CaptureCard.timeRangeString(meta: nil, fallback: wal.status.startedAt),
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
            MeterCaption(meter: manager.meter, paused: manager.isPaused,
                         isRecordingMic: manager.isRecordingMic)
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
            withAnimation(.easeOut(duration: 0.2)) {
                searchOpen.toggle()
                if !searchOpen { query = "" }
            }
        } label: {
            Image(grain: .search)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(searchOpen ? GrainColor.forgeBlue : GrainColor.textMuted)
                .frame(width: GrainSpacing.x8 + GrainSpacing.x2,
                       height: GrainSpacing.x8 + GrainSpacing.x2)
                .background(Circle().fill(GrainColor.surface.opacity(searchOpen ? 1 : 0)))
                .overlay(Circle().strokeBorder(
                    GrainColor.borderFaint.opacity(searchOpen ? 1 : 0), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchOpen ? "Close conversation search" : "Search conversations")
        .accessibilityValue(searchOpen ? "Open" : "Closed")
    }

    /// Activity remains one tap from Capture, with the same destination and Stats
    /// toolbar, but shares the prototype's quiet circular icon treatment.
    private var activityButton: some View {
        NavigationLink {
            activityDestination
        } label: {
            Image(grain: .spark)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(GrainColor.textMuted)
                .frame(width: GrainSpacing.x8 + GrainSpacing.x2,
                       height: GrainSpacing.x8 + GrainSpacing.x2)
                .contentShape(Circle())
        }
        .accessibilityLabel("Activity")
    }

    // MARK: connect header — auto-connect STATUS + the inline "Connect your Omi" affordance

    /// The capture header shown when the Omi isn't connected. Source connection is
    /// automatic + self-healing, so the connecting / reconnecting / searching states read
    /// as ambient STATUS (a spinner + a line) — the user does NOT drive a scan. A clean
    /// nothing-connected idle (or Bluetooth-off) surfaces the inline "Connect your Omi"
    /// affordance, whose tap kicks off the automatic connect flow. The phone-mic record
    /// sphere is always offered as a manual source. Discovered Omis fold in below only for
    /// first-time pairing (no saved device yet), so the user can tap theirs.
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
                activityButton
                // The phone-mic record sphere — a manual capture source, always available.
                if manager.phoneMicAvailable {
                    MicSphereButton(recording: manager.isRecordingMic) { manager.toggleMicRecording() }
                }
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
            activityButton
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
    /// The category it's filed under (chip on the card; nil = unfiled).
    var categoryName: String?
    /// Real segment sizes → the row's waveform thumbnail (loaded lazily; empty =
    /// audio pruned or not yet loaded — no waveform is drawn, never a fake one).
    var loadWaveform: (@Sendable () -> [Double])? = nil
    @State private var waveform: [Double] = []

    /// The conversation's NAME — the live poll's title, falling back to the durable card.
    private var name: String? {
        if let t = poller.title, !t.isEmpty { return t }
        if let t = card?.title, !t.isEmpty { return t }
        return nil
    }
    /// The conversation's DESCRIPTION — the live poll's summary, falling back to the card.
    private var description: String? {
        if let s = poller.summary, !s.isEmpty { return s }
        if let s = card?.summary, !s.isEmpty { return s }
        return nil
    }

    /// The on-device PROVISIONAL transcript body shown the instant a capture is stopped,
    /// until the authoritative Kiln summary lands (Feature 1). Only when the card is still
    /// provisional and the poller hasn't returned a real title yet.
    private var provisionalPreview: String? {
        guard card?.isProvisional == true, (poller.title ?? "").isEmpty else { return nil }
        guard let body = card?.provisionalTranscript, !body.isEmpty else { return nil }
        return body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            // Kiln-generated title as the card's headline once known (live poll OR the
            // durable card tombstone); the progress chip drops to a secondary line.
            // Falls back to chip-only until a title exists.
            if let name {
                HStack(alignment: .top, spacing: GrainSpacing.x2) {
                    // Generic/duplicate titles (near-silent "Thank you", "Okay"…) get the
                    // start time appended so two different short captures read distinctly
                    // (track 20260628T1609). Specific titles render unchanged.
                    Text(ConversationTitleDisplay.display(
                        title: name, start: cardStart,
                        timeString: { Self.timeFmt.string(from: $0) }))
                        .grainTextStyle(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(GrainColor.ink)
                        .lineLimit(2)
                    Spacer(minLength: GrainSpacing.x2)
                    statusIndicator
                }
            } else {
                HStack {
                    statusIndicator
                    Spacer()
                }
            }

            Text(metadataLine)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)

            // The conversation's DESCRIPTION (what it was about) — shown on the card,
            // not just inside the detail view, so the whole timeline is scannable.
            if let description {
                Text(description).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                    .lineLimit(2)
            } else if let preview = provisionalPreview {
                // Instant on-device body until Kiln's summary overrides it in place.
                Text(preview).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                    .lineLimit(2)
                Text("On-device transcript · finishing on your computer…")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }

            HStack(spacing: GrainSpacing.x2) {
                if let categoryName {
                    Text(categoryName)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.forgeBlue)
                        .lineLimit(1)
                        .padding(.horizontal, GrainSpacing.x2)
                        .padding(.vertical, GrainSpacing.x1)
                        .background(Capsule().fill(GrainColor.forgeBlueBg))
                        .overlay(Capsule().strokeBorder(GrainColor.forgeBlueBorder, lineWidth: 1))
                }
                Text(detail).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                Spacer(minLength: GrainSpacing.x1)
                if !waveform.isEmpty { WaveformThumbView(profile: waveform) }
            }
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
            .fill(GrainColor.surface))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
            .strokeBorder(GrainColor.borderFaint, lineWidth: 1))
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

    /// The calm, folded processing chip (local WAL stage + door pipeline stage).
    private var progress: ConversationProgress {
        ConversationProgress.resolve(
            wal: wal.status.stage,
            streaming: wal.status.streaming,
            door: poller.stage,
            hasTitle: !(poller.title ?? "").isEmpty,
            hasCachedTranscript: hasCachedTranscript
        )
    }

    /// Calm status dot + the same honest pipeline copy the original card exposed.
    private var statusIndicator: some View {
        HStack(spacing: GrainSpacing.x1) {
            GrainStatusDot(progress.statusDot, size: .sm)
            Text(statusText)
                .grainTextStyle(.caption)
                .foregroundStyle(progress == .failed ? GrainColor.dangerRed : GrainColor.textMuted)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// A dropped capture keeps Lore's specific terminal reason instead of a
    /// misleading generic retry label.
    private var statusText: String {
        if progress == .failed {
            return ConversationProgress.failureMessage(droppedReason: poller.droppedReason)
                ?? progress.label(local: local)
        }
        return progress.label(local: local)
    }

    /// "10:41–10:47 AM · 6 min" when closed; start time alone while open.
    private var timeRange: String { Self.timeRangeString(meta: meta, fallback: wal.status.startedAt) }

    /// Time and optional place share the prototype's single quiet metadata line.
    private var metadataLine: String {
        guard let place else { return timeRange }
        return "\(timeRange) · \(place)"
    }

    /// The conversation's durable REAL START (for the title-time suffix). Same
    /// processing-time-proof priority the list uses: meta → card → capture-id → (last
    /// resort) the WAL launch time.
    private var cardStart: Date {
        if let s = meta?.startedAt, s > 0 { return Date(timeIntervalSince1970: TimeInterval(s)) }
        if let s = card?.startedAt, s > 0 { return Date(timeIntervalSince1970: TimeInterval(s)) }
        if let s = CaptureIdTime.startedAt(fromCaptureId: wal.captureId), s > 0 {
            return Date(timeIntervalSince1970: TimeInterval(s))
        }
        return wal.status.startedAt
    }

    /// Shared formatter so the conversation detail view shows the SAME time range
    /// as the card. `fallback` is the WAL start used when there's no metadata sidecar.
    static func timeRangeString(meta: ConversationMeta?, fallback: Date) -> String {
        // Lead with the DATE so "when the recording happened" is unambiguous (captures
        // span days), then the time-of-day range + duration.
        guard let meta else { return "\(dayFmt.string(from: fallback)) · \(timeFmt.string(from: fallback))" }
        let start = Date(timeIntervalSince1970: TimeInterval(meta.startedAt))
        let day = dayFmt.string(from: start)
        guard let endSecs = meta.endedAt else { return "\(day) · \(timeFmt.string(from: start))" }
        let end = Date(timeIntervalSince1970: TimeInterval(endSecs))
        let span = "\(timeFmt.string(from: start))–\(timeFmt.string(from: end))"
        if let dur = meta.durationSeconds {
            let mins = max(1, Int((Double(dur) / 60).rounded()))
            return "\(day) · \(span) · \(mins) min"
        }
        return "\(day) · \(span)"
    }

    private var place: String? { meta?.location?.label }

    private var detail: String {
        let s = wal.status
        let kb = String(format: "%.1f", Double(s.bytes) / 1024)
        let synced = "\(s.syncedSegments)/\(s.totalSegments) segments synced · \(kb) KB"
        if let err = s.lastSyncError, s.pendingSegments > 0 { return "\(synced) · \(err)" }
        return synced
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()
}

/// The phone-mic record control as a compact sphere (Feature 3). Idle: a subtle mic
/// glyph in a quiet circle. Recording: a RED record sphere with an animated pulse ring
/// radiating outward, so "you're recording" reads at a glance. Tapping toggles.
/// The row's small waveform: real segment-size energy, normalized. Purely
/// decorative summary of the recording's shape — hidden entirely when audio has
/// been pruned (no fake waveforms).
private struct WaveformThumbView: View {
    let profile: [Double]

    var body: some View {
        Canvas { ctx, size in
            let n = profile.count
            guard n > 1 else { return }
            let step = size.width / CGFloat(n - 1)
            let middle = size.height / 2
            var path = Path()
            for (i, v) in profile.enumerated() {
                let x = CGFloat(i) * step
                let amplitude = max(1, size.height * CGFloat(v) * 0.42)
                let direction: CGFloat = i.isMultiple(of: 2) ? -1 : 1
                let point = CGPoint(x: x, y: middle + direction * amplitude)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            ctx.stroke(
                path,
                with: .color(GrainColor.forgeBlue.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: GrainSpacing.x8 + GrainSpacing.x8, height: GrainSpacing.x4)
        .accessibilityHidden(true)
    }
}

private struct MicSphereButton: View {
    let recording: Bool
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Pulsing ring (recording only): expands + fades, forever.
                if recording {
                    Circle()
                        .fill(GrainColor.dangerRed.opacity(0.35))
                        .frame(width: 44, height: 44)
                        .scaleEffect(pulse ? 1.3 : 0.8)
                        .opacity(pulse ? 0.0 : 0.7)
                }
                Circle()
                    .fill(recording ? GrainColor.dangerRed : GrainColor.surfaceElevated)
                    .frame(width: 34, height: 34)
                    .overlay(
                        Circle().strokeBorder(recording ? Color.clear : GrainColor.border, lineWidth: 1)
                    )
                Image(systemName: recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(recording ? Color.white : GrainColor.ink)
            }
            .frame(width: 46, height: 46)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recording ? "Stop recording" : "Record")
        .onAppear { syncPulse(recording) }
        .onChange(of: recording) { now in syncPulse(now) }
    }

    private func syncPulse(_ on: Bool) {
        if on {
            pulse = false
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
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
