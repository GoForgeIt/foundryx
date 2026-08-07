import XCTest
@testable import FoundryXKit

/// A door failure must name the state the user can ACT on, never the transport.
/// The field case this comes from: the relay resolved the host fine, the dial failed because
/// nothing was listening on the Mac end, and the user was shown
/// "Couldn't load transcript: Could not connect to the server." — which sent everyone
/// hunting a phone network problem that did not exist.
final class DoorFailureMessageTests: XCTestCase {

    /// The exact regression: host designated, tunnel dead → say so, don't blame the network.
    func testConnectedButFailingBlamesTheComputerNotTheNetwork() {
        let m = DoorFailureMessage.make(status: .connected(host: "h-532f1547e05a33df"),
                                        underlying: "Could not connect to the server.")
        XCTAssertEqual(m.text, "Your computer isn't connected right now.")
        XCTAssertEqual(m.action, "Open Solleva on your Mac and make sure it's awake.")
        XCTAssertFalse(m.line.contains("server"), "must not surface the transport string")
    }

    func testErrorStatusAlsoBlamesTheComputer() {
        let m = DoorFailureMessage.make(status: .error("Socket is not connected"),
                                        underlying: "Socket is not connected")
        XCTAssertEqual(m.text, "Your computer isn't connected right now.")
        XCTAssertFalse(m.line.contains("Socket"))
    }

    func testNoHostTellsYouToSetTheComputerUp() {
        let m = DoorFailureMessage.make(status: .noHost, underlying: "Could not connect to the server.")
        XCTAssertEqual(m.text, "No computer is set up for this account yet.")
        XCTAssertEqual(m.action, "Open Solleva on your Mac and sign in with the same account.")
    }

    func testSignedOutSaysSignedOutNotNetwork() {
        let m = DoorFailureMessage.make(status: .signedOut, underlying: "Could not connect to the server.")
        XCTAssertEqual(m.text, "You're signed out.")
        XCTAssertEqual(m.action, "Sign in to reach your computer.")
        XCTAssertFalse(m.line.lowercased().contains("connect to the server"))
    }

    func testResolvingIsHonestAboutStillWorking() {
        let m = DoorFailureMessage.make(status: .resolving, underlying: nil)
        XCTAssertEqual(m.text, "Still connecting to your computer…")
    }

    func testUnconfiguredBuildSaysSo() {
        let m = DoorFailureMessage.make(status: .unconfigured, underlying: nil)
        XCTAssertEqual(m.text, "Sign-in isn't available in this build.")
        XCTAssertNil(m.action)
    }

    /// Whatever the transport said, it never reaches the user for any account/host state —
    /// that is the whole point of the mapper.
    func testTransportStringNeverLeaksForAnyStatus() {
        let leak = "NSURLErrorDomain -1004 Could not connect to the server."
        for status: RemoteSession.Status in [.signedOut, .unconfigured, .noHost, .resolving,
                                             .connected(host: "h"), .error("boom")] {
            let line = DoorFailureMessage.make(status: status, underlying: leak).line
            XCTAssertFalse(line.contains("NSURLErrorDomain"), "leaked for \(status)")
            XCTAssertFalse(line.contains("-1004"), "leaked for \(status)")
        }
    }
}
