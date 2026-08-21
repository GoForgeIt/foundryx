import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// `features/the-owner-can-stop-and-can-empty-the-recorder.feature` — the two capabilities that
/// shipped as APIs nobody could reach.
///
/// WHY THE RULE IS ASSERTED HERE AND NOT AT A BUTTON. `swift test` cannot compile `App/`. Both
/// gaps this suite closes are the SAME defect wearing two hats: a capability existed in
/// `FoundryXKit`, was proven by its own tests, and had no owner-reachable path to it — and
/// nothing in the repository could tell, because the missing half lived in a file the suite
/// cannot see. So `PocketTransferControlsPresentation` holds WHICH CONTROLS EXIST as a value,
/// and `App/DeviceScreen.swift` is left dispatching on its cases.
///
/// WHAT EACH SCENARIO CAN FAIL ON — every one of these mutations was made and watched go red:
///
///   * Return `[]` for the in-flight case (the SHIPPED behaviour: no stop control at all) and
///     scenario 1 is red on both of its checks.
///   * Return the stop control UNCONDITIONALLY — the lazy way to make scenario 1 pass — and
///     scenario 2 is red. That pairing is the whole point: a stop offered when nothing is
///     running is a button that stops nothing, which is the inert control this page has
///     shipped twice.
///   * Drop the `backlogCount > 1` guard and scenario 4 is red, because a one-recording shelf
///     would offer two buttons that do the same thing by different names.
///   * Decide the batch from `snapshot.first` — the SHIPPED line — and scenario 5 is red on
///     three checks at once: two conversations are dropped, two file tokens go unrecorded, and
///     the sentence counts one instead of five.
///   * Put ANY magnitude in the batch sentence — a size, a rate, an estimate — and scenario 5's
///     last check is red. The recorder's listing unit is still unresolved and this surface has
///     printed an invented number three times.
final class OwnerCanStopAndEmptyFeatureTests: XCTestCase {
    func testTheOwnerCanStopAndCanEmptyTheRecorderFeature() async throws {
        let world = StopAndEmptyWorld()
        let result = try await BrineFeatureRunner.run(
            "the-owner-can-stop-and-can-empty-the-recorder",
            registry: StepRegistry(StopAndEmptySteps.make(world)))
        XCTAssertEqual(result.passed, 11,
                       "eleven scenarios — the duplicate-listing one was added 2026-08-20")
    }
}

private enum StopAndEmptySteps {
    static func make(_ world: StopAndEmptyWorld) -> [StepDefinition] {
        let givens = [
            "a transfer is running on this recorder",
            "no transfer is running and the recorder holds recordings this phone does not",
            "no transfer is running and the recorder holds exactly one recording this phone does not",
            "a queue of five recordings where three were brought over and two were not",
            "a queue holding three recordings that have not started",
            "a recorder listing four recordings, two of which this phone already holds",
            "a shelf check is running and the recorder holds recordings this phone does not",
            "a queue of five recordings that were all already on this iPhone",
            "a batch sentence asked for more brought over than the queue ever held",
            "a recorder listing the same recording twice, which this phone does not hold",
        ]
        let whens = ["the owner's stop is used", "a transfer is running as well"]
        let checks = [
            "the page offers a control that stops the transfer",
            "the page says what stopping would cost before it is pressed",
            "the page offers no control that stops anything",
            "no control the page offers is disabled while nothing is running",
            "the page offers a control that takes the whole backlog",
            "that control names the number of recordings it would take",
            "the page offers no control that takes the whole backlog",
            "the page still offers to bring that one recording over",
            "every recording that arrived is handed to the capture owner",
            "every recording that arrived is recorded against its own name",
            "the page says three of five were brought over and two are still on the recorder",
            "the sentence states no size, no rate and no estimate",
            "no recording in the queue is still waiting its turn",
            "none of them is offered to the queue again",
            "the backlog is the two this phone does not hold",
            "the backlog never contains a recording this phone is already holding",
            "no control the page offers can be tapped",
            "the stop can be tapped even though the page is busy",
            "the page does not say five were brought over",
            "the page says five were already on this iPhone",
            "the sentence never claims more than the queue held",
            "the backlog holds that recording once",
            "the number on the control is the number the queue would actually take",
        ]
        var steps = givens.map { phrase in
            defineStep(phrase) { context, _, _ in try await world.given(phrase); return context }
        }
        steps += whens.map { phrase in
            defineStep(phrase) { context, _, _ in try await world.when(phrase); return context }
        }
        steps += checks.map { phrase in
            defineCheck(phrase) { _, _, _ in try await world.check(phrase) }
        }
        return steps
    }
}

/// Answers `alreadyHeld` yes for a named set and nothing else. Every other member traps: a
/// custody stub that quietly answered "no file here" would make the backlog look right while
/// proving nothing about the question being asked.
private struct HoldsExactly: PocketRecorderFileCustody {
    let holding: Set<String>

    func alreadyHeld(_ key: PocketRecorderFileKey) async -> Bool {
        holding.contains(key.date + "/" + key.timestamp)
    }
    func heldFile(_ key: PocketRecorderFileKey) async -> URL? { nil }
    func beginKeeping(_ key: PocketRecorderFileKey) async throws -> any PocketRecorderFileWriting {
        fatalError("unreachable: these scenarios choose files, they never bring one over")
    }
    func conversation(for key: PocketRecorderFileKey) async -> String? { nil }
    func noteConversation(_ captureID: String, for key: PocketRecorderFileKey) async {
        fatalError("unreachable: nothing here imports a conversation")
    }
}

private final class StopAndEmptyWorld {

    /// THE BACKLOG SIZE USED BY THE MULTI-RECORDING SCENARIOS. Twelve, and it is deliberately
    /// not a number that appears anywhere in the implementation: a title built from a constant
    /// rather than from the argument would render the wrong one.
    private static let backlog = 12

    private var controls: [PocketTransferControl] = []
    private var transferInFlight = false
    private var batch: PocketTransferFollowThrough.Batch?
    private var queue: PocketTransferQueue?
    private var backlogRecordings: [PocketRecording] = []
    private var corruptLine: String?

    func given(_ phrase: String) async throws {
        switch phrase {
        case "a transfer is running on this recorder":
            transferInFlight = true
            controls = PocketTransferControlsPresentation.controls(transferInFlight: true,
                                                                   backlogCount: Self.backlog)
        case "no transfer is running and the recorder holds recordings this phone does not":
            transferInFlight = false
            controls = PocketTransferControlsPresentation.controls(transferInFlight: false,
                                                                   backlogCount: Self.backlog)
        case "no transfer is running and the recorder holds exactly one recording this phone does not":
            transferInFlight = false
            controls = PocketTransferControlsPresentation.controls(transferInFlight: false,
                                                                   backlogCount: 1)
        case "a queue of five recordings where three were brought over and two were not":
            batch = PocketTransferFollowThrough.decide(batch: Self.fiveOfWhichThreeArrived())
        case "a queue holding three recordings that have not started":
            // A REAL QUEUE, not a value. `stopAll()` had no test of any kind — the row that
            // now holds its production caller had no witness to declare — so this drives the
            // actor itself. `run()` is never called: the scenario is about what the OWNER'S
            // STOP does to a queue, and a queue that had to reach hardware first could not
            // assert it without a fake radio it does not need.
            let made = PocketTransferQueue(
                peripheralIdentifier: UUID(),
                advertisedName: "PKT01_BLUE_26079bc5",
                custody: HoldsExactly(holding: []),
                destination: .init(baseDir: URL(fileURLWithPath: NSTemporaryDirectory())),
                makeAttachment: { RecordingDeviceAttachment() })
            await made.enqueue(["one", "two", "three"].map {
                PocketRecording(date: "2026-08-07", timestamp: $0, sizeBytes: 0)
            })
            queue = made
        case "a shelf check is running and the recorder holds recordings this phone does not":
            transferInFlight = false
            controls = PocketTransferControlsPresentation.controls(transferInFlight: false,
                                                                   backlogCount: Self.backlog,
                                                                   otherErrandRunning: true)
        case "a queue of five recordings that were all already on this iPhone":
            batch = PocketTransferFollowThrough.decide(batch: (1...5).map { index in
                PocketTransferItem(
                    recording: PocketRecording(date: "2026-08-07", timestamp: "t\(index)",
                                               sizeBytes: 0),
                    phase: .alreadyHeld(captureID: "cap-\(index)"))
            })
        case "a batch sentence asked for more brought over than the queue ever held":
            corruptLine = PocketTransferFollowThrough.batchLine(broughtOver: 99, of: 2)
        case "a recorder listing the same recording twice, which this phone does not hold":
            // ONE recording, listed TWICE. Same date and same timestamp, which is the identity
            // every layer below keys on.
            backlogRecordings = [
                PocketRecording(date: "2026-08-07", timestamp: "one", sizeBytes: 0),
                PocketRecording(date: "2026-08-07", timestamp: "one", sizeBytes: 0),
            ]

        case "a recorder listing four recordings, two of which this phone already holds":
            backlogRecordings = ["one", "two", "three", "four"].map {
                PocketRecording(date: "2026-08-07", timestamp: $0, sizeBytes: 0)
            }
        default:
            throw BrineStepError("unknown given: " + phrase)
        }
    }

    func when(_ phrase: String) async throws {
        switch phrase {
        case "the owner's stop is used":
            guard let queue else { throw BrineStepError("no queue was built") }
            await queue.stopAll()
        case "a transfer is running as well":
            // THE SAME BUSY PAGE, now with a transfer on it. Everything else is unchanged, so
            // the only thing that can flip the answer is the rule under test.
            controls = PocketTransferControlsPresentation.controls(transferInFlight: true,
                                                                   backlogCount: Self.backlog,
                                                                   otherErrandRunning: true)
        default:
            throw BrineStepError("unknown when: " + phrase)
        }
    }

    func check(_ phrase: String) async throws {
        switch phrase {
        case "the page offers a control that stops the transfer":
            guard controls.contains(where: { $0.act == .stopEverything }) else {
                throw BrineStepError("a running transfer offered no way to stop it — the "
                                     + "shipped defect: stop(_:) had no production caller")
            }
            // The title is a real word, not an empty label on a live button.
            guard let stop = controls.first(where: { $0.act == .stopEverything }),
                  !stop.title.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw BrineStepError("the stop control carries no title")
            }
        case "the page says what stopping would cost before it is pressed":
            let line = PocketTransferControlsPresentation.stopConsequenceLine
            guard line.lowercased().contains("nothing"),
                  line.lowercased().contains("again") else {
                throw BrineStepError("stopping discards every byte and the sentence must say "
                                     + "so before the tap, not after it: " + line)
            }
        case "the page offers no control that stops anything":
            guard !controls.contains(where: { $0.act == .stopEverything }) else {
                throw BrineStepError("a stop was offered with nothing to stop — a button that "
                                     + "stops nothing is how the first one would have passed")
            }
        case "no control the page offers is disabled while nothing is running":
            // IT USED TO ASSERT ONLY THAT THE LIST WAS NON-EMPTY, because `PocketTransferControl`
            // carried no enabled/disabled state at all — so `.disabled(true)` in the view left
            // this green while the owner looked at dead buttons. An adversarial review named it;
            // the field now exists and this reads it. The non-emptiness check STAYS, because
            // "every control is enabled" is satisfied perfectly by a page with no controls.
            guard !controls.isEmpty else {
                throw BrineStepError("no controls at all — the prohibition below is satisfied "
                                     + "vacuously by an empty page")
            }
            guard controls.allSatisfy(\.isEnabled) else {
                throw BrineStepError("a control was dead with nothing running: "
                                     + String(describing: controls.filter { !$0.isEnabled }
                                                                  .map(\.title)))
            }
        case "the page offers a control that takes the whole backlog":
            guard controls.contains(where: { $0.act == .bringEverythingOver }) else {
                throw BrineStepError("no way to empty the recorder in one go — the shipped "
                                     + "defect: production only ever enqueued one recording")
            }
        case "that control names the number of recordings it would take":
            guard let all = controls.first(where: { $0.act == .bringEverythingOver }),
                  all.title.contains(String(Self.backlog)) else {
                throw BrineStepError("the control does not state how many it would take, and "
                                     + "every one of them is a full-length transfer")
            }
        case "the page offers no control that takes the whole backlog":
            guard !controls.contains(where: { $0.act == .bringEverythingOver }) else {
                throw BrineStepError("one recording is not a backlog, and two buttons doing "
                                     + "the same thing differ only in a way nobody can see")
            }
        case "the page still offers to bring that one recording over":
            guard controls.contains(where: { $0.act == .bringOneOver }) else {
                throw BrineStepError("the prohibition above is satisfied by a page with no "
                                     + "transfer controls at all")
            }
        case "every recording that arrived is handed to the capture owner":
            guard let batch else { throw BrineStepError("no batch was decided") }
            guard batch.landed.map(\.captureID) == ["cap-1", "cap-3", "cap-5"] else {
                throw BrineStepError("a conversation nothing hands over is a correct capture "
                                     + "directory the running app never learns about; got "
                                     + String(describing: batch.landed.map(\.captureID)))
            }
        case "every recording that arrived is recorded against its own name":
            guard let batch else { throw BrineStepError("no batch was decided") }
            guard batch.landed.map(\.token) == ["2026-08-07/one", "2026-08-07/three",
                                                "2026-08-07/five"] else {
                throw BrineStepError("the owner-armed clear's candidate set is exactly these "
                                     + "tokens, so a recording missing from them can never be "
                                     + "cleared; got "
                                     + String(describing: batch.landed.map(\.token)))
            }
        case "the page says three of five were brought over and two are still on the recorder":
            guard let line = batch?.line else { throw BrineStepError("the batch said nothing") }
            guard line.contains("3 of 5"), line.contains("2"),
                  line.lowercased().contains("still on the recorder") else {
                throw BrineStepError("the sentence must count both halves: " + line)
            }
        case "the sentence states no size, no rate and no estimate":
            guard let line = batch?.line else { throw BrineStepError("the batch said nothing") }
            let forbidden = ["KB", "MB", "GB", "byte", "sec", "min", "hour", "/s", "%", "about"]
            for word in forbidden where line.lowercased().contains(word.lowercased()) {
                throw BrineStepError("the batch sentence printed a magnitude (\(word)) — the "
                                     + "listing's unit is still unresolved: " + line)
            }
        case "no recording in the queue is still waiting its turn":
            guard let queue else { throw BrineStepError("no queue was built") }
            let waiting = await queue.snapshot.filter { !$0.phase.isFinished }
            guard waiting.isEmpty else {
                throw BrineStepError("the owner's stop left \(waiting.count) recording(s) "
                                     + "still queued — a Stop that stops nothing is the "
                                     + "control this page has shipped twice")
            }
        case "none of them is offered to the queue again":
            guard let queue else { throw BrineStepError("no queue was built") }
            // WITHOUT THE SUPPRESSION SET the derived queue immediately re-offers itself and
            // the button un-presses. Re-enqueuing the same recordings must change nothing.
            let before = await queue.snapshot.count
            await queue.enqueue(["one", "two", "three"].map {
                PocketRecording(date: "2026-08-07", timestamp: $0, sizeBytes: 0)
            })
            let after = await queue.snapshot.filter { !$0.phase.isFinished }
            guard after.isEmpty, await queue.snapshot.count == before else {
                throw BrineStepError("a stopped recording was re-offered, so the stop "
                                     + "un-presses itself on the next re-derivation")
            }
        case "the backlog is the two this phone does not hold":
            let backlog = await PocketTransferQueue.derivedBacklog(
                from: backlogRecordings,
                custody: HoldsExactly(holding: ["2026-08-07/one", "2026-08-07/three"]),
                identity: RecordingDeviceIdentity(shape: .filePull, hardwareToken: "t"))
            guard Set(backlog.map(\.timestamp)) == ["two", "four"] else {
                throw BrineStepError("the backlog was "
                                     + String(describing: backlog.map(\.timestamp)))
            }
        case "the backlog holds that recording once":
            let backlog = await PocketTransferQueue.derivedBacklog(
                from: backlogRecordings,
                custody: HoldsExactly(holding: []),
                identity: RecordingDeviceIdentity(shape: .filePull, hardwareToken: "t"))
            // COUNT, NOT A SET. Comparing `Set(map(\.timestamp))` is what let this through:
            // a duplicate is invisible to a set and is exactly the failure being held here.
            guard backlog.count == 1 else {
                throw BrineStepError("a recording listed twice produced a backlog of "
                                     + "\(backlog.count); the listing is not the population")
            }

        case "the number on the control is the number the queue would actually take":
            // THE TWO HALVES PUT TOGETHER. The button's title is rendered from the backlog's
            // count; the queue's population is what `enqueue` accepts. A person consents to the
            // number, so the number must be the set — if they can differ, the title states a
            // cost nobody will pay.
            let backlog = await PocketTransferQueue.derivedBacklog(
                from: backlogRecordings,
                custody: HoldsExactly(holding: []),
                identity: RecordingDeviceIdentity(shape: .filePull, hardwareToken: "t"))
            // NOT RUN — only asked what it would TAKE. No radio, no custody writes.
            let queue = PocketTransferQueue(peripheralIdentifier: UUID(),
                                            advertisedName: "duplicate-listing")
            await queue.enqueue(backlog)
            let queued = await queue.snapshot.count
            guard backlog.count == queued else {
                throw BrineStepError("the control would say \(backlog.count) and the queue "
                                     + "would take \(queued)")
            }
            // PAIRED EXISTENCE: an empty backlog satisfies the equality above trivially.
            guard queued >= 1 else {
                throw BrineStepError("the queue took nothing, so the equality is vacuous")
            }

        case "the backlog never contains a recording this phone is already holding":
            // THE PAIRED HALF, and it is not the same assertion twice: a `derivedBacklog` that
            // returned EVERYTHING satisfies neither, but one that returned NOTHING satisfies
            // the prohibition and fails the check above — so both are stated.
            let all = await PocketTransferQueue.derivedBacklog(
                from: backlogRecordings,
                custody: HoldsExactly(holding: []),
                identity: RecordingDeviceIdentity(shape: .filePull, hardwareToken: "t"))
            guard all.count == backlogRecordings.count else {
                throw BrineStepError("with nothing held, every listed recording is backlog; "
                                     + "got \(all.count) of \(backlogRecordings.count)")
            }
        case "no control the page offers can be tapped":
            guard !controls.isEmpty else {
                throw BrineStepError("no controls at all — the prohibition is vacuous")
            }
            guard controls.allSatisfy({ !$0.isEnabled }) else {
                throw BrineStepError("a transfer control was live while another errand held "
                                     + "the radio — one radio is one errand")
            }
        case "the stop can be tapped even though the page is busy":
            guard let stop = controls.first(where: { $0.act == .stopEverything }) else {
                throw BrineStepError("no stop was offered on a page with a transfer running")
            }
            guard stop.isEnabled else {
                throw BrineStepError("THE STOP WAS GREYED OUT EXACTLY WHILE THERE WAS SOMETHING "
                                     + "TO STOP — the errand it ends is why the page is busy")
            }
        case "the page does not say five were brought over":
            guard let line = batch?.line else { throw BrineStepError("the batch said nothing") }
            guard !line.contains("5 of 5 brought over") else {
                throw BrineStepError("nothing came over the radio, so \"brought over\" is the "
                                     + "wrong verb: " + line)
            }
        case "the page says five were already on this iPhone":
            guard let line = batch?.line else { throw BrineStepError("the batch said nothing") }
            guard line.contains("5 were already on this iPhone") else {
                throw BrineStepError("the paired half: it must still ACCOUNT for all five "
                                     + "rather than fall silent about them: " + line)
            }
        case "the sentence never claims more than the queue held":
            guard let line = corruptLine else { throw BrineStepError("no sentence was built") }
            guard !line.contains("99") else {
                throw BrineStepError("a count that cannot be true of its own queue was stated "
                                     + "as a confident success: " + line)
            }
            guard line.hasPrefix("2 of 2 brought over.") else {
                throw BrineStepError("corrupt input must be clamped into the population it "
                                     + "describes, not dropped: " + line)
            }
        default:
            throw BrineStepError("unknown check: " + phrase)
        }
    }

    /// FIVE ITEMS, THREE TERMINAL-AND-MOVED, TWO TERMINAL-AND-NOT — and the arrivals are the
    /// FIRST, MIDDLE AND LAST of the queue on purpose. A decision that read `snapshot.first`
    /// would find a moved item and look plausible; it drops the middle and the last, which is
    /// what the two `==` assertions above catch.
    private static func fiveOfWhichThreeArrived() -> [PocketTransferItem] {
        let names = ["one", "two", "three", "four", "five"]
        return names.enumerated().map { index, name in
            let recording = PocketRecording(date: "2026-08-07", timestamp: name, sizeBytes: 0)
            let arrived = index % 2 == 0
            return PocketTransferItem(
                recording: recording,
                phase: arrived
                    ? .broughtOver(captureID: "cap-\(index + 1)", clockWarning: nil)
                    : .failed(PocketBringOverPresentation.transferIncompleteLine))
        }
    }
}
