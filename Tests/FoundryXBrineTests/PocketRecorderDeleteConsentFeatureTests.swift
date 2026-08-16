import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// `features/pocket-recorder-delete-consent.feature`.
///
/// WHAT THE OLD GATE WAS, AND WHY IT COULD NOT FAIL. Two things claimed to hold the deletion
/// promise before this file existed:
///
///   * `PocketRecorderCustodyPromise.automaticDeleteCommands == 0`, asserted in four suites. It
///     is a CONSTANT. `PocketDurableSyncFeatureTests` reads the constant into a variable and
///     asserts the variable equals zero — a claim about a literal, which no change to any code
///     path this app runs could ever falsify.
///   * `PocketBringOverFeatureTests`' scan of the composed commands for `"DEL"`. The recorder's
///     delete is `APP&D&<date>&<timestamp>`. `"APP&D&2026-03-28&20260328001919".uppercased()`
///     does not contain `"DEL"`, so a bring-over that composed a real delete passed that check.
///     That is measured in `testTheOldDeleteScanCouldNotSeeARealDelete` below, and it is the
///     reason this file exists.
///
/// The population here is the SHIPPED `PocketBLEClient` writing to the SHIPPED transport seam,
/// driven through a real bring-over, a real failed pull and its retry, the real retention sweep
/// and the real upload/finalize lane — and read back out of the production census the client
/// writes to. Only the radio, the custody directory, the capture library and the two door
/// closures are injected.
final class PocketRecorderDeleteConsentFeatureTests: XCTestCase {

    func testPocketRecorderDeleteConsentFeature() async throws {
        let world = PocketDeleteConsentWorld()
        let result = try await BrineFeatureRunner.run(
            "pocket-recorder-delete-consent",
            registry: StepRegistry(PocketDeleteConsentSteps.make(world)))
        XCTAssertEqual(result.passed, 7)
    }

    /// THE DEFECT, MEASURED RATHER THAN ASSERTED. The gate that shipped scanned composed
    /// commands for the substring `DEL`, and the recorder's delete opcode is one letter.
    func testTheOldDeleteScanCouldNotSeeARealDelete() {
        let realDelete = "APP&D&2026-03-28&20260328001919"
        XCTAssertFalse(realDelete.uppercased().contains("DEL"),
                       "the shipped scan would have caught this after all — re-read the finding")
        XCTAssertTrue(PocketRecorderWire.namesADeletion(realDelete),
                      "the replacement gate cannot see the delete the old one missed")
    }
}

private enum PocketDeleteConsentSteps {
    static func make(_ world: PocketDeleteConsentWorld) -> [StepDefinition] {
        let givens = [
            "a recorder holding three recordings and none of them yet in Solleva",
            "the way a person's choice to remove a recording is carried",
            "the answers a recorder gives while it is listing what it holds",
            "the recorder panel a person reads before bringing anything over",
            "a recording that is on the recorder and nowhere else Solleva can prove",
        ]
        let whens = [
            "Solleva brings one over, retries a failed one, runs its retention sweep, and "
                + "sends what it is holding",
            "something inside Solleva asks that recorder to forget a recording nobody chose",
        ]
        let thens = [
            "a person's choice to remove it cannot even be recorded",
            "the same is true when Solleva has simply never checked",
            "a recording Solleva can prove it holds elsewhere CAN be chosen, so the bar is not "
                + "just always-no",
            "arming a recorder to clear itself cannot record a choice about that recording "
                + "either",
            "a recording Solleva holds elsewhere can be cleared by an armed recorder",
            "Solleva can tell the two paths apart afterwards",
            "Solleva composed commands to that recorder",
            "not one of them was a delete",
            "the recorder is never asked",
            "Solleva records that it refused, and that the reason was that nobody chose it",
            "there is exactly one way to make that choice, and it names the one recording",
            "nothing can make that choice without going through it",
            "not one of them reads as a recording having been removed",
            "the answer to a real removal still reads as one, so the reading is not blind",
            "it promises never to delete anything they did not ask it to",
            "it no longer claims Solleva cannot delete at all",
            "nothing Solleva does on its own is counted as something a person asked for",
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

/// Records the two calls that would otherwise reach a real door — the same seams
/// `PocketBringOverFeatureTests` injects at.
private final class DeleteGateDoorSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _finalized: [String] = []
    private var _uploaded: [String] = []
    var finalized: [String] { lock.withLock { _finalized } }
    var uploaded: [String] { lock.withLock { _uploaded } }
    func finalize(_ id: String) { lock.withLock { _finalized.append(id) } }
    func upload(_ id: String) { lock.withLock { _uploaded.append(id) } }
}

private actor PocketDeleteConsentWorld {
    private static let secret = "0123456789abcdef"
    private static let day = "2026-03-28"

    static func fixtureMP3(repeats: Int = 1) -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/pocket/pocket-fw16-3s.mp3")
        guard let one = try? Data(contentsOf: root) else { return Data() }
        guard repeats > 1 else { return one }
        var many = Data()
        for _ in 0..<repeats { many.append(one) }
        return many
    }

    private var stack: FakePocketBLEStack?
    private var secrets = InMemoryPocketSecretStore()
    private var identifier: UUID?
    private var custody: PocketRecorderFileStore?
    private var library: URL?
    private var shelf: [PocketRecording] = []
    private var door = DeleteGateDoorSpy()

    /// THE WINDOW. Everything the scenario drives is read back relative to this, so a
    /// concurrently-running Pocket suite cannot lend this one its commands or hide a delete.
    private var mark: PocketRecorderCommandLedger.Mark?
    private var composed: [PocketRecorderComposedCommand] = []
    private var outcomes: [PocketBringOverOutcome] = []
    private var sweptCaptureIDs: [String] = []
    private var finalizedCaptureIDs: [String] = []
    private var opusSegmentsToSend = 0
    private var adoptedTheCapture = false
    private var admission: PocketRecorderCommandGate.Admission?
    private var commandsOnTheWireDuringRefusal: [String] = []
    private var listingReplies: [String] = []
    /// A recording whose safety Solleva cannot demonstrate — the state the ruling forbids a
    /// deletion in, and the one every unchecked recorder is in.
    private var unprovenFile: PocketRecorderFileKey?

    private static let then = Date(timeIntervalSince1970: 1_800_000_000)
    /// Brought over, and nowhere else yet. The state a recording is in for the whole window
    /// between the transfer landing and the drain finishing.
    static let onlyHere = PocketRecordingPresence(
        onRecorder: PocketPlaceReading(answer: .yes, observedAt: then),
        onThisPhone: PocketPlaceReading(answer: .yes, observedAt: then),
        safeElsewhere: PocketPlaceReading(answer: .no, observedAt: then))
    /// Safe somewhere that is neither the recorder nor only this phone.
    static let provenSafe = PocketRecordingPresence(
        onRecorder: PocketPlaceReading(answer: .yes, observedAt: then),
        onThisPhone: PocketPlaceReading(answer: .yes, observedAt: then),
        safeElsewhere: PocketPlaceReading(answer: .yes, observedAt: then))
    /// HELD, NOT DROPPED. A `CaptureManager` released while its own drain is in flight takes
    /// the drain with it, and the send leg then contributes nothing to the census for a reason
    /// that has nothing to do with deletions.
    private var manager: CaptureManager?

    // MARK: - Given

    func given(_ phrase: String) async throws {
        outcomes = []
        composed = []
        sweptCaptureIDs = []
        finalizedCaptureIDs = []
        opusSegmentsToSend = 0
        adoptedTheCapture = false
        admission = nil
        commandsOnTheWireDuringRefusal = []
        listingReplies = []
        door = DeleteGateDoorSpy()
        secrets = InMemoryPocketSecretStore()

        switch phrase {
        case "a recorder holding three recordings and none of them yet in Solleva":
            let audio = Self.fixtureMP3()
            let unique = UUID().uuidString
            let made = UUID()
            identifier = made
            custody = PocketRecorderFileStore(
                root: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("pocket-delete-gate-\(unique)"))
            let captures = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pocket-delete-gate-library-\(unique)", isDirectory: true)
            try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
            library = captures
            // THREE RECORDINGS, AND THE MIDDLE ONE STOPS ARRIVING PARTWAY. A retry is only a
            // real path if something actually failed, and a recorder that never fails would
            // make "retries a failed one" a sentence rather than a step.
            let inventory: [FakePocketBLEStack.ScriptedRecording] = [
                .init(date: Self.day, timestamp: "20260328001919",
                      sizeBytes: audio.count, content: audio),
                .init(date: Self.day, timestamp: "20260328002020",
                      sizeBytes: audio.count, content: audio.prefix(audio.count / 3)),
                .init(date: Self.day, timestamp: "20260328002121",
                      sizeBytes: audio.count, content: audio),
            ]
            let stack = FakePocketBLEStack(deviceId: made,
                                           deviceName: "PKT01_BLUE_26079bc5",
                                           acceptedSecret: Self.secret,
                                           inventory: inventory)
            self.stack = stack
            shelf = inventory.map {
                PocketRecording(date: $0.date, timestamp: $0.timestamp, sizeBytes: $0.sizeBytes)
            }
            try await secrets.save(
                Self.secret,
                for: try PocketAuthenticatedIdentity(peripheralIdentifier: made.uuidString))
            mark = await PocketRecorderCommandLedger.shared.mark()

        case "the way a person's choice to remove a recording is carried",
             "the recorder panel a person reads before bringing anything over":
            break

        case "a recording that is on the recorder and nowhere else Solleva can prove":
            unprovenFile = PocketRecorderFileKey(
                identity: RecordingDeviceIdentity(shape: .filePull, hardwareToken: "peripheral"),
                date: Self.day, timestamp: "20260328001919")

        case "the answers a recorder gives while it is listing what it holds":
            // THE REAL COLLISION, IN THE REAL FRAMES. `APP&LIST_DIRS` is answered
            // `MCU&DIRS&<date>`, of which `MCU&D` — the delete acknowledgement — is a strict
            // prefix. A matcher written with `hasPrefix` reads every one of these as a
            // recording having been removed.
            listingReplies = ["MCU&DIRS&2026-03-28", "MCU&DIRS&2026-03-29", "MCU&DIRS",
                              "MCU&F&2026-03-28&20260328001919&12", "APP&LIST_DIRS"]

        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    // MARK: - When

    func when(_ phrase: String) async throws {
        switch phrase {
        case "Solleva brings one over, retries a failed one, runs its retention sweep, and "
            + "sends what it is holding":
            guard shelf.count == 3 else { throw BrineStepError("no recorder was staged") }
            // 1 + 2. ONE BROUGHT OVER, ONE FAILED, THAT SAME ONE RETRIED.
            outcomes.append(try await bringOver(shelf[0]))
            outcomes.append(try await bringOver(shelf[1]))
            outcomes.append(try await bringOver(shelf[1]))
            // 3. THE SEND: the ordinary upload + finalize lane every recording uses.
            try await sendWhatIsHeld()
            // 4. AND THE RETENTION SWEEP, on the real library, AFTER the capture is finalized —
            // which is the only state the sweep has an opinion about. Running it over a capture
            // still mid-finalize would be a sweep that could not prune anything, and a leg that
            // cannot act is not a leg this population has exercised.
            try await runTheRetentionSweep()
            composed = await PocketRecorderCommandLedger.shared.composed(since: try requireMark())

        case "something inside Solleva asks that recorder to forget a recording nobody chose":
            guard let stack else { throw BrineStepError("no recorder was staged") }
            let before = stack.commandsWritten
            // THROUGH THE SHIPPED CLIENT, NOT THROUGH THE GATE DIRECTLY.
            //
            // This step used to call `PocketRecorderCommandGate.admit` itself, which proved the
            // gate DECIDES correctly and nothing about whether the client OBEYS it. The
            // mutation that mattered — keep the call in `write`, discard its result — left that
            // version green while this client wrote every deletion handed to it. Driving the
            // real `write` over a real fake transport is what makes the refusal a behaviour
            // rather than an opinion.
            let frame = "APP&D&\(Self.day)&20260328001919"
            let transport = PocketFakeTransport(
                characteristics: PocketCharacteristicMap.primary.required,
                actions: [.control("MCU&SK&OK")])
            let client = try await PocketBLEClient.connect(transport: transport)
            try await client.authenticate(secret: "0123456789abcdef")
            let writesBeforeTheDelete = await transport.writes.count
            do {
                try await client.composeForTesting("D&\(Self.day)&20260328001919",
                                                    ownerConsent: nil)
                XCTFail("the shipped client PUT A DELETION ON THE WIRE for a recording nobody "
                            + "chose — it consulted the gate and then ignored the answer")
                admission = .admitted
            } catch let error as PocketProtocolError {
                XCTAssertEqual(error, .deletionNobodyChose,
                               "the client refused, but for the wrong reason: \(error)")
                admission = .refused(.nobodyChoseThisRecording)
            }
            // AND THE RADIO GENUINELY SAW NOTHING. The throw alone could be produced by a
            // client that wrote first and threw afterwards.
            let writesAfter = await transport.writes.count
            XCTAssertEqual(writesAfter, writesBeforeTheDelete,
                           "\(writesAfter - writesBeforeTheDelete) byte-write(s) reached the "
                               + "transport for a deletion nobody chose")
            // POSITIVE CONTROL: the same seam, the same client, a NON-delete frame — which must
            // reach the radio. Without it, a client that refuses everything passes above.
            try await client.composeForTesting("LIST_DIRS", ownerConsent: nil)
            let writesAfterControl = await transport.writes.count
            XCTAssertEqual(writesAfterControl, writesBeforeTheDelete + 1,
                           "POSITIVE CONTROL FAILED: an ordinary command did not reach the "
                               + "transport either, so the refusal above proves nothing")
            // NO SECOND `admit` HERE. The client's own consult already put exactly one refused
            // deletion into the census; asking the gate again would double-count the very
            // population the next assertion measures — and it was that direct call, not the
            // client, that this step used to test.
            _ = frame
            commandsOnTheWireDuringRefusal = Array(stack.commandsWritten.dropFirst(before.count))
            composed = await PocketRecorderCommandLedger.shared.composed(since: try requireMark())

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    private func bringOver(_ recording: PocketRecording) async throws -> PocketBringOverOutcome {
        guard let stack, let identifier, let custody, let library else {
            throw BrineStepError("no recorder was staged")
        }
        return await PocketBringOver.run(
            peripheralIdentifier: identifier,
            advertisedName: stack.deviceName,
            recording: recording,
            custody: custody,
            attachment: RecordingDeviceAttachment(
                makeCentral: stack.factory,
                secrets: secrets,
                recovery: nil,
                deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 2)),
            destination: .init(baseDir: library))
    }

    /// THE SHIPPED SWEEP, over the captures the bring-over actually made. `retentionSweep` is
    /// the same `nonisolated static` pass `CaptureManager.maybePrune` runs off the main actor
    /// every drain, so this is the production policy and not a re-statement of it.
    private func runTheRetentionSweep() async throws {
        guard let library else { throw BrineStepError("no capture library") }
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? [])
            .filter(CaptureLibrary.isNoteDirectory)
        sweptCaptureIDs = ids
        _ = CaptureManager.retentionSweep(ids: ids, baseDir: library)
    }

    /// THE APP'S HALF: hand the capture the bring-over produced to a running `CaptureManager`
    /// and let the ordinary drain upload and finalize it.
    private func sendWhatIsHeld() async throws {
        guard let library,
              let captureID = outcomes.compactMap({ $0.captureID }).first else {
            throw BrineStepError("the bring-over produced no conversation to send")
        }
        let spy = door
        let made = await MainActor.run {
            CaptureManager(target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!,
                                              bearer: "x"),
                           baseDir: library,
                           source: ReplaySource(frames: []),
                           finalize: { id, _ in spy.finalize(id) },
                           uploadSegment: { id, _, _ in spy.upload(id) })
        }
        manager = made
        await made.hydration?.value
        // WHAT THE CAPTURE ACTUALLY HOLDS, COUNTED BEFORE THE SEND IS JUDGED. `adoptCompletedCapture`
        // refuses a directory with no `seg-*.opus` in it, and on a host whose MP3 -> Opus
        // translation produced nothing there is nothing to send. Counting the segments is what
        // turns "the send did not land" into a measurement instead of a mystery — and it is a
        // positive control for the send leg: zero segments here is the same reason
        // `PocketBringOverFeatureTests` is red at this commit on this host.
        opusSegmentsToSend = ((try? FileManager.default.contentsOfDirectory(
            atPath: library.appendingPathComponent(captureID).path)) ?? [])
            .filter { $0.hasSuffix(".opus") }.count
        adoptedTheCapture = await MainActor.run { made.adoptCompletedCapture(captureId: captureID) }
        for _ in 0..<200 where spy.finalized.isEmpty {
            await made.drainPending()
            await made.retryPendingFinalizes()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        finalizedCaptureIDs = spy.finalized
    }

    private func requireMark() throws -> PocketRecorderCommandLedger.Mark {
        guard let mark else { throw BrineStepError("no ledger window was opened") }
        return mark
    }

    // MARK: - Then

    func then(_ phrase: String) async throws {
        switch phrase {

        // MARK: the population, asserted before the prohibition over it

        case "Solleva composed commands to that recorder":
            // THE PAIRED EXISTENCE ASSERTION. Delete this and "not one of them was a delete"
            // passes on a recorder nobody ever spoke to, which is the hole this gate exists to
            // close. Every leg of the population is named separately so a leg that silently
            // stopped running cannot be hidden by another leg's commands.
            XCTAssertFalse(composed.isEmpty,
                           "the census is empty — the promise below would be a claim about "
                               + "nothing")
            XCTAssertEqual(composed.filter { $0.frame.hasPrefix("APP&SK&") }.count, 3,
                           "three pulls were driven and \(composed.count) commands were "
                               + "composed: \(composed.map(\.frame))")
            XCTAssertEqual(composed.filter { $0.frame.hasPrefix("APP&U&") }.count, 3,
                           "a file was asked for on fewer than three of the three pulls")
            guard case .broughtOver = outcomes.first else {
                return XCTFail("the first pull did not land: \(outcomes)")
            }
            XCTAssertEqual(Array(outcomes.dropFirst()),
                           [.transferIncomplete, .transferIncomplete],
                           "the failing pull and its retry did not both fail, so no retry ran")
            XCTAssertEqual(sweptCaptureIDs.count, 1,
                           "the retention sweep ran over \(sweptCaptureIDs.count) captures")
            // THE SEND LEG, JUDGED AGAINST WHAT THERE WAS TO SEND. Where the host's audio
            // translation produced Opus frames, the ordinary upload + finalize lane must have
            // carried the capture. Where it produced none there is nothing to send and
            // adoption must have REFUSED — asserted, so a send that silently did nothing on a
            // working host cannot hide behind this branch.
            if opusSegmentsToSend > 0 {
                XCTAssertTrue(adoptedTheCapture)
                XCTAssertEqual(finalizedCaptureIDs.count, 1,
                               "nothing was sent, so the send leg contributed nothing to the "
                                   + "census")
            } else {
                XCTAssertFalse(adoptedTheCapture,
                               "a capture with no audio in it was adopted for sending")
                XCTAssertEqual(finalizedCaptureIDs, [])
            }

        case "not one of them was a delete":
            let deletes = composed.filter(\.namesADeletion)
            XCTAssertEqual(deletes, [],
                           "Solleva composed \(deletes.map(\.frame)) for a recorder while "
                               + "bringing one recording over, retrying one, sweeping and "
                               + "sending — no code path may compose a delete for a recording "
                               + "nobody chose")
            // AND THE SAME CLAIM AT THE OTHER SEAM: the radio's own record of every byte.
            guard let stack else { return XCTFail("no recorder was staged") }
            let onTheWire = stack.commandsWritten.filter {
                PocketRecorderWire.namesADeletion("APP&" + $0)
            }
            XCTAssertEqual(onTheWire, [],
                           "the recorder was sent \(onTheWire) — the census and the radio "
                               + "disagree, which means one of them is not measuring the "
                               + "commands this app actually composes")

        // MARK: a deletion nobody chose

        case "the recorder is never asked":
            XCTAssertEqual(admission, .refused(.nobodyChoseThisRecording),
                           "a delete nobody chose was admitted")
            XCTAssertEqual(commandsOnTheWireDuringRefusal, [],
                           "the refused delete still reached the radio as "
                               + "\(commandsOnTheWireDuringRefusal)")

        case "Solleva records that it refused, and that the reason was that nobody chose it":
            let refusals = composed.filter { $0.disposition == .refusedBecauseNobodyChoseIt }
            XCTAssertEqual(refusals.map(\.frame), ["APP&D&\(Self.day)&20260328001919"],
                           "the refusal was not recorded, so a code path that keeps composing "
                               + "deletes leaves no trace at all")
            XCTAssertTrue(refusals.allSatisfy(\.namesADeletion))
            XCTAssertEqual(composed.filter { $0.disposition == .putOnTheWire }
                               .filter(\.namesADeletion), [])

        // MARK: the safety predicate is required, not remembered

        case "a person's choice to remove it cannot even be recorded":
            let file = try XCTUnwrap(unprovenFile)
            // ON THE RECORDER, ON THIS PHONE, AND NOTHING ANYWHERE ELSE. This is the reading a
            // recording has the moment it has been brought over and before the drain and
            // finalize have put it anywhere that survives losing the phone.
            XCTAssertNil(PocketDeleteConsent.ownerChoseThisRecording(file, provenSafeBy: Self.onlyHere),
                         "a consent was minted for a recording Solleva cannot prove it holds "
                             + "anywhere but this phone — the ruling's invariant is that "
                             + "nothing leaves the recorder unless we can prove otherwise")

        case "the same is true when Solleva has simply never checked":
            let file = try XCTUnwrap(unprovenFile)
            XCTAssertNil(PocketDeleteConsent.ownerChoseThisRecording(file,
                                                                     provenSafeBy: .nothingAsked),
                         "an UNASKED place authorised a deletion. unknown must never read as "
                             + "yes on the one predicate a removal turns on")

        case "a recording Solleva can prove it holds elsewhere CAN be chosen, so the bar is not just always-no":
            // THE POSITIVE CONTROL. Without it, a factory hard-coded to return nil satisfies
            // both assertions above and makes the affordance Step 6 ships impossible rather
            // than safe.
            let file = try XCTUnwrap(unprovenFile)
            let consent = try XCTUnwrap(
                PocketDeleteConsent.ownerChoseThisRecording(file, provenSafeBy: Self.provenSafe),
                "POSITIVE CONTROL FAILED: no reading at all can authorise a removal, so the "
                    + "two refusals above prove nothing about the predicate")
            XCTAssertEqual(consent.file, file)

        case "arming a recorder to clear itself cannot record a choice about that recording either":
            let file = try XCTUnwrap(unprovenFile)
            XCTAssertNil(PocketDeleteConsent.ownerArmedThisRecorder(file, provenSafeBy: Self.onlyHere),
                         "the armed automatic clear took a LOWER bar than a person's own tap. "
                             + "The ruling is explicit that it is never retroactive to "
                             + "recordings whose safety we cannot currently demonstrate")
            XCTAssertNil(PocketDeleteConsent.ownerArmedThisRecorder(file,
                                                                    provenSafeBy: .nothingAsked))

        case "a recording Solleva holds elsewhere can be cleared by an armed recorder":
            let file = try XCTUnwrap(unprovenFile)
            let armed = try XCTUnwrap(
                PocketDeleteConsent.ownerArmedThisRecorder(file, provenSafeBy: Self.provenSafe),
                "POSITIVE CONTROL FAILED: the armed path can never authorise anything")
            XCTAssertEqual(armed.provenance, .ownerArmedThisRecorder)

        case "Solleva can tell the two paths apart afterwards":
            let file = try XCTUnwrap(unprovenFile)
            let chose = try XCTUnwrap(
                PocketDeleteConsent.ownerChoseThisRecording(file, provenSafeBy: Self.provenSafe))
            let armed = try XCTUnwrap(
                PocketDeleteConsent.ownerArmedThisRecorder(file, provenSafeBy: Self.provenSafe))
            XCTAssertNotEqual(chose.provenance, armed.provenance,
                              "both paths file under one name, so the ledger cannot answer the "
                                  + "only question anybody will ask it: which of the two "
                                  + "removed my recording")
            XCTAssertEqual(Set(PocketDeleteConsent.Provenance.allCases.map(\.rawValue)).count, 2)

        // MARK: consent cannot be made by accident

        case "there is exactly one way to make that choice, and it names the one recording":
            let key = PocketRecorderFileKey(
                identity: RecordingDeviceIdentity(shape: .filePull, hardwareToken: "peripheral"),
                date: Self.day, timestamp: "20260328001919")
            // THE SAFETY PREDICATE, HANDED OVER, because there is no other way to obtain one.
            // This is the reading the shelf row was drawn from — the ONE answer to "is this
            // safe" in this app — and the factory is failable so an unproven recording cannot
            // produce a consent at all.
            let safe = PocketRecordingPresence(
                onRecorder: PocketPlaceReading(answer: .yes, observedAt: Date()),
                onThisPhone: PocketPlaceReading(answer: .yes, observedAt: Date()),
                safeElsewhere: PocketPlaceReading(answer: .yes, observedAt: Date()))
            let consent = try XCTUnwrap(
                PocketDeleteConsent.ownerChoseThisRecording(key, provenSafeBy: safe))
            XCTAssertEqual(consent.file, key)
            XCTAssertEqual(consent.provenance, .ownerChose)
            // IT AUTHORISES THAT RECORDING AND NO OTHER. Consent is not a mode.
            XCTAssertTrue(consent.authorises(frame: "APP&D&\(Self.day)&20260328001919"))
            XCTAssertFalse(consent.authorises(frame: "APP&D&\(Self.day)&20260328002020"),
                           "consent for one recording authorised a different one")
            XCTAssertFalse(consent.authorises(frame: "APP&D&2026-03-29&20260328001919"),
                           "consent for one day authorised another day")
            // AND THE GATE HONOURS THE DIFFERENCE.
            let wrong = await PocketRecorderCommandGate.admit(
                frame: "APP&D&\(Self.day)&20260328002020", ownerConsent: consent)
            XCTAssertEqual(wrong, .refused(.consentNamesAnotherRecording))
            let right = await PocketRecorderCommandGate.admit(
                frame: "APP&D&\(Self.day)&20260328001919", ownerConsent: consent)
            XCTAssertEqual(right, .admitted,
                           "an owner's own choice was refused, which would make the affordance "
                               + "Step 6 ships impossible rather than safe")

        case "nothing can make that choice without going through it":
            let declaration = try Self.kitSource("Sources/FoundryXKit/PocketRecorderDeleteGate.swift")
            // NO PUBLIC INITIALISER, EXACTLY ONE FACTORY — asserted the way
            // `PocketMintConsent` is: over the source, because a type's shape is not
            // observable from a call site that is not allowed to exist.
            // MEASURED OVER THE TYPE'S OWN BODY rather than pinned to one spelling of the
            // signature: the previous form named the parameter list literally, so adding the
            // provenance field reddened a gate about privacy for a reason that had nothing to
            // do with privacy. What matters is that EVERY initialiser is private.
            let consentBody = Self.body(ofType: "PocketDeleteConsent", in: declaration)
            XCTAssertGreaterThan(Self.occurrences(of: "private init(", in: consentBody), 0,
                                 "PocketDeleteConsent has no private initialiser to find — the "
                                     + "assertion below is measuring nothing")
            XCTAssertEqual(Self.occurrences(of: "public init(", in: consentBody), 0,
                           "PocketDeleteConsent's initialiser is not private, so any call site "
                               + "can conjure consent")
            XCTAssertEqual(Self.occurrences(of: "init(", in: consentBody),
                           Self.occurrences(of: "private init(", in: consentBody),
                           "PocketDeleteConsent has an initialiser that is neither private nor "
                               + "counted — internal is enough to conjure consent from any "
                               + "file in this module")
            let factories = Self.occurrences(
                of: "public static func", in: Self.body(ofType: "PocketDeleteConsent",
                                                        in: declaration))
            // TWO FACTORIES, WHICH IS THE RULING'S SHAPE AND NOT A RELAXATION. Nick named two
            // paths and no third: an explicit tap, and an owner-armed automatic clear. They are
            // separately named so the ledger can say which one removed a recording, and they
            // are held at exactly two so a third way in cannot arrive unnoticed.
            XCTAssertEqual(factories, 2,
                           "PocketDeleteConsent has \(factories) factories — the ruling names "
                               + "two paths to a deletion and no third")
            let named = Set(PocketDeleteConsent.Provenance.allCases.map(\.rawValue))
            XCTAssertEqual(named, ["ownerChose", "ownerArmedThisRecorder"],
                           "the ledger cannot tell the ruling's two paths apart: \(named)")
            // AND NEITHER IS CONSTRUCTED YET: the verb is Step 6, and a consent constructed
            // today would be a consent no person was ever asked for.
            for factory in ["ownerChoseThisRecording(", "ownerArmedThisRecorder("] {
                let sites = try Self.constructionSites(of: factory)
                XCTAssertEqual(sites, [],
                               "owner consent for a deletion is constructed in \(sites) while "
                                   + "no screen can ask for it")
            }
            // THE SINGLE COMPOSER, COUNTED OVER THE WHOLE MODULE.
            //
            // This used to scan `PocketBLEProtocolClient.swift` ALONE, which is the file the
            // one composer happens to live in today — and `RecordingDeviceAttachment.write(_:to:)`
            // and `PocketSeamTransport.write` are INTERNAL to FoundryXKit, so any other file in
            // the module could have written to the command characteristic without passing the
            // gate or the census, and this gate would have stayed green. A delete composed in a
            // new file was exactly the shape it could not see.
            var composers: [String] = []
            for (path, code) in try Self.kitSources() where
                Self.occurrences(of: "transport.write(", in: code) > 0 {
                composers.append(path)
            }
            XCTAssertEqual(composers, ["Sources/FoundryXKit/PocketBLEProtocolClient.swift"],
                           "commands for a recorder are composed in \(composers) — the gate is "
                               + "not the only door")
            let client = try Self.kitSource("Sources/FoundryXKit/PocketBLEProtocolClient.swift")
            XCTAssertEqual(Self.occurrences(of: "transport.write(", in: client), 1,
                           "there is more than one place composing commands for a recorder, so "
                               + "the gate below is not the only door")
            XCTAssertEqual(Self.occurrences(of: "PocketRecorderCommandGate.admit(", in: client), 1,
                           "the one composer does not consult the gate")

        // MARK: a listing is not a deletion

        case "not one of them reads as a recording having been removed":
            XCTAssertFalse(listingReplies.isEmpty)
            let misread = listingReplies.filter(PocketRecorderWire.namesADeletion)
            XCTAssertEqual(misread, [],
                           "\(misread) was read as a deletion — `MCU&D` is a strict prefix of "
                               + "`MCU&DIRS&<date>` and a prefix match reads every directory "
                               + "listing as a file having been removed")

        case "the answer to a real removal still reads as one, so the reading is not blind":
            // THE POSITIVE CONTROL. Without it the check above passes on a reader that answers
            // no to everything.
            XCTAssertTrue(PocketRecorderWire.namesADeletion("MCU&D"))
            XCTAssertTrue(PocketRecorderWire.namesADeletion("APP&D&2026-03-28&20260328001919"))

        // MARK: the promise

        case "it promises never to delete anything they did not ask it to":
            XCTAssertEqual(PocketRecorderCustodyPromise.text,
                           "Solleva never deletes anything you didn't ask it to.")
            XCTAssertTrue(
                PocketRecorderCheckPresentation.sectionNote
                    .contains(PocketRecorderCustodyPromise.text),
                "the panel that offers a bring-over dropped the deletion promise")

        case "it no longer claims Solleva cannot delete at all":
            // THE POPULATION IS EVERY COPY FAMILY THIS SURFACE CAN DRAW, NOT THE THREE THAT
            // EXISTED WHEN THIS GATE WAS WRITTEN. The presence rows, the reset's cost, the
            // forget confirmation and the destination sentence all landed on this page after
            // this scan was written, and none of them was in it — so a line re-promising
            // "never deletes anything from your recorder" in any of them would have shipped
            // unseen by the gate whose entire job is to see it.
            let everyLine = PocketRecorderCheckPresentation.everyLine
                + PocketBringOverPresentation.everyLine
                + PocketMintConsentPresentation.everyLine
                + PocketRecorderCostPresentation.everyLine
                + PocketDestinationPresentation.everyLine
                + PocketPresencePresentation.everyLine
                + RecordingDeviceReadingPresentation.everyLine
                + [PocketRecorderCustodyPromise.text]
            XCTAssertFalse(everyLine.isEmpty)
            // AND THE SCAN CAN SEE A VIOLATION WHEN THERE IS ONE. Without this the loop below
            // is a loop that has never been shown to reject anything.
            XCTAssertTrue(
                (everyLine + ["Solleva never deletes anything from your recorder."])
                    .contains { $0.contains("never deletes anything from your recorder") },
                "POSITIVE CONTROL FAILED: the needle this gate searches for cannot be found "
                    + "even when it is deliberately present, so the loop below proves nothing")
            for line in everyLine {
                XCTAssertFalse(line.contains("never deletes anything from your recorder"),
                               "\"\(line)\" still promises Solleva cannot delete, which stops "
                                   + "being true the moment a person is allowed to ask")
                XCTAssertFalse(line.contains("never deletes anything from the recorder"),
                               "\"\(line)\" still promises Solleva cannot delete")
            }

        case "nothing Solleva does on its own is counted as something a person asked for":
            // THE INVARIANT THAT WAS ALREADY CORRECTLY NAMED AND MUST NOT BE WEAKENED. It is
            // no *automatic* delete — never was it no delete.
            // NOTE FOR STEP 6. `automaticDeleteCommands` is a CONSTANT compared to a literal —
            // no change to any code path this app runs can falsify it, and it becomes literally
            // false the day the owner-armed auto-clear ships. It is kept only until there is an
            // armed path to restate it about ("no delete on an UNARMED recorder"); the real
            // instrument is the census assertion below, which reads the population.
            XCTAssertEqual(PocketRecorderCustodyPromise.automaticDeleteCommands, 0)
            let unchosen = await PocketRecorderCommandGate.admit(
                frame: "APP&D&2026-03-28&20260328001919", ownerConsent: nil)
            XCTAssertEqual(unchosen, .refused(.nobodyChoseThisRecording))

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    // MARK: - Reading the kit's own source

    /// `swift test` can read the package source, and a type's SHAPE — no public initialiser,
    /// exactly one factory — is not observable from a call site the shape forbids.
    private static func kitSource(_ relative: String) throws -> String {
        let url = AppSourceTree.repoRoot.appendingPathComponent(relative)
        return AppSourceTree.code(of: try String(contentsOf: url, encoding: .utf8))
    }

    /// The braces-balanced body of a declaration, so "one factory" is counted inside the type
    /// rather than across the file.
    private static func body(ofType name: String, in source: String) -> String {
        guard let start = source.range(of: "public struct \(name)") else { return "" }
        var depth = 0
        var seenOpen = false
        var out = ""
        for character in source[start.lowerBound...] {
            if character == "{" { depth += 1; seenOpen = true }
            if seenOpen { out.append(character) }
            if character == "}" {
                depth -= 1
                if depth == 0 { break }
            }
        }
        return out
    }

    private static func occurrences(of needle: String, in source: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var rest = source[...]
        while let found = rest.range(of: needle) {
            count += 1
            rest = rest[found.upperBound...]
        }
        return count
    }

    /// Every production file — App-side or kit-side — whose CODE constructs consent.
    /// EVERY SWIFT FILE IN THE MODULE, as (relative path, comment-stripped code). The unit the
    /// "single composer" claim has to be made over: the write seam is module-internal.
    private static func kitSources() throws -> [(String, String)] {
        let kit = AppSourceTree.repoRoot.appendingPathComponent("Sources", isDirectory: true)
        var out: [(String, String)] = []
        guard let walk = FileManager.default.enumerator(at: kit, includingPropertiesForKeys: nil)
        else { return out }
        for case let url as URL in walk where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((AppSourceTree.relativePath(url), AppSourceTree.code(of: text)))
        }
        // A walk that found nothing would make every claim below vacuously true.
        XCTAssertGreaterThan(out.count, 50,
                             "the module walk found \(out.count) files — the scan below is "
                                 + "measuring almost nothing")
        return out.sorted { $0.0 < $1.0 }
    }

    private static func constructionSites(of needle: String) throws -> [String] {
        var hits = try AppSourceTree.filesContaining(needle)
        let kit = AppSourceTree.repoRoot.appendingPathComponent("Sources", isDirectory: true)
        if let walk = FileManager.default.enumerator(at: kit, includingPropertiesForKeys: nil) {
            for case let url as URL in walk where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let code = AppSourceTree.code(of: text)
                // The declaration itself is not a construction site.
                let uses = occurrences(of: needle, in: code)
                    - occurrences(of: "public static func \(needle)", in: code)
                if uses > 0 { hits.append(AppSourceTree.relativePath(url)) }
            }
        }
        return hits.sorted()
    }
}
