// PersonaCopy — the persona-routed welcome voice (track 20260713T0901,
// features/persona-welcome.feature; realigned to the prototype by track
// 20260714T1800 §2). One flow skeleton; only words and artwork route by who is
// arriving. This table is THE tweak point when the design locks: copy changes
// land here once and the welcome follows.
//
// Copy laws (each earned in review):
//  - individual never says "apprentice" (Nick, 2026-07-12)
//  - every persona shows the ONE canonical privacy line: "Your memory stays on
//    your devices, under your keys." (no per-persona prefixes, no absolutes)
//  - headlines come from the prototype (fullflow2.html WELCOME_COPY): work
//    "Take the work back." / life "It adapts to you." / firm "One standard,
//    inside your perimeter."

import Foundation

/// Who the welcome speaks to. Raw values are the stored representation.
public enum OnboardingPersona: String, CaseIterable, Codable, Sendable {
    case expert, individual, firm

    /// The quiet "What brings you here?" row label.
    public var chooserLabel: String {
        switch self {
        case .expert: return "For my work"
        case .individual: return "For my life"
        case .firm: return "For my firm"
        }
    }
}

/// The welcome's words for one persona.
public struct PersonaWelcomeCopy: Equatable, Sendable {
    public let headline: String
    /// The span of the headline rendered in the forge accent (empty = none).
    public let emphasis: String
    public let sub: String
    public let lockLine: String
}

public enum PersonaCopy {
    /// The single privacy line every persona shows — one canon, zero prefixes
    /// (prototype `privacy-line`, spec §2).
    public static let canonicalLockLine = "Your memory stays on your devices, under your keys."

    public static func welcome(for persona: OnboardingPersona) -> PersonaWelcomeCopy {
        switch persona {
        case .expert:
            return PersonaWelcomeCopy(
                headline: "Take the work back.",
                emphasis: "",
                sub: "Clients come for your judgment. FoundryX carries the record, recall, and follow-through.",
                lockLine: canonicalLockLine
            )
        case .individual:
            return PersonaWelcomeCopy(
                headline: "It adapts to you.",
                emphasis: "",
                // Individual = a person organizing their LIFE, not their job.
                // The Catch: it catches what you'd have forgotten and brings it
                // back at the moment it matters. Never "how you work".
                sub: "It catches the parts of life you meant to remember, right when they matter.",
                lockLine: canonicalLockLine
            )
        case .firm:
            return PersonaWelcomeCopy(
                headline: "One standard, inside your perimeter.",
                emphasis: "",
                sub: "Hard-won judgment becomes one private standard. It is not used for training, and stays useful offline.",
                lockLine: canonicalLockLine
            )
        }
    }
}

// MARK: - The welcome's fixed skeleton (spec §2 — one skeleton, words route)

/// The persona-independent pieces of the welcome surface, in render order.
/// The view renders FROM this — tests assert the same values the screen shows.
public enum PersonaWelcomeLayout {
    /// The skeleton's elements, top to bottom (prototype `renderWelcome`):
    /// wordmark → prompt + persona switch (ABOVE the art) → art → headline +
    /// body → actions (+ the privacy line).
    public enum Element: Equatable, CaseIterable, Sendable {
        case wordmark, prompt, personaSwitch, art, headline, body, actions
    }

    public static let order: [Element] =
        [.wordmark, .prompt, .personaSwitch, .art, .headline, .body, .actions]

    public static let prompt = "What brings you here?"
    /// Primary → voice enrollment; quiet → capture home (dismisses forever).
    public static let primaryAction = "Continue"
    public static let quietAction = "Set up later"
    public static let privacyLine = PersonaCopy.canonicalLockLine
}

// MARK: - The welcome-seen gate (B2)

/// Whether THIS install has seen the persona welcome — its own flag, deliberately
/// independent of `foundryx.onboarding.completed` so `migrateIfPriorUse` (which
/// suppresses the voice/consent ONBOARDING for established installs) can never
/// suppress the WELCOME: established installs see it once after the update.
public enum WelcomePrefs {
    public static let seenKey = "foundryx.welcome.seen"

    public static func seen(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: seenKey)
    }

    public static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seenKey)
    }
}

/// The pure presentation rule (mirrors OnboardingGate's style): sign-in FIRST
/// (locked decision #5), then the welcome once — unless the full onboarding
/// flow is about to present (it opens with the same welcome).
public enum WelcomeGate {
    public static func shouldPresent(signedIn: Bool,
                                     onboardingWillPresent: Bool,
                                     welcomeSeen: Bool) -> Bool {
        signedIn && !onboardingWillPresent && !welcomeSeen
    }
}

/// A sample "want me to…?" nudge the user can feel before anything real fires —
/// aimed at their demographic so it lands (Nick: individual = family/plans,
/// expert = client prep, firm = team/standard). Confirm-only by construction.
public struct PersonaNotificationExample: Equatable, Sendable {
    public let title: String
    public let body: String
}

public extension PersonaCopy {
    static func notificationExample(for persona: OnboardingPersona) -> PersonaNotificationExample {
        switch persona {
        case .individual:
            return PersonaNotificationExample(
                title: "A gentle reminder",
                body: "You mentioned taking Mom to her appointment Thursday. Want me to add it to your calendar?")
        case .expert:
            return PersonaNotificationExample(
                title: "Before your client call",
                body: "You have the Henderson call tomorrow. Want me to pull your notes and prep a brief?")
        case .firm:
            return PersonaNotificationExample(
                title: "A pattern this week",
                body: "Three people asked about the refund policy this week. Want me to draft the standard answer for the team?")
        }
    }
}

/// Persistence: one UserDefaults key beside the onboarding completed flag.
/// Defaults injectable so tests never touch the app domain.
public enum PersonaPrefs {
    public static let key = "foundryx.onboarding.persona"

    public static func persona(defaults: UserDefaults = .standard) -> OnboardingPersona {
        guard let raw = defaults.string(forKey: key),
              let p = OnboardingPersona(rawValue: raw) else { return .individual }
        return p
    }

    public static func set(_ persona: OnboardingPersona, defaults: UserDefaults = .standard) {
        defaults.set(persona.rawValue, forKey: key)
    }
}
