import XCTest
import Foundation
import FoundryXKit

/// Persona-routed welcome (features/persona-welcome.feature, track 20260713T0901).
/// The UI renders PURELY from OnboardingPersona + PersonaCopy; these tests pin the
/// durable pieces — the copy table, the default, persistence, and the copy laws
/// (individual never says "apprentice"; every persona keeps the lock line).
final class PersonaWelcomeTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "persona-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // Scenario: the welcome speaks the individual voice by default
    func testDefaultPersonaIsIndividual() {
        let d = freshDefaults()
        XCTAssertEqual(PersonaPrefs.persona(defaults: d), .individual)
        XCTAssertEqual(PersonaCopy.welcome(for: .individual).headline, "It adapts to you.")
    }

    // Scenario: choosing the firm/expert voice re-renders the welcome in place
    // (re-render = the copy is a pure function of the persona; the UI switches on it)
    func testCopyTableRoutesByPersona() {
        XCTAssertEqual(PersonaCopy.welcome(for: .firm).headline,
                       "Your data stays under your control.")
        XCTAssertEqual(PersonaCopy.welcome(for: .expert).headline,
                       "The expert work is why they hire you.")
        let headlines = Set(OnboardingPersona.allCases.map { PersonaCopy.welcome(for: $0).headline })
        XCTAssertEqual(headlines.count, OnboardingPersona.allCases.count,
                       "every persona has its own voice")
    }

    // Scenario: my choice persists across launches
    func testPersonaPersistsAcrossLaunches() {
        let d = freshDefaults()
        PersonaPrefs.set(.expert, defaults: d)
        // "relaunch" = a fresh read with no in-memory state
        XCTAssertEqual(PersonaPrefs.persona(defaults: d), .expert)
    }

    // Scenario: the individual voice never says apprentice (Nick, 2026-07-12)
    func testIndividualCopyNeverSaysApprentice() {
        let c = PersonaCopy.welcome(for: .individual)
        for text in [c.headline, c.sub, c.lockLine] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("apprentice"),
                           "individual copy must not say 'apprentice': \(text)")
        }
    }

    // Scenario: …the privacy line says my memory stays on my devices
    func testEveryPersonaKeepsTheLockLine() {
        for p in OnboardingPersona.allCases {
            XCTAssertFalse(PersonaCopy.welcome(for: p).lockLine.isEmpty,
                           "\(p) must carry a privacy lock line")
        }
    }

    // Scenario: I can change who it speaks to from Settings
    func testPersonaIsEditableAfterOnboarding() {
        let d = freshDefaults()
        PersonaPrefs.set(.individual, defaults: d)
        PersonaPrefs.set(.firm, defaults: d)
        XCTAssertEqual(PersonaPrefs.persona(defaults: d), .firm)
    }

    // Corrupt/unknown stored value falls back to the default, never crashes.
    func testUnknownStoredValueFallsBackToIndividual() {
        let d = freshDefaults()
        d.set("cyborg", forKey: PersonaPrefs.key)
        XCTAssertEqual(PersonaPrefs.persona(defaults: d), .individual)
    }
}
