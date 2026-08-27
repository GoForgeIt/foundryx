import XCTest
@testable import FoundryXKit

/// "Connecting to your computer…" must stop being said once it has stopped being true.
///
/// ## The defect
///
/// MEASURED 2026-08-26. The owner's phone showed "Connecting to your computer…" while every
/// door request it made carried an EMPTY bearer — 90 of 138 that day. The session was not
/// connecting; it had stopped. `WelcomeFrontDoor.connectStatus` maps `.resolving` to that
/// sentence, and `resolve()` has SEVEN `guard requestedGeneration == …identityGeneration
/// else { return }` abandonment points, every one of which leaves `status` at `.resolving`.
///
/// An abandoned resolve therefore renders as hopeful progress forever, with no reason given
/// and nothing to act on — the same shape as every other defect in this wave: an absence
/// (of a settled outcome) rendered as a presence (of progress).
final class ResolvingIsBoundedTests: XCTestCase {

    /// The mapping this whole fix turns on, pinned so it cannot drift silently.
    func testResolvingIsWhatRendersTheConnectingSentence() {
        let connecting = WelcomeFrontDoor.connectStatus(.resolving, email: nil)
        XCTAssertEqual(connecting?.text, "Connecting to your computer…")
        XCTAssertEqual(connecting?.settled, false,
                       "connecting is an UNSETTLED state — if it never settles the person "
                       + "is watching a spinner that means nothing")
    }

    /// The terminal state the watchdog moves to is one the person can actually read.
    ///
    /// ⚠ NOT `.signedOut`, WHICH RENDERS NO PILL AT ALL. Replacing a false "connecting" with
    /// silence would trade one unactionable state for another.
    func testTheTerminalStateSaysSomethingActionable() {
        let stopped = WelcomeFrontDoor.connectStatus(.error("Connection didn't complete"),
                                                     email: nil)
        XCTAssertNotNil(stopped, "the stopped state must render a pill, not vanish")
        XCTAssertEqual(stopped?.text, "Couldn't reach your computer")

        XCTAssertNil(WelcomeFrontDoor.connectStatus(.signedOut, email: nil),
                     "signedOut renders NOTHING — which is why the watchdog must not use it")
    }

    /// The budget is DECLARED, not chosen per call site.
    ///
    /// Generous on purpose: a watchdog that fires on a working connection is worse than no
    /// watchdog, because it teaches people to ignore it.
    @MainActor
    func testTheResolveBudgetIsDeclaredAndGenerous() {
        XCTAssertGreaterThanOrEqual(RemoteSession.resolveBudget, 15,
                                    "too short a budget fires on slow-but-working networks")
        XCTAssertLessThanOrEqual(RemoteSession.resolveBudget, 60,
                                 "too long and the person is left waiting on a lie")
    }
}
