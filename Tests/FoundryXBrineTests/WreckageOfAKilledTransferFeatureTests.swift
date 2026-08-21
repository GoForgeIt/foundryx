import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// `features/the-wreckage-of-a-killed-transfer-is-cleared.feature` — P2.3.
///
/// The second scenario is the one the spec's first draft got wrong. It originally proposed
/// keeping a `.partial` that "IS in flight" — but after process death no writer survives, so only
/// a stale durable marker could make that claim, and honouring it preserves the orphan forever
/// while passing. The distinction here is PROVENANCE: a live writer is one THIS process opened,
/// which needs nothing persisted.
///
/// The third scenario exists because a sweep that is too eager is worse than one that never runs:
/// deleting a completed `.mp3` destroys the only copy of somebody's recording.
final class WreckageOfAKilledTransferFeatureTests: XCTestCase {
    func testTheWreckageOfAKilledTransferIsCleared() async throws {
        let world = WreckageWorld()
        let result = try await BrineFeatureRunner.run(
            "the-wreckage-of-a-killed-transfer-is-cleared",
            registry: StepRegistry(WreckageSteps.make(world)))
        XCTAssertEqual(result.passed, 4, "all four scenarios must run and pass")
    }
}

private enum WreckageSteps {
    static func make(_ world: WreckageWorld) -> [StepDefinition] {
        let givens = [
            "a half-file left behind by a transfer that was killed",
            "a transfer that is writing its own half-file right now",
            "a recording that came over completely",
            "no half-files anywhere",
        ]
        let whens = ["the app starts and clears the wreckage", "the app clears the wreckage"]
        let thens = [
            "the half-file is gone",
            "the report names what it removed",
            "the half-file being written is still there",
            "the abandoned one is gone",
            "the recording is still there",
            "nothing was removed",
        ]
        var steps = givens.map { p in defineStep(p) { c, _, _ in try world.given(p); return c } }
        steps += whens.map { p in defineStep(p) { c, _, _ in try world.when(p); return c } }
        steps += thens.map { p in defineCheck(p) { _, _, _ in try world.then(p) } }
        return steps
    }
}

private final class WreckageWorld {
    private var root = WreckageWorld.freshRoot()
    private var live: Set<String> = []
    private var report: PocketPartialSweepReport?
    private var abandoned: URL?
    private var beingWritten: URL?
    private var finished: URL?

    fileprivate static func freshRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wreckage-\(UUID().uuidString)", isDirectory: true)
    }

    private func start() throws {
        root = Self.freshRoot()
        live = []; report = nil; abandoned = nil; beingWritten = nil; finished = nil
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("filePull/PKT01/2026-08-07", isDirectory: true),
            withIntermediateDirectories: true)
    }

    private var day: URL { root.appendingPathComponent("filePull/PKT01/2026-08-07", isDirectory: true) }

    func given(_ phrase: String) throws {
        switch phrase {
        case "a half-file left behind by a transfer that was killed":
            try start()
            let u = day.appendingPathComponent("20260807142852.mp3.partial")
            try Data(repeating: 0x5A, count: 4_096).write(to: u)
            abandoned = u

        case "a transfer that is writing its own half-file right now":
            let u = day.appendingPathComponent("20260807153240.mp3.partial")
            try Data(repeating: 0x5A, count: 512).write(to: u)
            beingWritten = u
            // THIS PROCESS OPENED IT. That is the whole distinction — no marker on disk.
            live = [u.path]

        case "a recording that came over completely":
            try start()
            let u = day.appendingPathComponent("20260807161651.mp3")
            try Data(repeating: 0x11, count: 19_770).write(to: u)
            finished = u

        case "no half-files anywhere":
            try start()

        default: throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    func when(_ phrase: String) throws {
        guard phrase.hasPrefix("the app") else { throw BrineStepError("unhandled When: \(phrase)") }
        report = PocketPartialSweep.sweep(under: root, liveWriterPaths: live)
    }

    private func exists(_ u: URL?) -> Bool {
        guard let u else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    func then(_ phrase: String) throws {
        switch phrase {
        case "the half-file is gone":
            guard !exists(abandoned) else {
                throw BrineStepError("the orphaned half-file survived the sweep, so it survives "
                                     + "every launch and nothing will ever remove it")
            }

        case "the report names what it removed":
            guard let r = report, r.swept.count == 1, r.swept[0].hasSuffix(".partial") else {
                throw BrineStepError("the report says \(report?.swept ?? []) — a reaper that "
                                     + "does not name what it destroyed cannot be audited")
            }

        case "the half-file being written is still there":
            guard exists(beingWritten) else {
                throw BrineStepError("the sweep deleted the file a transfer is writing RIGHT NOW")
            }
            guard report?.keptLive.count == 1 else {
                throw BrineStepError("the report does not record keeping it")
            }

        case "the abandoned one is gone":
            // PAIRED WITH THE ABOVE. "It kept the live one" is satisfied by a sweep that keeps
            // everything, which is the same as no sweep at all.
            guard !exists(abandoned) else {
                throw BrineStepError("nothing was swept, so keeping the live file proves nothing")
            }

        case "the recording is still there":
            guard exists(finished) else {
                throw BrineStepError("THE SWEEP DELETED A COMPLETED RECORDING — the only copy of "
                                     + "somebody's audio, destroyed by a reaper")
            }

        case "nothing was removed":
            guard report?.isEmpty == true else {
                throw BrineStepError("a clean tree reported \(report as Any)")
            }

        default: throw BrineStepError("unhandled Then: \(phrase)")
        }
    }
}
