import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// Step definitions for `features/where-a-recording-is-and-what-a-reset-costs.feature`.
///
/// EVERY STEP DRIVES REAL OBJECTS. Custody is a real `PocketRecorderFileStore` over a real
/// directory, written through its real streaming commit. The confirmation marker is stamped by
/// the real `TranscriptCacheStore.save`, and the "local audio was cleared away" state is
/// produced by DELETING the segment files, which is what the retention sweep does. The
/// phone-only tier is driven by the real `LocalBackend.finalize` over real WAL segments, with
/// only the speech engine faked — nothing hermetic can own an STT model.
final class PocketPresenceFeatureTests: XCTestCase {
    func testWhereARecordingIsFeature() async throws {
        let world = PocketPresenceWorld()
        let result = try await BrineFeatureRunner.run(
            "where-a-recording-is-and-what-a-reset-costs",
            registry: StepRegistry(PocketPresenceSteps.make(world)))
        XCTAssertEqual(result.passed, 8)
    }
}

private enum PocketPresenceSteps {
    static func make(_ world: PocketPresenceWorld) -> [StepDefinition] {
        let givens = [
            "a recording brought off a recorder, confirmed in the person's library, whose local audio has since been cleared away",
            "a recorder whose shelf Solleva has just read, and a phone it has not been asked about",
            "a recorder holding three recordings, one of which Solleva already has",
            "a person who keeps their notes on this phone alone",
            "a person whose notes go to their computer",
            "a recorder this phone has never been asked about"
        ]
        let whens = [
            "the last look at that recorder is an hour old",
            "a recording is finished and transcribed on the phone"
        ]
        let thens = [
            "Solleva says that recording is safe elsewhere",
            "a recording confirmed nowhere is not said to be safe",
            "the row says the recording is on the recorder, and how long ago that was read",
            "the row says it does not know whether the recording is on this iPhone",
            "the row does not say the recording is safe elsewhere",
            "the age of a place nobody asked about is shown as never checked",
            "starting the recorder over is offered",
            "it says two recordings are on the recorder and not on this iPhone",
            "starting the recorder over is still offered",
            "the first thing it asks for is a fresh look at the recorder",
            "forgetting the recorder repeats what forgetting costs",
            "Solleva does not say that recording is safe elsewhere",
            "the sentence about where a copy goes is this phone's own, not the computer's",
            "forgetting the recorder says Solleva has not checked what it is holding",
            "it does not claim Solleva already has everything the recorder listed",
            "starting the recorder over says the same thing about what it has not checked"
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

/// A fake speech engine. The ONE seam a hermetic run cannot own.
private final class PhoneBrainSTT: LocalSTT, @unchecked Sendable {
    var isAvailable: Bool { true }
    func transcribe(opusFrames: [Data]) async throws -> String { "a note kept on this phone" }
}

private final class PocketPresenceWorld: @unchecked Sendable {

    // Real directories, torn down per scenario.
    private var roots: [URL] = []
    private var custodyRoot: URL!
    private var libraryRoot: URL!
    private var custody: PocketRecorderFileStore!
    private var durability: PocketCaptureDurability?
    private let identity = RecordingDeviceIdentity(shape: .filePull,
                                                   hardwareToken: "PRESENCE-RECORDER")

    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var shelfReadAt: Date?

    /// The recording under test, and its siblings on the shelf.
    private var subject: PocketRecorderFileKey!
    private var presence: PocketRecordingPresence?
    private var shelfPresences: [PocketRecordingPresence] = []
    private var forgetMessage: String?
    private var destination: String?
    /// Whether this scenario handed the resolver an authority over this phone. FALSE is the
    /// state the old two-valued custody label could not express at all.
    private var phoneWasAsked = true
    /// WHICH BRAIN IS ON. It is what decides whether a segment upload-ack is evidence of
    /// anywhere other than this phone, so a scenario that does not state it is a scenario
    /// about no particular person. Defaulted to the computer tier — the tier every other
    /// scenario in this file was written against — so only the two tier scenarios move it.
    private var brain: BrainChoice = .myComputer
    /// THE STAGES A REAL RUN WOULD HAND OVER. `[:]` here was the defect the phone-only
    /// scenario shipped with: a floor that is never handed a stage cannot be observed to
    /// accept the wrong one.
    private var stages: [String: CaptureStage] = [:]
    /// nil ⇒ nobody has read this recorder's shelf. DISTINCT from `[]`, which is a shelf
    /// that WAS read and is holding nothing.
    private var shelfReading: [PocketRecordingPresence]?

    // MARK: - Given

    func given(_ phrase: String) async throws {
        reset()
        switch phrase {
        case "a recording brought off a recorder, confirmed in the person's library, whose local audio has since been cleared away":
            subject = try await hold(date: "2026-03-28", timestamp: "20260328001919",
                                     captureID: "cap-confirmed")
            // The door path's own write: a cached transcript AND the `.lore-confirmed`
            // marker. This is the fact the retention sweep is written to preserve.
            TranscriptCacheStore.save(
                CachedTranscript(transcript: "hello", title: nil, summary: nil, fetchedAt: 1),
                captureId: "cap-confirmed", baseDir: libraryRoot, markConfirmed: true)
            // THE ~30-DAY SWEEP, PERFORMED: the segment files are gone, so nothing can
            // recompute `savedToComputer` for this capture ever again.
            try clearLocalAudio("cap-confirmed")
            // A second recording that nothing anywhere has confirmed — the paired existence
            // that stops the predicate passing by always answering yes.
            _ = try await hold(date: "2026-03-28", timestamp: "20260328102020",
                               captureID: "cap-unconfirmed")
            durability = PocketCaptureDurability(baseDir: libraryRoot, stages: stages, brain: brain)

        case "a recorder whose shelf Solleva has just read, and a phone it has not been asked about":
            subject = PocketRecorderFileKey(identity: identity, date: "2026-03-28",
                                            timestamp: "20260328001919")
            shelfReadAt = now.addingTimeInterval(-20 * 60)
            phoneWasAsked = false

        case "a recorder holding three recordings, one of which Solleva already has":
            shelfReadAt = now.addingTimeInterval(-60)
            let onRecorderNow = PocketPlaceReading(answer: .yes, observedAt: shelfReadAt)
            let asked = PocketPlaceReading(answer: .no, observedAt: now)
            shelfPresences = [
                PocketRecordingPresence(onRecorder: onRecorderNow,
                                        onThisPhone: PocketPlaceReading(answer: .yes, observedAt: now),
                                        safeElsewhere: PocketPlaceReading(answer: .yes, observedAt: now)),
                PocketRecordingPresence(onRecorder: onRecorderNow,
                                        onThisPhone: asked, safeElsewhere: asked),
                // The third was never asked about on this phone. It STILL costs, because
                // unknown is not a copy anybody holds.
                PocketRecordingPresence(onRecorder: onRecorderNow,
                                        onThisPhone: .neverAsked, safeElsewhere: .neverAsked)
            ]
            shelfReading = shelfPresences

        case "a person who keeps their notes on this phone alone":
            brain = .justMyPhone
            destination = PocketDestinationPresentation.line(for: .justMyPhone)

        // THE POSITIVE CONTROL for the tier rule, and the reason the phone-only scenario is
        // not vacuous. The two scenarios run the SAME finished recording through the SAME
        // WAL and differ in exactly one fact: which brain is on. If the predicate were made
        // to always answer no, this reds; if the tier is ignored, the other one reds.
        case "a person whose notes go to their computer":
            brain = .myComputer
            destination = PocketDestinationPresentation.line(for: .myComputer)

        case "a recorder this phone has never been asked about":
            shelfReadAt = nil
            shelfReading = nil

        default:
            throw BrineStepError("Unhandled given: \(phrase)")
        }
    }

    // MARK: - When

    func when(_ phrase: String) async throws {
        switch phrase {
        case "the last look at that recorder is an hour old":
            shelfReadAt = now.addingTimeInterval(-3_600)

        case "a recording is finished and transcribed on the phone":
            // THE REAL PHONE-ONLY BRAIN, over real WAL segments.
            let captureID = "cap-phone-only"
            let cdir = libraryRoot.appendingPathComponent(captureID, isDirectory: true)
            try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
            try CaptureWAL.encodeSegment([Data([1, 2, 3])])
                .write(to: cdir.appendingPathComponent(CaptureWAL.segName(0)))
            try await LocalBackend(baseDir: libraryRoot, stt: PhoneBrainSTT())
                .finalize(captureId: captureID, meta: nil)

            // THE FLOOR, HANDED OVER THE WAY THE RUNNING APP HANDS IT OVER — and this is the
            // whole point of the scenario. `App/DeviceScreen.swift` passes
            // `manager.captureStages()`, and on the phone-only tier every one of those
            // captures reaches `.savedToComputer`, because `CaptureBackend.swift:71` gives
            // that tier `uploadSegment: { _, _, _ in }` — a closure that succeeds by doing
            // nothing — and the WAL's ack then means, in the file's own words, "durably on
            // this phone". Passing `[:]` here (which is what this step used to do) tested a
            // predicate that was never shown the value that breaks it.
            stages = [captureID: .savedToComputer]
            durability = PocketCaptureDurability(baseDir: libraryRoot,
                                                  stages: stages, brain: brain)
            subject = try await hold(date: "2026-04-01", timestamp: "20260401080000",
                                     captureID: captureID)
            presence = await resolveOffMain()

        default:
            throw BrineStepError("Unhandled when: \(phrase)")
        }
    }

    // MARK: - Then

    func then(_ phrase: String) async throws {
        switch phrase {
        case "Solleva says that recording is safe elsewhere":
            let p = await resolveOffMain()
            XCTAssertTrue(p.isDurableElsewhere,
                          "a recording confirmed in the person's library reads NOT safe once "
                              + "its local audio is cleared away — the gate closes because the "
                              + "system worked")
            XCTAssertEqual(PocketPresencePresentation.label(p),
                           PocketPresencePresentation.safeElsewhereLabel)

        case "a recording confirmed nowhere is not said to be safe":
            let other = PocketRecorderFileKey(identity: identity, date: "2026-03-28",
                                              timestamp: "20260328102020")
            let p = await resolveOffMain(key: other)
            XCTAssertFalse(p.isDurableElsewhere,
                           "a recording nothing has confirmed is called safe — the predicate "
                               + "passes by always answering yes")
            XCTAssertEqual(p.safeElsewhere.answer, .no)

        case "the row says the recording is on the recorder, and how long ago that was read":
            let lines = PocketPresencePresentation.lines(await resolveOffMain(), now: now)
            let onRecorder = try line(lines, PocketPresencePresentation.onRecorderPlace)
            XCTAssertEqual(onRecorder.answer, PocketPresencePresentation.yesAnswer)
            XCTAssertEqual(onRecorder.age, "20 minutes ago")

        case "the row says it does not know whether the recording is on this iPhone":
            let p = await resolveOffMain()
            XCTAssertEqual(p.onThisPhone.answer, .unknown,
                           "a phone nobody asked about answered \(p.onThisPhone.answer) — an "
                               + "unasked place is being drawn as a definite one")
            let lines = PocketPresencePresentation.lines(p, now: now)
            XCTAssertEqual(try line(lines, PocketPresencePresentation.onThisPhonePlace).answer,
                           PocketPresencePresentation.unknownAnswer)
            XCTAssertEqual(PocketPresencePresentation.label(p),
                           PocketPresencePresentation.phoneNotCheckedLabel)

        case "the row does not say the recording is safe elsewhere":
            let p = await resolveOffMain()
            XCTAssertFalse(p.isDurableElsewhere)
            XCTAssertEqual(p.safeElsewhere.answer, .unknown)

        case "the age of a place nobody asked about is shown as never checked":
            let lines = PocketPresencePresentation.lines(await resolveOffMain(), now: now)
            XCTAssertEqual(try line(lines, PocketPresencePresentation.safeElsewherePlace).age,
                           PocketPresencePresentation.neverCheckedAge)

        case "starting the recorder over is offered", "starting the recorder over is still offered":
            let g = resolveGate()
            XCTAssertTrue(g.isEnabled,
                          "the owner's own recorder reset disabled itself — a stale shelf must "
                              + "move the primary action, never the enabled state")

        case "it says two recordings are on the recorder and not on this iPhone":
            let expected = "2 recordings are on the recorder and not on this iPhone."
            XCTAssertEqual(PocketRecorderCostPresentation.onlyOnTheRecorder(shelfPresences), 2)
            let stated = forgetMessage ?? resolveGate().cost
            XCTAssertTrue(stated.contains(expected),
                          "the cost reads \"\(stated)\" — it must state "
                              + "count(on the recorder and not on this phone)")

        case "the first thing it asks for is a fresh look at the recorder":
            XCTAssertEqual(resolveGate().primaryAction,
                           PocketRecorderCostPresentation.checkFirstAction)

        case "forgetting the recorder repeats what forgetting costs":
            let warning = RecordingDevicePage.forgetWarning(for: .recordThenSync)
            let message = PocketRecorderCostPresentation.forgetMessage(warning: warning,
                                                                       presences: shelfReading)
            XCTAssertTrue(message.contains(warning),
                          "the forget confirmation dropped the shipped key warning")
            forgetMessage = message

        case "Solleva does not say that recording is safe elsewhere":
            let p = try XCTUnwrap(presence)
            XCTAssertEqual(stages["cap-phone-only"], .savedToComputer,
                           "this scenario did not even reach the state it exists to forbid — "
                               + "the capture never became savedToComputer, so a predicate "
                               + "that accepts that stage would still pass here")
            XCTAssertFalse(p.isDurableElsewhere,
                           "a recording whose ONLY copy is on this phone is called safe "
                               + "elsewhere. On the phone-only tier the segment ack is "
                               + "self-issued, so savedToComputer means \"durably on this "
                               + "phone\" — one tap from a delete that takes the last copy")

        case "the sentence about where a copy goes is this phone's own, not the computer's":
            XCTAssertEqual(destination, PocketDestinationPresentation.phoneOnlyLine)
            XCTAssertNotEqual(PocketDestinationPresentation.line(for: .justMyPhone),
                              PocketDestinationPresentation.line(for: .myComputer))
            // POPULATION, not one remembered string: every tier's sentence is distinct, so
            // reusing another tier's line collapses this count and reds here.
            XCTAssertEqual(Set(PocketDestinationPresentation.everyLine).count,
                           BrainChoice.allCases.count,
                           "two brains share one sentence about where the copy goes: "
                               + "\(PocketDestinationPresentation.everyLine)")

        case "forgetting the recorder says Solleva has not checked what it is holding":
            // THE UNREAD SHELF, EXACTLY AS THE PAGE HAS IT. `shelfReading` is nil here because
            // nothing has checked, which is the state a freshly opened recorder page is in.
            let warning = RecordingDevicePage.forgetWarning(for: .recordThenSync)
            let message = PocketRecorderCostPresentation.forgetMessage(warning: warning,
                                                                       presences: shelfReading)
            XCTAssertTrue(message.contains(warning),
                          "the forget confirmation dropped the shipped key warning")
            XCTAssertTrue(message.contains(PocketRecorderCostPresentation.shelfNotCheckedLine),
                          "the confirmation reads \"\(message)\" — a destructive gesture on a "
                              + "recorder nobody checked must say it has not checked")
            forgetMessage = message

        case "it does not claim Solleva already has everything the recorder listed":
            let message = try XCTUnwrap(forgetMessage)
            // THE POSITIVE CONTROL. The reassurance IS a real sentence this type says — for a
            // shelf that was READ and cost nothing. If it stopped existing, this assertion
            // would be about a string nothing produces and could never fail.
            let reassurance = PocketRecorderCostPresentation.costLine([])
            XCTAssertEqual(reassurance,
                           "Solleva already has every recording this recorder listed.",
                           "the reassurance this scenario forbids on an unread shelf is no "
                               + "longer produced for a read one either — the assertion below "
                               + "is now about a sentence nothing says")
            XCTAssertFalse(message.contains(reassurance),
                           "forgetting a recorder nobody checked told the owner Solleva "
                               + "already holds everything it listed, immediately before "
                               + "destroying the key that reaches it")

        case "starting the recorder over says the same thing about what it has not checked":
            let gate = PocketRecorderCostPresentation.resetGate(shelfObservedAt: shelfReadAt,
                                                                now: now,
                                                                presences: shelfReading)
            XCTAssertEqual(gate.cost, PocketRecorderCostPresentation.shelfNotCheckedLine)
            XCTAssertTrue(gate.isEnabled,
                          "the owner's own reset disabled itself on an unchecked recorder")
            XCTAssertEqual(gate.primaryAction,
                           PocketRecorderCostPresentation.checkFirstAction)

        default:
            throw BrineStepError("Unhandled assertion: \(phrase)")
        }
    }

    // MARK: - Helpers over REAL objects

    private func reset() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        custodyRoot = makeRoot("custody")
        libraryRoot = makeRoot("library")
        custody = PocketRecorderFileStore(root: custodyRoot)
        durability = nil
        subject = nil
        presence = nil
        shelfPresences = []

        forgetMessage = nil
        destination = nil
        shelfReadAt = nil
        phoneWasAsked = true
        brain = .myComputer
        stages = [:]
        shelfReading = nil
    }

    private func makeRoot(_ name: String) -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pocket-presence-\(name)-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    /// Put a file into REAL custody through its real streaming commit, and record the
    /// conversation it became.
    private func hold(date: String, timestamp: String,
                      captureID: String) async throws -> PocketRecorderFileKey {
        let key = PocketRecorderFileKey(identity: identity, date: date, timestamp: timestamp)
        let writer = try await custody.beginKeeping(key)
        try writer.write(Data(repeating: 0x2A, count: 512))
        _ = try writer.commit()
        await custody.noteConversation(captureID, for: key)
        return key
    }

    /// What the ~30-day retention sweep does: the segment files go, the confirmation marker
    /// and the readable tombstone stay.
    private func clearLocalAudio(_ captureID: String) throws {
        let dir = libraryRoot.appendingPathComponent(captureID, isDirectory: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix("seg-") {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Resolution runs OFF the main thread, which is where it runs in the app.
    private func resolveOffMain(key: PocketRecorderFileKey? = nil) async -> PocketRecordingPresence {
        let target = key ?? subject!
        let custody: (any PocketRecorderFileCustody)? = phoneWasAsked ? self.custody : nil
        let durability = self.durability
        let listedAt = shelfReadAt
        let askedAt = now
        return await Task.detached {
            await PocketPresenceReader.presence(for: target,
                                                listedAt: listedAt,
                                                custody: custody,
                                                durability: durability,
                                                askedAt: askedAt)
        }.value
    }

    private func resolveGate() -> PocketRecorderCostPresentation.ResetGate {
        PocketRecorderCostPresentation.resetGate(shelfObservedAt: shelfReadAt,
                                                 now: now,
                                                 presences: shelfReading)
    }

    private func line(_ lines: [PocketPlaceLine], _ place: String) throws -> PocketPlaceLine {
        guard let found = lines.first(where: { $0.place == place }) else {
            throw BrineStepError("no line for place \(place) in \(lines.map(\.place))")
        }
        return found
    }
}
