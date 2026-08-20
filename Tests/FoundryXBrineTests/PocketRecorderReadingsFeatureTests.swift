import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// features/pocket-recorder-readings.feature — Step 7 of the pocket delivery plan.
///
/// THESE STEPS DRIVE THE SHIPPED OBJECTS, NOT DOUBLES OF THEM. The only thing faked is the
/// radio: a scripted `PocketBLETransport` handing back the frames a real Pocket answers with.
/// Everything above it is production code — the real `PocketBLEClient` codec, the real
/// `PocketRecordingDeviceBridge`, the real account-scoped `RecordingDeviceStore` writing to a
/// real file on disk, the real `UnifiedDeviceListComposition` projection, and the real
/// `RecordingDevicePage`.
///
/// `ProcessGlobalStateTestCase` AND NOT `XCTestCase`. These steps sign an account in, which
/// moves `CaptureAccountScope` — a PROCESS-GLOBAL. Run as a bare `XCTestCase` this suite left
/// the scope pointing at its own throwaway account for everything that ran after it: a single
/// `swift test` went from 12 failures to 58, in suites that have nothing to do with recorders
/// (`CaptureResync*`, `OmiReconnect*`, `ChatSessionTests`). The base class sandboxes the
/// container and puts the process back afterwards.
final class PocketRecorderReadingsFeatureTests: ProcessGlobalStateTestCase {
    func testPocketRecorderReadingsFeature() async throws {
        let world = ReadingsWorld()
        let result = try await BrineFeatureRunner.run(
            "pocket-recorder-readings",
            registry: StepRegistry(ReadingsSteps.make(world)))
        XCTAssertEqual(result.passed, 4)
    }
}

private enum ReadingsSteps {
    static func make(_ world: ReadingsWorld) -> [StepDefinition] {
        let givens = [
            "a recorder whose battery and free space were read twenty minutes ago",
            "whose firmware has never been asked",
            "a remembered recorder that reports its charge, its firmware and how full it is",
            "a recorder whose battery was read an hour ago",
            "a remembered recorder nobody has ever checked",
        ]
        let whens = [
            "I open that recorder's page",
            "Solleva checks that recorder",
            "Solleva checks that recorder and the recorder answers nothing",
        ]
        let thens = [
            "the battery and the free space each show a number and how long ago it was read",
            "the firmware shows no number and offers the action that would ask",
            "nothing on that page reads \"Unavailable\" or \"N/A\"",
            "what the recorder said is kept against that recorder, each fact with the moment it was read",
            "how full it is is a number, and the number came off the recorder",
            "the battery still shows the hour-old number, and still says it is an hour old",
            "no fact was replaced by a fresher-looking guess",
            "every fact shows no number and offers the action that would ask",
        ]
        var steps = givens.map { phrase in
            defineStep(phrase) { context, _, _ in try await world.given(phrase); return context }
        }
        steps += whens.map { phrase in
            defineStep(phrase) { context, _, _ in try await world.when(phrase); return context }
        }
        steps += thens.map { phrase in
            defineCheck(phrase) { _, _, _ in try await world.then(phrase) }
        }
        return steps
    }
}

private actor ReadingsWorld {
    /// The recorder every scenario is about. A `filePull` identity, because that is what makes
    /// a device a record-then-sync recorder rather than something the phone streams from.
    ///
    /// LOWERCASE, BECAUSE `PocketAuthenticatedIdentity` LOWERCASES. The durable address is
    /// `peripheralIdentifier.lowercased()`, so a fixture that seeds the store under the
    /// uppercase UUID CoreBluetooth prints is seeding a different device — the store write
    /// then reports `noMatchingRecord` and the readings go nowhere. That is the shipped
    /// normalisation, and matching it here is the difference between driving it and faking it.
    private static let peripheral = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
    private static let secret = "A!b2-C_d.E?9+x=Z"

    private var store: RecordingDeviceStore?
    private var now = Date(timeIntervalSince1970: 1_770_000_000)
    private var page: RecordingDevicePagePresentation?
    private var observation: RecordingDeviceObservation?
    private var readingsBeforeTheSession: [String: RecordingDeviceReading] = [:]

    private var identity: RecordingDeviceIdentity {
        RecordingDeviceIdentity(shape: .filePull, hardwareToken: Self.peripheral)
    }

    // MARK: Given

    func given(_ phrase: String) throws {
        switch phrase {
        case "a recorder whose battery and free space were read twenty minutes ago":
            try remember(readings: [
                RecordingDeviceCapabilityKey.batteryLevel.rawValue:
                    RecordingDeviceReading(value: "84%",
                                           observedAt: now.addingTimeInterval(-20 * 60)),
                RecordingDeviceCapabilityKey.freeSpace.rawValue:
                    RecordingDeviceReading(value: "25% full",
                                           observedAt: now.addingTimeInterval(-20 * 60)),
            ])

        case "whose firmware has never been asked":
            // A prohibition needs the population it is quantified over. Nothing is seeded
            // here on purpose — this step ASSERTS the absence it names, so the scenario
            // cannot pass because a fixture quietly wrote a firmware nobody asked for.
            let stored = try requireRecord().readings
            XCTAssertNil(stored[RecordingDeviceCapabilityKey.firmwareVersion.rawValue],
                         "the fixture stored a firmware reading, so \"never been asked\" is "
                             + "not the state under test")

        case "a remembered recorder that reports its charge, its firmware and how full it is":
            try remember(readings: [:])

        case "a recorder whose battery was read an hour ago":
            readingsBeforeTheSession = [
                RecordingDeviceCapabilityKey.batteryLevel.rawValue:
                    RecordingDeviceReading(value: "41%",
                                           observedAt: now.addingTimeInterval(-60 * 60)),
            ]
            try remember(readings: readingsBeforeTheSession)

        case "a remembered recorder nobody has ever checked":
            try remember(readings: [:])

        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    // MARK: When

    func when(_ phrase: String) async throws {
        switch phrase {
        case "I open that recorder's page":
            page = try openThePage()

        case "Solleva checks that recorder":
            // THE SHIPPED READ, over the frames a real Pocket answers with. `MCU&SPA&<used>&
            // <total>` is the wire form the protocol client already decodes; the kilobytes
            // are the recorder's own units.
            try await check(answering: ["MCU&SK&OK", "MCU&BAT&64", "MCU&FW&1.6",
                                        "MCU&SPA&2000000&8000000"])

        case "Solleva checks that recorder and the recorder answers nothing":
            // Authenticated, and then silence — every fact read times out. This is the
            // session that must not be allowed to erase what an earlier one learned.
            try await check(answering: ["MCU&SK&OK"])
            page = try openThePage()

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    // MARK: Then

    func then(_ phrase: String) throws {
        switch phrase {
        case "the battery and the free space each show a number and how long ago it was read":
            let page = try requirePage()
            // PAIRED EXISTENCE. The prohibition two steps down passes vacuously on a blank
            // pane, so something real has to render first.
            let battery = try requireLine("Battery", on: page)
            let space = try requireLine("Storage", on: page)
            XCTAssertEqual(battery.value, "84%")
            XCTAssertEqual(space.value, "25% full")
            // AC2: EVERY rendered reading carries its age. Not "the two I remembered to
            // check" — every line on the page that shows a value at all.
            for line in page.readings where line.value != nil {
                XCTAssertNotNil(line.observedAgo,
                                "\(line.label) renders a number with no statement of when it "
                                    + "was read — which is the \"Unavailable\" defect with a "
                                    + "number in it")
            }
            XCTAssertEqual(battery.observedAgo, "read 20 minutes ago")
            XCTAssertEqual(space.observedAgo, "read 20 minutes ago")

        case "the firmware shows no number and offers the action that would ask":
            let page = try requirePage()
            let firmware = try requireLine("Firmware", on: page)
            // AC3: NO NUMBER AND NO PLAUSIBLE DEFAULT. Not "0%", not "—", not the last
            // version some other recorder reported.
            XCTAssertNil(firmware.value,
                         "a firmware nobody has ever asked for rendered \(firmware.value ?? "")")
            XCTAssertNil(firmware.observedAgo,
                         "a fact nobody read claims a moment it was read at")
            XCTAssertEqual(firmware.action, RecordingDevicePage.connectAndCheckAction,
                           "the page states an absence and offers no way to end it")

        case "nothing on that page reads \"Unavailable\" or \"N/A\"":
            let page = try requirePage()
            for banned in [RecordingDeviceConnectPresentation.unavailableValue,
                           DeviceMetricsPresentation.unavailableValue] {
                for line in everyLine(of: page) {
                    XCTAssertFalse(line.contains(banned),
                                   "the recorder's page says \"\(banned)\" in \"\(line)\" — a "
                                       + "word about Solleva dressed as a fact about the "
                                       + "recorder")
                }
            }

        case "what the recorder said is kept against that recorder, each fact with the moment it was read":
            let stored = try requireRecord().readings
            XCTAssertEqual(stored[RecordingDeviceCapabilityKey.batteryLevel.rawValue]?.value,
                           "64%")
            XCTAssertEqual(stored[RecordingDeviceCapabilityKey.firmwareVersion.rawValue]?.value,
                           "1.6")
            XCTAssertEqual(Set(stored.keys),
                           [RecordingDeviceCapabilityKey.batteryLevel.rawValue,
                            RecordingDeviceCapabilityKey.firmwareVersion.rawValue,
                            RecordingDeviceCapabilityKey.freeSpace.rawValue],
                           "the session read facts the account did not keep")
            for (key, reading) in stored {
                XCTAssertEqual(reading.observedAt, now,
                               "\(key) was kept without the moment it was read, or with "
                                   + "somebody else's moment")
            }

        case "how full it is is a number, and the number came off the recorder":
            let stored = try requireRecord().readings
            // A RATIO, AND BOTH SIDES OF IT ARE THE RECORDER'S OWN. It answered 2,000,000
            // used of 8,000,000, so it is a quarter full. THIS USED TO READ "5.7 GB free of
            // 7.6 GB" — an amount, in a unit nobody has resolved. `MCU&SPA` states five-digit
            // figures for a 64 GB recorder, so rendering them as kilobytes put "225 KB free of
            // 57.6 MB" on Nick's screen. The ratio survives not knowing the unit; the amount
            // does not.
            XCTAssertEqual(stored[RecordingDeviceCapabilityKey.freeSpace.rawValue]?.value,
                           "25% full")
            XCTAssertEqual(observation?.readings[
                RecordingDeviceCapabilityKey.freeSpace.rawValue]?.value,
                "25% full",
                "the free-space number was invented downstream of the recorder's answer")

        case "the battery still shows the hour-old number, and still says it is an hour old":
            let page = try requirePage()
            let battery = try requireLine("Battery", on: page)
            XCTAssertEqual(battery.value, "41%",
                           "a session that learned nothing overwrote what an earlier one knew")
            XCTAssertEqual(battery.observedAgo, "read 1 hour ago",
                           "the reading survived but its age was restamped, which makes an "
                               + "hour-old number look like a fresh one")

        case "no fact was replaced by a fresher-looking guess":
            let stored = try requireRecord().readings
            XCTAssertEqual(stored, readingsBeforeTheSession,
                           "a session that read nothing changed what the account holds")

        case "every fact shows no number and offers the action that would ask":
            let page = try requirePage()
            XCTAssertFalse(page.readings.isEmpty,
                           "the page renders no readings at all, so every claim about them "
                               + "below is vacuous")
            for line in page.readings {
                XCTAssertNil(line.value, "\(line.label) invented \(line.value ?? "")")
                XCTAssertNil(line.observedAgo)
                XCTAssertEqual(line.action, RecordingDevicePage.connectAndCheckAction)
            }

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    // MARK: The shipped path, driven

    /// A signed-in account with this recorder in its store — the real store, on real disk.
    private func remember(readings: [String: RecordingDeviceReading]) throws {
        CaptureAccountScope.setAccountForTests(
            email: "readings-\(UUID().uuidString.prefix(8))@example.com")
        guard let store = RecordingDeviceStore.current(),
              store.scope != CaptureAccountScope.signedOutScope else {
            throw BrineStepError("no account scope resolved for the recording-device store")
        }
        self.store = store
        try store.replaceAll([])
        try store.upsert(RecordingDeviceRecord(identity: identity,
                                               displayName: "PKT01_BLUE_26079bc5",
                                               readings: readings))
    }

    /// One authenticated session against a scripted radio, read by the SHIPPED bridge and
    /// kept by the SHIPPED store write.
    private func check(answering frames: [String]) async throws {
        let client = try await PocketBLEClient.connect(
            transport: ReadingsFakeTransport(frames: frames))
        try await client.authenticate(secret: Self.secret)
        let auth = try PocketAuthenticatedIdentity(peripheralIdentifier: Self.peripheral)
        var observed = await PocketRecordingDeviceBridge.observe(
            client: client, identity: auth, advertisedName: "PKT01_BLUE_26079bc5", now: now)
        // FREE SPACE IS A SEPARATE ASK, AND IT IS ASKED LAST — the same sequence the shipped
        // paths use. It left `observe` because `APP&SPACE` runs inside
        // `protected(.information)`, which retires the whole session on a timeout: read before
        // a listing it would take the listing down with it, and the owner would be told the
        // recorder never said what it was holding. This scenario drives the same two calls in
        // the same order the app does rather than modelling one merged one.
        if let space = await PocketRecordingDeviceBridge.storageReading(client: client, now: now) {
            observed = observed.withReading(
                space, for: RecordingDeviceCapabilityKey.freeSpace.rawValue)
        }
        observation = observed
        await client.close()
        switch RecordingDeviceStore.recordObservedFacts(identity: observed.identity,
                                                        readings: observed.readings) {
        case .recorded:
            return
        case .noMatchingRecord(let scope):
            throw BrineStepError("the account (\(scope)) does not remember this recorder")
        case .unavailable(let reason):
            throw BrineStepError("the readings were not kept: \(reason)")
        }
    }

    /// The recorder's own page, composed the way the app composes it: off the store, through
    /// the unified projection, into the page presentation.
    private func openThePage() throws -> RecordingDevicePagePresentation {
        let remembered = try requireStore().records()
        let inputs = UnifiedDeviceListComposition.inputs(remembered: remembered,
                                                         captureSources: [])
        guard let input = inputs.first(where: { $0.identity == identity }) else {
            throw BrineStepError("the projection dropped the recorder the account remembers")
        }
        return RecordingDevicePage.resolve(input, now: now)
    }

    /// Every user-facing string this page can render, so the prohibition is quantified over a
    /// POPULATION rather than over whichever field a test author remembered.
    private func everyLine(of page: RecordingDevicePagePresentation) -> [String] {
        var lines = [page.displayName, page.classCaption, page.status]
        lines += page.actions
        lines += [page.capabilityNote, page.recordingIndicatorSentence, page.forgetWarning]
            .compactMap { $0 }
        lines += page.capabilities.flatMap { [$0.label, $0.value] }
        lines += page.readings.flatMap { [$0.label, $0.value, $0.observedAgo, $0.action] }
            .compactMap { $0 }
        return lines
    }

    private func requireStore() throws -> RecordingDeviceStore {
        guard let store else { throw BrineStepError("no store — the Given did not run") }
        return store
    }

    private func requireRecord() throws -> RecordingDeviceRecord {
        guard let record = try requireStore().records().first(where: { $0.identity == identity })
        else { throw BrineStepError("the account no longer remembers this recorder") }
        return record
    }

    private func requirePage() throws -> RecordingDevicePagePresentation {
        guard let page else { throw BrineStepError("no page — the When did not run") }
        return page
    }

    private func requireLine(_ label: String,
                             on page: RecordingDevicePagePresentation) throws
        -> RecordingDeviceReadingLine {
        guard let line = page.readings.first(where: { $0.label == label }) else {
            throw BrineStepError("the page renders no \"\(label)\" reading — it renders "
                                 + "\(page.readings.map(\.label))")
        }
        return line
    }
}

/// The radio, and nothing else. Frames come back in the order a real Pocket serialises them;
/// when the script runs out the recorder has stopped answering, which is a timeout.
private actor ReadingsFakeTransport: PocketBLETransport {
    private var frames: [String]
    init(frames: [String]) { self.frames = frames }
    func availableCharacteristics() async throws -> Set<String> {
        PocketCharacteristicMap.primary.required
    }
    func write(_ data: Data, to characteristic: String) async throws {}
    func nextEvent(generation: UInt64) async throws -> PocketTransportEvent {
        guard !frames.isEmpty else { throw PocketTransportFailure.timeout }
        return .control(Data(frames.removeFirst().utf8), generation: generation)
    }
    func close() async {}
}
