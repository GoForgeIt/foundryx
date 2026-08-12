import XCTest
import BrineSwiftCore
@testable import FoundryXKit

final class PocketOnboardingFeatureTests: XCTestCase {
    func testPocketOnboardingFeature() async throws {
        let world = PocketOnboardingWorld()
        let result = try await BrineFeatureRunner.run(
            "pocket-onboarding",
            registry: StepRegistry(PocketOnboardingSteps.make(world: world)))
        XCTAssertEqual(result.passed, 12)
    }

    func testIdentityMutationCannotRetrieveSecret() async throws {
        let store = InMemoryPocketSecretStore()
        let original = try PocketAuthenticatedIdentity(
            peripheralIdentifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        let mutation = try PocketAuthenticatedIdentity(
            peripheralIdentifier: "AAAAAAAA-BBBB-CCCC-DDDD-FFFFFFFFFFFF")
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
            "only a stored Pocket custody record remains after launch",
            "an already-used Pocket with a matching stored secret",
            "an already-used Pocket without a matching stored secret",
            "a Pocket with a missing or mismatched identity component",
            "secure storage that refuses the first attempt",
            "Pocket authentication times out or disconnects",
            "a Pocket secret is in secure custody",
            "Pocket setup has completed"
        ]
        let whens = [
            "I open Pocket setup",
            "Pocket accepts the candidate and FoundryX securely stores it",
            "only the CoreBluetooth peripheral identifier is substituted",
            "the Pocket reconnects with its transport identity",
            "I reconnect it",
            "I ask how to connect it",
            "I try to set it up",
            "I set the Pocket up and then try again",
            "setup handles the result",
            "I inspect setup copy, diagnostics, and available actions",
            "I open How your recorder works",
            "I inspect the onboarding outcome"
        ]
        let thens = [
            "I see one sentence and one Set up button without credential language",
            "setup completes only after battery and firmware confirmation",
            "no Pocket secret is returned",
            "the stored Pocket secret is retrieved without already possessing it",
            "FoundryX submits only the stored secret and preserves the maker-app setup",
            "coexistence is explained as advanced key capture and reset is the last resort",
            "no credential is submitted and the observation is quarantined",
            "nothing reached the device until custody held the key, and setup completes only then",
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
        let identity = try PocketAuthenticatedIdentity(peripheralIdentifier: "A")
        switch phrase {
        case "Pocket accepts the candidate and FoundryX securely stores it":
            await client.configure(authentication: .accepted, battery: 72, firmware: "1.6")
            let flow = PocketOnboardingCoordinator(client: client, store: store)
            result = await flow.provisionFactoryFresh(identity: identity, candidate: secret,
                                                     consent: .ownerConfirmedAfterReadingTheConsequences())
        case "only the CoreBluetooth peripheral identifier is substituted":
            try await store.save(secret, for: identity)
            let changed = try PocketAuthenticatedIdentity(peripheralIdentifier: "B")
            retrieved = await store.secret(for: changed)
        case "the Pocket reconnects with its transport identity":
            try await store.save(secret, for: identity)
            let coldLaunchIdentity = try PocketAuthenticatedIdentity(peripheralIdentifier: "A")
            retrieved = await store.secret(for: coldLaunchIdentity)
        case "I reconnect it":
            try await store.save(secret, for: identity)
            await client.configure(authentication: .accepted, battery: 72, firmware: "1.6")
            result = await PocketOnboardingCoordinator(client: client, store: store).restore(identity: identity)
        case "I ask how to connect it":
            result = await PocketOnboardingCoordinator(client: client, store: store).restore(identity: identity)
        case "I try to set it up":
            result = await PocketOnboardingCoordinator(client: client, store: store)
                .provisionFactoryFresh(identity: nil, candidate: secret,
                                       consent: .ownerConfirmedAfterReadingTheConsequences())
        case "I set the Pocket up and then try again":
            // CUSTODY RUNS BEFORE THE RADIO, so a first attempt whose Keychain write fails
            // sends the recorder nothing at all and the "retry" is simply the same mint again.
            // The old order wrote the key to the device first and then discovered it could not
            // store it, which is a recorder holding a credential nothing in the world has.
            let failing = FailingThenWorkingPocketSecretStore()
            let isolatedClient = PocketOnboardingClientSpy()
            let flow = PocketOnboardingCoordinator(client: isolatedClient, store: failing)
            await isolatedClient.configure(authentication: .accepted, battery: 72, firmware: "1.6")
            preRetryResult = await flow.provisionFactoryFresh(
                identity: identity, candidate: secret,
                consent: .ownerConfirmedAfterReadingTheConsequences())
            submittedBeforeRetry = await isolatedClient.submittedSecrets
            result = await PocketOnboardingCoordinator(client: isolatedClient, store: failing)
                .provisionFactoryFresh(identity: identity, candidate: secret,
                                       consent: .ownerConfirmedAfterReadingTheConsequences())
            scenarioSubmitted = await isolatedClient.submittedSecrets
        case "setup handles the result":
            await client.configure(authentication: .indeterminate, battery: 72, firmware: "1.6")
            result = await PocketOnboardingCoordinator(client: client, store: store)
                .provisionFactoryFresh(identity: identity, candidate: secret,
                                       consent: .ownerConfirmedAfterReadingTheConsequences())
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
        case "the stored Pocket secret is retrieved without already possessing it": XCTAssertEqual(retrieved, secret)
        case "FoundryX submits only the stored secret and preserves the maker-app setup":
            let submitted = await client.submittedSecrets
            XCTAssertEqual(submitted, [secret]); XCTAssertEqual(result, .ready(batteryPercent: 72, firmware: "1.6"))
        case "coexistence is explained as advanced key capture and reset is the last resort":
            XCTAssertEqual(PocketSetupPresentation.keepBothApps.actions, ["Advanced instructions", "Reset and start over"])
            XCTAssertTrue(PocketSetupPresentation.keepBothApps.body.contains("one at a time"))
        case "no credential is submitted and the observation is quarantined":
            let submitted = await client.submittedSecrets
            XCTAssertEqual(result, .quarantined); XCTAssertTrue(submitted.isEmpty)
        case "nothing reached the device until custody held the key, and setup completes only then":
            XCTAssertEqual(preRetryResult, .keyNotKept,
                           "a candidate the Keychain refused produced "
                               + String(describing: preRetryResult))
            XCTAssertEqual(submittedBeforeRetry, [],
                           "a key this iPhone could not store still reached the recorder. This "
                               + "firmware has no reset and no key-read opcode, so that is a "
                               + "recorder nothing can ever connect to again")
            XCTAssertEqual(scenarioSubmitted, [secret],
                           "the second attempt sent something other than exactly one key")
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

/// THE SPY NOW MODELS WHAT THE RECORDER IS HOLDING, not just what it answered.
///
/// A mint is no longer believed on a bare `MCU&SK&OK` — the coordinator reads the recorder's
/// own access-point credentials back and requires the reported password to be the first eight
/// characters of the key it just sent. A spy that answered that read-back from a canned string
/// would make the proof unfalsifiable, so this one derives it from `heldSecret`, which moves
/// only when the modelled firmware actually takes a key.
private actor PocketOnboardingClientSpy: PocketOnboardingClient {
    var submittedSecrets: [String] = []
    private var authentication: PocketOnboardingAuthentication = .accepted
    private var battery = 72
    private var firmware = "1.6"
    /// What the modelled recorder is holding. `nil` is factory-fresh.
    private var heldSecret: String?
    /// Whether this firmware answers `APP&WIFI` at all.
    private var answersReadback = true
    func reset() {
        submittedSecrets = []; authentication = .accepted; battery = 72; firmware = "1.6"
        heldSecret = nil; answersReadback = true
    }
    func configure(authentication: PocketOnboardingAuthentication, battery: Int, firmware: String) { self.authentication = authentication; self.battery = battery; self.firmware = firmware }
    /// The dangerous firmware: it says yes to everything and keeps what it had.
    func configureBlindAcknowledgement(holding secret: String) {
        authentication = .accepted
        heldSecret = secret
    }
    func configureSilentAboutWiFi() { answersReadback = false }
    func authenticate(secret: String) async -> PocketOnboardingAuthentication {
        submittedSecrets.append(secret)
        // A recorder that ACCEPTS is a recorder that is now holding what it accepted — unless
        // it was configured to acknowledge blindly, in which case `heldSecret` stays put and
        // the read-back is what has to notice.
        if authentication == .accepted, heldSecret == nil { heldSecret = secret }
        return authentication
    }
    func confirmation() async throws -> PocketOnboardingConfirmation { .init(batteryPercent: battery, firmware: firmware) }
    func accessPointReadback() async throws -> PocketAccessPointReadback {
        guard answersReadback, let heldSecret else {
            throw PocketProtocolError.unsupportedOperation
        }
        return PocketAccessPointReadback(ssid: "PKT01_BLUE_26079bc5",
                                         fields: ["PKT01_BLUE_26079bc5",
                                                  String(heldSecret.prefix(8))])
    }
    func close() async {}
}

private actor FailingThenWorkingPocketSecretStore: PocketSecretStore {
    private var attempts = 0
    func save(_ secret: String, for identity: PocketAuthenticatedIdentity) async throws { attempts += 1; if attempts == 1 { throw PocketSecretStoreError.unavailable } }
    func secret(for identity: PocketAuthenticatedIdentity) async throws -> String? { nil }
    func remove(for identity: PocketAuthenticatedIdentity) async throws {}
}
