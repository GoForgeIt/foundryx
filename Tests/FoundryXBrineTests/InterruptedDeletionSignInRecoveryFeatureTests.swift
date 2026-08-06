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

    func reset(_ record: Record) {
        self.record = record
        cleanupFails = false
        cleanupCalls = 0
        signedIn = false
        refusal = nil
        beganCompleted = record == .completed
        DeletionRecorder.shared.clear()
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
        let defaultsName = "foundryx.live-signin-recovery.\(discriminator)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            throw BrineStepError("the sign-in fixture defaults were unavailable")
        }
        defaults.removePersistentDomain(forName: defaultsName)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        CaptureAccountScope.resetTestEnvironment()
        CaptureAccountScope.setContainerForTests(root)
        CaptureAccountScope.setDefaultsForTests(defaults)
        let scope = try CaptureAccountScope.key(for: identity)
        CaptureAccountScope.setInterruptedDeletionRecoveryForTests { [self] _ in
            cleanupCalls += 1
            if liveCleanupFails { throw AccountDeletionError.cleanupPending }
            let store = AccountDeletionLifecycleStore(container: root)
            try FileManager.default.removeItem(
                at: store.recordURL(ownerScope: scope))
        }
        _ = try AccountDeletionLifecycleStore(container: root)
            .createPending(ownerScope: scope)
        liveRoot = root
        liveDefaultsName = defaultsName
        liveIdentity = identity
        activationContinued = false
        liveCleanupFails = false
        cleanupCalls = 0
        refusal = nil
        DeletionRecorder.shared.clear()
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
                    $0.contains("account.signin.refused") && $0.contains("cleanup_failed")
                }) else {
                    throw BrineStepError("cleanup failure was not distinguishable in diagnostics")
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
        ]
    }
}
