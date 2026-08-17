import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryX

/// ONE TAP IS ONE ERRAND — asserted inside the shipping app, against the shipping model.
///
/// WHAT THESE HOLD THAT NOTHING ELSE COULD. Every claim here is about how many times
/// `App/DeviceScreen.swift` goes to the radio, what it leaves behind when it does, and what
/// happens when the owner walks away mid-transfer. None of it is visible to
/// `Tests/FoundryXBrineTests`, which cannot compile `App/` at all: the kit-level bring-over
/// scenarios pass identically whether the app opens one session or three.
///
/// THE MUTATIONS THESE ANSWER TO, all edits to `App/DeviceScreen.swift`:
///   * restore `self.run(…)` at the end of `bringOver` and the session count doubles —
///     "Bringing a recording over talks to the recorder once" goes red, and so does the
///     rebuild count;
///   * delete `cancel()`'s body and the radio stays connected and the transport stays bound
///     after the page is gone — "Walking away stops the errand" goes red;
///   * delete `beginErrand` / `finishErrand` and there is nothing to read afterwards — both
///     record scenarios go red;
///   * let the shelf be recomputed anywhere but `rebuildShelf` and the count exceeds two.
final class OneTapIsOneErrandFeatureTests: XCTestCase {

    /// The DEBUG radio seam is process-global, so it is cleared whatever the scenario did.
    override func tearDown() async throws {
        await MainActor.run { PocketRecorderCheckModel.attachmentFactoryForScenarios = nil }
        try await super.tearDown()
    }

    func testOneTapOnARecorderIsOneErrand() async throws {
        let world = await OneErrandWorld()
        let result = try await BrineFeatureRunner.run(
            "one-tap-on-a-recorder-is-one-errand",
            registry: StepRegistry(OneErrandSteps.make(world)))
        // THE POPULATION IS PINNED. A runner that only asserts "nothing failed" is green once
        // the scenarios have been deleted.
        XCTAssertEqual(result.passed, 6, "all six scenarios must run and pass")
    }
}

// MARK: - Steps

private enum OneErrandSteps {
    static func make(_ world: OneErrandWorld) -> [StepDefinition] {
        let givens = [
            "a remembered recorder holding two recordings",
            "Solleva has asked that recorder what it is holding",
            "a recorder Solleva cannot reach",
        ]
        let whens = [
            "I bring the offered recording over",
            "I ask what the recorder is holding and leave the page before it answers",
            "I ask what that recorder is holding",
        ]
        let thens = [
            "Solleva opened exactly one more session with that recorder",
            "it never asked that recorder for its day list a second time",
            "the shelf says that recording is in Solleva",
            "Solleva offers a different recording to bring over next",
            "Solleva is no longer holding that recorder open",
            "anything the recorder says after that reaches nobody",
            "Solleva is not still telling me it is checking",
            "the record says an errand started and that it finished",
            "the record says the recording was taken into Solleva's keeping",
            "the record does not claim anything was taken into Solleva's keeping",
            "Solleva rebuilt what it shows about that recorder exactly twice",
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
private final class OneErrandWorld {
    private static let secret = "0123456789abcdef"
    private static let recorderName = "PKT01_BLUE_26079bc5"
    private static let day = "2026-03-28"
    /// THE SMALLER ONE, therefore the one offered first: `PocketDurableSync.ordered` picks the
    /// newest day and then the SMALLEST file, so a short recording is the first thing anybody
    /// pulls off a recorder.
    private static let offeredTimestamp = "20260328001919"
    /// The one that is still there afterwards — the whole point of "offers a different one".
    private static let remainingTimestamp = "20260328002500"

    private static func fixtureMP3() throws -> Data {
        guard let url = Bundle(for: OneTapIsOneErrandFeatureTests.self)
            .url(forResource: "pocket-fw16-3s", withExtension: "mp3") else {
            throw BrineStepError("the Pocket audio fixture is not in the scenario bundle")
        }
        return try Data(contentsOf: url)
    }

    /// THE APP'S OWN MODEL — the type `App/DeviceScreen.swift` creates with `@StateObject`.
    private let check = PocketRecorderCheckModel()

    private let library: URL
    private let manager: CaptureManager

    /// Every recorder this world has stood up. The fake's peripheral and central hold their
    /// stack `unowned`, so releasing one while an in-flight session still refers to it is a
    /// crash rather than a failure — and a slow check is exactly the scenario that trips it.
    private var stacks: [FakePocketBLEStack] = []
    private var stack: FakePocketBLEStack!
    private var identifier = UUID()
    private let secrets = InMemoryPocketSecretStore()
    private let recovery = InMemoryPocketKeyRecoveryStore()

    // MARK: What one scenario measures against

    /// THE WORLD IS SHARED ACROSS THE FEATURE'S SIX SCENARIOS — that is the runner's shape,
    /// and it is right here because the app's model is a `@StateObject` that outlives a
    /// screen too. So everything cumulative is snapshotted at the scenario's first Given and
    /// asserted as a DIFFERENCE. "The total" would be the wrong question.
    private var commandsAtScenarioStart = 0
    private var rebuildsAtScenarioStart = 0
    /// The recorder's own command log at the moment the When began.
    private var wireAtWhen: [String] = []

    init() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("one-errand-library-\(UUID().uuidString)", isDirectory: true)
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
            let audio = try Self.fixtureMP3()
            try await stageRecorder(holding: [
                .init(date: Self.day, timestamp: Self.offeredTimestamp,
                      sizeBytes: audio.count, content: audio),
                // Three times the size, so ordering cannot pick it first. It is never pulled
                // in any scenario here; it exists to make "a DIFFERENT one next" a real claim
                // rather than a vacuous nil.
                .init(date: Self.day, timestamp: Self.remainingTimestamp,
                      sizeBytes: audio.count * 3, content: audio),
            ])

        case "a recorder Solleva cannot reach":
            try await stageRecorder(holding: [])
            // REFUSED, not silent: the connect gate answers immediately instead of burning
            // the deadline, and the failure this scenario is about is the RECORD, not the
            // reason. `neverAnswersConnect` would assert the same thing five seconds slower.
            stack.reachability.refusesToConnect = true

        case "Solleva has asked that recorder what it is holding":
            check.run(hardwareToken: identifier.uuidString, advertisedName: Self.recorderName,
                      library: library, stages: [:], brain: .myComputer)
            try await AppScenarioHost.settle(untilTrue: { !self.check.isChecking },
                                             describing: "the check to finish")
            guard check.offeredRecording != nil else {
                throw BrineStepError(
                    "the check produced no offer, so the scenario cannot proceed. The app "
                        + "said: \(check.message ?? "(nothing)")")
            }

        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    private func stageRecorder(holding inventory: [FakePocketBLEStack.ScriptedRecording])
        async throws {
        commandsAtScenarioStart = DoorLog.shared.commands.count
        rebuildsAtScenarioStart = check.shelfRebuildCountForTests
        identifier = UUID()
        let made = FakePocketBLEStack(deviceId: identifier,
                                      deviceName: Self.recorderName,
                                      acceptedSecret: Self.secret,
                                      inventory: inventory)
        stacks.append(made)
        stack = made
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
        case "I bring the offered recording over":
            wireAtWhen = stack.commandsWritten
            check.bringOver(hardwareToken: identifier.uuidString,
                            advertisedName: Self.recorderName,
                            into: manager)
            try await AppScenarioHost.settle(
                untilTrue: { !self.check.isBringingOver && !self.check.isChecking },
                describing: "the bring-over to finish")

        // THE DEPARTURE, STAGED SO IT IS DETERMINISTIC. `holdNotifyConfirmation` makes the
        // radio withhold the subscription confirmation the key handshake waits on, which is
        // the real, observed shape of a recorder that is slow to answer — so the errand is
        // genuinely mid-flight when the page goes away, rather than incidentally so.
        case "I ask what the recorder is holding and leave the page before it answers":
            stack.holdNotifyConfirmation = true
            check.run(hardwareToken: identifier.uuidString, advertisedName: Self.recorderName,
                      library: library, stages: [:], brain: .myComputer)
            // WAIT UNTIL THE RADIO IS ACTUALLY IN USE. Cancelling before the app has reached
            // the device would prove nothing — the positive control for the whole scenario.
            try await AppScenarioHost.settle(
                untilTrue: { self.stack.isConnected },
                describing: "the app to reach the recorder before the page goes away")
            // WHAT `onDisappear` CALLS, and the one line of this scenario that is a stand-in:
            // this lane cannot dismiss a SwiftUI view, so it calls what the view calls. That
            // the view calls it is held by `RecorderPageErrandWiringTests` over the source.
            check.cancel()

        case "I ask what that recorder is holding":
            wireAtWhen = stack.commandsWritten
            check.run(hardwareToken: identifier.uuidString, advertisedName: Self.recorderName,
                      library: library, stages: [:], brain: .myComputer)
            try await AppScenarioHost.settle(untilTrue: { !self.check.isChecking },
                                             describing: "the check to finish")

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    // MARK: Then

    func then(_ phrase: String) async throws {
        switch phrase {
        // ONE `SK&` IS ONE AUTHENTICATED SESSION. The key handshake happens once per session
        // and nowhere else, so counting it counts sessions — and it is counted at the
        // recorder, from the bytes the app actually wrote, not from anything the app claims.
        case "Solleva opened exactly one more session with that recorder":
            let opened = sinceWhen.filter { $0.hasPrefix("SK&") }
            guard opened.count == 1 else {
                throw BrineStepError(
                    "one tap opened \(opened.count) session(s) with the recorder, not one. "
                        + "Everything the app wrote after the tap: \(sinceWhen)")
            }

        case "it never asked that recorder for its day list a second time":
            let listings = stack.commandsWritten.filter { $0 == "LIST_DIRS" }
            guard listings.count == 1 else {
                throw BrineStepError(
                    "the app asked this recorder for its day list \(listings.count) time(s). "
                        + "Once is the check the owner asked for; a second is the shelf being "
                        + "re-read over the radio for a fact the phone's own disk already knew")
            }

        case "the shelf says that recording is in Solleva":
            let rows = check.detail?.manifest.rows ?? []
            guard rows.count == 2 else {
                throw BrineStepError("the shelf has \(rows.count) row(s), not the two files "
                                        + "on the recorder — it was not rebuilt")
            }
            // THE FACT FIRST, then that it is said in words. A row's custody is no longer a
            // two-valued label — it is one answer inside the three-place reading — so
            // asserting the sentence alone would pass on a row that says "In Solleva" while
            // knowing nothing, and would red on a rewording that changed nothing.
            guard rows.contains(where: { $0.presence.onThisPhone.answer == .yes }) else {
                throw BrineStepError(
                    "no row says this phone holds the file after it landed. The shelf was "
                        + "restated without asking custody")
            }
            guard rows.contains(where: { $0.presenceLabel.contains("In Solleva") }) else {
                throw BrineStepError(
                    "a row knows this phone holds the file and does not say so: "
                        + "\(rows.map(\.presenceLabel))")
            }

        case "Solleva offers a different recording to bring over next":
            guard let offered = check.offeredRecording else {
                throw BrineStepError("the recorder is still holding a recording Solleva has "
                                        + "never had, and the app offered nothing")
            }
            guard offered.timestamp == Self.remainingTimestamp else {
                throw BrineStepError(
                    "the app re-offered \(offered.timestamp) — the file it just brought over")
            }

        case "Solleva is no longer holding that recorder open":
            guard !stack.isConnected else {
                throw BrineStepError(
                    "the page is gone and the app is still connected to the recorder")
            }

        // THE STRONG FORM OF "NOBODY IS LISTENING". The fake holds its event sink WEAKLY, so
        // this is not a flag: it goes false when the last owner of the transport is released.
        // The recorder is then made to speak — the withheld confirmation is released, which is
        // exactly what a slow recorder eventually does — and nothing may consume it.
        case "anything the recorder says after that reaches nobody":
            try await AppScenarioHost.settle(
                untilTrue: { !self.stack.transportIsListening },
                timeout: 10,
                describing: "the app to let go of the radio after the page went away")
            let heardBefore = stack.notificationsHandedToTransport
            // THE POSITIVE CONTROL. If the recorder had never got a word in, "it now reaches
            // nobody" would be true of a conversation that never happened.
            guard heardBefore > 0 else {
                throw BrineStepError(
                    "this recorder never handed the app a single notification, so proving "
                        + "nothing reaches it now proves nothing at all")
            }
            stack.confirmNotifications()
            stack.drain()
            try? await Task.sleep(nanoseconds: 100_000_000)
            let heardAfter = stack.notificationsHandedToTransport
            guard heardAfter == heardBefore else {
                throw BrineStepError(
                    "the recorder spoke \(heardAfter - heardBefore) more time(s) after the "
                        + "page went away and something in the app was still there to hear it")
            }

        case "Solleva is not still telling me it is checking":
            guard !check.isChecking, !check.isBringingOver else {
                throw BrineStepError(
                    "the model is still busy after the page went away, so its own guard will "
                        + "refuse the next tap forever")
            }

        case "the record says an errand started and that it finished":
            let started = commandsThisScenario(named: PocketErrandCommand.start)
            let stopped = commandsThisScenario(named: PocketErrandCommand.stop)
            guard !started.isEmpty else {
                throw BrineStepError(
                    "nothing in the command record says an errand ever began. This is the "
                        + "slowest and most failure-prone thing the app does and it left "
                        + "nothing to read")
            }
            guard started.count == stopped.count else {
                throw BrineStepError(
                    "\(started.count) errand(s) started and \(stopped.count) stopped — an "
                        + "errand with no stop is one nobody can tell from one still running")
            }
            guard stopped.allSatisfy({ $0.outcome != nil }) else {
                throw BrineStepError("an errand stopped without saying how it ended")
            }

        case "the record says the recording was taken into Solleva's keeping":
            let kept = commandsThisScenario(named: PocketErrandCommand.custodyCommit)
            guard kept.count == 1 else {
                throw BrineStepError(
                    "the record holds \(kept.count) custody commits for one recording that "
                        + "landed. `errand.stop` alone cannot say whether anything was kept")
            }
            guard kept[0].subject == "\(Self.day)/\(Self.offeredTimestamp)" else {
                throw BrineStepError(
                    "the custody commit names \"\(kept[0].subject)\", which is not the file "
                        + "that was brought over")
            }

        // THE PROHIBITION, PAIRED WITH THE EXISTENCE ASSERTION ABOVE IT IN THE SAME SCENARIO:
        // an empty record satisfies this one vacuously, and "an errand started and finished"
        // is what rules that out.
        case "the record does not claim anything was taken into Solleva's keeping":
            let kept = commandsThisScenario(named: PocketErrandCommand.custodyCommit)
            guard kept.isEmpty else {
                throw BrineStepError(
                    "the errand never reached the recorder and the record claims \(kept.count) "
                        + "recording(s) were taken into custody")
            }

        // TWICE: once when the recorder answered the check, once when the recording landed.
        // Never a third time, because nothing else may recompute it — not the view, not a
        // second radio session, not a re-read nobody asked for.
        case "Solleva rebuilt what it shows about that recorder exactly twice":
            let rebuilds = check.shelfRebuildCountForTests - rebuildsAtScenarioStart
            guard rebuilds == 2 else {
                throw BrineStepError(
                    "the shelf was rebuilt \(rebuilds) time(s) for one check and one "
                        + "bring-over. Two is the whole vocabulary: the recorder answered, "
                        + "and a recording arrived")
            }

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    // MARK: Measurements

    /// Everything the app wrote to the recorder since this scenario's When began.
    private var sinceWhen: [String] {
        Array(stack.commandsWritten.dropFirst(wireAtWhen.count))
    }

    /// The commands the SHIPPING log holds for this scenario. `DoorLog.shared` is the log the
    /// app actually writes to and the one that reaches the relay; asserting against anything
    /// else would prove the scenario's own plumbing.
    private func commandsThisScenario(named name: String) -> [DoorLog.Command] {
        DoorLog.shared.commands
            .dropFirst(commandsAtScenarioStart)
            .filter { $0.name == name }
    }
}
