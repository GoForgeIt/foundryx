import XCTest
@testable import FoundryXKit
import BrineSwiftCore

/// `features/an-unreadable-deletion-record-does-not-end-my-account.feature` and
/// `features/a-locked-phone-does-not-permanently-block-my-account.feature`.
///
/// Both drive the REAL `AccountDeletionLifecycleStore` against real bytes on
/// disk and the REAL `CaptureAccountScope` resolution cache. The only injected
/// seams are the destructive cleanup edges, so "the record could not be read" is
/// produced exactly the way the device produces it.
final class UnreadableDeletionRecordFeatureTests: XCTestCase {

    // MARK: - a record this build cannot read

    fileprivate final class RecordWorld: @unchecked Sendable {
        var fixture: UnreadableRecordFixture?
        var result: Result<AccountDeletionLifecycleRecord, Error>?
        var bytesBefore: Data?

        func reset(_ damage: UnreadableRecordFixture.Damage) throws {
            fixture?.cleanup()
            let fixture = try UnreadableRecordFixture(damage: damage)
            self.fixture = fixture
            result = nil
            bytesBefore = fixture.recordBytes
        }

        func require() throws -> UnreadableRecordFixture {
            guard let fixture else {
                throw BrineStepError("no deletion record was prepared")
            }
            return fixture
        }
    }

    func testUnreadableDeletionRecordScenarios() async throws {
        let world = RecordWorld()
        defer { world.fixture?.cleanup() }

        try await BrineFeatureRunner.run(
            "an-unreadable-deletion-record-does-not-end-my-account",
            registry: StepRegistry([
                defineStep("the record of my unfinished deletion cannot be parsed") { ctx, _, _ in
                    try world.reset(.unparseable)
                    return ctx
                },
                defineStep("the record of my unfinished deletion was written by a newer build") { ctx, _, _ in
                    try world.reset(.futureVersion)
                    return ctx
                },
                defineStep("the record of my unfinished deletion cannot be parsed but still names its count") { ctx, _, _ in
                    try world.reset(.unparseableWithEpoch(41))
                    return ctx
                },
                defineStep("the record of my unfinished deletion cannot be opened at all") { ctx, _, _ in
                    try world.reset(.unopenable)
                    return ctx
                },
                defineStep("I finish the interrupted deletion") { ctx, _, _ in
                    let fixture = try world.require()
                    do {
                        world.result = .success(
                            try await fixture.lifecycle.recover(
                                ownerScope: fixture.binding.scope))
                    } catch {
                        world.result = .failure(error)
                    }
                    return ctx
                },
                defineCheck("the deletion finishes") { _, _, _ in
                    guard case .success(let record) = world.result,
                          record.phase == .completed else {
                        throw BrineStepError(
                            "an unreadable record ended the account instead of "
                            + "being rebuilt: \(String(describing: world.result))")
                    }
                },
                defineCheck("the deletion does not finish") { _, _, _ in
                    guard case .failure = world.result else {
                        throw BrineStepError(
                            "a record that could not be opened was treated as "
                            + "readable: \(String(describing: world.result))")
                    }
                },
                defineCheck("every erase step runs") { _, _, _ in
                    let fixture = try world.require()
                    guard fixture.cleanedGroups
                        == AccountDeletionCleanupGroup.allCases else {
                        throw BrineStepError(
                            "the rebuilt record claimed erase steps it never "
                            + "ran: \(fixture.cleanedGroups)")
                    }
                },
                defineCheck("the rebuilt record counts higher than the one that could not be read") { _, _, _ in
                    guard case .success(let record) = world.result else {
                        throw BrineStepError(
                            "no rebuilt record: \(String(describing: world.result))")
                    }
                    guard record.deletionEpoch > 41 else {
                        throw BrineStepError(
                            "the rebuilt record reused a count the device may "
                            + "still remember: \(record.deletionEpoch)")
                    }
                },
                defineCheck("the record on disk is left exactly as it was") { _, _, _ in
                    let fixture = try world.require()
                    guard fixture.recordBytes == world.bytesBefore else {
                        throw BrineStepError(
                            "a record that could not be READ was overwritten, "
                            + "discarding whatever progress it held")
                    }
                },
            ]))
    }

    // MARK: - a launch on a locked phone

    fileprivate final class LockWorld: @unchecked Sendable {
        var fixture: LockedLaunchFixture?
        var rootWhileLocked: URL?
        var diskReads = 0

        func require() throws -> LockedLaunchFixture {
            guard let fixture else {
                throw BrineStepError("no launch was prepared")
            }
            return fixture
        }
    }

    func testLockedPhoneDoesNotPermanentlyBlockScenarios() async throws {
        let world = LockWorld()
        defer { world.fixture?.cleanup() }

        try await BrineFeatureRunner.run(
            "a-locked-phone-does-not-permanently-block-my-account",
            registry: StepRegistry([
                defineStep("the app started while the phone was locked and could not read the deletion record") { ctx, _, _ in
                    world.fixture?.cleanup()
                    let fixture = try LockedLaunchFixture()
                    world.fixture = fixture
                    fixture.relaunchWithLockedRecord()
                    world.rootWhileLocked =
                        CaptureAccountScope.currentAccountBinding()?.root
                    return ctx
                },
                defineCheck("I have no account root") { _, _, _ in
                    guard world.rootWhileLocked == nil else {
                        throw BrineStepError(
                            "a locked launch handed out an account root")
                    }
                },
                defineStep("the phone is unlocked") { ctx, _, _ in
                    let fixture = try world.require()
                    fixture.unlock()
                    return ctx
                },
                defineCheck("I have my account root back without restarting the app") { _, _, _ in
                    let fixture = try world.require()
                    guard let binding =
                            CaptureAccountScope.currentAccountBinding() else {
                        throw BrineStepError(
                            "unlocking the phone was not enough — the refusal "
                            + "was remembered, so only force-quitting helps")
                    }
                    guard binding.scope == fixture.scope else {
                        throw BrineStepError(
                            "recovered into the wrong account: \(binding.scope)")
                    }
                },
                defineStep("the app started with the phone unlocked and a readable deletion record") { ctx, _, _ in
                    world.fixture?.cleanup()
                    let fixture = try LockedLaunchFixture()
                    world.fixture = fixture
                    fixture.relaunchUnlocked()
                    return ctx
                },
                defineStep("the app asks for the account root twice") { ctx, _, _ in
                    CaptureAccountScope.resetResolutionPersistenceEntriesForTests()
                    _ = CaptureAccountScope.currentAccountBinding()
                    _ = CaptureAccountScope.currentAccountBinding()
                    world.diskReads =
                        CaptureAccountScope.resolutionPersistenceEntryCountForTests
                    return ctx
                },
                defineCheck("it only read from disk once") { _, _, _ in
                    guard world.diskReads == 1 else {
                        throw BrineStepError(
                            "a decided answer was re-read \(world.diskReads) times")
                    }
                },
            ]))
    }
}

/// A real store, real bytes, and the destructive edges counted.
fileprivate final class UnreadableRecordFixture: @unchecked Sendable {
    enum Damage {
        /// Bytes that will not parse at all.
        case unparseable
        /// Bytes a NEWER build wrote — the routine TestFlight downgrade.
        case unparseableWithEpoch(UInt64)
        case futureVersion
        /// The file cannot be opened. A real record may be sitting there.
        case unopenable
    }

    private let state = State()
    let root: URL
    let binding: CaptureAccountScope.AccountBinding
    let store: AccountDeletionLifecycleStore
    let lifecycle: AccountDeletionLifecycle

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var groups: [AccountDeletionCleanupGroup] = []
        func record(_ group: AccountDeletionCleanupGroup) {
            lock.withLock { groups.append(group) }
        }
        var cleaned: [AccountDeletionCleanupGroup] {
            lock.withLock { groups }
        }
    }

    var cleanedGroups: [AccountDeletionCleanupGroup] { state.cleaned }

    var recordBytes: Data? {
        guard let url = try? store.recordURL(ownerScope: binding.scope) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    init(damage: Damage) throws {
        let discriminator = UUID().uuidString.lowercased()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foundryx-unreadable-record-\(discriminator)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let scope = "acct-c0ffee0000000011"
        binding = .init(
            root: root.appendingPathComponent(scope),
            scope: scope,
            generation: 7)
        store = AccountDeletionLifecycleStore(container: root)

        let expected = binding
        let state = self.state
        lifecycle = AccountDeletionLifecycle(
            store: store,
            environment: AccountDeletionLifecycleEnvironment(
                verifyCurrentBinding: { $0 == expected },
                blockResolution: { $0.generation + 1 },
                deliverIdentityBoundary: { _ in },
                setSignedInMirrorFalse: { _ in },
                withdrawWidget: { _ in .alreadyClosed },
                closeLiveExposures: { _ in [] },
                cancelStaleWork: { _ in [] },
                verifyExposureBarrier: { live, stale in
                    AccountExposureBarrier.isSatisfied(live: live, stale: stale)
                },
                removeGroup: { group, _, _ in state.record(group) },
                verifyGroupAbsent: { _, _ in true },
                legacyOwnerScope: { nil },
                reassertDeletionBarrier: { _ in
                    (expected, expected.generation + 1)
                }))

        try write(damage)
    }

    private func write(_ damage: Damage) throws {
        let url = try store.recordURL(ownerScope: binding.scope)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        switch damage {
        case .unparseable:
            try Data("{not json".utf8).write(to: url)
        case .unparseableWithEpoch(let epoch):
            // Parses as JSON, but the sealed decoder refuses the key set — the
            // exact shape a build with one extra field produces.
            try Data(#"{"version":1,"deletionEpoch":\#(epoch),"whatIsThis":true}"#
                .utf8).write(to: url)
        case .futureVersion:
            try Data(#"{"version":2}"#.utf8).write(to: url)
        case .unopenable:
            try Data(#"{"version":1}"#.utf8).write(to: url)
            AccountDeletionLifecycleStore.setReadFailureForTests(
                .unreadable, ownerScope: binding.scope)
        }
    }

    func cleanup() {
        AccountDeletionLifecycleStore.setReadFailureForTests(
            nil, ownerScope: binding.scope)
        try? FileManager.default.removeItem(at: root)
    }
}

/// A real activated account, then a relaunch whose deletion-record read fails
/// the way a protected file fails before the first unlock.
fileprivate final class LockedLaunchFixture {
    let root: URL
    let defaultsName: String
    let defaults: UserDefaults
    let scope: String
    private let identity: AuthIdentity

    init() throws {
        let discriminator = UUID().uuidString.lowercased()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foundryx-locked-launch-\(discriminator)", isDirectory: true)
        defaultsName = "foundryx.locked-launch.\(discriminator)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        CaptureAccountScope.resetTestEnvironment()
        CaptureAccountScope.setContainerForTests(root)
        CaptureAccountScope.setDefaultsForTests(defaults)
        CaptureWidgetSnapshotStore.setDefaultsForTesting(defaults)

        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8)
        let payload = Data(#"{"sub":"locked-launch-owner"}"#.utf8)
        let token = [header, payload].map {
            $0.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }.joined(separator: ".") + ".test-signature"
        identity = AuthIdentity(
            provider: AuthProvider.google.rawValue,
            idToken: token,
            refreshToken: nil,
            expiresAt: .distantFuture,
            email: "locked-launch@example.test")
        scope = try CaptureAccountScope.key(for: identity)
        try CaptureAccountScope.activateForTests(identity)
    }

    /// A fresh process that resolves before the first unlock.
    func relaunchWithLockedRecord() {
        AccountDeletionLifecycleStore.setReadFailureForTests(
            .protectedDataUnavailable, ownerScope: scope)
        CaptureAccountScope.resetProcessCacheForTests()
    }

    func relaunchUnlocked() {
        AccountDeletionLifecycleStore.setReadFailureForTests(
            nil, ownerScope: scope)
        CaptureAccountScope.resetProcessCacheForTests()
    }

    /// The person unlocks. NOTHING else changes — no relaunch, no cache reset.
    func unlock() {
        AccountDeletionLifecycleStore.setReadFailureForTests(
            nil, ownerScope: scope)
    }

    func cleanup() {
        AccountDeletionLifecycleStore.setReadFailureForTests(
            nil, ownerScope: scope)
        CaptureWidgetSnapshotStore.resetDefaultsForTesting()
        CaptureAccountScope.resetTestEnvironment()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
