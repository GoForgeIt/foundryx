// The recorder must offer the NEXT recording, not the same one forever.
//
// `PocketBringOver.offered(_:)` is ordering ONLY. Ordering alone is stable, so bringing a
// file over and re-reading the shelf re-elects the same winner: nothing subtracts what is
// already held. A person with a backlog could bring over exactly one recording per recorder,
// for the life of the device, paying a Bluetooth handshake each time to be handed the file
// they already have.
//
// These tests pin the subtraction. The ordering itself is not re-asserted here — it has its
// own coverage, and a second spelling of the comparator would drift from the shipped one.

import XCTest
@testable import FoundryXKit

final class PocketOffersTheNextRecordingTests: XCTestCase {

    /// THE ONE THAT MATTERS. Under the shipped code the second call returns the SAME
    /// recording, which is the bug.
    func testAfterBringingOneOverTheShelfOffersADifferentOne() {
        let shelf = [
            PocketRecording(date: "2026-08-14", timestamp: "PH260814090000", sizeBytes: 40_000),
            PocketRecording(date: "2026-08-14", timestamp: "PH260814100000", sizeBytes: 80_000),
            PocketRecording(date: "2026-08-14", timestamp: "PH260814110000", sizeBytes: 120_000),
        ]
        guard let first = PocketBringOver.offered(shelf) else {
            return XCTFail("an empty offer from a three-file shelf")
        }
        guard let second = PocketBringOver.offered(shelf, excluding: [first.request]) else {
            return XCTFail("the shelf still holds two files it has never been asked for")
        }
        XCTAssertNotEqual(
            second.request, first.request,
            "re-offering the file the owner just brought over costs a Bluetooth session to "
            + "hand them what they already have")
    }

    /// Draining the whole shelf must terminate, and must not skip anything on the way.
    func testEveryRecordingIsOfferedExactlyOnceUntilTheShelfIsDry() {
        let shelf = (0..<5).map {
            PocketRecording(date: "2026-08-14",
                            timestamp: "PH26081409000\($0)",
                            sizeBytes: 40_000 * ($0 + 1))
        }
        var held: Set<PocketRecordingRequest> = []
        var seen: [PocketRecordingRequest] = []
        while let next = PocketBringOver.offered(shelf, excluding: held) {
            XCTAssertFalse(held.contains(next.request), "offered a file it had already held")
            held.insert(next.request)
            seen.append(next.request)
            if seen.count > shelf.count { return XCTFail("the drain did not terminate") }
        }
        XCTAssertEqual(seen.count, shelf.count, "every file must get its turn")
        XCTAssertEqual(Set(seen).count, shelf.count, "and only one turn each")
    }

    /// A shelf whose every file is already here offers nothing — the honest answer, and the
    /// one that lets the surface say "everything is over" instead of proposing a re-pull.
    func testAFullyDrainedShelfOffersNothing() {
        let shelf = [
            PocketRecording(date: "2026-08-14", timestamp: "PH260814090000", sizeBytes: 40_000),
            PocketRecording(date: "2026-08-14", timestamp: "PH260814100000", sizeBytes: 80_000),
        ]
        let all = Set(shelf.map(\.request))
        XCTAssertNil(PocketBringOver.offered(shelf, excluding: all))
    }

    /// The exclusion key is the recorder's own name for the file. A file whose SIZE changed
    /// between listings is the same slot — re-offering it because a byte count moved would
    /// re-pull a recording the owner already has.
    func testASizeChangeDoesNotResurrectAHeldRecording() {
        let held = PocketRecording(date: "2026-08-14", timestamp: "PH260814090000", sizeBytes: 40_000)
        let relisted = PocketRecording(date: "2026-08-14", timestamp: "PH260814090000", sizeBytes: 41_000)
        XCTAssertNil(
            PocketBringOver.offered([relisted], excluding: [held.request]),
            "same date + timestamp is the same file on the recorder")
    }

    /// The async form must consult custody rather than an index of its own.
    func testTheAsyncFormSkipsWhatCustodyAlreadyHolds() async {
        let shelf = [
            PocketRecording(date: "2026-08-14", timestamp: "PH260814090000", sizeBytes: 40_000),
            PocketRecording(date: "2026-08-14", timestamp: "PH260814100000", sizeBytes: 80_000),
        ]
        let identity = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "test")
        let custody = HoldsTheSmallestCustody(holding: shelf[0].request)

        let next = await PocketBringOver.offeredNext(shelf, custody: custody, identity: identity)
        XCTAssertEqual(next?.request, shelf[1].request,
                       "the smallest is already here; the next one is what is left")
    }

    /// **THE STRAND, AND WHY IT COST A RECORDING FOREVER.**
    ///
    /// `alreadyHeld` is a bare `fileExists` and says nothing about whether a conversation was
    /// ever made. A pull that wrote the bytes and then failed to import left the audio on the
    /// phone with no conversation — and `offeredNext` excluded it on the bytes alone, so the
    /// shelf never offered it again and the retry (`run()` re-imports off the held file with no
    /// radio time) could not be reached.
    func testARecordingHeldButNeverImportedIsOfferedAgain() async {
        let shelf = [
            PocketRecording(date: "2026-08-14", timestamp: "PH260814090000", sizeBytes: 40_000),
            PocketRecording(date: "2026-08-14", timestamp: "PH260814100000", sizeBytes: 80_000),
        ]
        let identity = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "test")
        // bytes on disk, no conversation
        let custody = HoldsTheSmallestCustody(holding: shelf[0].request, importedToo: false)

        let next = await PocketBringOver.offeredNext(shelf, custody: custody, identity: identity)
        XCTAssertEqual(next?.request, shelf[0].request,
                       "a recording whose bytes are held but which never became a conversation "
                           + "was not offered again — it is stranded on the phone forever")
    }

    /// **THE PAIRED POSITIVE.** Without it, "offer the stranded one" is satisfied by "offer
    /// everything always", which would send the owner back to the recorder for files already
    /// safely imported.
    func testARecordingThatIsAlreadyAConversationIsNotOfferedAgain() async {
        let shelf = [
            PocketRecording(date: "2026-08-14", timestamp: "PH260814090000", sizeBytes: 40_000),
        ]
        let identity = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "test")
        // bytes AND a conversation
        let custody = HoldsTheSmallestCustody(holding: shelf[0].request, importedToo: true)

        let next = await PocketBringOver.offeredNext(shelf, custody: custody, identity: identity)
        XCTAssertNil(next,
                     "a recording that is already a conversation was offered again — the owner "
                         + "is being sent back to the recorder for something already here")
    }
}

/// Answers `alreadyHeld` yes for exactly one slot. Every other member is unreachable in these
/// tests and traps rather than returning a plausible default — a custody stub that quietly
/// answers "no file here" would make a bring-over test pass while proving nothing.
private struct HoldsTheSmallestCustody: PocketRecorderFileCustody {
    init(holding: PocketRecordingRequest, importedToo: Bool = true) {
        self.holding = holding
        self.importedToo = importedToo
    }

    let holding: PocketRecordingRequest

    func alreadyHeld(_ key: PocketRecorderFileKey) async -> Bool {
        key.date == holding.date && key.timestamp == holding.timestamp
    }
    func heldFile(_ key: PocketRecorderFileKey) async -> URL? { nil }
    func beginKeeping(_ key: PocketRecorderFileKey) async throws -> any PocketRecorderFileWriting {
        fatalError("unreachable: these tests choose a file, they never bring one over")
    }
    /// WHETHER THE HELD SLOT IS ALSO A CONVERSATION. This used to answer `nil` unconditionally,
    /// which quietly modelled a HELD-BUT-UNIMPORTED recording — the strand case — while the test
    /// above asserted such a recording is skipped. That assertion encoded the defect.
    let importedToo: Bool
    func conversation(for key: PocketRecorderFileKey) async -> String? {
        guard importedToo, key.date == holding.date, key.timestamp == holding.timestamp else {
            return nil
        }
        return "capture-for-\(holding.timestamp)"
    }
    func noteConversation(_ captureID: String, for key: PocketRecorderFileKey) async {
        fatalError("unreachable: nothing here imports a conversation")
    }
}
