import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// `features/the-drain-survives-being-killed.feature` — Phase 1 of
/// `20260821T0153_the_drain_survives_termination`.
///
/// **"Killed and started again" is modelled as a store read from a fresh instance**, which is what
/// actually happens: the actor and every `private var` on it are gone, and the only thing that
/// crosses the boundary is what reached disk. A test that kept the queue object alive and called a
/// `restore()` on it would be testing a method, not a termination.
///
/// WHAT EACH SCENARIO CAN FAIL ON:
///   * drop the write and nothing survives the boundary;
///   * persist the population but not `stopped` and the owner's refusal is handed back — the
///     defect the second scenario exists for, and the one a person actually notices;
///   * persist `attempts` as zero and the failure budget silently resets on every launch;
///   * treat an undecodable file as an empty backlog and a corrupt intent reads as "nothing to
///     do" — the two states a `PocketBacklog?` would have collapsed.
final class DrainSurvivesBeingKilledFeatureTests: XCTestCase {
    func testTheDrainSurvivesBeingKilled() async throws {
        let world = DrainSurvivalWorld()
        let result = try await BrineFeatureRunner.run(
            "the-drain-survives-being-killed",
            registry: StepRegistry(DrainSurvivalSteps.make(world)))
        XCTAssertEqual(result.passed, 5, "all five scenarios must run and pass")
    }
}

private enum DrainSurvivalSteps {
    static func make(_ world: DrainSurvivalWorld) -> [StepDefinition] {
        let givens = [
            "a recorder with three recordings queued to come over",
            "the owner stops the second one",
            "the first one has already failed twice",
            "a recorder whose saved backlog is corrupt",
            "a recorder with no saved backlog",
        ]
        let whens = ["the app is killed and started again"]
        let thens = [
            "all three are still waiting, in the same order",
            "the stopped recording is not offered",
            "the other two are still offered",
            "that recording has spent two of its attempts",
            "nothing is offered to drain",
            "the reason is stated rather than read as an empty queue",
            "that is not reported as a failure",
        ]
        var steps = givens.map { p in
            defineStep(p) { c, _, _ in try world.given(p); return c }
        }
        steps += whens.map { p in
            defineStep(p) { c, _, _ in try world.when(p); return c }
        }
        steps += thens.map { p in
            defineCheck(p) { _, _, _ in try world.then(p) }
        }
        return steps
    }
}

private final class DrainSurvivalWorld {
    /// A FRESH ROOT PER SCENARIO. Brine reuses one world across a feature, so without this the
    /// corrupt file written by the fourth scenario is still on disk for the fifth — which then
    /// reads `.unreadable` and fails claiming a never-drained recorder reported an error. The
    /// scenario was right and the fixture was leaking.
    private var root: URL = DrainSurvivalWorld.freshRoot()
    private let identity = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "PKT01-survival")

    fileprivate static func freshRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drain-survival-\(UUID().uuidString)", isDirectory: true)
    }

    /// Called at the head of every Given that opens a scenario.
    private func startScenario() {
        root = Self.freshRoot()
        writer = PocketBacklogStore(root: root)
        readout = .none
        staged = PocketBacklog()
    }
    /// The store the "previous process" wrote through. Deliberately NOT reused for reading.
    private var writer: PocketBacklogStore
    private var readout: PocketBacklogReadout = .none
    private var staged = PocketBacklog()

    private static let day = "2026-08-07"
    private static let timestamps = ["20260807142852", "20260807153240", "20260807161651"]

    init() { writer = PocketBacklogStore(root: root) }

    func given(_ phrase: String) throws {
        switch phrase {
        case "a recorder with three recordings queued to come over":
            startScenario()
            staged = PocketBacklog(entries: Self.timestamps.map {
                PocketBacklogEntry(date: Self.day, timestamp: $0, sizeBytes: 4_000)
            })
            try writer.write(staged, for: identity)

        case "the owner stops the second one":
            staged.entries[1].stopped = true
            try writer.write(staged, for: identity)

        case "the first one has already failed twice":
            staged.entries[0].attempts = 2
            try writer.write(staged, for: identity)

        case "a recorder whose saved backlog is corrupt":
            startScenario()
            // NOT an empty file and not absent — a file that exists and does not decode, which is
            // the case a nil would have hidden.
            let file = writer.url(for: identity)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("{ this is not a backlog".utf8).write(to: file)
            readout = PocketBacklogStore(root: root).read(for: identity)

        case "a recorder with no saved backlog":
            startScenario()
            readout = PocketBacklogStore(root: root).read(for: identity)

        default: throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    func when(_ phrase: String) throws {
        guard phrase == "the app is killed and started again" else {
            throw BrineStepError("unhandled When: \(phrase)")
        }
        // THE TERMINATION. Nothing in-memory crosses this line: a brand new store, reading only
        // what reached disk.
        readout = PocketBacklogStore(root: root).read(for: identity)
    }

    private func requireBacklog() throws -> PocketBacklog {
        guard case .backlog(let b) = readout else {
            throw BrineStepError("the backlog did not survive: \(readout)")
        }
        return b
    }

    func then(_ phrase: String) throws {
        switch phrase {
        case "all three are still waiting, in the same order":
            let b = try requireBacklog()
            guard b.entries.map(\.timestamp) == Self.timestamps else {
                throw BrineStepError("survived as \(b.entries.map(\.timestamp))")
            }

        case "the stopped recording is not offered":
            let b = try requireBacklog()
            guard !b.drainable.map(\.timestamp).contains(Self.timestamps[1]) else {
                throw BrineStepError(
                    "the recording the owner stopped came back after a relaunch — a stop that "
                        + "forgets itself is worse than no stop, because the pull restarts "
                        + "without being asked for")
            }

        case "the other two are still offered":
            // PAIRED EXISTENCE. "Not offered" is satisfied by a build that offers nothing at all.
            let b = try requireBacklog()
            let offered = Set(b.drainable.map(\.timestamp))
            guard offered == [Self.timestamps[0], Self.timestamps[2]] else {
                throw BrineStepError("offered \(offered.sorted()) rather than the two not stopped")
            }

        case "that recording has spent two of its attempts":
            let b = try requireBacklog()
            guard b.entries.first?.attempts == 2 else {
                throw BrineStepError(
                    "attempts came back as \(b.entries.first?.attempts ?? -1); a budget that "
                        + "resets on every launch is not a budget")
            }

        case "nothing is offered to drain":
            switch readout {
            case .backlog(let b) where b.drainable.isEmpty: break
            case .unreadable, .none: break
            case .backlog(let b):
                throw BrineStepError("\(b.drainable.count) recording(s) offered")
            }

        case "the reason is stated rather than read as an empty queue":
            guard case .unreadable(let because) = readout else {
                throw BrineStepError(
                    "a corrupt backlog read as \(readout) — an unreadable intent and an empty "
                        + "queue are opposite states and this one collapsed them")
            }
            guard because.count > 10 else { throw BrineStepError("the reason says nothing") }

        case "that is not reported as a failure":
            guard case .none = readout else {
                throw BrineStepError(
                    "a recorder nobody has drained reported \(readout) rather than simply none")
            }

        default: throw BrineStepError("unhandled Then: \(phrase)")
        }
    }
}
