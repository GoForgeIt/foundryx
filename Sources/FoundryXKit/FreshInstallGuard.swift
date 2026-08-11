import Foundation

// FreshInstallGuard — delete the app, reinstall, and you must be SIGNED OUT.
//
// iOS destroys an app's container (and with it every UserDefaults value) on
// uninstall. It deliberately does NOT destroy that app's Keychain items. So a
// delete-and-reinstall left FoundryX holding the previous person's identity: on
// TestFlight 771837 Nick deleted the app, reinstalled, and was still signed in as
// nickarinard@gmail.com. "Delete everything" followed by a full reinstall still
// left the identity on the device.
//
// For an app that holds capture audio and transcripts of real conversations that
// is data remanence, not a papercut. The asymmetry iOS gives us is also the
// detector: UserDefaults IS cleared and the Keychain IS NOT, so a marker in
// UserDefaults answers "did this install's container survive?".

/// What the launch check decided, and why. Every case is distinguishable so the
/// wrong branch cannot hide: signing users out on an ordinary launch would be a
/// far worse bug than the one this fixes.
public enum FreshInstallDisposition: Equatable, Sendable {
    /// The marker is present. The container survived, so this is an ordinary
    /// launch of an established install. NOTHING is read, purged or written.
    case establishedInstall
    /// The marker is absent but this install's UserDefaults still holds FoundryX
    /// state — so the container did NOT go away and this is an UPGRADE from a
    /// build that predates the marker. The marker is stamped; nothing is purged.
    /// Every existing install takes this path exactly once.
    case markerAdoptedByExistingInstall
    /// The container is genuinely new and the Keychain had nothing left over.
    case freshInstallNothingInherited
    /// The container is genuinely new and Keychain state from a PREVIOUS install
    /// was found and erased. `surfaces` are the ones that actually held something.
    case freshInstallPurged(surfaces: [AccountSurfaceID])
    /// The Keychain could not answer — most often a locked device on a background
    /// relaunch. The marker is deliberately NOT stamped, so the next launch asks
    /// again rather than leaving an inherited identity in place forever.
    case deferredUnreadableKeychain
    /// The purge could not be proved. The marker is NOT stamped, so the next
    /// launch retries; an unproved purge must never look like a finished one.
    case purgeFailed(String)
}

public enum FreshInstallGuard {
    /// Cleared by iOS on uninstall, which is the entire mechanism.
    static let installMarkerKey = "foundryx.install.marker.v1"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var launchDisposition:
        FreshInstallDisposition?

    /// The launch call. MUST run before anything reads auth state, or the app
    /// will have already published the inherited identity by the time it is
    /// erased. Idempotent: the answer is computed once per process.
    @discardableResult
    public static func runAtLaunch() -> FreshInstallDisposition {
        lock.lock()
        if let launchDisposition {
            lock.unlock()
            return launchDisposition
        }
        lock.unlock()
        let disposition = run(
            defaults: CaptureAccountScope.accountSurfaceDefaults,
            identityPresence: { AuthStore.identityPresence() },
            inheritedIdentity: { try? AuthStore.loadFallibly() },
            eraseSurfaces: { binding, defaults in
                AccountSurfaceRegistry.eraseAll(binding, defaults: defaults)
            },
            secretStore: SystemPairingSecretStore(),
            pairingServices: (
                cell: "com.goforgeit.foundryx.cell",
                door: DoorConfigStore.service),
            container: { CaptureAccountScope.container() })
        lock.lock()
        launchDisposition = disposition
        lock.unlock()
        return disposition
    }

    /// The decision, with every edge injected. `eraseSurfaces` is deliberately
    /// the WHOLE `AccountSurfaceRegistry` rather than a hand-written list of
    /// Keychain queries: the registry is the manifest of identity-bearing state,
    /// it is completeness-tested, and a surface added next year is covered here
    /// without anyone remembering to come back.
    static func run(
        defaults: UserDefaults,
        identityPresence: () -> AuthStore.IdentityPresence,
        inheritedIdentity: () -> AuthIdentity?,
        eraseSurfaces: (CaptureAccountScope.AccountBinding, UserDefaults)
            -> [AccountSurfaceID: AccountSurfaceOutcome],
        secretStore: any PairingSecretStore,
        pairingServices: (cell: String, door: String),
        container: () -> URL
    ) -> FreshInstallDisposition {
        guard defaults.object(forKey: installMarkerKey) == nil else {
            return .establishedInstall
        }
        // No marker is NOT the same as a fresh install. Every install that
        // predates this code also has no marker, and treating those as fresh
        // would sign the entire existing fleet out on the update that shipped
        // the fix. A container that still holds this app's own preferences
        // demonstrably survived, so it is an upgrade.
        guard !holdsPriorState(defaults) else {
            if let failure = stamp(defaults) { return failure }
            return .markerAdoptedByExistingInstall
        }

        switch identityPresence() {
        case .unreadableLocked, .unreadable:
            // "I cannot read the Keychain" is not "the Keychain is empty".
            // Stamping here would strand an inherited identity permanently.
            return .deferredUnreadableKeychain
        case .absent, .present:
            break
        }

        var purged: [AccountSurfaceID] = []
        if let identity = inheritedIdentity(),
           let scope = try? CaptureAccountScope.key(for: identity) {
            let binding = CaptureAccountScope.AccountBinding(
                root: container().appendingPathComponent(
                    scope, isDirectory: true),
                scope: scope,
                generation: CaptureAccountScope.identityGeneration)
            let outcomes = eraseSurfaces(binding, defaults)
            let failures = outcomes
                .filter { !$0.value.isTerminalSuccess }
                .sorted { $0.key.rawValue < $1.key.rawValue }
            guard failures.isEmpty else {
                return .purgeFailed(
                    failures.map { "\($0.key.rawValue)=\($0.value)" }
                        .joined(separator: ", "))
            }
            purged = outcomes.filter { $0.value == .done }.keys
                .sorted { $0.rawValue < $1.rawValue }
            // The pairing bearer secrets are Keychain items this app owns that
            // the registry deliberately retains (the deletion lifecycle removes
            // them through this same seam, after proving ownership). A fresh
            // container has no owner left to prove, so they go unconditionally.
            guard removePairingSecrets(
                secretStore, pairingServices, account: scope) else {
                return .purgeFailed("scoped pairing secrets survived the purge")
            }
        }
        // The pre-scope legacy pairing entries are keyed to an empty owner, so
        // they are swept whether or not an identity was left behind.
        guard removePairingSecrets(
            secretStore, pairingServices, account: "") else {
            return .purgeFailed("legacy pairing secrets survived the purge")
        }

        if let failure = stamp(defaults) { return failure }
        return purged.isEmpty
            ? .freshInstallNothingInherited
            : .freshInstallPurged(surfaces: purged)
    }

    /// Any FoundryX-owned value at all. Account-scoped keys are prefixed with the
    /// `acct-` scope, so both shapes count.
    private static func holdsPriorState(_ defaults: UserDefaults) -> Bool {
        defaults.dictionaryRepresentation().keys.contains { key in
            key.contains("foundryx") || key.hasPrefix("acct-")
        }
    }

    /// Returns a failure disposition, or nil when the marker is durable.
    private static func stamp(
        _ defaults: UserDefaults
    ) -> FreshInstallDisposition? {
        defaults.set(true, forKey: installMarkerKey)
        guard defaults.synchronize(),
              defaults.object(forKey: installMarkerKey) != nil else {
            return .purgeFailed("the install marker was not durable")
        }
        return nil
    }

    private static func removePairingSecrets(
        _ store: any PairingSecretStore,
        _ services: (cell: String, door: String),
        account: String
    ) -> Bool {
        [services.cell, services.door].allSatisfy {
            store.removeExplicitOwner(service: $0, account: account).succeeded
        }
    }

    #if DEBUG || PERF_HARNESS
    static func resetLaunchDispositionForTests() {
        lock.withLock { launchDisposition = nil }
    }
    #endif
}
