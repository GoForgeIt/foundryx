// DevicePagePresentation — pure presentation values for the Device tab
// (track 20260714T1800_ux_prototype_realignment §8, prototype `renderDevice`).
//
// The App-target DeviceScreen renders these 1:1; the brine step-defs for
// features/capture-sources.feature assert against the SAME builders, so the
// tested values ARE what ships. No SwiftUI here — keep it a pure value layer.

import Foundation

// MARK: - Computer memory (pairing) section

/// Whether a desktop Foundry is paired, projected from the remote session.
public enum ComputerPairingState: Equatable, Sendable {
    case notConnected
    /// Paired. `name` is the computer's friendly name when known ("Nick's
    /// MacBook"); the gateway's host/resolve does not yet return one (RelayConfig
    /// carries only the tunnel id), so live builds fall back to
    /// `ComputerMemoryPresentation.fallbackComputerName` until it does.
    case connected(name: String?)
}

/// The Computer memory section, exactly as the prototype frames it: a row
/// (title / subtitle / status pill), one full-width action button, and the
/// pairing privacy footer.
public struct ComputerMemoryPresentation: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let statusLabel: String
    public let isConnected: Bool
    /// The full-width button under the row: primary "Connect your computer"
    /// when unpaired, secondary "Disconnect computer" when paired.
    public let actionTitle: String
    public let actionIsPrimary: Bool
    public let footer: String

    public static let connectTitle = "Connect your computer"
    public static let disconnectTitle = "Disconnect computer"
    public static let footerLine = "Pairing is end-to-end encrypted to your own machine."
    /// Shown while the friendly host name is unknown (see ComputerPairingState).
    public static let fallbackComputerName = "Your computer"

    public static func resolve(_ pairing: ComputerPairingState) -> ComputerMemoryPresentation {
        switch pairing {
        case .notConnected:
            return ComputerMemoryPresentation(
                title: connectTitle,
                subtitle: "Pair the desktop app for full-history search and local Brain runs",
                statusLabel: "Not connected",
                isConnected: false,
                actionTitle: connectTitle,
                actionIsPrimary: true,
                footer: footerLine)
        case .connected(let name):
            let display = (name?.isEmpty == false) ? name! : fallbackComputerName
            return ComputerMemoryPresentation(
                title: display,
                subtitle: "Desktop app paired · Full-history search ready",
                statusLabel: "Connected",
                isConnected: true,
                actionTitle: disconnectTitle,
                actionIsPrimary: false,
                footer: footerLine)
        }
    }
}

public extension ComputerPairingState {
    /// Project the live remote session onto the pairing state: paired means the
    /// session can actually build a door target (signed in + host resolved) —
    /// the same predicate the rest of the app uses to talk to the desktop.
    @MainActor static func resolve(remote: RemoteSession) -> ComputerPairingState {
        remote.makeDoorTarget() != nil ? .connected(name: nil) : .notConnected
    }
}

// MARK: - Metrics strip (Battery / Signal / Firmware)

/// The 3-up metrics strip. Third column is Firmware (prototype), not Device ID.
public struct DeviceMetricsPresentation: Equatable, Sendable {
    public let battery: String
    public let signal: String
    public let firmware: String

    /// Column labels, in prototype order.
    public static let labels = ["Battery", "Signal", "Firmware"]

    /// NEW (spec §8): DeviceManager does not yet read the Omi's Device
    /// Information Service, so no real firmware version is available over BLE.
    /// This is the spec's hard-coded value, clearly labeled as such — swap for
    /// a real DIS read when DeviceManager surfaces one.
    public static let firmwareFallback = "2.4.1"

    public static func resolve(omiConnected: Bool,
                               batteryPercent: Int?,
                               signal: String) -> DeviceMetricsPresentation {
        DeviceMetricsPresentation(
            battery: batteryPercent.map { "\($0)%" } ?? "N/A",
            signal: signal,
            firmware: omiConnected ? firmwareFallback : "N/A")
    }
}

// MARK: - Capture-source rows

/// Row copy for the Capture sources section (exactly two rows in the
/// prototype: Omi microphone + Phone microphone).
public struct CaptureSourceRowPresentation: Equatable, Sendable {
    public let title: String
    public let subtitle: String

    public static func resolve(for source: CaptureSourceDescriptor,
                               omiConnected: Bool) -> CaptureSourceRowPresentation {
        switch source.category {
        case .omi:
            return CaptureSourceRowPresentation(
                title: "Omi microphone",
                subtitle: omiConnected
                    ? "Use the wearable for capture"
                    : "Reconnect Omi to use this source")
        case .phoneMic:
            return CaptureSourceRowPresentation(
                title: "Phone microphone",
                subtitle: "Use this iPhone as another capture source")
        case .appleWatch, .bluetoothMic:
            // Legacy added sources (the add-source flow is gone per §8) — keep
            // their honest connection label if one still exists in a store.
            let detail = source.detail.flatMap { $0.isEmpty ? nil : $0 }
            let label = detail.map { "\(source.connection.label) · \($0)" }
                ?? source.connection.label
            return CaptureSourceRowPresentation(title: source.displayName, subtitle: label)
        }
    }

    /// The rows the device page shows: the two prototype built-ins, in registry
    /// order. Previously added Bluetooth/watch sources stay in the registry (and
    /// in the active-source policy) but are no longer surfaced here.
    public static func prototypeRows(_ sources: [CaptureSourceDescriptor]) -> [CaptureSourceDescriptor] {
        sources.filter { $0.category == .omi || $0.category == .phoneMic }
    }
}
