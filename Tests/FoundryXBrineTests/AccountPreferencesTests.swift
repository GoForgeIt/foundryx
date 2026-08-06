import Foundation
import XCTest
@testable import FoundryXKit

#if os(macOS)
import Darwin
#endif

final class AccountPreferencesTests: XCTestCase {
    func testCatalogContainsExactlyTheSeventeenCanonicalActiveEntries() throws {
        let entries = AccountPreferenceCatalog.entries
        XCTAssertEqual(entries.count, 17)
        XCTAssertEqual(Set(entries.map(\.canonicalKey)).count, 17)

        let expectedKeys = [
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
        XCTAssertEqual(Set(entries.map(\.canonicalKey)), Set(expectedKeys))
        XCTAssertTrue(entries.allSatisfy {
            $0.classification == .account
                && $0.activationState == .active
        })

        assertEntry(
            "foundryx.onboarding.completed", in: entries,
            value: .bool, fresh: .value(.bool(false)),
            adoption: .copyExplicit, group: .firstRun, owner: .onboardingRoot)
        assertEntry(
            "foundryx.onboarding.persona", in: entries,
            value: .string, fresh: .value(.string("individual")),
            adoption: .copyValid, group: .firstRun, owner: .personaRoot)
        assertEntry(
            "foundryx.welcome.seen", in: entries,
            value: .bool, fresh: .value(.bool(false)),
            adoption: .copyExplicit, group: .firstRun, owner: .welcomeRoot)
        assertEntry(
            "foundryx.welcome.letStraightIn", in: entries,
            value: .bool, fresh: .value(.bool(false)),
            adoption: .copyExplicit, group: .firstRun, owner: .welcomeRoot)
        assertEntry(
            "foundryx.ambient.enabled", in: entries,
            value: .bool, fresh: .value(.bool(false)),
            adoption: .copyExplicit, group: .ambientConsent, owner: .ambientRoot)
        assertEntry(
            "foundryx.ambient.agentName", in: entries,
            value: .string, fresh: .value(.string("Foundry")),
            adoption: .copyValid, group: .ambientProfile, owner: .ambientRoot)
        assertEntry(
            "foundryx.ambient.grading", in: entries,
            value: .bool, fresh: .explicit(.bool(false)),
            adoption: .copyExplicitOrMaterializeFalse,
            group: .ambientConsent, owner: .ambientDoor)
        assertEntry(
            "foundryx.ambient.othersInline", in: entries,
            value: .bool, fresh: .value(.bool(false)),
            adoption: .copyExplicit, group: .ambientProfile, owner: .actionPolicyUI)
        assertEntry(
            "foundryx.vault.checkoutAttempt.id", in: entries,
            value: .string, fresh: .absent,
            adoption: .copyCompleteAtomicGroup,
            group: .vaultCheckout, owner: .checkoutFunnel)
        assertEntry(
            "foundryx.vault.checkoutAttempt.plan", in: entries,
            value: .string, fresh: .absent,
            adoption: .copyCompleteAtomicGroup,
            group: .vaultCheckout, owner: .checkoutFunnel)
        assertEntry(
            "foundryx.brain.choice", in: entries,
            value: .string, fresh: .value(.string("phone")),
            adoption: .copyValid, group: .brain, owner: .brainRoot)
        assertEntry(
            "foundryx.waitlist.joined", in: entries,
            value: .bool, fresh: .value(.bool(false)),
            adoption: .copyExplicit, group: .waitlist, owner: .waitlistIdentity)
        assertEntry(
            "foundryx.capture.silence-gap-seconds", in: entries,
            value: .double, fresh: .value(.double(120)),
            adoption: .copyValid, group: .captureRuntime, owner: .captureSession)
        assertEntry(
            "foundryx.capture.omi-desired-state", in: entries,
            value: .string, fresh: .explicit(.string("paused")),
            adoption: .copyEstablishedExplicit,
            group: .captureRuntime, owner: .captureSession)
        assertEntry(
            "foundryx.capture.sources.enabled-overrides", in: entries,
            value: .boolDictionary, fresh: .value(.boolDictionary([:])),
            adoption: .copyEstablishedExplicit,
            group: .captureRuntime, owner: .sourceRegistry)
        assertEntry(
            "foundryx.models.cache.v1", in: entries,
            value: .data, fresh: .coldEmpty,
            adoption: .neverCopy, group: .modelsCache, owner: .modelChatSession)
        assertEntry(
            "foundryx.account.signup-posted", in: entries,
            value: .bool, fresh: .value(.bool(false)),
            adoption: .sealedLegacySnapshot,
            group: .signup, owner: .signupRemoteGeneration)

        requireKey(AccountPreferenceCatalog.onboardingCompleted, as: Bool.self)
        requireKey(AccountPreferenceCatalog.onboardingPersona, as: String.self)
        requireKey(AccountPreferenceCatalog.welcomeSeen, as: Bool.self)
        requireKey(AccountPreferenceCatalog.welcomeLetStraightIn, as: Bool.self)
        requireKey(AccountPreferenceCatalog.ambientEnabled, as: Bool.self)
        requireKey(AccountPreferenceCatalog.ambientAgentName, as: String.self)
        requireKey(AccountPreferenceCatalog.ambientGrading, as: Bool.self)
        requireKey(AccountPreferenceCatalog.ambientOthersInline, as: Bool.self)
        requireKey(AccountPreferenceCatalog.vaultCheckoutAttemptID, as: String.self)
        requireKey(AccountPreferenceCatalog.vaultCheckoutAttemptPlan, as: String.self)
        requireKey(AccountPreferenceCatalog.brainChoice, as: String.self)
        requireKey(AccountPreferenceCatalog.waitlistJoined, as: Bool.self)
        requireKey(AccountPreferenceCatalog.captureSilenceGapSeconds, as: Double.self)
        requireKey(AccountPreferenceCatalog.captureOMIDesiredState, as: String.self)
        requireKey(
            AccountPreferenceCatalog.captureSourceEnabledOverrides,
            as: [String: Bool].self)
        requireKey(AccountPreferenceCatalog.modelsCache, as: Data.self)
        requireKey(AccountPreferenceCatalog.signupPosted, as: Bool.self)
    }

    func testPresenceDistinguishesAbsentFromExplicitFalse() {
        let absent: AccountPreferencePresence<Bool> = .absent
        let explicitFalse: AccountPreferencePresence<Bool> = .value(false)

        XCTAssertNotEqual(absent, explicitFalse)
        XCTAssertEqual(explicitFalse, .value(false))
    }

    func testAtomicGroupsHaveTheExactCanonicalMembershipAndCheckoutIsIndivisible() {
        let expected: [AccountPreferenceAtomicGroup: Set<String>] = [
            .firstRun: [
                "foundryx.onboarding.completed",
                "foundryx.onboarding.persona",
                "foundryx.welcome.seen",
                "foundryx.welcome.letStraightIn",
            ],
            .ambientConsent: [
                "foundryx.ambient.enabled",
                "foundryx.ambient.grading",
            ],
            .ambientProfile: [
                "foundryx.ambient.agentName",
                "foundryx.ambient.othersInline",
            ],
            .vaultCheckout: [
                "foundryx.vault.checkoutAttempt.id",
                "foundryx.vault.checkoutAttempt.plan",
            ],
            .brain: ["foundryx.brain.choice"],
            .waitlist: ["foundryx.waitlist.joined"],
            .captureRuntime: [
                "foundryx.capture.silence-gap-seconds",
                "foundryx.capture.omi-desired-state",
                "foundryx.capture.sources.enabled-overrides",
            ],
            .modelsCache: ["foundryx.models.cache.v1"],
            .signup: ["foundryx.account.signup-posted"],
        ]

        XCTAssertEqual(Set(AccountPreferenceAtomicGroup.allCases), Set(expected.keys))
        for (group, keys) in expected {
            XCTAssertEqual(
                Set(AccountPreferenceCatalog.entries(in: group).map(\.canonicalKey)),
                keys,
                "incorrect membership for \(group)")
        }
        XCTAssertEqual(expected.values.reduce(0) { $0 + $1.count }, 17)
        XCTAssertTrue(AccountPreferenceAtomicGroup.vaultCheckout.isIndivisible)
        XCTAssertTrue(
            AccountPreferenceAtomicGroup.allCases
                .filter { $0 != .vaultCheckout }
                .allSatisfy { !$0.isIndivisible })
    }

    func testDormantAdoptionSnapshotAndResultArePureSendableValues() {
        let snapshot = AccountPreferenceAdoptionSnapshot(
            scope: "acct-1234abcd",
            generation: 41,
            legacyValues: [
                AccountPreferenceCatalog.ambientGrading.canonicalKey: .bool(false),
                AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey:
                    .string("attempt-7"),
                AccountPreferenceCatalog.vaultCheckoutAttemptPlan.canonicalKey:
                    .string("starter"),
            ],
            legacySignupPosted: .absent)
        let result = AccountPreferenceAdoptionResult(
            scope: snapshot.scope,
            generation: snapshot.generation,
            adoptedValues: [
                AccountPreferenceCatalog.ambientGrading.canonicalKey: .bool(false),
            ],
            adoptedGroups: [.ambientConsent],
            skippedKeys: [
                AccountPreferenceCatalog.modelsCache.canonicalKey,
            ])

        requireSendable(snapshot)
        requireSendable(result)
        XCTAssertEqual(snapshot.legacySignupPosted, .absent)
        XCTAssertEqual(
            snapshot.legacyValues[
                AccountPreferenceCatalog.ambientGrading.canonicalKey],
            .bool(false))
        XCTAssertEqual(result.scope, snapshot.scope)
        XCTAssertEqual(result.generation, snapshot.generation)
        XCTAssertEqual(result.adoptedGroups, [.ambientConsent])
        XCTAssertEqual(
            result.skippedKeys,
            [AccountPreferenceCatalog.modelsCache.canonicalKey])
    }

    func testTaskSixActivatesEveryCatalogEntryAtomically() {
        XCTAssertEqual(AccountPreferenceCatalog.entries.count, 17)
        XCTAssertTrue(AccountPreferenceCatalog.entries.allSatisfy {
            $0.activationState == .active
        })
    }

    func testEstablishedOwnerAdoptionPreservesExplicitValuesAndPrivacy()
        throws
    {
        let snapshot = AccountPreferenceAdoptionSnapshot(
            scope: "acct-a11ce",
            generation: 41,
            legacyValues: [
                AccountPreferenceCatalog.onboardingCompleted.canonicalKey:
                    .bool(true),
                AccountPreferenceCatalog.onboardingPersona.canonicalKey:
                    .string("expert"),
                AccountPreferenceCatalog.welcomeSeen.canonicalKey:
                    .bool(true),
                AccountPreferenceCatalog.welcomeLetStraightIn.canonicalKey:
                    .bool(false),
                AccountPreferenceCatalog.ambientEnabled.canonicalKey:
                    .bool(true),
                AccountPreferenceCatalog.ambientAgentName.canonicalKey:
                    .string("Sage"),
                AccountPreferenceCatalog.ambientOthersInline.canonicalKey:
                    .bool(true),
                AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey:
                    .string("attempt-1"),
                AccountPreferenceCatalog.vaultCheckoutAttemptPlan.canonicalKey:
                    .string("starter"),
                AccountPreferenceCatalog.brainChoice.canonicalKey:
                    .string("computer"),
                AccountPreferenceCatalog.waitlistJoined.canonicalKey:
                    .bool(false),
                AccountPreferenceCatalog.captureSilenceGapSeconds.canonicalKey:
                    .double(75),
                AccountPreferenceCatalog.captureOMIDesiredState.canonicalKey:
                    .string("listening"),
                AccountPreferenceCatalog.captureSourceEnabledOverrides.canonicalKey:
                    .boolDictionary(["omi": true]),
                AccountPreferenceCatalog.modelsCache.canonicalKey:
                    .data(Data("legacy-warm".utf8)),
            ],
            legacySignupPosted: .value(true))

        let result = AccountPreferenceAdoptionPlanner.resolve(
            snapshot,
            existingValues: [:],
            establishedLegacyOwner: true)

        XCTAssertEqual(
            result.adoptedValues[
                AccountPreferenceCatalog.onboardingCompleted.canonicalKey],
            .bool(true))
        XCTAssertEqual(
            result.adoptedValues[
                AccountPreferenceCatalog.welcomeLetStraightIn.canonicalKey],
            .bool(false),
            "explicit false must survive adoption")
        XCTAssertEqual(
            result.adoptedValues[
                AccountPreferenceCatalog.ambientGrading.canonicalKey],
            .bool(false),
            "absent established grading must materialize explicit false")
        XCTAssertEqual(
            result.adoptedValues[
                AccountPreferenceCatalog.signupPosted.canonicalKey],
            .bool(true))
        XCTAssertNil(
            result.adoptedValues[
                AccountPreferenceCatalog.modelsCache.canonicalKey],
            "legacy model caches must never be adopted")
        XCTAssertTrue(result.skippedKeys.contains(
            AccountPreferenceCatalog.modelsCache.canonicalKey))
    }

    func testFreshAndSignedOutPlansUseSafeDefaultsWithoutLegacyAdoption() {
        let legacy: [String: AccountPreferenceValue] = [
            AccountPreferenceCatalog.onboardingCompleted.canonicalKey:
                .bool(true),
            AccountPreferenceCatalog.ambientEnabled.canonicalKey:
                .bool(true),
            AccountPreferenceCatalog.ambientGrading.canonicalKey:
                .bool(true),
            AccountPreferenceCatalog.captureOMIDesiredState.canonicalKey:
                .string("listening"),
            AccountPreferenceCatalog.captureSourceEnabledOverrides.canonicalKey:
                .boolDictionary(["omi": true]),
            AccountPreferenceCatalog.modelsCache.canonicalKey:
                .data(Data("legacy-warm".utf8)),
        ]
        for scope in ["acct-b", CaptureAccountScope.signedOutScope] {
            let result = AccountPreferenceAdoptionPlanner.resolve(
                .init(
                    scope: scope,
                    generation: 7,
                    legacyValues: legacy,
                    legacySignupPosted: .value(true)),
                existingValues: [:],
                establishedLegacyOwner: false)

            XCTAssertEqual(
                result.adoptedValues[
                    AccountPreferenceCatalog.onboardingCompleted.canonicalKey],
                .bool(false))
            XCTAssertEqual(
                result.adoptedValues[
                    AccountPreferenceCatalog.ambientEnabled.canonicalKey],
                .bool(false))
            XCTAssertEqual(
                result.adoptedValues[
                    AccountPreferenceCatalog.ambientGrading.canonicalKey],
                .bool(false))
            XCTAssertEqual(
                result.adoptedValues[
                    AccountPreferenceCatalog.captureOMIDesiredState.canonicalKey],
                .string("paused"))
            XCTAssertEqual(
                result.adoptedValues[
                    AccountPreferenceCatalog.captureSourceEnabledOverrides.canonicalKey],
                .boolDictionary([:]))
            XCTAssertNil(
                result.adoptedValues[
                    AccountPreferenceCatalog.modelsCache.canonicalKey])
            XCTAssertNil(
                result.adoptedValues[
                    AccountPreferenceCatalog.signupPosted.canonicalKey])
        }
    }

    func testAdoptionRequiresACompleteValidCheckoutPair() {
        let id = AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey
        let plan = AccountPreferenceCatalog.vaultCheckoutAttemptPlan.canonicalKey
        for legacy in [
            [id: AccountPreferenceValue.string("partial")],
            [
                id: AccountPreferenceValue.string("partial"),
                plan: AccountPreferenceValue.string("invalid"),
            ],
        ] {
            let result = AccountPreferenceAdoptionPlanner.resolve(
                .init(
                    scope: "acct-b",
                    generation: 1,
                    legacyValues: legacy,
                    legacySignupPosted: .absent),
                existingValues: [:],
                establishedLegacyOwner: true)
            XCTAssertNil(result.adoptedValues[id])
            XCTAssertNil(result.adoptedValues[plan])
        }
    }

    func testSnapshotInstallRejectsMismatchedScopeOrGenerationWithoutCachingEither()
        throws
    {
        let fixture = try AccountPreferenceScopeFixture()
        defer { fixture.cleanup() }
        let binding = try XCTUnwrap(
            CaptureAccountScope.currentScopedPreferenceBinding())
        let wrongScope = AccountPreferenceSnapshot(
            scope: "acct-deadbeef",
            generation: binding.generation,
            values: [:])
        let wrongGeneration = AccountPreferenceSnapshot(
            scope: binding.scope,
            generation: binding.generation &+ 1,
            values: [:])

        XCTAssertFalse(
            CaptureAccountScope.installAccountPreferenceSnapshot(
                wrongScope, as: binding))
        XCTAssertNil(CaptureAccountScope.currentAccountPreferenceSnapshot())
        XCTAssertFalse(
            CaptureAccountScope.installAccountPreferenceSnapshot(
                wrongGeneration, as: binding))
        XCTAssertNil(CaptureAccountScope.currentAccountPreferenceSnapshot())
    }

    func testSnapshotReadUsesOnlyTheInstalledGenerationBoundCache() throws {
        let fixture = try AccountPreferenceScopeFixture()
        defer { fixture.cleanup() }
        let binding = try XCTUnwrap(
            CaptureAccountScope.currentScopedPreferenceBinding())
        let snapshot = AccountPreferenceSnapshot(
            scope: binding.scope,
            generation: binding.generation,
            values: [
                AccountPreferenceCatalog.ambientGrading.canonicalKey: .bool(false),
            ])
        requireSendable(snapshot)

        XCTAssertTrue(
            CaptureAccountScope.installAccountPreferenceSnapshot(
                snapshot, as: binding))
        fixture.defaults.set(
            true,
            forKey: "\(binding.scope).foundryx.ambient.grading")
        CaptureAccountScope.resetResolutionPersistenceEntriesForTests()

        let cached = try XCTUnwrap(
            CaptureAccountScope.currentAccountPreferenceSnapshot())
        XCTAssertEqual(
            cached.presence(for: AccountPreferenceCatalog.ambientGrading),
            .value(false))
        XCTAssertEqual(
            CaptureAccountScope.resolutionPersistenceEntryCountForTests,
            0,
            "a cached snapshot read entered identity persistence/default resolution")
    }

    func testDormantWriterSourceHasOnlyTheConcreteNonCallbackSurface() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let preferencesSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/FoundryXKit/AccountPreferences.swift"),
            encoding: .utf8)
        let scopeSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/FoundryXKit/CaptureAccountScope.swift"),
            encoding: .utf8)
        let taskSources = preferencesSource + scopeSource
        _ = AccountPreferenceWriteStore()
        let writerStart = try XCTUnwrap(preferencesSource.range(
            of: "public final class AccountPreferenceWriteStore"))
        let compatibilityStart = try XCTUnwrap(preferencesSource.range(
            of: "public struct AccountPreferenceCompatibilityContext"))
        let writerSource = String(preferencesSource[
            writerStart.lowerBound..<compatibilityStart.lowerBound])
        let admissionStart = try XCTUnwrap(scopeSource.range(
            of: "static func beginPreferenceStoreMutation"))
        let admissionEnd = try XCTUnwrap(scopeSource.range(
            of: "static func endPreferenceStoreMutation"))
        let admissionSource = String(scopeSource[
            admissionStart.lowerBound..<admissionEnd.lowerBound])

        XCTAssertTrue(preferencesSource.contains("AccountPreferenceWriteStore"))
        for forbidden in [
            "AccountPreferenceWriteSink",
            "public static func writeAccountPreference",
            "to sink:",
            "sink.write(",
            "signupAccount",
        ] {
            XCTAssertFalse(
                taskSources.contains(forbidden),
                "obsolete preference API remains: \(forbidden)")
        }
        XCTAssertFalse(
            writerSource.contains("UserDefaults"),
            "the writer must not create, retain, or accept a UserDefaults instance")
        for forbiddenPattern in [
            #"@escaping\b"#,
            #"init\s*\([^)]*\b(?:callback|sink|backend|persistence)\b\s*:"#,
            #"init\s*\([^)]*\bany\s+\w+"#,
        ] {
            XCTAssertNil(
                writerSource.range(
                    of: forbiddenPattern,
                    options: [.regularExpression, .caseInsensitive]),
                "writer persistence remains caller-injectable: \(forbiddenPattern)")
        }
        XCTAssertNil(
            admissionSource.range(
                of: #"stateLock\s*\.\s*(?:lock|withLock|wait)\s*\("#,
                options: .regularExpression),
            "preference admission may block on state held by perform(as:)")
        XCTAssertEqual(
            preferencesSource.components(
                separatedBy: "foundryx.account.signup-posted.\\(").count - 1,
            1,
            "legacy signup may have exactly one narrow dynamic derivation site")
        XCTAssertFalse(
            preferencesSource.contains("public final class AccountPreferenceWriteBarrier"),
            "the deterministic test barrier must remain package-internal")
    }

    func testCurrentBindingPersistsExactScopedKeyAndAcknowledgesReadback()
        throws
    {
        let fixture = try AccountPreferenceScopeFixture()
        defer { fixture.cleanup() }
        let binding = try XCTUnwrap(
            CaptureAccountScope.currentScopedPreferenceBinding())
        let scoped = try XCTUnwrap(
            CaptureAccountScope.currentScopedPreferences())
        let store = AccountPreferenceWriteStore(suiteName: fixture.defaultsName)
        let expectedKey = scoped.key(
            AccountPreferenceCatalog.waitlistJoined.canonicalKey)

        let acknowledgement = store.write(
            true,
            for: AccountPreferenceCatalog.waitlistJoined,
            as: binding)

        XCTAssertEqual(acknowledgement.status, .saved)
        XCTAssertEqual(acknowledgement.scopedKey, expectedKey)
        XCTAssertEqual(acknowledgement.persistedReadback, .bool(true))
        XCTAssertEqual(
            store.readback(
                AccountPreferenceCatalog.waitlistJoined,
                as: binding),
            .value(true))
        XCTAssertEqual(
            fixture.synchronizedObject(forKey: expectedKey) as? Bool,
            true)
    }

    func testCurrentBindingPersistsAbsentAsExplicitFalseAndAcknowledgesReadback()
        throws
    {
        let fixture = try AccountPreferenceScopeFixture()
        defer { fixture.cleanup() }
        let binding = try XCTUnwrap(
            CaptureAccountScope.currentScopedPreferenceBinding())
        let scoped = try XCTUnwrap(
            CaptureAccountScope.currentScopedPreferences())
        let store = AccountPreferenceWriteStore(suiteName: fixture.defaultsName)
        let expectedKey = scoped.key(
            AccountPreferenceCatalog.ambientEnabled.canonicalKey)
        XCTAssertNil(fixture.synchronizedObject(forKey: expectedKey))

        let acknowledgement = store.write(
            false,
            for: AccountPreferenceCatalog.ambientEnabled,
            as: binding)

        XCTAssertEqual(acknowledgement.status, .saved)
        XCTAssertEqual(acknowledgement.scopedKey, expectedKey)
        XCTAssertEqual(acknowledgement.persistedReadback, .bool(false))
        XCTAssertEqual(
            store.readback(AccountPreferenceCatalog.ambientEnabled, as: binding),
            .value(false))
        XCTAssertNotNil(fixture.synchronizedObject(forKey: expectedKey))
        XCTAssertEqual(
            fixture.synchronizedObject(forKey: expectedKey) as? Bool,
            false)
    }

    func testFixedPersistenceFaultsFailWithoutAcknowledgingOrChangingTheDomain()
        throws
    {
        for fault in [
            AccountPreferenceWriteFault.droppedPersistence,
            AccountPreferenceWriteFault.mismatchedReadback,
        ] {
            let fixture = try AccountPreferenceScopeFixture()
            let binding = try XCTUnwrap(
                CaptureAccountScope.currentScopedPreferenceBinding())
            let scoped = try XCTUnwrap(
                CaptureAccountScope.currentScopedPreferences())
            let store = AccountPreferenceWriteStore(
                suiteName: fixture.defaultsName,
                faultForTests: fault)
            let targetKey = scoped.key(
                AccountPreferenceCatalog.waitlistJoined.canonicalKey)
            fixture.defaults.set(false, forKey: targetKey)
            let before = fixture.persistentDomain

            let acknowledgement = store.write(
                true,
                for: AccountPreferenceCatalog.waitlistJoined,
                as: binding)

            XCTAssertEqual(acknowledgement.status, .failed)
            XCTAssertNil(acknowledgement.persistedReadback)
            XCTAssertEqual(
                fixture.synchronizedObject(forKey: targetKey) as? Bool,
                false)
            XCTAssertEqual(fixture.persistentDomain, before)
            fixture.cleanup()
        }
    }

    func testIdentityGenerationInvalidatesSnapshotAndRejectsStaleBindingBeforeStoreMutation()
        throws
    {
        let fixture = try AccountPreferenceScopeFixture()
        defer { fixture.cleanup() }
        let stale = try XCTUnwrap(
            CaptureAccountScope.currentScopedPreferenceBinding())
        let staleSnapshot = AccountPreferenceSnapshot(
            scope: stale.scope,
            generation: stale.generation,
            values: [:])
        XCTAssertTrue(
            CaptureAccountScope.installAccountPreferenceSnapshot(
                staleSnapshot,
                as: stale))

        try CaptureAccountScope.activateForTests(
            fixture.identity(subject: "second-owner"))
        let store = AccountPreferenceWriteStore(suiteName: fixture.defaultsName)
        let before = fixture.persistentDomain
        let acknowledgement = store.write(
            true,
            for: AccountPreferenceCatalog.waitlistJoined,
            as: stale)

        XCTAssertEqual(acknowledgement.status, .stale)
        XCTAssertNil(acknowledgement.scopedKey)
        XCTAssertNil(acknowledgement.persistedReadback)
        XCTAssertEqual(fixture.persistentDomain, before)
        XCTAssertNil(
            CaptureAccountScope.currentAccountPreferenceSnapshot(),
            "an identity transition retained the prior generation's snapshot")
        XCTAssertFalse(
            CaptureAccountScope.installAccountPreferenceSnapshot(
                staleSnapshot,
                as: stale),
            "the old binding reinstalled its snapshot after the transition")
        XCTAssertNil(CaptureAccountScope.currentAccountPreferenceSnapshot())
    }

    func testTransitionWaitingAtTheSameGateLetsTheCurrentWriteFinishFirst()
        throws
    {
        let fixture = try AccountPreferenceScopeFixture()
        let barrier = AccountPreferenceWriteBarrier()
        barrier.pauseNextWriteAfterGateAcquisition()
        let workers = DispatchGroup()
        var workersJoined = false
        defer {
            barrier.resumePausedWrite()
            let joined = workersJoined
                || workers.wait(timeout: .now() + 2) == .success
            XCTAssertTrue(joined, "overlap workers did not exit after the gate resumed")
            if joined {
                fixture.cleanup()
            }
        }
        let binding = try XCTUnwrap(
            CaptureAccountScope.currentScopedPreferenceBinding())
        let scoped = try XCTUnwrap(
            CaptureAccountScope.currentScopedPreferences())
        let store = AccountPreferenceWriteStore(
            suiteName: fixture.defaultsName,
            barrier: barrier)
        let acknowledgement = LockedBox<AccountPreferenceWriteAcknowledgement>()
        let transitionError = LockedBox<Error>()
        let overlappingIdentity = fixture.identity(subject: "overlap-owner")

        workers.enter()
        DispatchQueue.global().async {
            defer { workers.leave() }
            acknowledgement.set(store.write(
                true,
                for: AccountPreferenceCatalog.waitlistJoined,
                as: binding))
        }
        guard barrier.waitUntilWriteIsPausedAfterGateAcquisition(timeout: 1) else {
            XCTFail("writer did not pause after acquiring the lifecycle gate")
            return
        }

        workers.enter()
        DispatchQueue.global().async {
            defer { workers.leave() }
            do {
                try CaptureAccountScope.activateForTests(overlappingIdentity)
            } catch {
                transitionError.set(error)
            }
        }
        guard barrier.waitUntilIdentityTransitionIsWaitingAtGate(timeout: 1) else {
            XCTFail("identity transition did not positively reach the held lifecycle gate")
            return
        }

        barrier.resumePausedWrite()
        guard workers.wait(timeout: .now() + 2) == .success else {
            XCTFail("overlap workers did not finish after the controlled resume")
            return
        }
        workersJoined = true

        XCTAssertNil(transitionError.value)
        XCTAssertEqual(acknowledgement.value?.status, .saved)
        XCTAssertEqual(acknowledgement.value?.persistedReadback, .bool(true))
        XCTAssertEqual(
            fixture.synchronizedObject(forKey: scoped.key(
                AccountPreferenceCatalog.waitlistJoined.canonicalKey)) as? Bool,
            true)
    }

    func testTransitionFirstMakesConcreteStoreWriteStaleWithoutChangingTheDomain()
        throws
    {
        let fixture = try AccountPreferenceScopeFixture()
        defer { fixture.cleanup() }
        let stale = try XCTUnwrap(
            CaptureAccountScope.currentScopedPreferenceBinding())
        let store = AccountPreferenceWriteStore(suiteName: fixture.defaultsName)
        try CaptureAccountScope.activateForTests(
            fixture.identity(subject: "transition-first-owner"))
        let before = fixture.persistentDomain

        let acknowledgement = store.write(
            true,
            for: AccountPreferenceCatalog.waitlistJoined,
            as: stale)

        XCTAssertEqual(acknowledgement.status, .stale)
        XCTAssertNil(acknowledgement.scopedKey)
        XCTAssertNil(acknowledgement.persistedReadback)
        XCTAssertEqual(fixture.persistentDomain, before)
    }

    func testUnresolvedTransitionNeverMutatesAnyPartOfThePersistentDomain() throws {
        let fixture = try AccountPreferenceScopeFixture()
        defer { fixture.cleanup() }
        _ = try CaptureAccountScope.beginActivationForTestsOnly(
            for: fixture.identity(subject: "pending-owner"))
        let store = AccountPreferenceWriteStore(suiteName: fixture.defaultsName)

        XCTAssertNil(CaptureAccountScope.currentScopedPreferenceBinding())
        XCTAssertNil(CaptureAccountScope.currentAccountPreferenceSnapshot())
        let forgedSignedOut = ScopedPreferenceBinding(
            scope: "acct-none",
            generation: CaptureAccountScope.identityGeneration)
        let before = fixture.persistentDomain
        let acknowledgement = store.write(
            false,
            for: AccountPreferenceCatalog.ambientEnabled,
            as: forgedSignedOut)
        XCTAssertEqual(acknowledgement.status, .unresolved)
        XCTAssertNil(acknowledgement.scopedKey)
        XCTAssertNil(acknowledgement.persistedReadback)
        XCTAssertEqual(fixture.persistentDomain, before)
    }

    #if os(macOS)
    func testReentrantWriterReturnsRejectedInBoundedChildProcess() throws {
        let markerEnvironmentKey = "FOUNDRYX_PREF_REENTRANCY_MARKER"
        if let markerPath = ProcessInfo.processInfo.environment[
            markerEnvironmentKey]
        {
            let fixture = try AccountPreferenceScopeFixture()
            defer { fixture.cleanup() }
            let accountBinding = try XCTUnwrap(
                CaptureAccountScope.currentAccountBinding())
            let preferenceBinding = try XCTUnwrap(
                CaptureAccountScope.currentScopedPreferenceBinding())
            let store = AccountPreferenceWriteStore(
                suiteName: fixture.defaultsName)
            let before = fixture.persistentDomain
            guard let acknowledgement = CaptureAccountScope.perform(
                as: accountBinding,
                { _ in
                    store.write(
                        true,
                        for: AccountPreferenceCatalog.waitlistJoined,
                        as: preferenceBinding)
                })
            else {
                return XCTFail("reentrant write returned nil")
            }
            guard acknowledgement.status == .rejected else {
                return XCTFail(
                    "reentrant write returned \(acknowledgement.status), not rejected")
            }
            XCTAssertNil(acknowledgement.scopedKey)
            XCTAssertNil(acknowledgement.persistedReadback)
            XCTAssertEqual(fixture.persistentDomain, before)

            let crossThreadAcknowledgement = try XCTUnwrap(
                try CaptureAccountScope.perform(as: accountBinding) { _ in
                    let result =
                        LockedBox<AccountPreferenceWriteAcknowledgement>()
                    let finished = DispatchSemaphore(value: 0)
                    DispatchQueue.global().async {
                        result.set(store.write(
                            true,
                            for: AccountPreferenceCatalog.waitlistJoined,
                            as: preferenceBinding))
                        finished.signal()
                    }
                    finished.wait()
                    return try XCTUnwrap(result.value)
                })
            XCTAssertEqual(crossThreadAcknowledgement.status, .rejected)
            XCTAssertNil(crossThreadAcknowledgement.scopedKey)
            XCTAssertNil(crossThreadAcknowledgement.persistedReadback)
            XCTAssertEqual(fixture.persistentDomain, before)
            try Data("rejected".utf8).write(
                to: URL(fileURLWithPath: markerPath),
                options: .atomic)
            return
        }

        let testBundle = Bundle(for: AccountPreferencesTests.self).bundleURL
        XCTAssertEqual(testBundle.pathExtension, "xctest")
        let probeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "foundryx-preference-reentrancy-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: probeDirectory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probeDirectory) }
        let markerURL = probeDirectory.appendingPathComponent("completed")
        let logURL = probeDirectory.appendingPathComponent("xctest.log")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: logURL.path,
            contents: nil))
        let logHandle = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "FoundryXBrineTests.AccountPreferencesTests/"
                + "testReentrantWriterReturnsRejectedInBoundedChildProcess",
            testBundle.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "XCTestConfigurationFilePath")
        environment.removeValue(forKey: "XCInjectBundleInto")
        environment[markerEnvironmentKey] = markerURL.path
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        try process.run()
        let exitedInTime = terminated.wait(timeout: .now() + 5) == .success
        var observedTermination = exitedInTime
        if !observedTermination {
            process.terminate()
            observedTermination =
                terminated.wait(timeout: .now() + 1) == .success
            if !observedTermination {
                Darwin.kill(process.processIdentifier, SIGKILL)
                observedTermination =
                    terminated.wait(timeout: .now() + 1) == .success
            }
        }
        guard observedTermination else {
            logHandle.closeFile()
            let log = String(
                data: (try? Data(contentsOf: logURL)) ?? Data(),
                encoding: .utf8) ?? "<non-UTF-8 xctest output>"
            XCTFail("child did not terminate after TERM and SIGKILL:\n\(log)")
            return
        }
        process.waitUntilExit()
        logHandle.closeFile()
        let log = String(
            data: try Data(contentsOf: logURL),
            encoding: .utf8) ?? "<non-UTF-8 xctest output>"

        XCTAssertTrue(exitedInTime, "child writer deadlocked:\n\(log)")
        XCTAssertEqual(process.terminationStatus, 0, "child xctest failed:\n\(log)")
        XCTAssertEqual(
            try? String(contentsOf: markerURL, encoding: .utf8),
            "rejected",
            "child selector did not execute and prove the exact rejection:\n\(log)")
    }
    #endif

    private func assertEntry(
        _ key: String,
        in entries: [AccountPreferenceCatalogEntry],
        value: AccountPreferenceValueKind,
        fresh: AccountPreferenceFreshDefault,
        adoption: AccountPreferenceAdoptionPolicy,
        group: AccountPreferenceAtomicGroup,
        owner: AccountPreferenceRefreshOwner,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let entry = entries.first(where: { $0.canonicalKey == key }) else {
            return XCTFail("missing catalog entry \(key)", file: file, line: line)
        }
        XCTAssertEqual(entry.valueKind, value, file: file, line: line)
        XCTAssertEqual(entry.freshDefault, fresh, file: file, line: line)
        XCTAssertEqual(entry.adoptionPolicy, adoption, file: file, line: line)
        XCTAssertEqual(entry.atomicGroup, group, file: file, line: line)
        XCTAssertEqual(entry.refreshOwner, owner, file: file, line: line)
    }

    private func requireKey<Value>(
        _ key: AccountPreferenceKey<Value>,
        as _: Value.Type
    ) {}

    private func requireSendable<Value: Sendable>(_: Value) {}
}

final class AccountPreferenceCompatibilityTests: XCTestCase {
    func testLegacyDefaultsAndPresenceVectorsRemainUnscoped() throws {
        let fixture = try CompatibilityFixture()
        defer { fixture.cleanup() }
        let store = AccountPreferenceCompatibilityStore(defaults: fixture.defaults)

        XCTAssertEqual(store.read(AccountPreferenceCatalog.onboardingCompleted), .value(false))
        XCTAssertEqual(store.read(AccountPreferenceCatalog.onboardingPersona), .value("individual"))
        XCTAssertEqual(store.read(AccountPreferenceCatalog.welcomeSeen), .value(false))
        XCTAssertEqual(store.read(AccountPreferenceCatalog.welcomeLetStraightIn), .value(false))
        XCTAssertEqual(store.read(AccountPreferenceCatalog.ambientEnabled), .value(false))
        XCTAssertEqual(store.read(AccountPreferenceCatalog.ambientAgentName), .absent)
        XCTAssertEqual(
            store.read(
                AccountPreferenceCatalog.ambientGrading,
                context: .init(ownerVoiceEnrolled: false)),
            .value(false))
        XCTAssertEqual(
            store.read(
                AccountPreferenceCatalog.ambientGrading,
                context: .init(ownerVoiceEnrolled: true)),
            .value(true),
            "legacy absence still infers grading consent from owner voice until activation")
        XCTAssertEqual(store.read(AccountPreferenceCatalog.ambientOthersInline), .value(false))
        XCTAssertEqual(store.read(AccountPreferenceCatalog.vaultCheckoutAttemptID), .absent)
        XCTAssertEqual(store.read(AccountPreferenceCatalog.vaultCheckoutAttemptPlan), .absent)
        XCTAssertEqual(store.read(AccountPreferenceCatalog.brainChoice), .value("phone"))
        XCTAssertEqual(
            store.read(
                AccountPreferenceCatalog.brainChoice,
                context: .init(hasPairedDesktop: true)),
            .value("computer"))
        XCTAssertEqual(store.read(AccountPreferenceCatalog.waitlistJoined), .value(false))
        XCTAssertEqual(store.read(AccountPreferenceCatalog.captureSilenceGapSeconds), .value(120))
        XCTAssertEqual(store.read(AccountPreferenceCatalog.captureOMIDesiredState), .value("listening"))
        XCTAssertEqual(
            store.read(AccountPreferenceCatalog.captureSourceEnabledOverrides),
            .value([:]))
        XCTAssertEqual(store.read(AccountPreferenceCatalog.modelsCache), .absent)
        XCTAssertEqual(
            store.read(AccountPreferenceCatalog.signupPosted),
            .absent)
    }

    func testLegacySpecialCasesStayByteAndValueCompatible() throws {
        let fixture = try CompatibilityFixture()
        defer { fixture.cleanup() }
        let defaults = fixture.defaults
        let store = AccountPreferenceCompatibilityStore(defaults: defaults)
        defaults.set(
            [1, 2],
            forKey: AccountPreferenceCatalog.ambientAgentName.canonicalKey)
        XCTAssertEqual(
            store.read(AccountPreferenceCatalog.ambientAgentName),
            .absent,
            "a wrong-typed stored name remains distinct from an empty string")
        defaults.set(
            "",
            forKey: AccountPreferenceCatalog.ambientAgentName.canonicalKey)
        defaults.set(
            false,
            forKey: AccountPreferenceCatalog.ambientGrading.canonicalKey)
        defaults.set("attempt-7", forKey: AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey)
        let models = Data(#"[{"id":"door-model","label":"Door Model"}]"#.utf8)
        defaults.set(models, forKey: AccountPreferenceCatalog.modelsCache.canonicalKey)

        XCTAssertEqual(
            store.read(AccountPreferenceCatalog.ambientAgentName),
            .value(""),
            "an explicitly stored empty name remains distinct from absence")
        XCTAssertEqual(
            store.remove(AccountPreferenceCatalog.ambientAgentName),
            .saved)
        XCTAssertEqual(
            store.read(AccountPreferenceCatalog.ambientAgentName),
            .absent)
        let afterFirstAgentRemoval = fixture.persistentDomain
        XCTAssertEqual(
            store.remove(AccountPreferenceCatalog.ambientAgentName),
            .saved,
            "removing an already absent optional value is idempotent")
        XCTAssertEqual(fixture.persistentDomain, afterFirstAgentRemoval)
        XCTAssertEqual(
            store.read(
                AccountPreferenceCatalog.ambientGrading,
                context: .init(ownerVoiceEnrolled: true)),
            .value(false),
            "an explicit grading choice overrides legacy owner-voice inference")
        XCTAssertEqual(
            store.read(AccountPreferenceCatalog.vaultCheckoutAttemptPlan),
            .value("pro"),
            "the legacy partial-checkout fallback remains pinned until activation")
        defaults.set(
            "starter",
            forKey: AccountPreferenceCatalog.vaultCheckoutAttemptPlan.canonicalKey)
        let checkoutBefore = fixture.persistentDomain
        XCTAssertEqual(
            store.remove(AccountPreferenceCatalog.vaultCheckoutAttemptID),
            .rejected)
        XCTAssertEqual(
            store.remove(AccountPreferenceCatalog.vaultCheckoutAttemptPlan),
            .rejected)
        XCTAssertEqual(
            fixture.persistentDomain,
            checkoutBefore,
            "neither member of an indivisible checkout pair may be removed alone")
        XCTAssertEqual(store.clearLegacyCheckoutAttempt(), .saved)
        XCTAssertNil(defaults.object(
            forKey: AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey))
        XCTAssertNil(defaults.object(
            forKey: AccountPreferenceCatalog.vaultCheckoutAttemptPlan.canonicalKey))
        let afterFirstCheckoutClear = fixture.persistentDomain
        XCTAssertEqual(
            store.clearLegacyCheckoutAttempt(),
            .saved,
            "clearing an already absent checkout pair is idempotent")
        XCTAssertEqual(fixture.persistentDomain, afterFirstCheckoutClear)
        XCTAssertEqual(store.read(AccountPreferenceCatalog.modelsCache), .value(models))
    }

    func testLegacySignupIsAvailableOnlyAsASealedActivationSnapshot() throws {
        let fixture = try CompatibilityFixture()
        defer { fixture.cleanup() }
        let defaults = fixture.defaults
        let store = AccountPreferenceCompatibilityStore(defaults: defaults)
        let identity = AuthIdentity(
            provider: "google",
            idToken: "not-a-jwt",
            refreshToken: nil,
            expiresAt: .distantFuture,
            email: "Nick@GoForgeIt.com")
        let scope = "acct-owner"
        let historicalKey =
            "foundryx.account.signup-posted.nick@goforgeit.com"
        defaults.set(
            true, forKey: historicalKey)
        let before = fixture.persistentDomain

        XCTAssertEqual(
            store.read(AccountPreferenceCatalog.signupPosted),
            .absent)
        XCTAssertEqual(
            store.write(false, for: AccountPreferenceCatalog.signupPosted),
            .rejected)
        XCTAssertEqual(
            store.remove(AccountPreferenceCatalog.signupPosted),
            .rejected)
        XCTAssertEqual(
            fixture.persistentDomain,
            before,
            "normal compatibility APIs cannot mutate dynamic signup state")
        XCTAssertEqual(
            LegacySignupMarkerMigration.snapshotForActivation(
                identity: identity,
                ownerScope: scope,
                generation: 7,
                durableLegacyOwnerScope: scope,
                defaults: defaults),
            .value(true))
        XCTAssertEqual(fixture.persistentDomain, before)
        XCTAssertEqual(
            LegacySignupMarkerMigration.snapshotForActivation(
                identity: identity,
                ownerScope: "acct-other",
                generation: 7,
                durableLegacyOwnerScope: scope,
                defaults: defaults),
            .absent)
    }

    func testLegacyAsyncCompletionStillWritesAfterIdentityGenerationChanges() throws {
        let fixture = try AccountPreferenceScopeFixture()
        defer { fixture.cleanup() }
        let store = AccountPreferenceCompatibilityStore(defaults: fixture.defaults)
        let initiatingGeneration = CaptureAccountScope.identityGeneration
        try CaptureAccountScope.activateForTests(
            fixture.identity(subject: "later-owner"))
        XCTAssertNotEqual(initiatingGeneration, CaptureAccountScope.identityGeneration)

        XCTAssertEqual(
            store.write(true, for: AccountPreferenceCatalog.waitlistJoined),
            .saved)
        XCTAssertTrue(
            fixture.defaults.bool(
                forKey: AccountPreferenceCatalog.waitlistJoined.canonicalKey))
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        lock.withLock { stored }
    }

    func set(_ value: Value) {
        lock.withLock {
            stored = value
        }
    }
}

private final class CompatibilityFixture {
    let name = "foundryx-account-preference-compatibility-\(UUID().uuidString)"
    let defaults: UserDefaults

    var persistentDomain: NSDictionary {
        (defaults.persistentDomain(forName: name) ?? [:]) as NSDictionary
    }

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: name)
    }
}

private final class AccountPreferenceScopeFixture {
    let defaultsName = "foundryx-account-preference-scope-\(UUID().uuidString)"
    let defaults: UserDefaults
    let container: URL

    var persistentDomain: NSDictionary {
        _ = defaults.synchronize()
        return (defaults.persistentDomain(forName: defaultsName) ?? [:])
            as NSDictionary
    }

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent(defaultsName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true)
        CaptureAccountScope.resetTestEnvironment()
        CaptureAccountScope.setContainerForTests(container)
        CaptureAccountScope.setDefaultsForTests(defaults)
        try CaptureAccountScope.activateForTests(identity(subject: "first-owner"))
    }

    func identity(subject: String) -> AuthIdentity {
        AuthIdentity(
            provider: AuthProvider.google.rawValue,
            idToken: Self.idToken(subject: subject),
            refreshToken: nil,
            expiresAt: .distantFuture,
            email: "\(subject)@example.test")
    }

    func synchronizedObject(forKey key: String) -> Any? {
        _ = defaults.synchronize()
        return defaults.object(forKey: key)
    }

    func cleanup() {
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
