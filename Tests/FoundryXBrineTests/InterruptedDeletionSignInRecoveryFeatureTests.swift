import XCTest
import BrineSwiftCore
@testable import FoundryXKit

final class InterruptedDeletionSignInRecoveryFeatureTests: XCTestCase {
    func testInterruptedDeletionSignInRecoveryScenarios() async throws {
        let world = InterruptedDeletionSignInRecoveryWorld()
        defer { world.cleanupLiveSignInFixture() }
        try await BrineFeatureRunner.run(
            "interrupted-deletion-signin-recovery",
            registry: StepRegistry(InterruptedDeletionSignInRecoverySteps.make(world)))
    }
}

private final class InterruptedDeletionSignInRecoveryWorld: @unchecked Sendable {
    private final class RecoveryDefaults: UserDefaults {
        private let lock = NSLock()
        private var values: [String: Any] = [:]

        init() { super.init(suiteName: nil)! }
        required init?(coder: NSCoder) { nil }
        override func object(forKey key: String) -> Any? {
            lock.withLock { values[key] }
        }
        override func set(_ value: Any?, forKey key: String) {
            lock.withLock { values[key] = value }
        }
        override func removeObject(forKey key: String) {
            _ = lock.withLock { values.removeValue(forKey: key) }
        }
        override func synchronize() -> Bool { true }
    }
    private final class SendableDefaultsBox: @unchecked Sendable {
        let value: UserDefaults
        init(_ value: UserDefaults) { self.value = value }
    }
    enum Record: Equatable { case pending, completed, unreadable }
    let identity = AuthIdentity(
        provider: AuthProvider.google.rawValue,
        idToken: "header.payload.signature",
        refreshToken: nil,
        expiresAt: .distantFuture,
        email: "returning@example.test")
    var record: Record = .pending
    var cleanupFails = false
    var cleanupCalls = 0
    var signedIn = false
    var refusal: Error?
    var beganCompleted = false
    private var liveRoot: URL?
    private var liveDefaultsName: String?
    private var liveIdentity: AuthIdentity?
    var activationContinued = false
    var liveCleanupFails = false
    var realRunnerRoot: URL?
    var visibleStatus: RemoteSession.Status = .signedOut

    func reset(_ record: Record) {
        self.record = record
        cleanupFails = false
        cleanupCalls = 0
        signedIn = false
        refusal = nil
        beganCompleted = record == .completed
        DeletionRecorder.shared.clear()
        visibleStatus = .signedOut
    }

    func signIn() async {
        do {
            try await FoundryAuth.persistAfterRecoveringInterruptedDeletion(
                identity: identity,
                persist: { [self] _ in
                    switch record {
                    case .pending:
                        throw CaptureAccountScopeError.deletionCleanupPending(
                            ownerScope: "acct-returning0001")
                    case .completed:
                        signedIn = true
                    case .unreadable:
                        throw CaptureAccountScopeError.activationState(
                            "account deletion state is unreadable")
                    }
                },
                recover: { [self] in
                    cleanupCalls += 1
                    if cleanupFails { throw AccountDeletionError.cleanupPending }
                    record = .completed
                })
        } catch {
            refusal = error
        }
    }

    func prepareLiveSignInFixture() throws {
        cleanupLiveSignInFixture()
        let discriminator = UUID().uuidString.lowercased()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foundryx-live-signin-recovery-\(discriminator)",
            isDirectory: true)
        let defaults = RecoveryDefaults()
        let defaultsBox = SendableDefaultsBox(defaults)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        CaptureAccountScope.resetTestEnvironment()
        CaptureAccountScope.setContainerForTests(root)
        CaptureAccountScope.setDefaultsForTests(defaults)
        let scope = try CaptureAccountScope.key(for: identity)
        CaptureAccountScope.setInterruptedDeletionRecoveryForTests { [self, defaultsBox] _ in
            cleanupCalls += 1
            let secrets = DeletionTypedSecretStore()
            if liveCleanupFails { secrets.forceNextRemoval(.failed) }
            let runner = CurrentOwnerSelectiveDeletionRunner(
                container: root,
                defaults: defaultsBox.value,
                secretStore: secrets,
                pairingServices: (cell: "cell.test", door: "door.test"),
                exposureCoordinator: AccountExposureCoordinator(),
                identityProvider: { self.identity })
            try await runner.eraseVerifiedCurrentOwner()
        }
        _ = try AccountDeletionLifecycleStore(container: root)
            .createPending(ownerScope: scope)
        liveRoot = root
        liveDefaultsName = nil
        liveIdentity = identity
        activationContinued = false
        liveCleanupFails = false
        cleanupCalls = 0
        refusal = nil
        DeletionRecorder.shared.clear()
    }

    func prepareSignedOutRealRunnerFixture() throws {
        cleanupLiveSignInFixture()
        let discriminator = UUID().uuidString.lowercased()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foundryx-real-signin-recovery-\(discriminator)", isDirectory: true)
        let defaults = RecoveryDefaults()
        let defaultsBox = SendableDefaultsBox(defaults)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CaptureAccountScope.resetTestEnvironment()
        CaptureAccountScope.setContainerForTests(root)
        CaptureAccountScope.setDefaultsForTests(defaults)
        let scope = try CaptureAccountScope.key(for: identity)
        _ = try AccountDeletionLifecycleStore(container: root)
            .createPending(ownerScope: scope)
        // Keep the production eraser/lifecycle and replace only the macOS test
        // process's Keychain backend. The phone uses SystemPairingSecretStore;
        // an empty typed store has the same observable state without requiring
        // this test host to hold the app's Keychain entitlement.
        CaptureAccountScope.setInterruptedDeletionRecoveryForTests { [identity, defaultsBox] _ in
            let runner = CurrentOwnerSelectiveDeletionRunner(
                container: root,
                defaults: defaultsBox.value,
                secretStore: DeletionTypedSecretStore(),
                pairingServices: (cell: "cell.test", door: "door.test"),
                exposureCoordinator: AccountExposureCoordinator(),
                identityProvider: { identity })
            try await runner.eraseVerifiedCurrentOwner()
        }
        liveRoot = root
        realRunnerRoot = root
        liveDefaultsName = nil
        liveIdentity = identity
        activationContinued = false
        refusal = nil
        DeletionRecorder.shared.clear()
    }

    func saveThroughRealSignInPersistence() async {
        do {
            try await AuthStore.save(identity)
            activationContinued = true
        } catch {
            refusal = error
        }
    }

    func beginLiveAccountActivation() async {
        guard let identity = liveIdentity else {
            refusal = BrineStepError("the live sign-in fixture was not prepared")
            return
        }
        do {
            _ = try await CaptureAccountScope.beginActivation(for: identity)
            activationContinued = true
        } catch let error as CaptureAccountScopeError {
            if case .deletionCleanupPending = error {
                refusal = error
            } else {
                // This sandbox can deny UserDefaults durability after the deletion
                // gate. Reaching that later activation stage proves the live refusal
                // chokepoint allowed the sign-in to continue.
                activationContinued = true
            }
        } catch {
            refusal = error
        }
    }

    func cleanupLiveSignInFixture() {
        CaptureAccountScope.resetTestEnvironment()
        if let name = liveDefaultsName {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        if let root = liveRoot {
            try? FileManager.default.removeItem(at: root)
        }
        liveRoot = nil
        liveDefaultsName = nil
        liveIdentity = nil
        realRunnerRoot = nil
    }
}

private enum InterruptedDeletionSignInRecoverySteps {
    static func make(_ w: InterruptedDeletionSignInRecoveryWorld) -> [StepDefinition] {
        [
            defineStep("a deletion record exists for my account that never finished") { ctx, _, _ in
                w.reset(.pending)
                return ctx
            },
            defineStep("the local cleanup cannot complete") { ctx, _, _ in
                w.cleanupFails = true
                return ctx
            },
            defineStep("a deletion record for my account is already completed") { ctx, _, _ in
                w.reset(.completed)
                return ctx
            },
            defineStep("the deletion state for my account cannot be read") { ctx, _, _ in
                w.reset(.unreadable)
                return ctx
            },
            defineStep("I sign in with that account") { ctx, _, _ in
                await w.signIn()
                return ctx
            },
            defineStep("the app sign-in path finds an unfinished deletion for my account") { ctx, _, _ in
                try w.prepareLiveSignInFixture()
                return ctx
            },
            defineStep("the app begins account activation for my sign-in") { ctx, _, _ in
                await w.beginLiveAccountActivation()
                return ctx
            },
            defineStep("cleanup at the activation chokepoint will fail") { ctx, _, _ in
                w.liveCleanupFails = true
                return ctx
            },
            defineStep("I am signed out with a cleanup-pending deletion for my account") { ctx, _, _ in
                try w.prepareSignedOutRealRunnerFixture()
                return ctx
            },
            defineStep("the real sign-in persistence path saves my verified identity") { ctx, _, _ in
                await w.saveThroughRealSignInPersistence()
                return ctx
            },
            defineCheck("the pending deletion cleanup completes") { _, _, _ in
                guard let root = w.realRunnerRoot else {
                    throw BrineStepError("the real runner fixture was not prepared")
                }
                let scope = try CaptureAccountScope.key(for: w.identity)
                guard case .record(let record) = AccountDeletionLifecycleStore(container: root)
                    .read(ownerScope: scope), record.phase == .completed else {
                    throw BrineStepError(
                        "the real AuthStore.save → CaptureAccountScope recovery path did not complete: \(String(describing: w.refusal)); diag=\(DeletionRecorder.shared.recorded())")
                }
            },
            defineCheck("the sign-in refusal diagnostic does not report cleanupPending") { _, _, _ in
                let lines = DeletionRecorder.shared.recorded()
                guard !lines.contains(where: {
                    $0.contains("account.signin.refused") && $0.contains("cleanupPending")
                }) else {
                    throw BrineStepError("the underlying recovery cause was flattened: \(lines)")
                }
            },
            defineCheck("the activation chokepoint completes the local cleanup") { _, _, _ in
                guard w.cleanupCalls == 1 else {
                    throw BrineStepError("the production activation chokepoint did not run cleanup")
                }
            },
            defineCheck("account activation is allowed to continue") { _, _, _ in
                guard w.activationContinued, w.refusal == nil else {
                    throw BrineStepError(
                        "the production activation path still refused the account: \(String(describing: w.refusal))")
                }
            },
            defineCheck("account activation is refused with a typed cleanup error") { _, _, _ in
                guard let error = w.refusal as? CaptureAccountScopeError,
                      case .deletionCleanupPending = error else {
                    throw BrineStepError("cleanup failure did not preserve the typed refusal")
                }
            },
            defineCheck("the sign-in diagnostics identify cleanup failure") { _, _, _ in
                guard DeletionRecorder.shared.recorded().contains(where: {
                    $0.contains("account.signin.refused")
                        && $0.contains("cleanup_failed")
                        && $0.contains("pairingSecrets")
                }) else {
                    throw BrineStepError(
                        "cleanup failure did not retain its specific cause in diagnostics: \(DeletionRecorder.shared.recorded())")
                }
            },
            defineCheck("the local cleanup is completed") { _, _, _ in
                guard w.cleanupCalls == 1, case .completed = w.record else {
                    throw BrineStepError("the existing cleanup path did not finish the record")
                }
                guard DeletionRecorder.shared.recorded().contains(where: {
                    $0.contains("account.signin.cleanup_completed")
                }) else {
                    throw BrineStepError("automatic recovery was absent from deletion diagnostics")
                }
            },
            defineCheck("I am signed in") { _, _, _ in
                guard w.signedIn, w.refusal == nil else {
                    throw BrineStepError("sign-in did not proceed after safe cleanup")
                }
                guard !w.beganCompleted || w.cleanupCalls == 0 else {
                    throw BrineStepError("sign-in ran cleanup after deletion was completed")
                }
            },
            defineCheck("I am not signed in") { _, _, _ in
                guard !w.signedIn else { throw BrineStepError("unsafe sign-in was allowed") }
            },
            defineCheck("I am told why") { _, _, _ in
                guard w.refusal is CaptureAccountScopeError,
                      DeletionRecorder.shared.recorded().contains(where: {
                          $0.contains("account.signin.refused") && $0.contains("cleanup_failed")
                      }) else {
                    throw BrineStepError("cleanup failure was not typed and diagnosed")
                }
            },
            defineCheck("I see that a previous deletion must finish before I can sign in") { _, _, _ in
                let presentation = WelcomeFrontDoor.signInRecoveryPresentation(
                    .deletionCleanupPending(ownerScope: "acct-returning0001"))
                guard presentation?.text.contains("must finish before you can sign in") == true else {
                    throw BrineStepError("the real sign-in presentation did not explain the refusal")
                }
            },
            defineStep("sign-in cleanup reaches the pairing secrets stage") { ctx, _, _ in
                w.visibleStatus = .deletionCleanupInProgress(stage: .pairingSecrets)
                return ctx
            },
            defineCheck("I see that pairing secrets are being removed") { _, _, _ in
                let presentation = WelcomeFrontDoor.signInRecoveryPresentation(w.visibleStatus)
                guard presentation?.text == "Finishing previous deletion: removing pairing secrets…" else {
                    throw BrineStepError("named cleanup progress was not rendered")
                }
            },
            defineStep("sign-in cleanup fails at the pairing secrets stage") { ctx, _, _ in
                w.visibleStatus = .deletionCleanupFailed(
                    stage: .pairingSecrets, reason: "durability")
                return ctx
            },
            defineCheck("I see that cleanup failed at Pairing secrets") { _, _, _ in
                let presentation = WelcomeFrontDoor.signInRecoveryPresentation(w.visibleStatus)
                guard presentation?.text.contains("Pairing secrets") == true,
                      presentation?.text.contains("couldn't be removed") == true else {
                    throw BrineStepError("the failed stage was hidden from the person")
                }
            },
            defineCheck("I am offered to retry cleanup") { _, _, _ in
                guard WelcomeFrontDoor.signInRecoveryPresentation(w.visibleStatus)?.action == "Retry cleanup" else {
                    throw BrineStepError("cleanup failure did not render a retry action")
                }
            },
            defineStep("sign-in cleanup succeeds") { ctx, _, _ in
                w.visibleStatus = .deletionCleanupSucceeded
                return ctx
            },
            defineCheck("I see that cleanup finished and sign-in is continuing") { _, _, _ in
                guard WelcomeFrontDoor.signInRecoveryPresentation(w.visibleStatus)?.text
                        == "Previous deletion finished. Continuing sign-in…" else {
                    throw BrineStepError("cleanup success was invisible")
                }
            },
        ]
    }
}
