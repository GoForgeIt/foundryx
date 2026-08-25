import XCTest
@testable import FoundryXKit

/// P11/AC4 — `NamingState.inFlight` is REACHABLE, and reachable ONLY from evidence.
///
/// Its own doc has always said *"a titling run is claimed/running — evidence, not an inference
/// from a NULL"*, and until Lore recorded the `conversation_processing` run id and resolved it
/// through the runtime's `GET /status/{run_id}`, **no code path could construct it.** These
/// tests pin both halves: that it can now be reached, and that it still cannot be reached the
/// wrong way.
///
/// The wrong way is specific and shipped once: the door's
/// `summarizing = transcribed && title.is_none()` reported work in flight for FOUR DAYS on a
/// capture that could never be titled, because the absence of a title is not evidence of work.
final class NamingIsEvidenceNotInferenceTests: XCTestCase {

    private func reading(title: String? = nil,
                         transcribed: Bool = true,
                         naming: String? = nil) -> RecordingJourneyReading {
        CaptureStatusPoller.journey(stage: .transcribing,
                                    transcribed: transcribed,
                                    title: title,
                                    droppedReason: nil,
                                    transcribeWindows: nil,
                                    naming: naming)
    }

    /// ⚠ THE FOUR-DAY DEFECT, PINNED. A transcribed capture with no title and NO evidence must
    /// not claim naming is running.
    func testATranscribedUntitledCaptureWithNoEvidenceDoesNotClaimNamingIsRunning() {
        XCTAssertEqual(reading(title: nil, transcribed: true, naming: nil).naming,
                       .notEstablished,
                       "an absent title became a running titling run — the summarizing defect")
    }

    /// PAIRED: without this, the test above is satisfied by a derivation that can never return
    /// `.inFlight` at all — which was literally the state of the world before this work.
    func testEvidenceOfARunningTitlingRunReachesInFlight() {
        XCTAssertEqual(reading(title: nil, naming: "inFlight").naming, .inFlight)
    }

    /// A title outranks the run state: the name exists, so the stage is done regardless of what
    /// the runtime says about a run that produced it.
    func testATitleThatExistsIsDoneEvenWhileARunIsReportedRunning() {
        XCTAssertEqual(reading(title: "A name", naming: "inFlight").naming, .done)
    }

    /// A FAILED run is not a running one. Telling those apart is the entire reason this arrives
    /// as evidence — the claim marker could not, because it is written before the fire.
    func testAFailedRunIsNotInFlight() {
        XCTAssertEqual(reading(naming: "failed").naming, .notEstablished)
        XCTAssertNotEqual(reading(naming: "failed").naming, .inFlight)
    }

    /// A COMPLETED run that produced no title is not "naming in progress". The runner documents
    /// abstention as a correct outcome — *"never a null fabricated over"* — so showing a naming
    /// stage for a run that deliberately declined to name would be the same lie inverted.
    func testACompletedRunWithNoTitleDoesNotClaimNamingIsRunning() {
        XCTAssertEqual(reading(naming: "completed").naming, .notEstablished)
    }

    /// An unrecognised token is not a stage. A Lore that grows a fourth state must not have it
    /// silently read as "running".
    func testAnUnrecognisedTokenIsNotAStage() {
        for token in ["running", "in_flight", "queued", "", "InFlight"] {
            XCTAssertEqual(reading(naming: token).naming, .notEstablished,
                           "token \(token) produced a stage; only 'inFlight' may")
        }
    }

    /// ⚠ THE PRODUCTION PATH, not a re-implementation. `RecordingJourneyReading.fromStatus` is what the
    /// card renders from, and an earlier version of this work was graded against a function the
    /// phone never called — the two derivations disagreed on 186 of 252 shapes, 108 of them on
    /// `naming` exactly.
    func testTheProductionDerivationCarriesTheEvidenceToo() {
        let resp = CaptureStatusResponse(stage: "transcribing",
                                         loreCaptureId: "cap-1",
                                         transcribed: true,
                                         title: nil,
                                         naming: "inFlight")
        XCTAssertEqual(RecordingJourneyReading.fromStatus(resp).naming, .inFlight)

        let noEvidence = CaptureStatusResponse(stage: "transcribing",
                                               loreCaptureId: "cap-1",
                                               transcribed: true,
                                               title: nil)
        XCTAssertEqual(RecordingJourneyReading.fromStatus(noEvidence).naming, .notEstablished)
    }

    /// The door's field must survive JSON decoding — a field declared and never decoded is
    /// always `nil` in production while every hand-built fixture passes.
    func testTheNamingFieldIsDecodedOffTheWire() throws {
        let json = #"{"stage":"transcribing","loreCaptureId":"c","transcribed":true,"naming":"inFlight"}"#
        let resp = try JSONDecoder().decode(CaptureStatusResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.naming, "inFlight")
        XCTAssertEqual(RecordingJourneyReading.fromStatus(resp).naming, .inFlight)
    }

    /// An unknown token must not fail the WHOLE response — the transcript reading must survive a
    /// Lore that grew a state this build does not know.
    func testAnUnknownTokenDoesNotTakeTheWholeResponseDown() throws {
        let json = #"{"stage":"transcribing","loreCaptureId":"c","transcribed":true,"naming":"quantum"}"#
        let resp = try JSONDecoder().decode(CaptureStatusResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.naming, "quantum")
        XCTAssertEqual(RecordingJourneyReading.fromStatus(resp).naming, .notEstablished)
    }
}
