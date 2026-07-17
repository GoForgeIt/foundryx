import XCTest
@testable import FoundryXKit

/// The honesty gate for tentative speaker matches: a raw WeSpeaker cosine is never a
/// percentage, and a weak inferred name never renders. Pure model — no UI, no network.
final class SpeakerConfidenceTests: XCTestCase {

    // MARK: - tier mapping

    func testTierIsWeakWithoutAScore() {
        XCTAssertEqual(SpeakerConfidence.tier(for: nil), .weak,
                       "no evidence → unproven → weak")
    }

    func testTierIsWeakJustBelowTheFloor() {
        XCTAssertEqual(SpeakerConfidence.tier(for: 0.84), .weak)
    }

    func testTierIsStrongAtTheFloor() {
        XCTAssertEqual(SpeakerConfidence.strongFloor, 0.85, accuracy: 0.0)
        XCTAssertEqual(SpeakerConfidence.tier(for: 0.85), .strong,
                       "the floor is inclusive")
    }

    func testTierIsStrongWellAboveTheFloor() {
        XCTAssertEqual(SpeakerConfidence.tier(for: 0.99), .strong)
    }

    // MARK: - copy has NO percentages, ever

    func testInlineHintIsAWordNotAPercentage() {
        XCTAssertEqual(SpeakerConfidence.inlineStrongHint, "suggested")
        XCTAssertFalse(SpeakerConfidence.inlineStrongHint.contains("%"))
    }

    func testStrongSheetCopyNamesThePersonWithoutAPercentage() {
        let copy = SpeakerConfidence.strongSheetCopy(name: "Govinda")
        XCTAssertTrue(copy.contains("Govinda"))
        XCTAssertFalse(copy.contains("%"))
    }

    func testWeakSheetCopyIsNeutralAndPercentFree() {
        XCTAssertFalse(SpeakerConfidence.weakSheetCopy.contains("%"))
        XCTAssertFalse(SpeakerConfidence.weakSheetCopy.contains("Govinda"))
    }

    func testSheetCopyPicksStrongOnlyAtStrongEvidence() {
        XCTAssertEqual(SpeakerConfidence.sheetCopy(name: "Govinda", score: 0.93),
                       SpeakerConfidence.strongSheetCopy(name: "Govinda"))
        // Weak score → the neutral copy, and the guessed name never appears.
        XCTAssertEqual(SpeakerConfidence.sheetCopy(name: "Govinda", score: 0.78),
                       SpeakerConfidence.weakSheetCopy)
        // No name → neutral copy.
        XCTAssertEqual(SpeakerConfidence.sheetCopy(name: nil, score: 0.99),
                       SpeakerConfidence.weakSheetCopy)
    }

    // MARK: - displayLabel gating

    func testWeakInferredSlotRendersAsUnnamedSpeaker() {
        let t = SpeakerTranscript(
            speakers: [CaptureSpeaker(slot: "speaker_1", status: .inferred,
                                      name: "Govinda", inferScore: 0.78,
                                      inferredSpeakerId: "spk_g")],
            segments: [TranscriptSegment(seq: 0, text: "hi", speaker: "speaker_1")])
        XCTAssertEqual(t.displayLabel(for: "speaker_1"), "Speaker 1",
                       "a weak cosine must not leak the guessed name")
        XCTAssertFalse(t.plainText.contains("Govinda"),
                       "the copy path must not leak it either")
    }

    func testInferredSlotWithNoScoreRendersAsUnnamedSpeaker() {
        let t = SpeakerTranscript(
            speakers: [CaptureSpeaker(slot: "speaker_1", status: .inferred,
                                      name: "Govinda", inferScore: nil)],
            segments: [TranscriptSegment(seq: 0, text: "hi", speaker: "speaker_1")])
        XCTAssertEqual(t.displayLabel(for: "speaker_1"), "Speaker 1")
    }

    func testStrongInferredSlotRendersTheName() {
        let t = SpeakerTranscript(
            speakers: [CaptureSpeaker(slot: "speaker_1", status: .inferred,
                                      name: "Govinda", inferScore: 0.93,
                                      inferredSpeakerId: "spk_g")],
            segments: [TranscriptSegment(seq: 0, text: "hi", speaker: "speaker_1")])
        XCTAssertEqual(t.displayLabel(for: "speaker_1"), "Govinda",
                       "a strong match still surfaces the tentative name")
    }

    func testConfirmedSlotAlwaysRendersTheNameEvenWithLowScore() {
        // A confirmed slot is user-vouched; its label is never gated on a cosine.
        let t = SpeakerTranscript(
            speakers: [CaptureSpeaker(slot: "speaker_1", status: .confirmed,
                                      name: "Govinda", inferScore: 0.10)],
            segments: [TranscriptSegment(seq: 0, text: "hi", speaker: "speaker_1")])
        XCTAssertEqual(t.displayLabel(for: "speaker_1"), "Govinda")
    }
}
