/// Turns a door-request failure into something TRUE and ACTIONABLE for the user.
///
/// Why this exists (Nick, 2026-07-23): a door fetch that failed because the desktop door
/// was not connected to the relay surfaced as the raw system string
/// **"Couldn't load transcript: Could not connect to the server."** That sentence is not
/// false, but it is useless and it is misdirecting: it reads as "the network is down" when
/// the actual state is "your computer isn't connected" (or, before the sign-in gate was
/// fixed, "you're signed out"). It cost hours of chasing a phantom connectivity bug on a
/// phone whose network was perfect the whole time.
///
/// The rule: NEVER show a transport error where an account/host state is what the user can
/// actually act on. Pure + UI-free so the mapping is tested directly.
public struct DoorFailureMessage: Equatable, Sendable {
    /// One plain sentence naming the REAL state.
    public let text: String
    /// What the user can do about it, when there is something. nil = nothing useful to add.
    public let action: String?

    /// - Parameters:
    ///   - status: the live remote-session status — the authority on account/host state.
    ///   - underlying: the transport error's `localizedDescription`, used ONLY as a last
    ///     resort when the session status explains nothing.
    public static func make(status: RemoteSession.Status, underlying: String?) -> DoorFailureMessage {
        switch status {
        case .deletionCleanupPending:
            // An account-state problem, never a transport one — saying "check your
            // connection" here would be the same lie this whole area exists to stop.
            return DoorFailureMessage(
                text: "Deleting this account never finished on this iPhone.",
                action: "Finish deleting it to use this account again.")
        case .signedOut:
            // Post-2026-07-23 this should be unreachable from inside the app (RootGate now
            // requires sign-in), but it stays honest rather than falling through to a
            // network string if any path ever reaches it again.
            return DoorFailureMessage(
                text: "You're signed out.",
                action: "Sign in to reach your computer.")
        case .unconfigured:
            return DoorFailureMessage(
                text: "Sign-in isn't available in this build.",
                action: nil)
        case .noHost:
            return DoorFailureMessage(
                text: "No computer is set up for this account yet.",
                action: "Open Foundry on your Mac and sign in with the same account.")
        case .resolving:
            return DoorFailureMessage(
                text: "Still connecting to your computer…",
                action: "This should only take a moment.")
        case .connected, .error:
            // The session believes a host is designated, so the failure is the TUNNEL or the
            // door itself — not the phone's network, and not the account. This is exactly the
            // case that used to read as "Could not connect to the server": the relay resolved
            // the host fine and the dial failed because nothing was listening on the Mac end.
            return DoorFailureMessage(
                text: "Your computer isn't connected right now.",
                action: "Open Foundry on your Mac and make sure it's awake.")
        }
    }

    /// For call sites that hold no `RemoteSession` (most detail views hold only the
    /// `CaptureManager`). Since sign-in is now REQUIRED to reach any of these surfaces
    /// (`RootGate`, corrected 2026-07-23), a transport failure on a door request can only
    /// mean the desktop door is not reachable — the account and host questions are already
    /// settled by the time the user is looking at this screen. So this says the one true,
    /// actionable thing instead of forwarding a transport string.
    public static func make(doorTransportFailure: Error) -> DoorFailureMessage {
        DoorFailureMessage(
            text: "Your computer isn't connected right now.",
            action: "Open Foundry on your Mac and make sure it's awake.")
    }

    /// The single line a compact surface renders (text + action joined).
    public var line: String { action.map { "\(text) \($0)" } ?? text }
}
