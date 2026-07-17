import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/welcome-front-door.feature (track 20260715T1502
/// re-cut, Nick 2026-07-16: the old connection page never gates; the welcome is
/// the front door; connection status shows on the welcome or inside the app).
/// Drives the REAL kit rules the RootView wiring renders from — RootGate,
/// WelcomeFrontDoor (surface / connectStatus / firstRunPresentation), and
/// WelcomePrefs on a fresh UserDefaults suite — hermetic: no UI, no network.
final class WelcomeFrontDoorFeatureTests: XCTestCase {
    func testWelcomeFrontDoorFeature() async throws {
        try await BrineFeatureRunner.run(
            "welcome-front-door",
            registry: StepRegistry(WelcomeFrontDoorSteps.make(world: WelcomeFrontDoorWorld())))
    }
}

/// One simulated launch-state: exactly the inputs RootView feeds the kit rules.
private final class WelcomeFrontDoorWorld: @unchecked Sendable {
    let defaults: UserDefaults

    // Session state (what RemoteSession publishes).
    var signedIn = false
    var status: RemoteSession.Status = .signedOut
    var email: String?
    var onboardingCompleted = false

    // Per-launch state.
    var entered = false

    // Step-to-step observations.
    var destination: RootDestination?
    var surface: WelcomeFrontDoor.Surface?
    var pill: WelcomeConnectStatus?
    var firstRun: WelcomeFrontDoor.FirstRunPresentation?

    init() {
        let name = "welcome-front-door-feature-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    /// A brand-new install/user (the world is shared across the feature's
    /// scenarios — each top-level Given starts from clean persisted prefs).
    func resetPrefs() {
        defaults.removeObject(forKey: WelcomePrefs.seenKey)
        defaults.removeObject(forKey: WelcomePrefs.letStraightInKey)
    }

    /// A cold launch: recompute exactly what RootView computes — the RootGate
    /// destination, and (when gated) the front-door surface + connect pill.
    func launch() {
        entered = false
        destination = RootGate.destination(
            signedIn: signedIn,
            splashElapsed: entered,
            brain: .myComputer,
            hostResolved: false,          // launch instant: the host is never resolved yet
            letStraightIn: WelcomePrefs.letStraightIn(defaults: defaults))
        refreshGate()
    }

    func refreshGate() {
        surface = WelcomeFrontDoor.surface(
            signedIn: signedIn,
            letStraightIn: WelcomePrefs.letStraightIn(defaults: defaults),
            entered: entered)
        pill = surface == .welcomeConnectGate
            ? WelcomeFrontDoor.connectStatus(status, email: email)
            : nil
    }

    /// RootView.enterApp(): markSeen FIRST, then the first-run ladder (AC4).
    func enterApp() {
        WelcomePrefs.markSeen(defaults: defaults)
        entered = true
        firstRun = WelcomeFrontDoor.firstRunPresentation(
            letStraightIn: WelcomePrefs.letStraightIn(defaults: defaults),
            onboardingCompleted: onboardingCompleted,
            welcomeSeen: WelcomePrefs.seen(defaults: defaults))
        destination = RootGate.destination(
            signedIn: signedIn,
            splashElapsed: entered,
            brain: .myComputer,
            hostResolved: false,
            letStraightIn: WelcomePrefs.letStraightIn(defaults: defaults))
        refreshGate()
    }
}

private enum WelcomeFrontDoorSteps {
    static func make(world w: WelcomeFrontDoorWorld) -> [StepDefinition] {
        [
            // MARK: Givens — who is arriving

            defineStep("I am signed in and have used the app before") { ctx, _, _ in
                w.resetPrefs()
                w.signedIn = true
                w.email = "nick@example.com"
                w.onboardingCompleted = true
                w.status = .resolving
                return ctx
            },
            defineStep("my computer is still being reached") { ctx, _, _ in
                w.status = .resolving
                return ctx
            },
            defineStep("a fresh install that has never signed in") { ctx, _, _ in
                w.resetPrefs()
                w.signedIn = false
                w.email = nil
                w.onboardingCompleted = false
                w.status = .signedOut
                return ctx
            },
            defineStep("the welcome is fronting the app while my computer is being reached") { ctx, _, _ in
                w.status = .resolving
                w.launch()
                guard w.surface == .welcomeConnectGate else {
                    throw BrineStepError("expected the connect-gate welcome, got \(String(describing: w.surface))")
                }
                return ctx
            },
            defineStep("the welcome is fronting the app") { ctx, _, _ in
                w.launch()
                guard w.destination == .signInGate, w.surface == .welcomeConnectGate else {
                    throw BrineStepError("welcome not fronting: dest=\(String(describing: w.destination)) surface=\(String(describing: w.surface))")
                }
                return ctx
            },
            defineStep("the sign-in welcome is fronting the app") { ctx, _, _ in
                w.launch()
                guard w.destination == .signInGate, w.surface == .welcomeSignIn else {
                    throw BrineStepError("expected the sign-in welcome front door, got \(String(describing: w.surface))")
                }
                return ctx
            },

            // MARK: Whens — actions

            defineStep("I launch the app") { ctx, _, _ in
                w.launch()
                return ctx
            },
            defineStep("the connection to my computer is established") { ctx, _, _ in
                w.status = .connected(host: "tunnel-1")
                w.refreshGate()
                return ctx
            },
            defineStep("I choose to go into the app") { ctx, _, _ in
                w.enterApp()
                return ctx
            },
            defineStep("I choose to skip the welcome from now on") { ctx, _, _ in
                // PersonaWelcomeStep's "Skip the welcome": persist the opt-out, then enter.
                WelcomePrefs.setLetStraightIn(true, defaults: w.defaults)
                w.enterApp()
                return ctx
            },
            defineStep("I launch the app again") { ctx, _, _ in
                w.launch()
                return ctx
            },
            defineStep("I sign out from settings") { ctx, _, _ in
                // RemoteSession.signOut(): email cleared; RootView state (entered)
                // is untouched — exactly the mid-session state under test.
                w.signedIn = false
                w.email = nil
                w.status = .signedOut
                w.destination = RootGate.destination(
                    signedIn: w.signedIn, splashElapsed: w.entered, brain: .myComputer,
                    hostResolved: false,
                    letStraightIn: WelcomePrefs.letStraightIn(defaults: w.defaults))
                w.refreshGate()
                return ctx
            },
            defineStep("I sign in and go into the app") { ctx, _, _ in
                w.signedIn = true
                w.email = "nick@example.com"
                w.status = .resolving
                w.refreshGate()
                guard w.surface == .welcomeConnectGate else {
                    throw BrineStepError("after sign-in the same welcome must carry the connect gate")
                }
                w.enterApp()
                return ctx
            },

            // MARK: Thens — outcomes

            defineCheck("the welcome page fronts the app") { _, _, _ in
                guard w.destination == .signInGate else {
                    throw BrineStepError("expected the gate destination, got \(String(describing: w.destination))")
                }
                guard w.surface == .welcomeConnectGate || w.surface == .welcomeSignIn else {
                    throw BrineStepError("the gate must render a welcome rendition, got \(String(describing: w.surface))")
                }
            },
            defineCheck("it shows that it is connecting to my computer") { _, _, _ in
                guard let pill = w.pill, !pill.settled,
                      pill.text == "Connecting to your computer…" else {
                    throw BrineStepError("expected the working connect pill, got \(String(describing: w.pill))")
                }
            },
            defineCheck("the old connection page is not shown") { _, _, _ in
                // The old page only ever rendered on the gate destination; the gate
                // now always renders a welcome rendition (never Surface.none there).
                if w.destination == .signInGate {
                    guard w.surface != WelcomeFrontDoor.Surface.none else {
                        throw BrineStepError("gate destination with no welcome rendition — the old page would show")
                    }
                }
            },
            defineCheck("the welcome shows I am connected with my account") { _, _, _ in
                guard let pill = w.pill, pill.settled,
                      pill.text == "Connected · nick@example.com" else {
                    throw BrineStepError("expected the settled connected pill, got \(String(describing: w.pill))")
                }
            },
            defineCheck("I am in the app") { _, _, _ in
                guard w.destination == .computerBrain || w.destination == .phoneBrain else {
                    throw BrineStepError("expected an in-app destination, got \(String(describing: w.destination))")
                }
            },
            defineCheck("the welcome does not appear again after entry") { _, _, _ in
                guard w.surface == WelcomeFrontDoor.Surface.none else {
                    throw BrineStepError("gate surface returned after entry: \(String(describing: w.surface))")
                }
                guard w.firstRun != .standaloneWelcome else {
                    throw BrineStepError("the legacy post-entry welcome re-presented (AC4)")
                }
            },
            defineCheck("I go straight into the app with no welcome and no connection page") { _, _, _ in
                guard w.destination == .phoneBrain || w.destination == .computerBrain else {
                    throw BrineStepError("straight-in launch still gated: \(String(describing: w.destination))")
                }
                guard w.surface == WelcomeFrontDoor.Surface.none else {
                    throw BrineStepError("a welcome rendition still fronts: \(String(describing: w.surface))")
                }
            },
            defineCheck("the connection to my computer still shows inside the app") { _, _, _ in
                // Settings → Brain → "My computer" renders this same mapping in-app.
                guard let s = WelcomeFrontDoor.connectStatus(w.status, email: w.email) else {
                    throw BrineStepError("no in-app connection status for \(w.status)")
                }
                guard !s.text.isEmpty else { throw BrineStepError("empty in-app connection status") }
            },
            defineCheck("the welcome page fronts the app with the sign-in choices") { _, _, _ in
                guard w.destination == .signInGate, w.surface == .welcomeSignIn else {
                    throw BrineStepError("expected the sign-in welcome front door, got \(String(describing: w.surface))")
                }
            },
            defineCheck("the welcome page fronts the app with the sign-in choices again") { _, _, _ in
                guard w.destination == .signInGate, w.surface == .welcomeSignIn else {
                    throw BrineStepError("mid-session sign-out dead-ended: dest=\(String(describing: w.destination)) surface=\(String(describing: w.surface))")
                }
            },
            defineCheck("onboarding continues without repeating the welcome") { _, _, _ in
                guard w.firstRun == .onboarding(skipWelcome: true) else {
                    throw BrineStepError("expected onboarding that skips its welcome step, got \(String(describing: w.firstRun))")
                }
            },
        ]
    }
}
