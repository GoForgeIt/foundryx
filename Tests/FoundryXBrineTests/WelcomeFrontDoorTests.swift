import XCTest
@testable import FoundryXKit

/// The welcome-front-door rules (track 20260715T1502 re-cut, Nick 2026-07-16:
/// the OLD connection intro page must never gate; the welcome surface is the
/// front door; connection status lives on the welcome or in the app). These pin
/// the pure core the RootView wiring renders from: the surface routing, the
/// connect-pill mapping, the sign-in caption, and the post-entry first-run
/// ladder that makes the double welcome impossible.
final class WelcomeFrontDoorTests: XCTestCase {

    // MARK: - Surface routing

    func testSignedOutFrontDoorIsTheWelcomeWithSignIn() {
        XCTAssertEqual(
            WelcomeFrontDoor.surface(signedIn: false, letStraightIn: false, entered: false),
            .welcomeSignIn, "signed out → sign-in buttons ON the welcome, never the old page")
    }

    func testSignedInFrontDoorIsTheConnectGateWelcome() {
        XCTAssertEqual(
            WelcomeFrontDoor.surface(signedIn: true, letStraightIn: false, entered: false),
            .welcomeConnectGate, "signed in → the welcome carries the live connect status")
    }

    func testOptedOutOrEnteredMeansNoGateAtAll() {
        // "Open straight to the app" (letStraightIn) skips the welcome for an
        // ALREADY-SIGNED-IN user only.
        XCTAssertEqual(
            WelcomeFrontDoor.surface(signedIn: true, letStraightIn: true, entered: false),
            WelcomeFrontDoor.Surface.none, "straight-in for a signed-in user: zero gate")
        // But sign-in is REQUIRED FIRST (locked decision #5) — a signed-OUT user with
        // letStraightIn set must STILL get the sign-in choices, never a dead `.none`
        // gate. (Build 288 returned `.none` here: signing out after skipping the
        // welcome dead-ended login. Fixed 2026-07-24, mirroring the RootGate rule.)
        XCTAssertEqual(
            WelcomeFrontDoor.surface(signedIn: false, letStraightIn: true, entered: false),
            .welcomeSignIn, "straight-in must NOT bypass sign-in for a signed-out user")
        XCTAssertEqual(
            WelcomeFrontDoor.surface(signedIn: true, letStraightIn: false, entered: true),
            .none, "after entry the gate never comes back mid-session")
    }

    // Implement-review F1: a mid-session sign-out must land on the SIGN-IN
    // welcome (provider buttons) — `entered` may only suppress the connect gate
    // for a still-signed-in user, never dead-end a signed-out one.
    func testMidSessionSignOutLandsOnTheSignInWelcome() {
        XCTAssertEqual(
            WelcomeFrontDoor.surface(signedIn: false, letStraightIn: false, entered: true),
            .welcomeSignIn, "sign-out after entry → the sign-in front door, not a dead end")
    }

    // A fresh signed-in install meets the SAME welcome gate — there is
    // deliberately no `onboarded` input (the flow skips its welcome instead).
    func testSurfaceHasNoOnboardedEscapeHatch() {
        XCTAssertEqual(
            WelcomeFrontDoor.surface(signedIn: true, letStraightIn: false, entered: false),
            .welcomeConnectGate)
    }

    // MARK: - The live connect pill

    func testConnectStatusMapsEveryLiveState() {
        XCTAssertEqual(WelcomeFrontDoor.connectStatus(.resolving, email: nil),
                       WelcomeConnectStatus(text: "Connecting to your computer…", settled: false))
        XCTAssertEqual(WelcomeFrontDoor.connectStatus(.connected(host: "t1"), email: "nick@x.com"),
                       WelcomeConnectStatus(text: "Connected · nick@x.com", settled: true))
        XCTAssertEqual(WelcomeFrontDoor.connectStatus(.connected(host: "t1"), email: nil),
                       WelcomeConnectStatus(text: "Connected", settled: true))
        XCTAssertEqual(WelcomeFrontDoor.connectStatus(.noHost, email: "nick@x.com"),
                       WelcomeConnectStatus(text: "On your phone", settled: true))
        XCTAssertEqual(WelcomeFrontDoor.connectStatus(.error("boom"), email: nil),
                       WelcomeConnectStatus(text: "Couldn't reach your computer", settled: false))
    }

    func testConnectStatusIsNilWhenThereIsNothingToConnect() {
        XCTAssertNil(WelcomeFrontDoor.connectStatus(.signedOut, email: nil))
        XCTAssertNil(WelcomeFrontDoor.connectStatus(.unconfigured, email: nil))
    }

    // MARK: - The sign-in caption

    func testSignInCaptionIsHonestAndQuiet() {
        XCTAssertEqual(WelcomeFrontDoor.signInCaption(.unconfigured),
                       "Sign-in isn't available in this build.")
        XCTAssertEqual(WelcomeFrontDoor.signInCaption(.resolving), "Signing in…")
        XCTAssertEqual(WelcomeFrontDoor.signInCaption(.error("token expired")), "token expired")
        XCTAssertNil(WelcomeFrontDoor.signInCaption(.signedOut),
                     "at rest the buttons speak for themselves")
        XCTAssertNil(WelcomeFrontDoor.signInCaption(.connected(host: "t1")))
        XCTAssertNil(WelcomeFrontDoor.signInCaption(.noHost))
    }

    // MARK: - The post-entry first-run ladder (never the welcome twice)

    func testFreshInstallOnboardsWithoutRepeatingTheWelcome() {
        // enterApp() marks the welcome seen BEFORE this decision runs.
        XCTAssertEqual(
            WelcomeFrontDoor.firstRunPresentation(letStraightIn: false,
                                                  onboardingCompleted: false,
                                                  welcomeSeen: true,
                                                  hasRecordingHistory: false),
            .onboarding(skipWelcome: true),
            "the gate already WAS the welcome — onboarding starts at the voice step")
    }

    func testSettingsTourStillOpensWithTheWelcome() {
        // The full-tour path never consults this ladder (Settings presents the
        // flow directly, skipWelcome defaults false); but a genuinely unseen
        // welcome before onboarding keeps the flow's own welcome step.
        XCTAssertEqual(
            WelcomeFrontDoor.firstRunPresentation(letStraightIn: false,
                                                  onboardingCompleted: false,
                                                  welcomeSeen: false,
                                                  hasRecordingHistory: false),
            .onboarding(skipWelcome: false))
    }

    func testEstablishedSeenUserGetsNothingAfterEntry() {
        XCTAssertEqual(
            WelcomeFrontDoor.firstRunPresentation(letStraightIn: false,
                                                  onboardingCompleted: true,
                                                  welcomeSeen: true,
                                                  hasRecordingHistory: false),
            .none, "AC4: no legacy post-entry welcome, ever")
    }

    func testWelcomeSeenCanNeverYieldTheStandaloneWelcome() {
        for completed in [true, false] {
            let p = WelcomeFrontDoor.firstRunPresentation(letStraightIn: false,
                                                          onboardingCompleted: completed,
                                                          welcomeSeen: true,
                                                          hasRecordingHistory: false)
            XCTAssertNotEqual(p, .standaloneWelcome,
                              "markSeen-first in enterApp() makes the repeat impossible")
        }
    }

    func testStraightInSuppressesEveryCeremony() {
        for completed in [true, false] {
            for seen in [true, false] {
                XCTAssertEqual(
                    WelcomeFrontDoor.firstRunPresentation(letStraightIn: true,
                                                          onboardingCompleted: completed,
                                                          welcomeSeen: seen,
                                                          hasRecordingHistory: false),
                    .none, "straight-in: nothing presents (completed=\(completed) seen=\(seen))")
            }
        }
    }

    func testMigratedEstablishedInstallStillGetsTheStandaloneWelcomeOnce() {
        XCTAssertEqual(
            WelcomeFrontDoor.firstRunPresentation(letStraightIn: false,
                                                  onboardingCompleted: true,
                                                  welcomeSeen: false,
                                                  hasRecordingHistory: false),
            .standaloneWelcome, "B2 preserved: onboarded-but-unseen sees it once")
    }
}
