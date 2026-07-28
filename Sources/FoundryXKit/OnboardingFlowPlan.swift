// OnboardingFlowPlan — what happens after the last question, and where notes live.
//
// The flow used to END on the ambient-intelligence CONSENT step: the final thing it
// asked for was a permission, and then it dropped the user on an empty library with no
// next action and no indication that a Vault — the thing cell provisioning sets up —
// existed at all. The Vault funnel was reachable only by digging through Settings, so in
// practice new users never found it (Nick, 2026-07-28: "it doesn't point me toward how
// to get started or even guide me to create my first recording/voice note? As a user I
// feel stuck like I don't know what to do next").
//
// So the flow gains an ending: make a first voice note (a WIN, not a permission), then
// choose where notes live — and choosing the Vault is what STARTS provisioning. This
// file is the pure part of that: step order and the destination choice, with no SwiftUI,
// so both are driven directly by
// features/onboarding-first-note-and-destination.feature.

import Foundation

/// The ordered first-run steps. `welcome` is skipped when the connect gate already
/// fronted the app (see `OnboardingFlowView.skipWelcome`); everything after it always
/// runs in this order.
public enum OnboardingStep: String, Sendable, CaseIterable, Equatable {
    case welcome
    case voice
    case ambient
    /// The win: a real voice note, made with the real capture path, live transcript
    /// visible while it is being spoken.
    case firstNote
    /// The demonstration: ask a question about the note just made, answered on-device.
    /// This is deliberately positioned BEFORE the destination choice — having felt "ask
    /// about this note", the user meets "ask across everything you've said" as an
    /// extension of something real rather than as a feature list.
    case askIt
    /// The fork: this phone / my computer / my Vault. Where cell provisioning begins.
    case destination
}

public enum OnboardingFlowPlan {
    /// The step after `step`, or nil when the flow is finished.
    ///
    /// The single invariant worth stating out loud: `next(after: .ambient)` is NOT nil.
    /// Ending on the consent step is the defect this file exists to prevent, and the
    /// feature file asserts it directly.
    public static func next(after step: OnboardingStep) -> OnboardingStep? {
        let order = OnboardingStep.allCases
        guard let i = order.firstIndex(of: step), i + 1 < order.count else { return nil }
        return order[i + 1]
    }

    /// Is the flow over once `step` is answered?
    public static func isFinished(after step: OnboardingStep) -> Bool {
        next(after: step) == nil
    }
}

/// The first-note step's view state.
///
/// Thin on purpose — the step does NOT reimplement recording, it drives the same capture
/// path the record button does. The one thing worth modelling here is the thing that was
/// actually broken in the field: whether the step is subscribed to the live transcript at
/// all. A step that records but shows no words is the failure Nick hit twice, so
/// "did anything arrive from the transcriber" is state, not a rendering detail.
///
/// Structural coverage only — that the words REACH THE SCREEN is proved by a UI test,
/// not by this.
public struct OnboardingFirstNote: Sendable, Equatable {
    public private(set) var transcript: LiveTranscript = .empty

    public init() {}

    /// Fold in whatever the on-device transcriber has produced so far.
    public mutating func consume(_ live: LiveTranscript) { transcript = live }

    /// Is there anything to show the user while they speak?
    public var showsTranscript: Bool { !transcript.isEmpty }

    /// The words to render, newest last.
    public var visibleText: String { transcript.displayText }
}

/// Answers a question about ONE voice note. The seam exists so the onboarding
/// demonstration can be driven in tests without a model: production supplies the
/// on-device path (the same one `LocalChatScreen` uses), tests supply a stub.
public protocol NoteAnswering: Sendable {
    /// Answer `question` using `transcript` — and nothing else. The implementation must
    /// be on-device: this runs during onboarding, possibly before any account exists,
    /// and the promise being demonstrated is that it works with no server.
    func answer(question: String, aboutNote transcript: String) async throws -> String
}

/// The ask-it step's state: the demonstration that a note can be talked to.
public struct OnboardingAskIt: Sendable, Equatable {
    public private(set) var question = ""
    public private(set) var answer: String?
    /// Proof the answer came from the handset, not a server — the claim the whole free
    /// tier rests on.
    public private(set) var answeredOnDevice = false

    public init() {}

    /// Ask `question` about `transcript`. The transcript is passed through verbatim so a
    /// test can prove the answer was drawn from the user's OWN note rather than invented
    /// from the question alone — an answer that ignores the note would make the
    /// demonstration a lie.
    public mutating func ask(_ question: String) { self.question = question }

    public mutating func record(answer: String, onDevice: Bool) {
        self.answer = answer
        self.answeredOnDevice = onDevice
    }

    public var hasAnswer: Bool { !(answer ?? "").isEmpty }
}

/// One line of the "what changes" comparison, answered for BOTH choices.
///
/// Both sides are required. A comparison with blanks down the free column reads as a
/// list of things the user is missing, which is exactly the shakedown posture this
/// screen must avoid — staying on the phone is a legitimate destination, not a
/// deficiency.
public struct TierComparisonPoint: Sendable, Equatable {
    public let onThisPhone: String
    public let withYourVault: String

    public init(onThisPhone: String, withYourVault: String) {
        self.onThisPhone = onThisPhone
        self.withYourVault = withYourVault
    }
}

public enum TierComparison {
    /// The ONE difference that carries the decision, and the only one stated as a
    /// headline. It is deliberately about scope of memory rather than product names:
    /// the user has just asked a question about a single note, so this reads as the
    /// same gesture made larger.
    public static let headline = TierComparisonPoint(
        onThisPhone: "Ask about the note you're in.",
        withYourVault: "Ask across everything you've ever said.")

    /// The consequences, in plain language. Product names (Lore, Kiln, Anvil) are
    /// deliberately absent — they mean nothing to someone ninety seconds into the app.
    public static let points: [TierComparisonPoint] = [
        headline,
        TierComparisonPoint(
            onThisPhone: "Every note is transcribed and summarised right here.",
            withYourVault: "Longer notes are transcribed and summarised by better models."),
        // Privacy is the first question anyone asks about moving their notes off the
        // handset, and leaving it unanswered reads as evasion. The Vault wording here is
        // the ALREADY-REVIEWED claim from the funnel (VaultFunnel.swift:114) — this
        // screen must not invent a stronger privacy promise than the product makes.
        TierComparisonPoint(
            onThisPhone: "Nothing ever leaves this phone.",
            withYourVault: "Encrypted and isolated — only your voice and login open it."),
        TierComparisonPoint(
            onThisPhone: "Your notes are here, on this device.",
            withYourVault: "Your notes are reachable anywhere you sign in."),
        TierComparisonPoint(
            onThisPhone: "You choose when to open a note.",
            withYourVault: "It notices moments while you speak, and offers to act."),
        TierComparisonPoint(
            onThisPhone: "The model on your phone, always free.",
            withYourVault: "Your own models and your own workflows, on your own keys."),
    ]

    /// Ways of writing a comparison cell that mean "you get nothing here". Used by the
    /// spec to keep the free column honest rather than punitive.
    static let emptyHandedPhrasings = ["—", "-", "n/a", "none", "no", "not available", "nothing"]

    /// Is every point answered for both choices, with neither side left empty-handed?
    public static func isHonest(_ points: [TierComparisonPoint] = TierComparison.points) -> Bool {
        points.allSatisfy { point in
            let phone = point.onThisPhone.trimmingCharacters(in: .whitespacesAndNewlines)
            let vault = point.withYourVault.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phone.isEmpty, !vault.isEmpty else { return false }
            return !emptyHandedPhrasings.contains(phone.lowercased())
        }
    }
}

/// Where this person's voice notes should live.
///
/// This is NOT a new preference. The three-way choice already exists as `BrainChoice`
/// (`justMyPhone` / `myComputer` / `foundryCloud`), which is declared in
/// `AccountPreferenceCatalog` and therefore account-scoped, migration-safe, and copied
/// correctly when a second account signs in. An earlier draft of this file introduced a
/// parallel `foundryx.note-destination` key; the account-preference source guard caught
/// it, and it was right to — two preferences meaning the same thing drift, and this one
/// would have leaked across accounts.
///
/// What belongs here is only the ONBOARDING reading of that choice.
public extension BrainChoice {
    /// Picking the Vault is the entry point to cell provisioning — the destination step
    /// hands off to the Vault funnel rather than finishing the flow. Every other choice
    /// finishes it.
    var startsVaultSetup: Bool { self == .foundryCloud }

    /// Does this choice keep the library on the handset? Drives the local-tier copy the
    /// home screen shows ("Nothing ever leaves this phone").
    var keepsNotesOnPhone: Bool { self == .justMyPhone }

    /// The destination step's wording, in the user's terms rather than the
    /// architecture's. `BrainChoice.label` is the Settings phrasing ("Foundry Cloud");
    /// onboarding speaks about where NOTES live.
    var destinationLabel: String {
        switch self {
        case .justMyPhone: return "Keep my notes on this phone"
        case .myComputer: return "I'll use my computer"
        case .foundryCloud: return "Set up my Vault"
        }
    }
}
