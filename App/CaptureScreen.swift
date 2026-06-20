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

    var body: some View {
        VStack(spacing: 0) {
            header
            if case .connected = device.connectionState { meterBar }
            syncBar
            if manager.captures.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: GrainSpacing.x3) {
                        ForEach(manager.captures, id: \.captureId) { wal in
                            CaptureCard(
                                wal: wal,
                                meta: manager.conversationMeta(for: wal.captureId),
                                poller: manager.statusPoller(for: wal.captureId)
                            )
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
            HStack(spacing: GrainSpacing.x2) {
                Circle().fill(stageColor).frame(width: 9, height: 9)
                Text(stageLabel).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
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
    private var timeRange: String {
        guard let meta else {
            // No metadata sidecar (older capture) — fall back to the WAL start.
            return Self.timeFmt.string(from: wal.status.startedAt)
        }
        let start = Date(timeIntervalSince1970: TimeInterval(meta.startedAt))
        guard let endSecs = meta.endedAt else {
            return Self.timeFmt.string(from: start)
        }
        let end = Date(timeIntervalSince1970: TimeInterval(endSecs))
        let startStr = Self.timeFmt.string(from: start)
        let endStr = Self.timeFmt.string(from: end)
        if let dur = meta.durationSeconds {
            let mins = max(1, Int((Double(dur) / 60).rounded()))
            return "\(startStr)–\(endStr) · \(mins) min"
        }
        return "\(startStr)–\(endStr)"
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
}
