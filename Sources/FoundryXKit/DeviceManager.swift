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

/// What a tap on the consolidated capture header's Omi icon should do, given its
/// current presentation (Feature 3). Pure so the SwiftUI button and a brine test agree
/// on the scan toggle.
public enum OmiScanTapAction: Equatable, Sendable { case startScan, stopScan, none }

/// The consolidated capture header's Omi control as a pure presentation over the
/// connection state (Feature 3). The control is a small CIRCULAR icon when collapsed
/// (idle / disconnected) and EXPANDS into a wider pill while scanning / connecting /
/// connected. Keeping this a pure value (no SwiftUI) lets a brine test assert the
/// collapsed-icon ↔ expanded-pill state machine and the scan toggle.
public enum OmiScanPresentation: Equatable, Sendable {
    case collapsed                 // idle / disconnected: a small icon; tap → start a scan
    case scanning                  // expanded "Scanning…" pill + a subtle activity indicator
    case connecting(String)        // expanded "Connecting…" pill + activity
    case connected(String)         // distinct connected style (the header itself switches to
                                   // the ambient layout on connect, so this rarely shows here)
    case off                       // Bluetooth off / unavailable: a non-interactive icon

    /// Map the live connection state onto the control's presentation.
    public static func from(_ state: DeviceConnectionState) -> OmiScanPresentation {
        switch state {
        case .idle, .disconnected: return .collapsed
        case .scanning: return .scanning
        case .connecting(let n): return .connecting(n)
        case .connected(let n): return .connected(n)
        case .poweredOff: return .off
        }
    }

    /// The control is a WIDE pill (vs a small circle) while scanning / connecting / connected.
    public var isExpanded: Bool {
        switch self {
        case .collapsed, .off: return false
        case .scanning, .connecting, .connected: return true
        }
    }

    /// A subtle activity indicator spins while actively scanning / connecting.
    public var showsActivity: Bool {
        switch self {
        case .scanning, .connecting: return true
        case .collapsed, .connected, .off: return false
        }
    }

    /// The short label inside the expanded pill (nil when collapsed / off → icon only).
    public var label: String? {
        switch self {
        case .collapsed, .off: return nil
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .connected(let n): return n
        }
    }

    /// What a tap does: start a scan from the collapsed icon, stop it while scanning,
    /// otherwise nothing (connecting / connected are driven by the BLE lifecycle).
    public var tapAction: OmiScanTapAction {
        switch self {
        case .collapsed: return .startScan
        case .scanning: return .stopScan
        case .connecting, .connected, .off: return .none
        }
    }
}

/// Pure auto-connect decision, testable WITHOUT CoreBluetooth (so the "stuck on
/// scanning, won't auto-connect" regression has real coverage). During a scan we
/// auto-connect to a discovered peripheral ONLY when it is the device we've already
/// paired (saved). First-time pairing stays an explicit tap so we never silently grab
/// a stranger's nearby Omi.
public enum OmiAutoConnect {
    public static func shouldAutoConnect(discoveredId: UUID, savedId: UUID?) -> Bool {
        guard let savedId else { return false }
        return discoveredId == savedId
    }
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
    /// Fired when the Omi hardware button is DOUBLE-clicked (wired to pause/resume the
    /// current recording). Detected from the Omi button-trigger characteristic — see
    /// `OmiUUID.buttonService`. Only fires if the paired firmware exposes that service.
    public var onButtonDoubleClick: (() -> Void)?
    /// Timestamp of the last button press, for the two-presses-within-window fallback
    /// (used when the firmware emits per-press events rather than a typed DOUBLE_TAP).
    private var lastButtonPressAt: Date?

    // UI-facing state (published on main).
    @Published public private(set) var connectionState: DeviceConnectionState = .poweredOff
    @Published public private(set) var discovered: [DiscoveredDevice] = []
    /// The remembered Omi (device page). nil until the user first connects one.
    @Published public private(set) var saved: SavedOmi?
    /// The connected device's battery level (0…100) read from the standard BLE Battery
    /// Service. `nil` when disconnected OR the device doesn't expose a battery — the UI
    /// then shows no battery rather than a fake value.
    @Published public private(set) var batteryLevel: Int?

    /// True when the connected device's battery is low enough to warrant a warning tint.
    public var isBatteryLow: Bool { (batteryLevel ?? 100) < 20 }

    private func setBatteryLevel(_ level: Int?) {
        let clamped = level.map { max(0, min(100, $0)) }
        DispatchQueue.main.async { self.batteryLevel = clamped }
    }

    private let log: DoorLog?
    private let bleQueue = DispatchQueue(label: "foundryx.device-ble")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private let headerBytes = 3   // Omi packet header [seq:2][index:1]
    private var audioNotifs = 0   // diagnostics: raw audio-char notifications seen (bleQueue only)
    /// When false the link is USER-SUSPENDED (the Omi was toggled OFF on the device
    /// page): we drop it AND stop auto-reconnecting until re-enabled, so a disabled Omi
    /// truly leaves the capture surface instead of silently reconnecting itself. The
    /// saved pairing is kept so re-enabling reconnects hands-free.
    private var autoConnect = true

    private static let savedKey = "foundryx.omi.peripheral-id"
    private static let savedNameKey = "foundryx.omi.peripheral-name"
    private static let savedDateKey = "foundryx.omi.last-connected"

    public init(log: DoorLog? = nil) {
        self.log = log
        super.init()
        saved = Self.loadSaved()
    }

    /// AudioFrameSource.start() = power on + begin the connect flow (auto-reconnect
    /// the saved device, else scan). RE-ENTRANT: when the central is already powered on
    /// and we're not currently linked, this RE-INITIATES the connect flow. Previously
    /// start() only created the central and otherwise no-oped, so re-selecting /
    /// re-enabling the Omi after a stop never reconnected (the user had to manually
    /// scan) — a primary "zero frames / stuck" cause.
    public func start() {
        autoConnect = true
        guard let c = central else {
            central = CBCentralManager(delegate: self, queue: bleQueue)
            return   // the connect flow resumes once the central reports .poweredOn
        }
        guard c.state == .poweredOn else { return }
        switch connectionState {
        case .connected, .connecting: break          // already linked — nothing to do
        default: autoReconnect()                      // re-initiate (reconnect saved, else scan)
        }
    }

    /// AudioFrameSource.stop() = drop the link (capture ends; we keep the saved id).
    public func stop() { disconnect() }

    /// Enable/disable the Omi as a capture source (device-page toggle). Disabling drops
    /// the link AND stops auto-reconnect, so a toggled-off Omi leaves the capture
    /// surface; enabling resumes the hands-free connect flow. The saved pairing persists.
    public func setEnabled(_ on: Bool) { if on { start() } else { suspend() } }

    /// User-suspend: drop the link, keep the saved device, and DON'T auto-reconnect
    /// (until `start()`/`setEnabled(true)`). Distinct from `disconnect()`, which keeps
    /// auto-reconnect armed for a transient drop.
    public func suspend() {
        autoConnect = false
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        setDiscovered([])
        setState(.idle)
        onState?(.stopped)
    }

    // MARK: connect UI API

    public func startScan() {
        guard let c = central, c.state == .poweredOn else { return }
        setDiscovered([])
        setState(.scanning)
        c.scanForPeripherals(withServices: [OmiUUID.audioService], options: nil)
    }

    /// Stop an in-progress scan and collapse back to idle (the consolidated header's
    /// Omi icon returns to its small circle). Clears any discovered results.
    public func stopScan() {
        central?.stopScan()
        setDiscovered([])
        setState(.idle)
    }

    public func connect(_ device: DiscoveredDevice) {
        autoConnect = true
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
        autoConnect = true
        guard let c = central, c.state == .poweredOn else { start(); return }
        autoReconnect()
    }

    /// Drop the current link AND forget the saved device (user-initiated).
    public func forget() {
        autoConnect = false
        central?.stopScan()
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
        case .poweredOn: if autoConnect { autoReconnect() }
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
        // Hands-free reconnect: when a scan turns up the device we've already paired,
        // connect to it AUTOMATICALLY instead of waiting for a manual tap. This is the
        // "stuck on scanning — sees the Omi but won't auto-connect" fix: autoReconnect's
        // retrievePeripherals() can come up empty (the OS handle isn't cached yet), so it
        // falls back to a scan that previously just listed the device and waited. First-
        // time pairing stays an explicit tap (no saved id ⇒ shouldAutoConnect == false).
        let savedId = UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init(uuidString:))
        if autoConnect, OmiAutoConnect.shouldAutoConnect(discoveredId: p.identifier, savedId: savedId) {
            log?.info("Omi: saved device in range during scan — auto-connecting \(p.name ?? "?")")
            c.stopScan()
            bind(p)
            markConnectingName(p.name ?? "Omi")
            c.connect(p, options: nil)
        }
    }

    /// Set the connecting state for a name (used by the scan auto-connect path).
    private func markConnectingName(_ name: String) { setState(.connecting(name)) }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log?.info("Omi: connected \(p.name ?? "?") — discovering audio service")
        // Discover the audio service AND the standard battery service — the battery
        // read is best-effort (a device without it just never reports a level).
        p.discoverServices([OmiUUID.audioService, OmiUUID.batteryService])
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        setState(.disconnected); onState?(.failed("connect failed: \(error?.localizedDescription ?? "?")"))
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        setBatteryLevel(nil)          // the level is stale once the link drops
        onState?(.stopped)            // ends the ambient capture session
        // A USER-suspended link (Omi toggled off) must stay down — don't fight the
        // toggle with an auto-reconnect. A transient drop (in/out of range) re-arms it.
        guard autoConnect else { setState(.idle); return }
        log?.warn("Omi: disconnected (\(error?.localizedDescription ?? "clean")) — auto-reconnecting")
        setState(.disconnected)
        autoReconnect()               // come back when it's in range
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for svc in p.services ?? [] {
            if svc.uuid == OmiUUID.audioService {
                p.discoverCharacteristics([OmiUUID.audioDataChar, OmiUUID.codecChar], for: svc)
            } else if svc.uuid == OmiUUID.batteryService {
                p.discoverCharacteristics([OmiUUID.batteryLevelChar], for: svc)
            } else if svc.uuid == OmiUUID.buttonService {
                p.discoverCharacteristics([OmiUUID.buttonTriggerChar], for: svc)
            }
        }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            if ch.uuid == OmiUUID.codecChar { p.readValue(for: ch) }
            if ch.uuid == OmiUUID.batteryLevelChar {
                p.readValue(for: ch)              // initial level
                p.setNotifyValue(true, for: ch)   // updates as it drains/charges
                log?.info("Omi: battery service found — reading level")
            }
            if ch.uuid == OmiUUID.audioDataChar {
                p.setNotifyValue(true, for: ch)
                markConnected(p.identifier, name: p.name ?? "Omi")
                setState(.connected(p.name ?? "Omi"))
                onState?(.streaming)   // triggers ambient capture
                log?.info("Omi: subscribed to audio — ambient capture live")
            }
            if ch.uuid == OmiUUID.buttonTriggerChar {
                p.setNotifyValue(true, for: ch)   // hardware button → double-click pauses
                log?.info("Omi: button service found — subscribed for double-click pause")
            }
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let error { log?.warn("Omi: didUpdateValue error: \(error.localizedDescription)") }
        guard let data = ch.value else { log?.warn("Omi: notify with nil value"); return }
        if ch.uuid == OmiUUID.batteryLevelChar {
            // Battery Level is a single byte, 0…100 (Bluetooth SIG 0x2A19).
            if let pct = data.first { setBatteryLevel(Int(pct)); log?.info("Omi: battery \(pct)%") }
            return
        }
        if ch.uuid == OmiUUID.codecChar { log?.info("Omi: codec=\(data.map { String($0) }.joined(separator: ","))"); return }
        if ch.uuid == OmiUUID.buttonTriggerChar { handleButtonNotify(data); return }
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

    /// Decode an Omi button-trigger notification into a double-click → `onButtonDoubleClick`.
    /// The firmware's event encoding is UNCONFIRMED here, so this is deliberately tolerant of
    /// both known shapes and logs the RAW payload so an on-device test reveals the real one:
    ///  (a) a typed event byte where 2 == DOUBLE_TAP (Omi/Friend devkit `button.c`) → fire directly;
    ///  (b) a stream of per-press events → two presses within 400 ms is a double-click.
    /// A firmware that never sends this characteristic simply never calls this.
    private func handleButtonNotify(_ data: Data) {
        log?.info("Omi: button notify raw=[\(data.map { String($0) }.joined(separator: ","))]")
        let now = Date()
        // (a) explicit double-tap code.
        if data.first == 2 {
            lastButtonPressAt = nil
            onButtonDoubleClick?()
            return
        }
        // (b) press-stream fallback (single/long codes 1/3, or a bare press with no code).
        if let last = lastButtonPressAt, now.timeIntervalSince(last) <= 0.4 {
            lastButtonPressAt = nil
            onButtonDoubleClick?()
        } else {
            lastButtonPressAt = now
        }
    }
}

/// Omi BLE UUIDs (firmware transport.c). Shared by DeviceManager + OmiBleSource.
public enum OmiUUID {
    public nonisolated(unsafe) static let audioService = CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214")
    public nonisolated(unsafe) static let audioDataChar = CBUUID(string: "19B10001-E8F2-537E-4F6C-D104768A1214")
    public nonisolated(unsafe) static let codecChar = CBUUID(string: "19B10002-E8F2-537E-4F6C-D104768A1214")
    /// The STANDARD Bluetooth Battery Service (0x180F) + Battery Level characteristic
    /// (0x2A19) — a single byte 0…100. The Omi exposes these; any device that does not
    /// simply never fires the read, and the level stays nil (no fake value).
    public nonisolated(unsafe) static let batteryService = CBUUID(string: "180F")
    public nonisolated(unsafe) static let batteryLevelChar = CBUUID(string: "2A19")
    /// Omi hardware BUTTON service (Omi/Friend devkit firmware `button.c`). The button-
    /// trigger characteristic notifies a small event byte on tap. UUIDs + the exact event
    /// encoding are FIRMWARE-DEPENDENT and NOT confirmed in this repo — a device whose
    /// firmware lacks this service simply never discovers it (the notify never fires and
    /// nothing happens). The raw payload of every button notify is logged so an on-device
    /// test reveals the real encoding, which the double-click detector can then be tuned to.
    public nonisolated(unsafe) static let buttonService = CBUUID(string: "23BA7924-0000-1000-7450-346EAC492E92")
    public nonisolated(unsafe) static let buttonTriggerChar = CBUUID(string: "23BA7925-0000-1000-7450-346EAC492E92")
}

#else
// Non-CoreBluetooth host (macOS test runner): a no-op manager so the app + tests compile.
public final class DeviceManager: ObservableObject, AudioFrameSource, @unchecked Sendable {
    public var onFrame: ((Data) -> Void)?
    public var onState: ((AudioSourceState) -> Void)?
    @Published public private(set) var connectionState: DeviceConnectionState = .poweredOff
    @Published public private(set) var discovered: [DiscoveredDevice] = []
    @Published public private(set) var saved: SavedOmi?
    @Published public private(set) var batteryLevel: Int?
    public var isBatteryLow: Bool { (batteryLevel ?? 100) < 20 }
    public init(log: DoorLog? = nil) { _ = log }
    public func start() { onState?(.failed("CoreBluetooth unavailable")) }
    public func stop() { onState?(.stopped) }
    public func setEnabled(_ on: Bool) {}
    public func suspend() { onState?(.stopped) }
    public func startScan() {}
    public func stopScan() {}
    public func connect(_ device: DiscoveredDevice) {}
    public func reconnect() {}
    public func forget() {}
    public func disconnect() {}
}
#endif
