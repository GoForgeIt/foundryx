import XCTest
@testable import FoundryXKit

/// Unit tests for the empty/near-silent/filler filter that hides useless conversation
/// cards from the list (track 20260628T1654; Omi empty-conversation gates). Data is
/// never deleted — these decide what RENDERS.
final class ConversationContentFilterTests: XCTestCase {

    func testEmptyOrWhitespaceIsHidden() {
        XCTAssertFalse(ConversationContentFilter.isMeaningful(transcript: nil))
        XCTAssertFalse(ConversationContentFilter.isMeaningful(transcript: ""))
        XCTAssertFalse(ConversationContentFilter.isMeaningful(transcript: "   \n\t "))
    }

    func testPureFillerIsHidden() {
        for filler in ["Thank you", "Thank you.", "thanks for watching", "Okay", "okay.",
                       "you", ".", "...", "but", "So so", "uh, um", "yeah"] {
            XCTAssertFalse(ConversationContentFilter.isMeaningful(transcript: filler),
                           "near-silent filler \"\(filler)\" must be hidden")
        }
    }

    func testRealConversationIsShown() {
        XCTAssertTrue(ConversationContentFilter.isMeaningful(
            transcript: "Let's discuss the quarterly budget plan tomorrow morning."))
        XCTAssertTrue(ConversationContentFilter.isMeaningful(
            transcript: "grab milk and bread on the way home"))
    }

    /// Omi's "higher bar for short clips": a single meaningful word is dropped when the
    /// clip is short, but kept when the conversation was long (real speech under-captured).
    func testSparseContentGatedByDuration() {
        XCTAssertFalse(ConversationContentFilter.isMeaningful(transcript: "umm, basketball",
                                                             durationSeconds: 4),
                       "one content word in a 4s clip → noise, hidden")
        XCTAssertTrue(ConversationContentFilter.isMeaningful(transcript: "umm, basketball",
                                                            durationSeconds: 600),
                      "one content word in a 10-minute conversation → keep (under-captured)")
        XCTAssertTrue(ConversationContentFilter.isMeaningful(transcript: "umm, basketball",
                                                            durationSeconds: nil),
                      "unknown duration is lenient")
    }
}
