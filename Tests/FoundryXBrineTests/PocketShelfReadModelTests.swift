// THE SHELF, RESTATED WITHOUT THE RADIO.
//
// `App/DeviceScreen.swift` ended every bring-over by re-running the whole check: a second
// attach, a second key handshake, a second `LIST_DIRS` and a second `LIST&` per day — to learn
// ONE fact this phone's own disk already knew. These hold the two pieces that replace it, in
// the kit where `swift test` can reach them: which files custody is holding, and a panel whose
// custody column moves while everything the RECORDER said stays exactly as the recorder said it.

import XCTest
@testable import FoundryXKit

final class PocketShelfReadModelTests: XCTestCase {

    private let identity = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "unit")

    private func shelf() -> [PocketRecording] {
        [
            PocketRecording(date: "2026-03-28", timestamp: "20260328001919", sizeBytes: 40_000),
            PocketRecording(date: "2026-03-28", timestamp: "20260328002500", sizeBytes: 120_000),
        ]
    }

    /// Put a real file into real custody through the SHIPPED writer, not by touching a path
    /// this test invented — `alreadyHeld` answers about the store's own layout, and a fixture
    /// that guessed at it would be asserting against the guess.
    private func keep(_ key: PocketRecorderFileKey,
                      in custody: PocketRecorderFileStore) async throws {
        let writer = try await custody.beginKeeping(key)
        try writer.write(Data(repeating: 0x41, count: 64))
        _ = try writer.commit()
    }

    private func store() -> PocketRecorderFileStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shelf-read-model-\(UUID().uuidString)", isDirectory: true)
        return PocketRecorderFileStore(root: root)
    }

    /// NOTHING HELD IS NOT A GUESS. An empty answer from a real custody store is the honest
    /// state every row starts in, and it is the one a panel must be able to reach.
    func testAShelfNothingIsHeldFromReportsNothingHeld() async {
        let held = await PocketShelfReadModel.heldFileIDs(shelf(),
                                                          custody: store(),
                                                          identity: identity)
        XCTAssertTrue(held.isEmpty)
    }

    /// THE ONE THAT MATTERS: custody is asked, one file at a time, and only the file that is
    /// actually here comes back.
    func testOnlyTheFileCustodyHoldsComesBack() async throws {
        let custody = store()
        let recordings = shelf()
        let key = PocketRecorderFileKey(identity: identity,
                                        date: recordings[0].date,
                                        timestamp: recordings[0].timestamp)
        try await keep(key, in: custody)
        let held = await PocketShelfReadModel.heldFileIDs(recordings,
                                                          custody: custody,
                                                          identity: identity)
        XCTAssertEqual(held, ["2026-03-28/20260328001919"])
    }

    /// THE IDENTITY IS PART OF THE QUESTION. Two recorders can list the same day and the same
    /// instant; answering "we have it" from another device's custody is how a recording gets
    /// marked delivered and then never fetched.
    func testAnotherRecordersCustodyDoesNotAnswerForThisOne() async throws {
        let custody = store()
        let recordings = shelf()
        let other = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "a-different-unit")
        try await keep(PocketRecorderFileKey(identity: other,
                                            date: recordings[0].date,
                                            timestamp: recordings[0].timestamp),
                       in: custody)
        let held = await PocketShelfReadModel.heldFileIDs(recordings,
                                                          custody: custody,
                                                          identity: identity)
        XCTAssertTrue(held.isEmpty, "one recorder's custody answered for another's shelf")
    }

    /// THE CASE OF THE TOKEN IS PART OF THE ADDRESS, AND THAT IS THE TRAP.
    ///
    /// `PocketAuthenticatedIdentity` LOWERCASES the peripheral identifier
    /// (`PocketOnboarding.swift:17`), so custody writes under the lowercase key — while
    /// `UUID.uuidString` is UPPERCASE. Anything that builds a `RecordingDeviceIdentity` from a
    /// RAW token therefore addresses a different device from the one custody wrote to. That is
    /// what made the recorder page claim "Only on the recorder" for a file sitting on the
    /// phone, and made `offeredNext` re-offer the recording it had just brought over — the
    /// exclusion working perfectly against a key nobody writes.
    ///
    /// ASSERTED AS AN ADDRESS, NOT AS A FILE LOOKUP, AND DELIBERATELY. Whether the two
    /// addresses collide on disk is a property of the VOLUME: a case-insensitive APFS (this
    /// Mac) folds them together and a case-sensitive one (the simulator this app's scenarios
    /// run on, and the device it ships to) does not. A test that asserted the lookup would
    /// therefore pass or fail on which machine ran it — which is the same class of instrument
    /// failure as trusting a pipe's exit status. The addresses differing is the fact; that a
    /// filesystem sometimes hides it is exactly why the fix is normalisation and not luck.
    func testARawUppercaseTokenAddressesADifferentDeviceFromCustodys() async throws {
        let custody = store()
        let recordings = shelf()
        let raw = "26079BC5-1234-4ABC-9DEF-0123456789AB"
        let asCustodySeesIt = try PocketAuthenticatedIdentity(peripheralIdentifier: raw)
            .recordingDeviceIdentity
        let asARawTokenWouldBe = RecordingDeviceIdentity(shape: .filePull, hardwareToken: raw)
        XCTAssertNotEqual(asCustodySeesIt.storageKey, asARawTokenWouldBe.storageKey,
                          "if these ever agree this test is asserting nothing")
        XCTAssertEqual(asCustodySeesIt.storageKey, "filePull/26079bc5-1234-4abc-9def-0123456789ab")
        XCTAssertEqual(asARawTokenWouldBe.storageKey, "filePull/26079BC5-1234-4ABC-9DEF-0123456789AB")

        // AND THE NORMALISED ONE ACTUALLY FINDS WHAT CUSTODY KEPT — the existence half, so the
        // inequality above cannot be satisfied by two keys that both address nothing.
        try await keep(PocketRecorderFileKey(identity: asCustodySeesIt,
                                             date: recordings[0].date,
                                             timestamp: recordings[0].timestamp),
                       in: custody)
        let seen = await PocketShelfReadModel.heldFileIDs(recordings,
                                                          custody: custody,
                                                          identity: asCustodySeesIt)
        XCTAssertEqual(seen, ["2026-03-28/20260328001919"])
    }

    /// ONLY THE CUSTODY COLUMN MOVES. Name, link, battery and firmware are facts the RECORDER
    /// supplied on a session that is now closed; re-deriving them without a recorder would be
    /// the panel inventing device state.
    func testRestatingTheManifestChangesNothingTheRecorderSaid() {
        let recordings = shelf()
        let before = StoredFileDevicePresentation.detail(
            name: "PKT01_BLUE_26079bc5",
            link: .connected,
            battery: .reported("72%"),
            firmware: .reported("1.6"),
            manifest: PocketInventoryReader.manifest(recordings))
        let after = before.withManifest(
            PocketInventoryReader.manifest(recordings,
                                           heldFileIDs: ["2026-03-28/20260328001919"]))

        XCTAssertEqual(after.name, before.name)
        XCTAssertEqual(after.eyebrow, before.eyebrow)
        XCTAssertEqual(after.linkLabel, before.linkLabel)
        XCTAssertEqual(after.battery, before.battery)
        XCTAssertEqual(after.firmware, before.firmware)
        XCTAssertEqual(after.showsRecordingState, before.showsRecordingState)
        XCTAssertEqual(after.showsLiveActivity, before.showsLiveActivity)

        // AND THE COLUMN THAT WAS SUPPOSED TO MOVE, MOVED. Without this the assertions above
        // are satisfied by a function that returns its receiver unchanged.
        XCTAssertEqual(before.manifest.rows.map(\.custodyLabel),
                       ["Only on the recorder", "Only on the recorder"])
        XCTAssertEqual(after.manifest.rows.map(\.custodyLabel),
                       ["In Solleva", "Only on the recorder"])
        XCTAssertEqual(after.manifest.rows.map(\.title), before.manifest.rows.map(\.title),
                       "restating custody must not reorder or retitle the shelf")
    }
}
