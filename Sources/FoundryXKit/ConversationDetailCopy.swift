// ConversationDetailCopy — the conversation detail's tier-varying sentences, moved out
// of the SwiftUI body that `swift test` cannot compile.
//
// WHY (X2, cross-vendor review 2026-08-19). Two sentences on the transcript face named a
// computer with no tier consulted at all, while `destination` sat IN SCOPE four lines
// away and was being passed to the waits either side of them:
//
//   • "On-device transcript, finishing on your computer."   selected by `showingProvisional`
//     ALONE — so a Vault owner reading a provisional transcript was told his Mac would
//     finish it, and a phone-only owner was told a computer would finish something that
//     is never leaving his handset.
//   • "Load this voice note's transcript from your computer." branching only on `isOlder`.
//
// A sentence written inside a view body is a sentence no test in this repository can
// execute. These live here instead, exhaustive over `CaptureDestination`, so a fourth
// tier fails to compile until it picks its words and `ConversationDetailCopyTests` sweeps
// them the way the waits are swept.

import Foundation

public enum ConversationDetailCopy {

    /// The note above a PROVISIONAL transcript: this phone wrote what you are reading, and
    /// the authoritative one is still being produced by the place this account saves to.
    /// On the phone tier there is no elsewhere — the on-device transcript IS the transcript.
    public static func provisionalTranscriptNote(destination: CaptureDestination) -> String {
        switch destination {
        case .phone:
            return "On-device transcript — this phone wrote it, and it is the only copy."
        case .computer:
            return "On-device transcript, finishing on your computer."
        case .vault:
            return "On-device transcript, finishing in your Vault."
        }
    }

    /// The empty-transcript explainer + its call to action. `isOlder` says the transcript
    /// was never cached here; the tier says where it would be loaded FROM.
    public static func loadTranscriptNote(isOlder: Bool,
                                          destination: CaptureDestination) -> String {
        switch destination {
        case .phone:
            return isOlder
                ? "This is an older voice note, and its transcript isn't on this phone any more."
                : "This voice note's transcript isn't on this phone yet."
        case .computer:
            return isOlder
                ? "This is an older voice note, so its transcript isn't stored on your phone. "
                    + "Load it from your computer."
                : "Load this voice note's transcript from your computer."
        case .vault:
            return isOlder
                ? "This is an older voice note, so its transcript isn't stored on your phone. "
                    + "Load it from your Vault."
                : "Load this voice note's transcript from your Vault."
        }
    }
}

/// THE ONE LINE UNDER THE SIGN-IN SCREEN, WHICH IS SHOWN BEFORE ANY TIER EXISTS.
///
/// X5: it read "End-to-end encrypted to your Mac · you choose what stays private",
/// UNCONDITIONALLY, on a screen that runs BEFORE a brain is resolved. It was false for a
/// Vault owner, false for a phone-only owner, and false for every brand-new user who has
/// not chosen anything yet — which is everyone who sees it.
///
/// The honest answer to "which place" before sign-in is NOT a place. `nil` is a real
/// input here and it produces a sentence that claims custody without naming hardware,
/// which is the only claim that is true of all three tiers at once.
public enum SignInCustodyLine {

    /// - Parameter destination: the resolved tier, or `nil` when none is resolved yet —
    ///   which is the normal case on the sign-in screen.
    public static func text(destination: CaptureDestination?) -> String {
        guard let destination else {
            return "End-to-end encrypted to your own devices · you choose what stays private"
        }
        switch destination {
        case .phone:
            return "Kept on this iPhone · you choose what stays private"
        case .computer:
            return "End-to-end encrypted to your Mac · you choose what stays private"
        case .vault:
            return "End-to-end encrypted to your Vault · you choose what stays private"
        }
    }
}
