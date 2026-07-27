import XCTest
import Foundation
@testable import FoundryXKit

@MainActor
final class CaptureAccountPreferenceTests: ProcessGlobalStateTestCase {
    private final class ScopeFixture {
        let defaultsName = "capture-account-scope-\(UUID().uuidString)"
        let widgetDefaultsName = "capture-widget-scope-\(UUID().uuidString)"
        let defaults: UserDefaults
        let widgetDefaults: UserDefaults
        let container: URL
        let binding: CaptureAccountScope.AccountBinding

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            widgetDefaults = try XCTUnwrap(
                UserDefaults(suiteName: widgetDefaultsName))
            defaults.removePersistentDomain(forName: defaultsName)
            widgetDefaults.removePersistentDomain(forName: widgetDefaultsName)
            container = FileManager.default.temporaryDirectory
                .appendingPathComponent(defaultsName, isDirectory: true)
            try FileManager.default.createDirectory(
                at: container, withIntermediateDirectories: true)

            CaptureWidgetSnapshotStore.resetDefaultsForTesting()
            CaptureAccountScope.resetTestEnvironment()
            CaptureAccountScope.setContainerForTests(container)
            CaptureAccountScope.setDefaultsForTests(defaults)
            CaptureWidgetSnapshotStore.setDefaultsForTesting(widgetDefaults)
            try CaptureAccountScope.activateForTests(Self.identity)
            binding = try XCTUnwrap(
                CaptureAccountScope.currentAccountBinding())
        }

        func cleanup() {
            CaptureWidgetSnapshotStore.transition(toOwner: nil)
            CaptureWidgetSnapshotStore.resetDefaultsForTesting()
            CaptureAccountScope.resetTestEnvironment()
            defaults.removePersistentDomain(forName: defaultsName)
            widgetDefaults.removePersistentDomain(forName: widgetDefaultsName)
            try? FileManager.default.removeItem(at: container)
        }

        private static let identity = AuthIdentity(
            provider: AuthProvider.google.rawValue,
            idToken: idToken(subject: "capture-owner"),
            refreshToken: nil,
            expiresAt: .distantFuture,
            email: "capture-owner@example.test")

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

    private final class ClosingSource:
        AccountAudioSourceExposure, @unchecked Sendable
    {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        private(set) var closeCalls = 0
        var emitDuringClose = false
        var closeResults: [AccountExposureCloseResult] = [.closed]

        func start() {}
        func stop() {}

        func closeAudioExposure() async -> AccountExposureCloseResult {
            closeCalls += 1
            if emitDuringClose {
                onFrame?(RealOmiFrames.voiced())
                onState?(.streaming)
            }
            guard !closeResults.isEmpty else { return .closed }
            return closeResults.removeFirst()
        }
    }

    private func makeFixture() throws -> ScopeFixture {
        let fixture = try ScopeFixture()
        addTeardownBlock { fixture.cleanup() }
        return fixture
    }

    private func captureFrameCount(root: URL, captureId: String) -> Int {
        let dir = root.appendingPathComponent(captureId, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".opus") }.sorted().reduce(0) {
            count, name in
            let data = (try? Data(contentsOf: dir.appendingPathComponent(name)))
                ?? Data()
            return count + CaptureWAL.decodeSegment(data).count
        }
    }

    private func rootFingerprint(_ root: URL) -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey])
        else { return [:] }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(
                forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let relative = url.path.replacingOccurrences(
                of: root.path + "/", with: "")
            result[relative] = (try? Data(contentsOf: url)) ?? Data()
        }
        return result
    }

    func testBackgroundRestorationDoesNotRecordPausedReplacementAccount()
        throws
    {
        let sourceOverridesKey =
            AccountPreferenceCatalog.captureSourceEnabledOverrides.canonicalKey
        let savedSourceOverrides =
            UserDefaults.standard.object(forKey: sourceOverridesKey)
        defer {
            if let savedSourceOverrides {
                UserDefaults.standard.set(
                    savedSourceOverrides, forKey: sourceOverridesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: sourceOverridesKey)
            }
        }

        CaptureSettings.omiCaptureDesiredState = .paused
        XCTAssertEqual(
            CaptureSettings.omiCaptureDesiredState,
            .paused,
            "the replacement account must explicitly pause before restoration")

        UserDefaults.standard.set(
            OmiCaptureDesiredState.listening.rawValue,
            forKey:
                AccountPreferenceCatalog.captureOMIDesiredState.canonicalKey)
        UserDefaults.standard.set(
            [CaptureSourceDescriptor.omiId: true],
            forKey: sourceOverridesKey)
        CaptureAccountScope.resetProcessCacheForTests()
        XCTAssertNil(CaptureAccountScope.currentAccountPreferenceSnapshot())

        let store = UserDefaultsCaptureSourceStore()
        XCTAssertEqual(
            store.enabledOverrides,
            [:],
            "an absent owner snapshot must not inherit legacy source choices")
        XCTAssertEqual(
            CaptureSettings.omiCaptureDesiredState,
            .paused,
            "an absent owner snapshot must fail closed despite legacy listening")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "paused-restoration-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let spool = OmiRestorationSpool(baseDir: root, silenceGap: 0)
        spool.handleState(.streaming)
        spool.append(Data([0x11, 0x22, 0x33]))
        XCTAssertEqual(
            spool.spooledFrameCount,
            0,
            "background restoration recorded B after B explicitly paused")
        XCTAssertNil(spool.activeCaptureId)
        spool.detach()
    }

    func testTask6RestorationBootstrapIsDormantAndSpoolHasNoLiveDefaultsReader()
        throws
    {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDelegate = try String(
            contentsOf: repository
                .appendingPathComponent("App/FoundryXAppDelegate.swift"),
            encoding: .utf8)
        XCTAssertFalse(
            appDelegate.contains("UserDefaultsCaptureSourceStore()"),
            "Task 6 must not activate the Task 7 restoration preference reader")
        XCTAssertFalse(
            appDelegate.contains("OmiRestorationSpool(log:"),
            "Task 6 must not create a live background restoration spool")
        XCTAssertFalse(
            appDelegate.contains("dm.start()"),
            "Task 6 must not activate CoreBluetooth restoration")

        let spool = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/FoundryXKit/OmiRestorationSpool.swift"),
            encoding: .utf8)
        XCTAssertFalse(
            spool.contains("CaptureSettings.omiCaptureDesiredState"),
            "the per-frame spool gate must not read live compatibility defaults")
        XCTAssertFalse(
            spool.contains("UserDefaults"),
            "the restoration spool must not query defaults per frame")
    }

    func testDormantSnapshotInstallAndExplicitRefreshPreserveCompatibility()
        async throws
    {
        let fixture = try makeFixture()
        let compatibility = AccountPreferenceCompatibilityStore(
            defaults: fixture.defaults)

        let empty = CaptureSettings.snapshot(
            compatibility: compatibility, binding: fixture.binding)
        XCTAssertEqual(empty.binding, fixture.binding)
        XCTAssertEqual(empty.silenceGapSeconds, 120)
        XCTAssertEqual(empty.omiDesiredState, .listening)
        XCTAssertEqual(empty.sourceEnabledOverrides, [:])

        fixture.defaults.set(
            -4,
            forKey: AccountPreferenceCatalog.captureSilenceGapSeconds
                .canonicalKey)
        fixture.defaults.set(
            "not-a-state",
            forKey: AccountPreferenceCatalog.captureOMIDesiredState
                .canonicalKey)
        fixture.defaults.set(
            ["omi": "not-a-bool"],
            forKey: AccountPreferenceCatalog.captureSourceEnabledOverrides
                .canonicalKey)
        let invalid = CaptureSettings.snapshot(
            compatibility: compatibility, binding: fixture.binding)
        XCTAssertEqual(invalid.silenceGapSeconds, 120)
        XCTAssertEqual(invalid.omiDesiredState, .listening)
        XCTAssertEqual(invalid.sourceEnabledOverrides, [:])

        fixture.defaults.set(
            37.5,
            forKey: AccountPreferenceCatalog.captureSilenceGapSeconds
                .canonicalKey)
        fixture.defaults.set(
            "paused",
            forKey: AccountPreferenceCatalog.captureOMIDesiredState
                .canonicalKey)
        fixture.defaults.set(
            ["omi": false, "phoneMic": true],
            forKey: AccountPreferenceCatalog.captureSourceEnabledOverrides
                .canonicalKey)
        let explicit = CaptureSettings.snapshot(
            compatibility: compatibility, binding: fixture.binding)
        XCTAssertEqual(explicit.silenceGapSeconds, 37.5)
        XCTAssertEqual(explicit.omiDesiredState, .paused)
        XCTAssertEqual(
            explicit.sourceEnabledOverrides,
            ["omi": false, "phoneMic": true])

        let source = ClosingSource()
        let manager = CaptureManager(
            target: DoorTarget(
                baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x"),
            baseDir: fixture.binding.root,
            source: source)
        let registry = CaptureSourceRegistry(
            store: InMemoryCaptureSourceStore(),
            discovery: NoAudioInputDiscovery())
        XCTAssertTrue(manager.installCapturePreferenceSnapshot(explicit))
        XCTAssertTrue(registry.installCapturePreferenceSnapshot(explicit))
        XCTAssertFalse(
            manager.installCapturePreferenceSnapshot(explicit),
            "install is one-time; later changes use the explicit refresh seam")
        XCTAssertEqual(manager.silenceGapSeconds, 37.5)
        XCTAssertTrue(manager.isPaused)
        XCTAssertFalse(registry.isEnabled(CaptureSourceDescriptor.omiId))

        fixture.defaults.set(
            9,
            forKey: AccountPreferenceCatalog.captureSilenceGapSeconds
                .canonicalKey)
        fixture.defaults.set(
            "listening",
            forKey: AccountPreferenceCatalog.captureOMIDesiredState
                .canonicalKey)
        fixture.defaults.set(
            ["omi": true, "phoneMic": false],
            forKey: AccountPreferenceCatalog.captureSourceEnabledOverrides
                .canonicalKey)
        XCTAssertEqual(
            manager.silenceGapSeconds, 37.5,
            "Task 3 must not activate automatic identity/default refresh")
        XCTAssertFalse(registry.isEnabled(CaptureSourceDescriptor.omiId))

        XCTAssertTrue(manager.refreshCapturePreferences(
            compatibility: compatibility, binding: fixture.binding))
        XCTAssertTrue(registry.refreshCapturePreferences(
            compatibility: compatibility, binding: fixture.binding))
        XCTAssertEqual(manager.silenceGapSeconds, 9)
        XCTAssertFalse(manager.isPaused)
        XCTAssertTrue(registry.isEnabled(CaptureSourceDescriptor.omiId))
        XCTAssertFalse(registry.isEnabled(CaptureSourceDescriptor.phoneMicId))

        let staleBinding = CaptureAccountScope.AccountBinding(
            root: fixture.binding.root,
            scope: fixture.binding.scope,
            generation: fixture.binding.generation &+ 1)
        XCTAssertFalse(manager.refreshCapturePreferences(
            compatibility: compatibility, binding: staleBinding))
        XCTAssertFalse(registry.refreshCapturePreferences(
            compatibility: compatibility, binding: staleBinding))
    }

    func testRouterCloseACKWaitsForSelectedFrameAndClearsAllHolds()
        async throws
    {
        let root = try makeFixture().binding.root
        let target = DoorTarget(
            baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let router = FrameRouter(
            segmenter: SilenceSegmenter(silenceGap: 120))
        let wal = CaptureWAL(
            captureId: "router-old", target: target, baseDir: root)
        router.setWAL(wal)
        let barrier = FrameRouterRouteBarrier()
        router.setRouteBarrierForTests(barrier)
        DispatchQueue.global().async {
            router.route(RealOmiFrames.voiced())
        }
        XCTAssertTrue(barrier.waitUntilTargetSelected(timeout: 1))

        let close = Task.detached {
            await router.closeAccountExposure()
        }
        XCTAssertTrue(barrier.waitUntilCloseIsWaiting(timeout: 1))
        barrier.releaseSelectedRoute()
        let routerCloseResult = await close.value
        XCTAssertEqual(routerCloseResult, .closed)
        wal.flushAndWait()
        let framesAtACK = captureFrameCount(
            root: root, captureId: wal.captureId)

        router.route(RealOmiFrames.voiced())
        let successor = CaptureWAL(
            captureId: "router-successor", target: target, baseDir: root)
        router.setWAL(successor)
        successor.flushAndWait()
        XCTAssertEqual(
            captureFrameCount(root: root, captureId: wal.captureId),
            framesAtACK)
        XCTAssertEqual(
            captureFrameCount(root: root, captureId: successor.captureId), 0)

        let heldRouter = FrameRouter(
            segmenter: SilenceSegmenter(silenceGap: 120))
        heldRouter.route(RealOmiFrames.voiced())
        heldRouter.setArmed(true)
        heldRouter.route(RealOmiFrames.voiced())
        let heldCloseResult = await heldRouter.closeAccountExposure()
        XCTAssertEqual(heldCloseResult, .closed)
        let heldSuccessor = CaptureWAL(
            captureId: "router-held-successor",
            target: target,
            baseDir: root)
        heldRouter.setWAL(heldSuccessor)
        heldSuccessor.flushAndWait()
        XCTAssertEqual(
            captureFrameCount(
                root: root, captureId: heldSuccessor.captureId),
            0,
            "pre-session and armed pre-roll frames cannot cross close ACK")
    }

    func testManagerCloseACKFlushesAndRejectsAdversarialCallbacks()
        async throws
    {
        let fixture = try makeFixture()
        let source = ClosingSource()
        let mic = ClosingSource()
        let manager = CaptureManager(
            target: DoorTarget(
                baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x"),
            baseDir: fixture.binding.root,
            source: source,
            micSource: mic)
        CaptureSettings.omiCaptureDesiredState = .listening
        let rawBefore = UserDefaults.standard.string(
            forKey: AccountPreferenceCatalog.captureOMIDesiredState
                .canonicalKey)
        source.onState?(.streaming)
        RealOmiFrames.openSession(source.onFrame)
        await manager.waitUntilActiveCaptureForTests()
        let wal = try XCTUnwrap(manager.active)
        for _ in 0..<7 { source.onFrame?(RealOmiFrames.voiced()) }

        let wrong = CaptureAccountScope.AccountBinding(
            root: fixture.binding.root,
            scope: fixture.binding.scope + "-successor",
            generation: fixture.binding.generation)
        let wrongOwnerResult = await manager.closeAccountExposure(
            expected: wrong)
        XCTAssertEqual(wrongOwnerResult, .ownerMismatch)
        XCTAssertNotNil(manager.active)

        source.emitDuringClose = true
        mic.emitDuringClose = true
        let closeResult = await manager.closeAccountExposure(
            expected: fixture.binding)
        XCTAssertEqual(closeResult, .closed)
        XCTAssertEqual(source.closeCalls, 1)
        XCTAssertEqual(mic.closeCalls, 1)
        XCTAssertNil(manager.active)
        XCTAssertFalse(wal.snapshot().streaming)
        let framesAtACK = captureFrameCount(
            root: fixture.binding.root, captureId: wal.captureId)
        XCTAssertGreaterThan(framesAtACK, 0, "partial WAL must be durable at ACK")

        source.onFrame?(RealOmiFrames.voiced())
        source.onState?(.streaming)
        mic.onFrame?(RealOmiFrames.voiced())
        mic.onState?(.streaming)
        let callbacksQuiesced =
            await manager.awaitAccountExposureWorkQuiescenceForTests()
        XCTAssertTrue(
            callbacksQuiesced,
            "post-close callbacks must be synchronously rejected or joined")
        XCTAssertNil(manager.active)
        XCTAssertEqual(
            captureFrameCount(
                root: fixture.binding.root, captureId: wal.captureId),
            framesAtACK)
        let repeatedCloseResult = await manager.closeAccountExposure(
            expected: fixture.binding)
        XCTAssertEqual(repeatedCloseResult, .alreadyClosed)
        XCTAssertEqual(
            UserDefaults.standard.string(
                forKey: AccountPreferenceCatalog.captureOMIDesiredState
                    .canonicalKey),
            rawBefore,
            "privacy closure must not persist a user pause")
        let repeatedQuiescence =
            await manager.awaitAccountExposureWorkQuiescenceForTests()
        XCTAssertTrue(repeatedQuiescence)
    }

    func testSpoolCloseIsOwnerAndExecutorSafeWithoutErasingSuccessorCallbacks()
        async throws
    {
        let fixture = try makeFixture()
        let executor = DispatchQueue(label: "capture-account-spool-test")
        let source = ClosingSource()
        let spool = OmiRestorationSpool(
            binding: fixture.binding,
            root: fixture.binding.root,
            executor: executor,
            silenceGap: 120,
            paused: { false })
        spool.attach(to: source)
        let retainedState = try XCTUnwrap(source.onState)
        let retainedFrame = try XCTUnwrap(source.onFrame)
        retainedState(.streaming)
        retainedFrame(Data([0xA1]))
        let captureId = try XCTUnwrap(spool.activeCaptureId)

        var successorStates = 0
        var successorFrames = 0
        source.onState = { _ in successorStates += 1 }
        source.onFrame = { _ in successorFrames += 1 }
        let wrong = CaptureAccountScope.AccountBinding(
            root: fixture.binding.root,
            scope: fixture.binding.scope + "-successor",
            generation: fixture.binding.generation)
        let wrongOwnerResult = await spool.closeAccountExposure(
            expected: wrong)
        XCTAssertEqual(wrongOwnerResult, .ownerMismatch)
        let closeResult = await spool.closeAccountExposure(
            expected: fixture.binding)
        XCTAssertEqual(closeResult, .closed)
        let framesAtACK = captureFrameCount(
            root: fixture.binding.root, captureId: captureId)

        source.onState?(.streaming)
        source.onFrame?(Data([0xC3]))
        XCTAssertEqual(successorStates, 1)
        XCTAssertEqual(successorFrames, 1)
        retainedState(.streaming)
        retainedFrame(Data([0xB2]))
        XCTAssertNil(spool.activeCaptureId)
        XCTAssertEqual(
            captureFrameCount(
                root: fixture.binding.root, captureId: captureId),
            framesAtACK)
        let executorCloseResult =
            await spool.closeAccountExposureFromExecutorForTests(
                expected: fixture.binding)
        XCTAssertEqual(
            executorCloseResult,
            .alreadyClosed,
            "the terminal path must dispatch inline on its own executor")
    }

    func testBackgroundSpoolStaysUnboundUntilForegroundHandoff()
        async throws
    {
        let fixture = try makeFixture()
        let legacyRoot = fixture.container.appendingPathComponent(
            "legacy-restoration-spool", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyRoot, withIntermediateDirectories: true)
        let spool = OmiRestorationSpool(
            baseDir: legacyRoot,
            silenceGap: 120,
            paused: { false },
            executor: DispatchQueue(
                label: "capture-account-unbound-spool-test"))

        XCTAssertNil(spool.availableAccountExposureBinding)
        let unavailableClose = await spool.closeAccountExposure(
            expected: fixture.binding)
        XCTAssertEqual(
            unavailableClose,
            .unavailable,
            "a locked/background restoration launch must not resolve an account")

        let rooted = try XCTUnwrap(
            spool.installAccountExposureBinding(from: fixture.binding))
        XCTAssertEqual(rooted.root, legacyRoot)
        XCTAssertEqual(rooted.scope, fixture.binding.scope)
        XCTAssertEqual(rooted.generation, fixture.binding.generation)
        XCTAssertEqual(spool.availableAccountExposureBinding, rooted)
        let wrongRootClose = await spool.closeAccountExposure(
            expected: fixture.binding)
        XCTAssertEqual(
            wrongRootClose,
            .ownerMismatch,
            "the spool remains rooted at its existing legacy capture directory")
        let rootedClose = await spool.closeAccountExposure(expected: rooted)
        XCTAssertEqual(rootedClose, .closed)
    }

    func testRegistryCloseReachesDeviceWithoutPersistingUserChoices()
        async throws
    {
        let fixture = try makeFixture()
        let store = UserDefaultsCaptureSourceStore(defaults: fixture.defaults)
        store.enabledOverrides = ["omi": true, "phoneMic": false]
        store.addedSources = [
            CaptureSourceRecord(
                id: "bt:route", category: .bluetoothMic,
                displayName: "Saved headset", routeUID: "route"),
        ]
        fixture.defaults.set(
            CaptureSourceKind.phoneMic.rawValue,
            forKey: "foundryx.capture.source")
        let before = fixture.defaults.persistentDomain(
            forName: fixture.defaultsName)
        let device = DeviceManager()
        var stopped = 0
        device.onState = { state in
            if state == .stopped { stopped += 1 }
        }
        let registry = CaptureSourceRegistry(
            store: store,
            discovery: NoAudioInputDiscovery(),
            accountBinding: fixture.binding,
            deviceManager: device)
        let wrong = CaptureAccountScope.AccountBinding(
            root: fixture.binding.root,
            scope: fixture.binding.scope,
            generation: fixture.binding.generation &+ 1)
        let wrongOwnerResult = await registry.closeAccountExposure(
            expected: wrong)
        XCTAssertEqual(wrongOwnerResult, .ownerMismatch)
        XCTAssertEqual(stopped, 0)
        let closeResult = await registry.closeAccountExposure(
            expected: fixture.binding)
        XCTAssertEqual(closeResult, .closed)
        XCTAssertEqual(stopped, 1)
        XCTAssertEqual(
            fixture.defaults.persistentDomain(forName: fixture.defaultsName)
                as NSDictionary?,
            before as NSDictionary?,
            "close ACK must not persist disabled overrides or erase phone hardware")
    }

    func testWidgetWithdrawIsOwnerCheckedAndPersistenceVerified() throws {
        let fixture = try makeFixture()
        let snapshot = CaptureWidgetSnapshot(
            phase: .recordingActive,
            sourceLabel: "Omi",
            updatedAt: Date(timeIntervalSince1970: 11))
        XCTAssertTrue(CaptureWidgetSnapshotStore.write(
            snapshot, as: fixture.binding))
        let ownerBefore = fixture.widgetDefaults.string(
            forKey: CaptureWidgetSnapshotStore.activeOwnerKey)
        let payloadBefore = fixture.widgetDefaults.data(
            forKey: CaptureWidgetSnapshotStore.key)

        XCTAssertEqual(
            CaptureWidgetSnapshotStore.withdraw(
                expectedOwner: fixture.binding.scope + "-other"),
            .ownerMismatch)
        XCTAssertEqual(
            fixture.widgetDefaults.string(
                forKey: CaptureWidgetSnapshotStore.activeOwnerKey),
            ownerBefore)
        XCTAssertEqual(
            fixture.widgetDefaults.data(
                forKey: CaptureWidgetSnapshotStore.key),
            payloadBefore)

        CaptureWidgetSnapshotStore.setWithdrawalFaultForTesting(
            .synchronizeFailure)
        XCTAssertEqual(
            CaptureWidgetSnapshotStore.withdraw(
                expectedOwner: fixture.binding.scope),
            .persistenceFailed)
        CaptureWidgetSnapshotStore.setWithdrawalFaultForTesting(nil)
        CaptureWidgetSnapshotStore.transition(
            toOwner: fixture.binding.scope)
        XCTAssertTrue(CaptureWidgetSnapshotStore.write(
            snapshot, as: fixture.binding))

        XCTAssertEqual(
            CaptureWidgetSnapshotStore.withdraw(
                expectedOwner: fixture.binding.scope),
            .withdrawn)
        XCTAssertNil(fixture.widgetDefaults.object(
            forKey: CaptureWidgetSnapshotStore.activeOwnerKey))
        XCTAssertNil(fixture.widgetDefaults.object(
            forKey: CaptureWidgetSnapshotStore.key))
        XCTAssertEqual(CaptureWidgetSnapshotStore.read(), .idle)
        XCTAssertEqual(
            CaptureWidgetSnapshotStore.withdraw(
                expectedOwner: fixture.binding.scope),
            .alreadyAbsent)
    }

    func testExposureCoordinatorIsWeakAttributableOrderedAndReentrant()
        async throws
    {
        final class Exposure: AccountLiveExposure, @unchecked Sendable {
            let participantID: String
            let accountExposureBinding: CaptureAccountScope.AccountBinding
            var result: AccountExposureCloseResult
            var close: (() -> Void)?
            private(set) var calls = 0

            init(
                _ id: String,
                binding: CaptureAccountScope.AccountBinding,
                result: AccountExposureCloseResult = .closed
            ) {
                participantID = id
                accountExposureBinding = binding
                self.result = result
            }

            func closeAccountExposure(
                expected: CaptureAccountScope.AccountBinding
            ) async -> AccountExposureCloseResult {
                calls += 1
                guard expected == accountExposureBinding else {
                    return .ownerMismatch
                }
                close?()
                return result
            }
        }

        final class Work: AccountStaleWork, @unchecked Sendable {
            let participantID: String
            let accountExposureBinding: CaptureAccountScope.AccountBinding
            var result: AccountExposureCloseResult
            private(set) var calls = 0

            init(
                _ id: String,
                binding: CaptureAccountScope.AccountBinding,
                result: AccountExposureCloseResult = .closed
            ) {
                participantID = id
                accountExposureBinding = binding
                self.result = result
            }

            func cancelAccountWork(
                expected: CaptureAccountScope.AccountBinding
            ) async -> AccountExposureCloseResult {
                calls += 1
                guard expected == accountExposureBinding else {
                    return .ownerMismatch
                }
                return result
            }
        }

        let fixture = try makeFixture()
        let coordinator = AccountExposureCoordinator()
        var releasedLive: Exposure? = Exposure(
            "released-live", binding: fixture.binding)
        weak var weakLive = releasedLive
        _ = coordinator.registerExposure(try XCTUnwrap(releasedLive))
        releasedLive = nil
        XCTAssertNil(weakLive)
        var releasedWork: Work? = Work(
            "released-work", binding: fixture.binding)
        weak var weakWork = releasedWork
        _ = coordinator.registerStaleWork(try XCTUnwrap(releasedWork))
        releasedWork = nil
        XCTAssertNil(weakWork)

        let reentrantWork = Work(
            "work-reentrant", binding: fixture.binding)
        let a = Exposure(
            "live-a",
            binding: fixture.binding,
            result: .verificationFailed)
        let b = Exposure(
            "live-b",
            binding: fixture.binding,
            result: .unavailable)
        a.close = {
            _ = coordinator.registerStaleWork(reentrantWork)
        }
        _ = coordinator.registerExposure(b)
        _ = coordinator.registerExposure(a)

        let other = CaptureAccountScope.AccountBinding(
            root: fixture.binding.root,
            scope: fixture.binding.scope + "-other",
            generation: fixture.binding.generation)
        let mismatchACKs =
            await coordinator.closeRegisteredExposures(expected: other)
        XCTAssertEqual(
            mismatchACKs,
            [
                AccountExposureAcknowledgement(
                    participantID: "live-a", kind: .live,
                    result: .ownerMismatch),
                AccountExposureAcknowledgement(
                    participantID: "live-b", kind: .live,
                    result: .ownerMismatch),
            ])
        XCTAssertEqual(a.calls, 0)
        XCTAssertEqual(b.calls, 0)

        let liveACKs = await coordinator.closeRegisteredExposures(
            expected: fixture.binding)
        XCTAssertEqual(
            liveACKs,
            [
                AccountExposureAcknowledgement(
                    participantID: "live-a", kind: .live,
                    result: .verificationFailed),
                AccountExposureAcknowledgement(
                    participantID: "live-b", kind: .live,
                    result: .unavailable),
            ],
            "ACKs are attributable and stable regardless of registration order")
        let staleACKs = await coordinator.cancelRegisteredStaleWork(
            expected: fixture.binding)
        XCTAssertEqual(
            staleACKs,
            [
                AccountExposureAcknowledgement(
                    participantID: "work-reentrant", kind: .staleWork,
                    result: .closed),
            ],
            "registration from an awaited hook must not deadlock or be lost")
    }

    func testExposureRegistrationMatchesIdentityButClosesWithParticipantRoot()
        async throws
    {
        final class Owner: @unchecked Sendable {
            private let lock = NSLock()
            private var receivedBindings:
                [CaptureAccountScope.AccountBinding] = []

            func record(_ binding: CaptureAccountScope.AccountBinding) {
                lock.lock()
                receivedBindings.append(binding)
                lock.unlock()
            }

            var received: [CaptureAccountScope.AccountBinding] {
                lock.lock()
                defer { lock.unlock() }
                return receivedBindings
            }
        }

        let fixture = try makeFixture()
        let participantRoot = fixture.container.appendingPathComponent(
            "participant-root", isDirectory: true)
        let participantBinding = CaptureAccountScope.AccountBinding(
            root: participantRoot,
            scope: fixture.binding.scope,
            generation: fixture.binding.generation)
        let coordinator = AccountExposureCoordinator()
        let owner = Owner()

        var released: AccountExposureRegistration? =
            AccountExposureRegistration(
            participantID: "released-registration",
            kind: .live,
            binding: fixture.binding,
            owner: owner,
            close: { owner, expected in
                owner.record(expected)
                return .closed
            })
        weak var weakReleased = released
        coordinator.register(try XCTUnwrap(released))
        released = nil
        XCTAssertNil(weakReleased)

        let rooted = AccountExposureRegistration(
            participantID: "root-bound-registration",
            kind: .live,
            binding: participantBinding,
            owner: owner,
            close: { owner, expected in
                owner.record(expected)
                return .closed
            })
        let unavailable = AccountExposureRegistration(
            participantID: "unavailable-registration",
            kind: .live,
            binding: nil,
            owner: owner,
            close: { owner, expected in
                owner.record(expected)
                return .closed
            })
        coordinator.register(unavailable)
        coordinator.register(rooted)

        let acknowledgements =
            await coordinator.closeRegisteredExposures(
                expected: fixture.binding)
        XCTAssertEqual(
            acknowledgements,
            [
                AccountExposureAcknowledgement(
                    participantID: "root-bound-registration",
                    kind: .live,
                    result: .closed),
                AccountExposureAcknowledgement(
                    participantID: "unavailable-registration",
                    kind: .live,
                    result: .unavailable),
            ])
        XCTAssertEqual(
            owner.received,
            [participantBinding],
            "scope+generation select the owner, but the hook receives its own root")
    }

    func testManagerCloseACKCancelsRealHydrationBeforeOldRootCommit()
        async throws
    {
        let fixture = try makeFixture()
        let id = "omi-20260727-030000-hydrate"
        let target = DoorTarget(
            baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let wal = CaptureWAL(
            captureId: id, target: target, baseDir: fixture.binding.root)
        wal.beginStreaming()
        wal.appendFrame(RealOmiFrames.voiced())
        wal.finish()
        ConversationMetaStore.recordStart(
            captureId: id,
            baseDir: fixture.binding.root,
            at: 100)
        XCTAssertNil(
            ConversationMetaStore.load(
                captureId: id,
                baseDir: fixture.binding.root)?.endedAt)

        let hydrationGate = Task3ControlledGate<Void>()
        let manager = CaptureManager(
            target: target,
            baseDir: fixture.binding.root,
            source: ClosingSource(),
            hydrationBeforeCommit: {
                await hydrationGate.suspend(returning: ())
            })
        await hydrationGate.waitUntilEntered()
        let close = Task {
            await manager.closeAccountExposure(expected: fixture.binding)
        }
        await manager.waitUntilAccountExposureClosingForTests()
        await hydrationGate.release()
        let closeResult = await close.value
        XCTAssertEqual(closeResult, .closed)

        XCTAssertNil(
            ConversationMetaStore.load(
                captureId: id,
                baseDir: fixture.binding.root)?.endedAt,
            "cancelled hydration cannot reconcile the old root after close")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.binding.root
                .appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(".needs-finalize").path))
    }

    func testManagerCloseACKRejectsSuspendedTimerDrainMutation()
        async throws
    {
        let fixture = try makeFixture()
        let target = DoorTarget(
            baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")

        let pendingID = "omi-20260727-031000-drain"
        let pending = CaptureWAL(
            captureId: pendingID,
            target: target,
            baseDir: fixture.binding.root)
        pending.beginStreaming()
        pending.appendFrame(RealOmiFrames.voiced())
        pending.finish()
        let pendingSegment = fixture.binding.root
            .appendingPathComponent(pendingID, isDirectory: true)
            .appendingPathComponent(CaptureWAL.segName(0))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: pendingSegment.path))

        let segmentGate = Task3ControlledGate<[UInt64]?>()
        let timer = ManualCaptureManagerTimer()
        let manager = CaptureManager(
            target: target,
            baseDir: fixture.binding.root,
            source: ClosingSource(),
            fetchSegments: { _ in
                await segmentGate.suspend(returning: [0])
            },
            drainTimerFactory: { _, tick in
                timer.install(tick)
                return timer
            })
        await manager.hydration?.value
        timer.fire()
        await segmentGate.waitUntilEntered()
        let close = Task {
            await manager.closeAccountExposure(expected: fixture.binding)
        }
        await manager.waitUntilAccountExposureClosingForTests()
        await segmentGate.release()
        let closeResult = await close.value
        XCTAssertEqual(closeResult, .closed)
        let ack = pendingSegment
            .deletingPathExtension()
            .appendingPathExtension("ack")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ack.path))
        let drainACK = rootFingerprint(fixture.binding.root)
        timer.fireRetainedCallbackForTests()
        let quiesced =
            await manager.awaitAccountExposureWorkQuiescenceForTests()
        XCTAssertTrue(quiesced)
        XCTAssertEqual(rootFingerprint(fixture.binding.root), drainACK)
        XCTAssertTrue(timer.invalidated)
    }

    func testManagerCloseACKRejectsSuspendedTimerFinalizeMutation()
        async throws
    {
        let finalizeFixture = try makeFixture()
        let target = DoorTarget(
            baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let finalizeID = "omi-20260727-032000-finalize"
        let finalized = CaptureWAL(
            captureId: finalizeID,
            target: target,
            baseDir: finalizeFixture.binding.root)
        finalized.beginStreaming()
        finalized.appendFrame(RealOmiFrames.voiced())
        finalized.finish()
        let finalizedDir = finalizeFixture.binding.root
            .appendingPathComponent(finalizeID, isDirectory: true)
        let finalizedSegment = finalizedDir
            .appendingPathComponent(CaptureWAL.segName(0))
        try Data().write(
            to: finalizedSegment
                .deletingPathExtension()
                .appendingPathExtension("ack"),
            options: [.atomic])
        try Data().write(
            to: finalizedDir.appendingPathComponent(".needs-finalize"),
            options: [.atomic])
        ConversationMetaStore.recordStart(
            captureId: finalizeID,
            baseDir: finalizeFixture.binding.root,
            at: 100)
        ConversationMetaStore.recordEnd(
            captureId: finalizeID,
            baseDir: finalizeFixture.binding.root,
            at: 200,
            location: nil)

        let finalizeGate = Task3ControlledGate<Void>()
        let finalizeTimer = ManualCaptureManagerTimer()
        let finalizeManager = CaptureManager(
            target: target,
            baseDir: finalizeFixture.binding.root,
            source: ClosingSource(),
            finalize: { _, _ in
                await finalizeGate.suspend(returning: ())
            },
            drainTimerFactory: { _, tick in
                finalizeTimer.install(tick)
                return finalizeTimer
            })
        await finalizeManager.hydration?.value
        finalizeTimer.fire()
        await finalizeGate.waitUntilEntered()
        let finalizeClose = Task {
            await finalizeManager.closeAccountExposure(
                expected: finalizeFixture.binding)
        }
        await finalizeManager.waitUntilAccountExposureClosingForTests()
        await finalizeGate.release()
        let closeResult = await finalizeClose.value
        XCTAssertEqual(closeResult, .closed)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: finalizedDir
                .appendingPathComponent(".needs-finalize").path))
        let finalizeACK = rootFingerprint(finalizeFixture.binding.root)
        finalizeTimer.fireRetainedCallbackForTests()
        let quiesced = await finalizeManager
            .awaitAccountExposureWorkQuiescenceForTests()
        XCTAssertTrue(quiesced)
        XCTAssertEqual(
            rootFingerprint(finalizeFixture.binding.root),
            finalizeACK)
        XCTAssertTrue(finalizeTimer.invalidated)
    }

    func testManagerFailedCloseStaysSealedAndMatchingRetryCanClose()
        async throws
    {
        let fixture = try makeFixture()
        let target = DoorTarget(
            baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let source = ClosingSource()
        source.emitDuringClose = true
        source.closeResults = [.verificationFailed, .closed]
        let manager = CaptureManager(
            target: target,
            baseDir: fixture.binding.root,
            source: source)
        await manager.hydration?.value

        let first = await manager.closeAccountExposure(
            expected: fixture.binding)
        XCTAssertEqual(first, .verificationFailed)
        XCTAssertEqual(source.closeCalls, 1)
        XCTAssertNil(manager.active)
        let failedCloseQuiesced =
            await manager.awaitAccountExposureWorkQuiescenceForTests()
        XCTAssertTrue(failedCloseQuiesced)

        let failureACK = rootFingerprint(fixture.binding.root)
        source.onFrame?(RealOmiFrames.voiced())
        source.onState?(.streaming)
        await Task { @MainActor in () }.value
        XCTAssertNil(
            manager.active,
            "a failed verification keeps the old callback gate sealed")
        XCTAssertEqual(rootFingerprint(fixture.binding.root), failureACK)

        let retry = await manager.closeAccountExposure(
            expected: fixture.binding)
        XCTAssertEqual(retry, .closed)
        XCTAssertEqual(source.closeCalls, 2)

        let closedACK = rootFingerprint(fixture.binding.root)
        source.onFrame?(RealOmiFrames.voiced())
        source.onState?(.streaming)
        await Task { @MainActor in () }.value
        XCTAssertNil(manager.active)
        XCTAssertEqual(rootFingerprint(fixture.binding.root), closedACK)
        let alreadyClosed = await manager.closeAccountExposure(
            expected: fixture.binding)
        XCTAssertEqual(
            alreadyClosed,
            .alreadyClosed)
    }

    func testManagerCloseACKRejectsDeferredTranscriptCacheWrite()
        async throws
    {
        let fixture = try makeFixture()
        let target = DoorTarget(
            baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let fetchGate = Task3ControlledGate<CaptureContent?>()
        let captureID = "omi-20260727-033000-cache"
        let manager = CaptureManager(
            target: target,
            baseDir: fixture.binding.root,
            source: ClosingSource(),
            fetchContent: { _ in
                await fetchGate.suspend(returning: CaptureContent(
                    transcript: "must not reach the old account root",
                    capturedAt: 100,
                    found: true,
                    title: "Stale title",
                    summary: "Stale summary"))
            })
        await manager.hydration?.value

        manager.ensureRecentTranscriptCached(captureID)
        await fetchGate.waitUntilEntered()
        let close = Task {
            await manager.closeAccountExposure(expected: fixture.binding)
        }
        await manager.waitUntilAccountExposureClosingForTests()
        await fetchGate.release()
        let closeResult = await close.value
        XCTAssertEqual(closeResult, .closed)

        XCTAssertNil(TranscriptCacheStore.load(
            captureId: captureID,
            baseDir: fixture.binding.root))
        XCTAssertNil(ConversationCardStore.load(
            captureId: captureID,
            baseDir: fixture.binding.root))
        let cacheACK = rootFingerprint(fixture.binding.root)
        manager.ensureRecentTranscriptCached(captureID)
        let cacheQuiesced =
            await manager.awaitAccountExposureWorkQuiescenceForTests()
        XCTAssertTrue(cacheQuiesced)
        XCTAssertEqual(rootFingerprint(fixture.binding.root), cacheACK)
    }

    func testManagerCloseACKCancelsAndJoinsDiscardedFragmentPrune()
        async throws
    {
        let fixture = try makeFixture()
        let target = DoorTarget(
            baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let fragment = fixture.binding.root.appendingPathComponent(
            "omi-20260720-010000-discarded",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: fragment, withIntermediateDirectories: true)
        let marker = fragment.appendingPathComponent(".discarded")
        try Data().write(to: marker)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3 * 24 * 60 * 60)],
            ofItemAtPath: marker.path)

        let pruneGate = Task3CancellationGate()
        let manager = CaptureManager(
            target: target,
            baseDir: fixture.binding.root,
            source: ClosingSource(),
            discardedPruneBeforeDelete: { _ in
                await pruneGate.suspend()
            })
        await pruneGate.waitUntilEntered()

        let close = Task {
            await manager.closeAccountExposure(expected: fixture.binding)
        }
        await manager.waitUntilAccountExposureClosingForTests()
        await pruneGate.release()
        let closeResult = await close.value
        XCTAssertEqual(closeResult, .closed)
        let pruneWasCancelled = await pruneGate.observedCancellation
        XCTAssertTrue(pruneWasCancelled)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fragment.path),
            "cancelled startup pruning cannot delete the old root after close")

        let pruneACK = rootFingerprint(fixture.binding.root)
        let pruneQuiesced =
            await manager.awaitAccountExposureWorkQuiescenceForTests()
        XCTAssertTrue(pruneQuiesced)
        XCTAssertEqual(rootFingerprint(fixture.binding.root), pruneACK)
    }

    func testStatusPollerCloseACKRejectsSuspendedFetchBeforeCardMerge()
        async throws
    {
        let fixture = try makeFixture()
        let fetcher = Task3SuspendedStatusFetcher()
        let callbacks = Task3PollerCallbackBox()
        let poller = CaptureStatusPoller(
            captureId: "omi-poller-close",
            client: fetcher,
            baseInterval: 60,
            baseDir: fixture.binding.root,
            onCardWritten: { callbacks.record($0) })
        poller.start()
        await fetcher.waitUntilEntered()
        let close = Task { await poller.close() }
        await poller.waitUntilClosingForTests()
        await fetcher.release()
        await close.value

        XCTAssertNil(ConversationCardStore.load(
            captureId: "omi-poller-close",
            baseDir: fixture.binding.root))
        XCTAssertEqual(callbacks.ids, [])
        XCTAssertEqual(poller.stage, .stored)
        XCTAssertNil(poller.title)
        XCTAssertNil(poller.summary)
    }
}

private actor Task3ControlledGate<Value: Sendable> {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend(returning value: Value) async -> Value {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return value
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor Task3CancellationGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var observedCancellation = false

    func suspend() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        observedCancellation = Task.isCancelled
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor Task3SuspendedStatusFetcher: CaptureStatusFetching {
    private let gate = Task3ControlledGate<Void>()

    func captureStatus(captureId: String) async throws
        -> CaptureStatusResponse
    {
        await gate.suspend(returning: ())
        return CaptureStatusResponse(
            stage: "transcribing",
            loreCaptureId: "lore-after-close",
            transcribed: true,
            title: "Must not land",
            summary: "Must not be written")
    }

    func waitUntilEntered() async {
        await gate.waitUntilEntered()
    }

    func release() async {
        await gate.release()
    }
}

private final class Task3PollerCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func record(_ id: String) {
        lock.lock()
        values.append(id)
        lock.unlock()
    }

    var ids: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
