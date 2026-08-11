import XCTest
@testable import FoundryXKit
import BrineSwiftCore

/// `features/deletion-is-not-blocked-by-an-absent-surface.feature`.
///
/// Every step drives the REAL `AccountExposureCoordinator` (real weak
/// registrations, real deallocation) and the REAL `AccountDeletionLifecycle`.
/// The only injected seams are the destructive edges — durable store, cleanup
/// groups — so an absent participant is measured exactly as it is in the app.
final class AbsentSurfaceDeletionFeatureTests: XCTestCase {
    fileprivate final class World: @unchecked Sendable {
        var fixture: AbsentSurfaceDeletionFixture?
        var result: Result<AccountDeletionLifecycleRecord, Error>?
        var barrierSatisfied: Bool?
        var pieces: [AccountExposureCloseResult] = []
        var foldedAnswer: AccountExposureCloseResult?

        func reset(
            _ participant: AbsentSurfaceDeletionFixture.Participant
        ) throws {
            fixture?.cleanup()
            fixture = try AbsentSurfaceDeletionFixture(participant: participant)
            result = nil
            barrierSatisfied = nil
        }

        func require() throws -> AbsentSurfaceDeletionFixture {
            guard let fixture else {
                throw BrineStepError("no deletion fixture was prepared")
            }
            return fixture
        }
    }

    func testAbsentSurfaceDeletionScenarios() async throws {
        let world = World()
        defer { world.fixture?.cleanup() }

        try await BrineFeatureRunner.run(
            "deletion-is-not-blocked-by-an-absent-surface",
            registry: StepRegistry([
                defineStep("a part of the app that must close on deletion has already been released") { ctx, _, _ in
                    try world.reset(.deallocatedOwner)
                    return ctx
                },
                defineStep("a part of the app that must close on deletion was never attached to any account") { ctx, _, _ in
                    try world.reset(.neverBound)
                    return ctx
                },
                defineStep("a part of the app cannot confirm that it closed") { ctx, _, _ in
                    try world.reset(.answers(.verificationFailed))
                    return ctx
                },
                defineStep("a part of the app could not durably record that it closed") { ctx, _, _ in
                    try world.reset(.answers(.persistenceFailed))
                    return ctx
                },
                defineStep("a part of the app is still bound to an earlier version of my account") { ctx, _, _ in
                    try world.reset(.staleGeneration(answers: .closed))
                    return ctx
                },
                defineStep("a part of the app is still bound to an earlier version of my account and cannot confirm that it closed") { ctx, _, _ in
                    try world.reset(.staleGeneration(answers: .verificationFailed))
                    return ctx
                },
                defineStep("a second copy of the same part of the app is still registered from before I signed in") { ctx, _, _ in
                    try world.reset(.duplicateFromEarlierGeneration)
                    return ctx
                },
                defineStep("a part of the app is bound to a different account") { ctx, _, _ in
                    try world.reset(.otherAccount)
                    return ctx
                },
                defineStep("I delete everything now") { ctx, _, _ in
                    let fixture = try world.require()
                    do {
                        world.result = .success(
                            try await fixture.lifecycle.begin(
                                binding: fixture.binding))
                    } catch {
                        world.result = .failure(error)
                    }
                    return ctx
                },
                defineStep("a part of the app has one piece that is gone and one that cannot confirm it closed") { ctx, _, _ in
                    // Gone FIRST, so answering in arrival order would report the
                    // absence and lose the refusal behind it.
                    world.pieces = [.unavailable, .verificationFailed]
                    return ctx
                },
                defineStep("a part of the app has only pieces that are gone") { ctx, _, _ in
                    world.pieces = [.unavailable, .unavailable]
                    return ctx
                },
                defineStep("that part answers for all of its pieces") { ctx, _, _ in
                    world.foldedAnswer = AccountExposureCloseResult.aggregate(
                        world.pieces)
                    return ctx
                },
                defineCheck("it reports that it cannot confirm it closed") { _, _, _ in
                    guard world.foldedAnswer == .verificationFailed else {
                        throw BrineStepError(
                            "a refusal was laundered into \(String(describing: world.foldedAnswer))")
                    }
                },
                defineCheck("it reports that there is nothing there") { _, _, _ in
                    guard world.foldedAnswer == .unavailable else {
                        throw BrineStepError(
                            "an all-absent part answered \(String(describing: world.foldedAnswer))")
                    }
                },
                defineStep("the deletion barrier verifies what every part answered") { ctx, _, _ in
                    let fixture = try world.require()
                    let live = await fixture.coordinator
                        .closeRegisteredExposures(expected: fixture.binding)
                    let stale = await fixture.coordinator
                        .cancelRegisteredStaleWork(expected: fixture.binding)
                    guard !(live + stale).isEmpty else {
                        throw BrineStepError(
                            "the barrier was asked about no participants at all")
                    }
                    world.barrierSatisfied = AccountExposureBarrier.isSatisfied(
                        live: live, stale: stale)
                    return ctx
                },
                defineCheck("my deletion finishes") { _, _, _ in
                    guard case .success(let record) = world.result,
                          record.phase == .completed else {
                        throw BrineStepError(
                            "deletion did not finish: \(String(describing: world.result))")
                    }
                },
                defineCheck("my deletion does not finish") { _, _, _ in
                    guard case .failure(let error) = world.result,
                          error as? AccountDeletionLifecycleError
                            == .exposureBarrierFailed else {
                        throw BrineStepError(
                            "an unprovable participant did not fail closed: \(String(describing: world.result))")
                    }
                },
                defineCheck("every erase step runs") { _, _, _ in
                    let fixture = try world.require()
                    guard fixture.cleanedGroups
                        == AccountDeletionCleanupGroup.allCases else {
                        throw BrineStepError(
                            "erase steps were skipped: \(fixture.cleanedGroups)")
                    }
                },
                defineCheck("no erase step runs") { _, _, _ in
                    let fixture = try world.require()
                    guard fixture.cleanedGroups.isEmpty else {
                        throw BrineStepError(
                            "a blocked deletion still erased: \(fixture.cleanedGroups)")
                    }
                },
                defineCheck("my account stays closed until every erase step finishes") { _, _, _ in
                    let fixture = try world.require()
                    guard fixture.store.read(ownerScope: fixture.binding.scope)
                        .record?.phase == .cleanupPending else {
                        throw BrineStepError(
                            "a blocked deletion did not stay pending")
                    }
                },
                defineCheck("the barrier is satisfied") { _, _, _ in
                    guard world.barrierSatisfied == true else {
                        throw BrineStepError(
                            "barrier verification refused an absent participant")
                    }
                },
                defineCheck("the barrier is not satisfied") { _, _, _ in
                    guard world.barrierSatisfied == false else {
                        throw BrineStepError(
                            "barrier verification accepted a participant that could not prove it closed")
                    }
                },
                // "It did not block me" is not the same claim as "it was closed".
                // Without these two the coordinator could pass every scenario
                // above by never asking anyone anything.
                defineCheck("that part was asked to close") { _, _, _ in
                    let fixture = try world.require()
                    guard fixture.participantWasAsked else {
                        throw BrineStepError(
                            "a participant holding this account's data was never asked to close")
                    }
                },
                defineCheck("that part was not asked to close") { _, _, _ in
                    let fixture = try world.require()
                    guard !fixture.participantWasAsked else {
                        throw BrineStepError(
                            "another account's participant was asked to close this account's surface")
                    }
                },
            ]))
    }
}

/// Retains nothing the fixture does not want retained: `Participant.deallocatedOwner`
/// deliberately drops its owner so the registration's weak hook answers
/// `.unavailable` the way a released screen does in the app.
private final class ScriptedExposureOwner: @unchecked Sendable {
    let answer: AccountExposureCloseResult
    init(_ answer: AccountExposureCloseResult) { self.answer = answer }
}

fileprivate final class AbsentSurfaceDeletionFixture: @unchecked Sendable {
    enum Participant {
        /// The registered owner has been deallocated — nothing left to render.
        case deallocatedOwner
        /// Registered but never bound to any account — never held this data.
        case neverBound
        /// Bound to an earlier generation of the SAME account, so it may still be
        /// holding this account's data and must be asked to close.
        case staleGeneration(answers: AccountExposureCloseResult)
        /// Two live registrations sharing one participant ID, one of them left
        /// over from the generation before the person signed in — exactly what a
        /// `MainTabs` remount leaves behind.
        case duplicateFromEarlierGeneration
        /// Bound to a DIFFERENT account. Nothing of this account is here.
        case otherAccount
        /// The participant is live and answers for itself.
        case answers(AccountExposureCloseResult)
    }

    private let state = State()
    let root: URL
    let binding: CaptureAccountScope.AccountBinding
    let coordinator = AccountExposureCoordinator()
    let store: AccountDeletionLifecycleStore
    let lifecycle: AccountDeletionLifecycle

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var groups: [AccountDeletionCleanupGroup] = []
        private var asked = false
        /// Retained ONLY for the cases that are supposed to still exist.
        var retained: [AnyObject] = []
        var registrations: [AccountExposureRegistration] = []

        func record(_ group: AccountDeletionCleanupGroup) {
            lock.withLock { groups.append(group) }
        }

        func markAsked() { lock.withLock { asked = true } }

        var wasAsked: Bool { lock.withLock { asked } }

        var cleaned: [AccountDeletionCleanupGroup] {
            lock.withLock { groups }
        }
    }

    var cleanedGroups: [AccountDeletionCleanupGroup] { state.cleaned }
    var participantWasAsked: Bool { state.wasAsked }

    init(participant: Participant) throws {
        let discriminator = UUID().uuidString.lowercased()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foundryx-absent-surface-\(discriminator)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let scope = "acct-ab5e07000000000f"
        binding = .init(
            root: root.appendingPathComponent(scope),
            scope: scope,
            generation: 4)
        store = AccountDeletionLifecycleStore(container: root)

        let expected = binding
        let state = self.state
        let coordinator = self.coordinator
        lifecycle = AccountDeletionLifecycle(
            store: store,
            environment: AccountDeletionLifecycleEnvironment(
                verifyCurrentBinding: { $0 == expected },
                blockResolution: { $0.generation + 1 },
                deliverIdentityBoundary: { _ in },
                setSignedInMirrorFalse: { _ in },
                withdrawWidget: { _ in .alreadyClosed },
                closeLiveExposures: { binding in
                    await coordinator.closeRegisteredExposures(expected: binding)
                },
                cancelStaleWork: { binding in
                    await coordinator.cancelRegisteredStaleWork(expected: binding)
                },
                // The production rule, not a restatement of it.
                verifyExposureBarrier: { live, stale in
                    AccountExposureBarrier.isSatisfied(live: live, stale: stale)
                },
                removeGroup: { group, _, _ in state.record(group) },
                verifyGroupAbsent: { _, _ in true },
                legacyOwnerScope: { nil }))

        install(participant)
    }

    /// The coordinator holds registrations weakly, so the fixture retains each
    /// one. It retains the OWNER only when the scenario says the owner is still
    /// alive — `.deallocatedOwner` deliberately keeps none.
    private func install(_ participant: Participant) {
        switch participant {
        case .deallocatedOwner:
            // Built in its own scope so the strong owner reference dies when that
            // scope returns. The registration's weak reference is nil by the time
            // the barrier asks — exactly a screen torn down before deletion ran.
            add(Self.registrationWithReleasedOwner(
                binding: binding, state: state))
        case .neverBound:
            add(registration(
                id: "never-bound-live-exposure",
                binding: nil,
                answer: .closed))
        case .staleGeneration(let answer):
            add(registration(
                id: "stale-generation-live-exposure",
                binding: earlierGeneration,
                answer: answer))
        case .duplicateFromEarlierGeneration:
            // SAME participant ID, two live registrations. The coordinator
            // dedupes by object identity, so both really are asked.
            add(registration(
                id: "capture-manager",
                binding: earlierGeneration,
                answer: .closed))
            add(registration(
                id: "capture-manager",
                binding: binding,
                answer: .closed))
        case .otherAccount:
            add(registration(
                id: "other-account-live-exposure",
                binding: CaptureAccountScope.AccountBinding(
                    root: binding.root.deletingLastPathComponent()
                        .appendingPathComponent("acct-00000000000000ff"),
                    scope: "acct-00000000000000ff",
                    generation: binding.generation),
                answer: .closed))
        case .answers(let answer):
            add(registration(
                id: "live-exposure",
                binding: binding,
                answer: answer))
        }
    }

    private var earlierGeneration: CaptureAccountScope.AccountBinding {
        CaptureAccountScope.AccountBinding(
            root: binding.root,
            scope: binding.scope,
            generation: binding.generation - 1)
    }

    private func registration(
        id: String,
        binding: CaptureAccountScope.AccountBinding?,
        answer: AccountExposureCloseResult
    ) -> AccountExposureRegistration {
        let owner = ScriptedExposureOwner(answer)
        let state = self.state
        state.retained.append(owner)
        return AccountExposureRegistration(
            participantID: id,
            kind: .live,
            binding: binding,
            owner: owner,
            close: { owner, _ in
                state.markAsked()
                return owner.answer
            })
    }

    private func add(_ registration: AccountExposureRegistration) {
        state.registrations.append(registration)
        coordinator.register(registration)
    }

    private static func registrationWithReleasedOwner(
        binding: CaptureAccountScope.AccountBinding,
        state: State
    ) -> AccountExposureRegistration {
        let owner = ScriptedExposureOwner(.closed)
        return AccountExposureRegistration(
            participantID: "released-live-exposure",
            kind: .live,
            binding: binding,
            owner: owner,
            close: { owner, _ in
                state.markAsked()
                return owner.answer
            })
    }

    func cleanup() {
        state.retained.removeAll()
        state.registrations.removeAll()
        try? FileManager.default.removeItem(at: root)
    }
}
