import XCTest
@testable import FoundryXKit

final class AccountPreferenceUsageGuardTests: XCTestCase {
    private static let expectedAccountKeys: Set<String> = [
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

    func testGuardTruthIsExactlyTheIndependentSeventeenKeySet() {
        let entries = AccountPreferenceCatalog.entries

        XCTAssertEqual(entries.count, 17)
        XCTAssertEqual(
            Set(entries.map(\.canonicalKey)),
            Self.expectedAccountKeys)
        XCTAssertTrue(entries.allSatisfy {
            $0.classification == .account
                && $0.activationState == .active
        })
    }

    func testDirectUnclassifiedSavedChoiceReportsStableLocationAndKey() throws {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/DirectUnclassifiedChoice.swift",
            text: """
            import Foundation
            UserDefaults.standard.set(
                true,
                forKey: "foundryx.unclassified-choice")
            """)

        let violation = try XCTUnwrap(
            AccountPreferenceUsageGuard.scan(sources: [source]).first,
            "a direct saved choice without ownership classification must fail")
        XCTAssertEqual(violation.path, source.path)
        XCTAssertEqual(violation.line, 2)
        XCTAssertEqual(violation.keyOrUse, "foundryx.unclassified-choice")
    }

    func testInterpolatedAliasSavedChoiceReportsStableLocationAndUse() throws {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/InterpolatedAliasChoice.swift",
            text: """
            import Foundation
            let defaults = UserDefaults.standard
            let owner = "someone"
            defaults.set(true, forKey: "foundryx.dynamic.\\(owner)")
            """)

        let violation = try XCTUnwrap(
            AccountPreferenceUsageGuard.scan(sources: [source]).first,
            "an interpolated key through a defaults alias must fail closed")
        XCTAssertEqual(violation.path, source.path)
        XCTAssertEqual(violation.line, 4)
        XCTAssertEqual(
            violation.keyOrUse,
            #""foundryx.dynamic.\(owner)""#)
    }

    func testDynamicConcatenationFormattingAndUnknownAliasFailClosed() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/DynamicChoices.swift",
            text: """
            import Foundation
            let defaults: UserDefaults = .standard
            let suffix = "owner"
            let unknownKey = "foundryx.unknown-choice"
            defaults.set(true, forKey: "foundryx." + suffix)
            defaults.set(true, forKey: String(format: "foundryx.%@", suffix))
            defaults.set(true, forKey: unknownKey)
            """)

        let violations = AccountPreferenceUsageGuard.scan(sources: [source])
        XCTAssertEqual(violations.count, 3)
        XCTAssertEqual(Set(violations.map(\.line)), [5, 6, 7])
        XCTAssertTrue(violations.allSatisfy { $0.path == source.path })
    }

    func testRawAccountKeyAndEscapedCompatibilityTypeFail() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/EscapedCompatibility.swift",
            text: """
            import Foundation
            final class EscapedCompatibilityStore {
                let defaults: UserDefaults = .standard
                func read() {
                    defaults.bool(forKey: "foundryx.onboarding.completed")
                }
            }
            """)

        let violation = AccountPreferenceUsageGuard.scan(sources: [source])
        XCTAssertEqual(violation.count, 1)
        XCTAssertEqual(
            violation.first?.keyOrUse,
            "foundryx.onboarding.completed")
        XCTAssertTrue(
            violation.first?.reason.contains("active") == true)
    }

    func testActiveCompatibilityAndDynamicSignupRawSeamsAreRejected() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/InactiveCompatibility.swift",
            text: """
            import Foundation
            final class AccountPreferenceCompatibilityStore {
                let defaults: UserDefaults = .standard
                func read() {
                    defaults.bool(forKey: "foundryx.onboarding.completed")
                }
                private func legacySignupKey(for account: String) -> String {
                    "foundryx.account.signup-posted." + account
                }
                func legacySignupPosted(account: String) {
                    defaults.bool(forKey: legacySignupKey(for: account))
                }
                func markLegacySignupPosted(account: String) {
                    let key = legacySignupKey(for: account)
                    defaults.set(true, forKey: key)
                }
            }
            """)

        let violations = AccountPreferenceUsageGuard.scan(sources: [source])
        XCTAssertEqual(violations.count, 3)
        XCTAssertTrue(violations.contains {
            $0.keyOrUse == "foundryx.onboarding.completed"
                && $0.reason.contains("active")
        })
        XCTAssertEqual(
            violations.filter {
                $0.keyOrUse == "legacySignupKey(for: account)"
            }.count,
            2)
    }

    func testActiveCatalogRejectsCompatibilityAndDynamicSignupSet() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/ActiveCompatibility.swift",
            text: """
            import Foundation
            final class AccountPreferenceCompatibilityStore {
                let defaults: UserDefaults = .standard
                func read() {
                    defaults.bool(forKey: "foundryx.onboarding.completed")
                }
            }
            struct LegacySignupMarkerMigration {
                let defaults: UserDefaults
                func historicalKey(_ identity: String) -> String {
                    "foundryx.account.signup-posted." + identity
                }
                func snapshot(identity: String) {
                    defaults.object(forKey: historicalKey(identity))
                }
                func retire(identity: String) {
                    defaults.removeObject(forKey: historicalKey(identity))
                }
                func forbiddenSet(identity: String) {
                    defaults.set(true, forKey: historicalKey(identity))
                }
            }
            """)

        let violations = AccountPreferenceUsageGuard.scan(
            sources: [source],
            catalog: activeCatalog())
        XCTAssertEqual(violations.count, 2)
        XCTAssertEqual(Set(violations.map(\.line)), [5, 20])
    }

    func testActiveSignupAllowsOnlySealedSnapshotAndRetirement() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/SealedSignupMigration.swift",
            text: """
            import Foundation
            struct LegacySignupMarkerMigration {
                let defaults: UserDefaults
                func historicalKey(_ identity: String) -> String {
                    "foundryx.account.signup-posted." + identity
                }
                func snapshot(identity: String) {
                    defaults.object(forKey: historicalKey(identity))
                    defaults.bool(forKey: historicalKey(identity))
                }
                func retire(identity: String) {
                    defaults.removeObject(forKey: historicalKey(identity))
                }
            }
            """)

        XCTAssertEqual(
            AccountPreferenceUsageGuard.scan(
                sources: [source],
                catalog: activeCatalog()),
            [])
    }

    func testAllowedTypeNamesDoNotPermitArbitraryDynamicExpressions() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/AllowedTypeEscape.swift",
            text: """
            import Foundation
            final class AccountPreferenceCompatibilityStore {
                let defaults: UserDefaults = .standard
                func read(owner: String) {
                    defaults.bool(forKey: "escaped.\\(owner)")
                }
            }
            final class AccountPreferenceWriteStore {
                let defaults: UserDefaults = .standard
                func write(owner: String) {
                    defaults.set(true, forKey: "escaped.\\(owner)")
                }
            }
            struct LegacySignupMarkerMigration {
                let defaults: UserDefaults
                func snapshot(identity: String) {
                    defaults.object(forKey: "escaped.\\(identity)")
                }
            }
            enum CaptureAccountScope {
                static let defaults: UserDefaults = .standard
                static func storedPreferenceValue(
                    forKey key: String,
                    owner: String
                ) {
                    defaults.object(forKey: key)
                    defaults.object(forKey: "escaped.\\(owner)")
                }
                static func mutateCheckoutPreferencePair(owner: String) {
                    defaults.set(true, forKey: "escaped.\\(owner)")
                }
            }
            enum AccountPreferenceActivationStore {
                static let defaults: UserDefaults = .standard
                static func explicitValues(
                    entry: AccountPreferenceCatalogEntry,
                    owner: String,
                    key: (String) -> String
                ) {
                    defaults.object(forKey: key(entry.canonicalKey))
                    defaults.object(forKey: "escaped.\\(owner)")
                }
            }
            """)

        let violations = AccountPreferenceUsageGuard.scan(sources: [source])
        XCTAssertEqual(violations.count, 6)
        XCTAssertEqual(
            Set(violations.map(\.line)),
            [5, 11, 17, 27, 30, 41])
    }

    func testDeletionOwnerCannotHideAnUnrelatedDynamicPreferenceRemoval() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/DeletionDynamicEscape.swift",
            text: """
            import Foundation
            final class LiveAccountDeletionContext {
                let defaults: UserDefaults = .standard
                func remove(plantedUnrelatedKey: String) {
                    defaults.removeObject(forKey: plantedUnrelatedKey)
                }
            }
            """)

        let violations = AccountPreferenceUsageGuard.scan(
            sources: [source])
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(
            violations.first?.reason,
            "dynamic or unresolved preference key is forbidden at this persistence use")
    }

    func testDeletionAndPairingOwnersRejectPlantedGenericKeyEscapes() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/PlantedDeletionEscapes.swift",
            text: """
            import Foundation
            final class LiveAccountDeletionContext {
                let defaults: UserDefaults = .standard
                func remove(unrelated: String, values: [String]) {
                    let key = unrelated
                    defaults.removeObject(forKey: key)
                    values.forEach { defaults.removeObject(forKey: $0) }
                }
            }
            final class CellStore {
                let defaults: UserDefaults = .standard
                func erasePairing(unrelated: String) {
                    defaults.removeObject(forKey: unrelated)
                }
            }
            final class DoorConfigStore {
                let defaults: UserDefaults = .standard
                func erasePairing(unrelated: String) {
                    defaults.removeObject(forKey: unrelated)
                }
            }
            """)
        let violations = AccountPreferenceUsageGuard.scan(sources: [source])
        XCTAssertGreaterThanOrEqual(
            violations.count, 4,
            "every planted persistence call must be rejected")
    }

    func testPhoneRegistryIsFiniteAndCannotEnterAccountScope() {
        let expected: Set<String> = [
            "foundryx.omi.peripheral-id",
            "foundryx.omi.peripheral-name",
            "foundryx.omi.last-connected",
            "foundryx.omi.central",
            "foundryx.battery.monitored.uuid",
            "foundryx.battery.monitored.name",
            "foundryx.capture.source",
            "foundryx.capture.sources.added",
            "foundryx.action-button.choice",
            "foundryx.diag.perfOverlay",
            "foundryx.auth.signed-in",
            "foundryx.capture-account-activation.v2",
            "foundryx.capture-account-scope",
            "foundryx.capture.widget-snapshot",
            "foundryx.capture.widget-snapshot.active-owner",
        ]
        XCTAssertEqual(AccountPreferenceUsageGuard.phoneOwnedKeys, expected)

        let source = AccountPreferenceSourceFile(
            path: "Fixture/PhoneChoices.swift",
            text: """
            import Foundation
            let defaults = UserDefaults.standard
            let scoped = CaptureAccountScope.ScopedPreferences(scope: "acct")
            defaults.set("omi", forKey: "foundryx.capture.source")
            defaults.set("omi", forKey: scoped.key("foundryx.capture.source"))
            """)
        let violations = AccountPreferenceUsageGuard.scan(sources: [source])
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations.first?.line, 5)
    }

    func testTrackARegistryAndExactLegacySeamsAreSealed() {
        XCTAssertEqual(
            AccountPreferenceUsageGuard.accountInfrastructureKeys,
            [
                "foundryx.cell.url",
                "foundryx.cell.authMode",
                "foundryx.door.url",
            ])
        XCTAssertEqual(
            AccountPreferenceUsageGuard.accountInfrastructureKeychainServices,
            [
                "com.goforgeit.foundryx.cell",
                "com.goforgeit.foundryx.door",
            ])
        let source = AccountPreferenceSourceFile(
            path: "Fixture/TrackA.swift",
            text: """
            import Foundation
            enum CaptureAccountScope {
                static func adoptLegacyPairingRecord(defaults: UserDefaults) {
                    let scoped = ScopedPreferences(scope: "owner")
                    let services = (
                        cell: "com.goforgeit.foundryx.cell",
                        door: "com.goforgeit.foundryx.door"
                    )
                    adoptLegacyCellPairing(
                        defaults: defaults,
                        scoped: scoped,
                        service: services.cell)
                    adoptLegacyDoorPairing(
                        defaults: defaults,
                        scoped: scoped,
                        service: services.door)
                }
                static func adoptLegacyCellPairing(
                    defaults: UserDefaults,
                    scoped: ScopedPreferences,
                    service: String
                ) {
                    let urlKey = "foundryx.cell.url"
                    let modeKey = "foundryx.cell.authMode"
                    let url = defaults.string(forKey: urlKey)
                    let mode = defaults.string(forKey: modeKey)
                    _ = adoptLegacyKeychainSecretIfNeeded(
                        service: service,
                        scope: scoped.scope)
                    defaults.set(url, forKey: scoped.key(urlKey))
                    defaults.set(mode, forKey: scoped.key(modeKey))
                }
                static func adoptLegacyDoorPairing(
                    defaults: UserDefaults,
                    scoped: ScopedPreferences,
                    service: String
                ) {
                    let urlKey = "foundryx.door.url"
                    let url = defaults.string(forKey: urlKey)
                    _ = adoptLegacyKeychainSecretIfNeeded(
                        service: service,
                        scope: scoped.scope)
                    defaults.set(url, forKey: scoped.key(urlKey))
                }
            }
            """)
        XCTAssertEqual(
            AccountPreferenceUsageGuard.scan(sources: [source]),
            [])
    }

    func testCommentsFixtureStringsAndUnrelatedForKeyCallsAreIgnored() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/FalsePositiveControls.swift",
            text: ##"""
            import Foundation
            // UserDefaults.standard.set(true, forKey: "foundryx.fake")
            let fixture = #"UserDefaults.standard.set(true, forKey: "foundryx.fake")"#
            let dictionary = ["saved": true]
            _ = dictionary.index(forKey: "saved")
            """##)

        XCTAssertEqual(
            AccountPreferenceUsageGuard.scan(sources: [source]),
            [])
    }

    func testUnicodeRawAndMultilineFixtureStringsPreserveOffsets() throws {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/UnicodeMasking.swift",
            text: ##"""
            let emoji = "🫠"
            let raw = #"UserDefaults.standard.set(true, forKey: "foundryx.fake.raw")"#
            let multiline = """
            UserDefaults.standard.set(true, forKey: "foundryx.fake.multiline")
            """
            let rawMultiline = #"""
            UserDefaults.standard.set(true, forKey: "foundryx.fake.raw-multiline")
            """#
            UserDefaults.standard.set(true, forKey: "foundryx.real-after-unicode")
            """##)

        let violation = try XCTUnwrap(
            AccountPreferenceUsageGuard.scan(sources: [source]).first)
        XCTAssertEqual(violation.line, 9)
        XCTAssertEqual(
            violation.keyOrUse,
            "foundryx.real-after-unicode")
    }

    func testOuterForKeyWinsOverNestedUnrelatedForKey() throws {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/NestedForKey.swift",
            text: """
            import Foundation
            let defaults = UserDefaults.standard
            defaults.set(
                decoder.decode(String.self, forKey: .payload),
                forKey: "foundryx.outer-choice")
            """)

        let violation = try XCTUnwrap(
            AccountPreferenceUsageGuard.scan(sources: [source]).first)
        XCTAssertEqual(violation.line, 3)
        XCTAssertEqual(violation.keyOrUse, "foundryx.outer-choice")
    }

    func testAppStorageAndPersistentDomainRemovalAreDetected() throws {
        let source = AccountPreferenceSourceFile(
            path: "App/AccountDeletionView.swift",
            text: """
            import Foundation
            extension AccountDeletionModel {
                static func live() {
                    let service = LiveAccountDeletionService(
                        eraseLocal: {
                            if let domain = Bundle.main.bundleIdentifier {
                                UserDefaults.standard.removePersistentDomain(forName: domain)
                            }
                        })
                }
            }
            @AppStorage("foundryx.unknown-app-storage") var unknown = false
            @SceneStorage("foundryx.unknown-scene-storage") var scene = false
            """)

        let violations = AccountPreferenceUsageGuard.scan(sources: [source])
        XCTAssertEqual(violations.count, 3)
        let deletion = try XCTUnwrap(violations.first {
            $0.keyOrUse == "removePersistentDomain"
        })
        XCTAssertEqual(deletion.line, 7)
        XCTAssertEqual(
            deletion.ownership,
            "AccountDeletionModel.live->eraseLocal")
        XCTAssertEqual(
            deletion.operationFingerprint,
            "UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier)")
    }

    func testEmptyCatalogAndIncompleteAtomicGroupFailHard() {
        let empty = AccountPreferenceUsageGuard.scan(
            sources: [], catalog: [])
        XCTAssertEqual(empty.first?.path, "<catalog>")
        XCTAssertTrue(empty.first?.reason.contains("empty") == true)

        let incomplete = AccountPreferenceCatalog.entries.filter {
            $0.canonicalKey != "foundryx.vault.checkoutAttempt.plan"
        }
        let violations = AccountPreferenceUsageGuard.scan(
            sources: [], catalog: incomplete)
        XCTAssertTrue(violations.first?.reason.contains("atomic") == true)

        let emptySources = AccountPreferenceUsageGuard.scan(sources: [])
        XCTAssertEqual(emptySources.first?.path, "<sources>")
        XCTAssertTrue(emptySources.first?.reason.contains("empty") == true)
    }

    func testChangedPersistentDomainCallCannotMatchTheBaselineDebt() throws {
        let source = AccountPreferenceSourceFile(
            path: "App/AccountDeletionView.swift",
            text: """
            import Foundation
            extension AccountDeletionModel {
                static func live() {
                    let defaults = UserDefaults.standard
                    let bundleID = Bundle.main.bundleIdentifier
                    let service = LiveAccountDeletionService(
                        eraseLocal: {
                            defaults.removePersistentDomain(forName: bundleID)
                        })
                }
            }
            """)
        let violation = try XCTUnwrap(
            AccountPreferenceUsageGuard.scan(sources: [source]).first)
        XCTAssertNotEqual(
            violation.operationFingerprint,
            "UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier)")
    }

    func testDeletionDebtOwnershipRequiresCallInsideEraseLocalClosure() throws {
        let source = AccountPreferenceSourceFile(
            path: "App/AccountDeletionView.swift",
            text: """
            import Foundation
            extension AccountDeletionModel {
                static func live() {
                    let service = LiveAccountDeletionService(
                        eraseLocal: {
                            _ = "local work"
                        },
                        deleteRemote: {
                            if let domain = Bundle.main.bundleIdentifier {
                                UserDefaults.standard.removePersistentDomain(forName: domain)
                            }
                        })
                }
            }
            """)

        let violation = try XCTUnwrap(
            AccountPreferenceUsageGuard.scan(sources: [source]).first)
        XCTAssertEqual(
            violation.operationFingerprint,
            "UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier)")
        XCTAssertNotEqual(
            violation.ownership,
            "AccountDeletionModel.live->eraseLocal")
    }

    func testCFPreferencesLiteralCannotEscapeInsideWriteStoreType() throws {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/CFPreferencesEscape.swift",
            text: """
            import Foundation
            final class AccountPreferenceWriteStore {
                func escapedRawWrite() {
                    CFPreferencesSetAppValue(
                        "foundryx.onboarding.completed" as CFString,
                        true as CFPropertyList,
                        kCFPreferencesCurrentApplication)
                }
            }
            """)

        let violation = try XCTUnwrap(
            AccountPreferenceUsageGuard.scan(sources: [source]).first)
        XCTAssertEqual(violation.line, 4)
        XCTAssertEqual(
            violation.keyOrUse,
            "foundryx.onboarding.completed")
    }

    func testTrackARejectsLoneScopedUseAndDeadStringServiceCoupling() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/TrackAEscapes.swift",
            text: """
            import Foundation
            struct RoguePairingOwner {
                let defaults: UserDefaults
                func save(scoped: ScopedPreferences) {
                    defaults.set("url", forKey: scoped.key("foundryx.cell.url"))
                }
            }
            enum CaptureAccountScope {
                static func adoptLegacyPairingRecord() {
                    _ = "com.goforgeit.foundryx.cell"
                    _ = "com.goforgeit.foundryx.door"
                }
                static func adoptLegacyCellPairing(defaults: UserDefaults) {
                    let urlKey = "foundryx.cell.url"
                    let modeKey = "foundryx.cell.authMode"
                    _ = defaults.string(forKey: urlKey)
                    _ = defaults.string(forKey: modeKey)
                }
                static func adoptLegacyDoorPairing(defaults: UserDefaults) {
                    let urlKey = "foundryx.door.url"
                    _ = defaults.string(forKey: urlKey)
                }
            }
            """)

        let violations = AccountPreferenceUsageGuard.scan(sources: [source])
        XCTAssertEqual(violations.count, 2)
        XCTAssertTrue(violations.contains {
            $0.keyOrUse == "foundryx.cell.url"
                && $0.reason.contains("owner")
        })
        XCTAssertTrue(violations.contains {
            $0.reason.contains("Keychain")
        })
    }

    func testTrackANormalOwnerRequiresOperationalKeychainCoupling() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/CellStore.swift",
            text: """
            import Foundation
            final class CellStore {
                let defaults: UserDefaults
                let fixtureService = "com.goforgeit.foundryx.cell"
                func pair(scoped: ScopedPreferences) {
                    defaults.set("url", forKey: scoped.key("foundryx.cell.url"))
                    defaults.set("mode", forKey: scoped.key("foundryx.cell.authMode"))
                }
            }
            """)

        let violations = AccountPreferenceUsageGuard.scan(sources: [source])
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(
            violations.first?.keyOrUse,
            "Track-A CellStore registry")
        XCTAssertTrue(
            violations.first?.reason.contains("Keychain operation") == true)
    }

    func testDefaultsAliasesResolveTransitivelyAndMutableAliasesFailClosed() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/DefaultsAliases.swift",
            text: """
            import Foundation
            let first = UserDefaults.standard
            let second = first
            second.set(true, forKey: "foundryx.transitive-unknown")
            let suite = UserDefaults(suiteName: "fixture")
            if let unwrapped = suite {
                unwrapped.set(true, forKey: "foundryx.optional-unknown")
            }
            var mutable = UserDefaults.standard
            mutable = injectedDefaults
            mutable.set(true, forKey: "foundryx.capture.source")
            """)

        let violations = AccountPreferenceUsageGuard.scan(sources: [source])
        XCTAssertEqual(violations.count, 3)
        XCTAssertEqual(Set(violations.map(\.line)), [4, 7, 11])
    }

    func testDefaultsAliasFixedPointPropagatesMutability() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/MutableDefaultsChains.swift",
            text: """
            import Foundation
            let first = UserDefaults.standard
            var second = first
            second.set(true, forKey: "foundryx.capture.source")
            var optional = UserDefaults(suiteName: "fixture")
            if let unwrapped = optional {
                unwrapped.set(true, forKey: "foundryx.capture.source")
            }
            var later: UserDefaults
            later = first
            later.set(true, forKey: "foundryx.capture.source")
            """)

        let violations = AccountPreferenceUsageGuard.scan(sources: [source])
        XCTAssertEqual(violations.count, 3)
        XCTAssertEqual(Set(violations.map(\.line)), [4, 7, 11])
        XCTAssertTrue(violations.allSatisfy {
            $0.reason.contains("mutable UserDefaults alias")
        })
    }

    func testEscapedQuoteInsideNormalFixtureStringDoesNotExposeFakeCall() throws {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/EscapedQuoteMask.swift",
            text: #"""
            let fixture = "escaped quote: \" UserDefaults.standard.set(true, forKey: \"foundryx.fake\")"
            UserDefaults.standard.set(true, forKey: "foundryx.real")
            """#)

        let violations = AccountPreferenceUsageGuard.scan(sources: [source])
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations.first?.line, 2)
        XCTAssertEqual(violations.first?.keyOrUse, "foundryx.real")
    }

    func testCatalogActivationCannotBePartiallyFlipped() {
        var entries = AccountPreferenceCatalog.entries
        let first = entries[0]
        entries[0] = AccountPreferenceCatalogEntry(
            canonicalKey: first.canonicalKey,
            classification: first.classification,
            valueKind: first.valueKind,
            freshDefault: first.freshDefault,
            adoptionPolicy: first.adoptionPolicy,
            atomicGroup: first.atomicGroup,
            refreshOwner: first.refreshOwner,
            activationState: .inactiveCompatibility)
        let source = AccountPreferenceSourceFile(
            path: "Fixture/Benign.swift",
            text: "import Foundation")

        let violations = AccountPreferenceUsageGuard.scan(
            sources: [source],
            catalog: entries)
        XCTAssertEqual(violations.first?.path, "<catalog>")
        XCTAssertTrue(violations.first?.reason.contains("activation") == true)
    }

    func testTrackALegacyPairMustRemainAtomicAndServiceCoupled() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/BrokenTrackA.swift",
            text: """
            import Foundation
            enum CaptureAccountScope {
                static func adoptLegacyPairingRecord() {
                    _ = "com.goforgeit.foundryx.cell"
                }
                static func adoptLegacyCellPairing(defaults: UserDefaults) {
                    let urlKey = "foundryx.cell.url"
                    _ = defaults.string(forKey: urlKey)
                }
                static func adoptLegacyDoorPairing(defaults: UserDefaults) {
                    let urlKey = "foundryx.door.url"
                    _ = defaults.string(forKey: urlKey)
                }
            }
            """)
        let violations = AccountPreferenceUsageGuard.scan(sources: [source])
        XCTAssertTrue(violations.contains {
            $0.reason.contains("registered atomically")
        })
    }

    func testTrackAContractsArePerMethodAndOperational() {
        let splitNormal = AccountPreferenceSourceFile(
            path: "Fixture/CellStore.swift",
            text: """
            import Foundation
            final class CellStore {
                static let urlKey = "foundryx.cell.url"
                static let modeKey = "foundryx.cell.authMode"
                let defaults: UserDefaults
                let secretStore: PairingSecretStore
                let keychainService = "com.goforgeit.foundryx.cell"
                func pair(scoped: ScopedPreferences) {
                    defaults.set("url", forKey: scoped.key(Self.urlKey))
                }
                func unpair(scoped: ScopedPreferences) {
                    defaults.removeObject(forKey: scoped.key(Self.modeKey))
                }
                func load(scoped: ScopedPreferences) {
                    _ = defaults.string(forKey: scoped.key(Self.urlKey))
                    _ = defaults.string(forKey: scoped.key(Self.modeKey))
                }
                func unrelated(scoped: ScopedPreferences) {
                    _ = secretStore.read(
                        service: keychainService,
                        account: scoped.scope)
                }
            }
            """)
        let hollowLegacy = AccountPreferenceSourceFile(
            path: "Fixture/CaptureAccountScope.swift",
            text: """
            import Foundation
            enum CaptureAccountScope {
                static func adoptLegacyPairingRecord() {
                    let services = (
                        cell: "com.goforgeit.foundryx.cell",
                        door: "com.goforgeit.foundryx.door"
                    )
                    adoptLegacyCellPairing(service: services.cell)
                    adoptLegacyDoorPairing(service: services.door)
                }
                static func adoptLegacyCellPairing(service: String) {
                    _ = "foundryx.cell.url"
                    _ = "foundryx.cell.authMode"
                }
                static func adoptLegacyDoorPairing(service: String) {
                    _ = "foundryx.door.url"
                }
            }
            """)

        let violations = AccountPreferenceUsageGuard.scan(
            sources: [splitNormal, hollowLegacy])
        XCTAssertEqual(violations.count, 2)
        XCTAssertTrue(violations.contains {
            $0.keyOrUse == "Track-A CellStore registry"
        })
        XCTAssertTrue(violations.contains {
            $0.keyOrUse == "Track-A legacy pairing registry"
        })
    }

    func testTrackARejectsDetachedKeysAndWrongSecretAccounts() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/CellStore.swift",
            text: """
            import Foundation
            final class CellStore {
                static let urlKey = "foundryx.cell.url"
                static let modeKey = "foundryx.cell.authMode"
                let defaults: UserDefaults
                let secretStore: PairingSecretStore
                let keychainService = "com.goforgeit.foundryx.cell"
                func pair(scoped: ScopedPreferences) {
                    defaults.set("url", forKey: scoped.key(Self.urlKey))
                    _ = scoped.key(Self.modeKey)
                    _ = secretStore.remove(
                        service: keychainService,
                        account: "wrong")
                    _ = secretStore.replace(
                        "token",
                        service: keychainService,
                        account: "wrong")
                }
                func unpair(scoped: ScopedPreferences) {
                    defaults.removeObject(forKey: scoped.key(Self.urlKey))
                    _ = scoped.key(Self.modeKey)
                    _ = secretStore.remove(
                        service: keychainService,
                        account: "wrong")
                }
                func load(scoped: ScopedPreferences) {
                    _ = defaults.string(forKey: scoped.key(Self.urlKey))
                    _ = scoped.key(Self.modeKey)
                    _ = secretStore.read(
                        service: keychainService,
                        account: "wrong")
                }
            }
            """)

        let violations = AccountPreferenceUsageGuard.scan(sources: [source])
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(
            violations.first?.keyOrUse,
            "Track-A CellStore registry")
    }

    func testTrackALegacyBareCallsRejectReceiverSpoofs() {
        let source = AccountPreferenceSourceFile(
            path: "Fixture/CaptureAccountScope.swift",
            text: """
            import Foundation
            enum CaptureAccountScope {
                static func adoptLegacyPairingRecord(
                    defaults: UserDefaults,
                    scoped: ScopedPreferences
                ) {
                    let services = (
                        cell: "com.goforgeit.foundryx.cell",
                        door: "com.goforgeit.foundryx.door"
                    )
                    decoy . adoptLegacyCellPairing(
                        defaults: defaults,
                        scoped: scoped,
                        service: services.cell)
                    decoy.adoptLegacyDoorPairing(
                        defaults: defaults,
                        scoped: scoped,
                        service: services.door)
                }
                static func adoptLegacyCellPairing(
                    defaults: UserDefaults,
                    scoped: ScopedPreferences,
                    service: String
                ) {
                    let urlKey = "foundryx.cell.url"
                    let modeKey = "foundryx.cell.authMode"
                    let url = defaults.string(forKey: urlKey)
                    let mode = defaults.string(forKey: modeKey)
                    _ = decoy.adoptLegacyKeychainSecretIfNeeded(
                        service: service,
                        scope: scoped.scope)
                    defaults.set(url, forKey: scoped.key(urlKey))
                    defaults.set(mode, forKey: scoped.key(modeKey))
                }
                static func adoptLegacyDoorPairing(
                    defaults: UserDefaults,
                    scoped: ScopedPreferences,
                    service: String
                ) {
                    let urlKey = "foundryx.door.url"
                    let url = defaults.string(forKey: urlKey)
                    _ = decoy . adoptLegacyKeychainSecretIfNeeded(
                        service: service,
                        scope: scoped.scope)
                    defaults.set(url, forKey: scoped.key(urlKey))
                }
            }
            """)

        let violations = AccountPreferenceUsageGuard.scan(sources: [source])
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(
            violations.first?.keyOrUse,
            "Track-A legacy pairing registry")
    }

    func testMissingAndEmptyRepositoryRootsFailHard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foundryx-usage-guard-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try AccountPreferenceUsageGuard.scanRepository(at: root)) {
                XCTAssertEqual(
                    $0 as? AccountPreferenceUsageGuardError,
                    .missingRequiredRoot("Sources/FoundryXKit"))
            }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/FoundryXKit"),
            withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try AccountPreferenceUsageGuard.scanRepository(at: root)) {
                XCTAssertEqual(
                    $0 as? AccountPreferenceUsageGuardError,
                    .emptyRequiredRoot("Sources/FoundryXKit"))
            }
    }

    private func activeCatalog() -> [AccountPreferenceCatalogEntry] {
        AccountPreferenceCatalog.entries.map { entry in
            AccountPreferenceCatalogEntry(
                canonicalKey: entry.canonicalKey,
                classification: entry.classification,
                valueKind: entry.valueKind,
                freshDefault: entry.freshDefault,
                adoptionPolicy: entry.adoptionPolicy,
                atomicGroup: entry.atomicGroup,
                refreshOwner: entry.refreshOwner,
                activationState: .active)
        }
    }
}
