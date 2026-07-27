import Foundation
import XCTest
import BrineSwiftCore
@testable import FoundryXKit

final class PairingFailureTests: XCTestCase {
    func testColdScopedPairingReadNeverWaitsForPersistenceMaintenance() throws {
        let fixture = try PairingTestFixture()
        defer { fixture.cleanup() }
        let secrets = ScriptedPairingSecretStore()
        let cell = CellStore(
            defaults: fixture.defaults,
            keychainService: fixture.cellService,
            secretStore: secrets)
        let original = CellConfig(
            url: "https://vault.example.test",
            auth: .bearer("original-vault-bearer"))
        XCTAssertTrue(cell.pair(original))
        let doorStore = DoorConfigStore(
            defaults: fixture.defaults,
            keychainService: fixture.doorService,
            secretStore: secrets)
        let door = try XCTUnwrap(DoorConfig(
            url: "https://door.example.test",
            bearer: "original-door-bearer"))
        XCTAssertTrue(doorStore.save(door))

        CaptureAccountScope.resetProcessCacheForTests()
        CaptureAccountScope.resetResolutionPersistenceEntriesForTests()
        XCTAssertNil(CaptureAccountScope.currentScopedPreferences())
        XCTAssertEqual(
            CaptureAccountScope.resolutionPersistenceEntryCountForTests,
            0,
            "a cache-cold scoped preference read attempted persistence resolution")
        XCTAssertEqual(secrets.value(
            service: fixture.cellService,
            account: fixture.scope), "original-vault-bearer")
        XCTAssertEqual(secrets.value(
            service: fixture.doorService,
            account: fixture.scope), "original-door-bearer")
    }

    func testFailedVaultBearerReplacementPreservesCurrentAndReopenedPairing() throws {
        let fixture = try PairingTestFixture()
        defer { fixture.cleanup() }
        let secrets = ScriptedPairingSecretStore()
        let store = CellStore(
            defaults: fixture.defaults,
            keychainService: fixture.cellService,
            secretStore: secrets)
        let original = CellConfig(
            url: "https://original-vault.example.test",
            auth: .bearer("original-bearer"))
        XCTAssertTrue(store.pair(original))

        secrets.failNextUpdate()
        let replacement = CellConfig(
            url: "https://replacement-vault.example.test",
            auth: .bearer("replacement-bearer"))
        XCTAssertFalse(store.pair(replacement))

        XCTAssertEqual(store.config, original)
        XCTAssertEqual(
            secrets.value(service: fixture.cellService, account: fixture.scope),
            "original-bearer")
        XCTAssertEqual(
            CellStore(
                defaults: fixture.defaults,
                keychainService: fixture.cellService,
                secretStore: secrets).config,
            original)
    }

    func testFailedFirstVaultBearerWriteLeavesNoPartialPairing() throws {
        let fixture = try PairingTestFixture()
        defer { fixture.cleanup() }
        let secrets = ScriptedPairingSecretStore()
        let store = CellStore(
            defaults: fixture.defaults,
            keychainService: fixture.cellService,
            secretStore: secrets)
        secrets.failNextAdd()
        XCTAssertFalse(store.pair(CellConfig(
            url: "https://new-vault.example.test",
            auth: .bearer("new-bearer"))))
        XCTAssertNil(store.config)
        XCTAssertNil(secrets.value(
            service: fixture.cellService,
            account: fixture.scope))
        XCTAssertNil(CellStore(
            defaults: fixture.defaults,
            keychainService: fixture.cellService,
            secretStore: secrets).config)
    }

    func testFailedVaultUnpairPreservesCurrentAndReopenedPairing() throws {
        let fixture = try PairingTestFixture()
        defer { fixture.cleanup() }
        let secrets = ScriptedPairingSecretStore()
        let store = CellStore(
            defaults: fixture.defaults,
            keychainService: fixture.cellService,
            secretStore: secrets)
        let original = CellConfig(
            url: "https://original-vault.example.test",
            auth: .bearer("original-bearer"))
        XCTAssertTrue(store.pair(original))

        secrets.failNextRemove()
        XCTAssertFalse(store.unpair())

        XCTAssertEqual(store.config, original)
        XCTAssertEqual(
            secrets.value(service: fixture.cellService, account: fixture.scope),
            "original-bearer")
        XCTAssertEqual(
            CellStore(
                defaults: fixture.defaults,
                keychainService: fixture.cellService,
                secretStore: secrets).config,
            original)
    }

    @MainActor
    func testFailedDoorSaveIsVisibleAndPreservesCurrentAndReopenedDoor() throws {
        let fixture = try PairingTestFixture()
        defer { fixture.cleanup() }
        let secrets = ScriptedPairingSecretStore()
        let store = DoorConfigStore(
            defaults: fixture.defaults,
            keychainService: fixture.doorService,
            secretStore: secrets)
        let original = try XCTUnwrap(DoorConfig(
            url: "https://original-door.example.test",
            bearer: "original-door-bearer"))
        XCTAssertTrue(store.save(original))

        let model = DoorConnectionSaveModel(store: store)
        let replacement = try XCTUnwrap(DoorConfig(
            url: "https://replacement-door.example.test",
            bearer: "replacement-door-bearer"))
        var callbackValue: DoorConfig?
        secrets.failNextUpdate()
        model.save(replacement) { callbackValue = $0 }

        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(callbackValue)
        XCTAssertEqual(store.load(), original)
        XCTAssertEqual(
            secrets.value(service: fixture.doorService, account: fixture.scope),
            "original-door-bearer")
        XCTAssertEqual(
            DoorConfigStore(
                defaults: fixture.defaults,
                keychainService: fixture.doorService,
                secretStore: secrets).load(),
            original)
    }

    func testFailedIdTokenChangePreservesBearerPairing() throws {
        let fixture = try PairingTestFixture()
        defer { fixture.cleanup() }
        let secrets = ScriptedPairingSecretStore()
        let store = CellStore(
            defaults: fixture.defaults,
            keychainService: fixture.cellService,
            secretStore: secrets)
        let original = CellConfig(
            url: "https://original-vault.example.test",
            auth: .bearer("original-bearer"))
        XCTAssertTrue(store.pair(original))

        secrets.failNextRemove()
        XCTAssertFalse(store.pair(CellConfig(
            url: "https://replacement-vault.example.test",
            auth: .idToken)))

        XCTAssertEqual(store.config, original)
        XCTAssertEqual(
            secrets.value(service: fixture.cellService, account: fixture.scope),
            "original-bearer")
        XCTAssertEqual(
            CellStore(
                defaults: fixture.defaults,
                keychainService: fixture.cellService,
                secretStore: secrets).config,
            original)
    }

    @MainActor
    func testCoordinatorObservesRealNotificationAndReloadsAfterRestore() throws {
        let fixture = try PairingTestFixture()
        defer { fixture.cleanup() }
        let generation = CaptureAccountScope.identityGeneration
        let center = NotificationCenter()
        let coordinator = AccountIdentityCoordinator(
            notificationCenter: center,
            activeGeneration: generation)
        var transitions: [UInt64] = []
        var restores: [UInt64] = []
        coordinator.bind(
            onIdentityTransition: { transitions.append($0) },
            onRestoreCompleted: { restores.append($0) },
            onTokenAvailable: { _ in })
        coordinator.start()
        center.post(
            name: CaptureAccountScope.identityDidChangeNotification,
            object: nil,
            userInfo: ["generation": NSNumber(value: generation)])
        coordinator.restoreCompleted(generation: generation)

        XCTAssertEqual(transitions, [generation])
        XCTAssertEqual(restores, [generation])
        coordinator.stop()
    }

    @MainActor
    func testCoordinatorRejectsTokenFromPriorAccountGeneration() throws {
        let fixture = try PairingTestFixture()
        defer { fixture.cleanup() }
        let currentGeneration = CaptureAccountScope.identityGeneration
        XCTAssertGreaterThan(currentGeneration, 0)
        let staleGeneration = currentGeneration - 1
        let coordinator = AccountIdentityCoordinator(
            activeGeneration: currentGeneration)
        var accepted: [AccountBoundToken] = []
        coordinator.bind(
            onIdentityTransition: { _ in },
            onRestoreCompleted: { _ in },
            onTokenAvailable: {
                if let token = $0 { accepted.append(token) }
            })

        coordinator.tokenDidChange(
            AccountBoundToken(
                value: "stale-a-token",
                generation: staleGeneration),
            generation: staleGeneration)
        coordinator.tokenDidChange(
            AccountBoundToken(
                value: "current-b-token",
                generation: currentGeneration),
            generation: currentGeneration)

        XCTAssertEqual(
            accepted,
            [AccountBoundToken(
                value: "current-b-token",
                generation: currentGeneration)])
    }

    @MainActor
    func testStaleRestoreCannotRewindCurrentIdentityGeneration() throws {
        let fixture = try PairingTestFixture()
        defer { fixture.cleanup() }
        let currentGeneration = CaptureAccountScope.identityGeneration
        XCTAssertGreaterThan(currentGeneration, 0)
        let staleGeneration = currentGeneration - 1
        let center = NotificationCenter()
        let coordinator = AccountIdentityCoordinator(
            notificationCenter: center,
            activeGeneration: staleGeneration)
        var transitions: [UInt64] = []
        var restores: [UInt64] = []
        var accepted: [AccountBoundToken] = []
        coordinator.bind(
            onIdentityTransition: { transitions.append($0) },
            onRestoreCompleted: { restores.append($0) },
            onTokenAvailable: {
                if let token = $0 { accepted.append(token) }
            })
        coordinator.start()

        center.post(
            name: CaptureAccountScope.identityDidChangeNotification,
            object: nil,
            userInfo: ["generation": NSNumber(value: currentGeneration)])
        coordinator.restoreCompleted(generation: staleGeneration)
        coordinator.tokenDidChange(
            AccountBoundToken(
                value: "stale-a-token",
                generation: staleGeneration),
            generation: staleGeneration)
        coordinator.restoreCompleted(generation: currentGeneration)
        let currentToken = AccountBoundToken(
            value: "current-b-token",
            generation: currentGeneration)
        coordinator.tokenDidChange(
            currentToken,
            generation: currentGeneration)

        XCTAssertEqual(transitions, [currentGeneration])
        XCTAssertEqual(restores, [currentGeneration])
        XCTAssertEqual(accepted, [currentToken])
        XCTAssertEqual(coordinator.currentToken, currentToken)
        coordinator.stop()
    }

    @MainActor
    func testDelayedCurrentGenerationTokenRestoresIdTokenVault() throws {
        let fixture = try PairingTestFixture()
        defer { fixture.cleanup() }
        let secrets = ScriptedPairingSecretStore()
        let cellStore = CellStore(
            defaults: fixture.defaults,
            keychainService: fixture.cellService,
            secretStore: secrets)
        XCTAssertTrue(cellStore.pair(CellConfig(
            url: "https://second-vault.example.test",
            auth: .idToken)))
        let token = PairingTokenBox()
        let model = VaultFunnelModel(
            service: PairingFailureVaultService(),
            browser: PairingFailureVaultBrowser(),
            cellStore: cellStore,
            idToken: { token.value },
            storefrontCountryCode: { "USA" })
        model.resetForIdentityTransition()
        XCTAssertEqual(model.entitlement, .off)

        let generation = CaptureAccountScope.identityGeneration
        let coordinator = AccountIdentityCoordinator(
            activeGeneration: generation)
        coordinator.bind(
            onIdentityTransition: { _ in },
            onRestoreCompleted: { _ in },
            onTokenAvailable: { available in
                if let available {
                    token.value = available.value
                    model.refreshForAvailableToken(
                        expectedGeneration: available.generation)
                } else {
                    token.value = nil
                    model.clearUnavailableIdentityToken(
                        expectedGeneration: generation)
                }
            })
        coordinator.tokenDidChange(
            AccountBoundToken(
                value: "second-account-token",
                generation: generation),
            generation: generation)

        XCTAssertEqual(model.entitlement, .live)
        XCTAssertEqual(
            model.connectedVault?.target.bearer,
            "second-account-token")

        coordinator.tokenDidChange(nil, generation: generation)
        XCTAssertEqual(model.entitlement, .off)
    }
}

final class ScriptedPairingSecretStore:
    PairingSecretStore, @unchecked Sendable
{
    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private let lock = NSLock()
    private var values: [Key: String] = [:]
    private var addFailures = 0
    private var removeFailures = 0
    private var updateFailures = 0

    func read(service: String, account: String) -> String? {
        lock.withLock { values[Key(service: service, account: account)] }
    }

    func update(
        _ value: String,
        service: String,
        account: String
    ) -> PairingSecretUpdateResult {
        lock.withLock {
            if updateFailures > 0 {
                updateFailures -= 1
                return .failed
            }
            let key = Key(service: service, account: account)
            guard values[key] != nil else { return .notFound }
            values[key] = value
            return .updated
        }
    }

    func add(_ value: String, service: String, account: String) -> Bool {
        lock.withLock {
            if addFailures > 0 {
                addFailures -= 1
                return false
            }
            let key = Key(service: service, account: account)
            guard values[key] == nil else { return false }
            values[key] = value
            return true
        }
    }

    func remove(service: String, account: String) -> Bool {
        lock.withLock {
            if removeFailures > 0 {
                removeFailures -= 1
                return false
            }
            values.removeValue(forKey: Key(service: service, account: account))
            return true
        }
    }

    func failNextAdd() {
        lock.withLock { addFailures += 1 }
    }

    func failNextRemove() {
        lock.withLock { removeFailures += 1 }
    }

    func failNextUpdate() {
        lock.withLock { updateFailures += 1 }
    }

    func value(service: String, account: String) -> String? {
        read(service: service, account: account)
    }
}

final class PairingTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

struct PairingTestFixture {
    let container: URL
    let defaultsName: String
    let defaults: UserDefaults
    let cellService: String
    let doorService: String
    let scope: String

    init() throws {
        let discriminator = UUID().uuidString.lowercased()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "foundryx-pairing-failure-\(discriminator)",
                isDirectory: true)
        defaultsName = "foundryx.pairing-failure.\(discriminator)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            throw XCTSkip("could not create isolated defaults")
        }
        self.defaults = defaults
        cellService = "foundryx.pairing-failure.cell.\(discriminator)"
        doorService = "foundryx.pairing-failure.door.\(discriminator)"

        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true)
        CaptureAccountScope.resetTestEnvironment()
        CaptureAccountScope.setContainerForTests(container)
        CaptureAccountScope.setDefaultsForTests(defaults)
        let identity = AuthIdentity(
            provider: AuthProvider.google.rawValue,
            idToken: PairingTestFixture.idToken(subject: discriminator),
            refreshToken: nil,
            expiresAt: .distantFuture,
            email: "\(discriminator)@example.test")
        try CaptureAccountScope.activateForTests(identity)
        scope = try XCTUnwrap(
            CaptureAccountScope.currentScopedPreferences()?.scope)
    }

    func cleanup() {
        let secretStore = SystemPairingSecretStore()
        _ = secretStore.remove(service: cellService, account: scope)
        _ = secretStore.remove(service: doorService, account: scope)
        CaptureAccountScope.resetTestEnvironment()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: container)
    }

    private static func idToken(subject: String) -> String {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8)
        let payload = Data(#"{"sub":"\#(subject)"}"#.utf8)
        return [header, payload].map {
            $0.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }.joined(separator: ".") + ".test-signature"
    }
}

struct PairingFailureVaultService: VaultSignupService {
    func createCheckoutAttempt(
        plan: VaultPlan,
        idToken: String?
    ) async throws -> VaultCheckoutAttempt {
        VaultCheckoutAttempt(id: "unused", checkoutURL: nil)
    }

    func reconcile(
        attemptId: String,
        idToken: String?
    ) async throws -> VaultProvisionStatus {
        .pending
    }

    func exchangeReturn(
        ticket: String,
        idToken: String?
    ) async throws -> VaultProvisionStatus {
        .pending
    }
}

struct PairingFailureVaultBrowser: VaultCheckoutBrowser {
    func open(_ url: URL) async throws -> URL? { nil }
}

final class PairingScenarioHarness: @unchecked Sendable {
    private let fixture: PairingTestFixture
    private let secrets = ScriptedPairingSecretStore()
    private var cellStore: CellStore?
    private var doorStore: DoorConfigStore?
    private var originalCell: CellConfig?
    private var originalDoor: DoorConfig?
    private var operationSucceeded: Bool?
    private var reopenedCell: CellConfig?
    private var reopenedDoor: DoorConfig?
    private var doorError: String?
    private var doorCallback: DoorConfig?
    private var coldReadFinished = false
    private var coldPairingsUnchanged = false
    private var vaultModel: VaultFunnelModel?
    private var staleTokenWasIgnored = false

    init() throws {
        fixture = try PairingTestFixture()
    }

    func cleanup() {
        fixture.cleanup()
    }

    func seedColdPairings() throws {
        let cell = CellStore(
            defaults: fixture.defaults,
            keychainService: fixture.cellService,
            secretStore: secrets)
        let config = CellConfig(
            url: "https://cold-vault.example.test",
            auth: .bearer("cold-vault-bearer"))
        guard cell.pair(config) else {
            throw BrineStepError("could not seed the cold Vault pairing")
        }
        let doorStore = DoorConfigStore(
            defaults: fixture.defaults,
            keychainService: fixture.doorService,
            secretStore: secrets)
        guard let door = DoorConfig(
            url: "https://cold-door.example.test",
            bearer: "cold-door-bearer"),
              doorStore.save(door) else {
            throw BrineStepError("could not seed the cold Door pairing")
        }
        originalCell = config
        originalDoor = door
        self.cellStore = cell
        self.doorStore = doorStore
    }

    func makePairingsCold() {
        CaptureAccountScope.resetProcessCacheForTests()
    }

    @MainActor
    func raceColdReadWithMaintenance() {
        let generation = CaptureAccountScope.identityGeneration
        CaptureAccountScope.resetResolutionPersistenceEntriesForTests()
        let coordinator = AccountIdentityCoordinator(
            activeGeneration: generation)
        var transitionFinished = false
        coordinator.bind(
            onIdentityTransition: { _ in
                self.cellStore?.reloadForIdentityTransition()
                _ = self.doorStore?.load()
                transitionFinished = true
            },
            onRestoreCompleted: { _ in },
            onTokenAvailable: { _ in })
        coordinator.start()
        NotificationCenter.default.post(
            name: CaptureAccountScope.identityDidChangeNotification,
            object: nil,
            userInfo: ["generation": NSNumber(value: generation)])
        coldReadFinished =
            transitionFinished
            && CaptureAccountScope.resolutionPersistenceEntryCountForTests == 0
        coordinator.stop()
        coldPairingsUnchanged =
            secrets.value(
                service: fixture.cellService,
                account: fixture.scope) == "cold-vault-bearer"
            && secrets.value(
                service: fixture.doorService,
                account: fixture.scope) == "cold-door-bearer"
    }

    func assertColdReadFinished() throws {
        guard coldReadFinished else {
            throw BrineStepError(
                "the cold pairing read waited for pairing maintenance")
        }
    }

    func assertColdPairingsUnchanged() throws {
        guard coldPairingsUnchanged else {
            throw BrineStepError(
                "the cold refresh claimed or changed an existing pairing")
        }
    }

    func failVaultReplacement() throws {
        let store = try seedBearerVault()
        secrets.failNextUpdate()
        operationSucceeded = store.pair(CellConfig(
            url: "https://replacement-vault.example.test",
            auth: .bearer("replacement-bearer")))
        reopenedCell = CellStore(
            defaults: fixture.defaults,
            keychainService: fixture.cellService,
            secretStore: secrets).config
    }

    func failVaultUnpair() throws {
        let store = try seedBearerVault()
        secrets.failNextRemove()
        operationSucceeded = store.unpair()
        reopenedCell = CellStore(
            defaults: fixture.defaults,
            keychainService: fixture.cellService,
            secretStore: secrets).config
    }

    func seedWorkingDoor() throws {
        let store = DoorConfigStore(
            defaults: fixture.defaults,
            keychainService: fixture.doorService,
            secretStore: secrets)
        guard let original = DoorConfig(
            url: "https://working-door.example.test",
            bearer: "working-door-bearer"),
              store.save(original) else {
            throw BrineStepError("could not seed the working Door")
        }
        originalDoor = original
        doorStore = store
    }

    @MainActor
    func failDoorReplacement() throws {
        guard let store = doorStore,
              let replacement = DoorConfig(
                url: "https://replacement-door.example.test",
                bearer: "replacement-door-bearer") else {
            throw BrineStepError("the working Door was not prepared")
        }
        secrets.failNextUpdate()
        let model = DoorConnectionSaveModel(store: store)
        model.save(replacement) { self.doorCallback = $0 }
        doorError = model.errorMessage
        reopenedDoor = DoorConfigStore(
            defaults: fixture.defaults,
            keychainService: fixture.doorService,
            secretStore: secrets).load()
    }

    func assertDoorFailureIsVisible() throws {
        guard doorError != nil, doorCallback == nil else {
            throw BrineStepError(
                "the failed Door save was not visible or still connected")
        }
    }

    func assertDoorRemainsWhole() throws {
        guard let originalDoor,
              doorStore?.load() == originalDoor,
              reopenedDoor == originalDoor,
              secrets.value(
                service: fixture.doorService,
                account: fixture.scope) == originalDoor.bearer else {
            throw BrineStepError(
                "the failed save did not preserve the working Door")
        }
    }

    @MainActor
    func seedDelayedTokenVault() throws {
        let store = CellStore(
            defaults: fixture.defaults,
            keychainService: fixture.cellService,
            secretStore: secrets)
        guard store.pair(CellConfig(
            url: "https://second-vault.example.test",
            auth: .idToken)) else {
            throw BrineStepError("could not seed the id-token Vault")
        }
        let token = PairingTokenBox()
        let model = VaultFunnelModel(
            service: PairingFailureVaultService(),
            browser: PairingFailureVaultBrowser(),
            cellStore: store,
            idToken: { token.value },
            storefrontCountryCode: { "USA" })
        model.resetForIdentityTransition()
        let generation = CaptureAccountScope.identityGeneration
        guard generation > 0 else {
            throw BrineStepError("the delayed-token generation could not advance")
        }
        let staleGeneration = generation - 1
        let center = NotificationCenter()
        delayedTokenTransitions = []
        delayedTokenRestores = []
        let coordinator = AccountIdentityCoordinator(
            notificationCenter: center,
            activeGeneration: staleGeneration)
        coordinator.bind(
            onIdentityTransition: {
                self.delayedTokenTransitions.append($0)
                model.resetForIdentityTransition()
            },
            onRestoreCompleted: {
                self.delayedTokenRestores.append($0)
                model.resetForIdentityTransition()
            },
            onTokenAvailable: { available in
                if let available {
                    token.value = available.value
                    model.refreshForAvailableToken(
                        expectedGeneration: available.generation)
                } else {
                    token.value = nil
                    model.clearUnavailableIdentityToken(
                        expectedGeneration: generation)
                }
            })
        coordinator.start()
        center.post(
            name: CaptureAccountScope.identityDidChangeNotification,
            object: nil,
            userInfo: ["generation": NSNumber(value: generation)])
        coordinator.restoreCompleted(generation: staleGeneration)
        coordinator.tokenDidChange(
            AccountBoundToken(
                value: "first-account-stale-token",
                generation: staleGeneration),
            generation: staleGeneration)
        staleTokenWasIgnored =
            model.entitlement == .off
            && delayedTokenTransitions == [generation]
            && delayedTokenRestores.isEmpty
        self.vaultModel = model
        self.delayedTokenCoordinator = coordinator
        self.delayedTokenGeneration = generation
    }

    @MainActor
    func publishDelayedToken() throws {
        guard let coordinator = delayedTokenCoordinator,
              let generation = delayedTokenGeneration else {
            throw BrineStepError("the delayed token scenario was not prepared")
        }
        coordinator.restoreCompleted(generation: generation)
        coordinator.tokenDidChange(
            AccountBoundToken(
                value: "second-account-token",
                generation: generation),
            generation: generation)
    }

    @MainActor
    func assertDelayedTokenIsUnavailable() throws {
        guard vaultModel?.entitlement == .off else {
            throw BrineStepError(
                "the id-token Vault became live before its token was available")
        }
    }

    @MainActor
    func assertDelayedVaultIsLive() throws {
        guard vaultModel?.entitlement == .live,
              vaultModel?.connectedVault?.target.bearer
                == "second-account-token" else {
            throw BrineStepError(
                "the current account's delayed token did not restore its Vault")
        }
    }

    func assertStaleVaultNeverReconnected() throws {
        guard staleTokenWasIgnored,
              let generation = delayedTokenGeneration,
              delayedTokenTransitions == [generation],
              delayedTokenRestores == [generation] else {
            throw BrineStepError(
                "the prior account's delayed restore or token reconnected its Vault")
        }
    }

    func seedBearerVaultForAuthChange() throws {
        _ = try seedBearerVault()
    }

    func failIdTokenChange() throws {
        guard let store = cellStore else {
            throw BrineStepError("the bearer Vault was not prepared")
        }
        secrets.failNextRemove()
        operationSucceeded = store.pair(CellConfig(
            url: "https://replacement-vault.example.test",
            auth: .idToken))
        reopenedCell = CellStore(
            defaults: fixture.defaults,
            keychainService: fixture.cellService,
            secretStore: secrets).config
    }

    func assertVaultOperationFailed() throws {
        guard operationSucceeded == false else {
            throw BrineStepError(
                "FoundryX did not report the secure Vault operation failure")
        }
    }

    func assertCurrentVaultRemainsWhole() throws {
        guard let originalCell,
              cellStore?.config == originalCell,
              secrets.value(
                service: fixture.cellService,
                account: fixture.scope) == Self.bearer(from: originalCell) else {
            throw BrineStepError(
                "the current session lost part of the original Vault pairing")
        }
    }

    func assertReopenedVaultRemainsWhole() throws {
        guard reopenedCell == originalCell else {
            throw BrineStepError(
                "reopening did not restore the original complete Vault pairing")
        }
    }

    private var delayedTokenCoordinator: AccountIdentityCoordinator?
    private var delayedTokenGeneration: UInt64?
    private var delayedTokenTransitions: [UInt64] = []
    private var delayedTokenRestores: [UInt64] = []

    private func seedBearerVault() throws -> CellStore {
        let store = CellStore(
            defaults: fixture.defaults,
            keychainService: fixture.cellService,
            secretStore: secrets)
        let original = CellConfig(
            url: "https://original-vault.example.test",
            auth: .bearer("original-bearer"))
        guard store.pair(original) else {
            throw BrineStepError("could not seed the original Vault")
        }
        originalCell = original
        cellStore = store
        return store
    }

    private static func bearer(from config: CellConfig) -> String? {
        guard case .bearer(let value) = config.auth else { return nil }
        return value
    }
}
