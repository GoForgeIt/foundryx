import SwiftUI
import Grain

/// Dedicated Omi device page (req 7): the remembered device (name / short id /
/// last-connected), live connection state, a Reconnect button for when
/// auto-reconnect hasn't re-bound, scan + pick a different device, Forget, and the
/// conversation-segmentation setting (the silence gap that auto-splits captures).
struct DeviceScreen: View {
    @ObservedObject var device: DeviceManager
    @ObservedObject var manager: CaptureManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                savedCard
                actions
                if !device.discovered.isEmpty { discoveredList }
                settingsCard
            }
            .padding(GrainSpacing.x4)
        }
        .grainBackground()
        .onAppear { device.start() }   // ensure the central is powered + reconnecting
    }

    // MARK: remembered device

    private var savedCard: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            HStack(spacing: GrainSpacing.x2) {
                Circle().fill(stateColor).frame(width: 10, height: 10)
                Text(device.saved?.name ?? "No Omi paired yet")
                    .grainTextStyle(.title).foregroundStyle(GrainColor.ink)
                Spacer()
            }
            Text(stateLabel).grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
            if let s = device.saved {
                Text("ID \(String(s.id.uuidString.prefix(8)))…")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                Text(lastConnected(s.lastConnected))
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            } else {
                Text("Scan below to find and connect your Omi. Once paired, it reconnects automatically.")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).fill(GrainColor.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).strokeBorder(GrainColor.border, lineWidth: 1))
    }

    private var actions: some View {
        HStack(spacing: GrainSpacing.x2) {
            GrainButton("Reconnect", variant: .filled, size: .sm) { device.reconnect() }
            GrainButton("Scan", variant: .tonal, size: .sm) { device.startScan() }
            Spacer()
            if device.saved != nil {
                GrainButton("Forget", variant: .text, size: .sm) { device.forget() }
            }
        }
    }

    private var discoveredList: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            Text("Nearby").grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
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
    }

    // MARK: conversation segmentation setting (req 9)

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            Text("Conversation splitting").grainTextStyle(.body).foregroundStyle(GrainColor.ink)
            Text("Capture is split into separate conversations after a silence gap — no need to press stop. Choose how long a pause ends a conversation.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            Picker("Silence gap", selection: Binding(
                get: { manager.silenceGapSeconds },
                set: { manager.setSilenceGap($0) })) {
                Text("30s").tag(TimeInterval(30))
                Text("1 min").tag(TimeInterval(60))
                Text("2 min").tag(TimeInterval(120))
                Text("5 min").tag(TimeInterval(300))
            }
            .pickerStyle(.segmented)
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).fill(GrainColor.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).strokeBorder(GrainColor.border, lineWidth: 1))
    }

    // MARK: derived labels

    private var stateColor: Color {
        switch device.connectionState {
        case .connected: return manager.isPaused ? GrainColor.amber : GrainColor.sage
        case .connecting, .scanning, .disconnected: return GrainColor.amber
        case .idle, .poweredOff: return GrainColor.inkTertiary
        }
    }

    private var stateLabel: String {
        switch device.connectionState {
        case .connected(let n): return manager.isPaused ? "Connected to \(n) · paused" : "Connected to \(n) · capturing"
        case .connecting(let n): return "Connecting to \(n)…"
        case .scanning: return "Scanning…"
        case .disconnected: return "Disconnected — reconnecting when in range"
        case .idle: return "Ready — not connected"
        case .poweredOff: return "Bluetooth is off"
        }
    }

    private func lastConnected(_ date: Date?) -> String {
        guard let date else { return "Last connected: never" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return "Last connected: \(f.string(from: date))"
    }
}
