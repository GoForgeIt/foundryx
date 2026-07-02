// AskFoundryXIntent — the Siri / Spotlight "Ask FoundryX" App Intent (H usefulness slice).
//
// "Hey Siri, Ask FoundryX…" (or the Shortcuts/Spotlight tile) opens the app and seeds a
// chat with the spoken question — your Foundry answers it. Mirrors the capture Live
// Activity's broker pattern (Widget/CaptureIntents.swift): the intent PERFORMS in the app
// process and routes through a tiny process-wide broker that the app wires to the live
// ChatBridge (in RootView). Nothing here talks to ChatBridge directly — the broker is the
// only seam, so this file never depends on the chat internals.
//
// AppIntents + AppShortcutsProvider both landed in iOS 16.0, which is the app's minimum
// deployment target, so no `@available` gate is required (compare Widget/CaptureIntents,
// whose `LiveActivityIntent` needs iOS 17+). The `#if canImport(AppIntents)` guard mirrors
// the codebase idiom and keeps the broker itself buildable even where AppIntents is absent.

import Foundation

/// Process-wide broker between the "Ask FoundryX" App Intent and the live chat surface.
/// The app installs a handler (→ ChatBridge) once the tabs mount; the intent calls
/// `perform(_:)`. Mirrors `CaptureIntentBroker`. Main-actor isolated because the handler
/// mutates main-actor chat state.
///
/// Cold-launch safety: a Siri invocation can run `perform()` BEFORE the tabs have mounted
/// and installed a handler (the app is still restoring / gated). In that window the question
/// is buffered and flushed the moment a handler is set (see `handler`'s `didSet`), so a
/// spoken question is never dropped.
@MainActor
public final class AskIntentBroker {
    public static let shared = AskIntentBroker()
    private init() {}

    /// The app's handler (wired in RootView to `ChatBridge.askAbout`). Setting it flushes any
    /// question that arrived before the app was ready.
    public var handler: ((String) -> Void)? {
        didSet {
            guard let handler, let q = pending else { return }
            pending = nil
            handler(q)
        }
    }
    private var pending: String?

    /// Route a question to the chat surface, or buffer it until a handler is installed.
    public func perform(_ question: String) {
        if let handler {
            handler(question)
        } else {
            pending = question
        }
    }
}

#if canImport(AppIntents)
import AppIntents

/// "Ask FoundryX" — open the app and seed a chat with the user's question. `question` is
/// optional so the bare phrase ("Ask FoundryX") still works; when omitted (or blank) it
/// falls back to a useful default the app already knows how to answer.
struct AskFoundryXIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask FoundryX"
    static let description = IntentDescription(
        "Ask your Foundry a question and open FoundryX to the answer.")
    // Foreground the app so the seeded chat is visible and the answer streams in.
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask your Foundry?")
    var question: String?

    init() {}
    init(question: String?) { self.question = question }

    @MainActor
    func perform() async throws -> some IntentResult {
        let trimmed = question?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = (trimmed?.isEmpty == false) ? trimmed! : "What did I agree to today?"
        AskIntentBroker.shared.perform(ask)
        return .result()
    }
}

/// Registers the natural-language phrases so "Ask FoundryX…" works from Siri, Spotlight,
/// and the Shortcuts app with zero user setup. `\(.applicationName)` resolves to "FoundryX".
struct FoundryXAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskFoundryXIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Ask \(.applicationName) about my day",
                "Ask \(.applicationName) what I agreed to",
            ],
            shortTitle: "Ask FoundryX",
            systemImageName: "sparkles"
        )
    }
}
#endif
