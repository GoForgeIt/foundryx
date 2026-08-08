import XCTest
@testable import FoundryXKit
import BrineSwiftCore

final class AccountDeletionWidgetBarrierFeatureTests: XCTestCase {
    fileprivate final class World: @unchecked Sendable {
        var fixture: WidgetDeletionFixture?
        var result: Result<AccountDeletionLifecycleRecord, Error>?

        func reset(_ mode: WidgetDeletionFixture.Mode) throws {
            fixture?.cleanup()
            fixture = try WidgetDeletionFixture(mode: mode)
            result = nil
        }
    }

    func testAccountDeletionWidgetBarrierScenarios() async throws {
        let world = World()
        defer { world.fixture?.cleanup() }

        try await BrineFeatureRunner.run(
            "account-deletion-widget-barrier",
            registry: StepRegistry([
                defineStep("the widget belongs to another live account") { ctx, _, _ in
                    try world.reset(.otherAccountPayload)
                    return ctx
                },
                defineStep("the widget owner tag names another account but the payload belongs to my account") { ctx, _, _ in
                    try world.reset(.staleTagForDeletedPayload)
                    return ctx
                },
                defineStep("the widget store cannot prove a durable withdrawal") { ctx, _, _ in
                    try world.reset(.persistenceFailure)
                    return ctx
                },
                defineStep("I delete my account") { ctx, _, _ in
                    guard let fixture = world.fixture else {
                        throw BrineStepError("missing deletion fixture")
                    }
                    do {
                        world.result = .success(
                            try await fixture.lifecycle.begin(binding: fixture.deletedBinding))
                    } catch {
                        world.result = .failure(error)
                    }
                    return ctx
                },
                defineCheck("my deletion completes") { _, _, _ in
                    guard case .success(let record) = world.result,
                          record.phase == .completed else {
                        throw BrineStepError("deletion did not complete: \(String(describing: world.result))")
                    }
                },
                defineCheck("the other account's widget payload remains readable") { _, _, _ in
                    guard CaptureWidgetSnapshotStore.read().lastFinishedTitle == "Other account note" else {
                        throw BrineStepError("the live account's widget payload was damaged")
                    }
                },
                defineCheck("no widget payload belonging to my deleted account is readable") { _, _, _ in
                    guard CaptureWidgetSnapshotStore.read().lastFinishedTitle == nil else {
                        throw BrineStepError("the deleted account's widget payload remains readable")
                    }
                },
                defineCheck("deletion remains incomplete") { _, _, _ in
                    guard case .failure(let error) = world.result,
                          error as? AccountDeletionLifecycleError == .exposureBarrierFailed else {
                        throw BrineStepError("persistence failure did not fail closed")
                    }
                },
                defineCheck("I can continue from the front door with a recovery action") { _, _, _ in
                    let presentation = WelcomeFrontDoor.signInRecoveryPresentation(
                        .deletionCleanupFailed(stage: .widgetWithdrawal, reason: "persistenceFailed"))
                    guard presentation?.action == "Retry cleanup" else {
                        throw BrineStepError("no front-door recovery action was available")
                    }
                },
            ]))
    }
}

fileprivate final class WidgetDeletionFixture: @unchecked Sendable {
    enum Mode { case otherAccountPayload, staleTagForDeletedPayload, persistenceFailure }

    let root: URL
    let defaultsName: String
    let defaults: UserDefaults
    let deletedBinding: CaptureAccountScope.AccountBinding
    let lifecycle: AccountDeletionLifecycle

    init(mode: Mode) throws {
        let discriminator = UUID().uuidString.lowercased()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foundryx-widget-deletion-\(discriminator)", isDirectory: true)
        defaultsName = "foundryx.widget-deletion.\(discriminator)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CaptureWidgetSnapshotStore.setDefaultsForTesting(defaults)

        deletedBinding = .init(
            root: root.appendingPathComponent("acct-de1e7ed000000001"),
            scope: "acct-de1e7ed000000001", generation: 1)
        let otherScope = "acct-07ae000000000001"
        defaults.set(otherScope, forKey: CaptureWidgetSnapshotStore.activeOwnerKey)
        let payloadOwner = mode == .otherAccountPayload ? otherScope : deletedBinding.scope
        let snapshot = CaptureWidgetSnapshot(
            phase: .idle,
            lastFinishedTitle: mode == .otherAccountPayload ? "Other account note" : "Deleted account note")
        defaults.set(
            try JSONEncoder().encode(CaptureWidgetSnapshotStore.Envelope(
                owner: payloadOwner, snapshot: snapshot)),
            forKey: CaptureWidgetSnapshotStore.key)
        if mode == .persistenceFailure {
            defaults.set(deletedBinding.scope, forKey: CaptureWidgetSnapshotStore.activeOwnerKey)
            CaptureWidgetSnapshotStore.setWithdrawalFaultForTesting(.synchronizeFailure)
        }

        let store = AccountDeletionLifecycleStore(container: root)
        let expectedBinding = deletedBinding
        lifecycle = AccountDeletionLifecycle(
            store: store,
            environment: AccountDeletionLifecycleEnvironment(
                verifyCurrentBinding: { $0 == expectedBinding },
                blockResolution: { $0.generation + 1 },
                deliverIdentityBoundary: { _ in },
                setSignedInMirrorFalse: { _ in },
                withdrawWidget: { binding in
                    switch CaptureWidgetSnapshotStore.withdraw(expectedOwner: binding.scope) {
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
                legacyOwnerScope: { nil }))
    }

    func cleanup() {
        CaptureWidgetSnapshotStore.resetDefaultsForTesting()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
