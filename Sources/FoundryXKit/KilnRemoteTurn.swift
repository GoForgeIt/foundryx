import Foundation

// One turn, into a chat that lives on the Mac.
//
// This is the ONLY place the phone sends into a Mac chat, and it is here rather than in a
// view so that "typing is how you continue" is a contract a scenario can drive through the
// real `DoorClient` instead of a claim about a button.

/// Sending into a chat that lives on the Mac.
public enum KilnRemoteTurn {

    /// Send one turn, resuming the chat in place first if it has never been picked up.
    ///
    /// THE READER ONLY TYPES. A chat brought over from Claude Code or Codex has history but
    /// no live session behind it; its first turn has to resume it. That resume is part of
    /// sending, not a separate thing to press — the phone was asking for a ceremony the
    /// desktop never asks for, and the ceremony left you on a screen with no composer.
    ///
    /// RESUME-IN-PLACE: `kilnContinueChat` refuses a reply naming a different id, so reaching
    /// the send means the turn is going into the SAME chat that was being read — no fork, no
    /// copy, no second row.
    ///
    /// Returns the plan for the NEXT turn: a chat is picked back up exactly once.
    @MainActor
    @discardableResult
    public static func send(
        text: String,
        row: LibraryChatRow,
        plan: KilnConversationPresentation.SendPlan,
        client: DoorClient,
        platform: String = "foundryx",
        onResumed: () -> Void = {},
        onEvent: (DoorEvent) -> Void
    ) async throws -> KilnConversationPresentation.SendPlan {
        if plan == .resumeInPlaceThenSend {
            _ = try await client.kilnContinueChat(chatId: row.id)
            // Announced the moment it lands, not at the end: if the turn that follows fails
            // on the wire, the chat is STILL live, and a caller that only learned about the
            // resume from a successful return would resume it a second time on the retry.
            onResumed()
        }
        let request = KilnConversationPresentation.request(row, text: text, platform: platform)
        for try await event in client.events(for: request) {
            onEvent(event)
        }
        return KilnConversationPresentation.planAfterSending(plan)
    }
}
