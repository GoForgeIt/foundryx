// AmbientCards — the confirm-first execution slice (track 20260710T2030 v3, Tier 3):
// a routed todo/workflow/agent candidate becomes an actionable notification
// ("Want me to X?" [Run][Dismiss]); RUN (or tapping the banner) opens the CHAT tab
// with a kiln conversation seeded from the moment — the user WATCHES the agent work
// in the chat page (Nick: "an action routes to a kiln chat in the chat page if
// accepted"). Dismiss does nothing. Every card outcome is appended to
// ambient-cards.jsonl (the scorer/council's accepted/dismissed gold set).

import Foundation
import SwiftUI
// (FoundryXKit types are same-module — the App target compiles Sources/FoundryXKit directly)

/// Process-wide bridge between the notification delegate and the chat UI.
/// The notification's RUN lands here; RootView installs `onNavigate` (→ chat tab);
/// ChatScreen observes `pendingSeed` and starts a seeded conversation.
@MainActor
final class AmbientCardBroker: ObservableObject {
    static let shared = AmbientCardBroker()
    private init() {}

    /// The seed text an accepted card wants sent as a new chat turn. ChatScreen
    /// consumes (and clears) it.
    @Published var pendingSeed: String?
    /// A delivered answer the user tapped — MainTabs presents the answer
    /// surface while this is set (features/ambient-answer-loop.feature).
    @Published var pendingAnswer: AmbientAnswer?
    /// Installed by RootView: navigate to the chat tab.
    var onNavigate: (() -> Void)?

    /// The accepted card's source conversation, when the call site knows it —
    /// the seeded chat's origin then carries the captureId (EXT3).
    var pendingSeedCaptureId: String?

    func run(
        seed: String,
        captureId: String? = nil,
        binding: CaptureAccountScope.AccountBinding? = nil
    ) {
        guard let binding = binding
                ?? CaptureAccountScope.currentAccountBinding() else { return }
        CaptureAccountScope.perform(as: binding) { captured in
            pendingSeedCaptureId = captureId
            pendingSeed = seed
            onNavigate?()
            Self.appendOutcome(
                "run", seed: seed, binding: captured)
        }
    }

    /// A seed to PRE-FILL the chat composer WITHOUT sending (the Actions face's
    /// "Act on it in chat", track 20260715T1500 addendum): the user reviews and
    /// edits before sending, and the `run` outcome is logged only when the
    /// seeded turn is ACTUALLY sent (`prefillSent`) — never on mere navigation.
    @Published var pendingPrefill: String?

    /// What the SENT prefill turn should record (EXT2/EXT3): the run outcome
    /// seed (nil for answer/user rows — they must never log a `run`), the
    /// action↔chat link keys, and the chat's provenance at creation.
    struct PrefillContext {
        /// Log `run` with this seed on actual send — nil ⇒ never log one.
        let runSeed: String?
        /// Link + origin keys (the source conversation and the acted utterance).
        let captureId: String?
        let utterance: String?
        /// The source conversation's category NAME at prefill time.
        let category: String?
    }
    var pendingPrefillContext: PrefillContext?

    func prefillChat(seed: String, context: PrefillContext) {
        pendingPrefillContext = context
        pendingPrefill = seed
        onNavigate?()
    }

    /// EXT2 — an action that already has a chat routes BACK to it. ChatScreen
    /// consumes (selects the conversation); RootView lands on the chat tab.
    @Published var pendingOpenChatId: String?
    /// Installed by RootView against the live ChatConversationStore: is this
    /// chat id still alive? Used to lazily prune dead action↔chat links.
    var isChatAlive: ((String) -> Bool)?

    func continueChat(id: String) {
        pendingOpenChatId = id
        onNavigate?()
    }

    /// The chat composer sent a turn that started from a prefill — NOW it's a
    /// run. Logs the ORIGINAL seed so the utterance join resolves even when the
    /// user edited the text before sending.
    nonisolated static func prefillSent(
        seed: String,
        binding: CaptureAccountScope.AccountBinding? = nil
    ) {
        logOutcome("run", seed: seed, binding: binding)
    }

    /// Tapping an answer notification opens the full answer surface.
    func showAnswer(_ answer: AmbientAnswer) {
        pendingAnswer = answer
    }

    /// Process-global presentation state must never survive an account boundary.
    /// Clear values and closures: the next account's MainTabs installs fresh hooks.
    func clearForIdentityTransition() {
        pendingSeed = nil
        pendingAnswer = nil
        onNavigate = nil
        pendingSeedCaptureId = nil
        pendingPrefill = nil
        pendingPrefillContext = nil
        pendingOpenChatId = nil
        isChatAlive = nil
    }

    nonisolated static func dismissed(
        seed: String,
        binding: CaptureAccountScope.AccountBinding? = nil
    ) {
        logOutcome("dismissed", seed: seed, binding: binding)
    }

    /// The Actions-face options sheet's feedback outcomes (track 20260715T1500
    /// addendum). The seed is the candidate's UTTERANCE so the existing
    /// seed-contains-utterance join resolves the row's state; the words ship to
    /// the desktop via the redacted ambient-signal channel (outcome only — the
    /// seed, like every seed, is dropped at the redaction map).
    nonisolated static func rejected(seed: String) {
        logOutcome("rejected", seed: seed)
    }

    nonisolated static func refined(seed: String) {
        logOutcome("refined", seed: seed)
    }

    /// Card outcomes: one JSONL line each — accepted cards are the router's true
    /// positives; dismissed cards its labeled false positives (council gold).
    nonisolated private static func logOutcome(
        _ outcome: String,
        seed: String,
        binding suppliedBinding: CaptureAccountScope.AccountBinding? = nil
    ) {
        guard let binding = suppliedBinding
                ?? CaptureAccountScope.currentAccountBinding() else { return }
        let line = (try? JSONSerialization.data(withJSONObject: [
            "ts": Int(Date().timeIntervalSince1970), "outcome": outcome,
            "seed": String(seed.prefix(300)),
        ])) ?? Data()
        guard !line.isEmpty else { return }
        var out = line
        out.append(UInt8(ascii: "\n"))
        CaptureAccountScope.perform(as: binding) { captured in
            appendOutcomeData(out, binding: captured)
        }
    }

    nonisolated private static func appendOutcome(
        _ outcome: String,
        seed: String,
        binding: CaptureAccountScope.AccountBinding
    ) {
        let line = (try? JSONSerialization.data(withJSONObject: [
            "ts": Int(Date().timeIntervalSince1970), "outcome": outcome,
            "seed": String(seed.prefix(300)),
        ])) ?? Data()
        guard !line.isEmpty else { return }
        var out = line
        out.append(UInt8(ascii: "\n"))
        appendOutcomeData(out, binding: binding)
    }

    nonisolated private static func appendOutcomeData(
        _ data: Data,
        binding: CaptureAccountScope.AccountBinding
    ) {
        let url = binding.root.appendingPathComponent("ambient-cards.jsonl")
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
