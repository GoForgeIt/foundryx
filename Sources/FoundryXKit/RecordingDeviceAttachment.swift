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
// CUSTODY, AND WHERE THE MINT ACTUALLY LIVES NOW. Attaching a stored-file recorder requires a
// 16-byte session secret. FoundryX RESTORES one it already holds through
// `PocketOnboardingCoordinator.restore`, and — only from the owner's explicit confirmation on
// the consent screen, which is the only thing that can construct a `PocketMintConsent` — it
// MINTS one through `coordinator.mintFactoryFresh` below. A plain tap passes `mint: nil` and a
// recorder FoundryX holds no key for comes back `.setupUnavailable`, the shipped §3.6 answer,
// which says out loud that nothing was written.
//
// (THIS PARAGRAPH USED TO SAY THE OPPOSITE — that "nothing anywhere in this app calls
// `provisionFactoryFresh`" and that "EVERY tap on a stored-file device lands on
// `.setupUnavailable`". Both were true when they were written and neither has been true since
// the consent screen shipped: `App/DeviceScreen.swift`'s `confirmMintAfterOwnerConsent()`
// calls `attach(…, mint:)`, which reaches the mint below. A comment that is a post-mortem of a
// gap already closed reads, to the next person, as current status.)
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
    /// It speaks the stored-file protocol and FoundryX holds no key for it.
    ///
    /// A TAP ALONE NEVER MINTS. Reaching this state writes NOTHING to the recorder beyond the
    /// stored-key handshake FoundryX had no key for, which is to say nothing at all — and it
    /// is what a tap without an owner's explicit confirmation must always produce, because a
    /// second `APP&SK&` write against a recorder that already holds a key may silently re-key
    /// it (proposal §6b, U1 — never observed on hardware). The consent screen is what comes
    /// next, and the mint only runs when the owner has said yes to it.
    case setupUnavailable
    /// THE RECORDER REFUSED THE NEW KEY. Another app owns it; nothing was changed.
    case mintRefused
    /// THE RECORDER ACKNOWLEDGED THE NEW KEY AND COULD NOT PROVE IT KEPT IT. The key is in
    /// custody — the recorder may well be holding it — and setup is NOT reported complete.
    case mintNotVerified
    /// THE RECORDER TOOK THE KEY AND THIS iPHONE COULD NOT STORE IT (design §3.7). The one
    /// state in the app where closing the app loses something irreversibly.
    ///
    /// UNREACHABLE FROM THE SHIPPED MINT, ON PURPOSE. Custody now runs BEFORE the `APP&SK&`
    /// write, so a key this iPhone cannot store is never offered to a recorder — that is
    /// `.keyNotKept` below, and nothing is written. This case and its retry are kept working as
    /// the backstop for that ordering, not as a state the flow can still produce.
    case keyAcceptedNotDurable
    /// THIS iPHONE'S SECURE STORAGE REFUSED THE KEY, SO THE RECORDER WAS NEVER ASKED. Nothing
    /// was written, and the recorder is holding whatever it was holding before.
    case keyNotKept
    /// CUSTODY THREW ON THE WAY IN. FoundryX may hold this recorder's key and could not read
    /// it — a locked Keychain, an unrecognised status, an item this build cannot decode. It is
    /// NOT "FoundryX holds no key", and it must never be routed to the mint offer: that would
    /// send a second key to a recorder FoundryX itself provisioned.
    case custodyUnreadable
    /// FoundryX held a key and the recorder refused it.
    case recoveryRequired
    /// The protocol leg succeeded and the ACCOUNT STORE could not keep the result — a lost
    /// user decision, so it is a case of its own rather than a silent success.
    case adoptionNotPersisted(String)
    /// It exposes the live audio service. The caller runs the shipped pairing path.
    case live
    /// It connected and spoke nothing this build knows.
    case unrecognised
    /// It never got far enough to establish anything, AND WHICH STEP IT STOPPED AT.
    ///
    /// The payload used to be a free-text `String` that the presentation discarded, so eleven
    /// distinct failures — a radio that was off, a peripheral this iPhone could not look up, a
    /// connect that timed out, a service discovery that stalled, a link that dropped — all
    /// rendered one sentence, and that sentence blamed distance. It is a value now because a
    /// caller that cannot tell those apart cannot say anything true about any of them.
    case unreachable(RecordingDeviceUnreachableReason)
}

/// WHERE A TAP STOPPED. One case per distinguishable failure in `RecordingDeviceAttachment`,
/// and the reason `.unreachable` is worth carrying at all.
///
/// WHY THIS IS AN ENUM AND NOT THE OLD STRING. A recorder lying against the back of the phone
/// that times out during SERVICE DISCOVERY is a completely different problem from one that
/// never connected, and from one this iPhone could not look up at all. Telling them apart is
/// what makes the next attempt informative instead of another dead end — for the person
/// holding the phone, and for whoever reads the log afterwards.
///
/// NOTHING HERE CLAIMS DISTANCE. `UnifiedDeviceListPresentation.bannedProximityWords` already
/// holds that a row may not say "in range", because this phone cannot distinguish out-of-range
/// from powered-off from connected-to-another-app. The connect sheet was saying exactly that
/// and worse — "bring it closer" — for every one of these.
/// WHERE A TAP CURRENTLY IS — the progress twin of `RecordingDeviceUnreachableReason`,
/// which says where a tap STOPPED. Every phase here names the step whose failure is a
/// reason there, so the line a row shows while it waits and the line it shows when it
/// gives up are drawn from one vocabulary rather than two that drift apart.
///
/// The row used to show a single static "Connecting…" for the whole sequence — radio,
/// lookup, connect, service discovery, characteristic discovery, protocol, key. Against
/// a Pocket that sequence is slow enough for the owner to reasonably conclude the tap
/// did nothing, which is the report that prompted this ("this step took a while, could
/// we give some more indication"). The phases are not decoration: an owner who can see
/// it reached `providingKey` knows the recorder answered, and one stuck at
/// `findingDevice` knows it never did.
public enum RecordingDeviceAttachPhase: String, Equatable, Sendable, CaseIterable {
    /// Waiting for the radio to report powered-on. Fails as `.bluetoothOff` /
    /// `.bluetoothNeverReported`.
    case wakingRadio
    /// Looking the peripheral up, and rescanning if this central has never seen it.
    /// Fails as `.deviceNotFound`.
    case findingDevice
    /// `connect` issued, waiting for the link. Fails as `.connectTimedOut` /
    /// `.connectRefused`.
    case connecting
    /// Listing services. Fails as `.serviceDiscoveryFailed` / `.serviceDiscoveryTimedOut`.
    case readingServices
    /// Listing characteristics. Fails as `.characteristicDiscoveryTimedOut`.
    case readingCharacteristics
    /// Negotiating the stored-file protocol. Fails as `.protocolNegotiationFailed`.
    case negotiatingProtocol
    /// Presenting the session key. Fails as `.handshakeUnanswered`.
    case providingKey

    /// What the row says. Present tense and about the RECORDER, not about Bluetooth
    /// internals — an owner watching this wants to know how far their device got, not
    /// which CoreBluetooth callback is outstanding.
    public var line: String {
        switch self {
        case .wakingRadio:            return "Waking up Bluetooth…"
        case .findingDevice:          return "Finding your recorder…"
        case .connecting:             return "Connecting…"
        case .readingServices:        return "Asking what it offers…"
        case .readingCharacteristics: return "Reading what it offers…"
        case .negotiatingProtocol:    return "Opening its recordings…"
        case .providingKey:           return "Unlocking with your key…"
        }
    }
}

public enum RecordingDeviceUnreachableReason: String, Equatable, Sendable, CaseIterable {
    /// The radio reported a state other than powered-on.
    case bluetoothOff
    /// The radio never reported ANY state inside the power-on deadline.
    case bluetoothNeverReported
    /// `retrievePeripherals(withIdentifiers:)` came up empty AND a fresh scan did not turn the
    /// device up either.
    ///
    /// A HYPOTHESIS ABOUT THE REPORTED DEFECT, NOT A DIAGNOSIS OF IT. The peripheral handle
    /// the pairing scan surfaced lives on `DeviceManager`'s central, and a brand-new central
    /// is not guaranteed to be able to look it up — which would have produced the old generic
    /// sentence with no way to tell it from four other causes. Nobody has yet seen a failing
    /// tap with this build's reporting in it, so whether Nick's Pocket landed here is unknown.
    /// That is what the reason is for: the NEXT one says.
    case deviceNotFound
    /// `connect` was issued and neither `didConnect` nor `didFailToConnect` ever came back.
    case connectTimedOut
    /// The radio answered `didFailToConnect` — a refusal, not a silence.
    case connectRefused
    /// The link came up and went away again before the graph was read — a mid-setup drop.
    case linkDroppedDuringSetup
    /// Connected, and service discovery came back with an error.
    case serviceDiscoveryFailed
    /// Connected, and service discovery never came back at all.
    case serviceDiscoveryTimedOut
    /// Services listed, and characteristic discovery never finished.
    case characteristicDiscoveryTimedOut
    /// The graph carried a stored-file map and the characteristics were gone by the time the
    /// transport asked for them.
    case protocolCharacteristicsVanished
    /// The transport was built and `PocketBLEClient.connect` could not negotiate over it.
    case protocolNegotiationFailed
    /// The peripheral identifier this iPhone holds cannot make a durable identity.
    case noDurableIdentity
    /// `setNotifyValue` was issued for the control characteristic and CoreBluetooth never
    /// confirmed it, so nothing could have answered a command written afterwards.
    case notificationsNeverEnabled
    /// The key handshake was issued and the recorder stopped answering part-way through.
    case handshakeUnanswered
    /// SOMETHING ELSE, SAID AS SOMETHING ELSE. The honest bucket — an error no branch above
    /// produced. It exists so an unmapped failure reads as "we don't know" rather than being
    /// rounded into whichever neighbouring cause has the friendliest sentence.
    case unexplained

    /// The short technical form, for the log and for `.linkFailed` payloads. It is NOT what
    /// the person sees; `RecordingDeviceAttachPresentation.line(for:)` is.
    public var diagnostic: String {
        switch self {
        case .bluetoothOff:                     return "bluetooth is not powered on"
        case .bluetoothNeverReported:           return "the radio never reported its state"
        case .deviceNotFound:                   return "the peripheral could not be found"
        case .connectTimedOut:                  return "the connect attempt timed out"
        case .connectRefused:                   return "the connect attempt was refused"
        case .linkDroppedDuringSetup:           return "the link dropped during setup"
        case .serviceDiscoveryFailed:           return "service discovery failed"
        case .serviceDiscoveryTimedOut:         return "service discovery timed out"
        case .characteristicDiscoveryTimedOut:  return "characteristic discovery timed out"
        case .protocolCharacteristicsVanished:  return "the protocol characteristics went away"
        case .protocolNegotiationFailed:        return "protocol negotiation failed"
        case .noDurableIdentity:                return "no durable identity for this peripheral"
        case .notificationsNeverEnabled:        return "the recorder never confirmed it would send replies"
        case .handshakeUnanswered:              return "the key handshake went unanswered"
        case .unexplained:                      return "an unmapped failure"
        }
    }
}

/// What a scoped session produced — the body's value, or the single reason there was no
/// session to run it on.
///
/// IT IS NOT `Result`. A `Result<T, RecordingDeviceAttachOutcome>` would need the outcome to
/// be an `Error`, and it is not one: `.live` and `.setupUnavailable` are things that happened,
/// not failures, and the two most-likely call sites (`try?`, `get()`) would flatten exactly
/// the distinctions the enum exists to keep.
public enum RecordingDeviceSessionResult<Value: Sendable>: Sendable {
    case ran(Value)
    case unavailable(RecordingDeviceAttachOutcome)
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

    /// WHAT EACH WAY OF NOT GETTING THERE ACTUALLY SAYS.
    ///
    /// There used to be ONE line here — "FoundryX couldn't connect to that device. Bring it
    /// closer and try again." — and every `.unreachable` rendered it, because the reason the
    /// outcome carried was discarded on the way to the screen. It was reported against a Pocket
    /// lying on the back of the phone, which is the one situation in which that sentence is
    /// certainly false, and it was the whole of what the attempt produced.
    ///
    /// NO LINE HERE MENTIONS DISTANCE. Nothing in this app can measure it: an RSSI is not a
    /// diagnosis, and out-of-range, powered-off and connected-to-another-app are the same
    /// silence on this side of the radio. Each line names the step that failed and, where
    /// there is one, the thing the person can actually do about it.
    public static func line(for reason: RecordingDeviceUnreachableReason) -> String {
        switch reason {
        case .bluetoothOff:
            return "Bluetooth is off on this iPhone, so FoundryX couldn't reach that device. "
                + "Turn Bluetooth on and try again."
        case .bluetoothNeverReported:
            return "FoundryX couldn't start Bluetooth on this iPhone. Try again, and if it "
                + "keeps happening, restart FoundryX."
        case .deviceNotFound:
            return "FoundryX couldn't find that device again after you tapped it. It may have "
                + "stopped broadcasting — wake it up and tap it again."
        case .connectTimedOut:
            return "That device never answered. It may be asleep, or already connected to "
                + "another app or another phone."
        case .connectRefused:
            return "That device refused the connection. It's most likely already connected to "
                + "another app or another phone."
        case .linkDroppedDuringSetup:
            return "That device disconnected while FoundryX was setting it up. Tap it again."
        case .serviceDiscoveryFailed:
            return "FoundryX connected to that device, and it wouldn't say what it can do. "
                + "Tap it again."
        case .serviceDiscoveryTimedOut:
            return "FoundryX connected to that device and it never said what it can do. Turn "
                + "it off and on again, then tap it."
        case .characteristicDiscoveryTimedOut:
            return "FoundryX connected to that device and it stopped part-way through "
                + "describing itself. Turn it off and on again, then tap it."
        case .protocolCharacteristicsVanished:
            return "FoundryX connected to that device and lost the connection before it could "
                + "start. Tap it again."
        case .protocolNegotiationFailed:
            return "FoundryX connected to that device, and it didn't answer in a way this "
                + "version understands."
        case .noDurableIdentity:
            return "FoundryX can't give that device a stable identity on this iPhone, so it "
                + "can't save it to your account."
        case .notificationsNeverEnabled:
            // Said as the connection problem it is, not as anything about the key —
            // the key was never sent. The recorder accepted the link and then never
            // confirmed it would send replies, which on a real device means it went
            // out of range or to sleep between connecting and being asked.
            return "That device connected but stopped responding before FoundryX could "
                + "talk to it. Wake it up, keep it close, and try again."
        case .handshakeUnanswered:
            // IT USED TO END "Tap it again." — WHICH WAS THE WHOLE OF THE REMEDY, AND THE
            // REMEDY WAS A LOOP. Solleva sends the key custody already holds; this firmware
            // answers a key it does not hold with silence; so tapping again sent the same key
            // and got the same nothing, and the sentence said to keep doing it. On the connect
            // sheet this is now a whole screen (`PocketSetupPresentation.handshakeUnanswered`)
            // with a way to replace the key, and this line is what the recorder page — which
            // has no ceremony — says. It names what happened and stops there rather than
            // prescribing the one action that cannot work.
            return "That device didn't answer the key FoundryX has for it. FoundryX can't tell "
                + "whether the device was busy or the key no longer works."
        case .unexplained:
            return "FoundryX couldn't reach that device and couldn't tell why. Tap it again — "
                + "if it keeps happening, the details are in the app's log."
        }
    }

    /// The protocol leg worked and the ACCOUNT could not keep the result. A lost user
    /// decision is said out loud rather than shown as a device that silently never appears.
    public static let notRememberedLine =
        "FoundryX connected to that device but couldn't save it to your account. Try again."

    /// THE LINK CAME UP AND NOTHING ON THE OTHER END WAS UNDERSTOOD. A separate fact from
    /// `unreachableLine`: telling someone to bring a device closer when the app is already
    /// connected to it sends them to fix the one thing that is not broken. It offers no retry
    /// because a second tap cannot change what the device speaks.
    public static let unrecognisedLine =
        "FoundryX connected to that device, but it isn't one this version can record from."

    /// Every line this surface can render, so "it names no vendor", "none of them is empty"
    /// and "not one of them claims distance" are held over the POPULATION rather than over
    /// whichever string a test author remembered. `allCases` is what keeps a new reason from
    /// slipping in without a sentence.
    public static let everyLine: [String] =
        [connectingLine, notRememberedLine, unrecognisedLine]
        + RecordingDeviceUnreachableReason.allCases.map(line(for:))

    /// The inline line an outcome earns, or nil when the outcome is not an inline message —
    /// `.adopted` closes the sheet, `.live` hands the tap to the shipped pairing path, and
    /// `.setupUnavailable` / `.recoveryRequired` are whole screens.
    public static func inlineMessage(for outcome: RecordingDeviceAttachOutcome) -> String? {
        switch outcome {
        case .unreachable(let reason): return line(for: reason)
        case .adoptionNotPersisted: return notRememberedLine
        case .unrecognised:         return unrecognisedLine
        case .adopted, .setupUnavailable, .recoveryRequired, .live,
             .mintRefused, .mintNotVerified, .keyAcceptedNotDurable, .keyNotKept,
             .custodyUnreadable:
            // Each of these is a whole screen with its own copy, not a one-line aside. A mint
            // that was refused, unproven, or unstorable is exactly the kind of answer that
            // gets rounded off into "try again" if it is allowed to be a caption.
            return nil
        }
    }
}

public enum RecordingDeviceAttachError: Error, Equatable, Sendable, CustomStringConvertible {
    /// THE REASON TRAVELS WITH THE ERROR. It used to be reconstructed from a stage STRING at
    /// the top of `attach`, which is how "connecting" and "service discovery" ended up
    /// indistinguishable by the time anything rendered them.
    case unreachable(RecordingDeviceUnreachableReason)
    case unknownCharacteristic(String)

    public var description: String {
        switch self {
        case .unreachable(let reason):      return reason.diagnostic
        case .unknownCharacteristic(let t): return "no characteristic \(t)"
        }
    }

    /// Which reason a thrown error means, total by construction. An error from outside this
    /// type is `.unexplained` — said as unknown rather than rounded into a neighbour.
    public static func reason(of error: Error) -> RecordingDeviceUnreachableReason {
        switch error as? RecordingDeviceAttachError {
        case .unreachable(let reason):  return reason
        case .unknownCharacteristic:    return .protocolNegotiationFailed
        case nil:                       return .unexplained
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

    /// `APP&WIFI` on the authenticated session. Nothing here enables the radio or joins
    /// anything — it is a read, and it is the only evidence a mint can be believed on.
    func accessPointReadback() async throws -> PocketAccessPointReadback {
        try await client.accessPointCredentials()
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

    private enum Gate: Hashable { case poweredOn, rediscovered, connected, services, characteristics, notifying }

    private let bleQueue: DispatchQueue
    private let makeCentral: BLECentralFactory
    private let secrets: any PocketSecretStore
    /// The synchronised recovery copy (§10 custody). A mint writes BOTH records or it is not a
    /// mint this app is willing to report as complete.
    private let recovery: (any PocketKeyRecoveryStore)?
    private let deadlines: Deadlines
    private let log: DoorLog?

    /// Where the current attempt has got to, for whoever is showing a row. Set before each
    /// step rather than after, so the line names what is being WAITED ON — the step that a
    /// slow or hanging device leaves you sitting in is exactly the one worth naming.
    /// Deliberately not an `@Published`/Combine thing: this type is UI-framework-free and
    /// tested without one.
    private var onPhase: (@Sendable (RecordingDeviceAttachPhase) -> Void)?
    private func report(_ phase: RecordingDeviceAttachPhase) {
        let sink = lock.withLock { onPhase }
        log?.info("recording device: \(phase.rawValue)")
        sink?(phase)
    }

    /// Observe attach progress. Replaces any previous observer; cleared by `teardown()`.
    public func observePhases(_ sink: (@Sendable (RecordingDeviceAttachPhase) -> Void)?) {
        lock.withLock { onPhase = sink }
    }

    private let lock = NSLock()
    private var central: BLECentral?
    private var peripheral: BLEPeripheral?
    /// The peripheral a RESCAN is looking for. Non-nil only while `rediscover` is running, so
    /// an unrelated advertisement cannot satisfy the gate.
    private var wantedIdentifier: UUID?
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
    /// DESIGN §3.7's ONE PIECE OF STATE. The recorder took a key and custody would not keep
    /// it, so the only copy of that key in the world is this one — in memory, in this object.
    /// It is held so `retryPendingCustody()` has something to retry; a screen whose only
    /// action cannot be performed is the screen that loses somebody's recorder.
    ///
    /// It is not logged, not described, and not returned. It leaves this object only into the
    /// custody seam.
    private var pendingMint: (key: String, identity: PocketAuthenticatedIdentity,
                              advertisedName: String, id: UUID)?

    public init(makeCentral: @escaping BLECentralFactory = CoreBluetoothCentral.make,
                secrets: any PocketSecretStore = KeychainPocketSecretStore(),
                recovery: (any PocketKeyRecoveryStore)? = KeychainPocketKeyRecoveryStore(),
                deadlines: Deadlines = Deadlines(),
                queue: DispatchQueue? = nil,
                log: DoorLog? = .shared) {
        self.makeCentral = makeCentral
        self.secrets = secrets
        self.recovery = recovery
        self.deadlines = deadlines
        self.bleQueue = queue ?? DispatchQueue(label: "foundryx.recording-device-attach")
        self.log = log
    }

    // MARK: - The one entry point

    /// Attach the device the user tapped, and report what was actually established.
    ///
    /// `advertisedName` is DISPLAY metadata and nothing else. The durable address is the
    /// authenticated peripheral token — a device that renames itself is the same device. The
    /// one place the name is read for anything but display is the RECOVERY INDEX, which is
    /// never an identity: a recovery hit still has to be accepted by the recorder.
    ///
    /// - Parameter mint: `nil` — the default, and what a plain tap always passes — means NEVER
    ///   write a key. A non-nil value can only be constructed from an owner's explicit
    ///   confirmation (`PocketMintConsent`), which is the type-level half of "a mint is never
    ///   attempted without consent"; the other half is that this parameter defaults to `nil`,
    ///   so a new call site cannot mint by omission.
    public func attach(peripheralIdentifier id: UUID,
                       advertisedName: String,
                       mint: PocketMintConsent? = nil) async -> RecordingDeviceAttachOutcome {
        do {
            try await reachDiscoveredGraph(of: id)
        } catch {
            // THE ONE PLACE THE FAILURE BECOMES EVIDENCE. It is logged with the step it
            // stopped at as well as returned, so a repeat of the reported defect leaves
            // something behind to read even if nobody screenshots the sheet.
            let reason = RecordingDeviceAttachError.reason(of: error)
            log?.error("recording device: unreachable — \(reason.diagnostic)")
            teardown()
            return .unreachable(reason)
        }

        guard speaksStoredFileProtocol else {
            let sawAudio = lock.withLock { serviceUUIDs.contains(OmiUUID.audioService) }
            teardown()
            return sawAudio ? .live : .unrecognised
        }

        let outcome = await adoptStoredFileRecorder(id: id, advertisedName: advertisedName,
                                                    mint: mint)
        // EVERY ATTEMPT SAYS HOW IT ENDED. Only the early `reachDiscoveredGraph`
        // failure was logged, so an attach that got all the way to `providingKey`
        // and then failed left NOTHING behind — which is exactly what happened on
        // build 779594: seven phase lines, then silence, and a screen blaming the
        // link for a recorder that was demonstrably connected. The outcome is the
        // one line that makes the phases diagnosable instead of merely present.
        // String(describing:) is safe here BY CONSTRUCTION: no case of
        // RecordingDeviceAttachOutcome carries a session key — the credential-hygiene
        // gate asserts exactly that — so this cannot leak one into a log that leaves
        // the handset.
        log?.info("recording device: outcome \(String(describing: outcome))")
        teardown()
        return outcome
    }

    /// DESIGN §3.7's ONLY ACTION, MADE REAL.
    ///
    /// It touches the CUSTODY SEAM AND NOTHING ELSE — no radio, and above all no second key.
    /// If the write lands, the recorder and this phone finally agree, and a plain attach (with
    /// no mint) restores and adopts it exactly as it would on any later launch. That is why
    /// the retry does not need the link that was already closed.
    ///
    /// `nil` when there is nothing pending, which is every state but §3.7.
    public func retryPendingCustody() async -> RecordingDeviceAttachOutcome? {
        guard let pending = lock.withLock({ pendingMint }) else { return nil }
        do {
            try await secrets.save(pending.key, for: pending.identity)
        } catch {
            return .keyAcceptedNotDurable
        }
        // Best effort, and second: the recovery copy failing does not make the recorder
        // unusable on this phone, and reporting §3.7 again over it would be false.
        if let recovery, let token = PocketRecoveryToken(advertisedName: pending.advertisedName) {
            try? await recovery.save(pending.key, under: token)
        }
        lock.withLock { pendingMint = nil }
        // A FRESH ATTACHMENT, because this one is torn down and single-use. It restores the
        // key that is now in custody — the same path a later launch takes.
        let sibling = RecordingDeviceAttachment(makeCentral: makeCentral, secrets: secrets,
                                                recovery: recovery, deadlines: deadlines,
                                                log: log)
        return await sibling.attach(peripheralIdentifier: pending.id,
                                    advertisedName: pending.advertisedName)
    }

    // MARK: - Radio flow

    private func reachDiscoveredGraph(of id: UUID) async throws {
        let created: BLECentral = lock.withLock {
            if let central { return central }
            let made = makeCentral(self, bleQueue, nil)
            central = made
            return made
        }
        report(.wakingRadio)
        if created.managerState == .poweredOn { fulfil(.poweredOn) }
        try await wait(for: .poweredOn, timeout: deadlines.powerOn,
                       onTimeout: .bluetoothNeverReported)
        guard created.managerState == .poweredOn else {
            throw RecordingDeviceAttachError.unreachable(.bluetoothOff)
        }
        report(.findingDevice)
        // `retrievePeripherals(withIdentifiers:)` WAS ASSUMED TO BE A SYSTEM LOOKUP, and the
        // comment that used to sit here said so out loud: "not a per-central cache, so the
        // peripheral the pairing scan surfaced on `DeviceManager`'s central is reachable from
        // this one." Apple does not promise that. `retrievePeripherals` returns peripherals
        // the system KNOWS — which reliably covers a bonded or currently-connected device, and
        // does not reliably cover one that a DIFFERENT central merely saw advertising a moment
        // ago and never connected to. Every recorder being paired for the first time is in
        // exactly that state, and an empty array here used to be the end of the attempt.
        //
        // So the empty array is now a first attempt, not a verdict: this central goes and
        // finds the device itself, with the same unfiltered scan the pairing list uses. A tap
        // that establishes nothing must not be a device that can never be paired.
        let found: BLEPeripheral
        if let known = created.retrievePeripherals(withIdentifiers: [id]).first {
            found = known
        } else {
            log?.info("recording device: not retrievable on this central — rescanning for it")
            found = try await rediscover(id, on: created)
        }
        lock.withLock { peripheral = found }
        found.routeEventsToSink()
        report(.connecting)
        created.connect(found, options: nil)
        try await wait(for: .connected, timeout: deadlines.connect, onTimeout: .connectTimedOut)

        // EVERY service, because the app genuinely does not know what this device is yet.
        // Asking for one vendor's service UUID is the same mistake the scan filter was.
        report(.readingServices)
        found.discoverServices(nil)
        try await wait(for: .services, timeout: deadlines.discovery,
                       onTimeout: .serviceDiscoveryTimedOut)

        let services = found.discoveredServices ?? []
        lock.withLock {
            serviceUUIDs = Set(services.map(\.uuid))
            outstandingServices = services.count
            if services.isEmpty { satisfied.insert(.characteristics) }
        }
        report(.readingCharacteristics)
        for service in services { found.discoverCharacteristics(nil, for: service) }
        try await wait(for: .characteristics, timeout: deadlines.discovery,
                       onTimeout: .characteristicDiscoveryTimedOut)
    }

    /// FIND THE DEVICE ON THIS CENTRAL, because looking it up on this central did not.
    ///
    /// Unfiltered, for the same reason the pairing scan is: a stored-file recorder advertises
    /// no live-audio service, and a scan filtered to one is how the app used to be unable to
    /// see the very devices this file exists to attach. The scan is stopped on every exit —
    /// including the timeout — so a failed tap does not leave the radio scanning.
    private func rediscover(_ id: UUID, on central: BLECentral) async throws -> BLEPeripheral {
        lock.withLock { wantedIdentifier = id }
        central.scanForPeripherals(withServices: nil, options: nil)
        defer {
            central.stopScan()
            lock.withLock { wantedIdentifier = nil }
        }
        try await wait(for: .rediscovered, timeout: deadlines.connect, onTimeout: .deviceNotFound)
        guard let found = lock.withLock({ peripheral }) else {
            throw RecordingDeviceAttachError.unreachable(.deviceNotFound)
        }
        return found
    }

    /// Does the discovered graph carry EITHER shipped stored-file characteristic map?
    private var speaksStoredFileProtocol: Bool {
        let available = lock.withLock { tokens }
        return PocketCharacteristicMap.primary.required.isSubset(of: available)
            || PocketCharacteristicMap.fallback.required.isSubset(of: available)
    }

    /// AN AUTHENTICATED SESSION THAT OUTLIVES THE CALL THAT OPENED IT.
    ///
    /// WHAT THIS EXISTS TO FIX. Every stored-file path in this file used to close the protocol
    /// session the instant custody was settled — `adoptStoredFileRecorder` calls
    /// `client.close()` on every single branch, and `attach` then calls `teardown()`. So the
    /// client was never handed to anybody, and `PocketBLEClient.listDates`,
    /// `listRecordings(on:)` and `download(_:)` had no caller anywhere in `App/` or `Sources/`
    /// — the app could reach an authenticated recorder and had no way to ask it anything.
    /// This is the scope in which asking is possible.
    ///
    /// IT NEVER MINTS. There is no `mint:` parameter, deliberately: a key is written to a
    /// recorder from exactly one place (`attach(…, mint:)`, from the consent screen), and a
    /// second door into `provisionFactoryFresh` is the kind of thing that gets added "just for
    /// this one caller" and then ships.
    ///
    /// SINGLE USE, exactly like `attach`. `teardown()` retires this object's link and its
    /// generation; a second call gets `.linkDropped`. Callers make a fresh attachment per
    /// check, which is what `PocketRecorderCheck.run` does.
    public func withAuthenticatedSession<T: Sendable>(
        peripheralIdentifier id: UUID,
        advertisedName: String,
        _ body: (PocketBLEClient, PocketAuthenticatedIdentity) async -> T
    ) async -> RecordingDeviceSessionResult<T> {
        do {
            try await reachDiscoveredGraph(of: id)
        } catch {
            // SAME EVIDENCE AS `attach`, FOR THE SAME REASON. This path reaches the radio by
            // the same steps, so a check that could not reach the recorder has to say WHICH
            // step stopped it — not the one generic sentence every cause used to share.
            let reason = RecordingDeviceAttachError.reason(of: error)
            log?.error("recording device: unreachable — \(reason.diagnostic)")
            teardown()
            return .unavailable(.unreachable(reason))
        }
        guard speaksStoredFileProtocol else {
            let sawAudio = lock.withLock { serviceUUIDs.contains(OmiUUID.audioService) }
            teardown()
            return .unavailable(sawAudio ? .live : .unrecognised)
        }
        switch await establishStoredFileSession(id: id, advertisedName: advertisedName,
                                                mint: nil) {
        case .blocked(let outcome):
            teardown()
            return .unavailable(outcome)
        case .ready(let client, let identity):
            let value = await body(client, identity)
            // THE SESSION IS CLOSED HERE AND NOWHERE ELSE ON THIS PATH, so a body that
            // returned early cannot leave a recorder holding an open authenticated link.
            await client.close()
            teardown()
            return .ran(value)
        }
    }

    /// The outcome of the custody handshake: either a live authenticated session, or the
    /// single `RecordingDeviceAttachOutcome` that says why there isn't one.
    ///
    /// Every `.blocked` value has ALREADY closed the client and harvested any key the
    /// coordinator was holding, so a caller cannot forget to.
    private enum StoredFileSession {
        case ready(PocketBLEClient, PocketAuthenticatedIdentity)
        case blocked(RecordingDeviceAttachOutcome)
    }

    private func adoptStoredFileRecorder(
        id: UUID, advertisedName: String, mint: PocketMintConsent?
    ) async -> RecordingDeviceAttachOutcome {
        // The graph is read; everything past here is the recorder answering for itself —
        // transport, then the key. These are the two slowest steps against a real Pocket
        // and the two an owner most wants distinguished: "it never answered" and "it
        // answered but would not take my key" are completely different problems.
        report(.negotiatingProtocol)
        switch await establishStoredFileSession(id: id, advertisedName: advertisedName,
                                                mint: mint) {
        case .blocked(let outcome):
            return outcome
        case .ready(let client, let identity):
            var observation = await PocketRecordingDeviceBridge.observe(
                client: client, identity: identity, advertisedName: advertisedName)
            // AND HOW FULL IT IS, ASKED LAST ON THIS PATH TOO. Nothing follows it here but
            // `close()`, so a session this read retires costs nothing — but it is the same
            // ordering rule as the check's, written the same way, so the two paths cannot
            // drift into disagreeing about when it is safe to ask.
            if let space = await PocketRecordingDeviceBridge.storageReading(client: client) {
                observation = observation.withReading(
                    space, for: RecordingDeviceCapabilityKey.freeSpace.rawValue)
            }
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
        }
    }

    private func establishStoredFileSession(
        id: UUID, advertisedName: String, mint: PocketMintConsent?
    ) async -> StoredFileSession {
        let map = characteristicMap()
        guard let map, let peripheral = lock.withLock({ peripheral }) else {
            return .blocked(.unreachable(.protocolCharacteristicsVanished))
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

        // AND WAIT FOR IT. The two lines above only REQUEST notifications;
        // CoreBluetooth confirms them asynchronously via
        // didUpdateNotificationStateFor, and until that lands the recorder has not
        // been told to send anything. Issuing APP&SK&<key> into that window is the
        // "silent hang rather than an error" the comment above predicts — and it is
        // what a real Pocket did on build 779594: reached providingKey, wrote the
        // key, and no reply ever came, reported as a link failure against a
        // recorder that was plainly connected.
        //
        // Bounded by the control deadline, and a timeout is its own reason rather
        // than borrowing a neighbour's: nothing was negotiated and nothing was
        // refused, the channel simply never opened.
        if control != nil {
            do {
                try await wait(for: .notifying, timeout: deadlines.control,
                               onTimeout: .notificationsNeverEnabled)
            } catch {
                let reason = RecordingDeviceAttachError.reason(of: error)
                log?.error("recording device: unreachable — \(reason.diagnostic)")
                return .blocked(.unreachable(reason))
            }
        }

        let transport = PocketSeamTransport(link: self, timeout: deadlines.control)
        guard let client = try? await PocketBLEClient.connect(transport: transport) else {
            return .blocked(.unreachable(.protocolNegotiationFailed))
        }
        guard let identity = try? PocketAuthenticatedIdentity(peripheralIdentifier: id.uuidString)
        else {
            await client.close()
            return .blocked(.unreachable(.noDurableIdentity))
        }

        report(.providingKey)
        // THE SHIPPED CUSTODY ORDER, THROUGH THE SHIPPED COORDINATOR. Restore first; never a
        // speculative fresh write. `coexistenceAvailable` means "FoundryX holds no key for
        // this recorder" — and only THEN, and only with consent in hand, is a key minted.
        let coordinator = PocketOnboardingCoordinator(
            client: PocketProtocolOnboardingClient(client: client),
            store: secrets,
            recovery: recovery,
            recoveryToken: PocketRecoveryToken(advertisedName: advertisedName))
        var state = await coordinator.restore(identity: identity)
        // NO KEY, AND THE OWNER SAID YES. This is the only place in the app a key is written to
        // a recorder, it happens at most once per attach, and it cannot be reached without a
        // `PocketMintConsent` the owner's confirmation constructed.
        if state == .coexistenceAvailable, let mint {
            state = await coordinator.mintFactoryFresh(identity: identity, consent: mint)
        }
        switch state {
        case .ready:
            // THE SESSION IS HANDED BACK OPEN. Whoever asked for it closes it — `attach` after
            // one observation, `withAuthenticatedSession` after its body — and that is the
            // whole difference between a recorder this app can identify and one it can ask.
            return .ready(client, identity)
        case .coexistenceAvailable:
            await client.close()
            return .blocked(.setupUnavailable)
        case .mintRefused:
            // THE SAFE ANSWER TO U1. The recorder heard one key and said no, so it is still
            // holding the one another app gave it. One key was sent; a second never will be.
            await client.close()
            return .blocked(.mintRefused)
        case .mintNotVerified:
            // ACKNOWLEDGED, UNPROVEN. `MCU&SK&OK` came back and the access-point read-back did
            // not agree with the key we sent, so this build refuses to call it setup. The key
            // is in custody — it was put there BEFORE the write — so the screen's promise that
            // nothing is lost is one the flow actually keeps. The harvest below is belt and
            // braces: if the coordinator is ever holding an unstored key in this state, it
            // leaves with this object rather than dying with the coordinator.
            if let key = await coordinator.mintedKeyPendingCustody() {
                lock.withLock { pendingMint = (key, identity, advertisedName, id) }
            }
            await client.close()
            return .blocked(.mintNotVerified)
        case .keyNotKept:
            // NOTHING WAS SENT. Custody refused the candidate before the recorder was asked,
            // which is the whole point of doing custody first.
            await client.close()
            return .blocked(.keyNotKept)
        case .custodyUnreadable:
            // FoundryX MAY HOLD THIS RECORDER'S KEY AND COULD NOT READ IT. Distinct from
            // `.setupUnavailable`, which is the state that offers to mint — offering to mint
            // here would write a second key to a recorder FoundryX itself set up.
            await client.close()
            return .blocked(.custodyUnreadable)
        case .acceptedNotDurable:
            // THE RECORDER HAS A KEY THIS PHONE COULD NOT STORE. The coordinator is about to
            // go away with the only copy of it, so the key is held here — and `mintedKey` is
            // the only reason `retryPendingCustody()` can be more than a button.
            if let key = await coordinator.mintedKeyPendingCustody() {
                lock.withLock {
                    pendingMint = (key, identity, advertisedName, id)
                }
            }
            await client.close()
            return .blocked(.keyAcceptedNotDurable)
        case .indeterminate:
            // THE HANDSHAKE NEVER COMPLETED. `restore` reserves `.indeterminate` for a key
            // that was never answered — a dropped link, a timeout, a firmware that stopped
            // talking after it accepted — and `.recoveryRequired` for a key the recorder
            // actually REFUSED. Reporting the first as the second is how a UI tells someone
            // their key is wrong when their recorder merely walked out of range.
            await client.close()
            return .blocked(.unreachable(.handshakeUnanswered))
        default:
            await client.close()
            return .blocked(.recoveryRequired)
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
        guard let peripheral else {
            throw RecordingDeviceAttachError.unreachable(.linkDroppedDuringSetup)
        }
        guard let characteristic else {
            throw RecordingDeviceAttachError.unknownCharacteristic(token)
        }
        // WITHOUT RESPONSE — the mode the recorder actually answers.
        //
        // This wrote `.withResponse`, and against a real Pocket every command went
        // unanswered: build 780017 reached providingKey (the notify subscription
        // confirmed), wrote APP&SK&<key>, and 8s later reported
        //   outcome unreachable(handshakeUnanswered)
        //
        // pocket-libre, which authenticates with the SAME KEY from a Mac, writes:
        //   commands.py:127  await client.write_gatt_char(CMD_WRITE_CHAR, payload,
        //                                                 response=False)
        // and CMD_WRITE_CHAR is AUDIO_META_CHAR (001120a3) — the same
        // characteristic this app uses, subscribed for the MCU& reply on the same
        // handle. The characteristic, the payload and the subscription all matched
        // already; the write MODE was the last difference between the flow that
        // works and the flow that does not.
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
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
        // Drop the phase observer with everything else it owns. A sink that outlives the
        // attempt is a retained view reporting progress for a device nobody is attaching.
        onPhase = nil
        generation &+= 1
        let peripheral = self.peripheral
        let central = self.central
        let pendingGates = waiters
        let pendingEventWaiters = eventWaiters
        waiters.removeAll()
        eventWaiters.removeAll()
        pendingEvents.removeAll()
        self.peripheral = nil
        self.wantedIdentifier = nil
        // AND THE CENTRAL, which this used to keep. It nilled `peripheral` and left `central`
        // in place, so the `CBCentralManager` a tap opened lived exactly as long as the
        // attachment object did — and two of the states the model DELIBERATELY retains the
        // attachment for (`.keyAcceptedNotDurable`, holding the only copy of an accepted key,
        // and the §3.7 screen it puts up) hold that object open indefinitely. A radio held
        // open by a failed attempt is one more thing wrong with the next attempt.
        //
        // It is safe to drop: this object is single-use by construction (`torndown` is never
        // cleared), and `retryPendingCustody` builds a SIBLING from `makeCentral` rather than
        // reusing this central.
        self.central = nil
        lock.unlock()

        for (_, continuations) in pendingGates {
            for continuation in continuations {
                continuation.resume(
                    throwing: RecordingDeviceAttachError.unreachable(.linkDroppedDuringSetup))
            }
        }
        for waiter in pendingEventWaiters {
            waiter.resume(throwing: PocketTransportFailure.disconnected)
        }
        if let peripheral, let central {
            central.stopScan()
            central.cancelPeripheralConnection(peripheral)
        }
    }

    /// Whether this attempt is still holding a central manager. Test-only: it is the one way
    /// to state "the radio a tap opened is released when the tap is over" as a claim about the
    /// object rather than about ARC's timing.
    var isHoldingRadio: Bool { lock.withLock { central != nil } }

    // MARK: - Gates

    private func wait(for gate: Gate, timeout: TimeInterval,
                      onTimeout reason: RecordingDeviceUnreachableReason) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if torndown {
                lock.unlock()
                continuation.resume(
                    throwing: RecordingDeviceAttachError.unreachable(.linkDroppedDuringSetup))
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
                self?.fail(gate, with: RecordingDeviceAttachError.unreachable(reason))
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

    // MARK: - BLEEventSink

    public func bleCentral(_ central: BLECentral, willRestore peripherals: [BLEPeripheral]) {
        // This central is created WITHOUT a restore identifier on purpose: a probe must never
        // be a reason iOS relaunches the app.
    }

    public func bleCentralDidUpdateState(_ central: BLECentral) {
        if central.managerState == .poweredOn {
            fulfil(.poweredOn)
        } else {
            fail(.poweredOn, with: RecordingDeviceAttachError.unreachable(.bluetoothOff))
        }
    }

    /// ONLY WHILE A RESCAN IS RUNNING, and only for the device the tap was about. Everything
    /// else advertising in the room is somebody else's problem here — `DeviceManager` owns the
    /// pairing list.
    public func bleCentral(_ central: BLECentral, didDiscover peripheral: BLEPeripheral, rssi: Int) {
        let wanted = lock.withLock { () -> Bool in
            guard wantedIdentifier == peripheral.identifier else { return false }
            self.peripheral = peripheral
            return true
        }
        guard wanted else { return }
        fulfil(.rediscovered)
    }

    public func bleCentral(_ central: BLECentral, didConnect peripheral: BLEPeripheral) {
        guard lock.withLock({ self.peripheral?.identifier == peripheral.identifier }) else { return }
        fulfil(.connected)
    }

    /// A REFUSAL, NOT A SILENCE. It used to be reported as `.linkDropped` alongside a mid-setup
    /// disconnect and a connect that simply never answered — three different situations, one
    /// sentence.
    public func bleCentral(_ central: BLECentral, didFailToConnect peripheral: BLEPeripheral,
                           error: Error?) {
        fail(.connected, with: RecordingDeviceAttachError.unreachable(.connectRefused))
    }

    public func bleCentral(_ central: BLECentral, didDisconnect peripheral: BLEPeripheral,
                           error: Error?) {
        guard lock.withLock({ self.peripheral?.identifier == peripheral.identifier }) else { return }
        for gate in [Gate.connected, .services, .characteristics] {
            fail(gate, with: RecordingDeviceAttachError.unreachable(.linkDroppedDuringSetup))
        }
        failOldestEventWaiter(with: PocketTransportFailure.disconnected)
    }

    public func blePeripheral(_ peripheral: BLEPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            // AN ERROR IS NOT A TIMEOUT. This branch reported one as the other, so a device
            // that answered "I can't tell you" and a device that answered nothing at all were
            // the same event by the time anything looked at them.
            fail(.services, with: RecordingDeviceAttachError.unreachable(.serviceDiscoveryFailed))
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

    /// THE CONFIRMATION THIS USED TO THROW AWAY.
    ///
    /// The body was `{}`, so `setNotifyValue` was fire-and-forget and the code three lines
    /// later could not have waited even if it wanted to — and it did not. The comment above
    /// that call states the hazard exactly ("a write issued before the notify state settles
    /// has nowhere to answer, which is a silent hang rather than an error") and then races
    /// it. Observed on build 779594 against a real Pocket: the attach reached `providingKey`,
    /// wrote APP&SK&<key>, and no reply ever arrived — the recorder had never been told to
    /// send one yet.
    public func blePeripheral(_ peripheral: BLEPeripheral,
                              didUpdateNotificationStateFor characteristic: BLECharacteristic,
                              error: Error?) {
        let isControl = lock.withLock { controlCharacteristic === characteristic }
        guard isControl else { return }
        if let error {
            log?.error("recording device: notify enable failed — \(error.localizedDescription)")
            return
        }
        fulfil(.notifying)
    }

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
