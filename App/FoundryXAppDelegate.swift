// FoundryXAppDelegate — process-level account exposure coordination.
//
// A Bluetooth-restoration relaunch may happen before protected Keychain data is
// readable. The headless path therefore starts only from the independently persisted
// ACTIVE owner plus its matching App-Group owner tag, and it snapshots that owner's
// capture choices once before wiring any per-frame callback.

import UIKit
import SwiftUI

final class FoundryXAppDelegate: NSObject, UIApplicationDelegate {
    /// One process-owned weak registry. Registration is inert; Task 5 explicitly
    /// invokes closure at the identity boundary.
    static let accountExposureCoordinator =
        AccountExposureCoordinator.process

    /// The spool serving a background-restoration launch (nil on normal launches or
    /// after the UI takes over). Main-thread only.
    private(set) static var restorationSpool: OmiRestorationSpool?
    private static var restorationSpoolExposure:
        AccountExposureRegistration?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = application
        guard launchOptions?[.bluetoothCentrals] != nil,
              FoundryAuth.hasPersistedSignIn,
              let binding = CaptureAccountScope.currentAccountBinding()
        else {
            return true
        }

        let preferences = CaptureSettings.snapshot(
            binding: binding)
        let omiEnabled = preferences.sourceEnabledOverrides[
            CaptureSourceDescriptor.omiId] ?? true
        guard omiEnabled else {
            return true
        }

        // THE SHARED LOG, NOT A PRIVATE ONE. Two bootstraps each built their own
        // DoorLog and wired a sink to it, which meant "the log" was whichever
        // instance a given caller happened to hold — and the nineteen call sites
        // that held none reported into nothing. Configuring the process-wide
        // instance here is what lets every one of them reach the relay.
        let log = DoorLog.shared
        log.setRemoteSink(
            RemoteConfig.fromBundle()?.gatewayHTTPURL
                .appendingPathComponent("diag/log"))
        let dm = DeviceManager.shared(log: log)
        // N7, on the headless path too: a gap outcome names the account it is about, or it is
        // withheld. This bootstrap already holds the one proved-owner binding.
        // ONE CALL, NOT TWO (review round 12, M12-1). This used to install the follower and
        // then push `binding.scope` separately — and that second, hand-written push is what a
        // mutation walked through: `setAccountScopeForGapOutcomes(String?.none)` here makes
        // every gap outcome on the headless path nameless while the follower call still
        // satisfies every search for this wiring. The scope is now HANDED OVER as the
        // follower's first value, so nothing under `App/` sets it by hand and the gate can
        // ban that call outright instead of guessing at spellings of `nil`.
        //
        // WHY THE PROVED-OWNER BINDING AND NOT THE RESOLVER. This is a background BLE
        // relaunch: `CaptureAccountScope.currentAccountBinding()` may not resolve at all here,
        // while this bootstrap has already proved which account owns the restoration. Handing
        // it over is the more specific answer; every LATER push comes from the identity
        // notification and is freshly resolved.
        dm.followAccountScopeChanges(startingFrom: binding.scope)
        let paused = preferences.omiDesiredState != .listening
        // The composition root resolves WHICH device this restoration is about to record
        // from and hands it in. It lives in the Kit (`OmiRestorationComposition`) rather
        // than here because `App/` is compiled by no test target — a boundary that cannot
        // be executed cannot be falsified, and this is the boundary where a device identity
        // enters a user's archive.
        let spool = OmiRestorationComposition.makeRestorationSpool(
            binding: binding,
            root: binding.root,
            executor: DispatchQueue(
                label: "foundryx.omi-restoration-owner"),
            log: log,
            silenceGap: preferences.silenceGapSeconds,
            paused: { paused },
            // A bluetooth-restoration relaunch exists BECAUSE an external stream reconnected;
            // the handset's microphone is not involved in this path at all.
            deviceContext: OmiRestorationComposition.resolveDeviceContext(
                binding: binding,
                activeDevice: OmiRestorationComposition.activeExternalDevice(
                    binding: binding, attached: dm.saved),
                recording: .externalStream))
        let exposure = AccountExposureRegistration(
            participantID: "omi-restoration-spool",
            kind: .live,
            binding: binding,
            owner: spool,
            close: { spool, expected in
                await spool.closeAccountExposure(expected: expected)
            })
        Self.restorationSpool = spool
        Self.restorationSpoolExposure = exposure
        Self.accountExposureCoordinator.register(exposure)
        spool.attach(to: dm)
        dm.start()
        return true
    }

    /// UI takeover (MainTabs building the real CaptureManager): flush the spool's
    /// partial segment to disk and release it. Safe no-op on normal launches.
    static func handOffRestorationToApp(
        accountBinding: CaptureAccountScope.AccountBinding?
    ) {
        guard let spool = restorationSpool else { return }
        if let accountBinding,
           let rooted = spool.installAccountExposureBinding(
                from: accountBinding) {
            restorationSpoolExposure?.installBinding(rooted)
        }
        spool.detach()
        restorationSpool = nil
        restorationSpoolExposure = nil
    }
}
