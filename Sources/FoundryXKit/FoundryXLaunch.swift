// FoundryXLaunch — what a launch owes, and what this particular launch is.
//
// WHY THIS IS IN THE KIT AND NOT IN THE APP DELEGATE. `swift test` compiles the SPM package
// only; it cannot see `App/` at all. A decision written inside `didFinishLaunchingWithOptions`
// is a decision no test can execute, and this is the decision that governs whether ANY
// diagnostics exist:
//
//   `App/FoundryXAppDelegate.swift` opened with a single `guard` that combined four
//   conditions — is this a CoreBluetooth restoration relaunch, is someone signed in, is there
//   an account binding, is the Omi source enabled — and returned early if any failed. Wiring
//   the process-wide diagnostic sink sat AFTER that guard. iOS supplies
//   `launchOptions[.bluetoothCentrals]` only on a background restoration relaunch, so on
//   every ordinary launch the method returned before reaching it: `DoorLog.shared` had no
//   sink, `flush()` returned at its first guard, and every line written by a call site that
//   holds no log of its own — which is the entire recorder surface — died on the device.
//
//   It was not visible as silence, either. `App/RootView.swift` built its own private
//   `DoorLog()` and sinked THAT, so 1,569 lines a day still arrived at the relay from one
//   handset. The transport looked healthy while an entire category of line (`cmd pocket…`,
//   every recorder line) had never once been shipped.
//
// So the two obligations are separated here, where they can be held: sinking the log is what
// EVERY launch owes, and the BLE restoration bootstrap is what SOME launches are.

import Foundation

public enum FoundryXLaunch {

    /// What a launch is, once the work every launch owes has been done.
    public struct Plan: Equatable, Sendable {
        /// Whether this launch should run the background CoreBluetooth restoration bootstrap
        /// (adopt the shared `DeviceManager`, build the restoration spool, start the link).
        /// True only on a relaunch iOS itself started to restore a central.
        public let runsBluetoothRestoration: Bool

        public init(runsBluetoothRestoration: Bool) {
            self.runsBluetoothRestoration = runsBluetoothRestoration
        }
    }

    /// Do the work every launch owes, then say what else this launch is.
    ///
    /// THE SINK IS INSTALLED UNCONDITIONALLY. Not "when signed in", not "when a device is
    /// paired" — a launch that fails to sign in is precisely the launch whose diagnostics are
    /// worth reading, and the sink is inert when `diagnosticSink` is nil.
    ///
    /// IT IS INSTALLED ONCE PER PROCESS for a given URL: `DoorLog.setRemoteSink` ignores a
    /// repeat of the sink already live, so a second bootstrap cannot reset the 15-second
    /// backstop flush before it has had a chance to fire.
    ///
    /// - Parameters:
    ///   - bluetoothRestoration: whether iOS handed this launch a CoreBluetooth restoration
    ///     (`launchOptions[.bluetoothCentrals] != nil`).
    ///   - diagnosticSink: the relay's `/diag/log` endpoint, or nil when the build has no
    ///     relay configured.
    ///   - log: the log to configure — the process-wide one in production. Injectable so a
    ///     test can hold this without reaching for a singleton.
    @discardableResult
    public static func begin(bluetoothRestoration: Bool,
                             diagnosticSink: URL?,
                             log: DoorLog = .shared) -> Plan {
        log.setRemoteSink(diagnosticSink)
        return Plan(runsBluetoothRestoration: bluetoothRestoration)
    }
}
