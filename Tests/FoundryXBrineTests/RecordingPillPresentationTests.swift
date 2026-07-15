import XCTest
@testable import FoundryXKit

final class RecordingPillPresentationTests: XCTestCase {
    func testIdlePresentsListening() {
        let presentation = RecordingPillPresentation.make(from: .idle)

        XCTAssertEqual(presentation.word, "Listening")
        XCTAssertEqual(presentation.tone, .neutral)
    }

    func testRecordingActivePresentsRecording() {
        let presentation = RecordingPillPresentation.make(from: .recordingActive)

        XCTAssertEqual(presentation.word, "Recording")
        XCTAssertEqual(presentation.tone, .recording)
    }

    func testPausedPresentsPaused() {
        let presentation = RecordingPillPresentation.make(from: .paused)

        XCTAssertEqual(presentation.word, "Paused")
        XCTAssertEqual(presentation.tone, .paused)
    }
}
