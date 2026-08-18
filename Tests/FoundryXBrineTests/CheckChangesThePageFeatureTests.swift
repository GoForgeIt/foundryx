import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// features/a-check-changes-the-page-it-was-run-from.feature
///
/// WHAT IS REAL HERE. The radio is the only double: a `FakePocketBLEStack` answering the frames
/// the measured unit answers. Above it the check is the SHIPPED `PocketRecorderCheck.run` — the
/// same call `App/DeviceScreen.swift` makes — writing through the shipped
/// `RecordingDeviceStore.recordObservedFacts` into a real account-scoped store on real disk. The
/// page is the shipped `RecordingDevicePage.resolve`.
///
/// WHY THE PUSHED INPUT IS KEPT SEPARATE FROM THE RENDERED ONE, and it is the whole point of
/// the first scenario. `DeviceScreen.devicePage(for:)` builds the page from a
/// `RecordingDeviceListInput` captured when the row's `NavigationLink` was pushed. A check
/// writes battery, firmware and free space to disk and touches nothing in that value, so the
/// page went on rendering the never-asked state over numbers already on the phone. The world
/// below therefore holds BOTH values and asserts, at the moment the claim is made, that the
/// pushed one is still stale — so the scenario passes because the page re-read what the check
/// wrote, and never because a fixture handed it a fresher snapshot.
///
/// `ProcessGlobalStateTestCase` AND NOT `XCTestCase`: these steps sign an account in, which
/// moves `CaptureAccountScope` — a process global. See `PocketRecorderReadingsFeatureTests`.
final class CheckChangesThePageFeatureTests: ProcessGlobalStateTestCase {
    func testACheckChangesThePageItWasRunFrom() async throws {
        let world = CheckRefreshWorld()
        let result = try await BrineFeatureRunner.run(
            "a-check-changes-the-page-it-was-run-from",
            registry: StepRegistry(CheckRefreshSteps.make(world)))
        XCTAssertEqual(result.passed, 4)
    }
}

private enum CheckRefreshSteps {
    static func make(_ world: CheckRefreshWorld) -> [StepDefinition] {
        let givens = [
            "a remembered recorder nobody has ever checked, with its page open",
            "a recorder that answered twenty minutes ago, with its page open",
        ]
        let whens = [
            "Solleva checks that recorder from that page",
            "a check against that recorder is in flight",
        ]
        let thens = [
            "the battery, the free space and the firmware each show a number and how long ago it was read",
            "no fact on that page still offers the action that would ask",
            "the header says nobody has checked this recorder",
            "the header states no link state",
            "the header says a check is running",
            "the header says the recorder answered twenty minutes ago",
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

private actor CheckRefreshWorld {
    private static let secret = "0123456789abcdef"
    private static let deviceName = "PKT01_BLUE_26079bc5"
    /// What the recorder is holding, so the check reaches its listing and the page it was run
    /// from is the page of a recorder with a shelf on it.
    private static let scripted: [FakePocketBLEStack.ScriptedRecording] = [
        .init(date: "2026-08-07", timestamp: "20260807093015", sizeBytes: 480_000),
        .init(date: "2026-08-11", timestamp: "PH260811175026", sizeBytes: 2_764_000),
    ]

    /// THE VALUE THE NAVIGATION LINK CAPTURED. Never re-derived: a scenario that re-composed
    /// this from the store between the check and the claim would prove nothing at all.
    private var pushedInput: RecordingDeviceListInput?
    /// WHAT THE PAGE RENDERS FROM. Equal to the pushed value until something re-reads.
    private var pageInput: RecordingDeviceListInput?
    private var check: RecordingDeviceCheckState?
    private var now = Date()

    private var store: RecordingDeviceStore?
    private var stack: FakePocketBLEStack?
    private var secrets = InMemoryPocketSecretStore()
    private var peripheral = UUID()
    private var custodyRoots: [URL] = []

    /// The address the SHIPPED check writes readings under: `PocketAuthenticatedIdentity`
    /// lowercases the peripheral identifier, so a store seeded under the uppercase form
    /// `UUID.uuidString` prints is a different device and the write lands nowhere.
    private var identity: RecordingDeviceIdentity {
        RecordingDeviceIdentity(shape: .filePull,
                                hardwareToken: peripheral.uuidString.lowercased())
    }

    // MARK: Given

    func given(_ phrase: String) async throws {
        switch phrase {
        case "a remembered recorder nobody has ever checked, with its page open":
            now = Date()
            try remember(readings: [:])
            try await stageRadio()
            try openThePage()
            // THE STATE UNDER TEST, ASSERTED RATHER THAN ASSUMED. If a fixture ever seeded a
            // reading here, every claim the scenarios make about a check filling these lines
            // would pass for the wrong reason.
            for line in try requirePage().readings {
                guard line.value == nil,
                      line.action == RecordingDevicePage.connectAndCheckAction else {
                    throw BrineStepError(
                        "\(line.label) already carries \(line.value ?? "no number") — so "
                            + "\"nobody has ever checked\" is not the state this scenario "
                            + "runs from")
                }
            }

        case "a recorder that answered twenty minutes ago, with its page open":
            now = Date(timeIntervalSince1970: 1_770_000_000)
            try remember(readings: [
                RecordingDeviceCapabilityKey.batteryLevel.rawValue:
                    RecordingDeviceReading(value: "84%",
                                           observedAt: now.addingTimeInterval(-20 * 60)),
            ])
            try openThePage()

        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    // MARK: When

    func when(_ phrase: String) async throws {
        switch phrase {
        case "Solleva checks that recorder from that page":
            guard let stack else { throw BrineStepError("no recorder was staged") }
            // THE SHIPPED CHECK, on the shipped seam. It is the call that writes the readings
            // (`PocketRecorderCheck` keeps them before it attempts the listing), so nothing in
            // this world puts a number into the store by hand.
            let attachment = RecordingDeviceAttachment(
                makeCentral: stack.factory,
                secrets: secrets,
                recovery: nil,
                deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 5))
            let outcome = await PocketRecorderCheck.run(
                peripheralIdentifier: peripheral,
                advertisedName: Self.deviceName,
                custody: PocketRecorderFileStore(root: custodyRoot()),
                attachment: attachment)
            guard case .checked = outcome else {
                throw BrineStepError("the check never reached the recorder: "
                                     + String(describing: outcome))
            }
            now = Date()
            // WHAT THE PAGE DOES WHEN A CHECK ENDS, and the one line this whole scenario is
            // about. `App/DeviceScreen.swift` runs the same call from the same event; the gate
            // in `DeviceCompositionRootGateTests` is what holds it there.
            let pushed = try requirePushedInput()
            let reRead = RecordingDevicePageFacts.reRead(pushed.identity)
            guard case .refreshed(let found) = reRead else {
                throw BrineStepError(
                    "the re-read did not find this account's facts for the recorder it just "
                        + "checked — it answered \(reRead)")
            }
            pageInput = pushed.withReadings(
                RecordingDevicePageFacts.readings(pushed: pushed.readings, lastRead: found))

        case "a check against that recorder is in flight":
            check = .checking

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    // MARK: Then

    func then(_ phrase: String) throws {
        switch phrase {
        case "the battery, the free space and the firmware each show a number and how long ago it was read":
            // THE PUSHED VALUE IS STILL STALE. Stated here, at the moment of the claim, so the
            // scenario can only pass because the page re-read what the check wrote.
            let asPushed = RecordingDevicePage.resolve(try requirePushedInput(), now: now)
            for line in asPushed.readings where line.value != nil {
                throw BrineStepError(
                    "the value the row was opened with already carries \(line.label) — this "
                        + "scenario is no longer measuring the re-read")
            }

            let page = try requirePage()
            guard page.readings.map(\.label) == RecordingDeviceReadingPresentation.labels else {
                throw BrineStepError("the page renders \(page.readings.map(\.label)) rather "
                                     + "than the recorder's facts")
            }
            for line in page.readings {
                guard line.value != nil else {
                    throw BrineStepError(
                        "\(line.label) is still blank one moment after a check measured it — "
                            + "the number is on this phone's disk and the page never re-read it")
                }
                guard line.observedAgo != nil else {
                    throw BrineStepError("\(line.label) shows a number with no statement of "
                                         + "when it was read")
                }
            }
            // The recorder's own answers, not a plausible default invented downstream.
            let battery = page.readings.first { $0.label == "Battery" }?.value
            let firmware = page.readings.first { $0.label == "Firmware" }?.value
            guard battery == "72%", firmware == "1.6" else {
                throw BrineStepError("the page shows battery \(battery ?? "nothing") and "
                                     + "firmware \(firmware ?? "nothing"), which is not what "
                                     + "this recorder answered")
            }

        case "no fact on that page still offers the action that would ask":
            let page = try requirePage()
            guard !page.readings.isEmpty else {
                throw BrineStepError("the page renders no readings, so this prohibition is "
                                     + "vacuous")
            }
            for line in page.readings {
                guard line.action == nil else {
                    throw BrineStepError("\(line.label) still offers \"\(line.action ?? "")\" "
                                         + "over a fact that was just measured")
                }
            }

        case "the header says nobody has checked this recorder":
            let status = try requirePage().status
            guard status == RecordingDevicePage.neverCheckedStatus else {
                throw BrineStepError("the header reads \"\(status)\" rather than "
                                     + "\"\(RecordingDevicePage.neverCheckedStatus)\"")
            }

        case "the header states no link state":
            let status = try requirePage().status
            for link in [RecordingDeviceLinkState.connected, .reconnecting, .disconnected]
            where status == link.label {
                throw BrineStepError(
                    "the header reads \"\(status)\" — a claim about a live link for a recorder "
                        + "that has none. The check opens its own session and closes it again, "
                        + "so there is no link here for a person to read anything into")
            }

        case "the header says a check is running":
            let status = try requirePage().status
            guard status == RecordingDevicePage.checkingStatus else {
                throw BrineStepError("the header reads \"\(status)\" while a check is on the "
                                     + "line with this recorder")
            }

        case "the header says the recorder answered twenty minutes ago":
            let status = try requirePage().status
            guard status == RecordingDevicePage.answeredStatus("20 minutes ago"),
                  status.contains("20 minutes ago") else {
                throw BrineStepError("the header reads \"\(status)\" and says when nothing")
            }

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    // MARK: The shipped path, driven

    private func remember(readings: [String: RecordingDeviceReading]) throws {
        CaptureAccountScope.setAccountForTests(
            email: "check-refresh-\(UUID().uuidString.prefix(8))@example.com")
        guard let store = RecordingDeviceStore.current(),
              store.scope != CaptureAccountScope.signedOutScope else {
            throw BrineStepError("no account scope resolved for the recording-device store")
        }
        self.store = store
        try store.replaceAll([])
        try store.upsert(RecordingDeviceRecord(identity: identity,
                                               displayName: Self.deviceName,
                                               readings: readings))
    }

    private func stageRadio() async throws {
        secrets = InMemoryPocketSecretStore()
        let made = FakePocketBLEStack(deviceId: peripheral,
                                      deviceName: Self.deviceName,
                                      acceptedSecret: Self.secret,
                                      inventory: Self.scripted)
        stack = made
        try await secrets.save(
            Self.secret,
            for: try PocketAuthenticatedIdentity(peripheralIdentifier: peripheral.uuidString))
    }

    /// The page, composed the way the app composes it: off the account's store, through the
    /// unified projection, into the value a `NavigationLink` would carry.
    private func openThePage() throws {
        let remembered = try requireStore().records()
        let inputs = UnifiedDeviceListComposition.inputs(remembered: remembered,
                                                         captureSources: [])
        guard let input = inputs.first(where: { $0.identity == identity }) else {
            throw BrineStepError("the projection dropped the recorder the account remembers")
        }
        pushedInput = input
        pageInput = input
        check = nil
    }

    private func custodyRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("check-refresh-custody-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        custodyRoots.append(root)
        return root
    }

    private func requireStore() throws -> RecordingDeviceStore {
        guard let store else { throw BrineStepError("no store — the Given did not run") }
        return store
    }

    private func requirePushedInput() throws -> RecordingDeviceListInput {
        guard let pushedInput else { throw BrineStepError("no page — the Given did not run") }
        return pushedInput
    }

    private func requirePage() throws -> RecordingDevicePagePresentation {
        guard let pageInput else { throw BrineStepError("no page — the Given did not run") }
        return RecordingDevicePage.resolve(pageInput, check: check, now: now)
    }
}
