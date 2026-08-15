import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for `features/connect-sheet-says-what-happened.feature`.
///
/// WHAT IS REAL HERE. The shipped `RecordingDeviceScanFilter` and the shipped
/// `RecordingDeviceConnectPresentation` copy the sheet renders 1:1; the shipped
/// `RecordingDeviceAttachment` over the same BLE seam `CoreBluetoothCentral` wraps, so the
/// failure scenarios run the REAL gate/deadline machinery — the real `retrievePeripherals`
/// miss, the real rescan, the real discovery deadline. Injected: the radio, which a hermetic
/// suite cannot own, and (for the adoption case) the secret store.
///
/// THE SCENARIO THAT CARRIES THE MOST WEIGHT IS THE THIRD ONE. `.unreachable` has always
/// carried the reason and the presentation discarded it, so a device this iPhone could not
/// find and a device that connected and stalled in service discovery rendered the same
/// sentence — and that sentence told the owner to move a recorder that was touching the phone.
final class ConnectSheetSaysWhatHappenedFeatureTests: ProcessGlobalStateTestCase {

    @MainActor
    func testConnectSheetSaysWhatHappenedFeature() async throws {
        let world = try ConnectSheetWorld()
        do {
            let result = try await BrineFeatureRunner.run(
                "connect-sheet-says-what-happened",
                registry: StepRegistry(ConnectSheetSteps.make(world: world)))
            // Pin the POPULATION: the runner asserts only that nothing FAILED, so deleting a
            // scenario would otherwise leave this suite green.
            XCTAssertEqual(result.passed, 10,
                           "connect-sheet-says-what-happened must run all 10 scenarios — the "
                               + "two that hold the scan fold (and that it strands nobody), "
                               + "the three that hold one sentence per failure, the one that "
                               + "holds the rescan a lost peripheral now gets, the one "
                               + "that holds the radio being released, and the two that hold "
                               + "the notify-before-write ordering a real recorder depends on, and the one that holds the write MODE it answers")
        } catch {
            world.cleanup()
            throw error
        }
        world.cleanup()
    }

    // MARK: unit — the fold is total, and it can never strand a device

    /// THE PROPERTY THE WHOLE FILTER RESTS ON: no discovered device is ever unreachable.
    ///
    /// Held over a population of lists rather than over the one the feature draws, because the
    /// dangerous case is the one nobody wrote a scenario for — and "hide anything without a
    /// name" is one line of code away from a nameless recorder that can never be paired.
    func testNoDiscoveredDeviceIsEverUnreachableFromTheSheet() {
        let fixtures: [[DiscoveredDevice]] = [
            [],
            [Self.unnamed(-40)],
            [Self.unnamed(-40), Self.unnamed(-50), Self.unnamed(-60)],
            [Self.named("PKT01", -40)],
            [Self.named("PKT01", -40), Self.unnamed(-50)],
            [Self.named("PKT01", -40), Self.named("Omi", -45), Self.unnamed(-50),
             Self.unnamed(-60), Self.unnamed(-70)],
            [Self.named("  ", -40), Self.named("PKT01", -50)],
        ]
        for discovered in fixtures {
            let folded = RecordingDeviceScanFilter.resolve(discovered, showingUnnamed: false)
            let shown = RecordingDeviceScanFilter.resolve(discovered, showingUnnamed: true)
            XCTAssertEqual(Set(shown.visible.map(\.id)), Set(discovered.map(\.id)),
                           "asking to show everything did not show everything — a device the "
                               + "scan found cannot be tapped, which is worse than a busy list")
            XCTAssertEqual(shown.hiddenUnnamedCount, 0,
                           "the sheet claims to be hiding something while showing everything")
            XCTAssertEqual(folded.visible.count + folded.hiddenUnnamedCount, discovered.count,
                           "the fold lost a device: \(folded.visible.count) shown and "
                               + "\(folded.hiddenUnnamedCount) counted out of \(discovered.count)")
            // A ROW THAT IS SHOWN IS ALWAYS TAPPABLE, and the count is always disclosed.
            if folded.hiddenUnnamedCount > 0 {
                XCTAssertFalse(folded.visible.isEmpty,
                               "every row was folded away, so the sheet is empty while devices "
                                   + "are in range — the one outcome this filter may not have")
                XCTAssertNotNil(folded.hiddenLine, "rows were folded with nothing said about it")
            } else {
                XCTAssertNil(folded.hiddenLine, "the sheet discloses a fold that did not happen")
            }
        }
    }

    /// A whitespace-only broadcast name is not a name. `DeviceManager` stores `p.name ?? ""`,
    /// and a device advertising `" "` would otherwise be promoted out of the fold and render
    /// a blank row.
    func testAWhitespaceNameIsNotAName() {
        XCTAssertFalse(RecordingDeviceScanFilter.broadcastsAName(Self.named(" ", -40)))
        XCTAssertFalse(RecordingDeviceScanFilter.broadcastsAName(Self.named("\n", -40)))
        XCTAssertFalse(RecordingDeviceScanFilter.broadcastsAName(Self.unnamed(-40)))
        XCTAssertTrue(RecordingDeviceScanFilter.broadcastsAName(Self.named("PKT01", -40)))
    }

    /// EVERY REASON EARNS A SENTENCE, AND THE MAP IS TOTAL. `allCases` is what stops a new
    /// failure mode from inheriting a neighbour's copy.
    func testEveryUnreachableReasonHasItsOwnNonEmptySentence() {
        var seen: [String: RecordingDeviceUnreachableReason] = [:]
        for reason in RecordingDeviceUnreachableReason.allCases {
            let line = RecordingDeviceAttachPresentation.line(for: reason)
            XCTAssertFalse(line.isEmpty, "\(reason) renders nothing at all")
            XCTAssertFalse(reason.diagnostic.isEmpty, "\(reason) has no diagnostic form")
            if let clash = seen[line] {
                XCTFail("\(reason) and \(clash) render the same sentence \"\(line)\" — two "
                            + "different failures that read identically are one failure with "
                            + "extra steps")
            }
            seen[line] = reason
            XCTAssertEqual(RecordingDeviceAttachPresentation.inlineMessage(for: .unreachable(reason)),
                           line,
                           "\(reason) is carried in the outcome and thrown away on the way to "
                               + "the screen, which is the whole of the reported defect")
        }
        XCTAssertGreaterThanOrEqual(RecordingDeviceUnreachableReason.allCases.count, 10,
                                    "the reason space collapsed back to a handful, so the "
                                        + "distinctness assertion above proves little")
    }

    // MARK: fixtures

    static func named(_ name: String, _ rssi: Int) -> DiscoveredDevice {
        DiscoveredDevice(id: UUID(), name: name, rssi: rssi)
    }

    static func unnamed(_ rssi: Int) -> DiscoveredDevice {
        DiscoveredDevice(id: UUID(), name: "", rssi: rssi)
    }
}

// MARK: - The world

@MainActor
private final class ConnectSheetWorld {

    private let token = UUID().uuidString
    private let sandbox: URL
    private let container: URL
    private let scopeDefaultsName: String
    private let scopeDefaults: UserDefaults

    private var discovered: [DiscoveredDevice] = []
    private var list: RecordingDeviceScanList?
    private var revealed: RecordingDeviceScanList?

    private var stack: FakePocketBLEStack?
    /// Whether a held notify-confirmation should eventually arrive, as a real radio's
    /// would. False models a subscription that never takes.
    private var releaseConfirmationAfterTap = false
    private var outcome: RecordingDeviceAttachOutcome?
    private var attachment: RecordingDeviceAttachment?
    private var secrets = InMemoryPocketSecretStore()

    private static let recorderId = UUID(uuidString: "26079BC5-9B44-4C1E-9A22-7E5F0D3C1B08")!
    private static let recorderName = "PKT01_BLUE_26079bc5"
    private static let sessionSecret = "A!b2-C_d.E?9+x=Z"

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-connect-sheet-\(token)", isDirectory: true)
        container = sandbox.appendingPathComponent("documents/foundryx-captures", isDirectory: true)
        scopeDefaultsName = "foundryx.connect-sheet.scope.\(token)"
        guard let scope = UserDefaults(suiteName: scopeDefaultsName) else {
            throw BrineStepError("could not create an isolated UserDefaults suite")
        }
        scopeDefaults = scope
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        CaptureAccountScope.setContainerForTests(container)
        CaptureAccountScope.setApplicationSupportRootForTests(
            sandbox.appendingPathComponent("application-support", isDirectory: true))
        CaptureAccountScope.setDefaultsForTests(scopeDefaults)
    }

    func cleanup() { try? CaptureAccountScope.signOutForTests() }

    // MARK: Given

    func given(_ phrase: String) throws {
        switch phrase {
        case "a scan that has turned up two devices with names and five with none":
            discovered = [
                ConnectSheetSaysWhatHappenedFeatureTests.named("PKT01_BLUE_26079bc5", -38),
                ConnectSheetSaysWhatHappenedFeatureTests.unnamed(-44),
                ConnectSheetSaysWhatHappenedFeatureTests.unnamed(-51),
                ConnectSheetSaysWhatHappenedFeatureTests.named("Omi", -55),
                ConnectSheetSaysWhatHappenedFeatureTests.unnamed(-61),
                ConnectSheetSaysWhatHappenedFeatureTests.unnamed(-66),
                ConnectSheetSaysWhatHappenedFeatureTests.unnamed(-72),
            ]

        case "a scan that has turned up three devices and not one of them broadcasts a name":
            discovered = [
                ConnectSheetSaysWhatHappenedFeatureTests.unnamed(-38),
                ConnectSheetSaysWhatHappenedFeatureTests.unnamed(-51),
                ConnectSheetSaysWhatHappenedFeatureTests.unnamed(-66),
            ]

        case "a discovered recorder this iPhone can no longer find":
            // NOT RETRIEVABLE AND NOT ADVERTISING. The rescan runs and finds nothing, which is
            // the only honest form of "I could not find that device".
            let staged = FakePocketBLEStack(deviceId: Self.recorderId,
                                            deviceName: Self.recorderName,
                                            acceptedSecret: Self.sessionSecret)
            staged.reachability.retrievableByIdentifier = false
            staged.reachability.answersScan = false
            stack = staged

        case "a recorder that has not yet confirmed it will send replies":
            // The confirmation is HELD, then released, so the product's wait is what
            // makes the ordering hold rather than the fake being fast.
            let holding = FakePocketBLEStack(deviceId: Self.recorderId,
                                             deviceName: Self.recorderName,
                                             acceptedSecret: Self.sessionSecret)
            holding.holdNotifyConfirmation = true
            releaseConfirmationAfterTap = true
            stack = holding

        case "a recorder that never confirms it will send replies":
            // Held and NEVER released: the subscription simply never takes. This is the
            // failure that used to be reported as "couldn't reach the recorder".
            let never = FakePocketBLEStack(deviceId: Self.recorderId,
                                           deviceName: Self.recorderName,
                                           acceptedSecret: Self.sessionSecret)
            never.holdNotifyConfirmation = true
            releaseConfirmationAfterTap = false
            stack = never

        case "a recorder that connects and then never says what it can do":
            let staged = FakePocketBLEStack(deviceId: Self.recorderId,
                                            deviceName: Self.recorderName,
                                            acceptedSecret: Self.sessionSecret)
            staged.reachability.neverListsServices = true
            stack = staged

        case "a recorder this iPhone cannot look up but which is still advertising":
            let staged = FakePocketBLEStack(deviceId: Self.recorderId,
                                            deviceName: Self.recorderName,
                                            acceptedSecret: Self.sessionSecret)
            staged.reachability.retrievableByIdentifier = false
            stack = staged
            try signIn()
            secrets = InMemoryPocketSecretStore()
            try holdTheKey()

        case "a signed-in account and a discovered recorder FoundryX already holds the key for":
            stack = FakePocketBLEStack(deviceId: Self.recorderId,
                                       deviceName: Self.recorderName,
                                       acceptedSecret: Self.sessionSecret)
            try signIn()
            secrets = InMemoryPocketSecretStore()
            try holdTheKey()

        case "the shipped connect-failure copy":
            break

        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    private func signIn() throws {
        CaptureAccountScope.setAccountForTests(email: "connect-sheet-\(token)@example.com")
        guard let binding = CaptureAccountScope.currentAccountBinding(),
              binding.scope != CaptureAccountScope.signedOutScope else {
            throw BrineStepError("signing in did not leave the signed-out scope")
        }
    }

    /// The account already holds this recorder's key, through the shipped custody seam.
    private func holdTheKey() throws {
        let identity = try PocketAuthenticatedIdentity(
            peripheralIdentifier: Self.recorderId.uuidString)
        let store = secrets
        let secret = Self.sessionSecret
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            try? await store.save(secret, for: identity)
            done.signal()
        }
        done.wait()
    }

    // MARK: When

    func when(_ phrase: String) throws {
        switch phrase {
        case "the connect sheet's list is drawn":
            list = RecordingDeviceScanFilter.resolve(discovered, showingUnnamed: false)
            revealed = RecordingDeviceScanFilter.resolve(discovered, showingUnnamed: true)
        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    func whenAsync(_ phrase: String) async throws {
        switch phrase {
        case "I tap that discovered device":
            guard let stack else { throw BrineStepError("no device was staged") }
            // THE PRODUCTION COMPONENT, on the production seam. Short deadlines because the
            // stalling scenarios are ABOUT the deadlines; the code they exercise is the same.
            let attachment = RecordingDeviceAttachment(
                makeCentral: stack.factory,
                secrets: secrets,
                recovery: nil,
                deadlines: .init(powerOn: 2, connect: 1, discovery: 1, control: 1))
            self.attachment = attachment
            // A held confirmation is released mid-attach, the way a radio's would
            // arrive after the subscription settles. The product must not have written
            // anything before this fires — which is what the ordering step asserts.
            if releaseConfirmationAfterTap {
                let s = stack
                Task.detached {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    s.confirmNotifications()
                }
            }
            outcome = await attachment.attach(peripheralIdentifier: stack.deviceId,
                                              advertisedName: stack.deviceName)
        default:
            throw BrineStepError("unhandled async When: \(phrase)")
        }
    }

    // MARK: Then

    func then(_ phrase: String) throws {
        switch phrase {

        // ── the fold ────────────────────────────────────────────────────────
        case "only the two named devices are listed":
            guard let list else { throw BrineStepError("the list was never drawn") }
            XCTAssertEqual(list.visible.map(\.name), ["PKT01_BLUE_26079bc5", "Omi"],
                           "the sheet is still drawing every advertising peripheral in the "
                               + "room — five interchangeable `Unnamed recording device` rows "
                               + "around the one the person is looking for")

        case "the sheet says how many devices with no name it is holding back":
            guard let list else { throw BrineStepError("the list was never drawn") }
            XCTAssertEqual(list.hiddenUnnamedCount, 5)
            XCTAssertEqual(list.hiddenLine, "5 devices with no name are hidden",
                           "rows vanished with nothing said about them, which is how a person "
                               + "concludes their recorder is not there")
            XCTAssertEqual(RecordingDeviceConnectPresentation.unnamedHiddenLine(count: 1),
                           "1 device with no name is hidden",
                           "the singular reads as a plural")

        case "asking to show them lists all seven, so none of them is unreachable":
            guard let revealed else { throw BrineStepError("the list was never drawn") }
            XCTAssertEqual(revealed.visible.count, 7,
                           "the disclosure does not actually reveal what was folded, so a "
                               + "recorder that broadcasts no name is unpairable")
            XCTAssertEqual(revealed.hiddenUnnamedCount, 0)
            XCTAssertFalse(RecordingDeviceConnectPresentation.showUnnamedAction.isEmpty,
                           "there is no action to reveal them with")

        case "the connect sheet actually applies that filter to what it draws":
            // `swift test` cannot compile `App/`, so the SOURCE is the evidence that the rule
            // reaches the screen. A filter with no caller is not a shipped fix.
            let code = try Self.deviceScreenCode()
            XCTAssertTrue(code.contains("RecordingDeviceScanFilter.resolve("),
                          "nothing in the Devices screen resolves the scan list, so the fold "
                              + "exists only in the kit and the sheet is unchanged")
            XCTAssertTrue(code.contains("ForEach(scan.visible)"),
                          "the sheet still iterates the raw discovered list")
            XCTAssertTrue(code.contains("RecordingDeviceConnectPresentation.showUnnamedAction"),
                          "the fold is not disclosed in the rendered app, so it IS a deletion "
                              + "as far as anyone using it is concerned")
            XCTAssertFalse(code.contains("ForEach(device.discovered)"),
                           "the unfiltered list is still being drawn somewhere on this screen")

        case "all three are listed":
            guard let list else { throw BrineStepError("the list was never drawn") }
            XCTAssertEqual(list.visible.count, 3,
                           "the unnamed devices were folded away with nothing to fold them "
                               + "behind, so the sheet is empty while three devices are in "
                               + "range — one of which may be the recorder being paired")

        case "the sheet holds nothing back":
            guard let list else { throw BrineStepError("the list was never drawn") }
            XCTAssertEqual(list.hiddenUnnamedCount, 0)
            XCTAssertNil(list.hiddenLine)

        // ── one sentence per failure ────────────────────────────────────────
        case "the app says it could not find that device rather than that it could not connect":
            XCTAssertEqual(outcome, .unreachable(.deviceNotFound),
                           "a device this iPhone cannot look up and cannot rediscover produced "
                               + String(describing: outcome))
            let line = RecordingDeviceAttachPresentation.inlineMessage(for: .unreachable(.deviceNotFound))
            XCTAssertEqual(line, RecordingDeviceAttachPresentation.line(for: .deviceNotFound))
            XCTAssertNotEqual(line,
                              RecordingDeviceAttachPresentation.line(for: .connectTimedOut),
                              "\"I never found it\" and \"it never answered\" read the same")

        case "the reason the attempt failed is carried in the outcome rather than discarded":
            guard case .unreachable(let reason) = outcome else {
                throw BrineStepError("the outcome was \(String(describing: outcome))")
            }
            XCTAssertEqual(reason, .deviceNotFound)
            // NON-VACUITY: the mapping must actually vary. If every reason rendered one
            // sentence — which is what shipped — this scenario would pass on a constant.
            let distinct = Set(RecordingDeviceUnreachableReason.allCases
                .map(RecordingDeviceAttachPresentation.line(for:)))
            XCTAssertEqual(distinct.count, RecordingDeviceUnreachableReason.allCases.count,
                           "\(RecordingDeviceUnreachableReason.allCases.count) reasons render "
                               + "\(distinct.count) sentences")

        case "the app says it connected and the device never described itself":
            XCTAssertEqual(outcome, .unreachable(.serviceDiscoveryTimedOut),
                           "a device that connected and then stalled in service discovery "
                               + "produced " + String(describing: outcome))
            let line = RecordingDeviceAttachPresentation.line(for: .serviceDiscoveryTimedOut)
            XCTAssertTrue(line.contains("connected"),
                          "\"\(line)\" does not say the app got as far as connecting, which is "
                              + "the one thing this failure knows for certain")

        case "that sentence is different from the one a device it never reached produces":
            let stalled = RecordingDeviceAttachPresentation.line(for: .serviceDiscoveryTimedOut)
            for other in [RecordingDeviceUnreachableReason.deviceNotFound, .connectTimedOut,
                          .connectRefused, .bluetoothOff] {
                XCTAssertNotEqual(stalled, RecordingDeviceAttachPresentation.line(for: other),
                                  "a device that CONNECTED reads the same as \(other) — which "
                                      + "is how somebody gets sent to fix the one thing that "
                                      + "is demonstrably not broken")
            }

        case "every reason a tap can fail to reach a device has a sentence of its own":
            for reason in RecordingDeviceUnreachableReason.allCases {
                XCTAssertFalse(RecordingDeviceAttachPresentation.line(for: reason).isEmpty,
                               "\(reason) renders nothing")
            }

        case "no two of those sentences are the same":
            let lines = RecordingDeviceUnreachableReason.allCases
                .map(RecordingDeviceAttachPresentation.line(for:))
            XCTAssertEqual(Set(lines).count, lines.count,
                           "two failures share a sentence, so one of them is being reported as "
                               + "the other")

        case "not one of them tells me to bring a device closer":
            // THE REPORTED SYMPTOM. The Pocket was against the back of the phone.
            for line in RecordingDeviceAttachPresentation.everyLine {
                for banned in ["closer", "move it", "in range", "out of range", "too far"] {
                    XCTAssertFalse(line.lowercased().contains(banned),
                                   "\"\(line)\" says \"\(banned)\" — this app cannot measure "
                                       + "distance, and out-of-range, powered-off and "
                                       + "connected-to-another-app are the same silence here")
                }
            }
            XCTAssertFalse(PocketSessionKeyEntryPresentation.linkFailedLine
                .lowercased().contains("closer"),
                           "the key-entry screen still blames distance for a link failure")

        case "every one of those sentences is in the population the brand-free gate is held over":
            for reason in RecordingDeviceUnreachableReason.allCases {
                XCTAssertTrue(
                    RecordingDeviceAttachPresentation.everyLine
                        .contains(RecordingDeviceAttachPresentation.line(for: reason)),
                    "\(reason)'s sentence escapes `everyLine`, so the brand-free and non-empty "
                        + "properties held over the population skip it")
            }

        // ── the rescan, and the radio ───────────────────────────────────────
        case "the app finds it with a scan and adopts it anyway":
            guard case .adopted(_, let displayName, let negotiated) = outcome else {
                throw BrineStepError(
                    "a recorder that could not be looked up but was still advertising produced "
                        + String(describing: outcome)
                        + " — a peripheral this central cannot retrieve used to be the end of "
                        + "the attempt, which made a first-time pairing unreachable")
            }
            XCTAssertEqual(displayName, Self.recorderName)
            XCTAssertEqual(negotiated, PocketRecordingDeviceBridge.protocolIdentifier)
            XCTAssertEqual(stack?.observedScanServiceFilter, .some(nil),
                           "the rescan carried a service filter — a stored-file recorder "
                               + "advertises no live-audio service and would never answer it")

        case "no command was written before that confirmation arrived":
            // The assertion the recorder's protocol actually requires. Mutation-checked:
            // delete the `wait(for: .notifying …)` in RecordingDeviceAttachment and this
            // step reports the exact command that jumped the queue — in practice
            // "APP&SK&…", the key itself, written into a channel with no listener.
            if let early = (stack as? FakePocketBLEStack)?.commandWrittenBeforeNotifyConfirmed {
                throw BrineStepError(
                    "a command was written before the recorder confirmed it would answer: "
                    + String(early.prefix(8)) + "… (a reply could not have arrived)")
            }

        case "every command was written the way the recorder answers":
            // pocket-libre writes commands with response=False (commands.py:127) to
            // CMD_WRITE_CHAR = 001120a3 — the same characteristic this app uses. With
            // .withResponse the recorder answered nothing: build 780017 reached
            // providingKey and then reported handshakeUnanswered 8s later.
            let types = (stack as? FakePocketBLEStack)?.commandWriteTypes ?? []
            guard !types.isEmpty else {
                throw BrineStepError("no command was written at all")
            }
            if let bad = types.firstIndex(where: { $0 != .withoutResponse }) {
                throw BrineStepError(
                    "command \(bad) was written .withResponse; the recorder answers "
                    + "writes made without response")
            }

        case "the sheet says it connected but stopped responding":
            let line = RecordingDeviceAttachPresentation.line(
                for: .notificationsNeverEnabled)
            guard line.contains("stopped responding") else {
                throw BrineStepError("expected a 'stopped responding' sentence, got: \(line)")
            }

        case "that sentence does not claim the recorder could not be reached":
            let line = RecordingDeviceAttachPresentation.line(
                for: .notificationsNeverEnabled)
            guard !line.lowercased().contains("couldn't reach"),
                  !line.lowercased().contains("could not reach") else {
                throw BrineStepError(
                    "the line blames the link for a recorder that connected: \(line)")
            }

        case "the attempt is holding no central manager afterwards":
            guard let attachment else { throw BrineStepError("no attempt was made") }
            XCTAssertFalse(attachment.isHoldingRadio,
                           "the attempt is still holding the central manager it opened. Two "
                               + "of the states the app deliberately RETAINS this object for "
                               + "hold it indefinitely, so a leaked central outlives the tap "
                               + "and every retry starts worse off than the last")
            XCTAssertEqual(outcome.map { if case .adopted = $0 { return true } else { return false } },
                           true,
                           "the tap did not adopt, so this scenario is measuring teardown after "
                               + "a failure rather than after a success")

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    private static func deviceScreenCode() throws -> String {
        let url = AppSourceTree.repoRoot.appendingPathComponent("App/DeviceScreen.swift")
        return AppSourceTree.withoutComments(of: try String(contentsOf: url, encoding: .utf8))
    }
}

// MARK: - Steps

private enum ConnectSheetSteps {
    static func make(world: ConnectSheetWorld) -> [StepDefinition] {
        let givens = [
            "a scan that has turned up two devices with names and five with none",
            "a scan that has turned up three devices and not one of them broadcasts a name",
            "a discovered recorder this iPhone can no longer find",
            "a recorder that connects and then never says what it can do",
            "a recorder this iPhone cannot look up but which is still advertising",
            "a signed-in account and a discovered recorder FoundryX already holds the key for",
            "the shipped connect-failure copy",
            "a recorder that has not yet confirmed it will send replies",
            "a recorder that never confirms it will send replies",
        ]
        let whens = ["the connect sheet's list is drawn"]
        let asyncWhens = ["I tap that discovered device"]
        let thens = [
            "only the two named devices are listed",
            "the sheet says how many devices with no name it is holding back",
            "asking to show them lists all seven, so none of them is unreachable",
            "the connect sheet actually applies that filter to what it draws",
            "all three are listed",
            "the sheet holds nothing back",
            "the app says it could not find that device rather than that it could not connect",
            "the reason the attempt failed is carried in the outcome rather than discarded",
            "the app says it connected and the device never described itself",
            "that sentence is different from the one a device it never reached produces",
            "every reason a tap can fail to reach a device has a sentence of its own",
            "no two of those sentences are the same",
            "not one of them tells me to bring a device closer",
            "every one of those sentences is in the population the brand-free gate is held over",
            "the app finds it with a scan and adopts it anyway",
            "the attempt is holding no central manager afterwards",
            "no command was written before that confirmation arrived",
            "every command was written the way the recorder answers",
            "the sheet says it connected but stopped responding",
            "that sentence does not claim the recorder could not be reached",
        ]
        var steps = givens.map { phrase in
            defineStep(phrase) { context, _, _ in
                try await world.given(phrase)
                return context
            }
        }
        steps += whens.map { phrase in
            defineStep(phrase) { context, _, _ in
                try await world.when(phrase)
                return context
            }
        }
        steps += asyncWhens.map { phrase in
            defineStep(phrase) { context, _, _ in
                try await world.whenAsync(phrase)
                return context
            }
        }
        steps += thens.map { phrase in
            defineCheck(phrase) { _, _, _ in
                try await world.then(phrase)
            }
        }
        return steps
    }
}
