// PersonaCopy — the persona-routed welcome voice (track 20260713T0901,
// features/persona-welcome.feature). One flow skeleton; only words and artwork
// route by who is arriving. This table is THE tweak point when the design locks:
// copy changes land here once and the welcome follows.
//
// Copy laws (each earned in review):
//  - individual never says "apprentice" (Nick, 2026-07-12)
//  - every persona keeps a privacy lock line (no absolute claims — "stays on your
//    devices, under your keys", never "nothing leaves")
//  - headlines come from the live site language (for-you / for-business)

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
    public static func welcome(for persona: OnboardingPersona) -> PersonaWelcomeCopy {
        switch persona {
        case .expert:
            return PersonaWelcomeCopy(
                headline: "The expert work is why they hire you.",
                emphasis: "why they hire you.",
                sub: "The busywork gets struck through. The judgment stays yours.",
                lockLine: "Privileged by default. Your memory stays on your devices, under your keys."
            )
        case .individual:
            return PersonaWelcomeCopy(
                headline: "It adapts to you.",
                emphasis: "It adapts",
                // Individual = a person organizing their LIFE, not their job.
                // The Catch: it catches what you'd have forgotten and brings it
                // back at the moment it matters. Never "how you work".
                sub: "It catches what you'd have forgotten, and brings it back right when it matters.",
                lockLine: "Private by design. Your memory stays on your devices, under your keys."
            )
        case .firm:
            return PersonaWelcomeCopy(
                headline: "Your data stays under your control.",
                emphasis: "your control.",
                sub: "Never trained on. Works offline. Yours by architecture.",
                lockLine: "Encrypted on your hardware. Never trained on."
            )
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
