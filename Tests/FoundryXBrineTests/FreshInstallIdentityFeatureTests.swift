import XCTest
@testable import FoundryXKit
import BrineSwiftCore

/// `features/fresh-install-does-not-inherit-an-identity.feature`.
///
/// The device keychain is the ONE injected edge (a hostless test has no keychain
/// entitlement, and the repo already treats it as a seam — see
/// `PairingSecretStore`). Everything else is production code: the real
/// `FreshInstallGuard`, the real `AccountSurfaceRegistry.eraseAll`, the real
/// `AuthStore.eraseIdentityCredential` erase path, and the real
/// `FoundryAuth.hasPersistedSignIn` reader for "am I still signed in?".
final class FreshInstallIdentityFeatureTests: XCTestCase {
    fileprivate final class World: @unchecked Sendable {
        var fixture: FreshInstallFixture?
        var disposition: FreshInstallDisposition?

        func require() throws -> FreshInstallFixture {
            guard let fixture else {
                throw BrineStepError("no fresh-install fixture was prepared")
            }
            return fixture
        }

        /// Each scenario opens with exactly one seeding step, and that step gets a
        /// brand-new device: a fixture shared across scenarios would carry the
        /// previous scenario's erase log and make "nothing is erased" a lie.
        func reset() throws -> FreshInstallFixture {
            fixture?.cleanup()
            disposition = nil
            let made = try FreshInstallFixture()
            fixture = made
            return made
        }
    }

    func testFreshInstallIdentityScenarios() async throws {
        let world = World()
        defer { world.fixture?.cleanup() }

        try await BrineFeatureRunner.run(
            "fresh-install-does-not-inherit-an-identity",
            registry: StepRegistry([
                defineStep("a sign-in credential from a previous install is still on this device") { ctx, _, _ in
                    let fixture = try world.reset()
                    fixture.keychain.seedPreviousInstall()
                    return ctx
                },
                defineStep("this is the first launch after installing the app") { ctx, _, _ in
                    // A reinstall gets an EMPTY container: no marker, and no
                    // FoundryX preference of any kind.
                    let fixture = try world.require()
                    fixture.emptyTheContainer()
                    return ctx
                },
                defineStep("the device is locked so the keychain cannot answer") { ctx, _, _ in
                    let fixture = try world.require()
                    fixture.keychain.isLocked = true
                    return ctx
                },
                defineStep("I signed in on a previous launch of this same install") { ctx, _, _ in
                    let fixture = try world.reset()
                    fixture.keychain.seedPreviousInstall()
                    try fixture.signInOnThisInstall()
                    fixture.stampInstallMarker()
                    return ctx
                },
                defineStep("I signed in on a build that predates the first-launch check") { ctx, _, _ in
                    // Identical state MINUS the marker: the container survived
                    // the update, but nothing ever wrote the marker into it.
                    let fixture = try world.reset()
                    fixture.keychain.seedPreviousInstall()
                    try fixture.signInOnThisInstall()
                    return ctx
                },
                defineStep("the app checks for an inherited identity at launch") { ctx, _, _ in
                    let fixture = try world.require()
                    world.disposition = fixture.runLaunchCheck()
                    return ctx
                },
                defineCheck("the inherited sign-in credential is gone from the device") { _, _, _ in
                    let fixture = try world.require()
                    guard fixture.keychain.identity == nil else {
                        throw BrineStepError(
                            "a reinstall inherited the previous account: \(String(describing: fixture.keychain.identity?.email))")
                    }
                    guard case .freshInstallPurged(let surfaces)? = world.disposition,
                          surfaces.contains(.keychainIdentity) else {
                        throw BrineStepError(
                            "the identity surface was not reported as purged: \(String(describing: world.disposition))")
                    }
                },
                defineCheck("the device is recorded as signed out") { _, _, _ in
                    let fixture = try world.require()
                    guard fixture.defaults.object(
                        forKey: AuthStore.signedInMirrorKey) as? Bool == false else {
                        throw BrineStepError(
                            "the signed-in mirror was not driven to false")
                    }
                    guard !FoundryAuth.hasPersistedSignIn else {
                        throw BrineStepError(
                            "a reinstalled app still reports a persisted sign-in")
                    }
                },
                defineCheck("the previous install's pairing secrets are gone from the device") { _, _, _ in
                    let fixture = try world.require()
                    guard fixture.keychain.pairingSecrets.isEmpty else {
                        throw BrineStepError(
                            "pairing secrets survived the reinstall: \(fixture.keychain.pairingSecrets.keys.sorted())")
                    }
                },
                defineCheck("nothing is erased") { _, _, _ in
                    let fixture = try world.require()
                    guard fixture.erasedSurfaces.isEmpty else {
                        throw BrineStepError(
                            "an ordinary launch erased account surfaces: \(fixture.erasedSurfaces)")
                    }
                    guard fixture.keychain.identity != nil else {
                        throw BrineStepError(
                            "an ordinary launch removed the sign-in credential")
                    }
                    guard !fixture.keychain.pairingSecrets.isEmpty else {
                        throw BrineStepError(
                            "an ordinary launch removed the pairing secrets")
                    }
                },
                defineCheck("the app recognised this install without inspecting the keychain") { _, _, _ in
                    let fixture = try world.require()
                    guard world.disposition == .establishedInstall else {
                        throw BrineStepError(
                            "a marked install was not recognised as established: \(String(describing: world.disposition))")
                    }
                    guard fixture.keychainReads == 0 else {
                        throw BrineStepError(
                            "an ordinary launch read the keychain \(fixture.keychainReads) time(s) before showing the app")
                    }
                },
                defineCheck("this install is recorded so the check settles for good") { _, _, _ in
                    let fixture = try world.require()
                    guard world.disposition == .markerAdoptedByExistingInstall else {
                        throw BrineStepError(
                            "an upgrade was not adopted: \(String(describing: world.disposition))")
                    }
                    guard fixture.defaults.object(
                        forKey: FreshInstallGuard.installMarkerKey) != nil else {
                        throw BrineStepError(
                            "the upgrade left no marker, so every later launch re-decides this")
                    }
                    guard fixture.runLaunchCheck() == .establishedInstall else {
                        throw BrineStepError(
                            "the launch after an adopted upgrade did not settle")
                    }
                },
                defineCheck("I am still signed in") { _, _, _ in
                    guard FoundryAuth.hasPersistedSignIn else {
                        throw BrineStepError(
                            "an ordinary launch signed the person out")
                    }
                },
                defineCheck("the inherited sign-in credential is still on the device") { _, _, _ in
                    let fixture = try world.require()
                    guard fixture.keychain.identity != nil else {
                        throw BrineStepError(
                            "an unreadable keychain was treated as an empty one")
                    }
                },
                defineCheck("the check runs again on the next launch") { _, _, _ in
                    let fixture = try world.require()
                    guard world.disposition == .deferredUnreadableKeychain else {
                        throw BrineStepError(
                            "a locked keychain was not deferred: \(String(describing: world.disposition))")
                    }
                    guard fixture.defaults.object(
                        forKey: FreshInstallGuard.installMarkerKey) == nil else {
                        throw BrineStepError(
                            "a deferred check stamped the marker, so it will never run again")
                    }
                    // Prove it by unlocking and re-running: the second launch
                    // must do the purge the first one could not.
                    fixture.keychain.isLocked = false
                    guard case .freshInstallPurged = fixture.runLaunchCheck(),
                          fixture.keychain.identity == nil else {
                        throw BrineStepError(
                            "the next launch did not purge the inherited identity")
                    }
                },
            ]))
    }
}

/// The device keychain, as the app sees it: survives an uninstall, can refuse to
/// answer while locked, and is the only thing the guard cannot reach in a test.
fileprivate final class DeviceKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var storedIdentity: AuthIdentity?
    private var secrets: [String: String] = [:]
    private var locked = false

    var isLocked: Bool {
        get { lock.withLock { locked } }
        set { lock.withLock { locked = newValue } }
    }

    var identity: AuthIdentity? { lock.withLock { storedIdentity } }
    var pairingSecrets: [String: String] { lock.withLock { secrets } }

    func seedPreviousInstall() {
        lock.withLock {
            storedIdentity = AuthIdentity(
                provider: AuthProvider.google.rawValue,
                idToken: FreshInstallFixture.token(subject: "previous-owner"),
                refreshToken: nil,
                expiresAt: .distantFuture,
                email: "previous-owner@example.test")
            secrets["com.goforgeit.foundryx.cell|"] = "legacy-cell-bearer"
            secrets["com.goforgeit.foundryx.door|"] = "legacy-door-bearer"
        }
    }

    /// Counted so an "ordinary launch" can assert the guard did not even LOOK —
    /// the cheapest possible proof that it took the established-install path.
    private(set) var reads = 0

    func presence() -> AuthStore.IdentityPresence {
        lock.withLock {
            reads += 1
            if locked { return .unreadableLocked }
            return storedIdentity == nil ? .absent : .present
        }
    }

    func load() -> AuthIdentity? {
        lock.withLock {
            reads += 1
            return locked ? nil : storedIdentity
        }
    }

    func eraseIdentity() -> AccountSurfaceOutcome {
        lock.withLock {
            guard storedIdentity != nil else { return .alreadyClean }
            storedIdentity = nil
            return .done
        }
    }

    func removeSecret(service: String, account: String) -> Bool {
        lock.withLock {
            secrets.removeValue(forKey: "\(service)|\(account)")
            return true
        }
    }
}

fileprivate struct DeviceKeychainSecretStore: PairingSecretStore {
    let keychain: DeviceKeychain

    func read(service: String, account: String) -> String? {
        keychain.pairingSecrets["\(service)|\(account)"]
    }
    func inspect(service: String, account: String) -> PairingSecretReadResult {
        read(service: service, account: account).map { .found($0) } ?? .notFound
    }
    func update(
        _ value: String, service: String, account: String
    ) -> PairingSecretUpdateResult { .notFound }
    func add(_ value: String, service: String, account: String) -> Bool { false }
    func remove(service: String, account: String) -> Bool {
        keychain.removeSecret(service: service, account: account)
    }
    func removeExplicitOwner(
        service: String, account: String
    ) -> PairingSecretRemovalResult {
        keychain.removeSecret(service: service, account: account)
            ? .removed : .failed
    }
}

fileprivate final class FreshInstallFixture: @unchecked Sendable {
    let root: URL
    let defaultsName: String
    let defaults: UserDefaults
    let keychain = DeviceKeychain()
    private let observed = ErasedSurfaceLog()

    var erasedSurfaces: [AccountSurfaceID] { observed.surfaces }
    var keychainReads: Int { keychain.reads }

    init() throws {
        let discriminator = UUID().uuidString.lowercased()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foundryx-fresh-install-\(discriminator)", isDirectory: true)
        defaultsName = "foundryx.fresh-install.\(discriminator)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        CaptureAccountScope.resetTestEnvironment()
        CaptureAccountScope.setContainerForTests(root)
        CaptureAccountScope.setDefaultsForTests(defaults)
        CaptureWidgetSnapshotStore.setDefaultsForTesting(defaults)
        AccountLiveActivityBoundary.endAllForTests = { .alreadyClean }
        let keychain = self.keychain
        AuthStore.setIdentityEraseForTests { keychain.eraseIdentity() }
        FreshInstallGuard.resetLaunchDispositionForTests()
    }

    static func token(subject: String) -> String {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8)
        let payload = Data(#"{"sub":"\#(subject)"}"#.utf8)
        return [header, payload].map {
            $0.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }.joined(separator: ".") + ".test-signature"
    }

    /// A reinstall gets a brand-new container: iOS threw the old one away.
    func emptyTheContainer() {
        defaults.removePersistentDomain(forName: defaultsName)
        CaptureAccountScope.resetProcessCacheForTests()
    }

    /// Real activation, so `FoundryAuth.hasPersistedSignIn` answers for real.
    func signInOnThisInstall() throws {
        try CaptureAccountScope.activateForTests(
            try XCTUnwrap(keychain.identity))
    }

    func stampInstallMarker() {
        defaults.set(true, forKey: FreshInstallGuard.installMarkerKey)
    }

    func runLaunchCheck() -> FreshInstallDisposition {
        let keychain = self.keychain
        let observed = self.observed
        return FreshInstallGuard.run(
            defaults: defaults,
            identityPresence: { keychain.presence() },
            inheritedIdentity: { keychain.load() },
            eraseSurfaces: { binding, defaults in
                let outcomes = AccountSurfaceRegistry.eraseAll(
                    binding, defaults: defaults)
                observed.record(
                    outcomes.filter { $0.value == .done }.keys)
                return outcomes
            },
            secretStore: DeviceKeychainSecretStore(keychain: keychain),
            pairingServices: (
                cell: "com.goforgeit.foundryx.cell",
                door: "com.goforgeit.foundryx.door"),
            container: { self.root })
    }

    func cleanup() {
        AuthStore.setIdentityEraseForTests(nil)
        AccountLiveActivityBoundary.endAllForTests = nil
        CaptureWidgetSnapshotStore.resetDefaultsForTesting()
        CaptureAccountScope.resetTestEnvironment()
        FreshInstallGuard.resetLaunchDispositionForTests()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ErasedSurfaceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AccountSurfaceID] = []

    func record<S: Sequence>(_ ids: S) where S.Element == AccountSurfaceID {
        lock.withLock { storage.append(contentsOf: ids) }
    }

    var surfaces: [AccountSurfaceID] {
        lock.withLock { storage.sorted { $0.rawValue < $1.rawValue } }
    }
}
