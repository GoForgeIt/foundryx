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
    /// Rung 3: all tabs on a hosted CELL over its direct public HTTPS door.
    case cellBrain
    /// The phone-only tier: LocalBackend capture + local chat, zero egress.
    case phoneBrain
}

public enum RootGate {
    /// `cellPaired` is `CellStore.isPaired` — a Foundry-Cloud choice only resolves to
    /// the cell brain once a cell is actually paired; a chosen-but-unpaired cloud
    /// brain degrades to the phone brain (additive, never destructive — spec §4).
    public static func destination(signedIn: Bool,
                                   splashElapsed: Bool,
                                   brain: BrainChoice,
                                   hostResolved: Bool,
                                   letStraightIn: Bool = false,
                                   cellPaired: Bool = false) -> RootDestination {
        // SIGN-IN IS REQUIRED — ALWAYS. (Nick, 2026-07-23.)
        //
        // "Local-first" describes WHERE a user's data lives and is processed — on their
        // phone, no egress required. It has never meant the app is usable without an
        // identity: signing in is what PROTECTS that data, including locally on the phone.
        //
        // "Open straight to the app" (`letStraightIn`) means: an ALREADY-AUTHENTICATED user
        // does not have to see the welcome screen again. It is NOT an auth bypass. The
        // previous code conflated "no welcome, no splash" with "no sign-in" and fell through
        // to `.phoneBrain` when `signedIn == false`, so a signed-out phone could use the
        // whole app while every door-dependent feature (transcripts, chat, context) failed
        // with a misleading NETWORK error instead of "you're signed out". That cost hours of
        // chasing a phantom connectivity bug, and it contradicted this file's own header
        // ("Sign in FIRST — locked decision #5").
        if !signedIn { return .signInGate }
        // Authenticated. `letStraightIn` now controls only whether the WELCOME leads.
        if !letStraightIn {
            guard splashElapsed else { return .signInGate }   // the welcome front door leads
        }
        if brain == .myComputer, hostResolved { return .computerBrain }
        if brain == .foundryCloud, cellPaired { return .cellBrain }
        return .phoneBrain
    }
}
