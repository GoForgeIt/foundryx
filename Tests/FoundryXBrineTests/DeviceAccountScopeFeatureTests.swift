import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for `features/device-account-scope.feature` (track
/// 20260725T2306_device_agnostic_recording_source, task T2).
///
/// The account scope, the roots, and the files are the PRODUCTION ones: the world installs
/// a sandboxed container under `CaptureAccountScope.setContainerForTests` and then signs
/// accounts in and out through the real activation path. Only the account SECRET is
/// injected, because the keychain is not readable in a hostless iOS test bundle.
final class DeviceAccountScopeFeatureTests: XCTestCase {

    func testDeviceAccountScopeFeature() async throws {
        let world = try DeviceAccountScopeWorld()
        do {
            try await BrineFeatureRunner.run(
                "device-account-scope",
                registry: StepRegistry(DeviceAccountScopeSteps.make(world: world)))
        } catch {
            world.cleanup()
            throw error
        }
        world.cleanup()
    }

    // MARK: unit — the reference is keyed on the account SECRET, never on the scope name

    /// The scope name (`acct-<fnv hash of the account key material>`) is derivable from an
    /// email address, so keying the reference on it would make every account's device
    /// references computable by anyone who can guess the address. The reference must move
    /// when the SECRET moves and must not be reproducible from the scope name.
    func testDeviceRefIsKeyedOnTheAccountSecret() {
        let identity = RecordingDeviceIdentity(shape: .bleStream, hardwareToken: "peripheral-1")
        let first = DeviceRefDerivation.ref(for: identity, accountKeyMaterial: "google|sub|alice")
        let second = DeviceRefDerivation.ref(for: identity, accountKeyMaterial: "google|sub|bob")
        XCTAssertNotEqual(first, second, "the same device produced the same reference for two accounts")
        XCTAssertEqual(first, DeviceRefDerivation.ref(for: identity, accountKeyMaterial: "google|sub|alice"),
                       "the reference is not stable for one account")

        // A fixed or scope-derived key would make this equal.
        let scopeName = CaptureAccountScope.key(forAccountKeyMaterial: "google|sub|alice")
        XCTAssertNotEqual(first, DeviceRefDerivation.ref(for: identity, accountKeyMaterial: scopeName),
                          "the reference is reproducible from the enumerable scope name")

        // Different devices under one account must differ, or the ref would identify only
        // the account and nothing about which device is speaking.
        let other = RecordingDeviceIdentity(shape: .audioRoute, hardwareToken: "route-9")
        XCTAssertNotEqual(first, DeviceRefDerivation.ref(for: other, accountKeyMaterial: "google|sub|alice"))

        // Domain separation: the same secret used for another purpose must not collide.
        XCTAssertFalse(DeviceRefDerivation.domain.isEmpty)
        XCTAssertFalse(first.hex.isEmpty)
        XCTAssertTrue(first.hex.allSatisfy(\.isHexDigit), "the reference is not opaque hex: \(first.hex)")
    }

    /// Active selection must not be able to see the shape at all. Permuting the shapes of
    /// a remembered set — while holding preference, readiness, and last-connected fixed —
    /// may never change who is active.
    func testActiveSelectionIsInvariantUnderShape() {
        let tokens = ["a", "b", "c"]
        var seen: Set<String> = []
        for shapes in permutations(of: RecordingDeviceShape.allCases) {
            let records = zip(tokens, shapes).map { token, shape in
                RecordingDeviceRecord(
                    identity: RecordingDeviceIdentity(shape: shape, hardwareToken: token),
                    displayName: "Device \(token)",
                    lastConnected: Date(timeIntervalSinceReferenceDate: 1000),
                    userDetached: false,
                    userPreferred: token == "b")
            }
            let ready = Set(records.map(\.identity))
            let active = RecordingDeviceActivation.active(among: records, ready: ready)
            seen.insert(active?.identity.hardwareToken ?? "none")
        }
        XCTAssertEqual(seen, ["b"], "active selection moved with the device shape: \(seen)")
    }

    private func permutations<T>(of items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        var out: [[T]] = []
        for (index, item) in items.enumerated() {
            var rest = items
            rest.remove(at: index)
            for tail in permutations(of: rest) { out.append([item] + tail) }
        }
        return out
    }
}

// MARK: - World

final class DeviceAccountScopeWorld: @unchecked Sendable {
    let token = UUID().uuidString.lowercased()
    let sandbox: URL
    let container: URL
    let defaults: UserDefaults
    let scopeDefaults: UserDefaults
    private let defaultsName: String
    private let scopeDefaultsName: String

    /// Injected account secret per email — the keychain is unreadable in a hostless iOS
    /// test bundle, so the SECRET (and only the secret) is supplied here.
    final class FixtureKeyMaterial: AccountKeyMaterialProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        init(_ value: String?) { self.value = value }
        var material: String? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
        func accountKeyMaterial() -> String? { material }
    }

    let keyMaterial = FixtureKeyMaterial(nil)
    var emissions: [String: DeviceStatusEmission] = [:]
    var lastEmission: DeviceStatusEmission?
    var refsAcrossRelaunch: [String: [DeviceRef]] = [:]
    var readyIdentities: Set<RecordingDeviceIdentity> = []
    var lastActive: RecordingDeviceRecord?
    var legacyIdentity: RecordingDeviceIdentity?
    var holdOutcome: RecordingDeviceHoldOutcome?
    var migrationOutcome: RecordingDeviceMigrationOutcome?

    static let legacyPeripheralID = "1D0C93A0-2E6A-4E8E-9E2B-0C0B0A090807"
    static let legacyDeviceName = "Trail Mic"

    init() throws {
        let token = self.token
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-device-account-scope-\(token)", isDirectory: true)
        container = sandbox.appendingPathComponent("documents/foundryx-captures", isDirectory: true)
        defaultsName = "foundryx.device-account-scope.legacy.\(token)"
        scopeDefaultsName = "foundryx.device-account-scope.scope.\(token)"
        guard let defaults = UserDefaults(suiteName: defaultsName),
              let scopeDefaults = UserDefaults(suiteName: scopeDefaultsName) else {
            throw BrineStepError("could not create isolated UserDefaults suites")
        }
        self.defaults = defaults
        self.scopeDefaults = scopeDefaults
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        CaptureAccountScope.setContainerForTests(container)
        CaptureAccountScope.setApplicationSupportRootForTests(
            sandbox.appendingPathComponent("application-support", isDirectory: true))
        CaptureAccountScope.setDefaultsForTests(scopeDefaults)
    }

    func cleanup() {
        try? CaptureAccountScope.signOutForTests()
        CaptureAccountScope.resetTestEnvironment()
        defaults.removePersistentDomain(forName: defaultsName)
        scopeDefaults.removePersistentDomain(forName: scopeDefaultsName)
        try? FileManager.default.removeItem(at: sandbox)
    }

    func email(_ label: String) -> String { "\(label)-\(token)@example.com" }

    func signIn(_ label: String) throws {
        CaptureAccountScope.setAccountForTests(email: email(label))
        keyMaterial.material = "google|email|\(email(label))"
        guard CaptureAccountScope.currentAccountBinding()?.scope
                != CaptureAccountScope.signedOutScope else {
            throw BrineStepError("signing in \(label) did not leave the signed-out scope")
        }
    }

    func signOut() throws {
        try CaptureAccountScope.signOutForTests()
        keyMaterial.material = nil
    }

    func store() throws -> RecordingDeviceStore {
        guard let store = RecordingDeviceStore.current() else {
            throw BrineStepError("no recording-device store resolved for the current account")
        }
        return store
    }

    /// Stage the shipped DEVICE-GLOBAL pairing exactly as `DeviceManager.setSaved` writes it.
    func stageLegacyPairing() {
        defaults.set(Self.legacyPeripheralID, forKey: DeviceManager.savedKey)
        defaults.set(Self.legacyDeviceName, forKey: DeviceManager.savedNameKey)
        defaults.set(Date().timeIntervalSinceReferenceDate, forKey: DeviceManager.savedDateKey)
        legacyIdentity = RecordingDeviceIdentity(shape: .bleStream,
                                                 hardwareToken: Self.legacyPeripheralID)
    }

    var legacyPairingStillPresent: Bool {
        defaults.string(forKey: DeviceManager.savedKey) == Self.legacyPeripheralID
    }

    func remember(_ name: String, shape: RecordingDeviceShape = .bleStream) throws -> RecordingDeviceRecord {
        let record = RecordingDeviceRecord(
            identity: RecordingDeviceIdentity(shape: shape, hardwareToken: "hw-\(name)"),
            displayName: name,
            lastConnected: Date(timeIntervalSinceReferenceDate: 1000))
        return try store().upsert(record)
    }

    func record(named name: String) throws -> RecordingDeviceRecord {
        guard let found = try store().records().first(where: { $0.displayName == name }) else {
            throw BrineStepError("no remembered device named \(name) in "
                                 + "\((try? store().records().map(\.displayName)) ?? [])")
        }
        return found
    }

    func recomputeActive() throws {
        lastActive = RecordingDeviceActivation.active(among: try store().records(),
                                                      ready: readyIdentities)
    }
}

enum DeviceAccountScopeSteps {

    static func make(world: DeviceAccountScopeWorld) -> [StepDefinition] {
        [
            // ── signed-out hold + legacy migration ───────────────────────────
            defineStep("a legacy device is paired and no account is signed in during upgrade") { ctx, _, _ in
                try world.signOut()
                world.stageLegacyPairing()
                let store = try world.store()
                guard store.isSignedOutScope else {
                    throw BrineStepError("upgrade resolved scope \(store.scope), expected the signed-out scope")
                }
                world.migrationOutcome = try RecordingDeviceMigration.adoptLegacyPairing(
                    defaults: world.defaults, into: store)
                return ctx
            },
            defineCheck("the device is retained without assignment to an account") { _, _, _ in
                let store = try world.store()
                guard store.isSignedOutScope else {
                    throw BrineStepError("the hold is in scope \(store.scope), not the signed-out scope")
                }
                let names = try store.records().map(\.displayName)
                guard names == [DeviceAccountScopeWorld.legacyDeviceName] else {
                    throw BrineStepError("the signed-out hold holds \(names)")
                }
                // "Without assignment to an account" is only meaningful if no account
                // scope holds it. Nothing has signed in yet, so no account directory may
                // contain a device file at all.
                let contents = (try? FileManager.default.contentsOfDirectory(
                    atPath: world.container.path)) ?? []
                let accountDirs = contents.filter {
                    $0.hasPrefix("acct-") && $0 != CaptureAccountScope.signedOutScope
                }
                for dir in accountDirs {
                    let file = world.container.appendingPathComponent(dir)
                        .appendingPathComponent("recording-devices.json")
                    guard !FileManager.default.fileExists(atPath: file.path) else {
                        throw BrineStepError("the hold was assigned to account scope \(dir)")
                    }
                }
            },
            defineStep("its owner signs in") { ctx, _, _ in
                try world.signIn("owner")
                world.holdOutcome = try RecordingDeviceHold.adopt(
                    into: try world.store(), container: world.container)
                return ctx
            },
            defineCheck("the device is restored without a physical re-pair") { _, _, _ in
                let store = try world.store()
                guard !store.isSignedOutScope else {
                    throw BrineStepError("still in the signed-out scope after sign-in")
                }
                let names = try store.records().map(\.displayName)
                guard names == [DeviceAccountScopeWorld.legacyDeviceName] else {
                    throw BrineStepError("after sign-in the account remembers \(names)")
                }
                guard case .adopted(let identities)? = world.holdOutcome,
                      identities == [world.legacyIdentity].compactMap({ $0 }) else {
                    throw BrineStepError("hold adoption reported \(String(describing: world.holdOutcome))")
                }
                // A "restore" that made the owner pair again would show up as the legacy
                // pairing having been consumed or the hardware token having changed.
                guard try world.record(named: DeviceAccountScopeWorld.legacyDeviceName)
                        .identity.hardwareToken == DeviceAccountScopeWorld.legacyPeripheralID else {
                    throw BrineStepError("the restored device has a different hardware identity")
                }
            },

            // ── account isolation ────────────────────────────────────────────
            defineStep("account {string} is signed in and has remembered a device named {string}") { ctx, p, _ in
                try world.signIn(try p.requireString(0))
                _ = try world.remember(try p.requireString(1))
                return ctx
            },
            defineStep("account {string} is signed in") { ctx, p, _ in
                try world.signIn(try p.requireString(0))
                return ctx
            },
            defineStep("account {string} signs in on the same handset") { ctx, p, _ in
                try world.signIn(try p.requireString(0))
                return ctx
            },
            defineStep("account {string} signs back in") { ctx, p, _ in
                try world.signIn(try p.requireString(0))
                return ctx
            },
            defineCheck("the second account remembers no devices") { _, _, _ in
                let names = try world.store().records().map(\.displayName)
                guard names.isEmpty else {
                    throw BrineStepError("the second account can see \(names)")
                }
            },
            defineCheck("the second account cannot make {string} active") { _, p, _ in
                let name = try p.requireString(0)
                let records = try world.store().records()
                let ready = Set(records.map(\.identity))
                let active = RecordingDeviceActivation.active(among: records, ready: ready)
                guard active?.displayName != name else {
                    throw BrineStepError("the second account activated \(name)")
                }
                // The activation function itself must not be trivially nil-returning, or
                // this check could never fail. Prove it can activate its OWN device.
                let own = RecordingDeviceRecord(
                    identity: RecordingDeviceIdentity(shape: .bleStream, hardwareToken: "own"),
                    displayName: "Own Device",
                    lastConnected: Date(timeIntervalSinceReferenceDate: 10))
                guard RecordingDeviceActivation.active(among: [own], ready: [own.identity]) != nil else {
                    throw BrineStepError("activation returns nil for everything — the check is vacuous")
                }
            },
            defineCheck("it still remembers {string}") { _, p, _ in
                _ = try world.record(named: try p.requireString(0))
            },

            // ── migration idempotence ────────────────────────────────────────
            defineStep("a legacy device pairing is present in the shipped device-global defaults") { ctx, _, _ in
                world.stageLegacyPairing()
                return ctx
            },
            defineStep("the legacy pairing is adopted") { ctx, _, _ in
                world.migrationOutcome = try RecordingDeviceMigration.adoptLegacyPairing(
                    defaults: world.defaults, into: try world.store())
                return ctx
            },
            defineStep("the legacy pairing is adopted again") { ctx, _, _ in
                world.migrationOutcome = try RecordingDeviceMigration.adoptLegacyPairing(
                    defaults: world.defaults, into: try world.store())
                guard world.migrationOutcome == .alreadyAdopted else {
                    throw BrineStepError(
                        "a second adoption reported \(String(describing: world.migrationOutcome))")
                }
                return ctx
            },
            defineCheck("the account remembers exactly one device") { _, _, _ in
                let names = try world.store().records().map(\.displayName)
                guard names.count == 1 else { throw BrineStepError("the account remembers \(names)") }
            },
            defineCheck("the shipped device-global pairing is still present") { _, _, _ in
                guard world.legacyPairingStillPresent else {
                    throw BrineStepError("migration deleted the shipped device-global pairing")
                }
            },

            // ── detach persistence ───────────────────────────────────────────
            defineStep("the device is ready") { ctx, _, _ in
                world.readyIdentities = Set(try world.store().records().map(\.identity))
                try world.recomputeActive()
                return ctx
            },
            defineCheck("it is the active device") { _, _, _ in
                try world.recomputeActive()
                guard world.lastActive != nil else { throw BrineStepError("no device is active") }
            },
            defineStep("I detach {string} myself") { ctx, p, _ in
                try world.store().detach(try world.record(named: try p.requireString(0)).identity)
                try world.recomputeActive()
                return ctx
            },
            defineCheck("no device is active") { _, _, _ in
                try world.recomputeActive()
                guard world.lastActive == nil else {
                    throw BrineStepError("\(world.lastActive!.displayName) is active")
                }
            },
            defineStep("the app relaunches and the device is ready again") { ctx, _, _ in
                // A relaunch is a NEW store over the same durable root, plus the radio
                // reporting the device present again — the exact combination that must
                // not resurrect a user detach.
                CaptureAccountScope.resetProcessCacheForTests()
                world.readyIdentities = Set(try world.store().records().map(\.identity))
                try world.recomputeActive()
                return ctx
            },
            defineStep("I reconnect {string} myself") { ctx, p, _ in
                try world.store().reconnect(try world.record(named: try p.requireString(0)).identity)
                try world.recomputeActive()
                return ctx
            },

            // ── preference and readiness, never vendor ───────────────────────
            defineStep("two remembered devices {string} and {string} are both ready") { ctx, p, _ in
                _ = try world.remember(try p.requireString(0), shape: .audioRoute)
                _ = try world.remember(try p.requireString(1), shape: .bleStream)
                world.readyIdentities = Set(try world.store().records().map(\.identity))
                return ctx
            },
            defineStep("I have chosen {string}") { ctx, p, _ in
                try world.store().prefer(try world.record(named: try p.requireString(0)).identity)
                try world.recomputeActive()
                return ctx
            },
            defineCheck("swapping which device is the BLE one does not change the active device") { _, _, _ in
                let records = try world.store().records()
                let swapped = records.map { record in
                    RecordingDeviceRecord(
                        identity: RecordingDeviceIdentity(
                            shape: record.identity.shape == .bleStream ? .audioRoute : .bleStream,
                            hardwareToken: record.identity.hardwareToken),
                        displayName: record.displayName,
                        lastConnected: record.lastConnected,
                        userDetached: record.userDetached,
                        userPreferred: record.userPreferred)
                }
                // The experiment must actually have swapped something, and the two devices
                // must genuinely have had DIFFERENT shapes, or "shape does not matter" is
                // being claimed over a set where shape never varied.
                guard Set(records.map(\.identity.shape)).count == 2,
                      zip(records, swapped).allSatisfy({ $0.identity.shape != $1.identity.shape }) else {
                    throw BrineStepError(
                        "the swap experiment is vacuous: shapes were \(records.map(\.identity.shape))")
                }
                let readySwapped = Set(swapped.map(\.identity))
                let after = RecordingDeviceActivation.active(among: swapped, ready: readySwapped)
                guard after?.displayName == world.lastActive?.displayName else {
                    throw BrineStepError(
                        "swapping the shapes moved the active device from "
                            + "\(world.lastActive?.displayName ?? "none") to \(after?.displayName ?? "none")")
                }
            },
            defineStep("{string} stops being ready") { ctx, p, _ in
                let identity = try world.record(named: try p.requireString(0)).identity
                world.readyIdentities.remove(identity)
                try world.recomputeActive()
                return ctx
            },
            defineCheck("{string} is the active device") { _, p, _ in
                let name = try p.requireString(0)
                try world.recomputeActive()
                guard world.lastActive?.displayName == name else {
                    throw BrineStepError("active is \(world.lastActive?.displayName ?? "none"), expected \(name)")
                }
            },
            defineCheck("at most one device is active") { _, _, _ in
                let records = try world.store().records()
                let actives = records.filter {
                    RecordingDeviceActivation.active(among: records, ready: world.readyIdentities)?
                        .identity == $0.identity
                }
                guard actives.count <= 1 else {
                    throw BrineStepError("\(actives.count) devices are active")
                }
                guard records.count >= 2 else {
                    throw BrineStepError("only \(records.count) device(s) remembered — the claim is vacuous")
                }
            },

            // ── privacy reference ────────────────────────────────────────────
            defineStep("no account secret is available") { ctx, _, _ in
                world.keyMaterial.material = nil
                return ctx
            },
            defineStep("device status is prepared for the handoff") { ctx, _, _ in
                world.lastEmission = DeviceRefDerivation.emission(
                    for: RecordingDeviceIdentity(shape: .bleStream, hardwareToken: "hw-Trail Mic"),
                    keyMaterial: world.keyMaterial)
                return ctx
            },
            defineCheck("no outbound device reference is produced") { _, _, _ in
                guard case .withheld = world.lastEmission else {
                    throw BrineStepError("an outbound reference was produced: "
                                         + "\(String(describing: world.lastEmission))")
                }
            },
            defineCheck("the withheld reason is recorded as {string}") { _, p, _ in
                let expected = try p.requireString(0)
                guard case .withheld(let reason)? = world.lastEmission,
                      reason.rawValue == expected else {
                    throw BrineStepError("withheld reason is \(String(describing: world.lastEmission))")
                }
            },
            defineCheck("the same preparation does produce a reference once an account secret exists") { _, _, _ in
                // Without this control, "no reference was produced" is satisfied by an
                // emitter that can never produce one — the check would be unfailable.
                world.keyMaterial.material = "google|sub|control-\(world.token)"
                let emission = DeviceRefDerivation.emission(
                    for: RecordingDeviceIdentity(shape: .bleStream, hardwareToken: "hw-Trail Mic"),
                    keyMaterial: world.keyMaterial)
                world.keyMaterial.material = nil
                guard case .emit(let ref) = emission, !ref.hex.isEmpty else {
                    throw BrineStepError(
                        "with a secret present the emitter still produced \(emission) — "
                            + "the withheld assertion above proves nothing")
                }
            },
            defineStep("the same physical device is remembered by two different accounts") { ctx, _, _ in
                world.emissions = [:]
                world.refsAcrossRelaunch = [:]
                for label in ["alpha", "beta"] {
                    try world.signIn(label)
                    _ = try world.remember("Trail Mic")
                }
                return ctx
            },
            defineStep("device status is prepared for each account") { ctx, _, _ in
                let identity = RecordingDeviceIdentity(shape: .bleStream, hardwareToken: "hw-Trail Mic")
                for label in ["alpha", "beta"] {
                    try world.signIn(label)
                    var refs: [DeviceRef] = []
                    for _ in 0..<2 {
                        // "Across relaunch": the process cache is dropped and the ref is
                        // derived again from the durable account secret.
                        CaptureAccountScope.resetProcessCacheForTests()
                        let emission = DeviceRefDerivation.emission(
                            for: identity, keyMaterial: world.keyMaterial)
                        world.emissions[label] = emission
                        if case .emit(let ref) = emission { refs.append(ref) }
                    }
                    world.refsAcrossRelaunch[label] = refs
                }
                return ctx
            },
            defineCheck("the two outbound references differ") { _, _, _ in
                guard case .emit(let alpha)? = world.emissions["alpha"],
                      case .emit(let beta)? = world.emissions["beta"] else {
                    throw BrineStepError("one of the accounts produced no reference: \(world.emissions)")
                }
                guard alpha != beta else {
                    throw BrineStepError("both accounts produced the same reference \(alpha.hex)")
                }
            },
            defineCheck("each account's reference is stable across relaunch") { _, _, _ in
                for (label, refs) in world.refsAcrossRelaunch {
                    guard refs.count == 2 else {
                        throw BrineStepError("\(label) produced \(refs.count) references, expected 2")
                    }
                    guard refs[0] == refs[1] else {
                        throw BrineStepError("\(label)'s reference changed across relaunch")
                    }
                }
            },
            defineCheck("neither reference contains the display name or the raw hardware identifier") { _, _, _ in
                for (label, emission) in world.emissions {
                    guard case .emit(let ref) = emission else {
                        throw BrineStepError("\(label) produced no reference")
                    }
                    let lowered = ref.hex.lowercased()
                    for forbidden in ["trail", "mic", "hw-", "bleStream".lowercased()] {
                        guard !lowered.contains(forbidden) else {
                            throw BrineStepError("\(label)'s reference leaks \"\(forbidden)\": \(ref.hex)")
                        }
                    }
                    guard ref.hex.allSatisfy(\.isHexDigit), ref.hex.count >= 32 else {
                        throw BrineStepError("\(label)'s reference is not an opaque 128-bit hex value: \(ref.hex)")
                    }
                }
            },
        ]
    }
}
