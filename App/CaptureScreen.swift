import SwiftUI
import Grain

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
            if case .connected = device.connectionState { meterBar }
            syncBar
            if manager.visibleCaptures.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: GrainSpacing.x3) {
                        ForEach(manager.visibleCaptures, id: \.captureId) { wal in
                            NavigationLink {
                                ConversationDetailView(
                                    target: target,
                                    captureId: wal.captureId,
                                    timeRange: manager.conversationMeta(for: wal.captureId)
                                        .map { CaptureCard.timeRangeString(meta: $0, fallback: wal.status.startedAt) }
                                        ?? CaptureCard.timeRangeString(meta: nil, fallback: wal.status.startedAt),
                                    place: manager.conversationMeta(for: wal.captureId)?.location?.label
                                )
                            } label: {
                                CaptureCard(
                                    wal: wal,
                                    meta: manager.conversationMeta(for: wal.captureId),
                                    poller: manager.statusPoller(for: wal.captureId)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(GrainSpacing.x4)
                }
            }
        }
        .grainBackground()
        .onAppear { manager.startSource(); manager.startMeter() }  // power on + drive the meter
        .onDisappear { manager.stopMeter() }
    }

    // MARK: live audio meter (req 8) — shows the Omi is actually hearing sound

    private var meterBar: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            LevelMeterView(levels: manager.levels, active: !manager.isPaused)
            Text(manager.isPaused ? "Paused — not listening" : "Listening — bars rise as it hears you")
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
            connectSection
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

    private var connectSection: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            HStack(spacing: GrainSpacing.x2) {
                Circle().fill(GrainColor.inkTertiary).frame(width: 9, height: 9)
                Text(connectLabel).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                Spacer()
                GrainButton("Scan", variant: .tonal, size: .sm) { device.startScan() }
            }
            ForEach(device.discovered) { dev in
                Button { device.connect(dev) } label: {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(GrainColor.forgeBlue)
                        Text(dev.name).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                        Spacer()
                        Text("\(dev.rssi) dBm").grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                    }
                    .padding(.vertical, GrainSpacing.x2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.vertical, GrainSpacing.x3)
        .overlay(alignment: .bottom) { Rectangle().fill(GrainColor.borderHairline).frame(height: 1) }
    }

    private var connectLabel: String {
        switch device.connectionState {
        case .poweredOff: return "Bluetooth off — enable it to connect your Omi"
        case .idle: return "Connect your Omi"
        case .scanning: return "Scanning for your Omi…"
        case .connecting(let n): return "Connecting to \(n)…"
        case .disconnected: return "Omi disconnected — reconnecting…"
        case .connected: return ""
        }
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
    @ObservedObject var poller: CaptureStatusPoller

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            // Kiln-generated title as the card's headline once the door has it; the
            // stage chip drops to a secondary line. Falls back to stage-only until then.
            if let title = poller.title, !title.isEmpty {
                Text(title).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                    .lineLimit(2)
            }
            HStack(spacing: GrainSpacing.x2) {
                Circle().fill(stageColor).frame(width: 9, height: 9)
                Text(stageLabel).grainTextStyle(poller.title == nil ? .body : .caption)
                    .foregroundStyle(poller.title == nil ? GrainColor.ink : GrainColor.textMuted)
                Spacer()
                Text(timeRange).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }
            // Place (when a fix was captured) — time-only otherwise (honest degradation).
            if let place {
                Text(place).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            }
            Text(detail).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).fill(GrainColor.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).strokeBorder(GrainColor.border, lineWidth: 1))
        // Drive the door→Lore stage chip while the card is on screen; stop when it
        // scrolls off (the poller itself also stops at a terminal stage, F11).
        .onAppear { poller.start() }
        .onDisappear { poller.stop() }
    }

    /// The chip prefers the door→Lore stage once the audio is on the desktop; until
    /// then it shows the local WAL sync stage (recording / saving on phone).
    private var effectiveStage: CaptureLifecycleStage {
        switch wal.status.stage {
        case .recording: return .recording
        case .savedOnPhone: return wal.status.streaming ? .recording : .stored
        case .savedToComputer:
            // Saved to computer → the door owns the rest; show the polled stage,
            // but never regress below "stored" (the door at least has the audio).
            return poller.stage == .recording ? .stored : poller.stage
        }
    }

    private var stageColor: Color {
        switch effectiveStage {
        case .recording: return GrainColor.forgeBlue
        case .stored, .transcribing, .transcribed: return GrainColor.amber
        case .inLore, .organized: return GrainColor.sage
        case .failed: return GrainColor.amber
        }
    }
    private var stageLabel: String { effectiveStage.chipLabel }

    /// "10:41–10:47 AM · 6 min" when closed; start time alone while open.
    private var timeRange: String { Self.timeRangeString(meta: meta, fallback: wal.status.startedAt) }

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

    @State private var content: CaptureContent?
    @State private var loadError: String?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GrainSpacing.x3) {
                Text(timeRange).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                if let place {
                    Text(place).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                }
                Divider().background(GrainColor.borderHairline)

                if loading {
                    Text("Loading transcript…")
                        .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
                } else if let loadError {
                    Text("Couldn't load transcript: \(loadError)")
                        .grainTextStyle(.body).foregroundStyle(GrainColor.amber)
                } else if let content, content.found, !content.transcript.isEmpty {
                    // Kiln-generated title + summary (Phase B) when ready; a subtle
                    // "Summarizing…" hint while the door generates them in the
                    // background (the .task re-fetches once so they fill in).
                    if let summary = content.summary, !summary.isEmpty {
                        Text("Summary").grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                        Text(summary)
                            .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                            .textSelection(.enabled)
                        Divider().background(GrainColor.borderHairline)
                    } else if content.summarizing {
                        Text("Summarizing…").grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                    }
                    Text("Transcript").grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                    Text(content.transcript)
                        .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                        .textSelection(.enabled)
                } else {
                    Text("Transcript still processing…")
                        .grainTextStyle(.title).foregroundStyle(GrainColor.ink)
                    Text("Your conversation is saved. The transcript shows up here once it's been processed on your computer.")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                }
            }
            .padding(GrainSpacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .grainBackground()
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// Prefer the Kiln-generated title; fall back to the first ~6 words of the
    /// transcript while it's still summarizing, then "Conversation".
    private var navTitle: String {
        if let t = content?.title, !t.isEmpty { return t }
        guard let t = content?.transcript, !t.isEmpty else { return "Conversation" }
        let words = t.split(whereSeparator: { $0 == " " || $0 == "\n" }).prefix(6).joined(separator: " ")
        return words.isEmpty ? "Conversation" : words
    }

    private func load() async {
        loading = true
        loadError = nil
        do {
            content = try await DoorClient(target: target).captureContent(captureId: captureId)
        } catch {
            loadError = (error as NSError).localizedDescription
        }
        loading = false
        // The door generates the title/summary in the background on first fetch; if
        // it's still summarizing, re-fetch once after a short delay so they appear
        // without the user having to leave + reopen the conversation.
        if content?.summarizing == true, (content?.title ?? "").isEmpty {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let refreshed = try? await DoorClient(target: target).captureContent(captureId: captureId) {
                content = refreshed
            }
        }
    }
}
