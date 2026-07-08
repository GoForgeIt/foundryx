import Foundation

/// A discovered BLE peripheral that advertises the standard Battery Service.
public struct BatteryDevice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let rssi: Int

    public init(id: UUID, name: String, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

/// Pure helpers shared by the iOS CoreBluetooth monitor and host-safe tests.
public enum BatteryMonitorModel {
    public static func upserting(_ device: BatteryDevice, into devices: [BatteryDevice]) -> [BatteryDevice] {
        var list = devices.filter { $0.id != device.id }
        list.append(device)
        return list.sorted { $0.rssi > $1.rssi }
    }

    public static func isLow(level: Int?) -> Bool {
        (level ?? 100) < 20
    }
}

public enum BatteryMonitorStore {
    public static let idKey = "foundryx.battery.monitored.uuid"
    public static let nameKey = "foundryx.battery.monitored.name"

    public static func save(id: UUID, name: String, defaults: UserDefaults = .standard) {
        defaults.set(id.uuidString, forKey: idKey)
        defaults.set(name, forKey: nameKey)
    }

    public static func load(defaults: UserDefaults = .standard) -> (id: UUID, name: String)? {
        guard let idString = defaults.string(forKey: idKey),
              let id = UUID(uuidString: idString) else { return nil }
        return (id, defaults.string(forKey: nameKey) ?? "Bluetooth device")
    }

    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: idKey)
        defaults.removeObject(forKey: nameKey)
    }
}

#if os(iOS)
import CoreBluetooth

/// User-initiated battery monitor for BLE devices that publish the standard Battery
/// Service. It owns a separate central so it never interferes with the Omi audio link.
public final class BatteryMonitor: NSObject, ObservableObject, @unchecked Sendable {
    @Published public private(set) var discovered: [BatteryDevice] = []
    @Published public private(set) var monitoredName: String? = nil
    @Published public private(set) var level: Int? = nil
    @Published public private(set) var isScanning: Bool = false

    public var isLow: Bool { BatteryMonitorModel.isLow(level: level) }

    private let bleQueue = DispatchQueue(label: "foundryx.battery-ble")
    private var central: CBCentralManager?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var targetPeripheral: CBPeripheral?
    private var stopRequested = false
    private var wantsScan = false
    private var scanGeneration = UUID()

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: bleQueue)
    }

    public func startScan() {
        stopRequested = false
        wantsScan = true
        let generation = UUID()
        scanGeneration = generation
        setDiscovered([])
        setScanning(true)
        scanIfPoweredOn()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.scanGeneration == generation else { return }
            self.stopScan()
        }
    }

    public func stopScan() {
        wantsScan = false
        central?.stopScan()
        setScanning(false)
    }

    public func monitor(_ device: BatteryDevice) {
        stopRequested = false
        stopScan()
        guard let c = central,
              let peripheral = discoveredPeripherals[device.id]
                ?? c.retrievePeripherals(withIdentifiers: [device.id]).first else { return }
        bind(peripheral)
        setMonitoredName(device.name)
        BatteryMonitorStore.save(id: device.id, name: device.name)
        c.connect(peripheral, options: nil)
    }

    public func stopMonitoring() {
        stopRequested = true
        wantsScan = false
        central?.stopScan()
        if let peripheral = targetPeripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        targetPeripheral = nil
        BatteryMonitorStore.clear()
        setLevel(nil)
        setMonitoredName(nil)
        setScanning(false)
    }

    private func scanIfPoweredOn() {
        guard let c = central, c.state == .poweredOn else { return }
        c.scanForPeripherals(
            withServices: [OmiUUID.batteryService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func resumePersistedMonitor() {
        guard let c = central,
              let saved = BatteryMonitorStore.load(),
              let peripheral = c.retrievePeripherals(withIdentifiers: [saved.id]).first else { return }
        stopRequested = false
        bind(peripheral)
        setMonitoredName(saved.name)
        c.connect(peripheral, options: nil)
    }

    private func bind(_ peripheral: CBPeripheral) {
        targetPeripheral = peripheral
        peripheral.delegate = self
    }

    private func setDiscovered(_ devices: [BatteryDevice]) {
        DispatchQueue.main.async { self.discovered = devices }
    }

    private func setMonitoredName(_ name: String?) {
        DispatchQueue.main.async { self.monitoredName = name }
    }

    private func setLevel(_ value: Int?) {
        let clamped = value.map { max(0, min(100, $0)) }
        DispatchQueue.main.async { self.level = clamped }
    }

    private func setScanning(_ scanning: Bool) {
        DispatchQueue.main.async { self.isScanning = scanning }
    }
}

extension BatteryMonitor: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantsScan { scanIfPoweredOn() }
            resumePersistedMonitor()
        case .unauthorized, .poweredOff, .unsupported:
            setLevel(nil)
            setScanning(false)
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        discoveredPeripherals[peripheral.identifier] = peripheral
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let device = BatteryDevice(
            id: peripheral.identifier,
            name: advertisedName ?? peripheral.name ?? "Bluetooth device",
            rssi: RSSI.intValue)
        DispatchQueue.main.async {
            self.discovered = BatteryMonitorModel.upserting(device, into: self.discovered)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        bind(peripheral)
        peripheral.discoverServices([OmiUUID.batteryService])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        setLevel(nil)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        setLevel(nil)
        guard !stopRequested, targetPeripheral?.identifier == peripheral.identifier else { return }
        central.connect(peripheral, options: nil)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == OmiUUID.batteryService {
            peripheral.discoverCharacteristics([OmiUUID.batteryLevelChar], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == OmiUUID.batteryLevelChar {
            peripheral.readValue(for: characteristic)
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == OmiUUID.batteryLevelChar else { return }
        setLevel(characteristic.value?.first.map(Int.init))
    }
}

#else
/// Non-iOS host (macOS test runner): no-op API mirror so SwiftPM tests compile.
public final class BatteryMonitor: ObservableObject, @unchecked Sendable {
    @Published public private(set) var discovered: [BatteryDevice] = []
    @Published public private(set) var monitoredName: String? = nil
    @Published public private(set) var level: Int? = nil
    @Published public private(set) var isScanning: Bool = false
    public var isLow: Bool { false }

    public init() {}
    public func startScan() {}
    public func stopScan() {}
    public func monitor(_ device: BatteryDevice) {}
    public func stopMonitoring() {}
}
#endif
