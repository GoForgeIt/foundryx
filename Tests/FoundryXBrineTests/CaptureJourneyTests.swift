import XCTest
@testable import FoundryXKit

/// Unit cover for the parts of the journey the feature files state in a person's words but do not
/// pin numerically: the byte formatter this surface has got wrong twice, the percentage rounding
/// that would turn a nearly-finished transfer into a finished one, and the three-valued brain
/// mapping whose two-valued spelling is the live defect.
final class CaptureJourneyTests: XCTestCase {

    // MARK: - bytes are rendered as bytes

    /// THE MEASURED DEFECT. `PocketRecordingDeviceSource` renders a recording's size by dividing
    /// bytes by 1,024 before calling `RecordingDeviceReadingPresentation.size(kilobytes:)`. The
    /// bug this program shipped was a "4 KB" label on a 19,770-byte file — and the neighbouring
    /// bug was handing that same kilobyte formatter a byte count, which reads 19,770 as 19.3 MB.
    /// Both are excluded here by naming the answer.
    func testNineteenThousandBytesIsNineteenKilobytes() {
        XCTAssertEqual(JourneyFigure.size(bytes: 19_770), "19 KB")
        XCTAssertNotEqual(JourneyFigure.size(bytes: 19_770), "4 KB")
        XCTAssertFalse(JourneyFigure.size(bytes: 19_770).contains("MB"))
    }

    func testSubKilobyteSizesSayBytesRatherThanZero() {
        XCTAssertEqual(JourneyFigure.size(bytes: 800), "800 bytes")
        XCTAssertEqual(JourneyFigure.size(bytes: 0), "0 bytes")
    }

    func testMegabytesAndGigabytesUseTheSharedFormatter() {
        XCTAssertEqual(JourneyFigure.size(bytes: 5_242_880),
                       RecordingDeviceReadingPresentation.size(kilobytes: 5_120))
    }

    // MARK: - the percentage cannot round itself to done

    func testANearlyFinishedTransferNeverReadsAsOneHundredPercent() {
        let almost = JourneyFigure.bytes(delivered: 999_999, announced: 1_000_000)
        XCTAssertEqual(almost.percentText, "99%")
        let done = JourneyFigure.bytes(delivered: 1_000_000, announced: 1_000_000)
        XCTAssertEqual(done.percentText, "100%")
    }

    func testAQuarterReadsAsTwentyFivePercent() {
        XCTAssertEqual(JourneyFigure.bytes(delivered: 250_000, announced: 1_000_000).percentText,
                       "25%")
    }

    // MARK: - every route into a figure degrades

    func testEveryDegenerateDenominatorFallsBackToACount() {
        let cases: [JourneyFigure] = [
            .outOf(5, of: 0, noun: "segments", settled: true),      // zero denominator
            .outOf(5, of: -3, noun: "segments", settled: true),     // negative denominator
            .outOf(9, of: 5, noun: "segments", settled: true),      // numerator past denominator
            .outOf(2, of: 5, noun: "segments", settled: false),     // still growing
            .bytes(delivered: 5, announced: nil),
            .bytes(delivered: 5, announced: 0),
            .bytes(delivered: 4_000, announced: 1_000),
        ]
        for figure in cases {
            XCTAssertNil(figure.total, "kept a denominator: \(figure.line)")
            XCTAssertNil(figure.fraction, "derived a fraction: \(figure.line)")
            XCTAssertNil(figure.percentText, "derived a percentage: \(figure.line)")
            XCTAssertFalse(figure.showsBar, "drew a bar: \(figure.line)")
            XCTAssertFalse(figure.line.contains("%"), "printed a percentage: \(figure.line)")
        }
    }

    func testASilentFigurePrintsNothingAtAll() {
        XCTAssertEqual(JourneyFigure.silent.line, "")
        XCTAssertTrue(JourneyFigure.silent.isLabelOnly)
        XCTAssertFalse(JourneyFigure.silent.showsBar)
    }

    // MARK: - the three-valued brain

    /// The crush, named: `.foundryCloud` and `.myComputer` must not resolve to the same place,
    /// because that equality IS the live defect on Nick's phone.
    func testEveryBrainNamesItsOwnPlaceAndNoTwoAgree() {
        let mapped = BrainChoice.allCases.map(\.captureDestination)
        XCTAssertEqual(Set(mapped).count, BrainChoice.allCases.count)
        XCTAssertEqual(BrainChoice.justMyPhone.captureDestination, .phone)
        XCTAssertEqual(BrainChoice.myComputer.captureDestination, .computer)
        XCTAssertEqual(BrainChoice.foundryCloud.captureDestination, .vault)
        XCTAssertNotEqual(BrainChoice.foundryCloud.captureDestination,
                          BrainChoice.myComputer.captureDestination)
    }

    /// And the same claim held over the JOURNEY, so a correct mapping wired into a careless
    /// builder still cannot put a computer in front of a cell owner.
    func testACloudBrainsJourneyNeverNamesAComputer() {
        let journey = CaptureJourney.build(.detail(
            status: nil, brain: .foundryCloud, transfer: .arrived, cardStage: "in_lore",
            content: nil, hasTranscript: true, separatedSpeakers: 0, hasSummary: false,
            synthesizingSummary: false, decisions: [], surfaced: 0))
        for step in journey.steps {
            XCTAssertFalse(step.title.lowercased().contains("computer"), step.title)
            XCTAssertFalse((step.detail ?? "").lowercased().contains("computer"),
                           step.detail ?? "")
        }
        XCTAssertEqual(journey.step(.secondPlace)?.title, "Saved to your Vault")
    }

    func testThePhoneOnlyBrainHasNoSecondPlaceStep() {
        let journey = CaptureJourney.build(.detail(
            status: nil, brain: .justMyPhone, transfer: .none, cardStage: nil,
            content: nil, hasTranscript: false, separatedSpeakers: 0, hasSummary: false,
            synthesizingSummary: false, decisions: [], surfaced: 0))
        XCTAssertNil(journey.step(.secondPlace))
    }

    // MARK: - the transfer, and the defect the bool-and-optional spelling shipped

    /// A RECORDING THAT HAS ALREADY COME OVER IS NOT STILL COMING OVER.
    ///
    /// The first version of this file took `cameOffARecorder: Bool` + `pull: PullReading?`, and
    /// the detail view — which knows the recorder's file is on this phone and nothing about the
    /// transfer that put it there — passed `true, nil`. The step read that as "in flight,
    /// unmeasured" and drew "Off the recorder … waiting" at the top of every already-transferred
    /// recording's page, permanently. `.arrived` is the third state that pair could not hold.
    func testAnArrivedTransferIsDoneAndClaimsNoNumber() {
        let journey = CaptureJourney.build(CaptureJourneyReading(
            transfer: .arrived, wal: .savedToComputer, totalSegments: 4, syncedSegments: 4,
            destination: .vault, door: .transcribed, transcribed: true, hasTranscript: true))
        let step = journey.step(.offTheRecorder)
        XCTAssertEqual(step?.state, .done)
        XCTAssertEqual(step?.figure.line, "")
        XCTAssertFalse(step?.figure.showsBar ?? true)
    }

    func testAPhoneRecordingHasNoTransferStepAtAll() {
        let journey = CaptureJourney.build(CaptureJourneyReading(
            transfer: .none, destination: .vault))
        XCTAssertNil(journey.step(.offTheRecorder))
    }

    func testAnInFlightTransferIsWorkingAndCarriesItsBytes() {
        let journey = CaptureJourney.build(CaptureJourneyReading(
            transfer: .measured(PullReading(delivered: 250_000, announced: 1_000_000,
                                            finished: false)),
            destination: .vault))
        let step = journey.step(.offTheRecorder)
        XCTAssertEqual(step?.state, .working)
        XCTAssertEqual(step?.figure.percentText, "25%")
    }

    // MARK: - the join

    func testAnUnknownCardStageDegradesRatherThanClaiming() {
        let reading = CaptureJourneyReading.detail(
            status: nil, brain: .foundryCloud, transfer: .none,
            cardStage: "some_stage_the_phone_has_never_heard_of", content: nil,
            hasTranscript: false, separatedSpeakers: 0, hasSummary: false,
            synthesizingSummary: false, decisions: [], surfaced: 0)
        XCTAssertEqual(reading.door, .stored)
    }

    func testTheHeadlineNamesTheStepAPersonIsWaitingOn() {
        let journey = CaptureJourney.build(CaptureJourneyReading(
            wal: .savedToComputer, totalSegments: 40, syncedSegments: 40,
            destination: .vault, door: .transcribing))
        XCTAssertEqual(journey.current?.phase, .transcript)
        XCTAssertEqual(journey.headline, "Transcribed")
    }

    func testAFailedTranscriptionSaysWhyRatherThanSpinning() {
        let journey = CaptureJourney.build(CaptureJourneyReading(
            wal: .savedToComputer, totalSegments: 40, syncedSegments: 40,
            destination: .vault, door: .failed, droppedReason: "silent_no_transcript"))
        XCTAssertEqual(journey.step(.transcript)?.state, .failed)
        XCTAssertEqual(journey.step(.transcript)?.detail, "No speech detected")
    }

    // MARK: - the ambient join

    func testAUserAddedActionCountsEvenWhereNoGateEverRan() {
        XCTAssertEqual(AmbientReading.reading(hasTranscript: false, decisions: [], surfaced: 1),
                       .surfaced(1))
    }

    func testAGateThatOnlyEverSkippedIsNotReportedAsEmpty() {
        let skipped = AmbientDecision(ts: 1, captureId: "c", windowChars: 10, outcome: .skipped,
                                      candidate: nil, skipReason: "gate_unavailable", latencyMs: 1)
        let reading = AmbientReading.reading(hasTranscript: true, decisions: [skipped],
                                             surfaced: 0)
        XCTAssertEqual(reading, .couldNotRead("gate_unavailable"))
        XCTAssertNotEqual(reading, .readAndFoundNothing)
        XCTAssertFalse(reading.isSettled)
    }

    func testOneRealReadAmongSkipsCountsAsARead() {
        let skipped = AmbientDecision(ts: 1, captureId: "c", windowChars: 10, outcome: .skipped,
                                      candidate: nil, skipReason: "gate_error", latencyMs: 1)
        let read = AmbientDecision(ts: 2, captureId: "c", windowChars: 10, outcome: .gatedNo,
                                   candidate: nil, skipReason: nil, latencyMs: 1)
        XCTAssertEqual(AmbientReading.reading(hasTranscript: true, decisions: [skipped, read],
                                              surfaced: 0),
                       .readAndFoundNothing)
    }
}

/// THE VOCABULARY GATE, EXTENDED TO THE COPY IT CANNOT SEE.
///
/// `features/voice-notes-language.feature` retired "recording" and "conversation" as words for a
/// voice note — and its gate scans `App/*.swift` only. Every sentence this track puts in front of
/// a person lives in `Sources/FoundryXKit`, so that gate is blind to all of it: the first draft of
/// this work said "this recording" five times and only the ONE copy of it that happened to sit in
/// an `App/` file was caught. An unscanned string is not an exempt one.
///
/// It reuses `VoiceNotesLanguage.offendingStringLiterals` — the REAL oracle, with the real
/// word-boundary regex — by handing it the copy as source, rather than restating the rule here
/// where the two spellings could drift.
final class CaptureJourneyCopyTests: XCTestCase {

    /// Every sentence the journey and the early name can render, across the whole population.
    private func everySentence() -> [String] {
        var out: [String] = AmbientReading.everyReading.map(\.line)
        for destination in CaptureDestination.allCases {
            for door in [CaptureLifecycleStage.stored, .transcribing, .inLore, .transcribed,
                         .organized, .failed] {
                for ambient in AmbientReading.everyReading {
                    let journey = CaptureJourney.build(CaptureJourneyReading(
                        transfer: .measured(
                            PullReading(delivered: 1, announced: 2, finished: false)),
                        wal: .savedToComputer, totalSegments: 4, syncedSegments: 4,
                        destination: destination, door: door,
                        transcribed: true, hasTranscript: true, separatedSpeakers: 2,
                        summarizing: true, hasSummary: false, ambient: ambient,
                        droppedReason: "noise"))
                    out.append(journey.headline)
                    for step in journey.steps {
                        out.append(step.title)
                        if let detail = step.detail { out.append(detail) }
                    }
                }
            }
        }
        out.append(EarlyConversationName.Offer(name: "n", basis: .seconds(45)).note)
        out.append(EarlyConversationName.Offer(name: "n", basis: .seconds(1)).note)
        out.append(EarlyConversationName.Offer(name: "n", basis: .openingWords).note)
        return out
    }

    func testNoSentenceThisTrackRendersUsesTheRetiredWords() {
        let sentences = everySentence()
        XCTAssertGreaterThan(sentences.count, 100,
                             "VACUOUS: the copy population is \(sentences.count)")
        // Each sentence presented to the real oracle as the kind of literal it actually is.
        let source = sentences
            .map { "Text(\"\($0.replacingOccurrences(of: "\"", with: "'"))\")" }
            .joined(separator: "\n")
        let offenses = VoiceNotesLanguage.offendingStringLiterals(in: source)
        XCTAssertTrue(offenses.isEmpty, "retired vocabulary in kit copy:\n"
                      + offenses.joined(separator: "\n"))
    }

    /// AND THE GATE CAN FAIL. A sentence with the retired word in it is rejected by the same
    /// call — so a green above is a green over a check that discriminates.
    /// NO SENTENCE LEAKS A WIRE TOKEN. `gate_unavailable`, `silent_no_transcript`, `in_lore` —
    /// every string on this seam that is a machine's word for something has an underscore in it,
    /// and no product sentence does. The property is cheap, and it is the one that catches the
    /// habit rather than one instance of it.
    func testNoSentenceLeaksAMachinesWordForSomething() {
        for sentence in everySentence() where sentence.contains("_") {
            XCTFail("a wire token reached a person: \(sentence)")
        }
        for reason in ["gate_unavailable", "gate_error", "something_new_nobody_mapped", ""] {
            let line = AmbientReading.couldNotRead(reason).line
            XCTAssertFalse(line.contains("_"), line)
        }
    }

    func testTheVocabularyOracleRejectsTheRetiredWord() {
        let offenses = VoiceNotesLanguage.offendingStringLiterals(
            in: "Text(\"Solleva read this recording and found nothing to act on.\")")
        XCTAssertFalse(offenses.isEmpty,
                       "the oracle passed a sentence calling a voice note a recording")
    }
}

/// Unit cover for the early name that the feature file states in words.
final class EarlyConversationNameTests: XCTestCase {

    private let opening = "We should get the roof quote from Martin before Friday "
        + "because the estimate expires"

    func testSecondsAreRoundedUpAndCappedAtTheWindow() {
        XCTAssertEqual(EarlyConversationName.seconds(fromMilliseconds: 11_400), 12)
        XCTAssertEqual(EarlyConversationName.seconds(fromMilliseconds: 0), 1)
        XCTAssertEqual(EarlyConversationName.seconds(fromMilliseconds: 900_000), 60)
    }

    /// A segment array with no `startMs` anywhere knows no more about time than a flat string
    /// does, and must not lend its shape to a duration claim.
    func testUntimedSegmentsAreNotAllowedToClaimSeconds() {
        let segments = [TranscriptSegment(seq: 0, text: opening, speaker: "S1")]
        let offer = EarlyConversationName.offer(segments: segments, flat: opening)
        XCTAssertEqual(offer?.basis, .openingWords)
        XCTAssertFalse(offer?.note.lowercased().contains("second") ?? true)
    }

    func testParagraphTimingsAreASourceOfSeconds() {
        let paragraphs = [TranscriptParagraph(start: 0, end: 18.2, speaker: nil, text: opening)]
        let offer = EarlyConversationName.offer(paragraphs: paragraphs)
        XCTAssertEqual(offer?.basis, .seconds(19))
    }

    func testMaterialPastTheWindowIsNotRead() {
        let segments = [
            TranscriptSegment(seq: 0, startMs: 0, endMs: 10_000, text: opening, speaker: "S1"),
            TranscriptSegment(seq: 1, startMs: 400_000, endMs: 420_000,
                              text: "zebra zebra zebra zebra zebra zebra zebra zebra",
                              speaker: "S1"),
        ]
        let offer = EarlyConversationName.offer(segments: segments)
        XCTAssertNotNil(offer)
        XCTAssertFalse(offer!.name.lowercased().contains("zebra"), offer!.name)
        XCTAssertEqual(offer?.basis, .seconds(10))
    }

    func testTheRowLatchIsOneWayAcrossManyReadings() {
        var row = ConversationNameOnTheRow()
        row.adopt(early: "Roof quote", settled: nil)
        XCTAssertTrue(row.isProvisional)
        row.adopt(early: "Roof quote", settled: "Roof replacement quote")
        XCTAssertFalse(row.isProvisional)
        // Twenty more readings, none of which carry a settled name.
        for _ in 0..<20 { row.adopt(early: "Something else", settled: nil) }
        XCTAssertEqual(row.name, "Roof replacement quote")
        XCTAssertFalse(row.isProvisional)
    }

    func testABlankSettledNameDoesNotLatchTheRow() {
        var row = ConversationNameOnTheRow()
        row.adopt(early: "Roof quote", settled: "   ")
        XCTAssertEqual(row.name, "Roof quote")
        XCTAssertTrue(row.isProvisional)
        XCTAssertFalse(row.everSettled)
    }
}
