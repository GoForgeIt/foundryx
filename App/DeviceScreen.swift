import SwiftUI
import Grain

/// The Device tab, realigned to the prototype's `renderDevice` frame (track
/// 20260714T1800 §8): the recording-device hero, a Battery / Signal / Firmware
/// metrics strip, exactly two capture-source rows (Omi + phone mic), and a
/// Computer memory section that pairs the desktop app right here.
///
/// This view is a thin wrapper: every string and state it shows comes from the
/// pure presentation builders in FoundryXKit (DevicePagePresentation.swift), so
/// the SPM tests drive the SAME values this view renders. The existing models
/// keep owning connection, discovery, source, and capture state.
struct DeviceScreen: View {
    @ObservedObject var device: DeviceManager
    @ObservedObject var manager: CaptureManager
    @ObservedObject var sources: CaptureSourceRegistry
    /// Computer pairing = the existing sign-in → resolve-designated-host flow
    /// (SignInView / RemoteSession) — reused here, not rebuilt.
    @ObservedObject var remote: RemoteSession

    @State private var showingComputerPairing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                omiHero
                if device.saved == nil {
                    firstTimePairingSection
                }
                deviceMetrics
                captureSourcesSection
                computerMemorySection
            }
            .padding(.horizontal, GrainSpacing.x4)
            .padding(.bottom, GrainSpacing.x8)
        }
        .grainBackground()
        .navigationBarTitleDisplayMode(.inline)
        // Power the central + auto-reconnect only for a REMEMBERED, enabled Omi. With no
        // saved device, opening this page arms NOTHING (no scan, no CB restoration) —
        // first-time pairing is the explicit "Pair your Omi" button (device.startScan()).
        // start() is itself dormant with no saved device, but gating here avoids even
        // creating an idle central just to view the page.
        .onAppear {
            if device.saved != nil, sources.isEnabled(CaptureSourceDescriptor.omiId) {
                device.start()
            }
        }
        // A user-initiated pairing scan that found nothing must not keep scanning after
        // the page is dismissed (a lingering scan re-arms the radio + CB restoration).
        .onDisappear {
            device.stopScanIfScanning()
        }
        .onChange(of: device.connectionState) { _ in
            syncOmiConnection()
        }
        .sheet(isPresented: $showingComputerPairing) {
            SignInView(remote: remote) { showingComputerPairing = false }
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
            // First-time pairing stays reachable from the hero: a tap starts the
            // scan and the discovered Omis list right below (firstTimePairingSection).
            GrainButton(isScanning ? "Scanning…" : "Pair your Omi",
                        variant: .text,
                        size: .sm) {
                device.startScan()
            }
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

    /// Shown ONLY while no Omi is saved: the discovered devices a tap pairs.
    private var firstTimePairingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(device.discovered) { found in
                Button {
                    device.connect(found)
                } label: {
                    HStack(spacing: GrainSpacing.x3) {
                        DeviceIconTile(icon: .mic)
                        Text(found.name)
                            .grainTextStyle(.body)
                            .foregroundStyle(GrainColor.ink)
                        Spacer()
                        Text("Tap to pair")
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.forgeBlue)
                    }
                    .padding(.vertical, GrainSpacing.x2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) {
                    hairline
                }
            }

            if isScanning && device.discovered.isEmpty {
                HStack(spacing: GrainSpacing.x2) {
                    ProgressView()
                        .tint(GrainColor.forgeBlue)
                    Text("Looking for your Omi…")
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                }
                .padding(.vertical, GrainSpacing.x2)
            }
        }
    }

    private var isScanning: Bool {
        if case .scanning = device.connectionState { return true }
        return false
    }

    // MARK: - Metrics strip (Battery / Signal / Firmware)

    private var deviceMetrics: some View {
        let metrics = DeviceMetricsPresentation.resolve(omiConnected: isOmiConnected,
                                                        batteryPercent: device.batteryLevel,
                                                        signal: signalValue)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                DeviceMetric(value: metrics.battery, label: DeviceMetricsPresentation.labels[0])
                metricDivider
                DeviceMetric(value: metrics.signal, label: DeviceMetricsPresentation.labels[1])
                metricDivider
                DeviceMetric(value: metrics.firmware, label: DeviceMetricsPresentation.labels[2])
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

    // MARK: - Capture sources (the two prototype rows: Omi + phone mic)

    private var captureSourcesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeviceSectionLabel("Capture sources")
                .padding(.top, GrainSpacing.x2)

            ForEach(CaptureSourceRowPresentation.prototypeRows(sources.sources)) { source in
                sourceRow(source)
            }
        }
    }

    private func sourceRow(_ source: CaptureSourceDescriptor) -> some View {
        let row = CaptureSourceRowPresentation.resolve(for: source, omiConnected: isOmiConnected)
        return HStack(spacing: GrainSpacing.x3) {
            DeviceIconTile(icon: sourceIcon(source.category),
                           foreground: source.id == sources.activeSourceId
                               ? GrainColor.sage
                               : GrainColor.forgeBlue)

            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                HStack(spacing: GrainSpacing.x1) {
                    Text(row.title)
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

                Text(row.subtitle)
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

    private func sourceIcon(_ category: CaptureSourceCategory) -> GrainIcon {
        switch category {
        case .omi, .bluetoothMic:
            return .mic
        case .phoneMic, .appleWatch:
            return .device
        }
    }

    // MARK: - Computer memory

    private var computerMemorySection: some View {
        let pres = ComputerMemoryPresentation.resolve(.resolve(remote: remote))
        return VStack(alignment: .leading, spacing: 0) {
            DeviceSectionLabel("Computer memory")
                .padding(.top, GrainSpacing.x3)
                .padding(.bottom, GrainSpacing.x1)

            HStack(alignment: .top, spacing: GrainSpacing.x3) {
                DeviceIconTile(icon: pres.isConnected ? .check : .device,
                               foreground: pres.isConnected ? GrainColor.sage : GrainColor.forgeBlue)

                VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                    Text(pres.title)
                        .grainTextStyle(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(GrainColor.ink)
                    Text(pres.subtitle)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: GrainSpacing.x1)

                HStack(spacing: GrainSpacing.x1) {
                    // Offline pill is muted/grey (not amber); paired is green.
                    GrainStatusDot(pres.isConnected ? .running : .stopped, size: .sm)
                    Text(pres.statusLabel)
                        .grainTextStyle(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(pres.isConnected ? GrainColor.sage : GrainColor.textFaint)
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

            // Full-width pairing action: primary connect when unpaired, secondary
            // disconnect when paired. Both open the existing pairing/connection
            // surface (SignInView → RemoteSession resolve) — no Settings redirect.
            Button {
                showingComputerPairing = true
            } label: {
                Text(pres.actionTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.grain(pres.actionIsPrimary ? .filled : .outlined))
            .padding(.top, GrainSpacing.x3)

            HStack(alignment: .top, spacing: GrainSpacing.x2) {
                Image(grain: .key)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                Text(pres.footer)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, GrainSpacing.x2)
        }
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

    private func signalHint(_ rssi: Int) -> String {
        if rssi >= -55 { return "Strong" }
        if rssi >= -75 { return "Nearby" }
        return "Weak"
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
