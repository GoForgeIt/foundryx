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

    func testSplashStillLeadsAndSignedInPathIsUnchanged() {
        // The branded splash still shows first regardless of the toggle.
        XCTAssertEqual(
            RootGate.destination(signedIn: false, splashElapsed: false,
                                 brain: .justMyPhone, hostResolved: false, letStraightIn: true),
            .signInGate, "splash leads before straight-in kicks in")

        // Signed-in routing is untouched: resolved computer brain still wins.
        XCTAssertEqual(
            RootGate.destination(signedIn: true, splashElapsed: true,
                                 brain: .myComputer, hostResolved: true, letStraightIn: true),
            .computerBrain, "signed-in + resolved computer → computerBrain (unchanged)")
    }
}
