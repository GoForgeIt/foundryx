import SwiftUI
import AVFoundation
import Grain

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
struct CaptureScreen: View {
    // Shared with the Device tab (owned by MainTabs) so both surfaces see one BLE
    // link + one capture pipeline.
    @ObservedObject var device: DeviceManager
    @ObservedObject var manager: CaptureManager
    /// The resolved door target — lets a tapped card open its transcript (Phase B).
    let target: DoorTarget

    var body: some View {
        VStack(spacing: 0) {
            header
            // Live transcript ABOVE the voice-recording animation (Feature 4): a tight
            // 1-clear + 1-fading window that slides up and dissolves under the header.
            // Ephemeral, on-device preview; Kiln's transcript remains authoritative.
            if isShowingCapture {
                if !manager.liveTranscript.isEmpty {
                    LiveTranscriptTicker(transcript: manager.liveTranscript)
                        .padding(.horizontal, GrainSpacing.x4)
                        .padding(.top, GrainSpacing.x2)
                }
                meterBar
            }
            syncBar
            if manager.visibleCaptures.isEmpty {
                emptyState
            } else {
                conversationList
            }
        }
        .grainBackground()
        .onAppear { manager.startSource(); manager.startMeter() }  // power on + drive the meter
        .onDisappear { manager.stopMeter() }
    }

    // MARK: conversation list — grouped into dated sections (Feature 5)

    /// The timeline, grouped newest-first into Today / Yesterday / weekday / "Last week"
    /// / "N weeks ago" / month sections. The grouping is the pure, tested
    /// `ConversationGrouping`; `visibleCaptures` is already date-desc, so sections stay
    /// in order. LazyVStack keeps off-screen cards (and their pollers) inert.
    private var conversationList: some View {
        let sections = ConversationGrouping.group(manager.visibleCaptures, now: Date()) {
            manager.conversationStartDate($0)
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: GrainSpacing.x3, pinnedViews: [.sectionHeaders]) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Section {
                        ForEach(section.items, id: \.captureId) { wal in
                            conversationRow(wal)
                        }
                    } header: {
                        Text(section.title)
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, GrainSpacing.x1)
                            .background(GrainColor.background)
                    }
                }
            }
            .padding(GrainSpacing.x4)
        }
    }

    /// One tappable conversation card → its transcript detail.
    private func conversationRow(_ wal: CaptureWAL) -> some View {
        NavigationLink {
            ConversationDetailView(
                target: target,
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
            CaptureCard(
                wal: wal,
                meta: manager.conversationMeta(for: wal.captureId),
                card: manager.cardMeta(for: wal.captureId),
                poller: manager.statusPoller(for: wal.captureId),
                hasCachedTranscript: manager.hasCachedTranscript(wal.captureId),
                // Cache RECENT (~14d) transcripts on sight (no-op for older / already-cached).
                onSight: { manager.ensureRecentTranscriptCached(wal.captureId) }
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: live audio meter (req 8) — shows the Omi is actually hearing sound

    private var meterBar: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            LevelMeterView(levels: manager.levels, active: !manager.isPaused)
            Text(manager.isPaused ? "Paused — not listening"
                 : (manager.isRecordingMic ? "Recording from phone mic — bars rise as it hears you"
                                           : "Listening — bars rise as it hears you"))
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            // Diagnostic: definitive "are frames arriving?" signal. framesReceived
            // stuck at 0 ⇒ the Omi isn't notifying (not a meter bug).
            Text("frames \(manager.framesReceived) · last \(manager.lastFrameBytes)B")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                .monospacedDigit()
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.vertical, GrainSpacing.x2)
        .overlay(alignment: .bottom) { Rectangle().fill(GrainColor.borderHairline).frame(height: 1) }
    }

    // MARK: header — ambient control when connected, else the connect/pairing flow

    @ViewBuilder private var header: some View {
        switch device.connectionState {
        case .connected(let name):
            ambientHeader(name)
        default:
            // Omi not connected: ONE compact header (Feature 3) — capture title/status on
            // the left; the Omi scan icon + the phone-mic record sphere inline on the
            // right; the discovered-device list folds in below only while scanning finds
            // results. Reclaims the vertical space the old separate connect rows ate.
            consolidatedHeader
        }
    }

    /// Whether the live capture surface (meter + transcript) should show: the Omi is
    /// connected, or the phone mic is actively recording.
    private var isShowingCapture: Bool {
        if case .connected = device.connectionState { return true }
        return manager.isRecordingMic
    }

    // MARK: consolidated capture header (Omi scan icon + mic sphere inline, Feature 3)

    /// The single compact capture header shown when the Omi isn't connected: the capture
    /// title + a status subtitle on the left; the Omi scan icon and the phone-mic record
    /// sphere inline on the right. The Omi icon expands into a "Scanning…" pill on tap and
    /// collapses on connect. Discovered devices fold in below only while there are results.
    private var consolidatedHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: GrainSpacing.x3) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Capture").grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                    Text(captureSubtitle)
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                }
                Spacer()
                // The Omi as a small circular icon that expands to a "Scanning…" pill.
                OmiScanButton(presentation: OmiScanPresentation.from(device.connectionState)) { action in
                    switch action {
                    case .startScan: device.startScan()
                    case .stopScan: device.stopScan()
                    case .none: break
                    }
                }
                // The phone-mic record sphere (build #65), inline beside the Omi icon.
                if manager.phoneMicAvailable {
                    MicSphereButton(recording: manager.isRecordingMic) { manager.toggleMicRecording() }
                }
            }
            .padding(.horizontal, GrainSpacing.x4)
            .padding(.vertical, GrainSpacing.x3)
            // Compact discovered-device list — only while a scan has found Omis.
            if !device.discovered.isEmpty { discoveredList }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(GrainColor.borderHairline).frame(height: 1) }
    }

    /// The header's status subtitle: phone-mic recording state takes priority, else a
    /// short reflection of the Omi connection state, else the inline how-to.
    private var captureSubtitle: String {
        if manager.isRecordingMic { return "Recording — tap to stop" }
        switch device.connectionState {
        case .scanning: return "Scanning for your Omi…"
        case .connecting(let n): return "Connecting to \(n)…"
        case .disconnected: return "Omi disconnected — reconnecting…"
        case .poweredOff: return "Bluetooth off — enable it to connect your Omi"
        default:
            return manager.phoneMicAvailable
                ? "Tap the mic to record · tap the Omi to connect"
                : "Tap the Omi to connect"
        }
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

    private func ambientHeader(_ name: String) -> some View {
        HStack(spacing: GrainSpacing.x3) {
            Circle().fill(manager.isPaused ? GrainColor.amber : GrainColor.forgeBlue)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                Text(manager.isPaused ? "Paused" : "Capturing ambiently")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            }
            Spacer()
            // Manual conversation split (Feature 2): finalize the current section +
            // start a fresh conversation now, without waiting for the silence gap.
            // Only meaningful while actively capturing (not paused).
            if manager.isCapturing {
                GrainButton("New", variant: .tonal, size: .sm) { manager.splitConversation() }
            }
            GrainButton(manager.isPaused ? "Resume" : "Pause",
                        variant: manager.isPaused ? .filled : .tonal, size: .sm) {
                manager.togglePause()
            }
            GrainButton("Disconnect", variant: .text, size: .sm) { device.forget() }
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.vertical, GrainSpacing.x3)
        .overlay(alignment: .bottom) { Rectangle().fill(GrainColor.borderHairline).frame(height: 1) }
    }

    // MARK: global "your data is safe" signal

    private var syncBar: some View {
        HStack(spacing: GrainSpacing.x2) {
            if manager.hasPending {
                Circle().fill(GrainColor.amber).frame(width: 8, height: 8)
                Text(syncMessage).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            } else if !manager.captures.isEmpty {
                Circle().fill(GrainColor.sage).frame(width: 8, height: 8)
                Text("All captures saved to computer").grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.vertical, GrainSpacing.x2)
    }

    private var syncMessage: String {
        let n = manager.pendingSegments
        if case .failed = manager.sourceState {
            return "\(n) segment\(n == 1 ? "" : "s") waiting to sync — will retry"
        }
        return "\(n) segment\(n == 1 ? "" : "s") saved on phone · syncing…"
    }

    private var emptyState: some View {
        VStack(spacing: GrainSpacing.x3) {
            Spacer()
            Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(GrainColor.inkTertiary)
            Text("No captures yet").grainTextStyle(.title).foregroundStyle(GrainColor.ink)
            Text("Connect your Omi above. Capture runs ambiently while it's connected — audio is held on your phone and synced to your computer; nothing leaves your devices.")
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
                // Generic/duplicate titles (near-silent "Thank you", "Okay"…) get the
                // start time appended so two different short captures read distinctly
                // (track 20260628T1609). Specific titles render unchanged.
                Text(ConversationTitleDisplay.display(title: name, start: cardStart,
                                                      timeString: { Self.timeFmt.string(from: $0) }))
                    .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                    .lineLimit(2)
            }
            HStack(spacing: GrainSpacing.x2) {
                // Calm Grain status dot communicates motion: working states pulse,
                // Ready breathes at rest, failed smolders.
                GrainStatusDot(progress.statusDot, size: .sm)
                Text(progress.label).grainTextStyle(name == nil ? .body : .caption)
                    .foregroundStyle(progress == .failed ? GrainColor.dangerRed
                                     : (name == nil ? GrainColor.ink : GrainColor.textMuted))
                Spacer()
                Text(timeRange).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }
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
            // Place (when a fix was captured) — time-only otherwise (honest degradation).
            if let place {
                Text(place).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            }
            Text(detail).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).fill(GrainColor.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).strokeBorder(GrainColor.border, lineWidth: 1))
        // Drive the door→Lore status poll while the card is on screen; stop when it
        // scrolls off (the poller itself also stops at a terminal stage, F11). Also
        // cache a recent conversation's transcript on sight (offline/instant later).
        .onAppear { poller.start(); onSight() }
        .onDisappear { poller.stop() }
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

    /// "10:41–10:47 AM · 6 min" when closed; start time alone while open.
    private var timeRange: String { Self.timeRangeString(meta: meta, fallback: wal.status.startedAt) }

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
        if let err = s.lastSyncError, s.pendingSegments > 0 { return "\(synced) · ⏳ \(err)" }
        return synced
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()
}

/// Phase B: a conversation's TRANSCRIPT. Fetched from the door (which reads it from
/// the local Lore engine, keyed by the phone's capture id). Shows time + place +
/// the transcript; a friendly "still processing" state until Lore has transcribed
/// it. The nav title is derived from the first few words of the transcript (real
/// subject/summary generation is a later slice).
struct ConversationDetailView: View {
    let target: DoorTarget
    let captureId: String
    let timeRange: String
    let place: String?
    /// When the conversation happened — used to decide whether its transcript is
    /// recent (auto-loaded/cached) or older (loaded on demand from the door).
    let conversationDate: Date?

    @State private var content: CaptureContent?
    @State private var cached: CachedTranscript?   // local fallback (pruned audio / offline)
    @State private var provisional: ConversationCardMeta?  // on-device provisional (instant, pre-Kiln)
    @State private var loadError: String?
    @State private var loading = true
    @State private var didAttemptFetch = false

    /// True when the conversation is OLDER than the ~14-day transcript-cache window:
    /// its transcript text isn't kept locally, so it loads on demand (a button /
    /// pull-to-refresh) rather than auto-fetching on open.
    private var isOlder: Bool {
        guard let d = conversationDate else { return false }
        return Date().timeIntervalSince(d) > CaptureRetention.transcriptRetention
    }

    // Listen affordance state.
    @State private var audioState: AudioState = .idle
    @State private var player: AVAudioPlayer?

    private enum AudioState: Equatable { case idle, loading, playing, unavailable, failed(String) }

    /// The transcript to render: prefer the live door content, fall back to the
    /// locally cached transcript (so it survives audio pruning + offline).
    private var transcriptText: String? {
        if let c = content, c.found, !c.transcript.isEmpty { return c.transcript }
        if let cached, !cached.transcript.isEmpty { return cached.transcript }
        // On-device provisional body — shown instantly until Kiln's lands.
        if let p = provisional, p.isProvisional, let body = p.provisionalTranscript, !body.isEmpty { return body }
        return nil
    }
    /// True when the transcript currently shown is the on-device provisional (no door /
    /// cached Kiln transcript yet) — drives a "still finishing" note.
    private var showingProvisional: Bool {
        let hasAuthoritative = (content?.found == true && !(content?.transcript.isEmpty ?? true))
            || (cached.map { !$0.transcript.isEmpty } ?? false)
        return !hasAuthoritative && (provisional?.isProvisional == true)
            && !((provisional?.provisionalTranscript ?? "").isEmpty)
    }
    private var summaryText: String? { content?.summary ?? cached?.summary }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GrainSpacing.x3) {
                Text(timeRange).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                if let place {
                    Text(place).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                }
                listenRow
                Divider().background(GrainColor.borderHairline)

                if let transcript = transcriptText {
                    // Kiln-generated summary when ready; a subtle "Summarizing…" hint
                    // while the door generates it (the .task re-fetches once).
                    if let summary = summaryText, !summary.isEmpty {
                        Text("Summary").grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                        Text(summary)
                            .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                            .textSelection(.enabled)
                        Divider().background(GrainColor.borderHairline)
                    } else if content?.summarizing == true {
                        Text("Summarizing…").grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                    }
                    if showingProvisional {
                        Text("On-device transcript · finishing on your computer…")
                            .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                    }
                    Text("Transcript").grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                    Text(transcript)
                        .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                        .textSelection(.enabled)
                } else if loading {
                    Text("Loading transcript…")
                        .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
                } else if didAttemptFetch, content?.found == false, loadError == nil {
                    // We asked the door and it doesn't have the transcript yet.
                    Text("Transcript still processing…")
                        .grainTextStyle(.title).foregroundStyle(GrainColor.ink)
                    Text("Your conversation is saved. The transcript shows up here once it's been processed on your computer.")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                    GrainButton("Check again", variant: .tonal, size: .sm) { Task { await fetchFromDoor() } }
                } else {
                    // Older / not-yet-fetched conversation: load the transcript on demand
                    // (this transcript isn't cached locally; pull-to-refresh also works).
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
            .padding(GrainSpacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .grainBackground()
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await fetchFromDoor() }   // pull-to-refresh loads on demand
        .task { await initialLoad() }
        .onDisappear { player?.stop() }
    }

    /// "Listen" affordance — replays the conversation audio via the door's `/audio`
    /// endpoint. Gated so a 404 (endpoint not ready / audio pruned on desktop) reads
    /// as a calm "Audio not available" rather than an error.
    @ViewBuilder private var listenRow: some View {
        switch audioState {
        case .idle:
            GrainButton("Listen", variant: .tonal, size: .sm) { Task { await playAudio() } }
        case .loading:
            Text("Loading audio…").grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        case .playing:
            GrainButton("Stop", variant: .text, size: .sm) { player?.stop(); audioState = .idle }
        case .unavailable:
            Text("Audio not available").grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
        case .failed(let why):
            Text("Couldn't play audio: \(why)").grainTextStyle(.caption).foregroundStyle(GrainColor.amber)
        }
    }

    /// Prefer the Kiln-generated title; fall back to the cached title, then the first
    /// ~6 words of the transcript, then "Conversation".
    private var navTitle: String {
        if let t = content?.title, !t.isEmpty { return t }
        if let t = cached?.title, !t.isEmpty { return t }
        if let t = provisional?.title, !t.isEmpty { return t }
        guard let t = transcriptText, !t.isEmpty else { return "Conversation" }
        let words = t.split(whereSeparator: { $0 == " " || $0 == "\n" }).prefix(6).joined(separator: " ")
        return words.isEmpty ? "Conversation" : words
    }

    /// On open: show the locally cached transcript instantly if we have one. Otherwise
    /// auto-fetch for a RECENT conversation; for an OLDER one, wait for an explicit
    /// "Load transcript" (or pull-to-refresh) so we don't always hit the network for
    /// the long tail of old conversations.
    private func initialLoad() async {
        loadError = nil
        // Seed from the local cache first so a recent / pruned-audio / offline
        // conversation shows its transcript instantly. Also load the on-device
        // provisional card so a just-stopped conversation shows its text before Kiln.
        let base = CaptureWAL.documentsCaptures()
        cached = TranscriptCacheStore.load(captureId: captureId, baseDir: base)
        provisional = ConversationCardStore.load(captureId: captureId, baseDir: base)
        if cached != nil {
            loading = false
            return            // instant from cache — no fetch needed
        }
        if isOlder {
            loading = false   // older + uncached → load on demand (button / pull-to-refresh)
            return
        }
        await fetchFromDoor() // recent + uncached → auto-fetch
    }

    /// Fetch the transcript from the door (`GET /content`) on demand, cache it if
    /// ready, and surface a summarizing re-fetch. Drives the "Load transcript" button
    /// and pull-to-refresh.
    private func fetchFromDoor() async {
        loading = true
        loadError = nil
        didAttemptFetch = true
        do {
            content = try await DoorClient(target: target).captureContent(captureId: captureId)
            cacheIfReady(content)
        } catch {
            // Door unreachable — keep the cached transcript if we have one; only show
            // an error when there's nothing cached to fall back to.
            if cached == nil { loadError = (error as NSError).localizedDescription }
        }
        loading = false
        // The door generates the title/summary in the background on first fetch; if
        // it's still summarizing, re-fetch once after a short delay so they appear
        // without the user having to leave + reopen the conversation.
        if content?.summarizing == true, (content?.title ?? "").isEmpty {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let refreshed = try? await DoorClient(target: target).captureContent(captureId: captureId) {
                content = refreshed
                cacheIfReady(refreshed)
            }
        }
    }

    /// Persist the transcript locally once the door returns it, so it survives audio
    /// pruning + offline. Also stamps the in-Lore confirmation marker (a transcript
    /// can only exist because Lore transcribed the audio).
    private func cacheIfReady(_ c: CaptureContent?) {
        guard let c, c.found, !c.transcript.isEmpty else { return }
        let baseDir = CaptureWAL.documentsCaptures()
        let entry = CachedTranscript(transcript: c.transcript, title: c.title,
                                     summary: c.summary, fetchedAt: UInt64(max(0, Date().timeIntervalSince1970)))
        TranscriptCacheStore.save(entry, captureId: captureId, baseDir: baseDir)
        // Seed the durable all-time name/description tombstone too.
        ConversationCardStore.merge(captureId: captureId, baseDir: baseDir,
                                    title: c.title, summary: c.summary, stage: nil)
        cached = entry
    }

    private func playAudio() async {
        audioState = .loading
        do {
            guard let bytes = try await DoorClient(target: target).captureAudio(captureId: captureId) else {
                audioState = .unavailable   // 404 — endpoint not ready / audio pruned on desktop
                return
            }
            // TODO: the door assembles Ogg-Opus; AVAudioPlayer can't decode Opus on all
            // iOS versions. If playback fails here, route the bytes through an Opus
            // decoder (or have the door transcode to AAC/m4a) — tracked with the
            // parallel /audio endpoint work.
            let p = try AVAudioPlayer(data: bytes)
            player = p
            p.play()
            audioState = .playing
        } catch {
            audioState = .failed((error as NSError).localizedDescription)
        }
    }
}

/// The Omi connect control as a compact CIRCULAR icon that EXPANDS into a "Scanning…"
/// pill on tap (Feature 3). Collapsed (idle/disconnected): a small circle with an
/// antenna glyph — tapping starts a scan. Scanning/Connecting: a wider capsule with a
/// label + a subtle activity indicator — tapping while scanning stops it. Connected is
/// styled distinctly (though the header switches to the ambient layout on connect, so it
/// rarely renders here). Pure presentation + toggle live in `OmiScanPresentation`.
private struct OmiScanButton: View {
    let presentation: OmiScanPresentation
    let onTap: (OmiScanTapAction) -> Void

    var body: some View {
        Button { onTap(presentation.tapAction) } label: {
            HStack(spacing: GrainSpacing.x1) {
                if presentation.showsActivity {
                    ProgressView().controlSize(.mini).tint(tint)
                } else {
                    Image(systemName: glyph)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
                if let label = presentation.label {
                    Text(label).grainTextStyle(.caption).foregroundStyle(tint).lineLimit(1)
                }
            }
            .padding(.horizontal, presentation.isExpanded ? GrainSpacing.x3 : 0)
            .frame(minWidth: 34, minHeight: 34)
            .frame(height: 34)
            .background(Capsule().fill(background))
            .overlay(Capsule().strokeBorder(borderColor, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: presentation.isExpanded)
        .accessibilityLabel(accessibilityLabel)
    }

    private var glyph: String {
        presentation == .off ? "antenna.radiowaves.left.and.right.slash"
                             : "antenna.radiowaves.left.and.right"
    }

    /// Accent (forge blue) while scanning/connecting/connected; quiet ink when collapsed;
    /// faint when Bluetooth is off.
    private var tint: Color {
        switch presentation {
        case .scanning, .connecting, .connected: return GrainColor.forgeBlue
        case .collapsed: return GrainColor.ink
        case .off: return GrainColor.textFaint
        }
    }

    private var background: Color {
        switch presentation {
        case .scanning, .connecting: return GrainColor.forgeBlue.opacity(0.12)
        case .connected: return GrainColor.forgeBlue.opacity(0.18)
        case .collapsed, .off: return GrainColor.surfaceElevated
        }
    }

    private var borderColor: Color {
        switch presentation {
        case .collapsed, .off: return GrainColor.border
        case .scanning, .connecting, .connected: return .clear
        }
    }

    private var accessibilityLabel: String {
        switch presentation {
        case .collapsed: return "Scan for your Omi"
        case .scanning: return "Scanning for your Omi, tap to stop"
        case .connecting(let n): return "Connecting to \(n)"
        case .connected(let n): return "Connected to \(n)"
        case .off: return "Bluetooth off"
        }
    }
}

/// The phone-mic record control as a compact sphere (Feature 3). Idle: a subtle mic
/// glyph in a quiet circle. Recording: a RED record sphere with an animated pulse ring
/// radiating outward, so "you're recording" reads at a glance. Tapping toggles.
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

    /// Word-level styled text (Feature 2): finalized words at full opacity, the trailing
    /// volatile word(s) dimmed with the NEWEST word the faintest + italic, each snapping
    /// to full opacity as the recognizer finalizes it. Driven by the pure, tested
    /// `LiveTranscript.renderedSegments()`.
    private var styledText: Text {
        let segments = transcript.renderedSegments()
        var result = Text("")
        for (i, seg) in segments.enumerated() {
            let prefix = i == 0 ? "" : " "
            var run = Text(prefix + seg.text).foregroundColor(GrainColor.ink.opacity(seg.opacity))
            if seg.volatile { run = run.italic() }   // still-settling tail also italic
            result = result + run
        }
        return result
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
