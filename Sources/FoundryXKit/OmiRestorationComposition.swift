// OmiRestorationComposition — the composition root for a background-restoration spool,
// LIVING IN THE KIT rather than in `App/`.
//
// WHY IT IS HERE AND NOT IN THE APP DELEGATE. `swift test` compiles only the SwiftPM
// package; the hostless iOS test target does not build `App/` either. Composition that
// lives in `FoundryXAppDelegate` is therefore, structurally, code no test can execute — and
// the composition is exactly where the device identity is resolved and handed to the thing
// that writes it into the user's archive. Putting it in the Kit is what makes the boundary
// falsifiable: omitting the context here reds a feature, instead of compiling silently in a
// file the test bundle cannot see.
//
// The AppDelegate keeps what only it can do — reading the bundle's remote-log config,
// owning the shared DeviceManager, registering the account-exposure participant — and calls
// this for the rest.

import Foundation

public enum OmiRestorationComposition {

    /// Resolve WHICH device a background restoration is about to record from.
    ///
    /// FAILS LOUD, BY TYPE. Both inputs can legitimately be absent during a background
    /// relaunch — the account container may not be resolvable before first unlock, and
    /// there may be no remembered device at all — and neither absence may be papered over.
    /// A placeholder identity written into a capture directory is indistinguishable from a
    /// real one forever after, so the answer is `blocked` and the caller defers.
    public static func resolveDeviceContext(
        binding: CaptureAccountScope.AccountBinding?,
        savedDevice: SavedOmi?
    ) -> CaptureDeviceContextResolution {
        guard let binding else {
            return .blocked(reason:
                "no account scope is resolvable during this background restoration, so any "
                    + "audio recorded now could not be attributed to an owner")
        }
        guard let savedDevice else {
            return .blocked(reason:
                "no remembered device is available, so audio recorded now could not be "
                    + "attributed to a device")
        }
        return .resolved(CaptureDeviceContext(
            identity: RecordingDeviceIdentity(shape: .bleStream,
                                              hardwareToken: savedDevice.id.uuidString),
            displayName: savedDevice.name,
            accountScope: binding.scope))
    }

    /// Build the spool the restoration bootstrap installs, carrying the resolved context in.
    ///
    /// `deviceContext` is NOT defaulted. A default would let the boundary this factory
    /// exists to hold be crossed by omission — the mutation "omit the context at the factory
    /// boundary" would then be a change nobody has to make deliberately.
    public static func makeRestorationSpool(
        binding: CaptureAccountScope.AccountBinding?,
        root: URL,
        executor: DispatchQueue,
        log: DoorLog?,
        silenceGap: TimeInterval,
        paused: @escaping () -> Bool,
        deviceContext: CaptureDeviceContextResolution
    ) -> OmiRestorationSpool {
        if case .blocked(let reason) = deviceContext {
            log?.warn("omi-restore: not recording — \(reason)")
        }
        return OmiRestorationSpool(
            baseDir: root,
            log: log,
            silenceGap: silenceGap,
            paused: paused,
            binding: binding,
            executor: executor,
            deviceContext: deviceContext)
    }
}
