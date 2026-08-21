import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// features/a-recording-says-where-it-is.feature, driven against the REAL presentation —
/// `RecordingJourneyPresentation` and `RecordingNamePresentation` — plus the gates that hold
/// the two properties a scenario cannot: that no bar is drawable without a measured
/// denominator anywhere in the population, and that no SwiftUI body spells a stage.
///
/// WHY THE ABSENCES ARE ASSERTED AND NOT JUST THE PRESENCES. Every defect this surface has
/// shipped was a number that rendered fine and meant nothing: 44-minute rows from an unmeasured
/// divisor, kilobytes read back as bytes, "4 KB" on a 19,770-byte file. A test that only checks
/// "the transcribing row says two of twenty" passes just as happily on a build that also draws a
/// bar for diarization that can never finish. So the population assertions below hold the
/// PROPERTY — "no row whose denominator nobody measured is drawable" — over every reading the
/// types can express, rather than over the readings this author thought of.
final class RecordingJourneyFeatureTests: XCTestCase {

    func testRecordingJourneyScenarios() async throws {
        let world = JourneyWorld()
        let result = try await BrineFeatureRunner.run("a-recording-says-where-it-is",
                                                      registry: StepRegistry(JourneySteps.make(world: world)))
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let parsed = parseFeatureText(try String(
            contentsOf: url.appendingPathComponent("features/a-recording-says-where-it-is.feature"),
            encoding: .utf8))
        XCTAssertEqual(result.passed, parsed.features[0].scenarios.count,
                       "every scenario must RUN — an undefined step is not a pass")
    }

    // MARK: - The measure: a bar exists only where a denominator was measured

    /// THE CHOKE POINT, held over the whole population of totals rather than over one.
    ///
    /// `progress(done:total:)` is the only way to build `.counted`, so this is the only place a
    /// bar can be born. Every refusal below is a defect this program has already paid for.
    func testNoDenominatorMeansNoBar() {
        // No total at all — the door's manifest carries none. AC8b.
        XCTAssertEqual(RecordingJourneyMeasure.progress(done: 79, total: nil), .tally(79))
        XCTAssertNil(RecordingJourneyMeasure.progress(done: 79, total: nil).fraction)
        XCTAssertFalse(RecordingJourneyMeasure.progress(done: 79, total: nil).drawsABar)

        // A zero total is not "we have not started" — it is a division nobody should make.
        XCTAssertEqual(RecordingJourneyMeasure.progress(done: 0, total: 0), .tally(0))
        XCTAssertFalse(RecordingJourneyMeasure.progress(done: 0, total: 0).drawsABar)

        // Numerator past denominator: the two came from different places. No bar.
        XCTAssertEqual(RecordingJourneyMeasure.progress(done: 101, total: 100), .tally(101))
        XCTAssertFalse(RecordingJourneyMeasure.progress(done: 101, total: 100).drawsABar)

        // The one case that IS drawable, and it reads what was measured — not 100 %.
        let real = RecordingJourneyMeasure.progress(done: 79, total: 100)
        XCTAssertEqual(real, .counted(79, of: 100))
        XCTAssertEqual(real.fraction ?? -1, 0.79, accuracy: 0.0001)
        XCTAssertTrue(real.drawsABar)
    }

    /// THE FALSE-COMPLETION CASE, AS ITS OWN ASSERTION.
    ///
    /// The forbidden denominator is the received set itself: `segments_received` as both
    /// numerator and denominator, or `max(seq)+1`. A fixture with an authoritative expected
    /// count of 100 and a NON-CONTIGUOUS acknowledged subset — {0…48, 50…79}, 79 segments whose
    /// highest sequence is 79 — separates all three answers. The received-set denominator reads
    /// 100 %; `max(seq)+1` reads 79/80; the truth is 79/100.
    func testTheReceivedSetIsNeverTheDenominator() {
        let acked = Array(0...48) + Array(50...79)
        XCTAssertEqual(acked.count, 79)
        XCTAssertEqual((acked.max() ?? -1) + 1, 80)

        let honest = RecordingJourneyMeasure.progress(done: acked.count, total: 100)
        XCTAssertEqual(honest, .counted(79, of: 100))
        XCTAssertEqual(honest.fraction ?? -1, 0.79, accuracy: 0.0001)

        // The two wrong denominators, spelled out so the numbers they would print are on the
        // record rather than in an argument.
        XCTAssertEqual(RecordingJourneyMeasure.progress(done: acked.count, total: acked.count).fraction ?? -1,
                       1.0, accuracy: 0.0001, "the received set as its own denominator reads DONE")
        XCTAssertNotEqual(RecordingJourneyMeasure.progress(done: acked.count, total: 80), honest)
    }

    // MARK: - The ladder, over its whole population

    /// AC3, AND THE ASSERTION THAT ACTUALLY CATCHES THE MUTATION.
    ///
    /// The track's stated catcher for "map `unavailable` → `pending`" is "a non-nil progress
    /// value". THAT CATCHER CANNOT FAIL: diarization has no countable denominator in EITHER
    /// state, so a `pending` row is `.none` too and the nil assertion stays green through the
    /// mutation. A gate that cannot fail is worse than no gate, so the assertion here is on the
    /// STATE and the SENTENCE — `.cannotHappen` and "Speakers weren't separated" — and the nil
    /// progress is asserted as well, as the property it is.
    func testUnavailableSpeakersAreNotPending() throws {
        let cloudOnlyVault = RecordingJourneyReading(transcript: .done, speakers: .unavailable)
        let row = try XCTUnwrap(RecordingJourneyPresentation.row(for: .separatingSpeakers,
                                                                reading: cloudOnlyVault))
        XCTAssertEqual(row.state, .cannotHappen,
                       "a Vault that can never separate speakers is not PENDING on it")
        XCTAssertEqual(row.line, RecordingJourneyPresentation.speakersNotSeparatedLine)
        XCTAssertEqual(row.measure, .none)
        XCTAssertFalse(row.drawsABar, "a bar for a thing that will never happen never finishes")

        // Paired existence: a Vault that IS separating them renders differently, so the
        // assertion above cannot pass on a build that says "weren't separated" for everything.
        let pending = try XCTUnwrap(RecordingJourneyPresentation.row(
            for: .separatingSpeakers,
            reading: RecordingJourneyReading(transcript: .done, speakers: .pending)))
        XCTAssertEqual(pending.state, .working)
        XCTAssertNotEqual(pending.line, row.line)
        XCTAssertFalse(pending.drawsABar, "not even a real pending diarization has a denominator")
    }

    /// AC5 — ASSERTED ON THE TOKEN, WHICH IS THE ONLY THING THAT CATCHES A SWAP.
    ///
    /// Distinctness proves two sentences differ. It does NOT stop them being exchanged, and an
    /// exchange tells a person a recording was read and found nothing when it was never read at
    /// all — a claim that the system did work it did not do. So the token is pinned first and
    /// the sentence second.
    func testActionsStatesAreNamedNotMerelyDistinct() throws {
        XCTAssertEqual(RecordingIntelligence.neverRun.token, "neverRun")
        XCTAssertEqual(RecordingIntelligence.ranFoundNothing.token, "ranFoundNothing")
        XCTAssertEqual(RecordingIntelligence.ranFound(3).token, "ranFoundN")
        XCTAssertEqual(RecordingIntelligence.notEstablished.token, "notEstablished")

        // Every state's token is its own — held over the population, not over the two an author
        // remembered.
        let tokens = RecordingIntelligence.everyState.map(\.token)
        XCTAssertEqual(Set(tokens).count, tokens.count, "two intelligence states share a token")

        let neverRun = try XCTUnwrap(RecordingJourneyPresentation.row(
            for: .readingForActions,
            reading: RecordingJourneyReading(intelligence: .neverRun)))
        let foundNothing = try XCTUnwrap(RecordingJourneyPresentation.row(
            for: .readingForActions,
            reading: RecordingJourneyReading(intelligence: .ranFoundNothing)))
        XCTAssertEqual(neverRun.line, RecordingJourneyPresentation.neverReadForActionsLine)
        XCTAssertEqual(foundNothing.line, RecordingJourneyPresentation.readAndFoundNothingLine)
        XCTAssertNotEqual(neverRun.line, foundNothing.line)
        XCTAssertEqual(neverRun.state, .waiting)
        XCTAssertEqual(foundNothing.state, .done,
                       "a recording that WAS read is finished with that stage; one that was "
                       + "never read is still waiting for it")

        // And the fourth state renders NOTHING — Nick asked whether intelligence came out of a
        // recording, and "nobody wired this up" is not an answer, it is silence.
        XCTAssertNil(RecordingJourneyPresentation.row(
            for: .readingForActions,
            reading: RecordingJourneyReading(intelligence: .notEstablished)))
    }

    /// THE ABSENCE OF A TITLE IS NOT EVIDENCE OF WORK. The door's shipped `summarizing` is
    /// `transcribed && title.is_none()` and it read `true` for four days on a capture that could
    /// never be titled. `fromStatus` must not reproduce it.
    func testATranscribedUntitledCaptureDoesNotClaimNamingIsRunning() {
        let transcribedNoTitle = CaptureStatusResponse(
            stage: "in_lore", loreCaptureId: "c001a016", transcribed: true, title: nil)
        let reading = RecordingJourneyReading.fromStatus(transcribedNoTitle)
        XCTAssertEqual(reading.naming, .notEstablished)
        XCTAssertNil(RecordingJourneyPresentation.row(for: .naming, reading: reading),
                     "no title yet is not \"working out what to call it\"")

        // Paired existence: a naming run that IS claimed does report work in flight, so the
        // assertion above cannot pass on a build that hardcodes "never in flight".
        var claimed = reading
        claimed.naming = .inFlight
        let row = RecordingJourneyPresentation.row(for: .naming, reading: claimed)
        XCTAssertEqual(row?.line, RecordingJourneyPresentation.namingInFlightLine)

        // And a titled capture is done.
        let titled = CaptureStatusResponse(stage: "in_lore", loreCaptureId: "c001a016",
                                           transcribed: true, title: "Kitchen table, Thursday")
        XCTAssertEqual(RecordingJourneyReading.fromStatus(titled).naming, .done)
    }

    /// AC2's shape: an ABSENT window reading is not `{0, 0}`.
    func testAbsentWindowProgressIsNotZeroOfZero() throws {
        let noWindows = RecordingJourneyReading(transcript: .inProgress(nil))
        let row = try XCTUnwrap(RecordingJourneyPresentation.row(for: .transcribing, reading: noWindows))
        XCTAssertEqual(row.line, RecordingJourneyPresentation.transcribingLine)
        XCTAssertEqual(row.measure, .none, "no windows means NO progress object, not 0 of 0")
        XCTAssertFalse(row.drawsABar)

        let twoOfTwenty = RecordingJourneyReading(
            transcript: .inProgress(TranscribeWindowsReading(windowsDone: 2, windowCount: 20)))
        let counted = try XCTUnwrap(RecordingJourneyPresentation.row(for: .transcribing,
                                                                    reading: twoOfTwenty))
        XCTAssertEqual(counted.measure, .counted(2, of: 20))
        XCTAssertTrue(counted.line.contains("2 of 20"))
        XCTAssertTrue(counted.drawsABar)

        // The sentence counts PARTS. Nick asked how long until it is transcribed, and windows
        // are audio, not minutes — turning them into a clock needs a rate nobody measures, which
        // is the unmeasured divisor that put 44-minute rows on this surface.
        for unit in ["minute", "second", "hour", "%"] {
            XCTAssertFalse(counted.line.localizedCaseInsensitiveContains(unit),
                           "the transcribing line promises \(unit): \"\(counted.line)\"")
        }
    }

    /// AC10 — EVERY STAGE IS REACHABLE AND EVERY DOOR STAGE IS ANSWERED, both enumerated from
    /// the TYPES rather than from a list somebody maintains by hand.
    func testEveryStageIsReachableAndEveryDoorStageIsAnswered() throws {
        // 1. Every ladder stage can be rendered by SOME reading, and its line is not blank.
        let readings: [RecordingJourneyReading] = [
            RecordingJourneyReading(offTheRecorder: RecorderTransferReading(bytesDelivered: 1,
                                                                           bytesAnnounced: 2)),
            RecordingJourneyReading(toTheVault: VaultUploadReading(segmentsConfirmed: 1,
                                                                  segmentsExpected: 2)),
            RecordingJourneyReading(transcript: .inProgress(nil)),
            RecordingJourneyReading(transcript: .notStarted),
            RecordingJourneyReading(transcript: .done),
            RecordingJourneyReading(transcript: .failed("noise")),
            RecordingJourneyReading(speakers: .unavailable),
            RecordingJourneyReading(speakers: .pending),
            RecordingJourneyReading(speakers: .done),
            RecordingJourneyReading(naming: .waitingForTranscript),
            RecordingJourneyReading(naming: .inFlight),
            RecordingJourneyReading(naming: .done),
            RecordingJourneyReading(intelligence: .neverRun),
            RecordingJourneyReading(intelligence: .ranFoundNothing),
            RecordingJourneyReading(intelligence: .ranFound(2)),
        ]
        for stage in RecordingJourneyStage.allCases {
            let rendered = readings.compactMap { RecordingJourneyPresentation.row(for: stage, reading: $0) }
            XCTAssertFalse(rendered.isEmpty, "no reading renders the \(stage.rawValue) stage")
            for row in rendered {
                XCTAssertEqual(row.stage, stage, "a row answered for the wrong stage")
                XCTAssertFalse(row.line.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(stage.rawValue) renders a blank line")
            }
        }

        // 2. Every stage the DOOR can report maps to a ladder that says something about the
        // transcript. A stage added to `CaptureLifecycleStage` with no answer here is a failure,
        // not a blank screen.
        for wire in CaptureLifecycleStage.allCases {
            let status = CaptureStatusResponse(stage: wire.rawValue, loreCaptureId: nil,
                                               transcribed: wire == .transcribed || wire == .organized)
            let reading = RecordingJourneyReading.fromStatus(status)
            XCTAssertNotNil(RecordingJourneyPresentation.row(for: .transcribing, reading: reading),
                            "door stage \(wire.rawValue) renders nothing about the transcript")
        }

        // 3. The ladder is in stage order, always — a person reading it top to bottom is
        // reading a journey, not a set.
        let everything = RecordingJourneyReading(
            offTheRecorder: RecorderTransferReading(bytesDelivered: 1, bytesAnnounced: 2),
            toTheVault: VaultUploadReading(segmentsConfirmed: 1, segmentsExpected: 2),
            transcript: .inProgress(nil), speakers: .pending, naming: .inFlight,
            intelligence: .ranFound(2))
        let ladder = RecordingJourneyPresentation.ladder(everything)
        XCTAssertEqual(ladder.map(\.stage), RecordingJourneyStage.allCases)
    }

    /// THE POPULATION PROPERTY. Over EVERY reading the types can express from a small grid of
    /// values, no row is drawable unless its own denominator was supplied. This is the
    /// assertion that survives somebody adding a stage.
    func testNoRowIsEverDrawableWithoutASuppliedDenominator() {
        let transfers: [RecorderTransferReading?] = [
            nil,
            RecorderTransferReading(bytesDelivered: 40_000, bytesAnnounced: nil),
            RecorderTransferReading(bytesDelivered: 40_000, bytesAnnounced: 100_000),
            RecorderTransferReading(bytesDelivered: 40_000, bytesAnnounced: 0),
        ]
        let uploads: [VaultUploadReading?] = [
            nil,
            VaultUploadReading(segmentsConfirmed: 79, segmentsExpected: nil),
            VaultUploadReading(segmentsConfirmed: 79, segmentsExpected: 100),
        ]
        let transcripts: [TranscriptReadiness] = [
            .notStarted, .inProgress(nil),
            .inProgress(TranscribeWindowsReading(windowsDone: 2, windowCount: 20)),
            .inProgress(TranscribeWindowsReading(windowsDone: 0, windowCount: 0)),
            .done, .failed(nil), .failed("noise"),
        ]
        var drawable = 0
        for transfer in transfers {
            for upload in uploads {
                for transcript in transcripts {
                    for speakers in SpeakerSeparation.allCases {
                        for naming in NamingState.allCases {
                            for intelligence in RecordingIntelligence.everyState {
                                let reading = RecordingJourneyReading(
                                    offTheRecorder: transfer, toTheVault: upload,
                                    transcript: transcript, speakers: speakers,
                                    naming: naming, intelligence: intelligence)
                                for row in RecordingJourneyPresentation.ladder(reading) {
                                    guard row.drawsABar else { continue }
                                    drawable += 1
                                    switch row.stage {
                                    case .comingOffTheRecorder:
                                        XCTAssertNotNil(transfer?.bytesAnnounced,
                                                        "a bar off the recorder with nothing announced")
                                        XCTAssertGreaterThan(transfer?.bytesAnnounced ?? 0, 0)
                                    case .reachingTheVault:
                                        XCTAssertNotNil(upload?.segmentsExpected,
                                                        "a bar to the Vault with no expected total")
                                    case .transcribing:
                                        guard case .inProgress(let w) = transcript, let w else {
                                            return XCTFail("a transcribing bar with no windows")
                                        }
                                        XCTAssertGreaterThan(w.windowCount, 0)
                                    case .separatingSpeakers, .naming, .readingForActions:
                                        XCTFail("\(row.stage.rawValue) has no denominator and "
                                                + "must never draw a bar")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(drawable, 0,
                             "no row in the whole population is drawable — this gate would pass "
                             + "on a build that draws nothing at all")
    }

    // MARK: - The name that arrives twice

    /// AC2 of the naming track: `"provisional"` and `"full"` decode to DISTINCT states, and the
    /// paired half — a full title decodes to `.full` — stops it passing by hardcoding either.
    func testProvenanceDecodesToDistinctStates() throws {
        let provisional = try XCTUnwrap(RecordingName(text: "Kitchen table",
                                                      provenanceWire: "provisional"))
        let full = try XCTUnwrap(RecordingName(text: "Kitchen table", provenanceWire: "full"))
        XCTAssertTrue(provisional.isProvisional)
        XCTAssertFalse(full.isProvisional)
        XCTAssertNotEqual(provisional, full)
        XCTAssertEqual(RecordingNamePresentation.note(for: provisional),
                       RecordingNamePresentation.provisionalNote)
        XCTAssertNil(RecordingNamePresentation.note(for: full),
                     "a permanent badge on a permanent name is noise")

        // An absent or unrecognised field is NO CLAIM, and no claim is `.full` — the safe
        // direction: it never badges a real name as provisional. Dropping the field therefore
        // collapses the provisional fixture, which is the falsification.
        XCTAssertEqual(RecordingNameProvenance(wire: nil), .full)
        XCTAssertEqual(RecordingNameProvenance(wire: "sometime-later"), .full)

        // A name from nothing is not a name — the empty first window cannot produce one.
        XCTAssertNil(RecordingName(text: "", provenance: .provisional))
        XCTAssertNil(RecordingName(text: "   \n ", provenance: .provisional))
        XCTAssertNil(RecordingName(text: nil, provenance: .full))
    }

    /// AC6 — THE TRANSITION, ASSERTED OVER THE WHOLE RUN RATHER THAN OVER ITS ENDPOINTS.
    ///
    /// A flicker does not live at the endpoints; it lives in the middle, and asserting
    /// `before == provisional` and `after == full` is green through a build that blanks the name
    /// in between. So the fold is asserted: once a name is displayed, no arrival ever takes the
    /// screen back to nothing, and the displayed text changes exactly once.
    func testTheNameNeverFlickers() throws {
        let provisional = try XCTUnwrap(RecordingName(text: "Kitchen table",
                                                      provenance: .provisional))
        let full = try XCTUnwrap(RecordingName(text: "Deciding the roof, at the kitchen table",
                                               provenance: .full))
        // The ordinary arrival sequence, including the polls that carry nothing at all.
        let seen = RecordingNamePresentation.displayed(after: [provisional, nil, nil, full, nil])
        XCTAssertEqual(seen.count, 5)
        XCTAssertFalse(seen.contains(where: { $0 == nil }),
                       "a poll carrying no title blanked a name already on screen — the "
                       + "title→empty→title jump-cut")
        let texts = seen.compactMap { $0?.text }
        XCTAssertEqual(texts, ["Kitchen table", "Kitchen table", "Kitchen table",
                               full.text, full.text])
        var changes = 0
        for (a, b) in zip(texts, texts.dropFirst()) where a != b { changes += 1 }
        XCTAssertEqual(changes, 1, "the displayed name changed \(changes) times, not once")
        XCTAssertEqual(seen.last??.provenance, .full)
        XCTAssertNil(RecordingNamePresentation.note(for: seen.last ?? nil))
    }

    /// AC5(ii) of the naming track, on the display side: a late provisional never walks a full
    /// name backwards, whatever the ordering.
    func testAProvisionalNameNeverReplacesAFullOne() throws {
        let provisional = try XCTUnwrap(RecordingName(text: "Kitchen table",
                                                      provenance: .provisional))
        let full = try XCTUnwrap(RecordingName(text: "Deciding the roof", provenance: .full))
        XCTAssertEqual(RecordingNamePresentation.settle(current: full, incoming: provisional), full)
        XCTAssertEqual(RecordingNamePresentation.settle(current: provisional, incoming: full), full)
        XCTAssertEqual(RecordingNamePresentation.settle(current: full, incoming: nil), full)
        XCTAssertEqual(RecordingNamePresentation.settle(current: nil, incoming: provisional),
                       provisional)
        // A newer provisional does replace an older one — the window can be re-run.
        let better = try XCTUnwrap(RecordingName(text: "Kitchen table, Thursday",
                                                 provenance: .provisional))
        XCTAssertEqual(RecordingNamePresentation.settle(current: provisional, incoming: better),
                       better)
        // And the property over every ordering of the two arrivals: the run ends on the FULL
        // name either way.
        for order in [[provisional, full], [full, provisional]] {
            XCTAssertEqual(RecordingNamePresentation.displayed(after: order).last??.provenance,
                           .full, "ordering \(order.map(\.text)) did not settle on the full name")
        }
    }

    /// THE SEAM THE APP ACTUALLY BINDS, over the three places a name can come from.
    ///
    /// The precedence lives here and not at the call site because the obvious spelling of it —
    /// `content?.title ?? cached?.title` — is WRONG in a way nobody would see: a door reply that
    /// arrives carrying no title yields `nil` from the left-hand side, and the `??` never
    /// reaches the locally cached name the phone already holds. The name would vanish on a poll.
    func testTheNameResolvesFromTheRightPlaceAndCarriesItsProvenance() throws {
        let provisionalCard = ConversationCardMeta(title: "Kitchen table", isProvisional: true)
        let settledCard = ConversationCardMeta(title: "Deciding the roof", isProvisional: false)

        // Door title wins, and is full.
        let fromDoor = try XCTUnwrap(RecordingNamePresentation.resolve(
            doorTitle: "Deciding the roof", cachedTitle: nil, card: provisionalCard))
        XCTAssertEqual(fromDoor.text, "Deciding the roof")
        XCTAssertEqual(fromDoor.provenance, .full)

        // A door reply with NO title falls through to the cache — not to nothing.
        let fromCache = try XCTUnwrap(RecordingNamePresentation.resolve(
            doorTitle: nil, cachedTitle: "Deciding the roof", card: provisionalCard))
        XCTAssertEqual(fromCache.provenance, .full)

        // Only the durable card is left, and it says the name is provisional.
        let fromCard = try XCTUnwrap(RecordingNamePresentation.resolve(
            doorTitle: nil, cachedTitle: nil, card: provisionalCard))
        XCTAssertEqual(fromCard.text, "Kitchen table")
        XCTAssertEqual(fromCard.provenance, .provisional)
        XCTAssertEqual(RecordingNamePresentation.note(for: fromCard),
                       RecordingNamePresentation.provisionalNote)

        // A card whose provisional flag has been CLEARED by authoritative content is full, and
        // is not badged. Without this the assertion above passes on a build that badges every
        // card-sourced name.
        let settled = try XCTUnwrap(RecordingNamePresentation.resolve(
            doorTitle: nil, cachedTitle: nil, card: settledCard))
        XCTAssertEqual(settled.provenance, .full)
        XCTAssertNil(RecordingNamePresentation.note(for: settled))

        // Nothing anywhere is nothing — never the placeholder dressed as a name.
        XCTAssertNil(RecordingNamePresentation.resolve(doorTitle: nil, cachedTitle: nil, card: nil))
        XCTAssertNil(RecordingNamePresentation.resolve(
            doorTitle: "  ", cachedTitle: "", card: ConversationCardMeta(title: "  ",
                                                                        isProvisional: true)))
    }

    /// THE POLLER PUBLISHES THE READING, so the band is bound to a live seam rather than to a
    /// value some view assembled. Without this the ladder is a function nobody calls.
    @MainActor func testThePollerPublishesTheJourneyItDerived() async {
        let poller = CaptureStatusPoller(captureId: "pkt-20260814-184537-BFE0FDA2",
                                         client: StubStatus(stage: "in_lore", transcribed: true),
                                         baseInterval: 0.01, maxInterval: 0.01)
        XCTAssertEqual(poller.journey, RecordingJourneyReading(),
                       "the journey must start empty — nothing has been polled")
        await poller.pollOnce()
        XCTAssertEqual(poller.journey.transcript, .done)
        XCTAssertEqual(poller.journey.naming, .notEstablished,
                       "a transcribed capture with no title must not claim naming is running")
        XCTAssertEqual(poller.journey.speakers, .notEstablished)
        XCTAssertEqual(poller.journey.intelligence, .notEstablished)
        let ladder = RecordingJourneyPresentation.ladder(poller.journey)
        XCTAssertEqual(ladder.map(\.stage), [.transcribing],
                       "the door's reply supports exactly one stage today, and the ladder must "
                       + "say only that: \(ladder.map { "\($0.stage.rawValue)=\($0.line)" })")
        XCTAssertFalse(ladder.contains(where: \.drawsABar))
    }

    // MARK: - AC9: no stage decision, and no stage sentence, inside a SwiftUI body

    /// `swift test` cannot compile `App/`, so a rule written in a view is a rule nothing in this
    /// repository can execute — which is exactly how the refuted privacy guards got there. This
    /// reads the app-side source (comments stripped, string literals INTACT, because a string
    /// literal is precisely the thing being held) and fails if any of the journey's sentences is
    /// spelled there.
    /// STATED LIMIT, because a gate whose reach is guessed at is the thing it is guarding
    /// against. The match is on the sentence **as a complete string literal** — `"…"`, quotes
    /// included — and NOT on a substring. Substring matching was tried first and reported
    /// `App/ConversationFacesView.swift:1181` for the one-word line "Transcribed", which the
    /// file contains only inside `"Transcribed in the cloud (Deepgram)"`: a different claim, in
    /// a receipt row, not a stage rendering. A gate that reds on a coincidence gets deleted.
    /// What this therefore does NOT catch: a sentence assembled by `+` or interpolation. Those
    /// would need a parser; this is a lexer, and saying so is better than pretending otherwise.
    func testNoAppSideFileSpellsAJourneySentence() throws {
        let population = RecordingJourneyPresentation.everyLine
            + [RecordingNamePresentation.provisionalNote]
        XCTAssertGreaterThan(population.count, 10, "the population under this gate is too small")
        var offences: [String] = []
        for file in try AppSourceTree.appSideSwiftFiles() {
            let text = AppSourceTree.withoutComments(of: try String(contentsOf: file, encoding: .utf8))
            for line in population where text.contains("\"\(line)\"") {
                offences.append("\(AppSourceTree.relativePath(file)) spells \"\(line)\"")
            }
        }
        XCTAssertTrue(offences.isEmpty,
                      "a journey sentence is written where `swift test` cannot reach it:\n"
                      + offences.joined(separator: "\n"))
    }
}

// MARK: - Step helpers

/// A step's assertion. `BrineStepError`'s message surfaces verbatim in the scenario diff, so
/// every call below says what it measured rather than "expected true".
private func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw BrineStepError(message()) }
}

/// A row the scenario is ABOUT must exist. A missing row is a failure with a name, never a
/// silently skipped assertion — the shape of a gate that cannot fail.
private func require<T>(_ value: T?, _ what: String = "a value the scenario is about") throws -> T {
    guard let value else { throw BrineStepError("\(what) is absent") }
    return value
}

/// A door-free `/status` source, so the poller's state machine is driven without HTTP.
private struct StubStatus: CaptureStatusFetching {
    let stage: String
    let transcribed: Bool
    var title: String? = nil
    func captureStatus(captureId: String) async throws -> CaptureStatusResponse {
        CaptureStatusResponse(stage: stage, loreCaptureId: "c001a016",
                              transcribed: transcribed, title: title)
    }
}

// MARK: - The world

private final class JourneyWorld: @unchecked Sendable {
    var reading = RecordingJourneyReading()
    var current: RecordingName?

    func row(_ stage: RecordingJourneyStage) -> RecordingJourneyRow? {
        RecordingJourneyPresentation.row(for: stage, reading: reading)
    }
}

// MARK: - Steps

private enum JourneySteps {
    static func make(world w: JourneyWorld) -> [StepDefinition] {
        [
            // MARK: transcription

            defineStep("a recording whose Vault transcribes it in twenty parts") { ctx, _, _ in
                w.reading = RecordingJourneyReading(
                    transcript: .inProgress(TranscribeWindowsReading(windowsDone: 0,
                                                                     windowCount: 20)))
                return ctx
            },
            defineStep("two of those parts are done") { ctx, _, _ in
                w.reading.transcript = .inProgress(
                    TranscribeWindowsReading(windowsDone: 2, windowCount: 20))
                return ctx
            },
            defineStep("a recording that is being transcribed with no countable parts") { ctx, _, _ in
                w.reading = RecordingJourneyReading(transcript: .inProgress(nil))
                return ctx
            },
            defineCheck("it says it is being transcribed") { _, _, _ in
                let row = try require(w.row(.transcribing))
                try expect(row.state == .working,
                           "the transcribing stage is \(row.state.rawValue), not working")
                try expect(row.line.hasPrefix(RecordingJourneyPresentation.transcribingLine),
                           "the line does not say it is being transcribed: \"\(row.line)\"")
            },
            defineCheck("it says two of twenty parts are done") { _, _, _ in
                let row = try require(w.row(.transcribing))
                try expect(row.measure == .counted(2, of: 20),
                           "the measure is \(row.measure), not 2 of 20")
                try expect(row.line.contains("2 of 20"),
                           "the sentence does not count the parts: \"\(row.line)\"")
            },

            // MARK: speakers

            defineStep("a recording on a Vault that cannot separate speakers") { ctx, _, _ in
                w.reading = RecordingJourneyReading(transcript: .done, speakers: .unavailable)
                return ctx
            },
            defineCheck("it says the speakers were not separated") { _, _, _ in
                let row = try require(w.row(.separatingSpeakers))
                try expect(row.line == RecordingJourneyPresentation.speakersNotSeparatedLine,
                           "the line is \"\(row.line)\"")
                try expect(row.state == .cannotHappen,
                           "a Vault that never separates speakers reads \(row.state.rawValue)")
            },
            defineCheck("it does not say the speakers are being separated") { _, _, _ in
                let row = try require(w.row(.separatingSpeakers))
                try expect(row.line != RecordingJourneyPresentation.separatingSpeakersLine,
                           "the surface claims work that will never happen")
                try expect(row.state != .working, "an impossible stage reads as working")
            },
            defineCheck("no progress bar may be drawn for it") { _, _, _ in
                let rows = RecordingJourneyPresentation.ladder(w.reading)
                try expect(!rows.isEmpty, "the ladder is empty — nothing was asserted")
                let drawable = rows.filter(\.drawsABar).map(\.stage.rawValue)
                try expect(drawable.isEmpty, "a bar is drawable for \(drawable)")
            },
            defineCheck("a progress bar may be drawn for it") { _, _, _ in
                let drawable = RecordingJourneyPresentation.ladder(w.reading).filter(\.drawsABar)
                try expect(!drawable.isEmpty, "no row in this reading is drawable")
            },

            // MARK: silence

            defineStep("a recording nothing is known about") { ctx, _, _ in
                w.reading = RecordingJourneyReading()
                return ctx
            },
            defineCheck("it says nothing about separating speakers") { _, _, _ in
                try expect(w.row(.separatingSpeakers) == nil,
                           "the surface invented a speakers stage from nothing")
            },
            defineCheck("it says nothing about actions") { _, _, _ in
                try expect(w.row(.readingForActions) == nil,
                           "the surface invented an actions stage from nothing")
            },
            defineCheck("it says nothing about naming it") { _, _, _ in
                try expect(w.row(.naming) == nil,
                           "the absence of a name was reported as work in flight")
            },

            // MARK: off the recorder

            defineStep("a recording that has {int} of its announced {int} bytes off the recorder") { ctx, p, _ in
                w.reading = RecordingJourneyReading(offTheRecorder: RecorderTransferReading(
                    bytesDelivered: try p.requireInt(0), bytesAnnounced: try p.requireInt(1)))
                return ctx
            },
            defineStep("a recording that has {int} bytes off the recorder and no announced total") { ctx, p, _ in
                w.reading = RecordingJourneyReading(offTheRecorder: RecorderTransferReading(
                    bytesDelivered: try p.requireInt(0), bytesAnnounced: nil))
                return ctx
            },
            defineCheck("it says it is coming off the recorder") { _, _, _ in
                let row = try require(w.row(.comingOffTheRecorder))
                try expect(row.line == RecordingJourneyPresentation.comingOffTheRecorderLine,
                           "the line is \"\(row.line)\"")
            },

            // MARK: to the Vault

            defineStep("{int} segments have reached the Vault and nobody knows how many there are") { ctx, p, _ in
                w.reading = RecordingJourneyReading(toTheVault: VaultUploadReading(
                    segmentsConfirmed: try p.requireInt(0), segmentsExpected: nil))
                return ctx
            },
            defineStep("{int} of an expected {int} segments have reached the Vault") { ctx, p, _ in
                w.reading = RecordingJourneyReading(toTheVault: VaultUploadReading(
                    segmentsConfirmed: try p.requireInt(0),
                    segmentsExpected: try p.requireInt(1)))
                return ctx
            },
            defineCheck("no progress bar may be drawn for reaching the Vault") { _, _, _ in
                let row = try require(w.row(.reachingTheVault))
                try expect(!row.drawsABar,
                           "a share was drawn from a total nobody measured: \(row.measure)")
                try expect(row.measure == .tally(79),
                           "the count itself is still a fact and must be shown: \(row.measure)")
            },
            defineCheck("a progress bar may be drawn for reaching the Vault") { _, _, _ in
                let row = try require(w.row(.reachingTheVault))
                try expect(row.drawsABar, "no bar for a measured total")
            },
            defineCheck("the share drawn is {int} of {int}") { _, p, _ in
                let row = try require(w.row(.reachingTheVault))
                let done = try p.requireInt(0), total = try p.requireInt(1)
                try expect(row.measure == .counted(done, of: total),
                           "the measure is \(row.measure), not \(done) of \(total)")
            },

            // MARK: actions

            defineStep("a recording that has been read for actions and produced none") { ctx, _, _ in
                w.reading = RecordingJourneyReading(intelligence: .ranFoundNothing)
                return ctx
            },
            defineStep("a recording that has never been read for actions") { ctx, _, _ in
                w.reading = RecordingJourneyReading(intelligence: .neverRun)
                return ctx
            },
            defineCheck("the actions stage reads {string}") { _, p, _ in
                let expected = try p.requireString(0)
                try expect(w.reading.intelligence.token == expected,
                           "the token is \"\(w.reading.intelligence.token)\", not \"\(expected)\"")
                _ = try require(w.row(.readingForActions))
            },

            // MARK: naming

            defineStep("a recording that has been transcribed and has no name") { ctx, _, _ in
                w.reading = RecordingJourneyReading.fromStatus(CaptureStatusResponse(
                    stage: "in_lore", loreCaptureId: "c001a016", transcribed: true, title: nil))
                return ctx
            },
            defineStep("a recording named from its first few minutes") { ctx, _, _ in
                w.current = RecordingName(text: "Kitchen table", provenance: .provisional)
                return ctx
            },
            defineStep("a recording that already carries its full name") { ctx, _, _ in
                w.current = RecordingName(text: "Deciding the roof", provenance: .full)
                return ctx
            },
            defineStep("the whole recording has been understood") { ctx, _, _ in
                w.current = RecordingNamePresentation.settle(
                    current: w.current,
                    incoming: RecordingName(text: "Deciding the roof", provenance: .full))
                return ctx
            },
            defineStep("a provisional name arrives late") { ctx, _, _ in
                w.current = RecordingNamePresentation.settle(
                    current: w.current,
                    incoming: RecordingName(text: "Kitchen table", provenance: .provisional))
                return ctx
            },
            defineStep("a reply arrives carrying no name at all") { ctx, _, _ in
                w.current = RecordingNamePresentation.settle(current: w.current, incoming: nil)
                return ctx
            },
            defineCheck("it has that name") { _, _, _ in
                let name = try require(w.current)
                try expect(name.text == "Kitchen table", "the name is \"\(name.text)\"")
            },
            defineCheck("it still has a name") { _, _, _ in
                _ = try require(w.current)
            },
            defineCheck("it says the name came from the first few minutes") { _, _, _ in
                try expect(RecordingNamePresentation.note(for: w.current)
                           == RecordingNamePresentation.provisionalNote,
                           "a provisional name is shown with no note saying so")
            },
            defineCheck("it carries the full name") { _, _, _ in
                let name = try require(w.current)
                try expect(name.provenance == .full,
                           "the name is still \(name.provenance.rawValue)")
                try expect(name.text == "Deciding the roof", "the name is \"\(name.text)\"")
            },
            defineCheck("it still carries the full name") { _, _, _ in
                let name = try require(w.current)
                try expect(name.provenance == .full && name.text == "Deciding the roof",
                           "a late provisional walked the real name backwards: \"\(name.text)\"")
            },
            defineCheck("it no longer says the name is provisional") { _, _, _ in
                try expect(RecordingNamePresentation.note(for: w.current) == nil,
                           "the full name is still badged as provisional")
            },
        ]
    }
}
