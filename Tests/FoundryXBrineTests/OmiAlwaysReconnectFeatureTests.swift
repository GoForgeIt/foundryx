import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// features/omi-always-reconnect.feature — the always-reconnect + offline-cache-sync
/// contract, driven through the REAL pure pieces (OmiReconnectPolicy, the
/// OmiOfflineSyncEngine with a mocked link, the OmiRestorationSpool with a real WAL
/// on a temp dir). The BLE wire itself is exercised on the `@ble-hardware` lane and
/// the real-device plan in the track (the sim cannot BLE).
final class OmiAlwaysReconnectFeatureTests: ProcessGlobalStateTestCase {
    func testOmiAlwaysReconnectScenarios() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let featurePath = url.appendingPathComponent("features/omi-always-reconnect.feature").path
        let text = try String(contentsOfFile: featurePath, encoding: .utf8)
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        let world = OmiReconnectWorld()
        let registry = StepRegistry(OmiReconnectSteps.make(world: world))

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry,
                                             resources: [], collector: { collected.append($0) })

        var failures: [String] = []
        for ev in collected {
            guard case .object(let o) = ev,
                  case .string("scenario_end")? = o["type"],
                  case .string(let status)? = o["status"], status != "passed" else { continue }
            let name: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(name): \(err)")
        }
        XCTAssertTrue(failures.isEmpty, "omi-always-reconnect scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
        XCTAssertEqual(result.passed, parsed.features[0].scenarios.count, "all scenarios should pass")
    }
}

/// Scenario state. The delivered-audio list is the ORDER oracle: recovered gap
/// frames must precede any live frame captured during the sync (the live hold —
/// the same contract DeviceManager's bleQueue hold implements).
private final class OmiReconnectWorld: @unchecked Sendable {
    var autoConnect = true
    var disconnectAction: OmiReconnectPolicy.DisconnectAction?
    var failAction: OmiReconnectPolicy.FailedConnectAction?
    var restoreAction: OmiReconnectPolicy.RestoreAction?

    // engine + mocked link
    var engine: OmiOfflineSyncEngine?
    var commands: [OmiOfflineSyncEngine.Command] = []
    var delivered: [Data] = []          // frames as the capture pipeline receives them
    var liveHold: [Data] = []           // live frames held while a sync is active
    var outcome: OmiOfflineSyncEngine.Outcome?

    // spool
    var baseDir: URL?
    var spool: OmiRestorationSpool?
    var source: MockAudioSource?
    var firstCaptureId: String?
    var secondCaptureId: String?
    var captureManagers: [CaptureManager] = []

    final class MockAudioSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    func reset() {
        autoConnect = true
        disconnectAction = nil; failAction = nil; restoreAction = nil
        engine = nil; commands = []; delivered = []; liveHold = []; outcome = nil
        captureManagers.removeAll()
        if let d = baseDir { try? FileManager.default.removeItem(at: d) }
        baseDir = nil; spool = nil; source = nil; firstCaptureId = nil; secondCaptureId = nil
    }

    func makeBaseDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("omi-reconnect-feature-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        baseDir = d
        return d
    }

    /// Wire an engine exactly the way DeviceManager does: recovered frames flow
    /// straight to the pipeline; live frames are held while the sync is active and
    /// flushed (in order) when it settles.
    func wireEngine() {
        let e = OmiOfflineSyncEngine()
        e.emit = { [weak self] in self?.commands.append($0) }
        e.emitFrame = { [weak self] in self?.delivered.append($0) }
        e.finished = { [weak self] o in
            guard let self else { return }
            self.outcome = o
            self.delivered.append(contentsOf: self.liveHold)   // release the hold, in order
            self.liveHold.removeAll()
        }
        engine = e
    }

    func liveFrame(_ f: Data) {
        if let e = engine, e.isActive { liveHold.append(f) } else { delivered.append(f) }
    }

    @MainActor
    func openBufferedConversation() async throws {
        let base = makeBaseDir()
        let src = MockAudioSource()
        source = src
        // Open deterministically through the real paused-restoration path, then resume
        // listening and buffer fewer than one WAL chunk. This avoids making the owner
        // continuity proof depend on host AudioToolbox's Opus decoder.
        CaptureSettings.omiCaptureDesiredState = .paused
        let manager = makeCaptureManager(baseDir: base, source: src)
        captureManagers = [manager]
        if let hydration = manager.hydration { await hydration.value }

        src.onState?(.streaming)
        try await waitUntil("initial buffered conversation to open") {
            manager.active != nil
        }
        manager.resume()
        for _ in 0..<10 { src.onFrame?(Data([0xA1])) }
        firstCaptureId = manager.active?.captureId

        guard let id = firstCaptureId,
              CaptureManager.newestSegmentMTimeOnDisk(id, baseDir: base) == nil else {
            throw BrineStepError("premise failed: the first audio must still be buffered")
        }
    }

    @MainActor
    func replaceActiveListeningOwner() async throws {
        guard let base = baseDir, let src = source else {
            throw BrineStepError("no buffered conversation whose owner can be replaced")
        }
        // Model the accepted SwiftUI StateObject being REPLACED, not speculative
        // construction that leaves callbacks on the original manager. The replacement
        // claims the real source callbacks immediately. Keep it paused until it has
        // re-adopted the segmentless durable capture, then resume and route enough speech
        // to force a WAL segment under whichever capture it chose.
        CaptureSettings.omiCaptureDesiredState = .paused
        let replacement = makeCaptureManager(baseDir: base, source: src)
        captureManagers.append(replacement)
        if let hydration = replacement.hydration { await hydration.value }
        src.onState?(.streaming)
        try await waitUntil("replacement listening owner to adopt a conversation") {
            replacement.active != nil
        }
        replacement.resume()
        for _ in 0..<60 { src.onFrame?(Data([0xA3])) }
        replacement.active?.flushAndWait()
        secondCaptureId = replacement.active?.captureId
    }

    @MainActor
    func relaunchWithinSilenceBoundary() async throws {
        guard let base = baseDir else {
            throw BrineStepError("no buffered conversation to relaunch")
        }
        let relaunchedSource = MockAudioSource()
        source = relaunchedSource
        CaptureSettings.omiCaptureDesiredState = .paused
        let relaunched = makeCaptureManager(baseDir: base, source: relaunchedSource)
        captureManagers.append(relaunched)
        if let hydration = relaunched.hydration { await hydration.value }
        relaunchedSource.onState?(.streaming)
        try await waitUntil("relaunched manager to open a conversation") {
            relaunched.active != nil
        }
        relaunched.resume()
        secondCaptureId = relaunched.active?.captureId
    }

    func captureDirectoryIds() -> [String] {
        guard let base = baseDir else { return [] }
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDirectory: ObjCBool = false
            return fm.fileExists(
                atPath: base.appendingPathComponent(name, isDirectory: true).path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }
    }

    func captureIdsContainingAudio() -> [String] {
        guard let base = baseDir else { return [] }
        let fm = FileManager.default
        return captureDirectoryIds().filter { id in
            let dir = base.appendingPathComponent(id, isDirectory: true)
            return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .contains { $0.hasSuffix(".opus") }
        }
    }

    @MainActor
    private func makeCaptureManager(
        baseDir: URL,
        source: MockAudioSource,
        attachToSourcesImmediately: Bool = true
    ) -> CaptureManager {
        CaptureManager(
            target: DoorTarget(
                baseURL: URL(string: "http://127.0.0.1:1")!,
                bearer: "feature-test"
            ),
            baseDir: baseDir,
            source: source,
            attachToSourcesImmediately: attachToSourcesImmediately,
            finalize: { _, _ in }
        )
    }

    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let started = Date()
        while !condition() {
            if Date().timeIntervalSince(started) > timeout {
                throw BrineStepError("timed out waiting for \(description)")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private enum OmiReconnectSteps {
    static func make(world: OmiReconnectWorld) -> [StepDefinition] {
        [
            // Scenario: out-of-range drop → pending reconnect
            defineStep("my Omi is connected and I walk out of Bluetooth range") { ctx, _, _ in
                world.reset()
                world.autoConnect = true
                return ctx
            },
            defineStep("the link drops") { ctx, _, _ in
                world.disconnectAction = OmiReconnectPolicy.onDisconnect(autoConnect: world.autoConnect)
                return ctx
            },
            defineStep("a pending reconnect to my Omi is issued immediately") { ctx, _, _ in
                guard world.disconnectAction == .reissuePendingConnect else {
                    throw BrineStepError("expected reissuePendingConnect, got \(String(describing: world.disconnectAction))")
                }
                return ctx
            },
            defineStep("the reconnect waits for the Omi to return without any scanning loop") { ctx, _, _ in
                // The policy's vocabulary has no scan/poll action at all — the pending
                // connect IS the wait. Assert the decision is the connect re-issue.
                guard world.disconnectAction == .reissuePendingConnect else {
                    throw BrineStepError("reconnect must be the pending connect, not a scan")
                }
                return ctx
            },

            // Scenario: failed attempt retries
            defineStep("my Omi is reconnecting") { ctx, _, _ in
                world.reset()
                world.autoConnect = true
                return ctx
            },
            defineStep("the connect attempt fails") { ctx, _, _ in
                world.failAction = OmiReconnectPolicy.onFailToConnect(autoConnect: world.autoConnect)
                return ctx
            },
            defineStep("another reconnect attempt is scheduled shortly after") { ctx, _, _ in
                guard case .retryAfterDelay(let d)? = world.failAction, d > 0, d <= 10 else {
                    throw BrineStepError("expected a short delayed retry, got \(String(describing: world.failAction))")
                }
                return ctx
            },

            // Scenario: user-suspended stays down
            defineStep("I turned my Omi off on the device page") { ctx, _, _ in
                world.reset()
                world.autoConnect = false
                return ctx
            },
            defineStep("no reconnect is issued until I re-enable it") { ctx, _, _ in
                guard world.disconnectAction == .stayDown else {
                    throw BrineStepError("a toggled-off Omi must stay down, got \(String(describing: world.disconnectAction))")
                }
                return ctx
            },

            // Scenario: background relaunch (state restoration) + durable spool
            defineStep("iOS terminated the app while a pending reconnect was waiting") { ctx, _, _ in
                world.reset()
                return ctx
            },
            defineStep("the Omi comes back into range") { ctx, _, _ in
                // The pending connect completes → iOS relaunches us → willRestoreState
                // hands the CONNECTED peripheral back → policy says rediscover.
                world.restoreAction = OmiReconnectPolicy.onRestore(state: .connected, autoConnect: true)
                let base = world.makeBaseDir()
                let src = OmiReconnectWorld.MockAudioSource()
                let spool = OmiRestorationSpool(baseDir: base, silenceGap: 120, paused: { false })
                spool.attach(to: src)
                world.source = src
                world.spool = spool
                src.onState?(.streaming)
                for _ in 0..<60 { src.onFrame?(Data([0xA1, 0xB2])) }
                world.firstCaptureId = spool.activeCaptureId
                return ctx
            },
            defineStep("the app is relaunched in the background and re-adopts the Omi link") { ctx, _, _ in
                guard world.restoreAction == .discoverServices else {
                    throw BrineStepError("restored connected peripheral must rediscover services")
                }
                return ctx
            },
            defineStep("the audio that streams in is saved durably on the phone without opening the app") { ctx, _, _ in
                guard let base = world.baseDir, let id = world.firstCaptureId else {
                    throw BrineStepError("no spooled capture")
                }
                world.spool?.detach()
                let segs = ((try? FileManager.default.contentsOfDirectory(
                    atPath: base.appendingPathComponent(id).path)) ?? []).filter { $0.hasSuffix(".opus") }
                guard !segs.isEmpty else { throw BrineStepError("no durable WAL segments written by the spool") }
                return ctx
            },

            // Scenario: pull gap audio from onboard storage
            defineStep("my Omi recorded audio to its onboard storage while disconnected") { ctx, _, _ in
                world.reset()
                world.wireEngine()
                return ctx
            },
            defineStep("the Omi reconnects") { ctx, _, _ in
                // Scenarios that already drove (or don't use) the engine reuse this step.
                guard let e = world.engine, world.outcome == nil else { return ctx }
                e.begin()
                e.statusResult(OmiRingProtocolTests.statusBytes(used: 888, unread: 2, free: 1000, rtc: 1))
                e.notification(OmiRingProtocolTests.infoBytes(readSeq: 5, writeSeq: 7, capacity: 64, dropped: 0, packetSize: 444))
                e.notification(OmiRingProtocolTests.readBeginBytes(startSeq: 5, count: 2))
                // Live speech arrives WHILE the ring is transferring.
                world.liveFrame(Data([0xFE, 0x01]))
                let recs = OmiRingProtocolTests.record(ts: 900, frames: [[1, 1]])
                    + OmiRingProtocolTests.record(ts: 901, frames: [[2, 2]])
                e.notification(Data([0x03]) + recs)
                world.liveFrame(Data([0xFE, 0x02]))
                e.notification(OmiRingProtocolTests.doneBytes(status: 0, nextSeq: 7))
                e.notification(Data([0x01, 0x00]))   // advance ACK
                return ctx
            },
            defineStep("the recorded gap audio is pulled from the device") { ctx, _, _ in
                guard case .synced(let records, _)? = world.outcome, records == 2 else {
                    throw BrineStepError("expected 2 synced records, got \(String(describing: world.outcome))")
                }
                return ctx
            },
            defineStep("the gap audio is delivered before any live audio so the conversation stays in order") { ctx, _, _ in
                guard world.delivered == [Data([1, 1]), Data([2, 2]), Data([0xFE, 0x01]), Data([0xFE, 0x02])] else {
                    throw BrineStepError("order violated: \(world.delivered.map { Array($0) })")
                }
                return ctx
            },
            defineStep("the device is told to advance past what was synced so nothing is pulled twice") { ctx, _, _ in
                guard world.commands.contains(.advance(seq: 7)) else {
                    throw BrineStepError("no advance to the firmware's nextSeq; commands=\(world.commands)")
                }
                return ctx
            },

            // Scenario: short gap same conversation
            defineStep("a conversation was interrupted by a short Bluetooth gap") { ctx, _, _ in
                world.reset()
                let base = world.makeBaseDir()
                let src = OmiReconnectWorld.MockAudioSource()
                let spool = OmiRestorationSpool(baseDir: base, silenceGap: 120, paused: { false })
                spool.attach(to: src)
                src.onState?(.streaming)
                for _ in 0..<60 { src.onFrame?(Data([3, 4])) }
                world.firstCaptureId = spool.activeCaptureId
                src.onState?(.stopped)   // the drop — seconds ago, well inside the gap
                _ = spool.activeCaptureId   // io.sync barrier: the drop's durable flush completes
                return ctx
            },
            defineStep("the Omi reconnects and the gap audio arrives") { ctx, _, _ in
                guard let base = world.baseDir else { throw BrineStepError("no base dir") }
                let src = OmiReconnectWorld.MockAudioSource()
                let spool = OmiRestorationSpool(baseDir: base, silenceGap: 120, paused: { false })
                spool.attach(to: src)
                src.onState?(.streaming)
                src.onFrame?(Data([5]))
                world.secondCaptureId = spool.activeCaptureId
                spool.detach()
                return ctx
            },
            defineStep("the same conversation continues under its original capture id") { ctx, _, _ in
                guard let a = world.firstCaptureId, let b = world.secondCaptureId, a == b else {
                    throw BrineStepError("expected same id, got \(String(describing: world.firstCaptureId)) vs \(String(describing: world.secondCaptureId))")
                }
                return ctx
            },

            // Scenarios: a segmentless capture survives owner churn and relaunch.
            defineStep("my Omi has opened a conversation and its first audio is still buffered") { ctx, _, _ in
                world.reset()
                try await world.openBufferedConversation()
                return ctx
            },
            defineStep("the app replaces the active listening owner while I keep speaking") { ctx, _, _ in
                try await world.replaceActiveListeningOwner()
                return ctx
            },
            defineStep("I still have one conversation") { ctx, _, _ in
                let ids = world.captureDirectoryIds()
                guard ids.count == 1, ids.first == world.firstCaptureId else {
                    throw BrineStepError(
                        "expected only the original conversation, got \(ids.sorted())"
                    )
                }
                guard world.secondCaptureId == world.firstCaptureId else {
                    throw BrineStepError(
                        "the replacement owner adopted \(world.secondCaptureId ?? "?") "
                        + "instead of the original \(world.firstCaptureId ?? "?")"
                    )
                }
                return ctx
            },
            defineStep("all recorded audio belongs to the original conversation") { ctx, _, _ in
                let ids = world.captureIdsContainingAudio()
                guard ids == [world.firstCaptureId].compactMap({ $0 }) else {
                    throw BrineStepError(
                        "expected audio only under \(world.firstCaptureId ?? "?"), got \(ids.sorted())"
                    )
                }
                return ctx
            },
            defineStep("the app relaunches within the conversation silence boundary") { ctx, _, _ in
                try await world.relaunchWithinSilenceBoundary()
                return ctx
            },

            // Scenario: long gap → new conversation
            defineStep("the Omi was away longer than the conversation silence boundary") { ctx, _, _ in
                world.reset()
                let base = world.makeBaseDir()
                let oldId = "omi-20260101-000000-feed0001"
                let dir = base.appendingPathComponent(oldId, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let seg = dir.appendingPathComponent(CaptureWAL.segName(0))
                try Data([0, 0, 0, 1, 9]).write(to: seg)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)],
                                                      ofItemAtPath: seg.path)
                try Data(CaptureSourceKind.omi.rawValue.utf8)
                    .write(to: CaptureManager.sourceMarkerURL(oldId, baseDir: base))
                world.firstCaptureId = oldId
                // Reconnect now, past the 120s boundary.
                let src = OmiReconnectWorld.MockAudioSource()
                let spool = OmiRestorationSpool(baseDir: base, silenceGap: 120, paused: { false })
                spool.attach(to: src)
                src.onState?(.streaming)
                src.onFrame?(Data([6]))
                world.secondCaptureId = spool.activeCaptureId
                spool.detach()
                return ctx
            },
            defineStep("a new conversation begins for the recovered and live audio") { ctx, _, _ in
                guard let b = world.secondCaptureId, b != world.firstCaptureId else {
                    throw BrineStepError("expected a NEW capture id past the boundary")
                }
                return ctx
            },

            // Scenario: no/old storage → live immediately
            defineStep("my Omi's storage cache is absent or speaks an older protocol") { ctx, _, _ in
                world.reset()
                world.wireEngine()
                world.engine?.begin()
                world.engine?.statusResult(Data([9, 9]))   // old-firmware shape
                return ctx
            },
            defineStep("offline sync is skipped and live audio flows immediately") { ctx, _, _ in
                guard case .unsupportedProtocol? = world.outcome else {
                    throw BrineStepError("expected unsupportedProtocol, got \(String(describing: world.outcome))")
                }
                world.liveFrame(Data([0x55]))
                guard world.delivered.last == Data([0x55]) else {
                    throw BrineStepError("live audio must flow immediately after the sync settles")
                }
                return ctx
            },

            // Scenario: stalled sync never blocks live audio
            defineStep("an offline cache sync has started") { ctx, _, _ in
                world.reset()
                world.wireEngine()
                world.engine?.begin()
                world.engine?.statusResult(OmiRingProtocolTests.statusBytes(used: 444, unread: 1, free: 10, rtc: 1))
                world.liveFrame(Data([0x77]))   // held while the sync is active
                return ctx
            },
            defineStep("the transfer stalls") { ctx, _, _ in
                world.engine?.stalled()
                return ctx
            },
            defineStep("the sync is abandoned and held live audio is released in order") { ctx, _, _ in
                guard world.outcome != nil else { throw BrineStepError("sync never settled") }
                guard world.delivered == [Data([0x77])], world.liveHold.isEmpty else {
                    throw BrineStepError("held live audio was not released; delivered=\(world.delivered.map { Array($0) })")
                }
                return ctx
            },
        ]
    }
}
