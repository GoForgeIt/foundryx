import SwiftUI
import Grain

/// Dedicated device / capture-source page. Two halves:
///   1. CAPTURE SOURCES (track 20260628T1702) — an extensible list of sources, each with
///      an independent on/off Toggle (no more mutually-exclusive segmented pick), plus a
///      "+ Add source" affordance that discovers Bluetooth mics and offers an Apple Watch
///      scaffold. The registry owns the model; this screen just renders it.
///   2. The remembered Omi device (name / id / last-connected), live connection state,
///      Reconnect / Scan / Forget, and the conversation-segmentation (silence-gap) setting.
struct DeviceScreen: View {
    @ObservedObject var device: DeviceManager
    @ObservedObject var manager: CaptureManager
    @ObservedObject var sources: CaptureSourceRegistry

    @State private var showingAddSource = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                captureSourcesCard
                savedCard
                actions
                if !device.discovered.isEmpty { discoveredList }
                settingsCard
            }
            .padding(GrainSpacing.x4)
        }
        .grainBackground()
        .onAppear { device.start() }   // ensure the central is powered + reconnecting
        .onChange(of: device.connectionState) { _ in syncOmiConnection() }
        .sheet(isPresented: $showingAddSource) {
            AddSourceSheet(sources: sources)
        }
    }

    /// Keep the registry's Omi row liveness in step with the BLE connection state, so
    /// the active-source policy (Omi only active when connected) is correct.
    private func syncOmiConnection() {
        if case .connected = device.connectionState { sources.setOmiConnected(true) }
        else { sources.setOmiConnected(false) }
    }

    // MARK: capture sources (per-source toggles + add-source)

    private var captureSourcesCard: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            Text("Capture sources").grainTextStyle(.body).foregroundStyle(GrainColor.ink)
            Text("Turn each source on or off independently. Audio from the active source flows through the same private pipeline. One source records at a time — the connected one with the highest priority.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            VStack(spacing: 0) {
                ForEach(sources.sources) { src in
                    sourceRow(src)
                    if src.id != sources.sources.last?.id {
                        Divider().overlay(GrainColor.border)
                    }
                }
            }
            .padding(.top, GrainSpacing.x1)
            Button { sources.discoverBluetoothMics(); showingAddSource = true } label: {
                HStack(spacing: GrainSpacing.x1) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(GrainColor.forgeBlue)
                    Text("Add source").grainTextStyle(.body).foregroundStyle(GrainColor.forgeBlue)
                }
                .padding(.top, GrainSpacing.x2)
            }
            .buttonStyle(.plain)
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).fill(GrainColor.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).strokeBorder(GrainColor.border, lineWidth: 1))
    }

    private func sourceRow(_ src: CaptureSourceDescriptor) -> some View {
        HStack(spacing: GrainSpacing.x2) {
            Image(systemName: src.category.symbolName)
                .foregroundStyle(src.id == sources.activeSourceId ? GrainColor.sage : GrainColor.inkTertiary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: GrainSpacing.x1) {
                    Text(src.displayName).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                    if src.id == sources.activeSourceId {
                        Text("ACTIVE").grainTextStyle(.caption).foregroundStyle(GrainColor.sage)
                    }
                }
                Text(connectionLabel(src)).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { src.enabled },
                set: { sources.setEnabled(src.id, $0) }))
                .labelsHidden()
                .disabled(!src.canToggle)
                .tint(GrainColor.forgeBlue)
        }
        .padding(.vertical, GrainSpacing.x2)
    }

    private func connectionLabel(_ src: CaptureSourceDescriptor) -> String {
        if let detail = src.detail, !detail.isEmpty { return "\(src.connection.label) · \(detail)" }
        return src.connection.label
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

    // MARK: conversation segmentation setting

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

/// "+ Add source" sheet: lists discovered Bluetooth mics (real, via AVAudioSession) to
/// add, plus an Apple Watch scaffold entry. Adding registers the source in the registry
/// (with its own toggle, enabled by default) and dismisses.
private struct AddSourceSheet: View {
    @ObservedObject var sources: CaptureSourceRegistry
    @Environment(\.dismiss) private var dismiss

    private var watchAlreadyAdded: Bool {
        sources.sources.contains { $0.category == .appleWatch }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                    bluetoothSection
                    watchSection
                }
                .padding(GrainSpacing.x4)
            }
            .grainBackground()
            .navigationTitle("Add source")
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private var bluetoothSection: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            HStack {
                Text("Bluetooth microphones").grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                Spacer()
                Button { sources.discoverBluetoothMics() } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(GrainColor.forgeBlue)
                }
                .buttonStyle(.plain)
            }
            if sources.discoveredBluetoothInputs.isEmpty {
                Text("No new Bluetooth microphones found. Connect a Bluetooth headset or mic in iOS Settings, then refresh.")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            } else {
                ForEach(sources.discoveredBluetoothInputs, id: \.uid) { input in
                    Button { sources.addBluetoothMic(input); dismiss() } label: {
                        HStack(spacing: GrainSpacing.x2) {
                            Image(systemName: "headphones").foregroundStyle(GrainColor.forgeBlue)
                            Text(input.name.isEmpty ? "Bluetooth microphone" : input.name)
                                .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(GrainColor.forgeBlue)
                        }
                        .padding(.vertical, GrainSpacing.x2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).fill(GrainColor.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).strokeBorder(GrainColor.border, lineWidth: 1))
    }

    private var watchSection: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            Text("Apple Watch").grainTextStyle(.body).foregroundStyle(GrainColor.ink)
            Text("Record with your Apple Watch's microphone. Coming soon — adds the source to your list so it's ready when the watch app ships.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            Button { sources.addAppleWatchScaffold(); dismiss() } label: {
                HStack(spacing: GrainSpacing.x2) {
                    Image(systemName: "applewatch").foregroundStyle(watchAlreadyAdded ? GrainColor.inkTertiary : GrainColor.forgeBlue)
                    Text(watchAlreadyAdded ? "Apple Watch added" : "Add Apple Watch")
                        .grainTextStyle(.body).foregroundStyle(watchAlreadyAdded ? GrainColor.textMuted : GrainColor.forgeBlue)
                    Spacer()
                    if !watchAlreadyAdded { Image(systemName: "plus.circle").foregroundStyle(GrainColor.forgeBlue) }
                }
                .padding(.vertical, GrainSpacing.x2)
            }
            .buttonStyle(.plain)
            .disabled(watchAlreadyAdded)
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).fill(GrainColor.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).strokeBorder(GrainColor.border, lineWidth: 1))
    }
}
