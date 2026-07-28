import XCTest
@testable import FoundryXKit

/// Unit tests for the pure honest-wait model: copy selection per wait kind, the
/// true-vs-fake progress contract, elapsed-phase thresholds, the determinate count
/// label, and deterministic tip rotation.
final class WaitingExperienceTests: XCTestCase {

    // MARK: - Copy selection per kind

    func testHeadlinesAreNamedPerKind() {
        XCTAssertEqual(WaitCopy.make(for: .recap, onDevice: true).headline, "Summarizing on your iPhone")
        XCTAssertEqual(WaitCopy.make(for: .transcription, onDevice: true).headline, "Transcribing locally")
        XCTAssertEqual(WaitCopy.make(for: .doorFetch, onDevice: false).headline, "Fetching from your Mac")
        XCTAssertEqual(WaitCopy.make(for: .title, onDevice: true).headline, "Naming this voice note")
    }

    func testTitleAndSyncCopyReflectTier() {
        // Titling: on-device says iPhone, computer tier says Mac — never the wrong one.
        XCTAssertTrue(WaitCopy.make(for: .title, onDevice: true).privacyLine.contains("iPhone"))
        XCTAssertTrue(WaitCopy.make(for: .title, onDevice: false).privacyLine.contains("Mac"))
        // Sync headline differs by tier but is honest in both.
        XCTAssertEqual(WaitCopy.make(for: .sync, onDevice: true).headline, "Catching up")
        XCTAssertEqual(WaitCopy.make(for: .sync, onDevice: false).headline, "Copying to your computer")
    }

    // MARK: - Progress contract (true vs fake)

    func testOnlyDeterminateProgressHasAFraction() {
        XCTAssertNil(WaitProgress.indeterminate.fraction)
        XCTAssertEqual(WaitProgress.determinate(done: 214, total: 1210).fraction!,
                       214.0 / 1210.0, accuracy: 0.0001)
    }

    func testDeterminateWithZeroOrNoTotalIsIndeterminate() {
        // A wait that has not measured a total yet must NOT show a (0/0) fake bar.
        XCTAssertNil(WaitProgress.determinate(done: 0, total: 0).fraction)
        XCTAssertFalse(WaitProgress.determinate(done: 0, total: 0).isDeterminate)
    }

    func testFractionIsClampedAndNeverExceedsOne() {
        // Over-count (done > total) can transiently happen; the bar must not overflow.
        XCTAssertEqual(WaitProgress.determinate(done: 1300, total: 1210).fraction!, 1.0, accuracy: 0.0001)
    }

    func testModelWaitsNeverShowAProgressBar() {
        for kind in [WaitKind.recap, .title, .transcription, .doorFetch] {
            let m = WaitingExperienceModel(kind: kind)
            XCTAssertNil(m.progress.fraction, "\(kind) must not show a progress bar")
        }
    }

    // MARK: - Determinate count label

    func testSyncLabelGroupsThousandsAndNamesDestination() {
        let m = WaitingExperienceModel(kind: .sync, onDevice: false,
                                       progress: .determinate(done: 214, total: 1210))
        XCTAssertEqual(m.statusLine(elapsed: 0), "214 of 1,210 segments safely on your computer")

        let phone = WaitingExperienceModel(kind: .sync, onDevice: true,
                                           progress: .determinate(done: 3, total: 8))
        XCTAssertEqual(phone.statusLine(elapsed: 0), "3 of 8 segments saved on your phone")
    }

    func testSyncLabelSingularSegment() {
        let m = WaitingExperienceModel(kind: .sync, onDevice: false,
                                       progress: .determinate(done: 0, total: 1))
        XCTAssertEqual(m.statusLine(elapsed: 0), "0 of 1 segment safely on your computer")
    }

    func testSyncLabelClampsOverCount() {
        let m = WaitingExperienceModel(kind: .sync, onDevice: false,
                                       progress: .determinate(done: 1300, total: 1210))
        XCTAssertEqual(m.statusLine(elapsed: 0), "1,210 of 1,210 segments safely on your computer")
    }

    // MARK: - Elapsed phase thresholds

    func testTranscriptionPhaseLadder() {
        let m = WaitingExperienceModel(kind: .transcription, onDevice: true)
        // Before the first rung: the base privacy line stands (no premature "taking long").
        XCTAssertFalse(m.statusLine(elapsed: 5).contains("longer voice notes take longer"))
        // 20s+ admits the honest truth.
        XCTAssertTrue(m.statusLine(elapsed: 20).contains("longer voice notes take longer"))
        // 45s+ escalates to the long-recording phase.
        XCTAssertTrue(m.statusLine(elapsed: 60).contains("this was a long one"))
    }

    func testDoorFetchPhaseIsShortFused() {
        let m = WaitingExperienceModel(kind: .doorFetch, onDevice: false)
        XCTAssertNil(WaitPhaseText.phrase(for: .doorFetch, elapsed: 1))
        XCTAssertEqual(WaitPhaseText.phrase(for: .doorFetch, elapsed: 3),
                       "Still reaching your Mac — the tunnel may be waking up.")
        XCTAssertTrue(m.statusLine(elapsed: 4).contains("Still reaching your Mac"))
    }

    func testRecapAndTitlePhasesAppearOnlyAfterTheirThreshold() {
        XCTAssertNil(WaitPhaseText.phrase(for: .recap, elapsed: 3))
        XCTAssertNotNil(WaitPhaseText.phrase(for: .recap, elapsed: 8))
        XCTAssertNil(WaitPhaseText.phrase(for: .title, elapsed: 3))
        XCTAssertNotNil(WaitPhaseText.phrase(for: .title, elapsed: 10))
    }

    func testSyncHasNoElapsedPhaseLadder() {
        // Sync is determinate — it must never fall back to elapsed guesswork.
        XCTAssertNil(WaitPhaseText.phrase(for: .sync, elapsed: 999))
    }

    // MARK: - Tip rotation determinism

    func testTipRotationIsDeterministicAndStableAtAMoment() {
        let m = WaitingExperienceModel(kind: .recap)
        // Same elapsed ⇒ same tip, always.
        XCTAssertEqual(m.tip(elapsed: 0), m.tip(elapsed: 0))
        XCTAssertEqual(m.tip(elapsed: 3.9), m.tip(elapsed: 0)) // same 4s bucket
        // Next bucket rotates to a different tip (deck has > 1 tip).
        XCTAssertNotEqual(m.tip(elapsed: 0), m.tip(elapsed: 4))
    }

    func testRotationIndexFollowsTheFourSecondCadence() {
        let m = WaitingExperienceModel(kind: .recap)
        XCTAssertEqual(m.rotationIndex(elapsed: 0), 0)
        XCTAssertEqual(m.rotationIndex(elapsed: 3.99), 0)
        XCTAssertEqual(m.rotationIndex(elapsed: 4), 1)
        XCTAssertEqual(m.rotationIndex(elapsed: 8.5), 2)
    }

    func testTipDeckWrapsForAnyIndexIncludingNegative() {
        let deck = WaitingTipDeck(kind: .transcription, onDevice: true)
        XCTAssertFalse(deck.tips.isEmpty)
        XCTAssertEqual(deck.tip(at: deck.count), deck.tip(at: 0))
        XCTAssertEqual(deck.tip(at: -1), deck.tip(at: deck.count - 1))
    }

    func testEveryTipIsUniqueAndNonEmpty() {
        for kind in WaitKind.allCases {
            let deck = WaitingTipDeck(kind: kind, onDevice: true)
            XCTAssertEqual(Set(deck.tips.map(\.text)).count, deck.tips.count,
                           "\(kind) deck has duplicate tips")
            XCTAssertFalse(deck.tips.contains { $0.text.isEmpty }, "\(kind) has an empty tip")
        }
    }

    // MARK: - Library stat tips

    func testStatTipsAppearOnlyWhenCountsArePresentAndPositive() {
        let none = WaitingTipDeck(kind: .recap, onDevice: true, stats: .none)
        XCTAssertFalse(none.tips.contains { $0.text.contains("captured") })

        let withStats = WaitingTipDeck(kind: .recap, onDevice: true,
                                       stats: .init(conversationCount: 1284, segmentsOnComputer: 9021))
        XCTAssertTrue(withStats.tips.contains { $0.text.contains("1,284 voice notes") },
                      "expected a grouped conversation-count tip")
        XCTAssertTrue(withStats.tips.contains { $0.text.contains("9,021 segments") },
                      "expected a grouped segment-count tip")
    }

    func testZeroStatsProduceNoStatTip() {
        let deck = WaitingTipDeck(kind: .recap, onDevice: true,
                                  stats: .init(conversationCount: 0, segmentsOnComputer: 0))
        XCTAssertFalse(deck.tips.contains { $0.text.contains("captured") })
        XCTAssertFalse(deck.tips.contains { $0.text.contains("counting") })
    }

    func testConversationCountTipIsSingularForOne() {
        let deck = WaitingTipDeck(kind: .recap, onDevice: true,
                                  stats: .init(conversationCount: 1))
        XCTAssertTrue(deck.tips.contains { $0.text.contains("1 voice note so far") })
    }
}
