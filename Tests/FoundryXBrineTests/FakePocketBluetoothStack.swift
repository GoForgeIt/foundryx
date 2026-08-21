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
        /// ALREADY KEYED AND SILENT ABOUT A WRONG ONE: `MCU&SK&OK` for the key it holds, and
        /// NOTHING AT ALL — no `MCU&SK&FAIL`, no error frame — for any other.
        ///
        /// THIS IS OBSERVED HARDWARE, NOT A HYPOTHETICAL. Unit PKT01_BLUE_26079bc5 on firmware
        /// 1.6 was driven from a Mac over `bleak`: `APP&SK&<its key>` answered `MCU&SK&OK` and
        /// `APP&LIST_DIRS` then listed five days and fourteen recordings, while the key Solleva
        /// was holding produced no frame whatsoever until the 8-second control deadline expired.
        /// `.keyed` — which answers `MCU&SK&FAIL` — models the POLITE firmware, and every Pocket
        /// scenario in this repository was written against it, so the whole silent-refusal half
        /// of the state space was unreachable from any test. That is the half the owner was
        /// stuck in.
        case silentToWrongKey(holding: String)
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
        /// HOW BIG THE FILE ACTUALLY IS, in bytes — what a fixture wants to say.
        let sizeBytes: Int
        /// WHAT THE FIRMWARE PUTS ON THE WIRE, which is KILOBYTES:
        /// `MCU&F&<date>&<timestamp>&<size_kb>` (pocket-libre PROTOCOL.md, File
        /// Listing). `sizeBytes` used to be written verbatim into that slot, so
        /// every fixture declared bytes and the wire carried them as kilobytes —
        /// and the test asserting 4000 -> "1 sec" agreed with the implementation
        /// while disagreeing with the device. That is how the owner's entire
        /// library shipped reading "0 sec" and "1 sec". Deriving it here keeps the
        /// fixtures honest about the file AND the wire honest about the protocol.
        /// ROUNDED, not truncated. `480_000 / 1024` truncates to 468 KB, which reads
        /// back as 119.8s and formats as "1 min" — a fixture losing a minute to
        /// integer division rather than to anything the protocol says. Rounding is
        /// also the likelier firmware behaviour for a size it reports in whole KB.
        var sizeKilobytes: Int { (sizeBytes + 512) / 1_024 }
        /// The bytes this firmware will actually put on the audio characteristic,
        /// which is NOT required to agree with the listed size.
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

    /// HOW A TRANSFER IS SPREAD OVER TIME, AND WHAT THE FIRMWARE SAYS WHEN IT ENDS.
    ///
    /// THE FAKE HAD NO TIME AXIS AT ALL, AND THAT IS WHY THE 8-SECOND BUG SHIPPED. `handleWrite`
    /// answered `APP&U&` by emitting every chunk in a tight synchronous `while` loop and then
    /// stopping — no delay between notifications and no end-of-transfer frame. A defect whose
    /// entire mechanism is "the transfer lasts longer than one deadline" is UNREPRESENTABLE
    /// against a recorder that finishes a transfer in zero wall-clock seconds, so every Pocket
    /// scenario in this repository could be green while no file over ~19 KB could ever come off
    /// a real recorder.
    ///
    /// `gapsSeconds` is the silence BEFORE each chunk after the first, `lengths` is how the
    /// content is cut up on the wire (the real device does not use a fixed size — 244 with
    /// occasional 192 and a short tail), and `terminatorAfterSeconds` is when `MCU&OFF` lands
    /// on the CONTROL characteristic after the last audio notification.
    ///
    /// The values every scenario uses are replayed from
    /// `fixtures/pocket/pocket-fw16-ble-download-trace.json`, not invented here.
    struct DownloadWireTiming: Sendable {
        /// Silence before chunk *n+1*. Shorter than the chunk count means the remaining
        /// chunks follow the last stated gap.
        let gapsSeconds: [TimeInterval]
        /// Wire chunk sizes, in order. `nil` falls back to the fixed `notificationBytes` cut.
        let lengths: [Int]?
        /// When `MCU&OFF` arrives after the final chunk. `nil` is a firmware that says nothing.
        let terminatorAfterSeconds: TimeInterval?
        /// THE RECORDER LEAVES MID-TRANSFER after this many chunks: the link drops (a real
        /// `didDisconnect`, not silence) and THE DEVICE STAYS AWAY — every later connect is
        /// refused, which is what out-of-range looks like to a central that can still see
        /// the address. `nil` is a recorder that stays.
        let dropLinkAfterChunks: Int?

        init(gapsSeconds: [TimeInterval], lengths: [Int]? = nil,
             terminatorAfterSeconds: TimeInterval? = nil,
             dropLinkAfterChunks: Int? = nil) {
            self.gapsSeconds = gapsSeconds
            self.lengths = lengths
            self.terminatorAfterSeconds = terminatorAfterSeconds
            self.dropLinkAfterChunks = dropLinkAfterChunks
        }

        /// The frame observed three times out of three on fw 1.6, immediately after the last
        /// audio chunk of a COMPLETE transfer.
        static let terminatorFrame = "MCU&OFF"

        func gap(before index: Int) -> TimeInterval {
            guard index > 0, !gapsSeconds.isEmpty else { return 0 }
            return gapsSeconds[min(index - 1, gapsSeconds.count - 1)]
        }

        func width(at index: Int, fallback: Int) -> Int {
            guard let lengths, !lengths.isEmpty else { return fallback }
            return lengths[min(index, lengths.count - 1)]
        }
    }

    let deviceId: UUID
    let deviceName: String
    /// `nil` keeps the old zero-time behaviour, so every scenario written before there was a
    /// clock is unchanged.
    private let downloadTiming: DownloadWireTiming?
    private let behaviour: KeyBehaviour
    /// The key this recorder is holding right now, which the WiFi read-back is derived from.
    /// It changes only when the firmware genuinely takes a new one.
    private var heldKey: String?
    /// Whether this firmware answers `APP&WIFI` at all. A firmware that does not is
    /// `MCU&UNKNOWN` — an honest "not proven", which is a different answer from a refusal.
    private let answersWiFiReadback: Bool
    /// What this recorder is holding, in the order its firmware lists it.
    ///
    /// MUTABLE, BECAUSE A REMOVAL IS THE ONE COMMAND THAT CHANGES IT. Before `APP&D&…` had a
    /// caller this could be a `let`: nothing this app composed could alter what the recorder
    /// held. A removal that did not actually change the fixture's shelf would make the
    /// re-read confirmation vacuous — it would agree with a recorder that removed nothing.
    /// Guarded by the same `lock` as `heldKey`.
    private var inventory: [ScriptedRecording]

    /// WHAT THIS FIRMWARE DOES WHEN IT IS ASKED TO REMOVE A RECORDING.
    ///
    /// Three behaviours because real firmware families have all three, and the middle one is
    /// the reason success is never taken from the acknowledgement.
    enum RemovalBehaviour: Sendable {
        /// fw 1.6, as measured on `PKT01_BLUE_26079bc5` 2026-08-16: it DISCRIMINATES. A file it
        /// holds is removed and acknowledged; a file that cannot exist answers `MCU&D&ERR`.
        case removesWhatItHolds
        /// It says yes to everything and removes nothing. The shape that makes a client which
        /// trusts the acknowledgement tell a person their recording is gone when it is not.
        case saysYesAndRemovesNothing
        /// It refuses everything.
        case refusesEverything
    }
    private let removalBehaviour: RemovalBehaviour

    /// What this recorder is holding RIGHT NOW, read under the lock. A scenario asserting that
    /// a removal actually happened reads this, so the assertion is about the fixture's own
    /// shelf rather than about what the client believes.
    var shelf: [ScriptedRecording] { lock.withLock { inventory } }
    /// Whether this firmware answers `LIST_DIRS` / `LIST&` at all. `false` is the honest
    /// "this build's command is not one I know" — `MCU&UNKNOWN` — which is a different answer
    /// from a recorder that lists nothing.
    private let answersInventory: Bool

    /// WHAT `APP&SPACE` ANSWERS, in the recorder's own kilobytes.
    ///
    /// The capacity is the one a real Pocket on fw 1.6 reported in the PacketLogger decode
    /// this protocol client was built from, and it is the same number
    /// `PocketBLEProtocolClientTests` pins. The used figure is a scenario choice and nothing
    /// else — it is stated here rather than spread across step definitions so that a scenario
    /// asserting "47.9 MB free of 59.6 MB" is asserting arithmetic over a measured capacity,
    /// not over a plausible-looking 8 GB somebody typed.
    static let capacityKilobytes = 61_032
    static let usedKilobytes = 12_000
    /// WHAT IT IS HOLDING RIGHT NOW, IN ITS OWN KILOBYTES — `Self.usedKilobytes` at rest, less
    /// whatever has actually left this recorder since.
    ///
    /// A FIXED ANSWER MADE ONE SCENARIO UNWRITABLE. `APP&SPACE` used to answer the static
    /// figure whatever the shelf held, so "removing a recording changes the free-space figure
    /// on the page" could only ever assert that an unchanged number was still unchanged —
    /// vacuously true whether or not anything re-read it. A recorder that deletes a file frees
    /// room; this one does too, and only on the branch that genuinely removes something.
    /// Every scenario that removes nothing sees exactly the number it always saw.
    private var usedKilobytesNow = FakePocketBLEStack.usedKilobytes
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

    /// THE ACCESS POINT'S OWN STATE, AS THE LEGEND IN `PROTOCOL.md:139-143` DEFINES IT:
    /// `0` closed / initialising, `3` AP created and waiting for a client, `2` client
    /// connecting, `1` ready for file transfer. The ONLY way to get from 3 to 1 is
    /// `clientJoinedTheAccessPoint()` — because on the real device the only way is a client
    /// joining, and a fixture that walked to 1 on its own would let a client that never joined
    /// look exactly like one that did.
    private var wifiStatus = 0
    private var wifiSelectedFile: String?
    private var wifiClosed = 0
    private var wifiStatusIsReadyForSelection: Bool {
        lock.lock(); defer { lock.unlock() }; return wifiStatus == 1
    }

    /// A PHONE JOINED THE RECORDER'S NETWORK. Real hardware moves 3 -> 2 -> 1 on its own once
    /// this happens; this fixture goes straight to 1 because nothing in the client distinguishes
    /// 2 from "still waiting", and a scripted intermediate would be invented behaviour.
    func clientJoinedTheAccessPoint() {
        lock.lock(); if wifiStatus == 3 { wifiStatus = 1 }; lock.unlock()
    }

    /// What the recorder's radio is doing, so a scenario can assert the AP was TORN DOWN rather
    /// than left up on somebody's desk.
    var accessPointStatus: Int { lock.lock(); defer { lock.unlock() }; return wifiStatus }
    var accessPointCloseCount: Int { lock.lock(); defer { lock.unlock() }; return wifiClosed }

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
         removalBehaviour: RemovalBehaviour = .removesWhatItHolds,
         downloadTiming: DownloadWireTiming? = nil,
         behaviour: KeyBehaviour? = nil) {
        self.downloadTiming = downloadTiming
        self.inventory = inventory
        self.answersInventory = answersInventory
        self.removalBehaviour = removalBehaviour
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
        case .silentToWrongKey(let key):      self.heldKey = key
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
    fileprivate func holdConfirmation(_ fire: @escaping () -> Void) {
        lock.lock(); pendingNotifyConfirmations.append(fire); lock.unlock()
    }

    fileprivate func deliver(_ body: @escaping (BLEEventSink) -> Void) {
        deliver(after: 0, body)
    }

    /// THE SAME DELIVERY, PUT ON THE CLOCK. A real radio hands notifications up milliseconds
    /// apart; the difference between that and a synchronous burst is the whole of the defect
    /// this fake previously could not express.
    ///
    /// AND PUT ON THE LINK. A transfer's notifications are scheduled the moment the command
    /// arrives, but a real peripheral that disconnects mid-transfer SENDS NOTHING MORE — so a
    /// delivery scheduled on a link that has since dropped is discarded, not delivered. Without
    /// this, a stopped first transfer's remaining chunks arrived interleaved into the NEXT
    /// session's download on the same characteristic — a radio physically incapable of that.
    fileprivate func deliver(after delay: TimeInterval, _ body: @escaping (BLEEventSink) -> Void) {
        lock.lock()
        let queue = self.queue
        let sink = self.sink
        let epoch = linkEpoch
        lock.unlock()
        guard let queue, let sink else { return }
        let gated: (BLEEventSink) -> Void = { [weak self] handed in
            guard let self else { return }
            self.lock.lock()
            let stillSameLink = self.linkEpoch == epoch
            self.lock.unlock()
            guard stillSameLink else { return }
            body(handed)
        }
        // WHAT THE RECORDER SAID AND SOMEBODY HEARD. The sink is held WEAKLY, so this is a
        // true measurement rather than a bookkeeping flag: an event counted here was handed
        // to an object that was still alive to receive it, and an event this counter does not
        // move is one that reached nobody. It is the only way "the app stopped listening when
        // I left the page" is a checkable claim instead of a reassurance.
        lock.lock(); handedToTransport += 1; lock.unlock()
        if delay <= 0 {
            queue.async { gated(sink) }
        } else {
            queue.asyncAfter(deadline: .now() + delay) { gated(sink) }
        }
    }

    private var handedToTransport = 0

    /// WHICH LINK a scheduled delivery belongs to. Bumped when a live connection drops, so
    /// notifications staged for a link that no longer exists die with it — see `deliver`.
    private var linkEpoch = 0

    /// How many radio events this recorder has handed to a LIVE transport.
    var notificationsHandedToTransport: Int {
        lock.lock(); defer { lock.unlock() }; return handedToTransport
    }

    /// Whether anything in the app is still bound as this radio's delegate. `false` is the
    /// strong form of "nobody is listening": the sink reference is weak, so this goes false
    /// when the last owner of the transport is released, not when a flag is set.
    var transportIsListening: Bool {
        lock.lock(); defer { lock.unlock() }; return sink != nil
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
        // The link is gone, and everything scheduled on it goes with it. The disconnect
        // event itself is delivered below under the NEW epoch — a radio does report the
        // drop; what it cannot do is keep notifying afterwards.
        if wasConnected { linkEpoch += 1 }
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
    /// THE ORDERING THE RECORDER DEPENDS ON.
    ///
    /// `APP&SK&<key>` is answered over a NOTIFICATION on the metadata characteristic
    /// (pocket-libre PROTOCOL.md: 001120A3, Write+Notify). A command written before
    /// CoreBluetooth has confirmed the subscription has nowhere to be answered — the
    /// recorder never sends, and the app waits forever on a link that is plainly up.
    /// Recorded here so a scenario can assert it instead of hoping.
    private(set) var notifyConfirmed = false
    private(set) var commandWrittenBeforeNotifyConfirmed: String?
    /// Widen the window so the race is deterministic under test rather than incidental.
    var holdNotifyConfirmation = false
    private var pendingNotifyConfirmations: [() -> Void] = []

    /// Release a held confirmation, as the radio eventually would.
    func confirmNotifications() {
        lock.lock()
        let pending = pendingNotifyConfirmations
        pendingNotifyConfirmations = []
        holdNotifyConfirmation = false
        lock.unlock()
        for p in pending { p() }
    }

    /// THE WRITE MODE THE RECORDER ANSWERS. pocket-libre writes commands with
    /// `response=False`; this app wrote `.withResponse` and every command went
    /// unanswered against real hardware. Recorded so a scenario can hold the mode
    /// rather than rediscovering it on a device.
    private(set) var commandWriteTypes: [CBCharacteristicWriteType] = []

    fileprivate func noteWriteType(_ type: CBCharacteristicWriteType,
                                   to characteristic: FakePocketBLECharacteristic) {
        guard characteristic.uuid == Self.characteristicUUID(map.command) else { return }
        lock.lock(); commandWriteTypes.append(type); lock.unlock()
    }

    fileprivate func noteNotifyConfirmed() {
        lock.lock(); notifyConfirmed = true; lock.unlock()
    }

    fileprivate func handleWrite(_ data: Data, to characteristic: FakePocketBLECharacteristic) {
        if characteristic.uuid == Self.characteristicUUID(map.command) {
            lock.lock()
            if !notifyConfirmed, commandWrittenBeforeNotifyConfirmed == nil {
                commandWrittenBeforeNotifyConfirmed =
                    String(data: data, encoding: .ascii) ?? "<non-ascii>"
            }
            lock.unlock()
        }
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
        } else if command == "SPACE" {
            // `MCU&SPA&<used_kb>&<total_kb>`, and the CAPACITY IS THE REFERENCE TRACE'S OWN:
            // 61032 KB is the number a real Pocket on fw 1.6 reported in the decode this
            // client was built from (`PocketBLEProtocolClientTests` pins the same value).
            // Inventing a plausible 8 GB here would make every scenario about free space an
            // assertion over a number nobody measured.
            lock.lock()
            let used = usedKilobytesNow
            lock.unlock()
            response = "MCU&SPA&\(used)&\(Self.capacityKilobytes)"
        } else if command.hasPrefix("D&") {
            // THE REMOVAL, AS THE ONE DEVICE ANYBODY HAS MEASURED ANSWERS IT.
            //
            // `APP&D&1970-01-01&19700101000000` — a file that cannot exist — answered
            // `MCU&D&ERR` on `PKT01_BLUE_26079bc5` (fw 1.6) on 2026-08-16, and the recorder
            // still held 19 recordings before AND after. So this firmware DISCRIMINATES, and
            // the fixture discriminates the same way. `MCU&D&ERR` shares a prefix with
            // `MCU&DIRS&…`, `MCU&DIRS_SUM&…` and the success acknowledgement, which is exactly
            // why this fake emits all four in one suite.
            let parts = command.dropFirst("D&".count)
                .split(separator: "&", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else {
                notifyControl("MCU&UNKNOWN")
                return
            }
            switch removalBehaviour {
            case .refusesEverything:
                response = "MCU&D&ERR"
            case .saysYesAndRemovesNothing:
                response = "MCU&D"
            case .removesWhatItHolds:
                lock.lock()
                let index = inventory.firstIndex {
                    $0.date == parts[0] && $0.timestamp == parts[1]
                }
                if let index {
                    // THE ROOM COMES BACK, and it comes back by the size of the file that
                    // left — never a round number. A scenario about free space changing has to
                    // be about arithmetic over the recorder's own figures, or it is about a
                    // constant somebody typed.
                    let freed = max(1, inventory[index].sizeBytes / 1024)
                    usedKilobytesNow = max(0, usedKilobytesNow - freed)
                    inventory.remove(at: index)
                }
                lock.unlock()
                response = index == nil ? "MCU&D&ERR" : "MCU&D"
            }
        } else if command == "LIST_DIRS", answersInventory {
            // THE DAYS, THEN THE COUNT — the reference trace's own two-frame shape. The count
            // frame is what makes an interrupted sequence detectable, so it is emitted here
            // rather than assumed by the reader.
            var days: [String] = []
            for recording in shelf where !days.contains(recording.date) {
                days.append(recording.date)
            }
            for day in days { notifyControl("MCU&DIRS&\(day)") }
            notifyControl("MCU&DIRS_SUM&\(days.count)")
            return
        } else if command.hasPrefix("LIST&"), answersInventory {
            let day = String(command.dropFirst("LIST&".count))
            let files = shelf.filter { $0.date == day }
            for file in files {
                notifyControl("MCU&F&\(file.date)&\(file.timestamp)&\(file.sizeKilobytes)")
            }
            notifyControl("MCU&LIST&\(files.count)")
            return
        } else if command == "U&WIFI" {
            // THE SAME WIRE FORM MEANS TWO THINGS, AND THE REFERENCE TRACE IS WHY.
            // `PROTOCOL.md:97-131` sends `APP&U&WIFI` TWICE: once at step 1 to put the radio
            // into WiFi mode (answered with a STATUS frame) and once at step 6, after a file
            // has been selected, to start the transfer (answered `MCU&U&WIFI`). A fixture that
            // answered the same thing both times would make the ordering this suite is about
            // unrepresentable.
            lock.lock()
            let selected = wifiSelectedFile != nil
            if !selected { wifiStatus = 0 }
            let status = wifiStatus
            lock.unlock()
            response = selected ? "MCU&U&WIFI" : "MCU&WIFIS&\(status)"
        } else if command == "WIFIO" {
            // THE ACCESS POINT COMES UP AND WAITS FOR SOMEBODY. Measured on real hardware:
            // `APP&WIFIO` -> `MCU&WIFIO`, and `APP&WIFIS` then answers `3` — "open, with no
            // client" — and STAYS there until a client actually joins.
            lock.lock(); wifiStatus = 3; lock.unlock()
            response = "MCU&WIFIO"
        } else if command == "WIFIS" {
            lock.lock(); let status = wifiStatus; lock.unlock()
            response = "MCU&WIFIS&\(status)"
        } else if command == "WIFIC" {
            // VERIFIED ON HARDWARE: status returns to 0 and the AP is gone.
            lock.lock(); wifiStatus = 0; wifiSelectedFile = nil; wifiClosed += 1; lock.unlock()
            response = "MCU&WIFIC"
        } else if command.hasPrefix("U&"), answersInventory,
                  command.dropFirst("U&".count).contains("&"),
                  wifiStatusIsReadyForSelection {
            // STEP 5 OF THE WIFI SEQUENCE: the same select frame as the BLE pull, but the bytes
            // are then served over HTTP rather than on the audio characteristic.
            let parts = command.dropFirst("U&".count)
                .split(separator: "&", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let file = inventory.first(where: {
                      $0.date == parts[0] && $0.timestamp == parts[1]
                  }) else {
                notifyControl("MCU&UNKNOWN")
                return
            }
            lock.lock(); wifiSelectedFile = command; lock.unlock()
            response = "MCU&U&\(file.announcedSizeBytes ?? file.sizeBytes)"
        } else if command.hasPrefix("U&"), answersInventory {
            // THE PULL, AS THE FIRMWARE SERIALISES IT: one control frame announcing the size,
            // then the file itself on the AUDIO characteristic. The chunking is deliberate —
            // a fixture that answered in one notification would leave the client's
            // multi-notification assembly, the half this protocol actually fails in, unproven.
            let parts = command.dropFirst("U&".count)
                .split(separator: "&", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let file = shelf.first(where: {
                      $0.date == parts[0] && $0.timestamp == parts[1]
                  }),
                  let content = file.content else {
                notifyControl("MCU&UNKNOWN")
                return
            }
            notifyControl("MCU&U&\(file.announcedSizeBytes ?? file.sizeBytes)")
            let timing = downloadTiming
            var offset = content.startIndex
            var index = 0
            var elapsed: TimeInterval = 0
            while offset < content.endIndex {
                if let dropAfter = timing?.dropLinkAfterChunks, index >= dropAfter {
                    // THE DEVICE LEAVES. No more audio, no terminator, and a real
                    // `didDisconnect` a beat after the last chunk it did send — then the
                    // recorder stays out of reach: reconnects are refused, exactly the
                    // situation the presence backoff exists for.
                    lock.lock()
                    let queue = self.queue
                    lock.unlock()
                    queue?.asyncAfter(deadline: .now() + elapsed + 0.005) { [weak self] in
                        guard let self else { return }
                        self.lock.lock()
                        self.storedReachability.refusesToConnect = true
                        self.lock.unlock()
                        self.cancelConnection()
                    }
                    return
                }
                let width = timing?.width(at: index, fallback: Self.notificationBytes)
                    ?? Self.notificationBytes
                let end = content.index(offset, offsetBy: max(1, width),
                                        limitedBy: content.endIndex) ?? content.endIndex
                elapsed += timing?.gap(before: index) ?? 0
                notifyAudio(content.subdata(in: offset..<end), after: elapsed)
                offset = end
                index += 1
            }
            // AND THEN THE TERMINATOR, OR NOTHING.
            //
            // `MCU&OFF` on the CONTROL characteristic, 0.086-11.078 ms after the last audio
            // chunk, three observations out of three on fw 1.6. It arrives AFTER the announced
            // byte count is satisfied — i.e. after the client's own transfer loop has already
            // stopped consuming — so it is left queued for whatever reads the control channel
            // NEXT. That is a frame the shipped client used to hand to the next command as its
            // answer, and the fake could not say it at all.
            //
            // A recorder whose `content` is shorter than what it announced says nothing at all,
            // which is exactly what a transfer that died partway looks like from the phone: no
            // error frame, just silence.
            if let terminator = timing?.terminatorAfterSeconds {
                notifyControl(DownloadWireTiming.terminatorFrame, after: elapsed + terminator)
            }
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
    ///
    /// `nil` IS A LEGAL ANSWER AND IT MEANS SILENCE. It used to return `String`, so every
    /// modelled recorder was obliged to say SOMETHING back — which quietly made "the firmware
    /// answers a wrong key with nothing at all" unrepresentable in this suite, and that is the
    /// exact behaviour the reported deadlock was made of.
    private func answerToKeyWrite(_ offered: String) -> String? {
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
        case .silentToWrongKey(let key):
            // The write LANDED — `writtenCommands` records it above, so "Solleva sent it one
            // key" stays checkable — and the recorder simply never speaks again about it.
            return offered == key ? "MCU&SK&OK" : nil
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

    private func notifyAudio(_ bytes: Data, after delay: TimeInterval = 0) {
        guard let audio = peripheral
            .discoveredCharacteristic(Self.characteristicUUID(map.audio)) else { return }
        deliver(after: delay) { [weak self] sink in
            guard let self else { return }
            audio.value = bytes
            sink.blePeripheral(self.peripheral, didUpdateValueFor: audio, error: nil)
        }
    }

    private func notifyControl(_ text: String, after delay: TimeInterval = 0) {
        guard let control = peripheral
            .discoveredCharacteristic(Self.characteristicUUID(map.control)) else { return }
        deliver(after: delay) { [weak self] sink in
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

    /// NOTIFICATIONS THAT ARRIVED BEFORE THE DELEGATE DID — the window AC13 exists to close.
    ///
    /// Production installs the real peripheral delegate ONLY in `routeEventsToSink()`
    /// (`BluetoothSeam.swift:327`), so anything a peripheral sends before that reaches no
    /// application code. This fake used to deliver it anyway: `deliver` sends to the
    /// factory-installed sink whenever one exists and never consulted the flag above, which
    /// `routeEventsToSink()` merely SET and nothing read. A scenario claiming to exercise
    /// "a chunk arrived before we were listening" was therefore exercising nothing.
    ///
    /// Staged here instead, so a test can assert BOTH halves: that nothing reached the app while
    /// unbound, and that a restoration coordinator which installs its delegate without first
    /// establishing a generation gate then receives them in a rush.
    private var stagedBeforeBinding: [(BLEEventSink) -> Void] = []

    /// How many deliveries this peripheral refused because no delegate was installed yet.
    private(set) var suppressedBeforeBinding = 0

    /// THE GATE. Every `sink.blePeripheral(…)` delivery goes through here, because a peripheral
    /// callback in CoreBluetooth reaches `CBPeripheralDelegate` and nothing else — a central
    /// callback is a different delegate and is deliberately NOT gated on this.
    fileprivate func deliverToDelegate(_ body: @escaping (BLEEventSink) -> Void) {
        lock.lock()
        let bound = boundToSink
        if !bound {
            stagedBeforeBinding.append(body)
            suppressedBeforeBinding += 1
        }
        lock.unlock()
        guard bound else { return }
        stack.deliver { sink in body(sink) }
    }

    /// Hand the app everything that arrived before it was listening. A restoration coordinator
    /// that installs its delegate before it is ready to reject stale work gets this in one go —
    /// which is the harm AC13's generation gate has to survive.
    func flushStagedNotifications() {
        lock.lock()
        let staged = stagedBeforeBinding
        stagedBeforeBinding = []
        lock.unlock()
        for body in staged { stack.deliver { sink in body(sink) } }
    }

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
        deliverToDelegate { [weak self] sink in
            guard let self else { return }
            sink.blePeripheral(self, didDiscoverServices: nil)
        }
    }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: BLEService) {
        guard let service = service as? FakePocketBLEService else {
            fatalError("the fake Pocket peripheral was handed a \(type(of: service))")
        }
        service.discover(characteristicUUIDs)
        deliverToDelegate { [weak self] sink in
            guard let self else { return }
            sink.blePeripheral(self, didDiscoverCharacteristicsFor: service, error: nil)
        }
    }

    func readValue(for characteristic: BLECharacteristic) {
        deliverToDelegate { [weak self] sink in
            guard let self else { return }
            sink.blePeripheral(self, didUpdateValueFor: characteristic, error: nil)
        }
    }

    func writeValue(_ data: Data, for characteristic: BLECharacteristic,
                    type: CBCharacteristicWriteType) {
        guard let characteristic = characteristic as? FakePocketBLECharacteristic else { return }
        stack.noteWriteType(type, to: characteristic)
        stack.handleWrite(data, to: characteristic)
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: BLECharacteristic) {
        (characteristic as? FakePocketBLECharacteristic)?.isNotifying = enabled
        let fire = { [weak self] in
            guard let self else { return }
            self.stack.noteNotifyConfirmed()
            self.stack.deliver { sink in
                sink.blePeripheral(self, didUpdateNotificationStateFor: characteristic, error: nil)
            }
        }
        // Held, a scenario can prove the product WAITS. Released immediately, every
        // other scenario behaves exactly as before.
        if stack.holdNotifyConfirmation { stack.holdConfirmation(fire) } else { fire() }
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
