// FoundryXAppDelegate — process-level account exposure coordination.
//
// Task 6 deliberately leaves CoreBluetooth background restoration dormant. A locked
// relaunch has no verified account preference snapshot, so it must not construct a
// source store, a capture spool, or a central. Task 7 owns the later verified-owner
// restoration design. The handoff remains an inert compatibility seam until then.

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
        _ = launchOptions
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
