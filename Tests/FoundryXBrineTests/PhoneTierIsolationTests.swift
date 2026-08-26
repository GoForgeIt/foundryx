import XCTest
@testable import FoundryXKit

/// L3.7 / AC6 — on the phone tier NOTHING reaches for a second place, and nothing NAMES one.
///
/// `CaptureDestination.secondPlace` returns `nil` there because that tier genuinely has no
/// second place. The criterion is not "the request fails gracefully" — it is that the request
/// is never made, and that no sentence implies a place the owner does not have.
@MainActor
final class PhoneTierIsolationTests: XCTestCase {

    func testThePhoneTierNamesNoSecondPlace() {
        XCTAssertNil(CaptureDestination.phone.secondPlace,
                     "the phone tier has no second place, so it must name none")
        XCTAssertNil(CaptureDestination.phone.secondPlacePossessive)
    }

    /// PAIRED. Without this, `secondPlace` could return nil for EVERY tier and the test above
    /// would pass while the computer and vault tiers lost their names too.
    func testTheOtherTiersDoNameTheirSecondPlace() {
        XCTAssertEqual(CaptureDestination.computer.secondPlace, "your Mac")
        XCTAssertEqual(CaptureDestination.vault.secondPlace, "your Vault")
    }

    /// AC6a — the REQUEST is never made, not merely handled.
    func testNoRequestIsMadeWhenThereIsNoSecondPlace() async {
        let asked = RequestProbe()
        let state = await FullHistorySearch.remoteState(
            query: "anything",
            localIds: [],
            computerConnected: false,
            search: { _ in asked.mark(); return [] }
        )
        XCTAssertEqual(state, .notConnected)
        XCTAssertFalse(asked.wasAsked,
                       "the phone tier must not REACH for a second place — not even to fail")
    }

    /// PAIRED with the above: proves the probe can actually observe a request, so the
    /// assertion is not passing because the instrument is blind.
    func testTheProbeObservesARequestWhenOneIsMade() async {
        let asked = RequestProbe()
        _ = await FullHistorySearch.remoteState(
            query: "anything",
            localIds: [],
            computerConnected: true,
            search: { _ in asked.mark(); return [] }
        )
        XCTAssertTrue(asked.wasAsked, "with a second place connected, the request IS made")
    }
}

private final class RequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false
    func mark() { lock.lock(); defer { lock.unlock() }; asked = true }
    var wasAsked: Bool { lock.lock(); defer { lock.unlock() }; return asked }
}
