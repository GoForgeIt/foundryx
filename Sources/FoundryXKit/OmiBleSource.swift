// OmiBleSource — the real Omi wearable as an AudioFrameSource, over CoreBluetooth.
// Scans for the Omi audio service, connects, reads the codec characteristic, and
// subscribes to the audio-data characteristic; each notification yields one Opus
// frame to `onFrame`. Modeled on Omi's own client (omi-lib `FriendManager` /
// `OmiBleManager`) + the firmware's `transport.c`.
//
// Omi BLE contract (firmware transport.c):
//   service 19B10000-E8F2-537E-4F6C-D104768A1214
//   audio-data 19B10001 (notify) — each packet = [seq:u16 LE][index:u8] header
//                                   + Opus payload (we strip the 3-byte header).
//   codec      19B10002 (read)   — the codec type (Opus).
//
// NOTE (hardware validation): the 3-byte-header strip + treating one notification
// as one frame matches the common Omi format; multi-notification fragment
// reassembly (via the index byte) is a refinement to confirm against a real
// device. This source is exercised only on the `@ble-hardware` Brine lane.

import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth

public final class OmiBleSource: NSObject, AudioFrameSource, @unchecked Sendable {
    public var onFrame: ((Data) -> Void)?
    public var onState: ((AudioSourceState) -> Void)?

    public nonisolated(unsafe) static let audioService = CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214")
    public nonisolated(unsafe) static let audioDataChar = CBUUID(string: "19B10001-E8F2-537E-4F6C-D104768A1214")
    public nonisolated(unsafe) static let codecChar = CBUUID(string: "19B10002-E8F2-537E-4F6C-D104768A1214")

    private let log: DoorLog?
    private let queue = DispatchQueue(label: "foundryx.omi-ble")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private let headerBytes = 3   // Omi packet header: [seq:2][index:1]

    public init(log: DoorLog? = nil) {
        self.log = log
        super.init()
    }

    public func start() {
        central = CBCentralManager(delegate: self, queue: queue)
        // Scanning begins once central reports .poweredOn (centralManagerDidUpdateState).
    }

    public func stop() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        peripheral = nil
        central = nil
        onState?(.stopped)
    }
}

extension OmiBleSource: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            onState?(.scanning)
            log?.info("Omi BLE: scanning for audio service")
            c.scanForPeripherals(withServices: [Self.audioService], options: nil)
        case .unauthorized: onState?(.failed("bluetooth unauthorized"))
        case .poweredOff: onState?(.failed("bluetooth off"))
        default: break
        }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        log?.info("Omi BLE: found \(p.name ?? "device") — connecting")
        peripheral = p
        p.delegate = self
        c.stopScan()
        c.connect(p, options: nil)
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([Self.audioService])
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        onState?(.failed("connect failed: \(error?.localizedDescription ?? "?")"))
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        onState?(.stopped)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == Self.audioService }) else { return }
        p.discoverCharacteristics([Self.audioDataChar, Self.codecChar], for: svc)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            if ch.uuid == Self.codecChar { p.readValue(for: ch) }
            if ch.uuid == Self.audioDataChar {
                p.setNotifyValue(true, for: ch)   // subscribe to the Opus stream
                onState?(.streaming)
                log?.info("Omi BLE: subscribed to audio stream")
            }
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value else { return }
        if ch.uuid == Self.codecChar {
            log?.info("Omi BLE: codec = \(data.map { String($0) }.joined(separator: ","))")
            return
        }
        guard ch.uuid == Self.audioDataChar, data.count > headerBytes else { return }
        onFrame?(data.subdata(in: headerBytes..<data.count))   // strip header → Opus frame
    }
}
#else
// Non-BLE platforms (e.g. the macOS test host): a no-op so the type still exists.
public final class OmiBleSource: AudioFrameSource, @unchecked Sendable {
    public var onFrame: ((Data) -> Void)?
    public var onState: ((AudioSourceState) -> Void)?
    public init(log: DoorLog? = nil) { _ = log }
    public func start() { onState?(.failed("CoreBluetooth unavailable on this platform")) }
    public func stop() { onState?(.stopped) }
}
#endif
