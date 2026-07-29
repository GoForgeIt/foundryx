// BluetoothSeam.swift — the injectable CoreBluetooth seam.
//
// WHY THIS EXISTS. `DeviceManager` is the only place in the app where a link drop becomes
// a re-issued pending connect and a rediscovered audio characteristic becomes
// `.streaming`. Every assertion about that chain used to stop at `OmiReconnectPolicy` (a
// pure function that decides but executes nothing) because the executing half is written
// against four CoreBluetooth types that a test cannot construct:
//
//   • `CBCentralManager` can be constructed, but it drives a real radio;
//   • `CBPeripheral`, `CBService` and `CBCharacteristic` have `NS_UNAVAILABLE`
//     initializers — there is no supported way to make one, and no way to make one
//     *report* a service or a characteristic that a device did not really advertise.
//
// So the seam wraps ALL FOUR. Wrapping only the central would leave the discovery half
// (services → characteristics → `.streaming`) undrivable, which is exactly the half that
// carries continuity. `DeviceManager` stores and passes only these protocol types; the
// production adapter below is the single place that touches CoreBluetooth.
//
// THREADING. Unchanged from the shipped design: the adapter hands the queue it was given
// straight to `CBCentralManager`, so every sink callback is delivered on `DeviceManager`'s
// `bleQueue` exactly as before. A fake must do the same — the funnel's
// `dispatchPrecondition(.onQueue(bleQueue))` is what makes that non-negotiable.

#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

// MARK: - The four wrapped types

/// A discovered GATT characteristic. Read-only: everything that ACTS on a characteristic
/// is issued through its peripheral, mirroring CoreBluetooth.
public protocol BLECharacteristic: AnyObject {
    var uuid: CBUUID { get }
    var value: Data? { get }
    var isNotifying: Bool { get }
}

/// A discovered GATT service.
public protocol BLEService: AnyObject {
    var uuid: CBUUID { get }
    /// `CBService.characteristics` — nil until characteristics have been discovered.
    var discoveredCharacteristics: [BLECharacteristic]? { get }
}

/// A peripheral handle. `linkState` and `discoveredServices` are the two pieces of
/// CoreBluetooth-owned state the reconnect chain reads back (restored-peripheral policy
/// and the storage-service check both depend on them).
public protocol BLEPeripheral: AnyObject {
    var identifier: UUID { get }
    var name: String? { get }
    /// `CBPeripheral.state`.
    var linkState: CBPeripheralState { get }
    /// `CBPeripheral.services` — a cache that survives a failed rediscovery.
    var discoveredServices: [BLEService]? { get }

    /// Deliver this peripheral's events to the owning central's sink. Production:
    /// `cb.delegate = adapter`. This is the seam's form of `p.delegate = self`, and it is
    /// a distinct, observable call precisely so `bind(_:)` cannot be deleted silently.
    func routeEventsToSink()

    func discoverServices(_ serviceUUIDs: [CBUUID]?)
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: BLEService)
    func readValue(for characteristic: BLECharacteristic)
    func writeValue(_ data: Data, for characteristic: BLECharacteristic,
                    type: CBCharacteristicWriteType)
    func setNotifyValue(_ enabled: Bool, for characteristic: BLECharacteristic)
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int
}

/// The central manager.
public protocol BLECentral: AnyObject {
    /// `CBCentralManager.state`.
    var managerState: CBManagerState { get }
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [BLEPeripheral]
    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?)
    func stopScan()
    func connect(_ peripheral: BLEPeripheral, options: [String: Any]?)
    func cancelPeripheralConnection(_ peripheral: BLEPeripheral)
}

// MARK: - The sink

/// Everything `DeviceManager` used to receive as `CBCentralManagerDelegate` /
/// `CBPeripheralDelegate`, restated in seam types. One-to-one with the CoreBluetooth
/// callbacks the shipped code actually implements — nothing added, nothing collapsed, so
/// the production adapter stays a forward and the behaviour under test is the real one.
public protocol BLEEventSink: AnyObject {
    func bleCentral(_ central: BLECentral, willRestore peripherals: [BLEPeripheral])
    func bleCentralDidUpdateState(_ central: BLECentral)
    func bleCentral(_ central: BLECentral, didDiscover peripheral: BLEPeripheral, rssi: Int)
    func bleCentral(_ central: BLECentral, didConnect peripheral: BLEPeripheral)
    func bleCentral(_ central: BLECentral, didFailToConnect peripheral: BLEPeripheral, error: Error?)
    func bleCentral(_ central: BLECentral, didDisconnect peripheral: BLEPeripheral, error: Error?)
    func blePeripheral(_ peripheral: BLEPeripheral, didDiscoverServices error: Error?)
    func blePeripheral(_ peripheral: BLEPeripheral,
                       didDiscoverCharacteristicsFor service: BLEService, error: Error?)
    func blePeripheral(_ peripheral: BLEPeripheral,
                       didUpdateNotificationStateFor characteristic: BLECharacteristic, error: Error?)
    func blePeripheral(_ peripheral: BLEPeripheral,
                       didUpdateValueFor characteristic: BLECharacteristic, error: Error?)
}

/// How `DeviceManager` obtains its central. The app never passes one; the S04 acceptance
/// proof passes a fake that drives the same sink on the same queue.
///
/// `restoreIdentifier` is non-nil only where CoreBluetooth state restoration exists (iOS);
/// the adapter creates the manager with or without the restore option accordingly.
public typealias BLECentralFactory =
    (_ sink: BLEEventSink, _ queue: DispatchQueue, _ restoreIdentifier: String?) -> BLECentral

// MARK: - The production adapter (the only CoreBluetooth-touching code)

/// Wraps a real `CBCentralManager` and the real `CBPeripheral` / `CBService` /
/// `CBCharacteristic` objects it vends.
///
/// IDENTITY. Wrappers are cached — peripherals by `identifier`, services and
/// characteristics by the object identity of the CoreBluetooth object they wrap — so the
/// same physical device/service/characteristic is always the same seam object. Without
/// that, `storageDataChar === the characteristic that just notified` would stop holding
/// and the ring-sync bookkeeping would silently drift.
public final class CoreBluetoothCentral: NSObject, BLECentral,
                                         CBCentralManagerDelegate, CBPeripheralDelegate {

    /// The default `BLECentralFactory`.
    public static func make(sink: BLEEventSink, queue: DispatchQueue,
                            restoreIdentifier: String?) -> BLECentral {
        CoreBluetoothCentral(sink: sink, queue: queue, restoreIdentifier: restoreIdentifier)
    }

    private weak var sink: BLEEventSink?
    private var manager: CBCentralManager!
    private let wrapperLock = NSLock()
    private var wrappedPeripherals: [UUID: CoreBluetoothPeripheral] = [:]

    private init(sink: BLEEventSink, queue: DispatchQueue, restoreIdentifier: String?) {
        self.sink = sink
        super.init()
        if let restoreIdentifier {
            manager = CBCentralManager(
                delegate: self, queue: queue,
                options: [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier])
        } else {
            manager = CBCentralManager(delegate: self, queue: queue)
        }
    }

    // MARK: wrapping / unwrapping

    fileprivate func wrap(_ peripheral: CBPeripheral) -> CoreBluetoothPeripheral {
        wrapperLock.lock(); defer { wrapperLock.unlock() }
        if let existing = wrappedPeripherals[peripheral.identifier] {
            existing.adopt(peripheral)
            return existing
        }
        let made = CoreBluetoothPeripheral(cb: peripheral, owner: self)
        wrappedPeripherals[peripheral.identifier] = made
        return made
    }

    /// THE INVARIANT. This adapter only ever hands out `CoreBluetoothPeripheral`, and
    /// `DeviceManager` only ever hands back objects it received from its own central. A
    /// foreign type here means two seam implementations were mixed in one manager, which
    /// is a wiring error with no correct recovery — a silent `return` would turn it into a
    /// device that never connects and never says why.
    private func unwrap(_ peripheral: BLEPeripheral) -> CBPeripheral {
        guard let mine = peripheral as? CoreBluetoothPeripheral else {
            preconditionFailure(
                "CoreBluetoothCentral received a \(type(of: peripheral)); the BLE seam "
                    + "implementations were mixed within one DeviceManager")
        }
        return mine.cb
    }

    // MARK: BLECentral

    public var managerState: CBManagerState { manager.state }

    public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [BLEPeripheral] {
        manager.retrievePeripherals(withIdentifiers: identifiers).map { wrap($0) }
    }

    public func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?,
                                   options: [String: Any]?) {
        manager.scanForPeripherals(withServices: serviceUUIDs, options: options)
    }

    public func stopScan() { manager.stopScan() }

    public func connect(_ peripheral: BLEPeripheral, options: [String: Any]?) {
        manager.connect(unwrap(peripheral), options: options)
    }

    public func cancelPeripheralConnection(_ peripheral: BLEPeripheral) {
        manager.cancelPeripheralConnection(unwrap(peripheral))
    }

    // MARK: CBCentralManagerDelegate — pure forwards

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        sink?.bleCentral(self, willRestore: restored.map { wrap($0) })
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        sink?.bleCentralDidUpdateState(self)
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        sink?.bleCentral(self, didDiscover: wrap(peripheral), rssi: RSSI.intValue)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        sink?.bleCentral(self, didConnect: wrap(peripheral))
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        sink?.bleCentral(self, didFailToConnect: wrap(peripheral), error: error)
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        sink?.bleCentral(self, didDisconnect: wrap(peripheral), error: error)
    }

    // MARK: CBPeripheralDelegate — pure forwards

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        sink?.blePeripheral(wrap(peripheral), didDiscoverServices: error)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let wrapped = wrap(peripheral)
        sink?.blePeripheral(wrapped, didDiscoverCharacteristicsFor: wrapped.wrap(service),
                            error: error)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        let wrapped = wrap(peripheral)
        sink?.blePeripheral(wrapped, didUpdateNotificationStateFor: wrapped.wrap(characteristic),
                            error: error)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let wrapped = wrap(peripheral)
        sink?.blePeripheral(wrapped, didUpdateValueFor: wrapped.wrap(characteristic), error: error)
    }
}

/// The `CBPeripheral` wrapper. Owns the service/characteristic wrapper caches for its own
/// peripheral, because CoreBluetooth scopes both to the peripheral.
final class CoreBluetoothPeripheral: BLEPeripheral {
    fileprivate private(set) var cb: CBPeripheral
    /// The central owns this wrapper; the back-reference exists to install the peripheral
    /// delegate and must not keep the central alive.
    private unowned let owner: CoreBluetoothCentral
    private let lock = NSLock()
    private var wrappedServices: [ObjectIdentifier: CoreBluetoothService] = [:]
    private var wrappedCharacteristics: [ObjectIdentifier: CoreBluetoothCharacteristic] = [:]

    init(cb: CBPeripheral, owner: CoreBluetoothCentral) {
        self.cb = cb
        self.owner = owner
    }

    /// CoreBluetooth normally vends one object per peripheral for the life of the central,
    /// but `retrievePeripherals` after a restore can hand back a fresh object for the same
    /// identifier. Domain identity is the identifier, so the wrapper adopts the new handle
    /// rather than becoming a second identity for one device.
    func adopt(_ peripheral: CBPeripheral) {
        guard peripheral !== cb else { return }
        lock.lock()
        cb = peripheral
        wrappedServices.removeAll()
        wrappedCharacteristics.removeAll()
        lock.unlock()
    }

    fileprivate func wrap(_ service: CBService) -> CoreBluetoothService {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(service)
        if let existing = wrappedServices[key] { return existing }
        let made = CoreBluetoothService(cb: service, peripheral: self)
        wrappedServices[key] = made
        return made
    }

    fileprivate func wrap(_ characteristic: CBCharacteristic) -> CoreBluetoothCharacteristic {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(characteristic)
        if let existing = wrappedCharacteristics[key] { return existing }
        let made = CoreBluetoothCharacteristic(cb: characteristic)
        wrappedCharacteristics[key] = made
        return made
    }

    private func unwrap(_ service: BLEService) -> CBService {
        guard let mine = service as? CoreBluetoothService else {
            preconditionFailure(
                "CoreBluetoothPeripheral received a \(type(of: service)); the BLE seam "
                    + "implementations were mixed within one DeviceManager")
        }
        return mine.cb
    }

    private func unwrap(_ characteristic: BLECharacteristic) -> CBCharacteristic {
        guard let mine = characteristic as? CoreBluetoothCharacteristic else {
            preconditionFailure(
                "CoreBluetoothPeripheral received a \(type(of: characteristic)); the BLE "
                    + "seam implementations were mixed within one DeviceManager")
        }
        return mine.cb
    }

    // MARK: BLEPeripheral

    var identifier: UUID { cb.identifier }
    var name: String? { cb.name }
    var linkState: CBPeripheralState { cb.state }
    var discoveredServices: [BLEService]? { cb.services.map { $0.map { wrap($0) } } }

    func routeEventsToSink() { cb.delegate = owner }

    func discoverServices(_ serviceUUIDs: [CBUUID]?) { cb.discoverServices(serviceUUIDs) }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: BLEService) {
        cb.discoverCharacteristics(characteristicUUIDs, for: unwrap(service))
    }

    func readValue(for characteristic: BLECharacteristic) {
        cb.readValue(for: unwrap(characteristic))
    }

    func writeValue(_ data: Data, for characteristic: BLECharacteristic,
                    type: CBCharacteristicWriteType) {
        cb.writeValue(data, for: unwrap(characteristic), type: type)
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: BLECharacteristic) {
        cb.setNotifyValue(enabled, for: unwrap(characteristic))
    }

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
        cb.maximumWriteValueLength(for: type)
    }
}

final class CoreBluetoothService: BLEService {
    fileprivate let cb: CBService
    private unowned let peripheral: CoreBluetoothPeripheral

    init(cb: CBService, peripheral: CoreBluetoothPeripheral) {
        self.cb = cb
        self.peripheral = peripheral
    }

    var uuid: CBUUID { cb.uuid }
    var discoveredCharacteristics: [BLECharacteristic]? {
        cb.characteristics.map { $0.map { peripheral.wrap($0) } }
    }
}

final class CoreBluetoothCharacteristic: BLECharacteristic {
    fileprivate let cb: CBCharacteristic

    init(cb: CBCharacteristic) { self.cb = cb }

    var uuid: CBUUID { cb.uuid }
    var value: Data? { cb.value }
    var isNotifying: Bool { cb.isNotifying }
}

#endif
