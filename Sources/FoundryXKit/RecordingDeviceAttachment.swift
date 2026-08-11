// RecordingDeviceAttachment.swift — THE MISSING LEG OF THE ADOPTION CHAIN.
//
// WHAT WAS MISSING, STATED PLAINLY. `PocketRecordingDeviceBridge.observe` turned an
// authenticated stored-file session into a vendor-neutral observation, and
// `RecordingDeviceAdoption.remember` turned that observation into the account's remembered
// device. Both existed. Neither had a caller outside `Tests/`. The chain the design draws —
//
//     scan discovers it → the user taps it → the transport client authenticates it →
//     PocketRecordingDeviceBridge.observe → RecordingDeviceAdoption.remember →
//     RecordingDeviceStore record → the unified list
//
// — was wired from `observe` rightwards and from `scan` leftwards, with nothing in between:
// there was no `PocketBLETransport` conformance backed by a radio anywhere in the tree, so
// the only `.filePull` record a device list could ever draw was one a TEST had written.
// This file is the middle. It is the only place a real peripheral becomes a
// `PocketBLEClient`.
//
// IT IS WRITTEN AGAINST THE SEAM, NOT AGAINST CoreBluetooth. `BLECentral` / `BLEPeripheral` /
// `BLEService` / `BLECharacteristic` are the same four wrapped types `DeviceManager` runs on,
// so the production path and the headless test path are the SAME code with a different
// factory — which is what makes the Brine scenario below evidence about the app rather than
// evidence about a fake.
//
// THE ONE STEP THIS BUILD GENUINELY CANNOT TAKE, AND IT IS NOT PAPERED OVER. Attaching a
// stored-file recorder requires a 16-byte session secret. FoundryX can RESTORE one it already
// holds (`PocketOnboardingCoordinator.restore`), and that whole leg runs here for real. It
// cannot MINT one: `provisionFactoryFresh` is documented as "called only for a factory-fresh
// unit after the firmware alphabet/entropy gate is met", and DESIGN-pocket-connect.md §3.6 /
// T2 req 3 hold that gate shut until an evidenced firmware-compatible key alphabet and a
// security-reviewed entropy policy exist. So a recorder FoundryX has never provisioned comes
// back `.setupUnavailable` — the shipped §3.6 screen, which says out loud that setup is off
// and that the recorder was sent nothing. That is the honest stopping point, and it is a
// RETURN VALUE rather than a comment so the UI has to render it.
//
// SAID EVEN MORE PLAINLY, BECAUSE IT IS THE THING MOST EASILY OVERCLAIMED: nothing anywhere
// in this app calls `provisionFactoryFresh`, so on a real phone today the Keychain holds a
// secret for no recorder and EVERY tap on a stored-file device lands on `.setupUnavailable`.
// The chain above it is complete and proven end to end — the transport, the client, the
// handshake, the bridge, the adoption, the store, the row — and the key is the one link that
// is still missing. It is missing on purpose, it is visible in the UI, and it is the single
// change that turns this from "reachable" into "reaches".
//
// WHAT IT DELIBERATELY DOES NOT DO. It does not decide that a device is live. If the
// peripheral speaks no stored-file protocol, it says so and hands the tap back to the shipped
// `DeviceManager.connect` path untouched — a Pocket leg that could break Omi pairing would be
// a bad trade for a device nobody can attach yet.

#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// What a connect attempt ESTABLISHED — never what a name or a shape suggested.
///
/// Design §1: *"the scan list below shows no class, no battery, and no capabilities. Class
/// appears the moment the transport client establishes which protocol the device actually
/// speaks."* This enum is that moment, as a value.
public enum RecordingDeviceAttachOutcome: Equatable, Sendable {
    /// It speaks the stored-file protocol, FoundryX restored custody, and the account now
    /// remembers it. The device list draws it on the next refresh.
    case adopted(identity: RecordingDeviceIdentity,
                 displayName: String,
                 negotiatedProtocol: String)
    /// It speaks the stored-file protocol and FoundryX holds no key for it. Provisioning is
    /// gated (design §3.6 / T2 req 3), so this is where the ceremony honestly stops.
    /// NOTHING was written to the recorder to reach this state.
    case setupUnavailable
    /// FoundryX held a key and the recorder refused it.
    case recoveryRequired
    /// The protocol leg succeeded and the ACCOUNT STORE could not keep the result — a lost
    /// user decision, so it is a case of its own rather than a silent success.
    case adoptionNotPersisted(String)
    /// It exposes the live audio service. The caller runs the shipped pairing path.
    case live
    /// It connected and spoke nothing this build knows.
    case unrecognised
    /// It never got far enough to establish anything.
    case unreachable(String)
}

/// The copy a tap can produce, in the kit rather than in the view — for the same reason every
/// other string on this screen is: `swift test` cannot compile `App/`, so a line invented in a
/// SwiftUI body is a second, unasserted implementation of the app's voice.
///
/// IT NAMES NO VENDOR AND NO CLASS. A tap that established nothing has established nothing to
/// name: the whole premise of the connect sheet is that the app cannot tell what a device is
/// until it connects, and a failure is the case where it still cannot.
public enum RecordingDeviceAttachPresentation {
    /// While the transport is establishing what the device speaks. Not "Pairing" — nothing is
    /// paired until custody is settled — and not a class caption.
    public static let connectingLine = "Connecting…"

    /// The link never came up, or came up and went away.
    public static let unreachableLine =
        "FoundryX couldn't connect to that device. Bring it closer and try again."

    /// The protocol leg worked and the ACCOUNT could not keep the result. A lost user
    /// decision is said out loud rather than shown as a device that silently never appears.
    public static let notRememberedLine =
        "FoundryX connected to that device but couldn't save it to your account. Try again."

    /// Every line this surface can render, so "it names no vendor" is held over the
    /// population rather than over whichever string a test author remembered.
    public static let everyLine: [String] = [connectingLine, unreachableLine, notRememberedLine]

    /// The inline line an outcome earns, or nil when the outcome is not an inline message —
    /// `.adopted` closes the sheet, `.live` / `.unrecognised` hand the tap to the shipped
    /// pairing path, and `.setupUnavailable` / `.recoveryRequired` are whole screens.
    public static func inlineMessage(for outcome: RecordingDeviceAttachOutcome) -> String? {
        switch outcome {
        case .unreachable:          return unreachableLine
        case .adoptionNotPersisted: return notRememberedLine
        case .adopted, .setupUnavailable, .recoveryRequired, .live, .unrecognised: return nil
        }
    }
}

public enum RecordingDeviceAttachError: Error, Equatable, Sendable, CustomStringConvertible {
    case radioUnavailable
    case timedOut(String)
    case linkDropped
    case notConnected
    case unknownCharacteristic(String)

    public var description: String {
        switch self {
        case .radioUnavailable:            return "Bluetooth is not available"
        case .timedOut(let stage):         return "\(stage) timed out"
        case .linkDropped:                 return "the link dropped"
        case .notConnected:                return "not connected"
        case .unknownCharacteristic(let t): return "no characteristic \(t)"
        }
    }
}

/// Bridges the shipped `PocketBLEClient` onto the shipped `PocketOnboardingCoordinator`.
///
/// The coordinator owns the ORDER custody is attempted in ("restore FoundryX custody first.
/// No speculative fresh write."), and that order is a security property, not a convenience.
/// Re-implementing it here would be a second, untested copy of it.
struct PocketProtocolOnboardingClient: PocketOnboardingClient {
    let client: PocketBLEClient

    func authenticate(secret: String) async -> PocketOnboardingAuthentication {
        do {
            try await client.authenticate(secret: secret)
            return .accepted
        } catch PocketProtocolError.authenticationRejected {
            return .rejected
        } catch {
            return .indeterminate
        }
    }

    func confirmation() async throws -> PocketOnboardingConfirmation {
        PocketOnboardingConfirmation(batteryPercent: try await client.batteryLevel(),
                                     firmware: try await client.firmwareVersion())
    }

    func close() async { await client.close() }
}

/// One tap's worth of radio work: connect, discover, decide what the device speaks, and — if
/// it speaks the stored-file protocol — run the real custody restore and the real adoption.
///
/// IT OWNS ITS OWN CENTRAL, exactly as `BatteryMonitor` does, so a connect probe can never
/// disturb `DeviceManager`'s audio link or its CoreBluetooth state restoration. It is created
/// per screen, not per app.
public final class RecordingDeviceAttachment: BLEEventSink, @unchecked Sendable {

    /// Every wait in the flow is BOUNDED. `CBCentralManager.connect` has no timeout of its
    /// own — a tap on a device that walked away would otherwise hang the sheet forever.
    public struct Deadlines: Sendable {
        public var powerOn: TimeInterval
        public var connect: TimeInterval
        public var discovery: TimeInterval
        public var control: TimeInterval

        public init(powerOn: TimeInterval = 3,
                    connect: TimeInterval = 10,
                    discovery: TimeInterval = 10,
                    control: TimeInterval = 8) {
            self.powerOn = powerOn
            self.connect = connect
            self.discovery = discovery
            self.control = control
        }
    }

    private enum Gate: Hashable { case poweredOn, connected, services, characteristics }

    private let bleQueue: DispatchQueue
    private let makeCentral: BLECentralFactory
    private let secrets: any PocketSecretStore
    private let deadlines: Deadlines
    private let log: DoorLog?

    private let lock = NSLock()
    private var central: BLECentral?
    private var peripheral: BLEPeripheral?
    private var satisfied: Set<Gate> = []
    private var waiters: [Gate: [CheckedContinuation<Void, Error>]] = [:]
    private var outstandingServices = 0
    private var characteristicsByToken: [String: BLECharacteristic] = [:]
    private var tokens: Set<String> = []
    private var serviceUUIDs: Set<CBUUID> = []
    private var controlCharacteristic: BLECharacteristic?
    private var audioCharacteristic: BLECharacteristic?
    private var pendingEvents: [PocketTransportEvent] = []
    private var eventWaiters: [CheckedContinuation<PocketTransportEvent, Error>] = []
    private var generation: UInt64 = 1
    private var torndown = false

    public init(makeCentral: @escaping BLECentralFactory = CoreBluetoothCentral.make,
                secrets: any PocketSecretStore = KeychainPocketSecretStore(),
                deadlines: Deadlines = Deadlines(),
                queue: DispatchQueue? = nil,
                log: DoorLog? = nil) {
        self.makeCentral = makeCentral
        self.secrets = secrets
        self.deadlines = deadlines
        self.bleQueue = queue ?? DispatchQueue(label: "foundryx.recording-device-attach")
        self.log = log
    }

    // MARK: - The one entry point

    /// Attach the device the user tapped, and report what was actually established.
    ///
    /// `advertisedName` is DISPLAY metadata and nothing else. The durable address is the
    /// authenticated peripheral token — a device that renames itself is the same device.
    public func attach(peripheralIdentifier id: UUID,
                       advertisedName: String) async -> RecordingDeviceAttachOutcome {
        do {
            try await reachDiscoveredGraph(of: id)
        } catch {
            teardown()
            return .unreachable(describe(error))
        }

        guard speaksStoredFileProtocol else {
            let sawAudio = lock.withLock { serviceUUIDs.contains(OmiUUID.audioService) }
            teardown()
            return sawAudio ? .live : .unrecognised
        }

        let outcome = await adoptStoredFileRecorder(id: id, advertisedName: advertisedName)
        teardown()
        return outcome
    }

    // MARK: - Radio flow

    private func reachDiscoveredGraph(of id: UUID) async throws {
        let created: BLECentral = lock.withLock {
            if let central { return central }
            let made = makeCentral(self, bleQueue, nil)
            central = made
            return made
        }
        if created.managerState == .poweredOn { fulfil(.poweredOn) }
        try await wait(for: .poweredOn, stage: "Bluetooth power-on", timeout: deadlines.powerOn)
        guard created.managerState == .poweredOn else {
            throw RecordingDeviceAttachError.radioUnavailable
        }
        // `retrievePeripherals(withIdentifiers:)` is a SYSTEM lookup, not a per-central cache,
        // so the peripheral the pairing scan surfaced on `DeviceManager`'s central is
        // reachable from this one. That is what lets the probe own a separate central.
        guard let found = created.retrievePeripherals(withIdentifiers: [id]).first else {
            throw RecordingDeviceAttachError.notConnected
        }
        lock.withLock { peripheral = found }
        found.routeEventsToSink()
        created.connect(found, options: nil)
        try await wait(for: .connected, stage: "connecting", timeout: deadlines.connect)

        // EVERY service, because the app genuinely does not know what this device is yet.
        // Asking for one vendor's service UUID is the same mistake the scan filter was.
        found.discoverServices(nil)
        try await wait(for: .services, stage: "service discovery", timeout: deadlines.discovery)

        let services = found.discoveredServices ?? []
        lock.withLock {
            serviceUUIDs = Set(services.map(\.uuid))
            outstandingServices = services.count
            if services.isEmpty { satisfied.insert(.characteristics) }
        }
        for service in services { found.discoverCharacteristics(nil, for: service) }
        try await wait(for: .characteristics, stage: "characteristic discovery",
                       timeout: deadlines.discovery)
    }

    /// Does the discovered graph carry EITHER shipped stored-file characteristic map?
    private var speaksStoredFileProtocol: Bool {
        let available = lock.withLock { tokens }
        return PocketCharacteristicMap.primary.required.isSubset(of: available)
            || PocketCharacteristicMap.fallback.required.isSubset(of: available)
    }

    private func adoptStoredFileRecorder(
        id: UUID, advertisedName: String
    ) async -> RecordingDeviceAttachOutcome {
        let map = characteristicMap()
        guard let map, let peripheral = lock.withLock({ peripheral }) else {
            return .unreachable("the recorder stopped exposing its protocol characteristics")
        }
        // Subscribe BEFORE the first command: a write issued before the notify state settles
        // has nowhere to answer, which is a silent hang rather than an error.
        let control = lock.withLock { characteristicsByToken[map.control] }
        let audio = lock.withLock { characteristicsByToken[map.audio] }
        lock.withLock {
            controlCharacteristic = control
            audioCharacteristic = audio
        }
        if let control { peripheral.setNotifyValue(true, for: control) }
        if let audio, audio !== control { peripheral.setNotifyValue(true, for: audio) }

        let transport = PocketSeamTransport(link: self, timeout: deadlines.control)
        guard let client = try? await PocketBLEClient.connect(transport: transport) else {
            return .unreachable("the recorder exposed no protocol this build speaks")
        }
        guard let identity = try? PocketAuthenticatedIdentity(peripheralIdentifier: id.uuidString)
        else {
            await client.close()
            return .unreachable("this device has no usable durable identity")
        }

        // THE SHIPPED CUSTODY ORDER, THROUGH THE SHIPPED COORDINATOR. Restore first; never a
        // speculative fresh write. `coexistenceAvailable` means "FoundryX holds no key for
        // this recorder", and minting one is exactly what T2 req 3 gates.
        let coordinator = PocketOnboardingCoordinator(
            client: PocketProtocolOnboardingClient(client: client), store: secrets)
        let state = await coordinator.restore(identity: identity)
        switch state {
        case .ready:
            let observation = await PocketRecordingDeviceBridge.observe(
                client: client, identity: identity, advertisedName: advertisedName)
            await client.close()
            switch RecordingDeviceAdoption.remember(observation) {
            case .recorded:
                log?.info("recording device: adopted a stored-file recorder")
                return .adopted(identity: observation.identity,
                                displayName: observation.reportedName,
                                negotiatedProtocol: PocketRecordingDeviceBridge.protocolIdentifier)
            case .noMatchingRecord:
                return .adoptionNotPersisted("the account store had no record to update")
            case .unavailable(let reason):
                log?.error("recording device: adoption NOT PERSISTED — "
                    + RecordingDeviceLogRedaction.redactingAccountScopes(reason))
                return .adoptionNotPersisted(reason)
            }
        case .coexistenceAvailable:
            await client.close()
            return .setupUnavailable
        case .indeterminate:
            // THE HANDSHAKE NEVER COMPLETED. `restore` reserves `.indeterminate` for a key
            // that was never answered — a dropped link, a timeout, a firmware that stopped
            // talking after it accepted — and `.recoveryRequired` for a key the recorder
            // actually REFUSED. Reporting the first as the second is how a UI tells someone
            // their key is wrong when their recorder merely walked out of range.
            await client.close()
            return .unreachable("the recorder stopped answering during the key handshake")
        default:
            await client.close()
            return .recoveryRequired
        }
    }

    /// Which shipped map the discovered graph satisfies. Primary wins, exactly as
    /// `PocketBLEClient.connect` chooses it, so the tokens this link writes to are the tokens
    /// the client asks for.
    private func characteristicMap() -> PocketCharacteristicMap? {
        let available = lock.withLock { tokens }
        if PocketCharacteristicMap.primary.required.isSubset(of: available) { return .primary }
        if PocketCharacteristicMap.fallback.required.isSubset(of: available) { return .fallback }
        return nil
    }

    // MARK: - What the transport asks of this link

    func availableTokens() -> Set<String> { lock.withLock { tokens } }

    func write(_ data: Data, to token: String) throws {
        let (peripheral, characteristic) = lock.withLock {
            (self.peripheral, characteristicsByToken[token])
        }
        guard let peripheral else { throw RecordingDeviceAttachError.notConnected }
        guard let characteristic else {
            throw RecordingDeviceAttachError.unknownCharacteristic(token)
        }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    func nextTransportEvent(timeout: TimeInterval) async throws -> PocketTransportEvent {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if torndown {
                lock.unlock()
                continuation.resume(throwing: PocketTransportFailure.disconnected)
                return
            }
            if !pendingEvents.isEmpty {
                let next = pendingEvents.removeFirst()
                lock.unlock()
                continuation.resume(returning: next)
                return
            }
            eventWaiters.append(continuation)
            lock.unlock()
            bleQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.failOldestEventWaiter(with: PocketTransportFailure.timeout)
            }
        }
    }

    private func failOldestEventWaiter(with error: Error) {
        lock.lock()
        guard !eventWaiters.isEmpty else { lock.unlock(); return }
        let waiter = eventWaiters.removeFirst()
        lock.unlock()
        waiter.resume(throwing: error)
    }

    // MARK: - Teardown

    /// Drop the probe's own link and fail everything still waiting on it. Idempotent: the
    /// transport closes, the flow's `defer` closes, and a link drop closes.
    public func teardown() {
        lock.lock()
        guard !torndown else { lock.unlock(); return }
        torndown = true
        generation &+= 1
        let peripheral = self.peripheral
        let central = self.central
        let pendingGates = waiters
        let pendingEventWaiters = eventWaiters
        waiters.removeAll()
        eventWaiters.removeAll()
        pendingEvents.removeAll()
        self.peripheral = nil
        lock.unlock()

        for (_, continuations) in pendingGates {
            for continuation in continuations {
                continuation.resume(throwing: RecordingDeviceAttachError.linkDropped)
            }
        }
        for waiter in pendingEventWaiters {
            waiter.resume(throwing: PocketTransportFailure.disconnected)
        }
        if let peripheral, let central { central.cancelPeripheralConnection(peripheral) }
    }

    // MARK: - Gates

    private func wait(for gate: Gate, stage: String, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if torndown {
                lock.unlock()
                continuation.resume(throwing: RecordingDeviceAttachError.linkDropped)
                return
            }
            if satisfied.contains(gate) {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters[gate, default: []].append(continuation)
            lock.unlock()
            bleQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.fail(gate, with: RecordingDeviceAttachError.timedOut(stage))
            }
        }
    }

    private func fulfil(_ gate: Gate) {
        lock.lock()
        satisfied.insert(gate)
        let pending = waiters.removeValue(forKey: gate) ?? []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    private func fail(_ gate: Gate, with error: Error) {
        lock.lock()
        let pending = waiters.removeValue(forKey: gate) ?? []
        lock.unlock()
        for continuation in pending { continuation.resume(throwing: error) }
    }

    private func describe(_ error: Error) -> String {
        (error as? RecordingDeviceAttachError)?.description ?? error.localizedDescription
    }

    // MARK: - BLEEventSink

    public func bleCentral(_ central: BLECentral, willRestore peripherals: [BLEPeripheral]) {
        // This central is created WITHOUT a restore identifier on purpose: a probe must never
        // be a reason iOS relaunches the app.
    }

    public func bleCentralDidUpdateState(_ central: BLECentral) {
        if central.managerState == .poweredOn {
            fulfil(.poweredOn)
        } else {
            fail(.poweredOn, with: RecordingDeviceAttachError.radioUnavailable)
        }
    }

    public func bleCentral(_ central: BLECentral, didDiscover peripheral: BLEPeripheral, rssi: Int) {}

    public func bleCentral(_ central: BLECentral, didConnect peripheral: BLEPeripheral) {
        guard lock.withLock({ self.peripheral?.identifier == peripheral.identifier }) else { return }
        fulfil(.connected)
    }

    public func bleCentral(_ central: BLECentral, didFailToConnect peripheral: BLEPeripheral,
                           error: Error?) {
        fail(.connected, with: RecordingDeviceAttachError.linkDropped)
    }

    public func bleCentral(_ central: BLECentral, didDisconnect peripheral: BLEPeripheral,
                           error: Error?) {
        guard lock.withLock({ self.peripheral?.identifier == peripheral.identifier }) else { return }
        for gate in [Gate.connected, .services, .characteristics] {
            fail(gate, with: RecordingDeviceAttachError.linkDropped)
        }
        failOldestEventWaiter(with: PocketTransportFailure.disconnected)
    }

    public func blePeripheral(_ peripheral: BLEPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            fail(.services, with: RecordingDeviceAttachError.timedOut("service discovery"))
            return
        }
        fulfil(.services)
    }

    public func blePeripheral(_ peripheral: BLEPeripheral,
                              didDiscoverCharacteristicsFor service: BLEService, error: Error?) {
        var finished = false
        lock.lock()
        for characteristic in service.discoveredCharacteristics ?? [] {
            for token in Self.tokens(of: characteristic.uuid) {
                tokens.insert(token)
                characteristicsByToken[token] = characteristic
            }
        }
        outstandingServices = max(0, outstandingServices - 1)
        finished = outstandingServices == 0
        lock.unlock()
        if finished { fulfil(.characteristics) }
    }

    public func blePeripheral(_ peripheral: BLEPeripheral,
                              didUpdateNotificationStateFor characteristic: BLECharacteristic,
                              error: Error?) {}

    public func blePeripheral(_ peripheral: BLEPeripheral,
                              didUpdateValueFor characteristic: BLECharacteristic,
                              error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        lock.lock()
        let isControl = controlCharacteristic === characteristic
        let isAudio = audioCharacteristic === characteristic
        let event: PocketTransportEvent?
        if isControl {
            event = .control(value, generation: generation)
        } else if isAudio {
            event = .audio(value, generation: generation)
        } else {
            event = nil
        }
        guard let event else { lock.unlock(); return }
        if eventWaiters.isEmpty {
            pendingEvents.append(event)
            lock.unlock()
            return
        }
        let waiter = eventWaiters.removeFirst()
        lock.unlock()
        waiter.resume(returning: event)
    }

    // MARK: - Characteristic tokens

    /// The shipped `PocketCharacteristicMap` addresses characteristics by an 8-hex token
    /// (`001120a3`), which is the leading segment of the vendor's 128-bit UUID. CoreBluetooth
    /// hands back whatever form the peripheral advertised, so a characteristic answers to
    /// EVERY spelling it could be addressed by: the full lowercased UUID string, its leading
    /// segment, and the bare short form. Matching on one spelling only is how a real recorder
    /// would fail the superset check while looking, in the logs, exactly like a device that
    /// speaks nothing.
    static func tokens(of uuid: CBUUID) -> Set<String> {
        let full = uuid.uuidString.lowercased()
        var result: Set<String> = [full]
        if let leading = full.split(separator: "-").first {
            result.insert(String(leading))
        }
        return result
    }
}

/// The `PocketBLETransport` a real radio backs.
///
/// It holds no BLE state of its own: every call is forwarded to the link, whose lock is the
/// one place peripheral objects are touched. That is what keeps this type `Sendable` without
/// making any CoreBluetooth object pretend to be.
final class PocketSeamTransport: PocketBLETransport, @unchecked Sendable {
    private let link: RecordingDeviceAttachment
    private let timeout: TimeInterval

    init(link: RecordingDeviceAttachment, timeout: TimeInterval) {
        self.link = link
        self.timeout = timeout
    }

    func availableCharacteristics() async throws -> Set<String> { link.availableTokens() }

    func write(_ data: Data, to characteristic: String) async throws {
        try link.write(data, to: characteristic)
    }

    /// The generation a notification carries is the LINK's, not the argument's. The link
    /// advances its own generation when it tears down, and stops delivering at the same
    /// moment, so a frame from a retired session cannot reach a live client.
    func nextEvent(generation: UInt64) async throws -> PocketTransportEvent {
        try await link.nextTransportEvent(timeout: timeout)
    }

    func close() async { link.teardown() }
}

#endif
