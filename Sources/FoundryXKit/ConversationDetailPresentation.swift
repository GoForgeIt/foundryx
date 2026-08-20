// ConversationDetailPresentation — the pure presentation models behind the
// conversation detail's Summary and Actions faces (track 20260714T1800
// ux_prototype_realignment §5, features/conversation-detail.feature @faces).
//
// The prototype (fullflow2.html renderDetail) shows:
//   • Summary face: a narrative lede, a "What mattered" bullet list, and an
//     "Open the relay answer" text action when an ambient answer is linked to
//     this capture.
//   • Actions face: a POPULATED list of the conversation's real surfaced items
//     (nudges, answers, open items) with the human outcome vocabulary
//     Completed / Ready / Open, plus an "Add an action" affordance. Empty state:
//     "Nothing surfaced from this conversation yet."
//
// Everything here is pure or file-backed (no SwiftUI) so the brine step-defs
// drive the REAL builders the view renders from (blocker resolution B1a).
// App/ConversationFacesView.swift is the thin wrapper.

import Foundation

// MARK: - Summary face

/// The Summary face's presentation: the "What mattered" bullets derived from
/// the summary text, plus the ambient answer linked to this capture (when one
/// surfaced) behind the "Open the relay answer" row.
public struct ConversationSummaryPresentation: Equatable, Sendable {
    /// The bullet list's label, exactly as the prototype renders it.
    public static let whatMatteredLabel = "What mattered"
    /// The linked-answer row's label, exactly as the prototype renders it.
    public static let openRelayAnswerLabel = "Open the relay answer"

    /// The "What mattered" bullets. Empty when the summary has fewer than two
    /// sentences (a one-line summary IS the lede — no list to repeat it).
    public let bullets: [String]
    /// The ambient answer linked to this capture — `nil` means NO answer row.
    public let linkedAnswer: LinkedConversationAnswer?

    public init(bullets: [String], linkedAnswer: LinkedConversationAnswer?) {
        self.bullets = bullets
        self.linkedAnswer = linkedAnswer
    }

    /// Build the face from the card/summary text + the answers surfaced from
    /// this capture (see `ConversationAnswerLog.answers`).
    public static func build(summary: String?,
                             linkedAnswers: [LinkedConversationAnswer]) -> Self {
        Self(bullets: bullets(fromSummary: summary), linkedAnswer: linkedAnswers.first)
    }

    /// Derive the "What mattered" bullets from the summary text: one bullet per
    /// sentence, capped at `limit`. A summary with fewer than two sentences
    /// yields NO bullets — the narrative lede already says it.
    public static func bullets(fromSummary summary: String?, limit: Int = 3) -> [String] {
        guard let summary, limit > 0 else { return [] }
        var sentences: [String] = []
        var current = ""
        for ch in summary {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        guard sentences.count >= 2 else { return [] }
        return Array(sentences.prefix(limit))
    }
}

/// An ambient answer that surfaced from a specific capture — what the Summary
/// face's "Open the relay answer" row opens.
public struct LinkedConversationAnswer: Equatable, Sendable {
    /// Short headline for the moment (the utterance that asked it).
    public let title: String
    /// The answer itself.
    public let text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

/// Read-only view over the delivered-answer log (ambient-answers.jsonl, written
/// by the notifier): the answers linked to ONE capture. Missing file or garbage
/// lines read as no answers — nothing is invented.
public enum ConversationAnswerLog {
    public static func answers(at url: URL, captureId: String) -> [LinkedConversationAnswer] {
        guard !captureId.isEmpty, let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                  obj["kind"] as? String == "answer",
                  obj["captureId"] as? String == captureId,
                  let answer = obj["answer"] as? String, !answer.isEmpty
            else { return nil }
            let utterance = (obj["utterance"] as? String) ?? ""
            return LinkedConversationAnswer(
                title: utterance.isEmpty ? "From your memory" : utterance,
                text: answer)
        }
    }
}

// MARK: - Actions face

/// The Actions face's presentation: rows built from the conversation's REAL
/// surfaced items — ambient nudges joined to their outcomes, delivered answers,
/// and the user's own added actions — in the prototype's outcome vocabulary.
public struct ConversationActionsPresentation: Equatable, Sendable {
    /// The empty state, per the prototype realignment.
    public static let emptyStateText = "Nothing surfaced from this voice note yet."
    /// The add affordance's label.
    public static let addActionLabel = "Add an action"
    /// The collapsed group holding actions OTHER people said (features/
    /// action-speaker-attribution.feature): detected, kept, one tap away — but
    /// out of the main list, which is yours.
    public static let othersGroupLabel = "Heard from others"

    public struct Row: Equatable, Sendable, Identifiable {
        /// Where the row came from — drives the icon, never shown as text.
        public enum Kind: String, Equatable, Sendable {
            /// An ambient nudge that surfaced during the conversation.
            case surfaced
            /// An answer compiled from the user's memory.
            case answer
            /// An action the user added by hand.
            case user
        }

        /// The human outcome word the state chip renders.
        public enum State: String, Equatable, Sendable {
            case completed = "Completed"
            case ready = "Ready"
            case open = "Open"
            case dismissed = "Dismissed"
            /// The user rejected it from the options sheet ("Not an action").
            case notAnAction = "Not an action"
        }

        public let id: String
        /// The row's primary line ("Send Sarah the deck").
        public let label: String
        /// The secondary line (the utterance, the asked question, provenance).
        public let meta: String?
        public let kind: Kind
        public let state: State
        /// The raw actionable line as heard — the feedback join key. Present
        /// only on rows the spotter surfaced (reject/refine make sense there).
        public let utterance: String?
        /// The user's latest refinement note, rendered on the row.
        public let note: String?
        /// The act-on-it-in-chat prefill. Nil means the row offers no chat action.
        public let seed: String?
        /// The outcome-log seed a SENT prefill records as a `run` — present ONLY
        /// on spotter-surfaced rows. Answer/user rows never log `run`: no nudge
        /// was accepted, and a fabricated `run` would poison the router's
        /// true-positive signal and the Activity ledger.
        public let runSeed: String?
        /// The chat this action was already acted on in (EXT2) — the options
        /// sheet then offers "Continue in chat →" instead of a fresh prefill.
        /// Nil when never acted on (or the linked chat was deleted).
        public let linkedChatId: String?
        /// WHO said it (surfaced rows only; nil on answer/user rows, where
        /// attribution is meaningless and no line renders).
        public let attribution: ActionAttribution?
        /// True when the item is finished.
        public var done: Bool { state == .completed }

        public init(id: String, label: String, meta: String?, kind: Kind, state: State,
                    utterance: String? = nil, note: String? = nil, seed: String? = nil,
                    runSeed: String? = nil, linkedChatId: String? = nil,
                    attribution: ActionAttribution? = nil) {
            self.id = id
            self.label = label
            self.meta = meta
            self.kind = kind
            self.state = state
            self.utterance = utterance
            self.note = note
            self.seed = seed
            self.runSeed = runSeed
            self.linkedChatId = linkedChatId
            self.attribution = attribution
        }
    }

    /// The MAIN list: what you said (plus pending/unclear — nothing hidden
    /// without evidence), delivered answers, and your own added actions.
    public let rows: [Row]
    /// The collapsed "Heard from others" group: actions with POSITIVE evidence
    /// someone else said them (empty when the "Actions from others" toggle puts
    /// everyone inline).
    public let othersRows: [Row]
    public var isEmpty: Bool { rows.isEmpty && othersRows.isEmpty }

    /// EVERYTHING THIS FACE IS ACTUALLY RENDERING — the main list AND the collapsed
    /// "Heard from others" group.
    ///
    /// IT EXISTS BECAUSE `rows.count` WAS BEING PASSED AS "how many items came out of
    /// this voice note". `othersRows` is not a lesser list; it is the same surfaced
    /// items, filed under a heading, and it is on the screen. A capture whose only
    /// surfaced item was uttered by someone else therefore reported ZERO, and
    /// `AmbientReading.reading` answered `.readAndFoundNothing` — "Solleva read this
    /// voice note and found nothing to act on" — rendered directly above an Actions face
    /// listing that very item under "Heard from others". One screen, two contradictory
    /// claims, both from this presentation.
    ///
    /// INVARIANT: `surfaced == 0` if and only if `isEmpty`. Anything that can put a row
    /// on this face has to be counted here, or the sentence above it goes false again.
    public var surfaced: Int { rows.count + othersRows.count }

    public init(rows: [Row], othersRows: [Row] = []) {
        self.rows = rows
        self.othersRows = othersRows
    }

    /// Build the face from everything that ACTUALLY surfaced for this capture:
    /// ambient candidates joined to their outcomes (ConversationActions), the
    /// delivered answers linked to it, the user's own added actions, and the
    /// user's feedback on the surfaced items (rejections + refinement notes).
    ///
    /// `transcript` (the diarized transcript, once it has landed) attributes
    /// each surfaced row to WHO said it; others-uttered rows re-file into
    /// `othersRows` unless the "Actions from others" toggle (`othersInline`)
    /// is on or the user promoted them (`promotions`).
    public static func build(captureId: String,
                             decisions: [AmbientDecision],
                             outcomes: [CardOutcomeRecord],
                             answers: [LinkedConversationAnswer],
                             userActions: [UserConversationAction],
                             feedback: [ActionFeedbackRecord] = [],
                             chatLinks: [String: String] = [:],
                             transcript: SpeakerTranscript? = nil,
                             othersInline: Bool = false,
                             promotions: Set<String> = []) -> Self {
        var rows: [Row] = []
        var othersRows: [Row] = []
        for card in ConversationActions.cards(
            for: captureId, decisions: decisions, outcomes: outcomes,
            transcript: transcript) {
            let label = card.summary.isEmpty ? card.utterance : card.summary
            let meta = (!card.summary.isEmpty && card.utterance != card.summary)
                ? "\u{201C}\(card.utterance)\u{201D}" : nil
            let row = Row(
                id: "surfaced-\(card.id)", label: label, meta: meta,
                kind: .surfaced, state: state(of: card.outcome),
                utterance: card.utterance,
                note: ActionFeedbackStore.latestRefinement(
                    forUtterance: card.utterance, in: feedback),
                seed: chatSeed(utterance: card.utterance, summary: card.summary),
                runSeed: card.utterance,
                linkedChatId: chatLinks[ConversationActions.utteranceKey(card.utterance)],
                attribution: card.attribution)
            let promoted = promotions.contains(ActionPromotionStore.key(
                captureId: captureId, utterance: card.utterance))
            if ActionSurfacePolicy.belongsInOthersGroup(
                attribution: card.attribution, othersInline: othersInline,
                promoted: promoted) {
                othersRows.append(row)
            } else {
                rows.append(row)
            }
        }
        for (i, answer) in answers.enumerated() {
            rows.append(Row(id: "answer-\(i)", label: "Answer found",
                            meta: answer.title, kind: .answer, state: .ready,
                            seed: answer.title.isEmpty ? nil
                                : chatSeed(utterance: answer.title, summary: "")))
        }
        for action in userActions {
            rows.append(Row(id: "user-\(action.id)", label: action.title,
                            meta: "Added by you", kind: .user,
                            state: action.done ? .completed : .open,
                            seed: userActionSeed(title: action.title)))
        }
        return Self(rows: rows, othersRows: othersRows)
    }

    /// The act-in-chat prefill for a surfaced moment — the SAME template the
    /// ambient card notification seeds chat with, so acting from the Actions
    /// face reads identically to accepting the nudge live.
    public static func chatSeed(utterance: String, summary: String) -> String {
        let ask = summary.isEmpty ? "help with that" : summary
        return "While I was taking a note, this came up: \u{201C}\(utterance)\u{201D}\n\nPlease \(ask)."
    }

    /// The act-in-chat prefill for an action the user added by hand.
    public static func userActionSeed(title: String) -> String {
        "From one of my voice notes, I noted an action: \u{201C}\(title)\u{201D}\n\nPlease help me get it done."
    }

    /// The prototype's outcome vocabulary over the logged card outcomes.
    static func state(of outcome: ActionOutcome) -> Row.State {
        switch outcome {
        case .sentToChat: return .completed
        case .answered: return .ready
        case .pending: return .open
        case .dismissed: return .dismissed
        case .rejected: return .notAnAction
        }
    }
}

// MARK: - User-added actions

/// An action the user added to a conversation by hand (the Actions face's
/// "Add an action" affordance).
public struct UserConversationAction: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var done: Bool
    /// Unix seconds when the user added it.
    public let createdAt: UInt64

    enum CodingKeys: String, CodingKey {
        case id, title, done
        case createdAt = "created_at"
    }

    public init(id: String = UUID().uuidString, title: String, done: Bool = false,
                createdAt: UInt64 = UInt64(max(0, Date().timeIntervalSince1970))) {
        self.id = id
        self.title = title
        self.done = done
        self.createdAt = createdAt
    }
}

/// Durable per-capture storage for user-added actions — a small `actions.json`
/// next to the card meta, following ConversationCardStore's pattern (atomic
/// write, tolerant load, missing file reads as none).
public enum UserActionStore {
    public static let filename = "actions.json"

    static func url(captureId: String, baseDir: URL) -> URL {
        baseDir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// Load a capture's user-added actions, oldest first. Missing or unreadable
    /// file reads as none.
    public static func load(captureId: String, baseDir: URL) -> [UserConversationAction] {
        guard let data = try? Data(contentsOf: url(captureId: captureId, baseDir: baseDir))
        else { return [] }
        return (try? JSONDecoder().decode([UserConversationAction].self, from: data)) ?? []
    }

    /// Durably persist (atomic write). Creates the capture dir if needed.
    public static func save(_ actions: [UserConversationAction],
                            captureId: String, baseDir: URL) {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(actions) else { return }
        try? data.write(to: url(captureId: captureId, baseDir: baseDir), options: [.atomic])
    }

    /// Append a user action and persist. A blank title adds nothing.
    @discardableResult
    public static func add(title: String, captureId: String,
                           baseDir: URL) -> UserConversationAction? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var actions = load(captureId: captureId, baseDir: baseDir)
        let action = UserConversationAction(title: trimmed)
        actions.append(action)
        save(actions, captureId: captureId, baseDir: baseDir)
        return action
    }
}

// MARK: - Speaker name suggestion (transcript face)

/// The transcript face's standing people-hint, exactly as the prototype words
/// it: "Sarah matches 3 past conversations. Use this name in all 3."
public enum SpeakerNameSuggestion {
    public static func standingHint(name: String, matchCount: Int) -> String {
        guard !name.isEmpty, matchCount > 0 else { return "" }
        if matchCount == 1 {
            return "\(name) matches 1 past conversation. Use this name in it."
        }
        return "\(name) matches \(matchCount) past conversations. Use this name in all \(matchCount)."
    }
}
