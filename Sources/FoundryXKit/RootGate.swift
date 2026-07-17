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
                                   hostResolved: Bool,
                                   letStraightIn: Bool = false) -> RootDestination {
        // "Take me straight in" (Nick 2026-07-16, track 20260715T1502): NO gate of any
        // kind — not the splash, not the welcome, never the old connection page. The app
        // opens immediately; a chosen computer brain is used the moment it resolves, and
        // connection status shows IN the app (Settings → Brain), not as an interstitial.
        if letStraightIn {
            if signedIn, brain == .myComputer, hostResolved { return .computerBrain }
            return .phoneBrain
        }
        guard splashElapsed else { return .signInGate }   // the welcome front door leads
        if !signedIn { return .signInGate }
        if brain == .myComputer, hostResolved { return .computerBrain }
        return .phoneBrain
    }
}
