import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for `features/device-gap-recovery.feature` (track
/// 20260725T2306_device_agnostic_recording_source, task T3).
///
/// Drives the real `GapRecoveryWindow` and the real `OmiOfflineSyncEngine.Outcome` values
/// the shipped engine produces. The window is a value type precisely so every close path is
/// data rather than a call-site count, which is what makes this hermetic.
final class DeviceGapRecoveryFeatureTests: XCTestCase {

    func testDeviceGapRecoveryFeature() async throws {
        let world = DeviceGapRecoveryWorld()
        let result = try await BrineFeatureRunner.run(
            "device-gap-recovery",
            registry: StepRegistry(DeviceGapRecoverySteps.make(world: world)))
        XCTAssertEqual(result.passed, 15,
                       "device-gap-recovery must run all 15 scenarios (8 plain + 7 outline rows)")
    }

    /// Every engine ending must map to exactly one outcome, and the mapping must be TOTAL:
    /// a new engine case with no mapping would otherwise silently inherit some default.
    func testEveryEngineEndingMapsAndOnlyRealLossIsALoss() {
        let endings: [(OmiOfflineSyncEngine.Outcome, GapRecoveryOutcome, Bool)] = [
            (.nothingToSync, .nothingBuffered, false),
            (.synced(records: 3, frames: 120), .recovered(records: 3, frames: 120), false),
            (.synced(records: 0, frames: 0), .nothingBuffered, false),
        ]
        for (ending, expected, isLoss) in endings {
            XCTAssertEqual(GapRecoveryWindow.outcome(for: ending), expected,
                           "wrong outcome for \(ending)")
            XCTAssertEqual(GapRecoveryWindow.outcome(for: ending).isLoss, isLoss)
        }
        // M3 — the most-reached close cause: every teardown with no prior explicit close
        // publishes it, so its VALUE matters, not just that it is non-nil.
        var generic = GapRecoveryWindow(interruptedCaptureId: "cap-1")
        let genericOutcome = generic.close(.closedWithoutEngine(reason: "superseded"))
        guard case .nothingToRecover = genericOutcome else {
            return XCTFail("the generic teardown publishes \(String(describing: genericOutcome))")
        }
        XCTAssertEqual(genericOutcome?.isLoss, false,
                       "a teardown that simply never collected the audio is not a loss")

        // The three reason-carrying endings, checked by SHAPE so the wording stays free.
        switch GapRecoveryWindow.outcome(for: .aborted(records: 2, frames: 40, reason: "link dropped")) {
        case .partiallyRecovered(let records, let frames, _):
            XCTAssertEqual([records, frames], [2, 40])
        default:
            XCTFail("a partial transfer is not partially recovered")
        }
        XCTAssertFalse(GapRecoveryWindow.outcome(for: .failed("link dropped")).isLoss,
                       "a failed sync leaves the span ON THE DEVICE — reporting it as a loss is a lie")
        XCTAssertTrue(GapRecoveryWindow.outcome(for: .unsupportedProtocol("not ring-shaped")).isLoss,
                      "firmware that cannot replay the gap means the audio really is gone")
    }

    // MARK: - The FUNNEL (finding H5)
    //
    // Everything above drives `GapRecoveryWindow` directly. That proves the MAPPING from a
    // cause to an outcome and says nothing about whether the wiring picks the right cause,
    // tags at open, or publishes once — four reviewer falsifications survived green against
    // the value type alone. These drive `DeviceManager`'s real funnel functions on their
    // real queue.

    /// Build a DeviceManager with the outcome sink captured. `init` creates no
    /// CBCentralManager (only `start()` does), so this is hermetic.
    private func makeFunnel() -> (DeviceManager, () -> [GapRecoveryOutcome]) {
        let manager = DeviceManager()
        let box = OutcomeBox()
        manager.onGapRecoveryOutcome = { box.append($0) }
        return (manager, { box.all })
    }

    /// X1 — the window must be tagged AT OPEN. If the tag were read at CLOSE, changing the
    /// snapshot after open would change what the window says.
    func testTheWindowIsTaggedAtOpenNotAtClose() {
        let (manager, outcomes) = makeFunnel()
        manager.setInterruptedCapture("cap-open")
        manager.runOnBleQueueForTests { manager.beginGapSyncWindow() }
        // The conversation ends between open and close: a close-time read would see nil and
        // publish nothing.
        manager.setInterruptedCapture(nil)
        manager.runOnBleQueueForTests { manager.applyLinkDrop() }
        XCTAssertEqual(outcomes().count, 1,
                       "the window was tagged at CLOSE, not at open — it published \(outcomes())")

        // Control, so "one outcome" cannot be satisfied by a funnel that always publishes:
        // a window opened while nothing was interrupted must stay silent.
        let (quiet, quietOutcomes) = makeFunnel()
        quiet.setInterruptedCapture(nil)
        quiet.runOnBleQueueForTests { quiet.beginGapSyncWindow() }
        quiet.setInterruptedCapture("cap-appeared-later")
        quiet.runOnBleQueueForTests { quiet.applyLinkDrop() }
        XCTAssertEqual(quietOutcomes(), [], "a window that interrupted nothing published anyway")
    }

    /// X2 — one opened window publishes at most one outcome THROUGH THE FUNNEL. The value
    /// type enforces it only if the funnel writes the mutated window back.
    func testTheFunnelPublishesAtMostOneOutcomePerWindow() throws {
        let (manager, outcomes) = makeFunnel()
        manager.setInterruptedCapture("cap-1")
        manager.runOnBleQueueForTests {
            manager.beginGapSyncWindow()
            manager.applyLinkDrop()
            manager.closeGapWindow(.engineFinished(.synced(records: 9, frames: 900)))
            manager.closeGapWindow(.deviceHasNoStorage)
        }
        XCTAssertEqual(outcomes().count, 1,
                       "one window published \(outcomes().count) outcomes: \(outcomes())")
        let first = try XCTUnwrap(outcomes().first)
        guard case .nothingToRecover = first else {
            return XCTFail("the FIRST cause must win, got \(first)")
        }
    }

    /// X7 — the plan's one named reachable sequence, driven through the funnel: window open,
    /// link gone before any engine existed. Deleting that close must red here.
    func testALinkDropBeforeAnyEngineKeepsTheSpanOnTheDevice() throws {
        let (manager, outcomes) = makeFunnel()
        manager.setInterruptedCapture("cap-1")
        manager.runOnBleQueueForTests {
            manager.beginGapSyncWindow()
            manager.applyLinkDrop()
        }
        XCTAssertEqual(outcomes().count, 1, "the named sequence published \(outcomes())")
        let published = try XCTUnwrap(outcomes().first)
        XCTAssertFalse(published.isLoss, "\(published) reports a loss")
        // MUST distinguish WHICH cause produced it. `.linkDroppedBeforeEngine` and the
        // generic teardown BOTH map to `.nothingToRecover`, so asserting only the case lets
        // a deleted close pass on the teardown fallback — the X7 falsification survived
        // exactly that way. Compare against the production mapping for the specific cause,
        // computed here rather than written as a literal, so no wording is pinned.
        var probe = GapRecoveryWindow(interruptedCaptureId: "probe")
        let fromLinkDrop = probe.close(.linkDroppedBeforeEngine)
        var teardownProbe = GapRecoveryWindow(interruptedCaptureId: "probe")
        let fromTeardown = teardownProbe.close(
            .closedWithoutEngine(reason: "the window closed before it was collected"))
        XCTAssertNotEqual(fromLinkDrop, fromTeardown,
                          "the two causes are indistinguishable, so this check cannot see a deleted close")
        XCTAssertEqual(published, fromLinkDrop,
                       "the named sequence did not publish the LINK-DROP outcome — it published \(published)")
        // With an engine running the ENGINE publishes and the funnel adds nothing — so the
        // branch above is a decision, not a constant. This models the real ordering:
        // `OmiOfflineSyncEngine.linkDropped()` -> `finish()` -> `finished?()` is fully
        // synchronous, so `gapSyncFinished` has already closed the window by the time
        // `applyLinkDrop` runs. (My first version of this control passed
        // `engineWasRunning: true` with no engine outcome, which the generic teardown then
        // published — a test artifact, not a production path.)
        let (withEngine, engineOutcomes) = makeFunnel()
        withEngine.setInterruptedCapture("cap-1")
        withEngine.runOnBleQueueForTests {
            withEngine.beginGapSyncWindow()
            withEngine.closeGapWindow(.engineFinished(.synced(records: 2, frames: 80)))
            withEngine.applyLinkDrop()
        }
        XCTAssertEqual(engineOutcomes().count, 1,
                       "the drop added an outcome on top of the engine's: \(engineOutcomes())")
        let engineOutcome = try XCTUnwrap(engineOutcomes().first)
        guard case .recovered = engineOutcome else {
            return XCTFail("the engine's outcome did not win: \(engineOutcome)")
        }
    }

    /// H3 / X5 — a service discovery that FAILED must not be reported as a device that keeps
    /// no audio, and must not consume the window before the drop that follows it.
    func testAFailedServiceDiscoveryIsNotReportedAsPermanentLoss() throws {
        // Successful discovery, genuinely no storage service: an honest loss.
        let (noStorage, noStorageOutcomes) = makeFunnel()
        noStorage.setInterruptedCapture("cap-1")
        noStorage.runOnBleQueueForTests {
            noStorage.beginGapSyncWindow()
            noStorage.applyServiceDiscovery(errorDescription: nil, sawStorageService: false)
        }
        XCTAssertEqual(noStorageOutcomes().count, 1)
        XCTAssertTrue(try XCTUnwrap(noStorageOutcomes().first).isLoss,
                      "a device that really keeps no audio must be reported as a loss")

        // FAILED discovery: the service list is empty because the read did not happen.
        let (failed, failedOutcomes) = makeFunnel()
        failed.setInterruptedCapture("cap-1")
        failed.runOnBleQueueForTests {
            failed.beginGapSyncWindow()
            failed.applyServiceDiscovery(errorDescription: "connection interrupted",
                                         sawStorageService: false)
        }
        XCTAssertEqual(failedOutcomes().count, 1)
        let failedOutcome = try XCTUnwrap(failedOutcomes().first)
        XCTAssertFalse(failedOutcome.isLoss,
                       "a failed discovery was reported as permanently lost audio: \(failedOutcome)")

        // Successful discovery WITH storage closes nothing — the engine path continues.
        let (ok, okOutcomes) = makeFunnel()
        ok.setInterruptedCapture("cap-1")
        ok.runOnBleQueueForTests {
            ok.beginGapSyncWindow()
            ok.applyServiceDiscovery(errorDescription: nil, sawStorageService: true)
        }
        XCTAssertEqual(okOutcomes(), [], "a healthy discovery closed the window early")
    }

    /// H3's ordering aggravation: a link drop DURING discovery delivers
    /// `didDiscoverServices(error:)` BEFORE `didDisconnectPeripheral`. If the first event
    /// consumed the window with a loss, the plan's mandated `.nothingToRecover` could never
    /// fire on the ordering that most plausibly produces it.
    func testADropDuringDiscoveryStillReportsTheSpanAsStillOnTheDevice() throws {
        let (manager, outcomes) = makeFunnel()
        manager.setInterruptedCapture("cap-1")
        manager.runOnBleQueueForTests {
            manager.beginGapSyncWindow()
            manager.applyServiceDiscovery(errorDescription: "the connection was interrupted",
                                          sawStorageService: false)
            manager.applyLinkDrop()
        }
        XCTAssertEqual(outcomes().count, 1, "the ordering published \(outcomes())")
        let ordered = try XCTUnwrap(outcomes().first)
        XCTAssertFalse(ordered.isLoss,
                       "a link drop during discovery was reported as lost audio: \(ordered)")
    }

    /// M6 — all four cells of `{discovery error} x {storage service seen}`, at the one
    /// decision point. The cell that matters is `error != nil && seen`: `didDiscoverServices`
    /// has ALREADY issued `discoverCharacteristics` for that service, so closing here would
    /// tear down the hold `maybeBeginGapSync` needs and forfeit a recovery that was about to
    /// happen.
    func testTheDiscoveryMatrixNeverDeclaresASeenStorageServiceUnreachable() {
        XCTAssertNil(GapWindowTrigger.closeCause(discoveryError: nil, sawStorageService: true),
                     "a healthy discovery that found storage must not close the window")
        XCTAssertNil(GapWindowTrigger.closeCause(discoveryError: "partial failure",
                                                 sawStorageService: true),
                     "the storage service was SEEN — closing forfeits the characteristic path")

        switch GapWindowTrigger.closeCause(discoveryError: nil, sawStorageService: false) {
        case .deviceHasNoStorage: break
        case let other: XCTFail("a successful discovery with no storage gave \(String(describing: other))")
        }
        switch GapWindowTrigger.closeCause(discoveryError: "connection interrupted",
                                           sawStorageService: false) {
        case .storageUnavailable: break
        case let other: XCTFail("a failed discovery gave \(String(describing: other))")
        }
    }

    /// The same cell through the funnel: the window must SURVIVE, which is only observable
    /// by closing it afterwards and seeing that close publish.
    ///
    /// Reachability of this cell in production: `p.services` is a cache that survives a
    /// failed re-discovery, and `handleRestoredPeripheral` re-issues `discoverServices` on an
    /// already-connected restored peripheral whose services CoreBluetooth restored. A
    /// rediscovery that errors while the cached storage service is still present lands here.
    /// Driving CoreBluetooth itself is T4's injected seam; this asserts the CB-free handler
    /// the delegate forwards to.
    func testAFailedRediscoveryThatStillSawStorageKeepsTheWindowOpen() throws {
        let (manager, outcomes) = makeFunnel()
        manager.setInterruptedCapture("cap-1")
        manager.runOnBleQueueForTests {
            manager.beginGapSyncWindow()
            manager.applyServiceDiscovery(errorDescription: "rediscovery failed",
                                          sawStorageService: true)
        }
        XCTAssertEqual(outcomes(), [],
                       "a failed rediscovery that still saw storage closed the window: \(outcomes())")

        // Still open: the decision deadline can still speak for it.
        manager.runOnBleQueueForTests { manager.closeGapWindow(.decisionDeadlinePassed) }
        XCTAssertEqual(outcomes().count, 1, "the window was already gone — the hold was torn down")
        XCTAssertFalse(try XCTUnwrap(outcomes().first).isLoss)
    }

    /// H4/H6 — the seam must be wireable from a main-actor composition root AGAINST THE
    /// REAL PRODUCER.
    ///
    /// The first version of this test wired a hand-written stub that duplicated
    /// `CaptureManager`'s shape. That guarded nothing: deleting
    /// `CaptureManager.onInterruptedCaptureChanged` and its `didSet` outright left the
    /// suite green, so the entire producer half of the seam was unobserved — the same
    /// "compiles only because nothing uses it" shape the seam was rewritten to escape.
    ///
    /// This drives a REAL `CaptureManager` through a REAL suspended-session transition: a
    /// conversation opens on the streaming source, the link drops, and the interrupted id
    /// must arrive at `DeviceManager` by the push alone.
    @MainActor
    func testTheInterruptedCaptureSeamIsWiredFromTheRealCaptureManager() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-seam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = SeamTestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let capture = CaptureManager(target: target, baseDir: dir, source: source)
        let device = DeviceManager()

        // THE T5-SHAPED WIRING, against the real types. That this compiles at all is half
        // the assertion: the previous closure-shaped seam could not be written here.
        capture.onInterruptedCaptureChanged = { [weak device] id in
            device?.setInterruptedCapture(id)
        }

        XCTAssertNil(device.interruptedCaptureAtOpen)

        source.onState?(.streaming)
        RealOmiFrames.openSession(source.onFrame)
        try await Self.waitUntil { capture.active != nil }
        let live = try XCTUnwrap(capture.active?.captureId)

        // The link drops: CaptureManager suspends the conversation and PUSHES.
        source.onState?(.stopped)
        try await Self.waitUntil { capture.isAwaitingReconnect }
        XCTAssertEqual(device.interruptedCaptureAtOpen, live,
                       "the interrupted conversation never reached DeviceManager")

        // And it is cleared when the hold resolves.
        capture.resolveReconnectGrace(
            now: Date().timeIntervalSince1970 + CaptureManager.reconnectGraceWindow + 1)
        try await Self.waitUntil { capture.active == nil }
        XCTAssertNil(device.interruptedCaptureAtOpen,
                     "the cleared hold never reached DeviceManager")
    }

    /// Generous deadline for the same reason `origin/main`'s `2cd144f` raised
    /// `ConversationCardTests`': a short bound under full-suite load tests the scheduler,
    /// not the behaviour. The assertion is unchanged — the condition must still become true.
    @MainActor
    static func waitUntil(timeout: TimeInterval = 300,
                          _ condition: @escaping @MainActor () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout { return XCTFail("waitUntil timed out") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The rule the plan states: at most one outcome per opened window, and exactly one
    /// only for a window tagged at open as following an interrupted capture.
    func testAtMostOneOutcomePerWindowAndNoneWithoutAnInterruptedCapture() {
        for cause: GapRecoveryWindow.Close in [
            .linkDroppedBeforeEngine,
            .decisionDeadlinePassed,
            .closedWithoutEngine(reason: "superseded"),
            .deviceHasNoStorage,
            .storageUnavailable(reason: "subscribe failed"),
            .engineFinished(.nothingToSync),
        ] {
            var tagged = GapRecoveryWindow(interruptedCaptureId: "cap-1")
            XCTAssertNotNil(tagged.close(cause), "a tagged window published nothing for \(cause)")
            XCTAssertNil(tagged.close(cause), "a second close published a second outcome for \(cause)")
            XCTAssertFalse(tagged.isOpen)

            var untagged = GapRecoveryWindow(interruptedCaptureId: nil)
            XCTAssertNil(untagged.close(cause),
                         "a window that interrupted nothing spoke anyway for \(cause)")
            XCTAssertNil(untagged.published)
        }
    }
}

// MARK: - World

final class DeviceGapRecoveryWorld: @unchecked Sendable {
    var window: GapRecoveryWindow?
    var outcomes: [GapRecoveryOutcome] = []
    /// Every outcome the scenario has seen, including across window re-opens, so
    /// "nothing anywhere claimed a loss" can be asserted over the whole history.
    var history: [GapRecoveryOutcome] = []
    var continuation: GapCaptureContinuation?
    var interruptedCaptureId: String?

    static let conversation = "cap-2026-07-28T0300"

    func open() {
        window = GapRecoveryWindow(interruptedCaptureId: interruptedCaptureId)
        outcomes = []
    }

    func close(_ cause: GapRecoveryWindow.Close) {
        guard var current = window else { return }
        if let outcome = current.close(cause) {
            outcomes.append(outcome)
            history.append(outcome)
        }
        window = current
    }
}

enum DeviceGapRecoverySteps {

    static func ending(named label: String) throws -> OmiOfflineSyncEngine.Outcome {
        switch label {
        case "nothing to sync": return .nothingToSync
        case "a full transfer": return .synced(records: 4, frames: 200)
        case "a transfer with no frames": return .synced(records: 0, frames: 0)
        case "a partial transfer": return .aborted(records: 2, frames: 40, reason: "sync budget exhausted")
        case "a failure": return .failed("link dropped")
        case "a dropped link": return .failed("link dropped")
        case "unsupported firmware": return .unsupportedProtocol("status not ring-shaped")
        default: throw BrineStepError("unknown engine ending: \(label)")
        }
    }

    static func matches(_ outcome: GapRecoveryOutcome, _ label: String) throws -> Bool {
        switch label {
        case "nothing buffered": if case .nothingBuffered = outcome { return true }
        case "recovered": if case .recovered = outcome { return true }
        case "partially recovered": if case .partiallyRecovered = outcome { return true }
        case "still on the device": if case .nothingToRecover = outcome { return true }
        case "unrecoverable": if case .unrecoverable = outcome { return true }
        default: throw BrineStepError("unknown outcome label: \(label)")
        }
        return false
    }

    static func make(world: DeviceGapRecoveryWorld) -> [StepDefinition] {
        [
            defineStep("a conversation was interrupted when the link dropped") { ctx, _, _ in
                world.interruptedCaptureId = DeviceGapRecoveryWorld.conversation
                world.history = []
                return ctx
            },
            defineStep("no conversation was interrupted when the link dropped") { ctx, _, _ in
                world.interruptedCaptureId = nil
                world.history = []
                return ctx
            },
            defineStep("the device reconnects and the gap window opens") { ctx, _, _ in
                world.open()
                guard world.window?.isOpen == true else {
                    throw BrineStepError("the window did not open")
                }
                return ctx
            },
            defineStep("the link drops again before the sync engine starts") { ctx, _, _ in
                world.close(.linkDroppedBeforeEngine)
                return ctx
            },
            defineStep("the storage service never appears and the decision deadline passes") { ctx, _, _ in
                world.close(.decisionDeadlinePassed)
                return ctx
            },
            defineStep("the device turns out to have no offline storage at all") { ctx, _, _ in
                world.close(.deviceHasNoStorage)
                return ctx
            },
            defineStep("the device's stored audio cannot be reached this time") { ctx, _, _ in
                world.close(.storageUnavailable(reason: "subscribe failed"))
                return ctx
            },
            defineStep("the sync engine ends with {string}") { ctx, p, _ in
                world.close(.engineFinished(try ending(named: try p.requireString(0))))
                return ctx
            },
            defineStep("the window is closed twice") { ctx, _, _ in
                world.close(.linkDroppedBeforeEngine)
                world.close(.engineFinished(.synced(records: 9, frames: 900)))
                return ctx
            },
            defineStep("the device reconnects and the same span is pulled back") { ctx, _, _ in
                world.open()
                world.close(.engineFinished(.synced(records: 3, frames: 150)))
                return ctx
            },
            defineCheck("the outcome says the audio is still on the device") { _, _, _ in
                guard let outcome = world.outcomes.last else {
                    throw BrineStepError("no outcome was published at all")
                }
                guard case .nothingToRecover = outcome else {
                    throw BrineStepError("the outcome is \(outcome)")
                }
            },
            defineCheck("the outcome is not a loss") { _, _, _ in
                guard let outcome = world.outcomes.last else {
                    throw BrineStepError("no outcome was published at all")
                }
                guard !outcome.isLoss else { throw BrineStepError("\(outcome) is reported as a loss") }
            },
            defineCheck("the outcome reports the audio as recovered") { _, _, _ in
                guard let outcome = world.outcomes.last else {
                    throw BrineStepError("no outcome was published at all")
                }
                guard case .recovered(let records, let frames) = outcome, records > 0, frames > 0 else {
                    throw BrineStepError("the outcome is \(outcome)")
                }
            },
            defineCheck("no outcome anywhere in this scenario claimed the audio was unrecoverable") { _, _, _ in
                guard world.history.count >= 2 else {
                    throw BrineStepError(
                        "only \(world.history.count) outcome(s) seen — the claim is vacuous")
                }
                let losses = world.history.filter(\.isLoss)
                guard losses.isEmpty else {
                    throw BrineStepError("audio still on the device was reported lost: \(losses)")
                }
            },
            defineCheck("no outcome is published at all") { _, _, _ in
                guard world.outcomes.isEmpty else {
                    throw BrineStepError("a window that interrupted nothing published \(world.outcomes)")
                }
                // The check must be able to see an outcome, or "none" is free: the same
                // close on a TAGGED window must publish exactly one.
                var tagged = GapRecoveryWindow(interruptedCaptureId: "control")
                guard tagged.close(.linkDroppedBeforeEngine) != nil else {
                    throw BrineStepError("no window ever publishes anything — the check is vacuous")
                }
            },
            defineCheck("the outcome reads {string}") { _, p, _ in
                let label = try p.requireString(0)
                guard let outcome = world.outcomes.last else {
                    throw BrineStepError("no outcome was published at all")
                }
                guard try matches(outcome, label) else {
                    throw BrineStepError("the outcome is \(outcome), expected \(label)")
                }
            },
            defineCheck("the outcome is a loss only when the audio is really gone") { _, _, _ in
                guard let outcome = world.outcomes.last else {
                    throw BrineStepError("no outcome was published at all")
                }
                // Only the unrecoverable case may report a loss, and it must.
                if case .unrecoverable = outcome {
                    guard outcome.isLoss else { throw BrineStepError("\(outcome) does not report a loss") }
                } else {
                    guard !outcome.isLoss else { throw BrineStepError("\(outcome) reports a loss") }
                }
            },
            defineCheck("exactly one outcome is published") { _, _, _ in
                guard world.outcomes.count == 1 else {
                    throw BrineStepError("\(world.outcomes.count) outcomes were published: \(world.outcomes)")
                }
            },
            defineCheck("the window still carries that conversation identity") { _, _, _ in
                guard world.window?.interruptedCaptureId == DeviceGapRecoveryWorld.conversation else {
                    throw BrineStepError(
                        "the window carries \(String(describing: world.window?.interruptedCaptureId))")
                }
            },
            defineStep("nothing proposes a different conversation") { ctx, _, _ in
                world.continuation = world.window?.continuation(forProposedCaptureId: nil)
                return ctx
            },
            defineStep("a replacement conversation is proposed") { ctx, _, _ in
                world.continuation = world.window?.continuation(forProposedCaptureId: "cap-REPLACEMENT")
                return ctx
            },
            defineCheck("the original conversation is resumed") { _, _, _ in
                guard world.continuation == .resumeSame(captureId: DeviceGapRecoveryWorld.conversation) else {
                    throw BrineStepError("continuation is \(String(describing: world.continuation))")
                }
            },
            defineCheck("the replacement is refused and the original identity is kept") { _, _, _ in
                guard world.continuation == .refuseReplacement(
                        carrying: DeviceGapRecoveryWorld.conversation, proposed: "cap-REPLACEMENT") else {
                    throw BrineStepError("continuation is \(String(describing: world.continuation))")
                }
            },
            defineCheck("a fresh conversation is opened") { _, _, _ in
                guard world.continuation == .openFresh else {
                    throw BrineStepError("continuation is \(String(describing: world.continuation))")
                }
                // "openFresh" is the value an unimplemented continuation returns for
                // everything, so this arm proves nothing on its own. The same call on a
                // window that IS carrying an identity must resume it.
                let carrying = GapRecoveryWindow(interruptedCaptureId: "control-cap")
                guard carrying.continuation(forProposedCaptureId: nil)
                        == .resumeSame(captureId: "control-cap") else {
                    throw BrineStepError(
                        "continuation answers openFresh even when carrying an identity — the check is vacuous")
                }
            },
        ]
    }
}


// MARK: - helpers

/// Thread-safe collector for outcomes published from `bleQueue`.
final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GapRecoveryOutcome] = []
    func append(_ outcome: GapRecoveryOutcome) {
        lock.lock(); storage.append(outcome); lock.unlock()
    }
    var all: [GapRecoveryOutcome] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}

/// A source the seam test drives directly, same shape the capture suites already use.
final class SeamTestSource: AudioFrameSource, @unchecked Sendable {
    var onFrame: ((Data) -> Void)?
    var onState: ((AudioSourceState) -> Void)?
    func start() {}
    func stop() {}
}
