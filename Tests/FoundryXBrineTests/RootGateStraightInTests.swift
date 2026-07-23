import XCTest
@testable import FoundryXKit

/// "Open straight to the app": an ALREADY-AUTHENTICATED returning user does not have to see
/// the welcome screen again. It is NOT an auth bypass.
///
/// CONTRACT CORRECTED 2026-07-23 (Nick): sign-in is REQUIRED, always. "Local-first" describes
/// WHERE data lives and is processed — it never meant the app is usable without an identity,
/// because signing in is what protects that data, including locally on the phone. The previous
/// contract (pinned by the test below, which was literally named
/// `testStraightInBypassesTheSignInGateWhenNotSignedIn`) let a signed-out phone use the whole
/// app; every door-dependent feature then failed with a misleading NETWORK error rather than
/// "you're signed out", and it contradicted RootGate.swift's own header, "Sign in FIRST".
final class RootGateStraightInTests: XCTestCase {

    /// INVERTED 2026-07-23. This test previously asserted that `letStraightIn` bypassed the
    /// sign-in gate — the exact defect it was named after. Sign-in is required either way;
    /// `letStraightIn` only decides whether an AUTHENTICATED user sees the welcome.
    func testSignInIsRequiredEvenWithStraightIn() {
        XCTAssertEqual(
            RootGate.destination(signedIn: false, splashElapsed: true,
                                 brain: .justMyPhone, hostResolved: false),
            .signInGate, "default: not signed in → sign-in gate")

        XCTAssertEqual(
            RootGate.destination(signedIn: false, splashElapsed: true,
                                 brain: .justMyPhone, hostResolved: false, letStraightIn: true),
            .signInGate,
            "straight-in is NOT an auth bypass — a signed-out user still signs in first")
    }

    // INVERTED by track 20260715T1502 (Nick 2026-07-16): straight-in means NO gate
    // of any kind — not even the launch splash. The old assertion ("splash leads
    // before straight-in kicks in") described exactly the bug being fixed: an
    // opted-out user met the old connection page for 2 s on every launch.
    func testStraightInSkipsEvenTheSplashAndSignedInPathIsUnchanged() {
        // Signed OUT + straight-in + pre-splash: still the sign-in gate (corrected 2026-07-23).
        XCTAssertEqual(
            RootGate.destination(signedIn: false, splashElapsed: false,
                                 brain: .justMyPhone, hostResolved: false, letStraightIn: true),
            .signInGate, "not signed in → sign-in gate, splash or no splash")

        // What straight-in DOES buy an authenticated user: no waiting on the splash/welcome.
        XCTAssertEqual(
            RootGate.destination(signedIn: true, splashElapsed: false,
                                 brain: .justMyPhone, hostResolved: false, letStraightIn: true),
            .phoneBrain, "signed in + straight-in: the app opens immediately, no welcome")

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
