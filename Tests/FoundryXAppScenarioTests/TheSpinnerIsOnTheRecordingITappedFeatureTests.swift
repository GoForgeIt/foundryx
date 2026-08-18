import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryX

/// THE SPINNER IS ON THE RECORDING I TAPPED — asserted inside the shipping app, against the
/// shipping model.
///
/// WHAT NICK REPORTED, on his own unit: tapping `Bring over` on one recording sent him back to
/// the list, where a single spinner at the top of the page said something was happening and
/// could not say what. The cause is a model with one in-flight flag per KIND of errand and no
/// subject on any of them — the same missing per-recording identity that made the rows inert.
///
/// NONE OF THIS IS VISIBLE TO `Tests/FoundryXBrineTests`, which cannot compile `App/` at all:
/// the kit's rule about which row shows progress passes identically whether or not the app
/// ever tells it which recording is moving. That wiring is what these scenarios hold.
///
/// THE MUTATIONS THESE ANSWER TO, all edits to `App/DeviceScreen.swift`:
///   * drop the recording from `beginErrand(…, about:)` on the bring-over path and the row the
///     owner tapped stops saying anything — "the recording I asked for is the one that says it
///     is working" goes red;
///   * pass the OFFERED recording instead of the one asked for and the same scenario goes red,
///     because the second recording is deliberately not the offered pick;
///   * stop clearing `inFlight` in `finishErrand` and "nothing is left spinning once the errand
///     is over" goes red — a spinner that outlives its errand is the state this page shipped
///     with for `isChecking` once already;
///   * hand `beginErrand` a recording on the SHELF path and "reading the shelf is about the
///     recorder" goes red, because a check would put a spinner on somebody's row.
final class TheSpinnerIsOnTheRecordingITappedFeatureTests: XCTestCase {

    /// The DEBUG radio seam is process-global, so it is cleared whatever the scenario did.
    override func tearDown() async throws {
        await MainActor.run { PocketRecorderCheckModel.attachmentFactoryForScenarios = nil }
        try await super.tearDown()
    }

    func testTheSpinnerIsOnTheRecordingITapped() async throws {
        let world = await SpinnerWorld()
        let result = try await BrineFeatureRunner.run(
            "the-spinner-is-on-the-recording-i-tapped",
            registry: StepRegistry(SpinnerSteps.make(world)))
        // THE POPULATION IS PINNED. A runner that only asserts "nothing failed" is green once
        // the scenarios have been deleted.
        XCTAssertEqual(result.passed, 4, "all four scenarios must run and pass")
    }
}

// MARK: - Steps

private enum SpinnerSteps {
    static func make(_ world: SpinnerWorld) -> [StepDefinition] {
        let givens = [
            "a remembered recorder holding two recordings",
            "that recorder has become slow to answer",
        ]
        let whens = [
            "I ask for the second recording by name",
            "I leave the recorder's page",
            "I ask what that recorder is holding",
        ]
        let thens = [
            "that recording says it is being brought over",
            "the other recording does not say it is being brought over",
            "the other recording says why it cannot be asked for right now",
            "no recording says it is being brought over",
            "the page says it is checking the recorder",
            "the record names that recording as what the errand is about",
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

/// `@MainActor` because `PocketRecorderCheckModel` is.
@MainActor
private final class SpinnerWorld {
    private static let secret = "0123456789abcdef"
    private static let recorderName = "PKT01_BLUE_26079bc5"
    private static let day = "2026-03-28"
    /// THE SMALLER ONE, therefore the one the page OFFERS — `PocketBringOver.offered` picks
    /// the smallest on the newest day.
    private static let offeredTimestamp = "20260328001919"
    /// THE ONE THE OWNER ASKS FOR BY NAME. It is deliberately NOT the offered pick, so a model
    /// that reports "the transfer that is running" without a subject cannot pass by accident.
    private static let askedForTimestamp = "20260328181500"

    private var offeredId: String { "\(Self.day)/\(Self.offeredTimestamp)" }
    private var askedForId: String { "\(Self.day)/\(Self.askedForTimestamp)" }

    /// THE APP'S OWN MODEL — the type `App/DeviceScreen.swift` creates with `@StateObject`.
    private let check = PocketRecorderCheckModel()

    private let library: URL
    private let manager: CaptureManager

    /// Every recorder this world has stood up, HELD FOR THE LIFE OF THE PROCESS.
    ///
    /// The fake's peripheral and central hold their stack `unowned`, so releasing one while a
    /// session still refers to it is a CRASH rather than a failure. These scenarios END with a
    /// hung session on purpose — an errand nobody stopped is exactly what a spinner is about —
    /// so a static array is the only place the fake radio can outlive the world that staged
    /// it. (Measured: with an instance array this whole lane died on "Attempted to read an
    /// unowned reference but object … was already deallocated", which reads like an ownership
    /// bug in the app and is not one.)
    private static var stacks: [FakePocketBLEStack] = []
    private var stack: FakePocketBLEStack!
    private var identifier = UUID()
    private let secrets = InMemoryPocketSecretStore()
    private let recovery = InMemoryPocketKeyRecoveryStore()

    /// Where the process-wide command stream stood when this scenario's errand began. The log
    /// is shared with every other suite in this process, so the claim is about the DELTA.
    private var commandsAtScenarioStart = 0

    init() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spinner-library-\(UUID().uuidString)", isDirectory: true)
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
        switch phrase {
        case "a remembered recorder holding two recordings":
            // THE PREVIOUS SCENARIO LEFT AN ERRAND HANGING ON PURPOSE. One world serves the
            // whole feature, and the model refuses a second errand while one is in flight — so
            // a scenario that did not stop the last one would be staged against a model that
            // ignores it.
            check.cancel()
            try await stageRecorder(holding: [
                .init(date: Self.day, timestamp: Self.offeredTimestamp, sizeBytes: 4_096),
                .init(date: Self.day, timestamp: Self.askedForTimestamp, sizeBytes: 65_536),
            ])
            // THE PAGE ALWAYS ASKS BEFORE IT CAN OFFER. A bring-over by name is resolved out of
            // the listing this check produced, so without it there is nothing to ask for.
            check.run(hardwareToken: identifier.uuidString, advertisedName: Self.recorderName,
                      library: manager.captureLibraryRoot, stages: manager.captureStages(),
                      brain: .myComputer)
            try await AppScenarioHost.settle(untilTrue: { !self.check.isChecking },
                                             describing: "the first check to finish")
            guard check.detail != nil else {
                throw BrineStepError("the recorder answered nothing, so there is no shelf to "
                                        + "ask about: \(check.message ?? "(no message)")")
            }

        // THE ERRAND HAS TO STILL BE RUNNING WHEN THE SCENARIO LOOKS AT IT. `holdNotify
        // Confirmation` withholds the subscription confirmation the key handshake waits on —
        // the observed shape of a recorder that is slow to answer — so the errand stays in
        // flight instead of finishing before anything can be asserted about it.
        case "that recorder has become slow to answer":
            stack.holdNotifyConfirmation = true

        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    private func stageRecorder(holding inventory: [FakePocketBLEStack.ScriptedRecording])
        async throws {
        identifier = UUID()
        let made = FakePocketBLEStack(deviceId: identifier,
                                      deviceName: Self.recorderName,
                                      acceptedSecret: Self.secret,
                                      inventory: inventory)
        Self.stacks.append(made)
        stack = made
        try await secrets.save(
            Self.secret,
            for: try PocketAuthenticatedIdentity(peripheralIdentifier: identifier.uuidString))
        RecordingDeviceStore.recordUserPair(
            identity: RecordingDeviceIdentity(shape: .filePull,
                                              hardwareToken: identifier.uuidString.lowercased()),
            displayName: Self.recorderName)
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
        // THE OWNER SAID "THAT ONE" — the entry point the detail sheet calls, with the
        // recorder's own name for the file, exactly as `App/DeviceScreen.swift` passes it.
        case "I ask for the second recording by name":
            commandsAtScenarioStart = DoorLog.shared.commands.count
            check.bringOver(id: askedForId,
                            hardwareToken: identifier.uuidString,
                            advertisedName: Self.recorderName,
                            into: manager)
            // THE POSITIVE CONTROL. Asserting about an errand that never reached the recorder
            // would prove nothing.
            try await AppScenarioHost.settle(
                untilTrue: { self.stack.isConnected && self.check.isBringingOver },
                describing: "the transfer to actually reach the recorder")

        case "I leave the recorder's page":
            check.cancel()

        case "I ask what that recorder is holding":
            commandsAtScenarioStart = DoorLog.shared.commands.count
            check.run(hardwareToken: identifier.uuidString, advertisedName: Self.recorderName,
                      library: manager.captureLibraryRoot, stages: manager.captureStages(),
                      brain: .myComputer)
            try await AppScenarioHost.settle(
                untilTrue: { self.stack.isConnected && self.check.isChecking },
                describing: "the check to actually reach the recorder")

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    // MARK: Then

    /// What the shelf row for `id` would draw — the SAME call `App/DeviceScreen.swift` makes,
    /// so a scenario cannot pass against a rule the page does not use.
    private func progress(for id: String) -> PocketErrandProgress {
        PocketErrandProgressPresentation.progress(check.inFlight, for: id)
    }

    func then(_ phrase: String) async throws {
        switch phrase {
        case "that recording says it is being brought over":
            guard check.inFlight?.recordingId == askedForId else {
                throw BrineStepError(
                    "the errand in flight is about \(check.inFlight?.recordingId ?? "nothing") "
                        + "and the owner asked for \(askedForId). Nothing in the app can put a "
                        + "spinner on the row they tapped")
            }
            let mine = progress(for: askedForId)
            guard mine.isThisRecording else {
                throw BrineStepError("the row the owner tapped shows no progress: \(mine)")
            }
            guard mine.line == PocketBringOverPresentation.inProgressLine else {
                throw BrineStepError("the row says \(mine.line ?? "nothing") while a transfer "
                                        + "is running on it")
            }

        case "the other recording does not say it is being brought over":
            let other = progress(for: offeredId)
            guard !other.isThisRecording else {
                throw BrineStepError("a recording nobody asked for is showing a transfer's "
                                        + "progress, which is a lie about where the bytes go")
            }

        case "the other recording says why it cannot be asked for right now":
            let other = progress(for: offeredId)
            guard other.blocksAnAction, let line = other.line, !line.isEmpty else {
                throw BrineStepError("the other recording's action is blocked with no sentence "
                                        + "saying why: \(other)")
            }

        case "no recording says it is being brought over":
            for id in [offeredId, askedForId] {
                let state = progress(for: id)
                guard !state.isThisRecording else {
                    throw BrineStepError("\(id) is still showing progress after the errand "
                                            + "ended — a spinner that outlives its errand")
                }
            }

        case "the page says it is checking the recorder":
            guard check.isChecking else {
                throw BrineStepError("the page is not checking anything")
            }
            guard check.inFlight?.recordingId == nil else {
                throw BrineStepError(
                    "a shelf read claims to be about \(check.inFlight?.recordingId ?? "") — so a "
                        + "check would put a spinner on one recording's row for work that is "
                        + "not about it")
            }
            guard progress(for: offeredId).line == PocketRecorderCheckPresentation.checkingLine
            else {
                throw BrineStepError("the page does not say it is checking the recorder")
            }

        case "the record names that recording as what the errand is about":
            let since = DoorLog.shared.commands.dropFirst(commandsAtScenarioStart)
            let starts = since.filter { $0.name == PocketErrandCommand.start }
            guard let started = starts.first else {
                throw BrineStepError("no errand.start was recorded at all")
            }
            guard started.about == askedForId else {
                throw BrineStepError(
                    "the record says the errand is about \(started.about ?? "nothing"), so the "
                        + "one instrument this project reads cannot say which recording a slow "
                        + "transfer was for")
            }
            guard started.subject == PocketErrandCommand.bringOverSubject else {
                throw BrineStepError("the errand is recorded as \(started.subject)")
            }

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }
}
