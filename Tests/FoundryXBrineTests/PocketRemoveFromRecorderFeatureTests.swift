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
        XCTAssertEqual(result.passed, 17)
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
            "a shelf with one recording confirmed safe elsewhere and one that is not",
            "a recording Solleva has confirmed safe somewhere else",
            "a recorder whose shelf Solleva could not re-read",
            "the three things taking a recording off a recorder can cost me",
        ]
        let whens = [
            "I ask Solleva to take it off the recorder",
            "I ask Solleva to take one of each off the recorder",
            "I turn on automatic clearing for the first recorder",
            "I turn on automatic clearing for that recorder",
            "I choose to take it off the recorder",
            "I ask Solleva to take a recording off it",
        ]
        let thens = [
            "the recorder is never asked to remove anything",
            "what I was told I would lose is that this leaves one copy, on my phone",
            "what I was told is that Solleva has not checked where else it is",
            "a Vault was suggested to me and it did not stand in the way",
            "each one of them is a different sentence",
            "a Vault is offered only where this would leave no other copy",
            "not one of them withholds the deletion",
            "both of them offer to be taken off the recorder",
            "a recording Solleva has never checked on offers it too",
            "a recording the recorder is not holding offers nothing",
            "automatic clearing would take only the confirmed one",
            "it would not take a recording Solleva has never checked on",
            "what I am asked names the recorder and says the act cannot be undone",
            "what I am asked claims no copy anywhere",
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
            "I am asked to confirm first",
            "nothing is asked of the recorder until I confirm",
            "Solleva says it cannot act on that recording right now",
            "Solleva asked that recorder how full it is on the same trip",
            "a recorder that refused to remove anything is not asked how full it is",
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
    /// THE READING EVERY SHELF ROW ACTUALLY HAS BEFORE A CHECK COMPLETES: the recorder listed
    /// it — that is why there is a row — and nothing else has been asked about it.
    static let listedButUnasked = PocketRecordingPresence(
        onRecorder: PocketPlaceReading(answer: .yes, observedAt: armingInstant),
        onThisPhone: .neverAsked,
        safeElsewhere: .neverAsked)

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

    // The four scenarios added after review.
    private var shelfReadings: [PocketRecordingPresence] = []
    private var confirmationAsked: String?

    /// WHAT THE OWNER WAS TOLD THEY WERE LOSING, taken off the consent the SHIPPED path
    /// composed — `PocketRemoveFromRecorder.consent`, not a copy of its rule written here. A
    /// scenario that re-derived the consequence would pass against a production path that
    /// derived a different one.
    private var consequenceStated: PocketDeleteConsequence?

    // MARK: - Given

    func given(_ phrase: String) async throws {
        outcomes = []
        commandsSeenByTheRecorder = []
        listingReplies = []
        composed = []
        consequenceStated = nil

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

        case "a shelf with one recording confirmed safe elsewhere and one that is not":
            // ONE OF EACH, ON PURPOSE. A fixture where every row agrees cannot tell a working
            // gate from a deleted `if`: the assertion would pass whether the affordance were
            // offered to all of them or none.
            // THE THIRD ROW IS LISTED-BUT-UNASKED, NOT `nothingAsked`. A shelf row exists
            // because the recorder's own listing produced it, so `onRecorder` is `.yes` on every
            // row a person can see; only the safety answer can be missing. Using
            // `PocketRecordingPresence.nothingAsked` here would have made the row fail the
            // affordance for the WRONG reason — the recorder's answer rather than the copy's —
            // and the scenario would have passed while proving nothing about the ruling.
            shelfReadings = [Self.provenSafe, Self.onlyHere, Self.listedButUnasked]

        case "a recording Solleva has confirmed safe somewhere else":
            try await stageRecorder(removal: .removesWhatItHolds)
            presence = Self.provenSafe
            confirmationAsked = nil

        case "a recorder whose shelf Solleva could not re-read":
            // THE REACHABLE STALE STATE. A check that reached the recorder followed by one that
            // did not leaves the page drawing the old rows with NO readings behind them — the
            // page publishes `shelfRecordings` on every check and `presences` only on a check
            // that answered. Modelled here as the reading being absent for the row tapped.
            try await stageRecorder(removal: .removesWhatItHolds)
            shelfReadings = []

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

        case "the sentences a person reads about taking recordings off a recorder",
             "the three things taking a recording off a recorder can cost me":
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

        case "I choose to take it off the recorder":
            // WHAT THE ROW'S BUTTON DOES NOW: it opens the confirmation. It does NOT compose a
            // removal, and the next two checks are what hold that apart.
            guard let stack else { throw BrineStepError("no recorder was staged") }
            let before = stack.commandsWritten.count
            confirmationAsked = PocketRemoveFromRecorderPresentation.confirmation(for: .justMyPhone)
            commandsSeenByTheRecorder = Array(stack.commandsWritten.dropFirst(before))
            composed = await PocketRecorderCommandLedger.shared.composed(since: try requireMark())

        case "I ask Solleva to take a recording off it":
            // THE PAGE'S OWN GUARD, run as the page runs it: no reading for the row means the
            // errand is never reached. The assertion below is that this produces a SENTENCE.
            guard let stack else { throw BrineStepError("no recorder was staged") }
            let before = stack.commandsWritten.count
            if shelfReadings.isEmpty {
                outcomes = []
            } else {
                outcomes.append(await remove(shelfWhenStaged[0], presence: shelfReadings[0],
                                             provenance: .ownerChose))
            }
            commandsSeenByTheRecorder = Array(stack.commandsWritten.dropFirst(before))
            composed = await PocketRecorderCommandLedger.shared.composed(since: try requireMark())

        case "I turn on automatic clearing for the first recorder",
             "I turn on automatic clearing for that recorder":
            guard let store, let first else { throw BrineStepError("no recorder was remembered") }
            try store.armAutoClear(first, at: Self.armingInstant)
            armedAt = Self.armingInstant

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    /// The consequence the shipped consent carried, or a failure that says which one it was.
    private func requireConsequence(_ expected: PocketDeleteConsequence) throws {
        guard let stated = consequenceStated else {
            throw BrineStepError("no consent was composed at all, so nothing was stated — the "
                                    + "manual path is refusing rather than telling")
        }
        guard stated == expected else {
            throw BrineStepError("Solleva stated \(stated.rawValue), not \(expected.rawValue)")
        }
        guard outcomes == [.removed(stillOnTheRecorder: shelfWhenStaged.count - 1)] else {
            throw BrineStepError("Solleva stated \(stated.rawValue) and then answered "
                                    + "\(outcomes) instead of removing it")
        }
    }

    private func remove(_ recording: PocketRecording,
                        presence: PocketRecordingPresence,
                        provenance: PocketDeleteConsent.Provenance) async -> PocketRemovalOutcome {
        guard let stack, let identifier else { return .notProvenSafe }
        // THE SHIPPED DERIVATION, ASKED THE SAME QUESTION THE ERRAND IS ABOUT TO ASK IT. Same
        // function, same arguments; this only reads what the errand's own consent will carry.
        consequenceStated = PocketRemoveFromRecorder.consent(
            for: PocketRecorderFileKey(
                identity: RecordingDeviceIdentity(shape: .filePull,
                                                  hardwareToken: identifier.uuidString),
                date: recording.date,
                timestamp: recording.timestamp),
            presence: presence,
            provenance: provenance)?.consequence
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

        case "what I was told I would lose is that this leaves one copy, on my phone":
            try requireConsequence(.thisPhoneWillHoldTheOnlyCopy)

        case "what I was told is that Solleva has not checked where else it is":
            try requireConsequence(.nobodyHasCheckedWhereElseItIs)

        case "a Vault was suggested to me and it did not stand in the way":
            guard let stated = consequenceStated else {
                throw BrineStepError("no consequence was stated at all")
            }
            guard stated.vaultSuggestion != nil else {
                throw BrineStepError("\(stated.rawValue) suggested no Vault, and it is a "
                                        + "consequence that leaves no confirmed copy")
            }
            // AND IT DID NOT STAND IN THE WAY. The suggestion is a sentence, so the removal it
            // sits beside must have happened. Without this half, "a Vault is suggested" passes
            // on a build that suggests a Vault INSTEAD of deleting — the exact shape of the
            // defect Nick ruled against.
            guard outcomes == [.removed(stillOnTheRecorder: shelfWhenStaged.count - 1)] else {
                throw BrineStepError("the Vault was suggested and Solleva answered \(outcomes) "
                                        + "— the suggestion got in the way")
            }

        case "each one of them is a different sentence":
            // AN INDEPENDENTLY WRITTEN LIST, not one generated from the enum. A copy test
            // derived from the same type shrinks with the type and stays green while the
            // sentences it was written to hold disappear.
            let required = [
                "Solleva has confirmed a copy of this recording somewhere other than the "
                    + "recorder.",
                "This leaves one copy, on this iPhone.",
                "Solleva doesn't hold a copy of this recording. Taking it off the recorder "
                    + "ends it.",
                "Solleva hasn't checked whether anything else has a copy of this. Taking it "
                    + "off the recorder could be the end of it.",
            ]
            let shipped = PocketDeleteConsequence.allCases.map(\.sentence)
            guard shipped == required else {
                throw BrineStepError("the consequences read \(shipped)")
            }
            guard Set(shipped).count == required.count else {
                throw BrineStepError("one sentence is used for more than one consequence")
            }

            // EVERY ONE OF THE NINE STATES, AND NOT ONE OF THEM MAY COUNT A PLACE NOBODY ASKED.
            //
            // THE DEFECT THIS EXISTS FOR WAS FOUND BY REVIEW, NOT BY DESIGN. The first draft
            // mapped nine states onto three sentences, and four of them came out asserting a
            // copy count over a place that had never answered: "This leaves one copy, on this
            // iPhone" for a recording nobody had asked about elsewhere, and "Solleva doesn't
            // hold a copy of this recording" for two more. A count is a categorical claim; over
            // an unasked place it is simply wrong, and being wrong toward caution is still wrong
            // when the app is the thing saying it.
            for elsewhere in PocketPresenceAnswer.allCases {
                for onPhone in PocketPresenceAnswer.allCases {
                    let reading = PocketRecordingPresence(
                        onRecorder: PocketPlaceReading(answer: .yes,
                                                       observedAt: Self.armingInstant),
                        onThisPhone: PocketPlaceReading(answer: onPhone, observedAt: nil),
                        safeElsewhere: PocketPlaceReading(answer: elsewhere, observedAt: nil))
                    let said = PocketDeleteConsequence.ofRemoving(reading)
                    let counts = said == .thisPhoneWillHoldTheOnlyCopy
                        || said == .nothingElseHoldsIt
                    let bothAnswered = elsewhere != .unknown && onPhone != .unknown
                    guard !counts || bothAnswered else {
                        throw BrineStepError(
                            "(elsewhere: \(elsewhere.rawValue), phone: \(onPhone.rawValue)) is "
                                + "told \"\(said.sentence)\" — a count over a place nobody asked")
                    }
                }
            }
            // AND THE COUNTS ARE STILL REACHABLE, so the rule above is not satisfied by never
            // stating one. Both fully-answered states must produce their own categorical
            // sentence, or the fourth case has swallowed the two that matter most.
            let bothSaidNo = PocketRecordingPresence(
                onRecorder: PocketPlaceReading(answer: .yes, observedAt: Self.armingInstant),
                onThisPhone: PocketPlaceReading(answer: .no, observedAt: Self.armingInstant),
                safeElsewhere: PocketPlaceReading(answer: .no, observedAt: Self.armingInstant))
            guard PocketDeleteConsequence.ofRemoving(bothSaidNo) == .nothingElseHoldsIt,
                  PocketDeleteConsequence.ofRemoving(Self.onlyHere)
                    == .thisPhoneWillHoldTheOnlyCopy else {
                throw BrineStepError("a fully answered reading no longer states what it costs")
            }

        case "a Vault is offered only where this would leave no other copy":
            let offering = PocketDeleteConsequence.allCases
                .filter { $0.vaultSuggestion != nil }
            guard offering == [.thisPhoneWillHoldTheOnlyCopy, .nothingElseHoldsIt,
                               .nobodyHasCheckedWhereElseItIs] else {
                throw BrineStepError("a Vault is suggested on \(offering.map(\.rawValue)) — it "
                                        + "belongs where it is true and nowhere else")
            }

        case "not one of them withholds the deletion":
            // THE POPULATION, and this is the criterion the whole ruling rests on. Every one of
            // the three composes a consent, so no consequence can quietly become a gate.
            let key = PocketRecorderFileKey(
                identity: RecordingDeviceIdentity(shape: .filePull, hardwareToken: "any"),
                date: Self.day, timestamp: "20260328001919")
            for consequence in PocketDeleteConsequence.allCases {
                let consent = PocketDeleteConsent.ownerChoseThisRecording(
                    key, statingThat: consequence)
                guard consent.consequence == consequence,
                      consent.provenance == .ownerChose else {
                    throw BrineStepError("\(consequence.rawValue) did not compose an owner "
                                            + "consent carrying its own sentence")
                }
            }

        case "both of them offer to be taken off the recorder":
            let offered = shelfReadings.map(PocketRemoveFromRecorderPresentation.isOffered(for:))
            guard offered == [true, true, true] else {
                throw BrineStepError("the affordance was offered as \(offered) over readings "
                                        + "[safe elsewhere, only here, never checked] — the "
                                        + "recorder is holding all three, so all three offer it")
            }

        case "a recording Solleva has never checked on offers it too":
            // `unknown` about a copy elsewhere is not a reason to withhold the control. Held
            // over every non-yes answer, because the arm a two-valued predicate gets wrong is
            // the one nobody wrote a case for.
            for answer in PocketPresenceAnswer.allCases where answer != .yes {
                let reading = PocketRecordingPresence(
                    onRecorder: PocketPlaceReading(answer: .yes, observedAt: Self.armingInstant),
                    onThisPhone: PocketPlaceReading(answer: .yes, observedAt: Self.armingInstant),
                    safeElsewhere: PocketPlaceReading(answer: answer, observedAt: nil))
                guard PocketRemoveFromRecorderPresentation.isOffered(for: reading) else {
                    throw BrineStepError("the affordance is withheld from a recording whose "
                                            + "safety answer is \(answer.rawValue)")
                }
            }

        case "a recording the recorder is not holding offers nothing":
            // THE PAIRED EXISTENCE. Without it, "every recording offers removal" is satisfied by
            // `isOffered` returning `true`, and the predicate could not fail.
            for answer in PocketPresenceAnswer.allCases where answer != .yes {
                let reading = PocketRecordingPresence(
                    onRecorder: PocketPlaceReading(answer: answer, observedAt: nil),
                    onThisPhone: PocketPlaceReading(answer: .yes, observedAt: Self.armingInstant),
                    safeElsewhere: PocketPlaceReading(answer: .yes, observedAt: Self.armingInstant))
                guard !PocketRemoveFromRecorderPresentation.isOffered(for: reading) else {
                    throw BrineStepError("the affordance is offered for a recording the recorder "
                                            + "answers \(answer.rawValue) about")
                }
            }

        case "automatic clearing would take only the confirmed one":
            let mayTake = shelfReadings.map(PocketRemoveFromRecorderPresentation.autoClearMayTake)
            guard mayTake == [true, false, false] else {
                throw BrineStepError("the armed clear would take \(mayTake) over readings "
                                        + "[safe elsewhere, only here, never checked] — the "
                                        + "manual ruling must not have moved this bar")
            }

        case "it would not take a recording Solleva has never checked on":
            for answer in PocketPresenceAnswer.allCases where answer != .yes {
                let reading = PocketRecordingPresence(
                    onRecorder: PocketPlaceReading(answer: .yes, observedAt: Self.armingInstant),
                    onThisPhone: PocketPlaceReading(answer: .yes, observedAt: Self.armingInstant),
                    safeElsewhere: PocketPlaceReading(answer: answer, observedAt: nil))
                guard !PocketRemoveFromRecorderPresentation.autoClearMayTake(reading) else {
                    throw BrineStepError("the armed clear would take a recording whose safety "
                                            + "answer is \(answer.rawValue)")
                }
                guard PocketDeleteConsent.ownerArmedThisRecorder(
                    PocketRecorderFileKey(
                        identity: RecordingDeviceIdentity(shape: .filePull,
                                                          hardwareToken: "armed"),
                        date: Self.day, timestamp: "20260328001919"),
                    provenSafeBy: reading) == nil else {
                    throw BrineStepError("the armed factory composed a consent for a recording "
                                            + "whose safety answer is \(answer.rawValue)")
                }
            }

        case "I am asked to confirm first":
            guard confirmationAsked != nil else {
                throw BrineStepError("choosing to remove a recording asked nothing — the "
                                        + "confirmation this behaviour wrote has no call site")
            }

        case "what I am asked names the recorder and says the act cannot be undone":
            let asked = confirmationAsked ?? ""
            // IT NAMES THE ACT, NOT THE RECORDING'S FATE. "Solleva can't get it back" was the
            // first wording and it reads as "the recording is unrecoverable" — false for one
            // a Vault already holds, and this band is shown for all four consequences.
            guard asked.contains("off the recorder"), asked.contains("can't be undone") else {
                throw BrineStepError("the confirmation reads \"\(asked)\" — it must name the "
                                        + "recorder as what the recording is leaving AND say "
                                        + "that taking it off cannot be undone")
            }
            for fate in ["get it back", "gone", "lost forever"] where asked.contains(fate) {
                throw BrineStepError("the confirmation says \"\(fate)\" about the RECORDING, "
                                        + "which is false whenever something else holds a copy — "
                                        + "what cannot be undone is the removal")
            }

        case "what I am asked claims no copy anywhere":
            // THE DEFECT THIS EXISTS FOR, AND IT IS THE ONE THE RULING CREATED. This band used
            // to append "Solleva has confirmed a copy on your computer." — safe to say only
            // while the durability guard made a removal without one impossible. With that guard
            // gone from the manual path, the same sentence over a recording nothing else holds
            // would be the app talking the owner into the deletion. Held over EVERY brain,
            // because the lie was tier-shaped.
            for brain in BrainChoice.allCases {
                let asked = PocketRemoveFromRecorderPresentation.confirmation(for: brain)
                for claim in ["confirmed a copy", "copy on your computer", "copy in your Vault"]
                where asked.contains(claim) {
                    throw BrineStepError("the confirmation for \(brain.rawValue) reads "
                                            + "\"\(asked)\" — it claims \"\(claim)\" about a "
                                            + "recording it was never shown a reading for")
                }
            }

        case "nothing is asked of the recorder until I confirm":
            let asked = commandsSeenByTheRecorder.filter {
                PocketRecorderWire.namesADeletion("APP&" + $0)
            }
            guard asked.isEmpty, composed.filter(\.namesADeletion).isEmpty else {
                throw BrineStepError("opening the confirmation already composed a deletion")
            }

        case "Solleva says it cannot act on that recording right now":
            // THE SENTENCE ITSELF. The page's guard used to `return` in silence here.
            guard !PocketRemoveFromRecorderPresentation.cannotActOnThisNowLine.isEmpty,
                  PocketRemoveFromRecorderPresentation.everyLine
                    .contains(PocketRemoveFromRecorderPresentation.cannotActOnThisNowLine) else {
                throw BrineStepError("there is no sentence for a tap that could not be carried "
                                        + "out, so the page has nothing to say and says it")
            }
            guard outcomes.isEmpty else {
                throw BrineStepError("an errand ran for a row with no safety reading")
            }

        case "Solleva asked that recorder how full it is on the same trip":
            let asked = commandsSeenByTheRecorder.filter { $0 == "SPACE" }
            guard !asked.isEmpty else {
                throw BrineStepError("the removal session never asked how full the recorder is: "
                                        + "the commands were \(commandsSeenByTheRecorder). The "
                                        + "owner is watching that number while trying to "
                                        + "reclaim space, and it stays frozen at whatever the "
                                        + "last check said")
            }

        case "a recorder that refused to remove anything is not asked how full it is":
            // THE PAIRED CONTROL. "The session asked how full it is" is also satisfied by a
            // session that asks unconditionally — which would spend a command, on a link whose
            // information timeout retires the whole session, for a reading nothing changed.
            // Same recorder, same call, ONE fact different: this one says no.
            try await stageRecorder(removal: .refusesEverything)
            guard let stack else { throw BrineStepError("no recorder was staged") }
            let before = stack.commandsWritten.count
            _ = await remove(shelfWhenStaged[0], presence: Self.provenSafe,
                             provenance: .ownerChose)
            let after = Array(stack.commandsWritten.dropFirst(before))
            guard !after.contains("SPACE") else {
                throw BrineStepError("a recorder that refused was still asked how full it is: "
                                        + "\(after)")
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
