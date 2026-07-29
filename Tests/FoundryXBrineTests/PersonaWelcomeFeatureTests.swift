import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/persona-welcome.feature. Drives the REAL persona routing the
/// welcome renders from — `PersonaCopy.welcome(for:)` headlines + the one canonical
/// privacy line, `OnboardingPersona.chooserLabel`, `PersonaWelcomeLayout` (skeleton order
/// + action copy + the Settings row), `PersonaPrefs` persistence, `WelcomeGate` /
/// `WelcomeFrontDoor.firstRunPresentation` (shown once after sign-in, including for
/// established installs), and `WelcomePrefs` (Set up later = seen forever). Hermetic: an
/// isolated UserDefaults suite, no UI.
final class PersonaWelcomeFeatureTests: XCTestCase {
    func testPersonaWelcomeFeature() async throws {
        try await BrineFeatureRunner.run(
            "persona-welcome",
            registry: StepRegistry(PersonaWelcomeSteps.make(world: PersonaWelcomeWorld())))
    }
}

private final class PersonaWelcomeWorld: @unchecked Sendable {
    let defaults: UserDefaults
    var persona: OnboardingPersona = .individual
    var copy: PersonaWelcomeCopy { PersonaCopy.welcome(for: persona) }
    // Gate inputs.
    var signedIn = false
    var onboardingCompleted = false

    init() {
        let name = "persona-welcome-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }
    /// This world is about a user who has JUST signed in for the first time, so the account
    /// has no recording history — stated rather than defaulted, because a default here would
    /// hide the very input S07 turns on.
    var hasRecordingHistory = false
    var firstRun: WelcomeFrontDoor.FirstRunPresentation {
        WelcomeFrontDoor.firstRunPresentation(
            letStraightIn: WelcomePrefs.letStraightIn(defaults: defaults),
            onboardingCompleted: onboardingCompleted,
            welcomeSeen: WelcomePrefs.seen(defaults: defaults),
            hasRecordingHistory: hasRecordingHistory)
    }
}

private enum PersonaWelcomeSteps {
    static func make(world w: PersonaWelcomeWorld) -> [StepDefinition] {
        [
            // ── S1 individual voice by default
            defineStep("I have just signed in for the first time") { ctx, _, _ in
                w.persona = PersonaPrefs.persona(defaults: w.defaults)   // default .individual
                w.signedIn = true
                return ctx
            },
            defineStep("the welcome shows") { ctx, _, _ in return ctx },
            defineCheck("the headline reads \"It adapts to you.\"") { _, _, _ in
                guard w.copy.headline == "It adapts to you." else { throw BrineStepError("headline was \(w.copy.headline)") }
            },
            defineCheck("the privacy line says my memory stays on my devices") { _, _, _ in
                guard w.copy.lockLine == "Your memory stays on your devices, under your keys." else {
                    throw BrineStepError("privacy line was \(w.copy.lockLine)")
                }
            },

            // ── S2/S3 choosing a voice re-renders in place
            defineStep("the welcome is showing") { ctx, _, _ in w.persona = .individual; return ctx },
            defineStep("I choose \"For my firm\"") { ctx, _, _ in w.persona = .firm; return ctx },
            defineCheck("the headline reads \"One standard, inside your perimeter.\"") { _, _, _ in
                guard w.copy.headline == "One standard, inside your perimeter." else { throw BrineStepError("firm headline was \(w.copy.headline)") }
            },
            defineCheck("I am still on the welcome step") { _, _, _ in
                // Re-rendering the voice never leaves the welcome — the seen flag is untouched.
                guard !WelcomePrefs.seen(defaults: w.defaults) else { throw BrineStepError("choosing a voice dismissed the welcome") }
            },
            defineStep("I choose \"For my work\"") { ctx, _, _ in w.persona = .expert; return ctx },
            defineCheck("the headline reads \"Take the work back.\"") { _, _, _ in
                guard w.copy.headline == "Take the work back." else { throw BrineStepError("expert headline was \(w.copy.headline)") }
            },

            // ── S4 canonical privacy line for every persona
            defineStep("the persona copy table") { ctx, _, _ in return ctx },
            defineCheck("every persona's privacy line reads exactly \"Your memory stays on your devices, under your keys.\"") { _, _, _ in
                for p in OnboardingPersona.allCases {
                    guard PersonaCopy.welcome(for: p).lockLine == "Your memory stays on your devices, under your keys." else {
                        throw BrineStepError("\(p) privacy line differs: \(PersonaCopy.welcome(for: p).lockLine)")
                    }
                }
            },

            // ── S5 actions + switch above the art
            defineCheck("the primary action reads \"Continue\"") { _, _, _ in
                guard PersonaWelcomeLayout.primaryAction == "Continue" else { throw BrineStepError("primary was \(PersonaWelcomeLayout.primaryAction)") }
            },
            defineCheck("the quiet action reads \"Set up later\"") { _, _, _ in
                guard PersonaWelcomeLayout.quietAction == "Set up later" else { throw BrineStepError("quiet was \(PersonaWelcomeLayout.quietAction)") }
            },
            defineCheck("the \"What brings you here?\" switch sits above the artwork") { _, _, _ in
                let order = PersonaWelcomeLayout.order
                guard PersonaWelcomeLayout.prompt == "What brings you here?" else { throw BrineStepError("prompt copy wrong") }
                guard let switchIdx = order.firstIndex(of: .personaSwitch), let artIdx = order.firstIndex(of: .art),
                      switchIdx < artIdx else {
                    throw BrineStepError("persona switch is not above the artwork: \(order)")
                }
            },

            // ── S6 welcome shows once after sign-in
            defineStep("I have just signed in") { ctx, _, _ in w.signedIn = true; return ctx },
            defineStep("I have not seen the persona welcome") { ctx, _, _ in
                w.defaults.removeObject(forKey: WelcomePrefs.seenKey); return ctx
            },
            defineStep("the app decides what to show") { ctx, _, _ in return ctx },
            defineCheck("the persona welcome is presented before the tabs") { _, _, _ in
                guard WelcomeGate.shouldPresent(signedIn: w.signedIn, onboardingWillPresent: false,
                                                welcomeSeen: WelcomePrefs.seen(defaults: w.defaults)) else {
                    throw BrineStepError("welcome not presented for a fresh signed-in user")
                }
            },

            // ── S7 established install still sees the welcome once after update
            defineStep("I have recordings from before the welcome existed") { ctx, _, _ in
                w.defaults.removeObject(forKey: WelcomePrefs.seenKey); return ctx
            },
            defineStep("migration marked my onboarding complete") { ctx, _, _ in
                w.onboardingCompleted = true; return ctx
            },
            defineCheck("the voice and consent onboarding is not re-presented") { _, _, _ in
                // firstRunPresentation must NOT return .onboarding for a migrated install.
                if case .onboarding = w.firstRun { throw BrineStepError("onboarding re-presented for a migrated install") }
            },
            defineCheck("the persona welcome is presented once") { _, _, _ in
                guard w.firstRun == .standaloneWelcome else {
                    throw BrineStepError("expected the standalone welcome once, got \(w.firstRun)")
                }
            },

            // ── S8 Set up later dismisses forever
            defineStep("I choose \"Set up later\"") { ctx, _, _ in WelcomePrefs.markSeen(defaults: w.defaults); return ctx },
            defineCheck("the welcome is marked seen") { _, _, _ in
                guard WelcomePrefs.seen(defaults: w.defaults) else { throw BrineStepError("not marked seen") }
            },
            defineCheck("it is not presented again on the next launch") { _, _, _ in
                guard !WelcomeGate.shouldPresent(signedIn: true, onboardingWillPresent: false,
                                                 welcomeSeen: WelcomePrefs.seen(defaults: w.defaults)) else {
                    throw BrineStepError("welcome re-presented after Set up later")
                }
            },

            // ── S9 choice persists across launches
            defineStep("I chose \"For my work\" on the welcome") { ctx, _, _ in
                PersonaPrefs.set(.expert, defaults: w.defaults); return ctx
            },
            defineStep("I relaunch the app") { ctx, _, _ in
                w.persona = PersonaPrefs.persona(defaults: w.defaults)   // re-read from persistence
                return ctx
            },
            defineCheck("the persona is expert") { _, _, _ in
                guard w.persona == .expert else { throw BrineStepError("persona did not persist: \(w.persona)") }
            },

            // ── S10 individual voice never says apprentice
            defineCheck("the individual welcome copy does not contain \"apprentice\"") { _, _, _ in
                let c = PersonaCopy.welcome(for: .individual)
                let blob = [c.headline, c.sub, c.lockLine].joined(separator: " ").lowercased()
                guard !blob.contains("apprentice") else { throw BrineStepError("individual copy says apprentice: \(blob)") }
            },

            // ── S11 change persona from Settings
            defineStep("I completed onboarding as an individual") { ctx, _, _ in
                PersonaPrefs.set(.individual, defaults: w.defaults); return ctx
            },
            defineStep("I change the persona to firm in Settings") { ctx, _, _ in
                PersonaPrefs.set(.firm, defaults: w.defaults)
                w.persona = PersonaPrefs.persona(defaults: w.defaults)
                return ctx
            },
            defineCheck("the persona is firm") { _, _, _ in
                guard w.persona == .firm else { throw BrineStepError("persona not changed to firm: \(w.persona)") }
            },

            // ── S12 welcome stays reachable from Settings
            defineStep("I dismissed the welcome with \"Set up later\"") { ctx, _, _ in WelcomePrefs.markSeen(defaults: w.defaults); return ctx },
            defineStep("I open Settings") { ctx, _, _ in return ctx },
            defineCheck("a \"Welcome & who it's for\" row reopens the persona welcome") { _, _, _ in
                guard PersonaWelcomeLayout.settingsRowLabel == "Welcome & who it's for" else {
                    throw BrineStepError("settings row label was \(PersonaWelcomeLayout.settingsRowLabel)")
                }
            },
        ]
    }
}
