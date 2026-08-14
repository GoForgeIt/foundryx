import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryX

/// EVERY STATE THE CEREMONY CAN PUT SOMEBODY IN, DRIVEN THROUGH THE APP THAT PUTS THEM THERE.
///
/// `UnansweredKeyDoesNotTrapMeFeatureTests` proves ONE state has a way out. This proves the
/// population does — because the defect was never "we got `.handshakeUnanswered` wrong", it was
/// "the exits hang off whichever state somebody was looking at when they wrote them". Six
/// instances, and the last one found here: `.didNotFinish`, the screen a recorder that REFUSED
/// the key Solleva holds lands on, whose FIRST and PRIMARY button was "Try again" — a title that
/// fell through `ceremonyAction`'s `default` arm and closed the entire connect sheet, under a
/// body reading "Try again before you close this."
///
/// EVERY BUTTON IS PRESSED BY ITS OWN TITLE THROUGH THE APP'S REAL ROUTING TABLE, and the titles
/// come from `PocketOnboardingView.drawnActions` — the same property the view's `body` draws
/// from. A scenario that asserted against a constant a test author picked would pass over a
/// screen the app never renders, which is the whole defect one level down.
///
/// THE MUTATIONS THESE ANSWER TO, all in `App/DeviceScreen.swift` or the kit's action arrays:
///   * restore the `where ceremonyScreen == …` allowlist on the retry row — the refused-key
///     scenarios go red naming a button that closes the flow;
///   * delete the `case PocketMintConsentPresentation.resetAction` arm — every "reset guidance
///     is reachable" scenario reds, on four different states;
///   * take the reset action back out of `handshakeUnanswered.actions` or `didNotFinish.actions`
///     — the screen reds as offering no way to start the recorder over;
///   * take the entry action out of `mintNotVerified.actions` — the owner of a recorder that
///     blindly acknowledged our key can no longer reach the other app's key.
/// None of the four moves any gate that existed before this file.
final class EveryStateHasAWayOutFeatureTests: XCTestCase {

    func testEveryCeremonyStateOffersTheExitsThatStateNeeds() async throws {
        let world = try await CeremonyExitWorld()
        defer { world.cleanup() }
        let result = try await BrineFeatureRunner.run(
            "every-state-has-a-way-out",
            registry: StepRegistry(CeremonyExitSteps.make(world)))
        // THE POPULATION IS PINNED. A runner that only asserts "nothing failed" is green the
        // moment the scenarios are deleted.
        XCTAssertEqual(result.passed, 17, "all seventeen scenarios must run and pass")
    }
}

// MARK: - Steps

private enum CeremonyExitSteps {
    static func make(_ world: CeremonyExitWorld) -> [StepDefinition] {
        let givens = [
            "a recorder that refuses the key Solleva holds",
            "a recorder that says nothing at all to the key Solleva holds",
            "a recorder no app has claimed, and Solleva holds no key for it",
            "a recorder another app owns, and Solleva holds no key for it",
            "a recorder that says yes to any key and goes on using the one it has",
            "a recorder Solleva holds no key for, and secure storage on this iPhone refuses to keep one",
            "a recorder Solleva may hold a key for, and secure storage on this iPhone cannot be read",
        ]
        let whens = [
            "I tap that recorder in the connect sheet",
            "I confirm that Solleva should send a new key",
            "I ask Solleva to try that recorder again",
            "I ask Solleva to try connecting again",
            "I ask how to start the recorder over",
            "I choose to enter a key I already have",
        ]
        let thens = [
            "Solleva puts up a screen rather than a caption",
            "that screen offers to let me enter a key",
            "that screen offers the maker's reset guidance",
            "that screen offers to try the recorder again",
            "that screen offers to send a new key",
            "that screen does not offer to send a new key",
            "nothing on that screen offers to forget the recorder's key",
            "every button on that screen either does something or says out loud that it closes",
            "the flow is still open on a screen with a way out",
            "Solleva asked the recorder again rather than dismissing me",
            "the recorder joins my account",
            "Solleva is showing me the maker's reset guidance",
            "Solleva is showing me the key field",
            "Solleva says the recorder already belongs to another app",
            "Solleva says it cannot confirm the recorder took the key",
            "Solleva says this iPhone could not store the key",
            "Solleva says it cannot read its own key",
            "Solleva sent that recorder no key at all",
            "the guidance states the cost before the gesture",
            "the guidance says Solleva can neither perform it nor check it worked",
            "the guidance can take me back to setting the recorder up",
            "no setup screen in the ceremony offers to forget, reveal, copy, share or export a key",
        ]
        var steps = givens.map { phrase in
            defineStep(phrase) { context, _, _ in try await world.given(phrase); return context }
        }
        steps += whens.map { phrase in
            defineStep(phrase) { context, _, _ in try await world.when(phrase); return context }
        }
        steps += thens.map { phrase in
            defineCheck(phrase) { _, _, _ in try await world.then(phrase) }
        }
        return steps
    }
}

// MARK: - A Keychain that can be told how to fail

/// THE TWO WAYS CUSTODY GOES WRONG, AS A STORE RATHER THAN AS A MOCKED OUTCOME.
///
/// `.keyNotKept` and `.custodyUnreadable` are two of the states this feature is about, and the
/// only honest way to reach them from inside the app is to hand the shipped attachment a store
/// that behaves that way — a save that throws, a read that throws. Everything above the store is
/// the shipping code: `PocketOnboardingCoordinator.restore`, `provisionFactoryFresh`'s
/// custody-before-the-radio ordering, and the model's routing.
private actor ScriptedSecretStore: PocketSecretStore {
    enum Behaviour: Sendable {
        case ordinary
        /// `save` throws. Custody runs BEFORE the `APP&SK&` write, so the recorder is never
        /// asked — which is the reassurance the `.keyNotKept` screen makes, and a scenario here
        /// checks the recorder's own command log to make sure it is true.
        case refusesToSave
        /// `secret(for:)` throws — a Keychain locked since restart. NOT the same answer as "there
        /// is no key", and routing it to the mint offer would send a second key to a recorder
        /// Solleva itself provisioned.
        case unreadable
    }

    private let behaviour: Behaviour
    private let inner = InMemoryPocketSecretStore()

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    func save(_ secret: String, for identity: PocketAuthenticatedIdentity) async throws {
        if behaviour == .refusesToSave { throw PocketSecretStoreError.unavailable }
        try await inner.save(secret, for: identity)
    }

    func secret(for identity: PocketAuthenticatedIdentity) async throws -> String? {
        if behaviour == .unreadable { throw PocketSecretStoreError.unavailable }
        return await inner.secret(for: identity)
    }

    func remove(for identity: PocketAuthenticatedIdentity) async throws {
        try await inner.remove(for: identity)
    }
}

// MARK: - The world one scenario stages

/// `@MainActor` because `RecordingDeviceAttachModel` is — it is the `ObservableObject` the
/// connect sheet creates and mutates on the main actor, and a world that hopped actors to reach
/// it would exercise a different threading story than the one that ships.
@MainActor
private final class CeremonyExitWorld {

    /// WHICH RECORDER IS IN FRONT OF THE PERSON. Held as a value rather than inferred, because
    /// the "every button" check RE-STAGES the whole situation between presses: some of those
    /// buttons mint, and a mint changes what the recorder is.
    private enum Situation: Sendable {
        case refusesOurKey
        case silentToOurKey
        case unclaimed
        case ownedByAnotherApp
        case blindlyAcknowledges
        case custodyRefusesToSave
        case custodyUnreadable
    }

    /// The key the recorder actually holds. Never the one Solleva is given.
    private static let recorderKey = "cafebabe12345678"
    /// What Solleva holds: well formed, 16 ASCII characters, and not this recorder's.
    private static let staleKey = "0123456789abcdef"
    private static let recorderName = "PKT01_BLUE_26079bc5"

    /// THE APP'S OWN MODEL — the type the connect sheet creates with `@StateObject` and runs
    /// every tap through, not a stand-in with the same shape.
    private let model = RecordingDeviceAttachModel()

    private var devices: DeviceManager!
    /// Kept for the world's whole life: the fake's peripheral and central hold their stack
    /// `unowned`, so releasing one while a session is still in flight is a crash rather than a
    /// test failure.
    private var stacks: [FakePocketBLEStack] = []
    private var stack: FakePocketBLEStack!
    private var identifier = UUID()
    private var situation: Situation = .silentToOurKey
    private var adopted = false
    private var scenarioIndex = 0
    /// THE WHEN STEPS THIS SCENARIO HAS RUN SINCE ITS `Given`. The "every button" check re-stages
    /// the entire situation between presses — several of those buttons mint, and a recorder that
    /// has been minted for is a different recorder — so it has to be able to walk the person back
    /// to the same screen, not merely back to the tap.
    private var path: [String] = []

    private nonisolated let token = UUID().uuidString
    private nonisolated let sandbox: URL
    private nonisolated let scopeDefaultsName: String
    /// `UserDefaults` is not `Sendable` and this one is reachable from the nonisolated
    /// `cleanup()`. Written once in `init`, read once in teardown, after every scenario.
    private nonisolated(unsafe) let scopeDefaults: UserDefaults

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-ceremony-exits-\(token)", isDirectory: true)
        scopeDefaultsName = "foundryx.ceremony-exits.scope.\(token)"
        guard let defaults = UserDefaults(suiteName: scopeDefaultsName) else {
            throw BrineStepError("could not create an isolated UserDefaults suite")
        }
        scopeDefaults = defaults
        let container = sandbox.appendingPathComponent("documents/foundryx-captures",
                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        CaptureAccountScope.setContainerForTests(container)
        CaptureAccountScope.setApplicationSupportRootForTests(
            sandbox.appendingPathComponent("application-support", isDirectory: true))
        CaptureAccountScope.setDefaultsForTests(scopeDefaults)
    }

    nonisolated func cleanup() {
        RecordingDeviceAttachModel.scenarioSeam = nil
        try? CaptureAccountScope.signOutForTests()
        CaptureAccountScope.resetTestEnvironment()
        scopeDefaults.removePersistentDomain(forName: scopeDefaultsName)
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: Given

    func given(_ phrase: String) async throws {
        switch phrase {
        case "a recorder that refuses the key Solleva holds":
            try await stage(.refusesOurKey)
        case "a recorder that says nothing at all to the key Solleva holds":
            try await stage(.silentToOurKey)
        case "a recorder no app has claimed, and Solleva holds no key for it":
            try await stage(.unclaimed)
        case "a recorder another app owns, and Solleva holds no key for it":
            try await stage(.ownedByAnotherApp)
        case "a recorder that says yes to any key and goes on using the one it has":
            try await stage(.blindlyAcknowledges)
        case "a recorder Solleva holds no key for, and secure storage on this iPhone refuses to keep one":
            try await stage(.custodyRefusesToSave)
        case "a recorder Solleva may hold a key for, and secure storage on this iPhone cannot be read":
            try await stage(.custodyUnreadable)
        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    /// Build the whole situation from nothing: a fresh account, a fresh peripheral identity, a
    /// fresh scripted recorder, and whatever custody that situation implies. It is a function
    /// rather than inline setup precisely so the "every button" check can run it again between
    /// presses — several of those buttons mint, and a minted recorder is a different recorder.
    private func stage(_ situation: Situation) async throws {
        self.situation = situation
        scenarioIndex += 1
        adopted = false
        path = []
        CaptureAccountScope.setAccountForTests(
            email: "ceremony-exits-\(token)-\(scenarioIndex)@example.com")
        guard let binding = CaptureAccountScope.currentAccountBinding(),
              binding.scope != CaptureAccountScope.signedOutScope else {
            throw BrineStepError("signing in did not leave the signed-out scope")
        }
        identifier = UUID()

        let behaviour: FakePocketBLEStack.KeyBehaviour
        let store: any PocketSecretStore
        let seeded: String?
        switch situation {
        case .refusesOurKey:
            // THE POLITE FIRMWARE: it answers a wrong key with `MCU&SK&FAIL`, which becomes
            // `.recoveryRequired` — the state where the key is PROVABLY wrong, and the state a
            // single mistyped character lands in.
            behaviour = .keyed(Self.recorderKey); store = ScriptedSecretStore(.ordinary)
            seeded = Self.staleKey
        case .silentToOurKey:
            // OBSERVED HARDWARE. Unit PKT01_BLUE_26079bc5 answers a wrong key with nothing at
            // all until the control deadline expires.
            behaviour = .silentToWrongKey(holding: Self.recorderKey)
            store = ScriptedSecretStore(.ordinary); seeded = Self.staleKey
        case .unclaimed:
            behaviour = .factoryFresh; store = ScriptedSecretStore(.ordinary); seeded = nil
        case .ownedByAnotherApp:
            behaviour = .keyed(Self.recorderKey); store = ScriptedSecretStore(.ordinary)
            seeded = nil
        case .blindlyAcknowledges:
            // THE DANGEROUS ANSWER TO U1: it says `MCU&SK&OK` to anything and goes on using the
            // key it has, so the access-point read-back reports the OTHER app's password.
            behaviour = .blindlyAcknowledges(holding: Self.recorderKey)
            store = ScriptedSecretStore(.ordinary); seeded = nil
        case .custodyRefusesToSave:
            behaviour = .factoryFresh; store = ScriptedSecretStore(.refusesToSave); seeded = nil
        case .custodyUnreadable:
            behaviour = .factoryFresh; store = ScriptedSecretStore(.unreadable); seeded = nil
        }

        let made = FakePocketBLEStack(deviceId: identifier, deviceName: Self.recorderName,
                                      behaviour: behaviour)
        stacks.append(made)
        stack = made
        devices = DeviceManager(makeCentral: made.factory)
        if let seeded {
            // CUSTODY IS SEEDED THROUGH THE SHIPPED SEAM, not around it.
            try await store.save(seeded,
                                 for: try PocketAuthenticatedIdentity(
                                    peripheralIdentifier: identifier.uuidString))
        }
        RecordingDeviceAttachModel.scenarioSeam = .init(
            makeCentral: made.factory,
            secrets: store,
            // `control` is the deadline the unanswered `APP&SK&` write expires on — short, but
            // not so short that the silence is indistinguishable from a slow fake.
            deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 2))
    }

    // MARK: When

    func when(_ phrase: String) async throws {
        try await execute(when: phrase)
        path.append(phrase)
    }

    /// The When step WITHOUT recording it, so the replay below cannot grow the path it is
    /// walking.
    private func execute(when phrase: String) async throws {
        switch phrase {
        case "I tap that recorder in the connect sheet":
            try await tapTheRecorder()
        case "I confirm that Solleva should send a new key":
            try await tapCeremonyButton(PocketMintConsentPresentation.confirmAction)
        case "I ask Solleva to try that recorder again":
            try await tapCeremonyButton(PocketSetupPresentation.retryAction)
        case "I ask Solleva to try connecting again":
            try await tapCeremonyButton(PocketMintNotVerifiedPresentation.retryAction)
        case "I ask how to start the recorder over":
            try await tapCeremonyButton(PocketMintConsentPresentation.resetAction)
        case "I choose to enter a key I already have":
            try await tapCeremonyButton(PocketSessionKeyEntryPresentation.entryAction)
        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    // MARK: Then

    func then(_ phrase: String) async throws {
        switch phrase {
        case "Solleva puts up a screen rather than a caption":
            guard model.showingCeremony else {
                throw BrineStepError(
                    "the tap produced no screen at all — only the inline caption "
                        + "\"\(model.inlineMessage ?? "(none)")\", behind a row whose only "
                        + "affordance is to be tapped again and produce it again")
            }

        case "that screen offers to let me enter a key":
            try requireExit(PocketSessionKeyEntryPresentation.entryAction,
                            named: "a way to enter a key",
                            why: "that field REPLACES the key in custody, and it hung off the one "
                                + "state that means \"Solleva holds no key\" — which a recorder "
                                + "with a wrong key stored for it can never produce")

        case "that screen offers the maker's reset guidance":
            try requireExit(PocketMintConsentPresentation.resetAction,
                            named: "the maker's reset guidance",
                            why: "PocketFactoryResetPresentation is fully written — the cost "
                                + "first, the gesture, and the two things Solleva cannot do — and "
                                + "it was reachable from the CONSENT screen only, which is the "
                                + "one state the owner it is written for cannot reach")

        case "that screen offers to try the recorder again":
            let titles = drawnActions()
            guard titles.contains(PocketSetupPresentation.retryAction)
                    || titles.contains(PocketMintNotVerifiedPresentation.retryAction) else {
                throw BrineStepError("the screen offers \(titles), with no way to ask the "
                                        + "recorder again")
            }

        case "that screen offers to send a new key":
            try requireExit(PocketMintConsentPresentation.confirmAction,
                            named: "the decision to send a new key",
                            why: "an unclaimed recorder is the one situation in which minting is "
                                + "the answer, and it is the only door to a mint in the app")

        case "that screen does not offer to send a new key":
            guard !drawnActions().contains(PocketMintConsentPresentation.confirmAction) else {
                throw BrineStepError(
                    "the screen offers to mint. Solleva may already hold this recorder's key and "
                        + "simply be unable to read it — a second key would replace the one the "
                        + "recorder is already using, and change its WiFi password with it")
            }

        case "nothing on that screen offers to forget the recorder's key":
            let text = (drawnActions() + [drawnTitle(), drawnBody()])
                .joined(separator: " ").lowercased()
            for word in ["forget", "erase", "wipe", "delete"] {
                guard !text.contains(word) else {
                    throw BrineStepError(
                        "the screen offers to \(word) the key. This firmware has no reset opcode "
                            + "and no key-read opcode, so on a recorder Solleva minted for, "
                            + "custody may hold the only copy in the world — and this screen is "
                            + "produced by evidence that proves nothing")
                }
            }

        // THE ASSERTION THAT WOULD HAVE CAUGHT `.didNotFinish`. Every button is pressed, through
        // the app's own routing table, and the whole situation is re-staged between presses
        // because several of these buttons mint. A button that closes the flow is legitimate only
        // when its own words say so.
        case "every button on that screen either does something or says out loud that it closes":
            // The words a button is allowed to close the flow with. Anything else that closes it
            // is a dead end wearing an action's clothes.
            let closing: Set<String> = ["Done", "Close", "Not now", "See what's connected"]
            let titles = drawnActions()
            let screen = model.ceremonyScreen
            let replay = path
            guard !titles.isEmpty else {
                throw BrineStepError("\(screen) draws no buttons at all")
            }
            for title in titles {
                let disposition = model.ceremonyAction(title)
                if disposition == .closeTheSheet && !closing.contains(title) {
                    throw BrineStepError("""
                    "\(title)" closes the entire connect sheet and does not say so. It is one of \
                    \(titles) on \(screen), and it is the shape of the shipped defect: \
                    `.didNotFinish` offered "Try again" as its FIRST, PRIMARY button under a body \
                    reading "Try again before you close this", and the title fell through the \
                    routing table's `default` arm because the retry row was guarded by an \
                    allowlist of three other screens.
                    """)
                }
                if disposition == .closeTheSheet { model.dismissCeremony() }
                try await AppScenarioHost.settle(untilTrue: { !self.model.submittingKey },
                                                 timeout: 30,
                                                 describing: "\"\(title)\" to finish")
                // A FRESH SITUATION FOR THE NEXT PRESS, WALKED BACK BY THE SAME STEPS. "Send a
                // new key" mints, and a recorder that has been minted for is a different
                // recorder — so the screen is rebuilt from nothing and the person is walked back
                // to it through the app rather than by assignment.
                guard title != titles.last else { break }
                try await stage(situation)
                for phrase in replay { try await execute(when: phrase) }
                guard model.showingCeremony, model.ceremonyScreen == screen else {
                    throw BrineStepError(
                        "re-walking \(replay) landed on "
                            + (model.showingCeremony ? "\(model.ceremonyScreen)" : "no screen")
                            + " rather than back on \(screen), so the remaining buttons could not "
                            + "be pressed on the screen this scenario is about")
                }
            }

        case "the flow is still open on a screen with a way out":
            guard model.showingCeremony else {
                throw BrineStepError(
                    "the button dismissed the whole flow. A retry that quietly closes the one "
                        + "screen with a way out is the deadlock with an extra step")
            }
            let titles = drawnActions()
            guard titles.contains(PocketSessionKeyEntryPresentation.entryAction)
                    || titles.contains(PocketMintConsentPresentation.resetAction) else {
                throw BrineStepError(
                    "the screen the retry landed on offers \(titles) — neither the key field nor "
                        + "the reset guidance, so the second attempt is strictly worse than the "
                        + "first")
            }

        case "Solleva asked the recorder again rather than dismissing me":
            let sessions = stack.commandsWritten.filter { $0.hasPrefix("SK&") }
            guard sessions.count >= 2 else {
                throw BrineStepError(
                    "the recorder was asked \(sessions.count) time(s) across a tap and a retry. "
                        + "A \"try again\" that never reaches the radio is a dismissal wearing "
                        + "the word")
            }

        case "Solleva is showing me the maker's reset guidance":
            try requireScreen(.factoryReset, describing: "asking how to start the recorder over")

        case "Solleva is showing me the key field":
            try requireScreen(.enterExistingKey,
                              describing: "choosing "
                                  + "\"\(PocketSessionKeyEntryPresentation.entryAction)\"")

        case "the recorder joins my account":
            guard adopted, !model.showingCeremony else {
                throw BrineStepError(
                    "the retry did not adopt the recorder — the app is "
                        + (model.showingCeremony ? "still on \(model.ceremonyScreen)"
                                                 : "showing nothing and never called back"))
            }
            let remembered = (try? RecordingDeviceStore.current()?.records()) ?? []
            guard remembered.contains(where: {
                $0.identity.hardwareToken == self.identifier.uuidString.lowercased()
            }) else {
                throw BrineStepError("the account does not remember the recorder — it holds "
                                        + "\(remembered.count) device(s)")
            }

        case "Solleva says the recorder already belongs to another app":
            try requireScreen(.mintRefused, describing: "the recorder refusing the new key")

        case "Solleva says it cannot confirm the recorder took the key":
            try requireScreen(.mintNotVerified, describing: "an acknowledged but unproven mint")

        case "Solleva says this iPhone could not store the key":
            try requireScreen(.keyNotKept, describing: "secure storage refusing the key")

        case "Solleva says it cannot read its own key":
            try requireScreen(.custodyUnreadable, describing: "custody that could not be read")

        case "Solleva sent that recorder no key at all":
            let keys = stack.commandsWritten.filter { $0.hasPrefix("SK&") }
            guard keys.isEmpty else {
                throw BrineStepError(
                    "the recorder was sent \(keys.count) key(s) on a path whose whole reassurance "
                        + "is that it was sent nothing")
            }

        case "the guidance states the cost before the gesture":
            let sections = PocketFactoryResetPresentation.sections
            guard let first = sections.first, first.body == PocketFactoryResetPresentation.costFirst
            else {
                throw BrineStepError(
                    "the reset guidance leads with \"\(sections.first?.title ?? "nothing")\". "
                        + "Somebody skimming for the steps has to read the cost on the way")
            }

        case "the guidance says Solleva can neither perform it nor check it worked":
            let text = PocketFactoryResetPresentation.everyLine.joined(separator: " ").lowercased()
            guard text.contains("can't do this"), text.contains("can't tell you whether it worked")
            else {
                throw BrineStepError(
                    "the guidance does not say that Solleva can neither perform the gesture nor "
                        + "verify it. Someone who believes the app is supervising a destructive "
                        + "gesture will do it casually")
            }

        case "the guidance can take me back to setting the recorder up":
            let titles = drawnActions()
            guard titles.contains(PocketFactoryResetPresentation.retryAction) else {
                throw BrineStepError("the reset guidance offers \(titles) and no way onward")
            }
            let disposition = model.ceremonyAction(PocketFactoryResetPresentation.retryAction)
            guard disposition == .handled, model.ceremonyScreen == .mintConsent else {
                throw BrineStepError(
                    "\"\(PocketFactoryResetPresentation.retryAction)\" produced \(disposition) and "
                        + "left the app on \(model.ceremonyScreen)")
            }

        case "no setup screen in the ceremony offers to forget, reveal, copy, share or export a key":
            // HELD OVER THE BUTTONS, NOT OVER THE PROSE. The consent screen's copy has to be able
            // to say the recorder "may take the new key and forget the old one" — that sentence is
            // the honest account of open question U1, and a check that banned the WORD everywhere
            // would delete the warning rather than the button. What may not exist is an ACTION.
            let everyAction = PocketSetupPresentation.all.flatMap(\.actions)
                + PocketMintConsentPresentation.actions
                + PocketMintRefusedPresentation.actions
                + PocketMintNotVerifiedPresentation.actions
                + PocketFactoryResetPresentation.actions
            for title in everyAction {
                for word in ["forget", "reveal", "copy", "share", "export", "erase", "wipe"] {
                    guard !title.lowercased().contains(word) else {
                        throw BrineStepError(
                            "a setup screen offers \"\(title)\". §10 custody is a separate, "
                                + "deliberately reached screen; the setup ceremony neither shows a "
                                + "key nor offers to destroy one, and on hardware with no reset "
                                + "opcode a one-tap forget is a one-tap brick")
                    }
                }
            }
            // AND THE PROSE MAY STILL NOT DESCRIBE A REVEAL, which is the shipped property the
            // hostless suite already holds over this same population.
            let everyLine = PocketSetupPresentation.all
                .flatMap { [$0.title, $0.body] + $0.actions }
                .joined(separator: " ").lowercased()
            for word in ["reveal", "copy", "share", "export"] {
                guard !everyLine.contains(word) else {
                    throw BrineStepError("a setup screen's copy offers to \(word) a credential")
                }
            }

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    // MARK: - Driving the app

    private func tapTheRecorder() async throws {
        model.attach(DiscoveredDevice(id: identifier, name: Self.recorderName, rssi: -42),
                     using: devices,
                     onAdopted: { self.adopted = true })
        try await AppScenarioHost.settle(untilTrue: { self.model.attaching == nil },
                                         timeout: 30, describing: "the tap to finish")
    }

    /// THE VIEW'S ACTION CLOSURE, VERBATIM. `App/DeviceScreen.swift` calls `ceremonyAction` and
    /// dismisses on `.closeTheSheet`; a step that called the model and ignored the answer would
    /// report a button that silently closes the sheet as one that worked.
    private func tapCeremonyButton(_ title: String) async throws {
        guard drawnActions().contains(title) else {
            throw BrineStepError(
                "\"\(title)\" is not on this screen. \(model.ceremonyScreen) offers "
                    + "\(drawnActions()), so a person standing here cannot take that action at "
                    + "all — which is the defect, not the test's problem")
        }
        if model.ceremonyAction(title) == .closeTheSheet { model.dismissCeremony() }
        try await AppScenarioHost.settle(untilTrue: { !self.model.submittingKey },
                                         timeout: 30, describing: "\"\(title)\" to finish")
    }

    // MARK: - What the app is actually drawing

    /// THE BUTTONS THE VIEW PUTS ON SCREEN FOR THE STATE THE MODEL SET — asked of
    /// `PocketOnboardingView.drawnActions`, which is the property the view's own `body` draws
    /// from. Asking a constant a test author picked would pass over a screen the app never
    /// renders, which is this defect class one level down.
    private func drawnActions() -> [String] {
        PocketOnboardingView(screen: model.ceremonyScreen, action: { _ in }).drawnActions
    }

    private func drawnTitle() -> String {
        PocketOnboardingView(screen: model.ceremonyScreen, action: { _ in }).presentation.title
    }

    private func drawnBody() -> String {
        PocketOnboardingView(screen: model.ceremonyScreen, action: { _ in }).presentation.body
    }

    private func requireExit(_ title: String, named what: String, why: String) throws {
        let titles = drawnActions()
        guard titles.contains(title) else {
            throw BrineStepError("""
            \(model.ceremonyScreen) offers \(titles) — none of which is \(what).
            \(why)
            """)
        }
    }

    private func requireScreen(_ expected: PocketOnboardingView.Screen,
                               describing what: String) throws {
        guard model.showingCeremony else {
            throw BrineStepError("no screen is up; \(what) produced nothing to look at")
        }
        guard model.ceremonyScreen == expected else {
            throw BrineStepError(
                "\(what) landed on \(model.ceremonyScreen), not \(expected)")
        }
    }
}
