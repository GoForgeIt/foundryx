import Foundation
import XCTest
@testable import FoundryXKit

final class AccountDeletionLifecycleTests: XCTestCase {
    private let scopeB = "acct-bbbbbbbbbbbbbbbb"
    private let scopeA = "acct-aaaaaaaaaaaaaaaa"

    func testV1RecordRoundTripsEverySealedField() throws {
        let record = AccountDeletionLifecycleRecord(
            version: 1,
            ownerScope: scopeB,
            deletionEpoch: 41,
            phase: .cleanupPending,
            exposureBarrier: .closed,
            blockedGeneration: 73,
            completedGroups: [
                .trackBPreferences,
                .pairingPreferences,
                .pairingSecrets,
            ],
            legacyDisposition: .pending)

        let encoded = try AccountDeletionLifecycleCodec.encode(record)
        XCTAssertEqual(
            try AccountDeletionLifecycleCodec.decode(encoded),
            record)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["ownerScope"] as? String, scopeB)
        XCTAssertEqual(object["deletionEpoch"] as? UInt64, 41)
        XCTAssertEqual(object["phase"] as? String, "cleanupPending")
        XCTAssertEqual(object["exposureBarrier"] as? String, "closed")
        XCTAssertEqual(object["blockedGeneration"] as? UInt64, 73)
        XCTAssertEqual(
            object["completedGroups"] as? [String],
            ["trackBPreferences", "pairingPreferences", "pairingSecrets"])
        XCTAssertEqual(object["legacyDisposition"] as? String, "pending")
    }

    func testCodecAndStoreFailClosedForEveryUnreadableRecordClass() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanup() }

        fixture.io.readResult = .absent
        XCTAssertEqual(
            fixture.store.read(ownerScope: scopeB),
            .missing)

        fixture.io.readResult = .success(Data("{broken".utf8))
        XCTAssertEqual(
            fixture.store.read(ownerScope: scopeB),
            .blocked(.corrupt))

        let unsupported = Data("""
            {"version":2,"ownerScope":"\(scopeB)","deletionEpoch":1,
             "phase":"cleanupPending","exposureBarrier":"pending",
             "blockedGeneration":null,"completedGroups":[],
             "legacyDisposition":"pending"}
            """.utf8)
        fixture.io.readResult = .success(unsupported)
        XCTAssertEqual(
            fixture.store.read(ownerScope: scopeB),
            .blocked(.unsupportedVersion(2)))

        fixture.io.readResult = .failure(.unreadable)
        XCTAssertEqual(
            fixture.store.read(ownerScope: scopeB),
            .blocked(.unreadable))
        fixture.io.readResult = .failure(.protectedDataUnavailable)
        XCTAssertEqual(
            fixture.store.read(ownerScope: scopeB),
            .blocked(.protectedDataUnavailable))
        fixture.io.readResult = .failure(.failed)
        XCTAssertEqual(
            fixture.store.read(ownerScope: scopeB),
            .blocked(.failed))
    }

    func testRecordPathAndStateMachineRejectEveryInconsistentForm()
        throws
    {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(
            try fixture.store.recordURL(ownerScope: scopeB),
            fixture.root
                .appendingPathComponent(
                    ".account-deletions-v1",
                    isDirectory: true)
                .appendingPathComponent("\(scopeB).json"))
        for invalidScope in [
            "",
            "acct-none",
            "../acct-b",
            "acct-b/escape",
            ".account-deletions-v1",
            "not-an-account",
        ] {
            XCTAssertThrowsError(
                try fixture.store.recordURL(ownerScope: invalidScope))
        }

        func data(_ changes: [String: Any]) throws -> Data {
            var object: [String: Any] = [
                "version": 1,
                "ownerScope": scopeB,
                "deletionEpoch": 1,
                "phase": "cleanupPending",
                "exposureBarrier": "pending",
                "blockedGeneration": NSNull(),
                "completedGroups": [],
                "legacyDisposition": "pending",
            ]
            object.merge(changes) { _, replacement in replacement }
            return try JSONSerialization.data(withJSONObject: object)
        }

        let invalidRecords: [[String: Any]] = [
            ["ownerScope": "../escape"],
            ["ownerScope": scopeA],
            ["phase": "unknown"],
            ["exposureBarrier": "unknown"],
            ["completedGroups": ["unknown"]],
            ["completedGroups": [
                "trackBPreferences", "trackBPreferences",
            ]],
            ["completedGroups": [
                "pairingPreferences", "trackBPreferences",
            ]],
            ["completedGroups": ["pairingPreferences"]],
            ["blockedGeneration": 1],
            [
                "exposureBarrier": "pending",
                "completedGroups": ["trackBPreferences"],
            ],
            [
                "exposureBarrier": "closed",
                "blockedGeneration": NSNull(),
            ],
            [
                "phase": "completed",
                "exposureBarrier": "pending",
                "completedGroups": [],
            ],
            [
                "phase": "completed",
                "exposureBarrier": "closed",
                "blockedGeneration": 2,
                "completedGroups": [
                    "trackBPreferences",
                    "pairingPreferences",
                    "pairingSecrets",
                    "localRoot",
                ],
                "legacyDisposition": "retired",
            ],
            [
                "phase": "completed",
                "exposureBarrier": "closed",
                "blockedGeneration": 2,
                "completedGroups": [
                    "trackBPreferences",
                    "pairingPreferences",
                    "pairingSecrets",
                    "localRoot",
                    "legacyInputs",
                ],
                "legacyDisposition": "pending",
            ],
            [
                "phase": "cleanupPending",
                "exposureBarrier": "closed",
                "blockedGeneration": 2,
                "completedGroups": ["trackBPreferences"],
                "legacyDisposition": "retired",
            ],
            [
                "phase": "cleanupPending",
                "exposureBarrier": "closed",
                "blockedGeneration": 2,
                "completedGroups": [
                    "trackBPreferences",
                    "pairingPreferences",
                    "pairingSecrets",
                    "localRoot",
                ],
                "legacyDisposition": "notOwned",
            ],
        ]
        for changes in invalidRecords {
            fixture.io.readResult = .success(try data(changes))
            guard case .blocked = fixture.store.read(ownerScope: scopeB) else {
                XCTFail("accepted inconsistent record changes: \(changes)")
                continue
            }
        }
    }

    func testEveryMutationUsesAtomicDurabilityTypedReadbackAndCAS() throws {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanup() }
        fixture.io.readResult = .absent

        let pending = try fixture.store.createPending(ownerScope: scopeB)
        XCTAssertEqual(pending.deletionEpoch, 1)
        XCTAssertEqual(
            fixture.io.operations,
            [
                .readCurrent,
                .createUniqueTempSameDirectory0600,
                .writeAll,
                .fsyncFile,
                .closeFile,
                .renamePOSIX,
                .fsyncParent,
                .closeParent,
                .typedReadback,
            ])
        fixture.io.readResult = .mirrorLastWrite

        fixture.io.operations = []
        let closed = try fixture.store.compareAndSwap(
            ownerScope: scopeB,
            expectedEpoch: pending.deletionEpoch
        ) {
            $0.exposureBarrier = .closed
            $0.blockedGeneration = 9
        }
        XCTAssertEqual(closed.deletionEpoch, pending.deletionEpoch)
        XCTAssertEqual(
            fixture.io.operations,
            [
                .readCurrent,
                .createUniqueTempSameDirectory0600,
                .writeAll,
                .fsyncFile,
                .closeFile,
                .renamePOSIX,
                .fsyncParent,
                .closeParent,
                .typedReadback,
            ])

        XCTAssertThrowsError(try fixture.store.compareAndSwap(
            ownerScope: scopeB,
            expectedEpoch: pending.deletionEpoch - 1
        ) { $0.phase = .completed }) {
            XCTAssertEqual(
                $0 as? AccountDeletionLifecycleError,
                .staleEpoch(
                    expected: pending.deletionEpoch - 1,
                    actual: pending.deletionEpoch))
        }

        let resumed = try fixture.store.createPending(ownerScope: scopeB)
        XCTAssertEqual(resumed, closed)

        fixture.io.corruptTypedReadback = true
        XCTAssertThrowsError(
            try fixture.store.compareAndSwap(
                ownerScope: scopeB,
                expectedEpoch: resumed.deletionEpoch
            ) { $0.exposureBarrier = .closed }) {
                XCTAssertEqual(
                    $0 as? AccountDeletionLifecycleError,
                    .typedReadbackMismatch)
            }
    }

    func testPendingDurabilityImmediatelyRevokesEveryCachedAdmission()
        async throws
    {
        let fixture = try DeletionScopeFixture()
        defer { fixture.cleanup() }
        let identity = fixture.identity(subject: "owner-b")
        try CaptureAccountScope.activateForTests(identity)
        let binding = try XCTUnwrap(
            CaptureAccountScope.currentAccountBinding())
        let lifecycle = AccountDeletionLifecycle(
            store: AccountDeletionLifecycleStore(container: fixture.root),
            environment: AccountDeletionLifecycleEnvironment(
                verifyCurrentBinding: { CaptureAccountScope.isCurrent($0) },
                blockResolution: {
                    try CaptureAccountScope.blockForAccountDeletion(
                        expected: $0)
                },
                deliverIdentityBoundary: { _ in },
                setSignedInMirrorFalse: { _ in },
                withdrawWidget: { binding in
                    switch CaptureWidgetSnapshotStore.withdraw(
                        expectedOwner: binding.scope) {
                    case .withdrawn: return .closed
                    case .alreadyAbsent: return .alreadyClosed
                    case .ownerMismatch: return .ownerMismatch
                    case .persistenceFailed: return .persistenceFailed
                    }
                },
                closeLiveExposures: { _ in [] },
                cancelStaleWork: { _ in [] },
                verifyExposureBarrier: { _, _ in true },
                removeGroup: { _, _, _ in },
                verifyGroupAbsent: { _, _ in true },
                legacyOwnerScope: { nil }),
            faultInjector: DeletionFaultInjector { point in
                if point == DeletionFaultPoint(.after, .pendingReadback) {
                    throw AccountDeletionLifecycleError.injectedCrash(point)
                }
            })

        await XCTAssertThrowsErrorAsync {
            try await lifecycle.begin(binding: binding)
        }

        XCTAssertFalse(CaptureAccountScope.isCurrent(binding))
        XCTAssertNil(CaptureAccountScope.perform(as: binding) { _ in true })
        XCTAssertNil(CaptureAccountScope.currentScopedPreferences())
        XCTAssertNil(CaptureAccountScope.currentScopedPreferenceBinding())
        XCTAssertNil(CaptureAccountScope.currentAccountBinding())
        XCTAssertTrue(CaptureAccountScope.currentRoot().path.contains(
            "account-scope-unavailable"))
        XCTAssertFalse(FoundryAuth.hasPersistedSignIn)
        XCTAssertNil(CaptureWidgetSnapshotStore.activeOwnerForTests)
    }

    func testAmbiguousPostRenamePendingNeverReopensCachedOwner() throws {
        let fixture = try DeletionScopeFixture()
        defer { fixture.cleanup() }
        let identity = fixture.identity(subject: "owner-b")
        try CaptureAccountScope.activateForTests(identity)
        let binding = try XCTUnwrap(
            CaptureAccountScope.currentAccountBinding())
        let store = AccountDeletionLifecycleStore(container: fixture.root)

        XCTAssertThrowsError(
            try CaptureAccountScope.persistPendingAccountDeletion(
                expected: binding
            ) {
                _ = try store.createPending(ownerScope: binding.scope)
                throw AccountDeletionLifecycleError.durability
            })
        XCTAssertNotNil(
            store.read(ownerScope: binding.scope).record,
            "the renamed destination is durable despite the ambiguous error")
        assertEveryCachedAdmissionIsBlocked(binding)
    }

    func testProvenPreRenameFailureCanRetryButUnreadableAmbiguityStaysBlocked()
        throws
    {
        let fixture = try DeletionScopeFixture()
        defer { fixture.cleanup() }
        let identity = fixture.identity(subject: "owner-b")
        try CaptureAccountScope.activateForTests(identity)
        let binding = try XCTUnwrap(
            CaptureAccountScope.currentAccountBinding())

        XCTAssertThrowsError(
            try CaptureAccountScope.persistPendingAccountDeletion(
                expected: binding
            ) {
                throw AccountDeletionLifecycleError.durability
            })
        XCTAssertTrue(CaptureAccountScope.isCurrent(binding))

        let store = AccountDeletionLifecycleStore(container: fixture.root)
        XCTAssertThrowsError(
            try CaptureAccountScope.persistPendingAccountDeletion(
                expected: binding
            ) {
                _ = try store.createPending(ownerScope: binding.scope)
                AccountDeletionLifecycleStore.setReadFailureForTests(
                    .unreadable, ownerScope: binding.scope)
                throw AccountDeletionLifecycleError.durability
            })
        defer {
            AccountDeletionLifecycleStore.setReadFailureForTests(
                nil, ownerScope: binding.scope)
        }
        assertEveryCachedAdmissionIsBlocked(binding)
    }

    func testExternalDurablePendingBlocksNonHotWritesAndPublication()
        throws
    {
        let fixture = try DeletionScopeFixture()
        defer { fixture.cleanup() }
        let identity = fixture.identity(subject: "owner-b")
        try CaptureAccountScope.activateForTests(identity)
        let binding = try XCTUnwrap(
            CaptureAccountScope.currentAccountBinding())
        let preferenceBinding = try XCTUnwrap(
            CaptureAccountScope.currentScopedPreferenceBinding())
        let snapshot = AccountPreferenceSnapshot(
            scope: preferenceBinding.scope,
            generation: preferenceBinding.generation,
            values: [:])
        XCTAssertTrue(CaptureAccountScope.installAccountPreferenceSnapshot(
            snapshot, as: preferenceBinding))

        _ = try AccountDeletionLifecycleStore(container: fixture.root)
            .createPending(ownerScope: binding.scope)

        XCTAssertEqual(
            CaptureAccountScope.currentAccountPreferenceSnapshot(),
            snapshot,
            "normal immutable snapshot reads remain cache-only")
        assertEveryCachedAdmissionIsBlocked(binding)
        let writeStore = AccountPreferenceWriteStore(
            suiteName: fixture.defaultsName)
        let write = writeStore.write(
            true,
            for: AccountPreferenceCatalog.waitlistJoined,
            as: preferenceBinding)
        XCTAssertNotEqual(write.status, .saved)
        XCTAssertNil(fixture.defaults.object(
            forKey: "\(binding.scope)."
                + AccountPreferenceCatalog.waitlistJoined.canonicalKey))
        XCTAssertNil(
            CaptureAccountScope.binding(forExplicitRoot:
                fixture.root.appendingPathComponent("explicit")))
        XCTAssertNotEqual(
            CaptureWidgetSnapshotStore.activeOwnerForTests,
            binding.scope)
    }

    private func assertEveryCachedAdmissionIsBlocked(
        _ binding: CaptureAccountScope.AccountBinding,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(CaptureAccountScope.isCurrent(binding), file: file, line: line)
        XCTAssertNil(CaptureAccountScope.perform(as: binding) { _ in true },
                     file: file, line: line)
        XCTAssertNil(CaptureAccountScope.currentScopedPreferences(),
                     file: file, line: line)
        XCTAssertNil(CaptureAccountScope.currentScopedPreferenceBinding(),
                     file: file, line: line)
        XCTAssertNil(CaptureAccountScope.currentAccountBinding(),
                     file: file, line: line)
        XCTAssertTrue(CaptureAccountScope.currentRoot().path.contains(
            "account-scope-unavailable"), file: file, line: line)
        XCTAssertFalse(FoundryAuth.hasPersistedSignIn, file: file, line: line)
    }

    func testStoreRejectsPendingReplacementRegressionsAndCompletedMutation()
        throws
    {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanup() }
        fixture.io.readResult = .mirrorLastWrite
        let pending = try fixture.store.createPending(ownerScope: scopeB)
        let closed = try fixture.store.compareAndSwap(
            ownerScope: scopeB,
            expectedEpoch: pending.deletionEpoch
        ) {
            $0.exposureBarrier = .closed
            $0.blockedGeneration = 8
        }
        XCTAssertThrowsError(try fixture.store.compareAndSwap(
            ownerScope: scopeB,
            expectedEpoch: closed.deletionEpoch
        ) {
            $0.exposureBarrier = .pending
            $0.blockedGeneration = nil
        })
        XCTAssertThrowsError(try fixture.store.compareAndSwap(
            ownerScope: scopeB,
            expectedEpoch: closed.deletionEpoch
        ) {
            $0.completedGroups = [.pairingPreferences]
        })
        var completed = closed
        for group in AccountDeletionCleanupGroup.allCases {
            completed = try fixture.store.compareAndSwap(
                ownerScope: scopeB,
                expectedEpoch: closed.deletionEpoch
            ) {
                $0.completedGroups.append(group)
                if group == .legacyInputs {
                    $0.legacyDisposition = .notOwned
                }
            }
        }
        completed = try fixture.store.compareAndSwap(
            ownerScope: scopeB,
            expectedEpoch: closed.deletionEpoch
        ) { $0.phase = .completed }
        XCTAssertThrowsError(try fixture.store.compareAndSwap(
            ownerScope: scopeB,
            expectedEpoch: completed.deletionEpoch
        ) {
            $0.blockedGeneration = 9
        })
    }

    func testActivationRechecksCompletedDeletionBeforeLegacyClaim() throws {
        let fixture = try DeletionScopeFixture()
        defer { fixture.cleanup() }
        let identity = fixture.identity(subject: "owner-b")
        let scope = try CaptureAccountScope.key(for: identity)
        let transaction = try CaptureAccountScope.beginActivationForTestsOnly(
            for: identity)
        let store = AccountDeletionLifecycleStore(container: fixture.root)
        let pending = try store.createPending(ownerScope: scope)
        _ = try completeDeletionRecord(
            store: store, pending: pending,
            blockedGeneration: 1, disposition: .retired)
        try Data(scope.utf8).write(
            to: fixture.root.appendingPathComponent(".migrated-to"))
        fixture.defaults.set(
            "https://legacy.example.test",
            forKey: "foundryx.cell.url")
        fixture.defaults.set(
            "idToken",
            forKey: "foundryx.cell.authMode")

        try CaptureAccountScope.completeActivationForTestsOnly(transaction)

        XCTAssertNil(fixture.defaults.object(
            forKey: "\(scope).foundryx.cell.url"))
        XCTAssertNil(fixture.defaults.object(
            forKey: "\(scope).foundryx.cell.authMode"))
        XCTAssertEqual(
            fixture.defaults.string(forKey: "foundryx.cell.url"),
            "https://legacy.example.test")
    }

    func testDeletionCheckpointWinsPausedActivationMigration() async throws {
        let fixture = try DeletionScopeFixture()
        defer { fixture.cleanup() }
        let identity = fixture.identity(subject: "owner-b")
        let activationTransaction = try CaptureAccountScope.beginActivationForTestsOnly(
            for: identity)
        let scope = activationTransaction.scope

        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        CaptureAccountScope.setActivationMigrationPauseHookForTests {
            entered.signal()
            resume.wait()
        }
        defer {
            resume.signal()
            CaptureAccountScope.setActivationMigrationPauseHookForTests(nil)
        }

        let activation = Task {
            try CaptureAccountScope.completeActivationForTestsOnly(
                activationTransaction)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

        let store = AccountDeletionLifecycleStore(
            container: fixture.root)
        let creationFinished = DeletionCompletionFlag()
        let lockAttempted = DispatchSemaphore(value: 0)
        AccountDeletionLifecycleStore
            .setBeforeOwnerLockAttemptHookForTests { attemptedScope in
                if attemptedScope == scope { lockAttempted.signal() }
            }
        defer {
            AccountDeletionLifecycleStore
                .setBeforeOwnerLockAttemptHookForTests(nil)
        }
        let pendingCreation = Task {
            defer { creationFinished.markFinished() }
            return try store.createPending(ownerScope: scope)
        }
        XCTAssertEqual(
            lockAttempted.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(
            creationFinished.isFinished,
            "pending creation must wait for activation owner admission")

        resume.signal()
        try await activation.value
        _ = try await pendingCreation.value
        let deletedRoot = fixture.root.appendingPathComponent(
            scope, isDirectory: true)
        let lifecycle = AccountDeletionLifecycle.live(
            container: fixture.root,
            defaults: fixture.defaults,
            secretStore: DeletionTypedSecretStore(),
            pairingServices: (cell: "cell.test", door: "door.test"),
            exposureCoordinator: AccountExposureCoordinator(),
            verifiedIdentityForScope: { _ in identity },
            legacyEnumerationObserver: { _ in })
        let completed = try await lifecycle.recover(ownerScope: scope)

        XCTAssertEqual(completed.phase, .completed)
        XCTAssertTrue(completed.completedGroups.contains(.localRoot))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: deletedRoot.path))
        XCTAssertNil(CaptureAccountScope.currentAccountBinding())
    }

    func testDurabilityAndFaultRegistriesAreExactLiteralContracts() {
        XCTAssertEqual(
            DeletionDurabilityOperation.allCases,
            [
                .readCurrent,
                .createUniqueTempSameDirectory0600,
                .writeAll,
                .fsyncFile,
                .closeFile,
                .renamePOSIX,
                .fsyncParent,
                .closeParent,
                .typedReadback,
            ])
        let stages: [DeletionFaultStage] = [
            .pendingSync,
            .pendingReadback,
            .resolutionGeneration,
            .signedInMirror,
            .widgetWithdrawal,
            .liveExposureClosure,
            .staleWorkCancellation,
            .barrierVerification,
            .barrierSync,
            .barrierReadback,
            .trackBPreferences,
            .pairingPreferences,
            .pairingSecrets,
            .localRoot,
            .legacyInputs,
            .accountSurfaces,
            .completedSync,
            .completedReadback,
        ]
        XCTAssertEqual(DeletionFaultStage.requiredV1, stages)
        XCTAssertEqual(
            DeletionFaultBoundary.allCases,
            [.before, .after])
        XCTAssertEqual(
            DeletionFaultPoint.requiredV1,
            stages.flatMap { stage in
                [
                    DeletionFaultPoint(.before, stage),
                    DeletionFaultPoint(.after, stage),
                ]
            })
    }

    func testWriteAllRetriesEINTRAndPerOwnerCASIsSerialized()
        async throws
    {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanup() }
        fixture.io.readResult = .mirrorLastWrite
        fixture.io.writeScript = [.interrupted, .writeRemaining]
        let pending = try fixture.store.createPending(ownerScope: scopeB)
        XCTAssertEqual(fixture.io.writeAttempts, 2)
        XCTAssertTrue(fixture.io.writeScript.isEmpty)
        _ = try fixture.store.compareAndSwap(
            ownerScope: scopeB,
            expectedEpoch: pending.deletionEpoch
        ) {
            $0.exposureBarrier = .closed
            $0.blockedGeneration = 0
        }
        let ownerScope = scopeB

        let results = await withTaskGroup(
            of: Error?.self,
            returning: [Error?].self
        ) { group in
            for _ in 0..<16 {
                group.addTask {
                    do {
                        _ = try fixture.store.compareAndSwap(
                            ownerScope: ownerScope,
                            expectedEpoch: pending.deletionEpoch
                        ) {
                            $0.blockedGeneration =
                                ($0.blockedGeneration ?? 0) + 1
                        }
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var values: [Error?] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertTrue(results.allSatisfy { $0 == nil })
        XCTAssertEqual(
            fixture.store.read(ownerScope: scopeB).record?.blockedGeneration,
            16)
    }

    func testReopenedStoresUseDurableEpochPhaseAndCASTruth()
        async throws
    {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanup() }
        fixture.io.readResult = .mirrorLastWrite
        let firstStore = fixture.store
        let pending = try firstStore.createPending(ownerScope: scopeB)
        let completed = try completeDeletionRecord(
            store: firstStore, pending: pending,
            blockedGeneration: 99, disposition: .notOwned)

        let reopened = AccountDeletionLifecycleStore(
            container: fixture.root,
            fileIO: fixture.io)
        XCTAssertEqual(
            reopened.read(ownerScope: scopeB),
            .record(completed))
        let next = try reopened.createPending(ownerScope: scopeB)
        XCTAssertEqual(next.deletionEpoch, completed.deletionEpoch + 1)

        XCTAssertThrowsError(try firstStore.compareAndSwap(
            ownerScope: scopeB,
            expectedEpoch: completed.deletionEpoch
        ) { $0.phase = .completed }) {
            XCTAssertEqual(
                $0 as? AccountDeletionLifecycleError,
                .staleEpoch(
                    expected: completed.deletionEpoch,
                    actual: next.deletionEpoch))
        }
    }

    func testTwoStoresSerializeSameOwnerEpochAgainstSharedDurableState()
        async throws
    {
        let fixture = try DeletionStoreFixture()
        defer { fixture.cleanup() }
        fixture.io.readResult = .mirrorLastWrite
        let other = AccountDeletionLifecycleStore(
            container: fixture.root,
            fileIO: fixture.io)
        let ownerScope = scopeB

        let epochs = await withTaskGroup(
            of: UInt64?.self,
            returning: [UInt64].self
        ) { group in
            for store in [fixture.store, other] {
                group.addTask {
                    try? store.createPending(
                        ownerScope: ownerScope).deletionEpoch
                }
            }
            var values: [UInt64] = []
            for await epoch in group {
                if let epoch { values.append(epoch) }
            }
            return values.sorted()
        }
        XCTAssertEqual(epochs, [1, 1])
        XCTAssertEqual(
            other.read(ownerScope: scopeB).record?.deletionEpoch,
            1)
    }

    func testDurabilityFailureNeverAuthorizesCleanup() async throws {
        for failedOperation in DeletionDurabilityOperation.allCases {
            let fixture = try DeletionLifecycleFixture()
            defer { fixture.cleanup() }
            fixture.io.failOperation = failedOperation

            await XCTAssertThrowsErrorAsync {
                try await fixture.lifecycle.begin(binding: fixture.bindingB)
            }
            XCTAssertTrue(fixture.cleanedGroups.isEmpty)
            XCTAssertFalse(fixture.publishedActiveScopes.contains(scopeB))
        }
    }

    func testExactBarrierThenCleanupOrderAndReadbacks() async throws {
        let fixture = try DeletionLifecycleFixture()
        defer { fixture.cleanup() }

        let completed = try await fixture.lifecycle.begin(
            binding: fixture.bindingB)

        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.exposureBarrier, .closed)
        XCTAssertEqual(
            completed.completedGroups,
            AccountDeletionCleanupGroup.allCases)
        XCTAssertEqual(
            fixture.events,
            [
                .pendingDurableReadback,
                .resolutionBlocked,
                .signedInMirrorFalse,
                .widgetWithdrawn,
                .liveExposuresClosed,
                .staleWorkCancelled,
                .barrierVerified,
                .barrierClosedDurableReadback,
                .cleanup(.trackBPreferences),
                .cleanup(.pairingPreferences),
                .cleanup(.pairingSecrets),
                .cleanup(.localRoot),
                .cleanup(.legacyInputs),
                .cleanup(.accountSurfaces),
                .completedDurableReadback,
            ])
    }

    func testEveryCrashPointBlocksAndRecoveryReassertsAllGates() async throws {
        for point in DeletionFaultPoint.requiredV1 {
            let fixture = try DeletionLifecycleFixture(failingAt: point)
            defer { fixture.cleanup() }
            await XCTAssertThrowsErrorAsync {
                try await fixture.lifecycle.begin(binding: fixture.bindingB)
            }
            XCTAssertFalse(fixture.publishedActiveScopes.contains(scopeB))
            XCTAssertTrue(
                fixture.cleanedGroups.isEmpty
                    || fixture.didDurablyCloseBarrierBeforeFirstCleanup)

            fixture.faultInjector.failingPoint = nil
            fixture.events = []
            let recovered: AccountDeletionLifecycleRecord
            let prior = fixture.store.read(ownerScope: scopeB)
            switch prior {
            case .missing:
                recovered = try await fixture.lifecycle.begin(
                    binding: fixture.bindingB)
            case .record(let record) where record.phase == .completed:
                recovered = try await fixture.lifecycle.recover(
                    ownerScope: scopeB)
                XCTAssertTrue(
                    fixture.events.isEmpty,
                    "completed recovery must not re-delete post-return state")
            case .record:
                recovered = try await fixture.lifecycle.recover(
                    ownerScope: scopeB)
                XCTAssertEqual(
                    Array(fixture.events.prefix(6)),
                    [
                        .resolutionBlocked,
                        .signedInMirrorFalse,
                        .widgetWithdrawn,
                        .liveExposuresClosed,
                        .staleWorkCancelled,
                        .barrierVerified,
                    ],
                    "pending recovery must reassert gates even for a recorded closed barrier")
            case .blocked(let reason):
                XCTFail("test fixture record unexpectedly unreadable: \(reason)")
                continue
            }
            XCTAssertEqual(recovered.phase, .completed)
        }
    }

    func testEveryNonSuccessExposureAcknowledgementBlocksAllGroups()
        async throws
    {
        let failures: [AccountExposureCloseResult] = [
            .ownerMismatch,
            .verificationFailed,
            .unavailable,
            .persistenceFailed,
        ]
        for result in failures {
            let fixture = try DeletionLifecycleFixture()
            defer { fixture.cleanup() }
            fixture.liveAcknowledgement = result

            await XCTAssertThrowsErrorAsync {
                try await fixture.lifecycle.begin(binding: fixture.bindingB)
            }
            XCTAssertTrue(fixture.cleanedGroups.isEmpty)
            XCTAssertEqual(
                fixture.store.read(ownerScope: scopeB).record?.phase,
                .cleanupPending)
            XCTAssertFalse(fixture.publishedActiveScopes.contains(scopeB))
        }
    }

    func testRealExposureCoordinatorCountsEveryLiveAndStaleRegistration()
        async throws
    {
        let fixture = try DeletionLifecycleFixture()
        defer { fixture.cleanup() }

        _ = try await fixture.lifecycle.begin(binding: fixture.bindingB)

        XCTAssertEqual(
            fixture.lastLiveAcknowledgements.map(\.participantID),
            ["live-a", "live-b"])
        XCTAssertEqual(
            fixture.lastStaleAcknowledgements.map(\.participantID),
            ["stale-a", "stale-b"])
        XCTAssertTrue(
            (fixture.lastLiveAcknowledgements
                + fixture.lastStaleAcknowledgements)
                .allSatisfy { $0.result == .closed })
    }

    func testEveryStaleFailureAndUnavailableBindingBlocksGroupOne()
        async throws
    {
        for result in [
            AccountExposureCloseResult.ownerMismatch,
            .verificationFailed,
            .unavailable,
            .persistenceFailed,
        ] {
            let fixture = try DeletionLifecycleFixture()
            defer { fixture.cleanup() }
            fixture.staleAcknowledgement = result
            await XCTAssertThrowsErrorAsync {
                try await fixture.lifecycle.begin(binding: fixture.bindingB)
            }
            XCTAssertTrue(fixture.cleanedGroups.isEmpty)
        }

        for kind in [
            AccountExposureRegistration.Kind.live,
            .staleWork,
        ] {
            let fixture = try DeletionLifecycleFixture()
            defer { fixture.cleanup() }
            fixture.installUnavailableRegistration(kind: kind)
            await XCTAssertThrowsErrorAsync {
                try await fixture.lifecycle.begin(binding: fixture.bindingB)
            }
            XCTAssertTrue(fixture.cleanedGroups.isEmpty)
            let all = fixture.lastLiveAcknowledgements
                + fixture.lastStaleAcknowledgements
            XCTAssertEqual(
                all.filter { $0.participantID == "missing-\(kind)" }.count,
                1)
            XCTAssertTrue(all.contains {
                $0.participantID == "missing-\(kind)"
                    && $0.result == .unavailable
            })
        }
    }

    func testCapturedBindingScopeGenerationAndRootDriveEveryCleanup()
        async throws
    {
        let fixture = try DeletionLifecycleFixture()
        defer { fixture.cleanup() }
        fixture.currentBinding = fixture.bindingB
        fixture.afterPendingCapture = {
            fixture.currentBinding = fixture.bindingA
        }

        _ = try await fixture.lifecycle.begin(binding: fixture.bindingB)

        XCTAssertTrue(fixture.cleanupBindings.allSatisfy {
            $0.scope == fixture.bindingB.scope
                && $0.generation == fixture.bindingB.generation
                && $0.root == fixture.bindingB.root
        })
        XCTAssertFalse(fixture.cleanupBindings.contains(fixture.bindingA))
    }

    func testBeginRejectsAnAlreadyStaleBindingBeforePendingOrCleanup()
        async throws
    {
        let fixture = try DeletionLifecycleFixture()
        defer { fixture.cleanup() }
        fixture.currentBinding = fixture.bindingA

        await XCTAssertThrowsErrorAsync {
            try await fixture.lifecycle.begin(binding: fixture.bindingB)
        }

        XCTAssertEqual(
            fixture.store.read(ownerScope: fixture.bindingB.scope),
            .missing)
        XCTAssertTrue(fixture.cleanedGroups.isEmpty)
    }

    func testStalePublicationAndWidgetTOCTOUCannotRepublishDeletedOwner()
        async throws
    {
        let scopeFixture = try DeletionScopeFixture()
        defer { scopeFixture.cleanup() }
        let bindingB = try scopeFixture.activate(subject: "owner-b")
        var transitionError: Error?
        CaptureAccountScope.setBeforeAccountBindingPublicationHookForTests {
            do {
                _ = try scopeFixture.activate(subject: "owner-c")
            } catch {
                transitionError = error
            }
        }
        defer {
            CaptureAccountScope
                .setBeforeAccountBindingPublicationHookForTests(nil)
        }

        XCTAssertNil(CaptureAccountScope.currentAccountBinding())
        XCTAssertNil(transitionError)
        let bindingC = try XCTUnwrap(
            CaptureAccountScope.currentAccountBinding())
        XCTAssertNotEqual(bindingB.scope, bindingC.scope)
        XCTAssertEqual(
            CaptureWidgetSnapshotStore.activeOwnerForTests,
            bindingC.scope)

        let fixture = try DeletionLifecycleFixture()
        defer { fixture.cleanup() }
        fixture.currentBinding = fixture.bindingC
        let staleWriteAccepted = fixture.publish(
            scope: scopeB,
            generation: fixture.bindingB.generation,
            root: fixture.bindingB.root)
        XCTAssertFalse(staleWriteAccepted)
    }

    func testDeletionEntryRejectsPreferenceMutationReentryWithoutDeadlock()
        throws
    {
        let scopeFixture = try DeletionScopeFixture()
        defer { scopeFixture.cleanup() }
        let binding = try scopeFixture.activate(subject: "owner-b")
        let deletion = try DeletionLifecycleFixture()
        defer { deletion.cleanup() }
        var observedError: AccountDeletionLifecycleError?

        let entered = CaptureAccountScope.perform(as: binding) { captured in
            do {
                try deletion.lifecycle.preflightBegin(binding: captured)
            } catch let error as AccountDeletionLifecycleError {
                observedError = error
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertNotNil(entered)
        XCTAssertEqual(observedError, .preferenceMutationInProgress)
        XCTAssertEqual(
            deletion.store.read(ownerScope: binding.scope),
            .missing)
    }

    func testDeletionBoundaryObserverIsDeliveredAfterLocksAndCanReenter()
        async throws
    {
        let fixture = try DeletionLifecycleFixture()
        defer { fixture.cleanup() }
        fixture.assertLocksReleasedInsideEveryHook = true
        fixture.reenterLifecycleFromEveryHook = true

        _ = try await fixture.lifecycle.begin(binding: fixture.bindingB)

        XCTAssertEqual(fixture.identityBoundaryDeliveries, 1)
        XCTAssertTrue(fixture.everyHookObservedLocksReleased)
    }

    func testRealScopePendingRecordBlocksEveryRestoreAndPublication()
        throws
    {
        let fixture = try DeletionScopeFixture()
        defer { fixture.cleanup() }
        let identity = fixture.identity(subject: "owner-b")
        let scope = try CaptureAccountScope.key(for: identity)
        let store = AccountDeletionLifecycleStore(container: fixture.root)
        _ = try store.createPending(ownerScope: scope)
        fixture.defaults.set(
            "legacy-value",
            forKey: AccountPreferenceCatalog.onboardingPersona.canonicalKey)

        CaptureAccountScope.resetProcessCacheForTests()
        XCTAssertThrowsError(
            try CaptureAccountScope.activateForTests(identity))
        XCTAssertNil(CaptureAccountScope.currentScopedPreferences())
        XCTAssertNil(CaptureAccountScope.currentAccountBinding())
        XCTAssertTrue(
            CaptureAccountScope.currentRoot().path.contains(
                "account-scope-unavailable"))
        XCTAssertNil(CaptureWidgetSnapshotStore.activeOwnerForTests)
        XCTAssertNil(fixture.defaults.object(
            forKey:
                "\(scope).\(AccountPreferenceCatalog.onboardingPersona.canonicalKey)"))
    }

    func testRealScopeCorruptUnsupportedUnreadableAndProtectedStayBlocked()
        throws
    {
        for failure in [
            RealScopeRecordFailure.corrupt,
            .unsupportedVersion,
            .unreadable,
            .protectedDataUnavailable,
            .failed,
        ] {
            let fixture = try DeletionScopeFixture()
            let identity = fixture.identity(subject: "owner-b")
            let scope = try CaptureAccountScope.key(for: identity)
            defer {
                AccountDeletionLifecycleStore
                    .setReadFailureForTests(nil, ownerScope: scope)
                fixture.cleanup()
            }
            let store = AccountDeletionLifecycleStore(
                container: fixture.root)
            switch failure {
            case .corrupt:
                let url = try store.recordURL(ownerScope: scope)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try Data("{broken".utf8).write(to: url)
            case .unsupportedVersion:
                let url = try store.recordURL(ownerScope: scope)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try Data(#"{"version":2}"#.utf8).write(to: url)
            case .unreadable, .protectedDataUnavailable, .failed:
                AccountDeletionLifecycleStore.setReadFailureForTests(
                    failure.injectedFailure, ownerScope: scope)
            }

            CaptureAccountScope.resetProcessCacheForTests()
            XCTAssertThrowsError(
                try CaptureAccountScope.activateForTests(identity))
            XCTAssertNil(CaptureAccountScope.currentScopedPreferences())
            XCTAssertNil(CaptureAccountScope.currentAccountBinding())
            XCTAssertNil(CaptureWidgetSnapshotStore.activeOwnerForTests)
        }
    }

    func testRealCompletedRecordAllowsFreshActivationButSuppressesAdoption()
        throws
    {
        let fixture = try DeletionScopeFixture()
        defer { fixture.cleanup() }
        let identity = fixture.identity(subject: "owner-b")
        let scope = try CaptureAccountScope.key(for: identity)
        let store = AccountDeletionLifecycleStore(container: fixture.root)
        let pending = try store.createPending(ownerScope: scope)
        _ = try completeDeletionRecord(
            store: store, pending: pending,
            blockedGeneration: 44, disposition: .retired)
        try Data(scope.utf8).write(
            to: fixture.root.appendingPathComponent(".migrated-to"))
        let cellURLKey = "foundryx.cell.url"
        let cellAuthModeKey = "foundryx.cell.authMode"
        fixture.defaults.set(
            "https://legacy-cell.example.test",
            forKey: cellURLKey)
        fixture.defaults.set("idToken", forKey: cellAuthModeKey)
        let legacyKey =
            AccountPreferenceCatalog.onboardingPersona.canonicalKey
        fixture.defaults.set("must-not-return", forKey: legacyKey)

        try CaptureAccountScope.activateForTests(identity)
        let fresh = try XCTUnwrap(
            CaptureAccountScope.currentAccountBinding())
        XCTAssertEqual(fresh.scope, scope)
        XCTAssertEqual(
            fixture.defaults.string(forKey: cellURLKey),
            "https://legacy-cell.example.test")
        XCTAssertEqual(
            fixture.defaults.string(forKey: cellAuthModeKey),
            "idToken")
        XCTAssertNil(fixture.defaults.object(
            forKey: "\(scope).\(cellURLKey)"))
        XCTAssertNil(fixture.defaults.object(
            forKey: "\(scope).\(cellAuthModeKey)"))
        XCTAssertNil(fixture.defaults.object(
            forKey: "\(scope).\(legacyKey)"))
        XCTAssertEqual(fixture.defaults.string(forKey: legacyKey),
                       "must-not-return")
        let stale = CaptureAccountScope.AccountBinding(
            root: fresh.root,
            scope: fresh.scope,
            generation: fresh.generation - 1)
        XCTAssertNil(CaptureAccountScope.perform(as: stale) { _ in true })
    }

    func testHooksAndAwaitedActionsRunWithoutLifecycleOrStateLocks()
        async throws
    {
        let fixture = try DeletionLifecycleFixture()
        defer { fixture.cleanup() }
        fixture.assertLocksReleasedInsideEveryHook = true
        fixture.reenterLifecycleFromEveryHook = true
        fixture.requireNoMainSync = true

        _ = try await fixture.lifecycle.begin(binding: fixture.bindingB)

        XCTAssertTrue(fixture.everyHookObservedLocksReleased)
        XCTAssertFalse(fixture.mainSyncAttempted)
    }

    func testCleanupIsIdempotentAndPreservesOtherOwnersAndPhoneState()
        async throws
    {
        let fixture = try DeletionLifecycleFixture()
        defer { fixture.cleanup() }
        let controls = fixture.seedPreservationControls(
            accountA: scopeA,
            accountB: scopeB)

        _ = try await fixture.lifecycle.begin(binding: fixture.bindingB)
        _ = try await fixture.lifecycle.recover(ownerScope: scopeB)

        XCTAssertEqual(fixture.preservationControls, controls)
        XCTAssertEqual(
            fixture.cleanedGroups,
            AccountDeletionCleanupGroup.allCases,
            "recovering completed must not rerun cleanup over fresh state")
        XCTAssertTrue(fixture.metadataDirectoryExists)
        XCTAssertFalse(fixture.metadataWasEnumeratedAsLegacyInput)
    }

    func testPendingRecoveryVerifiesRecordedGroupsAndRunsOnlyIncompleteOnes()
        async throws
    {
        let point = DeletionFaultPoint(.after, .pairingPreferences)
        let fixture = try DeletionLifecycleFixture(failingAt: point)
        defer { fixture.cleanup() }
        await XCTAssertThrowsErrorAsync {
            try await fixture.lifecycle.begin(binding: fixture.bindingB)
        }
        XCTAssertEqual(
            fixture.cleanedGroups,
            [.trackBPreferences, .pairingPreferences])

        fixture.faultInjector.failingPoint = nil
        fixture.cleanedGroups.removeAll()
        fixture.verifiedGroups.removeAll()
        _ = try await fixture.lifecycle.recover(ownerScope: scopeB)

        XCTAssertEqual(
            fixture.verifiedGroups.prefix(2),
            [.trackBPreferences, .pairingPreferences])
        XCTAssertEqual(
            fixture.cleanedGroups,
            [.pairingSecrets, .localRoot, .legacyInputs, .accountSurfaces])
    }

    func testLegacyInputsRequireOwnerProofAndMarkerIsPreserved()
        async throws
    {
        for proof in [nil, scopeA] {
            let fixture = try DeletionLifecycleFixture()
            defer { fixture.cleanup() }
            fixture.legacyOwnerProof = proof
            let legacyBytes = fixture.seedLegacyInputs()
            let record = try await fixture.lifecycle.begin(
                binding: fixture.bindingB)
            XCTAssertEqual(record.legacyDisposition, .notOwned)
            XCTAssertEqual(fixture.legacyBytes, legacyBytes)
        }

        let owned = try DeletionLifecycleFixture()
        defer { owned.cleanup() }
        owned.legacyOwnerProof = scopeB
        _ = owned.seedLegacyInputs()
        let record = try await owned.lifecycle.begin(binding: owned.bindingB)
        XCTAssertEqual(record.legacyDisposition, .retired)
        XCTAssertTrue(owned.legacyInputsAreAbsent)
        XCTAssertEqual(owned.legacyOwnerProof, scopeB)
    }

    func testLiveSelectiveCleanupErasesOnlyCapturedBAndPreservesControls()
        async throws
    {
        let fixture = try SelectiveDeletionIntegrationFixture(
            legacyProof: .ownedByB)
        defer { fixture.cleanup() }
        let controls = fixture.snapshotPreservedControls()
        let capturedBindingB = fixture.bindingB
        let mutationProbe =
            AccountPreferenceCatalog.onboardingPersona.canonicalKey

        let record = try await fixture.lifecycle.begin(
            binding: capturedBindingB)

        XCTAssertEqual(record.phase, .completed)
        XCTAssertEqual(
            record.completedGroups,
            [
                .trackBPreferences,
                .pairingPreferences,
                .pairingSecrets,
                .localRoot,
                .legacyInputs,
                .accountSurfaces,
            ])
        XCTAssertTrue(fixture.allScopedBInputsAreAbsent)
        XCTAssertTrue(fixture.allProvedLegacyInputsAreAbsent)
        XCTAssertEqual(fixture.snapshotPreservedControls(), controls)
        XCTAssertTrue(fixture.widgetOwnerAndPayloadAreAbsent)
        XCTAssertTrue(fixture.defaults.synchronize())
        XCTAssertTrue(fixture.signedInMirrorIsDurablyFalse)
        XCTAssertFalse(FoundryAuth.hasPersistedSignIn)
        XCTAssertNil(CaptureAccountScope.currentAccountBinding())
        XCTAssertNil(CaptureAccountScope.currentScopedPreferences())
        XCTAssertNil(CaptureAccountScope.perform(
            as: capturedBindingB
        ) { captured in
            fixture.defaults.set(
                "stale-mutation",
                forKey: "\(captured.scope).\(mutationProbe)")
            return true
        })
        XCTAssertNil(fixture.defaults.object(
            forKey: "\(capturedBindingB.scope).\(mutationProbe)"))
        XCTAssertEqual(fixture.readMigrationMarker(), capturedBindingB.scope)
        XCTAssertTrue(fixture.lifecycleMetadataExists)
        XCTAssertFalse(fixture.metadataAppearedInLegacyEnumeration)
        XCTAssertNil(
            fixture.historicalSignupMarkerObject,
            "retirement must use sealed verified identity + owner + tombstone proofs")

        try CaptureAccountScope.activateForTests(
            fixture.identityB,
            activatePreferences: true)
        let freshBindingB = try XCTUnwrap(
            CaptureAccountScope.currentAccountBinding())
        XCTAssertTrue(fixture.defaults.synchronize())
        XCTAssertNotNil(fixture.defaults.object(
            forKey: "foundryx.auth.signed-in"))
        XCTAssertTrue(fixture.defaults.bool(
            forKey: "foundryx.auth.signed-in"))
        XCTAssertEqual(
            CaptureWidgetSnapshotStore.activeOwnerForTests,
            freshBindingB.scope)
        XCTAssertEqual(
            CaptureAccountScope.currentScopedPreferences()?.scope,
            freshBindingB.scope)
        XCTAssertTrue(FoundryAuth.hasPersistedSignIn)
        XCTAssertEqual(freshBindingB.scope, capturedBindingB.scope)
        XCTAssertGreaterThan(
            freshBindingB.generation,
            capturedBindingB.generation)
        XCTAssertNil(CaptureAccountScope.perform(
            as: capturedBindingB
        ) { _ in true })
        XCTAssertEqual(
            CaptureAccountScope.perform(as: freshBindingB) { captured in
                fixture.defaults.set(
                    "fresh-mutation",
                    forKey: "\(captured.scope).\(mutationProbe)")
                return true
            },
            true)
        try fixture.seedFreshBState(as: freshBindingB)
        XCTAssertTrue(fixture.freshBStateExists(as: freshBindingB))
        let controlsBeforeSecondDeletion =
            fixture.snapshotPreservedControls()

        let later = try await fixture.lifecycle.begin(
            binding: freshBindingB)

        XCTAssertEqual(later.phase, .completed)
        XCTAssertGreaterThan(later.deletionEpoch, record.deletionEpoch)
        XCTAssertTrue(fixture.allScopedBInputsAreAbsent)
        XCTAssertEqual(
            fixture.snapshotPreservedControls(),
            controlsBeforeSecondDeletion)
        XCTAssertTrue(fixture.defaults.synchronize())
        XCTAssertTrue(fixture.signedInMirrorIsDurablyFalse)
        XCTAssertFalse(FoundryAuth.hasPersistedSignIn)
        XCTAssertTrue(fixture.widgetOwnerAndPayloadAreAbsent)
        XCTAssertNil(CaptureAccountScope.currentAccountBinding())
        XCTAssertNil(CaptureAccountScope.currentScopedPreferences())
        XCTAssertNil(CaptureAccountScope.perform(
            as: capturedBindingB
        ) { _ in true })
    }

    func testCurrentOwnerRunnerUsesVerifiedBindingAndSelectiveLifecycle()
        async throws
    {
        let fixture = try SelectiveDeletionIntegrationFixture(
            legacyProof: .ownedByB)
        defer { fixture.cleanup() }
        let controls = fixture.snapshotPreservedControls()
        let runner = CurrentOwnerSelectiveDeletionRunner(
            container: fixture.root,
            defaults: fixture.defaults,
            secretStore: fixture.secrets,
            pairingServices: (
                cell: fixture.cellService,
                door: fixture.doorService),
            exposureCoordinator: fixture.exposureCoordinator,
            identityProvider: { fixture.identityB })

        try await runner.eraseVerifiedCurrentOwner()

        XCTAssertTrue(fixture.allScopedBInputsAreAbsent)
        XCTAssertTrue(fixture.allProvedLegacyInputsAreAbsent)
        XCTAssertEqual(fixture.snapshotPreservedControls(), controls)
        XCTAssertEqual(
            fixture.lifecycle.record(ownerScope: fixture.bindingB.scope)
                .record?.phase,
            .completed)
    }

    func testCurrentOwnerRunnerProvesIdentityBeforeTouchingContainer()
        async
    {
        let containerWasTouched = DeletionCompletionFlag()
        let runner = CurrentOwnerSelectiveDeletionRunner(
            containerProvider: {
                containerWasTouched.markFinished()
                return FileManager.default.temporaryDirectory
            },
            defaults: .standard,
            secretStore: DeletionTypedSecretStore(),
            pairingServices: (cell: "cell.test", door: "door.test"),
            exposureCoordinator: AccountExposureCoordinator(),
            identityProvider: { nil })

        await XCTAssertThrowsErrorAsync {
            try await runner.eraseVerifiedCurrentOwner()
        }

        XCTAssertFalse(containerWasTouched.isFinished)
    }

    func testCurrentOwnerRunnerNeverErasesForMismatchedIdentity()
        async throws
    {
        let fixture = try SelectiveDeletionIntegrationFixture(
            legacyProof: .ownedByB)
        defer { fixture.cleanup() }
        let controls = fixture.snapshotPreservedControls()
        let runner = CurrentOwnerSelectiveDeletionRunner(
            container: fixture.root,
            defaults: fixture.defaults,
            secretStore: fixture.secrets,
            pairingServices: (
                cell: fixture.cellService,
                door: fixture.doorService),
            exposureCoordinator: fixture.exposureCoordinator,
            identityProvider: { fixture.identityA })

        await XCTAssertThrowsErrorAsync {
            try await runner.eraseVerifiedCurrentOwner()
        }

        XCTAssertTrue(fixture.allScopedBInputsRemainPresent)
        XCTAssertEqual(fixture.snapshotPreservedControls(), controls)
        XCTAssertEqual(
            fixture.lifecycle.record(ownerScope: fixture.bindingB.scope),
            .missing)
    }

    func testCurrentOwnerRunnerRecoversPendingWithoutRepublishingOwner()
        async throws
    {
        let fixture = try SelectiveDeletionIntegrationFixture(
            legacyProof: .ownedByB,
            failingAt: .init(.before, .pairingSecrets))
        defer { fixture.cleanup() }
        let controls = fixture.snapshotPreservedControls()
        await XCTAssertThrowsErrorAsync {
            try await fixture.lifecycle.begin(binding: fixture.bindingB)
        }
        fixture.allowRecovery()
        let runner = CurrentOwnerSelectiveDeletionRunner(
            container: fixture.root,
            defaults: fixture.defaults,
            secretStore: fixture.secrets,
            pairingServices: (
                cell: fixture.cellService,
                door: fixture.doorService),
            exposureCoordinator: fixture.exposureCoordinator,
            identityProvider: { fixture.identityB })

        try await runner.eraseVerifiedCurrentOwner()

        XCTAssertNil(CaptureAccountScope.currentAccountBinding())
        XCTAssertNil(CaptureAccountScope.currentScopedPreferences())
        XCTAssertTrue(fixture.allScopedBInputsAreAbsent)
        XCTAssertEqual(fixture.snapshotPreservedControls(), controls)
    }

    func testLiveLegacyCleanupPreservesInputsWithoutExactOwnerProof()
        async throws
    {
        for proof in [
            SelectiveDeletionIntegrationFixture.LegacyProof.absent,
            .ownedByA,
        ] {
            let fixture = try SelectiveDeletionIntegrationFixture(
                legacyProof: proof)
            defer { fixture.cleanup() }
            let legacy = fixture.snapshotLegacyInputs()

            let record = try await fixture.lifecycle.begin(
                binding: fixture.bindingB)

            XCTAssertEqual(record.legacyDisposition, .notOwned)
            XCTAssertEqual(fixture.snapshotLegacyInputs(), legacy)
            XCTAssertNotNil(fixture.historicalSignupMarkerObject)
            XCTAssertTrue(fixture.signedInMirrorIsDurablyFalse)
            XCTAssertNil(CaptureAccountScope.currentAccountBinding())
            XCTAssertNil(CaptureAccountScope.currentScopedPreferences())
            XCTAssertEqual(
                fixture.readMigrationMarker(),
                proof == .ownedByA ? fixture.scopeA : nil)
        }
    }

    func testLiveWidgetPersistenceFailureBlocksEveryCleanupGroup()
        async throws
    {
        let fixture = try SelectiveDeletionIntegrationFixture(
            legacyProof: .ownedByB)
        defer { fixture.cleanup() }
        CaptureWidgetSnapshotStore.setWithdrawalFaultForTesting(
            .synchronizeFailure)

        await XCTAssertThrowsErrorAsync {
            try await fixture.lifecycle.begin(binding: fixture.bindingB)
        }

        XCTAssertTrue(fixture.allScopedBInputsRemainPresent)
    }

    func testLiveSameLifecycleRecoveryReassertsBarrierAfterCleanupFailure()
        async throws
    {
        let fixture = try SelectiveDeletionIntegrationFixture(
            legacyProof: .ownedByB,
            registerRetryParticipants: true)
        defer { fixture.cleanup() }
        fixture.secrets.forceNextRemoval(.failed)

        await XCTAssertThrowsErrorAsync {
            try await fixture.lifecycle.begin(binding: fixture.bindingB)
        }
        XCTAssertEqual(fixture.liveParticipantCalls, 1)
        XCTAssertEqual(fixture.staleParticipantCalls, 1)
        let firstBlockedGeneration = fixture.lifecycle.record(
            ownerScope: fixture.bindingB.scope).record?.blockedGeneration

        let completed = try await fixture.lifecycle.recover(
            ownerScope: fixture.bindingB.scope)

        XCTAssertEqual(completed.phase, .completed)
        XCTAssertGreaterThan(
            completed.blockedGeneration ?? 0,
            firstBlockedGeneration ?? 0)
        XCTAssertEqual(fixture.liveParticipantCalls, 2)
        XCTAssertEqual(fixture.staleParticipantCalls, 2)
        XCTAssertTrue(fixture.allScopedBInputsAreAbsent)
    }

    func testLiveRetiresCanonicalHistoricalSignupForMixedCaseIdentity()
        async throws
    {
        let fixture = try SelectiveDeletionIntegrationFixture(
            legacyProof: .ownedByB,
            identityEmail: "Owner-B@Example.Test")
        defer { fixture.cleanup() }

        _ = try await fixture.lifecycle.begin(binding: fixture.bindingB)

        XCTAssertNil(fixture.historicalSignupMarkerObject)
    }

    func testCompletedAllowsFreshReturnAndLaterDeletionAdvancesEpoch()
        async throws
    {
        let fixture = try DeletionLifecycleFixture()
        defer { fixture.cleanup() }
        let first = try await fixture.lifecycle.begin(
            binding: fixture.bindingB)
        XCTAssertEqual(first.phase, .completed)

        fixture.activateFreshState(for: fixture.bindingB)
        XCTAssertTrue(fixture.freshStateIsPublishable)
        XCTAssertFalse(fixture.freshStateWasDeleted)

        let second = try await fixture.lifecycle.begin(
            binding: fixture.bindingB)
        XCTAssertGreaterThan(second.deletionEpoch, first.deletionEpoch)
        XCTAssertTrue(fixture.freshStateWasDeleted)
    }

    func testTask8RemovesEveryWholeDomainDeletionDebt() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let violations = try AccountPreferenceUsageGuard.scanRepository(
            at: repository)
        let debt = violations.filter {
            $0.reason == "whole preference-domain removal is forbidden"
        }
        XCTAssertTrue(
            debt.isEmpty,
            "selective account deletion must never remove a whole preference domain")
    }
}

private func completeDeletionRecord(
    store: AccountDeletionLifecycleStore,
    pending: AccountDeletionLifecycleRecord,
    blockedGeneration: UInt64,
    disposition: AccountDeletionLegacyDisposition
) throws -> AccountDeletionLifecycleRecord {
    var record = try store.compareAndSwap(
        ownerScope: pending.ownerScope,
        expectedEpoch: pending.deletionEpoch
    ) {
        $0.exposureBarrier = .closed
        $0.blockedGeneration = blockedGeneration
    }
    for group in AccountDeletionCleanupGroup.allCases {
        record = try store.compareAndSwap(
            ownerScope: pending.ownerScope,
            expectedEpoch: pending.deletionEpoch
        ) {
            $0.completedGroups.append(group)
            if group == .legacyInputs {
                $0.legacyDisposition = disposition
            }
        }
    }
    return try store.compareAndSwap(
        ownerScope: pending.ownerScope,
        expectedEpoch: pending.deletionEpoch
    ) { $0.phase = .completed }
}

private enum ScriptedDeletionRead {
    case absent
    case success(Data)
    case failure(ScriptedDeletionReadFailure)
    case mirrorLastWrite
}

private enum RealScopeRecordFailure {
    case corrupt
    case unsupportedVersion
    case unreadable
    case protectedDataUnavailable
    case failed

    var injectedFailure: AccountDeletionLifecycleReadFailure? {
        switch self {
        case .corrupt, .unsupportedVersion:
            return nil
        case .unreadable:
            return .unreadable
        case .protectedDataUnavailable:
            return .protectedDataUnavailable
        case .failed:
            return .failed
        }
    }
}

private enum ScriptedDeletionReadFailure: Error {
    case unreadable
    case protectedDataUnavailable
    case failed
}

private enum ScriptedWriteResult {
    case interrupted
    case writeRemaining
}

private final class ScriptedDeletionFileIO:
    AccountDeletionLifecycleFileIO, @unchecked Sendable
{
    private let lock = NSRecursiveLock()
    private var _readResult: ScriptedDeletionRead = .absent
    private var _operations: [DeletionDurabilityOperation] = []
    private var _failOperation: DeletionDurabilityOperation?
    private var _writeScript: [ScriptedWriteResult] = []
    private var _writeAttempts = 0
    private var _corruptTypedReadback = false
    var readResult: ScriptedDeletionRead {
        get { lock.withLock { _readResult } }
        set { lock.withLock { _readResult = newValue } }
    }
    var operations: [DeletionDurabilityOperation] {
        get { lock.withLock { _operations } }
        set { lock.withLock { _operations = newValue } }
    }
    var failOperation: DeletionDurabilityOperation? {
        get { lock.withLock { _failOperation } }
        set { lock.withLock { _failOperation = newValue } }
    }
    var writeScript: [ScriptedWriteResult] {
        get { lock.withLock { _writeScript } }
        set { lock.withLock { _writeScript = newValue } }
    }
    var writeAttempts: Int {
        lock.withLock { _writeAttempts }
    }
    var corruptTypedReadback: Bool {
        get { lock.withLock { _corruptTypedReadback } }
        set { lock.withLock { _corruptTypedReadback = newValue } }
    }
    private var corruptPendingReadback = false
    private var lastWrite = Data()
    private var typedReadbackExpected = false

    func read(_ url: URL) throws -> Data? {
        try lock.withLock {
            let isTypedReadback = typedReadbackExpected
            let operation: DeletionDurabilityOperation =
                isTypedReadback ? .typedReadback : .readCurrent
            typedReadbackExpected = false
            _operations.append(operation)
            if _failOperation == operation {
                throw ScriptedDeletionReadFailure.failed
            }
            if isTypedReadback {
                if corruptPendingReadback {
                    corruptPendingReadback = false
                    return Data(lastWrite.dropLast())
                }
                return lastWrite
            }
            switch _readResult {
            case .absent:
                return nil
            case .success(let data):
                return data
            case .failure(let error):
                throw error
            case .mirrorLastWrite:
                return lastWrite.isEmpty ? nil : lastWrite
            }
        }
    }

    func createUniqueTemporaryFile(
        in directory: URL,
        mode: Int
    ) throws -> URL {
        try lock.withLock {
        XCTAssertEqual(mode, 0o600)
        try record(.createUniqueTempSameDirectory0600)
        return directory.appendingPathComponent(
            ".deletion-\(UUID().uuidString).tmp")
        }
    }

    func writeSome(
        _ data: Data,
        from offset: Int,
        to temporaryFile: URL
    ) throws -> DeletionWriteResult {
        try lock.withLock {
        _writeAttempts += 1
        let scripted = _writeScript.isEmpty
            ? ScriptedWriteResult.writeRemaining
            : _writeScript.removeFirst()
        switch scripted {
        case .interrupted:
            return .interrupted
        case .writeRemaining:
            try record(.writeAll)
            lastWrite = data
            corruptPendingReadback = corruptTypedReadback
            typedReadbackExpected = true
            return .written(data.count - offset)
        }
        }
    }

    func fsyncFile(at url: URL) throws {
        try lock.withLock { try record(.fsyncFile) }
    }

    func closeFile(at url: URL) throws {
        try lock.withLock { try record(.closeFile) }
    }

    func renamePOSIX(_ source: URL, to destination: URL) throws {
        try lock.withLock {
        XCTAssertEqual(
            source.deletingLastPathComponent(),
            destination.deletingLastPathComponent())
        try record(.renamePOSIX)
        }
    }

    func fsyncParent(of url: URL) throws {
        try lock.withLock { try record(.fsyncParent) }
    }

    func closeParent(of url: URL) throws {
        try lock.withLock { try record(.closeParent) }
    }

    private func record(_ operation: DeletionDurabilityOperation) throws {
        _operations.append(operation)
        if _failOperation == operation {
            throw ScriptedDeletionReadFailure.failed
        }
    }
}

private final class DeletionStoreFixture: @unchecked Sendable {
    let root: URL
    let io = ScriptedDeletionFileIO()
    let store: AccountDeletionLifecycleStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foundryx-deletion-store-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        store = AccountDeletionLifecycleStore(container: root, fileIO: io)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum DeletionTestEvent: Equatable {
    case pendingDurableReadback
    case resolutionBlocked
    case signedInMirrorFalse
    case widgetWithdrawn
    case liveExposuresClosed
    case staleWorkCancelled
    case barrierVerified
    case barrierClosedDurableReadback
    case cleanup(AccountDeletionCleanupGroup)
    case completedDurableReadback
}

private final class DeletionFaultControl: @unchecked Sendable {
    var failingPoint: DeletionFaultPoint?
    lazy var injector = DeletionFaultInjector { [weak self] point in
        if point == self?.failingPoint {
            throw AccountDeletionLifecycleError.injectedCrash(point)
        }
    }

    init(failingPoint: DeletionFaultPoint?) {
        self.failingPoint = failingPoint
    }
}

private final class DeletionRegistrationOwner: @unchecked Sendable {}

final class DeletionCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var isFinished: Bool { lock.withLock { finished } }
    func markFinished() { lock.withLock { finished = true } }
}

private final class DeletionParticipantCallCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var live = 0
    private var stale = 0

    func increment(_ kind: AccountExposureRegistration.Kind) {
        lock.withLock {
            switch kind {
            case .live: live += 1
            case .staleWork: stale += 1
            }
        }
    }

    func count(_ kind: AccountExposureRegistration.Kind) -> Int {
        lock.withLock {
            switch kind {
            case .live: return live
            case .staleWork: return stale
            }
        }
    }
}

private final class DeletionLifecycleState: @unchecked Sendable {
    var events: [DeletionTestEvent] = []
    var cleanedGroups: [AccountDeletionCleanupGroup] = []
    var verifiedGroups: [AccountDeletionCleanupGroup] = []
    var cleanupBindings: [CaptureAccountScope.AccountBinding] = []
    var currentBinding: CaptureAccountScope.AccountBinding?
    var publishedActiveScopes: [String] = []
    var widgetOwner: String?
    var beforeWidgetPublication: (() -> Void)?
    var afterPendingCapture: (() -> Void)?
    var liveAcknowledgement: AccountExposureCloseResult = .closed
    var staleAcknowledgement: AccountExposureCloseResult = .closed
    var lastLiveAcknowledgements: [AccountExposureAcknowledgement] = []
    var lastStaleAcknowledgements: [AccountExposureAcknowledgement] = []
    var legacyOwnerProof: String?
    var legacyBytes = Data()
    var legacyInputsAreAbsent = false
    var preservationControls: [String: Data] = [:]
    var preservationSnapshot: [String: Data] = [:]
    var metadataWasEnumeratedAsLegacyInput = false
    var freshStateIsPublishable = false
    var freshStateWasDeleted = false
    var assertLocksReleasedInsideEveryHook = false
    var reenterLifecycleFromEveryHook = false
    var requireNoMainSync = false
    var everyHookObservedLocksReleased = true
    var mainSyncAttempted = false
    var identityBoundaryDeliveries = 0
    weak var lifecycle: AccountDeletionLifecycle?

    func observeHook() {
        guard assertLocksReleasedInsideEveryHook else { return }
        everyHookObservedLocksReleased =
            everyHookObservedLocksReleased
            && lifecycle?.lockStateForTests == .unlocked
        if reenterLifecycleFromEveryHook {
            _ = lifecycle?.record(ownerScope: currentBinding?.scope ?? "")
        }
        if requireNoMainSync {
            mainSyncAttempted =
                mainSyncAttempted || lifecycle?.mainSyncCountForTests != 0
        }
    }
}

private final class DeletionLifecycleFixture {
    let root: URL
    let io = ScriptedDeletionFileIO()
    let store: AccountDeletionLifecycleStore
    let state = DeletionLifecycleState()
    let faultInjector: DeletionFaultControl
    let lifecycle: AccountDeletionLifecycle
    let exposureCoordinator: AccountExposureCoordinator
    var exposureOwners: [DeletionRegistrationOwner]
    var exposureRegistrations: [AccountExposureRegistration]
    let bindingA: CaptureAccountScope.AccountBinding
    let bindingB: CaptureAccountScope.AccountBinding
    let bindingC: CaptureAccountScope.AccountBinding

    var events: [DeletionTestEvent] {
        get { state.events }
        set { state.events = newValue }
    }
    var cleanedGroups: [AccountDeletionCleanupGroup] {
        get { state.cleanedGroups }
        set { state.cleanedGroups = newValue }
    }
    var verifiedGroups: [AccountDeletionCleanupGroup] {
        get { state.verifiedGroups }
        set { state.verifiedGroups = newValue }
    }
    var cleanupBindings: [CaptureAccountScope.AccountBinding] {
        state.cleanupBindings
    }
    var currentBinding: CaptureAccountScope.AccountBinding? {
        get { state.currentBinding }
        set { state.currentBinding = newValue }
    }
    var publishedActiveScopes: [String] {
        state.publishedActiveScopes
    }
    var widgetOwner: String? { state.widgetOwner }
    var beforeWidgetPublication: (() -> Void)? {
        get { state.beforeWidgetPublication }
        set { state.beforeWidgetPublication = newValue }
    }
    var afterPendingCapture: (() -> Void)? {
        get { state.afterPendingCapture }
        set { state.afterPendingCapture = newValue }
    }
    var liveAcknowledgement: AccountExposureCloseResult {
        get { state.liveAcknowledgement }
        set { state.liveAcknowledgement = newValue }
    }
    var staleAcknowledgement: AccountExposureCloseResult {
        get { state.staleAcknowledgement }
        set { state.staleAcknowledgement = newValue }
    }
    var lastLiveAcknowledgements: [AccountExposureAcknowledgement] {
        state.lastLiveAcknowledgements
    }
    var lastStaleAcknowledgements: [AccountExposureAcknowledgement] {
        state.lastStaleAcknowledgements
    }
    var legacyOwnerProof: String? {
        get { state.legacyOwnerProof }
        set { state.legacyOwnerProof = newValue }
    }
    var legacyBytes: Data { state.legacyBytes }
    var legacyInputsAreAbsent: Bool { state.legacyInputsAreAbsent }
    var preservationControls: [String: Data] {
        state.preservationControls
    }
    var metadataDirectoryExists: Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                AccountDeletionLifecycleStore.metadataDirectoryName
            ).path)
    }
    var metadataWasEnumeratedAsLegacyInput: Bool {
        state.metadataWasEnumeratedAsLegacyInput
    }
    var freshStateIsPublishable: Bool { state.freshStateIsPublishable }
    var freshStateWasDeleted: Bool { state.freshStateWasDeleted }
    var assertLocksReleasedInsideEveryHook: Bool {
        get { state.assertLocksReleasedInsideEveryHook }
        set { state.assertLocksReleasedInsideEveryHook = newValue }
    }
    var reenterLifecycleFromEveryHook: Bool {
        get { state.reenterLifecycleFromEveryHook }
        set { state.reenterLifecycleFromEveryHook = newValue }
    }
    var requireNoMainSync: Bool {
        get { state.requireNoMainSync }
        set { state.requireNoMainSync = newValue }
    }
    var everyHookObservedLocksReleased: Bool {
        state.everyHookObservedLocksReleased
    }
    var mainSyncAttempted: Bool { state.mainSyncAttempted }
    var identityBoundaryDeliveries: Int {
        state.identityBoundaryDeliveries
    }
    var didDurablyCloseBarrierBeforeFirstCleanup: Bool {
        guard let firstCleanup = events.firstIndex(where: {
            if case .cleanup = $0 { return true }
            return false
        }) else { return true }
        return events[..<firstCleanup].contains(
            .barrierClosedDurableReadback)
    }

    init(failingAt point: DeletionFaultPoint? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foundryx-deletion-lifecycle-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        io.readResult = .mirrorLastWrite
        store = AccountDeletionLifecycleStore(container: root, fileIO: io)
        faultInjector = DeletionFaultControl(failingPoint: point)
        exposureCoordinator = AccountExposureCoordinator()
        exposureOwners = []
        exposureRegistrations = []
        bindingA = .init(
            root: root.appendingPathComponent("acct-aaaaaaaaaaaaaaaa"),
            scope: "acct-aaaaaaaaaaaaaaaa",
            generation: 10)
        bindingB = .init(
            root: root.appendingPathComponent("acct-bbbbbbbbbbbbbbbb"),
            scope: "acct-bbbbbbbbbbbbbbbb",
            generation: 20)
        bindingC = .init(
            root: root.appendingPathComponent("acct-cccccccccccccccc"),
            scope: "acct-cccccccccccccccc",
            generation: 30)
        state.currentBinding = bindingB
        for (id, kind) in [
            ("live-a", AccountExposureRegistration.Kind.live),
            ("live-b", .live),
            ("stale-a", .staleWork),
            ("stale-b", .staleWork),
        ] {
            let owner = DeletionRegistrationOwner()
            let registration = AccountExposureRegistration(
                participantID: id,
                kind: kind,
                binding: bindingB,
                owner: owner
            ) { [state] _, _ in
                state.observeHook()
                return kind == .live
                    ? state.liveAcknowledgement
                    : state.staleAcknowledgement
            }
            exposureOwners.append(owner)
            exposureRegistrations.append(registration)
            exposureCoordinator.register(registration)
        }
        exposureCoordinator.register(exposureRegistrations[0])
        let registeredExposureCoordinator = exposureCoordinator
        let expectedExposureBinding = bindingB

        let environment = AccountDeletionLifecycleEnvironment(
            verifyCurrentBinding: { [state] binding in
                state.observeHook()
                return state.currentBinding == binding
            },
            blockResolution: { [state] binding in
                state.observeHook()
                state.events.append(.resolutionBlocked)
                state.currentBinding = nil
                return binding.generation + 1
            },
            deliverIdentityBoundary: { [state] _ in
                state.observeHook()
                state.identityBoundaryDeliveries += 1
            },
            setSignedInMirrorFalse: { [state] _ in
                state.observeHook()
                state.events.append(.signedInMirrorFalse)
            },
            withdrawWidget: { [state] binding in
                state.observeHook()
                state.events.append(.widgetWithdrawn)
                if state.widgetOwner == binding.scope {
                    state.widgetOwner = nil
                }
                return .closed
            },
            closeLiveExposures: { [state] _ in
                state.observeHook()
                state.events.append(.liveExposuresClosed)
                let acknowledgements =
                    await registeredExposureCoordinator
                        .closeRegisteredExposures(
                            expected: expectedExposureBinding)
                state.lastLiveAcknowledgements = acknowledgements
                return acknowledgements
            },
            cancelStaleWork: { [state] _ in
                state.observeHook()
                state.events.append(.staleWorkCancelled)
                let acknowledgements =
                    await registeredExposureCoordinator
                        .cancelRegisteredStaleWork(
                            expected: expectedExposureBinding)
                state.lastStaleAcknowledgements = acknowledgements
                return acknowledgements
            },
            verifyExposureBarrier: { [state] _, _ in
                state.observeHook()
                state.events.append(.barrierVerified)
                let all = state.lastLiveAcknowledgements
                    + state.lastStaleAcknowledgements
                return !all.isEmpty && all.allSatisfy {
                    $0.result == .closed || $0.result == .alreadyClosed
                }
            },
            removeGroup: { [state] group, binding, legacyOwned in
                state.observeHook()
                state.events.append(.cleanup(group))
                state.cleanedGroups.append(group)
                state.cleanupBindings.append(binding)
                if group == .legacyInputs, legacyOwned {
                    state.legacyBytes = Data()
                    state.legacyInputsAreAbsent = true
                }
                if state.freshStateIsPublishable {
                    state.freshStateWasDeleted = true
                }
            },
            verifyGroupAbsent: { [state] group, _ in
                state.observeHook()
                state.verifiedGroups.append(group)
                return true
            },
            legacyOwnerScope: { [state] in
                state.observeHook()
                return state.legacyOwnerProof
            },
            reassertDeletionBarrier: { [state] ownerScope in
                state.observeHook()
                guard ownerScope == expectedExposureBinding.scope else {
                    return nil
                }
                state.events.append(.resolutionBlocked)
                state.currentBinding = nil
                return (
                    expectedExposureBinding,
                    expectedExposureBinding.generation + 2)
            })
        lifecycle = AccountDeletionLifecycle(
            store: store,
            environment: environment,
            faultInjector: faultInjector.injector,
            eventObserver: { [state] event in
                switch event {
                case .pendingDurableReadback:
                    state.events.append(.pendingDurableReadback)
                    state.afterPendingCapture?()
                case .barrierClosedDurableReadback:
                    state.events.append(.barrierClosedDurableReadback)
                case .completedDurableReadback:
                    state.events.append(.completedDurableReadback)
                }
            })
        state.lifecycle = lifecycle
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func installUnavailableRegistration(
        kind: AccountExposureRegistration.Kind
    ) {
        let owner = DeletionRegistrationOwner()
        let registration = AccountExposureRegistration(
            participantID: "missing-\(kind)",
            kind: kind,
            binding: nil,
            owner: owner
        ) { _, _ in
            XCTFail("nil binding must not invoke participant")
            return .closed
        }
        exposureOwners.append(owner)
        exposureRegistrations.append(registration)
        exposureCoordinator.register(registration)
    }

    func publishCurrentBinding() -> CaptureAccountScope.AccountBinding? {
        guard let captured = state.currentBinding else { return nil }
        state.beforeWidgetPublication?()
        guard state.currentBinding == captured else {
            if let current = state.currentBinding {
                state.widgetOwner = current.scope
            }
            return nil
        }
        state.widgetOwner = captured.scope
        state.publishedActiveScopes.append(captured.scope)
        return captured
    }

    func publish(scope: String, generation: UInt64, root: URL) -> Bool {
        guard let current = state.currentBinding,
              current.scope == scope,
              current.generation == generation,
              current.root == root else {
            return false
        }
        state.publishedActiveScopes.append(scope)
        return true
    }

    func seedPreservationControls(
        accountA: String,
        accountB: String
    ) -> [String: Data] {
        let values: [String: Data] = [
            "\(accountA).preferences": Data("A-preferences".utf8),
            "\(accountA).pairing": Data("A-pairing".utf8),
            "\(accountA).root": Data("A-root".utf8),
            "phone.hardware": Data("phone-hardware".utf8),
            "bootstrap.auth": Data("bootstrap-auth".utf8),
            "activation.record": Data("activation".utf8),
            "app-group.widget": Data("widget-handoff".utf8),
        ]
        state.preservationControls = values
        state.preservationSnapshot = values
        return values
    }

    @discardableResult
    func seedLegacyInputs() -> Data {
        let bytes = Data("legacy-values-and-empty-account-secrets".utf8)
        state.legacyBytes = bytes
        return bytes
    }

    func activateFreshState(
        for binding: CaptureAccountScope.AccountBinding
    ) {
        state.currentBinding = binding
        state.freshStateIsPublishable = true
        state.freshStateWasDeleted = false
        state.publishedActiveScopes.append(binding.scope)
    }
}

private final class DeletionScopeFixture {
    let root: URL
    let defaultsName: String
    let defaults: UserDefaults

    init() throws {
        let discriminator = UUID().uuidString.lowercased()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foundryx-deletion-scope-\(discriminator)",
            isDirectory: true)
        defaultsName = "foundryx.deletion-scope.\(discriminator)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        CaptureAccountScope.resetTestEnvironment()
        CaptureAccountScope.setContainerForTests(root)
        CaptureAccountScope.setDefaultsForTests(defaults)
        CaptureWidgetSnapshotStore.setDefaultsForTesting(defaults)
    }

    func activate(
        subject: String
    ) throws -> CaptureAccountScope.AccountBinding {
        try CaptureAccountScope.activateForTests(identity(subject: subject))
        return try XCTUnwrap(CaptureAccountScope.currentAccountBinding())
    }

    func identity(subject: String) -> AuthIdentity {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8)
        let payload = Data(#"{"sub":"\#(subject)"}"#.utf8)
        let token = [header, payload].map {
            $0.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }.joined(separator: ".") + ".test-signature"
        return AuthIdentity(
            provider: AuthProvider.google.rawValue,
            idToken: token,
            refreshToken: nil,
            expiresAt: .distantFuture,
            email: "\(subject)@example.test")
    }

    func cleanup() {
        CaptureAccountScope
            .setBeforeAccountBindingPublicationHookForTests(nil)
        CaptureWidgetSnapshotStore.resetDefaultsForTesting()
        CaptureAccountScope.resetTestEnvironment()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class DeletionMetadataObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var wasEnumerated: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

final class SelectiveDeletionIntegrationFixture:
    @unchecked Sendable
{
    enum LegacyProof: Equatable {
        case absent
        case ownedByA
        case ownedByB
    }

    let root: URL
    let defaultsName: String
    let appGroupDefaultsName: String
    let defaults: UserDefaults
    let appGroupDefaults: UserDefaults
    let secrets = DeletionTypedSecretStore()
    let identityA: AuthIdentity
    let identityB: AuthIdentity
    let scopeA: String
    let bindingB: CaptureAccountScope.AccountBinding
    let cellService: String
    let doorService: String
    let authService: String
    let noiseService: String
    let lifecycle: AccountDeletionLifecycle
    let exposureCoordinator = AccountExposureCoordinator()
    private let participantCallCounts = DeletionParticipantCallCounts()
    private var exposureOwners: [DeletionRegistrationOwner] = []
    private var exposureRegistrations: [AccountExposureRegistration] = []
    private let metadataObservation = DeletionMetadataObservation()
    private let faultControl: DeletionFaultControl

    private let trackAKeys = [
        "foundryx.cell.url",
        "foundryx.cell.authMode",
        "foundryx.door.url",
    ]
    private var preservedKeys: [String] {
        AccountPreferenceUsageGuard.phoneOwnedKeys
            .subtracting([
                "foundryx.capture.widget-snapshot",
                "foundryx.capture.widget-snapshot.active-owner",
                "foundryx.auth.signed-in",
                "foundryx.omi.peripheral-id",
                "foundryx.omi.peripheral-name",
                "foundryx.omi.last-connected",
                "foundryx.battery.monitored.uuid",
                "foundryx.battery.monitored.name",
                "foundryx.capture.source",
                "foundryx.capture.sources.added",
                "foundryx.action-button.choice",
            ])
            .sorted()
    }
    private let historicalIdentityB = "owner-b@example.test"

    init(
        legacyProof: LegacyProof,
        identityEmail: String = "owner-b@example.test",
        registerRetryParticipants: Bool = false,
        failingAt faultPoint: DeletionFaultPoint? = nil
    ) throws {
        faultControl = DeletionFaultControl(failingPoint: faultPoint)
        let discriminator = UUID().uuidString.lowercased()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foundryx-live-deletion-\(discriminator)",
            isDirectory: true)
        defaultsName = "foundryx.live-deletion.\(discriminator)"
        appGroupDefaultsName =
            "foundryx.live-deletion.widget.\(discriminator)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        appGroupDefaults = try XCTUnwrap(
            UserDefaults(suiteName: appGroupDefaultsName))
        cellService = "foundryx.live-deletion.cell.\(discriminator)"
        doorService = "foundryx.live-deletion.door.\(discriminator)"
        authService = "foundryx.live-deletion.auth.\(discriminator)"
        noiseService = "foundryx.live-deletion.noise.\(discriminator)"
        identityA = Self.identity(subject: "owner-a")
        identityB = Self.identity(
            subject: "owner-b", email: identityEmail)
        scopeA = try CaptureAccountScope.key(for: identityA)

        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        CaptureAccountScope.resetTestEnvironment()
        CaptureAccountScope.setContainerForTests(root)
        CaptureAccountScope.setDefaultsForTests(defaults)
        CaptureWidgetSnapshotStore.setDefaultsForTesting(appGroupDefaults)
        CaptureAccountScope.setPairingKeychainServicesForTests(
            cell: cellService,
            door: doorService)
        AuthStore.setIdentityEraseForTests { .alreadyClean }
        try CaptureAccountScope.activateForTests(identityB)
        bindingB = try XCTUnwrap(
            CaptureAccountScope.currentAccountBinding())
        let migrationMarker = root.appendingPathComponent(".migrated-to")
        try? FileManager.default.removeItem(at: migrationMarker)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: migrationMarker.path))

        try Self.seedScopedOwner(
            scope: scopeA,
            root: root.appendingPathComponent(scopeA),
            discriminator: "A",
            defaults: defaults,
            secrets: secrets,
            cellService: cellService,
            doorService: doorService,
            trackAKeys: trackAKeys)
        try Self.seedScopedOwner(
            scope: bindingB.scope,
            root: bindingB.root,
            discriminator: "B",
            defaults: defaults,
            secrets: secrets,
            cellService: cellService,
            doorService: doorService,
            trackAKeys: trackAKeys)
        for (index, key) in AccountPreferenceCatalog.entries
            .map(\.canonicalKey).enumerated() {
            defaults.set("legacy-\(index)", forKey: key)
        }
        for key in trackAKeys {
            defaults.set("legacy-\(key)", forKey: key)
        }
        defaults.set(
            true,
            forKey: "foundryx.account.signup-posted.\(historicalIdentityB)")
        secrets.seed(
            "legacy-cell",
            service: cellService,
            account: "")
        secrets.seed(
            "legacy-door",
            service: doorService,
            account: "")
        secrets.seed(
            "auth-bootstrap",
            service: authService,
            account: "current")
        secrets.seed(
            "noise-identity",
            service: noiseService,
            account: "device")
        let initialPreservedKeys =
            AccountPreferenceUsageGuard.phoneOwnedKeys
                .subtracting([
                    "foundryx.capture.widget-snapshot",
                    "foundryx.capture.widget-snapshot.active-owner",
                    "foundryx.auth.signed-in",
                ])
                .sorted()
        for key in initialPreservedKeys {
            if defaults.object(forKey: key) == nil {
                defaults.set(Data("preserve-\(key)".utf8), forKey: key)
            }
        }
        defaults.set(true, forKey: "foundryx.auth.signed-in")
        appGroupDefaults.set(
            Data("widget-handoff".utf8),
            forKey: "foundryx.capture.widget-snapshot")
        appGroupDefaults.set(
            bindingB.scope,
            forKey: "foundryx.capture.widget-snapshot.active-owner")
        appGroupDefaults.set(
            Data("unrelated-app-group-sentinel".utf8),
            forKey: "foundryx.test.unrelated-app-group-sentinel")
        switch legacyProof {
        case .absent:
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: migrationMarker.path))
        case .ownedByA:
            try Data(scopeA.utf8).write(
                to: migrationMarker)
            XCTAssertEqual(
                try String(contentsOf: migrationMarker, encoding: .utf8),
                scopeA)
        case .ownedByB:
            try Data(bindingB.scope.utf8).write(
                to: migrationMarker)
            XCTAssertEqual(
                try String(contentsOf: migrationMarker, encoding: .utf8),
                bindingB.scope)
        }
        let verifiedScope = bindingB.scope
        let verifiedIdentity = identityB
        let observation = metadataObservation
        if registerRetryParticipants {
            for (id, kind) in [
                ("live-retry", AccountExposureRegistration.Kind.live),
                ("stale-retry", .staleWork),
            ] {
                let owner = DeletionRegistrationOwner()
                let calls = participantCallCounts
                let registration = AccountExposureRegistration(
                    participantID: id,
                    kind: kind,
                    binding: bindingB,
                    owner: owner
                ) { _, _ in
                    calls.increment(kind)
                    return .closed
                }
                exposureOwners.append(owner)
                exposureRegistrations.append(registration)
                exposureCoordinator.register(registration)
            }
        }

        lifecycle = AccountDeletionLifecycle.live(
            container: root,
            defaults: defaults,
            secretStore: secrets,
            pairingServices: (cell: cellService, door: doorService),
            exposureCoordinator: exposureCoordinator,
            verifiedIdentityForScope: { scope in
                scope == verifiedScope ? verifiedIdentity : nil
            },
            legacyEnumerationObserver: { url in
                if url.lastPathComponent == ".account-deletions-v1" {
                    observation.wasEnumerated = true
                }
            },
            faultInjector: faultControl.injector)
    }

    var historicalSignupMarkerObject: Any? {
        defaults.object(
            forKey:
                "foundryx.account.signup-posted.\(historicalIdentityB)")
    }

    var liveParticipantCalls: Int {
        participantCallCounts.count(.live)
    }

    var staleParticipantCalls: Int {
        participantCallCounts.count(.staleWork)
    }

    var lifecycleMetadataExists: Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                ".account-deletions-v1",
                isDirectory: true).path)
    }

    var widgetOwnerAndPayloadAreAbsent: Bool {
        appGroupDefaults.object(
            forKey: "foundryx.capture.widget-snapshot") == nil
            && appGroupDefaults.object(
                forKey:
                    "foundryx.capture.widget-snapshot.active-owner") == nil
    }

    var signedInMirrorIsDurablyFalse: Bool {
        defaults.object(forKey: "foundryx.auth.signed-in") != nil
            && defaults.bool(forKey: "foundryx.auth.signed-in") == false
    }

    var metadataAppearedInLegacyEnumeration: Bool {
        metadataObservation.wasEnumerated
    }

    var allScopedBInputsAreAbsent: Bool {
        let keys = AccountPreferenceCatalog.entries.map(\.canonicalKey)
            + trackAKeys
        return keys.allSatisfy {
            defaults.object(
                forKey: "\(bindingB.scope).\($0)") == nil
        }
            && secrets.inspect(
                service: cellService,
                account: bindingB.scope) == .notFound
            && secrets.inspect(
                service: doorService,
                account: bindingB.scope) == .notFound
            && !FileManager.default.fileExists(
                atPath: bindingB.root.path)
    }

    var allScopedBInputsRemainPresent: Bool {
        let keys = AccountPreferenceCatalog.entries.map(\.canonicalKey)
            + trackAKeys
        return keys.allSatisfy {
            defaults.object(
                forKey: "\(bindingB.scope).\($0)") != nil
        }
            && secrets.inspect(
                service: cellService,
                account: bindingB.scope) != .notFound
            && secrets.inspect(
                service: doorService,
                account: bindingB.scope) != .notFound
            && FileManager.default.fileExists(
                atPath: bindingB.root.path)
    }

    var allProvedLegacyInputsAreAbsent: Bool {
        let keys = AccountPreferenceCatalog.entries.map(\.canonicalKey)
            + trackAKeys
        return keys.allSatisfy {
            defaults.object(forKey: $0) == nil
        }
            && historicalSignupMarkerObject == nil
            && secrets.inspect(
                service: cellService, account: "") == .notFound
            && secrets.inspect(
                service: doorService, account: "") == .notFound
    }

    func snapshotPreservedControls() -> [String: Data] {
        var snapshot: [String: Data] = [:]
        for key in AccountPreferenceCatalog.entries.map(\.canonicalKey)
            + trackAKeys {
            snapshot["A-pref|\(key)"] = bytes(
                defaults.object(forKey: "\(scopeA).\(key)"))
        }
        for key in preservedKeys {
            snapshot["phone|\(key)"] = bytes(
                defaults.object(forKey: key))
        }
        snapshot["A-cell-secret"] = bytes(secrets.value(
            service: cellService, account: scopeA))
        snapshot["A-door-secret"] = bytes(secrets.value(
            service: doorService, account: scopeA))
        snapshot["auth-keychain"] = bytes(secrets.value(
            service: authService, account: "current"))
        snapshot["noise-keychain"] = bytes(secrets.value(
            service: noiseService, account: "device"))
        snapshot["A-root"] = (try? Data(contentsOf:
            root.appendingPathComponent(scopeA)
                .appendingPathComponent("payload.bin"))) ?? Data()
        snapshot["app-group-sentinel"] = bytes(appGroupDefaults.object(
            forKey: "foundryx.test.unrelated-app-group-sentinel"))
        return snapshot
    }

    func activationAliases() -> [String: String]? {
        guard let data = defaults.data(
            forKey: "foundryx.capture-account-activation.v2"),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let aliases = object["aliases"] as? [String: String] else {
            return nil
        }
        return aliases
    }

    func snapshotLegacyInputs() -> [String: Data] {
        var result: [String: Data] = [:]
        for key in AccountPreferenceCatalog.entries.map(\.canonicalKey)
            + trackAKeys {
            result[key] = bytes(defaults.object(forKey: key))
        }
        result["historical-signup"] = bytes(historicalSignupMarkerObject)
        result["empty-cell"] = bytes(secrets.value(
            service: cellService, account: ""))
        result["empty-door"] = bytes(secrets.value(
            service: doorService, account: ""))
        return result
    }

    func readMigrationMarker() -> String? {
        try? String(
            contentsOf: root.appendingPathComponent(".migrated-to"),
            encoding: .utf8)
    }

    func cleanup() {
        AuthStore.setIdentityEraseForTests(nil)
        CaptureWidgetSnapshotStore.resetDefaultsForTesting()
        CaptureAccountScope.resetTestEnvironment()
        defaults.removePersistentDomain(forName: defaultsName)
        appGroupDefaults.removePersistentDomain(
            forName: appGroupDefaultsName)
        try? FileManager.default.removeItem(at: root)
    }

    func installTestEnvironment() {
        CaptureAccountScope.resetTestEnvironment()
        CaptureAccountScope.setContainerForTests(root)
        CaptureAccountScope.setDefaultsForTests(defaults)
        CaptureWidgetSnapshotStore.setDefaultsForTesting(appGroupDefaults)
        CaptureAccountScope.setPairingKeychainServicesForTests(
            cell: cellService,
            door: doorService)
        AuthStore.setIdentityEraseForTests { .alreadyClean }
    }

    func allowRecovery() {
        faultControl.failingPoint = nil
    }

    func seedFreshBState(
        as binding: CaptureAccountScope.AccountBinding
    ) throws {
        XCTAssertEqual(
            CaptureAccountScope.currentAccountBinding(),
            binding)
        try Self.seedScopedOwner(
            scope: binding.scope,
            root: binding.root,
            discriminator: "fresh-B",
            defaults: defaults,
            secrets: secrets,
            cellService: cellService,
            doorService: doorService,
            trackAKeys: trackAKeys)
    }

    func freshBStateExists(
        as binding: CaptureAccountScope.AccountBinding
    ) -> Bool {
        let keys = AccountPreferenceCatalog.entries.map(\.canonicalKey)
            + trackAKeys
        return keys.allSatisfy {
            defaults.object(forKey: "\(binding.scope).\($0)") != nil
        }
            && secrets.inspect(
                service: cellService,
                account: binding.scope) == .found("fresh-B-cell")
            && secrets.inspect(
                service: doorService,
                account: binding.scope) == .found("fresh-B-door")
            && FileManager.default.fileExists(
                atPath: binding.root.appendingPathComponent(
                    "payload.bin").path)
    }

    private static func seedScopedOwner(
        scope: String,
        root: URL,
        discriminator: String,
        defaults: UserDefaults,
        secrets: DeletionTypedSecretStore,
        cellService: String,
        doorService: String,
        trackAKeys: [String]
    ) throws {
        for (index, key) in AccountPreferenceCatalog.entries
            .map(\.canonicalKey).enumerated() {
            defaults.set(
                "\(discriminator)-\(index)",
                forKey: "\(scope).\(key)")
        }
        for key in trackAKeys {
            defaults.set(
                "\(discriminator)-\(key)",
                forKey: "\(scope).\(key)")
        }
        secrets.seed(
            "\(discriminator)-cell",
            service: cellService,
            account: scope)
        secrets.seed(
            "\(discriminator)-door",
            service: doorService,
            account: scope)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        try Data("\(discriminator)-root".utf8).write(
            to: root.appendingPathComponent("payload.bin"))
    }

    private func bytes(_ value: Any?) -> Data {
        Data(String(describing: value).utf8)
    }

    private static func identity(
        subject: String,
        email: String? = nil
    ) -> AuthIdentity {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8)
        let payload = Data(#"{"sub":"\#(subject)"}"#.utf8)
        let token = [header, payload].map {
            $0.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }.joined(separator: ".") + ".test-signature"
        return AuthIdentity(
            provider: AuthProvider.google.rawValue,
            idToken: token,
            refreshToken: nil,
            expiresAt: .distantFuture,
            email: email ?? "\(subject)@example.test")
    }
}

final class DeletionTypedSecretStore:
    PairingSecretStore, @unchecked Sendable
{
    private struct Key: Hashable {
        let service: String
        let account: String
    }
    private let lock = NSLock()
    private var values: [Key: String] = [:]
    private var forcedRemoval: PairingSecretRemovalResult?

    func read(service: String, account: String) -> String? {
        lock.withLock {
            values[Key(service: service, account: account)]
        }
    }

    func inspect(
        service: String,
        account: String
    ) -> PairingSecretReadResult {
        read(service: service, account: account)
            .map(PairingSecretReadResult.found) ?? .notFound
    }

    func update(
        _ value: String,
        service: String,
        account: String
    ) -> PairingSecretUpdateResult {
        lock.withLock {
            let key = Key(service: service, account: account)
            guard values[key] != nil else { return .notFound }
            values[key] = value
            return .updated
        }
    }

    func add(_ value: String, service: String, account: String) -> Bool {
        lock.withLock {
            let key = Key(service: service, account: account)
            guard values[key] == nil else { return false }
            values[key] = value
            return true
        }
    }

    func remove(service: String, account: String) -> Bool {
        switch removeExplicitOwner(service: service, account: account) {
        case .removed, .notFound: return true
        case .unavailable, .failed: return false
        }
    }

    func removeExplicitOwner(
        service: String,
        account: String
    ) -> PairingSecretRemovalResult {
        lock.withLock {
            if let forcedRemoval {
                self.forcedRemoval = nil
                return forcedRemoval
            }
            let result: PairingSecretRemovalResult =
                values.removeValue(
                    forKey: Key(service: service, account: account)) == nil
                ? .notFound : .removed
            return result
        }
    }

    func forceNextRemoval(_ result: PairingSecretRemovalResult) {
        lock.withLock { forcedRemoval = result }
    }

    func seed(_ value: String, service: String, account: String) {
        lock.withLock {
            values[Key(service: service, account: account)] = value
        }
    }

    func value(service: String, account: String) -> String? {
        read(service: service, account: account)
    }
}

/// Scenario-9 driver shared by the Brine step file. Each fault point owns a
/// separate real live-deletion fixture so interruption state is retained until
/// the later retry and fresh-return steps inspect it.
final class SelectiveDeletionBehaviorHarness: @unchecked Sendable {
    private struct InterruptedCase {
        let point: DeletionFaultPoint
        let fixture: SelectiveDeletionIntegrationFixture
        let preservedBefore: [String: Data]
        let activationAliasesBefore: [String: String]
    }

    private var interruptedCases: [InterruptedCase] = []
    private var preparedFixture: SelectiveDeletionIntegrationFixture?
    private(set) var confirmationWasOpened = false

    func prepareTwoAccountPhone() throws {
        preparedFixture?.cleanup()
        preparedFixture = try SelectiveDeletionIntegrationFixture(
            legacyProof: .ownedByB)
        confirmationWasOpened = false
    }

    func assertCurrentOwnerInputsWereSeeded() throws {
        guard let fixture = preparedFixture,
              fixture.allScopedBInputsRemainPresent,
              !fixture.snapshotPreservedControls().isEmpty else {
            throw BrineStepError(
                "the two-account phone did not seed both owners and phone controls")
        }
    }

    func openLocalConfirmation() {
        confirmationWasOpened = true
    }

    func assertCurrentAccountOnlyCopy() throws {
        guard confirmationWasOpened,
              AccountDeletionScope.thisPhone.title
                .localizedCaseInsensitiveContains("account"),
              AccountDeletionScope.thisPhone.subtitle.contains(
                "current account") else {
            throw BrineStepError(
                "local deletion does not promise current-account-only erasure")
        }
    }

    func assertPreservationCopy() throws {
        guard AccountDeletionScope.thisPhone.subtitle.contains(
                "Other accounts"),
              AccountDeletionScope.thisPhone.subtitle.contains(
                "pairings"),
              AccountDeletionScope.thisPhone.subtitle.contains(
                "cannot cross accounts") else {
            throw BrineStepError(
                "local deletion does not preserve other accounts while disclosing "
                    + "shared identity-setup removal")
        }
    }

    func interruptAtEveryFaultPoint() async throws {
        preparedFixture?.cleanup()
        preparedFixture = nil
        for point in DeletionFaultPoint.requiredV1 {
            let fixture = try SelectiveDeletionIntegrationFixture(
                legacyProof: .ownedByB,
                failingAt: point)
            let preserved = fixture.snapshotPreservedControls()
            guard let activationAliases = fixture.activationAliases(),
                  !activationAliases.isEmpty else {
                fixture.cleanup()
                throw BrineStepError(
                    "\(point.boundary.rawValue) \(point.stage.rawValue) "
                        + "did not seed activation aliases")
            }
            do {
                _ = try await fixture.lifecycle.begin(
                    binding: fixture.bindingB)
                fixture.cleanup()
                throw BrineStepError(
                    "\(point.boundary.rawValue) \(point.stage.rawValue) "
                        + "did not interrupt deletion")
            } catch let error as BrineStepError {
                fixture.cleanup()
                throw error
            } catch {
                interruptedCases.append(.init(
                    point: point,
                    fixture: fixture,
                    preservedBefore: preserved,
                    activationAliasesBefore: activationAliases))
            }
        }
        guard interruptedCases.count == DeletionFaultPoint.requiredV1.count
        else {
            throw BrineStepError(
                "did not retain every required interrupted deletion case")
        }
    }

    func assertDeletedOwnerBlocked() throws {
        for item in interruptedCases {
            item.fixture.installTestEnvironment()
            guard item.fixture.lifecycle.record(
                    ownerScope: item.fixture.bindingB.scope) != .missing,
                  CaptureAccountScope.currentAccountBinding() == nil,
                  CaptureAccountScope.currentScopedPreferences() == nil,
                  CaptureAccountScope.perform(
                    as: item.fixture.bindingB, { _ in true }) == nil else {
                throw BrineStepError(
                    "\(label(item.point)) left the deleting account open")
            }
        }
    }

    func assertDeletedOwnerDataUnavailable() throws {
        for item in interruptedCases {
            item.fixture.installTestEnvironment()
            guard CaptureAccountScope.currentRoot()
                    != item.fixture.bindingB.root,
                  CaptureAccountScope.currentScopedPreferences() == nil else {
                throw BrineStepError(
                    "\(label(item.point)) exposed deleting-account data")
            }
        }
    }

    func assertWidgetInactive() throws {
        for item in interruptedCases {
            guard item.fixture.widgetOwnerAndPayloadAreAbsent else {
                throw BrineStepError(
                    "\(label(item.point)) retained deleting-account widget activity")
            }
        }
    }

    func assertVisibleRetry() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "App/AccountDeletionView.swift"),
            encoding: .utf8)
        guard source.contains("Retry deletion"),
              source.contains("case .blocked") else {
            throw BrineStepError(
                "pending deletion has no explicit blocked retry action")
        }
    }

    func assertOtherAccountUnchanged() throws {
        for item in interruptedCases {
            guard item.fixture.snapshotPreservedControls()
                    == item.preservedBefore else {
                throw BrineStepError(
                    "\(label(item.point)) changed the other account")
            }
        }
    }

    func assertPhoneUnchanged() throws {
        // Shared identity-bearing setup may still be present before the final
        // replay-tracked surface group, or absent after it; it must never alter the
        // other account's scoped controls.
        try assertOtherAccountUnchanged()
    }

    func retryEveryInterruption() async throws {
        for item in interruptedCases {
            item.fixture.installTestEnvironment()
            item.fixture.allowRecovery()
            let record: AccountDeletionLifecycleRecord
            switch item.fixture.lifecycle.record(
                ownerScope: item.fixture.bindingB.scope) {
            case .missing:
                guard let binding =
                        CaptureAccountScope.currentAccountBinding(),
                      binding.scope == item.fixture.bindingB.scope else {
                    throw BrineStepError(
                        "\(label(item.point)) cannot retry from active owner")
                }
                record = try await item.fixture.lifecycle.begin(
                    binding: binding)
            case .record(let pending) where pending.phase == .cleanupPending:
                record = try await item.fixture.lifecycle.recover(
                    ownerScope: item.fixture.bindingB.scope)
            case .record:
                record = try await item.fixture.lifecycle.recover(
                    ownerScope: item.fixture.bindingB.scope)
            case .blocked(let reason):
                throw BrineStepError(
                    "\(label(item.point)) retry record is blocked: \(reason)")
            }
            guard record.phase == .completed,
                  item.fixture.allScopedBInputsAreAbsent,
                  item.fixture.allProvedLegacyInputsAreAbsent,
                  item.fixture.snapshotPreservedControls()
                    == item.preservedBefore else {
                throw BrineStepError(
                    "\(label(item.point)) retry did not selectively complete")
            }
        }
    }

    func signDeletedOwnerInAgain() throws {
        for item in interruptedCases {
            item.fixture.installTestEnvironment()
            try CaptureAccountScope.activateForTests(
                item.fixture.identityB,
                activatePreferences: true)
            guard let binding =
                    CaptureAccountScope.currentAccountBinding(),
                  binding.scope == item.fixture.bindingB.scope else {
                throw BrineStepError(
                    "\(label(item.point)) did not permit a fresh owner return")
            }
        }
    }

    func assertFreshFirstRun() throws {
        for item in interruptedCases {
            item.fixture.installTestEnvironment()
            try CaptureAccountScope.activateForTests(
                item.fixture.identityB,
                activatePreferences: true)
            guard AccountPreferences.read(
                    AccountPreferenceCatalog.onboardingCompleted)
                    == .value(false),
                  AccountPreferences.read(
                    AccountPreferenceCatalog.welcomeSeen)
                    == .value(false) else {
                throw BrineStepError(
                    "\(label(item.point)) resurrected completed first run")
            }
        }
    }

    func assertCaptureStartsPaused() throws {
        for item in interruptedCases {
            item.fixture.installTestEnvironment()
            try CaptureAccountScope.activateForTests(
                item.fixture.identityB,
                activatePreferences: true)
            guard let binding =
                    CaptureAccountScope.currentAccountBinding(),
                  CaptureSettings.snapshot(binding: binding).omiDesiredState
                    == .paused else {
                throw BrineStepError(
                    "\(label(item.point)) did not return capture paused")
            }
        }
    }

    func assertDeletedDataDoesNotReturn() throws {
        let pairingKeys = [
            "foundryx.cell.url",
            "foundryx.cell.authMode",
            "foundryx.door.url",
        ]
        for item in interruptedCases {
            item.fixture.installTestEnvironment()
            try CaptureAccountScope.activateForTests(
                item.fixture.identityB,
                activatePreferences: true)
            guard let binding =
                    CaptureAccountScope.currentAccountBinding(),
                  !FileManager.default.fileExists(
                    atPath: binding.root.appendingPathComponent(
                        "payload.bin").path),
                  pairingKeys.allSatisfy({
                    item.fixture.defaults.object(
                        forKey: "\(binding.scope).\($0)") == nil
                  }),
                  item.fixture.secrets.inspect(
                    service: item.fixture.cellService,
                    account: binding.scope) == .notFound,
                  item.fixture.secrets.inspect(
                    service: item.fixture.doorService,
                    account: binding.scope) == .notFound else {
                throw BrineStepError(
                    "\(label(item.point)) resurrected deleted local data")
            }
        }
    }

    func assertPostReturnChoicesPersist() async throws {
        for item in interruptedCases {
            item.fixture.installTestEnvironment()
            try CaptureAccountScope.activateForTests(
                item.fixture.identityB,
                activatePreferences: true)
            let value = "after-return-\(item.point.stage.rawValue)-"
                + item.point.boundary.rawValue
            guard AccountPreferences.write(
                    value,
                    for: AccountPreferenceCatalog.ambientAgentName)
                    == .saved else {
                throw BrineStepError(
                    "\(label(item.point)) could not save a fresh choice")
            }
            _ = try await item.fixture.lifecycle.recover(
                ownerScope: item.fixture.bindingB.scope)
            guard AccountPreferences.read(
                    AccountPreferenceCatalog.ambientAgentName)
                    == .value(value) else {
                throw BrineStepError(
                    "\(label(item.point)) stale epoch deleted a fresh choice")
            }
        }
    }

    func assertOtherAccountStillUnchangedAfterReturn() throws {
        for item in interruptedCases {
            item.fixture.installTestEnvironment()
            try CaptureAccountScope.activateForTests(
                item.fixture.identityA,
                activatePreferences: true)
            var preservedBefore = item.preservedBefore
            var preservedAfter = item.fixture.snapshotPreservedControls()
            let activationKey =
                "phone|foundryx.capture-account-activation.v2"
            preservedBefore.removeValue(forKey: activationKey)
            preservedAfter.removeValue(forKey: activationKey)
            let aliasesAfter = item.fixture.activationAliases() ?? [:]
            // `capture-account-activation.v2` is expected to change when a
            // different owner activates. The preservation oracle therefore
            // keeps its real coverage by requiring every pre-existing alias
            // mapping to remain present and byte-for-byte unmodified, while
            // comparing every other owner/phone control exactly.
            let aliasesPreserved =
                item.activationAliasesBefore.allSatisfy {
                    aliasesAfter[$0.key] == $0.value
                }
            guard preservedAfter == preservedBefore,
                  aliasesPreserved else {
                let changed = Set(preservedBefore.keys)
                    .union(preservedAfter.keys)
                    .sorted()
                    .compactMap { key -> String? in
                        let before = preservedBefore[key] ?? Data()
                        let after = preservedAfter[key] ?? Data()
                        guard before != after else { return nil }
                        return "\(key): \(String(decoding: before, as: UTF8.self))"
                            + " -> \(String(decoding: after, as: UTF8.self))"
                    }
                    .joined(separator: "; ")
                let changedAliases = item.activationAliasesBefore
                    .filter { aliasesAfter[$0.key] != $0.value }
                    .map { key, value in
                        "\(key): \(value) -> \(aliasesAfter[key] ?? "nil")"
                    }
                    .sorted()
                    .joined(separator: "; ")
                throw BrineStepError(
                    "\(label(item.point)) changed the other account after return: "
                        + [changed, changedAliases]
                            .filter { !$0.isEmpty }
                            .joined(separator: "; "))
            }
        }
    }

    func cleanup() {
        preparedFixture?.cleanup()
        preparedFixture = nil
        for item in interruptedCases {
            item.fixture.cleanup()
        }
        interruptedCases.removeAll()
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func label(_ point: DeletionFaultPoint) -> String {
        "\(point.boundary.rawValue) \(point.stage.rawValue)"
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected async expression to throw", file: file, line: line)
    } catch {}
}
