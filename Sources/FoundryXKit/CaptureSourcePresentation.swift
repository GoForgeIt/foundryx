// CaptureSourcePresentation — the capture page's PRIMARY source banner, as a pure
// projection of the live Omi BLE connection state plus whether the Omi is an enabled
// capture source (the device-page toggle).
//
// The capture page is the ONLY place to start/stop recording, and source connection is
// AUTOMATIC + self-healing: the app auto-connects to the user's saved Omi and
// auto-reconnects on a drop. So the connecting / reconnecting / searching states render
// as ambient STATUS — the user never hand-drives a BLE scan. Only a clean, nothing-
// connected idle surfaces the inline "Connect your Omi" affordance (a tap kicks off the
// automatic connect flow); Bluetooth-off asks the user to enable Bluetooth; a
// device-page toggle-OFF removes the Omi from the capture page entirely (phone-mic only).
//
// Keeping this a pure value (no SwiftUI, no CoreBluetooth) lets the capture-page banner
// state machine — including "no source connected ⇒ show the connect affordance" — be
// unit-tested without UI or hardware.

import Foundation

public enum CaptureSourcePresentation: Equatable, Sendable {
    case listening(name: String)     // Omi connected, capturing ambiently
    case paused(name: String)        // Omi connected, capture paused
    case connecting(name: String)    // auto-connecting to the saved Omi
    case reconnecting                // link dropped — auto-reconnecting (self-healing)
    case searching                   // scanning for the saved Omi (auto / first-time pairing)
    case needsConnection             // nothing connected → inline "Connect your Omi"
    case bluetoothOff                // Bluetooth off/unauthorized → ask to enable
    case omiDisabled                 // Omi toggled OFF on the device page → phone-mic only

    /// True while the Omi is connected + actively capturing (the single record/pause
    /// control offers Pause; the live meter + transcript are shown).
    public var isCapturing: Bool { if case .listening = self { return true }; return false }

    /// True while the Omi is connected (capturing OR paused) — drives the ambient header
    /// (vs the connect header) and whether the live capture surface is shown.
    public var isConnected: Bool {
        switch self {
        case .listening, .paused: return true
        default: return false
        }
    }

    /// True when the page should surface the inline "Connect your Omi" affordance. A tap
    /// kicks off the AUTOMATIC connect flow (auto-reconnect the saved Omi; first-time
    /// pairing scans + lists discovered Omis) — it is NOT a user-driven scan list.
    public var showsConnectAffordance: Bool {
        switch self {
        case .needsConnection, .bluetoothOff: return true
        default: return false
        }
    }

    /// True while the connect flow is auto-running (the header shows a spinner + status,
    /// with no user action required — the link is self-healing).
    public var isAutoConnecting: Bool {
        switch self {
        case .connecting, .reconnecting, .searching: return true
        default: return false
        }
    }

    /// The active source's display name when connected (else nil).
    public var connectedName: String? {
        switch self {
        case .listening(let n), .paused(let n): return n
        default: return nil
        }
    }

    /// Short status line for the capture header.
    public var statusLine: String {
        switch self {
        case .listening: return "Listening — capturing ambiently"
        case .paused: return "Paused"
        case .connecting(let n): return "Connecting to \(n)…"
        case .reconnecting: return "Reconnecting to your Omi…"
        case .searching: return "Looking for your Omi…"
        case .needsConnection: return "Connect your Omi to start capturing"
        case .bluetoothOff: return "Turn on Bluetooth to connect your Omi"
        case .omiDisabled: return "Omi is off — turn it on in Device to capture"
        }
    }

    /// Project the live BLE connection state (+ Omi-enabled + paused) onto the banner.
    /// A toggled-OFF Omi short-circuits to `.omiDisabled` regardless of the BLE link, so
    /// a disabled source never shows as the capture page's active source.
    public static func resolve(connection: DeviceConnectionState,
                               omiEnabled: Bool,
                               isPaused: Bool) -> CaptureSourcePresentation {
        guard omiEnabled else { return .omiDisabled }
        switch connection {
        case .connected(let n): return isPaused ? .paused(name: n) : .listening(name: n)
        case .connecting(let n): return .connecting(name: n)
        case .disconnected:      return .reconnecting
        case .scanning:          return .searching
        case .idle:              return .needsConnection
        case .poweredOff:        return .bluetoothOff
        }
    }
}
