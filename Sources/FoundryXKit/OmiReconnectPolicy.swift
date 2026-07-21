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
    /// Seconds to wait before re-issuing connect() after the FIRST didFailToConnect. A
    /// failed attempt only happens with the device in range (the handshake itself
    /// failed), so this is a rare, event-driven retry — not a poll loop. Repeated
    /// failures grow this exponentially (see `onFailToConnect`), capped, so a device
    /// that keeps refusing the handshake never becomes a fixed tight retry loop.
    public static let failedConnectRetryDelay: TimeInterval = 3
    /// Exponential-backoff ceiling for repeated failed connect attempts.
    public static let failedConnectRetryCap: TimeInterval = 120

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

    /// On `didFailToConnect` — retry with EXPONENTIAL BACKOFF instead of dead-ending or
    /// looping at a fixed interval. `attempt` is the number of consecutive prior
    /// failures (0 on the first retry): the delay is `failedConnectRetryDelay` doubled
    /// per prior attempt, capped at `failedConnectRetryCap`. attempt 0 ⇒ the unchanged
    /// first-retry timing. Previously one failed handshake dead-ended (`.disconnected`,
    /// stopped); the fixed-3s follow-up was still a tight loop under a flapping device.
    public static func onFailToConnect(autoConnect: Bool, attempt: Int = 0) -> FailedConnectAction {
        guard autoConnect else { return .stayDown }
        let delay = min(failedConnectRetryCap,
                        failedConnectRetryDelay * pow(2, Double(max(0, attempt))))
        return .retryAfterDelay(delay)
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

    // MARK: auto-connect / scan arming — the "no Omi ⇒ dormant" decision

    /// What the auto-reconnect entry should do, given whether a device is SAVED, whether
    /// CoreBluetooth has CACHED its peripheral handle, and whether THIS entry is a user
    /// gesture (an explicit "Connect/Pair" tap) vs the automatic path (central powered
    /// on, Bluetooth toggled on, a launch).
    public enum AutoConnectAction: Equatable, Sendable {
        /// Saved + handle cached ⇒ issue the (event-driven, no-poll) pending connect.
        case connectSaved
        /// Saved + handle NOT cached ⇒ a bounded, exponentially-backed-off reacquire scan
        /// OFF the main thread (never a tight loop).
        case reacquireBackoff
        /// No saved device, but a USER asked to connect ⇒ a bounded pairing scan.
        case pairingScan
        /// No saved device on the AUTOMATIC path ⇒ do NOTHING at all.
        case dormant
    }

    /// The core "don't run the loop when there's no Omi" decision. With no saved device
    /// and no user gesture the answer is `.dormant`: NO scan and NO pending connect, so
    /// CoreBluetooth persists no state-restoration data and iOS never relaunches the app
    /// to service a device that isn't there. That relaunch (re-running the DeviceManager/
    /// spool setup on the main thread) was the ~1s block the field telemetry symbolicated
    /// to `OmiRestorationSpool.attach`, and the standing scan was the "servicesToScan"
    /// the device syslog kept persisting — all for an Omi the owner never paired.
    public static func onAutoConnect(hasSaved: Bool, handleCached: Bool,
                                     userInitiated: Bool) -> AutoConnectAction {
        if hasSaved { return handleCached ? .connectSaved : .reacquireBackoff }
        return userInitiated ? .pairingScan : .dormant
    }
}

/// A pure exponential-backoff schedule (`base · multiplier^attempt`, capped). Used for
/// the saved-but-absent reacquire scan and repeated failed connects — the "paired but
/// absent" retries run OFF the main thread on THIS schedule, growing, never a fixed
/// tight loop. Value type so the DeviceManager owns one on its BLE queue and a test can
/// drive the exact delay sequence without CoreBluetooth.
public struct OmiBackoff: Equatable, Sendable {
    public let base: TimeInterval
    public let multiplier: Double
    public let cap: TimeInterval
    /// The number of delays already handed out (0 until the first `nextDelay()`).
    public private(set) var attempt: Int

    public init(base: TimeInterval = 4, multiplier: Double = 2, cap: TimeInterval = 120) {
        self.base = base
        self.multiplier = multiplier
        self.cap = cap
        self.attempt = 0
    }

    /// The delay for the NEXT attempt, then advance. Monotonic non-decreasing, capped.
    public mutating func nextDelay() -> TimeInterval {
        let d = min(cap, base * pow(multiplier, Double(attempt)))
        attempt += 1
        return d
    }

    /// Back to the first delay — call on a successful connect so the next outage starts
    /// from `base` again, not from the capped ceiling.
    public mutating func reset() { attempt = 0 }
}
