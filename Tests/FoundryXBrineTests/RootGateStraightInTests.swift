import XCTest
@testable import FoundryXKit

/// "Take me straight in" (track 20260714T1800 follow-up): a returning user who turned the
/// welcome/sign-in gate off opens directly into the phone-only tier — whole and offline —
/// while everyone else still hits the sign-in gate first. Default behavior is unchanged.
final class RootGateStraightInTests: XCTestCase {

    func testStraightInBypassesTheSignInGateWhenNotSignedIn() {
        // Default (letStraightIn = false): not signed in → the sign-in/connection gate.
        XCTAssertEqual(
            RootGate.destination(signedIn: false, splashElapsed: true,
                                 brain: .justMyPhone, hostResolved: false),
            .signInGate, "default: not signed in → sign-in gate")

        // Opted in: not signed in → straight into the phone tier (no connection needed).
        XCTAssertEqual(
            RootGate.destination(signedIn: false, splashElapsed: true,
                                 brain: .justMyPhone, hostResolved: false, letStraightIn: true),
            .phoneBrain, "letStraightIn: open straight to the app, even offline")
    }

    // INVERTED by track 20260715T1502 (Nick 2026-07-16): straight-in means NO gate
    // of any kind — not even the launch splash. The old assertion ("splash leads
    // before straight-in kicks in") described exactly the bug being fixed: an
    // opted-out user met the old connection page for 2 s on every launch.
    func testStraightInSkipsEvenTheSplashAndSignedInPathIsUnchanged() {
        XCTAssertEqual(
            RootGate.destination(signedIn: false, splashElapsed: false,
                                 brain: .justMyPhone, hostResolved: false, letStraightIn: true),
            .phoneBrain, "straight-in: zero gate — the app opens immediately")

        // Signed-in routing is untouched: resolved computer brain still wins.
        XCTAssertEqual(
            RootGate.destination(signedIn: true, splashElapsed: true,
                                 brain: .myComputer, hostResolved: true, letStraightIn: true),
            .computerBrain, "signed-in + resolved computer → computerBrain (unchanged)")
    }

    // A straight-in computer-brain user rides the phone tier until the host
    // resolves (whole and offline), then the computer brain takes over — the
    // connection forms IN the app, never as an interstitial.
    func testStraightInComputerBrainDegradesToPhoneUntilResolved() {
        XCTAssertEqual(
            RootGate.destination(signedIn: true, splashElapsed: false,
                                 brain: .myComputer, hostResolved: false, letStraightIn: true),
            .phoneBrain, "unresolved host: straight into the phone tier, no gate")
        XCTAssertEqual(
            RootGate.destination(signedIn: true, splashElapsed: false,
                                 brain: .myComputer, hostResolved: true, letStraightIn: true),
            .computerBrain, "the moment the host resolves, the computer brain takes over")
    }

    // Default behavior (letStraightIn = false) still leads with the gate — which
    // is now the WELCOME front door, never the old connection page.
    func testDefaultStillLeadsWithTheGate() {
        XCTAssertEqual(
            RootGate.destination(signedIn: true, splashElapsed: false,
                                 brain: .myComputer, hostResolved: false),
            .signInGate, "non-opted-out signed-in user gates on the welcome until entry")
        XCTAssertEqual(
            RootGate.destination(signedIn: true, splashElapsed: true,
                                 brain: .myComputer, hostResolved: false),
            .phoneBrain, "after entry, an unresolved computer degrades to the phone tier")
    }
}
