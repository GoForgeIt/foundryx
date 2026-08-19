import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// `features/a-transfer-outlives-the-page.feature` — the three decisions that stood between a
/// proven `PocketTransferQueue` and a recorder page that actually uses it.
///
/// WHY THESE THREE AND NOT THE QUEUE ITSELF. The queue's own behaviour is held by
/// `PocketTransferQueueFeatureTests` against the captured hardware trace. What was left
/// unheld — and what kept the register row `pocket-transfer-queue-run` red — was the WIRING,
/// and every part of it is the kind of rule this repository has already shipped wrong because
/// it was written in a SwiftUI body: an `.onDisappear` that cancelled unconditionally, a
/// `phase != .active` comparison that made taking a SCREENSHOT kill a transfer, an `if let
/// captureID` branch nothing could reach.
///
/// WHAT EACH SCENARIO CAN FAIL ON:
///
///   * DEPARTURE is asserted over all four errands the page runs, INCLUDING the fast sync,
///     which records itself under the same `bring-over` subject and must still stop. Return
///     `.leaveItRunning` on the subject alone and the fast-sync check is red; return
///     `.stopTheErrand` always — the shipped defect — and the transfer check is red.
///   * FOLLOW-THROUGH is asserted over every case of `PocketTransferPhase`, so a case added
///     without a decision cannot compile past the exhaustive switch, and the clock warning is
///     asserted to be IN the rendered sentence — drop it from the phase or from the renderer
///     and this is red, which is the producer-with-no-consumer hole all over again.
///   * COALESCING is measured, not asserted at: the readings of a long transfer at the
///     CAPTURED chunk sizes are replayed one by one, and the screen must be woken exactly once
///     per whole percent. Delete the percent comparison and the count is the reading count —
///     two hundred-odd times larger — and red.
final class PocketTransferHandoffFeatureTests: XCTestCase {
    func testATransferOutlivesThePageFeature() async throws {
        let world = TransferHandoffWorld()
        let result = try await BrineFeatureRunner.run(
            "a-transfer-outlives-the-page",
            registry: StepRegistry(TransferHandoffSteps.make(world)))
        XCTAssertEqual(result.passed, 3)
    }
}

private enum TransferHandoffSteps {
    static func make(_ world: TransferHandoffWorld) -> [StepDefinition] {
        let acts = [
            "a shelf check, a durable transfer and the WiFi fast sync, each in flight in turn",
            "the owner leaves the page during each of them",
            "every way one queued recording can end",
            "each ending is put to the follow-through",
            "the readings a long transfer produces at the captured chunk sizes",
            "every reading is offered to the screen",
        ]
        let checks = [
            "the shelf check is stopped",
            "the durable transfer is left running",
            "the fast sync is stopped, because it is not a durable job",
            "a page with nothing running still answers stop",
            "only the endings that moved custody hand a conversation to the running app",
            "the sentence for a finished transfer carries the recorder's clock warning",
            "every ending closes the errand with its own token",
            "a recording still in flight closes no errand at all",
            "the screen is woken once per whole percent and no more",
            "the first reading and the last reading both reach it",
            "a reading that is not progress always reaches it",
        ]
        var steps = acts.map { phrase in
            defineStep(phrase) { context, _, _ in try world.act(phrase); return context }
        }
        steps += checks.map { phrase in
            defineCheck(phrase) { _, _, _ in try world.check(phrase) }
        }
        return steps
    }
}

/// THE CAPTURED CHUNK SIZES, READ AT RUN TIME. If the fixture is missing this REFUSES rather
/// than substituting an invented notification size — the coalescing rule is entirely about how
/// many readings a real radio produces, so an invented one would make the whole scenario a
/// statement about nothing.
private enum HandoffTrace {
    /// The 82 real notification lengths of the captured transfer.
    static func chunkLengths() throws -> [Int] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/pocket/pocket-fw16-ble-download-trace.json")
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runs = root["runs"] as? [String: Any],
              let run = runs["A_single_download_audio_subscribed_at_establish"] as? [String: Any],
              let chunks = run["chunks"] as? [String: Any],
              let lengths = chunks["lengths"] as? [Int], !lengths.isEmpty else {
            throw BrineStepError("the captured BLE trace has no chunk lengths to replay")
        }
        return lengths
    }

    /// A FILE LONG ENOUGH FOR THE RULE TO MATTER, in the recorder's own arithmetic: twenty-seven
    /// minutes at the 4,000 bytes/second `PocketRecording.durationSeconds` divides by — the
    /// length `PocketTransferQueue`'s own retry budget is written around ("a 27-minute file is
    /// not free"). The captured lengths are cycled to fill it, so every reading in this
    /// scenario is a real notification size and only the COUNT of them is extrapolated.
    static let longFileBytes = 27 * 60 * 4_000
}

private final class TransferHandoffWorld {

    // MARK: - Departure

    private var departures: [String: PocketErrandDeparture] = [:]

    // MARK: - Follow-through

    private var endings: [(name: String, phase: PocketTransferPhase)] = []
    private var followed: [(name: String, result: PocketTransferFollowThrough)] = []
    private let clockWarning = "The recorder's clock was 3 min behind this phone."
    private let broughtOverCaptureID = "capture-brought-over"
    private let alreadyHeldCaptureID = "capture-already-held"

    // MARK: - Coalescing

    private var readings: [PocketTransferPhase] = []
    private var admitted: [Int] = []          // indices into `readings`
    private var wholePercents: Set<Int> = []

    func act(_ phrase: String) throws {
        switch phrase {
        case "a shelf check, a durable transfer and the WiFi fast sync, each in flight in turn":
            // Nothing is staged here that the step below does not use; the errands are the
            // page's own four states and they are named where they are decided.
            departures = [:]

        case "the owner leaves the page during each of them":
            departures["shelf"] = PocketErrandDeparturePolicy.decide(
                PocketErrandInFlight(subject: PocketErrandCommand.shelfSubject),
                isDurableJob: false)
            departures["transfer"] = PocketErrandDeparturePolicy.decide(
                PocketErrandInFlight(subject: PocketErrandCommand.bringOverSubject,
                                     recordingId: "2026-08-07/20260807142852"),
                isDurableJob: true)
            // THE TRAP THIS SCENARIO EXISTS FOR. The WiFi leg records itself under the SAME
            // subject token as the Bluetooth transfer and is not a durable job.
            departures["fast-sync"] = PocketErrandDeparturePolicy.decide(
                PocketErrandInFlight(subject: PocketErrandCommand.bringOverSubject,
                                     recordingId: "2026-08-07/20260807142852"),
                isDurableJob: false)
            departures["removal"] = PocketErrandDeparturePolicy.decide(
                PocketErrandInFlight(subject: PocketErrandCommand.removalSubject,
                                     recordingId: "2026-08-07/20260807142852"),
                isDurableJob: true)
            departures["idle"] = PocketErrandDeparturePolicy.decide(nil, isDurableJob: false)

        case "every way one queued recording can end":
            endings = [
                ("brought-over", .broughtOver(captureID: broughtOverCaptureID,
                                              clockWarning: clockWarning)),
                ("already-held", .alreadyHeld(captureID: alreadyHeldCaptureID)),
                ("stopped", .stopped),
                ("unreadable",
                 .failed(PocketBringOverPresentation.unreadableRecordingLine)),
                ("incomplete",
                 .failed(PocketBringOverPresentation.transferIncompleteLine)),
                ("gave-up", .failed(PocketTransferQueuePresentation.gaveUpLine)),
                ("unavailable", .failed(PocketRecorderCheckPresentation.notThisRecorderLine)),
                ("queued", .queued),
                ("starting", .starting),
                ("transferring", .transferring(deliveredBytes: 1_000, announcedBytes: 19_770)),
                ("waiting", .waitingToRetry(afterSeconds: 60, attempt: 2)),
            ]

        case "each ending is put to the follow-through":
            followed = endings.map { ($0.name, PocketTransferFollowThrough.decide($0.phase)) }

        case "the readings a long transfer produces at the captured chunk sizes":
            let lengths = try HandoffTrace.chunkLengths()
            let total = HandoffTrace.longFileBytes
            var delivered = 0
            var index = 0
            var built: [PocketTransferPhase] = [.starting]
            while delivered < total {
                delivered = min(total, delivered + lengths[index % lengths.count])
                index += 1
                built.append(.transferring(deliveredBytes: delivered, announcedBytes: total))
            }
            readings = built
            wholePercents = Set(built.compactMap { $0.fraction.map { Int($0 * 100) } })

        case "every reading is offered to the screen":
            let reporter = PocketTransferProgressReporter()
            admitted = readings.indices.filter { reporter.admit(readings[$0]) }

        default:
            throw BrineStepError("unbound step: \(phrase)")
        }
    }

    func check(_ phrase: String) throws {
        switch phrase {

        // MARK: Departure

        case "the shelf check is stopped":
            try expect(departures["shelf"] == .stopTheErrand,
                       "a check whose page is gone has nothing left to answer, so it stops")
        case "the durable transfer is left running":
            try expect(departures["transfer"] == .leaveItRunning,
                       "THE WHOLE DEFECT. A bring-over is custody moving, and the page leaving "
                           + "is the ordinary case rather than an abandonment")
        case "the fast sync is stopped, because it is not a durable job":
            try expect(departures["fast-sync"] == .stopTheErrand,
                       "the WiFi leg shares the `bring-over` subject and is NOT durable: its "
                           + "whole tail is behind the page's model and it holds a "
                           + "background-time assertion this model has to give back")
        case "a page with nothing running still answers stop":
            try expect(departures["idle"] == .stopTheErrand,
                       "a departure from an idle page must still release whatever a lease or a "
                           + "token is holding")
            try expect(departures["removal"] == .stopTheErrand,
                       "a destructive errand must never outlive the screen that authorised it, "
                           + "durable job or not")

        // MARK: Follow-through

        case "only the endings that moved custody hand a conversation to the running app":
            let adopting = followed.filter { $0.result.adoptCaptureID != nil }.map(\.name)
            try expect(adopting.sorted() == ["already-held", "brought-over"],
                       "the endings that hand a conversation over are \(adopting.sorted()); "
                           + "without this hand-off the recording is a capture directory the "
                           + "running app does not know exists and will not upload until the "
                           + "next launch")
            try expect(result(of: "brought-over")?.adoptCaptureID == broughtOverCaptureID
                        && result(of: "already-held")?.adoptCaptureID == alreadyHeldCaptureID,
                       "the conversation handed over is not the one the ending named")
            let moved = followed.filter(\.result.custodyMoved).map(\.name)
            try expect(moved.sorted() == ["already-held", "brought-over"],
                       "custody moved on \(moved.sorted()) — the shelf and the safety evidence "
                           + "are re-taken from exactly this fact")

        case "the sentence for a finished transfer carries the recorder's clock warning":
            let line = result(of: "brought-over")?.line
            try expect(line?.contains(clockWarning) == true,
                       "the rendered sentence is \(line ?? "nothing") and the recorder-clock "
                           + "warning is not in it — a fact only the import could establish, "
                           + "computed and dropped, which is the exact hole "
                           + "`pocket-clock-warning-rendered` exists to hold shut")
            try expect(line?.hasPrefix(PocketBringOverPresentation.broughtOverLine) == true,
                       "the warning replaced the sentence instead of following it")

        case "every ending closes the errand with its own token":
            let tokens = Dictionary(uniqueKeysWithValues:
                followed.compactMap { pair in pair.result.outcomeToken.map { (pair.name, $0) } })
            try expect(tokens == ["brought-over": DoorLog.succeeded,
                                  "already-held": "already-held",
                                  "stopped": "stopped",
                                  "unreadable": "unreadable",
                                  "incomplete": "transfer-incomplete",
                                  "gave-up": "gave-up",
                                  "unavailable": "recorder-unavailable"],
                       "the closed tokens are \(tokens.sorted(by: { $0.key < $1.key })); folding "
                           + "four diagnoses into one word is how 'it didn't work' becomes "
                           + "unanswerable at three in the morning")

        case "a recording still in flight closes no errand at all":
            let unfinished = followed.filter { !$0.result.isFinished }.map(\.name)
            try expect(unfinished.sorted() == ["queued", "starting", "transferring", "waiting"],
                       "the unfinished phases are \(unfinished.sorted())")
            try expect(followed.filter { !$0.result.isFinished }
                        .allSatisfy { $0.result.outcomeToken == nil },
                       "an errand that is still running was given a closing token")

        // MARK: Coalescing

        case "the screen is woken once per whole percent and no more":
            try expect(readings.count > 10_000,
                       "only \(readings.count) readings were replayed — a transfer this short "
                           + "cannot show whether the rule reduces anything")
            // ONE MORE THAN THE PERCENTS: the `.starting` reading opens the transfer and is not
            // a progress reading at all, and it is always admitted.
            try expect(admitted.count == wholePercents.count + 1,
                       "\(admitted.count) readings reached the screen for "
                           + "\(wholePercents.count) whole percents; the rule is one wake per "
                           + "percent, plus the events")
            try expect(readings.count / admitted.count > 100,
                       "the rule collapsed \(readings.count) readings into \(admitted.count), "
                           + "which is not a reduction worth having — a `@Published` write per "
                           + "BLE notification is a SwiftUI invalidation per BLE notification")

        case "the first reading and the last reading both reach it":
            try expect(admitted.first == 0,
                       "the transfer's first reading did not reach the screen")
            try expect(admitted.last == readings.count - 1,
                       "the reading that lands exactly on the announced total did not reach the "
                           + "screen, so the bar stops short of the end it reached")

        case "a reading that is not progress always reaches it":
            let reporter = PocketTransferProgressReporter()
            let events: [PocketTransferPhase] = [
                .starting,
                .waitingToRetry(afterSeconds: 60, attempt: 1),
                .waitingToRetry(afterSeconds: 60, attempt: 1),
                .stopped,
                .queued,
                .broughtOver(captureID: "c", clockWarning: nil),
                .failed(PocketTransferQueuePresentation.gaveUpLine),
            ]
            try expect(events.allSatisfy { reporter.admit($0) },
                       "an event was collapsed away — a start, a retry wait, a stop and an "
                           + "ending are each one thing that happened, and dropping one loses "
                           + "the sentence rather than the frame")

        default:
            throw BrineStepError("unbound check: \(phrase)")
        }
    }

    private func result(of name: String) -> PocketTransferFollowThrough? {
        followed.first { $0.name == name }?.result
    }

    private func expect(_ condition: Bool, _ why: String) throws {
        if !condition { throw BrineStepError(why) }
    }
}
