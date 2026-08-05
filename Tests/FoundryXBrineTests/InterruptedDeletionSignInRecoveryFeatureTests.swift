import XCTest
import BrineSwiftCore
@testable import FoundryXKit

final class InterruptedDeletionSignInRecoveryFeatureTests: XCTestCase {
    func testInterruptedDeletionSignInRecoveryScenarios() async throws {
        let world = InterruptedDeletionSignInRecoveryWorld()
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
