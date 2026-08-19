import XCTest
@testable import FoundryXKit

/// Unit tests for the pure honest-wait model: copy selection per wait kind and
/// destination, the true-vs-fake progress contract, elapsed-phase thresholds, the
/// determinate count label, and deterministic tip rotation.
///
/// NOTE (cell-tier fix, 2026-08-18): this file used to assert
/// `WaitCopy.make(for: .title, onDevice: false).privacyLine.contains("Mac")` — a test
/// that PINNED the two-way defect in place: `onDevice: false` meant "Mac" for cell
/// owners too. Those assertions are REPLACED (not weakened) by per-destination ones;
/// the cross-destination gate lives in WaitingDestinationGateTests.
final class WaitingExperienceTests: XCTestCase {

    // MARK: - Copy selection per kind

    func testHeadlinesAreNamedPerKind() {
        XCTAssertEqual(WaitCopy.make(for: .recap, destination: .phone).headline, "Summarizing on your iPhone")
        XCTAssertEqual(WaitCopy.make(for: .transcription, destination: .phone).headline, "Transcribing on this iPhone")
        XCTAssertEqual(WaitCopy.make(for: .doorFetch, destination: .computer).headline, "Fetching from your Mac")
        XCTAssertEqual(WaitCopy.make(for: .doorFetch, destination: .vault).headline, "Fetching from your Vault")
        XCTAssertEqual(WaitCopy.make(for: .title, destination: .phone).headline, "Naming this voice note")
    }

    func testTitleAndSyncCopyReflectDestination() {
        // Titling names the brain that is actually reading the transcript.
        XCTAssertTrue(WaitCopy.make(for: .title, destination: .phone).privacyLine.contains("iPhone"))
        XCTAssertTrue(WaitCopy.make(for: .title, destination: .computer).privacyLine.contains("Mac"))
        XCTAssertTrue(WaitCopy.make(for: .title, destination: .vault).privacyLine.contains("Vault"))
        // The sync headline names each destination honestly.
        XCTAssertEqual(WaitCopy.make(for: .sync, destination: .phone).headline, "Catching up")
        XCTAssertEqual(WaitCopy.make(for: .sync, destination: .computer).headline, "Copying to your computer")
        XCTAssertEqual(WaitCopy.make(for: .sync, destination: .vault).headline, "Copying to your Vault")
    }

    func testTranscriptionPrivacyLineIsTruePerDestination() {
        // Phone: the only tier allowed to claim the audio stays in the owner's hands.
        XCTAssertTrue(WaitCopy.make(for: .transcription, destination: .phone)
            .privacyLine.contains("never leaves"))
        // Computer: one speech service, purpose-limited — the PrivacyView sentence, reused.
        XCTAssertTrue(WaitCopy.make(for: .transcription, destination: .computer)
            .privacyLine.contains("one speech service"))
        // Vault: a private machine of the owner's own, one speech service — and NEVER
        // the screenshot's sentence ("the audio never goes to a server we run").
        let vault = WaitCopy.make(for: .transcription, destination: .vault).privacyLine
        XCTAssertTrue(vault.contains("Vault"))
        XCTAssertTrue(vault.contains("one speech service"))
        XCTAssertFalse(vault.contains("never goes to a server"))
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
            for destination in CaptureDestination.allCases {
                let m = WaitingExperienceModel(kind: kind, destination: destination)
                XCTAssertNil(m.progress.fraction, "\(kind) must not show a progress bar")
            }
        }
    }

    // MARK: - Determinate count label

    func testSyncLabelGroupsThousandsAndNamesDestination() {
        let m = WaitingExperienceModel(kind: .sync, destination: .computer,
                                       progress: .determinate(done: 214, total: 1210))
        XCTAssertEqual(m.statusLine(elapsed: 0), "214 of 1,210 segments safely on your computer")

        let phone = WaitingExperienceModel(kind: .sync, destination: .phone,
                                           progress: .determinate(done: 3, total: 8))
        XCTAssertEqual(phone.statusLine(elapsed: 0), "3 of 8 segments saved on your phone")

        let vault = WaitingExperienceModel(kind: .sync, destination: .vault,
                                           progress: .determinate(done: 3, total: 8))
        XCTAssertEqual(vault.statusLine(elapsed: 0), "3 of 8 segments safely in your Vault")
    }

    func testSyncLabelSingularSegment() {
        let m = WaitingExperienceModel(kind: .sync, destination: .computer,
                                       progress: .determinate(done: 0, total: 1))
        XCTAssertEqual(m.statusLine(elapsed: 0), "0 of 1 segment safely on your computer")
    }

    func testSyncLabelClampsOverCount() {
        let m = WaitingExperienceModel(kind: .sync, destination: .computer,
                                       progress: .determinate(done: 1300, total: 1210))
        XCTAssertEqual(m.statusLine(elapsed: 0), "1,210 of 1,210 segments safely on your computer")
    }

    // MARK: - Elapsed phase thresholds

    func testTranscriptionPhaseLadder() {
        let m = WaitingExperienceModel(kind: .transcription, destination: .phone)
        // Before the first rung: the base privacy line stands (no premature "taking long").
        XCTAssertFalse(m.statusLine(elapsed: 5).contains("longer voice notes take longer"))
        // 20s+ admits the honest truth.
        XCTAssertTrue(m.statusLine(elapsed: 20).contains("longer voice notes take longer"))
        // 45s+ escalates to the long-recording phase.
        XCTAssertTrue(m.statusLine(elapsed: 60).contains("this was a long one"))
    }

    func testDoorFetchPhaseIsShortFusedAndNamesItsOwnPlace() {
        let m = WaitingExperienceModel(kind: .doorFetch, destination: .computer)
        XCTAssertNil(WaitPhaseText.phrase(for: .doorFetch, destination: .computer, elapsed: 1))
        XCTAssertEqual(WaitPhaseText.phrase(for: .doorFetch, destination: .computer, elapsed: 3),
                       "Still reaching your Mac — the tunnel may be waking up.")
        XCTAssertTrue(m.statusLine(elapsed: 4).contains("Still reaching your Mac"))
        // The cell tier has NO tunnel and no Mac — its phase names the Vault.
        XCTAssertEqual(WaitPhaseText.phrase(for: .doorFetch, destination: .vault, elapsed: 3),
                       "Still reaching your Vault — it may be waking up.")
    }

    func testRecapAndTitlePhasesAppearOnlyAfterTheirThreshold() {
        XCTAssertNil(WaitPhaseText.phrase(for: .recap, destination: .phone, elapsed: 3))
        XCTAssertNotNil(WaitPhaseText.phrase(for: .recap, destination: .phone, elapsed: 8))
        XCTAssertNil(WaitPhaseText.phrase(for: .title, destination: .phone, elapsed: 3))
        XCTAssertNotNil(WaitPhaseText.phrase(for: .title, destination: .phone, elapsed: 10))
    }

    func testSyncHasNoElapsedPhaseLadder() {
        // Sync is determinate — it must never fall back to elapsed guesswork.
        for destination in CaptureDestination.allCases {
            XCTAssertNil(WaitPhaseText.phrase(for: .sync, destination: destination, elapsed: 999))
        }
    }

    // MARK: - Tip rotation determinism

    func testTipRotationIsDeterministicAndStableAtAMoment() {
        let m = WaitingExperienceModel(kind: .recap, destination: .phone)
        // Same elapsed ⇒ same tip, always.
        XCTAssertEqual(m.tip(elapsed: 0), m.tip(elapsed: 0))
        XCTAssertEqual(m.tip(elapsed: 3.9), m.tip(elapsed: 0)) // same 4s bucket
        // Next bucket rotates to a different tip (deck has > 1 tip).
        XCTAssertNotEqual(m.tip(elapsed: 0), m.tip(elapsed: 4))
    }

    func testRotationIndexFollowsTheFourSecondCadence() {
        let m = WaitingExperienceModel(kind: .recap, destination: .phone)
        XCTAssertEqual(m.rotationIndex(elapsed: 0), 0)
        XCTAssertEqual(m.rotationIndex(elapsed: 3.99), 0)
        XCTAssertEqual(m.rotationIndex(elapsed: 4), 1)
        XCTAssertEqual(m.rotationIndex(elapsed: 8.5), 2)
    }

    func testTipDeckWrapsForAnyIndexIncludingNegative() {
        let deck = WaitingTipDeck(kind: .transcription, destination: .phone)
        XCTAssertFalse(deck.tips.isEmpty)
        XCTAssertEqual(deck.tip(at: deck.count), deck.tip(at: 0))
        XCTAssertEqual(deck.tip(at: -1), deck.tip(at: deck.count - 1))
    }

    func testEveryTipIsUniqueAndNonEmpty() {
        for kind in WaitKind.allCases {
            for destination in CaptureDestination.allCases {
                let deck = WaitingTipDeck(kind: kind, destination: destination)
                XCTAssertEqual(Set(deck.tips.map(\.text)).count, deck.tips.count,
                               "\(kind)/\(destination) deck has duplicate tips")
                XCTAssertFalse(deck.tips.contains { $0.text.isEmpty },
                               "\(kind)/\(destination) has an empty tip")
            }
        }
    }

    // MARK: - Library stat tips

    func testStatTipsAppearOnlyWhenCountsArePresentAndPositive() {
        let none = WaitingTipDeck(kind: .recap, destination: .phone, stats: .none)
        XCTAssertFalse(none.tips.contains { $0.text.contains("captured") })

        let withStats = WaitingTipDeck(kind: .recap, destination: .phone,
                                       stats: .init(conversationCount: 1284, segmentsOnComputer: 9021))
        XCTAssertTrue(withStats.tips.contains { $0.text.contains("1,284 voice notes") },
                      "expected a grouped conversation-count tip")
        XCTAssertTrue(withStats.tips.contains { $0.text.contains("9,021 segments") },
                      "expected a grouped segment-count tip")
    }

    func testZeroStatsProduceNoStatTip() {
        let deck = WaitingTipDeck(kind: .recap, destination: .phone,
                                  stats: .init(conversationCount: 0, segmentsOnComputer: 0))
        XCTAssertFalse(deck.tips.contains { $0.text.contains("captured") })
        XCTAssertFalse(deck.tips.contains { $0.text.contains("counting") })
    }

    func testConversationCountTipIsSingularForOne() {
        let deck = WaitingTipDeck(kind: .recap, destination: .phone,
                                  stats: .init(conversationCount: 1))
        XCTAssertTrue(deck.tips.contains { $0.text.contains("1 voice note so far") })
    }
}
