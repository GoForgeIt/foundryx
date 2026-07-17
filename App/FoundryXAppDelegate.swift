// FoundryXAppDelegate — the CoreBluetooth STATE-RESTORATION bootstrap.
//
// When the Omi walks out of range, DeviceManager leaves a standing PENDING connect
// (no timeout). If iOS then terminates the app, the pending connect survives inside
// bluetoothd, and when the Omi returns to range iOS RELAUNCHES the app in the
// background, passing our central's restore identifier in the launch options. That
// launch has NO UI: SwiftUI scene/`RootView` construction isn't guaranteed, and the
// full CaptureManager pipeline (sign-in, door target) isn't built. So the delegate —
// the earliest, guaranteed hook — re-creates the shared DeviceManager (same restore
// identifier ⇒ `willRestoreState` hands the peripheral back) and attaches the
// headless OmiRestorationSpool so the reconnected stream is saved durably to the
// standard capture WAL. When the user later opens the app, MainTabs adopts the SAME
// shared DeviceManager, detaches the spool, and the existing resume-same-id logic
// continues the conversation from the spool's segments.

import UIKit
import SwiftUI

final class FoundryXAppDelegate: NSObject, UIApplicationDelegate {
    /// The spool serving a background-restoration launch (nil on normal launches or
    /// after the UI takes over). Main-thread only.
    private(set) static var restorationSpool: OmiRestorationSpool?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let centrals = (launchOptions?[.bluetoothCentrals] as? [String]) ?? []
        if centrals.contains(DeviceManager.restoreIdentifier) {
            Self.beginBackgroundRestoration()
        }
        return true
    }

    /// Recreate the central (same restore identifier — `willRestoreState` fires) and
    /// spool frames durably. Honors the user's persisted intents: an Omi the user
    /// toggled OFF is never resurrected; a paused capture holds the link but records
    /// nothing (the spool checks pause per-frame).
    private static func beginBackgroundRestoration() {
        // A signed-out phone must never record in the background. The check must
        // work with the device LOCKED (phone in pocket — the normal case), so it
        // reads the lock-screen-safe persisted sign-in signal, not the keychain.
        guard FoundryAuth.hasPersistedSignIn else { return }
        let store = UserDefaultsCaptureSourceStore()
        let omiEnabled = store.enabledOverrides[CaptureSourceDescriptor.omiId] ?? true
        guard omiEnabled else { return }

        let log = DoorLog()
        log.setRemoteSink(RemoteConfig.fromBundle()?.gatewayHTTPURL.appendingPathComponent("diag/log"))
        log.info("omi-restore: background relaunch for bluetooth-central restoration")

        let dm = DeviceManager.shared(log: log)
        let spool = OmiRestorationSpool(log: log)
        spool.attach(to: dm)
        restorationSpool = spool
        dm.start()   // creates the central with the SAME restore identifier → willRestoreState
    }

    /// UI takeover (MainTabs building the real CaptureManager): flush the spool's
    /// partial segment to disk and release it. Safe no-op on normal launches.
    static func handOffRestorationToApp() {
        guard let spool = restorationSpool else { return }
        spool.detach()
        restorationSpool = nil
    }
}
