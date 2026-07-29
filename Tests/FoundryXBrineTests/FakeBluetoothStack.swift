import Foundation
import CoreBluetooth
@testable import FoundryXKit

/// A scripted BLE device behind the T4 seam (track 20260725T2306, task T4).
///
/// WHAT IT IS FOR. `DeviceManager` turns a link drop into a re-issued pending connect and a
/// rediscovered audio characteristic into `.streaming`. Before the seam nothing could drive
/// that sequence: `CBPeripheral`, `CBService` and `CBCharacteristic` all have
/// `NS_UNAVAILABLE` initializers, so no test could make a peripheral report a service or a
/// service report a characteristic. This is that peripheral.
///
/// IT MODELS THE TRANSPORT, NOT THE OUTCOME. Every response here is what CoreBluetooth
/// itself does — `discoverServices` populates `services` and then fires
/// `didDiscoverServices`; `setNotifyValue` flips `isNotifying` and then fires
/// `didUpdateNotificationStateFor`; a connect issued against an out-of-range device stays
/// PENDING with no timeout and completes when the device returns. Nothing here decides
/// anything about reconnecting, resuming, or continuity: those decisions stay in the
/// production code under test, which is the entire point.
///
/// THREADING. Callbacks are delivered with `queue.async` on the very queue
/// `DeviceManager` handed the factory — its `bleQueue`. That is what the shipped
/// `CBCentralManager(delegate:queue:)` does, and it is what makes
/// `beginGapSyncWindow()`'s `dispatchPrecondition(.onQueue(bleQueue))` hold. Delivering
/// synchronously from the caller's thread would satisfy the assertions while testing a
/// threading model the app does not have.
final class FakeBLEStack: @unchecked Sendable {

    /// Everything an assertion can see the production code DO to the transport.
    enum Event: Equatable, CustomStringConvertible {
        case centralCreated
        case scanStarted
        case scanStopped
        case connectIssued
        case connectCancelled
        case peripheralBound
        case servicesRequested([CBUUID])
        case characteristicsRequested(CBUUID)
        case notifySet(CBUUID, Bool)
        case valueRead(CBUUID)
        case valueWritten(CBUUID)

        var description: String {
            switch self {
            case .centralCreated: return "centralCreated"
            case .scanStarted: return "scanStarted"
            case .scanStopped: return "scanStopped"
            case .connectIssued: return "connectIssued"
            case .connectCancelled: return "connectCancelled"
            case .peripheralBound: return "peripheralBound"
            case .servicesRequested(let u): return "servicesRequested(\(u.map(\.uuidString)))"
            case .characteristicsRequested(let u): return "characteristicsRequested(\(u.uuidString))"
            case .notifySet(let u, let on): return "notifySet(\(u.uuidString), \(on))"
            case .valueRead(let u): return "valueRead(\(u.uuidString))"
            case .valueWritten(let u): return "valueWritten(\(u.uuidString))"
            }
        }
    }

    // MARK: construction

    let deviceId: UUID
    let deviceName: String
    private(set) var peripheral: FakeBLEPeripheral!

    private let lock = NSLock()
    private var events: [Event] = []
    private weak var sink: BLEEventSink?
    private var queue: DispatchQueue?
    private var central: FakeBLECentral?
    /// A connect issued while the device is out of range stays pending — exactly like a
    /// real `CBCentralManager.connect`, which has no timeout.
    private var pendingConnect = false
    private var inRange = true
    private var poweredOn = true
    private var announceStateOnCreation = true

    /// What the device advertises for onboard storage.
    enum StorageShape {
        /// No storage service at all — service discovery answers "this device keeps
        /// nothing while disconnected" and the gap window closes on the spot.
        case absent
        /// The service is there and its DATA characteristic subscribes, but the CONTROL
        /// characteristic never appears. `maybeBeginGapSync` requires both, so no engine
        /// is ever created and the gap window STAYS OPEN, holding, until its decision
        /// deadline. That is the only stable way to observe an open tagged window, which
        /// is what the N7 probe needs.
        case dataCharacteristicOnly
    }

    /// A stock Omi: the audio service with its data + codec characteristics, and by default
    /// no onboard storage service (a device that keeps nothing while disconnected — the
    /// shape T3 already covers by outcome).
    init(deviceId: UUID = UUID(), deviceName: String = "Omi", storage: StorageShape = .absent,
         announceStateOnCreation: Bool = true) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.announceStateOnCreation = announceStateOnCreation
        let audio = FakeBLEService(
            OmiUUID.audioService,
            characteristics: [FakeBLECharacteristic(OmiUUID.audioDataChar),
                              FakeBLECharacteristic(OmiUUID.codecChar, value: Data([1]))])
        var services = [audio]
        if case .dataCharacteristicOnly = storage {
            services.append(FakeBLEService(
                OmiUUID.storageService,
                characteristics: [FakeBLECharacteristic(OmiUUID.storageDataChar)]))
        }
        peripheral = FakeBLEPeripheral(identifier: deviceId, name: deviceName,
                                       services: services, stack: self)
    }

    /// The firmware comes back WITHOUT its audio stream. The service is still advertised,
    /// so the connect and the service discovery both succeed — only `.streaming` never
    /// arrives, which is the state a "capture resumed" assertion must be able to see.
    func loseAudioStream() {
        for service in peripheral.catalog where service.uuid == OmiUUID.audioService {
            service.removeCharacteristic(OmiUUID.audioDataChar)
        }
    }

    /// The `BLECentralFactory` to hand `DeviceManager(makeCentral:)`.
    ///
    /// `announceStateOnCreation` models the ordinary launch, where CoreBluetooth reports the
    /// manager's state right after creation. A STATE-RESTORATION launch is different and the
    /// difference is the whole point: iOS delivers `willRestoreState` FIRST, while the
    /// central is not yet `poweredOn`, and only then reports `poweredOn`. Announcing the
    /// state eagerly would make the restored peripheral arrive too late to be acted on,
    /// which is not how the shipped code is reached.
    var factory: BLECentralFactory {
        { [weak self] sink, queue, _ in
            guard let self else {
                fatalError("the fake BLE stack was released before DeviceManager asked for a central")
            }
            let made = FakeBLECentral(stack: self)
            self.lock.lock()
            self.sink = sink
            self.queue = queue
            self.central = made
            self.events.append(.centralCreated)
            let announce = self.announceStateOnCreation
            self.lock.unlock()
            if announce { self.deliver { $0.bleCentralDidUpdateState(made) } }
            return made
        }
    }

    /// CB STATE RESTORATION: iOS relaunched the process because an event fired for this
    /// central, and hands the peripherals back BEFORE the manager reports `poweredOn`.
    /// `state` is the peripheral's link state at reclaim — `.connected` is the case that
    /// matters, because the link SURVIVED the process death and re-issuing a connect on it
    /// would throw away a live connection instead of rediscovering its services.
    func restoreState(peripheralState state: CBPeripheralState = .connected) {
        peripheral.setLinkState(state)
        let central = currentCentral
        deliver { sink in
            guard let central else { return }
            sink.bleCentral(central, willRestore: [self.peripheral])
        }
    }

    /// The central reports `poweredOn`. On a restoration launch this is what releases the
    /// reclaimed peripheral into the restore policy.
    func powerOn() {
        let central = currentCentral
        deliver { sink in
            guard let central else { return }
            sink.bleCentralDidUpdateState(central)
        }
    }

    // MARK: event log

    func record(_ event: Event) {
        lock.lock(); events.append(event); lock.unlock()
    }

    var log: [Event] {
        lock.lock(); defer { lock.unlock() }; return events
    }

    func count(of event: Event) -> Int {
        log.filter { $0 == event }.count
    }

    func clearLog() {
        lock.lock(); events.removeAll(); lock.unlock()
    }

    // MARK: delivery

    fileprivate func deliver(_ body: @escaping (BLEEventSink) -> Void) {
        lock.lock()
        let queue = self.queue
        lock.unlock()
        guard let queue else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let sink = self.sink
            self.lock.unlock()
            guard let sink else { return }
            body(sink)
        }
    }

    fileprivate var currentCentral: FakeBLECentral? {
        lock.lock(); defer { lock.unlock() }; return central
    }

    var managerState: CBManagerState {
        lock.lock(); defer { lock.unlock() }
        return poweredOn ? .poweredOn : .poweredOff
    }

    // MARK: the transport's own behaviour

    fileprivate func issueConnect() {
        record(.connectIssued)
        lock.lock()
        pendingConnect = true
        let canComplete = inRange
        lock.unlock()
        if canComplete { completePendingConnect() }
    }

    /// The device comes back into range: any standing pending connect completes. This is
    /// the whole reason the shipped policy re-issues `connect` instead of scanning.
    func bringDeviceIntoRange() {
        lock.lock()
        inRange = true
        let hasPending = pendingConnect
        lock.unlock()
        if hasPending { completePendingConnect() }
    }

    func takeDeviceOutOfRange() {
        lock.lock(); inRange = false; lock.unlock()
    }

    private func completePendingConnect() {
        lock.lock()
        guard pendingConnect else { lock.unlock(); return }
        pendingConnect = false
        lock.unlock()
        peripheral.setLinkState(.connected)
        let central = currentCentral
        deliver { sink in
            guard let central else { return }
            sink.bleCentral(central, didConnect: self.peripheral)
        }
    }

    var hasPendingConnect: Bool {
        lock.lock(); defer { lock.unlock() }; return pendingConnect
    }

    /// The SYSTEM link drop: the device walked out of range. No user gesture, no app event.
    func dropLink(reason: String = "the device went out of range") {
        takeDeviceOutOfRange()
        peripheral.forgetDiscoveredGraph()
        peripheral.setLinkState(.disconnected)
        let central = currentCentral
        deliver { sink in
            guard let central else { return }
            sink.bleCentral(central, didDisconnect: self.peripheral,
                            error: NSError(domain: "FakeBLE", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: reason]))
        }
    }

    fileprivate func cancelConnection() {
        record(.connectCancelled)
        lock.lock(); pendingConnect = false; lock.unlock()
        peripheral.forgetDiscoveredGraph()
        peripheral.setLinkState(.disconnected)
        let central = currentCentral
        deliver { sink in
            guard let central else { return }
            sink.bleCentral(central, didDisconnect: self.peripheral, error: nil)
        }
    }

    /// Push one Opus payload up the audio characteristic, header and all, exactly as the
    /// firmware notifies it. `DeviceManager` strips the 3-byte `[seq:2][index:1]` header.
    func deliverAudioFrames(_ frame: Data, count: Int) {
        guard let audio = peripheral.discoveredCharacteristic(OmiUUID.audioDataChar) else { return }
        for i in 0..<count {
            let header = Data([UInt8(i & 0xff), UInt8((i >> 8) & 0xff), 0])
            let payload = header + frame
            deliver { [weak self] sink in
                guard let self else { return }
                audio.value = payload
                sink.blePeripheral(self.peripheral, didUpdateValueFor: audio, error: nil)
            }
        }
    }

    /// Wait until every callback queued so far has been delivered. The queue is serial, so
    /// a barrier `sync` is an exact "the transport has caught up" — no polling, no sleep.
    func drain() {
        lock.lock()
        let queue = self.queue
        lock.unlock()
        queue?.sync {}
    }
}

// MARK: - The four wrapped types, faked

final class FakeBLECharacteristic: BLECharacteristic, @unchecked Sendable {
    let uuid: CBUUID
    private let lock = NSLock()
    private var storedValue: Data?
    private var notifying = false

    init(_ uuid: CBUUID, value: Data? = nil) {
        self.uuid = uuid
        self.storedValue = value
    }

    var value: Data? {
        get { lock.lock(); defer { lock.unlock() }; return storedValue }
        set { lock.lock(); storedValue = newValue; lock.unlock() }
    }

    var isNotifying: Bool {
        get { lock.lock(); defer { lock.unlock() }; return notifying }
        set { lock.lock(); notifying = newValue; lock.unlock() }
    }
}

final class FakeBLEService: BLEService, @unchecked Sendable {
    let uuid: CBUUID
    private let lock = NSLock()
    /// What the device HAS — invisible until discovery asks for it.
    private var catalog: [FakeBLECharacteristic]
    private var discovered: [FakeBLECharacteristic]?

    init(_ uuid: CBUUID, characteristics: [FakeBLECharacteristic]) {
        self.uuid = uuid
        self.catalog = characteristics
    }

    /// Firmware that stops exposing a characteristic. The service is still advertised, so
    /// the reconnect and the service discovery both succeed and only the stream is missing.
    func removeCharacteristic(_ uuid: CBUUID) {
        lock.lock(); catalog.removeAll { $0.uuid == uuid }; lock.unlock()
    }

    /// nil until `discoverCharacteristics` has run, exactly like `CBService`.
    var discoveredCharacteristics: [BLECharacteristic]? {
        lock.lock(); defer { lock.unlock() }
        return discovered
    }

    fileprivate func discover(_ uuids: [CBUUID]?) -> [FakeBLECharacteristic] {
        lock.lock()
        let found = catalog.filter { uuids?.contains($0.uuid) ?? true }
        discovered = found
        lock.unlock()
        return found
    }

    fileprivate func forgetDiscovered() {
        lock.lock(); discovered = nil; lock.unlock()
    }
}

final class FakeBLEPeripheral: BLEPeripheral, @unchecked Sendable {
    let identifier: UUID
    let name: String?
    /// What the device HAS — invisible until discovery asks for it.
    let catalog: [FakeBLEService]
    private unowned let stack: FakeBLEStack
    private let lock = NSLock()
    private var state: CBPeripheralState = .disconnected
    private var discovered: [FakeBLEService]?
    private var bound = false

    init(identifier: UUID, name: String?, services: [FakeBLEService], stack: FakeBLEStack) {
        self.identifier = identifier
        self.name = name
        self.catalog = services
        self.stack = stack
    }

    var linkState: CBPeripheralState {
        lock.lock(); defer { lock.unlock() }; return state
    }

    fileprivate func setLinkState(_ s: CBPeripheralState) {
        lock.lock(); state = s; lock.unlock()
    }

    var discoveredServices: [BLEService]? {
        lock.lock(); defer { lock.unlock() }
        return discovered
    }

    /// A dropped link invalidates the discovered graph — the next connect must rediscover
    /// it. Keeping a stale graph would let a broken reconnect look like a working one.
    fileprivate func forgetDiscoveredGraph() {
        lock.lock(); discovered = nil; lock.unlock()
        for service in catalog { service.forgetDiscovered() }
    }

    func discoveredCharacteristic(_ uuid: CBUUID) -> FakeBLECharacteristic? {
        lock.lock()
        let services = discovered ?? []
        lock.unlock()
        for service in services {
            if let match = (service.discoveredCharacteristics as? [FakeBLECharacteristic])?
                .first(where: { $0.uuid == uuid }) {
                return match
            }
        }
        return nil
    }

    // MARK: BLEPeripheral

    /// True once `DeviceManager.bind(_:)` routed this peripheral's events to the sink.
    var boundToSink: Bool {
        lock.lock(); defer { lock.unlock() }; return bound
    }

    func routeEventsToSink() {
        lock.lock(); bound = true; lock.unlock()
        stack.record(.peripheralBound)
    }

    func discoverServices(_ serviceUUIDs: [CBUUID]?) {
        stack.record(.servicesRequested(serviceUUIDs ?? []))
        let found = catalog.filter { serviceUUIDs?.contains($0.uuid) ?? true }
        lock.lock(); discovered = found; lock.unlock()
        stack.deliver { [weak self] sink in
            guard let self else { return }
            sink.blePeripheral(self, didDiscoverServices: nil)
        }
    }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: BLEService) {
        guard let service = service as? FakeBLEService else {
            fatalError("the fake peripheral was handed a \(type(of: service))")
        }
        stack.record(.characteristicsRequested(service.uuid))
        _ = service.discover(characteristicUUIDs)
        stack.deliver { [weak self] sink in
            guard let self else { return }
            sink.blePeripheral(self, didDiscoverCharacteristicsFor: service, error: nil)
        }
    }

    func readValue(for characteristic: BLECharacteristic) {
        stack.record(.valueRead(characteristic.uuid))
        stack.deliver { [weak self] sink in
            guard let self else { return }
            sink.blePeripheral(self, didUpdateValueFor: characteristic, error: nil)
        }
    }

    func writeValue(_ data: Data, for characteristic: BLECharacteristic,
                    type: CBCharacteristicWriteType) {
        stack.record(.valueWritten(characteristic.uuid))
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: BLECharacteristic) {
        stack.record(.notifySet(characteristic.uuid, enabled))
        (characteristic as? FakeBLECharacteristic)?.isNotifying = enabled
        stack.deliver { [weak self] sink in
            guard let self else { return }
            sink.blePeripheral(self, didUpdateNotificationStateFor: characteristic, error: nil)
        }
    }

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 180 }
}

final class FakeBLECentral: BLECentral, @unchecked Sendable {
    private unowned let stack: FakeBLEStack

    init(stack: FakeBLEStack) { self.stack = stack }

    var managerState: CBManagerState { stack.managerState }

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [BLEPeripheral] {
        identifiers.contains(stack.deviceId) ? [stack.peripheral] : []
    }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
        stack.record(.scanStarted)
    }

    func stopScan() { stack.record(.scanStopped) }

    func connect(_ peripheral: BLEPeripheral, options: [String: Any]?) {
        stack.issueConnect()
    }

    func cancelPeripheralConnection(_ peripheral: BLEPeripheral) {
        stack.cancelConnection()
    }
}

/// Thread-safe collector for `AudioSourceState` emissions, which arrive on `bleQueue`.
final class SourceStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AudioSourceState] = []
    func append(_ state: AudioSourceState) {
        lock.lock(); storage.append(state); lock.unlock()
    }
    var all: [AudioSourceState] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}
