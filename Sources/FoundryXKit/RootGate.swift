// RootGate — the pure first-launch routing rule (track 20260705T1100, Phase 6).
// Sign in FIRST (locked decision #5), then the app is WHOLE without a brain:
// "Just my phone" needs no desktop, no host, no network. The computer brain is
// used only when chosen AND resolved; a chosen-but-unreachable computer degrades
// to the phone brain with everything still readable (spec §4 — additive, never
// destructive).

import Foundation

public enum RootDestination: Equatable {
    /// The forced identity login (Apple / Google / Microsoft) + launch splash.
    case signInGate
    /// Today's flow: all tabs on the resolved remote door.
    case computerBrain
    /// The phone-only tier: LocalBackend capture + local chat, zero egress.
    case phoneBrain
}

public enum RootGate {
    public static func destination(signedIn: Bool,
                                   splashElapsed: Bool,
                                   brain: BrainChoice,
                                   hostResolved: Bool) -> RootDestination {
        guard signedIn, splashElapsed else { return .signInGate }
        if brain == .myComputer, hostResolved { return .computerBrain }
        return .phoneBrain
    }
}
