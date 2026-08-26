import XCTest
@testable import FoundryXKit

/// A card the poller has never reached must say NOTHING about a stage — not "not yet".
///
/// ## The defect this pins
///
/// MEASURED 2026-08-26, on a shipped build, reported with screenshots. The capture list
/// rendered "Not transcribed yet" under two recordings whose OWN detail view said
/// "Transcribed ✓ / Summarized ✓". Two surfaces, one truth, and the surface with LESS
/// information was the one making the claim.
///
/// The cause was in the type, not the view. `TranscriptReadiness` had no way to spell "I do
/// not know": `RecordingJourneyReading` defaulted `transcript` to `.notStarted`, and
/// `CaptureStatusPoller.journey` starts as a default reading. So a poller that had never
/// reached the door — which is every card when the door is unreachable — asserted a fact.
///
/// `RecordingJourneyBand`'s own comment promised this behaviour already: "a card that has
/// not been polled says nothing rather than claiming a stage". The type made that promise
/// impossible to keep, and a promise only a comment enforces is not enforced.
final class UnpolledCardClaimsNothingTests: XCTestCase {

    func testAnUnpolledReadingProducesNoTranscriptRow() {
        // Exactly what `CaptureStatusPoller.journey` holds before any successful poll.
        let unpolled = RecordingJourneyReading()

        XCTAssertEqual(unpolled.transcript, .unknown,
                       "an unpolled reading must default to UNKNOWN, never to a claim")

        let row = RecordingJourneyPresentation.row(for: .transcribing, reading: unpolled)
        XCTAssertNil(row, "an unpolled card must render no transcript row at all")
    }

    /// The other half, and it is what keeps this from being satisfied by a band that never
    /// draws anything. A reading that genuinely says "not started" MUST still say so.
    func testAKnownNotStartedReadingStillSaysSo() {
        var polled = RecordingJourneyReading()
        polled.transcript = .notStarted

        let row = RecordingJourneyPresentation.row(for: .transcribing, reading: polled)
        XCTAssertNotNil(row, "a real not-started answer must still be rendered")
        XCTAssertEqual(row?.state, .waiting)
        XCTAssertEqual(row?.line, RecordingJourneyPresentation.transcriptNotStartedLine)
    }

    /// ⚠ UNKNOWN IS NOT A WAIT. Nobody is waiting on an answer nobody asked for, and telling
    /// a person "still producing" about an unpolled recording is the same manufactured claim
    /// in a different sentence.
    func testUnknownIsNotAWait() {
        XCTAssertFalse(TranscriptReadiness.unknown.isAWait)
        XCTAssertTrue(TranscriptReadiness.notStarted.isAWait,
                      "a real not-started answer IS someone waiting")
    }

    /// The whole ladder, so the band's `rows.isEmpty` path is the one an unpolled card takes.
    func testAnUnpolledReadingYieldsAnEmptyLadder() {
        let ladder = RecordingJourneyPresentation.ladder(RecordingJourneyReading())
        XCTAssertTrue(
            ladder.isEmpty,
            "an unpolled card must produce NO rows — the band renders EmptyView for an empty "
            + "ladder, which is how it takes up no space and makes no claim. Got: "
            + "\(ladder.map(\.line))")
    }
}
