import Foundation
import XCTest
@testable import FoundryXKit

final class AccountPreferenceOwnerRoutingTests: XCTestCase {
    func testPersonaAndWelcomeReadsUseTheInjectedCompatibilityStore() {
        let suite = "AccountPreferenceOwnerRoutingTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(
            "not-a-persona",
            forKey: AccountPreferenceCatalog.onboardingPersona.canonicalKey)
        defaults.set(
            true,
            forKey: AccountPreferenceCatalog.welcomeSeen.canonicalKey)
        defaults.set(
            false,
            forKey: AccountPreferenceCatalog.welcomeLetStraightIn.canonicalKey)
        let compatibility = AccountPreferenceCompatibilityStore(defaults: defaults)

        XCTAssertEqual(
            PersonaPrefs.persona(compatibility: compatibility),
            .individual)
        XCTAssertTrue(WelcomePrefs.seen(compatibility: compatibility))
        XCTAssertFalse(
            WelcomePrefs.letStraightIn(compatibility: compatibility))
    }

    func testLegacySignupMarkerMigrationRequiresOpaqueOwnerProofs() {
        typealias Migration = LegacySignupMarkerMigration
        let construct: (UserDefaults) -> Migration = {
            Migration(defaults: $0)
        }
        let snapshot:
            (
                Migration,
                Migration.VerifiedIdentity,
                Migration.DurableLegacyOwnerProof
            ) -> AccountPreferencePresence<Bool> = {
                migration, identity, ownerProof in
                migration.snapshot(
                    identity: identity,
                    ownerProof: ownerProof)
            }
        let retire:
            (
                Migration,
                Migration.VerifiedIdentity,
                Migration.DurableLegacyOwnerProof,
                Migration.DeletionTombstoneProof
            ) -> AccountPreferenceWriteResult = {
                migration, identity, ownerProof, deletionTombstone in
                migration.retire(
                    identity: identity,
                    ownerProof: ownerProof,
                    deletionTombstone: deletionTombstone)
            }

        _ = construct
        _ = snapshot
        _ = retire
    }

    func testTypedOwnersPreserveLegacyValuesAndDefaults() throws {
        let suite = "AccountPreferenceOwnerParity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let compatibility = AccountPreferenceCompatibilityStore(defaults: defaults)

        XCTAssertEqual(
            compatibility.read(AccountPreferenceCatalog.onboardingCompleted),
            .value(false))
        XCTAssertEqual(
            compatibility.write(
                true,
                for: AccountPreferenceCatalog.onboardingCompleted),
            .saved)
        XCTAssertEqual(
            compatibility.read(AccountPreferenceCatalog.onboardingCompleted),
            .value(true))

        defaults.set(
            "invalid",
            forKey: AccountPreferenceCatalog.onboardingPersona.canonicalKey)
        XCTAssertEqual(
            PersonaPrefs.persona(compatibility: compatibility),
            .individual)
        XCTAssertEqual(
            PersonaPrefs.set(.expert, compatibility: compatibility),
            .saved)
        XCTAssertEqual(
            PersonaPrefs.persona(compatibility: compatibility),
            .expert)

        XCTAssertEqual(
            WelcomePrefs.markSeen(compatibility: compatibility),
            .saved)
        XCTAssertTrue(WelcomePrefs.seen(compatibility: compatibility))
        XCTAssertEqual(
            WelcomePrefs.setLetStraightIn(
                false,
                compatibility: compatibility),
            .saved)
        XCTAssertFalse(
            WelcomePrefs.letStraightIn(compatibility: compatibility))

        XCTAssertEqual(
            AmbientPrefs.setEnabled(true, compatibility: compatibility),
            .saved)
        XCTAssertTrue(AmbientPrefs.enabled(compatibility: compatibility))
        XCTAssertNil(AmbientPrefs.agentName(compatibility: compatibility))
        defaults.set(
            ["wrong-type"],
            forKey: AccountPreferenceCatalog.ambientAgentName.canonicalKey)
        XCTAssertNil(AmbientPrefs.agentName(compatibility: compatibility))
        XCTAssertEqual(
            AmbientPrefs.setAgentName("", compatibility: compatibility),
            .saved)
        XCTAssertEqual(
            AmbientPrefs.agentName(compatibility: compatibility),
            "")

        XCTAssertEqual(
            ActionSurfacePolicy.setOthersInline(
                true,
                compatibility: compatibility),
            .saved)
        XCTAssertTrue(
            ActionSurfacePolicy.othersInline(
                compatibility: compatibility))

        defaults.set(
            "invalid",
            forKey: AccountPreferenceCatalog.brainChoice.canonicalKey)
        let brains = BrainStore(
            compatibility: compatibility,
            hasPairedDesktop: false)
        XCTAssertEqual(brains.choice, .justMyPhone)
        XCTAssertTrue(
            brains.hasExplicitChoice,
            "an invalid legacy raw value still counted as an explicit choice")
        brains.select(.foundryCloud)
        XCTAssertEqual(
            BrainStore(compatibility: compatibility).choice,
            .foundryCloud)
    }

    func testBrainExplicitPresenceMatchesLegacyStringCoercionOnly()
        throws
    {
        let suite = "AccountPreferenceBrainPresence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let compatibility = AccountPreferenceCompatibilityStore(defaults: defaults)
        let key = AccountPreferenceCatalog.brainChoice.canonicalKey

        defaults.set("invalid-string", forKey: key)
        var brains = BrainStore(
            compatibility: compatibility,
            hasPairedDesktop: true)
        XCTAssertTrue(brains.hasExplicitChoice)
        XCTAssertEqual(brains.choice, .myComputer)

        defaults.set(true, forKey: key)
        brains = BrainStore(
            compatibility: compatibility,
            hasPairedDesktop: true)
        XCTAssertEqual(
            brains.hasExplicitChoice,
            defaults.string(forKey: key) != nil,
            "Bool coercion must remain exactly UserDefaults-compatible")
        XCTAssertEqual(brains.choice, .myComputer)

        defaults.set(["not", "a", "choice"], forKey: key)
        brains = BrainStore(
            compatibility: compatibility,
            hasPairedDesktop: true)
        XCTAssertFalse(brains.hasExplicitChoice)
        XCTAssertEqual(brains.choice, .myComputer)

        defaults.set(Data([0x62, 0x72, 0x61, 0x69, 0x6e]), forKey: key)
        brains = BrainStore(
            compatibility: compatibility,
            hasPairedDesktop: true)
        XCTAssertFalse(brains.hasExplicitChoice)
        XCTAssertEqual(brains.choice, .myComputer)
    }

    func testLegacyPresenceSeamIsStringOnlyAndSignupStaysSealed()
        throws
    {
        let stringPresence:
            (
                AccountPreferenceCompatibilityStore,
                AccountPreferenceKey<String>
            ) -> Bool = {
                compatibility, key in
                compatibility.hasLegacyStringValue(for: key)
            }
        _ = stringPresence

        let suite = "AccountPreferenceSealedSignup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let compatibility = AccountPreferenceCompatibilityStore(defaults: defaults)
        defaults.set(
            true,
            forKey: AccountPreferenceCatalog.signupPosted.canonicalKey)
        XCTAssertEqual(
            compatibility.read(AccountPreferenceCatalog.signupPosted),
            .absent)
        XCTAssertEqual(
            compatibility.write(
                true,
                for: AccountPreferenceCatalog.signupPosted),
            .rejected)

        let accountPreferences = normalize(
            try source(at: "Sources/FoundryXKit/AccountPreferences.swift"))
        XCTAssertTrue(
            accountPreferences.contains(
                "funchasLegacyStringValue("
                    + "forkey:AccountPreferenceKey<String>)->Bool"))
        XCTAssertFalse(accountPreferences.contains("hasLegacyValue<"))
        XCTAssertFalse(accountPreferences.contains("hasLegacyValue("))
    }

    func testGenerationBearingCompatibilityCompletionsStayLegacyEquivalent()
        throws
    {
        let suite = "AccountPreferenceGenerationParity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let compatibility = AccountPreferenceCompatibilityStore(defaults: defaults)
        let initiatingGeneration: UInt64 = 7
        let laterGeneration: UInt64 = 99
        XCTAssertNotEqual(initiatingGeneration, laterGeneration)

        XCTAssertEqual(
            WaitlistPrefs.completePost(
                succeeded: false,
                compatibility: compatibility,
                generation: initiatingGeneration),
            .rejected)
        XCTAssertFalse(WaitlistPrefs.joined(compatibility: compatibility))
        XCTAssertEqual(
            WaitlistPrefs.completePost(
                succeeded: true,
                compatibility: compatibility,
                generation: initiatingGeneration),
            .saved,
            "a delayed Task-2 success still commits its legacy value")
        XCTAssertTrue(WaitlistPrefs.joined(compatibility: compatibility))

        let attempts = VaultCheckoutAttemptStore(
            compatibility: compatibility)
        XCTAssertEqual(
            attempts.save(
                attemptId: "attempt-delayed",
                plan: .starter,
                generation: initiatingGeneration),
            .saved)
        XCTAssertEqual(
            attempts.load(generation: laterGeneration),
            .init(attemptId: "attempt-delayed", plan: .starter))
        XCTAssertEqual(
            attempts.clear(generation: initiatingGeneration),
            .saved)
        XCTAssertNil(attempts.load(generation: laterGeneration))

        let models = [ModelOption(id: "warm", label: "Warm")]
        XCTAssertEqual(
            ModelCache.save(
                models,
                compatibility: compatibility,
                generation: initiatingGeneration),
            .saved)
        XCTAssertEqual(
            ModelCache.load(
                compatibility: compatibility,
                generation: laterGeneration),
            models,
            "Task 2 keeps the shared stale completion warm")

        let account = " Owner@Example.COM "
        defaults.set(
            true,
            forKey: AccountPreferenceCatalog.signupPosted.canonicalKey)
        XCTAssertTrue(
            AccountClient.shouldPostSignup(
                account: account,
                compatibility: compatibility,
                generation: initiatingGeneration),
            "the static future key is ignored during compatibility")
        XCTAssertEqual(
            AccountClient.completeSignupPost(
                succeeded: false,
                account: account,
                compatibility: compatibility,
                generation: initiatingGeneration),
            .rejected)
        XCTAssertTrue(
            AccountClient.shouldPostSignup(
                account: account,
                compatibility: compatibility,
                generation: laterGeneration),
            "a failed delayed POST must remain retryable")
        XCTAssertEqual(
            AccountClient.completeSignupPost(
                succeeded: true,
                account: account,
                compatibility: compatibility,
                generation: initiatingGeneration),
            .saved)
        XCTAssertFalse(
            AccountClient.shouldPostSignup(
                account: account,
                compatibility: compatibility,
                generation: laterGeneration))
        XCTAssertNotNil(
            defaults.object(
                forKey:
                    "foundryx.account.signup-posted. owner@example.com "),
            "historical lowercase normalization must not trim")
    }

    func testCheckoutLegacyEmptyAndPartialShapesRemainPinned() throws {
        let suite = "AccountPreferenceCheckoutParity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let compatibility = AccountPreferenceCompatibilityStore(defaults: defaults)
        let attempts = VaultCheckoutAttemptStore(
            compatibility: compatibility)

        defaults.set(
            "",
            forKey:
                AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey)
        XCTAssertNil(attempts.load())

        defaults.set(
            "partial",
            forKey:
                AccountPreferenceCatalog.vaultCheckoutAttemptID.canonicalKey)
        defaults.removeObject(
            forKey:
                AccountPreferenceCatalog.vaultCheckoutAttemptPlan.canonicalKey)
        XCTAssertEqual(
            attempts.load(),
            .init(attemptId: "partial", plan: .pro))
        defaults.set(
            "invalid",
            forKey:
                AccountPreferenceCatalog.vaultCheckoutAttemptPlan.canonicalKey)
        XCTAssertEqual(
            attempts.load(),
            .init(attemptId: "partial", plan: .pro))
    }

    @MainActor
    func testCompatibilityStoreRefreshCarriesGenerationWithoutScopedState() {
        let generation = CaptureAccountScope.identityGeneration
        let coordinator = AccountIdentityCoordinator(
            activeGeneration: generation)
        var refreshes: [AccountPreferenceCompatibilityRefresh] = []
        coordinator.bind(
            onIdentityTransition: { _ in },
            onRestoreCompleted: { _ in },
            onTokenAvailable: { _ in },
            onCompatibilityStoreRefresh: { refreshes.append($0) })

        coordinator.restoreCompleted(generation: generation)

        XCTAssertEqual(
            refreshes,
            [.init(generation: generation)])
    }

    func testWaitlistSuccessStillUpdatesBothSurfacesIndependentOfWriteStatus()
        throws
    {
        for path in [
            "App/LocalChatScreen.swift",
            "App/SettingsScreen.swift",
        ] {
            let normalized = normalize(try source(at: path))
            XCTAssertTrue(
                normalized.contains(
                    "ifsucceeded{_=WaitlistPrefs.completePost("
                        + "succeeded:true,generation:generation)"
                        + "waitlistJoined=true}"),
                "\(path) must preserve successful-POST UI behavior while "
                    + "treating compatibility persistence as best effort")
        }
    }

    func testGenerationPlumbingIsPresentButCompatibilityOwnersStayDormant()
        throws
    {
        let expectedGenerationForms: [String: [String]] = [
            "Sources/FoundryXKit/VaultFunnel.swift": [
                "continueToCheckout(plan:VaultPlan,generation:UInt64)async",
                "reconcileOnForeground(generation:UInt64)async",
                "attempts.save(",
                "generation:generation)",
                "attempts.clear(generation:generation)",
            ],
            "Sources/FoundryXKit/RemoteSession.swift": [
                "postSignup(idToken:token,name:auth.signedInName,"
                    + "generation:requestedGeneration)",
                "completeSignupPost(succeeded:succeeded,account:account,"
                    + "compatibility:signupCompatibility,"
                    + "generation:requestedGeneration)",
            ],
            "App/ChatScreen.swift": [
                "ModelCache.save(fetched,"
                    + "compatibility:AccountPreferenceCompatibilityStore(),"
                    + "generation:accountBinding.generation)",
            ],
            "App/LocalChatScreen.swift": [
                "postWaitlist(idToken:token,generation:generation)",
                "completePost(succeeded:true,generation:generation)",
            ],
            "App/SettingsScreen.swift": [
                "postWaitlist(idToken:token,generation:generation)",
                "completePost(succeeded:true,generation:generation)",
            ],
            "Sources/FoundryXKit/AccountIdentityCoordinator.swift": [
                "AccountPreferenceCompatibilityRefresh",
                "onCompatibilityStoreRefresh(.init(generation:generation))",
            ],
        ]

        for (path, tokens) in expectedGenerationForms {
            let normalized = normalize(try source(at: path))
            for token in tokens {
                XCTAssertTrue(
                    normalized.contains(token),
                    "\(path) lost generation-bearing compatibility form: \(token)")
            }
        }

        let runtimeOwnerFiles = [
            "Sources/FoundryXKit/PersonaCopy.swift",
            "Sources/FoundryXKit/AmbientLane.swift",
            "Sources/FoundryXKit/ActionAttribution.swift",
            "Sources/FoundryXKit/VaultFunnel.swift",
            "Sources/FoundryXKit/BrainStore.swift",
            "Sources/FoundryXKit/ModelCache.swift",
            "Sources/FoundryXKit/AccountClient.swift",
            "Sources/FoundryXKit/RemoteSession.swift",
            "Sources/FoundryXKit/AccountIdentityCoordinator.swift",
            "App/OnboardingFlowView.swift",
            "App/RootView.swift",
            "App/SettingsScreen.swift",
            "App/LocalChatScreen.swift",
            "App/ChatScreen.swift",
            "App/CaptureScreen.swift",
        ]
        for path in runtimeOwnerFiles {
            let text = try source(at: path)
            XCTAssertFalse(text.contains("AccountPreferenceWriteStore("), path)
            XCTAssertFalse(
                text.contains("currentAccountPreferenceSnapshot("),
                path)
            XCTAssertFalse(text.contains("installAccountPreferenceSnapshot("), path)
            XCTAssertFalse(text.contains("AccountPreferenceAdoption"), path)
        }
        XCTAssertTrue(AccountPreferenceCatalog.entries.allSatisfy {
            $0.activationState == .inactiveCompatibility
        })
    }

    func testRawClassifiedDefaultsAccessIsAbsentFromOwnersAndCallSites() throws {
        let facadeFilesAndTypes = [
            ("Sources/FoundryXKit/PersonaCopy.swift", "PersonaPrefs"),
            ("Sources/FoundryXKit/PersonaCopy.swift", "WelcomePrefs"),
            ("Sources/FoundryXKit/AmbientLane.swift", "AmbientPrefs"),
            ("Sources/FoundryXKit/ActionAttribution.swift", "ActionSurfacePolicy"),
            ("Sources/FoundryXKit/VaultFunnel.swift", "VaultCheckoutAttemptStore"),
            ("Sources/FoundryXKit/BrainStore.swift", "BrainStore"),
            ("Sources/FoundryXKit/ModelCache.swift", "ModelCache"),
            ("Sources/FoundryXKit/AccountClient.swift", "AccountClient"),
        ]
        let callSiteFiles = [
            "App/OnboardingFlowView.swift",
            "App/RootView.swift",
            "App/SettingsScreen.swift",
            "App/LocalChatScreen.swift",
            "App/ChatScreen.swift",
            "App/CaptureScreen.swift",
            "App/ActionFeedbackFlow.swift",
            "App/AmbientNotifier.swift",
            "Sources/FoundryXKit/PersonaCopy.swift",
            "Sources/FoundryXKit/AmbientLane.swift",
            "Sources/FoundryXKit/ActionAttribution.swift",
            "Sources/FoundryXKit/VaultFunnel.swift",
            "Sources/FoundryXKit/BrainStore.swift",
            "Sources/FoundryXKit/ModelCache.swift",
            "Sources/FoundryXKit/AccountClient.swift",
            "Sources/FoundryXKit/RemoteSession.swift",
            "Sources/FoundryXKit/AccountIdentityCoordinator.swift",
            "Sources/FoundryXKit/DoorClient.swift",
            "Sources/FoundryXKit/ConversationDetailPresentation.swift",
        ]

        var violations: [String] = []
        for (path, type) in facadeFilesAndTypes {
            let source = try source(at: path)
            let body = try typeBody(named: type, in: source)
            let normalized = normalize(body)
            let operationalDefaults = [
                "defaults.bool(forKey:",
                "defaults.string(forKey:",
                "defaults.data(forKey:",
                "defaults.object(forKey:",
                "defaults.set(",
                "defaults.removeObject(forKey:",
            ]
            for operation in operationalDefaults where normalized.contains(operation) {
                violations.append("\(path): \(type) still calls \(operation)")
            }
        }

        for path in callSiteFiles {
            let normalized = normalize(try source(at: path))
            for call in rawStandardDefaultsCalls(in: normalized)
            where referencesClassifiedPreference(call) {
                violations.append("\(path): raw classified access \(call)")
            }
        }

        XCTAssertEqual(
            violations,
            [],
            "classified preferences must route through typed inactive owners:\n"
                + violations.joined(separator: "\n"))
    }

    func testHistoricalSignupPrefixIsConfinedToSealedMigrationAndCompatibilityHelper()
        throws
    {
        let accountPreferences = try source(
            at: "Sources/FoundryXKit/AccountPreferences.swift")
        let migration = try typeBody(
            named: "LegacySignupMarkerMigration",
            in: accountPreferences)

        XCTAssertFalse(migration.contains("public "))
        let normalizedMigration = normalize(migration)
        XCTAssertTrue(normalizedMigration.contains("VerifiedIdentity"))
        XCTAssertTrue(normalizedMigration.contains("DurableLegacyOwnerProof"))
        XCTAssertTrue(normalizedMigration.contains("DeletionTombstoneProof"))
        XCTAssertTrue(
            normalizedMigration.contains(
                "snapshot(identity:VerifiedIdentity,"
                    + "ownerProof:DurableLegacyOwnerProof)"
                    + "->AccountPreferencePresence<Bool>"))
        XCTAssertTrue(
            normalizedMigration.contains(
                "retire(identity:VerifiedIdentity,"
                    + "ownerProof:DurableLegacyOwnerProof,"
                    + "deletionTombstone:DeletionTombstoneProof)"
                    + "->AccountPreferenceWriteResult"))
        XCTAssertFalse(
            migration.range(
                of: #"\b(?:mark|set|write)\w*\s*\("#,
                options: .regularExpression) != nil,
            "the sealed migration must not expose a dynamic setter")

        var disallowedPrefixFiles: [String] = []
        let productionFiles = [
            "Sources/FoundryXKit/AccountPreferences.swift",
            "Sources/FoundryXKit/AccountClient.swift",
        ]
        for path in productionFiles {
            var sourceText = try source(at: path)
            if path.hasSuffix("AccountPreferences.swift") {
                sourceText = sourceText.replacingOccurrences(
                    of: migration,
                    with: "")
                let compatibilityHelper = try functionBlock(
                    named: "legacySignupKey",
                    in: sourceText)
                sourceText = sourceText.replacingOccurrences(
                    of: compatibilityHelper,
                    with: "")
            }
            if sourceText.contains("foundryx.account.signup-posted.") {
                disallowedPrefixFiles.append(path)
            }
        }
        XCTAssertEqual(
            disallowedPrefixFiles,
            [],
            "historical dynamic-key derivation escaped its two sealed helpers")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(at relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    private func normalize(_ source: String) -> String {
        source.replacingOccurrences(
            of: #"\s+"#,
            with: "",
            options: .regularExpression)
    }

    private func typeBody(named name: String, in source: String) throws -> String {
        let declaration = try XCTUnwrap(
            source.range(
                of: #"\b(?:public\s+)?(?:final\s+)?(?:enum|struct|class)\s+\#(name)\b"#,
                options: .regularExpression))
        return try bracedBlock(after: declaration, in: source)
    }

    private func functionBlock(named name: String, in source: String) throws -> String {
        let declaration = try XCTUnwrap(
            source.range(
                of: #"\bfunc\s+\#(name)\s*\("#,
                options: .regularExpression))
        return try bracedBlock(after: declaration, in: source)
    }

    private func bracedBlock(
        after declaration: Range<String.Index>,
        in source: String
    ) throws -> String {
        let opening = try XCTUnwrap(
            source[declaration.upperBound...].firstIndex(of: "{"))
        var depth = 0
        var cursor = opening
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[opening...cursor])
                }
            default: break
            }
            cursor = source.index(after: cursor)
        }
        throw NSError(
            domain: "AccountPreferenceOwnerRoutingTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "unterminated source block"])
    }

    private func rawStandardDefaultsCalls(in source: String) -> [String] {
        let prefix = "UserDefaults.standard."
        let operations = [
            "bool(forKey:", "string(forKey:", "data(forKey:",
            "object(forKey:", "set(", "removeObject(forKey:",
        ]
        var calls: [String] = []
        var searchStart = source.startIndex
        while let receiver = source.range(
            of: prefix,
            range: searchStart..<source.endIndex)
        {
            let operationStart = receiver.upperBound
            guard let operation = operations.first(where: {
                source[operationStart...].hasPrefix($0)
            }) else {
                searchStart = receiver.upperBound
                continue
            }
            let opening = source.index(
                operationStart,
                offsetBy: operation.firstIndex(of: "(")!.utf16Offset(
                    in: operation))
            var depth = 0
            var cursor = opening
            while cursor < source.endIndex {
                if source[cursor] == "(" { depth += 1 }
                if source[cursor] == ")" {
                    depth -= 1
                    if depth == 0 {
                        calls.append(String(source[receiver.lowerBound...cursor]))
                        searchStart = source.index(after: cursor)
                        break
                    }
                }
                cursor = source.index(after: cursor)
            }
            if cursor == source.endIndex { break }
        }
        return calls
    }

    private func referencesClassifiedPreference(_ call: String) -> Bool {
        let canonicalFragments = [
            "foundryx.onboarding.", "foundryx.welcome.",
            "foundryx.ambient.", "foundryx.vault.checkoutAttempt.",
            "foundryx.brain.choice", "foundryx.waitlist.joined",
            "foundryx.models.cache.v1", "foundryx.account.signup-posted",
        ]
        let aliases = [
            "OnboardingPrefs.completedKey",
            "PersonaPrefs.key",
            "WelcomePrefs.seenKey", "WelcomePrefs.letStraightInKey",
            "AmbientPrefs.enabledKey", "AmbientPrefs.agentNameKey",
            "AmbientPrefs.gradingKey",
            "ActionSurfacePolicy.othersInlineKey",
            "VaultCheckoutAttemptStore.idKey",
            "VaultCheckoutAttemptStore.planKey",
            "BrainStore.key", "ModelCache.key",
            "AccountPreferenceCatalog.",
        ]
        return (canonicalFragments + aliases).contains {
            call.contains($0)
        }
    }
}
