import XCTest
@testable import FoundryXKit

/// AC10 — a local deletion is not resurrected by the merge, and a recreated conversation is
/// not suppressed.
///
/// ⚠ THIS NEEDS NO INCARNATION IDENTITY, AND THAT IS A MEASURED CLAIM. AC-C5 was withdrawn
/// because `CaptureManager.newCaptureId()` mints `omi-<stamp>-<uuid8>` — a FRESH uuid every
/// time — so a recreated conversation can never share a tombstoned id. Tombstoning BY
/// captureId is therefore exact. (Corroborating, not the proof: 42,290 envelopes in lore.db,
/// 19,825 tombstoned, zero repeated external ids. The minting code is the proof.)
final class DeletionPrecedenceTests: XCTestCase {

    private func hit(_ id: String) -> ConversationHit {
        ConversationHit(captureId: id, title: "T-\(id)", dateLabel: "2026-08-26", snippet: "s",
                        capturedAt: 100, observedAt: 1_000)
    }

    func testALocallyDeletedConversationIsNotResurrectedByTheRemote() {
        let kept = DeletionPrecedence.apply(
            remote: [hit("omi-a"), hit("omi-b")],
            locallyDeleted: ["omi-a"]
        )
        XCTAssertEqual(kept.map(\.captureId), ["omi-b"],
                       "the remote still holds it, but this phone deleted it — deletion wins")
    }

    /// PAIRED — the arm that keeps the rule from becoming "suppress everything".
    func testAConversationNobodyDeletedSurvives() {
        let kept = DeletionPrecedence.apply(remote: [hit("omi-a")], locallyDeleted: [])
        XCTAssertEqual(kept.map(\.captureId), ["omi-a"])
    }

    /// ⚠ THE ARM AC-C5 WAS SUPPOSED TO BUY. A re-recorded conversation gets a DIFFERENT id
    /// (fresh uuid8), so it is not caught by the tombstone — no incarnation field required.
    func testARecreatedConversationIsNotSuppressedByAnOldTombstone() {
        // ⚠ SAME TIMESTAMP, DIFFERENT UUID — and that is the whole point.
        //
        // The first version of this test used a different DAY as well, so a prefix match would
        // have separated them for the wrong reason and the assertion proved nothing about the
        // uuid. Mutation caught it: matching on a 12-char prefix left all four tests green.
        // These two ids differ ONLY in the uuid8, which is precisely the discriminator AC-C5
        // was going to build and the id scheme already provides.
        let recreated = hit("omi-20260826-101500-ffff9999")
        let kept = DeletionPrecedence.apply(
            remote: [recreated],
            locallyDeleted: ["omi-20260826-101500-aaaa1111"]   // same second, earlier recording
        )
        XCTAssertEqual(kept.map(\.captureId), [recreated.captureId],
                       "a new recording is a new id; an old tombstone must not swallow it")
    }

    /// The invariant the withdrawal of AC-C5 rests on, PINNED so it cannot drift silently.
    func testMintedIdsAreNeverReused() {
        let ids = (0..<500).map { _ in CaptureManager.newCaptureId() }
        XCTAssertEqual(Set(ids).count, ids.count,
                       "capture ids carry a fresh uuid8; reuse would make tombstoning ambiguous "
                       + "and would resurrect the need for incarnation identity")
    }
}
