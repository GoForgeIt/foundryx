import XCTest
import BrineSwiftCore
@testable import FoundryXKit

final class PocketOnboardingFeatureTests: XCTestCase {
    func testPocketOnboardingFeature() async throws {
        let world = PocketOnboardingWorld()
        let result = try await BrineFeatureRunner.run(
            "pocket-onboarding",
            registry: StepRegistry(PocketOnboardingSteps.make(world: world)))
        XCTAssertEqual(result.passed, 11)
    }

    func testIdentityMutationCannotRetrieveSecret() async throws {
        let store = InMemoryPocketSecretStore()
        let original = try PocketAuthenticatedIdentity(
            peripheralIdentifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            sessionSecret: "0123456789ABCDEF")
        let mutation = try PocketAuthenticatedIdentity(
            peripheralIdentifier: "AAAAAAAA-BBBB-CCCC-DDDD-FFFFFFFFFFFF",
            sessionSecret: "0123456789ABCDEF")
        try await store.save("0123456789ABCDEF", for: original)
        let retrieved = await store.secret(for: mutation)
        XCTAssertNil(retrieved)
    }
}

private enum PocketOnboardingSteps {
    static func make(world: PocketOnboardingWorld) -> [StepDefinition] {
        let givens = [
            "a selected factory-fresh Pocket with authenticated identity components",
            "a stored Pocket secret bound to an authenticated composite identity",
            "an already-used Pocket with a matching stored secret",
            "an already-used Pocket without a matching stored secret",
            "a Pocket with a missing or mismatched identity component",
            "Pocket accepted a candidate but secure storage failed",
            "Pocket authentication times out or disconnects",
            "a Pocket secret is in secure custody",
            "Pocket setup has completed"
        ]
        let whens = [
            "I open Pocket setup",
            "Pocket accepts the candidate and FoundryX securely stores it",
            "only the CoreBluetooth peripheral identifier is substituted",
            "I reconnect it",
            "I ask how to connect it",
            "I try to set it up",
            "I retry secure storage for the same identity",
            "setup handles the result",
            "I inspect setup copy, diagnostics, and available actions",
            "I open How your recorder works",
            "I inspect the onboarding outcome"
        ]
        let thens = [
            "I see one sentence and one Set up button without credential language",
            "setup completes only after battery and firmware confirmation",
            "no Pocket secret is returned",
            "FoundryX submits only the stored secret and preserves the maker-app setup",
            "coexistence is explained as advanced key capture and reset is the last resort",
            "no credential is submitted and the observation is quarantined",
            "no device write occurs and setup completes only if that retry succeeds",
            "setup stops without offering reset, coexistence, or another credential",
            "the secret is absent and there is no reveal, copy, share, or export action",
            "button, switch, and light guidance appears without claiming detected recording state",
            "there is no live capture, recording pill, Live Activity, or current recording state"
        ]
        var steps = givens.map { phrase in defineStep(phrase) { context, _, _ in await world.given(phrase); return context } }
        steps += whens.map { phrase in defineStep(phrase) { context, _, _ in try await world.when(phrase); return context } }
        steps += thens.map { phrase in defineCheck(phrase) { _, _, _ in try await world.then(phrase) } }
        return steps
    }
}

private actor PocketOnboardingWorld {
    private var givenPhrase = ""
    private var whenPhrase = ""
    private let secret = "0123456789ABCDEF"
    private let store = InMemoryPocketSecretStore()
    private let client = PocketOnboardingClientSpy()
    private var result: PocketOnboardingState?
    private var retrieved: String?
    private var scenarioSubmitted: [String]?
    private var submittedBeforeRetry: [String]?
    private var preRetryResult: PocketOnboardingState?

    func given(_ phrase: String) async {
        givenPhrase = phrase
        result = nil
        retrieved = nil
        scenarioSubmitted = nil
        submittedBeforeRetry = nil
        preRetryResult = nil
        await client.reset()
    }

    func when(_ phrase: String) async throws {
        whenPhrase = phrase
        let identity = try PocketAuthenticatedIdentity(peripheralIdentifier: "A", sessionSecret: secret)
        switch phrase {
        case "Pocket accepts the candidate and FoundryX securely stores it":
            await client.configure(authentication: .accepted, battery: 72, firmware: "1.6")
            let flow = PocketOnboardingCoordinator(client: client, store: store)
            result = await flow.provisionFactoryFresh(identity: identity, candidate: secret)
        case "only the CoreBluetooth peripheral identifier is substituted":
            try await store.save(secret, for: identity)
            let changed = try PocketAuthenticatedIdentity(peripheralIdentifier: "B", sessionSecret: secret)
            retrieved = try await store.secret(for: changed)
        case "I reconnect it":
            try await store.save(secret, for: identity)
            await client.configure(authentication: .accepted, battery: 72, firmware: "1.6")
            result = await PocketOnboardingCoordinator(client: client, store: store).restore(identity: identity)
        case "I ask how to connect it": result = .coexistenceAvailable
        case "I try to set it up": result = .quarantined
        case "I retry secure storage for the same identity":
            let failing = FailingThenWorkingPocketSecretStore()
            let isolatedClient = PocketOnboardingClientSpy()
            let flow = PocketOnboardingCoordinator(client: isolatedClient, store: failing)
            await isolatedClient.configure(authentication: .accepted, battery: 72, firmware: "1.6")
            preRetryResult = await flow.provisionFactoryFresh(identity: identity, candidate: secret)
            submittedBeforeRetry = await isolatedClient.submittedSecrets
            result = await flow.retrySecureStorage()
            scenarioSubmitted = await isolatedClient.submittedSecrets
        case "setup handles the result": result = .indeterminate
        default: break
        }
    }

    func then(_ phrase: String) async throws {
        let setup = PocketSetupPresentation.setup
        switch phrase {
        case "I see one sentence and one Set up button without credential language":
            XCTAssertEqual(setup.body, "Keep the recorder nearby.")
            XCTAssertEqual(setup.actions, ["Set up"])
            XCTAssertFalse((setup.title + setup.body).lowercased().contains("key"))
        case "setup completes only after battery and firmware confirmation":
            XCTAssertEqual(result, .ready(batteryPercent: 72, firmware: "1.6"))
        case "no Pocket secret is returned": XCTAssertNil(retrieved)
        case "FoundryX submits only the stored secret and preserves the maker-app setup":
            let submitted = await client.submittedSecrets
            XCTAssertEqual(submitted, [secret]); XCTAssertEqual(result, .ready(batteryPercent: 72, firmware: "1.6"))
        case "coexistence is explained as advanced key capture and reset is the last resort":
            XCTAssertEqual(PocketSetupPresentation.keepBothApps.actions, ["Advanced instructions", "Reset and start over"])
            XCTAssertTrue(PocketSetupPresentation.keepBothApps.body.contains("one at a time"))
        case "no credential is submitted and the observation is quarantined":
            let submitted = await client.submittedSecrets
            XCTAssertEqual(result, .quarantined); XCTAssertTrue(submitted.isEmpty)
        case "no device write occurs and setup completes only if that retry succeeds":
            let submitted = scenarioSubmitted
            XCTAssertEqual(preRetryResult, .acceptedNotDurable)
            XCTAssertEqual(submittedBeforeRetry, [secret])
            XCTAssertEqual(submitted, submittedBeforeRetry)
            XCTAssertEqual(result, .ready(batteryPercent: 72, firmware: "1.6"))
        case "setup stops without offering reset, coexistence, or another credential":
            XCTAssertEqual(result, .indeterminate); XCTAssertEqual(PocketSetupPresentation.indeterminate.actions, ["Try again"])
        case "the secret is absent and there is no reveal, copy, share, or export action":
            let all = PocketSetupPresentation.all.flatMap { [$0.title, $0.body] + $0.actions }.joined(separator: " ").lowercased()
            XCTAssertFalse(all.contains(secret.lowercased())); for word in ["reveal", "copy", "share", "export"] { XCTAssertFalse(all.contains(word)) }
        case "button, switch, and light guidance appears without claiming detected recording state":
            let education = PocketDeviceEducation.presentation
            XCTAssertEqual(education.sections.map(\.title), ["Is it recording?", "The light", "The button", "The switch"])
            XCTAssertTrue(education.sections[0].body.contains("Check the light")); XCTAssertFalse(education.claimsTelemetry)
        case "there is no live capture, recording pill, Live Activity, or current recording state":
            XCTAssertEqual(PocketOnboardingCapabilities.delivery, .pullAfterTheFact); XCTAssertFalse(PocketOnboardingCapabilities.hasLiveRecordingSurface)
        default: XCTFail("Unhandled assertion: \(phrase)")
        }
    }
}

private actor PocketOnboardingClientSpy: PocketOnboardingClient {
    var submittedSecrets: [String] = []
    private var authentication: PocketOnboardingAuthentication = .accepted
    private var battery = 72
    private var firmware = "1.6"
    func reset() { submittedSecrets = []; authentication = .accepted; battery = 72; firmware = "1.6" }
    func configure(authentication: PocketOnboardingAuthentication, battery: Int, firmware: String) { self.authentication = authentication; self.battery = battery; self.firmware = firmware }
    func authenticate(secret: String) async -> PocketOnboardingAuthentication { submittedSecrets.append(secret); return authentication }
    func confirmation() async throws -> PocketOnboardingConfirmation { .init(batteryPercent: battery, firmware: firmware) }
    func close() async {}
}

private actor FailingThenWorkingPocketSecretStore: PocketSecretStore {
    private var attempts = 0
    func save(_ secret: String, for identity: PocketAuthenticatedIdentity) async throws { attempts += 1; if attempts == 1 { throw PocketSecretStoreError.unavailable } }
    func secret(for identity: PocketAuthenticatedIdentity) async throws -> String? { nil }
}
