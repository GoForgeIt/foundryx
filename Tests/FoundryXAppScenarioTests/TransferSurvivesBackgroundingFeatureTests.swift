import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryX

/// A TRANSFER THAT SURVIVES A SCREENSHOT — asserted inside the shipping app, against the
/// shipping model.
///
/// WHAT THESE HOLD THAT NOTHING ELSE COULD. The defect was one comparison inside a SwiftUI
/// body (`if phase != .active { check.cancel() }`) and the fix is a lifecycle: background time
/// taken when an errand starts, released on every path out of it. `Tests/FoundryXBrineTests`
/// cannot compile `App/` at all, so it can hold the RULE (`PocketBackgroundErrandTests`) and
/// the WIRING as text (`RecorderPageErrandWiringTests`) — and neither of those can tell you
/// whether a transfer that is actually in flight, on an actually-connected radio, is still in
/// flight after the app reports `.inactive`.
///
/// THE MUTATIONS THESE ANSWER TO, all edits to `App/DeviceScreen.swift`:
///   * restore `if phase != .active { check.cancel() }` in the page body and route the phase
///     through it — "Taking a screenshot of a transfer does not stop the transfer" goes red;
///   * delete `lease.begin(subject:)` from `beginErrand` — "A transfer asks the system for the
///     time to finish in" goes red, and so does "Putting the phone away mid-transfer does not
///     stop the transfer", because the policy then reads an unprotected errand as stoppable;
///   * delete `lease.end()` from `finishErrand` — every "gives the time back" scenario goes
///     red, which is the leak that gets an app terminated by the watchdog;
///   * make `sceneChanged(to:)` ignore `.background` entirely — "A transfer the system will
///     not make room for stops when the phone is put away" goes red, because the page would
///     then sit there claiming to work inside a process about to be suspended.
final class TransferSurvivesBackgroundingFeatureTests: XCTestCase {

    /// Both DEBUG seams are process-global, so both are cleared whatever the scenario did.
    ///
    /// AND THE RADIO IS LEFT QUIET, which is not hygiene — it is the difference between this
    /// suite passing and the NEXT one crashing. The whole point of these scenarios is a
    /// transfer that is deliberately still in flight when something interrupts it, and a
    /// session that is still winding down when the process moves on to another bundle takes
    /// its scripted radio with it. Measured, not theorised: the first green run of this file
    /// was followed by `UnansweredKeyDoesNotTrapMeFeatureTests` dying on "Attempted to read an
    /// unowned reference but object was already deallocated" four seconds later.
    override func tearDown() async throws {
        try? await SurvivesBackgroundingWorld.settleEveryRadio()
        await MainActor.run {
            PocketRecorderCheckModel.attachmentFactoryForScenarios = nil
            PocketRecorderCheckModel.backgroundTimeForScenarios = nil
        }
        try await super.tearDown()
    }

    func testATransferSurvivesAScreenshotAndAPocket() async throws {
        let world = await SurvivesBackgroundingWorld()
        let result = try await BrineFeatureRunner.run(
            "a-transfer-survives-a-screenshot",
            registry: StepRegistry(SurvivesBackgroundingSteps.make(world)))
        // THE POPULATION IS PINNED. A runner that only asserts "nothing failed" is green once
        // the scenarios have been deleted.
        XCTAssertEqual(result.passed, 9, "all nine scenarios must run and pass")
    }
}

// MARK: - Steps

private enum SurvivesBackgroundingSteps {
    static func make(_ world: SurvivesBackgroundingWorld) -> [StepDefinition] {
        let givens = [
            "a system that will not make room for anything to finish",
            "a remembered recorder holding one recording",
            "a recorder Solleva cannot reach",
            "a transfer that is under way",
        ]
        let whens = [
            "something momentary interrupts the app",
            "I put the phone away",
            "the transfer is allowed to finish",
            "I leave the page",
            "the errand is stopped outright",
            "the system takes the time back",
            "I ask what that recorder is holding",
        ]
        let thens = [
            "the transfer is still under way",
            "Solleva is still holding the recorder open",
            "the transfer then finishes and Solleva keeps the recording",
            "Solleva has asked the system for time to finish it",
            "Solleva has given back every piece of time it asked for",
            "the transfer is no longer under way",
            "the record says it stopped because there was no time to finish in",
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
private final class SurvivesBackgroundingWorld {
    private static let secret = "0123456789abcdef"
    private static let recorderName = "PKT01_BLUE_26079bc5"
    private static let day = "2026-03-28"
    private static let timestamp = "20260328001919"

    private static func fixtureMP3() throws -> Data {
        guard let url = Bundle(for: TransferSurvivesBackgroundingFeatureTests.self)
            .url(forResource: "pocket-fw16-3s", withExtension: "mp3") else {
            throw BrineStepError("the Pocket audio fixture is not in the scenario bundle")
        }
        return try Data(contentsOf: url)
    }

    /// THE APP'S OWN MODEL — the type `App/DeviceScreen.swift` creates with `@StateObject`.
    ///
    /// BUILT PER SCENARIO, unlike `OneErrandWorld`'s, because the thing being measured here is
    /// a LEASE the model takes at construction: a model shared across scenarios would carry
    /// one scenario's background-time budget into the next, and the scenario that needs a
    /// system which refuses could never be staged at all.
    private var check: PocketRecorderCheckModel!

    /// The system's background-time budget, which a hermetic run cannot own.
    private var time = ScriptedBackgroundTime()
    /// Whether the NEXT model is built against a system that grants nothing.
    private var systemRefusesTime = false

    private let library: URL
    private let manager: CaptureManager

    /// Every recorder this world has stood up, HELD FOR THE LIFE OF THE PROCESS.
    ///
    /// The fake's peripheral and central hold their stack `unowned`, so releasing one while a
    /// session still refers to it is a CRASH rather than a failure. Every other world in this
    /// lane keeps its stacks in an instance array, which is enough when each scenario ends
    /// with the radio quiet — and this file's scenarios are precisely the ones that do not:
    /// a transfer held open mid-handshake is the subject, not an accident. A static array is
    /// the only place a fake radio can outlive the world that staged it.
    private static var stacks: [FakePocketBLEStack] = []
    private var stack: FakePocketBLEStack!

    private var identifier = UUID()
    private let secrets = InMemoryPocketSecretStore()
    private let recovery = InMemoryPocketKeyRecoveryStore()

    /// Wait until nothing in the app is bound to any of these radios. `transportIsListening`
    /// is a weak-reference read rather than a flag, so this is the true "everybody has let go"
    /// and not a bookkeeping claim.
    static func settleEveryRadio() async throws {
        try await AppScenarioHost.settle(
            untilTrue: { !stacks.contains { $0.transportIsListening } },
            timeout: 30,
            describing: "every scripted recorder to be let go of")
    }

    /// The shipping log's length when this scenario began. Every claim about the record is a
    /// DIFFERENCE — `DoorLog.shared` is process-wide and outlives a scenario.
    private var commandsAtScenarioStart = 0

    init() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("survives-backgrounding-\(UUID().uuidString)", isDirectory: true)
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
        // ORDERED BEFORE THE RECORDER ON PURPOSE, and the feature file says so: the model
        // leases from whatever budget existed when it was BUILT, which is the same moment the
        // shipping `@StateObject` resolves.
        case "a system that will not make room for anything to finish":
            systemRefusesTime = true

        case "a remembered recorder holding one recording":
            let audio = try Self.fixtureMP3()
            try await stageRecorder(holding: [
                .init(date: Self.day, timestamp: Self.timestamp,
                      sizeBytes: audio.count, content: audio),
            ])

        case "a recorder Solleva cannot reach":
            try await stageRecorder(holding: [])
            // REFUSED, not silent: the connect gate answers immediately instead of burning the
            // deadline. What this scenario is about is the RELEASE, not the reason.
            stack.reachability.refusesToConnect = true

        // A TRANSFER GENUINELY IN FLIGHT, staged so it is deterministic.
        //
        // `holdNotifyConfirmation` makes the radio withhold the subscription confirmation the
        // key handshake waits on — the real, observed shape of a recorder that is slow to
        // answer. The check runs to completion FIRST, because there is nothing to bring over
        // until the recorder has said what it is holding.
        case "a transfer that is under way":
            check.run(hardwareToken: identifier.uuidString, advertisedName: Self.recorderName,
                      library: manager.captureLibraryRoot,
                      stages: manager.captureStages(), brain: .myComputer)
            try await AppScenarioHost.settle(untilTrue: { !self.check.isChecking },
                                             describing: "the check to finish")
            guard check.offeredRecording != nil else {
                throw BrineStepError(
                    "the check produced no offer, so there is no transfer to start. The app "
                        + "said: \(check.message ?? "(nothing)")")
            }
            // FROM HERE the log difference is the transfer's, not the check's.
            commandsAtScenarioStart = DoorLog.shared.commands.count
            stack.holdNotifyConfirmation = true
            check.bringOver(hardwareToken: identifier.uuidString,
                            advertisedName: Self.recorderName,
                            into: manager)
            // THE POSITIVE CONTROL FOR EVERY SCENARIO IN THIS FILE. Interrupting an errand
            // that had not yet reached the recorder would prove nothing at all.
            try await AppScenarioHost.settle(
                untilTrue: { self.stack.isConnected && self.check.isBringingOver },
                describing: "the transfer to actually reach the recorder")

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
        // THE BUDGET IS INSTALLED BEFORE THE MODEL IS BUILT, because that is when the shipping
        // model takes its lease.
        time = ScriptedBackgroundTime(grants: !systemRefusesTime)
        // CONSUMED, NOT STICKY. The world is shared across this feature's eight scenarios —
        // that is the runner's shape — so a budget staged for ONE of them must not be
        // inherited by the next, which would make the scenario after it pass for the wrong
        // reason and hide the very defect it is about.
        systemRefusesTime = false
        PocketRecorderCheckModel.backgroundTimeForScenarios = time.seam
        check = PocketRecorderCheckModel()
        commandsAtScenarioStart = DoorLog.shared.commands.count
    }

    // MARK: When

    func when(_ phrase: String) async throws {
        switch phrase {
        // A SCREENSHOT. Also Control Center, the app switcher, a notification banner and an
        // incoming call: iOS reports `.inactive` for every one of them, and the shipped
        // comparison treated all five as the owner walking away.
        case "something momentary interrupts the app":
            check.sceneChanged(to: .inactive)
            try await settleABeat()

        case "I put the phone away":
            check.sceneChanged(to: .background)
            try await settleABeat()

        case "the transfer is allowed to finish":
            try await releaseTheRecorder()

        // LEAVING THE PAGE IS `departed()`, NOT `cancel()`, AND THAT IS THE POINT OF THE STEP.
        // The recorder page's `.onDisappear` calls exactly this, and what it does for a durable
        // transfer is nothing — the bytes are the point, not the screen.
        case "I leave the page":
            check.departed()
            try await settleABeat()

        // AND THE OTHER HALF, SO THE STOP IS STILL PROVEN. `cancel()` is what the scene policy
        // reaches for when the system will not make room, and a transfer it stops must still
        // stop and still give the time back.
        case "the errand is stopped outright":
            check.cancel()

        case "the system takes the time back":
            time.expireEverything()
            try await settleABeat()

        case "I ask what that recorder is holding":
            check.run(hardwareToken: identifier.uuidString, advertisedName: Self.recorderName,
                      library: manager.captureLibraryRoot,
                      stages: manager.captureStages(), brain: .myComputer)
            try await AppScenarioHost.settle(untilTrue: { !self.check.isChecking },
                                             describing: "the check to finish")

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    /// Let the withheld subscription through — what a slow recorder eventually does — and wait
    /// for the transfer to land.
    private func releaseTheRecorder() async throws {
        stack.confirmNotifications()
        stack.drain()
        try await AppScenarioHost.settle(
            untilTrue: { !self.check.isBringingOver && !self.check.isChecking },
            timeout: 30,
            describing: "the transfer to finish once the recorder answered")
    }

    /// GIVE THE MAIN ACTOR UP FOR A MOMENT. Every "still under way" claim would be vacuously
    /// true if it were asserted in the same turn as the scene change: the cancel it is about
    /// is synchronous, but the Task it would have torn down resumes on this actor, and a claim
    /// that never yields is a claim nothing could ever disprove.
    private func settleABeat() async throws {
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    // MARK: Then

    func then(_ phrase: String) async throws {
        switch phrase {
        case "the transfer is still under way":
            guard check.isBringingOver else {
                throw BrineStepError(
                    "the transfer stopped. A screenshot, Control Center, the app switcher and "
                        + "a notification banner all report .inactive, and none of them is "
                        + "somebody leaving. The app said: "
                        + "\(check.bringOverMessage ?? "(nothing)")")
            }

        case "Solleva is still holding the recorder open":
            guard stack.isConnected else {
                throw BrineStepError(
                    "the app let go of the radio, so whatever the page still says, there is no "
                        + "session left for the recording to come over")
            }

        case "the transfer then finishes and Solleva keeps the recording":
            try await releaseTheRecorder()
            let rows = check.detail?.manifest.rows ?? []
            guard rows.contains(where: { $0.presence.onThisPhone.answer == .yes }) else {
                throw BrineStepError(
                    "the transfer ended and nothing on this phone holds the recording. The "
                        + "app said: \(check.bringOverMessage ?? "(nothing)")")
            }

        case "Solleva has asked the system for time to finish it":
            guard time.namesAsked.contains(PocketErrandCommand.bringOverSubject) else {
                throw BrineStepError(
                    "the app never asked the system for time to finish the transfer in, so "
                        + "putting the phone in a pocket suspends the process within seconds "
                        + "and the transfer dies with the page still claiming it is working. "
                        + "It asked for: \(time.namesAsked)")
            }
            guard check.isHoldingBackgroundTime else {
                throw BrineStepError("the app asked for time and is not holding any")
            }

        case "Solleva has given back every piece of time it asked for":
            // THE POSITIVE CONTROL FIRST. "Nothing outstanding" is trivially true of an app
            // that never asked for anything, which is the defect this whole file is about.
            guard !time.namesAsked.isEmpty else {
                throw BrineStepError(
                    "this errand never asked the system for any time, so proving it gave all "
                        + "of it back proves nothing at all")
            }
            guard time.outstanding.isEmpty, !check.isHoldingBackgroundTime else {
                throw BrineStepError(
                    "the errand is over and \(time.outstanding.count) piece(s) of background "
                        + "time are still held. An assertion that outlives its errand is how "
                        + "iOS terminates the app")
            }

        case "the transfer is no longer under way":
            guard !check.isBringingOver, !check.isChecking else {
                throw BrineStepError(
                    "the app is still claiming to work inside a process the system is about "
                        + "to suspend — which is the same silence as a transfer that failed, "
                        + "with none of the honesty")
            }

        case "the record says it stopped because there was no time to finish in":
            let stops = commandsThisScenario(named: PocketErrandCommand.stop)
            guard !stops.isEmpty else {
                throw BrineStepError("nothing in the record says the errand ever stopped")
            }
            let token = PocketErrandScenePhasePolicy.stoppedWithoutBackgroundTimeToken
            guard stops.contains(where: { $0.outcome == token }) else {
                throw BrineStepError(
                    "the record says the errand stopped for "
                        + "\(stops.compactMap(\.outcome)) — none of which is \"\(token)\", so "
                        + "a transfer the system would not make room for is indistinguishable "
                        + "from one the owner walked away from")
            }

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
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

// MARK: - A system whose background-time answers a scenario owns

/// THE SECOND THING A HERMETIC RUN CANNOT OWN. The radio is the first. No scenario can make
/// iOS refuse an assertion or take one back on cue, and those are exactly the two states the
/// honest half of this fix is about — so the budget is scripted and everything else (when time
/// is asked for, that it is asked for once, that every exit path hands it back) stays the
/// shipped code running in the shipped process.
private final class ScriptedBackgroundTime: @unchecked Sendable {
    private let lock = NSLock()
    private let grants: Bool
    private var asked: [String] = []
    private var held: [PocketBackgroundTimeToken] = []
    private var expiries: [PocketBackgroundTimeToken: @MainActor @Sendable () -> Void] = [:]
    private var next = 1

    init(grants: Bool = true) { self.grants = grants }

    var namesAsked: [String] { lock.lock(); defer { lock.unlock() }; return asked }
    var outstanding: [PocketBackgroundTimeToken] {
        lock.lock(); defer { lock.unlock() }; return held
    }

    var seam: PocketBackgroundTime {
        PocketBackgroundTime(
            begin: { [self] named, onExpiry -> PocketBackgroundTimeToken? in
                lock.lock()
                defer { lock.unlock() }
                asked.append(named)
                guard grants else { return nil }
                let token = PocketBackgroundTimeToken(rawValue: next)
                next += 1
                held.append(token)
                expiries[token] = onExpiry
                return token
            },
            end: { [self] token in
                lock.lock()
                held.removeAll { $0 == token }
                expiries[token] = nil
                lock.unlock()
            })
    }

    /// What iOS does when the budget runs out.
    @MainActor
    func expireEverything() {
        lock.lock()
        let handlers = Array(expiries.values)
        lock.unlock()
        for handler in handlers { handler() }
    }
}
