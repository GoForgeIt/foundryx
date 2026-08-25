import XCTest
@testable import FoundryXKit

/// L3.6 / AC5a + AC5b — a confirmation reads as CONFIRMED only once the second place has it.
///
/// The flow declares, verbatim, *"Instant LOCAL success — the label flips in place NOW; the Mac
/// is not consulted"*, and ships detached, staying *"quietly pending"* on failure. That makes a
/// confirmation which never landed indistinguishable from one that did — and that is the exact
/// failure standing between 17 confirmed speakers and the 1,005 captures waiting to be tagged.
///
/// The optimistic WRITE stays: it is what keeps the tap from hanging. What changes is that
/// `confirmed` is no longer CLAIMED before the second place accepts.
@MainActor
final class SpeakerConfirmLandingTests: XCTestCase {

    private func flow() -> SpeakerConfirmController {
        SpeakerConfirmController(baseDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("confirm-landing-\(UUID().uuidString)"))
    }

    /// AC5b — an unshipped confirmation is VISUALLY DISTINCT from a landed one.
    func testAConfirmationThatHasNotLandedReadsPendingNotConfirmed() async {
        let f = flow()
        let phase = await f.confirm(
            captureId: "c1", slot: "speaker_0", name: "Nick",
            ship: { throw URLError(.notConnectedToInternet) }
        )
        XCTAssertEqual(phase, .pendingSync,
                       "a local save is not a landing; the row must not read confirmed")
        XCTAssertNotEqual(phase, .confirmed)
    }

    /// The optimistic write still happens — the tap does not wait on the network.
    func testTheLocalSaveStillHappensImmediately() async {
        let f = flow()
        var sawOutcome = false
        _ = await f.confirm(
            captureId: "c2", slot: "speaker_0", name: "Nick",
            ship: { throw URLError(.timedOut) },
            onConfirmed: { _ in sawOutcome = true }
        )
        XCTAssertTrue(sawOutcome, "the local outcome fires without waiting on the ship")
    }

    /// PAIRED with the first test: without this, `pendingSync` could simply replace
    /// `confirmed` everywhere and nothing would ever read as landed — a state machine that
    /// cannot reach its own success is not stricter, it is broken.
    func testAnAcknowledgedConfirmationReadsConfirmed() async {
        let f = flow()
        let phase = await f.confirm(
            captureId: "c3", slot: "speaker_0", name: "Nick",
            ship: {
                ConfirmOutcome(captureId: "c3", slotLabel: "speaker_0", status: "confirmed",
                               speakerId: "s1", speakerName: "Nick", offeredCaptures: [])
            }
        )
        // The ship is detached, so the landing is observed rather than returned.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let settled = f.phase(for: "speaker_0")
        XCTAssertEqual(settled, .confirmed,
                       "once the second place acknowledges, the row reads confirmed")
        XCTAssertNotEqual(phase, .confirmed, "but not at the moment of the local save")
    }
}
