import XCTest
import Foundation
import FoundryXKit

/// The ephemeral live-transcript buffer must stay bounded during a long CONTINUOUS
/// conversation — the on-device transcribers accumulate finalized text for the life of a
/// conversation, and an unbounded buffer is what fed the build-89/90 main-thread stack
/// overflow. `LiveTranscriptBuffer.boundedTail` is the single shared cap both backends
/// route their `finalizedText` through; the authoritative full transcript is Kiln's.
final class LiveTranscriptBufferTests: XCTestCase {

    /// AC1: a long transcript is capped to the most-recent N words, newest kept.
    func testBoundedTailKeepsAtMostMaxWordsNewestKept() {
        let long = (1...500).map { "w\($0)" }.joined(separator: " ")
        let out = LiveTranscriptBuffer.boundedTail(long, maxWords: 80)
        let words = out.split(separator: " ").map(String.init)

        XCTAssertEqual(words.count, 80, "must cap to exactly maxWords")
        XCTAssertEqual(words.last, "w500", "newest word is retained")
        XCTAssertEqual(words.first, "w421", "oldest kept = count - maxWords + 1")
    }

    /// Text at or under the cap is returned unchanged.
    func testShortTextIsUnchanged() {
        XCTAssertEqual(LiveTranscriptBuffer.boundedTail("hello there", maxWords: 80), "hello there")
        XCTAssertEqual(LiveTranscriptBuffer.boundedTail("", maxWords: 80), "")
    }

    /// AC5: the default retained window is ≥ the ticker's render cap (48) so the visible
    /// preview is never starved by the buffer bound.
    func testDefaultCapIsAtLeastTheRenderCap() {
        XCTAssertGreaterThanOrEqual(LiveTranscriptBuffer.maxRetainedWords, 48)
    }

    /// AC3: simulating a very long continuous conversation (repeated bounded appends, the
    /// SpeechAnalyzer shape) keeps the buffer flat regardless of session length.
    func testRepeatedAppendStaysFlatOverALongSession() {
        var body = ""
        for i in 1...2000 {
            body = LiveTranscriptBuffer.boundedTail(body.isEmpty ? "s\(i)" : body + " s\(i)")
        }
        XCTAssertLessThanOrEqual(body.split(separator: " ").count, LiveTranscriptBuffer.maxRetainedWords)
        XCTAssertTrue(body.hasSuffix("s2000"), "the newest words survive")
    }

    /// AC3 (SFSpeech shape): assigning the whole ever-growing utterance each tick also
    /// stays bounded when passed through the same helper.
    func testWholeUtteranceAssignmentStaysBounded() {
        for n in [10, 100, 1000, 5000] {
            let utterance = (1...n).map { "u\($0)" }.joined(separator: " ")
            let out = LiveTranscriptBuffer.boundedTail(utterance)
            XCTAssertLessThanOrEqual(out.split(separator: " ").count, LiveTranscriptBuffer.maxRetainedWords)
        }
    }
}
