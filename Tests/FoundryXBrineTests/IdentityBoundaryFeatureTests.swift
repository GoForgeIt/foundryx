import XCTest
@testable import FoundryXKit
import BrineSwiftCore

final class IdentityBoundaryFeatureTests: XCTestCase {
    fileprivate final class World: @unchecked Sendable {
        var fixture: IdentityBoundaryFixture?
        var firstBinding: CaptureAccountScope.AccountBinding?
        var secondBinding: CaptureAccountScope.AccountBinding?
        var deletionResult: Result<AccountDeletionLifecycleRecord, Error>?
        var eraseOutcomes: [AccountSurfaceID: AccountSurfaceOutcome] = [:]
        var credentialPresent = false
        var liveActivityPresent = false
        var returnedBinding: CaptureAccountScope.AccountBinding?
        var provisioningRequested = false
        var racePassed = false
        var signOutError: Error?

        func reset() throws {
            fixture?.cleanup()
            fixture = try IdentityBoundaryFixture(world: self)
            firstBinding = nil
            secondBinding = nil
            deletionResult = nil
            eraseOutcomes = [:]
            credentialPresent = false
            liveActivityPresent = false
            returnedBinding = nil
            provisioningRequested = false
            racePassed = false
            signOutError = nil
        }

        func requireFixture() throws -> IdentityBoundaryFixture {
            guard let fixture else { throw BrineStepError("identity fixture is missing") }
            return fixture
        }
    }

    func testIdentityBoundaryScenarios() async throws {
        let world = World()
        defer { world.fixture?.cleanup() }

        try await BrineFeatureRunner.run(
            "identity-boundary",
            registry: StepRegistry([
                defineStep("I am signed in and my widget shows my account") { ctx, _, _ in
                    try world.reset()
                    let fixture = try world.requireFixture()
                    world.firstBinding = try fixture.activate(subject: "first")
                    world.credentialPresent = true
                    try fixture.seedWidget(owner: world.firstBinding!, title: "First note")
                    return ctx
                },
                defineStep("I sign out") { ctx, _, _ in
                    do { try FoundryAuth().signOut() } catch { world.signOutError = error }
                    return ctx
                },
                defineCheck("the widget shows no account or capture from my previous account") { _, _, _ in
                    guard let first = world.firstBinding,
                          CaptureWidgetSnapshotStore.activeOwnerForTests != first.scope,
                          CaptureWidgetSnapshotStore.read().lastFinishedTitle == nil else {
                        throw BrineStepError("the previous account remains on the widget")
                    }
                },
                defineStep("the widget has a capture from my first account") { ctx, _, _ in
                    try world.reset()
                    let fixture = try world.requireFixture()
                    world.firstBinding = try fixture.activate(subject: "first")
                    world.credentialPresent = true
                    try fixture.seedWidget(owner: world.firstBinding!, title: "First note")
                    return ctx
                },
                defineStep("I sign out and sign in as a second account") { ctx, _, _ in
                    let fixture = try world.requireFixture()
                    _ = AccountSurfaceRegistry.detachAll(
                        previous: world.firstBinding, defaults: fixture.defaults)
                    try FoundryAuth().signOut()
                    world.secondBinding = try fixture.activate(subject: "second")
                    return ctx
                },
                defineCheck("the widget belongs to my second account") { _, _, _ in
                    guard CaptureWidgetSnapshotStore.activeOwnerForTests == world.secondBinding?.scope else {
                        throw BrineStepError("the widget did not attach to the second account")
                    }
                },
                defineCheck("the first account's capture is not readable from the widget") { _, _, _ in
                    guard CaptureWidgetSnapshotStore.read().lastFinishedTitle != "First note" else {
                        throw BrineStepError("the first account's snapshot crossed accounts")
                    }
                },
                defineStep("work started under my old account is still finishing") { ctx, _, _ in
                    try world.reset()
                    return ctx
                },
                defineStep("I switch to a new account before that work finishes") { ctx, _, _ in
                    let fixture = try world.requireFixture()
                    world.racePassed = try await withCheckedThrowingContinuation {
                        continuation in
                        DispatchQueue.global().async {
                            continuation.resume(with: Result {
                                try fixture.runOldReaderRace()
                            })
                        }
                    }
                    return ctx
                },
                defineCheck("the widget shows only my new account after the old work finishes") { _, _, _ in
                    guard world.racePassed else {
                        throw BrineStepError("old work re-stamped the widget")
                    }
                },
                defineStep("my account is present on every account-bearing surface") { ctx, _, _ in
                    try world.reset()
                    let fixture = try world.requireFixture()
                    world.firstBinding = try fixture.activate(subject: "delete-me", activatePreferences: true)
                    world.credentialPresent = true
                    world.liveActivityPresent = true
                    fixture.seedDeviceGlobalState()
                    try fixture.seedAccountRoot(world.firstBinding!)
                    return ctx
                },
                defineStep("another account owns the widget") { ctx, _, _ in
                    try world.requireFixture().seedOtherAccountWidget()
                    return ctx
                },
                defineStep("I delete my account now") { ctx, _, _ in
                    let fixture = try world.requireFixture()
                    guard let binding = world.firstBinding else {
                        throw BrineStepError("deletion has no captured binding")
                    }
                    do {
                        let record = try await fixture.deletionLifecycle(binding: binding).begin(binding: binding)
                        world.deletionResult = .success(record)
                        world.eraseOutcomes = fixture.lastEraseOutcomes
                    } catch {
                        world.deletionResult = .failure(error)
                    }
                    return ctx
                },
                defineCheck("deletion completes") { _, _, _ in
                    guard case .success(let record) = world.deletionResult,
                          record.phase == .completed else {
                        throw BrineStepError("deletion did not complete: \(String(describing: world.deletionResult))")
                    }
                },
                defineCheck("my deleted account is absent from every erasable surface") { _, _, _ in
                    let fixture = try world.requireFixture()
                    guard !world.credentialPresent,
                          !world.liveActivityPresent,
                          fixture.deviceGlobalStateIsAbsent,
                          world.eraseOutcomes.values.allSatisfy(\.isTerminalSuccess),
                          world.firstBinding.map({ !FileManager.default.fileExists(atPath: $0.root.path) }) == true else {
                        throw BrineStepError("an erasable surface retained the deleted account")
                    }
                },
                defineCheck("the other account's widget remains readable") { _, _, _ in
                    guard CaptureWidgetSnapshotStore.read().lastFinishedTitle == "Other note" else {
                        throw BrineStepError("deletion damaged the other account's widget")
                    }
                },
                defineStep("my account has a saved sign-in credential") { ctx, _, _ in
                    if world.fixture == nil {
                        try world.reset()
                        world.firstBinding = try world.requireFixture().activate(subject: "credential-owner")
                    }
                    world.credentialPresent = true
                    return ctx
                },
                defineCheck("no sign-in credential for my deleted account remains on the device") { _, _, _ in
                    guard !world.credentialPresent else {
                        throw BrineStepError("the deleted credential remains")
                    }
                },
                defineStep("my account deletion completed on this device") { ctx, _, _ in
                    try world.reset()
                    let fixture = try world.requireFixture()
                    let binding = try fixture.activate(subject: "returning", activatePreferences: true)
                    world.firstBinding = binding
                    _ = AccountClient.completeSignupPost(
                        succeeded: true, generation: binding.generation)
                    let record = try await fixture.deletionLifecycle(binding: binding).begin(binding: binding)
                    guard record.phase == .completed else {
                        throw BrineStepError("fixture deletion did not complete")
                    }
                    return ctx
                },
                defineStep("I sign up again with the deleted account") { ctx, _, _ in
                    let fixture = try world.requireFixture()
                    try CaptureAccountScope.signOutForTests()
                    world.returnedBinding = try fixture.activate(
                        subject: "returning", activatePreferences: true)
                    if let binding = world.returnedBinding {
                        world.provisioningRequested = AccountClient.shouldPostSignup(
                            generation: binding.generation)
                    }
                    return ctx
                },
                defineCheck("the account is admitted as a returning account") { _, _, _ in
                    guard world.returnedBinding?.isCurrent == true else {
                        throw BrineStepError("completed deletion did not admit the returning account")
                    }
                },
                defineCheck("provisioning is requested again") { _, _, _ in
                    guard world.provisioningRequested else {
                        throw BrineStepError("returning account kept the old signup marker")
                    }
                },
                defineStep("an identity change is in flight") { ctx, _, _ in
                    try world.reset()
                    let fixture = try world.requireFixture()
                    _ = try fixture.activate(subject: "old")
                    _ = try CaptureAccountScope.beginActivationForTestsOnly(
                        for: fixture.identity(subject: "new"))
                    return ctx
                },
                defineCheck("I am signed out") { _, _, _ in
                    guard world.signOutError == nil,
                          !CaptureAccountScope.hasPersistedActiveScope else {
                        throw BrineStepError("sign-out was refused during the identity change")
                    }
                },
                defineCheck("no sign-in credential for my account remains on the device") { _, _, _ in
                    guard !world.credentialPresent else {
                        throw BrineStepError("sign-out left the saved credential")
                    }
                },
                defineStep("my account has a lock-screen capture card") { ctx, _, _ in
                    try world.reset()
                    world.firstBinding = try world.requireFixture().activate(subject: "live-card")
                    world.credentialPresent = true
                    world.liveActivityPresent = true
                    return ctx
                },
                defineCheck("no lock-screen capture card from my previous account remains") { _, _, _ in
                    guard !world.liveActivityPresent else {
                        throw BrineStepError("the previous account's Live Activity remains")
                    }
                },
                defineStep("I am signed in with a saved Omi pairing") { ctx, _, _ in
                    try world.reset()
                    let fixture = try world.requireFixture()
                    world.firstBinding = try fixture.activate(subject: "omi-owner")
                    world.credentialPresent = true
                    fixture.seedDeviceGlobalState()
                    return ctx
                },
                defineStep("I am signed in with device pairings") { ctx, _, _ in
                    try world.reset()
                    let fixture = try world.requireFixture()
                    world.firstBinding = try fixture.activate(subject: "pairing-owner")
                    world.credentialPresent = true
                    fixture.seedDeviceGlobalState()
                    return ctx
                },
                defineStep("erasing the identity credential will fail") { ctx, _, _ in
                    AuthStore.setIdentityEraseForTests { .failed("injected Keychain failure") }
                    return ctx
                },
                defineCheck("my Omi pairing remains available for the next sign-in") { _, _, _ in
                    guard try world.requireFixture().omiPairingIsPresent else {
                        throw BrineStepError("sign-out forgot the saved Omi pairing")
                    }
                },
                defineCheck("my account remains signed in") { _, _, _ in
                    guard world.signOutError != nil,
                          world.credentialPresent,
                          CaptureAccountScope.currentAccountBinding()?.scope == world.firstBinding?.scope else {
                        throw BrineStepError("failed sign-out did not restore the signed-in account")
                    }
                },
                defineCheck("my device pairings remain available") { _, _, _ in
                    guard try world.requireFixture().deviceGlobalStateIsPresent else {
                        throw BrineStepError("failed sign-out destroyed device pairing state")
                    }
                },
                defineStep("my first account paired a recording device") { ctx, _, _ in
                    try world.reset()
                    let fixture = try world.requireFixture()
                    world.firstBinding = try fixture.activate(subject: "hardware-owner")
                    fixture.seedDeviceGlobalState()
                    return ctx
                },
                defineCheck("the second account does not reconnect to the first account's recording device") { _, _, _ in
                    let fixture = try world.requireFixture()
                    guard fixture.omiPairingIsPresent,
                          fixture.deviceReconnectStateIsAbsent else {
                        throw BrineStepError("the second account inherited the first account's paired device")
                    }
                },
            ]))
    }
}

private final class IdentityBoundaryFixture: @unchecked Sendable {
    let root: URL
    let defaultsName: String
    let defaults: UserDefaults
    unowned let world: IdentityBoundaryFeatureTests.World
    private(set) var lastEraseOutcomes: [AccountSurfaceID: AccountSurfaceOutcome] = [:]

    init(world: IdentityBoundaryFeatureTests.World) throws {
        self.world = world
        let token = UUID().uuidString.lowercased()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foundryx-identity-boundary-\(token)", isDirectory: true)
        defaultsName = "foundryx.identity-boundary.\(token)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CaptureAccountScope.resetTestEnvironment()
        CaptureAccountScope.setContainerForTests(root)
        CaptureAccountScope.setDefaultsForTests(defaults)
        CaptureWidgetSnapshotStore.setDefaultsForTesting(defaults)
        AuthStore.setIdentityEraseForTests { [weak world] in
            guard let world else { return .alreadyClean }
            if world.credentialPresent {
                world.credentialPresent = false
                return .done
            }
            return .alreadyClean
        }
        AccountLiveActivityBoundary.endAllForTests = { [weak world] in
            guard let world else { return .alreadyClean }
            if world.liveActivityPresent {
                world.liveActivityPresent = false
                return .done
            }
            return .alreadyClean
        }
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
            refreshToken: "refresh-\(subject)",
            expiresAt: .distantFuture,
            email: "\(subject)@example.test")
    }

    func activate(
        subject: String,
        activatePreferences: Bool = false
    ) throws -> CaptureAccountScope.AccountBinding {
        try CaptureAccountScope.activateForTests(
            identity(subject: subject), activatePreferences: activatePreferences)
        return try XCTUnwrap(CaptureAccountScope.currentAccountBinding())
    }

    func seedWidget(
        owner binding: CaptureAccountScope.AccountBinding,
        title: String
    ) throws {
        XCTAssertTrue(CaptureWidgetSnapshotStore.write(
            CaptureWidgetSnapshot(lastFinishedTitle: title), as: binding))
    }

    func seedOtherAccountWidget() throws {
        let owner = "acct-07ae000000000001"
        defaults.set(owner, forKey: CaptureWidgetSnapshotStore.activeOwnerKey)
        defaults.set(
            try JSONEncoder().encode(CaptureWidgetSnapshotStore.Envelope(
                owner: owner,
                snapshot: CaptureWidgetSnapshot(lastFinishedTitle: "Other note"))),
            forKey: CaptureWidgetSnapshotStore.key)
        _ = defaults.synchronize()
    }

    func seedAccountRoot(_ binding: CaptureAccountScope.AccountBinding) throws {
        try FileManager.default.createDirectory(at: binding.root, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: binding.root.appendingPathComponent("private.bin"))
    }

    func seedDeviceGlobalState() {
        defaults.set(UUID().uuidString, forKey: "foundryx.omi.peripheral-id")
        defaults.set("First owner's Omi", forKey: "foundryx.omi.peripheral-name")
        defaults.set(Date().timeIntervalSinceReferenceDate, forKey: "foundryx.omi.last-connected")
        defaults.set(UUID().uuidString, forKey: BatteryMonitorStore.idKey)
        defaults.set("First owner's battery", forKey: BatteryMonitorStore.nameKey)
        defaults.set("omi", forKey: "foundryx.capture.source")
        defaults.set(Data("[]".utf8), forKey: "foundryx.capture.sources.added")
        defaults.set("chat", forKey: "foundryx.action-button.choice")
    }

    var deviceGlobalStateIsAbsent: Bool {
        [
            "foundryx.omi.peripheral-id", "foundryx.omi.peripheral-name",
            "foundryx.omi.last-connected", BatteryMonitorStore.idKey,
            BatteryMonitorStore.nameKey, "foundryx.capture.source",
            "foundryx.capture.sources.added", "foundryx.action-button.choice",
        ].allSatisfy { defaults.object(forKey: $0) == nil }
    }

    var omiPairingIsPresent: Bool {
        [
            "foundryx.omi.peripheral-id", "foundryx.omi.peripheral-name",
            "foundryx.omi.last-connected",
        ].allSatisfy { defaults.object(forKey: $0) != nil }
    }

    var deviceReconnectStateIsAbsent: Bool {
        [
            BatteryMonitorStore.idKey, BatteryMonitorStore.nameKey,
            "foundryx.capture.source", "foundryx.capture.sources.added",
            "foundryx.action-button.choice",
        ].allSatisfy { defaults.object(forKey: $0) == nil }
    }

    var deviceGlobalStateIsPresent: Bool {
        [
            "foundryx.omi.peripheral-id", "foundryx.omi.peripheral-name",
            "foundryx.omi.last-connected", BatteryMonitorStore.idKey,
            BatteryMonitorStore.nameKey, "foundryx.capture.source",
            "foundryx.capture.sources.added", "foundryx.action-button.choice",
        ].allSatisfy { defaults.object(forKey: $0) != nil }
    }

    func deletionLifecycle(
        binding: CaptureAccountScope.AccountBinding
    ) -> AccountDeletionLifecycle {
        let store = AccountDeletionLifecycleStore(container: root)
        return AccountDeletionLifecycle(
            store: store,
            environment: AccountDeletionLifecycleEnvironment(
                verifyCurrentBinding: { $0 == binding },
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
                removeGroup: { [weak self] group, binding, _ in
                    guard group == .accountSurfaces, let self else { return }
                    self.lastEraseOutcomes = AccountSurfaceRegistry.eraseAll(
                        binding, defaults: self.defaults)
                    guard self.lastEraseOutcomes.values.allSatisfy(\.isTerminalSuccess) else {
                        throw AccountDeletionLifecycleError.exposureBarrierFailed
                    }
                },
                verifyGroupAbsent: { [weak self] group, _ in
                    guard group == .accountSurfaces else { return true }
                    return self?.lastEraseOutcomes.values.allSatisfy(\.isTerminalSuccess) == true
                },
                legacyOwnerScope: { nil }))
    }

    func runOldReaderRace() throws -> Bool {
        let old = try activate(subject: "race-old")
        let guarded = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let readerDone = DispatchSemaphore(value: 0)
        let transitionEntered = DispatchSemaphore(value: 0)
        let transitionDone = DispatchSemaphore(value: 0)
        let ordering = IdentityBoundaryRaceOrdering()
        let newIdentity = identity(subject: "race-new")
        let newScope = try CaptureAccountScope.key(for: newIdentity)
        CaptureAccountScope.setAfterAccountBindingGuardHookForTests {
            guarded.signal(); _ = release.wait(timeout: .now() + 5)
        }
        DispatchQueue.global().async {
            _ = CaptureAccountScope.currentAccountBinding()
            ordering.record(.readerExited)
            readerDone.signal()
        }
        guard guarded.wait(timeout: .now() + 2) == .success else { return false }
        let readerHoldsTransitionGate =
            CaptureAccountScope.isExposurePublicationGuardHeldForTests
        DispatchQueue.global().async {
            transitionEntered.signal()
            try? CaptureAccountScope.activateForTests(newIdentity)
            ordering.record(.transitionExited)
            transitionDone.signal()
        }
        guard transitionEntered.wait(timeout: .now() + 2) == .success else {
            return false
        }
        guard CaptureAccountScope
            .waitUntilExposurePublicationGuardIsContendedForTests(timeout: 2) else {
            return false
        }
        release.signal()
        guard readerDone.wait(timeout: .now() + 2) == .success,
              transitionDone.wait(timeout: .now() + 2) == .success else { return false }
        CaptureAccountScope.setAfterAccountBindingGuardHookForTests(nil)
        let current = try XCTUnwrap(CaptureAccountScope.currentAccountBinding())
        try seedWidget(owner: current, title: "New note")
        return readerHoldsTransitionGate
            && ordering.events == [.readerExited, .transitionExited]
            && old.scope != newScope
            && current.scope == newScope
            && CaptureWidgetSnapshotStore.activeOwnerForTests == newScope
            && CaptureWidgetSnapshotStore.read().lastFinishedTitle == "New note"
    }

    func cleanup() {
        AccountLiveActivityBoundary.endAllForTests = nil
        AuthStore.setIdentityEraseForTests(nil)
        CaptureAccountScope.setAfterAccountBindingGuardHookForTests(nil)
        CaptureWidgetSnapshotStore.resetDefaultsForTesting()
        CaptureAccountScope.resetTestEnvironment()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class IdentityBoundaryRaceOrdering: @unchecked Sendable {
    enum Event: Equatable { case readerExited, transitionExited }
    private let lock = NSLock()
    private var stored: [Event] = []
    var events: [Event] { lock.withLock { stored } }
    func record(_ event: Event) { lock.withLock { stored.append(event) } }
}
