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

    func run(seed: String) {
        pendingSeed = seed
        onNavigate?()
        Self.logOutcome("run", seed: seed)
    }

    /// Tapping an answer notification opens the full answer surface.
    func showAnswer(_ answer: AmbientAnswer) {
        pendingAnswer = answer
    }

    nonisolated static func dismissed(seed: String) {
        logOutcome("dismissed", seed: seed)
    }

    /// Card outcomes: one JSONL line each — accepted cards are the router's true
    /// positives; dismissed cards its labeled false positives (council gold).
    nonisolated private static func logOutcome(_ outcome: String, seed: String) {
        let url = CaptureWAL.documentsCaptures().appendingPathComponent("ambient-cards.jsonl")
        let line = (try? JSONSerialization.data(withJSONObject: [
            "ts": Int(Date().timeIntervalSince1970), "outcome": outcome,
            "seed": String(seed.prefix(300)),
        ])) ?? Data()
        guard !line.isEmpty else { return }
        var out = line
        out.append(UInt8(ascii: "\n"))
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: out)
        } else {
            try? out.write(to: url)
        }
    }
}
