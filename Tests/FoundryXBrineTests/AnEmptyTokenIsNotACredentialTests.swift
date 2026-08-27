import XCTest
@testable import FoundryXKit

/// An empty string is not a credential, and every guard on the path used to accept one.
///
/// ## The defect
///
/// MEASURED 2026-08-26 in the Mac's own gateway log: **90 of 138** requests that day arrived
/// and were refused as `no bearer on /foundryx/chat`. The phone was connected, the relay
/// worked, the requests reached the door — and every one carried `Authorization: Bearer `
/// with nothing after it.
///
/// Nothing threw. `currentIdToken()` returned `id.idToken` with no emptiness check;
/// `resolve()`'s `guard let token = resolvedToken` passed, because `""` is not nil;
/// `makeDoorTarget()`'s guards passed, because `"" == ""`. A well-formed `DoorTarget` was
/// handed out carrying an unusable credential.
///
/// ⚠ EXACTLY ONE call site in the whole kit checked `!idToken.isEmpty`, and it was not on
/// this path. That is the shape: an absence that satisfies every test for presence.
///
/// ⚠ AND MY FIRST VERSION OF THIS TEST PROVED NOTHING. It built a bare `RemoteSession()`,
/// set an empty token, and asserted `makeDoorTarget()` was nil — which it was, because
/// `relay` and `remote` were also nil. It passed identically with and without the fix. The
/// rule is now a function a test can execute directly, so the assertion is about the rule.
final class AnEmptyTokenIsNotACredentialTests: XCTestCase {

    func testAnEmptyStringIsNotAUsableBearer() {
        XCTAssertFalse(RemoteSession.isUsableBearer(""),
                       "an empty token produced `Authorization: Bearer ` for a day")
    }

    func testWhitespaceIsNotAUsableBearer() {
        XCTAssertFalse(RemoteSession.isUsableBearer("   "))
        XCTAssertFalse(RemoteSession.isUsableBearer("\n"))
        XCTAssertFalse(RemoteSession.isUsableBearer("\t "),
                       "whitespace is the same absence in different clothes — the door "
                       + "refuses it the same way")
    }

    /// The positive control. Without it every case above is satisfied by a rule that
    /// refuses everything, which would hand out no credential ever.
    func testARealTokenIsUsable() {
        XCTAssertTrue(RemoteSession.isUsableBearer("a-real-looking-id-token"))
        XCTAssertTrue(RemoteSession.isUsableBearer("eyJhbGciOiJSUzI1NiIsImtpZCI6IjEifQ.x.y"),
                      "a JWT-shaped token must survive the rule")
    }

    /// The seam actually CONSULTS the rule — otherwise the rule is correct and uncalled,
    /// which is the defect this entire session has been about.
    func testMakeDoorTargetConsultsTheRule() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/FoundryXKit/RemoteSession.swift"),
            encoding: .utf8)
        let body = source.components(separatedBy: "public func makeDoorTarget()").last ?? ""
        let guardBlock = body.components(separatedBy: "return DoorTarget").first ?? ""
        XCTAssertTrue(
            guardBlock.contains("isUsableBearer"),
            "makeDoorTarget no longer checks the bearer is usable. A correct rule with no "
            + "caller is exactly how the empty bearer shipped.")
    }
}
