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

public extension CaptureDestination {

    /// THE SECOND PLACE, NAMED ONCE FOR THE WHOLE PROGRAM.
    ///
    /// Every surface that has to say "the OTHER place your things live" used to write the
    /// word "Mac" into its own sentence, because when they were written there was only one
    /// other place. There are two now, and one tier has none at all — so the phrase is a
    /// property of the tier, answered here, and `nil` is a real answer: on the phone tier
    /// there is no second place, and a sentence about one must not be written.
    var secondPlace: String? {
        switch self {
        case .phone:    return nil
        case .computer: return "your Mac"
        case .vault:    return "your Vault"
        }
    }

    /// The possessive form — "your Mac's chats", "your Vault's chats".
    var secondPlacePossessive: String? {
        switch self {
        case .phone:    return nil
        case .computer: return "your Mac's"
        case .vault:    return "your Vault's"
        }
    }

    /// The second place as the SUBJECT of a connectivity sentence. The computer tier says
    /// "your computer" here rather than "your Mac": the point is the machine answering,
    /// not which one it is.
    var brainSubject: String? {
        switch self {
        case .phone:    return nil
        case .computer: return "your computer"
        case .vault:    return "your Vault"
        }
    }

    /// WHAT A PERSON CAN ACTUALLY DO when the second place is not answering. This is the
    /// sentence that mattered most: a Vault owner was told "Open Solleva on your Mac and
    /// make sure it's awake" — sent to go and fix a machine he does not own, which is
    /// worse than saying nothing, because it looks like an instruction that should work.
    var wakeAction: String? {
        switch self {
        case .phone:    return nil
        case .computer: return "Open Solleva on your Mac and make sure it's awake."
        case .vault:    return "Check your Vault in Settings — it may still be waking up."
        }
    }
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

    /// THE SAME MAPPING, TOTAL, FOR THE ONE CALLER THAT IS ALREADY ON SCREEN.
    ///
    /// THIS EXISTS BECAUSE THE MAPPING ABOVE HAD NO PRODUCTION CALLER. It was written,
    /// correct, and pinned by `SyncBarPresenterTests` — and `App/RootView.swift` named the
    /// place with three hand-written literals anyway — `.computer`, `.vault`, `.phone`,
    /// one per brain arm. A tested table nothing consults is decorative. `swift test` cannot
    /// compile `App/`, so flipping any one of those literals compiled, shipped, and passed
    /// every gate in this repository while an entire tier read another tier's words. The
    /// only cure is that the App has nothing left to restate: it asks for the place, and
    /// the answer is decided HERE, where a test can execute it.
    ///
    /// It is total because a view already on screen has to draw SOMETHING. `.signInGate`
    /// never mounts the tabs, and if it somehow did it would take the phone's words — the
    /// only tier that names no second place at all — rather than inventing a Mac or a
    /// Vault for a user who has not even signed in.
    var captureDestinationOnScreen: CaptureDestination {
        captureDestination ?? .phone
    }
}
