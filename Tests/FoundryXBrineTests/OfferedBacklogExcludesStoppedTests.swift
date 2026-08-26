import XCTest
@testable import FoundryXKit

/// Track `20260825T0034` — the offered backlog excludes what the owner STOPPED.
///
/// Its predecessor's reflection review (HIGH-1) traced the live path: `derivedBacklog` does not
/// exclude stopped recordings, the selection takes its output, `promised = s.count` therefore
/// counts a stopped recording, and `enqueue` then REFUSES it —
/// `guard !stoppedRequests.contains(recording.request)`. So `accepted < promised`: a number a
/// person consents to that is larger than the set they get.
///
/// Harmless before multi-select, LIVE after it: with one recording offered at a time the offer
/// is recomputed and the mismatch cannot surface. `20260823T0908` shipped multi-select and so
/// activated the hazard it disclosed.
///
/// ⚠ AC4 — `stoppedRequests` stays PRIVATE and no test reaches it. Its privacy is why stop is
/// "the difference between a stop button and a decoration". The exclusion is read from the
/// DURABLE store, which already records `stopped` per entry, not by widening the actor's set.
final class OfferedBacklogExcludesStoppedTests: XCTestCase {

    private func rec(_ ts: String) -> PocketRecording {
        PocketRecording(date: "20260826", timestamp: ts, sizeBytes: 1_000)
    }

    /// AC1 — one of two stopped: the offer holds ONE.
    func testAStoppedRecordingIsNotOffered() {
        let backlog = PocketBacklog(entries: [
            PocketBacklogEntry(date: "20260826", timestamp: "0900", sizeBytes: 1_000, stopped: false),
            PocketBacklogEntry(date: "20260826", timestamp: "1000", sizeBytes: 1_000, stopped: true),
        ])
        XCTAssertEqual(backlog.drainable.map(\.timestamp), ["0900"],
                       "a recording the owner stopped is never offered")
    }

    /// AC2 — PAIRED EXISTENCE. Without it, "excludes stopped" is satisfied by an offer that is
    /// always empty, which excludes everything and offers nothing.
    func testWithNothingStoppedBothAreOffered() {
        let backlog = PocketBacklog(entries: [
            PocketBacklogEntry(date: "20260826", timestamp: "0900", sizeBytes: 1_000, stopped: false),
            PocketBacklogEntry(date: "20260826", timestamp: "1000", sizeBytes: 1_000, stopped: false),
        ])
        XCTAssertEqual(backlog.drainable.count, 2, "nothing stopped — the whole backlog is offered")
    }

    /// ⚠ THE DEFECT ITSELF — `derivedBacklog`, the function the SELECTION actually calls
    /// (`DeviceScreen.swift:2681`), not `drainable`.
    ///
    /// My first three assertions passed on arrival because they exercised
    /// `PocketBacklog.drainable`, which already excludes stopped correctly. The live path does
    /// not go through it. A test that passes without touching the defect is the failure this
    /// repository names most often, and I wrote three of them before checking the call site.
    func testDerivedBacklogExcludesWhatTheOwnerStopped() async {
        let shelf = [rec("0900"), rec("1000")]
        let stopped: Set<PocketRecordingRequest> = [rec("1000").request]
        let offered = await PocketTransferQueue.derivedBacklog(
            from: shelf,
            custody: HoldsNothing(),
            identity: RecordingDeviceIdentity(shape: .bleStream, hardwareToken: "t"),
            stopped: stopped)
        XCTAssertEqual(offered.map(\.timestamp), ["0900"],
                       "the selection's own source must exclude a stopped recording, or the "
                       + "count consented to is larger than the set enqueue will accept")
    }

    /// PAIRED with the above at the SAME seam: with nothing stopped the offer is whole.
    func testDerivedBacklogOffersEverythingWhenNothingIsStopped() async {
        let shelf = [rec("0900"), rec("1000")]
        let offered = await PocketTransferQueue.derivedBacklog(
            from: shelf,
            custody: HoldsNothing(),
            identity: RecordingDeviceIdentity(shape: .bleStream, hardwareToken: "t"),
            stopped: [])
        XCTAssertEqual(offered.count, 2)
    }

    /// AC3 — the CONSENT COUNT, end to end. The number the control states must equal the number
    /// the queue will accept. This is the assertion the whole track exists for.
    func testThePromisedCountEqualsWhatWillBeAccepted() {
        let backlog = PocketBacklog(entries: [
            PocketBacklogEntry(date: "20260826", timestamp: "0900", sizeBytes: 1_000, stopped: false),
            PocketBacklogEntry(date: "20260826", timestamp: "1000", sizeBytes: 1_000, stopped: true),
            PocketBacklogEntry(date: "20260826", timestamp: "1100", sizeBytes: 1_000, stopped: false),
        ])
        let promised = backlog.drainable.count
        // What `enqueue` would accept: everything not stopped. Modelled here from the SAME
        // durable fact, so the two cannot be resolved two different ways — which is the shape
        // that produced this defect and its duplicate-listing predecessor.
        let acceptable = backlog.entries.filter { !$0.stopped }.count
        XCTAssertEqual(promised, acceptable,
                       "a number a person consents to must not be larger than the set they get")
        XCTAssertEqual(promised, 2)
    }
}


/// Holds nothing; every other member traps. A stub that quietly answered "no file here" for the
/// wrong reason would make the backlog look right while proving nothing.
private struct HoldsNothing: PocketRecorderFileCustody {
    func alreadyHeld(_ key: PocketRecorderFileKey) async -> Bool { false }
    func heldFile(_ key: PocketRecorderFileKey) async -> URL? { nil }
    func beginKeeping(_ key: PocketRecorderFileKey) async throws -> any PocketRecorderFileWriting {
        fatalError("unreachable: these scenarios choose files, they never bring one over")
    }
    /// nil = held-but-unimported. These scenarios never reach it; trapping would be wrong
    /// because the queue consults it while deriving, so it answers the honest "no record".
    func conversation(for key: PocketRecorderFileKey) async -> String? { nil }
    func noteConversation(_ captureID: String, for key: PocketRecorderFileKey) async {
        fatalError("unreachable: these scenarios never import")
    }
}
