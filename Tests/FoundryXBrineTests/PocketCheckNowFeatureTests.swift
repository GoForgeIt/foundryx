import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// `features/pocket-check-now.feature`, driven against the SAME wrapped BLE seam
/// `DeviceManager` runs on. The only injected things are the radio and the secret store;
/// `RecordingDeviceAttachment`, `PocketSeamTransport`, `PocketBLEClient`,
/// `PocketOnboardingCoordinator`, `PocketRecordingDeviceBridge`, `PocketInventoryReader` and
/// `StoredFileDevicePresentation` are the shipped types `App/DeviceScreen.swift` calls.
final class PocketCheckNowFeatureTests: XCTestCase {
    func testPocketCheckNowFeature() async throws {
        let world = PocketCheckNowWorld()
        let result = try await BrineFeatureRunner.run(
            "pocket-check-now",
            registry: StepRegistry(PocketCheckNowSteps.make(world)))
        XCTAssertEqual(result.passed, 6)
    }
}

private enum PocketCheckNowSteps {
    static func make(_ world: PocketCheckNowWorld) -> [StepDefinition] {
        let givens = [
            "a remembered recorder FoundryX holds the key for, holding two recordings",
            "a remembered recorder FoundryX holds no key for",
            "a remembered recorder that is not reachable",
            "a remembered recorder FoundryX holds the key for, holding nothing",
            "a remembered recorder FoundryX holds the key for that will not answer a listing",
        ]
        let whens = ["I check that recorder now"]
        let thens = [
            "the check reports the recorder's battery and firmware",
            "it lists both recordings newest first with a duration for each",
            "every listed recording says it is only on the recorder",
            "the panel offers one bring-over action and repeats the deletion promise",
            "one key handshake was issued and the listing commands followed it on that same session",
            "the recorder was sent no download, no delete and no WiFi command",
            "the link was closed once the answer was in hand",
            "the check says the key is missing rather than showing an empty shelf",
            "no listing command was issued",
            "the check says the recorder could not be reached rather than showing an empty shelf",
            "the check reports an empty shelf in words and still repeats the deletion promise",
            "the panel claims no recording state and no Live Activity",
            "the check says it connected but got no list rather than showing an empty shelf",
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

private actor PocketCheckNowWorld {
    private static let secret = "0123456789abcdef"
    /// The two files this recorder is holding, in the order its firmware lists them — an
    /// OLDER day first, so "newest first" is a claim the fixture can actually falsify.
    private static let scripted: [FakePocketBLEStack.ScriptedRecording] = [
        .init(date: "2026-03-27", timestamp: "20260327091500", sizeBytes: 96_000),
        .init(date: "2026-03-28", timestamp: "20260328001919", sizeBytes: 480_000),
    ]

    private var stack: FakePocketBLEStack?
    private var secrets = InMemoryPocketSecretStore()
    /// The identifier the check is asked for, which is NOT always the one the radio can find.
    private var targetIdentifier: UUID?
    private var outcome: PocketRecorderCheckOutcome?
    private var custodyRoots: [URL] = []

    /// A real, empty custody directory this world owns.
    private func emptyCustodyRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pocket-checknow-custody-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        custodyRoots.append(root)
        return root
    }

    func given(_ phrase: String) async throws {
        outcome = nil
        secrets = InMemoryPocketSecretStore()
        let identifier = UUID()
        switch phrase {
        case "a remembered recorder FoundryX holds the key for, holding two recordings":
            try await stage(identifier: identifier, inventory: Self.scripted, holdsKey: true)

        case "a remembered recorder FoundryX holds no key for":
            // The recorder is keyed — by somebody. This iPhone's custody is empty, which is
            // the state every recorder in the world is in until FoundryX provisions one.
            try await stage(identifier: identifier, inventory: Self.scripted, holdsKey: false)

        case "a remembered recorder that is not reachable":
            try await stage(identifier: identifier, inventory: Self.scripted, holdsKey: true)
            // THE RADIO CANNOT FIND IT. `retrievePeripherals(withIdentifiers:)` is a system
            // lookup; asking for an identifier this stack does not own is exactly the answer
            // a recorder that walked away gives.
            targetIdentifier = UUID()

        case "a remembered recorder FoundryX holds the key for, holding nothing":
            try await stage(identifier: identifier, inventory: [], holdsKey: true)

        case "a remembered recorder FoundryX holds the key for that will not answer a listing":
            try await stage(identifier: identifier, inventory: Self.scripted, holdsKey: true,
                            answersInventory: false)

        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    private func stage(identifier: UUID,
                       inventory: [FakePocketBLEStack.ScriptedRecording],
                       holdsKey: Bool,
                       answersInventory: Bool = true) async throws {
        let made = FakePocketBLEStack(deviceId: identifier,
                                      deviceName: "PKT01_BLUE_26079bc5",
                                      acceptedSecret: Self.secret,
                                      inventory: inventory,
                                      answersInventory: answersInventory)
        stack = made
        targetIdentifier = identifier
        if holdsKey {
            try await secrets.save(
                Self.secret,
                for: try PocketAuthenticatedIdentity(peripheralIdentifier: identifier.uuidString))
        }
    }

    func when(_ phrase: String) async throws {
        guard phrase == "I check that recorder now" else {
            throw BrineStepError("unhandled When: \(phrase)")
        }
        guard let stack, let targetIdentifier else {
            throw BrineStepError("no recorder was staged")
        }
        // THE PRODUCTION COMPONENT, on the production seam. `recovery: nil` keeps this
        // hermetic: with no in-memory attach record, the shipped default would consult a real
        // iCloud Keychain item.
        let attachment = RecordingDeviceAttachment(
            makeCentral: stack.factory,
            secrets: secrets,
            recovery: nil,
            deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 5))
        // AN EMPTY CUSTODY STORE, NOT AN ABSENT ONE. `nil` custody means "the phone was never
        // asked", and since `StoredFileCustody` was retired for `PocketRecordingPresence` that
        // now renders as `Unknown` rather than as a definite no — correctly. What this scenario
        // is about is a recorder whose files this phone genuinely does NOT hold, which is what
        // the shipping screen always asks (`DeviceScreen` passes a `PocketRecorderFileStore` on
        // every check), so the store is real and empty.
        let emptyCustody = PocketRecorderFileStore(root: emptyCustodyRoot())
        outcome = await PocketRecorderCheck.run(peripheralIdentifier: targetIdentifier,
                                                advertisedName: stack.deviceName,
                                                custody: emptyCustody,
                                                attachment: attachment)
    }

    private func requireDetail() throws -> StoredFileDeviceDetailPresentation {
        guard case .checked(let detail) = outcome else {
            throw BrineStepError("the check did not report a reading: \(String(describing: outcome))")
        }
        return detail
    }

    private func requireCommands() throws -> [String] {
        guard let stack else { throw BrineStepError("no recorder was staged") }
        return stack.commandsWritten
    }

    func then(_ phrase: String) async throws {
        switch phrase {
        case "the check reports the recorder's battery and firmware":
            let detail = try requireDetail()
            XCTAssertEqual(detail.battery, "72%")
            XCTAssertEqual(detail.firmware, "1.6")
            XCTAssertEqual(detail.linkLabel, RecordingDeviceLinkState.connected.label)

        case "it lists both recordings newest first with a duration for each":
            let detail = try requireDetail()
            XCTAssertEqual(detail.manifest.rows.map(\.title),
                           ["2026-03-28 · 00:19", "2026-03-27 · 09:15"],
                           "the recorder's own reported instants are not listed newest first")
            // THE RECORDER'S OWN NUMBER. `MCU&F&<date>&<stamp>&<KB>` states kilobytes; a
            // duration was never stated by anything (`PocketMeasuredFigures`).
            // EXACTLY WHAT CAME OFF THE WIRE. `MCU&F&…&<KB>` is kilobytes, the client stores it
            // as `KB * 1024`, so the row's divide-by-1024 returns the recorder's own integer
            // with nothing lost. A duration was never stated by anything
            // (`PocketMeasuredFigures`).
            XCTAssertEqual(detail.manifest.rows.map(\.size), ["469 KB", "94 KB"])

        case "every listed recording says it is only on the recorder":
            let detail = try requireDetail()
            XCTAssertEqual(detail.manifest.rows.map(\.presenceLabel),
                           ["Only on the recorder", "Only on the recorder"],
                           "a file that has never been brought over is labelled as though "
                               + "Solleva were holding a copy of it")

        case "the panel offers one bring-over action and repeats the deletion promise":
            // THE RECORDED §6c DECISION, DELIBERATELY REVERSED. This used to scan
            // `everyLine` for "Bring"/"Download"/"Import"/"Transfer" and assert that no
            // bring-over existed, because the download path had never run end to end.
            // `PocketBringOver` is that path with a caller, so what is asserted now is the
            // new truth — held over the POPULATION, exactly as the absence was.
            XCTAssertTrue(RecordingDevicePage.bringOverIsOffered)
            XCTAssertEqual(
                PocketBringOverPresentation.everyLine.filter {
                    $0 == PocketBringOverPresentation.actionTitle
                },
                ["Bring over"],
                "the shelf offers something other than exactly one bring-over action")
            // AND STILL NOTHING THAT PROMISES A BACKLOG. One file at a time is the shape
            // `PocketBringOver` actually has; "Sync"/"Import"/"Download" would each be a
            // claim about a leg that still has no caller.
            for line in PocketBringOverPresentation.everyLine
                + PocketRecorderCheckPresentation.everyLine {
                for banned in ["Download", "Import", "Transfer all", "Sync"] {
                    XCTAssertFalse(line.contains(banned),
                                   "the panel says \"\(banned)\" — a bring-over moves ONE "
                                       + "file, and the backlog and cadence still have no "
                                       + "caller")
                }
            }
            XCTAssertTrue(
                PocketRecorderCheckPresentation.sectionNote
                    .contains(PocketRecorderCustodyPromise.text),
                "the shipped deletion promise is not on the one surface that lists a "
                    + "recorder's files — the promise had no renderer at all")

        case "one key handshake was issued and the listing commands followed it on that same session":
            let commands = try requireCommands()
            XCTAssertEqual(commands.filter { $0.hasPrefix("SK&") }.count, 1,
                           "the check opened more than one authenticated session")
            guard let handshake = commands.firstIndex(where: { $0.hasPrefix("SK&") }),
                  let listing = commands.firstIndex(of: "LIST_DIRS") else {
                return XCTFail("the recorder was never asked what it is holding: \(commands)")
            }
            XCTAssertLessThan(handshake, listing)
            // THE WHOLE TRANSCRIPT, PINNED. `BAT`/`FW` appear TWICE because the shipped
            // custody flow reads them twice on a successful restore — once as
            // `PocketOnboardingCoordinator`'s confirmation that the key was accepted, once as
            // `PocketRecordingDeviceBridge.observe`'s facts — which is exactly what the
            // adoption path has always done. It is pinned rather than tolerated: a fourth read
            // appearing here is a regression somebody should have to look at.
            //
            // `SPACE` IS THE ONE ADDITION, AND IT COMES AFTER THE LISTING — WHICH IS THE
            // WHOLE CORRECTION.
            //
            // It first shipped BEFORE the listing, last among the three information reads, on
            // a comment claiming that order protected the listing. It did not: all three of
            // those reads precede the listing, so ordering among themselves protects the two
            // READINGS and nothing else. `APP&SPACE` runs inside `protected(.information)`,
            // which RETIRES the whole client on a `.timeout`, and `try?` swallows the throw
            // but not the retirement — so a firmware that silently ignores the command (rather
            // than answering `MCU&UNKNOWN`, which retires nothing) took the session down and
            // the listing threw `.unauthenticated`. Every "Connect and check now" would then
            // report "it didn't say what it's holding" for a recorder that would have listed
            // perfectly well, trading the one thing the owner opened the page for against a
            // number. These bytes have never been issued to a real recorder; probe P3 has not
            // run. So the listing is banked first.
            //
            // This line is the only thing in the repository that would notice that order
            // moving back.
            XCTAssertEqual(commands, ["SK&\(Self.secret)", "BAT", "FW", "BAT", "FW",
                                      "LIST_DIRS", "LIST&2026-03-27", "LIST&2026-03-28",
                                      "SPACE"])

        case "the recorder was sent no download, no delete and no WiFi command":
            let commands = try requireCommands()
            for command in commands {
                XCTAssertFalse(command.hasPrefix("U&"),
                               "the check issued the download command \"\(command)\"")
                XCTAssertFalse(command.hasPrefix("WIFI"),
                               "the check took the recorder off Bluetooth: \"\(command)\"")
                XCTAssertFalse(command.uppercased().contains("DEL"),
                               "the check issued \"\(command)\" — no automatic delete, ever")
            }

        case "the link was closed once the answer was in hand":
            guard let stack else { throw BrineStepError("no recorder was staged") }
            XCTAssertFalse(stack.isConnected,
                           "the probe left its own GATT link up after the answer was in hand")

        case "the check says the key is missing rather than showing an empty shelf":
            XCTAssertEqual(outcome, .unavailable(.setupUnavailable))
            XCTAssertEqual(PocketRecorderCheckPresentation.message(for: try requireOutcome()),
                           PocketRecorderCheckPresentation.keyUnusableLine)

        case "no listing command was issued":
            let commands = try requireCommands()
            XCTAssertFalse(commands.contains("LIST_DIRS"),
                           "a recorder Solleva holds no key for was asked what it is holding")

        case "the check says the recorder could not be reached rather than showing an empty shelf":
            guard case .unavailable(.unreachable(let reason)) = try requireOutcome() else {
                return XCTFail("an unreachable recorder reported \(String(describing: outcome))")
            }
            // THE REASON SURVIVES AS FAR AS THE PANEL. The staged failure is a lookup that
            // came up empty, so the honest answer is `.deviceNotFound` and not one of the
            // four other causes that used to share a single sentence with it.
            XCTAssertEqual(reason, .deviceNotFound,
                           "a recorder the radio could not look up was reported as \(reason)")
            XCTAssertEqual(PocketRecorderCheckPresentation.message(for: try requireOutcome()),
                           RecordingDeviceAttachPresentation.line(for: .deviceNotFound))

        case "the check reports an empty shelf in words and still repeats the deletion promise":
            let detail = try requireDetail()
            XCTAssertEqual(detail.manifest.rows, [])
            XCTAssertEqual(PocketRecorderCheckPresentation.emptyLine,
                           "There's nothing on this recorder right now.")
            XCTAssertTrue(
                PocketRecorderCheckPresentation.sectionNote
                    .contains(PocketRecorderCustodyPromise.text))

        case "the panel claims no recording state and no Live Activity":
            let detail = try requireDetail()
            XCTAssertFalse(detail.showsRecordingState,
                           "reading a recorder's shelf dressed itself as recording")
            XCTAssertFalse(detail.showsLiveActivity)

        case "the check says it connected but got no list rather than showing an empty shelf":
            guard case .inventoryFailed = try requireOutcome() else {
                return XCTFail("a recorder that refused the listing reported "
                               + String(describing: outcome))
            }
            XCTAssertEqual(PocketRecorderCheckPresentation.message(for: try requireOutcome()),
                           PocketRecorderCheckPresentation.inventoryFailedLine)
            let commands = try requireCommands()
            XCTAssertTrue(commands.contains("LIST_DIRS"),
                          "the listing was never attempted, so 'it would not answer' is not "
                              + "what was proven")

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    private func requireOutcome() throws -> PocketRecorderCheckOutcome {
        guard let outcome else { throw BrineStepError("the check never ran") }
        return outcome
    }
}
