// OmiReconnectPolicy — the pure always-reconnect decisions, testable WITHOUT
// CoreBluetooth (same ethos as OmiAutoConnect). DeviceManager maps CB delegate
// callbacks onto these events and executes the returned action verbatim.
//
// The iOS-correct primitive: CBCentralManager.connect() has NO timeout. Issued
// against an out-of-range peripheral it stays PENDING and completes whenever the
// device returns to range — including while the app is backgrounded (with the
// bluetooth-central background mode) and, with state restoration, even after iOS
// terminated the app. So the policy is: every unexpected disconnect immediately
// re-issues connect() on the SAME peripheral (never a scan loop), and a failed
// connect attempt retries after a short delay instead of dead-ending.

import Foundation

public enum OmiReconnectPolicy {
    /// Seconds to wait before re-issuing connect() after didFailToConnect. A failed
    /// attempt only happens with the device in range (the handshake itself failed),
    /// so this is a rare, event-driven retry — not a poll loop.
    public static let failedConnectRetryDelay: TimeInterval = 3

    public enum DisconnectAction: Equatable, Sendable {
        /// Re-issue connect() on the same peripheral — the standing pending connect.
        case reissuePendingConnect
        /// User-suspended (device page toggle off): stay down until re-enabled.
        case stayDown
    }

    /// On `didDisconnectPeripheral`. The ONLY reason not to re-arm is an explicit
    /// user suspend; a transient drop (out of range, device reboot) always re-arms.
    public static func onDisconnect(autoConnect: Bool) -> DisconnectAction {
        autoConnect ? .reissuePendingConnect : .stayDown
    }

    public enum FailedConnectAction: Equatable, Sendable {
        case retryAfterDelay(TimeInterval)
        case stayDown
    }

    /// On `didFailToConnect` — retry (delayed) instead of dead-ending. Previously
    /// this path set `.disconnected` and stopped: one failed handshake meant the
    /// Omi never came back until the user foregrounded the app.
    public static func onFailToConnect(autoConnect: Bool) -> FailedConnectAction {
        autoConnect ? .retryAfterDelay(failedConnectRetryDelay) : .stayDown
    }

    /// A restored peripheral's connection state, CB-free for tests.
    public enum RestoredPeripheralState: Equatable, Sendable {
        case connected      // link survived — rediscover services and resume streaming
        case connecting     // the pending connect is still pending — leave it alone
        case disconnected   // restoration raced the drop — issue a fresh pending connect
    }

    public enum RestoreAction: Equatable, Sendable {
        case discoverServices
        case waitForPendingConnect
        case reissuePendingConnect
        case stayDown
    }

    /// What to do with the peripheral handed back by `willRestoreState`, once the
    /// central reports poweredOn. (State restoration relaunched the app because a
    /// bluetooth-central event fired for us; a user-suspended Omi has no pending
    /// connect to restore, but guard anyway.)
    public static func onRestore(state: RestoredPeripheralState, autoConnect: Bool) -> RestoreAction {
        guard autoConnect else { return .stayDown }
        switch state {
        case .connected: return .discoverServices
        case .connecting: return .waitForPendingConnect
        case .disconnected: return .reissuePendingConnect
        }
    }
}
