import XCTest
import Foundation
import FoundryXKit

/// Persona-routed welcome (features/persona-welcome.feature, tracks 20260713T0901
/// + 20260714T1800 ux_prototype_realignment §2/B2). The UI renders PURELY from
/// OnboardingPersona + PersonaCopy + PersonaWelcomeLayout; these tests pin the
/// durable pieces — the copy table (prototype headlines), the canonical privacy
/// line, the action labels, the switch-above-art order, the default, persistence,
/// and the welcome-seen gate that keeps the welcome reachable for established
/// installs without re-running the voice/consent onboarding.
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
    // Headlines are the PROTOTYPE's (fullflow2.html WELCOME_COPY) — this test was
    // inverted by the realignment track after pinning the divergent app copy.
    func testCopyTableRoutesByPersona() {
        XCTAssertEqual(PersonaCopy.welcome(for: .firm).headline,
                       "One standard, inside your perimeter.")
        XCTAssertEqual(PersonaCopy.welcome(for: .expert).headline,
                       "Take the work back.")
        let headlines = Set(OnboardingPersona.allCases.map { PersonaCopy.welcome(for: $0).headline })
        XCTAssertEqual(headlines.count, OnboardingPersona.allCases.count,
                       "every persona has its own voice")
    }

    // The welcome bodies match the prototype word for word.
    func testWelcomeBodiesMatchThePrototype() {
        XCTAssertEqual(PersonaCopy.welcome(for: .expert).sub,
                       "Clients come for your judgment. FoundryX carries the record, recall, and follow-through.")
        XCTAssertEqual(PersonaCopy.welcome(for: .individual).sub,
                       "It catches the parts of life you meant to remember, right when they matter.")
        XCTAssertEqual(PersonaCopy.welcome(for: .firm).sub,
                       "Hard-won judgment becomes one private standard. It is not used for training, and stays useful offline.")
    }

    // Scenario: every persona shows the one canonical privacy line
    // (was non-empty-only, which let the firm divergence ship green)
    func testEveryPersonaShowsTheOneCanonicalPrivacyLine() {
        for p in OnboardingPersona.allCases {
            XCTAssertEqual(PersonaCopy.welcome(for: p).lockLine,
                           "Your memory stays on your devices, under your keys.",
                           "\(p) must carry the single canonical privacy line")
        }
        XCTAssertEqual(PersonaWelcomeLayout.privacyLine,
                       "Your memory stays on your devices, under your keys.")
    }

    // Scenario: the welcome offers Continue and Set up later with the switch above the art
    func testWelcomeActionsAndSwitchPlacement() {
        XCTAssertEqual(PersonaWelcomeLayout.primaryAction, "Continue")
        XCTAssertEqual(PersonaWelcomeLayout.quietAction, "Set up later")
        XCTAssertEqual(PersonaWelcomeLayout.prompt, "What brings you here?")
        let order = PersonaWelcomeLayout.order
        guard let switchIdx = order.firstIndex(of: .personaSwitch),
              let promptIdx = order.firstIndex(of: .prompt),
              let artIdx = order.firstIndex(of: .art),
              let headlineIdx = order.firstIndex(of: .headline) else {
            return XCTFail("welcome layout must place prompt, switch, art, and headline")
        }
        XCTAssertLessThan(promptIdx, switchIdx, "the prompt introduces the switch")
        XCTAssertLessThan(switchIdx, artIdx, "the persona switch sits ABOVE the art")
        XCTAssertLessThan(artIdx, headlineIdx, "art precedes the headline + body")
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

    // Scenario: I can change who it speaks to from Settings
    func testPersonaIsEditableAfterOnboarding() {
        let d = freshDefaults()
        PersonaPrefs.set(.individual, defaults: d)
        PersonaPrefs.set(.firm, defaults: d)
        XCTAssertEqual(PersonaPrefs.persona(defaults: d), .firm)
    }

    // Persona-relatable sample notifications (Nick): each persona gets a demographic
    // example, all confirm-only ("Want me to…?"), distinct per persona.
    func testNotificationExamplesArePersonaRelatableAndConfirmOnly() {
        let ind = PersonaCopy.notificationExample(for: .individual)
        let exp = PersonaCopy.notificationExample(for: .expert)
        let firm = PersonaCopy.notificationExample(for: .firm)
        XCTAssertTrue(ind.body.contains("Mom"), "individual = family/life")
        XCTAssertTrue(exp.body.localizedCaseInsensitiveContains("client")
                      || exp.body.contains("Henderson"), "expert = a client")
        XCTAssertTrue(firm.body.localizedCaseInsensitiveContains("team")
                      || firm.body.contains("policy"), "firm = team/standard")
        for ex in [ind, exp, firm] {
            XCTAssertTrue(ex.body.contains("Want me to"), "confirm-only nudge")
            XCTAssertFalse(ex.body.contains("—"), "no em dashes")
        }
        XCTAssertNotEqual(ind.body, exp.body)
        XCTAssertNotEqual(exp.body, firm.body)
    }

    // Corrupt/unknown stored value falls back to the default, never crashes.
    func testUnknownStoredValueFallsBackToIndividual() {
        let d = freshDefaults()
        d.set("cyborg", forKey: PersonaPrefs.key)
        XCTAssertEqual(PersonaPrefs.persona(defaults: d), .individual)
    }
}

/// The welcome-seen gate (B2): sign-in FIRST (locked decision #5), then the
/// persona welcome ONCE, then tabs. `migrateIfPriorUse` keeps suppressing the
/// voice/consent ONBOARDING for established installs but must NOT suppress the
/// persona WELCOME — a separate `foundryx.welcome.seen` flag, independent of
/// `foundryx.onboarding.completed`.
final class WelcomeGateTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "welcome-gate-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // Scenario: the welcome shows once after sign-in
    func testWelcomePresentsAfterSignInWhenUnseen() {
        XCTAssertTrue(WelcomeGate.shouldPresent(signedIn: true,
                                                onboardingWillPresent: false,
                                                welcomeSeen: false))
        XCTAssertFalse(WelcomeGate.shouldPresent(signedIn: false,
                                                 onboardingWillPresent: false,
                                                 welcomeSeen: false),
                       "sign-in stays FIRST — never before the gate")
    }

    // A fresh install gets the full onboarding flow (which OPENS with the
    // welcome) — the standalone welcome must not double-present over it.
    func testOnboardingFlowSupersedesTheStandaloneWelcome() {
        XCTAssertFalse(WelcomeGate.shouldPresent(signedIn: true,
                                                 onboardingWillPresent: true,
                                                 welcomeSeen: false))
    }

    // Scenario: an established install still sees the welcome once after an update
    // (migration marks onboarding complete; the welcome flag is INDEPENDENT)
    func testMigratedInstallStillSeesTheWelcomeOnce() {
        let d = freshDefaults()
        // migrateIfPriorUse's effect: onboarding completed, welcome untouched.
        d.set(true, forKey: "foundryx.onboarding.completed")
        XCTAssertFalse(WelcomePrefs.seen(defaults: d),
                       "marking onboarding complete must not mark the welcome seen")
        XCTAssertTrue(WelcomeGate.shouldPresent(signedIn: true,
                                                onboardingWillPresent: false,
                                                welcomeSeen: WelcomePrefs.seen(defaults: d)))
    }

    // Scenario: Set up later dismisses the welcome forever
    func testMarkSeenSuppressesTheWelcomeOnTheNextLaunch() {
        let d = freshDefaults()
        WelcomePrefs.markSeen(defaults: d)
        XCTAssertTrue(WelcomePrefs.seen(defaults: d))
        XCTAssertFalse(WelcomeGate.shouldPresent(signedIn: true,
                                                 onboardingWillPresent: false,
                                                 welcomeSeen: WelcomePrefs.seen(defaults: d)))
    }

    // The flag is its own key, independent of the onboarding once-flag.
    func testWelcomeSeenKeyIsIndependentOfOnboardingCompleted() {
        XCTAssertEqual(WelcomePrefs.seenKey, "foundryx.welcome.seen")
        let d = freshDefaults()
        WelcomePrefs.markSeen(defaults: d)
        XCTAssertFalse(d.bool(forKey: "foundryx.onboarding.completed"),
                       "welcome seen must not imply onboarding completed")
    }
}

/// The app shell (features/app-shell.feature, spec §1 + T1 20260715T1457, Nick
/// 2026-07-15): four tabs in order — Capture, Activity, Chats, Settings — Capture
/// first. Settings is a first-class bottom-nav tab now (superseding the 2026-07-14
/// "Settings as a sheet / 3 content tabs" decision); Device management still lives
/// inside Settings (no Device tab). The Chat tab's label reads **Chats** (plural,
/// matching the rail — T-PHONE-CHATLAW, IA-D1) — the tab count and order are
/// unaffected (tracks.md T-PHONE-CHATLAW's own gate: "the four tabs and their
/// order do not change; Capture stays the launch tab").
final class AppShellPresentationTests: XCTestCase {

    // Scenario: the app shows Capture, Activity, Chats, Settings tabs in order
    func testTabBarIsCaptureActivityChatsSettingsInOrder() {
        XCTAssertEqual(AppTab.allCases, [.capture, .activity, .chat, .settings])
        XCTAssertEqual(AppTab.allCases.map(\.label),
                       ["Capture", "Activity", "Chats", "Settings"])
        XCTAssertEqual(AppTab.launch, .capture, "Capture is the launch/home tab")
    }

    // Regression guard (T-PHONE-CHATLAW): still exactly 4 tabs, no fifth added for
    // multiplayer — it enters through the chat-list drawer instead
    // (tracks.md T-PHONE-CHATLAW, ia-brief.md §5.3).
    func testStillExactlyFourTabsNoFifthForMultiplayer() {
        XCTAssertEqual(AppTab.allCases.count, 4,
                       "multiplayer must enter through the chat-list drawer, never a fifth tab")
    }

    // Scenario: Settings IS a tab now; Device still is NOT (it lives inside Settings)
    func testSettingsIsATabButDeviceIsNot() {
        let labels = AppTab.allCases.map(\.label)
        XCTAssertTrue(labels.contains("Settings"),
                      "Settings is the 4th bottom-nav tab (Nick 2026-07-15)")
        XCTAssertFalse(labels.contains("Device"), "Device lives inside Settings, not a tab")
    }

    // Every tab carries a usable SF Symbol.
    func testTabIcons() {
        for tab in AppTab.allCases {
            XCTAssertFalse(tab.systemImage.isEmpty, "\(tab) needs an icon")
        }
        XCTAssertEqual(AppTab.settings.systemImage, "gearshape")
    }

    // The Settings tab carries its title (was the sheet title before the supersession).
    func testSettingsTabTitle() {
        XCTAssertEqual(SettingsSheetPresentation.title, "Settings")
    }
}

/// B5 — the waitlist/upsell button never silently no-ops for a tokenless
/// (phone-only) user: sign-in first, POST after sign-in, honest caption when
/// the sign-in is dismissed.
final class WaitlistJoinTests: XCTestCase {

    // Scenario: a local user with no id token can join the cloud waitlist
    func testTokenlessUserIsRoutedToSignInFirst() {
        XCTAssertEqual(WaitlistJoin.step(joined: false, hasIdToken: false), .signInFirst)
    }

    func testSignedInUserPostsDirectly() {
        XCTAssertEqual(WaitlistJoin.step(joined: false, hasIdToken: true), .post)
    }

    func testJoinedUserDoesNothing() {
        XCTAssertEqual(WaitlistJoin.step(joined: true, hasIdToken: false), .alreadyJoined)
        XCTAssertEqual(WaitlistJoin.step(joined: true, hasIdToken: true), .alreadyJoined)
    }

    // Scenario: dismissing the sign-in leaves an honest caption
    func testDismissedSignInCaption() {
        XCTAssertEqual(WaitlistJoin.signInCaption, "Sign in to join")
    }
}
