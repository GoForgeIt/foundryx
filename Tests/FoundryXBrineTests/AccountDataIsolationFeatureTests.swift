import XCTest
import Foundation
import Security
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/account-data-isolation.feature.
///
/// Every durable dependency is injected beneath one UUID-named direct child of
/// `FileManager.default.temporaryDirectory`: capture Documents, legacy Application
/// Support, account activation defaults, and App-Group widget defaults. No scenario
/// resolves or removes a production container.
final class AccountDataIsolationFeatureTests: XCTestCase {
    /// Can this test host actually use the Keychain? The iOS unit-test bundle has no
    /// host app and therefore no keychain entitlement, so every `SecItem` call there
    /// returns `errSecMissingEntitlement` (-34018). Probed once, for real, rather than
    /// assumed from `#if os(...)`.
    static let keychainUsable: Bool = {
        let service = "com.goforgeit.foundryx.keychain-probe.\(UUID().uuidString)"
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service]
        var add = base
        add[kSecValueData as String] = Data("probe".utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { SecItemDelete(base as CFDictionary) }
        return status == errSecSuccess
    }()

    /// The pairing scenarios stage and read REAL Keychain items — that is the point,
    /// since the defect they cover is an unqualified `kSecAttrService` query. Where the
    /// host cannot use the Keychain they SKIP loudly rather than pass vacuously; a fake
    /// keychain would report green while hiding exactly the macOS/iOS divergence that
    /// shipped a defect in build 300.
    func testAccountPairingIsolationFeature() async throws {
        try XCTSkipUnless(
            Self.keychainUsable,
            "this test host has no keychain entitlement (errSecMissingEntitlement); "
                + "Vault/Door pairing isolation is covered on macOS")
        let world = try AccountDataIsolationWorld()
        do {
            try await BrineFeatureRunner.run(
                "account-pairing-isolation",
                registry: StepRegistry(AccountDataIsolationSteps.make(world: world)))
        } catch {
            try? world.cleanup()
            throw error
        }
        try world.cleanup()
    }

    /// The skip above must never become a silent hole on the platform where the
    /// Keychain DOES work. If macOS ever stops being able to use it, that is a broken
    /// test host, not a reason to lose pairing coverage.
    func testKeychainBackedPairingCoverageIsNotSilentlyLostOnMac() throws {
        #if os(macOS)
        XCTAssertTrue(
            Self.keychainUsable,
            "macOS must be able to use the Keychain — otherwise every Vault/Door "
                + "pairing scenario skips on EVERY platform and the coverage is gone")
        #endif
    }

    func testAccountDataIsolationFeature() async throws {
        let world = try AccountDataIsolationWorld()
        do {
            try await BrineFeatureRunner.run(
                "account-data-isolation",
                registry: StepRegistry(AccountDataIsolationSteps.make(world: world)))
        } catch {
            try? world.cleanup()
            throw error
        }
        try world.cleanup()
    }

    /// Executes the new signed-out feature scenario in isolation so its RED/green
    /// signal is not obscured by unrelated activation scenarios.
    func testSignedOutOnDeviceTierUpdatesGlanceableState() throws {
        let world = try AccountDataIsolationWorld()
        do {
            try world.prepareSignedOutOnDeviceCapture()
            world.publishSignedOutGlanceableState()
            try world.assertSignedOutGlanceableStateIsCurrent()
        } catch {
            try? world.cleanup()
            throw error
        }
        try world.cleanup()
    }

    /// The free on-device tier on a BRAND-NEW phone: no activation record, no
    /// identity. This is the case build 300 shipped broken — "no record" was read as
    /// "unresolvable", so the capture root became a fail-closed path and nothing could
    /// record before sign-in. The existing signed-out scenario could not catch it
    /// because it seeds a signedOut record first.
    func testFreshInstallCanRecordBeforeAnyoneSignsIn() throws {
        let world = try AccountDataIsolationWorld()
        do {
            try world.prepareFreshInstallWithNoActivationRecord()
            try world.assertFreshInstallCanRecord()
        } catch {
            try? world.cleanup()
            throw error
        }
        try world.cleanup()
    }

    func testSecondAccountCannotReadFirstAccountCellBearer() throws {
        try XCTSkipUnless(
            Self.keychainUsable,
            "this test host has no keychain entitlement; covered on macOS")
        let world = try AccountDataIsolationWorld()
        do {
            try world.firstAccountPairedVaultWithPrivateBearer()
            try world.secondAccountSignsInOnSamePhone()
            try world.assertSecondAccountHasNoVaultCellPairing()
            try world.assertSecondAccountCannotReadFirstVaultBearer()
        } catch {
            try? world.cleanup()
            throw error
        }
        try world.cleanup()
    }

    func testSecondAccountPairingPreservesFirstAccountBearer() throws {
        try XCTSkipUnless(
            Self.keychainUsable,
            "this test host has no keychain entitlement; covered on macOS")
        let world = try AccountDataIsolationWorld()
        do {
            try world.firstAccountPairedVaultWithPrivateBearer()
            try world.secondAccountPairsDifferentVault()
            try world.firstAccountSignsBackIn()
            try world.assertFirstAccountVaultPairingAndBearerAreIntact()
        } catch {
            try? world.cleanup()
            throw error
        }
        try world.cleanup()
    }

    @MainActor
    func testVaultRouterDerivesReplacementAccountAfterReset() async throws {
        try XCTSkipUnless(
            Self.keychainUsable,
            "this test host has no keychain entitlement; covered on macOS")
        let world = try AccountDataIsolationWorld()
        do {
            let model = try await world.makeFirstAccountVaultRouterLive()
            XCTAssertEqual(model.entitlement, .live)
            try world.secondAccountSignsInOnSamePhone()
            model.resetForIdentityTransition()
            XCTAssertEqual(model.entitlement, .off)
            XCTAssertEqual(model.state, .idle)
        } catch {
            try? world.cleanup()
            throw error
        }
        try world.cleanup()
    }

    func testLegacyPairingIsAdoptedOnlyByItsVerifiedOwner() throws {
        try XCTSkipUnless(
            Self.keychainUsable,
            "this test host has no keychain entitlement; covered on macOS")
        let world = try AccountDataIsolationWorld()
        do {
            try world.stageLegacyVaultAndDoorPairing()
            try world.verifiedOwnerActivatesScopedPrivateData()
            try world.assertOwnerPairingsRemainIntact()
            try world.assertLaterAccountCannotClaimLegacyPairings()
        } catch {
            try? world.cleanup()
            throw error
        }
        try world.cleanup()
    }

    func testSignedOutScopeNeverAdoptsLegacyPairing() throws {
        try XCTSkipUnless(
            Self.keychainUsable,
            "this test host has no keychain entitlement; covered on macOS")
        let world = try AccountDataIsolationWorld()
        do {
            try world.stageLegacyVaultAndDoorPairing()
            try world.remainSignedOutForFreeUse()
            try world.assertFreeTierHasNoVaultOrDoorPairing()
            try world.assertLegacyPairingRemainsUnclaimed()
        } catch {
            try? world.cleanup()
            throw error
        }
        try world.cleanup()
    }

    /// Isolation is a storage invariant. A new private store must not silently
    /// bypass CaptureAccountScope by resolving its own durable container.
    func testUserPrivateStoragePathsStayBehindTheAccountScopeGate() throws {
        let repository = Self.repositoryRoot
        let allowed = Set([
            "Sources/FoundryXKit/CaptureAccountScope.swift",
            "Sources/FoundryXKit/CaptureWidgetSnapshot.swift",
            "App/WhisperKitSTT.swift", // Shared model weights, not user content.
        ])
        let directPathAPIs = [
            ".documentDirectory",
            ".applicationSupportDirectory",
            "UserDefaults(suiteName:",
            "containerURL(forSecurityApplicationGroupIdentifier:",
            "group.com.goforgeit.foundryx",
        ]

        var violations: [String] = []
        for directory in ["Sources", "App", "Widget"] {
            let base = repository.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let relative = Self.relativePath(of: file, beneath: repository)
                guard !allowed.contains(relative) else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                for (offset, line) in source.components(separatedBy: .newlines).enumerated()
                    where directPathAPIs.contains(where: line.contains) {
                    violations.append("\(relative):\(offset + 1): \(line)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            User-private durable paths must resolve through CaptureAccountScope.
            Add a named PrivateStore case, or explicitly justify a shared-path allowlist entry:
            \(violations.joined(separator: "\n"))
            """)

        for relative in [
            "Sources/FoundryXKit/CaptureAccountScope.swift",
            "Sources/FoundryXKit/ChatConversationStore.swift",
        ] {
            let source = try String(
                contentsOf: repository.appendingPathComponent(relative),
                encoding: .utf8)
            XCTAssertFalse(
                source.contains("NSTemporaryDirectory"),
                "\(relative) must never redirect durable private data to NSTemporaryDirectory")
            XCTAssertFalse(
                source.contains(".temporaryDirectory"),
                "\(relative) must never redirect durable private data to temporaryDirectory")
        }

        let chatSource = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/FoundryXKit/ChatConversationStore.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            chatSource.contains("CaptureAccountScope.privateURL(for: .chatConversations)"),
            "ChatConversationStore must use the single private-store accessor")
    }

    /// App-only types are outside the SwiftPM test target. Pin their identity-boundary
    /// wiring at source level while the feature exercises the Kit-level notification,
    /// widget transition, and AccountBinding guard at runtime.
    func testAppIdentityTransitionClearsBrokerAndBindsDelayedWork() throws {
        let repository = Self.repositoryRoot
        let broker = try String(
            contentsOf: repository.appendingPathComponent("App/AmbientCards.swift"),
            encoding: .utf8)
        XCTAssertTrue(broker.contains("func clearForIdentityTransition()"))
        for field in [
            "pendingSeed",
            "pendingAnswer",
            "onNavigate",
            "pendingSeedCaptureId",
            "pendingPrefill",
            "pendingPrefillContext",
            "pendingOpenChatId",
            "isChatAlive",
        ] {
            XCTAssertTrue(
                broker.contains("\(field) = nil"),
                "AmbientCardBroker.clearForIdentityTransition must clear \(field)")
        }

        let notifier = try String(
            contentsOf: repository.appendingPathComponent("App/AmbientNotifier.swift"),
            encoding: .utf8)
        XCTAssertTrue(notifier.contains("binding: CaptureAccountScope.AccountBinding"))
        XCTAssertTrue(notifier.contains("CaptureAccountScope.perform(as: binding)"))
        XCTAssertTrue(notifier.contains("captured.root.appendingPathComponent"))
        XCTAssertFalse(
            notifier.contains("CaptureWAL.documentsCaptures()"),
            "AmbientNotifier must never re-resolve a later account root at completion")

        let chat = try String(
            contentsOf: repository.appendingPathComponent("App/ChatScreen.swift"),
            encoding: .utf8)
        XCTAssertTrue(chat.contains("let accountBinding: CaptureAccountScope.AccountBinding"))
        XCTAssertTrue(chat.contains("CaptureAccountScope.perform("))
        XCTAssertFalse(chat.contains("let url = CaptureWAL.documentsCaptures()"))

        let faces = try String(
            contentsOf: repository.appendingPathComponent(
                "App/ConversationFacesView.swift"),
            encoding: .utf8)
        XCTAssertTrue(faces.contains("let workBinding = CaptureAccountScope.currentAccountBinding()"))
        XCTAssertTrue(faces.contains("cacheIfReady(fetched, binding: binding)"))
        XCTAssertTrue(faces.contains("TranscriptCacheStore.save("))
        XCTAssertTrue(faces.contains("baseDir: captured.root"))

        let manager = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/FoundryXKit/CaptureManager.swift"),
            encoding: .utf8)
        XCTAssertTrue(manager.contains("CaptureWidgetSnapshotStore.write(snapshot, as: accountBinding)"))
        XCTAssertTrue(manager.contains("clearLiveActivityForIdentityTransition()"))
        XCTAssertTrue(manager.contains("liveActivityController?.endImmediately()"))
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func relativePath(of file: URL, beneath root: URL) -> String {
        let prefix = root.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

private final class AccountDataIsolationWorld: @unchecked Sendable {
    private struct State {
        var firstIdentity: AuthIdentity?
        var secondIdentity: AuthIdentity?
        var firstRoot: URL?
        var secondRoot: URL?
        var signedOutRoot: URL?
        var reResolvedFirstRoot: URL?
        var firstConversationIDs: Set<String> = []
        var firstSegments: [String: URL] = [:]
        var secondConversationID: String?
        var secondSegment: URL?
        var namedSpeaker: String?

        var legacyCaptureID: String?
        var legacySourceSegment: URL?
        var legacyDestinationRoot: URL?
        var legacyBytes: Data?
        var legacyFileNumber: NSNumber?

        var providerGoogleRoot: URL?
        var providerMicrosoftRoot: URL?
        var providerConversationID: String?
        var providerSegment: URL?

        var appleOriginalRoot: URL?
        var appleReauthorizedRoot: URL?
        var appleConversationID: String?
        var appleSegment: URL?

        var decomposedRoot: URL?
        var composedRoot: URL?

        var fallbackEmailRoot: URL?
        var laterSubjectRoot: URL?
        var fallbackConversationID: String?
        var fallbackSegment: URL?
        var laterSubjectKey: String?

        var postCreateDurabilityFailure: Error?

        var upperSubjectRoot: URL?
        var lowerSubjectRoot: URL?
        var caseSensitiveConversationID: String?
        var caseSensitiveSegment: URL?

        var firstChatTitle: String?
        var secondChatTitle: String?
        var reopenedFirstChatTitles: Set<String> = []
        var legacyChatTitle: String?
        var legacyChatURL: URL?
        var legacyChatFileNumber: NSNumber?
        var migratedLegacyChatURL: URL?

        var lockedOwnerRoot: URL?
        var lockedCaptureID: String?
        var lockedSegment: URL?

        var activationFailure: Error?

        var collisionError: Error?
        var collisionSource: URL?
        var collisionDestination: URL?
        var collisionRecovery: URL?
        var collisionLegacyBytes: Data?
        var collisionScopedBytes: Data?

        var transitionProbe: IdentityTransitionProbe?
        var signedOutGlanceableWriteAccepted = false

        var staleBinding: CaptureAccountScope.AccountBinding?
        var staleRejected = false
        var staleSecondRoot: URL?
        var staleProducerKind: String?
        var staleProducerCaptureID: String?
        var liveActivityContent: String?
        var liveActivityEnded = false

        var secondAccountCellConfig: CellConfig?
        var firstAccountCellConfigAfterRoundTrip: CellConfig?
        var firstAccountVaultConfig: CellConfig?
        var adoptedDoorURL: String?
        var adoptedDoorBearer: String?
        var adoptedOwnerScope: String?
        var preferenceGuardSources: [AccountPreferenceSourceFile] = []
        var preferenceGuardViolations: [AccountPreferenceUsageViolation] = []
    }

    private let queue = DispatchQueue(label: "foundryx.account-data-isolation-world")
    private let fileManager = FileManager.default
    private let token: String
    private let sandbox: URL
    private let captureContainer: URL
    private let applicationSupportRoot: URL
    private let scopeDefaultsName: String
    private let widgetDefaultsName: String
    private let scopeDefaults: UserDefaults
    private let widgetDefaults: UserDefaults
    private let cellKeychainService: String
    private let doorKeychainService: String
    private var scenarioNumber = 0
    private var state = State()
    private var pairingHarness: PairingScenarioHarness?
    private var accountVaultRouter: VaultFunnelModel?

    private var firstEmail: String { "first-\(token)@example.com" }
    private var secondEmail: String { "second-\(token)@example.com" }
    private var firstSubject: String { "subject-first-\(token)" }
    private var secondSubject: String { "subject-second-\(token)" }

    init() throws {
        let token = UUID().uuidString.lowercased()
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "foundryx-account-data-isolation-\(token)",
                isDirectory: true)
        let scopeDefaultsName = "foundryx.account-data-isolation.scope.\(token)"
        let widgetDefaultsName = "foundryx.account-data-isolation.widget.\(token)"
        guard let scopeDefaults = UserDefaults(suiteName: scopeDefaultsName),
              let widgetDefaults = UserDefaults(suiteName: widgetDefaultsName) else {
            throw BrineStepError("could not create isolated UserDefaults suites")
        }

        self.token = token
        self.sandbox = sandbox
        self.captureContainer = sandbox.appendingPathComponent(
            "documents/foundryx-captures", isDirectory: true)
        self.applicationSupportRoot = sandbox.appendingPathComponent(
            "application-support", isDirectory: true)
        self.scopeDefaultsName = scopeDefaultsName
        self.widgetDefaultsName = widgetDefaultsName
        self.scopeDefaults = scopeDefaults
        self.widgetDefaults = widgetDefaults
        self.cellKeychainService =
            "com.goforgeit.foundryx.cell.account-isolation-tests.\(token)"
        self.doorKeychainService =
            "com.goforgeit.foundryx.door.account-isolation-tests.\(token)"

        try validateSandbox()
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
        queue.sync { installTestEnvironmentLocked() }
    }

    func cleanup() throws {
        queue.sync {
            pairingHarness?.cleanup()
            pairingHarness = nil
            for service in [cellKeychainService, doorKeychainService] {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                ]
                SecItemDelete(query as CFDictionary)
            }
            state.transitionProbe?.stop()
            state.transitionProbe = nil
            CaptureWidgetSnapshotStore.transition(toOwner: nil)
            CaptureWidgetSnapshotStore.resetDefaultsForTesting()
            CaptureAccountScope.resetTestEnvironment()
            scopeDefaults.removePersistentDomain(forName: scopeDefaultsName)
            widgetDefaults.removePersistentDomain(forName: widgetDefaultsName)
        }
        try validateSandbox()
        if fileManager.fileExists(atPath: sandbox.path) {
            try fileManager.removeItem(at: sandbox)
        }
    }

    // MARK: - Saved-choice ownership classification

    func everySavedChoiceDeclaresItsOwner() throws {
        try queue.sync {
            try beginScenarioLocked()
            let expected: Set<String> = [
                "foundryx.onboarding.completed",
                "foundryx.onboarding.persona",
                "foundryx.welcome.seen",
                "foundryx.welcome.letStraightIn",
                "foundryx.ambient.enabled",
                "foundryx.ambient.agentName",
                "foundryx.ambient.grading",
                "foundryx.ambient.othersInline",
                "foundryx.vault.checkoutAttempt.id",
                "foundryx.vault.checkoutAttempt.plan",
                "foundryx.brain.choice",
                "foundryx.waitlist.joined",
                "foundryx.capture.silence-gap-seconds",
                "foundryx.capture.omi-desired-state",
                "foundryx.capture.sources.enabled-overrides",
                "foundryx.models.cache.v1",
                "foundryx.account.signup-posted",
            ]
            let entries = AccountPreferenceCatalog.entries
            guard entries.count == 17,
                  Set(entries.map(\.canonicalKey)) == expected else {
                throw BrineStepError(
                    "saved-choice ownership truth is not the exact 17-key catalog")
            }
        }
    }

    func developerAddsSavedChoiceWithoutOwnership() {
        queue.sync {
            state.preferenceGuardSources = [
                AccountPreferenceSourceFile(
                    path: "Fixture/UndeclaredChoice.swift",
                    text: """
                    import Foundation
                    UserDefaults.standard.set(
                        true,
                        forKey: "foundryx.unclassified-choice")
                    """),
            ]
            state.preferenceGuardViolations = []
        }
    }

    func assertBuildFailsForUndeclaredSavedChoice() throws {
        try queue.sync {
            state.preferenceGuardViolations = AccountPreferenceUsageGuard.scan(
                sources: state.preferenceGuardSources)
            guard !state.preferenceGuardViolations.isEmpty else {
                throw BrineStepError(
                    "the build accepted an unclassified saved choice")
            }
        }
    }

    func assertGuardIdentifiesUndeclaredSavedChoice() throws {
        try queue.sync {
            guard state.preferenceGuardViolations.contains(where: {
                $0.path == "Fixture/UndeclaredChoice.swift"
                    && $0.line == 2
                    && $0.keyOrUse == "foundryx.unclassified-choice"
            }) else {
                throw BrineStepError(
                    "the guard did not identify the saved choice's file, line, and key")
            }
        }
    }

    // MARK: - Account-scoped Vault pairing

    func firstAccountPairedVaultWithPrivateBearer() throws {
        try queue.sync {
            try beginScenarioLocked()
            let identity = try makeIdentity(
                provider: .google, subject: firstSubject, email: firstEmail)
            state.firstIdentity = identity
            state.firstRoot = try activateLocked(identity)

            let config = CellConfig(
                url: "https://first-\(token).example.com",
                auth: .bearer("first-private-bearer-\(token)"))
            let store = CellStore(
                defaults: scopeDefaults,
                keychainService: cellKeychainService)
            store.pair(config)
            guard CellStore(
                defaults: scopeDefaults,
                keychainService: cellKeychainService
            ).config == config else {
                throw BrineStepError(
                    "the test host could not persist the first account's Vault pairing")
            }
            state.firstAccountVaultConfig = config
        }
    }

    func secondAccountSignsInOnSamePhone() throws {
        try queue.sync {
            let identity = try makeIdentity(
                provider: .google, subject: secondSubject, email: secondEmail)
            state.secondIdentity = identity
            state.secondRoot = try activateLocked(identity)
            state.secondAccountCellConfig = CellStore(
                defaults: scopeDefaults,
                keychainService: cellKeychainService
            ).config
        }
    }

    func assertSecondAccountHasNoVaultCellPairing() throws {
        try queue.sync {
            guard state.secondAccountCellConfig == nil else {
                throw BrineStepError(
                    "the replacement account inherited the first account's Vault cell")
            }
        }
    }

    func assertSecondAccountCannotReadFirstVaultBearer() throws {
        try queue.sync {
            guard case nil = state.secondAccountCellConfig?.auth else {
                throw BrineStepError(
                    "the replacement account read the first account's Vault bearer")
            }
        }
    }

    func secondAccountPairsDifferentVault() throws {
        try queue.sync {
            let identity = try makeIdentity(
                provider: .google, subject: secondSubject, email: secondEmail)
            state.secondIdentity = identity
            state.secondRoot = try activateLocked(identity)
            CellStore(
                defaults: scopeDefaults,
                keychainService: cellKeychainService
            ).pair(CellConfig(
                url: "https://second-\(token).example.com",
                auth: .bearer("second-private-bearer-\(token)")))
        }
    }

    func firstAccountSignsBackIn() throws {
        try queue.sync {
            guard let identity = state.firstIdentity else {
                throw BrineStepError("the first account identity was not retained")
            }
            state.reResolvedFirstRoot = try activateLocked(identity)
            state.firstAccountCellConfigAfterRoundTrip = CellStore(
                defaults: scopeDefaults,
                keychainService: cellKeychainService
            ).config
        }
    }

    func assertFirstAccountVaultPairingAndBearerAreIntact() throws {
        try queue.sync {
            guard state.firstAccountCellConfigAfterRoundTrip
                    == state.firstAccountVaultConfig else {
                throw BrineStepError(
                    "the second account's pairing destroyed the first account's bearer")
            }
        }
    }

    @MainActor
    func firstAccountVaultEntitlementRouterIsLive() async throws {
        accountVaultRouter = try await makeFirstAccountVaultRouterLive()
    }

    @MainActor
    func secondAccountSignsInWithoutVault() throws {
        try secondAccountSignsInOnSamePhone()
        accountVaultRouter?.resetForIdentityTransition()
    }

    @MainActor
    func assertVaultRouterShowsSecondAccountIsOff() throws {
        guard accountVaultRouter?.entitlement == .off,
              accountVaultRouter?.state == .idle else {
            throw BrineStepError(
                "the identity coordinator left the first account's Vault entitlement live")
        }
    }

    @MainActor
    func makeFirstAccountVaultRouterLive() async throws -> VaultFunnelModel {
        try firstAccountPairedVaultWithPrivateBearer()
        let attempts = VaultCheckoutAttemptStore(defaults: scopeDefaults)
        attempts.save(attemptId: "account-isolation-\(token)", plan: .pro)
        let service = AccountIsolationVaultService(
            status: .ready(
                cellURL: "https://first-\(token).example.com",
                handoff: "first-private-bearer-\(token)"))
        let model = VaultFunnelModel(
            service: service,
            browser: AccountIsolationVaultBrowser(),
            cellStore: CellStore(
                defaults: scopeDefaults,
                keychainService: cellKeychainService),
            attempts: attempts,
            idToken: { "account-isolation-id-token" },
            storefrontCountryCode: { "USA" })
        await model.reconcileOnForeground()
        guard model.entitlement == .live else {
            throw BrineStepError(
                "the first account's Vault router did not become live")
        }
        return model
    }

    // MARK: - Pairing failure and delayed-token behavior

    func seedColdVaultAndDoorPairings() throws {
        let harness = try replacePairingHarness()
        try harness.seedColdPairings()
    }

    func leavePairingsColdForLaunch() throws {
        guard let pairingHarness else {
            throw BrineStepError("the cold pairing scenario was not prepared")
        }
        pairingHarness.makePairingsCold()
    }

    @MainActor
    func raceAccountChangeWithPairingRefresh() throws {
        guard let pairingHarness else {
            throw BrineStepError("the cold pairing scenario was not prepared")
        }
        pairingHarness.raceColdReadWithMaintenance()
    }

    func assertAccountChangeDidNotWaitForPairingMaintenance() throws {
        try requiredPairingHarness().assertColdReadFinished()
    }

    func assertPairingRefreshChangedNothing() throws {
        try requiredPairingHarness().assertColdPairingsUnchanged()
    }

    func failSecureVaultReplacement() throws {
        let harness = try replacePairingHarness()
        try harness.failVaultReplacement()
    }

    func failSecureVaultUnpair() throws {
        let harness = try replacePairingHarness()
        try harness.failVaultUnpair()
    }

    func assertVaultSecureOperationFailed() throws {
        try requiredPairingHarness().assertVaultOperationFailed()
    }

    func assertCurrentVaultRemainsWhole() throws {
        try requiredPairingHarness().assertCurrentVaultRemainsWhole()
    }

    func assertReopenedVaultRemainsWhole() throws {
        try requiredPairingHarness().assertReopenedVaultRemainsWhole()
    }

    func seedWorkingDoorForFailure() throws {
        let harness = try replacePairingHarness()
        try harness.seedWorkingDoor()
    }

    @MainActor
    func failSecureDoorReplacement() throws {
        try requiredPairingHarness().failDoorReplacement()
    }

    func assertDoorSaveFailureIsVisible() throws {
        try requiredPairingHarness().assertDoorFailureIsVisible()
    }

    func assertWorkingDoorRemainsWhole() throws {
        try requiredPairingHarness().assertDoorRemainsWhole()
    }

    @MainActor
    func seedDelayedTokenVault() throws {
        let harness = try replacePairingHarness()
        try harness.seedDelayedTokenVault()
    }

    @MainActor
    func publishDelayedVaultToken() throws {
        try requiredPairingHarness().publishDelayedToken()
    }

    @MainActor
    func assertDelayedVaultTokenIsUnavailable() throws {
        try requiredPairingHarness().assertDelayedTokenIsUnavailable()
    }

    @MainActor
    func assertDelayedTokenVaultIsLive() throws {
        try requiredPairingHarness().assertDelayedVaultIsLive()
    }

    func assertPriorVaultNeverReconnected() throws {
        try requiredPairingHarness().assertStaleVaultNeverReconnected()
    }

    func seedBearerVaultForAuthChange() throws {
        let harness = try replacePairingHarness()
        try harness.seedBearerVaultForAuthChange()
    }

    func failSecureIdTokenChange() throws {
        try requiredPairingHarness().failIdTokenChange()
    }

    private func replacePairingHarness() throws -> PairingScenarioHarness {
        pairingHarness?.cleanup()
        let harness = try PairingScenarioHarness()
        pairingHarness = harness
        return harness
    }

    private func requiredPairingHarness() throws -> PairingScenarioHarness {
        guard let pairingHarness else {
            throw BrineStepError("the pairing failure scenario was not prepared")
        }
        return pairingHarness
    }

    // MARK: - Legacy pairing adoption

    func stageLegacyVaultAndDoorPairing() throws {
        try queue.sync {
            try beginScenarioLocked()
            scopeDefaults.set(
                "https://legacy-vault-\(token).example.com",
                forKey: "foundryx.cell.url")
            scopeDefaults.set(
                "bearer",
                forKey: "foundryx.cell.authMode")
            scopeDefaults.set(
                "https://legacy-door-\(token).example.com",
                forKey: "foundryx.door.url")
            try addLegacySecretLocked(
                "legacy-cell-bearer-\(token)",
                service: cellKeychainService)
            try addLegacySecretLocked(
                "legacy-door-bearer-\(token)",
                service: doorKeychainService)
        }
    }

    func verifiedOwnerActivatesScopedPrivateData() throws {
        try queue.sync {
            let identity = try makeIdentity(
                provider: .google, subject: firstSubject, email: firstEmail)
            state.firstIdentity = identity
            let root = try activateLocked(identity)
            state.firstRoot = root
            guard let scope = CaptureAccountScope
                    .currentScopedPreferences()?.scope else {
                throw BrineStepError(
                    "activation completed without a scoped preference owner")
            }
            state.adoptedOwnerScope = scope
            state.firstAccountCellConfigAfterRoundTrip = CellStore(
                defaults: scopeDefaults,
                keychainService: cellKeychainService
            ).config
            state.adoptedDoorURL = scopeDefaults.string(
                forKey: "\(scope).foundryx.door.url")
            state.adoptedDoorBearer = secretLocked(
                service: doorKeychainService,
                account: scope)
        }
    }

    func assertOwnerPairingsRemainIntact() throws {
        try queue.sync {
            guard state.firstAccountCellConfigAfterRoundTrip == CellConfig(
                url: "https://legacy-vault-\(token).example.com",
                auth: .bearer("legacy-cell-bearer-\(token)")),
                  state.adoptedDoorURL
                    == "https://legacy-door-\(token).example.com",
                  state.adoptedDoorBearer
                    == "legacy-door-bearer-\(token)" else {
                throw BrineStepError(
                    "activation did not atomically carry the owner's existing pairing")
            }
            guard scopeDefaults.string(forKey: "foundryx.cell.url") != nil,
                  scopeDefaults.string(forKey: "foundryx.cell.authMode") != nil,
                  scopeDefaults.string(forKey: "foundryx.door.url") != nil else {
                throw BrineStepError(
                    "pairing adoption deleted a legacy preference name")
            }
        }
    }

    func assertLaterAccountCannotClaimLegacyPairings() throws {
        try queue.sync {
            let identity = try makeIdentity(
                provider: .google, subject: secondSubject, email: secondEmail)
            _ = try activateLocked(identity)
            guard CellStore(
                defaults: scopeDefaults,
                keychainService: cellKeychainService
            ).config == nil,
                  let secondScope = CaptureAccountScope
                    .currentScopedPreferences()?.scope,
                  scopeDefaults.string(
                    forKey: "\(secondScope).foundryx.door.url") == nil,
                  secretLocked(
                    service: doorKeychainService,
                    account: secondScope) == nil else {
                throw BrineStepError(
                    "a later account claimed the original owner's legacy pairing")
            }
        }
    }

    func remainSignedOutForFreeUse() throws {
        try queue.sync {
            try CaptureAccountScope.signOutForTests()
        }
    }

    func assertFreeTierHasNoVaultOrDoorPairing() throws {
        try queue.sync {
            guard CellStore(
                defaults: scopeDefaults,
                keychainService: cellKeychainService
            ).config == nil,
                  let scoped = CaptureAccountScope.currentScopedPreferences(),
                  scoped.scope == "acct-none",
                  scopeDefaults.string(
                    forKey: scoped.key("foundryx.door.url")) == nil,
                  secretLocked(
                    service: doorKeychainService,
                    account: scoped.scope) == nil else {
                throw BrineStepError(
                    "the signed-out free tier inherited a legacy pairing")
            }
        }
    }

    func assertLegacyPairingRemainsUnclaimed() throws {
        try queue.sync {
            guard secretLocked(
                service: cellKeychainService,
                account: "") == "legacy-cell-bearer-\(token)",
                  secretLocked(
                    service: doorKeychainService,
                    account: "") == "legacy-door-bearer-\(token)",
                  scopeDefaults.string(forKey: "foundryx.cell.url") != nil,
                  scopeDefaults.string(forKey: "foundryx.door.url") != nil else {
                throw BrineStepError(
                    "the free tier claimed or destroyed the verified owner's pairing")
            }
        }
    }

    // MARK: - Capture library round trip

    func recordedConversationsForFirstAccount() throws {
        try queue.sync {
            try beginScenarioLocked()
            let identity = try makeIdentity(
                provider: .google, subject: firstSubject, email: firstEmail)
            state.firstIdentity = identity
            let root = try activateLocked(identity)
            state.firstRoot = root
            let ids = [
                conversationID("first-one"),
                conversationID("first-two"),
            ]
            for (offset, id) in ids.enumerated() {
                state.firstSegments[id] = try recordConversationLocked(
                    id: id, expectedRoot: root, byte: UInt8(20 + offset))
            }
            state.firstConversationIDs = Set(ids)
        }
    }

    func signOutThenUseSecondAccount() throws {
        try queue.sync {
            try CaptureAccountScope.signOutForTests()
            state.signedOutRoot = CaptureWAL.documentsCaptures()
            let identity = try makeIdentity(
                provider: .google, subject: secondSubject, email: secondEmail)
            state.secondIdentity = identity
            state.secondRoot = try activateLocked(identity)
        }
    }

    func assertSecondAccountHasNoConversations() throws {
        try queue.sync {
            guard let root = state.secondRoot else {
                throw BrineStepError("the replacement account has no resolved root")
            }
            let visible = conversationIDsLocked(at: root)
            guard visible.isEmpty else {
                throw BrineStepError(
                    "the replacement account can see \(visible.sorted())")
            }
        }
    }

    func assertSecondAccountCannotReadFirstFiles() throws {
        try queue.sync {
            guard let firstRoot = state.firstRoot,
                  let secondRoot = state.secondRoot,
                  firstRoot != secondRoot else {
                throw BrineStepError("the two accounts did not resolve distinct roots")
            }
            for id in state.firstConversationIDs {
                let replacementCopy = secondRoot
                    .appendingPathComponent(id, isDirectory: true)
                    .appendingPathComponent(CaptureWAL.segName(0))
                guard !fileManager.fileExists(atPath: replacementCopy.path),
                      let original = state.firstSegments[id],
                      fileManager.fileExists(atPath: original.path) else {
                    throw BrineStepError(
                        "the first account's \(id) crossed roots or was lost")
                }
            }
        }
    }

    func secondAccountRecordedConversation() throws {
        try queue.sync {
            try CaptureAccountScope.signOutForTests()
            let identity = try makeIdentity(
                provider: .google, subject: secondSubject, email: secondEmail)
            state.secondIdentity = identity
            let root = try activateLocked(identity)
            state.secondRoot = root
            let id = conversationID("second")
            state.secondConversationID = id
            state.secondSegment = try recordConversationLocked(
                id: id, expectedRoot: root, byte: 42)
        }
    }

    func useFirstAccountAgain() throws {
        try queue.sync {
            guard let identity = state.firstIdentity else {
                throw BrineStepError("the original identity was not prepared")
            }
            state.reResolvedFirstRoot = try activateLocked(identity)
            CaptureAccountScope.resetProcessCacheForTests()
            state.firstRoot = CaptureWAL.documentsCaptures()
        }
    }

    func assertFirstAccountHasExactlyItsConversations() throws {
        try queue.sync {
            guard let identity = state.firstIdentity,
                  let beforeRelaunch = state.reResolvedFirstRoot,
                  let afterRelaunch = state.firstRoot else {
                throw BrineStepError("the original account was not reopened")
            }
            let expected = captureContainer.appendingPathComponent(
                try CaptureAccountScope.key(for: identity), isDirectory: true)
            guard beforeRelaunch == expected, afterRelaunch == expected else {
                throw BrineStepError(
                    "the stable account root changed across process-cache reset")
            }
            let visible = conversationIDsLocked(at: afterRelaunch)
            guard visible == state.firstConversationIDs else {
                throw BrineStepError(
                    "expected \(state.firstConversationIDs.sorted()), found \(visible.sorted())")
            }
        }
    }

    func assertSecondConversationIsAbsentFromFirst() throws {
        try queue.sync {
            guard let firstRoot = state.firstRoot,
                  let secondRoot = state.secondRoot,
                  let id = state.secondConversationID,
                  let segment = state.secondSegment else {
                throw BrineStepError("the replacement conversation was not prepared")
            }
            guard !fileManager.fileExists(
                atPath: firstRoot.appendingPathComponent(id).path),
                  fileManager.fileExists(atPath: segment.path),
                  segment.path.hasPrefix(secondRoot.path + "/") else {
                throw BrineStepError(
                    "the replacement conversation crossed roots or was lost")
            }
        }
    }

    // MARK: - Biometric and named-speaker data

    func taughtVoiceAndNamedSpeakerForFirstAccount() throws {
        try queue.sync {
            try beginScenarioLocked()
            let identity = try makeIdentity(
                provider: .google, subject: firstSubject, email: firstEmail)
            state.firstIdentity = identity
            let root = try activateLocked(identity)
            state.firstRoot = root

            let frames = Array(
                repeating: Data([0x01, 0x02, 0x03]),
                count: OwnerVoiceStore.minimumFrames)
            try OwnerVoiceStore.save(frames: frames, baseDir: root, now: 1)
            let name = "Speaker-\(token)"
            SpeakerConfirmQueue.enqueue(
                captureId: conversationID("speaker"),
                slot: "speaker_0",
                name: name,
                baseDir: root,
                now: 1)
            state.namedSpeaker = name
            guard OwnerVoiceStore.state(baseDir: root) == .recorded(at: 1),
                  SpeakerConfirmQueue.pending(baseDir: root).contains(
                    where: { $0.name == name }) else {
                throw BrineStepError("the first account's private voice data was not stored")
            }
        }
    }

    func useSecondAccount() throws {
        try queue.sync {
            let identity = try makeIdentity(
                provider: .google, subject: secondSubject, email: secondEmail)
            state.secondIdentity = identity
            state.secondRoot = try activateLocked(identity)
        }
    }

    func assertSecondAccountHasNoOwnerVoice() throws {
        try queue.sync {
            guard let firstRoot = state.firstRoot,
                  let secondRoot = state.secondRoot else {
                throw BrineStepError("voice isolation roots were not prepared")
            }
            guard OwnerVoiceStore.state(baseDir: secondRoot) == .none,
                  OwnerVoiceStore.sampleFrames(baseDir: secondRoot).isEmpty,
                  !fileManager.fileExists(
                    atPath: OwnerVoiceStore.sampleURL(baseDir: secondRoot).path),
                  OwnerVoiceStore.state(baseDir: firstRoot) == .recorded(at: 1) else {
                throw BrineStepError("the owner voice crossed accounts or was lost")
            }
        }
    }

    func assertSecondAccountHasNoNamedSpeakers() throws {
        try queue.sync {
            guard let firstRoot = state.firstRoot,
                  let secondRoot = state.secondRoot,
                  let name = state.namedSpeaker else {
                throw BrineStepError("named-speaker isolation was not prepared")
            }
            guard SpeakerConfirmQueue.pending(baseDir: secondRoot).isEmpty,
                  !fileManager.fileExists(
                    atPath: SpeakerConfirmQueue.url(baseDir: secondRoot).path),
                  SpeakerConfirmQueue.pending(baseDir: firstRoot).contains(
                    where: { $0.name == name }) else {
                throw BrineStepError("a named speaker crossed accounts or was lost")
            }
        }
    }

    // MARK: - Legacy capture ownership

    func recordedLegacyConversations() throws {
        try queue.sync {
            try beginScenarioLocked()
            let id = conversationID("legacy")
            let segment = try recordConversationLocked(
                id: id,
                expectedRoot: captureContainer,
                byte: 73,
                explicitBaseDir: captureContainer)
            guard let bytes = try? Data(contentsOf: segment),
                  let fileNumber = fileNumberLocked(segment) else {
                throw BrineStepError("could not snapshot the legacy recording")
            }
            state.legacyCaptureID = id
            state.legacySourceSegment = segment
            state.legacyBytes = bytes
            state.legacyFileNumber = fileNumber
        }
    }

    func ownerAccountClaimsLegacyConversations() throws {
        try queue.sync {
            let identity = try makeIdentity(
                provider: .google, subject: firstSubject, email: firstEmail)
            state.firstIdentity = identity
            let root = try activateLocked(identity)
            state.firstRoot = root
            state.legacyDestinationRoot = root
        }
    }

    func assertLegacyConversationsWereKept() throws {
        try queue.sync {
            guard let id = state.legacyCaptureID,
                  let source = state.legacySourceSegment,
                  let destinationRoot = state.legacyDestinationRoot,
                  let expectedBytes = state.legacyBytes,
                  let before = state.legacyFileNumber else {
                throw BrineStepError("legacy migration was not prepared")
            }
            let destination = destinationRoot
                .appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(CaptureWAL.segName(0))
            guard !fileManager.fileExists(atPath: source.path),
                  let actualBytes = try? Data(contentsOf: destination),
                  actualBytes == expectedBytes,
                  fileNumberLocked(destination) == before else {
                throw BrineStepError(
                    "the legacy recording was not moved intact into the owner root")
            }
        }
    }

    func assertLegacyConversationsBelongToOwner() throws {
        try queue.sync {
            guard let ownerIdentity = state.firstIdentity,
                  let ownerRoot = state.legacyDestinationRoot else {
                throw BrineStepError("the legacy owner was not activated")
            }
            let ownerScope = try CaptureAccountScope.key(for: ownerIdentity)
            let marker = captureContainer.appendingPathComponent(
                CaptureAccountScope.migrationMarker)
            guard (try? String(contentsOf: marker, encoding: .utf8)) == ownerScope else {
                throw BrineStepError("the durable ownership marker does not name the owner")
            }

            let residual = captureContainer.appendingPathComponent(
                "legacy-residual-\(token)-\(scenarioNumber)")
            let residualBytes = Data([0xaa, 0xbb, 0xcc])
            try residualBytes.write(to: residual, options: .withoutOverwriting)

            let laterIdentity = try makeIdentity(
                provider: .google, subject: secondSubject, email: secondEmail)
            let laterRoot = try activateLocked(laterIdentity)
            guard fileManager.fileExists(atPath: residual.path),
                  !fileManager.fileExists(
                    atPath: laterRoot.appendingPathComponent(
                        residual.lastPathComponent).path),
                  ownerRoot.lastPathComponent == ownerScope else {
                throw BrineStepError("a later account inherited residual legacy data")
            }
        }
    }

    // MARK: - Signed-out scope

    func signOut() throws {
        try queue.sync {
            try CaptureAccountScope.signOutForTests()
            state.signedOutRoot = CaptureWAL.documentsCaptures()
        }
    }

    func assertSignedOutCannotReadConversations() throws {
        try queue.sync {
            guard let firstRoot = state.firstRoot,
                  let signedOutRoot = state.signedOutRoot else {
                throw BrineStepError("signed-in and signed-out roots were not prepared")
            }
            guard signedOutRoot.lastPathComponent == CaptureAccountScope.signedOutScope,
                  signedOutRoot != firstRoot,
                  conversationIDsLocked(at: signedOutRoot).isEmpty else {
                throw BrineStepError("sign-out exposed an account recording library")
            }
            for id in state.firstConversationIDs {
                guard let original = state.firstSegments[id],
                      fileManager.fileExists(atPath: original.path),
                      !fileManager.fileExists(
                        atPath: signedOutRoot.appendingPathComponent(id).path) else {
                    throw BrineStepError("sign-out exposed or lost \(id)")
                }
            }
        }
    }

    // MARK: - Provider-qualified stable identity

    func googleStoredConversationForSharedEmail() throws {
        try queue.sync {
            try beginScenarioLocked()
            let sharedEmail = "shared-\(token)@example.com"
            let sharedSubject = "shared-subject-\(token)"
            let identity = try makeIdentity(
                provider: .google, subject: sharedSubject, email: sharedEmail)
            let root = try activateLocked(identity)
            state.providerGoogleRoot = root
            let id = conversationID("provider-google")
            state.providerConversationID = id
            state.providerSegment = try recordConversationLocked(
                id: id, expectedRoot: root, byte: 81)
        }
    }

    func microsoftUsesSharedEmail() throws {
        try queue.sync {
            let identity = try makeIdentity(
                provider: .microsoft,
                subject: "shared-subject-\(token)",
                email: "shared-\(token)@example.com")
            state.providerMicrosoftRoot = try activateLocked(identity)
        }
    }

    func assertMicrosoftHasDifferentEmptyLibrary() throws {
        try queue.sync {
            guard let google = state.providerGoogleRoot,
                  let microsoft = state.providerMicrosoftRoot,
                  google != microsoft,
                  conversationIDsLocked(at: microsoft).isEmpty else {
                throw BrineStepError(
                    "Google and Microsoft did not receive distinct empty/account libraries")
            }
        }
    }

    func assertGoogleConversationRemainsOnlyWithGoogle() throws {
        try queue.sync {
            guard let google = state.providerGoogleRoot,
                  let microsoft = state.providerMicrosoftRoot,
                  let id = state.providerConversationID,
                  let segment = state.providerSegment,
                  segment.path.hasPrefix(google.path + "/"),
                  fileManager.fileExists(atPath: segment.path),
                  !fileManager.fileExists(
                    atPath: microsoft.appendingPathComponent(id).path) else {
                throw BrineStepError("the Google conversation crossed provider roots")
            }
        }
    }

    func appleRecordedOnFirstAuthorization() throws {
        try queue.sync {
            try beginScenarioLocked()
            let identity = try makeIdentity(
                provider: .apple,
                subject: "apple-subject-\(token)",
                email: "apple-\(token)@privaterelay.appleid.com")
            let root = try activateLocked(identity)
            state.appleOriginalRoot = root
            let id = conversationID("apple")
            state.appleConversationID = id
            state.appleSegment = try recordConversationLocked(
                id: id, expectedRoot: root, byte: 91)
        }
    }

    func appleReauthorizesWithoutEmail() throws {
        try queue.sync {
            CaptureAccountScope.resetProcessCacheForTests()
            let identity = try makeIdentity(
                provider: .apple,
                subject: "apple-subject-\(token)",
                email: nil)
            state.appleReauthorizedRoot = try activateLocked(identity)
        }
    }

    func assertAppleRestoresOriginalLibrary() throws {
        try queue.sync {
            guard let original = state.appleOriginalRoot,
                  let restored = state.appleReauthorizedRoot,
                  let id = state.appleConversationID,
                  let segment = state.appleSegment,
                  original == restored,
                  conversationIDsLocked(at: restored).contains(id),
                  fileManager.fileExists(atPath: segment.path) else {
                throw BrineStepError(
                    "Apple reauthorization without email did not restore its subject library")
            }
        }
    }

    func assertAppleDidNotResolveSignedOut() throws {
        try queue.sync {
            guard let root = state.appleReauthorizedRoot,
                  root.lastPathComponent != CaptureAccountScope.signedOutScope,
                  CaptureAccountScope.currentAccountBinding()?.root == root else {
                throw BrineStepError("Apple's subject resolved to signed-out storage")
            }
        }
    }

    func googleUsesDecomposedAddress() throws {
        try queue.sync {
            try beginScenarioLocked()
            let decomposed = "caf\u{0065}\u{0301}-\(token)@example.com"
            let identity = try makeIdentity(
                provider: .google, subject: nil, email: decomposed)
            state.decomposedRoot = try activateLocked(identity)
        }
    }

    func googleReturnsWithComposedAddress() throws {
        try queue.sync {
            CaptureAccountScope.resetProcessCacheForTests()
            let composed = "caf\u{00E9}-\(token)@example.com"
            let identity = try makeIdentity(
                provider: .google, subject: nil, email: composed)
            state.composedRoot = try activateLocked(identity)
        }
    }

    func assertUnicodeRepresentationsShareLibrary() throws {
        try queue.sync {
            guard let decomposed = state.decomposedRoot,
                  let composed = state.composedRoot,
                  decomposed == composed,
                  composed.lastPathComponent != CaptureAccountScope.signedOutScope else {
                throw BrineStepError(
                    "canonically equivalent fallback emails minted different scopes")
            }
        }
    }

    // MARK: - Durable identity aliases and opaque subjects

    func emailFallbackOwnsRecordingLibrary() throws {
        try queue.sync {
            try beginScenarioLocked()
            let identity = try makeIdentity(
                provider: .google, subject: nil, email: firstEmail)
            let root = try activateLocked(identity)
            let id = conversationID("email-fallback")
            state.fallbackEmailRoot = root
            state.fallbackConversationID = id
            state.fallbackSegment = try recordConversationLocked(
                id: id, expectedRoot: root, byte: 0x31)
        }
    }

    func sameAccountReturnsWithSubject() throws {
        try queue.sync {
            let identity = try makeIdentity(
                provider: .google, subject: firstSubject, email: firstEmail)
            state.laterSubjectKey = try CaptureAccountScope.key(for: identity)
            state.laterSubjectRoot = try activateLocked(identity)
        }
    }

    func assertFallbackLibraryStillResolves() throws {
        try queue.sync {
            guard let original = state.fallbackEmailRoot,
                  let resolved = state.laterSubjectRoot,
                  let id = state.fallbackConversationID,
                  original == resolved,
                  conversationIDsLocked(at: resolved).contains(id),
                  let segment = state.fallbackSegment,
                  fileManager.fileExists(atPath: segment.path) else {
                throw BrineStepError(
                    "the later subject forked or lost the email-owned recording library")
            }
        }
    }

    func assertNoLaterSubjectLibraryWasCreated() throws {
        try queue.sync {
            guard let original = state.fallbackEmailRoot,
                  let subjectKey = state.laterSubjectKey else {
                throw BrineStepError("the fallback alias roots were not captured")
            }
            let subjectRoot = captureContainer.appendingPathComponent(
                subjectKey, isDirectory: true)
            guard subjectRoot == original
                    || !fileManager.fileExists(atPath: subjectRoot.path) else {
                throw BrineStepError(
                    "the later subject created a second account library")
            }
            let accountDirectories = (try? fileManager.contentsOfDirectory(
                at: captureContainer,
                includingPropertiesForKeys: [.isDirectoryKey]))?
                .filter {
                    $0.lastPathComponent.hasPrefix(CaptureAccountScope.scopePrefix)
                        && (try? $0.resourceValues(forKeys: [.isDirectoryKey])
                            .isDirectory) == true
                } ?? []
            guard accountDirectories.count == 1 else {
                throw BrineStepError(
                    "expected one account library, found \(accountDirectories.count)")
            }
        }
    }

    func failActiveOwnerDurabilityConfirmation() throws {
        try queue.sync {
            try beginScenarioLocked()
            CaptureAccountScope.setMarkerSyncFailureForTests(true)
        }
    }

    func attemptActivationWithPostCreateDurabilityFailure() throws {
        queue.sync {
            do {
                let identity = try makeIdentity(
                    provider: .google, subject: firstSubject, email: firstEmail)
                try CaptureAccountScope.activateForTests(identity)
                state.postCreateDurabilityFailure = nil
            } catch {
                state.postCreateDurabilityFailure = error
            }
        }
    }

    func assertPostCreateDurabilityFailureStayedClosed() throws {
        try queue.sync {
            guard state.postCreateDurabilityFailure != nil,
                  CaptureAccountScope.currentAccountBinding() == nil,
                  !FoundryAuth.hasPersistedSignIn else {
                throw BrineStepError(
                    "ACTIVE was published after durability confirmation failed")
            }
        }
    }

    func upperCaseSubjectOwnsRecording() throws {
        try queue.sync {
            try beginScenarioLocked()
            let identity = try makeIdentity(
                provider: .google,
                subject: "CaseSensitive-\(token)",
                email: nil)
            let root = try activateLocked(identity)
            let id = conversationID("case-sensitive")
            state.upperSubjectRoot = root
            state.caseSensitiveConversationID = id
            state.caseSensitiveSegment = try recordConversationLocked(
                id: id, expectedRoot: root, byte: 0x41)
        }
    }

    func lowerCaseSubjectSignsIn() throws {
        try queue.sync {
            let identity = try makeIdentity(
                provider: .google,
                subject: "casesensitive-\(token)",
                email: nil)
            state.lowerSubjectRoot = try activateLocked(identity)
        }
    }

    func assertCaseSensitiveSubjectGetsEmptyLibrary() throws {
        try queue.sync {
            guard let first = state.upperSubjectRoot,
                  let second = state.lowerSubjectRoot,
                  first != second,
                  conversationIDsLocked(at: second).isEmpty else {
                throw BrineStepError(
                    "case-distinct opaque subjects resolved to the same library")
            }
        }
    }

    func assertUpperSubjectRecordingStayedPrivate() throws {
        try queue.sync {
            guard let first = state.upperSubjectRoot,
                  let second = state.lowerSubjectRoot,
                  let id = state.caseSensitiveConversationID,
                  conversationIDsLocked(at: first).contains(id),
                  !conversationIDsLocked(at: second).contains(id),
                  let segment = state.caseSensitiveSegment,
                  fileManager.fileExists(atPath: segment.path) else {
                throw BrineStepError(
                    "the first case-sensitive subject's recording crossed accounts")
            }
        }
    }

    // MARK: - Chat isolation and legacy chat migration

    func firstAccountHasDurableChat(title: String) throws {
        try queue.sync {
            try beginScenarioLocked()
            let identity = try makeIdentity(
                provider: .google, subject: firstSubject, email: firstEmail)
            state.firstIdentity = identity
            state.firstRoot = try activateLocked(identity)
            try persistChatLocked(title: title)
            state.firstChatTitle = title
        }
    }

    func secondAccountCreatesDurableChat(title: String) throws {
        try queue.sync {
            let identity = try makeIdentity(
                provider: .google, subject: secondSubject, email: secondEmail)
            state.secondIdentity = identity
            state.secondRoot = try activateLocked(identity)
            try persistChatLocked(title: title)
            state.secondChatTitle = title
        }
    }

    func firstAccountReopensChat() throws {
        try queue.sync {
            guard let identity = state.firstIdentity else {
                throw BrineStepError("the first chat owner identity is missing")
            }
            _ = try activateLocked(identity)
            let reopened = ChatConversationStore(
                storageURL: ChatConversationStore.defaultStorageURL())
            state.reopenedFirstChatTitles = Set(reopened.conversations.map(\.title))
        }
    }

    func assertOnlyFirstChatReturns(_ expected: String) throws {
        try queue.sync {
            guard expected == state.firstChatTitle,
                  state.reopenedFirstChatTitles.contains(expected),
                  state.reopenedFirstChatTitles.filter({ $0 == expected }).count == 1 else {
                throw BrineStepError(
                    "the first account's durable chat did not return exactly once")
            }
        }
    }

    func assertSecondChatAbsentFromFirst(_ second: String) throws {
        try queue.sync {
            guard second == state.secondChatTitle,
                  !state.reopenedFirstChatTitles.contains(second) else {
                throw BrineStepError("the second account's chat appeared in the first chat list")
            }
        }
    }

    func unscopedChatContains(title: String) throws {
        try queue.sync {
            try beginScenarioLocked()
            let legacyURL = applicationSupportRoot
                .appendingPathComponent("FoundryX", isDirectory: true)
                .appendingPathComponent("chat-conversations.json")
            let store = ChatConversationStore(storageURL: legacyURL)
            store.setMessages(
                [.init(role: "user", text: title)],
                for: store.activeId)
            guard fileManager.fileExists(atPath: legacyURL.path),
                  let number = fileNumberLocked(legacyURL) else {
                throw BrineStepError("the hermetic legacy chat file was not persisted")
            }
            state.legacyChatTitle = title
            state.legacyChatURL = legacyURL
            state.legacyChatFileNumber = number
        }
    }

    func firstProviderClaimsExistingPrivateData() throws {
        try queue.sync {
            let identity = try makeIdentity(
                provider: .google, subject: firstSubject, email: firstEmail)
            state.firstIdentity = identity
            let root = try activateLocked(identity)
            state.firstRoot = root
            state.migratedLegacyChatURL = ChatConversationStore.storageURL(
                inAccountRoot: root)
        }
    }

    func assertLegacyChatMoved(_ expected: String) throws {
        try queue.sync {
            guard expected == state.legacyChatTitle,
                  let source = state.legacyChatURL,
                  let destination = state.migratedLegacyChatURL,
                  let fileNumber = state.legacyChatFileNumber,
                  !fileManager.fileExists(atPath: source.path),
                  fileManager.fileExists(atPath: destination.path),
                  fileNumberLocked(destination) == fileNumber else {
                throw BrineStepError("the legacy chat file was not moved into its owner root")
            }
            let store = ChatConversationStore(storageURL: destination)
            guard store.conversations.map(\.title).contains(expected) else {
                throw BrineStepError("the moved legacy chat could not be reopened")
            }
        }
    }

    func assertLaterProviderCannotClaimLegacyChat() throws {
        try queue.sync {
            guard let title = state.legacyChatTitle,
                  let destination = state.migratedLegacyChatURL else {
                throw BrineStepError("legacy chat ownership was not prepared")
            }
            let later = try makeIdentity(
                provider: .microsoft,
                subject: "later-chat-\(token)",
                email: firstEmail)
            let laterRoot = try activateLocked(later)
            let laterStore = ChatConversationStore(
                storageURL: ChatConversationStore.storageURL(inAccountRoot: laterRoot))
            guard !laterStore.conversations.map(\.title).contains(title),
                  fileManager.fileExists(atPath: destination.path) else {
                throw BrineStepError("a later provider claimed the owner's legacy chat")
            }
        }
    }

    // MARK: - Locked background restoration

    func persistOpaqueOwnerScope() throws {
        try queue.sync {
            try beginScenarioLocked()
            let identity = try makeIdentity(
                provider: .google, subject: firstSubject, email: firstEmail)
            state.firstIdentity = identity
            state.lockedOwnerRoot = try activateLocked(identity)
            guard FoundryAuth.hasPersistedSignIn else {
                throw BrineStepError("activation did not durably seed the owner scope")
            }
        }
    }

    func relaunchLockedAndSpoolAudio() throws {
        try queue.sync {
            guard let ownerRoot = state.lockedOwnerRoot else {
                throw BrineStepError("the locked owner root was not seeded")
            }
            CaptureAccountScope.resetProcessCacheForTests()
            guard FoundryAuth.hasPersistedSignIn,
                  CaptureWAL.documentsCaptures() == ownerRoot else {
                throw BrineStepError(
                    "the locked relaunch could not recover the durable owner scope")
            }

            let spool = OmiRestorationSpool(
                log: nil, silenceGap: 0, paused: { false })
            spool.handleState(.streaming)
            guard let captureID = spool.activeCaptureId else {
                throw BrineStepError("the restoration spool did not open a capture")
            }
            spool.append(Data([0x11, 0x22, 0x33]))
            guard spool.spooledFrameCount == 1 else {
                throw BrineStepError("the restoration spool did not accept authenticated audio")
            }
            spool.detach()

            let segment = ownerRoot
                .appendingPathComponent(captureID, isDirectory: true)
                .appendingPathComponent(CaptureWAL.segName(0))
            state.lockedCaptureID = captureID
            state.lockedSegment = segment
        }
    }

    func assertRestoredAudioTargetsOwner() throws {
        try queue.sync {
            guard let root = state.lockedOwnerRoot,
                  let segment = state.lockedSegment,
                  segment.path.hasPrefix(root.path + "/"),
                  fileManager.fileExists(atPath: segment.path) else {
                throw BrineStepError("restored audio was not written to the durable owner root")
            }
        }
    }

    func assertRestoredAudioAvoidsSignedOut() throws {
        try queue.sync {
            guard let captureID = state.lockedCaptureID else {
                throw BrineStepError("the restoration capture id is missing")
            }
            let signedOutSegment = captureContainer
                .appendingPathComponent(
                    CaptureAccountScope.signedOutScope, isDirectory: true)
                .appendingPathComponent(captureID, isDirectory: true)
                .appendingPathComponent(CaptureWAL.segName(0))
            guard !fileManager.fileExists(atPath: signedOutSegment.path) else {
                throw BrineStepError("authenticated restoration audio landed in acct-none")
            }
        }
    }

    // MARK: - Fallible ownership and collision recovery

    func makeOwnershipClaimUnwritable() throws {
        try queue.sync {
            try beginScenarioLocked()
            let marker = captureContainer.appendingPathComponent(
                CaptureAccountScope.migrationMarker, isDirectory: true)
            try fileManager.createDirectory(
                at: marker, withIntermediateDirectories: true)
        }
    }

    func attemptActivationWithFailedClaim() throws {
        queue.sync {
            do {
                let identity = try makeIdentity(
                    provider: .google, subject: firstSubject, email: firstEmail)
                try CaptureAccountScope.activateForTests(identity)
                state.activationFailure = nil
            } catch {
                state.activationFailure = error
            }
        }
    }

    func assertActivationFailedClosed() throws {
        try queue.sync {
            guard state.activationFailure != nil,
                  CaptureAccountScope.currentAccountBinding() == nil,
                  !FoundryAuth.hasPersistedSignIn else {
                throw BrineStepError(
                    "a failed ownership claim still exposed an active account")
            }
            let root = CaptureWAL.documentsCaptures()
            guard !root.path.hasPrefix(captureContainer.path + "/"),
                  root.path.contains("account-scope-unavailable") else {
                throw BrineStepError(
                    "a failed ownership claim exposed a usable private root: \(root.path)")
            }
            do {
                try Data([0xff]).write(to: root.appendingPathComponent("must-not-write"))
                throw BrineStepError("the fail-closed root unexpectedly accepted private data")
            } catch is BrineStepError {
                throw BrineStepError("the fail-closed root unexpectedly accepted private data")
            } catch {
                // Expected: the sentinel root is deliberately unwritable.
            }
        }
    }

    func stageMigrationCollision() throws {
        try queue.sync {
            try beginScenarioLocked()
            let identity = try makeIdentity(
                provider: .google, subject: firstSubject, email: firstEmail)
            state.firstIdentity = identity
            let expectedRoot = captureContainer.appendingPathComponent(
                try CaptureAccountScope.key(for: identity), isDirectory: true)
            let name = conversationID("collision")
            let sourceDir = captureContainer.appendingPathComponent(
                name, isDirectory: true)
            let destinationDir = expectedRoot.appendingPathComponent(
                name, isDirectory: true)
            try fileManager.createDirectory(
                at: sourceDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: destinationDir, withIntermediateDirectories: true)
            let legacyBytes = Data([0x10, 0x20, 0x30])
            let scopedBytes = Data([0xa0, 0xb0, 0xc0])
            let sourceSegment = sourceDir.appendingPathComponent(CaptureWAL.segName(0))
            let destinationSegment = destinationDir.appendingPathComponent(
                CaptureWAL.segName(0))
            try legacyBytes.write(to: sourceSegment, options: .withoutOverwriting)
            try scopedBytes.write(to: destinationSegment, options: .withoutOverwriting)
            state.collisionSource = sourceDir
            state.collisionDestination = destinationDir
            state.collisionLegacyBytes = legacyBytes
            state.collisionScopedBytes = scopedBytes
        }
    }

    func attemptCollidingMigration() throws {
        queue.sync {
            do {
                guard let identity = state.firstIdentity else {
                    throw BrineStepError("the collision owner identity is missing")
                }
                try CaptureAccountScope.activateForTests(identity)
                state.collisionError = nil
            } catch {
                state.collisionError = error
                if let scopeError = error as? CaptureAccountScopeError,
                   case .legacyDestinationCollision(
                    _, _, let recoveryPath) = scopeError {
                    state.collisionRecovery = URL(fileURLWithPath: recoveryPath)
                }
            }
        }
    }

    func assertCollisionReported() throws {
        try queue.sync {
            guard let error = state.collisionError as? CaptureAccountScopeError,
                  case .legacyDestinationCollision = error,
                  error.localizedDescription.contains("Both versions were kept") else {
                throw BrineStepError(
                    "the recovered collision was not surfaced to account activation")
            }
        }
    }

    func assertCollisionVersionsRemainIntact() throws {
        try queue.sync {
            guard let source = state.collisionSource,
                  let destination = state.collisionDestination,
                  let recovery = state.collisionRecovery,
                  let legacyBytes = state.collisionLegacyBytes,
                  let scopedBytes = state.collisionScopedBytes,
                  let identity = state.firstIdentity else {
                throw BrineStepError("collision recovery state is incomplete")
            }
            let ownerRoot = captureContainer.appendingPathComponent(
                try CaptureAccountScope.key(for: identity), isDirectory: true)
            let recoveredSegment = recovery.appendingPathComponent(CaptureWAL.segName(0))
            let scopedSegment = destination.appendingPathComponent(CaptureWAL.segName(0))
            guard !fileManager.fileExists(atPath: source.path),
                  recovery.path.hasPrefix(ownerRoot.path + "/"),
                  (try? Data(contentsOf: recoveredSegment)) == legacyBytes,
                  (try? Data(contentsOf: scopedSegment)) == scopedBytes else {
                throw BrineStepError(
                    "collision recovery clobbered or stranded one version")
            }
        }
    }

    // MARK: - Widget/broker identity transition

    func seedWidgetAndPendingState() async throws {
        try queue.sync { try beginScenarioLocked() }
        await drainMainQueue()

        let probe = IdentityTransitionProbe()
        let before = await probe.transitionCount
        try queue.sync {
            state.transitionProbe = probe
            let identity = try makeIdentity(
                provider: .google, subject: firstSubject, email: firstEmail)
            state.firstIdentity = identity
            state.firstRoot = try activateLocked(identity)
        }
        await probe.wait(untilAtLeast: before + 2)
        await probe.seedEveryPendingValue()

        try queue.sync {
            guard let binding = CaptureAccountScope.currentAccountBinding() else {
                throw BrineStepError("the widget producer has no account binding")
            }
            CaptureWidgetSnapshotStore.write(CaptureWidgetSnapshot(
                phase: .idle,
                lastFinishedTitle: "Private widget title \(token)",
                lastFinishedAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 11)), as: binding)
            guard CaptureWidgetSnapshotStore.read().lastFinishedTitle != nil else {
                throw BrineStepError("the first account's widget snapshot was not stored")
            }
        }
    }

    func transitionPhoneToSecondAccount() async throws {
        guard let probe = queue.sync(execute: { state.transitionProbe }) else {
            throw BrineStepError("the identity-transition observer is missing")
        }
        let before = await probe.transitionCount
        try queue.sync {
            let identity = try makeIdentity(
                provider: .google, subject: secondSubject, email: secondEmail)
            state.secondIdentity = identity
            state.secondRoot = try activateLocked(identity)
        }
        await probe.wait(untilAtLeast: before + 2)
    }

    func assertWidgetIsIdleForSecondAccount() throws {
        try queue.sync {
            let snapshot = CaptureWidgetSnapshotStore.read()
            guard snapshot.phase == .idle,
                  snapshot.lastFinishedTitle == nil,
                  snapshot.lastFinishedAt == nil else {
                throw BrineStepError(
                    "the replacement account inherited the previous widget title")
            }
        }
    }

    func assertEveryPendingValueWasCleared() async throws {
        guard let probe = queue.sync(execute: { state.transitionProbe }) else {
            throw BrineStepError("the identity-transition observer is missing")
        }
        let remaining = await probe.pendingValues
        guard remaining.isEmpty else {
            throw BrineStepError(
                "identity notification left pending values: \(remaining.sorted())")
        }
    }

    /// A REAL fresh install: no activation record at all, and no identity. Distinct
    /// from `prepareSignedOutOnDeviceCapture`, which seeds a signedOut record — that
    /// seeding is precisely why the free tier could be fail-closed on a new phone while
    /// this suite stayed green (build 300, Nick 2026-07-25).
    func prepareFreshInstallWithNoActivationRecord() throws {
        try queue.sync {
            try beginScenarioLocked()
            scopeDefaults.removeObject(forKey: "foundryx.capture-account-activation.v2")
            scopeDefaults.removeObject(forKey: "foundryx.auth.signed-in")
            CaptureAccountScope.resetProcessCacheForTests()
        }
    }

    /// A new phone must be able to RECORD before anyone signs in: a writable root
    /// inside the real container, and a binding so every producer (widget, Live
    /// Activity, ambient) still works. Resolving `.blocked` here sent the capture root
    /// to an unwritable fail-closed path and killed the whole free tier.
    func assertFreshInstallCanRecord() throws {
        try queue.sync {
            let root = CaptureWAL.documentsCaptures()
            guard root.lastPathComponent == CaptureAccountScope.signedOutScope else {
                throw BrineStepError(
                    "a fresh install resolved \(root.path) instead of the on-device scope")
            }
            guard root.path.hasPrefix(captureContainer.path) else {
                throw BrineStepError(
                    "a fresh install resolved outside its container: \(root.path)")
            }
            // Writable in fact, not just in name — the regression produced a path
            // under /dev/null that every write would have failed against.
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            let probe = root.appendingPathComponent(".fresh-install-write-probe")
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            guard CaptureAccountScope.currentAccountBinding() != nil else {
                throw BrineStepError(
                    "a fresh install produced no AccountBinding, so every bound "
                        + "producer (widget, Live Activity, ambient) silently no-ops")
            }
        }
    }

    func prepareSignedOutOnDeviceCapture() throws {
        try queue.sync {
            try beginScenarioLocked()
            let signedOutRecord = try JSONSerialization.data(
                withJSONObject: [
                    "phase": "signedOut",
                    "aliases": [String: String](),
                ],
                options: [.sortedKeys])
            scopeDefaults.set(
                signedOutRecord,
                forKey: "foundryx.capture-account-activation.v2")
            CaptureAccountScope.resetProcessCacheForTests()
            guard CaptureWAL.documentsCaptures().lastPathComponent
                    == CaptureAccountScope.signedOutScope else {
                throw BrineStepError(
                    "signed-out capture did not resolve its isolated on-device scope")
            }
        }
    }

    func publishSignedOutGlanceableState() {
        queue.sync {
            guard let binding = CaptureAccountScope.currentAccountBinding() else {
                state.signedOutGlanceableWriteAccepted = false
                return
            }
            state.signedOutGlanceableWriteAccepted =
                CaptureWidgetSnapshotStore.write(
                    CaptureWidgetSnapshot(
                        phase: .recordingActive,
                        sourceLabel: "Phone",
                        sourceSymbol: "mic.fill",
                        startedAt: Date(timeIntervalSince1970: 20),
                        updatedAt: Date(timeIntervalSince1970: 21)),
                    as: binding)
        }
    }

    func assertSignedOutGlanceableStateIsCurrent() throws {
        try queue.sync {
            let snapshot = CaptureWidgetSnapshotStore.read()
            guard state.signedOutGlanceableWriteAccepted,
                  snapshot.phase == .recordingActive,
                  snapshot.sourceLabel == "Phone",
                  snapshot.startedAt == Date(timeIntervalSince1970: 20) else {
                throw BrineStepError(
                    "signed-out on-device capture did not update glanceable state")
            }
        }
    }

    // MARK: - Stale AccountBinding guard

    func suspendAmbientAnswerForFirstAccount() throws {
        try queue.sync {
            try beginScenarioLocked()
            let identity = try makeIdentity(
                provider: .google, subject: firstSubject, email: firstEmail)
            state.firstIdentity = identity
            state.firstRoot = try activateLocked(identity)
            guard let binding = CaptureAccountScope.currentAccountBinding() else {
                throw BrineStepError("ambient work could not capture its account binding")
            }
            state.staleBinding = binding
        }
    }

    func activateSecondBeforeAmbientCompletion() throws {
        try queue.sync {
            let identity = try makeIdentity(
                provider: .google, subject: secondSubject, email: secondEmail)
            state.secondIdentity = identity
            let secondRoot = try activateLocked(identity)
            state.staleSecondRoot = secondRoot

            guard let binding = state.staleBinding else {
                throw BrineStepError("the suspended work lost its starting binding")
            }
            if binding.isCurrent {
                let line = Data("{\"answer\":\"private A answer\"}\n".utf8)
                try line.write(
                    to: binding.root.appendingPathComponent("ambient-answers.jsonl"))
                state.staleRejected = false
            } else {
                state.staleRejected = true
            }
        }
    }

    func assertStaleWorkWasRejected() throws {
        try queue.sync {
            guard state.staleRejected,
                  let binding = state.staleBinding,
                  !binding.isCurrent else {
                throw BrineStepError(
                    "A's suspended AccountBinding remained valid after the switch")
            }
        }
    }

    func assertFirstAnswerAbsentFromSecondLedger() throws {
        try queue.sync {
            guard let secondRoot = state.staleSecondRoot else {
                throw BrineStepError("the second account root is missing")
            }
            let ledger = secondRoot.appendingPathComponent("ambient-answers.jsonl")
            let contents = (try? String(contentsOf: ledger, encoding: .utf8)) ?? ""
            guard !contents.contains("private A answer") else {
                throw BrineStepError("A's answer was appended to B's activity ledger")
            }
        }
    }

    // MARK: - Bound producer completions

    func suspendWidgetWorkForFirstAccount() throws {
        try suspendProducerLocked(kind: "widget")
    }

    func completeWidgetAfterSecondAccount() throws {
        try queue.sync {
            try activateReplacementForStaleProducerLocked()
            guard let binding = state.staleBinding else {
                throw BrineStepError("widget work lost its originating binding")
            }
            state.staleRejected = !CaptureWidgetSnapshotStore.write(
                CaptureWidgetSnapshot(
                    phase: .idle,
                    lastFinishedTitle: "private A widget title",
                    updatedAt: Date()),
                as: binding)
        }
    }

    func assertSecondWidgetRemainsIdle() throws {
        try queue.sync {
            let snapshot = CaptureWidgetSnapshotStore.read()
            guard snapshot == .idle else {
                throw BrineStepError("stale A widget content was published for B")
            }
        }
    }

    func suspendAmbientDismissalForFirstAccount() throws {
        try suspendProducerLocked(kind: "ambient-dismissal")
    }

    func completeAmbientDismissalAfterSecondAccount() throws {
        try completeJSONProducerAfterSwitch(
            file: "ambient-cards.jsonl",
            payload: #"{"outcome":"dismissed","seed":"private A"}\n"#)
    }

    func assertNoFirstOutcomeInSecondLedger() throws {
        try assertSecondRootExcludes(
            "private A", file: "ambient-cards.jsonl",
            failure: "A's dismissal was appended to B's ledger")
    }

    func suspendChatToolActivityForFirstAccount() throws {
        try suspendProducerLocked(kind: "chat-tool")
    }

    func completeChatToolAfterSecondAccount() throws {
        try completeJSONProducerAfterSwitch(
            file: "ambient-answers.jsonl",
            payload: #"{"kind":"agent_run","answer":"private A tool"}\n"#)
    }

    func assertNoFirstToolInSecondLedger() throws {
        try assertSecondRootExcludes(
            "private A tool", file: "ambient-answers.jsonl",
            failure: "A's tool activity was appended to B's ledger")
    }

    func suspendDoorTranscriptForFirstAccount() throws {
        try queue.sync {
            try suspendProducerLockedBody(kind: "door-transcript")
            state.staleProducerCaptureID = conversationID("door-transcript")
        }
    }

    func completeDoorTranscriptAfterSecondAccount() throws {
        try queue.sync {
            try activateReplacementForStaleProducerLocked()
            guard let binding = state.staleBinding,
                  let captureID = state.staleProducerCaptureID else {
                throw BrineStepError("Door transcript work lost its originating state")
            }
            let entry = CachedTranscript(
                transcript: "private A full transcript",
                title: "A title", summary: nil, fetchedAt: 1)
            state.staleRejected = CaptureAccountScope.perform(
                as: binding,
                { captured in
                    TranscriptCacheStore.save(
                        entry, captureId: captureID, baseDir: captured.root)
                    return true
                }) != true
        }
    }

    func assertNoFirstTranscriptInSecondCache() throws {
        try queue.sync {
            guard let secondRoot = state.staleSecondRoot,
                  let captureID = state.staleProducerCaptureID else {
                throw BrineStepError("the replacement transcript root is missing")
            }
            guard TranscriptCacheStore.load(
                captureId: captureID, baseDir: secondRoot) == nil else {
                throw BrineStepError("A's full transcript was cached into B")
            }
        }
    }

    func seedLiveActivityForFirstAccount() throws {
        try queue.sync {
            try suspendProducerLockedBody(kind: "live-activity")
            state.liveActivityContent = "private A title and transcript"
        }
    }

    func transitionLiveActivityToSecondAccount() async throws {
        try queue.sync {
            try activateReplacementForStaleProducerLocked()
            if let binding = state.staleBinding, !binding.isCurrent {
                state.liveActivityContent = nil
                state.liveActivityEnded = true
            }
        }
        await drainMainQueue()
    }

    func assertFirstLiveActivityEnded() throws {
        try queue.sync {
            guard state.liveActivityEnded else {
                throw BrineStepError("the first account's Live Activity remained active")
            }
        }
    }

    func assertNoLiveActivityContentForSecondAccount() throws {
        try queue.sync {
            guard state.liveActivityContent == nil else {
                throw BrineStepError(
                    "the replacement account inherited Live Activity content")
            }
        }
    }

    func assertStaleProducerWasRejected() throws {
        try queue.sync {
            guard state.staleRejected,
                  let binding = state.staleBinding,
                  !binding.isCurrent else {
                throw BrineStepError(
                    "the stale producer passed the account completion gate")
            }
        }
    }

    private func suspendProducerLocked(kind: String) throws {
        try queue.sync { try suspendProducerLockedBody(kind: kind) }
    }

    private func suspendProducerLockedBody(kind: String) throws {
        try beginScenarioLocked()
        let identity = try makeIdentity(
            provider: .google, subject: firstSubject, email: firstEmail)
        state.firstIdentity = identity
        state.firstRoot = try activateLocked(identity)
        guard let binding = CaptureAccountScope.currentAccountBinding() else {
            throw BrineStepError("\(kind) could not capture its account binding")
        }
        state.staleBinding = binding
        state.staleProducerKind = kind
    }

    private func activateReplacementForStaleProducerLocked() throws {
        let identity = try makeIdentity(
            provider: .google, subject: secondSubject, email: secondEmail)
        state.secondIdentity = identity
        let secondRoot = try activateLocked(identity)
        state.secondRoot = secondRoot
        state.staleSecondRoot = secondRoot
    }

    private func completeJSONProducerAfterSwitch(
        file: String, payload: String
    ) throws {
        try queue.sync {
            try activateReplacementForStaleProducerLocked()
            guard let binding = state.staleBinding else {
                throw BrineStepError("stale producer lost its originating binding")
            }
            let data = Data(payload.utf8)
            state.staleRejected = try CaptureAccountScope.perform(
                as: binding,
                { captured in
                    try data.write(
                        to: captured.root.appendingPathComponent(file))
                    return true
                }) != true
        }
    }

    private func assertSecondRootExcludes(
        _ text: String, file: String, failure: String
    ) throws {
        try queue.sync {
            guard let root = state.staleSecondRoot else {
                throw BrineStepError("the replacement producer root is missing")
            }
            let contents = (try? String(
                contentsOf: root.appendingPathComponent(file),
                encoding: .utf8)) ?? ""
            guard !contents.contains(text) else { throw BrineStepError(failure) }
        }
    }

    // MARK: - Hermetic support

    private func beginScenarioLocked() throws {
        pairingHarness?.cleanup()
        pairingHarness = nil
        state.transitionProbe?.stop()
        state.transitionProbe = nil
        for service in [cellKeychainService, doorKeychainService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            SecItemDelete(query as CFDictionary)
        }
        CaptureWidgetSnapshotStore.transition(toOwner: nil)
        CaptureWidgetSnapshotStore.resetDefaultsForTesting()
        CaptureAccountScope.resetTestEnvironment()

        try validateSandbox()
        for directory in [captureContainer, applicationSupportRoot]
            where fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        scopeDefaults.removePersistentDomain(forName: scopeDefaultsName)
        widgetDefaults.removePersistentDomain(forName: widgetDefaultsName)
        scenarioNumber += 1
        state = State()
        installTestEnvironmentLocked()
        CaptureAccountScope.resetProcessCacheForTests()
    }

    private func installTestEnvironmentLocked() {
        CaptureAccountScope.setContainerForTests(captureContainer)
        CaptureAccountScope.setApplicationSupportRootForTests(applicationSupportRoot)
        CaptureAccountScope.setDefaultsForTests(scopeDefaults)
        CaptureAccountScope.setPairingKeychainServicesForTests(
            cell: cellKeychainService,
            door: doorKeychainService)
        CaptureWidgetSnapshotStore.setDefaultsForTesting(widgetDefaults)
        CaptureWidgetSnapshotStore.transition(toOwner: nil)
    }

    private func addLegacySecretLocked(
        _ value: String,
        service: String
    ) throws {
        // Idempotent: more than one scenario in a feature run stages legacy pairing
        // against the same per-world service, and a bare SecItemAdd fails the second
        // time with errSecDuplicateItem (-25299). Clear first — the service name is
        // namespaced to this world, so this can only remove our own fixture.
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BrineStepError(
                "the test host could not stage legacy Keychain item \(service) "
                    + "(\(status))")
        }
    }

    private func secretLocked(
        service: String,
        account: String
    ) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(
            query as CFDictionary,
            &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func validateSandbox() throws {
        let temp = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate = sandbox
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == temp,
              candidate.pathComponents.count == temp.pathComponents.count + 1,
              candidate.lastPathComponent.hasPrefix(
                "foundryx-account-data-isolation-\(token)") else {
            throw BrineStepError(
                "refusing recursive cleanup outside the UUID temporary sandbox: "
                    + candidate.path)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeIdentity(
        provider: AuthProvider,
        subject: String?,
        email: String?
    ) throws -> AuthIdentity {
        var claims: [String: Any] = [:]
        if let subject { claims["sub"] = subject }
        if let email { claims["email"] = email }
        let payload = try JSONSerialization.data(
            withJSONObject: claims, options: [.sortedKeys])
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8)
        let jwt = [
            Self.base64URL(header),
            Self.base64URL(payload),
            "test-signature",
        ].joined(separator: ".")
        return AuthIdentity(
            provider: provider.rawValue,
            idToken: jwt,
            refreshToken: nil,
            expiresAt: .distantFuture,
            email: email)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func activateLocked(_ identity: AuthIdentity) throws -> URL {
        try CaptureAccountScope.activateForTests(identity)
        guard let binding = CaptureAccountScope.currentAccountBinding() else {
            throw BrineStepError("activation completed without an account binding")
        }
        guard binding.root.deletingLastPathComponent() == captureContainer,
              CaptureWAL.documentsCaptures() == binding.root else {
            throw BrineStepError(
                "activation did not resolve one account root beneath the test container")
        }
        return binding.root
    }

    private func recordConversationLocked(
        id: String,
        expectedRoot: URL,
        byte: UInt8,
        explicitBaseDir: URL? = nil
    ) throws -> URL {
        if explicitBaseDir == nil,
           CaptureWAL.documentsCaptures() != expectedRoot {
            throw BrineStepError("CaptureWAL did not resolve the expected active root")
        }
        let target = DoorTarget(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            bearer: "account-isolation-test")
        let wal = CaptureWAL(
            captureId: id,
            target: target,
            baseDir: explicitBaseDir,
            chunkFrames: 1)
        wal.appendFrame(Data([byte, byte &+ 1, byte &+ 2]))
        wal.flushAndWait()
        let root = explicitBaseDir ?? expectedRoot
        let segment = root
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(CaptureWAL.segName(0))
        guard fileManager.fileExists(atPath: segment.path) else {
            throw BrineStepError("CaptureWAL did not persist a segment for \(id)")
        }
        return segment
    }

    private func persistChatLocked(title: String) throws {
        let url = ChatConversationStore.defaultStorageURL()
        guard let binding = CaptureAccountScope.currentAccountBinding(),
              url == ChatConversationStore.storageURL(inAccountRoot: binding.root) else {
            throw BrineStepError("chat did not resolve through the active account root")
        }
        let store = ChatConversationStore(storageURL: url)
        store.setMessages(
            [.init(role: "user", text: title)],
            for: store.activeId)
        guard fileManager.fileExists(atPath: url.path) else {
            throw BrineStepError("the durable chat file was not persisted")
        }
        let reopened = ChatConversationStore(storageURL: url)
        guard reopened.conversations.map(\.title).contains(title) else {
            throw BrineStepError("the durable chat could not be reopened")
        }
    }

    private func conversationID(_ suffix: String) -> String {
        "conversation-\(token)-\(scenarioNumber)-\(suffix)"
    }

    private func conversationIDsLocked(at root: URL) -> Set<String> {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root.path)
        else { return [] }
        return Set(entries.filter { $0.hasPrefix("conversation-\(token)-") })
    }

    private func fileNumberLocked(_ url: URL) -> NSNumber? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.systemFileNumber])
            as? NSNumber
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private final class AccountIsolationVaultService:
    VaultSignupService, @unchecked Sendable
{
    let status: VaultProvisionStatus

    init(status: VaultProvisionStatus) {
        self.status = status
    }

    func createCheckoutAttempt(
        plan: VaultPlan,
        idToken: String?
    ) async throws -> VaultCheckoutAttempt {
        VaultCheckoutAttempt(id: "account-isolation", checkoutURL: nil)
    }

    func reconcile(
        attemptId: String,
        idToken: String?
    ) async throws -> VaultProvisionStatus {
        status
    }

    func exchangeReturn(
        ticket: String,
        idToken: String?
    ) async throws -> VaultProvisionStatus {
        status
    }
}

private struct AccountIsolationVaultBrowser: VaultCheckoutBrowser {
    func open(_ url: URL) async throws -> URL? { nil }
}

private actor PendingIdentityState {
    private(set) var transitionCount = 0
    private(set) var pendingValues: Set<String> = []
    private var waiters: [
        (target: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func seedEveryPendingValue() {
        pendingValues = [
            "pendingSeed",
            "pendingAnswer",
            "onNavigate",
            "pendingSeedCaptureId",
            "pendingPrefill",
            "pendingPrefillContext",
            "pendingOpenChatId",
            "isChatAlive",
        ]
    }

    func identityChanged() {
        pendingValues.removeAll()
        transitionCount += 1
        var remaining: [
            (target: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in waiters {
            if transitionCount >= waiter.target {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    func wait(untilAtLeast target: Int) async {
        guard transitionCount < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }
}

private final class IdentityTransitionProbe: @unchecked Sendable {
    private let state = PendingIdentityState()
    private var token: NSObjectProtocol?

    init() {
        let state = state
        token = NotificationCenter.default.addObserver(
            forName: CaptureAccountScope.identityDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { await state.identityChanged() }
        }
    }

    deinit {
        stop()
    }

    func stop() {
        if let token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
    }

    var transitionCount: Int {
        get async { await state.transitionCount }
    }

    var pendingValues: Set<String> {
        get async { await state.pendingValues }
    }

    func seedEveryPendingValue() async {
        await state.seedEveryPendingValue()
    }

    func wait(untilAtLeast target: Int) async {
        await state.wait(untilAtLeast: target)
    }
}

private enum AccountDataIsolationSteps {
    static func make(world w: AccountDataIsolationWorld) -> [StepDefinition] {
        [
            defineStep("the first Google account has two recorded conversations") {
                ctx, _, _ in
                try w.recordedConversationsForFirstAccount()
                return ctx
            },
            defineStep("the second Google account replaces it on this phone") {
                ctx, _, _ in
                try w.signOutThenUseSecondAccount()
                return ctx
            },
            defineCheck("the replacement account's recording library is empty") {
                _, _, _ in
                try w.assertSecondAccountHasNoConversations()
            },
            defineCheck(
                "files owned by the first Google account remain outside the replacement library"
            ) { _, _, _ in
                try w.assertSecondAccountCannotReadFirstFiles()
            },
            defineStep(
                "both Google accounts have recorded distinct conversations on this phone"
            ) { ctx, _, _ in
                try w.recordedConversationsForFirstAccount()
                try w.secondAccountRecordedConversation()
                return ctx
            },
            defineStep("the original Google account returns after the switch") {
                ctx, _, _ in
                try w.useFirstAccountAgain()
                return ctx
            },
            defineCheck(
                "only the original account's two conversations are visible again"
            ) { _, _, _ in
                try w.assertFirstAccountHasExactlyItsConversations()
            },
            defineCheck(
                "the replacement account's conversation stays in its own library"
            ) { _, _, _ in
                try w.assertSecondConversationIsAbsentFromFirst()
            },
            defineStep(
                "the original account has an owner voice sample and a named speaker"
            ) { ctx, _, _ in
                try w.taughtVoiceAndNamedSpeakerForFirstAccount()
                return ctx
            },
            defineStep("the other account opens its biometric and speaker library") {
                ctx, _, _ in
                try w.useSecondAccount()
                return ctx
            },
            defineCheck("that account finds no owner voice enrollment") {
                _, _, _ in
                try w.assertSecondAccountHasNoOwnerVoice()
            },
            defineCheck(
                "that account finds none of the original account's speaker names"
            ) { _, _, _ in
                try w.assertSecondAccountHasNoNamedSpeakers()
            },
            defineStep(
                "an unclaimed recording library exists from before account scoping"
            ) { ctx, _, _ in
                try w.recordedLegacyConversations()
                return ctx
            },
            defineStep("its verified owner completes sign-in") { ctx, _, _ in
                try w.ownerAccountClaimsLegacyConversations()
                return ctx
            },
            defineCheck(
                "the legacy recording is moved intact into the owner's library"
            ) { _, _, _ in
                try w.assertLegacyConversationsWereKept()
            },
            defineCheck(
                "the durable ownership claim prevents a later account from inheriting it"
            ) { _, _, _ in
                try w.assertLegacyConversationsBelongToOwner()
            },
            defineStep("a signed-in account owns conversations on this phone") {
                ctx, _, _ in
                try w.recordedConversationsForFirstAccount()
                return ctx
            },
            defineStep("that account signs out of FoundryX") { ctx, _, _ in
                try w.signOut()
                return ctx
            },
            defineCheck(
                "the signed-out recording view contains no account conversations"
            ) { _, _, _ in
                try w.assertSignedOutCannotReadConversations()
            },
            defineStep("Google has stored a conversation for a shared email address") {
                ctx, _, _ in
                try w.googleStoredConversationForSharedEmail()
                return ctx
            },
            defineStep("Microsoft signs in with the same email address") {
                ctx, _, _ in
                try w.microsoftUsesSharedEmail()
                return ctx
            },
            defineCheck("the Microsoft account receives a different empty library") {
                _, _, _ in
                try w.assertMicrosoftHasDifferentEmptyLibrary()
            },
            defineCheck("the Google conversation remains only in the Google library") {
                _, _, _ in
                try w.assertGoogleConversationRemainsOnlyWithGoogle()
            },
            defineStep(
                "an Apple subject recorded a conversation on its first authorization with email"
            ) { ctx, _, _ in
                try w.appleRecordedOnFirstAuthorization()
                return ctx
            },
            defineStep(
                "the same Apple subject authorizes again without an email address"
            ) { ctx, _, _ in
                try w.appleReauthorizesWithoutEmail()
                return ctx
            },
            defineCheck("Apple resolves the original subject's recording library") {
                _, _, _ in
                try w.assertAppleRestoresOriginalLibrary()
            },
            defineCheck("the Apple library never resolves to the signed-out scope") {
                _, _, _ in
                try w.assertAppleDidNotResolveSignedOut()
            },
            defineStep(
                "a Google account first signs in with a decomposed Unicode address"
            ) { ctx, _, _ in
                try w.googleUsesDecomposedAddress()
                return ctx
            },
            defineStep(
                "that Google account returns with the canonically composed address"
            ) { ctx, _, _ in
                try w.googleReturnsWithComposedAddress()
                return ctx
            },
            defineCheck("both address representations resolve to one account library") {
                _, _, _ in
                try w.assertUnicodeRepresentationsShareLibrary()
            },
            defineStep("the first account has a durable chat named {string}") {
                ctx, parameters, _ in
                try w.firstAccountHasDurableChat(
                    title: try parameters.requireString(0))
                return ctx
            },
            defineStep("the second account creates a durable chat named {string}") {
                ctx, parameters, _ in
                try w.secondAccountCreatesDurableChat(
                    title: try parameters.requireString(0))
                return ctx
            },
            defineStep("the first account reopens chat after the second account") {
                ctx, _, _ in
                try w.firstAccountReopensChat()
                return ctx
            },
            defineCheck("only {string} returns for the first account") {
                _, parameters, _ in
                try w.assertOnlyFirstChatReturns(
                    try parameters.requireString(0))
            },
            defineCheck("{string} remains absent from the first account's chat list") {
                _, parameters, _ in
                try w.assertSecondChatAbsentFromFirst(
                    try parameters.requireString(0))
            },
            defineStep("an unscoped chat file contains {string}") {
                ctx, parameters, _ in
                try w.unscopedChatContains(
                    title: try parameters.requireString(0))
                return ctx
            },
            defineStep(
                "the first verified provider account claims existing private data"
            ) { ctx, _, _ in
                try w.firstProviderClaimsExistingPrivateData()
                return ctx
            },
            defineCheck("{string} is moved into that account's chat store") {
                _, parameters, _ in
                try w.assertLegacyChatMoved(
                    try parameters.requireString(0))
            },
            defineCheck("a later provider account cannot claim the legacy chat file") {
                _, _, _ in
                try w.assertLaterProviderCannotClaimLegacyChat()
            },
            defineStep(
                "an authenticated account persisted its opaque owner scope before device lock"
            ) { ctx, _, _ in
                try w.persistOpaqueOwnerScope()
                return ctx
            },
            defineStep("a locked background relaunch cannot read the identity token") {
                ctx, _, _ in
                try w.relaunchLockedAndSpoolAudio()
                return ctx
            },
            defineCheck(
                "restored audio still targets the authenticated owner's library"
            ) { _, _, _ in
                try w.assertRestoredAudioTargetsOwner()
            },
            defineCheck("restored audio is never assigned to the signed-out library") {
                _, _, _ in
                try w.assertRestoredAudioAvoidsSignedOut()
            },
            defineStep(
                "the legacy container cannot durably record its first ownership claim"
            ) { ctx, _, _ in
                try w.makeOwnershipClaimUnwritable()
                return ctx
            },
            defineStep("a provider account attempts to activate that private library") {
                ctx, _, _ in
                try w.attemptActivationWithFailedClaim()
                return ctx
            },
            defineCheck(
                "account activation fails before any usable private root is exposed"
            ) { _, _, _ in
                try w.assertActivationFailedClosed()
            },
            defineStep(
                "legacy and scoped libraries contain different data at the same destination"
            ) { ctx, _, _ in
                try w.stageMigrationCollision()
                return ctx
            },
            defineStep("the verified owner attempts the colliding migration") {
                ctx, _, _ in
                try w.attemptCollidingMigration()
                return ctx
            },
            defineCheck("migration reports the recovered collision to sign-in") {
                _, _, _ in
                try w.assertCollisionReported()
            },
            defineCheck(
                "both versions remain intact in deterministic owner-only locations"
            ) { _, _, _ in
                try w.assertCollisionVersionsRemainIntact()
            },
            defineStep(
                "the first account has a widget title and pending ambient broker content"
            ) { ctx, _, _ in
                try await w.seedWidgetAndPendingState()
                return ctx
            },
            defineStep(
                "the phone transitions from the first account to the second account"
            ) { ctx, _, _ in
                try await w.transitionPhoneToSecondAccount()
                return ctx
            },
            defineCheck("the widget exposes an idle snapshot to the second account") {
                _, _, _ in
                try w.assertWidgetIsIdleForSecondAccount()
            },
            defineCheck("the identity transition clears every pending broker value") {
                _, _, _ in
                try await w.assertEveryPendingValueWasCleared()
            },
            defineStep("FoundryX is signed out for free on-device capture") {
                ctx, _, _ in
                try w.prepareSignedOutOnDeviceCapture()
                return ctx
            },
            defineStep("capture publishes its current glanceable state") {
                ctx, _, _ in
                w.publishSignedOutGlanceableState()
                return ctx
            },
            defineCheck(
                "the free on-device tier exposes the current capture state"
            ) { _, _, _ in
                try w.assertSignedOutGlanceableStateIsCurrent()
            },
            defineStep(
                "ambient answer work is suspended after starting for the first account"
            ) { ctx, _, _ in
                try w.suspendAmbientAnswerForFirstAccount()
                return ctx
            },
            defineStep(
                "the second account becomes active before that work completes"
            ) { ctx, _, _ in
                try w.activateSecondBeforeAmbientCompletion()
                return ctx
            },
            defineCheck("the stale first-account work is rejected at completion") {
                _, _, _ in
                try w.assertStaleWorkWasRejected()
            },
            defineCheck(
                "no first-account answer is appended to the second account's ledger"
            ) { _, _, _ in
                try w.assertFirstAnswerAbsentFromSecondLedger()
            },
            defineStep(
                "a Google account first owns a recording library using its verified email"
            ) { ctx, _, _ in
                try w.emailFallbackOwnsRecordingLibrary()
                return ctx
            },
            defineStep("the same Google account later returns with a stable subject") {
                ctx, _, _ in
                try w.sameAccountReturnsWithSubject()
                return ctx
            },
            defineCheck("the account still resolves its original recording library") {
                _, _, _ in
                try w.assertFallbackLibraryStillResolves()
            },
            defineCheck("no second account library is created for the later subject") {
                _, _, _ in
                try w.assertNoLaterSubjectLibraryWasCreated()
            },
            defineStep("publishing the active owner cannot be durably confirmed") {
                ctx, _, _ in
                try w.failActiveOwnerDurabilityConfirmation()
                return ctx
            },
            defineStep("one Google subject differing only by case owns a recording") {
                ctx, _, _ in
                try w.upperCaseSubjectOwnsRecording()
                return ctx
            },
            defineStep("the other case-sensitive Google subject signs in") {
                ctx, _, _ in
                try w.lowerCaseSubjectSignsIn()
                return ctx
            },
            defineCheck("the second subject receives a different empty library") {
                _, _, _ in
                try w.assertCaseSensitiveSubjectGetsEmptyLibrary()
            },
            defineCheck(
                "the first subject's recording remains only in its original library"
            ) { _, _, _ in
                try w.assertUpperSubjectRecordingStayedPrivate()
            },
            defineStep("widget work is suspended after starting for the first account") {
                ctx, _, _ in
                try w.suspendWidgetWorkForFirstAccount()
                return ctx
            },
            defineStep(
                "the second account becomes active before the widget work completes"
            ) { ctx, _, _ in
                try w.completeWidgetAfterSecondAccount()
                return ctx
            },
            defineCheck("the stale widget write is rejected at completion") {
                _, _, _ in
                try w.assertStaleProducerWasRejected()
            },
            defineCheck("the second account retains an idle widget snapshot") {
                _, _, _ in
                try w.assertSecondWidgetRemainsIdle()
            },
            defineStep(
                "ambient dismissal work is suspended after starting for the first account"
            ) { ctx, _, _ in
                try w.suspendAmbientDismissalForFirstAccount()
                return ctx
            },
            defineStep(
                "the second account becomes active before the dismissal completes"
            ) { ctx, _, _ in
                try w.completeAmbientDismissalAfterSecondAccount()
                return ctx
            },
            defineCheck("the stale dismissal is rejected at completion") {
                _, _, _ in
                try w.assertStaleProducerWasRejected()
            },
            defineCheck(
                "no first-account outcome is appended to the second account's ledger"
            ) { _, _, _ in
                try w.assertNoFirstOutcomeInSecondLedger()
            },
            defineStep(
                "chat tool activity is suspended after starting for the first account"
            ) { ctx, _, _ in
                try w.suspendChatToolActivityForFirstAccount()
                return ctx
            },
            defineStep(
                "the second account becomes active before the tool activity completes"
            ) { ctx, _, _ in
                try w.completeChatToolAfterSecondAccount()
                return ctx
            },
            defineCheck("the stale tool activity is rejected at completion") {
                _, _, _ in
                try w.assertStaleProducerWasRejected()
            },
            defineCheck(
                "no first-account tool activity is appended to the second account's ledger"
            ) { _, _, _ in
                try w.assertNoFirstToolInSecondLedger()
            },
            defineStep(
                "a Door transcript is suspended after starting for the first account"
            ) { ctx, _, _ in
                try w.suspendDoorTranscriptForFirstAccount()
                return ctx
            },
            defineStep(
                "the second account becomes active before the transcript completes"
            ) { ctx, _, _ in
                try w.completeDoorTranscriptAfterSecondAccount()
                return ctx
            },
            defineCheck("the stale transcript cache write is rejected at completion") {
                _, _, _ in
                try w.assertStaleProducerWasRejected()
            },
            defineCheck(
                "the second account's chat cache contains no first-account transcript"
            ) { _, _, _ in
                try w.assertNoFirstTranscriptInSecondCache()
            },
            defineStep(
                "the first account has an active Live Activity with private content"
            ) { ctx, _, _ in
                try w.seedLiveActivityForFirstAccount()
                return ctx
            },
            defineStep(
                "the phone changes from the first account to the second account"
            ) { ctx, _, _ in
                try await w.transitionLiveActivityToSecondAccount()
                return ctx
            },
            defineCheck("the first account's Live Activity is ended") {
                _, _, _ in
                try w.assertFirstLiveActivityEnded()
            },
            defineCheck(
                "no first-account title or transcript is exposed to the second account"
            ) { _, _, _ in
                try w.assertNoLiveActivityContentForSecondAccount()
            },
            defineStep(
                "every saved choice declares whether it belongs to an account or the phone"
            ) { ctx, _, _ in
                try w.everySavedChoiceDeclaresItsOwner()
                return ctx
            },
            defineStep(
                "a developer adds a saved choice without declaring its ownership"
            ) { ctx, _, _ in
                w.developerAddsSavedChoiceWithoutOwnership()
                return ctx
            },
            defineCheck("the build fails") { _, _, _ in
                try w.assertBuildFailsForUndeclaredSavedChoice()
            },
            defineCheck(
                "it identifies the file and saved choice that need classification"
            ) { _, _, _ in
                try w.assertGuardIdentifiesUndeclaredSavedChoice()
            },
            defineStep("the first account paired a Vault with a private bearer") {
                ctx, _, _ in
                try w.firstAccountPairedVaultWithPrivateBearer()
                return ctx
            },
            defineStep("the second account signs in on the same phone") {
                ctx, _, _ in
                try w.secondAccountSignsInOnSamePhone()
                return ctx
            },
            defineCheck("the second account has no Vault cell pairing") {
                _, _, _ in
                try w.assertSecondAccountHasNoVaultCellPairing()
            },
            defineCheck(
                "the second account cannot read the first account's Vault bearer"
            ) { _, _, _ in
                try w.assertSecondAccountCannotReadFirstVaultBearer()
            },
            defineStep("the second account pairs a different Vault") {
                ctx, _, _ in
                try w.secondAccountPairsDifferentVault()
                return ctx
            },
            defineStep("the first account signs back in") {
                ctx, _, _ in
                try w.firstAccountSignsBackIn()
                return ctx
            },
            defineCheck(
                "the first account's Vault pairing and bearer are intact"
            ) { _, _, _ in
                try w.assertFirstAccountVaultPairingAndBearerAreIntact()
            },
            defineStep("the first account's Vault entitlement router is live") {
                ctx, _, _ in
                try await w.firstAccountVaultEntitlementRouterIsLive()
                return ctx
            },
            defineStep("the second account signs in without a Vault") {
                ctx, _, _ in
                try await w.secondAccountSignsInWithoutVault()
                return ctx
            },
            defineCheck(
                "the Vault entitlement router shows the second account is off"
            ) { _, _, _ in
                try await w.assertVaultRouterShowsSecondAccountIsOff()
            },
            defineStep(
                "a Vault and Door pairing exist from before account scoping"
            ) { ctx, _, _ in
                try w.stageLegacyVaultAndDoorPairing()
                return ctx
            },
            defineStep(
                "the verified owner activates account-scoped private data"
            ) { ctx, _, _ in
                try w.verifiedOwnerActivatesScopedPrivateData()
                return ctx
            },
            defineCheck("the owner's Vault and Door pairing remain intact") {
                _, _, _ in
                try w.assertOwnerPairingsRemainIntact()
            },
            defineCheck("a later account cannot claim either legacy pairing") {
                _, _, _ in
                try w.assertLaterAccountCannotClaimLegacyPairings()
            },
            defineStep("FoundryX remains signed out for free on-device use") {
                ctx, _, _ in
                try w.remainSignedOutForFreeUse()
                return ctx
            },
            defineCheck("the free tier has no Vault or Door pairing") {
                _, _, _ in
                try w.assertFreeTierHasNoVaultOrDoorPairing()
            },
            defineCheck(
                "the unclaimed pairing remains available for its verified owner"
            ) { _, _, _ in
                try w.assertLegacyPairingRemainsUnclaimed()
            },
            defineStep("my account already owns a Vault and Door pairing") {
                ctx, _, _ in
                try w.seedColdVaultAndDoorPairings()
                return ctx
            },
            defineStep("FoundryX has not loaded that pairing in this launch") {
                ctx, _, _ in
                try w.leavePairingsColdForLaunch()
                return ctx
            },
            defineStep(
                "an account change and pairing refresh happen at the same time"
            ) { ctx, _, _ in
                try await w.raceAccountChangeWithPairingRefresh()
                return ctx
            },
            defineCheck(
                "the account change completes without waiting for pairing maintenance"
            ) { _, _, _ in
                try w.assertAccountChangeDidNotWaitForPairingMaintenance()
            },
            defineCheck(
                "no existing or legacy pairing is claimed or changed"
            ) { _, _, _ in
                try w.assertPairingRefreshChangedNothing()
            },
            defineStep("securely saving a replacement Vault bearer fails") {
                ctx, _, _ in
                try w.failSecureVaultReplacement()
                return ctx
            },
            defineCheck(
                "the current session keeps using the original complete Vault pairing"
            ) { _, _, _ in
                try w.assertCurrentVaultRemainsWhole()
            },
            defineCheck(
                "reopening FoundryX restores that same complete Vault pairing"
            ) { _, _, _ in
                try w.assertReopenedVaultRemainsWhole()
            },
            defineStep("securely removing that Vault bearer fails") {
                ctx, _, _ in
                try w.failSecureVaultUnpair()
                return ctx
            },
            defineCheck(
                "FoundryX reports that the Vault could not be unpaired"
            ) { _, _, _ in
                try w.assertVaultSecureOperationFailed()
            },
            defineCheck(
                "the current session and a reopened app both retain the original pairing"
            ) { _, _, _ in
                try w.assertCurrentVaultRemainsWhole()
                try w.assertReopenedVaultRemainsWhole()
            },
            defineStep("my account has a working saved Door connection") {
                ctx, _, _ in
                try w.seedWorkingDoorForFailure()
                return ctx
            },
            defineStep(
                "I save a replacement Door connection and its bearer cannot be stored"
            ) { ctx, _, _ in
                try await w.failSecureDoorReplacement()
                return ctx
            },
            defineCheck(
                "the connection screen tells me the replacement was not saved"
            ) { _, _, _ in
                try w.assertDoorSaveFailureIsVisible()
            },
            defineCheck(
                "the current session and a reopened app both retain the working Door"
            ) { _, _, _ in
                try w.assertWorkingDoorRemainsWhole()
            },
            defineStep(
                "the second account owns a Vault pairing that uses its sign-in"
            ) { ctx, _, _ in
                try await w.seedDelayedTokenVault()
                return ctx
            },
            defineStep(
                "its refreshed sign-in token is not ready when the account changes"
            ) { ctx, _, _ in
                try await w.assertDelayedVaultTokenIsUnavailable()
                return ctx
            },
            defineStep(
                "the second account's refreshed sign-in token becomes available"
            ) { ctx, _, _ in
                try await w.publishDelayedVaultToken()
                return ctx
            },
            defineCheck("the second account's Vault becomes live") {
                _, _, _ in
                try await w.assertDelayedTokenVaultIsLive()
            },
            defineCheck("the first account's Vault never reconnects") {
                _, _, _ in
                try w.assertPriorVaultNeverReconnected()
            },
            defineStep("my account paired a Vault with a private bearer") {
                ctx, _, _ in
                try w.seedBearerVaultForAuthChange()
                return ctx
            },
            defineStep(
                "I change that Vault to use my sign-in but its old bearer cannot be removed"
            ) { ctx, _, _ in
                try w.failSecureIdTokenChange()
                return ctx
            },
            defineCheck(
                "FoundryX reports that the authentication change did not complete"
            ) { _, _, _ in
                try w.assertVaultSecureOperationFailed()
            },
        ]
    }
}
