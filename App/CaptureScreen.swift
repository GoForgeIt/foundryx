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

/// The hero tile's provisional NAME, isolated in its own observer so a rolling-title
/// publish invalidates just this label — never the conversation list behind it. The same
/// law `RecordingRingView` obeys for the 12 Hz meter, applied to the live TEXT that was
/// left on the hot object (track 20260722T1244).
private struct LiveHeroTitleLabel: View {
    @ObservedObject var live: CaptureManager.LiveCaptureModel
    /// DEBUG screenshot override; nil in a normal launch (then the live model is read).
    var previewTitle: String? = nil

    @ViewBuilder var body: some View {
        if let title = previewTitle ?? live.title {
            Text(title)
                .grainTextStyle(.body).foregroundStyle(GrainColor.ink).lineLimit(1)
        }
    }
}

/// The hero tile's live transcript ticker, isolated for the same reason as
/// `LiveHeroTitleLabel`: the transcript publishes several times a second while recording.
private struct LiveHeroTicker: View {
    @ObservedObject var live: CaptureManager.LiveCaptureModel
    /// DEBUG screenshot override; nil in a normal launch.
    var previewTranscript: LiveTranscript? = nil

    @ViewBuilder var body: some View {
        let transcript = previewTranscript ?? live.transcript
        if !transcript.isEmpty { LiveTranscriptTicker(transcript: transcript) }
    }
}

/// The session-owned ticking elapsed readout (1 Hz), monospaced so it never wobbles.
/// STATELESS — it holds NO `@State`: it derives its value from a `RecordingClock` the
/// manager owns (`clock.elapsed(now:)`, which already excludes paused spans), so a view
/// re-present (minimize → restore, a fresh `fullScreenCover`) can never reset it or
/// double-count a pause. A nil clock reads `0:00` (no live session).
struct SessionElapsedLabel: View {
    /// The session clock to render (manager-owned); nil ⇒ no live recording.
    let clock: RecordingClock?
    /// Optional font override (defaults to the Grain `.caption` scale). The full-screen
    /// RecordingScreen reuses this for its big ring-center time AND its small forge island
    /// time, so it needs to restyle the readout.
    var font: Font? = nil
    /// Optional colour override (defaults to `textMuted`).
    var color: Color? = nil

    @ViewBuilder private func readout(_ s: Int) -> some View {
        let text = Text(String(format: "%d:%02d", s / 60, s % 60))
        if let font { text.font(font) } else { text.grainTextStyle(.caption) }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let s = max(0, Int(clock?.elapsed(now: timeline.date) ?? 0))
            readout(s)
                .foregroundStyle(color ?? GrainColor.textMuted)
                .monospacedDigit()
        }
    }
}

// `CaptureActivityWiring` lived here: Activity's parameter wiring, extracted from the old
// buried Capture NavigationLink when Activity became a top-level TAB (track 20260714T1800).
// DELETED (track `residual_on_main_actor_work`) — it had no callers left; `MainTabs` in
// RootView.swift is the one place that mounts `ActivityView`. It was also a trap: it kept
// the eager `recapPool: manager.recapConversationPool()` argument and the eager
// `StatsView` destination that the Activity tab has since moved off the render path, so
// anyone reviving it would have silently reintroduced both.

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
    /// The transcript to REOPEN, from the durable place the shell restored
    /// (features/app-place-restore.feature). Drives one programmatic push; cleared when
    /// that detail is dismissed, or by the shell if the person moves off this tab first.
    @Binding var reopenCaptureId: String?
    /// The transcript that is open RIGHT NOW, reported UP so the shell can write it down.
    /// Reported by the detail itself, so a tap on a row's `NavigationLink` and a
    /// programmatic push are both seen — there is one place a detail appears.
    @Binding var openCaptureId: String?
    @State private var pendingDeleteId: String?
    // Multi-select MERGE (Nick's decision): a long-press on a conversation row enters
    // multi-select and selects it; tapping more rows toggles them; a "Merge N" action folds
    // the selected split conversations into ONE (CaptureManager.merge). Normal single-tap
    // (open conversation) is preserved when NOT in multi-select.
    @State private var selectionMode = false
    @State private var selectedIds: Set<String> = []
    /// After a merge lands, the primary conversation to OPEN so you see it all together
    /// (drives a programmatic push into its detail). Cleared when the detail is dismissed.
    @State private var justMergedId: String?
    /// The RESOLVED target of the one programmatic push — a merged conversation or a
    /// restored place's transcript, whichever is pending, once the library actually holds
    /// it. Resolved by `resolvePendingDetailPush()`, never by the render path.
    @State private var pushedDetail: CaptureWAL?
    #if DEBUG || PERF_HARNESS
    @State private var deepDetail = false      // screen-proof: `-Screen detail`
    @State private var deepRecording = false   // screen-proof: `-Screen recording`
    /// screen-proof: `-CaptureHome recording` → the Capture tab's LIVE HERO TILE (not the
    /// full-screen recorder), seeded with a ring + elapsed + transcript, no real mic.
    /// Derived DIRECTLY from the launch args on every render — NOT @State. Under
    /// `-MainPreview` the phone-tier model-download banner (`brainSetupBanner`) toggles a
    /// sibling ABOVE CaptureScreen in its VStack, churning CaptureScreen's structural
    /// identity and resetting any @State to its initial `false` — which silently dropped
    /// the forced tile back to the plain CTA. Reading the args each render is immune.
    private var capturePreviewRecording: Bool {
        let a = ProcessInfo.processInfo.arguments
        return a.contains("-CaptureHome") && a.contains("recording")
    }
    /// screen-proof: the paused variant (`-CaptureHome recording paused`).
    private var capturePreviewPaused: Bool {
        ProcessInfo.processInfo.arguments.contains("paused")
    }
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
         target: DoorTarget, local: Bool = false,
         reopenCaptureId: Binding<String?> = .constant(nil),
         openCaptureId: Binding<String?> = .constant(nil)) {
        self.device = device
        self.manager = manager
        self.sources = sources
        self.target = target
        self.local = local
        _reopenCaptureId = reopenCaptureId
        _openCaptureId = openCaptureId
        _categories = StateObject(wrappedValue: manager.makeCategoryStore())
    }

    /// Whether the Omi is still an enabled capture source (device-page toggle). When off,
    /// the capture page neither auto-starts nor shows the Omi scan affordance.
    private var omiEnabled: Bool { sources.isEnabled(CaptureSourceDescriptor.omiId) }

    /// Resolve a pending programmatic push (a just-merged conversation, or a restored
    /// place's transcript) against the library — ONCE per library change, never per body
    /// pass. The `navigationDestination` binding then reads `pushedDetail` in O(1).
    ///
    /// Doing the `first(where:)` inside the binding's `get` instead would be an O(N) scan
    /// on every render for the entire time the detail is presented — the exact per-render
    /// main-actor cost `ResidualMainActorWorkTests` exists to keep out.
    private func resolvePendingDetailPush() {
        guard pushedDetail == nil, let id = justMergedId ?? reopenCaptureId else { return }
        // Not found yet is not "gone": the library hydrates off-main after mount. Nothing
        // is pushed until the conversation is actually loadable, so a restore can never
        // land on an empty shell — and a conversation that is truly gone simply never
        // arrives, leaving the list, which is the honest answer.
        guard let wal = manager.captures.first(where: { $0.captureId == id }) else { return }
        pushedDetail = wal
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            syncBar
            // The hero slot (track 20260717T0600): not recording → the calm "Record a
            // conversation" CTA; recording (or a connected source) → a FULL-HERO-SIZE live
            // recording tile — the big ring, the elapsed time from the session's start, the
            // live words — and the whole tile opens the recorder. The old compact strip that
            // crammed the big ring into a small row is gone; the hero slot IS the live tile.
            heroSlotView
            if manager.visibleCaptures.isEmpty {
                if manager.listRows.isEmpty {
                    // Keep the header search affordance honest even before the first
                    // capture: opening it still reveals the same local search field.
                    if find.searchOpen { findBar }
                    emptyState
                } else {
                    // Scan-free warm seed (T1 AC5): the list paints populated on the first
                    // frame from card.json (no segment scan) while the off-main WAL
                    // hydration runs; it swaps to the real cards the instant it lands.
                    recentHeadline(count: manager.listRows.count)
                    seededList
                }
            } else {
                recentHeadline(count: manager.visibleCaptures.count)
                findBar
                conversationList
            }
        }
        .grainBackground()
        // The full-screen recording surface (prototype scene 09): present whenever the
        // phone mic is recording OR an ambient session is active. The record CTA starts
        // the mic → the flag flips → this presents; End/save clears the flag/session → the
        // computed binding goes false → SwiftUI dismisses. (Supersedes the inline strip,
        // which stays behind the cover as the pre-record "listening" surface.)
        .fullScreenCover(isPresented: Binding(
            get: { (manager.isRecordingMic || manager.active != nil)
                    && !manager.recordingScreenMinimized
                    // A surface already owning the screen and driving capture itself
                    // (onboarding's first-note step) suppresses this cover for its
                    // whole lifetime — two competing full-screen covers means SwiftUI
                    // drops one, and it was dropping the flow the user was mid-way
                    // through.
                    && !manager.suppressesRecordingSurface },
            set: { _ in })) {
            RecordingScreen(
                manager: manager,
                live: manager.live,
                target: target,
                suggestions: { recordingSuggestions },
                onEnd: endRecording,
                onMinimize: { manager.minimizeRecordingScreen() })
        }
        // Multi-select MERGE: the bottom action bar rides above the list while selecting.
        .overlay(alignment: .bottom) {
            if selectionMode { mergeActionBar.transition(.move(edge: .bottom)) }
        }
        .animation(.easeOut(duration: 0.2), value: selectionMode)
        // The ONE programmatic push into a conversation's detail, with two callers: a merge
        // that just landed (open the merged conversation so you see it all together) and a
        // restored place reopening the transcript you were reading. Deliberately one
        // modifier, not two — SwiftUI honours a single `navigationDestination(isPresented:)`
        // per stack, so a second one silently wins over the first.
        //
        // `isPresented` is true only once the conversation is actually LOADABLE. A restore
        // fires at mount, before the library has hydrated, and pushing on the id alone
        // renders the empty shell this whole change exists to avoid; waiting means the push
        // lands a moment later, or — if the conversation is genuinely gone — never, leaving
        // you on the list, which is the honest answer.
        .navigationDestination(isPresented: Binding(
            get: { pushedDetail != nil },
            set: { if !$0 { pushedDetail = nil; justMergedId = nil; reopenCaptureId = nil } }
        )) {
            if let wal = pushedDetail { conversationDetail(wal) }
        }
        // Re-attempt the pending push whenever the library changes size — which is how a
        // restore issued at mount lands once hydration reaches its conversation. Runs on
        // appear too, so an already-warm library pushes immediately.
        .task(id: manager.captures.count) { resolvePendingDetailPush() }
        #if DEBUG || PERF_HARNESS
        // DEV screen-proof deep-links (real manager + target; PERF_HARNESS too, so the
        // sim-perf deep-nav phase can surveil the detail/speaker surfaces under the
        // stall watchdog): `-Screen detail` opens a
        // conversation's three-face detail; `-Screen recording` presents the full
        // RecordingScreen from a FROZEN preview (fixed clock + seeded live transcript +
        // demo suggestions) so every section renders in the simulator without a real mic.
        .onAppear {
            // COMPILED OUT OF A SHIPPING BUILD (leak gate) — same class as the other `-Screen`
            // seams: a launch argument that deep-links a surface. No effect on a normal launch
            // either way; the argument path simply no longer exists in the shipping build.
            #if DEBUG || PERF_HARNESS
            let a = ProcessInfo.processInfo.arguments
            if a.contains("-Screen"), a.contains("detail") { deepDetail = true }
            if a.contains("-Screen"), a.contains("recording") { deepRecording = true }
            #endif
            // The live HERO tile on the Capture tab (NOT the full-screen recorder) is forced
            // statelessly from the launch args in `heroSlot` — no seeding needed: the tile
            // renders its ring + fixed elapsed + seeded transcript from the forced slot. We
            // deliberately do NOT seed an active session here, so the redundant minimized
            // RecordingPill (RootView) stays out of the clean hero screenshot. Tap-through to
            // the real recorder is exercised by real recordings, not this static preview.
        }
        .fullScreenCover(isPresented: $deepRecording) {
            RecordingScreen(
                manager: manager,
                live: manager.live,
                target: target,
                suggestions: { recordingSuggestions },
                preview: RecordingPreview(
                    since: Date().addingTimeInterval(-102),   // reads 01:42, like the prototype
                    transcript: LiveTranscript(
                        finalizedText: "For the launch we still need the deck updated. The relay decision matters here.",
                        volatileTail: "Foundry remind me to send Sarah the deck",
                        isComplete: false)),
                onEnd: { deepRecording = false },
                onMinimize: { deepRecording = false })
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
            Text("Categories are yours: rename or delete them any time. Deleting one never deletes its voice notes.")
        }
        // NOTE: the on-device summary backfill was REMOVED — it drove up to ~12 conversations ×
        // 2 Foundation-Models inferences on every home-list appear, and Apple's FoundationModels
        // aggregator crashes (EXC_BREAKPOINT "Range requires lowerBound <= upperBound" in
        // TranscriptWritingAggregator.transcriptEntriesSlice, incident 81C00A61 / build 211). A
        // Swift runtime trap can't be caught, so the only mitigation is to not batch-call the
        // framework. The card-summary fallback (ConversationFacesView.summaryText) fixes the
        // headline "card shows a summary but detail says none" bug without any model call.
        // Power on the Omi only when it's still an enabled source; always drive the meter.
        // `-SyntheticOmi` (DEBUG/PERF-only, leak-gated) stands in for a paired Omi, so it
        // must start the ambient source even though the preview registry has no real device
        // enabled — otherwise the ambient E2E can never arm (AmbientRecordingProofUITests).
        .onAppear {
            var startAmbient = omiEnabled
            #if DEBUG || PERF_HARNESS
            if ProcessInfo.processInfo.arguments.contains("-SyntheticOmi") { startAmbient = true }
            #endif
            if startAmbient { manager.startSource() }
            manager.startMeter()
        }
        // Presenting the full-screen RecordingScreen cover fires THIS view's onDisappear;
        // stopping the meter unconditionally there kills the recording ring / pill ring /
        // Live Activity level mid-session (Bug 2). Let the manager decide — it only stops
        // the meter when genuinely idle.
        .onDisappear { manager.captureSurfaceDidDisappear() }
        .confirmationDialog("Delete voice note?",
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

    // MARK: full-screen recording presentation

    /// End the capture behind the full-screen RecordingScreen: a phone-mic session stops
    /// (its `.stopped` finalizes + clears the flag); an Omi session ends the current
    /// conversation. Either clears the binding's condition, dismissing the cover.
    private func endRecording() {
        if manager.isRecordingMic {
            manager.stopMicRecording()
        } else {
            _ = manager.endCurrentConversation()
        }
    }

    /// The ambient suggestions to stack on the recording screen — mapped from the REAL
    /// candidates the Tier-1 lane surfaced during this recording (`manager.recordingCandidates`).
    /// The section collapses when there are none (the screen never fabricates a suggestion).
    /// The DEV `-Screen recording` proof seeds the prototype's two rows so the section renders.
    private var recordingSuggestions: [RecordingSuggestion] {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        if a.contains("-Screen"), a.contains("recording") {
            return [
                RecordingSuggestion(
                    id: "demo-memory",
                    tint: .memory, systemImage: "sparkle", eyebrow: "From your memory",
                    title: "The relay decision",
                    body: "You chose the blind Noise relay on June 30.",
                    actionLabel: "Open", action: {}),
                RecordingSuggestion(
                    id: "demo-agent",
                    tint: .agent, systemImage: "bolt", eyebrow: "Request heard",
                    title: "Send Sarah the deck Friday at 9:00 AM",
                    body: "Review before anything runs.",
                    actionLabel: "Review", action: {}),
            ]
        }
        #endif
        return manager.recordingCandidates.map(candidateSuggestion)
    }

    /// Map ONE real lane candidate to a recording-screen row. The candidate carries no
    /// pre-routed kind (routing happens async through the door), so we use the same
    /// on-device signal the notifier's owner gate uses: an utterance that names the
    /// configured agent reads as an AGENT request (forge tint, "Review"); everything
    /// else reads as a MEMORY surface (amber tint, "Open"). The action does the real
    /// thing — hands the moment to a seeded chat (the wired RUN path) — after minimizing
    /// the surface so the chat is visible; the row is dismissed either way.
    private func candidateSuggestion(_ c: AmbientCandidate) -> RecordingSuggestion {
        let agentName = AmbientPrefs.agentName() ?? ""
        let isAgent = !agentName.isEmpty
            && (c.utterance.range(of: agentName, options: .caseInsensitive) != nil
                || c.summary.range(of: agentName, options: .caseInsensitive) != nil)
        let ask = c.summary.isEmpty ? "help with that" : c.summary
        let seed = "While I was taking a note, this came up: “\(c.utterance)”\n\nPlease \(ask)."
        return RecordingSuggestion(
            id: c.utterance,   // stable identity = the candidate's dedup key
            tint: isAgent ? .agent : .memory,
            systemImage: isAgent ? "bolt" : "sparkle",
            eyebrow: isAgent ? "Request heard" : "From your memory",
            title: c.summary.isEmpty ? c.utterance : c.summary,
            body: "“\(c.utterance)”",
            actionLabel: isAgent ? "Review" : "Open",
            action: {
                manager.dismissRecordingCandidate(c)
                manager.minimizeRecordingScreen()   // reveal the chat under the cover
                // The live recording IS the source conversation (EXT3 provenance).
                AmbientCardBroker.shared.run(seed: seed,
                                             captureId: manager.active?.captureId)
            })
    }

    // MARK: record CTA — the calm "Record a conversation" card (prototype :2202)

    /// Mic circle + headline + the on-phone reassurance line. Tapping starts the
    /// existing phone-mic recording path.
    private var recordCTA: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
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
                .accessibilityIdentifier("record-cta")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!manager.phoneMicAvailable)

            // A blocked/greyed record button is otherwise silent — say WHY. A missing mic
            // source disables the button (so a tap can't set the reason), so surface that
            // case directly; otherwise show whatever the last tap recorded.
            if let reason = recordBlockCaption {
                Text(reason)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("record-block-reason")
            }
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.top, GrainSpacing.x2)
    }

    /// The record-block explanation to show under the CTA, or nil when recording is
    /// unblocked. A missing mic source greys the button (no tap → no manager reason),
    /// so explain that directly; else defer to the manager's last-tap reason.
    private var recordBlockCaption: String? {
        if !manager.phoneMicAvailable {
            return "Microphone access is needed — enable it in Settings"
        }
        return manager.lastRecordBlockReason
    }

    // MARK: "Recent on this phone" headline + Search all (prototype :2203)

    private func recentHeadline(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                GrainSectionEyebrow(CaptureHomeCopy.recentHeadline)
                Text(CaptureHomeCopy.conversationCount(count))
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
            .accessibilityLabel("Search all voice notes")
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
        // PRESORTED: `visibleCaptures` is sorted date-descending at every rebuild and the
        // search/category filters preserve order, so the grouping must not re-sort N rows on
        // every body pass (track `residual_on_main_actor_work`).
        let sections = ConversationGrouping.groupPresorted(filteredCaptures, now: Date()) {
            manager.conversationStartDate($0)
        }
        // NOT pinned (T1 AC3): a pinned header needs an opaque band to hide the rows
        // scrolling under it — that band was the white/elevated stripe the design never
        // had. Non-sticky eyebrows sit on the page background instead.
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
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

    /// The scan-free first-paint list (T1 AC5): the warm-seeded rows (title + date from
    /// card.json, no segment scan) rendered as the same conversation card, so the Capture
    /// home is POPULATED on the first frame. Replaced by `conversationList` the instant the
    /// off-main WAL hydration publishes `visibleCaptures`.
    private var seededList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(manager.listRows) { row in
                    GrainConversationCard(
                        title: row.title,
                        summaryLine: nil,
                        meta: row.dateLabel,
                        statusWord: "",
                        status: .neutral,
                        waveform: [],
                        onTap: nil
                    )
                    .padding(.bottom, GrainSpacing.x2)
                }
            }
            .padding(.horizontal, GrainSpacing.x4)
            .padding(.bottom, GrainSpacing.x6)
        }
    }

    /// A plain small-caps eyebrow on the page background — no filled band (T1 AC3).
    private func searchSectionHeader(_ title: String) -> some View {
        GrainSectionEyebrow(title, tint: .muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, GrainSpacing.x3)
            .padding(.bottom, GrainSpacing.x2)
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
                Text(hit.title.isEmpty ? "Untitled voice note" : hit.title)
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

    /// One conversation row. In NORMAL mode it's a tappable card → its transcript detail,
    /// with a LONG-PRESS entering multi-select. In MULTI-SELECT mode the same card toggles
    /// its selection on tap and shows a Grain selection badge — navigation is suppressed so a
    /// tap selects, not opens.
    @ViewBuilder private func conversationRow(_ wal: CaptureWAL) -> some View {
        if selectionMode {
            selectableConversationRow(wal)
        } else {
            navigableConversationRow(wal)
        }
    }

    /// NORMAL mode: tap opens the three-face detail; a long-press enters multi-select and
    /// selects this row. `simultaneousGesture` keeps the tap-to-open behavior intact.
    private func navigableConversationRow(_ wal: CaptureWAL) -> some View {
        NavigationLink {
            // LAZY DESTINATION, and here it is not hygiene (review round 12, H12-1).
            // `NavigationLink`'s `destination:` is a @ViewBuilder evaluated WITH the link, so
            // an unwrapped `conversationDetail(wal)` is constructed on every body pass of THIS
            // screen, once per row — and `conversationDetail` now evaluates
            // `CaptureAttributionPresentation.attribution(captureId:baseDir:)` as an eager
            // argument, which is an uncached `fileExists` + two `Data(contentsOf:)` + a JSON
            // decode on the MAIN ACTOR. That is precisely the "a decode and a `fileExists` PER
            // ROW PER RENDER" pathology `ResidualMainActorWorkTests` exists for, and it cannot
            // see this one because `swift test` cannot compile `App/`. `LazyView` (declared in
            // `App/RootView.swift`, with the full rationale) defers construction to the first
            // render of the destination itself — so the read happens once, when the row is
            // actually pushed.
            LazyView { conversationDetail(wal) }
        } label: {
            conversationCard(wal)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in enterSelection(wal.captureId) }
        )
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
            // Merge — the discoverable entry into multi-select for folding split conversations.
            Button {
                enterSelection(wal.captureId)
            } label: {
                Label("Merge with…", systemImage: "arrow.triangle.merge")
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

    /// MULTI-SELECT mode: tapping the card toggles its selection; a Grain badge + highlight
    /// mark the chosen rows (adaptive light + Night Shift via Grain tokens).
    private func selectableConversationRow(_ wal: CaptureWAL) -> some View {
        let selected = selectedIds.contains(wal.captureId)
        return conversationCard(wal)
            .overlay(alignment: .topTrailing) { selectionBadge(selected) }
            .overlay(
                RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                    .strokeBorder(selected ? GrainColor.forgeBlue : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
            .onTapGesture { toggleSelection(wal.captureId) }
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            .accessibilityLabel(selected ? "Selected for merge" : "Tap to select for merge")
            // Auto-file where the on-device model can — only while the user hasn't.
            .task { await autoTagIfNeeded(wal.captureId) }
    }

    /// The conversation card content shared by both row modes (the label under the
    /// NavigationLink, and the tappable card in multi-select).
    @ViewBuilder private func conversationCard(_ wal: CaptureWAL) -> some View {
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
                                          buckets: 24, seed: wal.captureId)
                },
                // The ACCOUNT-SCOPED root, not `CaptureWAL.documentsCaptures()` — reading the
                // device-global tree would attribute from the wrong account's archive.
                loadAttribution: { [weak manager] in
                    guard let baseDir = manager?.baseDir else { return nil }
                    return CaptureAttributionPresentation.attribution(captureId: wal.captureId,
                                                                       baseDir: baseDir)
                },
                canRecover: manager.canManuallyRecover(wal.captureId),
                recoveryInProgress: manager.isManualRecoveryInProgress(wal.captureId),
                onRecover: { [weak manager] in
                    Task { await manager?.recoverIncompleteCapture(wal.captureId) }
                }
            )
        }
    }

    /// The three-face detail (track 20260713T0904): Summary / Actions / Transcript + text
    /// search; same parameters, same stores underneath.
    private func conversationDetail(_ wal: CaptureWAL) -> some View {
        ConversationFacesView(
            target: target,
            manager: manager,
            captureId: wal.captureId,
            timeRange: manager.conversationMeta(for: wal.captureId)
                .map { CaptureCardPresentation.timeRangeString(meta: $0, fallback: wal.status.startedAt) }
                ?? CaptureCardPresentation.timeRangeString(meta: nil, fallback: wal.status.startedAt),
            place: manager.conversationMeta(for: wal.captureId)?.location?.label,
            // Read from the ACCOUNT-SCOPED root — never `CaptureWAL.documentsCaptures()`,
            // which would attribute from the wrong account's archive.
            //
            // THIS IS AN EAGER ARGUMENT AND IT TOUCHES DISK. An earlier comment here claimed
            // it was "read ONCE, at push time — not per body pass"; that was false, and
            // review round 12 (H12-1) measured the difference. It is read whenever
            // `conversationDetail(_:)` is CALLED, and the row's `NavigationLink` calls it —
            // so the honest way to make the claim true is the `LazyView` at the call site,
            // which is what defers this to the push. Keep them together: unwrap that
            // `LazyView` and this becomes an uncached main-actor disk read per row per body
            // pass.
            attribution: CaptureAttributionPresentation.attribution(captureId: wal.captureId,
                                                                     baseDir: manager.baseDir),
            conversationDate: manager.conversationMeta(for: wal.captureId)
                .map { Date(timeIntervalSince1970: TimeInterval($0.startedAt)) }
                ?? wal.status.startedAt
        )
        // THE ONE PLACE A TRANSCRIPT REPORTS ITSELF. Every route into a conversation's
        // detail — a tapped row's `NavigationLink`, a merge, a restored place — calls this
        // builder, so reporting here means the shell knows what is open without any of
        // those call sites having to remember to say so (features/app-place-restore.feature).
        .onAppear { openCaptureId = wal.captureId }
        .onDisappear { if openCaptureId == wal.captureId { openCaptureId = nil } }
    }

    /// The Grain selection badge shown on a row in multi-select: a filled Forge-Blue check
    /// when selected, an empty ring otherwise.
    private func selectionBadge(_ selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(selected ? GrainColor.forgeBlue : GrainColor.surface)
                .overlay(Circle().strokeBorder(
                    selected ? GrainColor.forgeBlue : GrainColor.borderFaint, lineWidth: 1.5))
            if selected {
                Image(grain: .check)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(GrainColor.onAccent)
            }
        }
        .frame(width: 24, height: 24)
        .padding(GrainSpacing.x2)
    }

    // MARK: multi-select MERGE actions

    /// Enter multi-select and select `captureId` (the long-pressed row).
    private func enterSelection(_ captureId: String) {
        selectionMode = true
        selectedIds = [captureId]
    }

    /// Toggle a row's membership in the merge selection.
    private func toggleSelection(_ captureId: String) {
        if selectedIds.contains(captureId) { selectedIds.remove(captureId) }
        else { selectedIds.insert(captureId) }
    }

    /// Leave multi-select, dropping the selection.
    private func exitSelection() {
        selectionMode = false
        selectedIds = []
    }

    /// The bottom action bar shown in multi-select: "Merge N" (enabled at ≥2) + "Cancel".
    private var mergeActionBar: some View {
        HStack(spacing: GrainSpacing.x3) {
            GrainButton("Cancel", variant: .ghost, size: .lg) { exitSelection() }
            Spacer()
            Text("\(selectedIds.count) selected")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
            GrainButton("Merge \(selectedIds.count)", variant: .filled, size: .lg) {
                let ids = Array(selectedIds)
                exitSelection()   // snappy exit
                Task {
                    // Open the merged conversation so you land on it all together (the door
                    // re-ingests the fuller transcript in the background; the detail refreshes
                    // as it arrives). No-op merge (nil) leaves you on the list.
                    if let primaryId = await manager.merge(captureIds: ids) {
                        justMergedId = primaryId
                        // The merged conversation exists NOW, so resolve the push straight
                        // away rather than waiting for the next library-size change (a merge
                        // shrinks the library, so that would fire — but not depending on it
                        // keeps "open what I merged" immediate).
                        resolvePendingDetailPush()
                    }
                }
            }
            .disabled(selectedIds.count < 2)
            .opacity(selectedIds.count < 2 ? 0.5 : 1)
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.vertical, GrainSpacing.x3)
        .background(
            GrainColor.surface
                .overlay(GrainColor.borderFaint.frame(height: 1), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
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

    // MARK: hero slot — record CTA, or the live recording tile (track 20260717T0600)

    /// The Capture tab's hero: the calm record CTA when idle, a full-hero-size live tile
    /// while recording (or a source is connected). ONE slot — the compact instrument strip
    /// that used to cram the big ring into a small row (track 20260713T0903) is gone.
    @ViewBuilder private var heroSlotView: some View {
        switch heroSlot {
        case .recordCTA:
            recordCTA
        case .liveTile(let tile):
            liveHeroTile(tile)
        }
    }

    /// Which tile the hero slot shows — the pure, tested `LiveHeroPresentation` decision.
    /// The DEBUG `-CaptureHome recording` seed forces the live tile so the simulator can
    /// screenshot it without a real mic.
    private var heroSlot: LiveHeroPresentation.Slot {
        #if DEBUG
        if capturePreviewRecording {
            return .liveTile(.init(showsElapsed: true, hasRecorder: true, paused: capturePreviewPaused))
        }
        #endif
        return LiveHeroPresentation.slot(
            isShowingCapture: isShowingCapture,
            hasActiveSession: manager.active != nil,
            isRecordingMic: manager.isRecordingMic,
            isPaused: manager.isPaused)
    }

    /// The full-hero-size live recording tile — the hero slot itself while recording. Reads
    /// as the same card family as `GrainRecordCTA` at the same visual weight: the hero-scale
    /// voice ring on the left, the live readout (status · elapsed · provisional title) on the
    /// right, the live transcript below, Pause/Resume in reach. The whole tile is tappable →
    /// opens the full recording screen (`restoreRecordingScreen` clears `minimized`, so the
    /// `fullScreenCover` binding presents it). The ring observes ONLY `manager.meter`, so its
    /// 12 Hz tick never invalidates the conversation list (the isolation law the old strip
    /// obeyed). A connected source with no active WAL degrades: ring + status, no elapsed,
    /// not tappable.
    private func liveHeroTile(_ tile: LiveHeroPresentation.LiveTile) -> some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x3) {
            HStack(spacing: GrainSpacing.cardPad) {
                RecordingRingView(meter: manager.meter, paused: tile.paused)
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                    Text(MeterCaptionText.caption(paused: tile.paused,
                                                  isRecordingMic: manager.isRecordingMic))
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                    // Elapsed from the SESSION-OWNED RecordingClock (track 20260717T0630's
                    // law): manager-owned, pause-aware, survives minimize/restore and
                    // internal conversation rolls — no view-local timer, no view @State.
                    if tile.showsElapsed {
                        SessionElapsedLabel(clock: heroClock,
                                            font: GrainFont.sans(28, weight: .semibold),
                                            color: GrainColor.ink)
                    }
                    // The provisional name — the manager's ROLLING title, derived from the
                    // WHOLE conversation so far (track 20260717T1015) and stabilized by the
                    // arbiter, so it appears once enough was said and never jitters.
                    LiveHeroTitleLabel(live: manager.live, previewTitle: heroPreviewTitle)
                }
                Spacer(minLength: 0)
                if tile.hasRecorder {
                    GrainButton(tile.paused ? "Resume" : "Pause",
                                variant: tile.paused ? .filled : .tonal, size: .sm) {
                        manager.togglePause()
                    }
                    .accessibilityIdentifier("live-hero-pause")
                }
            }
            LiveHeroTicker(live: manager.live, previewTranscript: heroPreviewTranscript)
        }
        .padding(GrainSpacing.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                .fill(GrainColor.surface))
        .overlay(
            RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                .strokeBorder(GrainColor.borderFaint, lineWidth: 1))
        .contentShape(Rectangle())
        // Tapping opens the full recording screen (only when a recorder is behind the tile;
        // a connected-idle source has none). Pause's own Button consumes its taps.
        .onTapGesture { if tile.hasRecorder { manager.restoreRecordingScreen() } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(tile.hasRecorder ? .isButton : [])
        .accessibilityLabel(tile.hasRecorder ? "Voice note in progress, tap to open" : "Listening")
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.top, GrainSpacing.x2)
    }

    /// The clock behind the live tile's elapsed readout: the manager-owned session
    /// clock (the single elapsed-time truth). The DEBUG preview derives a fixed-offset
    /// clock so the screenshot reads a non-zero time.
    private var heroClock: RecordingClock? {
        #if DEBUG
        if capturePreviewRecording {
            return RecordingClock(startedAt: Date().addingTimeInterval(-102),  // reads 01:42
                                  paused: capturePreviewPaused)
        }
        #endif
        return manager.recordingClock
    }

    /// The hero tile's provisional name is the manager's ROLLING title (the same
    /// whole-conversation source the recording screen reads; fixed at the source, track
    /// 20260717T1015) — read INSIDE `LiveHeroTitleLabel`, which observes the live model
    /// alone so a title publish can't invalidate the list. This is only the DEBUG
    /// screenshot override, derived from the seeded preview transcript; nil in a normal
    /// launch.
    private var heroPreviewTitle: String? {
        #if DEBUG
        if capturePreviewRecording, let t = heroPreviewTranscript {
            return WholeConversationTitle.heuristic(from: t.displayText)
        }
        #endif
        return nil
    }

    /// The seeded preview transcript for the DEBUG `-CaptureHome recording` screenshot
    /// path; nil in a normal launch, where `LiveHeroTicker` reads the live model.
    private var heroPreviewTranscript: LiveTranscript? {
        #if DEBUG
        if capturePreviewRecording {
            return LiveTranscript(
                finalizedText: "For the launch we still need the deck updated. The relay decision matters here.",
                volatileTail: "Foundry remind me to send Sarah the deck",
                isComplete: false)
        }
        #endif
        return nil
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
        .accessibilityLabel(find.searchOpen ? "Close voice note search" : "Search all voice notes")
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
                    // connectOrPair(): reconnect a remembered device, else a bounded,
                    // user-initiated pairing scan. start() alone is dormant with no saved
                    // device (the no-Omi fix), so a first-time user needs the explicit scan.
                    GrainButton("Connect your Omi", variant: .filled, size: .sm) { device.connectOrPair() }
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

    /// The HONEST determinate drain progress across captures that still have pending
    /// segments — read-only over the sync-owned WAL state (WS-C). `nil` when nothing is
    /// draining, so no fake bar ever shows.
    private var syncProgress: WaitProgress? {
        let active = manager.captures.filter { $0.status.pendingSegments > 0 }
        guard !active.isEmpty else { return nil }
        let total = active.reduce(0) { $0 + $1.status.totalSegments }
        let done = active.reduce(0) { $0 + $1.status.syncedSegments }
        return .determinate(done: done, total: total)
    }

    private var sourceFailed: Bool {
        if case .failed = manager.sourceState { return true }
        return false
    }

    // The one-line, CONSTANT-HEIGHT "your data is safe" strip (WS-B). The old strip
    // swapped between a one-liner, a three-line waiting card, and nothing — shoving the
    // list down every time a sync flapped. Now it's a fixed-height row whose content
    // cross-fades, debounced + minimum-shown by `SyncBarPresenter` so brief drains never
    // flicker it. All copy/height come from the strip's own honest ingredients below.
    private var syncBar: some View {
        SyncStatusStripView(content: syncStripContent)
    }

    /// The honest ingredients for the strip, computed from live sync state. Every string
    /// is real: the determinate sync count comes from `WaitingExperienceModel.statusLine`,
    /// the pending detail from `syncMessage`, and the calm settled line from
    /// `SyncStripCopy` — nothing is invented.
    private var syncStripContent: SyncStripContent {
        let determinate = syncProgress != nil && !sourceFailed
        // The honest "N of M segments …" count paired with the bar while syncing.
        let syncingText: String = {
            guard let progress = syncProgress else { return syncMessage ?? "" }
            let model = WaitingExperienceModel(kind: .sync, onDevice: local, progress: progress)
            return model.statusLine(elapsed: 0)
        }()
        // Settled content: the pending detail if any work is still in flight, else the
        // calm all-saved line.
        let settledText: String
        let settledIsPending: Bool
        if let message = syncMessage {
            settledText = message
            settledIsPending = anyWorkPending
        } else {
            settledText = SyncStripCopy.allSaved(local: local)
            settledIsPending = false
        }
        return SyncStripContent(
            hasCaptures: !manager.captures.isEmpty,
            syncing: determinate,
            progress: syncProgress,
            syncingText: syncingText,
            settledText: settledText,
            settledIsPending: settledIsPending)
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
            parts.append("\(convos) voice note\(convos == 1 ? "" : "s") processing")
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
            Text("No voice notes yet").grainTextStyle(.title).foregroundStyle(GrainColor.ink)
            // Phone-only tier: no computer, no required Omi — record with the mic and
            // everything is transcribed + stays on-device. Computer tier keeps the
            // ambient-Omi + sync story.
            Text(local
                 ? "Make your first voice note. It’s transcribed and titled here on your phone. Nothing leaves this device."
                 : "Connect your Omi above, or make a voice note. Capture stays ambient while your Omi is connected. Audio stays on your phone and syncs to your computer. Nothing leaves your devices.")
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
    /// WHICH DEVICE RECORDED THIS, read off the capture directory (two small file reads).
    /// Loaded exactly like the waveform — once, off the main thread — because
    /// `CaptureAttributionPresentation.attribution(captureId:baseDir:)` touches disk and a
    /// computed property is re-evaluated on every body pass inside a LazyVStack.
    var loadAttribution: (@Sendable () -> CaptureAttribution?)? = nil
    @State private var attribution: CaptureAttribution?
    var canRecover = false
    var recoveryInProgress = false
    var onRecover: (() -> Void)?

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
            waveform: waveform,
            manualRecoveryInProgress: recoveryInProgress)
    }

    var body: some View {
        let p = presentation
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            GrainConversationCard(
                title: p.title,
                categoryLabel: p.categoryLabel,
                summaryLine: p.summaryLine,
                // The device that RECORDED this conversation, named on the row. Composed in the
                // Kit so the copy is a tested value and not string arithmetic in a view body.
                meta: CaptureAttributionPresentation.metaLine(p.metaLine, attribution: attribution),
                statusWord: p.statusWord,
                status: statusTone(for: p),
                waveform: p.waveform,
                // Animate only in-progress cards (recording / transcribing); a finished card
                // is static-but-varied (T1 AC4).
                waveformAnimated: isInProgress(p),
                onTap: nil
            )
            if canRecover || recoveryInProgress {
                Button(CaptureCardPresentation.manualRecoveryActionTitle) { onRecover?() }
                    .disabled(recoveryInProgress)
                    .grainTextStyle(.body)
                    .accessibilityHint("Retries sending this voice note's audio to your computer")
            }
        }
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
        // Same shape as the waveform: one lazy read of the two on-disk surfaces.
        .task {
            guard attribution == nil, let loadAttribution else { return }
            attribution = await Task.detached(priority: .utility) { loadAttribution() }.value
        }
    }

    /// An in-progress conversation still being captured or transcribed — its waveform
    /// animates (a live shimmer); every settled state is static.
    private func isInProgress(_ presentation: CaptureCardPresentation) -> Bool {
        switch presentation.progress {
        case .recording, .transcribing: return true
        default: return false
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
