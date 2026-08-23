import XCTest
@testable import FoundryXKit

/// **AC6 and AC7 — the transcription wait appears when something is coming, and not otherwise.**
///
/// THE DEFECT. `ConversationFacesView`'s detail screen decided this from `/content` alone:
///
/// ```swift
/// } else if didAttemptFetch, content?.found == false, loadError == nil {
///     WaitingExperienceView(kind: .transcription)   // "still being produced"
/// ```
///
/// `found == false` is **not** evidence that transcription is running. Those are two different
/// facts, and the screen conflated them — so a capture the door reports `transcribed:true` whose
/// content simply is not there (**the live capture's exact state**, which is why the spec calls
/// AC6 "this is the live capture's exact state, as a fixture") read *"the transcript is still being
/// produced"* forever.
///
/// It is the same shape as the four-day `summarizing: true` defect this proposal exists to end:
/// **an absence presented as progress.**
///
/// AC6 is the negative and AC7 is its PAIRED EXISTENCE. The spec is explicit about why:
/// *"Without this, AC6 passes on a screen that never waits for anything."* A predicate hardcoded
/// to `false` satisfies AC6 perfectly and breaks every real wait.
final class TheWaitIsOnlyShownWhenSomethingIsComingTests: XCTestCase {

    private func status(stage: String, transcribed: Bool, dropped: String? = nil)
        -> CaptureStatusResponse {
        CaptureStatusResponse(stage: stage, loreCaptureId: "c001a016",
                              transcribed: transcribed, title: nil, droppedReason: dropped)
    }

    /// **AC6.** `/status` says transcribed, `/content` has nothing → NO wait.
    func testATranscribedCaptureWhoseContentIsMissingDoesNotClaimItIsStillBeingProduced() {
        let reading = RecordingJourneyReading.fromStatus(status(stage: "in_lore", transcribed: true))
        XCTAssertEqual(reading.transcript, .done,
                       "the door said transcribed — that is the fact the screen must read")
        XCTAssertFalse(reading.transcript.isAWait,
                       "the transcript EXISTS; `/content` not returning it is a different problem, "
                           + "and telling a person it is 'still being produced' is an absence "
                           + "presented as progress")
    }

    /// **AC7 — the paired existence.** Without it, AC6 passes on a screen that never waits.
    func testACaptureThatIsGenuinelyTranscribingDoesRenderAWait() {
        let reading = RecordingJourneyReading.fromStatus(
            status(stage: "transcribing", transcribed: false))
        XCTAssertTrue(reading.transcript.isAWait,
                      "work IS in flight here — a predicate hardcoded to false would satisfy AC6 "
                          + "and break every real wait, which is exactly what this pairing exists "
                          + "to prevent")
    }

    /// The cruellest version of the defect, and the one the old branch also produced: a recording
    /// that was DROPPED, told it is still being produced.
    func testADroppedRecordingIsNeverStillBeingProduced() {
        let reading = RecordingJourneyReading.fromStatus(
            status(stage: "failed", transcribed: false, dropped: "noise"))
        XCTAssertFalse(reading.transcript.isAWait,
                       "it is never arriving. \"Still being produced\" about a dropped recording "
                           + "is the same lie as a name pending on one.")
    }

    /// Not-yet-started IS a wait — the other true case, so `isAWait` is not just "inProgress".
    func testACaptureThatHasNotStartedIsStillSomethingAPersonIsWaitingFor() {
        let reading = RecordingJourneyReading.fromStatus(
            status(stage: "stored", transcribed: false))
        XCTAssertEqual(reading.transcript, .notStarted)
        XCTAssertTrue(reading.transcript.isAWait,
                      "nothing has begun, but something is coming — a person waiting for it is "
                          + "waiting correctly")
    }

    /// EVERY case is decided, and the count is exact. A `switch` that grew a fifth case would
    /// otherwise pick up whatever the `default` said, silently.
    func testEveryReadinessCaseIsDecidedAndTheCensusIsExact() {
        let all: [TranscriptReadiness] = [
            .notStarted,
            .inProgress(nil),
            .inProgress(TranscribeWindowsReading(windowsDone: 2, windowCount: 20)),
            .done,
            .failed(nil),
            .failed("noise"),
        ]
        let waits = all.filter(\.isAWait).count
        XCTAssertEqual(waits, 3,
                       "exactly three of these six are waits (notStarted and the two inProgress "
                           + "shapes). An exact number, not a bound: 'some are waits' is satisfied "
                           + "by a predicate that says everything is.")
        XCTAssertEqual(all.count - waits, 3,
                       "and exactly three are not — done twice over and both failures")
    }
}
