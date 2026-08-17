import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryX

/// FAST SYNC, EXECUTED INSIDE THE APPLICATION.
///
/// `features/pocket-fast-sync.feature` drives `PocketFastSyncCoordinator` directly and has been
/// green for months. It was green while the coordinator had ZERO production constructors and
/// the word "FastSync" appeared nowhere under `App/` — the repository's own reachability
/// register said `unreachable`, "constructed only in its own feature test". Green therefore
/// proved the handoff was RIGHT, not that anything reached it.
///
/// These scenarios drive the recorder page's own model — `PocketRecorderCheckModel` in
/// `App/DeviceScreen.swift` — inside the shipping app's process on a simulator. Everything they
/// touch is shipped code except the three things a hermetic run cannot own: the radio
/// (`FakePocketBLEStack`, the same scripted recorder the hostless suite drives), the WiFi
/// association, and an HTTP server on an address nobody has ever confirmed.
///
/// THE MUTATIONS THESE ANSWER TO, all edits to `App/DeviceScreen.swift`:
///   * delete the `PocketFastSyncErrand.run(` call from `fastSync` and nothing is ever kept;
///   * drop `manager.adoptCompletedCapture(` from it and the conversation is invisible to the
///     running app until the next launch;
///   * drop the shelf re-read and the row never learns the recording landed.
final class RecorderPageFastSyncFeatureTests: XCTestCase {

    override func tearDown() async throws {
        await MainActor.run {
            PocketRecorderCheckModel.attachmentFactoryForScenarios = nil
            PocketRecorderCheckModel.fastSyncSeamForScenarios = nil
        }
        try await super.tearDown()
    }

    func testSollevasRecorderPageCanBringARecordingOverTheRecordersOwnNetwork() async throws {
        let world = await FastSyncPageWorld()
        let result = try await BrineFeatureRunner.run(
            "a-recorders-page-offers-fast-sync",
            registry: StepRegistry(FastSyncPageSteps.make(world)))
        XCTAssertEqual(result.passed, 3, "all three scenarios must run and pass")
    }
}

private enum FastSyncPageSteps {
    static func make(_ world: FastSyncPageWorld) -> [StepDefinition] {
        let givens = [
            "a remembered recorder holding one recording",
            "a remembered recorder holding one recording and a network this phone can join",
            "a remembered recorder holding one recording and a network that serves no file",
        ]
        let whens = [
            "Solleva asks that recorder what it is holding",
            "I bring the offered recording over with fast sync",
        ]
        let thens = [
            "Solleva offers fast sync and says the phone leaves its normal network",
            "Solleva says it kept the recording",
            "the recorder's shelf now says that recording is in Solleva",
            "the recorder was put back on Bluetooth",
            "Solleva says nothing was kept",
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

@MainActor
private final class FastSyncPageWorld {
    private static let secret = "0123456789abcdef"
    private static let recorderName = "PKT01_BLUE_26079bc5"
    private static let day = "2026-03-28"
    private static let timestamp = "20260328001919"
    /// AN ADDRESS FOR THE SCENARIO ONLY. `PocketFastSyncEndpoint.measured` is nil in the
    /// shipping app because nobody has confirmed one; a scenario that used the shipped constant
    /// would be asserting the refusal, not the transfer.
    private static let scenarioEndpoint = URL(string: "http://192.0.2.1/scenario")!

    private static func fixtureMP3() throws -> Data {
        guard let url = Bundle(for: RecorderPageFastSyncFeatureTests.self)
            .url(forResource: "pocket-fw16-3s", withExtension: "mp3") else {
            throw BrineStepError("the Pocket audio fixture is not in the scenario bundle")
        }
        return try Data(contentsOf: url)
    }

    private let check = PocketRecorderCheckModel()
    private let library: URL
    private let manager: CaptureManager
    private var stacks: [FakePocketBLEStack] = []
    private var identifier = UUID()
    private let secrets = InMemoryPocketSecretStore()
    private let recovery = InMemoryPocketKeyRecoveryStore()

    init() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recorder-page-fastsync-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = root
        manager = CaptureManager(
            target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x"),
            baseDir: root,
            source: ReplaySource(frames: []),
            finalize: { _, _ in },
            uploadSegment: { _, _, _ in })
    }

    // MARK: Given

    func given(_ phrase: String) async throws {
        let audio = try Self.fixtureMP3()
        switch phrase {
        case "a remembered recorder holding one recording":
            try await stageRecorder(audio: audio, serves: audio)
        case "a remembered recorder holding one recording and a network this phone can join":
            try await stageRecorder(audio: audio, serves: audio)
        case "a remembered recorder holding one recording and a network that serves no file":
            try await stageRecorder(audio: audio, serves: nil)
        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    private func stageRecorder(audio: Data, serves served: Data?) async throws {
        identifier = UUID()
        let made = FakePocketBLEStack(deviceId: identifier,
                                      deviceName: Self.recorderName,
                                      acceptedSecret: Self.secret,
                                      inventory: [.init(date: Self.day, timestamp: Self.timestamp,
                                                        sizeBytes: audio.count, content: audio)])
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
        // THE PHONE THAT JOINS IS THE FAKE JOINER. That is not a shortcut: on real hardware the
        // recorder only leaves status 3 ("waiting for a client") BECAUSE a phone associated, so
        // a fake that joined without telling the recorder would hide the very ordering these
        // scenarios exist to hold.
        PocketRecorderCheckModel.fastSyncSeamForScenarios = .init(
            endpoint: Self.scenarioEndpoint,
            joiner: ScenarioJoiner(stack: made),
            http: ScenarioHTTP(payload: served),
            secrets: secrets)
    }

    // MARK: When

    func when(_ phrase: String) async throws {
        switch phrase {
        case "Solleva asks that recorder what it is holding":
            // THE SAME FOUR ARGUMENTS THE SHIPPING PAGE PASSES. This call was written against
            // a base that predates the safety predicate, and after the merge it drove a
            // signature that no longer exists.
            check.run(hardwareToken: identifier.uuidString, advertisedName: Self.recorderName,
                      library: manager.captureLibraryRoot, stages: manager.captureStages(),
                      brain: .myComputer)
            try await AppScenarioHost.settle(untilTrue: { !self.check.isChecking },
                                             describing: "the check to finish")
        case "I bring the offered recording over with fast sync":
            check.fastSync(hardwareToken: identifier.uuidString,
                           advertisedName: Self.recorderName,
                           into: manager,
                           brain: .myComputer)
            try await AppScenarioHost.settle(
                untilTrue: { !self.check.isBringingOver && !self.check.isChecking },
                describing: "the fast sync and the shelf re-read that follows it")
        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    // MARK: Then

    func then(_ phrase: String) async throws {
        switch phrase {
        case "Solleva offers fast sync and says the phone leaves its normal network":
            guard check.offeredRecording != nil else {
                throw BrineStepError("the page offers no recording, so it offers no fast sync "
                                        + "either — the button is rendered beside the offer")
            }
            guard PocketRecorderCheckModel.fastSyncCanRun else {
                throw BrineStepError("the page's fast sync action is not usable even with an "
                                        + "endpoint and a joinable network staged")
            }
            guard PocketFastSyncPresentation.sheetWarning.contains("leaves its normal WiFi") else {
                throw BrineStepError("the page does not say the phone leaves its own network")
            }

        case "Solleva says it kept the recording":
            guard check.bringOverMessage == PocketFastSyncPresentation.succeededLine else {
                throw BrineStepError(
                    "the app said \"\(check.bringOverMessage ?? "(nothing at all)")\" rather "
                        + "than that it kept the recording")
            }

        case "the recorder's shelf now says that recording is in Solleva":
            let rows = check.detail?.manifest.rows ?? []
            guard let row = rows.first else {
                throw BrineStepError("the shelf has no rows after the transfer — the app never "
                                        + "re-read it")
            }
            // THE FACT FIRST, then that it is said in words. Step 5 replaced the two-valued
            // custody label with a three-place reading, so an equality against one sentence
            // both over- and under-matches: the row now says WHERE it is and how old each
            // answer is.
            guard row.presence.onThisPhone.answer == .yes else {
                throw BrineStepError(
                    "the row still reads \"\(row.presenceLabel)\" after the file landed over "
                        + "WiFi. A fast-synced recording must land in the SAME custody a "
                        + "Bluetooth one does, or the page is telling the truth about one "
                        + "transport and not the other")
            }

        case "the recorder was put back on Bluetooth":
            guard let stack = stacks.last else { throw BrineStepError("no recorder was staged") }
            guard stack.accessPointStatus == 0 else {
                throw BrineStepError("the recorder was left with its access point UP "
                                        + "(status \(stack.accessPointStatus)) — on somebody's "
                                        + "desk, out of sight, until its battery goes")
            }
            guard stack.accessPointCloseCount >= 1 else {
                throw BrineStepError("nothing ever sent WIFIC, so the teardown is an accident "
                                        + "of the fixture rather than something the app did")
            }

        case "Solleva says nothing was kept":
            guard check.bringOverMessage == PocketFastSyncPresentation.transferFailedLine else {
                throw BrineStepError(
                    "a network that served no file produced \"\(check.bringOverMessage ?? "nothing")\" "
                        + "rather than saying nothing was kept")
            }
            let rows = check.detail?.manifest.rows ?? []
            if rows.first?.presence.onThisPhone.answer == .yes {
                throw BrineStepError("the shelf claims Solleva is holding a recording that "
                                        + "never arrived")
            }

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }
}

/// The phone, as far as the recorder is concerned.
private struct ScenarioJoiner: PocketSoftAPJoining {
    let stack: FakePocketBLEStack
    func join(_ accessPoint: PocketAccessPoint) async throws {
        // The credential is the one the RECORDER reported. A joiner that accepted anything
        // would make the possession gate untestable from here.
        guard accessPoint.ssid == stack.deviceName, accessPoint.password.count == 8 else {
            throw PocketFastSyncGap.joinFailed
        }
        stack.clientJoinedTheAccessPoint()
    }
}

/// An address that either serves the file or answers nothing at all — which is the outcome the
/// unconfirmed real endpoint is most likely to produce.
private struct ScenarioHTTP: PocketHTTPPulling {
    let payload: Data?
    func pull(_ endpoint: URL) async throws -> Data {
        guard let payload else { throw PocketFastSyncGap.httpFailed }
        return payload
    }
}
