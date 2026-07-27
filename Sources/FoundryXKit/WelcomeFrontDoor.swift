// WelcomeFrontDoor — the front-door rule (track 20260715T1502, re-cut 2026-07-17).
//
// Nick (2026-07-16): the OLD connection intro page (SignInView) must NOT appear
// as a gate on ANY path; the welcome surface is the front door; connection
// status lives ON the welcome or inside the app — never a blocking interstitial.
//
// This file is the pure, tested core of that contract: which rendition of the
// welcome fronts the app, what the live connection line says, and how the
// first-run ladder presents after entry — so the App-target wiring renders FROM
// these rules instead of re-deriving them.

import Foundation

/// A quiet, live connection status shown on the welcome when it doubles as the
/// post-sign-in CONNECT gate. nil = no pill (first-run flow, Settings explorer).
public struct WelcomeConnectStatus: Equatable, Sendable {
    public let text: String
    /// true once the connection settled (connected / on-phone) → a calm sage dot;
    /// false while still resolving → a working amber dot.
    public let settled: Bool

    public init(text: String, settled: Bool) {
        self.text = text
        self.settled = settled
    }
}

public enum WelcomeFrontDoor {

    /// Which rendition of the welcome fronts the `.signInGate` destination.
    public enum Surface: Equatable, Sendable {
        /// Signed out: the welcome carries the sign-in provider buttons —
        /// the old SignInView never gates.
        case welcomeSignIn
        /// Signed in, not opted out, not yet entered: the welcome carries the
        /// live connect pill + "Take me in" / "Skip the welcome".
        case welcomeConnectGate
        /// No gate at all — straight into the app (opted out, or already entered).
        case none
    }

    /// The front-door rule. Deliberately has NO `onboarded` input: a fresh
    /// signed-in install meets the same welcome gate; the double welcome is
    /// prevented by `firstRunPresentation` (the onboarding flow skips its
    /// internal welcome step once the gate marked it seen).
    ///
    /// ORDER MATTERS (implement-review F1): `signedIn` is checked BEFORE
    /// `entered` — a mid-session sign-out (Settings → Sign out) must land on the
    /// sign-in welcome (provider buttons), not a dead-ended button-less welcome.
    /// `entered` only suppresses the connect gate for the still-signed-in user,
    /// so a mid-session re-sign-in goes straight back into the app.
    public static func surface(signedIn: Bool,
                               letStraightIn: Bool,
                               entered: Bool) -> Surface {
        // SIGN-IN IS REQUIRED FIRST (locked decision #5, mirrors RootGate — Nick
        // 2026-07-24). `letStraightIn` ("Open straight to the app" / "Skip the
        // welcome") only skips the WELCOME for an ALREADY-authenticated user; it must
        // never short-circuit a signed-OUT gate to `.none`. Build 288 checked
        // letStraightIn first, so signing out after skipping the welcome left a DEAD
        // front door — no provider buttons, no working action, no way back in.
        if !signedIn { return .welcomeSignIn }
        if letStraightIn { return .none }
        return entered ? .none : .welcomeConnectGate
    }

    /// The live connection line for the connect-gate pill, from the remote
    /// session status. nil while signed out / unconfigured (no pill).
    public static func connectStatus(_ status: RemoteSession.Status,
                                     email: String?) -> WelcomeConnectStatus? {
        switch status {
        case .resolving:
            return WelcomeConnectStatus(text: "Connecting to your computer…", settled: false)
        case .connected:
            let suffix = email.map { " · \($0)" } ?? ""
            return WelcomeConnectStatus(text: "Connected" + suffix, settled: true)
        case .noHost:
            return WelcomeConnectStatus(text: "On your phone", settled: true)
        case .error:
            return WelcomeConnectStatus(text: "Couldn't reach your computer", settled: false)
        case .signedOut, .unconfigured:
            return nil
        }
    }

    /// The caption under the sign-in buttons on the welcome front door.
    /// nil = nothing to say (the buttons speak for themselves).
    public static func signInCaption(_ status: RemoteSession.Status) -> String? {
        switch status {
        case .unconfigured: return "Sign-in isn't available in this build."
        case .resolving: return "Signing in…"
        case .error(let message): return message
        case .signedOut, .connected, .noHost: return nil
        }
    }

    // MARK: - The post-entry first-run ladder (plan-review F1: pure + tested)

    /// What presents after the user enters the app (B2 ladder, welcome-gate aware).
    public enum FirstRunPresentation: Equatable, Sendable {
        /// The full onboarding flow; `skipWelcome` = its internal welcome step is
        /// skipped because the gate already was the welcome (never twice — AC3/AC4).
        case onboarding(skipWelcome: Bool)
        /// The standalone persona welcome (established installs that never saw it).
        case standaloneWelcome
        case none
    }

    /// The single decision `presentFirstRunSurfacesIfNeeded` renders from.
    /// `enterApp()` marks the welcome seen BEFORE calling this — so a gate entry
    /// can never re-present the welcome (`welcomeSeen == true` ⇒ never
    /// `.standaloneWelcome`, and any onboarding skips its welcome step).
    public static func firstRunPresentation(letStraightIn: Bool,
                                            onboardingCompleted: Bool,
                                            welcomeSeen: Bool) -> FirstRunPresentation {
        // Honor "take me straight in" — no ceremony of any kind.
        if letStraightIn { return .none }
        if OnboardingGate.shouldPresent(signedIn: true, completed: onboardingCompleted) {
            return .onboarding(skipWelcome: welcomeSeen)
        }
        if WelcomeGate.shouldPresent(signedIn: true,
                                     onboardingWillPresent: false,
                                     welcomeSeen: welcomeSeen) {
            return .standaloneWelcome
        }
        return .none
    }

    /// The exact current-owner decision rendered by RootView. Keeping the account
    /// readers inside this tested presentation seam prevents the App target from
    /// accidentally substituting phone-global compatibility values.
    public static func firstRunPresentationForCurrentOwner()
        -> FirstRunPresentation
    {
        firstRunPresentation(
            letStraightIn: WelcomePrefs.letStraightIn(),
            onboardingCompleted: AccountPreferences.value(
                AccountPreferenceCatalog.onboardingCompleted,
                default: false),
            welcomeSeen: WelcomePrefs.seen())
    }
}
