import SwiftUI
import Grain

/// The capture surface. When no Omi is connected it's a connect/pairing flow
/// (scan → pick a device → connect, persisted + auto-reconnecting). Once
/// connected, capture is AMBIENT — it runs automatically; the header shows the
/// device + a Pause/Resume control. Below: the Omi-style timeline (each capture
/// Recording → Saved on phone → Saved to computer) + a global "your data is safe"
/// sync indicator so nothing ever feels lost into the phone.
struct CaptureScreen: View {
    @StateObject private var device: DeviceManager
    @StateObject private var manager: CaptureManager

    init(config: DoorConfig) {
        let log = DoorLog()
        let dm = DeviceManager(log: log)
        let target = DoorTarget(baseURL: config.doorURL, bearer: config.bearer)
        _device = StateObject(wrappedValue: dm)
        _manager = StateObject(wrappedValue: CaptureManager(target: target, log: log, source: dm))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            syncBar
            if manager.captures.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: GrainSpacing.x3) {
                        ForEach(manager.captures, id: \.captureId) { wal in
                            CaptureCard(wal: wal)
                        }
                    }
                    .padding(GrainSpacing.x4)
                }
            }
        }
        .grainBackground()
        .onAppear { manager.startSource() }   // power on → auto-reconnect saved Omi / scan
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

/// One capture's card — observes its WAL so the chip advances live.
private struct CaptureCard: View {
    @ObservedObject var wal: CaptureWAL

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            HStack(spacing: GrainSpacing.x2) {
                Circle().fill(chipColor).frame(width: 9, height: 9)
                Text(chipLabel).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                Spacer()
                Text(started).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }
            Text(detail).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).fill(GrainColor.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).strokeBorder(GrainColor.border, lineWidth: 1))
    }

    private var chipColor: Color {
        switch wal.status.stage {
        case .recording: return GrainColor.forgeBlue
        case .savedOnPhone: return GrainColor.amber
        case .savedToComputer: return GrainColor.sage
        }
    }
    private var chipLabel: String {
        switch wal.status.stage {
        case .recording: return wal.status.streaming ? "🔴 Recording" : "💾 Saved on phone"
        case .savedOnPhone: return "💾 Saved on phone"
        case .savedToComputer: return "✅ Saved to computer"
        }
    }
    private var detail: String {
        let s = wal.status
        let kb = String(format: "%.1f", Double(s.bytes) / 1024)
        let synced = "\(s.syncedSegments)/\(s.totalSegments) segments synced · \(kb) KB"
        if let err = s.lastSyncError, s.pendingSegments > 0 { return "\(synced) · ⏳ \(err)" }
        return synced
    }
    private var started: String {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"
        return f.string(from: wal.status.startedAt)
    }
}
