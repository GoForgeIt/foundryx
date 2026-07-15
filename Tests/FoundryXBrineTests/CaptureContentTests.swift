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

    /// FIX 1: an inferred→confirmed rename leaves the transcript AND the segment count
    /// untouched — only the speaker slot's status/name change. Comparing transcript +
    /// segment count alone would discard the fresh confirm; the speaker comparison must
    /// still report a difference so the confirmed label re-renders on every matching turn.
    func testCachePolicyAdoptsInferredToConfirmedRename() {
        let segments = [
            TranscriptSegment(seq: 0, startMs: 0, endMs: 900, text: "hello", speaker: "speaker_0"),
            TranscriptSegment(seq: 1, startMs: 900, endMs: 1800, text: "again", speaker: "speaker_0"),
        ]
        let cached = CachedTranscript(
            transcript: "hello again", title: "Chat", summary: "Greeting",
            segments: segments,
            speakers: [CaptureSpeaker(slot: "speaker_0", status: .inferred, name: "Bob", inferScore: 0.71)],
            fetchedAt: 1)
        // Same transcript, same segment COUNT — only the speaker flips inferred→confirmed.
        let fetched = CaptureContent(
            transcript: "hello again", capturedAt: 1, found: true,
            title: "Chat", summary: "Greeting", segments: segments,
            speakers: [CaptureSpeaker(slot: "speaker_0", status: .confirmed, name: "Bob",
                                      confirmedSpeakerId: "spk-42")])

        XCTAssertEqual(fetched.segments.count, cached.segments.count,
                       "the confirm must not change the transcript shape")
        XCTAssertTrue(
            CaptureContentCachePolicy.contentDiffers(fetched, from: cached),
            "a bare inferred→confirmed confirm changes only the speaker slot and must be adopted")
    }

    /// The gate must NOT over-fire: identical content (same transcript, segments, and
    /// speakers) is not a difference, so the background refresh doesn't churn the cache.
    func testCachePolicyIgnoresIdenticalContent() {
        let segments = [
            TranscriptSegment(seq: 0, startMs: 0, endMs: 900, text: "hello", speaker: "speaker_0"),
        ]
        let speakers = [CaptureSpeaker(slot: "speaker_0", status: .confirmed, name: "Alice")]
        let cached = CachedTranscript(
            transcript: "hello", title: "Chat", summary: "Greeting",
            segments: segments, speakers: speakers, fetchedAt: 1)
        let fetched = CaptureContent(
            transcript: "hello", capturedAt: 1, found: true,
            title: "Chat", summary: "Greeting", segments: segments, speakers: speakers)

        XCTAssertFalse(
            CaptureContentCachePolicy.contentDiffers(fetched, from: cached),
            "identical content must not report a difference")
    }
}
