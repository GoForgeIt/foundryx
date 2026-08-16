import XCTest
import Foundation
@testable import FoundryXKit

/// AC5 of the presence track: `isConfirmedInLore` is read OFF the main thread, and it is
/// MEMOISED.
///
/// WHY THIS IS NOT A BRINE SCENARIO. It was one, and the scenario silently could not fail. A
/// Brine step that `await`s `MainActor.run` inside an `async` XCTest method has its
/// continuation resumed AFTER XCTest has already declared the test case finished — every
/// `XCTFail` raised from that step is dropped on the floor, and the scenario is counted as
/// passed. Measured on 2026-08-16: an unconditional `XCTFail("PRESENCE-DIAG")` placed in the
/// step produced NO failure line, while the `print` beside it appeared in the log AFTER
/// `Test Case ... failed`. So the main-thread half of this track lives here, in the same
/// `@MainActor XCTestCase` idiom `HangReproTests` and `ResidualMainActorWorkTests` already use,
/// where the assertions are on the thread that is being measured.
///
/// EVERY ARM CARRIES A POSITIVE CONTROL. A counter that is never incremented satisfies
/// `== 0` on an empty codebase, so each "zero on main" assertion is paired with a deliberate
/// main-thread read that MUST move the same counter. If the control does not fire, the
/// instrument is broken and the zero means nothing.
@MainActor
final class PocketPresenceMainThreadGateTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func makeRoot(_ name: String) -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pocket-presence-gate-\(name)-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    /// Working out where a recording is does ZERO synchronous main-thread storage reads —
    /// and the counter that says so demonstrably fires when the same read IS made on main.
    func testResolvingPresenceReadsStorageOffTheMainThreadOnly() async throws {
        let custodyRoot = makeRoot("custody")
        let libraryRoot = makeRoot("library")
        let custody = PocketRecorderFileStore(root: custodyRoot)
        let identity = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "GATE-RECORDER")
        let key = PocketRecorderFileKey(identity: identity, date: "2026-03-28",
                                        timestamp: "20260328001919")
        let writer = try await custody.beginKeeping(key)
        try writer.write(Data(repeating: 0x2A, count: 256))
        _ = try writer.commit()
        await custody.noteConversation("cap-gate", for: key)
        TranscriptCacheStore.save(
            CachedTranscript(transcript: "hello", title: nil, summary: nil, fetchedAt: 1),
            captureId: "cap-gate", baseDir: libraryRoot, markConfirmed: true)

        let durability = PocketCaptureDurability(baseDir: libraryRoot, stages: [:], brain: .myComputer)
        CaptureManager.resetMainThreadTranscriptDecodesForTests()
        let presence = await Task.detached {
            await PocketPresenceReader.presence(for: key, listedAt: Date(),
                                                custody: custody, durability: durability,
                                                askedAt: Date())
        }.value
        let duringResolve = CaptureManager.mainThreadTranscriptDecodesForTests

        XCTAssertTrue(presence.isDurableElsewhere, "premise: this recording IS confirmed")
        XCTAssertEqual(duringResolve, 0,
                       "working out where a recording is read storage on the main thread "
                           + "\(duringResolve) times")

        // POSITIVE CONTROL — this test method is @MainActor, so this read IS on the main
        // thread. If the counter does not move, the assertion above is watching nothing.
        _ = TranscriptCacheStore.isConfirmedInLore(captureId: "cap-gate", baseDir: libraryRoot)
        XCTAssertEqual(CaptureManager.mainThreadTranscriptDecodesForTests, 1,
                       "POSITIVE CONTROL FAILED: a deliberate main-thread read of the "
                           + "confirmation marker did not move the counter, so the zero above "
                           + "proves nothing")
    }

    /// The memo answers `true` without going back to disk — and it never memoises `false`, so
    /// a recording confirmed AFTER the object was built still reads safe.
    func testConfirmationIsMemoisedAndAbsenceIsNot() async throws {
        let libraryRoot = makeRoot("memo")
        let durability = PocketCaptureDurability(baseDir: libraryRoot, stages: [:], brain: .myComputer)

        XCTAssertFalse(durability.confirmedInLore("cap-later"),
                       "premise: nothing has confirmed this capture yet")
        TranscriptCacheStore.save(
            CachedTranscript(transcript: "hello", title: nil, summary: nil, fetchedAt: 1),
            captureId: "cap-later", baseDir: libraryRoot, markConfirmed: true)
        XCTAssertTrue(durability.confirmedInLore("cap-later"),
                      "a `false` was memoised — a recording confirmed after this object was "
                          + "built would read unsafe for the life of the shelf")

        // Now the marker goes away UNDER the object. The memo answers from memory, which is
        // the whole point: a confirmation never un-happens, and the retention sweep that
        // deletes the audio is written to keep this marker.
        try FileManager.default.removeItem(
            at: libraryRoot.appendingPathComponent("cap-later", isDirectory: true)
                .appendingPathComponent(".lore-confirmed"))
        XCTAssertFalse(TranscriptCacheStore.isConfirmedInLore(captureId: "cap-later",
                                                              baseDir: libraryRoot),
                       "premise: the marker really is gone from disk")
        XCTAssertTrue(durability.confirmedInLore("cap-later"),
                      "the confirmation was not memoised — every listed recording pays a "
                          + "fresh stat on every shelf read")
    }
}
