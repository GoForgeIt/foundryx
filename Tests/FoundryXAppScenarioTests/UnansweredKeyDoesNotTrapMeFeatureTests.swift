import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryX

/// THE OWNER'S DEADLOCK, DRIVEN AGAINST THE APP THAT PRODUCED IT.
///
/// `RecordingDeviceAttachModel` lives in `App/DeviceScreen.swift`. It is what a tap in the
/// connect sheet runs, it owns which ceremony screen a tap lands on, and nothing in this
/// repository could execute it: `swift test` compiles the FoundryXKit library alone. So the
/// hostless Pocket suites can prove — and did prove, green, for the whole time the owner was
/// stuck — that `PocketOnboardingCoordinator.restore` distinguishes a refused key from an
/// unanswered one, while the application turned the second into a caption with no way off it.
///
/// EVERY OBJECT BELOW EXCEPT THE RADIO AND THE KEYCHAIN IS THE SHIPPED ONE, running inside the
/// shipping app's process: the app's own model, `RecordingDeviceAttachment`,
/// `PocketSeamTransport`, `PocketBLEClient`, `PocketOnboardingCoordinator`,
/// `PocketSessionKeyEntryCoordinator`, `PocketRecordingDeviceBridge`,
/// `RecordingDeviceAdoption`, and `PocketOnboardingView`'s own screen→copy map. The radio is
/// `FakePocketBLEStack` in its `.silentToWrongKey` mode — the behaviour unit PKT01_BLUE_26079bc5
/// actually exhibits — and the Keychain is in-memory because this lane's host is unsigned.
///
/// THE MUTATIONS THESE SCENARIOS ANSWER TO, all of them edits to `App/DeviceScreen.swift`:
///   * drop the `.unreachable(.handshakeUnanswered)` route from `attach` and the tap falls back
///     to an inline caption — the reported defect, exactly;
///   * drop `.handshakeUnanswered` from `ceremonyAction`'s retry row and "Try again" silently
///     dismisses the sheet;
///   * drop `.handshakeUnanswered` from `retryPlainAttach`'s switch and a retry that fails the
///     same way reports itself as an unrelated "Setup didn't finish".
/// None of the three moves any existing gate.
final class UnansweredKeyDoesNotTrapMeFeatureTests: XCTestCase {

    func testAKeyTheRecorderNeverAnswersDoesNotTrapTheOwner() async throws {
        let world = try await UnansweredKeyWorld()
        defer { world.cleanup() }
        let result = try await BrineFeatureRunner.run(
            "a-key-the-recorder-never-answers-does-not-trap-me",
            registry: StepRegistry(UnansweredKeySteps.make(world)))
        // THE POPULATION IS PINNED. A runner that only asserts "nothing failed" is green once
        // the scenarios have been deleted.
        XCTAssertEqual(result.passed, 5, "all five scenarios must run and pass")
    }
}

// MARK: - Steps

private enum UnansweredKeySteps {
    static func make(_ world: UnansweredKeyWorld) -> [StepDefinition] {
        let givens = [
            "a recorder that answers only the key it was set up with, and Solleva holds a different key",
        ]
        let whens = [
            "I tap that recorder in the connect sheet",
            "I choose to enter a key I already have",
            "I enter the key that recorder was actually set up with",
            "I ask Solleva to try that recorder again",
        ]
        let thens = [
            "Solleva puts up a screen rather than a caption I can only retry",
            "it says the recorder did not answer the key Solleva is holding",
            "it does not claim that key is the wrong one",
            "that screen offers to let me enter a key",
            "it offers to try the recorder again",
            "the key Solleva holds is still in secure custody",
            "Solleva sent that recorder exactly one key",
            "Solleva is showing me the key field",
            "the recorder is adopted through the shipped chain",
            "the key Solleva now holds is the one the recorder answered",
            "Solleva is still on the screen that offers to let me enter a key",
            "Solleva sent that recorder one key per attempt and no more",
            "no setup screen offers to reveal, copy, share, or export a key",
            "the key Solleva holds appears in no line the setup screens can display",
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

// MARK: - The world one scenario stages

/// `@MainActor` because `RecordingDeviceAttachModel` is — it is the `ObservableObject` the
/// connect sheet creates and mutates on the main actor, and a world that hopped actors to reach
/// it would exercise a different threading story than the one that ships.
@MainActor
private final class UnansweredKeyWorld {
    /// THE KEY THE RECORDER ACTUALLY HOLDS — the one a Mac in the same room proved works.
    private static let realKey = "cafebabe12345678"
    /// THE KEY SOLLEVA IS HOLDING. Well formed, 16 ASCII characters, and not the recorder's, so
    /// the recorder says nothing at all to it. It is never entered by hand in any scenario: it
    /// is already in custody when the tap happens, which is the owner's situation exactly.
    private static let staleKey = "0123456789abcdef"
    private static let recorderName = "PKT01_BLUE_26079bc5"

    /// THE APP'S OWN MODEL. Not a stand-in with the same shape — the type the connect sheet
    /// creates with `@StateObject` and runs every tap through.
    private let model = RecordingDeviceAttachModel()

    /// A `DeviceManager` over the SAME fake radio, because `attach` takes one: it is the object
    /// the `.live` fall-through hands an Omi to. No scenario here reaches that branch, and
    /// building it over the fake means none of them can quietly start a real central either.
    private var devices: DeviceManager!

    /// Kept for the world's whole life: the fake's peripheral and central hold their stack
    /// `unowned`, so releasing one while a session is still in flight is a crash rather than a
    /// test failure.
    private var stacks: [FakePocketBLEStack] = []
    private var stack: FakePocketBLEStack!
    private var identifier = UUID()
    private let secrets = InMemoryPocketSecretStore()
    private var adopted = false

    /// AN ACCOUNT, BECAUSE `RecordingDeviceStore` IS ACCOUNT-SCOPED. Adoption writes into the
    /// signed-in account's record file, so a scenario with no account would report the whole
    /// chain as "couldn't save it to your account" and prove nothing about the handshake. The
    /// container and defaults are redirected into a sandbox this world owns and removes.
    /// `nonisolated` so `cleanup()` can be called from the test's own teardown without hopping
    /// actors. Each is an immutable `Sendable` value; nothing here is shared mutable state.
    private nonisolated let token = UUID().uuidString
    private nonisolated let sandbox: URL
    private nonisolated let scopeDefaultsName: String
    /// `UserDefaults` is not `Sendable`, and this one is reachable from the nonisolated
    /// `cleanup()`. It is safe for the reason `nonisolated(unsafe)` exists: it is written once
    /// in `init` and read once in teardown, after every scenario has finished.
    private nonisolated(unsafe) let scopeDefaults: UserDefaults
    private var scenarioIndex = 0

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-unanswered-key-\(token)", isDirectory: true)
        scopeDefaultsName = "foundryx.unanswered-key.scope.\(token)"
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

    /// `nonisolated` so the test's teardown can run it without hopping actors: every static it
    /// touches is process-global, and the seam it clears is the one thing that would otherwise
    /// hand the NEXT suite a recorder it never staged.
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
        case "a recorder that answers only the key it was set up with, and Solleva holds a different key":
            // A FRESH ACCOUNT PER SCENARIO, so the scenario that adopts the recorder cannot
            // satisfy the ones that assert the account remembers nothing yet.
            scenarioIndex += 1
            adopted = false
            CaptureAccountScope.setAccountForTests(
                email: "unanswered-key-\(token)-\(scenarioIndex)@example.com")
            guard let binding = CaptureAccountScope.currentAccountBinding(),
                  binding.scope != CaptureAccountScope.signedOutScope else {
                throw BrineStepError("signing in did not leave the signed-out scope")
            }
            identifier = UUID()
            let made = FakePocketBLEStack(
                deviceId: identifier,
                deviceName: Self.recorderName,
                behaviour: .silentToWrongKey(holding: Self.realKey))
            stacks.append(made)
            stack = made
            devices = DeviceManager(makeCentral: made.factory)
            // CUSTODY IS SEEDED THROUGH THE SHIPPED SEAM, not by reaching around it. This is
            // "Solleva already has a key for this recorder", which is the whole premise.
            try await secrets.save(
                Self.staleKey,
                for: try PocketAuthenticatedIdentity(peripheralIdentifier: identifier.uuidString))
            RecordingDeviceAttachModel.scenarioSeam = .init(
                makeCentral: made.factory,
                secrets: secrets,
                // SHORT, BUT NOT SO SHORT THAT THE SILENCE IS INDISTINGUISHABLE FROM A SLOW
                // FAKE. `control` is the deadline the unanswered `APP&SK&` write actually
                // expires on, and it is the one this whole scenario turns on.
                deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 2))
        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    // MARK: When

    func when(_ phrase: String) async throws {
        switch phrase {
        // THE APP'S ENTRY POINT, WITH THE APP'S ARGUMENTS — the same call the row's tap makes.
        case "I tap that recorder in the connect sheet":
            model.attach(DiscoveredDevice(id: identifier, name: Self.recorderName, rssi: -42),
                         using: devices,
                         onAdopted: { self.adopted = true })
            try await AppScenarioHost.settle(untilTrue: { self.model.attaching == nil },
                                             timeout: 30,
                                             describing: "the tap to finish")

        // THE BUTTON, BY ITS OWN TITLE, THROUGH THE APP'S OWN ROUTING TABLE — and the sheet is
        // closed on `.closeTheSheet` exactly as the view's action closure closes it. Passing
        // the title is what makes this a claim about the screen the owner is looking at: a
        // button whose words the kit produced, handed to the function the view calls.
        case "I choose to enter a key I already have":
            tapCeremonyButton(PocketSessionKeyEntryPresentation.entryAction)

        case "I enter the key that recorder was actually set up with":
            model.submitExistingKey(Self.realKey)
            try await AppScenarioHost.settle(untilTrue: { !self.model.submittingKey },
                                             timeout: 30,
                                             describing: "the submitted key to be answered")

        case "I ask Solleva to try that recorder again":
            tapCeremonyButton(PocketSetupPresentation.retryAction)
            try await AppScenarioHost.settle(untilTrue: { !self.model.submittingKey },
                                             timeout: 30,
                                             describing: "the retry to finish")

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    // MARK: Then

    func then(_ phrase: String) async throws {
        switch phrase {
        case "Solleva puts up a screen rather than a caption I can only retry":
            guard model.showingCeremony else {
                throw BrineStepError(
                    "the recorder never answered the key Solleva holds and the app put up no "
                        + "screen at all. All it produced was the inline caption "
                        + "\"\(model.inlineMessage ?? "(none)")\" — and the only screen that "
                        + "can replace a key hangs off a state that means \"Solleva holds no "
                        + "key\", so from here there is nothing the owner can do but tap again "
                        + "and send the same unusable key")
            }

        case "it says the recorder did not answer the key Solleva is holding":
            let drawn = try drawnScreen()
            let text = (drawn.title + " " + drawn.body).lowercased()
            guard text.contains("didn't answer") || text.contains("said nothing") else {
                throw BrineStepError(
                    "the screen does not say the recorder failed to answer. It says: "
                        + "\"\(drawn.title)\"")
            }
            guard drawn.body.lowercased().contains("key") else {
                throw BrineStepError("the screen never mentions the key it is about")
            }

        // SILENCE IS NOT EVIDENCE, AND THE COPY MAY NOT PRETEND IT IS. A sleeping recorder, one
        // busy with another app, and one holding a different key are the same nothing from
        // here — so a screen that told the owner their key was rejected would be inventing a
        // fact, and one that offered to delete it would be acting on the invention.
        case "it does not claim that key is the wrong one":
            let drawn = try drawnScreen()
            let text = (drawn.title + " " + drawn.body + " " + drawn.actions.joined(separator: " "))
                .lowercased()
            for claim in ["refused", "rejected", "not accept", "didn't accept", "wrong key"] {
                guard !text.contains(claim) else {
                    throw BrineStepError(
                        "the screen says \"\(claim)\" about a key the recorder never answered. "
                            + "Nothing here distinguishes a wrong key from a sleeping recorder")
                }
            }
            guard text.contains("can't tell") else {
                throw BrineStepError(
                    "the screen does not admit that Solleva cannot tell why the recorder was "
                        + "silent, which is the one honest thing it knows")
            }
            guard !text.contains("forget") else {
                throw BrineStepError(
                    "the screen offers to forget the recorder's key on the strength of silence. "
                        + "This firmware has no reset and no key-read opcode, so on a recorder "
                        + "Solleva minted for, custody may hold the only copy in the world")
            }

        case "that screen offers to let me enter a key":
            let drawn = try drawnScreen()
            guard drawn.actions.contains(PocketSessionKeyEntryPresentation.entryAction) else {
                throw BrineStepError(
                    "the screen offers \(drawn.actions) — none of which reaches the key field. "
                        + "That field was reachable only from the state that means \"Solleva "
                        + "holds no key\", which is precisely the state a recorder with a bad "
                        + "key stored for it can never produce")
            }

        case "it offers to try the recorder again":
            let drawn = try drawnScreen()
            guard drawn.actions.contains(PocketSetupPresentation.retryAction) else {
                throw BrineStepError("the screen offers \(drawn.actions), with no way to ask "
                                        + "the recorder again")
            }

        // THE KEY IS KEPT, and that is a decision rather than an omission — see the note on
        // `PocketSetupPresentation.handshakeUnanswered`.
        case "the key Solleva holds is still in secure custody":
            guard await heldKey() == Self.staleKey else {
                throw BrineStepError(
                    "the key Solleva was holding is gone after one silent recorder. Silence is "
                        + "not evidence the key is wrong, and this firmware cannot be asked for "
                        + "it back")
            }

        case "Solleva sent that recorder exactly one key":
            let keyWrites = stack.commandsWritten.filter { $0.hasPrefix("SK&") }
            guard keyWrites.count == 1 else {
                throw BrineStepError("one tap wrote \(keyWrites.count) keys to the recorder")
            }
            guard keyWrites == ["SK&\(Self.staleKey)"] else {
                throw BrineStepError("the tap sent something other than the key in custody")
            }

        case "Solleva is showing me the key field":
            guard model.ceremonyScreen == .enterExistingKey else {
                throw BrineStepError(
                    "choosing \"\(PocketSessionKeyEntryPresentation.entryAction)\" left the app "
                        + "on \(model.ceremonyScreen), not on the field")
            }
            guard model.showingCeremony else {
                throw BrineStepError("the ceremony was dismissed instead of showing the field")
            }

        case "the recorder is adopted through the shipped chain":
            guard adopted, !model.showingCeremony else {
                throw BrineStepError(
                    "the key the recorder actually answers did not adopt it. The app said: "
                        + "\"\(model.keyEntryMessage ?? "(nothing)")\"")
            }
            let remembered = (try? RecordingDeviceStore.current()?.records()) ?? []
            guard remembered.contains(where: {
                $0.identity.hardwareToken == self.identifier.uuidString.lowercased()
            }) else {
                throw BrineStepError(
                    "the account does not remember the recorder — it holds "
                        + "\(remembered.count) device(s)")
            }

        // THE REPLACEMENT IS THE ESCAPE. `PocketSecretStore.save` overwrites, so entering a key
        // is how an owner gets an unusable one out of custody without a button that can brick a
        // recorder Solleva itself provisioned.
        case "the key Solleva now holds is the one the recorder answered":
            let held = await heldKey()
            guard held == Self.realKey else {
                throw BrineStepError(
                    "custody holds \(held == Self.staleKey ? "the old key" : "no key of this recorder's"), "
                        + "so the next launch restores the key that goes unanswered")
            }

        case "Solleva is still on the screen that offers to let me enter a key":
            guard model.showingCeremony else {
                throw BrineStepError(
                    "\"\(PocketSetupPresentation.retryAction)\" dismissed the sheet. A retry "
                        + "that quietly closes the one screen with a way out is the deadlock "
                        + "with an extra step")
            }
            let drawn = try drawnScreen()
            guard drawn.actions.contains(PocketSessionKeyEntryPresentation.entryAction) else {
                throw BrineStepError(
                    "a retry that failed the same way landed on \(model.ceremonyScreen), whose "
                        + "actions are \(drawn.actions) — the way to the key field is gone")
            }

        case "Solleva sent that recorder one key per attempt and no more":
            let keyWrites = stack.commandsWritten.filter { $0.hasPrefix("SK&") }
            guard keyWrites.count == 2 else {
                throw BrineStepError(
                    "a tap and a retry wrote \(keyWrites.count) keys, not two. A second key "
                        + "write against a keyed recorder may silently re-key it")
            }
            guard Set(keyWrites) == ["SK&\(Self.staleKey)"] else {
                throw BrineStepError("a retry sent a key that was not the one in custody")
            }

        // THE SHIPPED SECURITY PROPERTY, HELD OVER THE POPULATION THIS SCREEN JOINED. The owner
        // asked to be shown the key; the answer is that he can replace it, not read it.
        case "no setup screen offers to reveal, copy, share, or export a key":
            let ceremony = PocketSetupPresentation.all
                .flatMap { [$0.title, $0.body] + $0.actions }.joined(separator: " ").lowercased()
            for word in ["reveal", "copy", "share", "export"] {
                guard !ceremony.contains(word) else {
                    throw BrineStepError("a setup screen offers to \(word) a credential")
                }
            }

        case "the key Solleva holds appears in no line the setup screens can display":
            let everything = (PocketSetupPresentation.all
                .flatMap { [$0.title, $0.body] + $0.actions }
                + PocketSessionKeyEntryPresentation.everyLine
                + [model.keyEntryMessage ?? "", model.inlineMessage ?? ""])
                .joined(separator: "\n")
            for key in [Self.staleKey, Self.realKey] {
                guard !everything.contains(key) else {
                    throw BrineStepError("a rendered line carries the session key")
                }
            }

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    // MARK: What the app produced

    /// THE VIEW'S ACTION CLOSURE, VERBATIM. `App/DeviceScreen.swift` calls `ceremonyAction` and
    /// dismisses on `.closeTheSheet`; a scenario that called the model and ignored the answer
    /// would report a button that silently closes the sheet as one that worked.
    private func tapCeremonyButton(_ title: String) {
        if model.ceremonyAction(title) == .closeTheSheet {
            model.dismissCeremony()
        }
    }

    /// THE COPY THE VIEW WOULD DRAW FOR THE STATE THE MODEL SET — asked of
    /// `PocketOnboardingView`'s own map rather than of a constant this test picked. A model that
    /// lands on a screen the view renders as `.setup` is a dead end with a friendly title, and
    /// this is the only place that difference is visible from outside a `body`.
    private func drawnScreen() throws -> PocketSetupPresentation {
        guard model.showingCeremony else {
            throw BrineStepError("no ceremony screen is up, so there is nothing to read")
        }
        return PocketOnboardingView(screen: model.ceremonyScreen, action: { _ in }).presentation
    }

    private func heldKey() async -> String? {
        guard let identity = try? PocketAuthenticatedIdentity(
            peripheralIdentifier: identifier.uuidString) else { return nil }
        return await secrets.secret(for: identity)
    }
}
