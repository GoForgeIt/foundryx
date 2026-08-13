import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// `features/pocket-bring-over.feature`, driven against the SAME wrapped BLE seam
/// `DeviceManager` runs on. `PocketBLEClient.download` shipped implemented and unit-tested
/// with no caller outside `Tests/`; these scenarios drive the shipped
/// `RecordingDeviceAttachment`, `PocketSeamTransport`, `PocketBLEClient`,
/// `PocketOnboardingCoordinator`, `PocketBringOver` and `PocketRecorderFileStore`. Only the
/// radio and the directory custody writes into are injected.
final class PocketBringOverFeatureTests: XCTestCase {
    func testPocketBringOverFeature() async throws {
        let world = PocketBringOverWorld()
        let result = try await BrineFeatureRunner.run(
            "pocket-bring-over",
            registry: StepRegistry(PocketBringOverSteps.make(world)))
        XCTAssertEqual(result.passed, 7)
    }

    /// THE CEILING, WHICH NO SCENARIO CAN REACH OVER A FAKE RADIO AND WHICH IS STILL THE
    /// LOAD-BEARING PART OF THE SHAPE. The current bring-over holds the payload AND the
    /// re-read copy in memory at once, so a file large enough to end the app is refused
    /// BEFORE a session is opened — the recorder is not even asked.
    func testAFileTooLargeToHoldInMemoryIsRefusedBeforeTheRecorderIsAsked() async throws {
        let identifier = UUID()
        let stack = FakePocketBLEStack(deviceId: identifier,
                                       deviceName: "PKT01_BLUE_26079bc5",
                                       acceptedSecret: "0123456789abcdef")
        let secrets = InMemoryPocketSecretStore()
        try await secrets.save(
            "0123456789abcdef",
            for: try PocketAuthenticatedIdentity(peripheralIdentifier: identifier.uuidString))
        let custody = PocketRecorderFileStore(
            root: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pocket-bring-over-ceiling-\(UUID().uuidString)"))
        let outcome = await PocketBringOver.run(
            peripheralIdentifier: identifier,
            advertisedName: stack.deviceName,
            recording: .init(date: "2026-03-28",
                             timestamp: "20260328001919",
                             sizeBytes: PocketBringOver.maximumBytes + 1),
            custody: custody,
            attachment: RecordingDeviceAttachment(
                makeCentral: stack.factory,
                secrets: secrets,
                recovery: nil,
                deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 2)))
        XCTAssertEqual(outcome, .unreadableRecording)
        XCTAssertEqual(stack.commandsWritten, [],
                       "a file this build cannot hold was refused only after the recorder had "
                           + "already been opened and asked")
    }
}

private enum PocketBringOverSteps {
    static func make(_ world: PocketBringOverWorld) -> [StepDefinition] {
        let givens = [
            "a remembered recorder holding one short recording",
            "a remembered recorder holding a long recording and a short one",
            "a remembered recorder whose file stops arriving partway through",
            "a remembered recorder whose file is not a readable recording",
        ]
        let whens = [
            "I bring that recording over",
            "I bring the offered recording over",
            "I bring that recording over twice",
        ]
        let thens = [
            "the recorder is asked for that file on the session the handshake opened",
            "the file is kept where it can be read back byte for byte",
            "that recording is listed as being in Solleva rather than only on the recorder",
            "the shorter file is the one that was asked for",
            "Solleva keeps no partial copy and says the transfer did not finish",
            "that recording is still listed as only on the recorder",
            "Solleva keeps no copy and says it could not read the recording",
            "one copy is kept and the recorder was asked only once",
            "the recorder was sent no delete command and the deletion promise is still shown",
            "no FrameRouter, WAL, Live Activity, recording pill, or currently-recording state "
                + "is reached",
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

private actor PocketBringOverWorld {
    private static let secret = "0123456789abcdef"
    private static let day = "2026-03-28"

    /// A FILE THIS BUILD CAN READ: it opens on the `0xFF 0xF3` sync `PocketBLEClient.download`
    /// trims to, and it is several notifications long, so assembling it is a real assembly.
    private static func mp3(_ count: Int) -> Data {
        var bytes = Data([0xff, 0xf3])
        bytes.append(Data(repeating: 0x41, count: max(0, count - 2)))
        return bytes
    }

    private var stack: FakePocketBLEStack?
    private var secrets = InMemoryPocketSecretStore()
    private var targetIdentifier: UUID?
    /// The shelf as the reader would report it, which is what `offered` chooses from.
    private var shelf: [PocketRecording] = []
    /// The one file a scenario said "that recording" about.
    private var subject: PocketRecording?
    private var custodyRoot: URL?
    private var custody: PocketRecorderFileStore?
    private var outcomes: [PocketBringOverOutcome] = []
    private var liveEffects = StoredFileLiveEffectCounts()

    // MARK: - Given

    func given(_ phrase: String) async throws {
        outcomes = []
        liveEffects = .init()
        secrets = InMemoryPocketSecretStore()
        let identifier = UUID()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pocket-bring-over-\(UUID().uuidString)")
        custodyRoot = root
        custody = PocketRecorderFileStore(root: root)

        switch phrase {
        case "a remembered recorder holding one short recording":
            try await stage(identifier: identifier, inventory: [
                .init(date: Self.day, timestamp: "20260328001919", sizeBytes: 900,
                      content: Self.mp3(900)),
            ])

        case "a remembered recorder holding a long recording and a short one":
            // THE SAME DAY ON PURPOSE. The shipped comparator is newest day first and only
            // THEN shorter file, so putting the long one on an older day would let a
            // by-date-only implementation pass a claim about size.
            try await stage(identifier: identifier, inventory: [
                .init(date: Self.day, timestamp: "20260328010000", sizeBytes: 96_000,
                      content: Self.mp3(96_000)),
                .init(date: Self.day, timestamp: "20260328020000", sizeBytes: 900,
                      content: Self.mp3(900)),
            ])

        case "a remembered recorder whose file stops arriving partway through":
            // IT ANNOUNCES 900 AND SENDS 360, then says nothing more — no error frame, which
            // is what a transfer that died looks like from the phone.
            try await stage(identifier: identifier, inventory: [
                .init(date: Self.day, timestamp: "20260328001919", sizeBytes: 900,
                      content: Self.mp3(360)),
            ])

        case "a remembered recorder whose file is not a readable recording":
            try await stage(identifier: identifier, inventory: [
                .init(date: Self.day, timestamp: "20260328001919", sizeBytes: 900,
                      content: Data(repeating: 0x41, count: 900)),
            ])

        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    private func stage(identifier: UUID,
                       inventory: [FakePocketBLEStack.ScriptedRecording]) async throws {
        let made = FakePocketBLEStack(deviceId: identifier,
                                      deviceName: "PKT01_BLUE_26079bc5",
                                      acceptedSecret: Self.secret,
                                      inventory: inventory)
        stack = made
        targetIdentifier = identifier
        shelf = inventory.map {
            PocketRecording(date: $0.date, timestamp: $0.timestamp, sizeBytes: $0.sizeBytes)
        }
        subject = shelf.count == 1 ? shelf.first : nil
        try await secrets.save(
            Self.secret,
            for: try PocketAuthenticatedIdentity(peripheralIdentifier: identifier.uuidString))
    }

    // MARK: - When

    func when(_ phrase: String) async throws {
        switch phrase {
        case "I bring that recording over":
            outcomes = [try await bringOver(try requireSubject())]
        case "I bring the offered recording over":
            guard let offered = PocketBringOver.offered(shelf) else {
                throw BrineStepError("nothing was offered off a shelf of \(shelf.count) files")
            }
            subject = offered
            outcomes = [try await bringOver(offered)]
        case "I bring that recording over twice":
            let recording = try requireSubject()
            outcomes = [try await bringOver(recording), try await bringOver(recording)]
        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
        // THE LIVE BOUNDARIES, WATCHED THROUGH THE SAME SPY `pocket-durable-sync` uses. A
        // bring-over is not a recording, and this is the only thing that says so about the
        // code rather than about the intent.
        let spy = StoredFileLiveBoundarySpy()
        StoredFileDeviceLifecycle.runFullLinkLifecycle(liveBoundaries: spy)
        liveEffects = spy.counts
    }

    private func bringOver(_ recording: PocketRecording) async throws -> PocketBringOverOutcome {
        guard let stack, let targetIdentifier, let custody else {
            throw BrineStepError("no recorder was staged")
        }
        // THE PRODUCTION COMPONENT, on the production seam. `recovery: nil` keeps this
        // hermetic; a fresh attachment per pull because `teardown()` retires the link.
        return await PocketBringOver.run(
            peripheralIdentifier: targetIdentifier,
            advertisedName: stack.deviceName,
            recording: recording,
            custody: custody,
            attachment: RecordingDeviceAttachment(
                makeCentral: stack.factory,
                secrets: secrets,
                recovery: nil,
                deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 2)))
    }

    /// The shelf as the SHIPPED check would report it once custody has been consulted — the
    /// same call `App/DeviceScreen.swift` re-runs after a bring-over, over the real radio.
    private func checkedShelf() async throws -> StoredFileDeviceDetailPresentation {
        guard let stack, let targetIdentifier, let custody else {
            throw BrineStepError("no recorder was staged")
        }
        let outcome = await PocketRecorderCheck.run(
            peripheralIdentifier: targetIdentifier,
            advertisedName: stack.deviceName,
            custody: custody,
            attachment: RecordingDeviceAttachment(
                makeCentral: stack.factory,
                secrets: secrets,
                recovery: nil,
                deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 2)))
        guard case .checked(let detail) = outcome else {
            throw BrineStepError("the shelf could not be re-read: \(String(describing: outcome))")
        }
        return detail
    }

    // MARK: - Then

    func then(_ phrase: String) async throws {
        switch phrase {
        case "the recorder is asked for that file on the session the handshake opened":
            let recording = try requireSubject()
            let commands = try requireCommands()
            XCTAssertEqual(commands.filter { $0.hasPrefix("SK&") }.count, 1,
                           "the bring-over opened more than one authenticated session")
            // THE WHOLE TRANSCRIPT, PINNED. `BAT`/`FW` are the shipped coordinator's
            // confirmation that the key was accepted; the pull follows them on the same
            // session, and nothing else is sent at all.
            XCTAssertEqual(commands,
                           ["SK&\(Self.secret)", "BAT", "FW",
                            "U&\(recording.date)&\(recording.timestamp)"])

        case "the file is kept where it can be read back byte for byte":
            XCTAssertEqual(outcomes, [.broughtOver(bytes: 900)])
            let kept = try keptFiles()
            XCTAssertEqual(kept.count, 1, "custody holds \(kept.count) artifacts, not one")
            guard let only = kept.first else { return XCTFail("nothing was kept") }
            XCTAssertEqual(try Data(contentsOf: only), Self.mp3(900),
                           "what is on disk is not the bytes the recorder sent")

        case "that recording is listed as being in Solleva rather than only on the recorder":
            let detail = try await checkedShelf()
            let recording = try requireSubject()
            let row = detail.manifest.rows.first {
                $0.title == PocketRecordingLabel.title(date: recording.date,
                                                       timestamp: recording.timestamp)
            }
            XCTAssertEqual(row?.custodyLabel, "In Solleva",
                           "a file Solleva is holding a verified copy of is still listed as "
                               + "only on the recorder")

        case "the shorter file is the one that was asked for":
            let commands = try requireCommands()
            let pulls = commands.filter { $0.hasPrefix("U&") }
            XCTAssertEqual(pulls, ["U&\(Self.day)&20260328020000"],
                           "the pull did not go to the shorter of the two files — the first "
                               + "file anybody pulls off a Pocket should be one that finishes")

        case "Solleva keeps no partial copy and says the transfer did not finish":
            XCTAssertEqual(outcomes, [.transferIncomplete])
            XCTAssertEqual(try keptFiles(), [],
                           "a transfer that stopped partway left an artifact behind")
            XCTAssertEqual(PocketBringOverPresentation.message(for: .transferIncomplete),
                           PocketBringOverPresentation.transferIncompleteLine)

        case "that recording is still listed as only on the recorder":
            let detail = try await checkedShelf()
            XCTAssertEqual(detail.manifest.rows.map(\.custodyLabel), ["Only on the recorder"],
                           "a file that never landed is claimed as one Solleva is holding")

        case "Solleva keeps no copy and says it could not read the recording":
            XCTAssertEqual(outcomes, [.unreadableRecording])
            XCTAssertEqual(try keptFiles(), [])
            XCTAssertEqual(PocketBringOverPresentation.message(for: .unreadableRecording),
                           PocketBringOverPresentation.unreadableRecordingLine)

        case "one copy is kept and the recorder was asked only once":
            XCTAssertEqual(outcomes, [.broughtOver(bytes: 900), .alreadyHeld])
            XCTAssertEqual(try keptFiles().count, 1, "the second pull kept a second copy")
            let commands = try requireCommands()
            XCTAssertEqual(commands.filter { $0.hasPrefix("U&") }.count, 1,
                           "the recorder was asked for a file Solleva already holds")

        case "the recorder was sent no delete command and the deletion promise is still shown":
            let commands = try requireCommands()
            for command in commands {
                XCTAssertFalse(command.uppercased().contains("DEL"),
                               "the bring-over issued \"\(command)\" — no automatic delete, ever")
            }
            XCTAssertEqual(PocketRecorderCustodyPromise.automaticDeleteCommands, 0)
            XCTAssertTrue(
                PocketRecorderCheckPresentation.sectionNote
                    .contains(PocketRecorderCustodyPromise.text),
                "the panel that now offers a bring-over dropped the deletion promise")
            for line in PocketBringOverPresentation.everyLine {
                XCTAssertFalse(line.uppercased().contains("DELET"),
                               "the bring-over says \"\(line)\" — nothing here deletes")
            }

        case "no FrameRouter, WAL, Live Activity, recording pill, or currently-recording state "
            + "is reached":
            XCTAssertEqual(liveEffects.storedFileLifecycleEvents, 5)
            XCTAssertEqual(liveEffects.activeSourceSelections, 0)
            XCTAssertEqual(liveEffects.frameRouterStarts, 0)
            XCTAssertEqual(liveEffects.walWrites, 0)
            XCTAssertEqual(liveEffects.liveActivities, 0)
            XCTAssertEqual(liveEffects.liveStateMutations, 0)

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    // MARK: - What custody is actually holding

    /// EVERY artifact under the custody root, `.partial` files included. Asking only for
    /// finished `.mp3`s would call a directory full of half-written files empty.
    private func keptFiles() throws -> [URL] {
        guard let custodyRoot else { throw BrineStepError("no custody root was staged") }
        guard let walker = FileManager.default.enumerator(
            at: custodyRoot, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            let regular = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile
            if regular == true { found.append(url) }
        }
        return found.sorted { $0.path < $1.path }
    }

    private func requireCommands() throws -> [String] {
        guard let stack else { throw BrineStepError("no recorder was staged") }
        return stack.commandsWritten
    }

    private func requireSubject() throws -> PocketRecording {
        guard let subject else {
            throw BrineStepError("no single recording was staged for \"that recording\"")
        }
        return subject
    }
}
