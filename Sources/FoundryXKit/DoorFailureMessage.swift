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
    ///   - destination: WHICH BRAIN this account resolved to. It is required, and there is
    ///     no default: these sentences send a person somewhere to fix something, and the
    ///     Mac-only spellings below told a Vault owner to "Open Solleva on your Mac" — an
    ///     instruction that looks actionable and cannot be acted on.
    public static func make(status: RemoteSession.Status, underlying: String?,
                            destination: CaptureDestination) -> DoorFailureMessage {
        switch status {
        case .deletionCleanupPending:
            // An account-state problem, never a transport one — saying "check your
            // connection" here would be the same lie this whole area exists to stop.
            return DoorFailureMessage(
                text: "Deleting this account never finished on this iPhone.",
                action: "Finish deleting it to use this account again.")
        case .deletionCleanupInProgress:
            return DoorFailureMessage(
                text: WelcomeFrontDoor.signInRecoveryPresentation(status)?.text
                    ?? "Finishing the previous deletion…",
                action: nil)
        case .deletionCleanupFailed:
            return DoorFailureMessage(
                text: WelcomeFrontDoor.signInRecoveryPresentation(status)?.text
                    ?? "The previous deletion is still incomplete.",
                action: "Retry cleanup")
        case .deletionCleanupSucceeded:
            return DoorFailureMessage(
                text: "Previous deletion finished. Continuing sign-in…",
                action: nil)
        case .signedOut:
            // Post-2026-07-23 this should be unreachable from inside the app (RootGate now
            // requires sign-in), but it stays honest rather than falling through to a
            // network string if any path ever reaches it again.
            return DoorFailureMessage(
                text: "You're signed out.",
                action: destination.brainSubject.map { "Sign in to reach \($0)." })
        case .unconfigured:
            return DoorFailureMessage(
                text: "Sign-in isn't available in this build.",
                action: nil)
        case .noHost:
            switch destination {
            case .phone:
                return DoorFailureMessage(
                    text: "This phone is your only brain, so there is nothing to connect to.",
                    action: nil)
            case .computer:
                return DoorFailureMessage(
                    text: "No computer is set up for this account yet.",
                    action: "Open Solleva on your Mac and sign in with the same account.")
            case .vault:
                return DoorFailureMessage(
                    text: "No Vault is set up for this account yet.",
                    action: "Set up your Vault in Settings, signed in with the same account.")
            }
        case .resolving:
            return DoorFailureMessage(
                text: destination.brainSubject.map { "Still connecting to \($0)…" }
                    ?? "Still getting ready…",
                action: "This should only take a moment.")
        case .connected, .error:
            // The session believes a host is designated, so the failure is the TUNNEL or the
            // door itself — not the phone's network, and not the account. This is exactly the
            // case that used to read as "Could not connect to the server": the relay resolved
            // the host fine and the dial failed because nothing was listening on the Mac end.
            return DoorFailureMessage(
                text: destination.brainSubject.map { subject in
                    let s = subject.prefix(1).uppercased() + subject.dropFirst()
                    return "\(s) isn't connected right now."
                } ?? "This phone's own storage didn't answer.",
                action: destination.wakeAction)
        }
    }

    /// For call sites that hold no `RemoteSession` (most detail views hold only the
    /// `CaptureManager`). Since sign-in is now REQUIRED to reach any of these surfaces
    /// (`RootGate`, corrected 2026-07-23), a transport failure on a door request can only
    /// mean the desktop door is not reachable — the account and host questions are already
    /// settled by the time the user is looking at this screen. So this says the one true,
    /// actionable thing instead of forwarding a transport string.
    public static func make(doorTransportFailure: Error,
                            destination: CaptureDestination) -> DoorFailureMessage {
        DoorFailureMessage(
            text: destination.brainSubject.map { subject in
                let s = subject.prefix(1).uppercased() + subject.dropFirst()
                return "\(s) isn't connected right now."
            } ?? "This phone's own storage didn't answer.",
            action: destination.wakeAction)
    }

    /// For a failed read of Kiln's SHARED conversation library.
    ///
    /// The door deliberately distinguishes "I hold no kiln-session URL at all" (503) from "I
    /// could not reach the session" (502), and NEITHER is ever degraded to an empty list —
    /// because an empty list reads on the phone as "you have no conversations" when the truth
    /// is "the door could not ask". That distinction survives all the way to the sentence the
    /// user reads: a stopped Kiln is a different, differently-fixable thing from a sleeping
    /// Mac. No status code, no NSError domain, and above all no "no conversations" ever
    /// appears in any of these.
    public static func make(kilnLibraryFailure: KilnLibraryError,
                            destination: CaptureDestination) -> DoorFailureMessage {
        let subject = destination.brainSubject ?? "this phone"
        let capitalised = subject.prefix(1).uppercased() + subject.dropFirst()
        switch kilnLibraryFailure {
        case .noSession:
            // The door answered — so the brain IS reachable. What is missing is Kiln itself.
            return DoorFailureMessage(
                text: "Kiln isn't running on \(subject) right now.",
                action: destination == .computer
                    ? "Open Solleva on your Mac and start Kiln."
                    : destination.wakeAction)
        case .unreachable, .http:
            return DoorFailureMessage(
                text: "\(capitalised) couldn't reach Kiln right now.",
                action: destination.wakeAction)
        case .unauthorized:
            return DoorFailureMessage(
                text: "You're signed out.",
                action: destination.brainSubject.map { "Sign in to reach \($0)." })
        }
    }

    /// The single line a compact surface renders (text + action joined).
    public var line: String { action.map { "\(text) \($0)" } ?? text }
}
