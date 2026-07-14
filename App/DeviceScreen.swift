import SwiftUI
import Grain

/// Device and connection controls presented in the flat, separator-led DEVICE layout.
/// The existing models continue to own connection, discovery, source, and capture state.
struct DeviceScreen: View {
    @ObservedObject var device: DeviceManager
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var manager: CaptureManager
    @ObservedObject var sources: CaptureSourceRegistry

    @State private var showingAddSource = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                omiHero
                deviceMetrics
                captureSourcesSection
                computerMemorySection
                bluetoothBatterySection
                conversationSplittingSection
            }
            .padding(.horizontal, GrainSpacing.x4)
            .padding(.bottom, GrainSpacing.x8)
        }
        .grainBackground()
        .navigationBarTitleDisplayMode(.inline)
        // Power the central and reconnect only while Omi remains an enabled source.
        .onAppear {
            if sources.isEnabled(CaptureSourceDescriptor.omiId) {
                device.start()
            }
        }
        .onChange(of: device.connectionState) { _ in
            syncOmiConnection()
        }
        .sheet(isPresented: $showingAddSource) {
            AddSourceSheet(sources: sources)
        }
    }

    private func syncOmiConnection() {
        if case .connected = device.connectionState {
            sources.setOmiConnected(true)
        } else {
            sources.setOmiConnected(false)
        }
    }

    // MARK: - Recording device

    private var omiHero: some View {
        HStack(alignment: .center, spacing: GrainSpacing.x3) {
            wearablePortrait

            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                Text("RECORDING DEVICE")
                    .grainTextStyle(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(GrainColor.forgeBlue)

                Text(omiDisplayName)
                    .grainTextStyle(.title)
                    .foregroundStyle(GrainColor.ink)

                HStack(spacing: GrainSpacing.x1) {
                    GrainStatusDot(stateStatus, size: .sm)
                    Text(compactStateLabel)
                        .grainTextStyle(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(stateColor)
                }
                .accessibilityElement(children: .combine)

                omiActions
            }

            Spacer(minLength: GrainSpacing.x2)
        }
        .padding(.top, GrainSpacing.x2)
        .padding(.bottom, GrainSpacing.x3)
        .overlay(alignment: .bottom) {
            hairline
        }
    }

    private var wearablePortrait: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                .fill(GrainColor.forgeBlueBg)
                .overlay {
                    RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                        .strokeBorder(GrainColor.forgeBlueBorder, lineWidth: 1)
                }
                .frame(width: 38, height: 76)

            Image(grain: .mic)
                .grainTextStyle(.title)
                .foregroundStyle(GrainColor.forgeBlue)
        }
        .frame(width: 64, height: 86)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var omiActions: some View {
        if device.saved != nil {
            HStack(spacing: GrainSpacing.x3) {
                GrainButton(isOmiConnected ? "Disconnect Omi" : "Connect Omi",
                            variant: .text,
                            size: .sm) {
                    toggleOmiConnection()
                }

                Button {
                    device.forget()
                } label: {
                    Text("Forget")
                        .grainTextStyle(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(GrainColor.dangerRed)
                        .frame(height: 28)
                }
                .buttonStyle(.plain)
            }
        } else {
            Text("Pair your Omi from Capture")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
        }
    }

    private func toggleOmiConnection() {
        if isOmiConnected {
            sources.setEnabled(CaptureSourceDescriptor.omiId, false)
        } else if sources.isEnabled(CaptureSourceDescriptor.omiId) {
            device.reconnect()
        } else {
            sources.setEnabled(CaptureSourceDescriptor.omiId, true)
        }
    }

    private var deviceMetrics: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                DeviceMetric(value: batteryValue, label: "Battery")
                metricDivider
                DeviceMetric(value: signalValue, label: "Signal")
                metricDivider
                DeviceMetric(value: pairingValue, label: "Device ID")
            }
            .padding(.vertical, GrainSpacing.x2)

            if let saved = device.saved {
                Text(lastConnected(saved.lastConnected))
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .padding(.bottom, GrainSpacing.x2)
            }
        }
        .overlay(alignment: .bottom) {
            hairline
        }
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(GrainColor.borderFaint)
            .frame(width: 1, height: 40)
    }

    // MARK: - Capture sources

    private var captureSourcesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: GrainSpacing.x2) {
                DeviceSectionLabel("Capture sources")
                Spacer()
                GrainButton("Add source", variant: .text, size: .sm) {
                    sources.discoverBluetoothMics()
                    showingAddSource = true
                }
            }
            .padding(.top, GrainSpacing.x2)

            ForEach(sources.sources) { source in
                sourceRow(source)
            }
        }
    }

    private func sourceRow(_ source: CaptureSourceDescriptor) -> some View {
        HStack(spacing: GrainSpacing.x3) {
            DeviceIconTile(icon: sourceIcon(source.category),
                           foreground: source.id == sources.activeSourceId
                               ? GrainColor.sage
                               : GrainColor.forgeBlue)

            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                HStack(spacing: GrainSpacing.x1) {
                    Text(sourceTitle(source))
                        .grainTextStyle(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(GrainColor.ink)

                    if source.id == sources.activeSourceId {
                        Text("ACTIVE")
                            .grainTextStyle(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(GrainColor.sage)
                    }
                }

                Text(sourceDescription(source))
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: GrainSpacing.x2)

            Toggle("", isOn: Binding(
                get: { source.enabled },
                set: { sources.setEnabled(source.id, $0) }
            ))
            .labelsHidden()
            .disabled(!source.canToggle)
            .tint(GrainColor.forgeBlue)
        }
        .padding(.vertical, GrainSpacing.x2)
        .frame(minHeight: 54)
        .overlay(alignment: .bottom) {
            hairline
        }
    }

    private func sourceTitle(_ source: CaptureSourceDescriptor) -> String {
        source.category == .omi ? "Omi microphone" : source.displayName
    }

    private func sourceDescription(_ source: CaptureSourceDescriptor) -> String {
        switch source.category {
        case .omi:
            return isOmiConnected
                ? "Use the wearable for capture"
                : "Reconnect Omi to use this source"
        case .phoneMic:
            return "Use this iPhone as another capture source"
        case .appleWatch, .bluetoothMic:
            return connectionLabel(source)
        }
    }

    private func sourceIcon(_ category: CaptureSourceCategory) -> GrainIcon {
        switch category {
        case .omi, .bluetoothMic:
            return .mic
        case .phoneMic, .appleWatch:
            return .device
        }
    }

    private func connectionLabel(_ source: CaptureSourceDescriptor) -> String {
        if let detail = source.detail, !detail.isEmpty {
            return "\(source.connection.label) · \(detail)"
        }
        return source.connection.label
    }

    // MARK: - Computer memory

    private var computerMemorySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeviceSectionLabel("Computer memory")
                .padding(.top, GrainSpacing.x3)
                .padding(.bottom, GrainSpacing.x1)

            HStack(alignment: .top, spacing: GrainSpacing.x3) {
                DeviceIconTile(icon: .device)

                VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                    Text("Connect your computer")
                        .grainTextStyle(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(GrainColor.ink)
                    Text("Pair in Settings for full-history search and local Brain runs")
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: GrainSpacing.x1)

                HStack(spacing: GrainSpacing.x1) {
                    GrainStatusDot(.thinking, size: .sm)
                    Text("Not connected")
                        .grainTextStyle(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(GrainColor.amber)
                }
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityElement(children: .combine)
            }
            .padding(.vertical, GrainSpacing.x2)
            .frame(minHeight: 54)
            .overlay(alignment: .top) {
                hairline
            }
            .overlay(alignment: .bottom) {
                hairline
            }

            HStack(alignment: .top, spacing: GrainSpacing.x2) {
                Image(grain: .key)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                Text("Pairing is end-to-end encrypted to your own machine. Computer pairing is managed in Settings.")
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, GrainSpacing.x2)
        }
    }

    // MARK: - Generic Bluetooth battery monitor

    private var bluetoothBatterySection: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            HStack(spacing: GrainSpacing.x2) {
                DeviceSectionLabel("Bluetooth battery")
                Spacer()
                if battery.isScanning {
                    ProgressView()
                        .tint(GrainColor.forgeBlue)
                }
            }

            if let name = battery.monitoredName {
                HStack(spacing: GrainSpacing.x3) {
                    DeviceIconTile(icon: .device)
                    Text(name)
                        .grainTextStyle(.body)
                        .foregroundStyle(GrainColor.ink)
                    Spacer()
                    if let level = battery.level {
                        BatteryBadge(level: level, low: battery.isLow)
                    }
                    GrainButton("Stop", variant: .text, size: .sm) {
                        battery.stopMonitoring()
                    }
                }
                .padding(.vertical, GrainSpacing.x2)
                .overlay(alignment: .bottom) {
                    hairline
                }
            } else {
                GrainButton("Find Bluetooth devices", variant: .tonal, size: .sm) {
                    battery.startScan()
                }

                ForEach(battery.discovered) { discoveredDevice in
                    Button {
                        battery.monitor(discoveredDevice)
                    } label: {
                        HStack(spacing: GrainSpacing.x3) {
                            DeviceIconTile(icon: .device)
                            Text(discoveredDevice.name)
                                .grainTextStyle(.body)
                                .foregroundStyle(GrainColor.ink)
                            Spacer()
                            Text(signalHint(discoveredDevice.rssi))
                                .grainTextStyle(.caption)
                                .foregroundStyle(GrainColor.textFaint)
                        }
                        .padding(.vertical, GrainSpacing.x2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        hairline
                    }
                }
            }

            Text("Shows battery for Bluetooth devices that publish it over Bluetooth LE. AirPods and most headphones keep their battery private to iOS and will not appear here.")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, GrainSpacing.x4)
    }

    private func signalHint(_ rssi: Int) -> String {
        if rssi >= -55 { return "Strong" }
        if rssi >= -75 { return "Nearby" }
        return "Weak"
    }

    // MARK: - Conversation splitting

    private var conversationSplittingSection: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            DeviceSectionLabel("Conversation splitting")
            Text("Capture starts a new conversation after a silence gap. Choose how long a pause ends the current conversation.")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Silence gap", selection: Binding(
                get: { manager.silenceGapSeconds },
                set: { manager.setSilenceGap($0) }
            )) {
                Text("30s").tag(TimeInterval(30))
                Text("1 min").tag(TimeInterval(60))
                Text("2 min").tag(TimeInterval(120))
                Text("5 min").tag(TimeInterval(300))
            }
            .pickerStyle(.segmented)
            .tint(GrainColor.forgeBlue)
        }
        .padding(.top, GrainSpacing.x4)
    }

    // MARK: - Derived presentation

    private var isOmiConnected: Bool {
        if case .connected = device.connectionState { return true }
        return false
    }

    private var omiDisplayName: String {
        switch device.connectionState {
        case .connected(let name), .connecting(let name):
            return name
        case .poweredOff, .idle, .scanning, .disconnected:
            return device.saved?.name ?? "Omi"
        }
    }

    private var compactStateLabel: String {
        switch device.connectionState {
        case .connected:
            return manager.isPaused ? "Connected, paused" : "Connected"
        case .connecting:
            return "Connecting"
        case .scanning:
            return "Scanning"
        case .disconnected:
            return "Not connected"
        case .idle:
            return device.saved == nil ? "Not paired" : "Ready to connect"
        case .poweredOff:
            return "Bluetooth is off"
        }
    }

    private var stateStatus: GrainStatus {
        switch device.connectionState {
        case .connected:
            return manager.isPaused ? .thinking : .running
        case .connecting, .scanning, .disconnected:
            return .thinking
        case .idle, .poweredOff:
            return .stopped
        }
    }

    private var stateColor: Color {
        switch device.connectionState {
        case .connected:
            return manager.isPaused ? GrainColor.amber : GrainColor.sage
        case .connecting, .scanning, .disconnected:
            return GrainColor.amber
        case .idle, .poweredOff:
            return GrainColor.textFaint
        }
    }

    private var batteryValue: String {
        device.batteryLevel.map { "\($0)%" } ?? "N/A"
    }

    private var signalValue: String {
        if let saved = device.saved,
           let discovered = device.discovered.first(where: { $0.id == saved.id }) {
            return signalHint(discovered.rssi)
        }
        switch device.connectionState {
        case .connected:
            return "Ready"
        case .connecting, .scanning:
            return "Searching"
        case .disconnected, .idle, .poweredOff:
            return "N/A"
        }
    }

    private var pairingValue: String {
        guard let saved = device.saved else { return "N/A" }
        return String(saved.id.uuidString.prefix(8))
    }

    private func lastConnected(_ date: Date?) -> String {
        guard let date else { return "Last connected: never" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Last connected: \(formatter.string(from: date))"
    }

    private var hairline: some View {
        Rectangle()
            .fill(GrainColor.borderFaint)
            .frame(height: 1)
    }
}

// MARK: - Add source sheet

private struct AddSourceSheet: View {
    @ObservedObject var sources: CaptureSourceRegistry
    @Environment(\.dismiss) private var dismiss

    private var watchAlreadyAdded: Bool {
        sources.sources.contains { $0.category == .appleWatch }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GrainSpacing.x6) {
                    bluetoothSection
                    watchSection
                }
                .padding(.horizontal, GrainSpacing.x4)
                .padding(.vertical, GrainSpacing.x3)
            }
            .grainBackground()
            .navigationTitle("Add source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") {
                    dismiss()
                }
            }
            .tint(GrainColor.forgeBlue)
        }
    }

    private var bluetoothSection: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            HStack(spacing: GrainSpacing.x2) {
                DeviceSectionLabel("Bluetooth microphones")
                Spacer()
                GrainButton("Refresh", variant: .text, size: .sm) {
                    sources.discoverBluetoothMics()
                }
            }

            if sources.discoveredBluetoothInputs.isEmpty {
                Text("No new Bluetooth microphones found. Connect a Bluetooth headset or microphone in iOS Settings, then refresh.")
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(sources.discoveredBluetoothInputs, id: \.uid) { input in
                    Button {
                        sources.addBluetoothMic(input)
                        dismiss()
                    } label: {
                        HStack(spacing: GrainSpacing.x3) {
                            DeviceIconTile(icon: .mic)
                            Text(input.name.isEmpty ? "Bluetooth microphone" : input.name)
                                .grainTextStyle(.body)
                                .foregroundStyle(GrainColor.ink)
                            Spacer()
                            Image(grain: .check)
                                .foregroundStyle(GrainColor.forgeBlue)
                        }
                        .padding(.vertical, GrainSpacing.x2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        sheetHairline
                    }
                }
            }
        }
    }

    private var watchSection: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            DeviceSectionLabel("Apple Watch")
            Text("Record with your Apple Watch microphone. Coming soon. Add the source now so it is ready when the watch app ships.")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                sources.addAppleWatchScaffold()
                dismiss()
            } label: {
                HStack(spacing: GrainSpacing.x3) {
                    DeviceIconTile(icon: .device,
                                   foreground: watchAlreadyAdded
                                       ? GrainColor.textFaint
                                       : GrainColor.forgeBlue)
                    Text(watchAlreadyAdded ? "Apple Watch added" : "Add Apple Watch")
                        .grainTextStyle(.body)
                        .foregroundStyle(watchAlreadyAdded
                            ? GrainColor.textMuted
                            : GrainColor.forgeBlue)
                    Spacer()
                    if !watchAlreadyAdded {
                        Image(grain: .check)
                            .foregroundStyle(GrainColor.forgeBlue)
                    }
                }
                .padding(.vertical, GrainSpacing.x2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(watchAlreadyAdded)
            .overlay(alignment: .bottom) {
                sheetHairline
            }
        }
    }

    private var sheetHairline: some View {
        Rectangle()
            .fill(GrainColor.borderFaint)
            .frame(height: 1)
    }
}

// MARK: - Shared device presentation

private struct DeviceSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .grainTextStyle(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(GrainColor.textFaint)
    }
}

private struct DeviceIconTile: View {
    let icon: GrainIcon
    var foreground: Color = GrainColor.forgeBlue

    var body: some View {
        Image(grain: icon)
            .grainTextStyle(.body)
            .foregroundStyle(foreground)
            .frame(width: GrainSpacing.x8, height: GrainSpacing.x8)
            .background {
                RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous)
                    .fill(GrainColor.forgeBlueBg)
            }
            .overlay {
                RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous)
                    .strokeBorder(GrainColor.forgeBlueBorder, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

private struct DeviceMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            Text(value)
                .grainTextStyle(.body)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(GrainColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)
        }
        .padding(.horizontal, GrainSpacing.x2)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Compact battery presentation for devices that publish a real battery level.
struct BatteryBadge: View {
    let level: Int
    let low: Bool

    var body: some View {
        HStack(spacing: GrainSpacing.x1) {
            GrainStatusDot(low ? .thinking : .running, size: .sm)
            Text("\(level)%")
                .grainTextStyle(.caption)
                .monospacedDigit()
        }
        .foregroundStyle(low ? GrainColor.amber : GrainColor.textMuted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Device battery \(level) percent\(low ? ", low" : "")")
    }
}
