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

    func testDecodesDeepgramParagraphs() throws {
        let json = Data(#"""
        {"transcript":"hello there\n\nnext topic","capturedAt":222,"found":true,
         "paragraphs":[
            {"start":0.0,"end":2.4,"speaker":"0","text":"hello there"},
            {"start":15.1,"end":20.0,"speaker":"0","text":"next topic"}]}
        """#.utf8)

        let c = try JSONDecoder().decode(CaptureContent.self, from: json)

        XCTAssertEqual(c.paragraphs.count, 2)
        XCTAssertEqual(c.paragraphs[0], TranscriptParagraph(start: 0, end: 2.4, speaker: "0", text: "hello there"))
        XCTAssertEqual(c.paragraphs[1].start, 15.1, accuracy: 0.0001)
    }

    func testCachePolicyAdoptsContentWhenOnlySpeakersChange() {
        let segments = [
            TranscriptSegment(seq: 0, startMs: 0, endMs: 900, text: "hello", speaker: "speaker_0"),
        ]
        let cached = CachedTranscript(
            transcript: "hello",
            title: "Chat",
            summary: "Greeting",
            segments: segments,
            speakers: [CaptureSpeaker(slot: "speaker_0", status: .anonymous)],
            fetchedAt: 1)
        let fetched = CaptureContent(
            transcript: "hello",
            capturedAt: 1,
            found: true,
            title: "Chat",
            summary: "Greeting",
            segments: segments,
            speakers: [CaptureSpeaker(slot: "speaker_0", status: .confirmed, name: "Alice")])

        XCTAssertTrue(
            CaptureContentCachePolicy.contentDiffers(fetched, from: cached),
            "a confirm/rename can change only speakers[], and must replace the cached Speaker N label")
    }
}
