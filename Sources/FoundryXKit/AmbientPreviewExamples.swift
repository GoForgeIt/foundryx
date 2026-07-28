import Foundation

/// An inert, worked example of the suggestion cards ambient intelligence can surface.
///
/// This deliberately is not an `AmbientCandidate`: it has no capture identity, lane
/// state, persistence hook, or action closure. A preview can therefore be rendered, but
/// it cannot enter the ambient lane or append an outcome to `ambient-cards.jsonl`.
public struct AmbientPreviewExample: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case agentDirected
        case memorySurface
    }

    public enum Persistence: Equatable, Sendable {
        case neverStore
    }

    public let id: String
    public let kind: Kind
    public let systemImage: String
    public let eyebrow: String
    public let moment: String
    public let offer: String
    public let actionLabel: String

    /// Explicit presentation metadata; callers never have to infer preview status from
    /// marketing copy.
    public let isExample = true
    public let exampleLabel = "Example"
    public let persistence = Persistence.neverStore

    public init(
        id: String,
        kind: Kind,
        systemImage: String,
        eyebrow: String,
        moment: String,
        offer: String,
        actionLabel: String
    ) {
        self.id = id
        self.kind = kind
        self.systemImage = systemImage
        self.eyebrow = eyebrow
        self.moment = moment
        self.offer = offer
        self.actionLabel = actionLabel
    }
}

public enum AmbientPreviewExamples {
    public static let all: [AmbientPreviewExample] = [
        AmbientPreviewExample(
            id: "agent-moving-checklist",
            kind: .agentDirected,
            systemImage: "bolt",
            eyebrow: "Request heard",
            moment: "“Foundry, turn this voice note into a checklist for moving day.”",
            offer: "Review a moving-day checklist",
            actionLabel: "Review"
        ),
        AmbientPreviewExample(
            id: "memory-saved-book",
            kind: .memorySurface,
            systemImage: "sparkle",
            eyebrow: "From your memory",
            moment: "“What was the name of that book I saved in a voice note last month?”",
            offer: "Open the note where you mentioned The Creative Act",
            actionLabel: "Open"
        ),
    ]
}
