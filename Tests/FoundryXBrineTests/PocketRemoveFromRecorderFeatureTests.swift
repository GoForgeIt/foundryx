import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// `features/pocket-remove-from-the-recorder.feature`.
///
/// WHAT DRIVES WHAT. Every removal here goes through the SHIPPED `PocketRemoveFromRecorder.run`,
/// which opens a real `RecordingDeviceAttachment` over a faked radio, authenticates with the
/// real `PocketBLEClient`, and composes its frame through the real
/// `PocketRecorderCommandGate`. The only injected things are the radio and the account's device
/// store. Nothing in this file re-implements the gate, the consent, or the safety predicate.
///
/// THE FIXTURE CAN REFUSE. `FakePocketBLEStack.RemovalBehaviour` models the three firmwares that
/// matter — one that removes what it holds and answers `MCU&D&ERR` for what it does not (the
/// measured behaviour of `PKT01_BLUE_26079bc5` on fw 1.6), one that says yes and removes
/// nothing, and one that refuses everything. Without the middle one, "success is the re-read and
/// never the acknowledgement" is an opinion.
final class PocketRemoveFromRecorderFeatureTests: XCTestCase {

    func testPocketRemoveFromTheRecorderFeature() async throws {
        let world = PocketRemoveWorld()
        let result = try await BrineFeatureRunner.run(
            "pocket-remove-from-the-recorder",
            registry: StepRegistry(PocketRemoveSteps.make(world)))
        XCTAssertEqual(result.passed, 11)
    }

    /// THE PREFIX COLLISION, MEASURED RATHER THAN ASSERTED. A matcher on `"MCU&D"` answers
    /// `acknowledged` to four different frames this same firmware emits, and two of them are
    /// the recorder merely saying what days it holds.
    func testAPrefixMatcherReadsFourDifferentFramesAsOneRemoval() {
        let colliding = ["MCU&D", "MCU&D&ERR", "MCU&DIRS&2026-03-28", "MCU&DIRS_SUM&005"]
        for frame in colliding {
            XCTAssertTrue(frame.hasPrefix("MCU&D"),
                          "\(frame) does not collide after all — re-read the finding")
        }
        XCTAssertEqual(colliding.map(PocketRemovalAck.read),
                       [.acknowledged, .theRecorderRefused,
                        .notAboutARemoval, .notAboutARemoval],
                       "the shipped matcher cannot tell four colliding frames apart")
    }
}

private enum PocketRemoveSteps {
    static func make(_ world: PocketRemoveWorld) -> [StepDefinition] {
        let givens = [
            "a recorder holding a recording that Solleva has not confirmed anywhere else",
            "a recorder holding a recording Solleva has never checked on",
            "a recorder holding a recording Solleva has confirmed safe somewhere else",
            "a recorder that will not remove the recording it is asked about",
            "a recorder that says yes to anything and removes nothing",
            "the answers a recorder gives while it is listing what it holds",
            "a recorder that names some of its recordings one way and the rest another way",
            "two recorders I have set up",
            "a recorder whose recordings synced before I turned automatic clearing on",
            "a recorder with automatic clearing turned on",
            "the sentences a person reads about taking recordings off a recorder",
        ]
        let whens = [
            "I ask Solleva to take it off the recorder",
            "I ask Solleva to take one of each off the recorder",
            "I turn on automatic clearing for the first recorder",
            "I turn on automatic clearing for that recorder",
        ]
        let thens = [
            "Solleva refuses and says it has not confirmed a copy anywhere else",
            "the recorder is never asked to remove anything",
            "Solleva asked that recorder to remove that one recording and no other",
            "the recorder's own shelf no longer lists it",
            "Solleva says it was removed from the recorder",
            "Solleva says the recorder would not remove it",
            "Solleva does not claim the recording is gone",
            "Solleva says the recording is still on the recorder",
            "not one of them reads as a recording having been removed",
            "a recorder's refusal reads as a refusal, not as a removal",
            "a recorder's yes still reads as a yes, so the reading is not blind",
            "each request carried the recorder's own spelling of that recording, unchanged",
            "neither of them clears anything on its own",
            "the first recorder clears a recording once it has synced",
            "the second recorder still clears nothing on its own",
            "nothing that synced before I turned it on is cleared",
            "the next recording to sync after that is cleared",
            "a recording Solleva cannot prove it holds elsewhere is still not cleared",
            "a recording Solleva has never checked on is still not cleared",
            "turning on automatic clearing says what synced is trusted to mean and where the "
                + "copy went",
            "on a phone with nowhere else to put a copy, automatic clearing is not offered at all",
            "none of them promises an amount of space nobody has measured",
            "the promise is still that Solleva never deletes anything you did not ask it to",
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

private actor PocketRemoveWorld {

    private static let secret = "0123456789abcdef"
    private static let day = "2026-03-28"
    /// The instant every date in this suite is measured against. Fixed, so "synced before you
    /// armed it" is a fact the scenario states rather than a race it runs.
    private static let armingInstant = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: The three readings, stated once

    /// Brought over, and nowhere else yet — the state a recording is in for the whole window
    /// between the transfer landing and the drain finishing.
    static let onlyHere = PocketRecordingPresence(
        onRecorder: PocketPlaceReading(answer: .yes, observedAt: armingInstant),
        onThisPhone: PocketPlaceReading(answer: .yes, observedAt: armingInstant),
        safeElsewhere: PocketPlaceReading(answer: .no, observedAt: armingInstant))
    /// Safe somewhere that is neither the recorder nor only this phone.
    static let provenSafe = PocketRecordingPresence(
        onRecorder: PocketPlaceReading(answer: .yes, observedAt: armingInstant),
        onThisPhone: PocketPlaceReading(answer: .yes, observedAt: armingInstant),
        safeElsewhere: PocketPlaceReading(answer: .yes, observedAt: armingInstant))
    /// Nobody asked anything. `unknown` is not `no`, and it is not a yes either.
    static let neverChecked = PocketRecordingPresence.nothingAsked

    private var stack: FakePocketBLEStack?
    private var secrets = InMemoryPocketSecretStore()
    private var identifier: UUID?
    private var presence = PocketRemoveWorld.neverChecked
    private var shelfWhenStaged: [PocketRecording] = []
    private var outcomes: [PocketRemovalOutcome] = []
    private var commandsSeenByTheRecorder: [String] = []
    private var listingReplies: [String] = []
    private var mark: PocketRecorderCommandLedger.Mark?
    private var composed: [PocketRecorderComposedCommand] = []

    // The armed-control half, which never touches a radio.
    private var store: RecordingDeviceStore?
    private var first: RecordingDeviceIdentity?
    private var second: RecordingDeviceIdentity?
    private var syncedBeforeArming: Date?
    private var armedAt: Date?

    // MARK: - Given

    func given(_ phrase: String) async throws {
        outcomes = []
        commandsSeenByTheRecorder = []
        listingReplies = []
        composed = []

        switch phrase {
        case "a recorder holding a recording that Solleva has not confirmed anywhere else":
            try await stageRecorder(removal: .removesWhatItHolds)
            presence = Self.onlyHere

        case "a recorder holding a recording Solleva has never checked on":
            try await stageRecorder(removal: .removesWhatItHolds)
            presence = Self.neverChecked

        case "a recorder holding a recording Solleva has confirmed safe somewhere else":
            try await stageRecorder(removal: .removesWhatItHolds)
            presence = Self.provenSafe

        case "a recorder that will not remove the recording it is asked about":
            try await stageRecorder(removal: .refusesEverything)
            presence = Self.provenSafe

        case "a recorder that says yes to anything and removes nothing":
            try await stageRecorder(removal: .saysYesAndRemovesNothing)
            presence = Self.provenSafe

        case "a recorder that names some of its recordings one way and the rest another way":
            // TWO SPELLINGS ON ONE DEVICE, MEASURED. `PKT01_BLUE_26079bc5` on fw 1.6 lists both
            // a bare `20260807142852` and a PH-prefixed `PH260811175026`. Nothing in the design
            // accounted for that, and `(date, timestamp)` is only a stable identity if the
            // spelling survives verbatim rather than being normalised on the way back out.
            try await stageRecorder(removal: .removesWhatItHolds, inventory: [
                .init(date: "2026-08-07", timestamp: "20260807142852", sizeBytes: 4_000),
                .init(date: "2026-08-11", timestamp: "PH260811175026", sizeBytes: 4_000),
            ])
            presence = Self.provenSafe

        case "the answers a recorder gives while it is listing what it holds":
            // THE REAL FRAMES, IN THE REAL COLLISION. `MCU&D` is a strict prefix of all of
            // these, and two of them are the recorder simply saying what days it holds.
            listingReplies = ["MCU&DIRS&2026-03-28", "MCU&DIRS&2026-03-29",
                              "MCU&DIRS_SUM&005", "MCU&LIST&006",
                              "MCU&F&2026-03-28&20260328001919&12", "MCU&DIRS"]

        case "two recorders I have set up":
            try stageTwoRememberedRecorders()

        case "a recorder whose recordings synced before I turned automatic clearing on":
            try stageTwoRememberedRecorders()
            syncedBeforeArming = Self.armingInstant.addingTimeInterval(-3_600)

        case "a recorder with automatic clearing turned on":
            try stageTwoRememberedRecorders()
            guard let store, let first else { throw BrineStepError("no recorder was remembered") }
            try store.armAutoClear(first, at: Self.armingInstant)
            armedAt = Self.armingInstant

        case "the sentences a person reads about taking recordings off a recorder":
            break

        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    /// TWO RECORDERS, BECAUSE THE CONTROL IS RECORDER-SCOPED. One remembered device cannot show
    /// that arming is not global; a scenario with one device passes on an implementation that
    /// arms everything.
    private func stageTwoRememberedRecorders() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pocket-autoclear-\(UUID().uuidString)", isDirectory: true)
        let store = RecordingDeviceStore(root: root, scope: "acct-step6")
        let first = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "recorder-one")
        let second = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "recorder-two")
        try store.upsert(RecordingDeviceRecord(identity: first, displayName: "The one I carry"))
        try store.upsert(RecordingDeviceRecord(identity: second, displayName: "The other one"))
        self.store = store
        self.first = first
        self.second = second
        armedAt = nil
        syncedBeforeArming = nil
    }

    private func stageRecorder(
        removal: FakePocketBLEStack.RemovalBehaviour,
        inventory: [FakePocketBLEStack.ScriptedRecording]? = nil
    ) async throws {
        let made = UUID()
        identifier = made
        let shelf = inventory ?? [
            .init(date: Self.day, timestamp: "20260328001919", sizeBytes: 4_000),
            .init(date: Self.day, timestamp: "20260328002020", sizeBytes: 4_000),
            .init(date: Self.day, timestamp: "20260328002121", sizeBytes: 4_000),
        ]
        let stack = FakePocketBLEStack(deviceId: made,
                                       deviceName: "PKT01_BLUE_26079bc5",
                                       acceptedSecret: Self.secret,
                                       inventory: shelf,
                                       removalBehaviour: removal)
        self.stack = stack
        shelfWhenStaged = shelf.map {
            PocketRecording(date: $0.date, timestamp: $0.timestamp, sizeBytes: $0.sizeBytes)
        }
        secrets = InMemoryPocketSecretStore()
        try await secrets.save(
            Self.secret,
            for: try PocketAuthenticatedIdentity(peripheralIdentifier: made.uuidString))
        mark = await PocketRecorderCommandLedger.shared.mark()
    }

    // MARK: - When

    func when(_ phrase: String) async throws {
        switch phrase {
        case "I ask Solleva to take it off the recorder":
            guard let stack, let target = shelfWhenStaged.first else {
                throw BrineStepError("no recorder was staged")
            }
            let before = stack.commandsWritten.count
            outcomes.append(await remove(target, presence: presence, provenance: .ownerChose))
            commandsSeenByTheRecorder = Array(stack.commandsWritten.dropFirst(before))
            composed = await PocketRecorderCommandLedger.shared.composed(since: try requireMark())

        case "I ask Solleva to take one of each off the recorder":
            guard let stack else { throw BrineStepError("no recorder was staged") }
            let before = stack.commandsWritten.count
            for recording in shelfWhenStaged {
                outcomes.append(await remove(recording, presence: presence,
                                             provenance: .ownerChose))
            }
            commandsSeenByTheRecorder = Array(stack.commandsWritten.dropFirst(before))

        case "I turn on automatic clearing for the first recorder",
             "I turn on automatic clearing for that recorder":
            guard let store, let first else { throw BrineStepError("no recorder was remembered") }
            try store.armAutoClear(first, at: Self.armingInstant)
            armedAt = Self.armingInstant

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    private func remove(_ recording: PocketRecording,
                        presence: PocketRecordingPresence,
                        provenance: PocketDeleteConsent.Provenance) async -> PocketRemovalOutcome {
        guard let stack, let identifier else { return .notProvenSafe }
        return await PocketRemoveFromRecorder.run(
            peripheralIdentifier: identifier,
            advertisedName: stack.deviceName,
            recording: recording,
            presence: presence,
            provenance: provenance,
            attachment: RecordingDeviceAttachment(
                makeCentral: stack.factory,
                secrets: secrets,
                recovery: nil,
                deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 2)))
    }

    // MARK: - Then

    func then(_ phrase: String) async throws {
        switch phrase {

        case "Solleva refuses and says it has not confirmed a copy anywhere else":
            guard outcomes == [.notProvenSafe] else {
                throw BrineStepError("Solleva answered \(outcomes) instead of refusing")
            }
            guard PocketRemoveFromRecorderPresentation.message(for: .notProvenSafe)
                == PocketRemoveFromRecorderPresentation.notProvenSafeLine else {
                throw BrineStepError("the refusal does not say why")
            }

        case "the recorder is never asked to remove anything":
            let asked = commandsSeenByTheRecorder.filter {
                PocketRecorderWire.namesADeletion("APP&" + $0)
            }
            guard asked.isEmpty else {
                throw BrineStepError("the recorder was asked \(asked.count) time(s): \(asked)")
            }
            let composedDeletes = composed.filter(\.namesADeletion)
            guard composedDeletes.isEmpty else {
                throw BrineStepError(
                    "\(composedDeletes.count) delete frame(s) were composed for a recording "
                        + "nobody proved safe: \(composedDeletes.map(\.frame))")
            }
            // THE PAIRED EXISTENCE ASSERTION, OVER THE SAME POPULATION. "No delete reached the
            // recorder" is satisfied by a recorder nobody ever spoke to, and this scenario
            // opens no session at all — so on its own it is the vacuous shape every prohibition
            // in this repository is required to pair against. The SAME recording, the SAME
            // recorder, the SAME call, with the ONE fact changed: the shelf can now state that
            // Solleva holds it elsewhere.
            guard let stack, let target = shelfWhenStaged.first else {
                throw BrineStepError("no recorder was staged")
            }
            let before = stack.commandsWritten.count
            _ = await remove(target, presence: Self.provenSafe, provenance: .ownerChose)
            let control = Array(stack.commandsWritten.dropFirst(before)).filter {
                PocketRecorderWire.namesADeletion("APP&" + $0)
            }
            guard control.count == 1 else {
                throw BrineStepError(
                    "POSITIVE CONTROL FAILED: the same recording, proven safe, put "
                        + "\(control.count) delete(s) on the wire — so the absence above "
                        + "proves nothing about the predicate")
            }

        case "Solleva asked that recorder to remove that one recording and no other":
            guard let target = shelfWhenStaged.first else {
                throw BrineStepError("no recorder was staged")
            }
            let asked = commandsSeenByTheRecorder.filter {
                PocketRecorderWire.namesADeletion("APP&" + $0)
            }
            guard asked == ["D&\(target.date)&\(target.timestamp)"] else {
                throw BrineStepError("the recorder was asked \(asked), not for exactly the one "
                                        + "recording \(target.date)/\(target.timestamp)")
            }

        case "the recorder's own shelf no longer lists it":
            guard let stack, let target = shelfWhenStaged.first else {
                throw BrineStepError("no recorder was staged")
            }
            let held = stack.shelf
            guard !held.contains(where: {
                $0.date == target.date && $0.timestamp == target.timestamp
            }) else {
                throw BrineStepError("the recorder is still holding \(target.timestamp)")
            }
            // AND IT KEPT THE REST. A fixture that emptied its whole shelf would satisfy the
            // line above while describing a catastrophe.
            guard held.count == shelfWhenStaged.count - 1 else {
                throw BrineStepError(
                    "the recorder went from \(shelfWhenStaged.count) recordings to "
                        + "\(held.count) — one removal took \(shelfWhenStaged.count - held.count)")
            }

        case "Solleva says it was removed from the recorder":
            guard outcomes == [.removed(stillOnTheRecorder: shelfWhenStaged.count - 1)] else {
                throw BrineStepError("Solleva answered \(outcomes)")
            }
            guard PocketRemoveFromRecorderPresentation.message(for: outcomes[0])
                == PocketRemoveFromRecorderPresentation.removedLine else {
                throw BrineStepError("the removal is not reported in words")
            }

        case "Solleva says the recorder would not remove it":
            guard outcomes == [.theRecorderRefused] else {
                throw BrineStepError("Solleva answered \(outcomes) for a recorder that said ERR")
            }
            guard PocketRemoveFromRecorderPresentation.message(for: .theRecorderRefused)
                == PocketRemoveFromRecorderPresentation.recorderRefusedLine else {
                throw BrineStepError("the refusal is not reported in the recorder's own terms")
            }

        case "Solleva says the recording is still on the recorder":
            guard outcomes == [.stillListedAfterwards] else {
                throw BrineStepError(
                    "a recorder that acknowledged and removed nothing was reported as "
                        + "\(outcomes) — the acknowledgement was trusted")
            }

        case "Solleva does not claim the recording is gone":
            guard let stack, let target = shelfWhenStaged.first else {
                throw BrineStepError("no recorder was staged")
            }
            guard stack.shelf.contains(where: {
                $0.date == target.date && $0.timestamp == target.timestamp
            }) else {
                throw BrineStepError("the fixture removed it after all — the scenario is void")
            }
            for outcome in outcomes {
                if case .removed = outcome {
                    throw BrineStepError("Solleva reported a removal that did not happen")
                }
                guard PocketRemoveFromRecorderPresentation.message(for: outcome)
                        != PocketRemoveFromRecorderPresentation.removedLine else {
                    throw BrineStepError("the sentence says it was removed, and it was not")
                }
            }

        case "not one of them reads as a recording having been removed":
            guard !listingReplies.isEmpty else {
                throw BrineStepError("no listing frames were staged")
            }
            let misread = listingReplies.filter { PocketRemovalAck.read($0) != .notAboutARemoval }
            guard misread.isEmpty else {
                throw BrineStepError("\(misread) read as an answer about a removal")
            }

        case "a recorder's refusal reads as a refusal, not as a removal":
            guard PocketRemovalAck.read("MCU&D&ERR") == .theRecorderRefused else {
                throw BrineStepError(
                    "MCU&D&ERR reads as \(PocketRemovalAck.read("MCU&D&ERR")) — a recorder "
                        + "saying no is being read as a recording having gone")
            }

        case "a recorder's yes still reads as a yes, so the reading is not blind":
            guard PocketRemovalAck.read("MCU&D") == .acknowledged else {
                throw BrineStepError("MCU&D reads as \(PocketRemovalAck.read("MCU&D"))")
            }

        case "each request carried the recorder's own spelling of that recording, unchanged":
            let asked = commandsSeenByTheRecorder.filter {
                PocketRecorderWire.namesADeletion("APP&" + $0)
            }
            let expected = shelfWhenStaged.map { "D&\($0.date)&\($0.timestamp)" }
            guard asked == expected else {
                throw BrineStepError("the recorder was asked \(asked), not \(expected)")
            }
            // AND THE TWO SPELLINGS ARE GENUINELY DIFFERENT, so this is not one shape asserted
            // twice. One is bare digits; the other carries the firmware's `PH` prefix.
            let spellings = Set(shelfWhenStaged.map { $0.timestamp.prefix(2) })
            guard spellings.count == 2 else {
                throw BrineStepError("the fixture used one spelling, so nothing was proven")
            }

        case "neither of them clears anything on its own":
            guard let store, let first, let second else {
                throw BrineStepError("no recorder was remembered")
            }
            for identity in [first, second] {
                let control = try store.autoClear(for: identity)
                guard !control.isArmed else {
                    throw BrineStepError("\(identity) is armed on a recorder nobody armed")
                }
                let decision = control.decision(syncedAt: Self.armingInstant,
                                                presence: Self.provenSafe)
                guard decision == .thisRecorderIsNotArmed else {
                    throw BrineStepError(
                        "an unarmed recorder answered \(decision) for a recording that is safe "
                            + "elsewhere — automatic clearing is on by default")
                }
                // AND THE CONSENT IS NOT AVAILABLE EITHER. The control being off is a setting;
                // this is the invariant underneath it.
                guard PocketRemoveFromRecorder.consent(
                        for: PocketRecorderFileKey(identity: identity,
                                                   date: Self.day, timestamp: "20260328001919"),
                        presence: Self.neverChecked,
                        provenance: .ownerArmedThisRecorder) == nil else {
                    throw BrineStepError("an armed path can consent to an unchecked recording")
                }
            }

        case "the first recorder clears a recording once it has synced":
            guard let store, let first else { throw BrineStepError("no recorder was remembered") }
            let control = try store.autoClear(for: first)
            guard control.isArmed else { throw BrineStepError("arming did not stick") }
            let decision = control.decision(
                syncedAt: Self.armingInstant.addingTimeInterval(60), presence: Self.provenSafe)
            guard decision == .clears else {
                throw BrineStepError("an armed recorder answered \(decision) for a recording "
                                        + "that synced after it was armed")
            }

        case "the second recorder still clears nothing on its own":
            guard let store, let second else { throw BrineStepError("no recorder was remembered") }
            let control = try store.autoClear(for: second)
            guard !control.isArmed else {
                throw BrineStepError("arming one recorder armed the other — the control is "
                                        + "global, and the ruling says it is per recorder")
            }
            let decision = control.decision(
                syncedAt: Self.armingInstant.addingTimeInterval(60), presence: Self.provenSafe)
            guard decision == .thisRecorderIsNotArmed else {
                throw BrineStepError("the recorder nobody armed answered \(decision)")
            }

        case "nothing that synced before I turned it on is cleared":
            guard let store, let first, let synced = syncedBeforeArming else {
                throw BrineStepError("no backlog was staged")
            }
            let decision = try store.autoClear(for: first)
                .decision(syncedAt: synced, presence: Self.provenSafe)
            guard decision == .itSyncedBeforeYouArmedThisRecorder else {
                throw BrineStepError(
                    "a recording that synced an hour before the control was armed answered "
                        + "\(decision) — arming reached back over the backlog")
            }

        case "the next recording to sync after that is cleared":
            guard let store, let first, let armedAt else {
                throw BrineStepError("nothing was armed")
            }
            let decision = try store.autoClear(for: first)
                .decision(syncedAt: armedAt.addingTimeInterval(1), presence: Self.provenSafe)
            guard decision == .clears else {
                throw BrineStepError("the control clears nothing at all: \(decision)")
            }

        case "a recording Solleva cannot prove it holds elsewhere is still not cleared":
            try assertArmedRefuses(Self.onlyHere)

        case "a recording Solleva has never checked on is still not cleared":
            try assertArmedRefuses(Self.neverChecked)

        case "turning on automatic clearing says what synced is trusted to mean and where the "
            + "copy went":
            for brain in [BrainChoice.myComputer, .foundryCloud] {
                guard let sentence =
                        PocketRemoveFromRecorderPresentation.autoClearExplanation(for: brain)
                else { throw BrineStepError("\(brain) offers the control with no sentence") }
                guard sentence.lowercased().contains("synced means confirmed") else {
                    throw BrineStepError(
                        "\(brain)'s sentence does not say what synced is trusted to mean: "
                            + sentence)
                }
                let destination = brain == .myComputer ? "your computer" : "your Vault"
                guard sentence.contains(destination) else {
                    throw BrineStepError("\(brain)'s sentence does not name \(destination)")
                }
            }
            // AND THE TWO SENTENCES ARE DIFFERENT. One sentence reused for both destinations
            // would satisfy every line above while naming the wrong place for one of them.
            guard PocketRemoveFromRecorderPresentation.autoClearExplanation(for: .myComputer)
                != PocketRemoveFromRecorderPresentation.autoClearExplanation(for: .foundryCloud)
            else { throw BrineStepError("both destinations share one sentence") }
            guard PocketRemoveFromRecorderPresentation.autoClearNotRetroactiveLine
                    .lowercased().contains("from now on") else {
                throw BrineStepError("nothing tells a person the control is not retroactive")
            }

        case "on a phone with nowhere else to put a copy, automatic clearing is not offered at all":
            guard PocketRemoveFromRecorderPresentation
                    .autoClearExplanation(for: .justMyPhone) == nil else {
                throw BrineStepError(
                    "the phone-only brain is offered a control that can never fire — nothing on "
                        + "that tier ever becomes safe elsewhere")
            }
            guard PocketRemoveFromRecorderPresentation.autoClearUnavailableLine
                    .contains("this iPhone") else {
                throw BrineStepError("the absence is stated without saying why")
            }

        case "none of them promises an amount of space nobody has measured":
            let population = PocketRemoveFromRecorderPresentation.everyLine
                + PocketRecorderCheckPresentation.everyLine
                + PocketPresencePresentation.everyLine
                + RecordingDeviceReadingPresentation.everyLine
            guard population.count > 20 else {
                throw BrineStepError("the population is \(population.count) lines — a "
                                        + "prohibition over a near-empty set proves nothing")
            }
            // NO REMOVAL HAS EVER BEEN ISSUED TO A REAL FILE, so no `APP&SPACE` delta has ever
            // been observed. Until one is, this surface does not promise one.
            for forbidden in ["free up space", "frees up", "make room", "reclaim"] {
                let offenders = population.filter { $0.lowercased().contains(forbidden) }
                guard offenders.isEmpty else {
                    throw BrineStepError("\(offenders) promise \"\(forbidden)\", which nobody "
                                            + "has measured")
                }
            }
            // AND THE THING IT SAYS INSTEAD IS ACTUALLY THERE.
            guard population.contains(where: {
                $0.lowercased().contains("off the recorder")
                    || $0.lowercased().contains("remove it from the recorder")
            }) else {
                throw BrineStepError("the surface says nothing about the recorder at all")
            }

        case "the promise is still that Solleva never deletes anything you did not ask it to":
            guard PocketRecorderCustodyPromise.text
                == "Solleva never deletes anything you didn't ask it to." else {
                throw BrineStepError("the promise changed: \(PocketRecorderCustodyPromise.text)")
            }
            guard PocketRecorderCheckPresentation.sectionNote
                .contains(PocketRecorderCustodyPromise.text) else {
                throw BrineStepError("the panel no longer renders the promise")
            }

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    /// AN ARMED CONTROL MEETS THE SAME BAR A TAP DOES — asserted at BOTH levels, because they
    /// are two different mistakes. The setting could be right and the consent factory wrong.
    private func assertArmedRefuses(_ presence: PocketRecordingPresence) throws {
        guard let store, let first, let armedAt else {
            throw BrineStepError("nothing was armed")
        }
        let decision = try store.autoClear(for: first)
            .decision(syncedAt: armedAt.addingTimeInterval(60), presence: presence)
        guard decision == .notProvenSafe else {
            throw BrineStepError("an armed recorder answered \(decision) for a recording "
                                    + "Solleva cannot prove it holds elsewhere")
        }
        guard PocketRemoveFromRecorder.consent(
                for: PocketRecorderFileKey(identity: first, date: Self.day,
                                           timestamp: "20260328001919"),
                presence: presence,
                provenance: .ownerArmedThisRecorder) == nil else {
            throw BrineStepError("the armed path produced a consent for an unproven recording")
        }
    }

    private func requireMark() throws -> PocketRecorderCommandLedger.Mark {
        guard let mark else { throw BrineStepError("no ledger window was opened") }
        return mark
    }
}
