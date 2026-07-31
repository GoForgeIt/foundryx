// AuthExpiryRouter — one place that turns "the server rejected our sign-in" into
// "you are signed out", instead of every screen inventing its own red text.
//
// Nick, 2026-07-30: "if sign in expires shouldn't it put the user back on login page".
// Yes — and it did not. Each surface discovered auth failure locally and rendered a
// message: the Vault funnel said "your sign-in expired", account deletion said "check
// your connection", and the app carried on as though signed in. So a dead session looked
// like a different, unrelated bug on every screen you happened to be standing on, and the
// one action that fixes it — signing in again — was never offered.
//
// A 401 is not a per-screen cosmetic problem. It is a fact about the SESSION, and the
// session is the thing that should react.

import Foundation

/// Observes auth failures from anywhere and drives the app to signed-out exactly once.
@MainActor
public final class AuthExpiryRouter: ObservableObject {
    public static let shared = AuthExpiryRouter()

    /// Installed by RootView: end the session and return to the front door.
    public var onExpired: (() -> Void)?

    /// The generation that was live when we last routed, so a burst of 401s from several
    /// in-flight requests signs the user out ONCE rather than N times — and so a 401 that
    /// belongs to an already-replaced identity is ignored rather than kicking the NEW one.
    private var lastRoutedGeneration: UInt64?

    private init() {}

    /// Report that the server rejected this session's credentials.
    ///
    /// Callers pass the generation the request was signed under. A stale generation means
    /// the account already changed and this rejection is about someone who is gone.
    public func authRejected(generation: UInt64) {
        guard generation == CaptureAccountScope.identityGeneration else { return }
        guard lastRoutedGeneration != generation else { return }
        lastRoutedGeneration = generation
        onExpired?()
    }

    /// Clear the latch when a fresh identity takes over, so a later expiry routes again.
    public func identityChanged() { lastRoutedGeneration = nil }
}
