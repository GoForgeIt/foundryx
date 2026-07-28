import XCTest
import Foundation
import CoreBluetooth
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for `features/device-system-reconnect.feature` (track
/// 20260725T2306_device_agnostic_recording_source, task T4) — the spec's S04.
///
/// WHAT MAKES THIS THE ACCEPTANCE PROOF AND NOT A POLICY TEST. `OmiReconnectPolicy` already
/// had unit coverage, and it decides without executing: it cannot show that a drop reaches
/// the decision, that the decision's action is issued, that the completed connect rediscovers
/// the stream, or that the resulting `.streaming` reaches the capture state machine. Every
/// one of those steps lives in `DeviceManager`'s CoreBluetooth delegate methods, which
/// nothing could drive until T4's seam. This suite drives them:
///
///   `didDisconnect` -> `OmiReconnectPolicy.onDisconnect` -> the `.reissuePendingConnect`
///   arm's `bind` + `connect` -> `didConnect` -> `discoverServices` -> `didDiscoverServices`
///   -> `discoverCharacteristics` -> `didDiscoverCharacteristicsFor` -> `emitSourceState(.streaming)`
///   -> `CaptureManager.onSourceState`'s resume arms
///
/// against a REAL `DeviceManager` and a REAL `CaptureManager`, with real Opus frames pushed
/// up the audio characteristic. Nothing here injects `.streaming` into `CaptureManager` and
/// nothing calls `resumeSession`: the plan forbids that half-proof, and it would make the
/// continuity Then satisfiable without any of the transport working.
///
/// PROCESS-GLOBAL STATE. Inherits `ProcessGlobalStateTestCase` because it needs a decided
/// capture source and a decided ambient intent — `CaptureSettings.captureSource` is
/// phone-global and the desired state is account-scoped, and both change what
/// `onSourceState` does. The three device-global pairing keys `DeviceManager` reads directly
/// are snapshotted and restored by the world.
final class DeviceSystemReconnectFeatureTests: ProcessGlobalStateTestCase {

    func testDeviceSystemReconnectFeature() async throws {
        let world = DeviceSystemReconnectWorld()
        do {
            // Pin the POPULATION: the runner asserts only that nothing FAILED, so deleting
            // a scenario would otherwise leave this suite green.
            let result = try await BrineFeatureRunner.run(
                "device-system-reconnect",
                registry: StepRegistry(DeviceSystemReconnectSteps.make(world: world)))
            XCTAssertEqual(result.passed, 5,
                           "device-system-reconnect must run all 5 scenarios")
        } catch {
            await world.teardown()
            throw error
        }
        await world.teardown()
    }

    /// The seam itself must be able to be WRONG. A production `DeviceManager` with no
    /// injected factory builds the real CoreBluetooth adapter; the fake must not be
    /// reachable by accident, and the fake must actually be what the scenarios drive.
    func testTheInjectedCentralIsTheOneTheManagerUses() async throws {
        let stack = FakeBLEStack()
        let device = DeviceManager(makeCentral: stack.factory)
        XCTAssertEqual(stack.log, [], "the factory ran before anything asked for a central")

        // `start()` is dormant with no saved device — the shipped no-Omi fix. So this also
        // proves the fake sees the REAL guard rather than a test-only shortcut.
        let saved = DeviceGlobalPairing()
        saved.clear()
        device.start()
        stack.drain()
        XCTAssertEqual(stack.log, [],
                       "a central was created with no saved device: \(stack.log)")

        saved.stage(id: stack.deviceId, name: stack.deviceName)
        defer { saved.restore() }
        device.start()
        stack.drain()
        try await DeviceSystemReconnectWorld.settle(timeout: 30) {
            stack.count(of: .connectIssued) > 0
        }
        XCTAssertTrue(stack.log.contains(.centralCreated),
                      "the injected factory was never used: \(stack.log)")
        XCTAssertGreaterThan(stack.count(of: .connectIssued), 0,
                             "the saved device was never connected: \(stack.log)")
    }

    /// THE SCENARIO IS THE SPEC'S, VERBATIM.
    ///
    /// T4's claim is that it asserts every `Then` of S04. That claim is worth nothing if the
    /// feature file's wording can drift from the frozen spec — the easiest way to make a
    /// hard assertion pass is to soften the sentence it came from. This re-derives S04's
    /// clause list from the pinned `spec.md` and requires the feature file to carry it
    /// exactly, and requires `then-capabilities.json` to name the same clauses.
    func testTheDrivenScenarioIsTheSpecScenarioVerbatim() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let specURL = root.appendingPathComponent(
            "Tests/FoundryXBrineTests/fixtures/device-agnostic/spec.md")
        let featureURL = root.appendingPathComponent("features/device-system-reconnect.feature")
        let mapURL = root.appendingPathComponent("Tests/FoundryXBrineTests/then-capabilities.json")

        let name = "system reconnect preserves continuity while user detach stays detached"
        let fromSpec = try Self.thenClauses(of: name, inGherkinAt: specURL)
        let fromFeature = try Self.thenClauses(of: name, inGherkinAt: featureURL)

        XCTAssertFalse(fromSpec.isEmpty, "S04 was not found in the pinned spec — the check is vacuous")
        XCTAssertEqual(fromFeature, fromSpec,
                       "the driven scenario's Thens have drifted from the frozen spec's S04")

        // And the T0 map names the same clauses, so the ownership ledger and the thing
        // actually executed cannot disagree.
        let map = try JSONSerialization.jsonObject(with: Data(contentsOf: mapURL)) as? [String: Any]
        let scenarios = map?["scenarios"] as? [[String: Any]]
        let s04 = scenarios?.first { $0["id"] as? String == "S04" }
        let mappedKeys: [String] = Array((s04?["thens"] as? [String: Any])?.keys ?? [:].keys)
        let mapped = Set(mappedKeys)
        XCTAssertEqual(mapped, Set(fromSpec),
                       "then-capabilities.json's S04 clauses disagree with the spec's")
    }

    /// N7 (carried from the T3 review) — an account-exposure close over an OPEN, TAGGED gap
    /// window. `closeAudioExposure` clears `gapSync`, `gapSyncHolding` and `liveHold` but
    /// never touches `gapWindow`. The T3 reviewer could not construct the losing case
    /// because CoreBluetooth was undrivable; the seam makes it constructible, so this
    /// records what actually happens rather than leaving T5 a hypothesis.
    ///
    /// TWO FACTS THIS PINS, for whoever wires `onGapRecoveryOutcome` (T5):
    ///
    /// 1. **The outcome is not lost.** The `cancelPeripheralConnection` the close issues
    ///    drives `didDisconnect` -> `applyLinkDrop`, which closes the window honestly. So
    ///    `closeAudioExposure` not touching `gapWindow` is survivable, not a silent drop.
    /// 2. **`onGapRecoveryOutcome` is NOT gated by the exposure close, and `onState` IS.**
    ///    Both are published from the SAME `didDisconnect` callback after the account's
    ///    audio exposure has already been claimed closed: the `.stopped` state is suppressed
    ///    by `audioExposureClosed`, and the gap outcome sails straight through. A T5 wiring
    ///    that renders gap outcomes into whatever account is current will therefore render
    ///    THIS account's outcome into the NEXT one. Deciding that is T5's (N2 keeps the
    ///    production wiring out of T4); this test only makes it impossible to miss.
    func testAnAccountExposureCloseOverAnOpenGapWindowIsNotSilentAndIsNotGated() async throws {
        // A device whose storage service subscribes but never exposes its control
        // characteristic: `maybeBeginGapSync` needs both, so no engine starts and the tagged
        // window stays open — the only stable way to observe an open tagged window.
        let stack = FakeBLEStack(storage: .dataCharacteristicOnly)
        let device = DeviceManager(makeCentral: stack.factory)
        let outcomes = OutcomeBox()
        let states = SourceStateBox()
        device.onGapRecoveryOutcome = { outcomes.append($0) }
        device.onState = { states.append($0) }
        device.setInterruptedCapture("cap-n7")

        let saved = DeviceGlobalPairing()
        saved.stage(id: stack.deviceId, name: stack.deviceName)
        defer { saved.restore() }

        device.start()
        try await DeviceSystemReconnectWorld.settle(timeout: 30) {
            stack.count(of: .notifySet(OmiUUID.storageDataChar, true)) > 0
        }
        stack.drain()
        XCTAssertGreaterThan(stack.count(of: .notifySet(OmiUUID.storageDataChar, true)), 0,
                             "the storage subscription never happened, so no window is open "
                                 + "and the probe is vacuous: \(stack.log)")
        XCTAssertEqual(outcomes.all, [],
                       "the window closed before the exposure close — nothing left to observe")

        // Everything from here on happens with the exposure ALREADY claimed closed:
        // `claimAudioExposureClose()` runs synchronously at the top of `closeAudioExposure`,
        // before any of its queued work. So an outcome that appears after this line is an
        // outcome published past a closed account door.
        let statesBeforeClose = states.all.count
        let result = await device.closeAudioExposure()
        XCTAssertEqual(result, .closed)
        stack.drain()
        stack.drain()

        XCTAssertEqual(outcomes.all.count, 1,
                       "an open tagged window survived an account-exposure close without ever "
                           + "speaking: \(outcomes.all)")
        let published = try XCTUnwrap(outcomes.all.first)
        XCTAssertFalse(published.isLoss,
                       "an account-exposure close was reported as lost audio: \(published)")

        // The contrast that makes fact 2 a measurement and not an assumption: the SAME
        // `didDisconnect` also calls `emitSourceState(.stopped)`, and that one is suppressed.
        // Only the close's own terminal `.stopped` gets through.
        let after = Array(states.all.dropFirst(statesBeforeClose))
        XCTAssertEqual(after, [.stopped],
                       "the state door is not behaving as this comparison assumes: \(after)")
    }

    // MARK: - Gherkin helper

    /// Every `Then` / post-`Then` `And` of one named scenario, normalized the same way the
    /// T0 verifier normalizes (trim + collapse internal whitespace runs).
    private static func thenClauses(of scenario: String, inGherkinAt url: URL) throws -> [String] {
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
        var inScenario = false
        var afterThen = false
        var clauses: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Scenario:") || trimmed.hasPrefix("Scenario Outline:") {
                let name = normalize(String(trimmed.drop(while: { $0 != ":" }).dropFirst()))
                if inScenario { break }
                inScenario = (name == normalize(scenario))
                afterThen = false
                continue
            }
            guard inScenario else { continue }
            if trimmed.hasPrefix("Then ") {
                clauses.append(normalize(String(trimmed.dropFirst(5))))
                afterThen = true
            } else if trimmed.hasPrefix("And ") {
                if afterThen { clauses.append(normalize(String(trimmed.dropFirst(4)))) }
            } else if trimmed.hasPrefix("Given ") || trimmed.hasPrefix("When ")
                        || trimmed.hasPrefix("But ") {
                afterThen = false
            }
        }
        return clauses
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }
}

// MARK: - The three device-global pairing keys `DeviceManager` reads from `UserDefaults.standard`

/// `DeviceManager` reads the shipped pairing straight out of `UserDefaults.standard`, so a
/// suite that stages a pairing mutates process-global state and must put it back. Only keys
/// that were PRESENT are restored; an absent key is removed, never written back as a null.
final class DeviceGlobalPairing: @unchecked Sendable {
    private static var keys: [String] {
        [DeviceManager.savedKey, DeviceManager.savedNameKey, DeviceManager.savedDateKey]
    }
    private var snapshot: [String: Any]?

    private func snapshotIfNeeded() {
        guard snapshot == nil else { return }
        var taken: [String: Any] = [:]
        for key in Self.keys {
            if let value = UserDefaults.standard.object(forKey: key) { taken[key] = value }
        }
        snapshot = taken
    }

    func clear() {
        snapshotIfNeeded()
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func stage(id: UUID, name: String) {
        snapshotIfNeeded()
        UserDefaults.standard.set(id.uuidString, forKey: DeviceManager.savedKey)
        UserDefaults.standard.set(name, forKey: DeviceManager.savedNameKey)
        UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate,
                                  forKey: DeviceManager.savedDateKey)
    }

    func restore() {
        guard let snapshot else { return }
        for key in Self.keys {
            if let value = snapshot[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        self.snapshot = nil
    }
}

// MARK: - World

final class DeviceSystemReconnectWorld: @unchecked Sendable {
    let pairing = DeviceGlobalPairing()
    var baseDir: URL!
    var deviceId = UUID()
    var stack: FakeBLEStack!
    var device: DeviceManager!
    var capture: CaptureManager!
    /// The conversation open before the drop — what "the same conversation" refers to.
    var conversationBeforeDrop: String?
    /// Connects the TRANSPORT was asked to issue after the drop, with no app gesture between.
    var connectsAfterDrop = 0
    var scansAfterDrop = 0
    /// Snapshot of what the transport did during the last window, for failure messages.
    var transportLogAfterDrop: [FakeBLEStack.Event] = []
    var detachedIdentity: RecordingDeviceIdentity?

    private var directories: [URL] = []

    // MARK: lifecycle

    /// A clean handset: fresh capture dir, fresh device-scoped store, fresh transport, and a
    /// staged pairing (so the shipped "no saved device => stay fully dormant" guard does not
    /// make the automatic path a no-op).
    @MainActor
    func freshHandset() throws {
        baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-system-reconnect-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        directories.append(baseDir)
        if let store = RecordingDeviceStore.current() {
            try? FileManager.default.removeItem(at: store.fileURL)
        }
        conversationBeforeDrop = nil
        connectsAfterDrop = 0
        scansAfterDrop = 0
        transportLogAfterDrop = []
        detachedIdentity = nil
        deviceId = UUID()
        pairing.stage(id: deviceId, name: "Omi")
        try bootProcess(inRange: true)
    }

    /// A BLUETOOTH-RESTORATION launch: iOS rebuilt the process because an event fired for
    /// our central, and will hand the peripheral back through `willRestoreState` BEFORE the
    /// central reports `poweredOn`. Modelled by not announcing the state at creation.
    @MainActor
    func bootRestorationProcess() throws {
        try bootProcess(inRange: true, announceStateOnCreation: false)
    }

    /// Everything an app launch builds: the transport, the device manager over it, and the
    /// capture manager attached to that device as its audio source. Called again — with the
    /// SAME saved pairing and capture directory — to model a relaunch.
    @MainActor
    func bootProcess(inRange: Bool, announceStateOnCreation: Bool = true) throws {
        stack = FakeBLEStack(deviceId: deviceId, deviceName: "Omi",
                             announceStateOnCreation: announceStateOnCreation)
        if !inRange { stack.takeDeviceOutOfRange() }
        device = DeviceManager(makeCentral: stack.factory)
        capture = CaptureManager(
            target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x"),
            baseDir: baseDir,
            source: device,
            finalize: { _, _ in })
        device.start()
    }

    /// A relaunched process has FINISHED LAUNCHING when its hydration task has completed —
    /// BOTH phases.
    ///
    /// MY FIRST VERSION WAITED ON THE WRONG PHASE (review finding M1). It waited for
    /// `!captures.isEmpty`, which is satisfied at the end of hydration PHASE 1. The cause I
    /// had correctly diagnosed — `finishStartupAfterHydration` → `reconcileOrphanedCaptures`,
    /// which can bind or discard the very capture the scenario is about — runs in the
    /// PHASE-2 main-actor hop, after the off-main warm pass and the retention sweep. So the
    /// wait narrowed the race instead of closing it, and 8/8 clean was consistent with both
    /// readings. `hydration` is the repository's own two-phase join (`public private(set)`,
    /// used the same way in `CaptureAccountPreferenceTests`); awaiting it closes the race
    /// rather than shrinking it. No assertion changes.
    @MainActor
    func waitForRelaunchToHydrate() async throws {
        await capture.hydration?.value
    }

    /// Drop the process's objects the way a watchdog kill does: nothing is ended, nothing is
    /// finalized, the WAL is simply left on disk mid-conversation.
    @MainActor
    func killProcess() {
        capture = nil
        device = nil
        stack = nil
    }

    @MainActor
    func teardown() {
        killProcess()
        pairing.restore()
        for dir in directories { try? FileManager.default.removeItem(at: dir) }
        directories = []
    }

    // MARK: driving

    var identity: RecordingDeviceIdentity {
        RecordingDeviceIdentity(shape: .bleStream, hardwareToken: deviceId.uuidString)
    }

    var discoveredDevice: DiscoveredDevice {
        DiscoveredDevice(id: deviceId, name: "Omi", rssi: -47)
    }

    func store() throws -> RecordingDeviceStore {
        guard let store = RecordingDeviceStore.current() else {
            throw BrineStepError("no account-scoped recording-device store resolved")
        }
        return store
    }

    /// Capture dirs on disk — the count that distinguishes "resumed" from "opened a second
    /// conversation that happens to be live".
    func conversationsOnDisk() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: baseDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .filter {
                var isDir: ObjCBool = false
                let path = baseDir.appendingPathComponent($0).path
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                    && isDir.boolValue
            }
            .sorted()
    }

    /// Wait for a PRECONDITION that must hold before the step under test can mean anything,
    /// and fail loudly if it does not.
    ///
    /// THE BOUND. `origin/main`'s `2cd144f` raised the house `waitUntil` bound to 30s because a
    /// 3s bound was measuring the scheduler under full-suite load. This is twice that, and the
    /// chains it waits on settle in tens of milliseconds — roughly a thousand-fold margin. It is
    /// deliberately NOT the 300s some suites use: this is a `Given`, so when it does not hold
    /// the run should say which precondition failed promptly rather than hang for five minutes
    /// per scenario on every red. Nothing is weakened — the condition must still become true.
    @MainActor
    static func waitUntil(timeout: TimeInterval = 60,
                          _ condition: @escaping @MainActor () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                throw BrineStepError("timed out after \(Int(timeout))s waiting for a precondition")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Let the system settle toward a condition and RETURN either way. Used at the end of a
    /// `When` so that a broken chain produces the `Then`'s real diagnostic instead of a
    /// timeout inside the action.
    @MainActor
    static func settle(timeout: TimeInterval = 30,
                       until condition: @escaping @MainActor () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

// MARK: - Steps

enum DeviceSystemReconnectSteps {

    /// Open a real conversation the way the device does: `.streaming` arms the listening
    /// window and REAL voiced Opus frames cross the speech-onset bar.
    @MainActor
    private static func openConversation(_ w: DeviceSystemReconnectWorld) async throws {
        try await DeviceSystemReconnectWorld.waitUntil { w.capture.sourceState == .streaming }
        w.stack.deliverAudioFrames(RealOmiFrames.cachedVoiced, count: 15)
        try await DeviceSystemReconnectWorld.waitUntil { w.capture.active != nil }
        w.conversationBeforeDrop = w.capture.active?.captureId
    }

    /// The SYSTEM link drop, with no app gesture of any kind afterwards.
    @MainActor
    private static func dropTheLink(_ w: DeviceSystemReconnectWorld) async throws {
        w.stack.clearLog()
        w.stack.dropLink()
        try await DeviceSystemReconnectWorld.waitUntil { w.capture.isAwaitingReconnect }
        w.stack.drain()
        w.transportLogAfterDrop = w.stack.log
        w.connectsAfterDrop = w.stack.count(of: .connectIssued)
        w.scansAfterDrop = w.stack.count(of: .scanStarted)
    }

    static func make(world w: DeviceSystemReconnectWorld) -> [StepDefinition] {
        [
            // MARK: Given

            defineStep("an active external recording device is capturing a conversation") { ctx, _, _ in
                try await MainActor.run { try w.freshHandset() }
                try await openConversation(w)
                return ctx
            },

            // MARK: When

            defineStep("the system link drops and returns inside the existing short-gap boundary") { ctx, _, _ in
                try await dropTheLink(w)
                await MainActor.run { w.stack.bringDeviceIntoRange() }
                try await DeviceSystemReconnectWorld.settle {
                    w.capture.active?.captureId == w.conversationBeforeDrop
                        && !w.capture.isAwaitingReconnect
                }
                return ctx
            },

            defineStep("the system link drops and the device returns without its audio stream") { ctx, _, _ in
                try await dropTheLink(w)
                await MainActor.run {
                    w.stack.loseAudioStream()
                    w.stack.bringDeviceIntoRange()
                }
                // Settle on what the transport CAN reach: the service was rediscovered.
                try await DeviceSystemReconnectWorld.settle {
                    w.stack.count(of: .characteristicsRequested(OmiUUID.audioService)) > 0
                        && w.stack.peripheral.linkState == .connected
                }
                // Then give the (absent) resume every chance to happen anyway.
                try await DeviceSystemReconnectWorld.settle(timeout: 3) {
                    w.capture.active != nil && !w.capture.isAwaitingReconnect
                }
                return ctx
            },

            defineStep("iOS kills the app and relaunches it holding the still-connected device") { ctx, _, _ in
                // NOT a link drop. iOS terminated the PROCESS while the Omi stayed
                // connected, then relaunched us because a bluetooth-central event fired —
                // and hands the LIVE peripheral back through `willRestoreState`. This is
                // the path S04's other relaunch scenario cannot reach: there the link had
                // dropped and a fresh connect was needed; here there is nothing to connect,
                // and re-issuing one would throw away a live connection's discovery state
                // instead of rediscovering it.
                try await MainActor.run {
                    w.killProcess()
                    // A restoration launch: CoreBluetooth does NOT report `poweredOn`
                    // before delivering the restored peripherals, so the fake does not
                    // announce it either.
                    try w.bootRestorationProcess()
                }
                // WAIT FOR THE RELAUNCH TO FINISH LAUNCHING. A fresh CaptureManager hydrates
                // its library off-main and then runs `finishStartupAfterHydration`, whose
                // `reconcileOrphanedCaptures` can bind or discard the very capture this
                // scenario is about. Racing the device's return against that is not the
                // production sequence — a cold launch takes seconds, a BLE event does not
                // wait for it — and it made this scenario fail 1 run in 5. Waiting for the
                // hydrated timeline removes the race without weakening anything: the
                // assertions that follow are unchanged.
                try await w.waitForRelaunchToHydrate()
                await MainActor.run {
                    w.stack.clearLog()
                    w.stack.restoreState(peripheralState: .connected)
                    w.stack.powerOn()
                }
                w.stack.drain()
                try await DeviceSystemReconnectWorld.settle {
                    w.capture.active?.captureId == w.conversationBeforeDrop
                }
                w.stack.drain()
                w.transportLogAfterDrop = w.stack.log
                w.connectsAfterDrop = w.stack.count(of: .connectIssued)
                return ctx
            },

            defineCheck("the restored connection is rediscovered without issuing a new connect") { _, _, _ in
                // The reclaim is what makes the powered-on callback rediscover the LIVE
                // link. Without it the manager falls through to the ordinary auto-reconnect
                // and issues a connect against a peripheral that is already connected —
                // which is the classic state-restoration bug, and the observable difference.
                guard w.stack.count(of: .servicesRequested([OmiUUID.audioService,
                                                            OmiUUID.batteryService,
                                                            OmiUUID.storageService])) > 0 else {
                    throw BrineStepError(
                        "the restored connection was never rediscovered; the transport saw "
                            + "\(w.transportLogAfterDrop)")
                }
                guard w.connectsAfterDrop == 0 else {
                    throw BrineStepError(
                        "a new connect was issued against an already-connected restored "
                            + "peripheral: \(w.transportLogAfterDrop)")
                }
                // Non-vacuous: this transport DOES record connects — scenario 1 depends on
                // it, and the same fake reported them there.
                guard w.stack.peripheral.boundToSink else {
                    throw BrineStepError("the restored peripheral was never bound to the manager")
                }
            },

            defineStep("the system link drops and the app is relaunched before the device returns") { ctx, _, _ in
                try await dropTheLink(w)
                try await MainActor.run {
                    w.killProcess()
                    try w.bootProcess(inRange: false)
                }
                // The relaunched process finishes its startup work (hydration, reconcile)
                // BEFORE the device returns — which is what makes the next step the
                // cold-resume path rather than a race against startup. Both halves matter:
                // the pending connect proves the transport is armed, and the hydrated
                // timeline proves `reconcileOrphanedCaptures` has already run over the
                // interrupted capture instead of landing on it mid-resume.
                try await DeviceSystemReconnectWorld.settle {
                    w.stack.hasPendingConnect
                }
                try await w.waitForRelaunchToHydrate()
                return ctx
            },

            defineStep("the device returns inside the silence gap") { ctx, _, _ in
                await MainActor.run { w.stack.bringDeviceIntoRange() }
                try await DeviceSystemReconnectWorld.settle {
                    w.capture.active?.captureId == w.conversationBeforeDrop
                }
                return ctx
            },

            defineStep("I switch the device off") { ctx, _, _ in
                await MainActor.run { w.device.setEnabled(false) }
                w.stack.drain()
                return ctx
            },

            defineStep("the system link drops") { ctx, _, _ in
                await MainActor.run {
                    w.stack.clearLog()
                    w.stack.dropLink()
                }
                w.stack.drain()
                // A re-issued connect would be recorded synchronously inside the delivered
                // callback, so one further drain settles anything the callback queued.
                w.stack.drain()
                w.transportLogAfterDrop = w.stack.log
                w.connectsAfterDrop = w.stack.count(of: .connectIssued)
                return ctx
            },

            defineStep("I explicitly detach the device") { ctx, _, _ in
                await MainActor.run { w.device.forget() }
                w.stack.drain()
                w.detachedIdentity = w.identity
                return ctx
            },

            // MARK: Then

            defineCheck("the device reconnects without reopening the app") { _, _, _ in
                // 1. The transport was asked to reconnect, with no app gesture between the
                //    drop and the request — the step made none.
                guard w.connectsAfterDrop > 0 else {
                    throw BrineStepError(
                        "no connect was re-issued after the link dropped; the transport saw "
                            + "\(w.transportLogAfterDrop)")
                }
                // 2. It is a PENDING CONNECT, not a scan. That distinction is the whole
                //    reason this works with the app closed: `connect` has no timeout and
                //    completes in the background, a scan does not run there.
                guard w.scansAfterDrop == 0 else {
                    throw BrineStepError(
                        "the reconnect was driven by a scan, which cannot complete with the "
                            + "app closed: \(w.transportLogAfterDrop)")
                }
                // 3. And the link is genuinely back — the peripheral is bound to the sink
                //    and connected, not merely "connect() was called".
                let state = await MainActor.run { w.stack.peripheral.linkState }
                guard state == .connected else {
                    throw BrineStepError("the link never came back: peripheral state \(state.rawValue)")
                }
                guard w.stack.peripheral.boundToSink else {
                    throw BrineStepError("the peripheral was never bound to the manager")
                }
            },

            defineCheck("capture resumes the same conversation") { _, _, _ in
                guard let before = w.conversationBeforeDrop else {
                    throw BrineStepError("no conversation was open before the drop — the check is vacuous")
                }
                let (active, awaiting) = await MainActor.run {
                    (w.capture.active?.captureId, w.capture.isAwaitingReconnect)
                }
                guard let active else {
                    throw BrineStepError("no conversation is open after the reconnect")
                }
                guard active == before else {
                    throw BrineStepError("the reconnect opened \(active) instead of resuming \(before)")
                }
                guard !awaiting else {
                    throw BrineStepError("the conversation is still held awaiting the device")
                }
                // A resumed conversation is ONE conversation. Comparing ids alone would pass
                // a manager that resumed the old id AND left a second capture on disk.
                let onDisk = w.conversationsOnDisk()
                guard onDisk == [before] else {
                    throw BrineStepError("the disk holds \(onDisk), not just \(before)")
                }
            },

            defineCheck("exactly one conversation exists on disk") { _, _, _ in
                let onDisk = w.conversationsOnDisk()
                guard onDisk.count == 1 else {
                    throw BrineStepError("the drop and relaunch produced \(onDisk.count) conversations: \(onDisk)")
                }
                guard onDisk.first == w.conversationBeforeDrop else {
                    throw BrineStepError(
                        "the surviving conversation is \(onDisk) — not the one that was interrupted "
                            + "(\(w.conversationBeforeDrop ?? "nil"))")
                }
            },

            defineCheck("capture is still waiting for the device rather than resumed") { _, _, _ in
                let (active, awaiting) = await MainActor.run {
                    (w.capture.active?.captureId, w.capture.isAwaitingReconnect)
                }
                guard awaiting else {
                    throw BrineStepError(
                        "the conversation was released even though the audio stream never "
                            + "came back (active = \(active ?? "nil"))")
                }
                // Non-vacuous: the very same wiring DOES release the hold when the stream is
                // there — that is scenario 1. Here, prove the manager never even saw the
                // stream, so this is the absence of `.streaming` and not a stuck flag.
                guard w.stack.count(of: .notifySet(OmiUUID.audioDataChar, true)) == 0 else {
                    throw BrineStepError("the audio stream WAS subscribed — this is not the no-stream case")
                }
            },

            defineCheck("no connection is re-issued") { _, _, _ in
                guard w.connectsAfterDrop == 0 else {
                    throw BrineStepError(
                        "a switched-off device was re-armed by a system drop: \(w.transportLogAfterDrop)")
                }
            },

            defineCheck("the same drop on an armed device does re-issue one") { _, _, _ in
                // The negative above is only meaningful if this wiring can produce a connect
                // at all. The shipped policy is the thing being relied on, so ask it both
                // ways rather than restating the constant.
                guard OmiReconnectPolicy.onDisconnect(autoConnect: true) == .reissuePendingConnect,
                      OmiReconnectPolicy.onDisconnect(autoConnect: false) == .stayDown else {
                    throw BrineStepError("the disconnect policy no longer discriminates — the negative is free")
                }
                // And drive it: re-arm the device and drop the link again on the SAME
                // transport. A wiring that never issues a connect would pass the negative.
                await MainActor.run {
                    w.device.setEnabled(true)
                    w.stack.clearLog()
                    w.stack.dropLink()
                }
                w.stack.drain()
                w.stack.drain()
                guard w.stack.count(of: .connectIssued) > 0 else {
                    throw BrineStepError(
                        "an ARMED device produced no connect either, so the negative proved "
                            + "nothing: \(w.stack.log)")
                }
            },

            defineCheck("it remains detached until I reconnect it") { _, _, _ in
                guard let identity = w.detachedIdentity else {
                    throw BrineStepError("nothing was detached — the check is vacuous")
                }
                let store = try w.store()
                let detached = try store.records().first { $0.identity == identity }
                guard detached?.userDetached == true else {
                    throw BrineStepError(
                        "the explicit detach was not remembered: \(String(describing: detached))")
                }
                guard RecordingDeviceActivation.active(among: try store.records(),
                                                       ready: [identity]) == nil else {
                    throw BrineStepError("a detached device is still eligible to be the active device")
                }

                // REMAINS detached: an automatic system drop must not re-arm it.
                await MainActor.run {
                    w.stack.clearLog()
                    w.stack.dropLink()
                }
                w.stack.drain()
                w.stack.drain()
                guard w.stack.count(of: .connectIssued) == 0 else {
                    throw BrineStepError(
                        "an automatic path re-armed a detached device: \(w.stack.log)")
                }

                // UNTIL I RECONNECT IT: pairing the same device again from the device list is
                // the user gesture that revokes the detach. `forget()` erased the saved
                // pairing, so this is the re-pair arm — and it runs through the REAL
                // transport, which is what T2's round trip could not reach (its guard
                // returned early with no central, so nothing behind it was ever exercised).
                await MainActor.run {
                    w.stack.clearLog()
                    w.device.connect(w.discoveredDevice)
                }
                w.stack.drain()
                let reattached = try w.store().records().first { $0.identity == identity }
                guard reattached?.userDetached == false else {
                    throw BrineStepError(
                        "re-pairing did not revoke the detach: \(String(describing: reattached))")
                }
                guard w.stack.count(of: .connectIssued) > 0 else {
                    throw BrineStepError(
                        "the re-pair never reached the transport: \(w.stack.log)")
                }
                guard RecordingDeviceActivation.active(among: try w.store().records(),
                                                       ready: [identity])?.identity == identity else {
                    throw BrineStepError("the re-paired device did not become active again")
                }
            },
        ]
    }
}
