// AnswerSurface — models for the ambient-answer surface (track 20260713T0906 AC1,
// fullflow v8 "answer" scene). An ambient lookup's answer opens as a real surface:
// the answer text, the SOURCES CONSULTED from the user's own memory (never
// "citations" — these are the user's own conversations, not references), small
// Helpful/Not-useful toggles that start UNSELECTED (the system never rates
// itself), a free-text note, and "Continue in Chat" seeding a fresh session with
// the answer. Pure models here; App/AnswerSurfaceView.swift renders them.

import Foundation

/// One conversation the answer drew on — a "source consulted" chip.
public struct AnswerSource: Equatable, Sendable, Identifiable {
    public let id: String
    /// The conversation's title, e.g. "Architecture call".
    public let title: String
    /// Optional short date label, e.g. "Jun 30".
    public let dateLabel: String?

    public init(id: String = UUID().uuidString, title: String, dateLabel: String? = nil) {
        self.id = id
        self.title = title
        self.dateLabel = dateLabel
    }

    /// The chip's text: "Architecture call · Jun 30" (title alone when undated).
    public var chipText: String {
        guard let dateLabel, !dateLabel.isEmpty else { return title }
        return "\(title) · \(dateLabel)"
    }
}

/// The answer an ambient lookup compiled from the user's own memory.
public struct AmbientAnswer: Equatable, Sendable {
    /// Short headline for the moment, e.g. "The relay decision".
    public let title: String
    /// The answer itself.
    public let text: String
    /// The conversations consulted to compile it.
    public let sources: [AnswerSource]

    public init(title: String, text: String, sources: [AnswerSource] = []) {
        self.title = title
        self.text = text
        self.sources = sources
    }

    /// The first turn "Continue in Chat" sends into a FRESH session — the answer
    /// (and the user's note, when they wrote one) so the agent has the context.
    public func chatSeed(note: String = "") -> String {
        var seed = "Earlier you answered this from my memory"
        if !title.isEmpty { seed += " (\(title))" }
        seed += ":\n\n\(text)\n\nLet's continue from that answer."
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { seed += "\n\nMy note: \(trimmed)" }
        return seed
    }
}

/// The user's verdict on an answer. `none` is the DEFAULT and the resting state —
/// feedback is the user's alone to give, never pre-selected.
public enum AnswerRating: String, Equatable, Sendable, Codable {
    case none, helpful, notUseful
}

/// Feedback the answer surface collects: a small toggle pair + a free-text note.
/// Starts unselected; tapping the selected toggle clears it; tapping the other
/// switches. ("Tunes when it speaks up" — the council reads these.)
public struct AnswerFeedback: Equatable, Sendable, Codable {
    public var rating: AnswerRating = .none
    public var note: String = ""

    public init() {}

    /// Toggle semantics: tap the selected rating → back to none; tap the other →
    /// switch. Tapping `.none` itself is meaningless and ignored.
    public mutating func toggle(_ tapped: AnswerRating) {
        guard tapped != .none else { return }
        rating = (rating == tapped) ? .none : tapped
    }

    /// True when there is anything worth recording.
    public var hasContent: Bool {
        rating != .none || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Every user-facing string on the answer surface, in one place — so the
/// "never say citations" rule is enforceable and the copy stays tweakable
/// without hunting through view code.
public enum AnswerCopy {
    public static let kicker = "From your memory"
    public static let sourcesLabel = "Sources consulted"
    public static let helpful = "Helpful"
    public static let notUseful = "Not useful"
    public static let feedbackHint = "tunes when it speaks up"
    public static let notePlaceholder = "Add a note…"
    public static let continueInChat = "Continue in Chat"
    public static let done = "Done"

    /// The full copy set, for the guard test: none of it may say "citations".
    public static var all: [String] {
        [kicker, sourcesLabel, helpful, notUseful, feedbackHint,
         notePlaceholder, continueInChat, done]
    }
}
