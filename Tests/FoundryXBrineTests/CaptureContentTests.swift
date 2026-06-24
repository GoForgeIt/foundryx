import XCTest
import Foundation
@testable import FoundryXKit

/// Phase B wire contract: the door's `GET /foundryx/capture/{id}/content` reply
/// (`{transcript, capturedAt, found}`) decodes into `CaptureContent`, and the
/// not-yet-transcribed sentinel (the door 404s) is represented as found:false.
final class CaptureContentTests: XCTestCase {

    func testDecodesTranscriptReply() throws {
        let json = Data(#"{"transcript":"hello there world","capturedAt":222,"found":true}"#.utf8)
        let c = try JSONDecoder().decode(CaptureContent.self, from: json)
        XCTAssertEqual(c.transcript, "hello there world")
        XCTAssertEqual(c.capturedAt, 222)
        XCTAssertTrue(c.found)
    }

    func testNotReadySentinelIsFoundFalse() {
        // What captureContent(_:) returns on a 404 — a "still processing" state,
        // not an error: empty transcript + found:false.
        let notReady = CaptureContent(transcript: "", capturedAt: 0, found: false)
        XCTAssertFalse(notReady.found)
        XCTAssertTrue(notReady.transcript.isEmpty)
    }
}
