// DeviceManager — the Omi connect/pairing flow: scan for Omi devices, let the
// user pick one, connect, PERSIST the choice, and auto-reconnect on launch / when
// it returns in range. It is also the live AudioFrameSource for the connected
// device (emits Opus frames), so the capture pipeline depends only on
// AudioFrameSource — the app injects this, tests inject ReplaySource.
//
// Connection ≠ capture: this owns the BLE link + its lifecycle; CaptureManager
// turns the resulting `.streaming` state into an ambient capture session. Modeled
// on Omi's omi-lib FriendManager / OmiBleManager + firmware transport.c.

import Foundation

/// What the connect UI shows.
public enum DeviceConnectionState: Equatable, Sendable {
    case poweredOff          // Bluetooth unavailable/off/unauthorized
    case idle                // powered on, not scanning, nothing connected
    case scanning
    case connecting(String)  // device name
    case connected(String)   // device name — ambient capture runs here
    case disconnected        // was connected, link dropped (auto-reconnecting)
}

/// A discovered, connectable Omi.
public struct DiscoveredDevice: Identifiable, Equatable, Sendable {
    public let id: UUID        // CBPeripheral.identifier
    public let name: String
    public let rssi: Int
}

/// The remembered Omi shown on the dedicated device page (req 7): what we
/// auto-reconnect to, plus when we last had it connected.
public struct SavedOmi: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let lastConnected: Date?
}

#if canImport(CoreBluetooth)
import CoreBluetooth

public final class DeviceManager: NSObject, ObservableObject, AudioFrameSource, @unchecked Sendable {
    // AudioFrameSource — the connected device's Opus stream.
    public var onFrame: ((Data) -> Void)?
    public var onState: ((AudioSourceState) -> Void)?

    // UI-facing state (published on main).
    @Published public private(set) var connectionState: DeviceConnectionState = .poweredOff
    @Published public private(set) var discovered: [DiscoveredDevice] = []
    /// The remembered Omi (device page). nil until the user first connects one.
    @Published public private(set) var saved: SavedOmi?

    private let log: DoorLog?
    private let bleQueue = DispatchQueue(label: "foundryx.device-ble")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private let headerBytes = 3   // Omi packet header [seq:2][index:1]
    private var audioNotifs = 0   // diagnostics: raw audio-char notifications seen (bleQueue only)

    private static let savedKey = "foundryx.omi.peripheral-id"
    private static let savedNameKey = "foundryx.omi.peripheral-name"
    private static let savedDateKey = "foundryx.omi.last-connected"

    public init(log: DoorLog? = nil) {
        self.log = log
        super.init()
        saved = Self.loadSaved()
    }

    /// AudioFrameSource.start() = power on + begin the connect flow (auto-reconnect
    /// the saved device, else scan).
    public func start() {
        if central == nil { central = CBCentralManager(delegate: self, queue: bleQueue) }
        // The rest happens once the central reports .poweredOn.
    }

    /// AudioFrameSource.stop() = drop the link (capture ends; we keep the saved id).
    public func stop() { disconnect() }

    // MARK: connect UI API

    public func startScan() {
        guard let c = central, c.state == .poweredOn else { return }
        setDiscovered([])
        setState(.scanning)
        c.scanForPeripherals(withServices: [OmiUUID.audioService], options: nil)
    }

    public func connect(_ device: DiscoveredDevice) {
        guard let c = central,
              let p = c.retrievePeripherals(withIdentifiers: [device.id]).first
                  ?? discoveredPeripherals[device.id] else { return }
        c.stopScan()
        bind(p)
        setSaved(device.id, name: p.name ?? device.name)
        setState(.connecting(p.name ?? "Omi"))
        c.connect(p, options: nil)
    }

    /// Manual reconnect (device page, req 7): re-run the saved-device connect, or
    /// fall back to a scan when there's nothing saved / it's out of range.
    public func reconnect() {
        guard let c = central, c.state == .poweredOn else { start(); return }
        autoReconnect()
    }

    /// Drop the current link AND forget the saved device (user-initiated).
    public func forget() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
        UserDefaults.standard.removeObject(forKey: Self.savedNameKey)
        UserDefaults.standard.removeObject(forKey: Self.savedDateKey)
        DispatchQueue.main.async { self.saved = nil }
        setState(.idle)
        onState?(.stopped)
    }

    /// Drop the current link but keep the saved device (so we auto-reconnect).
    public func disconnect() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        onState?(.stopped)
    }

    // MARK: internals

    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]   // bleQueue only

    private func bind(_ p: CBPeripheral) { peripheral = p; p.delegate = self }

    private func autoReconnect() {
        guard let c = central,
              let idStr = UserDefaults.standard.string(forKey: Self.savedKey),
              let id = UUID(uuidString: idStr),
              let p = c.retrievePeripherals(withIdentifiers: [id]).first else {
            setState(.idle); startScan(); return
        }
        log?.info("Omi: auto-reconnecting saved device \(p.name ?? "?")")
        bind(p)
        setState(.connecting(p.name ?? "Omi"))
        c.connect(p, options: nil)
    }

    // main-thread published mutations
    private func setState(_ s: DeviceConnectionState) { DispatchQueue.main.async { self.connectionState = s } }
    private func setDiscovered(_ d: [DiscoveredDevice]) { DispatchQueue.main.async { self.discovered = d } }

    private func setSaved(_ id: UUID, name: String) {
        let d = UserDefaults.standard
        d.set(id.uuidString, forKey: Self.savedKey)
        d.set(name, forKey: Self.savedNameKey)
        publishSaved()
    }

    /// Record a successful connection (updates "last connected" on the device page).
    private func markConnected(_ id: UUID, name: String) {
        let d = UserDefaults.standard
        d.set(id.uuidString, forKey: Self.savedKey)
        d.set(name, forKey: Self.savedNameKey)
        d.set(Date().timeIntervalSinceReferenceDate, forKey: Self.savedDateKey)
        publishSaved()
    }

    private func publishSaved() {
        let s = Self.loadSaved()
        DispatchQueue.main.async { self.saved = s }
    }

    static func loadSaved() -> SavedOmi? {
        let d = UserDefaults.standard
        guard let idStr = d.string(forKey: Self.savedKey), let id = UUID(uuidString: idStr) else { return nil }
        let name = d.string(forKey: Self.savedNameKey) ?? "Omi"
        let ts = d.double(forKey: Self.savedDateKey)
        let last = ts > 0 ? Date(timeIntervalSinceReferenceDate: ts) : nil
        return SavedOmi(id: id, name: name, lastConnected: last)
    }
}

extension DeviceManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: autoReconnect()
        case .unauthorized, .poweredOff, .unsupported:
            setState(.poweredOff); onState?(.failed("bluetooth unavailable"))
        default: break
        }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        discoveredPeripherals[p.identifier] = p
        let dev = DiscoveredDevice(id: p.identifier, name: p.name ?? "Omi", rssi: RSSI.intValue)
        DispatchQueue.main.async {
            var list = self.discovered.filter { $0.id != dev.id }
            list.append(dev)
            self.discovered = list.sorted { $0.rssi > $1.rssi }
        }
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log?.info("Omi: connected \(p.name ?? "?") — discovering audio service")
        p.discoverServices([OmiUUID.audioService])
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        setState(.disconnected); onState?(.failed("connect failed: \(error?.localizedDescription ?? "?")"))
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log?.warn("Omi: disconnected (\(error?.localizedDescription ?? "clean")) — auto-reconnecting")
        setState(.disconnected)
        onState?(.stopped)            // ends the ambient capture session
        autoReconnect()               // come back when it's in range
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == OmiUUID.audioService }) else { return }
        p.discoverCharacteristics([OmiUUID.audioDataChar, OmiUUID.codecChar], for: svc)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            if ch.uuid == OmiUUID.codecChar { p.readValue(for: ch) }
            if ch.uuid == OmiUUID.audioDataChar {
                p.setNotifyValue(true, for: ch)
                markConnected(p.identifier, name: p.name ?? "Omi")
                setState(.connected(p.name ?? "Omi"))
                onState?(.streaming)   // triggers ambient capture
                log?.info("Omi: subscribed to audio — ambient capture live")
            }
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let error { log?.warn("Omi: didUpdateValue error: \(error.localizedDescription)") }
        guard let data = ch.value else { log?.warn("Omi: notify with nil value"); return }
        if ch.uuid == OmiUUID.codecChar { log?.info("Omi: codec=\(data.map { String($0) }.joined(separator: ","))"); return }
        guard ch.uuid == OmiUUID.audioDataChar else { return }
        // Diagnostics: count RAW notifications (before the header filter) so a
        // "connected but silent" device is unambiguous in the logs — log the first
        // one, then every 200th, plus any runt packet ≤ the 3-byte header.
        audioNotifs += 1
        if audioNotifs == 1 || audioNotifs % 200 == 0 {
            log?.info("Omi: audio notif #\(audioNotifs), \(data.count) bytes raw (mtu \(p.maximumWriteValueLength(for: .withoutResponse)))")
        }
        guard data.count > headerBytes else {
            if audioNotifs <= 5 { log?.warn("Omi: runt audio notif \(data.count)B (≤ header) — dropped") }
            return
        }
        onFrame?(data.subdata(in: headerBytes..<data.count))   // strip header → Opus frame
    }
}

/// Omi BLE UUIDs (firmware transport.c). Shared by DeviceManager + OmiBleSource.
public enum OmiUUID {
    public nonisolated(unsafe) static let audioService = CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214")
    public nonisolated(unsafe) static let audioDataChar = CBUUID(string: "19B10001-E8F2-537E-4F6C-D104768A1214")
    public nonisolated(unsafe) static let codecChar = CBUUID(string: "19B10002-E8F2-537E-4F6C-D104768A1214")
}

#else
// Non-CoreBluetooth host (macOS test runner): a no-op manager so the app + tests compile.
public final class DeviceManager: ObservableObject, AudioFrameSource, @unchecked Sendable {
    public var onFrame: ((Data) -> Void)?
    public var onState: ((AudioSourceState) -> Void)?
    @Published public private(set) var connectionState: DeviceConnectionState = .poweredOff
    @Published public private(set) var discovered: [DiscoveredDevice] = []
    @Published public private(set) var saved: SavedOmi?
    public init(log: DoorLog? = nil) { _ = log }
    public func start() { onState?(.failed("CoreBluetooth unavailable")) }
    public func stop() { onState?(.stopped) }
    public func startScan() {}
    public func connect(_ device: DiscoveredDevice) {}
    public func reconnect() {}
    public func forget() {}
    public func disconnect() {}
}
#endif
