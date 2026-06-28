import XCTest
@testable import FoundryXKit

/// When a turn is refused/blocked, the door now emits a clear `error` event (just before
/// the refused `done`) carrying a human-readable reason — e.g. confidential content kept
/// local, or auth expired. The phone must surface THAT reason instead of a bare "refused".
@MainActor
final class RefusalReasonTests: XCTestCase {

    func testParsesErrorEvent() {
        guard case .error(let code, let reason) = DoorEvent.parse(
            #"{"type":"error","code":"requested_target_noncompliant","reason":"kept local"}"#
        ) else { return XCTFail("expected error event") }
        XCTAssertEqual(code, "requested_target_noncompliant")
        XCTAssertEqual(reason, "kept local")
    }

    func testErrorThenDoneSurfacesReasonOnRefused() {
        let m = ChatViewModel()
        m.beginUserTurn("send to opus")
        // The door emits `error` first, then the refused `done` (client stops at `done`).
        m.apply(.error(code: "requested_target_noncompliant",
                       reason: "The selected cloud model isn't allowed at this privacy level."))
        m.apply(.done(reason: "refused"))

        guard case .refused(let reason) = m.turnState else {
            return XCTFail("expected refused, got \(m.turnState)")
        }
        XCTAssertEqual(reason, "The selected cloud model isn't allowed at this privacy level.",
                       "the refused state carries the door's clear reason, not a bare label")
    }

    func testRefusedWithoutErrorEventHasNilReason() {
        let m = ChatViewModel()
        m.beginUserTurn("hi")
        m.apply(.done(reason: "refused"))
        guard case .refused(let reason) = m.turnState else {
            return XCTFail("expected refused")
        }
        XCTAssertNil(reason, "no error event → nil reason (UI falls back to a generic label)")
    }

    func testErrorReasonClearedOnNextTurn() {
        let m = ChatViewModel()
        m.beginUserTurn("first")
        m.apply(.error(code: "no_policy", reason: "no policy configured"))
        m.apply(.done(reason: "refused"))
        XCTAssertEqual(m.lastErrorReason, "no policy configured")

        m.beginUserTurn("second")
        XCTAssertNil(m.lastErrorReason, "a new turn clears the stale refusal reason")
    }
}
