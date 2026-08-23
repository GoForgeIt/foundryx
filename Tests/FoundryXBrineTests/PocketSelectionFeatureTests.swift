import XCTest
@testable import FoundryXKit

/// **The owner picks which recordings come over, and in what order.**
///
/// This is P6's item B, the piece its predecessor track
/// (`20260816T2154_pocket_recorder_offers_the_next_recording`) deliberately did not close on —
/// it sits at `reflection_review` rather than `completed` for exactly this reason.
///
/// The drain machinery already existed: `PocketTransferJob.enqueue` preserves the caller's array
/// order, dedupes on `request`, and refuses a recording the owner stopped. What did not exist was
/// any record of **what the owner picked** — `selectedRecordings` and `multiSelect` appeared in
/// zero files across `Sources` and `App`.
final class PocketSelectionFeatureTests: XCTestCase {

    private func rec(_ name: String, bytes: Int = 40_000) -> PocketRecording {
        PocketRecording(date: "2026-08-23", timestamp: name, sizeBytes: bytes)
    }

    // MARK: - AC1 — order is the order they were picked

    func testTheSelectionIsOrderedByWhenItWasPickedNotByTheListing() {
        let a = rec("A"), b = rec("B"), c = rec("C")
        // The recorder lists A, B, C. The owner taps C, A, B.
        var s = PocketSelection(selectable: [a, b, c])
        s.select(c.request); s.select(a.request); s.select(b.request)

        XCTAssertEqual(s.picked, [c.request, a.request, b.request],
                       "the owner tapped C, A, B — the listing's order is the device's opinion, "
                           + "not theirs")
        XCTAssertEqual(s.orderedRecordings.map(\.timestamp), ["C", "A", "B"],
                       "the recordings handed to the queue must be in the owner's order")
    }

    // MARK: - AC2 — deselect disturbs nobody else

    func testDeselectingOneLeavesEveryOtherPositionAlone() {
        let a = rec("A"), b = rec("B"), c = rec("C")
        var s = PocketSelection(selectable: [a, b, c])
        s.select(c.request); s.select(a.request); s.select(b.request)

        s.deselect(a.request)

        XCTAssertEqual(s.picked, [c.request, b.request],
                       "removing A must not reshuffle C and B")
        XCTAssertEqual(s.picked.first, c.request, "C was picked first and is still first")
    }

    // MARK: - AC3 — re-selecting goes to the END, and that is a decision not a bug

    func testReselectingPutsARecordingAtTheEndBecauseItIsANewDecision() {
        let a = rec("A"), b = rec("B"), c = rec("C")
        var s = PocketSelection(selectable: [a, b, c])
        s.select(c.request); s.select(a.request); s.select(b.request)
        s.deselect(a.request)

        s.select(a.request)

        XCTAssertEqual(s.picked, [c.request, b.request, a.request],
                       "an owner who changed their mind is making a NEW decision. Restoring A to "
                           + "index 1 would tell them they wanted it second when what they said "
                           + "was they want it now.")
    }

    // MARK: - AC4 — one tap, one selection

    func testPickingTheSameRecordingTwiceIsOneSelectionAndChangesNoOrder() {
        let a = rec("A"), b = rec("B")
        var s = PocketSelection(selectable: [a, b])
        s.select(a.request); s.select(b.request)
        let before = s.picked

        s.select(a.request)

        XCTAssertEqual(s.picked, before,
                       "a second tap on A is not a second copy of A — `enqueue` dedupes on "
                           + "`request` and a selection that counted differently is the consent "
                           + "defect this file exists for")
        XCTAssertEqual(s.count, 2)
    }

    // MARK: - AC5 — PAIRED. Selectable and not-selectable.

    func testOnlyRecordingsInTheSuppliedListCanBePicked() {
        let offered = rec("OFFERED")
        let held = rec("ALREADY-HELD")
        // The selectable list is what `derivedBacklog` returned: it already excluded anything held
        // that also has a conversation, so `held` is simply absent from it.
        var s = PocketSelection(selectable: [offered])

        s.select(held.request)
        XCTAssertEqual(s.picked, [],
                       "a recording that is not on offer cannot be picked")

        // THE PAIRED HALF, and it is the point: without it, "rejects what is not offered" is
        // satisfied perfectly by a selection that rejects everything.
        s.select(offered.request)
        XCTAssertEqual(s.picked, [offered.request],
                       "and one that IS on offer must be pickable — otherwise the assertion above "
                           + "passes on a selection that accepts nothing")
    }

    // MARK: - AC6 — PAIRED, through the input rather than through private state

    func testAStoppedRecordingIsAbsentFromTheOfferAndReturnsWhenItIsAllowedAgain() {
        let a = rec("A"), stopped = rec("STOPPED")

        // `stoppedRequests` is private to PocketTransferJob and stays that way, so this is modelled
        // where the owner actually experiences it: the offer they are shown.
        var whileStopped = PocketSelection(selectable: [a])
        whileStopped.select(stopped.request)
        XCTAssertEqual(whileStopped.picked, [], "a stopped recording is not on offer")

        var afterAllowAgain = PocketSelection(selectable: [a, stopped])
        afterAllowAgain.select(stopped.request)
        XCTAssertEqual(afterAllowAgain.picked, [stopped.request],
                       "after allowAgain it is offered once more — without this half, \"excludes "
                           + "stopped\" is satisfied by excluding everything")
    }

    // MARK: - AC7 — THE CONSENT COUNT, from two independent sources

    /// **The number a person consents to must equal the number that is taken.**
    ///
    /// `derivedBacklog`'s own comment records what happens when it does not: *"the button said
    /// "Bring all 2 over" and the queue took one: a number a person consents to that is larger than
    /// the set."*
    ///
    /// ⚠ THE TWO NUMBERS COME FROM DIFFERENT OBJECTS ON PURPOSE. The promised count is read off the
    /// SELECTION; the accepted count is read off the JOB after `enqueue`. Reading both off the
    /// selection would make this `n == n` — the consent defect rebuilt inside the assertion written
    /// to catch it.
    func testThePromisedCountEqualsTheCountTheQueueAccepts() async {
        let a = rec("A"), b = rec("B"), c = rec("C")
        var s = PocketSelection(selectable: [a, b, c])
        s.select(c.request); s.select(a.request)
        s.select(a.request)          // a duplicate tap, which must not inflate the promise

        let promised = s.count                       // source 1: the selection

        let job = PocketTransferQueue(peripheralIdentifier: UUID(), advertisedName: "test-recorder")
        await job.enqueue(s.orderedRecordings)
        let accepted = await job.items.count       // source 2: the queue

        XCTAssertEqual(promised, 2, "two distinct recordings were picked")
        XCTAssertEqual(accepted, promised,
                       "the queue accepted \(accepted) of a promised \(promised). A count a person "
                           + "consents to that is larger than the set is the defect this asserts "
                           + "against.")
    }

    // MARK: - AC8 — the queue drains in the owner's order

    func testTheQueueTakesTheRecordingsInTheOwnersOrder() async {
        let a = rec("A"), b = rec("B"), c = rec("C")
        var s = PocketSelection(selectable: [a, b, c])
        s.select(c.request); s.select(a.request); s.select(b.request)

        let job = PocketTransferQueue(peripheralIdentifier: UUID(), advertisedName: "test-recorder")
        await job.enqueue(s.orderedRecordings)

        let queued = await job.items.map(\.recording.timestamp)
        XCTAssertEqual(queued, ["C", "A", "B"],
                       "`enqueue` preserves the caller's array order, so the owner's order IS the "
                           + "drain order — this asserts that rather than assuming it")
    }
}
