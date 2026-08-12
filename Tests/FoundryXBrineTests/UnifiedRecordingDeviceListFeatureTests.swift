import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for `features/unified-recording-device-list.feature` (track
/// 20260810T2158_unified_recording_device_list_wires_pocket_and_omi).
///
/// WHAT IS REAL HERE. `RecordingSourceCatalog.merge` — the only thing that decides the order —
/// the account-scoped `RecordingDeviceStore` in a sandboxed container, the real Pocket
/// authenticated identity, the shipped `RecordingDeviceConnectPresentation` copy, and the
/// presentation values `App/DeviceScreen.swift` renders 1:1. Injected: which devices exist (a
/// radio is the one thing a hermetic suite cannot own).
///
/// THE ORDERING SCENARIO IS THE ONE THAT MATTERS MOST. The spec's first acceptance criterion
/// is that a shape-first ordering FAILS, so the fixture is chosen to make shape-first and
/// name-first disagree, and the same step also re-runs the merge with the record-then-sync
/// device renamed so that it sorts FIRST — which no grouping by class can produce.
final class UnifiedRecordingDeviceListFeatureTests: ProcessGlobalStateTestCase {

    @MainActor
    func testUnifiedRecordingDeviceListFeature() async throws {
        let world = try UnifiedDeviceListWorld()
        do {
            let result = try await BrineFeatureRunner.run(
                "unified-recording-device-list",
                registry: StepRegistry(UnifiedDeviceListSteps.make(world: world)))
            // Pin the POPULATION: the runner asserts only that nothing FAILED, so deleting a
            // scenario would otherwise leave this suite green.
            XCTAssertEqual(result.passed, 12,
                           "unified-recording-device-list must run all 12 scenarios — one per "
                               + "acceptance criterion in the track spec, plus the ordering, "
                               + "relaunch and honest-capability cases, plus the three that "
                               + "hold the APP'S OWN adoption chain: the tap that adopts, the "
                               + "recorder FoundryX has no key for, and the unfiltered scan")
        } catch {
            world.cleanup()
            throw error
        }
        world.cleanup()
    }

    // MARK: unit — the derived class is total, and mirrors the adapter mapping

    /// `deviceClass(for:)` is THE one derived function the whole design rests on. Held over
    /// every shape rather than over the three a test author remembered, and held against the
    /// adapter mapping it is said to mirror — a shape that gains a `storedFileSync` adapter
    /// without gaining the record-then-sync class is precisely the drift that would put a
    /// recorder back on the live pipeline.
    func testEveryShapeHasAClassAndItMirrorsTheAdapter() {
        for shape in RecordingDeviceShape.allCases {
            let deviceClass = RecordingSourceCatalog.deviceClass(for: shape)
            let adapter = RecordingSourceCatalog.adapter(for: shape)
            XCTAssertEqual(deviceClass == .recordThenSync, adapter == .storedFileSync,
                           "\(shape) is classified \(deviceClass) but adapts through \(adapter) "
                               + "— the class must mirror the adapter, or a device that "
                               + "delivers stored files is being offered a live surface")
            XCTAssertFalse(deviceClass.caption.isEmpty,
                           "\(shape) renders no class caption at all")
        }
        XCTAssertEqual(Set(RecordingDeviceShape.allCases.map {
            RecordingSourceCatalog.deviceClass(for: $0)
        }), Set(RecordingDeviceClass.allCases),
                       "the fixture is degenerate — every shape landed in one class, so the "
                           + "mirror assertion above cannot fail")
    }

    /// A record-then-sync device may not be handed a recording claim BY ANY CALLER. This is
    /// the property over the whole activity space, not the one value the feature exercises.
    func testNoActivityCanMakeARecordThenSyncDeviceClaimItIsRecording() {
        let activities: [RecordingDeviceLiveActivity] = [
            .none, .availableAsInput, .recording(elapsed: "12:04"), .recording(elapsed: "0:01"),
        ]
        for link in [RecordingDeviceLinkState.connected, .reconnecting, .disconnected] {
            for activity in activities {
                let state = UnifiedDeviceListPresentation.state(
                    deviceClass: .recordThenSync, link: link, activity: activity)
                XCTAssertEqual(state, link.label,
                               "a record-then-sync device rendered \"\(state)\" for \(activity) "
                                   + "— the phone is not in the loop while this device records, "
                                   + "so the only fact it has is the link")
                for banned in UnifiedDeviceListPresentation.bannedProximityWords {
                    XCTAssertFalse(state.contains(banned),
                                   "\"\(state)\" says \"\(banned)\" — this phone cannot "
                                       + "distinguish out-of-range from powered-off from "
                                       + "connected-to-another-app")
                }
            }
        }
        // Non-vacuity: a LIVE device must actually be able to say it.
        XCTAssertEqual(
            UnifiedDeviceListPresentation.state(deviceClass: .live, link: .connected,
                                                activity: .recording(elapsed: "12:04")),
            "Recording now · 12:04",
            "a live device can no longer report that it is recording — this test's "
                + "record-then-sync claims are then vacuous")
    }

    /// Battery in a ROW comes only from `.reported`. Held over every capability state.
    func testARowShowsABatteryValueOnlyWhenTheDeviceReportedOne() {
        let declaredNothing = RecordingDeviceCapabilities(declared: [:])
        let declaredValueless = RecordingDeviceCapabilities(
            declared: [RecordingDeviceCapabilityKey.batteryLevel.rawValue: nil])
        let reported = RecordingDeviceCapabilities(
            declared: [RecordingDeviceCapabilityKey.batteryLevel.rawValue: "84%"])
        XCTAssertNil(UnifiedDeviceListPresentation.reportedBattery(declaredNothing),
                     "an undeclared battery produced a value")
        XCTAssertNil(UnifiedDeviceListPresentation.reportedBattery(declaredValueless),
                     "\"this device has a battery\" is not a percentage, and printing one for "
                         + "it is how `N/A` and `0%` get onto a row")
        XCTAssertEqual(UnifiedDeviceListPresentation.reportedBattery(reported), "84%")
    }

    /// THE APP MUST ACTUALLY CALL THE CHAIN. `swift test` cannot compile `App/`, so nothing
    /// else connects "the attachment works" to "a tap reaches it" — which is precisely how
    /// `RecordingDeviceAdoption.remember` shipped with zero non-test callers.
    func testTheConnectSheetRunsTheAdoptionChainRatherThanOnlyThePairingPath() throws {
        let url = AppSourceTree.repoRoot.appendingPathComponent("App/DeviceScreen.swift")
        let code = AppSourceTree.withoutComments(of: try String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(code.contains("RecordingDeviceAttachment"),
                      "nothing in the Devices screen constructs the attachment, so a tap "
                          + "cannot reach `PocketBLEClient`, `PocketRecordingDeviceBridge` or "
                          + "`RecordingDeviceAdoption` and no discovered recorder can become "
                          + "a row")
        XCTAssertTrue(code.contains(".attach("),
                      "the attachment is named but never run")
        XCTAssertTrue(code.contains("RecordingDeviceAttachPresentation"),
                      "the outcome of a tap is being worded in the view instead of in the "
                          + "kit, where it can be asserted")
        XCTAssertTrue(code.contains("PocketOnboardingView(screen: attach.ceremonyScreen)"),
                      "a tap that lands on the gated setup state does not reach the §3.6 "
                          + "screen, so the one step this build cannot take is invisible")
        XCTAssertTrue(code.contains("device.connect(found)"),
                      "the shipped pairing path is gone — a live device tapped in the connect "
                          + "sheet would no longer pair at all")
    }

    /// A characteristic must answer to EVERY spelling `PocketCharacteristicMap` could address
    /// it by. Matching one form only is how a real recorder fails the superset check while
    /// looking, in the logs, exactly like a device that speaks nothing.
    func testACharacteristicAnswersToTheTokenTheProtocolMapAddressesItBy() {
        for token in PocketCharacteristicMap.primary.required
            .union(PocketCharacteristicMap.fallback.required) {
            let uuid = FakePocketBLEStack.characteristicUUID(token)
            XCTAssertTrue(RecordingDeviceAttachment.tokens(of: uuid).contains(token),
                          "a characteristic advertised as \(uuid.uuidString) does not answer "
                              + "to \"\(token)\", which is the only name "
                              + "`PocketCharacteristicMap` knows it by")
        }
        // Non-vacuity: an unrelated characteristic must NOT answer to a protocol token.
        let unrelated = RecordingDeviceAttachment.tokens(of: OmiUUID.audioDataChar)
        XCTAssertTrue(unrelated.isDisjoint(with: PocketCharacteristicMap.primary.required),
                      "the live-audio characteristic answers to a stored-file protocol token, "
                          + "so the protocol check would classify an Omi as a recorder")
    }

    /// The copy a tap can produce is brand-free, held over the population.
    func testEveryAttachLineNamesNoVendor() {
        for line in RecordingDeviceAttachPresentation.everyLine {
            for vendor in ["Pocket", "Omi", "PKT", "Friend"] {
                XCTAssertFalse(line.contains(vendor),
                               "\"\(line)\" names \(vendor) — a tap that established nothing "
                                   + "has established nothing to name")
            }
            XCTAssertFalse(line.isEmpty)
        }
    }
}

// MARK: - Steps

private enum UnifiedDeviceListSteps {
    static func make(world: UnifiedDeviceListWorld) -> [StepDefinition] {
        let givens = [
            "an audio-route headset, this iPhone's microphone, a paired Omi and a paired Pocket",
            "a remembered device that has never reported a battery level",
            "a paired Pocket that is not connected",
            "this iPhone's microphone and a Bluetooth headset the account does not remember",
            "the shipped recording-device connect copy",
            "a signed-in account that pairs a Pocket through the shipped adoption seam",
            "a signed-in account and a discovered recorder FoundryX already holds the key for",
            "a signed-in account and a discovered recorder FoundryX holds no key for",
            "the connect affordance has started a pairing scan",
        ]
        /// The chain the app runs on a tap is ASYNCHRONOUS end to end — a radio, a protocol
        /// client and a keychain — so these cannot be discharged inside `MainActor.run`.
        let asyncWhens = [
            "I tap that discovered device",
        ]
        let whens = [
            "the device list is drawn",
            "the Pocket is handed a claim that it is recording right now",
            "its device page is built",
            "each device page is built",
            "a stored-file device is discovered attached displayed disconnected and reconnected",
            "the account's remembered devices are read back",
        ]
        let thens = [
            "the rows read in name order rather than in shape order",
            "every row uses the same grammar of a name and a class and a state",
            "grouping those same devices by shape would produce a different list",
            "the Pocket row reads \"Records on its own · Not connected\"",
            "the Pocket row is not first and not last by virtue of its shape",
            "its row still reports only whether the link is reachable",
            "that row carries no battery value",
            "no row anywhere in the list says \"N/A\"",
            "a device that did report its battery shows the value it reported",
            "the Settings entry subtitle reads \"3 live, 1 records on its own\"",
            "that subtitle contains no vendor name",
            "the page carries the recorder-light sentence where a live device carries record and stop",
            "the page offers no record or stop control",
            "the page never says the device is in range",
            "the page's capability strip is battery firmware gap recovery and offline storage",
            "the page's capability strip has no signal column",
            "its education comes from the protocol it speaks and not from its shape",
            "neither page renders a capability it can never fill",
            "neither page offers to forget a device the account does not remember",
            "a remembered live device is offered forget without a claim about a key",
            "its class may not contribute a Live Activity in any state",
            "a live device's class may",
            "no active source FrameRouter WAL Live Activity or live state mutation occurs",
            "the affordance is titled \"Connect a recording device\"",
            "the list is titled \"Recording devices\"",
            "the scanning and empty lines name no vendor",
            "the education line above the list explains the one distinction the list is organised by",
            "that link opens the class explanation rather than one device's light",
            "the app presents the recorder setup screen from the connect affordance",
            "no branded setup row is pinned above whatever answered the scan",
            "the Pocket is remembered under its stored-file identity",
            "the redrawn list shows it as a peer row reading \"Records on its own · Not connected\"",
            "the transport client established which protocol that device speaks",
            "FoundryX authenticated it and read its battery and firmware over the radio seam",
            "the app says setup isn't available yet instead of adding a row",
            "FoundryX sent that recorder nothing at all",
            "the account does not remember that recorder",
            "the scan carries no service filter at all",
            "a device advertising no live-audio service still answers it and appears in the list",
        ]
        var steps = givens.map { phrase in
            defineStep(phrase) { context, _, _ in
                try await world.given(phrase)
                return context
            }
        }
        steps += asyncWhens.map { phrase in
            defineStep(phrase) { context, _, _ in
                try await world.whenAsync(phrase)
                return context
            }
        }
        steps += whens.map { phrase in
            defineStep(phrase) { context, _, _ in
                try await MainActor.run { try world.when(phrase) }
                return context
            }
        }
        steps += thens.map { phrase in
            defineCheck(phrase) { _, _, _ in
                try await MainActor.run { try world.then(phrase) }
            }
        }
        return steps
    }
}

// MARK: - World

@MainActor
private final class UnifiedDeviceListWorld {

    private let token = UUID().uuidString
    private let sandbox: URL
    private let container: URL
    private let scopeDefaultsName: String
    private let legacyDefaultsName: String
    private let scopeDefaults: UserDefaults
    /// The DEVICE-GLOBAL legacy pairing suite, isolated from the real one — the composition
    /// adopts a legacy pairing on the way past, and it must adopt this one, not the machine's.
    private let legacyDefaults: UserDefaults

    private var inputs: [RecordingDeviceListInput] = []
    private var rows: [UnifiedDeviceRow] = []
    private var page: RecordingDevicePagePresentation?
    private var pages: [RecordingDevicePagePresentation] = []
    private var liveEffects: StoredFileLiveEffectCounts?
    private var remembered: [RecordingDeviceRecord] = []
    /// The outcome the SHIPPING adoption seam returned, so the relaunch scenario is evidence
    /// about `RecordingDeviceAdoption` rather than about a record the test wrote itself.
    private var adoption: RecordingDeviceDetachOutcome?

    /// THE APP'S OWN CHAIN, not a record the test wrote. `attachStack` is a scripted
    /// peripheral behind the BLE SEAM — the same four types `CoreBluetoothCentral` wraps — so
    /// what runs between the tap and the store row is the shipped `RecordingDeviceAttachment`,
    /// the shipped `PocketSeamTransport`, the real `PocketBLEClient`, the real
    /// `PocketOnboardingCoordinator` and the real `RecordingDeviceAdoption`.
    private var attachStack: FakePocketBLEStack?
    private var attachOutcome: RecordingDeviceAttachOutcome?
    private var secrets = InMemoryPocketSecretStore()
    /// The pairing scan, driven through the real `DeviceManager` on the same seam.
    private var scanStack: FakePocketBLEStack?
    private var scanDevice: DeviceManager?
    private var scanAnswered: Bool?

    /// The design's own fixture: the list that must read AirPods, iPhone, Omi, PKT01 — and
    /// not "wearables first".
    private static let headsetName = "AirPods Pro"
    private static let handsetName = "iPhone microphone"
    private static let omiName = "Omi"
    private static let pocketName = "PKT01_BLUE_26079bc5"
    private static let pocketPeripheral = "26079BC5-9B44-4C1E-9A22-7E5F0D3C1B08"
    /// The SAME peripheral as `pocketPeripheral`, as the radio hands it back. The durable
    /// identity is derived from it by `PocketAuthenticatedIdentity`, never from the name.
    private static let pocketPeripheralId = UUID(uuidString: pocketPeripheral)!
    /// A DIFFERENT recorder, so the "no key" scenario can assert the account remembers
    /// nothing for it regardless of what any other scenario adopted.
    private static let unprovisionedPeripheralId =
        UUID(uuidString: "FFFFFFFF-9B44-4C1E-9A22-7E5F0D3C1B08")!
    /// A well-formed 16-byte ASCII session secret, as the protocol client requires.
    private static let sessionSecret = "A!b2-C_d.E?9+x=Z"

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-unified-device-list-\(token)", isDirectory: true)
        container = sandbox.appendingPathComponent("documents/foundryx-captures", isDirectory: true)
        scopeDefaultsName = "foundryx.unified-device-list.scope.\(token)"
        legacyDefaultsName = "foundryx.unified-device-list.legacy.\(token)"
        guard let scope = UserDefaults(suiteName: scopeDefaultsName),
              let legacy = UserDefaults(suiteName: legacyDefaultsName) else {
            throw BrineStepError("could not create isolated UserDefaults suites")
        }
        scopeDefaults = scope
        legacyDefaults = legacy
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        installSandbox()
    }

    private func installSandbox() {
        CaptureAccountScope.setContainerForTests(container)
        CaptureAccountScope.setApplicationSupportRootForTests(
            sandbox.appendingPathComponent("application-support", isDirectory: true))
        CaptureAccountScope.setDefaultsForTests(scopeDefaults)
    }

    func cleanup() {
        try? CaptureAccountScope.signOutForTests()
        CaptureAccountScope.resetTestEnvironment()
        scopeDefaults.removePersistentDomain(forName: scopeDefaultsName)
        legacyDefaults.removePersistentDomain(forName: legacyDefaultsName)
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: fixtures

    private static var pocketIdentity: RecordingDeviceIdentity {
        get throws {
            try PocketAuthenticatedIdentity(peripheralIdentifier: pocketPeripheral)
                .recordingDeviceIdentity
        }
    }

    private static let omiIdentity = RecordingDeviceIdentity(
        shape: .bleStream, hardwareToken: "5C2E1A70-9B44-4C1E-9A22-7E5F0D3C1B08")

    /// The handset's own capture sources, exactly as `CaptureSourceRegistry` describes them.
    private static var captureSources: [CaptureSourceDescriptor] {
        [
            CaptureSourceDescriptor(id: CaptureSourceDescriptor.phoneMicId, category: .phoneMic,
                                    displayName: handsetName, connection: .builtIn,
                                    enabled: true, canToggle: true, isBuiltIn: true),
            CaptureSourceDescriptor(id: CaptureSourceDescriptor.bluetoothId(routeUID: "airpods-1"),
                                    category: .bluetoothMic, displayName: headsetName,
                                    connection: .available, enabled: true, canToggle: true,
                                    isBuiltIn: false, routeUID: "airpods-1"),
            // The Omi is a REMEMBERED device and arrives through the store. Its legacy
            // "capture source" row is here so the composition is proved to skip it rather
            // than list the same device twice.
            CaptureSourceDescriptor(id: CaptureSourceDescriptor.omiId, category: .omi,
                                    displayName: "Omi wearable", connection: .connected,
                                    enabled: true, canToggle: true, isBuiltIn: true),
        ]
    }

    private func fourDeviceFixture(pocketName: String = pocketName) throws
        -> [RecordingDeviceListInput] {
        let records = [
            RecordingDeviceRecord(identity: Self.omiIdentity, displayName: Self.omiName),
            RecordingDeviceRecord(identity: try Self.pocketIdentity, displayName: pocketName),
        ]
        return UnifiedDeviceListComposition.inputs(
            remembered: records,
            captureSources: Self.captureSources,
            link: [Self.omiIdentity: .connected],
            batteryPercent: [Self.omiIdentity: 84])
    }

    // MARK: Given

    func given(_ phrase: String) async throws {
        rows = []
        page = nil
        pages = []
        liveEffects = nil
        remembered = []
        adoption = nil
        attachOutcome = nil
        scanAnswered = nil
        switch phrase {
        case "an audio-route headset, this iPhone's microphone, a paired Omi and a paired Pocket":
            inputs = try fourDeviceFixture()

        case "a remembered device that has never reported a battery level":
            // The exact shape of the shipped defect: an unpaired device whose strip read
            // `N/A · N/A · N/A`. It declares nothing, and one device beside it declares a
            // real reading so the assertion is not satisfied by an empty list.
            inputs = UnifiedDeviceListComposition.inputs(
                remembered: [
                    RecordingDeviceRecord(identity: Self.omiIdentity, displayName: Self.omiName),
                    RecordingDeviceRecord(identity: try Self.pocketIdentity,
                                          displayName: Self.pocketName),
                ],
                captureSources: [],
                batteryPercent: [Self.omiIdentity: 84])

        case "a paired Pocket that is not connected":
            // The protocol its transport client NEGOTIATED — which is what education attaches
            // to (design §5), and the only thing that may unlock a "How this recorder works"
            // row. Not the shape, and never the reported name.
            inputs = UnifiedDeviceListComposition.inputs(
                remembered: [RecordingDeviceRecord(identity: try Self.pocketIdentity,
                                                   displayName: Self.pocketName)],
                captureSources: [],
                negotiatedProtocol: [
                    try Self.pocketIdentity: PocketRecordingDeviceBridge.protocolIdentifier,
                ])

        case "this iPhone's microphone and a Bluetooth headset the account does not remember":
            // Neither comes from the store. Both used to get a four-row capability strip and
            // a "deletes FoundryX's key" forget action.
            inputs = UnifiedDeviceListComposition.inputs(
                remembered: [], captureSources: Self.captureSources)

        case "the shipped recording-device connect copy":
            inputs = []

        case "a signed-in account that pairs a Pocket through the shipped adoption seam":
            CaptureAccountScope.setAccountForTests(email: "unified-\(token)@example.com")
            guard let binding = CaptureAccountScope.currentAccountBinding(),
                  binding.scope != CaptureAccountScope.signedOutScope else {
                throw BrineStepError("signing in did not leave the signed-out scope")
            }
            // THE WHOLE SHIPPING CHAIN, NOT A RECORD THE TEST WROTE. The previous version of
            // this step called `RecordingDeviceStore.recordUserPair` itself with a
            // `.filePull` identity — a path the app did not have, since the only caller of
            // `recordUserPair` in the tree was `DeviceManager.connect` with `.bleStream`. A
            // gate that seeds through a path the app does not have is not evidence the app
            // has the path. So: the real protocol client over a fake transport, the real
            // authenticated identity, the real discovery bridge, and the real adoption seam.
            let transport = UnifiedDeviceListFakeTransport(
                controls: ["MCU&SK&OK", "MCU&BAT&72", "MCU&FW&1.6"])
            let client = try await PocketBLEClient.connect(transport: transport)
            try await client.authenticate(secret: Self.sessionSecret)
            let authenticated = try PocketAuthenticatedIdentity(
                peripheralIdentifier: Self.pocketPeripheral)
            let observation = await PocketRecordingDeviceBridge.observe(
                client: client, identity: authenticated, advertisedName: Self.pocketName)
            adoption = RecordingDeviceAdoption.remember(observation)
            guard case .recorded = adoption else {
                throw BrineStepError("the adoption seam did not record the pair: "
                                         + String(describing: adoption))
            }
            inputs = []

        case "a signed-in account and a discovered recorder FoundryX already holds the key for":
            try signIn()
            // The SAME peripheral the relaunch scenario remembers, so the two scenarios
            // converge on one record rather than leaving a second device in the account.
            let stack = FakePocketBLEStack(deviceId: Self.pocketPeripheralId,
                                           deviceName: Self.pocketName,
                                           acceptedSecret: Self.sessionSecret)
            attachStack = stack
            secrets = InMemoryPocketSecretStore()
            // CUSTODY FoundryX ALREADY HOLDS. Provisioning a FRESH key is what design §3.6 /
            // T2 req 3 gates; RESTORING one is the leg that ships, and it is the leg driven
            // here, through the shipped `PocketOnboardingCoordinator`.
            try await secrets.save(Self.sessionSecret,
                                   for: try PocketAuthenticatedIdentity(
                                       peripheralIdentifier: stack.deviceId.uuidString))
            inputs = []

        case "a signed-in account and a discovered recorder FoundryX holds no key for":
            try signIn()
            attachStack = FakePocketBLEStack(deviceId: Self.unprovisionedPeripheralId,
                                             deviceName: "PKT02_BLUE_ffffffff",
                                             acceptedSecret: Self.sessionSecret)
            // EMPTY ON PURPOSE. This is every recorder in the world today.
            secrets = InMemoryPocketSecretStore()
            inputs = []

        case "the connect affordance has started a pairing scan":
            // A recorder that advertises NO live-audio service — the device the shipped
            // filter made unable to answer at all.
            let stack = FakePocketBLEStack(deviceId: Self.unprovisionedPeripheralId,
                                           deviceName: "PKT02_BLUE_ffffffff")
            let device = DeviceManager(makeCentral: stack.factory)
            scanStack = stack
            scanDevice = device
            device.startScan()          // creates the central; the scan follows power-on
            try await settle()
            device.startScan()          // …and the affordance's own gesture, once powered on
            try await settle()
            // ANSWERED THROUGH THE FILTER THE APP ACTUALLY ISSUED. The fake models
            // CoreBluetooth's own semantics — a filtered scan reports only peripherals
            // advertising one of the named services — so with the shipped
            // `[OmiUUID.audioService]` filter this device is simply never reported.
            scanAnswered = stack.deliverScanResult()
            try await settle()
            inputs = []

        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    private func signIn() throws {
        CaptureAccountScope.setAccountForTests(email: "unified-\(token)@example.com")
        guard let binding = CaptureAccountScope.currentAccountBinding(),
              binding.scope != CaptureAccountScope.signedOutScope else {
            throw BrineStepError("signing in did not leave the signed-out scope")
        }
    }

    /// Let the main queue and the seam's own queue catch up. `DeviceManager` defers its scan
    /// to the main queue and the seam delivers every callback asynchronously, exactly as
    /// `CBCentralManager(delegate:queue:)` does — a synchronous assertion would be testing a
    /// threading model the app does not have.
    private func settle() async throws {
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 20_000_000)
            scanStack?.drain()
        }
    }

    // MARK: When (async — the chain the app runs is asynchronous)

    func whenAsync(_ phrase: String) async throws {
        switch phrase {
        case "I tap that discovered device":
            guard let stack = attachStack else {
                throw BrineStepError("no discovered recorder was staged")
            }
            // THE PRODUCTION COMPONENT, on the production seam. The only injected things are
            // the radio and the secret store; everything between the tap and the store row is
            // the shipped code path `App/DeviceScreen.swift` calls.
            // `recovery: nil` KEEPS THIS HERMETIC. With no attach record, `restore` consults
            // the SYNCHRONISED recovery record, which under the shipped default is a real
            // Keychain item — and the claim here is about a phone that holds nothing for this
            // recorder at all.
            let attachment = RecordingDeviceAttachment(
                makeCentral: stack.factory,
                secrets: secrets,
                recovery: nil,
                deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 5))
            attachOutcome = await attachment.attach(peripheralIdentifier: stack.deviceId,
                                                    advertisedName: stack.deviceName)

        default:
            throw BrineStepError("unhandled async When: \(phrase)")
        }
    }

    // MARK: When

    func when(_ phrase: String) throws {
        switch phrase {
        case "the device list is drawn":
            rows = UnifiedDeviceListPresentation.rows(inputs)

        case "the Pocket is handed a claim that it is recording right now":
            let pocket = try Self.pocketIdentity
            inputs = inputs.map { input in
                guard input.identity == pocket else { return input }
                return RecordingDeviceListInput(
                    identity: input.identity,
                    displayName: input.displayName,
                    declaredCapabilities: input.declaredCapabilities,
                    audioProfile: input.audioProfile,
                    link: input.link,
                    liveActivity: .recording(elapsed: "12:04"))
            }
            rows = UnifiedDeviceListPresentation.rows(inputs)

        case "its device page is built":
            guard let input = inputs.first(where: { $0.identity.shape == .filePull }) else {
                throw BrineStepError("no record-then-sync device in the fixture")
            }
            page = RecordingDevicePage.resolve(input)

        case "each device page is built":
            pages = inputs.map { RecordingDevicePage.resolve($0) }

        case "a stored-file device is discovered attached displayed disconnected and reconnected":
            let spy = StoredFileLiveBoundarySpy()
            StoredFileDeviceLifecycle.runFullLinkLifecycle(liveBoundaries: spy)
            liveEffects = spy.counts

        case "the account's remembered devices are read back":
            remembered = UnifiedDeviceListComposition.rememberedForCurrentAccount(
                defaults: legacyDefaults)
            rows = UnifiedDeviceListPresentation.rows(
                UnifiedDeviceListComposition.inputs(remembered: remembered, captureSources: []))

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    // MARK: Then

    func then(_ phrase: String) throws {
        switch phrase {
        case "the rows read in name order rather than in shape order":
            XCTAssertEqual(rows.map(\.displayName),
                           [Self.headsetName, Self.handsetName, Self.omiName, Self.pocketName],
                           "the list is not in the shipped merge() order. It must read "
                               + "AirPods, iPhone, Omi, PKT01 — not wearables first, and not "
                               + "vendors first")
            // A CLASS CANNOT PROMOTE OR DEMOTE A DEVICE. The same four devices with the
            // record-then-sync one renamed must put it FIRST — which no grouping by class or
            // by shape can produce.
            let renamed = UnifiedDeviceListPresentation.rows(
                try fourDeviceFixture(pocketName: "Aeon Recorder"))
            XCTAssertEqual(renamed.first?.displayName, "Aeon Recorder",
                           "renaming the record-then-sync device did not move it — its "
                               + "position is coming from its class or its shape, which is "
                               + "\"one list, vendors first\" wearing a different hat")

        case "every row uses the same grammar of a name and a class and a state":
            XCTAssertFalse(rows.isEmpty, "no rows at all — every claim below is vacuous")
            for row in rows {
                XCTAssertFalse(row.displayName.isEmpty, "a row rendered no name")
                XCTAssertTrue(
                    row.detailLine.hasPrefix(
                        row.classCaption + UnifiedDeviceListPresentation.separator),
                    "\"\(row.detailLine)\" does not read `<class> · <state>` — the row grammar "
                        + "is the same for all four shapes or it is not one list")
                XCTAssertFalse(row.state.isEmpty, "\(row.displayName) rendered no state")
            }
            XCTAssertEqual(Set(rows.map(\.classCaption)).count, 2,
                           "the fixture is degenerate — every row shares one class, so the "
                               + "grammar claim above proves nothing about the split")

        case "grouping those same devices by shape would produce a different list":
            let shapeFirst = rows.sorted { left, right in
                let leftShape = RecordingDeviceShape.allCases.firstIndex(of: left.identity.shape) ?? 0
                let rightShape = RecordingDeviceShape.allCases.firstIndex(of: right.identity.shape) ?? 0
                if leftShape != rightShape { return leftShape < rightShape }
                return left.displayName.lowercased() < right.displayName.lowercased()
            }
            XCTAssertNotEqual(shapeFirst.map(\.displayName), rows.map(\.displayName),
                              "shape-first and name-first agree on this fixture, so this "
                                  + "scenario could not tell them apart — the fixture, not the "
                                  + "code, is what is wrong")

        case "the Pocket row reads \"Records on its own · Not connected\"":
            let pocket = try row(shape: .filePull)
            XCTAssertEqual(pocket.detailLine, "Records on its own · Not connected",
                           "the Pocket row reads \"\(pocket.detailLine)\" — a record-then-sync "
                               + "device's line 2 is a fact about the LINK, never about "
                               + "recording")

        case "the Pocket row is not first and not last by virtue of its shape":
            let names = rows.map(\.displayName)
            XCTAssertEqual(names.last, Self.pocketName,
                           "this fixture's Pocket sorts last BY NAME; if it stopped doing so "
                               + "the assertion below is measuring the wrong thing")
            let renamed = UnifiedDeviceListPresentation.rows(
                try fourDeviceFixture(pocketName: "Aeon Recorder"))
            XCTAssertEqual(renamed.map(\.displayName).firstIndex(of: "Aeon Recorder"), 0,
                           "the record-then-sync row's position does not follow its name, so "
                               + "it is following its shape")

        case "its row still reports only whether the link is reachable":
            let pocket = try row(shape: .filePull)
            XCTAssertEqual(pocket.state, RecordingDeviceLinkState.disconnected.label,
                           "handing a record-then-sync device a recording claim changed what "
                               + "its row says. The phone never hears this device live; the "
                               + "builder must discard the claim rather than trust its caller")
            XCTAssertFalse(pocket.detailLine.contains(
                UnifiedDeviceListPresentation.recordingNowState),
                           "\"\(pocket.detailLine)\" claims a recording state")

        case "that row carries no battery value":
            let pocket = try row(shape: .filePull)
            XCTAssertNil(pocket.battery,
                         "an unpaired device rendered the battery value "
                             + "\"\(pocket.battery ?? "")\" — absent is the honest answer")
            XCTAssertFalse(pocket.detailLine.contains("Battery"),
                           "\"\(pocket.detailLine)\" carries a battery clause for a device "
                               + "that has never reported one")

        case "no row anywhere in the list says \"N/A\"":
            for row in rows {
                XCTAssertFalse(row.detailLine.contains("N/A"),
                               "\"\(row.detailLine)\" renders N/A — the `N/A · N/A · N/A` strip "
                                   + "is the exact anti-pattern this list replaces")
                XCTAssertFalse(row.detailLine.contains("0%"),
                               "\"\(row.detailLine)\" renders a zeroed battery")
            }

        case "a device that did report its battery shows the value it reported":
            let omi = try row(shape: .bleStream)
            XCTAssertEqual(omi.battery, "84%",
                           "the device that DID report a battery lost its value — this "
                               + "scenario's other claims are then satisfied by a list that "
                               + "shows nothing at all")
            XCTAssertTrue(omi.detailLine.hasSuffix("Battery 84%"),
                          "\"\(omi.detailLine)\" does not carry the reported battery")

        case "the Settings entry subtitle reads \"3 live, 1 records on its own\"":
            XCTAssertEqual(UnifiedDeviceListPresentation.settingsSubtitle(rows),
                           "3 live, 1 records on its own",
                           "the Settings subtitle must count CLASSES. The shipped one read "
                               + "\"Omi connected\" — a vendor name hardcoded into the one "
                               + "line a user reads before opening the page")

        case "that subtitle contains no vendor name":
            let subtitle = UnifiedDeviceListPresentation.settingsSubtitle(rows)
            for vendor in ["Omi", "Pocket", "AirPods", "PKT", "Apple", "iPhone"] {
                XCTAssertFalse(subtitle.localizedCaseInsensitiveContains(vendor),
                               "the subtitle \"\(subtitle)\" names \(vendor)")
            }

        case "the page carries the recorder-light sentence where a live device carries record and stop":
            let page = try requirePage()
            XCTAssertEqual(page.recordingIndicatorSentence,
                           RecordingDevicePage.recorderIndicatorSentence,
                           "the band a live device fills with record/stop is blank. The design's "
                               + "rule is that the empty space is occupied by the true fact")
            XCTAssertTrue(page.recordingIndicatorSentence?.contains("solid amber means recording")
                              ?? false,
                          "the sentence no longer names the only recording indicator there is")
            XCTAssertEqual(page.classCaption, RecordingDeviceClass.recordThenSync.caption)
            XCTAssertEqual(page.status, RecordingDeviceLinkState.disconnected.label)

        case "the page offers no record or stop control":
            let page = try requirePage()
            XCTAssertFalse(page.showsRecordControl,
                           "a record-then-sync device page offers a record/stop control — this "
                               + "iPhone cannot start, stop or observe this recorder")
            XCTAssertFalse(page.showsLiveActivity)
            for action in page.actions {
                for banned in ["Record", "Stop", "Pause"] {
                    XCTAssertFalse(action.hasPrefix(banned),
                                   "the page offers the action \"\(action)\"")
                }
            }
            XCTAssertFalse(RecordingDevicePage.bringOverIsNotOfferedYet,
                           "a bring-over button is being offered. Design §6c: the download "
                               + "path has never run end-to-end, and a button that always "
                               + "fails is worse than an honest absence")

        case "the page never says the device is in range":
            let page = try requirePage()
            let everything = ([page.status, page.classCaption, page.capabilityNote ?? ""]
                              + page.actions
                              + [page.recordingIndicatorSentence ?? ""]).joined(separator: " ")
            for banned in UnifiedDeviceListPresentation.bannedProximityWords {
                XCTAssertFalse(everything.contains(banned),
                               "the page says \"\(banned)\". A BLE peripheral stops "
                                   + "advertising while another app holds it, so a Pocket "
                                   + "sitting on the table would read \"not in range\"")
            }
            XCTAssertEqual(page.capabilityNote, RecordingDevicePage.disconnectedCapabilityNote,
                           "a disconnected page reads Unavailable without saying that the LINK "
                               + "is why — which reads as an accusation about the recorder")

        case "the page's capability strip is battery firmware gap recovery and offline storage":
            let page = try requirePage()
            XCTAssertEqual(page.capabilities.map(\.label),
                           RecordingDeviceConnectPresentation.capabilityLabels,
                           "the strip is not the shipped `capabilityOrder`")
            XCTAssertEqual(page.capabilities.map(\.label),
                           ["Battery", "Firmware", "Gap recovery", "Offline storage"])
            // Offline storage is a CLASS fact and survives the link being down; battery and
            // firmware are live readings and do not.
            XCTAssertEqual(
                page.capabilities.first { $0.label == "Offline storage" }?.value,
                RecordingDeviceConnectPresentation.availableValue)
            XCTAssertEqual(page.capabilities.first { $0.label == "Battery" }?.value,
                           RecordingDeviceConnectPresentation.unavailableValue,
                           "a battery nobody read rendered as something other than the shipped "
                               + "unavailable word — `N/A` is the value this replaces")

        case "the page's capability strip has no signal column":
            let page = try requirePage()
            XCTAssertFalse(page.capabilities.contains { $0.label == "Signal" },
                           "Signal is an RSSI word meaningful only while streaming, so it "
                               + "cannot appear for a device this phone never streams from")
            XCTAssertFalse(page.capabilities.contains { $0.value == "N/A" },
                           "the strip renders N/A")

        case "its education comes from the protocol it speaks and not from its shape":
            let page = try requirePage()
            XCTAssertTrue(page.actions.contains(RecordingDevicePage.educationAction),
                          "a recorder whose negotiated protocol HAS an education bundle was "
                              + "offered none — the claims below would then be vacuous")
            // THE SUBSTITUTION, WHICH IS THE WHOLE POINT OF §5. The same shape, the same
            // class, a different protocol — and no education, because this build knows
            // nothing true about that device's buttons or lights.
            let other = RecordingDeviceListInput(
                identity: RecordingDeviceIdentity(shape: .filePull,
                                                  hardwareToken: "aeon-recorder-1"),
                displayName: "Aeon Recorder",
                declaredCapabilities: [
                    RecordingDeviceCapabilityKey.offlineStorage.rawValue: String?.none,
                ],
                isRemembered: true,
                negotiatedProtocol: "aeon-stored-file/v1")
            let otherPage = RecordingDevicePage.resolve(other)
            XCTAssertFalse(otherPage.actions.contains(RecordingDevicePage.educationAction),
                           "a second record-then-sync device inherited the first one's "
                               + "education. Its light means something else, or it has no "
                               + "light — education attaches to the PROTOCOL the transport "
                               + "client negotiated, never to the shape")
            XCTAssertNil(RecordingDeviceEducationCatalog.bundle(for: nil),
                         "a device nothing has ever connected to was handed an education "
                             + "bundle — no protocol has been established for it")

        case "neither page renders a capability it can never fill":
            XCTAssertEqual(pages.count, 2,
                           "the fixture is not the handset microphone plus one route")
            for page in pages {
                XCTAssertEqual(page.capabilities.map(\.label), [],
                               "\(page.displayName) renders "
                                   + "\(page.capabilities.map { "\($0.label) \($0.value)" }) — a "
                                   + "phone microphone and a Bluetooth route have no battery, "
                                   + "no firmware, no gap recovery and no offline storage, and "
                                   + "four rows of \"Unavailable\" for them is `N/A · N/A · "
                                   + "N/A` in the shipped word")
                XCTAssertNil(page.capabilityNote,
                             "\(page.displayName) explains an Unavailable it does not render, "
                                 + "with copy written for a recorder's resting state")
            }

        case "neither page offers to forget a device the account does not remember":
            for page in pages {
                XCTAssertFalse(page.actions.contains(RecordingDevicePage.forgetAction),
                               "\(page.displayName) offers \"Forget this recorder\" for a "
                                   + "device that came from the handset's own registry — the "
                                   + "store has no record to remove, so the confirmation is "
                                   + "destructive-sounding and then a no-op")
                XCTAssertNil(page.forgetWarning)
            }

        case "a remembered live device is offered forget without a claim about a key":
            let remembered = UnifiedDeviceListComposition.inputs(
                remembered: [RecordingDeviceRecord(identity: Self.omiIdentity,
                                                   displayName: Self.omiName)],
                captureSources: [])
            guard let input = remembered.first else {
                throw BrineStepError("the remembered fixture produced no input")
            }
            let page = RecordingDevicePage.resolve(input)
            XCTAssertTrue(page.actions.contains(RecordingDevicePage.forgetAction),
                          "a device the account DOES remember cannot be forgotten — the "
                              + "absence claims above are then satisfied by forbidding it "
                              + "everywhere")
            XCTAssertEqual(page.forgetWarning, RecordingDevicePage.liveForgetWarning)
            XCTAssertFalse(page.forgetWarning?.contains("key") ?? true,
                           "the warning for a live device claims FoundryX holds a key for it: "
                               + "\"\(page.forgetWarning ?? "")\"")
            XCTAssertTrue(RecordingDevicePage.forgetWarning.contains("key"),
                          "the record-then-sync warning stopped naming the key, so the claim "
                              + "above proves nothing")

        case "its class may not contribute a Live Activity in any state":
            XCTAssertFalse(RecordingDeviceClass.recordThenSync.mayContributeLiveSurface,
                           "a record-then-sync device may reach a Live Activity, Dynamic "
                               + "Island, pill or lock screen. A file transfer is not a "
                               + "recording and must never be dressed as one — in any state, "
                               + "including mid-sync")
            let drawn = UnifiedDeviceListPresentation.rows(inputs)
            XCTAssertEqual(drawn.filter { $0.contributesLiveSurface }.map(\.displayName), [],
                           "a record-then-sync row claims a live surface")
            XCTAssertFalse(drawn.isEmpty, "no rows at all — the claim above is vacuous")

        case "a live device's class may":
            XCTAssertTrue(RecordingDeviceClass.live.mayContributeLiveSurface,
                          "no class may contribute a live surface, so the claim above is "
                              + "vacuous")

        case "no active source FrameRouter WAL Live Activity or live state mutation occurs":
            XCTAssertEqual(liveEffects, .zero,
                           "a stored-file device's whole link lifecycle touched a live capture "
                               + "boundary")

        case "the affordance is titled \"Connect a recording device\"":
            XCTAssertEqual(RecordingDeviceConnectPresentation.affordanceTitle,
                           "Connect a recording device")

        case "the list is titled \"Recording devices\"":
            XCTAssertEqual(RecordingDeviceConnectPresentation.listTitle, "Recording devices")

        case "the scanning and empty lines name no vendor":
            for line in RecordingDeviceConnectPresentation.genericCopy {
                for vendor in ["Omi", "Pocket", "AirPods", "Bluetooth"] {
                    XCTAssertFalse(line.localizedCaseInsensitiveContains(vendor),
                                   "the generic line \"\(line)\" names \(vendor)")
                }
            }
            XCTAssertEqual(RecordingDeviceConnectPresentation.scanningLine,
                           "Looking for recording devices…")
            XCTAssertEqual(RecordingDeviceConnectPresentation.emptyLine,
                           "No recording devices found yet. Put yours in pairing mode.")
            // A device that advertises no name (design §3.1, T3 req 8). It is a SHIPPED
            // constant rather than a literal in the view because `App/`'s copy is scanned by
            // the voice-notes language guard, which retires "recording" from app literals —
            // and a scan row typed straight into the view is how that guard reds.
            XCTAssertEqual(RecordingDeviceConnectPresentation.unnamedDeviceName,
                           "Unnamed recording device")
            XCTAssertTrue(RecordingDeviceConnectPresentation.genericCopy
                              .contains(RecordingDeviceConnectPresentation.unnamedDeviceName),
                          "the unnamed-device name escapes the population the brand-free "
                              + "assertion is held over")

        case "the education line above the list explains the one distinction the list is organised by":
            XCTAssertEqual(UnifiedDeviceListPresentation.educationLead,
                           "Some devices record with your phone. Some record on their own.")
            XCTAssertEqual(UnifiedDeviceListPresentation.educationLink, "What's the difference?")
            for vendor in ["Omi", "Pocket"] {
                XCTAssertFalse(
                    UnifiedDeviceListPresentation.educationLead
                        .localizedCaseInsensitiveContains(vendor),
                    "the education line names \(vendor) — the distinction is a class, not a brand")
            }

        case "that link opens the class explanation rather than one device's light":
            // A QUESTION ABOUT CLASSES GETS THE CLASS ANSWER. The link used to open one
            // vendor's LED legend — "Solid amber — Recording, Blue — Connected" — so a person
            // with only an Omi and an iPhone asked what the difference was and was taught
            // another company's hardware.
            XCTAssertEqual(RecordingDeviceClassExplanation.sections.map(\.title),
                           [RecordingDeviceClass.live.caption,
                            RecordingDeviceClass.recordThenSync.caption],
                           "the explanation is not organised by the two classes the list is")
            for line in RecordingDeviceClassExplanation.everyLine {
                for vendor in ["Omi", "Pocket", "AirPods", "PKT"] {
                    XCTAssertFalse(line.localizedCaseInsensitiveContains(vendor),
                                   "the class explanation names \(vendor): \"\(line)\"")
                }
                XCTAssertFalse(line.contains("amber"),
                               "the class explanation teaches a device's light legend: "
                                   + "\"\(line)\"")
            }
            let screen = try Self.deviceScreenCode()
            XCTAssertTrue(screen.contains("RecordingDeviceClassExplanationView"),
                          "App/DeviceScreen.swift no longer renders the class explanation "
                              + "behind \"\(UnifiedDeviceListPresentation.educationLink)\"")
            XCTAssertFalse(screen.contains("PocketDeviceEducation"),
                           "the list header reaches one vendor's education content directly")

        case "the app presents the recorder setup screen from the connect affordance":
            // `swift test` CANNOT COMPILE `App/`, so a presenter that is deleted compiles
            // fine and every value-level claim above stays green. `PocketOnboardingView`
            // shipped exactly that way: orphaned, with no reference anywhere in the tree.
            // This scenario reads the file instead.
            let code = try Self.deviceScreenCode()
            XCTAssertTrue(code.contains("PocketOnboardingView(screen: .setupUnavailable)"),
                          "App/DeviceScreen.swift no longer presents the recorder setup "
                              + "ceremony — the view goes back to being orphaned, which is "
                              + "the defect this track exists to fix")
            XCTAssertTrue(code.contains("RecordingDeviceConnectPresentation.affordanceTitle"),
                          "the one connection affordance is no longer titled from the shipped "
                              + "constant")
            XCTAssertTrue(code.contains("RecordingDeviceConnectPresentation.setupHelpLink"),
                          "nothing in the connect sheet answers the question a person whose "
                              + "recorder never appears actually has")
            let presenters = try AppSourceTree.filesReferencing("PocketOnboardingView")
            XCTAssertTrue(presenters.contains("App/DeviceScreen.swift"),
                          "no App-side file outside PocketOnboardingView.swift references it "
                              + "— referencing files: \(presenters)")

        case "no branded setup row is pinned above whatever answered the scan":
            let code = try Self.deviceScreenCode()
            // The row that was pinned first in the connect list, by literal and by the
            // constant that supplied it.
            XCTAssertFalse(code.contains("PocketSetupPresentation.setup.title"),
                           "a branded setup row is back above the scan results. Design §3.1 "
                               + "draws two rows that read identically because the app "
                               + "genuinely knows nothing but the broadcast name, and a brand "
                               + "name above a person's own device is \"vendors first\"")
            XCTAssertFalse(code.contains("RecordingDeviceClass.recordThenSync.caption"),
                           "a class caption is being asserted for a device the app has never "
                               + "connected to — class appears the moment the transport "
                               + "establishes which protocol a device speaks, not before")
            XCTAssertEqual(RecordingDeviceConnectPresentation.connectSheetTitle,
                           "Connect a device",
                           "the affordance's destination is not titled as the design draws it")
            XCTAssertNotEqual(RecordingDeviceConnectPresentation.connectSheetTitle,
                              RecordingDeviceConnectPresentation.listTitle,
                              "the list title and the sheet title are the same string again — "
                                  + "they shipped swapped")
            XCTAssertTrue(code.contains("RecordingDeviceConnectPresentation.connectSheetTitle"),
                          "the connect sheet no longer wears its own title")
            XCTAssertTrue(
                try AppSourceTree.filesContaining("RecordingDeviceConnectPresentation.listTitle")
                    .contains("App/SettingsScreen.swift"),
                "the one list is not titled from the shipped `listTitle` — the screen Nick "
                    + "opens is still hardcoded")

        case "the Pocket is remembered under its stored-file identity":
            let identity = try Self.pocketIdentity
            XCTAssertEqual(identity.shape, .filePull)
            guard case .recorded = adoption else {
                throw BrineStepError(
                    "the record under test was not written by `RecordingDeviceAdoption` — "
                        + "the only thing that makes this scenario evidence about the app "
                        + "rather than about the test: \(String(describing: adoption))")
            }
            XCTAssertTrue(remembered.contains { $0.identity == identity },
                          "the account does not remember the Pocket it paired — remembered: "
                              + "\(remembered.map(\.displayName))")
            XCTAssertFalse(identity.storageKey.contains("PKT01"),
                           "the advertised name leaked into the durable identity")

        case "the redrawn list shows it as a peer row reading \"Records on its own · Not connected\"":
            XCTAssertEqual(rows.map(\.detailLine), ["Records on its own · Not connected"],
                           "a relaunch did not redraw the remembered Pocket as a peer row")
            XCTAssertEqual(rows.first?.displayName, Self.pocketName)

        // ── the app's own chain, tap to row ──────────────────────────────────
        case "the transport client established which protocol that device speaks":
            guard case .adopted(let identity, let displayName, let negotiated) = attachOutcome
            else {
                throw BrineStepError(
                    "the tap did not adopt the recorder — it returned "
                        + "\(String(describing: attachOutcome)). This is the whole point of "
                        + "the scenario: `RecordingDeviceAdoption.remember` had no caller "
                        + "outside Tests/, so no discovered device could ever become a row")
            }
            XCTAssertEqual(identity.shape, .filePull,
                           "the app adopted the recorder under the wrong shape, so the list "
                               + "would caption it as a live device")
            XCTAssertEqual(identity.hardwareToken,
                           Self.pocketPeripheralId.uuidString.lowercased(),
                           "the durable address is not the authenticated peripheral token")
            XCTAssertEqual(displayName, Self.pocketName)
            XCTAssertEqual(negotiated, PocketRecordingDeviceBridge.protocolIdentifier,
                           "class and education attach to the protocol the transport "
                               + "NEGOTIATED (design §5) — nothing else may supply it")

        case "FoundryX authenticated it and read its battery and firmware over the radio seam":
            guard let stack = attachStack else {
                throw BrineStepError("no discovered recorder was staged")
            }
            let commands = stack.commandsWritten
            XCTAssertTrue(commands.contains { $0.hasPrefix("SK&") },
                          "no authentication was ever written to the recorder, so whatever "
                              + "produced the row above did not come from the protocol: "
                              + "\(commands)")
            XCTAssertTrue(commands.contains("BAT") && commands.contains("FW"),
                          "the discovery bridge never asked the device for the only two facts "
                              + "it is allowed to ask for: \(commands)")
            XCTAssertFalse(commands.contains("SPACE") || commands.contains("STE"),
                           "this path asked for SPACE/STE — the bridge is documented as "
                               + "neither querying nor interpreting them: \(commands)")
            XCTAssertFalse(stack.isConnected,
                           "the probe left its own link up after adopting — a connect probe "
                               + "must not sit on the radio a person is no longer looking at")

        case "the app says setup isn't available yet instead of adding a row":
            XCTAssertEqual(attachOutcome, .setupUnavailable,
                           "a recorder FoundryX holds no key for produced "
                               + "\(String(describing: attachOutcome)). Minting a key is "
                               + "gated by design §3.6 / T2 req 3, and the honest answer is "
                               + "the setup screen — not a row, and not silence")
            XCTAssertNil(RecordingDeviceAttachPresentation.inlineMessage(for: .setupUnavailable),
                         "the gap is being reported as a one-line aside rather than as the "
                             + "screen that explains it")
            XCTAssertTrue(PocketSetupPresentation.setupUnavailable.body.contains("sent it nothing"),
                          "the screen this outcome lands on no longer says the one thing that "
                              + "is knowable about the recorder")

        case "FoundryX sent that recorder nothing at all":
            guard let stack = attachStack else {
                throw BrineStepError("no discovered recorder was staged")
            }
            XCTAssertEqual(stack.commandsWritten, [],
                           "\"Your recorder is untouched. FoundryX sent it nothing\" is a "
                               + "claim on the §3.6 screen, and this path wrote "
                               + "\(stack.commandsWritten) to the device")

        case "the account does not remember that recorder":
            let unprovisioned = try PocketAuthenticatedIdentity(
                peripheralIdentifier: Self.unprovisionedPeripheralId.uuidString)
                .recordingDeviceIdentity
            let records = UnifiedDeviceListComposition.rememberedForCurrentAccount(
                defaults: legacyDefaults)
            XCTAssertFalse(records.contains { $0.identity == unprovisioned },
                           "a recorder FoundryX cannot attach was remembered anyway — the "
                               + "list would draw a device no connect action can ever reach")

        // ── the scan ────────────────────────────────────────────────────────
        case "the scan carries no service filter at all":
            guard let observed = scanStack?.observedScanServiceFilter else {
                throw BrineStepError("the pairing gesture never issued a scan at all")
            }
            XCTAssertNil(observed,
                         "the pairing scan still asks CoreBluetooth for "
                             + "\(String(describing: observed)). A filtered scan is answered "
                             + "only by devices advertising that service, so the brand-free "
                             + "connect list was one vendor's list by construction")

        case "a device advertising no live-audio service still answers it and appears in the list":
            guard let stack = scanStack, let device = scanDevice else {
                throw BrineStepError("no pairing scan was staged")
            }
            XCTAssertFalse(stack.peripheral.advertisedServiceUUIDs.contains(OmiUUID.audioService),
                           "the fixture advertises the live-audio service, so it would answer "
                               + "the old filtered scan too and this scenario proves nothing")
            XCTAssertEqual(scanAnswered, true,
                           "the recorder did not answer the scan the app actually issued")
            XCTAssertTrue(device.discovered.contains { $0.id == stack.deviceId },
                          "the device answered the scan and never reached the list: "
                              + "\(device.discovered.map(\.name))")

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    // MARK: helpers

    private func row(shape: RecordingDeviceShape) throws -> UnifiedDeviceRow {
        guard let row = rows.first(where: { $0.identity.shape == shape }) else {
            throw BrineStepError("no \(shape) row in the drawn list: "
                                     + "\(rows.map(\.displayName))")
        }
        return row
    }

    private func requirePage() throws -> RecordingDevicePagePresentation {
        guard let page else { throw BrineStepError("no device page was built") }
        return page
    }

    /// `App/DeviceScreen.swift` with comments stripped and string literals kept — the same
    /// walk every other App-side gate in this suite uses.
    fileprivate static func deviceScreenCode() throws -> String {
        let url = AppSourceTree.repoRoot.appendingPathComponent("App/DeviceScreen.swift")
        return AppSourceTree.withoutComments(
            of: try String(contentsOf: url, encoding: .utf8))
    }
}

// MARK: - The transport the protocol client is driven over

/// A fake `PocketBLETransport` that replays control frames. A hermetic suite cannot own a
/// radio; everything above the radio — the characteristic map, the authentication handshake,
/// the battery and firmware reads, the observation, the adoption and the store — is real.
private actor UnifiedDeviceListFakeTransport: PocketBLETransport {
    private var controls: [String]
    init(controls: [String]) { self.controls = controls }

    func availableCharacteristics() async throws -> Set<String> {
        PocketCharacteristicMap.primary.required
    }

    func write(_ data: Data, to characteristic: String) async throws {}

    func nextEvent(generation: UInt64) async throws -> PocketTransportEvent {
        guard !controls.isEmpty else { throw PocketTransportFailure.timeout }
        return .control(Data(controls.removeFirst().utf8), generation: 1)
    }

    func close() async {}
}
