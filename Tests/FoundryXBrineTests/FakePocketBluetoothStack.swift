import Foundation
import CoreBluetooth
// THE SAME FILE, COMPILED INTO TWO LANES THAT NAME THE KIT DIFFERENTLY.
//
// Under SPM / `FoundryXiOSTests`, the kit is its own module (`FoundryXKit`). In the
// app-hosted scenario lane the app target COMPILES `Sources/FoundryXKit` directly, so
// there is no `FoundryXKit` module there at all — the same types live in the app module.
// Importing both would put two distinct `BLECentral` types in one file and nothing would
// typecheck. This shim is the whole difference; every line below is shared verbatim,
// which is the point: the app-hosted lane must be driven by the fake the rest of the
// suite already trusts, not by a second opinion about what a recorder does.
#if APP_HOSTED_SCENARIOS
@testable import FoundryX
#else
@testable import FoundryXKit
#endif

/// A SCRIPTED STORED-FILE RECORDER BEHIND THE SAME BLE SEAM THE APP RUNS ON.
///
/// WHY THIS EXISTS AND WHY IT IS NOT `UnifiedDeviceListFakeTransport`. The previous gate for
/// "a paired Pocket is a peer row" handed `PocketBLEClient` a fake `PocketBLETransport` — a
/// type that answers protocol questions directly. That proves the protocol client, the
/// bridge, the adoption seam and the store, and it proves NOTHING about whether the app can
/// reach any of them, because the app has no `PocketBLETransport` of its own to hand it.
///
/// This fake sits one layer LOWER, at `BLECentral` / `BLEPeripheral` / `BLEService` /
/// `BLECharacteristic` — the four types `DeviceManager` and `CoreBluetoothCentral` are
/// written against. So the code under test is the shipped `RecordingDeviceAttachment` and the
/// shipped `PocketSeamTransport`: the real characteristic-map negotiation, the real
/// `PocketBLEClient.connect`, the real `PocketOnboardingCoordinator.restore`, the real
/// `PocketRecordingDeviceBridge.observe`, the real `RecordingDeviceAdoption.remember`. The
/// only injected thing is the radio, which a hermetic suite cannot own.
///
/// IT MODELS THE TRANSPORT, NOT THE OUTCOME. It answers `APP&…` commands with the control
/// frames the reference trace records and nothing else; every decision about what those
/// frames MEAN stays in the production code.
final class FakePocketBLEStack: @unchecked Sendable {

    /// A vendor-style 128-bit characteristic UUID whose leading segment is the 8-hex token
    /// `PocketCharacteristicMap` addresses characteristics by.
    static func characteristicUUID(_ token: String) -> CBUUID {
        CBUUID(string: "\(token.uppercased())-1212-EFDE-1523-785FEABCD123")
    }

    nonisolated(unsafe) static let serviceUUID =
        CBUUID(string: "00112000-1212-EFDE-1523-785FEABCD123")

    /// HOW A RECORDER TREATS AN `APP&SK&` WRITE, AS THE THREE BEHAVIOURS THAT ACTUALLY MATTER.
    ///
    /// This is the modelled half of proposal §6b's open question U1 — nobody has ever run a
    /// second key write against a keyed unit, so the app has to be correct under BOTH answers.
    /// Making them three explicit modes is what lets a scenario say which recorder it is
    /// standing in front of instead of inferring it from a nil.
    enum KeyBehaviour: Sendable {
        /// FACTORY-FRESH: no key yet, and the FIRST key written becomes the key. This is the
        /// behaviour observed on hardware (unit PKT01_BLUE_26079bc5, firmware 1.6, never
        /// paired): writing `APP&SK&<our own key>` provisioned it.
        case factoryFresh
        /// ALREADY KEYED AND HONEST ABOUT IT: it holds a key and refuses any other. This is the
        /// SAFE answer to U1 — a mint attempt is then a free, non-destructive probe.
        case keyed(String)
        /// ALREADY KEYED AND ACKNOWLEDGES ANYTHING: it answers `MCU&SK&OK` to every key write
        /// and goes on using the key it has. This is the DANGEROUS answer to U1, and it is the
        /// exact case a bare `MCU&SK&OK` cannot distinguish from success — which is why the
        /// mint is verified by reading the access-point password back.
        case blindlyAcknowledges(holding: String)
    }

    /// ONE FILE THIS RECORDER IS HOLDING, in the reference trace's own fields.
    ///
    /// `content` USED TO BE ABSENT ON PURPOSE — "nothing in this suite downloads, and a
    /// fixture that carried bytes would invite one to". Something now does, so the bytes are
    /// here, and the interesting fixtures are the ones where they disagree with `sizeBytes`:
    /// announcing more than is ever sent is how a transfer that stops partway is modelled, and
    /// content with no `0xFF 0xF3` anywhere is how a file this build cannot read is. `nil`
    /// keeps the old shape for every scenario that only ever lists.
    struct ScriptedRecording: Sendable, Equatable {
        let date: String
        let timestamp: String
        let sizeBytes: Int
        /// The bytes this firmware will actually put on the audio characteristic, which is NOT
        /// required to be `sizeBytes` long.
        let content: Data?
        /// THE SIZE THIS FIRMWARE ANNOUNCES WHEN THE FILE IS ASKED FOR, which is a DIFFERENT
        /// number from the one it listed. Real firmware answers `LIST&<day>` and `U&<file>`
        /// from two different places, and nothing on the wire makes them agree — which is the
        /// hole a ceiling that only ever checked the LISTED size sailed straight through.
        /// Defaults to `sizeBytes`, so every existing fixture is unchanged.
        let announcedSizeBytes: Int?

        init(date: String, timestamp: String, sizeBytes: Int, content: Data? = nil,
             announcedSizeBytes: Int? = nil) {
            self.date = date
            self.timestamp = timestamp
            self.sizeBytes = sizeBytes
            self.content = content
            self.announcedSizeBytes = announcedSizeBytes
        }
    }

    let deviceId: UUID
    let deviceName: String
    private let behaviour: KeyBehaviour
    /// The key this recorder is holding right now, which the WiFi read-back is derived from.
    /// It changes only when the firmware genuinely takes a new one.
    private var heldKey: String?
    /// Whether this firmware answers `APP&WIFI` at all. A firmware that does not is
    /// `MCU&UNKNOWN` — an honest "not proven", which is a different answer from a refusal.
    private let answersWiFiReadback: Bool
    /// What this recorder is holding, in the order its firmware lists it.
    private let inventory: [ScriptedRecording]
    /// Whether this firmware answers `LIST_DIRS` / `LIST&` at all. `false` is the honest
    /// "this build's command is not one I know" — `MCU&UNKNOWN` — which is a different answer
    /// from a recorder that lists nothing.
    private let answersInventory: Bool
    private let map: PocketCharacteristicMap

    /// HOW A DEVICE FAILS TO BE REACHED, as the shapes a real radio actually produces. The
    /// scripted recorder above models a device that answers; these model the ways one does
    /// not, which is the half the connect sheet had no vocabulary for.
    struct Reachability: Sendable {
        /// `retrievePeripherals(withIdentifiers:)` comes up empty on this central — the state
        /// every never-bonded peripheral discovered by a DIFFERENT central is in.
        var retrievableByIdentifier = true
        /// Whether an unfiltered scan on this central turns the device up.
        var answersScan = true
        /// `connect` produces `didFailToConnect` instead of `didConnect`.
        var refusesToConnect = false
        /// `connect` produces nothing at all, so the connect gate has to time out.
        var neverAnswersConnect = false
        /// Connected, and `discoverServices` never calls back.
        var neverListsServices = false
    }

    /// Mutable so a scenario can stage the failure it is about without a second initialiser.
    var reachability: Reachability {
        get { lock.lock(); defer { lock.unlock() }; return storedReachability }
        set { lock.lock(); storedReachability = newValue; lock.unlock() }
    }
    private var storedReachability = Reachability()

    private let lock = NSLock()
    private weak var sink: BLEEventSink?
    private var queue: DispatchQueue?
    private var central: FakePocketBLECentral?
    private(set) var peripheral: FakePocketBLEPeripheral!
    private var writtenCommands: [String] = []
    private var connected = false

    /// - Parameters:
    ///   - map: which shipped characteristic map this firmware exposes. Both are real
    ///     alternatives in `PocketBLEClient.connect`, so both are drivable here.
    ///   - exposesStoredFileProtocol: false builds a peripheral with a service that is not a
    ///     stored-file one — the non-vacuity case, where the attachment must NOT claim a class.
    init(deviceId: UUID = UUID(),
         deviceName: String = "PKT01",
         acceptedSecret: String? = "0123456789abcdef",
         map: PocketCharacteristicMap = .primary,
         exposesStoredFileProtocol: Bool = true,
         alsoExposesOmiAudioService: Bool = false,
         answersWiFiReadback: Bool = true,
         inventory: [ScriptedRecording] = [],
         answersInventory: Bool = true,
         behaviour: KeyBehaviour? = nil) {
        self.inventory = inventory
        self.answersInventory = answersInventory
        self.deviceId = deviceId
        self.deviceName = deviceName
        // `acceptedSecret` stays the shorthand every existing scenario is written in: a value
        // is a recorder keyed to it, `nil` is a recorder Solleva holds no key for. `behaviour`
        // is the explicit spelling the mint scenarios need.
        self.behaviour = behaviour ?? acceptedSecret.map { KeyBehaviour.keyed($0) } ?? .factoryFresh
        switch self.behaviour {
        case .factoryFresh:                   self.heldKey = nil
        case .keyed(let key):                 self.heldKey = key
        case .blindlyAcknowledges(let key):   self.heldKey = key
        }
        self.answersWiFiReadback = answersWiFiReadback
        self.map = map
        var services: [FakePocketBLEService] = []
        if exposesStoredFileProtocol {
            var characteristics = [FakePocketBLECharacteristic(Self.characteristicUUID(map.command)),
                                   FakePocketBLECharacteristic(Self.characteristicUUID(map.audio))]
            if map.control != map.command {
                characteristics.append(
                    FakePocketBLECharacteristic(Self.characteristicUUID(map.control)))
            }
            services.append(FakePocketBLEService(Self.serviceUUID, characteristics: characteristics))
        }
        if alsoExposesOmiAudioService {
            services.append(FakePocketBLEService(
                OmiUUID.audioService,
                characteristics: [FakePocketBLECharacteristic(OmiUUID.audioDataChar)]))
        }
        if services.isEmpty {
            services.append(FakePocketBLEService(
                CBUUID(string: "180A"),
                characteristics: [FakePocketBLECharacteristic(CBUUID(string: "2A29"))]))
        }
        peripheral = FakePocketBLEPeripheral(identifier: deviceId, name: deviceName,
                                             services: services, stack: self)
    }

    /// `@Sendable` because the shipped compositions that take a factory — including
    /// `PocketSessionKeyEntryCoordinator.live`, which builds a fresh attachment inside a
    /// concurrent closure — require one. The stack is already `@unchecked Sendable`; every
    /// field it touches here is under its own lock.
    var factory: @Sendable (BLEEventSink, DispatchQueue, String?) -> BLECentral {
        { [weak self] sink, queue, _ in
            guard let self else {
                fatalError("the fake Pocket stack was released before a central was asked for")
            }
            let made = FakePocketBLECentral(stack: self)
            self.lock.lock()
            self.sink = sink
            self.queue = queue
            self.central = made
            self.lock.unlock()
            self.deliver { $0.bleCentralDidUpdateState(made) }
            return made
        }
    }

    /// Every `APP&…` command the production code actually wrote, in order. This is what makes
    /// "FoundryX sent the recorder nothing" a checkable claim rather than a reassurance.
    var commandsWritten: [String] {
        lock.lock(); defer { lock.unlock() }; return writtenCommands
    }

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }; return connected
    }

    // MARK: the scan, and CoreBluetooth's own filter semantics

    private var lastScanFilter: [CBUUID]??

    fileprivate func recordScanFilter(_ services: [CBUUID]?) {
        lock.lock(); lastScanFilter = .some(services); lock.unlock()
    }

    /// nil until a scan was issued; `.some(nil)` for an UNFILTERED scan.
    var observedScanServiceFilter: [CBUUID]?? {
        lock.lock(); defer { lock.unlock() }; return lastScanFilter
    }

    /// THE FILTER SEMANTICS, MODELLED RATHER THAN ASSUMED. `scanForPeripherals(withServices:)`
    /// reports a peripheral only when the scan asked for no services at all, or asked for one
    /// this peripheral advertises. That is the whole of finding 2: a recorder advertising no
    /// live-audio service could never answer a scan filtered to one, so this device answers
    /// here exactly when it would answer on a real radio.
    ///
    /// - Returns: whether the peripheral was reported.
    @discardableResult
    func deliverScanResult(rssi: Int = -50) -> Bool {
        lock.lock()
        let filter = lastScanFilter ?? nil
        lock.unlock()
        let advertised = Set(peripheral.advertisedServiceUUIDs)
        if let filter, !filter.contains(where: { advertised.contains($0) }) { return false }
        let central = currentCentral
        deliver { sink in
            guard let central else { return }
            sink.bleCentral(central, didDiscover: self.peripheral, rssi: rssi)
        }
        return true
    }

    /// THE SINK IS BOUND WHEN THE EVENT HAPPENS, NOT WHEN THE QUEUE GETS TO IT.
    ///
    /// This used to re-read `self.sink` inside the async block, which made an event belong to
    /// whichever attachment was registered by the time it was dequeued. A second session over
    /// the same recorder — a check after a bring-over, a bring-over after a bring-over — is
    /// exactly the case that breaks: the FIRST attachment's teardown queues a disconnect, the
    /// SECOND attachment registers before it runs, and the new session is told its link
    /// dropped before it ever opened. A real radio cannot do that; each attachment builds its
    /// own `CBCentralManager` and only ever hears its own delegate callbacks.
    fileprivate func deliver(_ body: @escaping (BLEEventSink) -> Void) {
        lock.lock()
        let queue = self.queue
        let sink = self.sink
        lock.unlock()
        guard let queue, let sink else { return }
        queue.async { body(sink) }
    }

    fileprivate var currentCentral: FakePocketBLECentral? {
        lock.lock(); defer { lock.unlock() }; return central
    }

    fileprivate func issueConnect() {
        let staged = reachability
        if staged.neverAnswersConnect { return }
        if staged.refusesToConnect {
            let central = currentCentral
            deliver { sink in
                guard let central else { return }
                sink.bleCentral(central, didFailToConnect: self.peripheral, error: nil)
            }
            return
        }
        lock.lock(); connected = true; lock.unlock()
        peripheral.setLinkState(.connected)
        let central = currentCentral
        deliver { sink in
            guard let central else { return }
            sink.bleCentral(central, didConnect: self.peripheral)
        }
    }

    fileprivate func cancelConnection() {
        lock.lock()
        let wasConnected = connected
        connected = false
        lock.unlock()
        guard wasConnected else { return }
        peripheral.forgetDiscoveredGraph()
        peripheral.setLinkState(.disconnected)
        let central = currentCentral
        deliver { sink in
            guard let central else { return }
            sink.bleCentral(central, didDisconnect: self.peripheral, error: nil)
        }
    }

    /// THE FIRMWARE'S ANSWERS. Only the reference-trace control frames, and only for the
    /// commands the adoption chain issues.
    fileprivate func handleWrite(_ data: Data, to characteristic: FakePocketBLECharacteristic) {
        guard characteristic.uuid == Self.characteristicUUID(map.command),
              let text = String(data: data, encoding: .ascii),
              text.hasPrefix("APP&") else { return }
        let command = String(text.dropFirst("APP&".count))
        lock.lock(); writtenCommands.append(command); lock.unlock()

        let response: String?
        if command.hasPrefix("SK&") {
            let offered = String(command.dropFirst("SK&".count))
            response = answerToKeyWrite(offered)
        } else if command == "BAT" {
            response = "MCU&BAT&72"
        } else if command == "FW" {
            response = "MCU&FW&1.6"
        } else if command == "LIST_DIRS", answersInventory {
            // THE DAYS, THEN THE COUNT — the reference trace's own two-frame shape. The count
            // frame is what makes an interrupted sequence detectable, so it is emitted here
            // rather than assumed by the reader.
            var days: [String] = []
            for recording in inventory where !days.contains(recording.date) {
                days.append(recording.date)
            }
            for day in days { notifyControl("MCU&DIRS&\(day)") }
            notifyControl("MCU&DIRS_SUM&\(days.count)")
            return
        } else if command.hasPrefix("LIST&"), answersInventory {
            let day = String(command.dropFirst("LIST&".count))
            let files = inventory.filter { $0.date == day }
            for file in files {
                notifyControl("MCU&F&\(file.date)&\(file.timestamp)&\(file.sizeBytes)")
            }
            notifyControl("MCU&LIST&\(files.count)")
            return
        } else if command.hasPrefix("U&"), answersInventory {
            // THE PULL, AS THE FIRMWARE SERIALISES IT: one control frame announcing the size,
            // then the file itself on the AUDIO characteristic. The chunking is deliberate —
            // a fixture that answered in one notification would leave the client's
            // multi-notification assembly, the half this protocol actually fails in, unproven.
            let parts = command.dropFirst("U&".count)
                .split(separator: "&", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let file = inventory.first(where: {
                      $0.date == parts[0] && $0.timestamp == parts[1]
                  }),
                  let content = file.content else {
                notifyControl("MCU&UNKNOWN")
                return
            }
            notifyControl("MCU&U&\(file.announcedSizeBytes ?? file.sizeBytes)")
            var offset = content.startIndex
            while offset < content.endIndex {
                let end = content.index(offset, offsetBy: Self.notificationBytes,
                                        limitedBy: content.endIndex) ?? content.endIndex
                notifyAudio(content.subdata(in: offset..<end))
                offset = end
            }
            // AND THEN IT STOPS. A recorder whose `content` is shorter than what it announced
            // says nothing more, which is exactly what a transfer that died partway looks like
            // from the phone: no error frame, just silence.
            return
        } else if command == "WIFI" {
            // THE READ-BACK, DERIVED FROM WHAT THE FIRMWARE IS ACTUALLY HOLDING.
            //
            // This is the whole reason the fake is allowed to decide anything: the access-point
            // password is the first eight characters of the key the RECORDER has, not of the
            // key the app hoped it took. A blindly-acknowledging recorder therefore reports the
            // OLD key's password here, exactly as real hardware would, and the production code
            // is what has to notice.
            lock.lock(); let held = heldKey; lock.unlock()
            if !answersWiFiReadback || held == nil {
                response = "MCU&UNKNOWN"
            } else {
                response = "MCU&WIFI&\(deviceName)&\(String(held!.prefix(8)))"
            }
        } else {
            response = "MCU&UNKNOWN"
        }
        guard let response else { return }
        notifyControl(response)
    }

    /// The firmware's key-write policy, per modelled behaviour.
    private func answerToKeyWrite(_ offered: String) -> String {
        lock.lock(); defer { lock.unlock() }
        switch behaviour {
        case .factoryFresh:
            // The observed hardware fact: the first key written IS the key from then on.
            if heldKey == nil || heldKey == offered {
                heldKey = offered
                return "MCU&SK&OK"
            }
            return offered == heldKey ? "MCU&SK&OK" : "MCU&SK&FAIL"
        case .keyed(let key):
            return offered == key ? "MCU&SK&OK" : "MCU&SK&FAIL"
        case .blindlyAcknowledges:
            // Says yes and changes nothing. `heldKey` deliberately does NOT move.
            return "MCU&SK&OK"
        }
    }

    /// What the firmware is holding, so a scenario can assert a mint actually landed — or
    /// actually did not.
    var keyHeldByRecorder: String? {
        lock.lock(); defer { lock.unlock() }; return heldKey
    }

    /// One BLE notification's worth of a file, matching this peripheral's own
    /// `maximumWriteValueLength`. Small enough that even the shortest fixture arrives in
    /// several frames.
    static let notificationBytes = 180

    private func notifyAudio(_ bytes: Data) {
        guard let audio = peripheral
            .discoveredCharacteristic(Self.characteristicUUID(map.audio)) else { return }
        deliver { [weak self] sink in
            guard let self else { return }
            audio.value = bytes
            sink.blePeripheral(self.peripheral, didUpdateValueFor: audio, error: nil)
        }
    }

    private func notifyControl(_ text: String) {
        guard let control = peripheral
            .discoveredCharacteristic(Self.characteristicUUID(map.control)) else { return }
        deliver { [weak self] sink in
            guard let self else { return }
            control.value = Data(text.utf8)
            sink.blePeripheral(self.peripheral, didUpdateValueFor: control, error: nil)
        }
    }

    func drain() {
        lock.lock()
        let queue = self.queue
        lock.unlock()
        queue?.sync {}
    }
}

// MARK: - The four wrapped types, faked

final class FakePocketBLECharacteristic: BLECharacteristic, @unchecked Sendable {
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

final class FakePocketBLEService: BLEService, @unchecked Sendable {
    let uuid: CBUUID
    private let lock = NSLock()
    private let catalog: [FakePocketBLECharacteristic]
    private var discovered: [FakePocketBLECharacteristic]?

    init(_ uuid: CBUUID, characteristics: [FakePocketBLECharacteristic]) {
        self.uuid = uuid
        self.catalog = characteristics
    }

    var discoveredCharacteristics: [BLECharacteristic]? {
        lock.lock(); defer { lock.unlock() }
        return discovered
    }

    fileprivate func discover(_ uuids: [CBUUID]?) {
        lock.lock()
        discovered = catalog.filter { uuids?.contains($0.uuid) ?? true }
        lock.unlock()
    }

    fileprivate func forgetDiscovered() {
        lock.lock(); discovered = nil; lock.unlock()
    }

    fileprivate func characteristic(_ uuid: CBUUID) -> FakePocketBLECharacteristic? {
        lock.lock(); defer { lock.unlock() }
        return (discovered ?? []).first { $0.uuid == uuid }
    }
}

final class FakePocketBLEPeripheral: BLEPeripheral, @unchecked Sendable {
    let identifier: UUID
    let name: String?
    private let catalog: [FakePocketBLEService]
    private unowned let stack: FakePocketBLEStack
    private let lock = NSLock()
    private var state: CBPeripheralState = .disconnected
    private var discovered: [FakePocketBLEService]?
    private(set) var boundToSink = false

    init(identifier: UUID, name: String?, services: [FakePocketBLEService],
         stack: FakePocketBLEStack) {
        self.identifier = identifier
        self.name = name
        self.catalog = services
        self.stack = stack
    }

    /// What this device BROADCASTS — what a filtered scan matches against.
    var advertisedServiceUUIDs: [CBUUID] { catalog.map(\.uuid) }

    var linkState: CBPeripheralState {
        lock.lock(); defer { lock.unlock() }; return state
    }

    fileprivate func setLinkState(_ newState: CBPeripheralState) {
        lock.lock(); state = newState; lock.unlock()
    }

    var discoveredServices: [BLEService]? {
        lock.lock(); defer { lock.unlock() }
        return discovered
    }

    fileprivate func forgetDiscoveredGraph() {
        lock.lock(); discovered = nil; lock.unlock()
        for service in catalog { service.forgetDiscovered() }
    }

    fileprivate func discoveredCharacteristic(_ uuid: CBUUID) -> FakePocketBLECharacteristic? {
        lock.lock()
        let services = discovered ?? []
        lock.unlock()
        for service in services {
            if let match = service.characteristic(uuid) { return match }
        }
        return nil
    }

    func routeEventsToSink() {
        lock.lock(); boundToSink = true; lock.unlock()
    }

    func discoverServices(_ serviceUUIDs: [CBUUID]?) {
        // A CONNECTED DEVICE THAT NEVER SAYS WHAT IT CAN DO. Not an error callback — silence,
        // which is what the discovery deadline exists for and what the sheet used to render
        // as "bring it closer".
        if stack.reachability.neverListsServices { return }
        let found = catalog.filter { serviceUUIDs?.contains($0.uuid) ?? true }
        lock.lock(); discovered = found; lock.unlock()
        stack.deliver { [weak self] sink in
            guard let self else { return }
            sink.blePeripheral(self, didDiscoverServices: nil)
        }
    }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: BLEService) {
        guard let service = service as? FakePocketBLEService else {
            fatalError("the fake Pocket peripheral was handed a \(type(of: service))")
        }
        service.discover(characteristicUUIDs)
        stack.deliver { [weak self] sink in
            guard let self else { return }
            sink.blePeripheral(self, didDiscoverCharacteristicsFor: service, error: nil)
        }
    }

    func readValue(for characteristic: BLECharacteristic) {
        stack.deliver { [weak self] sink in
            guard let self else { return }
            sink.blePeripheral(self, didUpdateValueFor: characteristic, error: nil)
        }
    }

    func writeValue(_ data: Data, for characteristic: BLECharacteristic,
                    type: CBCharacteristicWriteType) {
        guard let characteristic = characteristic as? FakePocketBLECharacteristic else { return }
        stack.handleWrite(data, to: characteristic)
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: BLECharacteristic) {
        (characteristic as? FakePocketBLECharacteristic)?.isNotifying = enabled
        stack.deliver { [weak self] sink in
            guard let self else { return }
            sink.blePeripheral(self, didUpdateNotificationStateFor: characteristic, error: nil)
        }
    }

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 180 }
}

final class FakePocketBLECentral: BLECentral, @unchecked Sendable {
    private unowned let stack: FakePocketBLEStack

    init(stack: FakePocketBLEStack) { self.stack = stack }

    var managerState: CBManagerState { .poweredOn }

    /// CoreBluetooth's own caveat, modelled. `retrievePeripherals` returns peripherals the
    /// SYSTEM knows; a never-bonded device that a different central merely saw advertising is
    /// not reliably one of them, and `reachability.retrievableByIdentifier == false` is that
    /// device. The production code's answer is to go and scan for it.
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [BLEPeripheral] {
        guard stack.reachability.retrievableByIdentifier else { return [] }
        return identifiers.contains(stack.deviceId) ? [stack.peripheral] : []
    }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
        stack.recordScanFilter(serviceUUIDs)
        // A DEVICE THAT IS STILL ADVERTISING ANSWERS A SCAN. `DeviceManager`'s own scan
        // scenarios drive `deliverScanResult()` by hand and are unaffected: this fires only
        // for a stack staged as un-retrievable, which is the case the rescan exists for.
        guard !stack.reachability.retrievableByIdentifier,
              stack.reachability.answersScan else { return }
        stack.deliverScanResult()
    }

    func stopScan() {}

    func connect(_ peripheral: BLEPeripheral, options: [String: Any]?) {
        stack.issueConnect()
    }

    func cancelPeripheralConnection(_ peripheral: BLEPeripheral) {
        stack.cancelConnection()
    }
}
