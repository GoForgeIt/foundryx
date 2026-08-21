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
