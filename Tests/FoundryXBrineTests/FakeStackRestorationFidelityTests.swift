import XCTest
import Foundation
@testable import FoundryXKit

/// THE FIXTURE IS THE THING UNDER TEST HERE, AND THAT IS THE POINT.
///
/// `20260821T0153_the_drain_survives_termination` P0.2. Three of its acceptance criteria describe
/// a peripheral iOS restored underneath us — one that may already be connected, already
/// subscribed, and already sending — and a fixture that cannot present one makes those criteria
/// **unrepresentable rather than merely untested**. From a green suite those are indistinguishable,
/// and only one of them is fixed by writing another scenario.
///
/// This repository has paid for that once already: the BLE fake had no time axis and no terminator
/// frame, so a stale-timer kill and a trailing `MCU&OFF` could not be expressed at all, and both
/// shipped.
///
/// WHAT WAS UNFAITHFUL. Production installs the real peripheral delegate ONLY inside
/// `routeEventsToSink()` (`Sources/FoundryXKit/BluetoothSeam.swift:327`). The fake set a
/// `boundToSink` flag there and **nothing ever read it** — `deliver` handed callbacks to the
/// factory-installed sink whenever one existed. A scenario claiming to exercise "a chunk arrived
/// before we were listening" was exercising nothing at all. Found by the cross-vendor plan review.
final class FakeStackRestorationFidelityTests: XCTestCase {

    /// A peripheral delegate callback issued BEFORE the delegate is installed reaches nobody —
    /// which is what a real `CBPeripheral` with no delegate does.
    func testNothingReachesTheAppBeforeItsDelegateIsInstalled() {
        let stack = FakePocketBLEStack(deviceName: "PKT01_BLUE_26079bc5")
        let sink = RecordingSink()
        let queue = DispatchQueue(label: "fidelity")
        _ = stack.factory(sink, queue, nil)

        // The peripheral exists and is asked to read — before anything called routeEventsToSink().
        let peripheral = stack.peripheral!
        XCTAssertFalse(peripheral.boundToSink, "the delegate is installed before the test began")
        peripheral.discoverServices(nil)
        queue.sync {}

        XCTAssertEqual(sink.peripheralCallbacks, 0,
                       "a peripheral callback reached the app with no delegate installed — the "
                           + "fake is unfaithful in exactly the dimension AC13 is about")
        XCTAssertGreaterThanOrEqual(peripheral.suppressedBeforeBinding, 1,
                                    "nothing was suppressed, so the gate is not on the path")
    }

    /// PAIRED EXISTENCE, and without it the assertion above is satisfied by a fake that delivers
    /// nothing ever. Once the delegate IS installed, the same call arrives.
    func testTheSameCallbackArrivesOnceTheDelegateIsInstalled() {
        let stack = FakePocketBLEStack(deviceName: "PKT01_BLUE_26079bc5")
        let sink = RecordingSink()
        let queue = DispatchQueue(label: "fidelity")
        _ = stack.factory(sink, queue, nil)

        let peripheral = stack.peripheral!
        peripheral.routeEventsToSink()
        peripheral.discoverServices(nil)
        queue.sync {}

        XCTAssertGreaterThanOrEqual(sink.peripheralCallbacks, 1,
                                    "nothing arrived even with a delegate installed")
    }

    /// THE HARM AC13 HAS TO SURVIVE, now expressible: a coordinator that installs its delegate
    /// before it is ready to reject stale work receives everything that queued up, at once.
    func testStagedNotificationsArriveInARushWhenTheDelegateIsInstalledCarelessly() {
        let stack = FakePocketBLEStack(deviceName: "PKT01_BLUE_26079bc5")
        let sink = RecordingSink()
        let queue = DispatchQueue(label: "fidelity")
        _ = stack.factory(sink, queue, nil)

        let peripheral = stack.peripheral!
        peripheral.discoverServices(nil)
        peripheral.discoverServices(nil)
        queue.sync {}
        XCTAssertEqual(sink.peripheralCallbacks, 0)

        // The careless order: bind first, then discover you had a backlog.
        peripheral.routeEventsToSink()
        peripheral.flushStagedNotifications()
        queue.sync {}

        XCTAssertEqual(sink.peripheralCallbacks, 2,
                       "the staged callbacks did not arrive, so the window a generation gate has "
                           + "to close cannot be exercised")
    }
    /// P0.1 — THE STATE NO `connect()` CAN PRODUCE.
    ///
    /// A restored peripheral is connected, its service graph is already walked, and its
    /// characteristics are already notifying — because a PREVIOUS process did all of that. The
    /// app is handed the result through `bleCentral(_:willRestore:)`, which the seam has always
    /// declared and no fixture has ever called.
    func testARestoredPeripheralArrivesConnectedAndSubscribedWithoutThisProcessConnecting() {
        let stack = FakePocketBLEStack(deviceName: "PKT01_BLUE_26079bc5")
        let sink = RecordingSink()
        let queue = DispatchQueue(label: "restore")
        _ = stack.factory(sink, queue, nil)

        stack.presentAsRestoredSession()
        queue.sync {}

        XCTAssertEqual(sink.restored.count, 1,
                       "the app was never handed a restored peripheral, so every criterion about "
                           + "restoration is unrepresentable")
        XCTAssertEqual(stack.peripheral.linkState, .connected,
                       "a restored peripheral arrived disconnected")
        let notifying = (stack.peripheral.discoveredServices ?? [])
            .flatMap { ($0.discoveredCharacteristics ?? []) }
            .filter(\.isNotifying)
        XCTAssertGreaterThanOrEqual(notifying.count, 1,
                                    "no characteristic is notifying, so a restored session cannot "
                                        + "deliver the chunk AC1 must refuse to commit")
    }

    /// PAIRED EXISTENCE. A fixture that reports restoration for a stack nobody restored would
    /// satisfy the assertions above on every test in the suite.
    func testAnOrdinaryStackIsNotReportedAsRestored() {
        let stack = FakePocketBLEStack(deviceName: "PKT01_BLUE_26079bc5")
        let sink = RecordingSink()
        let queue = DispatchQueue(label: "restore")
        _ = stack.factory(sink, queue, nil)
        queue.sync {}

        XCTAssertTrue(sink.restored.isEmpty,
                      "a stack nobody restored reported a restored peripheral")
    }
    /// P0.3 — A `.partial` ON DISK THAT NO WRITER IN THIS PROCESS OWNS.
    ///
    /// The state after a mid-write termination, and the one AC1 and AC3 both turn on.
    /// `PocketBringOver` writes arriving bytes to a `<timestamp>.mp3.partial` sibling and takes
    /// the real name only after a verified re-read (`Sources/FoundryXKit/PocketBringOver.swift:146`)
    /// — a genuinely good design, and it means partial bytes are NEVER mistaken for a recording.
    /// What is missing is a reaper: `abandon()` is in-process only, so a kill mid-write leaves the
    /// `.partial` forever and nothing at launch removes it.
    ///
    /// A fixture must be able to produce one WITHOUT a writer, because a `.partial` created by a
    /// live writer is the case AC3 says to LEAVE ALONE. The two are distinguished by provenance,
    /// so the fixture has to be able to make both.
    func testAPartialCanBeStagedWithNoWriterInThisProcess() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("p03-\(UUID().uuidString)", isDirectory: true)
        let store = PocketRecorderFileStore(root: root)
        let key = PocketRecorderFileKey(
            identity: RecordingDeviceIdentity(shape: .filePull, hardwareToken: "t"),
            date: "2026-08-07", timestamp: "20260807142852")

        let orphan = try PocketOrphanedPartial.stage(bytes: 4_096, for: key, in: store)

        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path),
                      "no .partial was staged, so the state after a mid-write kill cannot be set up")
        XCTAssertEqual(orphan.pathExtension, "partial")
        // AND IT IS NOT MISTAKEN FOR A RECORDING — the property the whole design rests on.
        let real = store.url(for: key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.path),
                       "staging a partial produced an .mp3, which would mean partial bytes can be "
                           + "read back as a complete recording")
        let held = await store.alreadyHeld(key)
        XCTAssertFalse(held, "custody claims a file that is only a .partial")
        try? FileManager.default.removeItem(at: root)
    }
    /// P0.4 — TWO PHONES CAN HOLD ONE RECORDER, or AC16 is theatre.
    ///
    /// **The Critical finding of this track's plan review.** The stack kept one sink, one queue and
    /// one central, and the factory overwrote all three on every call — so a second phone could not
    /// exist and AC16's falsification, "two concurrent `SK&` in one recorder transcript", could
    /// never be produced. The criterion would have reported green against any implementation.
    ///
    /// That is the same objection that justified this entire phase for AC1 — a harm the fixture
    /// cannot express is UNREPRESENTABLE, not untested — missed one criterion over, by the author
    /// who had just made it.
    func testASecondCentralDoesNotEraseTheFirst() {
        let stack = FakePocketBLEStack(deviceName: "PKT01_BLUE_26079bc5")
        let phoneA = RecordingSink()
        let phoneB = RecordingSink()
        let queueA = DispatchQueue(label: "phoneA")
        let queueB = DispatchQueue(label: "phoneB")

        _ = stack.factory(phoneA, queueA, nil)
        XCTAssertEqual(stack.attachedCentralCount, 1)

        _ = stack.factory(phoneB, queueB, nil)
        XCTAssertEqual(stack.attachedCentralCount, 2,
                       "the second central replaced the first instead of joining it, so a "
                           + "two-phone race cannot be staged and AC16 cannot fail")
    }

    /// PAIRED EXISTENCE. A counter that only ever goes up would satisfy the assertion above while
    /// counting nothing real; one central must read as one.
    func testOneCentralReadsAsOne() {
        let stack = FakePocketBLEStack(deviceName: "PKT01_BLUE_26079bc5")
        _ = stack.factory(RecordingSink(), DispatchQueue(label: "solo"), nil)
        XCTAssertEqual(stack.attachedCentralCount, 1,
                       "one attached central did not read as one")
    }

    /// AND THE TRANSCRIPT IS SHARED, which is what makes "two concurrent `SK&`" observable at all.
    /// A recorder has one command channel; two phones writing to it produce one interleaved
    /// transcript, and AC16's whole falsification is reading that.
    func testBothPhonesWriteIntoOneRecorderTranscript() {
        let stack = FakePocketBLEStack(deviceName: "PKT01_BLUE_26079bc5")
        _ = stack.factory(RecordingSink(), DispatchQueue(label: "a"), nil)
        _ = stack.factory(RecordingSink(), DispatchQueue(label: "b"), nil)
        XCTAssertEqual(stack.attachedCentralCount, 2)
        XCTAssertNotNil(stack.commandsWritten,
                        "there is no single transcript to read a concurrent SK& out of")
    }
    /// P0.5 — PROVE THE HARNESS ITSELF, which is the only task in this phase that could not be
    /// skipped without the other four becoming decoration.
    ///
    /// Phase 0 closes no acceptance criterion. Its deliverable is that AC1, AC12, AC13 and AC16
    /// become **capable of failing**, and there is exactly one way to know that: build the wrong
    /// implementation on purpose and watch the fixture catch it.
    ///
    /// The coordinator does not exist yet — that is Phase 2 — so the wrong implementation is
    /// modelled here: a consumer that does what a naive rebind of the Omi path would do, which is
    /// take a restored peripheral's bytes and commit them.
    ///
    /// **If this test could not distinguish the naive consumer from a correct one, every scenario
    /// written against this fixture in Phase 2 would be theatre**, and a green suite would say
    /// nothing at all about whether the restored path is safe.
    func testTheFixtureCatchesAConsumerThatCommitsRestoredBytes() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("p05-\(UUID().uuidString)", isDirectory: true)
        let store = PocketRecorderFileStore(root: root)
        let key = PocketRecorderFileKey(
            identity: RecordingDeviceIdentity(shape: .filePull, hardwareToken: "t"),
            date: "2026-08-07", timestamp: "20260807142852")
        try PocketOrphanedPartial.stage(bytes: 4_096, for: key, in: store)

        let stack = FakePocketBLEStack(deviceName: "PKT01_BLUE_26079bc5")
        let sink = RecordingSink()
        let queue = DispatchQueue(label: "p05")
        _ = stack.factory(sink, queue, nil)
        stack.presentAsRestoredSession()
        queue.sync {}

        // THE WRONG IMPLEMENTATION, stated as code rather than described in a comment: it sees a
        // restored peripheral, binds immediately the way DeviceManager:1056 does for Omi, and
        // accepts whatever arrives.
        XCTAssertEqual(sink.restored.count, 1, "nothing to be naive ABOUT")
        stack.peripheral.routeEventsToSink()
        stack.peripheral.flushStagedNotifications()
        stack.peripheral.readValue(for: stack.peripheral.discoveredServices!
            .flatMap { $0.discoveredCharacteristics ?? [] }.first!)
        queue.sync {}

        // THE FIXTURE'S ANSWER: bytes reached a consumer that had no writer, no meter and no
        // expected byte count. A correct coordinator must make this count zero by refusing at
        // ingress, and Phase 2's AC13 is that refusal.
        XCTAssertGreaterThanOrEqual(sink.peripheralCallbacks, 1,
                                    "a naive consumer received NOTHING from a restored peripheral, "
                                        + "so this fixture cannot tell a safe coordinator from an "
                                        + "unsafe one and every Phase 2 scenario would be theatre")

        // AND THE WRECKAGE IS STILL THERE TO BE MISHANDLED — the orphan a correct sweep removes
        // and a naive one either commits or leaves forever.
        let orphan = store.url(for: key).appendingPathExtension("partial")
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path),
                      "the staged partial vanished, so AC3 has nothing to act on")
        let held = await store.alreadyHeld(key)
        XCTAssertFalse(held, "custody already claims the file, so AC1 cannot observe a wrong commit")
        try? FileManager.default.removeItem(at: root)
    }
}

/// STAGE THE WRECKAGE OF A TERMINATED TRANSFER.
///
/// Deliberately not a method on `PocketRecorderFileWriter`: a writer that can produce this has an
/// owning process, and the whole point is a `.partial` with none. It writes the file the way a
/// half-finished transfer leaves it and nothing else — no custody record, no receipt.
enum PocketOrphanedPartial {
    @discardableResult
    static func stage(bytes: Int, for key: PocketRecorderFileKey,
                      in store: PocketRecorderFileStore) throws -> URL {
        let real = store.url(for: key)
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let partial = real.appendingPathExtension("partial")
        try Data(repeating: 0x5A, count: bytes).write(to: partial)
        return partial
    }
}

/// Counts what the application layer was actually handed. Deliberately minimal: the question is
/// only ever "did anything reach the app", never what it contained.
private final class RecordingSink: BLEEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var peripheralCallbacks: Int { lock.lock(); defer { lock.unlock() }; return count }
    private func note() { lock.lock(); count += 1; lock.unlock() }

    /// RECORDED SEPARATELY FROM EVERYTHING ELSE, because this is the one the whole track turns
    /// on: the seam already declares it and the fake has never called it.
    private(set) var restored: [BLEPeripheral] = []
    func bleCentral(_ central: BLECentral, willRestore peripherals: [BLEPeripheral]) {
        lock.lock(); restored.append(contentsOf: peripherals); lock.unlock()
    }
    func bleCentralDidUpdateState(_ central: BLECentral) {}
    func bleCentral(_ central: BLECentral, didDiscover peripheral: BLEPeripheral, rssi: Int) {}
    func bleCentral(_ central: BLECentral, didConnect peripheral: BLEPeripheral) {}
    func bleCentral(_ central: BLECentral, didFailToConnect peripheral: BLEPeripheral,
                    error: Error?) {}
    func bleCentral(_ central: BLECentral, didDisconnect peripheral: BLEPeripheral,
                    error: Error?) {}
    func blePeripheral(_ peripheral: BLEPeripheral, didDiscoverServices error: Error?) { note() }
    func blePeripheral(_ peripheral: BLEPeripheral, didDiscoverCharacteristicsFor service: BLEService,
                       error: Error?) { note() }
    func blePeripheral(_ peripheral: BLEPeripheral, didUpdateValueFor characteristic: BLECharacteristic,
                       error: Error?) { note() }
    func blePeripheral(_ peripheral: BLEPeripheral,
                       didUpdateNotificationStateFor characteristic: BLECharacteristic,
                       error: Error?) { note() }
}
