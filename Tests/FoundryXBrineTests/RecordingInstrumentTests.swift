import XCTest
import Foundation
import FoundryXKit

/// The recording instrument (features/recording-instrument.feature, track
/// 20260713T0903). The ring itself is Grain (pure presentation); these tests pin
/// the durable logic the screen renders from — the provisional live title and
/// the pill's visibility rule.
final class RecordingInstrumentTests: XCTestCase {

    // Scenario: a recording earns its name from what was said
    func testNoTitleUntilEnoughSaid() {
        XCTAssertNil(ProvisionalLiveTitle.title(from: ""))
        XCTAssertNil(ProvisionalLiveTitle.title(from: "So um"),
                     "a couple of words is not a name")
    }

    func testTitleAppearsFromSpokenWords() {
        let text = "Let's plan the launch for the October release and split the work"
        let title = ProvisionalLiveTitle.title(from: text)
        XCTAssertNotNil(title)
        XCTAssertTrue(text.hasPrefix(title!.replacingOccurrences(of: "…", with: "")),
                      "the provisional name comes from what was actually said")
        XCTAssertLessThanOrEqual(title!.split(separator: " ").count, 8)
    }

    // …and it updates in place rather than jumping the layout: the title is a
    // pure function of the transcript, so the same head → the same title.
    func testTitleIsStableForTheSameHead() {
        let head = "Let's plan the launch for the October release"
        let t1 = ProvisionalLiveTitle.title(from: head + " and split the work")
        let t2 = ProvisionalLiveTitle.title(from: head + " and split the work between us")
        XCTAssertEqual(t1, t2, "growth beyond the head never rewrites the name")
    }

    // Scenario: recording survives leaving the tab (the pill's visibility rule)
    func testPillShowsOnlyWhileRecordingAwayFromCapture() {
        XCTAssertTrue(RecordingPillState.visible(recordingActive: true, onCaptureTab: false))
        XCTAssertFalse(RecordingPillState.visible(recordingActive: true, onCaptureTab: true),
                       "the capture page IS the instrument — no pill on top of it")
        XCTAssertFalse(RecordingPillState.visible(recordingActive: false, onCaptureTab: false))
    }

    // Scenario: the ring follows the conversation / goes nearly still when paused
    func testRingEnergyFollowsMeterAndPause() {
        XCTAssertEqual(RecordingRingModel.energy(meterLevel: 0.8, paused: true), 0.03,
                       accuracy: 0.001, "paused = a near-still shimmer, not dead")
        XCTAssertGreaterThan(RecordingRingModel.energy(meterLevel: 0.8, paused: false),
                             RecordingRingModel.energy(meterLevel: 0.1, paused: false))
        XCTAssertLessThanOrEqual(RecordingRingModel.energy(meterLevel: 2.0, paused: false), 1.0)
    }

    // A conversation never completes: order stays put mid-band while recording.
    func testRingOrderNeverCompletesWhileRecording() {
        XCTAssertEqual(RecordingRingModel.order, 0.35, accuracy: 0.001)
    }
}
