import XCTest
import BrineSwiftCore
@testable import FoundryXKit

final class PocketFilePullDeviceFeatureTests: XCTestCase {
    func testPocketFilePullDeviceFeature() async throws {
        let world = PocketFilePullWorld()
        let result = try await BrineFeatureRunner.run(
            "pocket-file-pull-device",
            registry: StepRegistry(PocketFilePullSteps.make(world)))
        XCTAssertEqual(result.passed, 6)
    }
}

private enum PocketFilePullSteps {
    static func make(_ world: PocketFilePullWorld) -> [StepDefinition] {
        let givens = [
            "an authenticated stored-file recorder without a live audio profile",
            "a provisioned recorder identity and its persisted public lookup components",
            "an authenticated Pocket transport reporting battery and firmware",
            "a connected stored-file recorder with battery and firmware facts",
            "recorder files that FoundryX has and files only on the recorder",
            "spies around every live capture boundary"
        ]
        let whens = [
            "the recording source catalog evaluates it",
            "the device list reconstructs the identity without the session secret",
            "the Pocket discovery bridge observes the device",
            "the device page presentation is built",
            "the storage manifest presentation is built",
            "a stored-file device is discovered attached displayed disconnected and reconnected"
        ]
        let thens = [
            "it selects stored-file sync and is usable for later file access",
            "it is excluded from live source candidates",
            "its device-list identity and secret-storage key are identical",
            "its advertised name is absent from that identity",
            "the one device list contains its friendly row with literal battery and firmware",
            "offline storage is present without exposing the uncalibrated storage pair",
            "its hero reports the link as connected with battery and firmware",
            "no recording pill, recording state, or Live Activity surface is present",
            "each recording shows its custody and duration at 32 kilobits per second",
            "no active source FrameRouter WAL Live Activity or live state mutation occurs"
        ]
        var steps = givens.map { phrase in defineStep(phrase) { context, _, _ in await world.given(phrase); return context } }
        steps += whens.map { phrase in defineStep(phrase) { context, _, _ in try await world.when(phrase); return context } }
        steps += thens.map { phrase in defineCheck(phrase) { _, _, _ in try await world.then(phrase) } }
        return steps
    }
}

private actor PocketFilePullWorld {
    private let secret = "A!b2-C_d.E?9+x=Z"
    private var entry: RecordingDeviceEntry?
    private var identity: PocketAuthenticatedIdentity?
    private var observed: RecordingDeviceObservation?
    private var detail: StoredFileDeviceDetailPresentation?
    private var manifest: StoredFileManifestPresentation?
    private var effects: StoredFileLiveEffectCounts?

    func given(_ phrase: String) async {
        entry = nil; identity = nil; observed = nil; detail = nil; manifest = nil; effects = nil
    }

    func when(_ phrase: String) async throws {
        switch phrase {
        case "the recording source catalog evaluates it":
            entry = RecordingSourceCatalog.evaluate(.init(
                identity: .init(shape: .filePull, hardwareToken: "peripheral/fingerprint"),
                reportedName: "Pocket", audioProfile: nil,
                declaredCapabilities: [RecordingDeviceCapabilityKey.offlineStorage.rawValue: nil]))
        case "the device list reconstructs the identity without the session secret":
            let provisioned = try PocketAuthenticatedIdentity(peripheralIdentifier: "ABC", sessionSecret: secret)
            identity = try PocketAuthenticatedIdentity(
                peripheralIdentifier: provisioned.peripheralIdentifier,
                sessionKeyFingerprint: provisioned.sessionKeyFingerprint)
        case "the Pocket discovery bridge observes the device":
            let transport = FilePullFakeTransport(actions: ["MCU&SK&OK", "MCU&BAT&72", "MCU&FW&1.6"])
            let client = try await PocketBLEClient.connect(transport: transport)
            try await client.authenticate(secret: secret)
            let auth = try PocketAuthenticatedIdentity(peripheralIdentifier: "ABC", sessionSecret: secret)
            observed = await PocketRecordingDeviceBridge.observe(
                client: client, identity: auth, advertisedName: " PKT01_BLUE_26079bc5 ")
        case "the device page presentation is built":
            detail = StoredFileDevicePresentation.detail(
                name: "Pocket", link: .connected, battery: .reported("72%"),
                firmware: .reported("1.6"), manifest: [])
        case "the storage manifest presentation is built":
            manifest = StoredFileDevicePresentation.manifest([
                .init(id: "a", title: "Walkthrough", sizeBytes: 88_000, custody: .foundryX),
                .init(id: "b", title: "Wed 4:02 PM", sizeBytes: 48_000, custody: .recorderOnly)
            ])
        case "a stored-file device is discovered attached displayed disconnected and reconnected":
            let spy = StoredFileLiveBoundarySpy()
            StoredFileDeviceLifecycle.runFullLinkLifecycle(liveBoundaries: spy)
            effects = spy.counts
        default: break
        }
    }

    func then(_ phrase: String) async throws {
        switch phrase {
        case "it selects stored-file sync and is usable for later file access":
            XCTAssertEqual(entry?.adapter, .storedFileSync); XCTAssertEqual(entry?.isStoredFileUsable, true)
        case "it is excluded from live source candidates": XCTAssertEqual(entry?.isLiveSourceCandidate, false)
        case "its device-list identity and secret-storage key are identical":
            XCTAssertEqual(identity?.recordingDeviceIdentity.storageKey, identity?.storageKey)
        case "its advertised name is absent from that identity": XCTAssertFalse(identity?.storageKey.contains("PKT01") ?? true)
        case "the one device list contains its friendly row with literal battery and firmware":
            let row = observed.map(RecordingSourceCatalog.evaluate)
            XCTAssertEqual(row?.displayName, "PKT01_BLUE_26079bc5")
            XCTAssertEqual(row?.capabilities.state(of: .batteryLevel), .reported("72%"))
            XCTAssertEqual(row?.capabilities.state(of: .firmwareVersion), .reported("1.6"))
        case "offline storage is present without exposing the uncalibrated storage pair":
            XCTAssertEqual(observed?.declaredCapabilities[RecordingDeviceCapabilityKey.offlineStorage.rawValue]!, nil)
            XCTAssertEqual(observed?.declaredCapabilities.keys.sorted(), ["battery-level", "firmware-version", "offline-storage"])
        case "its hero reports the link as connected with battery and firmware":
            XCTAssertEqual(detail?.linkLabel, "Connected"); XCTAssertEqual(detail?.battery, "72%"); XCTAssertEqual(detail?.firmware, "1.6")
        case "no recording pill, recording state, or Live Activity surface is present":
            XCTAssertEqual(detail?.showsRecordingState, false); XCTAssertEqual(detail?.showsLiveActivity, false)
        case "each recording shows its custody and duration at 32 kilobits per second":
            XCTAssertEqual(manifest?.rows.map(\.duration), ["22 sec", "12 sec"])
            XCTAssertEqual(manifest?.rows.map(\.custodyLabel), ["In FoundryX", "Only on the recorder"])
        case "no active source FrameRouter WAL Live Activity or live state mutation occurs":
            XCTAssertEqual(effects, .zero)
        default: XCTFail("Unhandled assertion: \(phrase)")
        }
    }
}

private actor FilePullFakeTransport: PocketBLETransport {
    var actions: [String]
    init(actions: [String]) { self.actions = actions }
    func availableCharacteristics() async throws -> Set<String> { PocketCharacteristicMap.primary.required }
    func write(_ data: Data, to characteristic: String) async throws {}
    func nextEvent(generation: UInt64) async throws -> PocketTransportEvent {
        guard !actions.isEmpty else { throw PocketTransportFailure.timeout }
        return .control(Data(actions.removeFirst().utf8), generation: generation)
    }
    func close() async {}
}
