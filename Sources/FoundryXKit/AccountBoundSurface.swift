import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// Every store that holds per-account state joins the identity boundary here.
public protocol AccountBoundSurface: Sendable {
    static var surfaceID: AccountSurfaceID { get }
    static func attachAccount(
        _ binding: CaptureAccountScope.AccountBinding
    ) -> AccountSurfaceOutcome
    static func detachAccount(
        previous: CaptureAccountScope.AccountBinding?
    ) -> AccountSurfaceOutcome
    static func eraseAccount(
        _ binding: CaptureAccountScope.AccountBinding
    ) -> AccountSurfaceOutcome
    /// Prove the erase held, WITHOUT erasing again.
    ///
    /// Deletion verifies each cleanup group after removing it, and re-verifies
    /// every already-completed group on recovery, so this runs up to three times
    /// per erase. Most surfaces are UserDefaults or Keychain reads where erasing
    /// twice is free, and for those the default below is exactly right. It is
    /// not right for a surface whose erase is expensive or can time out: the
    /// Live Activity surface blocks the calling thread on a semaphore waiting
    /// for a detached Task, so re-running it turned one 5-second cliff into
    /// three, on a thread the deletion is already awaiting.
    static func verifyAccountErased(
        _ binding: CaptureAccountScope.AccountBinding
    ) -> AccountSurfaceOutcome
}

public extension AccountBoundSurface {
    /// Idempotent erasers ARE their own verification, and re-running them is
    /// what proves cross-process and Keychain state after a crash.
    static func verifyAccountErased(
        _ binding: CaptureAccountScope.AccountBinding
    ) -> AccountSurfaceOutcome {
        eraseAccount(binding)
    }
}

/// The complete manifest of identity-bearing state. The raw values are stable audit
/// labels; registry execution sorts by them so a failure is reproducible.
public enum AccountSurfaceID: String, CaseIterable, Sendable {
    case widgetActiveOwner
    case widgetSnapshotPayload
    case activationRecord
    case signedInMirror
    case keychainIdentity
    case accountPreferences
    case legacyPreferences
    case legacySignupMarker
    case cellBinding
    case cellBearerSecret
    case doorBinding
    case doorBearerSecret
    case localAccountRoot
    case legacyPrivateData
    case legacyPairingSecret
    case deletionTombstone
    case omiPairing
    case batteryMonitoredDevice
    case captureSourceChoice
    case userAddedCaptureSources
    case actionButtonChoice
    case bleCentralRestoration
    case liveActivity
    case inMemorySession
    case appRootDerivedState
    case mainTabsSubtree
}

public enum AccountSurfaceOutcome: Sendable, Equatable {
    case done
    case alreadyClean
    case retainedByDesign(reason: String)
    case failed(String)

    public var isTerminalSuccess: Bool {
        switch self {
        case .done, .alreadyClean: return true
        case .retainedByDesign(let reason):
            return !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .failed: return false
        }
    }
}

private enum AccountSurfaceRuntime {
    static let lock = NSRecursiveLock()
    nonisolated(unsafe) static var injectedDefaults: UserDefaults?
    static var storage: UserDefaults {
        injectedDefaults ?? CaptureAccountScope.accountSurfaceDefaults
    }

    static func withDefaults<T>(_ defaults: UserDefaults, _ operation: () -> T) -> T {
        lock.lock()
        let previous = injectedDefaults
        injectedDefaults = defaults
        defer {
            injectedDefaults = previous
            lock.unlock()
        }
        return operation()
    }

    static func clear(_ keys: [String]) -> AccountSurfaceOutcome {
        let storage: UserDefaults = self.storage
        let existed = keys.contains { storage.object(forKey: $0) != nil }
        keys.forEach { storage.removeObject(forKey: $0) }
        guard storage.synchronize(),
              keys.allSatisfy({ storage.object(forKey: $0) == nil }) else {
            return .failed("preference removal was not durable")
        }
        return existed ? .done : .alreadyClean
    }

    static func clearScoped(
        _ canonicalKeys: [String], binding: CaptureAccountScope.AccountBinding
    ) -> AccountSurfaceOutcome {
        clear(canonicalKeys.map { "\(binding.scope).\($0)" })
    }
}

struct AccountSurfaceDetachSnapshot {
    fileprivate let values: [String: Any]
    fileprivate let absentKeys: Set<String>
}

/// Static, total registry. There is no runtime registration path that can silently be
/// empty; adding a manifest case without adding a conformer turns the completeness test
/// red.
public enum AccountSurfaceRegistry {
    public static let surfaces: [any AccountBoundSurface.Type] = [
        AccountPreferencesSurface.self,
        ActionButtonChoiceSurface.self,
        ActivationRecordSurface.self,
        AppRootDerivedStateSurface.self,
        BatteryMonitoredDeviceSurface.self,
        BLECentralRestorationSurface.self,
        CellBearerSecretSurface.self,
        CellBindingSurface.self,
        CaptureSourceChoiceSurface.self,
        DeletionTombstoneSurface.self,
        DoorBearerSecretSurface.self,
        DoorBindingSurface.self,
        InMemorySessionSurface.self,
        KeychainIdentitySurface.self,
        LegacyPairingSecretSurface.self,
        LegacyPreferencesSurface.self,
        LegacyPrivateDataSurface.self,
        LegacySignupMarkerSurface.self,
        LiveActivitySurface.self,
        LocalAccountRootSurface.self,
        MainTabsSubtreeSurface.self,
        OmiPairingSurface.self,
        SignedInMirrorSurface.self,
        UserAddedCaptureSourcesSurface.self,
        WidgetActiveOwnerSurface.self,
        WidgetSnapshotPayloadSurface.self,
    ].sorted { $0.surfaceID.rawValue < $1.surfaceID.rawValue }

    public static var surfaceIDs: [AccountSurfaceID] {
        surfaces.map { surface in surface.surfaceID }
    }

    public static func attachAll(
        _ binding: CaptureAccountScope.AccountBinding
    ) -> [AccountSurfaceID: AccountSurfaceOutcome] {
        outcomes { $0.attachAccount(binding) }
    }

    public static func detachAll(
        previous: CaptureAccountScope.AccountBinding?
    ) -> [AccountSurfaceID: AccountSurfaceOutcome] {
        outcomes { $0.detachAccount(previous: previous) }
    }

    static func captureDetachSnapshot() -> AccountSurfaceDetachSnapshot {
        let storage = AccountSurfaceRuntime.storage
        return AccountSurfaceDetachSnapshot(
            values: Dictionary(uniqueKeysWithValues: detachPreferenceKeys.compactMap { key in
                storage.object(forKey: key).map { (key, $0) }
            }),
            absentKeys: Set(detachPreferenceKeys.filter { storage.object(forKey: $0) == nil }))
    }

    static func restoreDetachSnapshot(
        _ snapshot: AccountSurfaceDetachSnapshot
    ) -> AccountSurfaceOutcome {
        let storage = AccountSurfaceRuntime.storage
        snapshot.absentKeys.forEach { storage.removeObject(forKey: $0) }
        snapshot.values.forEach { storage.set($0.value, forKey: $0.key) }
        guard storage.synchronize(),
              snapshot.values.allSatisfy({ storage.object(forKey: $0.key) != nil }),
              snapshot.absentKeys.allSatisfy({ storage.object(forKey: $0) == nil }) else {
            return .failed("detached preference state was not durably restored")
        }
        return .done
    }

    static func detachAll(
        previous: CaptureAccountScope.AccountBinding?,
        defaults: UserDefaults
    ) -> [AccountSurfaceID: AccountSurfaceOutcome] {
        AccountSurfaceRuntime.withDefaults(defaults) {
            detachAll(previous: previous)
        }
    }

    public static func eraseAll(
        _ binding: CaptureAccountScope.AccountBinding
    ) -> [AccountSurfaceID: AccountSurfaceOutcome] {
        outcomes { $0.eraseAccount(binding) }
    }

    static func eraseAll(
        _ binding: CaptureAccountScope.AccountBinding,
        defaults: UserDefaults
    ) -> [AccountSurfaceID: AccountSurfaceOutcome] {
        AccountSurfaceRuntime.withDefaults(defaults) { eraseAll(binding) }
    }

    /// Prove the erase held. Same manifest, same completeness guarantee — but a
    /// surface may answer this without redoing its erase.
    static func verifyAll(
        _ binding: CaptureAccountScope.AccountBinding,
        defaults: UserDefaults
    ) -> [AccountSurfaceID: AccountSurfaceOutcome] {
        AccountSurfaceRuntime.withDefaults(defaults) {
            outcomes { $0.verifyAccountErased(binding) }
        }
    }

    /// Identity publication is deliberately narrower than sign-out: activation may
    /// publish a blocked intermediate state before the credential transaction commits.
    /// It still goes through the manifest-owned widget surfaces, never a raw store call.
    static func publishIdentity(
        _ binding: CaptureAccountScope.AccountBinding,
        replacingIdentity: Bool
    ) {
        if replacingIdentity {
            CaptureWidgetSnapshotStore.transition(toOwner: binding.scope)
        }
        _ = WidgetActiveOwnerSurface.attachAccount(binding)
        _ = WidgetSnapshotPayloadSurface.attachAccount(binding)
    }

    static func withdrawPublishedIdentity() {
        _ = WidgetActiveOwnerSurface.detachAccount(previous: nil)
        _ = WidgetSnapshotPayloadSurface.detachAccount(previous: nil)
        _ = LiveActivitySurface.detachAccount(previous: nil)
    }

    private static func outcomes(
        _ operation: (any AccountBoundSurface.Type) -> AccountSurfaceOutcome
    ) -> [AccountSurfaceID: AccountSurfaceOutcome] {
        var result: [AccountSurfaceID: AccountSurfaceOutcome] = [:]
        for surface in surfaces { result[surface.surfaceID] = operation(surface) }
        return result
    }
}

private let managedAccountPreferenceKeys = AccountPreferenceCatalog.entries.map(\.canonicalKey)
private let pairingBindingKeys = [
    "foundryx.cell.url", "foundryx.cell.authMode", "foundryx.door.url",
]
private let omiPairingKeys = [
    "foundryx.omi.peripheral-id",
    "foundryx.omi.peripheral-name",
    "foundryx.omi.last-connected",
]
private let detachPreferenceKeys = [
    CaptureWidgetSnapshotStore.activeOwnerKey,
    CaptureWidgetSnapshotStore.key,
    AuthStore.signedInMirrorKey,
    BatteryMonitorStore.idKey,
    BatteryMonitorStore.nameKey,
    "foundryx.capture.source",
    "foundryx.capture.sources.added",
    "foundryx.action-button.choice",
]

private protocol PassiveSurface: AccountBoundSurface {}
private extension PassiveSurface {
    static func attachAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome { .alreadyClean }
    static func detachAccount(previous: CaptureAccountScope.AccountBinding?) -> AccountSurfaceOutcome { .alreadyClean }
}

private struct WidgetActiveOwnerSurface: AccountBoundSurface {
    static let surfaceID = AccountSurfaceID.widgetActiveOwner
    static func attachAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        CaptureWidgetSnapshotStore.publishActiveOwner(binding.scope); return .done
    }
    static func detachAccount(previous: CaptureAccountScope.AccountBinding?) -> AccountSurfaceOutcome {
        CaptureWidgetSnapshotStore.transition(toOwner: nil); return .done
    }
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        switch CaptureWidgetSnapshotStore.withdraw(expectedOwner: binding.scope) {
        case .withdrawn: return .done
        case .alreadyAbsent, .ownerMismatch: return .alreadyClean
        case .persistenceFailed: return .failed("widget owner withdrawal was not durable")
        }
    }
}

private struct WidgetSnapshotPayloadSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.widgetSnapshotPayload
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        switch CaptureWidgetSnapshotStore.withdraw(expectedOwner: binding.scope) {
        case .withdrawn: return .done
        case .alreadyAbsent, .ownerMismatch: return .alreadyClean
        case .persistenceFailed: return .failed("widget payload withdrawal was not durable")
        }
    }
}

private struct ActivationRecordSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.activationRecord
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        .retainedByDesign(reason: "the activation record is re-phased so interrupted deletion and sign-out can recover safely")
    }
}

private struct SignedInMirrorSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.signedInMirror
    static func detachAccount(previous: CaptureAccountScope.AccountBinding?) -> AccountSurfaceOutcome { clear() }
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome { clear() }
    private static func clear() -> AccountSurfaceOutcome {
        let storage: UserDefaults = AccountSurfaceRuntime.storage
        storage.set(false, forKey: AuthStore.signedInMirrorKey)
        return storage.synchronize() && storage.bool(forKey: AuthStore.signedInMirrorKey) == false
            ? .done : .failed("signed-in mirror did not persist false")
    }
}

private struct KeychainIdentitySurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.keychainIdentity
    static func detachAccount(previous: CaptureAccountScope.AccountBinding?) -> AccountSurfaceOutcome {
        .retainedByDesign(reason: "AuthStore deletes the credential only after every reversible detach succeeds, preserving sign-out rollback")
    }
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        AuthStore.eraseIdentityCredential()
    }
}

private struct AccountPreferencesSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.accountPreferences
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        AccountSurfaceRuntime.clearScoped(managedAccountPreferenceKeys, binding: binding)
    }
}

private struct LegacyPreferencesSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.legacyPreferences
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        .retainedByDesign(reason: "legacy preferences are erased only after the deletion lifecycle proves legacy ownership")
    }
}

private struct LegacySignupMarkerSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.legacySignupMarker
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        .retainedByDesign(reason: "the legacy signup marker is retired by the owner-proving legacy cleanup group")
    }
}

private struct CellBindingSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.cellBinding
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        AccountSurfaceRuntime.clearScoped(Array(pairingBindingKeys.prefix(2)), binding: binding)
    }
}
private struct DoorBindingSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.doorBinding
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        AccountSurfaceRuntime.clearScoped([pairingBindingKeys[2]], binding: binding)
    }
}
private struct CellBearerSecretSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.cellBearerSecret
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        .retainedByDesign(reason: "the replay-safe pairing-secrets cleanup group removes and verifies the injected Cell keychain service")
    }
}
private struct DoorBearerSecretSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.doorBearerSecret
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        .retainedByDesign(reason: "the replay-safe pairing-secrets cleanup group removes and verifies the injected Door keychain service")
    }
}

private struct LocalAccountRootSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.localAccountRoot
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        guard FileManager.default.fileExists(atPath: binding.root.path) else { return .alreadyClean }
        do {
            try FileManager.default.removeItem(at: binding.root)
            return FileManager.default.fileExists(atPath: binding.root.path)
                ? .failed("account root remained after removal") : .done
        } catch { return .failed("account root removal failed: \(error)") }
    }
}

private struct LegacyPrivateDataSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.legacyPrivateData
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        .retainedByDesign(reason: "legacy private data is erased only when the durable migration marker proves ownership")
    }
}
private struct LegacyPairingSecretSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.legacyPairingSecret
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        .retainedByDesign(reason: "empty-account legacy secrets are removed only by the owner-proving legacy cleanup group")
    }
}
private struct DeletionTombstoneSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.deletionTombstone
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        .retainedByDesign(reason: "the completed deletion tombstone must survive the account-root wipe so a returning account can be admitted and provisioned again")
    }
}

private struct OmiPairingSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.omiPairing
    static func detachAccount(previous: CaptureAccountScope.AccountBinding?) -> AccountSurfaceOutcome {
        .retainedByDesign(
            reason: "sign-out suspends the wearable while retaining its saved pairing for the next sign-in")
    }
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        AccountSurfaceRuntime.clear(omiPairingKeys)
    }
}
private struct BatteryMonitoredDeviceSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.batteryMonitoredDevice
    static func detachAccount(previous: CaptureAccountScope.AccountBinding?) -> AccountSurfaceOutcome {
        AccountSurfaceRuntime.clear([BatteryMonitorStore.idKey, BatteryMonitorStore.nameKey])
    }
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        detachAccount(previous: binding)
    }
}
private struct CaptureSourceChoiceSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.captureSourceChoice
    static func detachAccount(previous: CaptureAccountScope.AccountBinding?) -> AccountSurfaceOutcome {
        AccountSurfaceRuntime.clear(["foundryx.capture.source"])
    }
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome { detachAccount(previous: binding) }
}
private struct UserAddedCaptureSourcesSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.userAddedCaptureSources
    static func detachAccount(previous: CaptureAccountScope.AccountBinding?) -> AccountSurfaceOutcome {
        AccountSurfaceRuntime.clear(["foundryx.capture.sources.added"])
    }
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome { detachAccount(previous: binding) }
}
private struct ActionButtonChoiceSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.actionButtonChoice
    static func detachAccount(previous: CaptureAccountScope.AccountBinding?) -> AccountSurfaceOutcome {
        AccountSurfaceRuntime.clear(["foundryx.action-button.choice"])
    }
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome { detachAccount(previous: binding) }
}
private struct BLECentralRestorationSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.bleCentralRestoration
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        .retainedByDesign(reason: "the CoreBluetooth restoration identifier contains no account data; clearing the saved peripheral prevents cross-account reconnect")
    }
}

private struct LiveActivitySurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.liveActivity
    static func detachAccount(previous: CaptureAccountScope.AccountBinding?) -> AccountSurfaceOutcome {
        AccountLiveActivityBoundary.endAll()
    }
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome {
        AccountLiveActivityBoundary.endAll()
    }
    /// Asking ActivityKit whether anything is running is a synchronous read.
    /// Ending them is not — see `AccountLiveActivityBoundary.endAll`.
    static func verifyAccountErased(
        _ binding: CaptureAccountScope.AccountBinding
    ) -> AccountSurfaceOutcome {
        AccountLiveActivityBoundary.verifyEnded()
    }
}

private struct InMemorySessionSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.inMemorySession
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome { .done }
}
private struct AppRootDerivedStateSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.appRootDerivedState
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome { .done }
}
private struct MainTabsSubtreeSurface: PassiveSurface {
    static let surfaceID = AccountSurfaceID.mainTabsSubtree
    static func eraseAccount(_ binding: CaptureAccountScope.AccountBinding) -> AccountSurfaceOutcome { .done }
}

enum AccountLiveActivityBoundary {
    #if DEBUG || PERF_HARNESS
    nonisolated(unsafe) static var endAllForTests: (() -> AccountSurfaceOutcome)?
    #endif

    static func endAll() -> AccountSurfaceOutcome {
        #if DEBUG || PERF_HARNESS
        if let endAllForTests { return endAllForTests() }
        #endif
        #if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.2, *) {
            let activities = Activity<CaptureActivityAttributes>.activities
            guard !activities.isEmpty else { return .alreadyClean }
            let finished = DispatchSemaphore(value: 0)
            nonisolated(unsafe) let handles = activities
            Task.detached {
                for handle in handles {
                    await handle.end(nil, dismissalPolicy: .immediate)
                }
                finished.signal()
            }
            return finished.wait(timeout: .now() + 5) == .success
                ? .done : .failed("Live Activity termination timed out")
        }
        #endif
        return .alreadyClean
    }

    /// The same question, asked without doing the work again. Reading
    /// `Activity.activities` does not await anything, so verification cannot
    /// block the deletion's own thread or time out.
    static func verifyEnded() -> AccountSurfaceOutcome {
        #if DEBUG || PERF_HARNESS
        if let endAllForTests { return endAllForTests() }
        #endif
        #if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.2, *) {
            return Activity<CaptureActivityAttributes>.activities.isEmpty
                ? .alreadyClean
                : .failed("a Live Activity for this account is still running")
        }
        #endif
        return .alreadyClean
    }
}
