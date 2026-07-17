// ConversationActions — the pure model behind the conversation detail's Actions
// face (track 20260713T0904, features/conversation-detail.feature AC4): the action
// cards that surfaced DURING a conversation, each joined to what came of it.
//
// Data reality (both logs already exist; this file only READS them):
//   • ambient-decisions.jsonl (AmbientLane) — every gate decision, keyed by
//     captureId; `outcome == candidate` lines carry the surfaced moment.
//   • ambient-cards.jsonl (AmbientCardBroker) — one line per card outcome the
//     user produced: "run" (sent to chat) or "dismissed". Lines carry the chat
//     SEED text (which embeds the candidate's utterance), not a captureId — so
//     the join is: an outcome belongs to the candidate whose utterance its seed
//     contains. "answered" is parsed for forward-compat (a lookup card that
//     showed its answer); nothing writes it yet.
//
// No SwiftUI here — App/ConversationFacesView.swift renders the cards.

import Foundation

/// What came of an action card, in the vocabulary the Actions face renders.
public enum ActionOutcome: Equatable, Sendable {
    /// Surfaced, but the user hasn't decided yet (or never saw it).
    case pending
    /// The user ran it — the card seeded a chat turn ("run" in the log).
    case sentToChat
    /// The user dismissed it (the council's labeled false positive).
    case dismissed
    /// A lookup card that showed its answer from the user's memory.
    case answered
    /// The user marked it "Not an action" from the Actions face — the spotter's
    /// strongest labeled false positive (track 20260715T1500 addendum).
    case rejected

    /// Map the on-disk outcome word; anything unknown degrades to pending.
    public init(wire: String) {
        switch wire {
        case "run": self = .sentToChat
        case "dismissed": self = .dismissed
        case "answered": self = .answered
        case "rejected": self = .rejected
        default: self = .pending
        }
    }

    /// The state chip's label.
    public var label: String {
        switch self {
        case .pending: return "Waiting on you"
        case .sentToChat: return "Sent to chat"
        case .dismissed: return "Dismissed"
        case .answered: return "Answered"
        case .rejected: return "Not an action"
        }
    }
}

/// One parsed line of ambient-cards.jsonl.
public struct CardOutcomeRecord: Equatable, Sendable {
    public let ts: UInt64
    /// The raw outcome word ("run" | "dismissed" | future words).
    public let outcome: String
    /// The chat seed the card carried (embeds the candidate's utterance).
    public let seed: String

    public init(ts: UInt64, outcome: String, seed: String) {
        self.ts = ts
        self.outcome = outcome
        self.seed = seed
    }
}

/// One action card on the detail's Actions face: the moment that surfaced, and
/// what came of it. Carries its `captureId` so the card can link back to its
/// conversation from ANY surface that renders it.
public struct ConversationActionCard: Equatable, Sendable, Identifiable {
    public let captureId: String
    /// When the moment surfaced (the decision's ts, seconds).
    public let ts: UInt64
    /// The actionable line, as heard.
    public let utterance: String
    /// The gate's one-line summary of what could be done.
    public let summary: String
    public let outcome: ActionOutcome

    public var id: String { "\(ts)-\(utterance.prefix(60))" }

    public init(captureId: String, ts: UInt64, utterance: String,
                summary: String, outcome: ActionOutcome) {
        self.captureId = captureId
        self.ts = ts
        self.utterance = utterance
        self.summary = summary
        self.outcome = outcome
    }
}

public enum ConversationActions {
    /// The card-outcome log's filename (lives next to the capture WAL files).
    public static let outcomeLogFilename = "ambient-cards.jsonl"

    /// The action cards for ONE conversation: its candidate decisions (deduped —
    /// the same moment re-surfaced across growing windows folds into one card,
    /// keeping its first surfacing time), each joined to its latest logged
    /// outcome. Gated-no / skipped windows never produce a card.
    public static func cards(
        for captureId: String,
        decisions: [AmbientDecision],
        outcomes: [CardOutcomeRecord]
    ) -> [ConversationActionCard] {
        var seen = Set<String>()
        var cards: [ConversationActionCard] = []
        for d in decisions.sorted(by: { $0.ts < $1.ts })
        where d.captureId == captureId && d.outcome == .candidate {
            guard let c = d.candidate, !c.utterance.isEmpty,
                  !seen.contains(c.utterance) else { continue }
            seen.insert(c.utterance)
            cards.append(ConversationActionCard(
                captureId: captureId, ts: d.ts,
                utterance: c.utterance, summary: c.summary,
                outcome: outcome(forUtterance: c.utterance, in: outcomes)))
        }
        return cards
    }

    /// The latest outcome whose seed carries this utterance — the seed is the
    /// only join key the outcome log has (it embeds the utterance verbatim).
    /// No matching record means the card is still pending. `refined` lines are
    /// state-transparent: refining an action never changes what came of it
    /// (track 20260715T1500 addendum), so they are skipped here.
    private static func outcome(
        forUtterance utterance: String, in records: [CardOutcomeRecord]
    ) -> ActionOutcome {
        // Seeds are clipped to 300 chars in the log — clip the key the same way
        // so a long utterance still matches its truncated seed.
        let key = String(utterance.prefix(200))
        guard let hit = records.last(where: {
            $0.outcome != "refined" && $0.seed.contains(key)
        }) else {
            return .pending
        }
        return ActionOutcome(wire: hit.outcome)
    }

    /// Parse ambient-cards.jsonl: one record per well-formed line; garbage lines
    /// are skipped, a missing file reads as no outcomes.
    public static func readOutcomes(at url: URL) -> [CardOutcomeRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                  let outcome = obj["outcome"] as? String,
                  let seed = obj["seed"] as? String
            else { return nil }
            let ts = (obj["ts"] as? NSNumber)?.uint64Value ?? 0
            return CardOutcomeRecord(ts: ts, outcome: outcome, seed: seed)
        }
    }
}
