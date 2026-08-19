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
        // A CHOSEN BRAIN THAT DID NOT RESOLVE IS NOT A REASON TO STOP SENDING AUDIO
        // ANYWHERE.
        //
        // This gate had no rung between "my computer" and "nothing ever leaves the
        // phone". An owner who chose the computer brain and walked off his LAN fell all
        // the way to the tier whose uploads are self-issued ACKs — while a vault sat
        // paired, reachable, and holding that same phone's other recordings. That is the
        // divergence: recordings brought over in the app reached the vault; ambient
        // recordings made in the same window reached nowhere and were written down as
        // done. The vault was never consulted because it was not the CHOSEN brain.
        //
        // The degrade is deliberately scoped to a brain that ASKED for a destination.
        // `.justMyPhone` is a promise of zero content egress, and a paired vault must
        // never override it — this rung is for a choice that failed to resolve, never
        // for a choice that was honoured.
        if brain != .justMyPhone, cellPaired { return .cellBrain }
        return .phoneBrain
    }
}

/// WHERE A FINISHED VOICE NOTE ACTUALLY LANDS.
///
/// THIS TYPE EXISTS BECAUSE THE ANSWER WAS A BOOLEAN AND THE QUESTION HAS THREE ANSWERS.
/// `RootGate` has resolved to three brains since rung 3 shipped, but every surface that
/// wanted to NAME the destination asked `local: Bool` — "is this the phone-only tier?".
/// `.computerBrain` and `.cellBrain` both answer that question `false`, byte-identically,
/// so a Vault owner with no computer read "All voice notes saved to computer" on his
/// capture page and a unit test pinned the sentence in place.
///
/// It is deliberately DERIVED from `RootDestination` rather than from `BrainChoice`: a
/// brain that was CHOSEN but did not resolve (a picked computer with no reachable host, a
/// picked cloud with no paired cell) degrades to the phone, and the sentence has to
/// degrade with it. Naming a place from an unresolved choice is the same defect one layer
/// up.
public enum CaptureDestination: String, Equatable, Sendable, CaseIterable {
    /// The phone-only tier. The phone holds the only copy; there is no other place to name.
    case phone
    /// The user's own desktop Foundry, over the relayed door.
    case computer
    /// A hosted Foundry cell — "your Vault" in every word the product uses for it.
    case vault
}

public extension RootDestination {
    /// The destination this resolved brain actually writes to, or `nil` for a destination
    /// that is not running the app at all (the sign-in gate has nowhere to save anything,
    /// and must not be given a default that reads like a place).
    var captureDestination: CaptureDestination? {
        switch self {
        case .computerBrain: return .computer
        case .cellBrain:     return .vault
        case .phoneBrain:    return .phone
        case .signInGate:    return nil
        }
    }
}
