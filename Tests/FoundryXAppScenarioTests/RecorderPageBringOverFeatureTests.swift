import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryX

/// THE FIRST SCENARIOS IN THIS REPO THAT EXECUTE `App/`.
///
/// `PocketRecorderCheckModel` lives in `App/DeviceScreen.swift`. Until this file existed
/// nothing could run it: `swift test` and `FoundryXiOSTests` both compile the FoundryXKit
/// library alone, so the model that decides which recording the app offers, that passes
/// custody to the check, and that re-reads the shelf after a transfer had no test coverage of
/// any kind — while `features/pocket-bring-over.feature` reported seven green scenarios about
/// the machinery underneath it.
///
/// Every object below except the radio is the shipped one, running in the shipped app's
/// process: the app's model, `PocketRecorderCheck.run`, `PocketInventoryReader`,
/// `PocketBringOver.run`, `PocketRecorderFileStore`, `StoredFileDevicePresentation`. The radio
/// is `FakePocketBLEStack` — the same scripted recorder the hostless suite drives — reaching
/// the model through the one DEBUG seam on `PocketRecorderCheckModel`.
///
/// THE MUTATIONS THESE SCENARIOS ANSWER TO, all of them edits to `App/DeviceScreen.swift`:
///   * drop `offeredRecording = PocketBringOver.offered(…)` from `run` and the app offers
///     nothing to bring over, which is `PocketBLEClient.download`'s original defect exactly;
///   * drop `custody: self.custody` from the check and every row claims to be only on the
///     recorder forever, including the one this phone is holding;
///   * drop the `self.run(…)` re-read at the end of `bringOver` and the shelf never learns
///     that the file landed.
/// None of the three moves any existing gate.
final class RecorderPageBringOverFeatureTests: XCTestCase {

    /// The DEBUG radio seam is process-global, so it is cleared whatever the scenario did — a
    /// leaked factory would hand the next suite a recorder it never staged.
    override func tearDown() async throws {
        await MainActor.run { PocketRecorderCheckModel.attachmentFactoryForScenarios = nil }
        try await super.tearDown()
    }

    func testSollevasRecorderPageBringsARecordingOver() async throws {
        let world = await RecorderPageWorld()
        let result = try await BrineFeatureRunner.run(
            "a-recorders-page-offers-to-bring-a-recording-over",
            registry: StepRegistry(RecorderPageSteps.make(world)))
        // THE POPULATION IS PINNED. A runner that only asserts "nothing failed" is green once
        // the scenarios have been deleted — the same shape of hole this lane exists to close.
        XCTAssertEqual(result.passed, 3, "all three scenarios must run and pass")
    }
}

// MARK: - Steps

private enum RecorderPageSteps {
    static func make(_ world: RecorderPageWorld) -> [StepDefinition] {
        let givens = [
            "a remembered recorder holding one recording",
            "a remembered recorder holding nothing",
        ]
        let whens = [
            "Solleva asks that recorder what it is holding",
            "I bring the offered recording over",
        ]
        let thens = [
            "Solleva says what is on the recorder",
            "Solleva offers to bring that recording over",
            "Solleva offers nothing to bring over",
            "Solleva says it kept the recording",
            "the recorder's shelf now says that recording is in Solleva",
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

// MARK: - The world one scenario stages

/// `@MainActor` because `PocketRecorderCheckModel` is — it is an `ObservableObject` the app
/// creates and mutates on the main actor, and a world that hopped actors to reach it would be
/// exercising a different threading story than the one that ships.
@MainActor
private final class RecorderPageWorld {
    private static let secret = "0123456789abcdef"
    private static let recorderName = "PKT01_BLUE_26079bc5"
    private static let day = "2026-03-28"
    private static let timestamp = "20260328001919"

    /// A FILE THIS BUILD CAN READ: it opens on the `0xFF 0xF3` sync `PocketBLEClient.download`
    /// trims to, and it is several notifications long, so assembling it is a real assembly.
    private static func mp3(_ count: Int) -> Data {
        var bytes = Data([0xff, 0xf3])
        bytes.append(Data(repeating: 0x41, count: max(0, count - 2)))
        return bytes
    }

    /// THE APP'S OWN MODEL. Not a stand-in with the same shape — the type `App/DeviceScreen
    /// .swift` creates with `@StateObject` on the recorder page.
    private let check = PocketRecorderCheckModel()

    /// EVERY recorder this world has ever stood up, kept for the world's whole life. The
    /// fake's peripheral and central hold their stack `unowned`, so releasing one while any
    /// in-flight session still refers to it is a crash rather than a test failure — and the
    /// scenario that would trip it is precisely the one where a check is slow.
    private var stacks: [FakePocketBLEStack] = []
    private var identifier = UUID()
    private let secrets = InMemoryPocketSecretStore()
    private let recovery = InMemoryPocketKeyRecoveryStore()

    // MARK: Given

    func given(_ phrase: String) async throws {
        switch phrase {
        case "a remembered recorder holding one recording":
            try await stageRecorder(holding: [
                .init(date: Self.day, timestamp: Self.timestamp, sizeBytes: 900,
                      content: Self.mp3(900)),
            ])
        case "a remembered recorder holding nothing":
            try await stageRecorder(holding: [])
        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    /// Stand a recorder up, put the key for it where the shipped attachment will look, and
    /// point the APP'S model at that radio. Everything after this line is production code.
    private func stageRecorder(holding inventory: [FakePocketBLEStack.ScriptedRecording])
        async throws {
        identifier = UUID()
        let made = FakePocketBLEStack(deviceId: identifier,
                                      deviceName: Self.recorderName,
                                      acceptedSecret: Self.secret,
                                      inventory: inventory)
        stacks.append(made)
        try await secrets.save(
            Self.secret,
            for: try PocketAuthenticatedIdentity(peripheralIdentifier: identifier.uuidString))
        let secrets = self.secrets
        let recovery = self.recovery
        PocketRecorderCheckModel.attachmentFactoryForScenarios = {
            RecordingDeviceAttachment(
                makeCentral: made.factory,
                secrets: secrets,
                recovery: recovery,
                deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 5),
                log: nil)
        }
    }

    // MARK: When

    func when(_ phrase: String) async throws {
        switch phrase {
        // THE APP'S ENTRY POINT, WITH THE APP'S ARGUMENTS. `hardwareToken` is the peripheral
        // identifier, which is exactly what `input.identity.hardwareToken` carries on the page.
        case "Solleva asks that recorder what it is holding":
            check.run(hardwareToken: identifier.uuidString, advertisedName: Self.recorderName)
            try await AppScenarioHost.settle(untilTrue: { !self.check.isChecking },
                                             describing: "the check to finish")

        case "I bring the offered recording over":
            check.bringOver(hardwareToken: identifier.uuidString,
                            advertisedName: Self.recorderName)
            // BOTH FLAGS, because `bringOver` ends by re-running the check — and the whole
            // point of the last Then is that it does. Waiting on `isBringingOver` alone would
            // read the shelf mid-re-read and the scenario would be a race.
            try await AppScenarioHost.settle(
                untilTrue: { !self.check.isBringingOver && !self.check.isChecking },
                describing: "the bring-over and the shelf re-read that follows it")

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    // MARK: Then

    func then(_ phrase: String) throws {
        switch phrase {
        case "Solleva says what is on the recorder":
            guard let detail = check.detail else {
                throw BrineStepError(
                    "the app's model produced no shelf at all. Its message was: "
                        + (check.message ?? "(none)"))
            }
            guard detail.name.isEmpty == false else {
                throw BrineStepError("the shelf named no recorder")
            }

        case "Solleva offers to bring that recording over":
            guard let offered = check.offeredRecording else {
                throw BrineStepError(
                    "the recorder is holding a recording and the app offered nothing to bring "
                        + "over. `PocketBringOver.offered` works — the hostless suite proves "
                        + "that, and proved it while nothing on earth called it — so what is "
                        + "missing is the CALLER in App/DeviceScreen.swift. The shelf the app "
                        + "did read: \(check.detail?.manifest.rows.count ?? 0) row(s)")
            }
            guard offered.timestamp == Self.timestamp else {
                throw BrineStepError("the app offered \(offered.timestamp), not the recording "
                                        + "on the recorder (\(Self.timestamp))")
            }

        case "Solleva offers nothing to bring over":
            guard check.offeredRecording == nil else {
                throw BrineStepError(
                    "the recorder is holding nothing and the app still offered to bring "
                        + "something over")
            }

        case "Solleva says it kept the recording":
            guard check.bringOverMessage == PocketBringOverPresentation.broughtOverLine else {
                throw BrineStepError(
                    "the app said \"\(check.bringOverMessage ?? "(nothing at all)")\" rather "
                        + "than that it kept the recording")
            }

        // THE LOAD-BEARING ONE. Custody is a fact about this phone's disk, and the only way
        // the page can state it is if the app (a) hands `custody` to the check and (b) asks
        // again after a transfer. Remove either from App/DeviceScreen.swift and this is red;
        // nothing else in the repository moves.
        case "the recorder's shelf now says that recording is in Solleva":
            let rows = check.detail?.manifest.rows ?? []
            guard let row = rows.first else {
                throw BrineStepError("the shelf has no rows after the bring-over — the app "
                                        + "never re-read it")
            }
            guard row.custodyLabel == "In Solleva" else {
                throw BrineStepError(
                    "the row still reads \"\(row.custodyLabel)\" after the file landed. Either "
                        + "the app never asked custody, or it never re-read the shelf")
            }

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }
}
