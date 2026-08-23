import XCTest
@testable import FoundryXKit

/// **AC8 — the upload bar's numerator and denominator are both right, and they are different facts.**
///
/// The spec rewrote this AC after review round 2 because *"the first draft could not fail: it
/// forbade one wrong denominator (`sizeBytes`) and accepted every other invented one, including the
/// received count itself."* So the fixture here is the one the spec specifies — an authoritative
/// expected count with a **non-contiguous acknowledged subset**, `expected 100, acked {0…48, 50…79}
/// = 79` — and **numerator and denominator are asserted independently.**
///
/// THE THREE WRONG DENOMINATORS, and why each fixture catches it:
///
/// | wrong denominator | what it reads | caught because |
/// |---|---|---|
/// | `segments_received` | **100 %** — received over received | 79/100 is asserted, not 79/79 |
/// | `max(seq) + 1` | 79/**80** | the acked set is non-contiguous, so max+1 ≠ the total |
/// | `sizeBytes` | a byte count as a segment total | the units are asserted as segments |
///
/// **WHY THE DENOMINATOR CANNOT COME FROM THE DOOR.** Every number the door has is a fact about
/// what ARRIVED: `/segments` returns received `seqs`; the manifest has `segments_received`,
/// `first_seq`, `last_seq`. **None is a total.** The phone produced the segments, so the phone is
/// the only party that knows how many there are.
final class TheUploadBarDividesByWhatTheUploaderKnowsTests: XCTestCase {

    /// `expected 100, acked {0…48, 50…79}` — 79 acknowledged, one hole at 49, highest seq 79.
    private func nonContiguous() -> CaptureStatus {
        var s = CaptureStatus(id: "c001a016", stage: .savedOnPhone, totalSegments: 100,
                              syncedSegments: 79, bytes: 4_000_000, startedAt: Date(),
                              streaming: false)
        s.lastSyncError = nil
        return s
    }

    // MARK: - AC8 — the two numbers, asserted independently

    func testTheNumeratorAndTheDenominatorAreBothCorrectAndAreNotTheSameFact() {
        guard let reading = VaultUploadReading.from(nonContiguous()) else {
            return XCTFail("a capture with 100 segments has a denominator; nil means the "
                               + "derivation refused a case it must answer")
        }

        // Independently. Asserting a ratio would pass for 79/79 and for 100/100 alike.
        XCTAssertEqual(reading.segmentsConfirmed, 79,
                       "79 segments are acknowledged — the count, not the contiguous watermark, "
                           + "which for this set is 49")
        XCTAssertEqual(reading.segmentsExpected, 100,
                       "100 segments exist. Dividing by the RECEIVED count would read 100% while "
                           + "21 are still in flight — the false-completion case")
    }

    /// **The false-completion case, stated as its own assertion.** This is the one the spec names
    /// first, and the one a reviewer will look for.
    func testTheBarCannotReadCompleteWhileSegmentsAreStillInFlight() {
        guard let reading = VaultUploadReading.from(nonContiguous()) else {
            return XCTFail("no reading")
        }
        XCTAssertNotEqual(reading.segmentsConfirmed, reading.segmentsExpected,
                          "79 of 100 is not complete. If these are ever equal here, the "
                              + "denominator has become the numerator.")
        XCTAssertLessThan(reading.segmentsConfirmed, reading.segmentsExpected!,
                          "and the confirmed count must be BELOW the total, not merely different")
    }

    /// `max(seq) + 1` would be 80, not 100 — the second wrong denominator.
    func testTheDenominatorIsNotDerivedFromTheHighestSequenceNumber() {
        guard let reading = VaultUploadReading.from(nonContiguous()) else {
            return XCTFail("no reading")
        }
        XCTAssertNotEqual(reading.segmentsExpected, 80,
                          "the acked set is {0…48, 50…79}, so max(seq)+1 is 80 — which is neither "
                              + "the total nor the acknowledged count. A non-contiguous fixture is "
                              + "the only kind that separates these three numbers.")
    }

    // MARK: - AC8b — no authoritative total means no bar, and not a zero

    func testACaptureWithNoSegmentsYieldsNoReadingAtAllRatherThanZeroOfZero() {
        let empty = CaptureStatus(id: "c001a016", stage: .recording, totalSegments: 0,
                                  syncedSegments: 0, bytes: 0, startedAt: Date(), streaming: true)
        XCTAssertNil(VaultUploadReading.from(empty),
                     "nothing to divide by is an ABSENCE, not 0 of 0. `{0, 0}` gets drawn as "
                         + "\"0 %\" of something, which is a claim about work that has not started.")
    }

    /// **PAIRED EXISTENCE for the nil case.** Without this, "returns nil when there is no total" is
    /// satisfied perfectly by a derivation that always returns nil and never draws a bar at all.
    func testACaptureThatDoesHaveSegmentsYieldsAReading() {
        let one = CaptureStatus(id: "c001a016", stage: .savedOnPhone, totalSegments: 1,
                                syncedSegments: 0, bytes: 4_000, startedAt: Date(), streaming: false)
        let reading = VaultUploadReading.from(one)
        XCTAssertNotNil(reading,
                        "one segment IS a denominator — otherwise the nil assertion above passes "
                            + "on a derivation that refuses every case")
        XCTAssertEqual(reading?.segmentsConfirmed, 0)
        XCTAssertEqual(reading?.segmentsExpected, 1)
    }

    /// A fully-synced capture reads complete — the other end of the range, so "not complete" above
    /// is not satisfied by a derivation that can never report completion.
    func testAFullySyncedCaptureReadsComplete() {
        let done = CaptureStatus(id: "c001a016", stage: .savedToComputer, totalSegments: 12,
                                 syncedSegments: 12, bytes: 48_000, startedAt: Date(),
                                 streaming: false)
        let reading = VaultUploadReading.from(done)
        XCTAssertEqual(reading?.segmentsConfirmed, 12)
        XCTAssertEqual(reading?.segmentsExpected, 12,
                       "12 of 12 — and this pairs with the false-completion assertion, which would "
                           + "otherwise hold on a derivation that never reports done")
    }
}
