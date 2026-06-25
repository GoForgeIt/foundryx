import XCTest
@testable import FoundryXKit

/// The conversation list hides recordings that captured NOTHING (0 segments, not
/// streaming) — useless empty cards — while keeping recordings that have real audio,
/// including ones whose upload failed ("socket is not connected"): their segments are on
/// the phone, pending retry, and must not vanish.
final class CaptureVisibilityTests: XCTestCase {
    private func status(segments: Int, streaming: Bool, syncError: String? = nil) -> CaptureStatus {
        CaptureStatus(id: "c", stage: .recording, totalSegments: segments,
                      syncedSegments: 0, bytes: segments * 100, startedAt: Date(),
                      streaming: streaming, lastSyncError: syncError)
    }

    func testEmptyNonStreamingCaptureIsHidden() {
        XCTAssertFalse(CaptureManager.isWorthShowing(status(segments: 0, streaming: false)),
                       "a recording with 0 segments that isn't streaming is useless → hidden")
    }

    func testJustStartedCaptureIsShown() {
        XCTAssertTrue(CaptureManager.isWorthShowing(status(segments: 0, streaming: true)),
                      "a just-started capture (0 segments yet, still streaming) stays visible")
    }

    func testFailedUploadCaptureStaysVisible() {
        // Recorded 12 segments but every upload failed — the audio is real + pending retry.
        XCTAssertTrue(
            CaptureManager.isWorthShowing(status(segments: 12, streaming: false,
                                                 syncError: "The operation couldn’t be completed. Socket is not connected")),
            "a failed-upload recording HAS data (segments on disk) → must not be hidden")
    }

    func testRealCaptureIsShown() {
        XCTAssertTrue(CaptureManager.isWorthShowing(status(segments: 162, streaming: false)),
                      "a normal recording is shown")
    }
}
