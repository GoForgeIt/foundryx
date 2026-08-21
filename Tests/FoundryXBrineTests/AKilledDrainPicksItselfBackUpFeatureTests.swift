import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// `features/a-killed-drain-picks-itself-back-up.feature` — P2.6 (trigger seam) and P2.9 (AC12).
///
/// **The first scenario is why this phase is not four refusals.** A build containing only the
/// ingress gate, the commit admission, the sweep and the session policy refuses a restored stream
/// flawlessly and never recovers a recording — and passes AC1, AC2, AC3 and AC11 while doing it.
/// The cross-vendor review of the spec found exactly that hole.
///
/// The last scenario is its counterweight: a restart with nothing outstanding must not report a
/// failure, or a healthy app looks broken every time it is killed while idle.
final class AKilledDrainPicksItselfBackUpFeatureTests: XCTestCase {
    func testAKilledDrainPicksItselfBackUp() async throws {
        let world = KilledDrainWorld()
        let result = try await BrineFeatureRunner.run(
            "a-killed-drain-picks-itself-back-up",
            registry: StepRegistry(KilledDrainSteps.make(world)))
        XCTAssertEqual(result.passed, 5, "all five scenarios must run and pass")
    }
}

private enum KilledDrainSteps {
    static func make(_ world: KilledDrainWorld) -> [StepDefinition] {
        let givens = [
            "a drain that was killed with two recordings still waiting",
            "a drain that was killed with nothing waiting",
            "a half-file left behind by the transfer that was interrupted",
            "the recorder will only give back one of them",
        ]
        let whens = ["the app recovers from the restart"]
        let thens = [
            "both recordings come over",
            "nobody had to tap anything",
            "it stops listening to the old link before anything else",
            "it drops the half-finished file before retiring the link",
            "it retires the link before talking to the recorder again",
            "the half-file is gone",
            "it reports that it did not get everything it tried for",
            "nothing comes over",
            "that counts as having recovered everything it tried for",
        ]
        var steps = givens.map { p in defineStep(p) { c, _, _ in try world.given(p); return c } }
        steps += whens.map { p in defineStep(p) { c, _, _ in try await world.when(p); return c } }
        steps += thens.map { p in defineCheck(p) { _, _, _ in try world.then(p) } }
        return steps
    }
}

/// A driver that keeps whatever it is handed, minus anything the scenario says the recorder will
/// withhold. **No radio**: this is about the coordinator's order and its reporting, and a fake
/// radio here would only test the fake.
private final class ScriptedDriver: PocketRestorationDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var refuse: Set<String>
    private var _asked: [String] = []
    var asked: [String] { lock.withLock { _asked } }
    init(refusing: Set<String> = []) { refuse = refusing }

    func retryFromByteZero(_ recording: PocketRecording) async -> PocketRecordingRequest? {
        let no = lock.withLock {
            _asked.append(recording.timestamp)
            return refuse.contains(recording.timestamp)
        }
        return no ? nil : recording.request
    }
}

private final class KilledDrainWorld {
    private var root = URL(fileURLWithPath: NSTemporaryDirectory())
    private var backlog = PocketBacklog()
    private var driver = ScriptedDriver()
    private var outcome: PocketRestorationOutcome?
    private var partial: URL?
    private static let stamps = ["20260807142852", "20260807153240"]

    private func start() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("killed-drain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        outcome = nil; partial = nil; driver = ScriptedDriver()
    }

    func given(_ phrase: String) throws {
        switch phrase {
        case "a drain that was killed with two recordings still waiting":
            try start()
            backlog = PocketBacklog(entries: Self.stamps.map {
                PocketBacklogEntry(date: "2026-08-07", timestamp: $0, sizeBytes: 19_770)
            })
        case "a drain that was killed with nothing waiting":
            try start()
            backlog = PocketBacklog()
        case "a half-file left behind by the transfer that was interrupted":
            let u = root.appendingPathComponent("20260807142852.mp3.partial")
            try Data(repeating: 0x5A, count: 4_096).write(to: u)
            partial = u
        case "the recorder will only give back one of them":
            driver = ScriptedDriver(refusing: [Self.stamps[1]])
        default: throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    func when(_ phrase: String) async throws {
        guard phrase == "the app recovers from the restart" else {
            throw BrineStepError("unhandled When: \(phrase)")
        }
        outcome = await PocketRestorationCoordinator.recover(
            gate: PocketRestorationGate(startingAfter: PocketTransferGeneration(7)),
            backlog: backlog, partialRoot: root, driver: driver)
    }

    private func requireOutcome() throws -> PocketRestorationOutcome {
        guard let outcome else { throw BrineStepError("no recovery ran") }
        return outcome
    }

    private func indexOf(_ step: PocketRestoredSessionStep) throws -> Int {
        guard let i = try requireOutcome().stepsPerformed.firstIndex(of: step) else {
            throw BrineStepError("\(step) never happened")
        }
        return i
    }

    func then(_ phrase: String) throws {
        switch phrase {
        case "both recordings come over":
            let o = try requireOutcome()
            guard o.committed.count == 2 else {
                throw BrineStepError(
                    "\(o.committed.count) of 2 came over — four refusals and no recovery passes "
                        + "every other criterion in this phase while bringing nothing over")
            }
        case "nobody had to tap anything":
            guard driver.asked.count == 2 else {
                throw BrineStepError("the recorder was asked \(driver.asked.count) times")
            }
        case "it stops listening to the old link before anything else":
            guard try indexOf(.closeIngress) == 0 else {
                throw BrineStepError("ingress closed at step \(try indexOf(.closeIngress)); the "
                                     + "radio does not stop talking while the later steps run")
            }
        case "it drops the half-finished file before retiring the link":
            guard try indexOf(.discardPartialTransfer) < indexOf(.retireLink) else {
                throw BrineStepError("a retired link cannot tell you what it was writing")
            }
        case "it retires the link before talking to the recorder again":
            guard try indexOf(.retireLink) < indexOf(.reauthenticateOnAFreshLink) else {
                throw BrineStepError(
                    "the key was written over a link the recorder still associates with the "
                        + "previous session — which may silently re-key")
            }
        case "the half-file is gone":
            guard let p = partial, !FileManager.default.fileExists(atPath: p.path) else {
                throw BrineStepError("the wreckage survived the recovery")
            }
        case "it reports that it did not get everything it tried for":
            let o = try requireOutcome()
            guard !o.recoveredEverythingItTried, o.committed.count == 1, o.attempted.count == 2 else {
                throw BrineStepError(
                    "a partial recovery reported \(o.committed.count)/\(o.attempted.count) as "
                        + "\(o.recoveredEverythingItTried) — a success that lost one is worse "
                        + "than a stated partial")
            }
        case "nothing comes over":
            guard try requireOutcome().committed.isEmpty else { throw BrineStepError("kept something") }
        case "that counts as having recovered everything it tried for":
            guard try requireOutcome().recoveredEverythingItTried else {
                throw BrineStepError(
                    "a restart with nothing outstanding reported a failure, so a healthy app "
                        + "looks broken every time it is killed while idle")
            }
        default: throw BrineStepError("unhandled Then: \(phrase)")
        }
    }
}
