import XCTest
import Foundation
import FoundryXKit

/// Door-free tests for the WORD-LEVEL faded-tail rendering (Feature 2). The live
/// transcript decomposes into per-word render segments: finalized words lock in at full
/// opacity, the trailing volatile word(s) are dimmed with the NEWEST word the faintest,
/// and each word snaps to full opacity when the recognizer finalizes it. This is the
/// pure decomposition the `LiveTranscriptTicker` renders; here we assert the opacities
/// and that no words are dropped or duplicated.
final class LiveTranscriptRenderingTests: XCTestCase {

    /// Finalized words render fully opaque; the volatile tail words are dimmed with the
    /// newest (last) word at the floor opacity.
    func testFinalizedWordsAreFullOpacityVolatileTailIsDimmed() {
        let t = LiveTranscript(finalizedText: "hello there", volatileTail: "world")
        let segs = t.renderedSegments(fadeWindow: 3, floorOpacity: 0.35)

        XCTAssertEqual(segs.map(\.text), ["hello", "there", "world"])
        // Finalized words: full opacity, not volatile.
        XCTAssertEqual(segs[0].opacity, 1.0, accuracy: 0.0001)
        XCTAssertEqual(segs[1].opacity, 1.0, accuracy: 0.0001)
        XCTAssertFalse(segs[0].volatile)
        XCTAssertFalse(segs[1].volatile)
        // The single volatile word is the newest → faintest (floor) + marked volatile.
        XCTAssertEqual(segs[2].opacity, 0.35, accuracy: 0.0001)
        XCTAssertTrue(segs[2].volatile)
    }

    /// Within a multi-word volatile tail the NEWEST word is faintest and opacity ramps
    /// UP toward full for the older words (a graduated fade, not a flat dim).
    func testVolatileTailRampsNewestWordFaintest() {
        let t = LiveTranscript(finalizedText: "", volatileTail: "alpha beta gamma")
        let segs = t.renderedSegments(fadeWindow: 3, floorOpacity: 0.4)

        XCTAssertEqual(segs.map(\.text), ["alpha", "beta", "gamma"])
        // gamma (newest) = floor; beta brighter; alpha brighter still.
        XCTAssertEqual(segs[2].opacity, 0.4, accuracy: 0.0001)             // newest → floor
        XCTAssertGreaterThan(segs[1].opacity, segs[2].opacity)            // older = brighter
        XCTAssertGreaterThan(segs[0].opacity, segs[1].opacity)
        XCTAssertLessThanOrEqual(segs[0].opacity, 1.0)
        segs.forEach { XCTAssertTrue($0.volatile) }
    }

    /// Words OLDER than the fade window stay fully opaque (only the most-recent few fade).
    func testVolatileWordsBeyondTheWindowAreFullOpacity() {
        let t = LiveTranscript(finalizedText: "", volatileTail: "one two three four five")
        let segs = t.renderedSegments(fadeWindow: 3, floorOpacity: 0.35)

        // five (newest) faint; four/three brighter; two/one beyond the 3-word window → 1.0.
        XCTAssertEqual(segs[4].opacity, 0.35, accuracy: 0.0001)
        XCTAssertLessThan(segs[3].opacity, 1.0)
        XCTAssertLessThan(segs[2].opacity, 1.0)
        XCTAssertEqual(segs[1].opacity, 1.0, accuracy: 0.0001)
        XCTAssertEqual(segs[0].opacity, 1.0, accuracy: 0.0001)
    }

    /// When the volatile tail empties (the recognizer finalized everything) ALL words
    /// lock in at full opacity — the "snap to full when it finalizes" behavior (AC2).
    func testEmptyVolatileTailLocksEverythingIn() {
        let t = LiveTranscript(finalizedText: "kiln is the engine", volatileTail: "")
        let segs = t.renderedSegments()

        XCTAssertEqual(segs.count, 4)
        segs.forEach {
            XCTAssertEqual($0.opacity, 1.0, accuracy: 0.0001)
            XCTAssertFalse($0.volatile)
        }
    }

    /// The rendered segments reconstruct the display text exactly — no words dropped,
    /// reordered, or duplicated (AC2).
    func testSegmentsReconstructDisplayText() {
        for t in [
            LiveTranscript(finalizedText: "hello there", volatileTail: "world now"),
            LiveTranscript(finalizedText: "", volatileTail: "just volatile words"),
            LiveTranscript(finalizedText: "only finalized text", volatileTail: ""),
            LiveTranscript(finalizedText: "Kiln", volatileTail: ""),
        ] {
            let joined = t.renderedSegments().map(\.text).joined(separator: " ")
            XCTAssertEqual(joined, t.displayText, "segments must reconstruct the display text")
        }
    }

    /// An empty transcript yields no segments (nothing to render).
    func testEmptyTranscriptHasNoSegments() {
        XCTAssertTrue(LiveTranscript.empty.renderedSegments().isEmpty)
    }

    /// A LONG continuous conversation must not produce an unbounded segment list: the
    /// live ticker only shows ~2 lines, and folding one `Text` per word into a
    /// `ConcatenatedTextStorage` overflows the main-thread stack past a few hundred words
    /// (the build-89/90 crash). `maxWords` caps the render to a bounded tail.
    func testLongTranscriptIsCappedToATailWindow() {
        let body = (1...1200).map { "word\($0)" }.joined(separator: " ")
        let t = LiveTranscript(finalizedText: body, volatileTail: "settling now")
        let segs = t.renderedSegments(maxWords: 48)

        XCTAssertLessThanOrEqual(segs.count, 48, "render must be bounded regardless of length")
        // The cap keeps the NEWEST words (the tail), including the volatile ones.
        XCTAssertEqual(segs.suffix(2).map(\.text), ["settling", "now"])
        XCTAssertTrue(segs.last?.volatile ?? false)
    }

    /// Without a cap (or with a cap larger than the content) behavior is unchanged —
    /// existing callers/tests keep their full segment list.
    func testUncappedRenderIsUnchanged() {
        let t = LiveTranscript(finalizedText: "hello there", volatileTail: "world")
        XCTAssertEqual(t.renderedSegments().count, 3)
        XCTAssertEqual(t.renderedSegments(maxWords: 100).count, 3)
    }
}
