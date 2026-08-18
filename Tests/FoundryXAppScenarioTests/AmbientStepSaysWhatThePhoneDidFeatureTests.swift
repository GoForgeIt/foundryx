import XCTest
import Foundation
import UserNotifications
import BrineSwiftCore
@testable import FoundryX

/// THE AMBIENT STEP, DRIVEN INSIDE THE SHIPPING APP, AGAINST A SCRIPTED PHONE.
///
/// WHAT THIS HOLDS THAT NOTHING ELSE COULD. `AmbientNotifier` lives in `App/`, which
/// `Tests/FoundryXBrineTests` cannot compile — so every guard over the sample-nudge path was
/// a `contains()` over its source. Three one-line mutations to the shipped fix passed
/// 1536/1536 as a result:
///
///   * `guard let binding = CaptureAccountScope.currentAccountBinding() else { return }` put
///     back at the top of `postPreview` — the original FX-4(a) defect, where the step
///     announced "We just sent a sample nudge" over a function that had sent nothing.
///     KILLED HERE by counting what reached the phone: with that guard back, zero
///     notifications are handed over and "exactly one notification was handed to my phone"
///     goes red.
///   * the permission-denied arm changed from `report?(.refused)` to `report?(.scheduled)`,
///     telling a user who had just tapped "Don't Allow" to check their lock screen. KILLED
///     HERE by scripting a refusal and asking the step what it says.
///   * a silent `guard let … else { return }` inserted into `deliver`. KILLED HERE because
///     a swallowed path reports nothing, and a step that hears nothing back settles on
///     "the sample did not go out" rather than on a claim — and never stays on "checking".
///
/// The scripted centre is the whole seam: it is what `AmbientNotifier.centre` returns while
/// `notificationCentreForScenarios` is set, and it records what it was asked for. It is
/// `#if DEBUG`, so `scripts/ci-gates.sh phase_leak` compiles it out of Release.
final class AmbientStepSaysWhatThePhoneDidFeatureTests: XCTestCase {

    override func tearDown() async throws {
        AmbientNotifier.notificationCentreForScenarios = nil
        try await super.tearDown()
    }

    func testTheAmbientStepSaysWhatThePhoneDid() async throws {
        let world = try await AmbientStepWorld()
        defer { world.cleanup() }
        let result = try await BrineFeatureRunner.run(
            "the-ambient-step-says-what-the-phone-did",
            registry: StepRegistry(AmbientStepSteps.make(world)))
        // THE POPULATION IS PINNED. A runner that only asserts "nothing failed" is green the
        // moment the scenarios stop existing.
        XCTAssertEqual(result.passed, 7, "all seven scenarios must run and pass")
    }
}

// MARK: - The scripted phone

/// What the scripted centre was told to be.
enum ScriptedPhone: Sendable {
    /// Nobody has asked yet; the user then grants (or not), and iOS accepts the request.
    case notAsked(grants: Bool)
    /// Already authorized, and iOS accepts.
    case allows
    /// Already authorized, but iOS rejects the request itself.
    case allowsButRejectsTheRequest
    /// Already denied. Asking again is not permitted.
    case alreadyRefused
    /// Reads the settings and never calls back — a hung centre, which is exactly what a
    /// swallowed early return looks like from the step's side.
    case neverAnswers
}

/// A stand-in for `UNUserNotificationCenter` that RECORDS. Every count below is a fact about
/// what the application did, not about how its source is spelled.
///
/// `Sendable` and lock-guarded because the notifier's completions are `@Sendable` and may
/// arrive on any queue — which is the very reason the real centre cannot be substituted
/// without a seam.
final class ScriptedNotificationCentre: AmbientNotificationCentre, @unchecked Sendable {
    private let lock = NSLock()
    private let phone: ScriptedPhone

    private var _permissionReads = 0
    private var _asks = 0
    private var _handed: [UNNotificationRequest] = []
    private var _withdrawn: [String] = []
    private var _surfaceInstalls = 0
    private var _installedCategories: Set<UNNotificationCategory> = []

    init(_ phone: ScriptedPhone) { self.phone = phone }

    var permissionReads: Int { lock.withLock { _permissionReads } }
    var asks: Int { lock.withLock { _asks } }
    var handed: [UNNotificationRequest] { lock.withLock { _handed } }
    var withdrawn: [String] { lock.withLock { _withdrawn } }
    var surfaceInstalls: Int { lock.withLock { _surfaceInstalls } }
    var installedCategories: Set<UNNotificationCategory> { lock.withLock { _installedCategories } }

    func installSurface(delegate: UNUserNotificationCenterDelegate,
                        categories: Set<UNNotificationCategory>) {
        lock.withLock {
            _surfaceInstalls += 1
            _installedCategories = categories
        }
    }

    func permission(_ completion: @escaping @Sendable (AmbientNudgePermission) -> Void) {
        lock.withLock { _permissionReads += 1 }
        switch phone {
        case .notAsked:                   completion(.notDetermined)
        case .allows:                     completion(.authorized)
        case .allowsButRejectsTheRequest: completion(.authorized)
        case .alreadyRefused:             completion(.denied)
        case .neverAnswers:               break   // the hung phone: no callback, ever
        }
    }

    func ask(_ completion: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { _asks += 1 }
        switch phone {
        case .notAsked(let grants): completion(grants)
        case .neverAnswers:         break
        default:                    completion(true)
        }
    }

    func hand(_ request: UNNotificationRequest,
              _ completion: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { _handed.append(request) }
        switch phone {
        case .allowsButRejectsTheRequest: completion(false)
        case .neverAnswers:               break
        default:                          completion(true)
        }
    }

    func withdraw(identifiers: [String]) {
        lock.withLock { _withdrawn.append(contentsOf: identifiers) }
    }

    func withdrawEverything() {
        lock.withLock { _handed.removeAll() }
    }
}

// MARK: - Steps

private enum AmbientStepSteps {
    static func make(_ world: AmbientStepWorld) -> [StepDefinition] {
        let givens = [
            "a phone that has not been asked about notifications",
            "a phone that will refuse notification permission",
            "a phone that has already refused notifications",
            "a phone that allows notifications but rejects the request",
            "a phone that never answers",
            "there is no account yet, because this is onboarding",
            "my phone cannot resolve an account scope at all",
        ]
        let whens = [
            "I turn ambient intelligence on",
            "I turn ambient intelligence on and wait for the step to give up",
            "the app sets up its notifications the way launch does",
        ]
        let thens = [
            "my phone was asked for notification permission exactly once",
            "my phone was not asked for notification permission again",
            "my phone was not asked for notification permission at all",
            "exactly one notification was handed to my phone",
            "nothing was handed to my phone",
            "the step tells me a sample nudge was sent",
            "the step does not claim a sample nudge was sent",
            "the step tells me how to turn notifications on",
            "the step is no longer telling me it is checking",
            "ambient intelligence is still on",
            "the banner can be shown while the app is open",
        ]
        var steps = givens.map { phrase in
            defineStep(phrase) { ctx, _, _ in try await world.given(phrase); return ctx }
        }
        steps += whens.map { phrase in
            defineStep(phrase) { ctx, _, _ in try await world.when(phrase); return ctx }
        }
        steps += thens.map { phrase in
            defineCheck(phrase) { _, _, _ in try await world.then(phrase) }
        }
        return steps
    }
}

// MARK: - The world one scenario stages

/// `@MainActor` because `AmbientSampleNudge` is — it is the app's own step model, the one
/// `App/OnboardingFlowView.swift` creates with `@StateObject`.
@MainActor
private final class AmbientStepWorld {
    private var centre: ScriptedNotificationCentre?
    /// Under half a second of patience, so "my phone never answers" is a scenario rather
    /// than a coffee break. A constructor argument on the real model, not a hidden knob.
    private let nudge = AmbientSampleNudge(patience: 0.4)

    // ---- THE ONBOARDING WORLD: a fresh container, an isolated defaults suite, signed out.
    // Same staging `EveryStateHasAWayOutFeatureTests` uses. It matters here more than
    // anywhere: the defect this feature exists for is what the sample nudge does WITH NO
    // ACCOUNT, and the scenario host carries whatever account state the suites before it
    // left behind.
    private nonisolated let token = UUID().uuidString
    private nonisolated let sandbox: URL
    private nonisolated let scopeDefaultsName: String
    /// `UserDefaults` is not `Sendable` and this one is reachable from `cleanup()`.
    /// Written once in `init`, read once in teardown.
    private nonisolated(unsafe) let scopeDefaults: UserDefaults

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-ambient-step-\(token)", isDirectory: true)
        scopeDefaultsName = "foundryx.ambient-step.scope.\(token)"
        guard let defaults = UserDefaults(suiteName: scopeDefaultsName) else {
            throw BrineStepError("could not create an isolated UserDefaults suite")
        }
        scopeDefaults = defaults
        try stageSignedOutPhone()
    }

    /// A fresh container, an isolated defaults suite, signed out. Re-run per scenario,
    /// because the unbound scenario deliberately points the container somewhere
    /// unresolvable and a world that did not put it back would poison whatever ran next.
    private nonisolated func stageSignedOutPhone() throws {
        let container = sandbox.appendingPathComponent("documents/foundryx-captures",
                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        CaptureAccountScope.setContainerForTests(container)
        CaptureAccountScope.setApplicationSupportRootForTests(
            sandbox.appendingPathComponent("application-support", isDirectory: true))
        CaptureAccountScope.setDefaultsForTests(scopeDefaults)
        try? CaptureAccountScope.signOutForTests()
    }

    nonisolated func cleanup() {
        AmbientNotifier.notificationCentreForScenarios = nil
        try? CaptureAccountScope.signOutForTests()
        CaptureAccountScope.resetTestEnvironment()
        scopeDefaults.removePersistentDomain(forName: scopeDefaultsName)
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func phone() throws -> ScriptedNotificationCentre {
        guard let centre else { throw BrineStepError("no scripted phone was staged") }
        return centre
    }

    func given(_ phrase: String) throws {
        switch phrase {
        case "a phone that has not been asked about notifications":
            stage(.notAsked(grants: true))
        case "a phone that will refuse notification permission":
            stage(.notAsked(grants: false))
        case "a phone that has already refused notifications":
            stage(.alreadyRefused)
        case "a phone that allows notifications but rejects the request":
            stage(.allowsButRejectsTheRequest)
        case "a phone that never answers":
            stage(.neverAnswers)
        case "there is no account yet, because this is onboarding":
            // MEASURED, NOT ASSUMED. A signed-out phone with a fresh container still
            // resolves the local scope `acct-none`, so "onboarding" is a BOUND state — the
            // feature says so rather than letting a reader believe otherwise.
            try stageSignedOutPhone()
            let bound = CaptureAccountScope.currentAccountBinding()
            guard bound?.scope == "acct-none" else {
                throw BrineStepError(
                    "a signed-out phone resolves “\(bound?.scope ?? "no scope at all")”, not " +
                    "the local `acct-none` this feature stages onboarding as")
            }
        case "my phone cannot resolve an account scope at all":
            // THE UNBOUND STATE, WHICH IS WHAT THE SAMPLE NUDGE MUST SURVIVE. An
            // unresolvable durable container is how `currentAccountBinding()` actually
            // returns nil, and it is the state in which the FX-4(a) guard —
            // `guard let binding = CaptureAccountScope.currentAccountBinding() else
            // { return }` at the top of `postPreview` — swallowed the sample while the step
            // announced a send. Asserted, because a staging that quietly failed to produce
            // it would make the scenario green about nothing.
            CaptureAccountScope.setContainerForTests(
                URL(fileURLWithPath: "/dev/null/foundryx-no-container-\(token)"))
            let unresolvable = CaptureAccountScope.currentAccountBinding()
            guard unresolvable == nil else {
                throw BrineStepError(
                    "the scope “\(unresolvable?.scope ?? "?")” is still bound, so this " +
                    "scenario cannot measure the unbound sample it exists for")
            }
        default:
            throw BrineStepError("unknown given: \(phrase)")
        }
    }

    private func stage(_ phone: ScriptedPhone) {
        let scripted = ScriptedNotificationCentre(phone)
        centre = scripted
        AmbientNotifier.notificationCentreForScenarios = scripted
    }

    func when(_ phrase: String) async throws {
        switch phrase {
        case "I turn ambient intelligence on":
            nudge.turnOn()
            let phone = try phone()
            try await AppScenarioHost.settle(
                untilTrue: { self.nudge.attempt != .pending },
                timeout: 5,
                describing: "the step to hear back from the phone (permission reads " +
                    "\(phone.permissionReads), asks \(phone.asks), handed \(phone.handed.count))")
        case "I turn ambient intelligence on and wait for the step to give up":
            nudge.turnOn()
            try await AppScenarioHost.settle(
                untilTrue: { self.nudge.attempt != .pending },
                timeout: 5,
                describing: "the step to stop saying it is checking after a phone that " +
                    "never answers — it has no timeout and sits on `.pending` forever")
        case "the app sets up its notifications the way launch does":
            // THE LAUNCH PATH ITSELF. `App/RootView.swift` calls exactly this, and it used
            // to call `requestAuthorizationIfNeeded()`, which raised the OS prompt
            // anonymously before onboarding — which RootView hosts — had said a word.
            AmbientNotifier.installNotificationSurface()
        default:
            throw BrineStepError("unknown when: \(phrase)")
        }
    }

    func then(_ phrase: String) throws {
        let phone = try phone()
        let said = nudge.said
        switch phrase {
        case "my phone was asked for notification permission exactly once":
            guard phone.asks == 1 else {
                throw BrineStepError("the phone was asked \(phone.asks) time(s), not once")
            }
        case "my phone was not asked for notification permission again":
            guard phone.asks == 0 else {
                throw BrineStepError(
                    "a phone that has already said no was asked \(phone.asks) more time(s)")
            }
        case "my phone was not asked for notification permission at all":
            guard phone.asks == 0, phone.permissionReads == 0 else {
                throw BrineStepError(
                    "launch raised the notification prompt: \(phone.asks) ask(s), " +
                    "\(phone.permissionReads) settings read(s). A prompt nobody promised is a " +
                    "prompt nobody can report the answer of")
            }
        case "exactly one notification was handed to my phone":
            guard phone.handed.count == 1 else {
                throw BrineStepError(
                    "\(phone.handed.count) notification(s) reached the phone, not one — the " +
                    "step promises a sample and the phone was handed nothing")
            }
        case "nothing was handed to my phone":
            guard phone.handed.isEmpty else {
                throw BrineStepError(
                    "\(phone.handed.count) notification(s) went out anyway")
            }
        case "the step tells me a sample nudge was sent":
            guard nudge.attempt == .scheduled, said.claimsNudgeSent,
                  OnboardingAmbientStepCopy.assertsANudgeWasSent(said.spokenText) else {
                throw BrineStepError(
                    "a nudge WAS accepted by the phone but the step settled on " +
                    "\(nudge.attempt.rawValue) and says: “\(said.spokenText)”")
            }
        case "the step does not claim a sample nudge was sent":
            guard !said.claimsNudgeSent,
                  !OnboardingAmbientStepCopy.assertsANudgeWasSent(said.spokenText) else {
                throw BrineStepError(
                    "\(nudge.attempt.rawValue): the step claims a send that never happened: " +
                    "“\(said.spokenText)”")
            }
        case "the step tells me how to turn notifications on":
            guard nudge.attempt == .refused, said.pointsToSystemSettings,
                  said.detail.lowercased().contains("settings") else {
                throw BrineStepError(
                    "I refused the prompt and the step settled on \(nudge.attempt.rawValue) " +
                    "saying “\(said.detail)” — a refusal is the one failure I can fix, so it " +
                    "has to say where")
            }
        case "the step is no longer telling me it is checking":
            guard nudge.attempt != .pending else {
                throw BrineStepError(
                    "the step is still on `.pending` — “\(said.detail)” — after a phone that " +
                    "never answered, so the promise sits unresolved forever")
            }
        case "ambient intelligence is still on":
            guard AmbientPrefs.enabled() else {
                throw BrineStepError("a failed sample nudge turned ambient intelligence off")
            }
            guard said.headline.hasPrefix("On") else {
                throw BrineStepError(
                    "the step reads as if the whole feature failed: “\(said.headline)”")
            }
        case "the banner can be shown while the app is open":
            guard phone.surfaceInstalls == 1 else {
                throw BrineStepError(
                    "launch installed the foreground presenter \(phone.surfaceInstalls) " +
                    "time(s) — without it iOS silently swallows the banner while the app is " +
                    "in the user's hand, which is exactly the situation during onboarding")
            }
            guard phone.installedCategories.contains(where: {
                $0.identifier == AmbientNotifier.cardCategory
            }) else {
                throw BrineStepError(
                    "the confirm-card actions were never registered, so Run/Dismiss on a " +
                    "real nudge do nothing")
            }
        default:
            throw BrineStepError("unknown then: \(phrase)")
        }
    }
}
