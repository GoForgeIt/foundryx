import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for `features/pocket-factory-fresh-mint.feature`.
///
/// WHAT IS REAL HERE. The shipped `RecordingDeviceAttachment` over the same BLE seam
/// `CoreBluetoothCentral` wraps, the real `PocketBLEClient` handshake and its `APP&WIFI`
/// read-back, the real `PocketOnboardingCoordinator.mintFactoryFresh`, the real
/// `PocketSessionKeyMint` generator, the real `PocketRecordingDeviceBridge.observe`, the real
/// `RecordingDeviceAdoption.remember`, and an account-scoped `RecordingDeviceStore` in a
/// sandboxed container. Injected: the radio and the two custody stores.
///
/// THE SCENARIOS THAT CARRY THE MOST WEIGHT ARE THE ONES THAT MUST STAY RED-ABLE.
///
///   * "a recorder that only says yes is not called set up" stands in front of a firmware that
///     answers `MCU&SK&OK` to every key write and goes on using the key it already had — which
///     is proposal §6b's unobserved-but-possible U1 behaviour. Delete the access-point
///     read-back from `provisionFactoryFresh` and this scenario reports the device adopted,
///     which is the whole failure it exists to catch.
///   * "nothing is written to a recorder until I say so" runs the shipped attach with no
///     consent and asserts the transport's OWN record of every `APP&…` byte is empty. Give
///     `attach`'s `mint:` parameter a non-nil default and it goes red.
final class PocketFactoryFreshMintFeatureTests: ProcessGlobalStateTestCase {

    @MainActor
    func testPocketFactoryFreshMintFeature() async throws {
        let world = try FactoryFreshMintWorld()
        do {
            let result = try await BrineFeatureRunner.run(
                "pocket-factory-fresh-mint",
                registry: StepRegistry(FactoryFreshMintSteps.make(world: world)))
            // Pin the POPULATION: the runner asserts only that nothing FAILED, so deleting a
            // scenario would otherwise leave this suite green.
            XCTAssertEqual(result.passed, 12,
                           "pocket-factory-fresh-mint must run all 12 scenarios — the fresh "
                               + "mint, the two unproven-mint branches, the already-claimed "
                               + "branch, the no-consent-no-bytes gate, the key's own "
                               + "properties, the unstorable key that is never sent, the "
                               + "unreadable custody that never mints, custody and recovery, "
                               + "credential hygiene, the reset guidance, and the honesty "
                               + "rules")
        } catch {
            world.cleanup()
            throw error
        }
        world.cleanup()
    }

    // MARK: unit — the generator, held against the constraints that make it safe

    /// THE ALPHABET IS A COMPATIBILITY REQUIREMENT, NOT A STYLE. The first eight characters of
    /// the key BECOME the recorder's WPA passphrase, and the whole control protocol is
    /// `&`-delimited. A generator that drifts off this alphabet produces either a recorder
    /// whose WiFi cannot be joined or a key that splits its own provisioning command.
    func testTheGeneratedKeyIsWireAndWiFiSafeEveryTime() throws {
        for _ in 0..<256 {
            let key = try PocketSessionKeyMint.generate()
            XCTAssertEqual(key.utf8.count, 16, "a generated key is not sixteen bytes")
            XCTAssertTrue(PocketSecretRecord.isValid(key),
                          "the generator produced a key the shipped custody predicate refuses, "
                              + "so a mint would store nothing")
            XCTAssertTrue(PocketSessionKeyMint.isWireAndWiFiSafe(key))
            XCTAssertFalse(key.contains("&"),
                           "a key containing the protocol's own delimiter would split "
                               + "APP&SK&<key> into a different command")
            XCTAssertEqual(key.trimmingCharacters(in: .whitespacesAndNewlines), key,
                           "a key with edge whitespace can never be re-entered as itself — "
                               + "`PocketSessionKey.normalised` would trim it away")
            let password = PocketSessionKeyMint.accessPointPassword(for: key)
            XCTAssertEqual(password?.count, 8,
                           "the derived WiFi password is not the WPA minimum length")
            XCTAssertTrue(password?.unicodeScalars.allSatisfy {
                $0.isASCII && $0.value >= 32 && $0.value <= 126
            } ?? false, "the derived WiFi password is not a legal WPA passphrase")
        }
    }

    /// UNIFORM, AND NOT BY ASSERTION. `byte % 57` would over-weight the first 28 characters of
    /// the alphabet by ~14%. This is a coarse but genuinely failing check on that: over a large
    /// sample no character may be wildly more common than the mean.
    func testTheGeneratorIsNotModuloBiased() throws {
        var histogram: [Character: Int] = [:]
        let draws = 4_000
        for _ in 0..<draws {
            for character in try PocketSessionKeyMint.generate() {
                histogram[character, default: 0] += 1
            }
        }
        let alphabet = PocketSessionKeyMint.alphabet
        XCTAssertEqual(Set(histogram.keys), Set(alphabet),
                       "the generator does not use its whole alphabet, or uses characters "
                           + "outside it")
        let mean = Double(draws * 16) / Double(alphabet.count)
        for (character, count) in histogram {
            let ratio = Double(count) / mean
            XCTAssertTrue(ratio > 0.85 && ratio < 1.15,
                          "\"\(character)\" appears at \(String(format: "%.2f", ratio))× the "
                              + "mean — the generator is biased, which is what `% alphabet"
                              + ".count` without a rejection filter does")
        }
    }

    /// A key is never derived from anything, so two draws collide only by chance. 93 bits of
    /// entropy make a collision in 512 draws impossible in practice; equality here means the
    /// generator returned something constant.
    func testTwoGeneratedKeysAreNeverTheSame() throws {
        let keys = try (0..<512).map { _ in try PocketSessionKeyMint.generate() }
        XCTAssertEqual(Set(keys).count, keys.count,
                       "the generator repeats itself, so every recorder this app sets up "
                           + "shares a key with somebody else's")
    }

    // MARK: unit — the proof

    /// THE READ-BACK IS ORDER-AGNOSTIC AND STILL A PROOF. No hardware session recorded which
    /// field of `MCU&WIFI&…` is the password, so the check may not depend on position — but it
    /// must still refuse a recorder reporting somebody else's password.
    func testTheAccessPointReadbackProvesPossessionAndOnlyPossession() {
        let ours = "Zq7vK3wRpL2xAbCd"
        let theirs = "Aa1Bb2Cc3Dd4Ee5F"
        let derived = PocketSessionKeyMint.accessPointPassword(for: ours)!

        for response in ["MCU&WIFI&PKT01_BLUE_26079bc5&\(derived)",
                         "MCU&WIFI&\(derived)&PKT01_BLUE_26079bc5"] {
            guard let readback = PocketAccessPointReadback.parse(response) else {
                return XCTFail("a well-formed credentials response did not parse: \(response)")
            }
            XCTAssertTrue(readback.provesPossession(ofSessionKey: ours),
                          "the proof depends on which field the password landed in, and no "
                              + "hardware session recorded that order")
            XCTAssertFalse(readback.provesPossession(ofSessionKey: theirs),
                           "a recorder reporting somebody else's password satisfied the proof")
        }

        // A recorder still holding another app's key reports THAT key's password.
        let otherPassword = PocketSessionKeyMint.accessPointPassword(for: theirs)!
        let stale = PocketAccessPointReadback.parse("MCU&WIFI&PKT01&\(otherPassword)")!
        XCTAssertFalse(stale.provesPossession(ofSessionKey: ours),
                       "a blindly-acknowledging recorder passed the proof, which is the exact "
                           + "failure the read-back exists to catch")

        // Not-a-credentials-response is a DIFFERENT answer from a mismatch, and the parser
        // must not launder one into the other.
        XCTAssertNil(PocketAccessPointReadback.parse("MCU&UNKNOWN"))
        XCTAssertNil(PocketAccessPointReadback.parse("MCU&WIFI&"))
        XCTAssertNil(PocketAccessPointReadback.parse(""))
    }

    /// A malformed key has no eight-character password, and deriving one anyway would hand a
    /// WPA join a passphrase shorter than the standard's minimum.
    func testNoPasswordIsDerivedFromAMalformedKey() {
        for candidate in ["", "short", "0123456789abcdefg", "0123456789abcde\u{00E9}"] {
            XCTAssertNil(PocketSessionKeyMint.accessPointPassword(for: candidate),
                         "\"\(candidate)\" produced a WiFi password")
        }
    }

    // MARK: unit — custody, which is what gates minting at all

    /// THE RECOVERY INDEX IS A SERIAL, NOT A MODEL NAME. Filing two units of one model under
    /// one index would hand the second unit the first one's key.
    func testTheRecoveryIndexRefusesNamesThatAreNotAUnit() {
        XCTAssertNotNil(PocketRecoveryToken(advertisedName: "PKT01_BLUE_26079bc5"))
        XCTAssertNotNil(PocketRecoveryToken(advertisedName: "PKT01-26079bc5"))
        for name in ["", "   ", "PKT01", "Pocket", "PKT01_A", "PKT01_BLUE_26079bc5/../root",
                     String(repeating: "a", count: 200)] {
            XCTAssertNil(PocketRecoveryToken(advertisedName: name),
                         "\"\(name)\" was accepted as a per-unit recovery index")
        }
    }

    /// THE TWO CUSTODY RECORDS HAVE DIFFERENT ADDRESSES AND DIFFERENT SYNC POLICIES, ON
    /// PURPOSE, and the reason is not stylistic.
    ///
    /// The attach record is keyed by the CoreBluetooth peripheral UUID, which iOS generates per
    /// device per app — so a synced copy of it would be unreachable on another phone by
    /// construction. It must stay device-only, and the shipped security gate says so.
    ///
    /// The recovery record is keyed by the recorder's own broadcast serial, which is the same
    /// on every device the owner has. It must sync, or a replaced phone is a dead recorder —
    /// and this firmware has no reset opcode to recover from that.
    func testTheTwoCustodyRecordsAreAddressedAndSyncedDifferently() throws {
        let attach = AppSourceTree.code(of: try String(
            contentsOf: AppSourceTree.repoRoot
                .appendingPathComponent("Sources/FoundryXKit/PocketOnboarding.swift"),
            encoding: .utf8))
        XCTAssertTrue(attach.contains("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"),
                      "the ATTACH record left the device — it is addressed by a per-app "
                          + "peripheral UUID, so syncing it buys nothing and escrows a key")

        let recovery = AppSourceTree.code(of: try String(
            contentsOf: AppSourceTree.repoRoot
                .appendingPathComponent("Sources/FoundryXKit/PocketKeyCustody.swift"),
            encoding: .utf8))
        XCTAssertTrue(recovery.contains("kSecAttrSynchronizable as String: kCFBooleanTrue"),
                      "the RECOVERY record no longer syncs, so a replaced phone is a dead "
                          + "recorder and minting is back to being unsafe")
        XCTAssertTrue(recovery.contains("kSecAttrAccessibleAfterFirstUnlock"),
                      "the recovery record's accessibility class is gone")
        XCTAssertFalse(recovery.contains("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"),
                       "the recovery record is device-only, which cannot be synchronisable — "
                           + "the item would simply never be written")
        XCTAssertTrue(recovery.contains("kSecAttrAccount as String: token.value"),
                      "the recovery record is no longer addressed by the recorder's own "
                          + "serial, which is the only reason it is safe to sync at all")
        XCTAssertNotEqual(KeychainPocketKeyRecoveryStore.defaultService,
                          KeychainPocketSecretStore.defaultService,
                          "both records share a Keychain service, so one overwrites the other")
    }
}

// MARK: - Steps

private enum FactoryFreshMintSteps {
    static func make(world: FactoryFreshMintWorld) -> [StepDefinition] {
        let givens = [
            "a signed-in account and a recorder nobody has ever claimed",
            "a signed-in account and a recorder that says yes to any key and changes nothing",
            "a signed-in account and a recorder that never reports its WiFi",
            "a signed-in account and a recorder another app already claimed",
            "a signed-in account, a recorder nobody has claimed, and storage that fails once",
            "a signed-in account and a recorder whose stored key cannot be read",
            "the key Solleva makes for a new recorder",
            "the shipped guidance for starting a recorder over",
            "every screen this setup can show me",
        ]
        let whens = [
            "I confirm that Solleva should set this recorder up",
            "I tap that recorder without confirming anything",
            "I confirm that Solleva should set this recorder up while every output is captured",
        ]
        let thens = [
            "the recorder is holding the key Solleva made",
            "Solleva tells me this iPhone could not store the key",
            "Solleva says it cannot read its own key and does not offer to make a new one",
            "the key is kept and the recorder is adopted, and no second key was ever sent",
            "Solleva checked the recorder's own WiFi password before calling it set up",
            "the recorder is adopted through the shipped chain",
            "Solleva keeps that key where I can get it back",
            "Solleva does not tell me the recorder is set up",
            "the account does not remember that recorder",
            "Solleva still keeps the key, because the recorder might be holding it",
            "it tells me it could not confirm the recorder took the key",
            "the recorder is still holding the key the other app gave it",
            "Solleva tells me the recorder already belongs to another app",
            "it offers me the key I already have and the way to start the recorder over",
            "Solleva sent that recorder exactly one key and no more",
            "Solleva sent that recorder nothing at all",
            "the recorder is still holding no key",
            "Solleva asks me to confirm, and says what it cannot predict",
            "it is sixteen characters the recorder's protocol can carry",
            "its first eight characters are a password a WiFi network will accept",
            "two keys made one after another are never the same",
            "it contains no character that would split the recorder's own commands",
            "I can see this recorder's key on a screen of its own",
            "a new phone with the same Apple Account can recover it",
            "a phone that has never seen this recorder connects with the key I already own",
            "it doesn't promise me a key on my next phone when there isn't one",
            "the key is not shown until I ask for it",
            "forgetting the recorder removes both copies of the key",
            "the key appears nowhere in the captured output",
            "the key appears in no line any of these screens can display",
            "the captured output is not empty, so the search is not vacuous",
            "it tells me what it costs me before it tells me how",
            "it says Solleva cannot do it for me",
            "it says Solleva cannot check whether it worked",
            "it says where the steps came from",
            "none of them says the recorder is recording or in range",
            "none of them puts this recorder on my lock screen",
            "none of them reports a battery level Solleva did not just read",
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

/// Custody that refuses the FIRST write and keeps every one after it.
///
/// It is a real conformer to the shipped protocol rather than a stub of an outcome, so the
/// §3.7 state is produced by the production code deciding what a failed save means.
private actor FailingOncePocketSecretStore: PocketSecretStore {
    private var refusedOnce = false
    private var values: [String: String] = [:]
    func save(_ secret: String, for identity: PocketAuthenticatedIdentity) throws {
        guard refusedOnce else {
            refusedOnce = true
            throw PocketSecretStoreError.unavailable
        }
        guard PocketSecretRecord.isValid(secret) else { throw PocketSecretStoreError.unavailable }
        values[identity.storageKey] = secret
    }
    func secret(for identity: PocketAuthenticatedIdentity) -> String? {
        values[identity.storageKey]
    }
    func remove(for identity: PocketAuthenticatedIdentity) { values[identity.storageKey] = nil }
}

/// A STORE THAT THROWS ON READ — the state a locked Keychain, an unrecognised OSStatus, or an
/// item written by a previous tag scheme actually produces.
///
/// It is a real conformer rather than a stubbed outcome, because the whole defect being guarded
/// against is production code flattening a THROW and a NIL into the same answer with `try?`.
private actor UnreadablePocketSecretStore: PocketSecretStore {
    func save(_ secret: String, for identity: PocketAuthenticatedIdentity) throws {
        throw PocketSecretStoreError.unavailable
    }
    func secret(for identity: PocketAuthenticatedIdentity) throws -> String? {
        throw PocketSecretStoreError.unavailable
    }
    func remove(for identity: PocketAuthenticatedIdentity) throws {}
}

// MARK: - The world

private actor FactoryFreshMintWorld {

    private let token = UUID().uuidString
    private let sandbox: URL
    private let container: URL
    private let scopeDefaultsName: String
    private let scopeDefaults: UserDefaults

    private var stack: FakePocketBLEStack?
    private var secrets = InMemoryPocketSecretStore()
    private var recovery = InMemoryPocketKeyRecoveryStore()
    /// Custody that refuses the FIRST write and accepts every one after it — the §3.7 state,
    /// produced through the shipped code rather than by stubbing an outcome.
    private var failingSecrets: FailingOncePocketSecretStore?
    /// Custody that THROWS when it is read — not custody that is empty. The two used to be the
    /// same answer to the shipped code, and the empty one is what the UI offers to mint from.
    private var unreadableSecrets: UnreadablePocketSecretStore?
    private var log = DoorLog()
    private var outcome: RecordingDeviceAttachOutcome?
    private var capturedOutput: String?
    private var scenario = 0

    private static let recorderName = "PKT01_BLUE_26079bc5"
    private static let recorderId = UUID(uuidString: "26079BC5-2C71-4E0D-9F41-6D2B8A5C7E10")!
    /// The key some other app set a recorder up with. Distinctive enough that a substring
    /// search over captured output means something.
    private static let otherAppsKey = "Zq7vK3wRpL2xAbCd"

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-factory-fresh-mint-\(token)", isDirectory: true)
        container = sandbox.appendingPathComponent("documents/foundryx-captures",
                                                   isDirectory: true)
        scopeDefaultsName = "foundryx.factory-fresh-mint.scope.\(token)"
        guard let scope = UserDefaults(suiteName: scopeDefaultsName) else {
            throw BrineStepError("could not create an isolated UserDefaults suite")
        }
        scopeDefaults = scope
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        CaptureAccountScope.setContainerForTests(container)
        CaptureAccountScope.setApplicationSupportRootForTests(
            sandbox.appendingPathComponent("application-support", isDirectory: true))
        CaptureAccountScope.setDefaultsForTests(scopeDefaults)
    }

    nonisolated func cleanup() {
        try? CaptureAccountScope.signOutForTests()
        CaptureAccountScope.resetTestEnvironment()
        UserDefaults().removePersistentDomain(forName: scopeDefaultsName)
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: Given

    func given(_ phrase: String) throws {
        outcome = nil
        capturedOutput = nil
        switch phrase {
        case "a signed-in account and a recorder nobody has ever claimed":
            try signIn()
            stage(behaviour: .factoryFresh)

        case "a signed-in account and a recorder that says yes to any key and changes nothing":
            // PROPOSAL §6b, U1's DANGEROUS ANSWER, modelled. Nobody has watched a keyed
            // recorder receive a second key; if it acknowledges and keeps the old one, a bare
            // `MCU&SK&OK` is a lie the app would otherwise repeat to its owner.
            try signIn()
            stage(behaviour: .blindlyAcknowledges(holding: Self.otherAppsKey))

        case "a signed-in account and a recorder that never reports its WiFi":
            // An older firmware, or one that simply does not answer `APP&WIFI`. That is an
            // honest "not proven", and it is a different thing from a refusal.
            try signIn()
            stage(behaviour: .factoryFresh, answersWiFiReadback: false)

        case "a signed-in account and a recorder another app already claimed":
            // U1's SAFE answer: it refuses any key but the one it holds.
            try signIn()
            stage(behaviour: .keyed(Self.otherAppsKey))

        case "a signed-in account, a recorder nobody has claimed, and storage that fails once":
            // DESIGN §3.7. The recorder takes the key and the Keychain refuses it, leaving the
            // only copy of a live credential in memory. This is the one state in the app where
            // closing it loses something irreversibly.
            try signIn()
            stage(behaviour: .factoryFresh)
            failingSecrets = FailingOncePocketSecretStore()

        case "a signed-in account and a recorder whose stored key cannot be read":
            // NOT AN EMPTY STORE. Solleva may well hold this recorder's key; the Keychain
            // simply would not answer. Offering to mint from here writes a SECOND key to a
            // recorder Solleva itself provisioned.
            try signIn()
            stage(behaviour: .factoryFresh)
            unreadableSecrets = UnreadablePocketSecretStore()

        case "the key Solleva makes for a new recorder",
             "the shipped guidance for starting a recorder over",
             "every screen this setup can show me":
            break

        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    private func signIn() throws {
        // A FRESH ACCOUNT PER SCENARIO. `RecordingDeviceStore` is account-scoped, so a shared
        // sign-in would let the scenario that adopts a recorder satisfy the scenarios that
        // assert the account remembers nothing.
        scenario += 1
        CaptureAccountScope.setAccountForTests(email: "mint-\(token)-\(scenario)@example.com")
        guard let binding = CaptureAccountScope.currentAccountBinding(),
              binding.scope != CaptureAccountScope.signedOutScope else {
            throw BrineStepError("signing in did not leave the signed-out scope")
        }
    }

    private func stage(behaviour: FakePocketBLEStack.KeyBehaviour,
                       answersWiFiReadback: Bool = true) {
        stack = FakePocketBLEStack(deviceId: Self.recorderId,
                                   deviceName: Self.recorderName,
                                   map: .primary,
                                   answersWiFiReadback: answersWiFiReadback,
                                   behaviour: behaviour)
        // EMPTY ON PURPOSE. Solleva holds no key for this recorder, which is the only state a
        // mint may be attempted from.
        secrets = InMemoryPocketSecretStore()
        recovery = InMemoryPocketKeyRecoveryStore()
        failingSecrets = nil
        unreadableSecrets = nil
        log = DoorLog()
    }

    // MARK: When

    func when(_ phrase: String) async throws {
        switch phrase {
        case "I confirm that Solleva should set this recorder up":
            outcome = await mint()

        case "I tap that recorder without confirming anything":
            // THE SHIPPED TAP, WITH NO CONSENT VALUE. This is the default call — the same one
            // the connect sheet makes — and it must never write a key.
            outcome = await attach(mint: nil)

        case "I confirm that Solleva should set this recorder up while every output is captured":
            capturedOutput = await captureProcessOutput { self.outcome = await self.mint() }
            try await settle()
            capturedOutput = (capturedOutput ?? "") + "\n" + log.dump()

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    /// THE MINT, THROUGH THE SHIPPED ATTACHMENT. The consent value is constructed here for the
    /// same reason the app constructs it in one place: nothing else can.
    private func mint() async -> RecordingDeviceAttachOutcome {
        await attach(mint: .ownerConfirmedAfterReadingTheConsequences())
    }

    private func attach(mint consent: PocketMintConsent?) async -> RecordingDeviceAttachOutcome {
        guard let stack else { return .unreachable(.unexplained) }
        let attachment = RecordingDeviceAttachment(
            makeCentral: stack.factory,
            // WHICHEVER CUSTODY THIS SCENARIO STAGED. `??` between two different concrete
            // actors needs the existential spelled out.
            secrets: (unreadableSecrets as (any PocketSecretStore)?)
                ?? (failingSecrets as (any PocketSecretStore)?) ?? secrets,
            recovery: recovery,
            deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 5),
            log: log)
        return await attachment.attach(peripheralIdentifier: stack.deviceId,
                                       advertisedName: stack.deviceName,
                                       mint: consent)
    }

    private func heldKey() throws -> String? {
        guard let stack else { throw BrineStepError("no recorder was staged") }
        return stack.keyHeldByRecorder
    }

    private func custodyKey() async throws -> String? {
        let identity = try PocketAuthenticatedIdentity(
            peripheralIdentifier: Self.recorderId.uuidString)
        if let failingSecrets { return await failingSecrets.secret(for: identity) }
        return await secrets.secret(for: identity)
    }

    // MARK: Then

    func then(_ phrase: String) async throws {
        switch phrase {

        // ── the fresh mint ──────────────────────────────────────────────────
        case "the recorder is holding the key Solleva made":
            let held = try heldKey()
            XCTAssertNotNil(held, "the recorder is holding no key, so nothing was provisioned")
            let stored = try await custodyKey()
            XCTAssertEqual(held, stored,
                           "the key the recorder is holding is not the key Solleva kept — "
                               + "which is a recorder nothing can connect to again. (Neither "
                               + "value is printed here.)")
            XCTAssertTrue(PocketSessionKeyMint.isWireAndWiFiSafe(held ?? ""),
                          "the key that reached the recorder is not one its own WiFi could "
                              + "use as a passphrase")

        case "Solleva checked the recorder's own WiFi password before calling it set up":
            guard let stack else { throw BrineStepError("no recorder was staged") }
            let commands = stack.commandsWritten
            guard let keyIndex = commands.firstIndex(where: { $0.hasPrefix("SK&") }),
                  let wifiIndex = commands.firstIndex(of: "WIFI") else {
                return XCTFail("the mint never read the access-point credentials back, so a "
                                   + "bare MCU&SK&OK was taken as proof: \(commands)")
            }
            XCTAssertLessThan(keyIndex, wifiIndex,
                              "the read-back was issued before the key was written, so it "
                                  + "cannot be evidence about the key: \(commands)")

        case "the recorder is adopted through the shipped chain":
            guard case .adopted(let identity, let displayName, let negotiated) = outcome else {
                throw BrineStepError("a confirmed mint on a factory-fresh recorder produced "
                                         + String(describing: outcome))
            }
            XCTAssertEqual(identity.shape, .filePull)
            XCTAssertEqual(identity.hardwareToken,
                           Self.recorderId.uuidString.lowercased(),
                           "the durable address is not the authenticated peripheral token — a "
                               + "broadcast name can be copied and is not proof of which "
                               + "device this is")
            XCTAssertEqual(displayName, Self.recorderName)
            XCTAssertEqual(negotiated, PocketRecordingDeviceBridge.protocolIdentifier)
            let records = UnifiedDeviceListComposition.rememberedForCurrentAccount(
                defaults: scopeDefaults)
            XCTAssertTrue(records.contains { $0.identity == identity },
                          "the account does not remember the recorder it just set up, so the "
                              + "list would not draw it")

        case "Solleva keeps that key where I can get it back":
            // BOTH RECORDS. The attach record makes the recorder work on this phone; the
            // synchronised recovery copy is what makes a replaced phone survivable — and this
            // firmware has no reset opcode, so there is no other way back.
            let stored = try await custodyKey()
            XCTAssertNotNil(stored, "the attach record is empty after a completed mint")
            guard let recoveryToken = PocketRecoveryToken(advertisedName: Self.recorderName)
            else { return XCTFail("this recorder's own name is not a usable recovery index") }
            let recovered = await recovery.key(under: recoveryToken)
            XCTAssertEqual(recovered, stored,
                           "no recovery copy was written, so replacing this phone would leave "
                               + "the owner with a recorder nothing can ever connect to")

        // ── custody runs before the radio ───────────────────────────────────
        case "Solleva tells me this iPhone could not store the key":
            // THE ORDER IS THE WHOLE POINT. The candidate goes into the Keychain BEFORE the
            // `APP&SK&` write, so a phone that cannot store a key never offers one — where the
            // old order left the recorder holding a credential nothing had a copy of, on
            // hardware with no reset and no key-read opcode.
            XCTAssertEqual(outcome, .keyNotKept,
                           "custody refused the key and the flow produced "
                               + String(describing: outcome)
                               + " instead of stopping before the radio")
            let screen = PocketSetupPresentation.keyNotKept
            XCTAssertTrue(screen.body.contains("sent it nothing"),
                          "the screen does not make the reassurance that is knowable — nothing "
                              + "reached the recorder at all")
            XCTAssertFalse(screen.actions.contains(PocketMintConsentPresentation.confirmAction),
                           "a storage failure offers to send a key anyway")

        case "the key is kept and the recorder is adopted, and no second key was ever sent":
            guard case .adopted = outcome else {
                throw BrineStepError("retrying secure storage produced "
                                         + String(describing: outcome)
                                         + " instead of adopting the recorder")
            }
            let stored = try await custodyKey()
            XCTAssertNotNil(stored, "the retry reported success with nothing in custody")
            XCTAssertEqual(stored, try heldKey(),
                           "custody and the recorder disagree about the key after the retry")
            guard let stack else { throw BrineStepError("no recorder was staged") }
            // DISTINCT KEYS, NOT WRITES. The retry re-runs the ordinary restore path, which
            // authenticates with the key already in custody — that is the SAME key, sent
            // again, and it is how every later launch connects. What must never happen is a
            // SECOND key: a new credential written to a recorder already holding one is how
            // the first one becomes unrecoverable twice over.
            let keysOffered = Set(stack.commandsWritten
                .filter { $0.hasPrefix("SK&") }
                .map { String($0.dropFirst("SK&".count)) })
            XCTAssertEqual(keysOffered.count, 1,
                           "the recorder was offered \(keysOffered.count) different keys")
            XCTAssertEqual(keysOffered.first, stored,
                           "the key the recorder was offered is not the key custody kept")

        // ── acknowledged but unproven ───────────────────────────────────────
        case "Solleva does not tell me the recorder is set up":
            XCTAssertEqual(outcome, .mintNotVerified,
                           "a recorder that acknowledged the key without proving it took it "
                               + "produced \(String(describing: outcome)). A bare MCU&SK&OK is "
                               + "an acknowledgement, not evidence")

        case "the account does not remember that recorder":
            let records = UnifiedDeviceListComposition.rememberedForCurrentAccount(
                defaults: scopeDefaults)
            XCTAssertTrue(records.isEmpty,
                          "an unproven mint added a row anyway: \(records.map(\.displayName))")

        case "Solleva still keeps the key, because the recorder might be holding it":
            let stored = try await custodyKey()
            XCTAssertNotNil(stored,
                            "the key was discarded after the recorder acknowledged it. If the "
                                + "recorder IS holding it, this is a device nothing can ever "
                                + "connect to again — there is no reset and no key-read opcode")

        case "it tells me it could not confirm the recorder took the key":
            let body = PocketMintNotVerifiedPresentation.body
            XCTAssertTrue(body.contains("check"),
                          "the screen does not say that CHECKING is what failed: \"\(body)\"")
            XCTAssertTrue(body.contains("kept the key"),
                          "the screen does not tell the owner the key was kept, which is the "
                              + "one thing that stops them starting over and re-keying")
            for claim in ["is set up", "setup is complete", "ready to use"] {
                XCTAssertFalse(PocketMintNotVerifiedPresentation.title.contains(claim),
                               "the unverified screen claims setup completed: \"\(claim)\"")
            }

        // ── already claimed ─────────────────────────────────────────────────
        case "the recorder is still holding the key the other app gave it":
            XCTAssertEqual(try heldKey(), Self.otherAppsKey,
                           "a refused mint changed what the recorder is holding")

        case "Solleva tells me the recorder already belongs to another app":
            XCTAssertEqual(outcome, .mintRefused,
                           "a recorder that refused the key produced "
                               + String(describing: outcome))
            XCTAssertTrue(PocketMintRefusedPresentation.title.contains("another app"))
            XCTAssertTrue(PocketMintRefusedPresentation.body.contains("Nothing changed"),
                          "the screen does not make the one reassurance that is knowable")

        case "it offers me the key I already have and the way to start the recorder over":
            XCTAssertTrue(PocketMintRefusedPresentation.actions
                .contains(PocketSessionKeyEntryPresentation.entryAction))
            XCTAssertTrue(PocketMintRefusedPresentation.actions
                .contains(PocketMintConsentPresentation.resetAction),
                          "a refused recorder is offered no route at all, which is the dead "
                              + "end this branch exists to avoid")

        case "Solleva sent that recorder exactly one key and no more":
            guard let stack else { throw BrineStepError("no recorder was staged") }
            let keyWrites = stack.commandsWritten.filter { $0.hasPrefix("SK&") }
            XCTAssertEqual(keyWrites.count, 1,
                           "the app sent \(keyWrites.count) keys. It sends one, once, and "
                               + "never retries on its own — guessing at a device credential "
                               + "is how people get locked out of their own hardware")

        // ── no consent, no bytes ────────────────────────────────────────────
        case "Solleva sent that recorder nothing at all":
            guard let stack else { throw BrineStepError("no recorder was staged") }
            XCTAssertEqual(stack.commandsWritten, [],
                           "a tap with no confirmation wrote \(stack.commandsWritten) to the "
                               + "recorder. Because nobody has observed what an already-keyed "
                               + "recorder does with a second key, an unconfirmed write is a "
                               + "possibly destructive act")

        case "Solleva says it cannot read its own key and does not offer to make a new one":
            // A THROW IS NOT AN EMPTY STORE. `.setupUnavailable` is the state the app turns
            // into the MINT OFFER, so collapsing an unreadable Keychain into it is how a
            // transient storage error becomes a second key written to a recorder Solleva
            // itself provisioned — and, if that recorder refuses it, a screen telling the
            // owner their own recorder belongs to somebody else.
            XCTAssertEqual(outcome, .custodyUnreadable,
                           "custody threw on the way in and the flow produced "
                               + String(describing: outcome)
                               + ". `.setupUnavailable` here IS the mint offer")
            let unreadable = PocketSetupPresentation.custodyUnreadable
            XCTAssertTrue(unreadable.body.contains("won't make a new key"),
                          "the screen does not say the one thing that makes this state safe: "
                              + "that no new key is made from it")
            XCTAssertFalse(unreadable.actions.contains(
                            PocketMintConsentPresentation.confirmAction),
                           "an unreadable Keychain offers to mint a key anyway")
            XCTAssertFalse(unreadable.title.contains("another app"),
                           "the screen accuses another app of owning a recorder Solleva may "
                               + "have set up itself")

        case "the recorder is still holding no key":
            XCTAssertNil(try heldKey(),
                         "an unconfirmed tap provisioned the recorder anyway")

        case "Solleva asks me to confirm, and says what it cannot predict":
            // AND THE TAP STOPPED THERE. `.setupUnavailable` is the state the app routes to
            // the consent screen; anything else means it either minted or gave up.
            XCTAssertEqual(outcome, .setupUnavailable,
                           "a tap with no confirmation produced "
                               + String(describing: outcome))
            XCTAssertEqual(PocketMintConsentPresentation.actions.first,
                           PocketMintConsentPresentation.confirmAction)
            XCTAssertTrue(PocketMintConsentPresentation.whatSollevaDoesNotKnow
                .contains("never seen"),
                          "the consent screen states the unknown as a risk assessment rather "
                              + "than as the absence of evidence it is")
            XCTAssertTrue(PocketMintConsentPresentation.whatItCouldCost.contains("recording"),
                          "the consent screen does not mention the recordings that may be out "
                              + "of reach afterwards")
            XCTAssertTrue(PocketMintConsentPresentation.theWiFiPasswordChanges
                .contains("WiFi password"),
                          "the consent screen does not mention that the recorder's own WiFi "
                              + "password changes with the key")

        // ── the key's own properties ────────────────────────────────────────
        case "it is sixteen characters the recorder's protocol can carry":
            let key = try PocketSessionKeyMint.generate()
            XCTAssertEqual(key.utf8.count, 16)
            XCTAssertTrue(PocketSecretRecord.isValid(key))

        case "its first eight characters are a password a WiFi network will accept":
            let key = try PocketSessionKeyMint.generate()
            guard let password = PocketSessionKeyMint.accessPointPassword(for: key) else {
                return XCTFail("no WiFi password is derived from a freshly generated key")
            }
            XCTAssertEqual(password, String(key.prefix(8)))
            XCTAssertEqual(password.count, 8, "shorter than WPA's own minimum")
            XCTAssertTrue(password.unicodeScalars.allSatisfy {
                $0.isASCII && $0.value >= 32 && $0.value <= 126
            })

        case "two keys made one after another are never the same":
            XCTAssertNotEqual(try PocketSessionKeyMint.generate(),
                              try PocketSessionKeyMint.generate())

        case "it contains no character that would split the recorder's own commands":
            for _ in 0..<64 {
                let key = try PocketSessionKeyMint.generate()
                XCTAssertFalse(key.contains("&"))
                XCTAssertEqual(key.trimmingCharacters(in: .whitespacesAndNewlines), key)
            }

        // ── custody ─────────────────────────────────────────────────────────
        case "I can see this recorder's key on a screen of its own":
            let identity = try PocketAuthenticatedIdentity(
                peripheralIdentifier: Self.recorderId.uuidString)
            let custody = PocketKeyCustody(attachStore: secrets, recoveryStore: recovery)
            let revealed = await custody.reveal(for: identity)
            XCTAssertNotNil(revealed,
                            "there is no way for the owner to read back the key their recorder "
                                + "was set up with, so a lost phone is a dead recorder")
            let stored = try await custodyKey()
            XCTAssertEqual(revealed, stored)
            XCTAssertTrue(PocketKeyCustodyPresentation.everyLine
                .contains(PocketKeyCustodyPresentation.copyAction),
                          "the key can be shown and not copied, which makes it something the "
                              + "owner has to transcribe off a screen")
            // AND IT IS REACHABLE FROM THE RECORDER'S OWN PAGE, not only from setup.
            let page = RecordingDevicePage.resolve(
                RecordingDeviceListInput(
                    identity: identity.recordingDeviceIdentity,
                    displayName: Self.recorderName,
                    link: .disconnected,
                    isRemembered: true,
                    negotiatedProtocol: PocketRecordingDeviceBridge.protocolIdentifier),
                canConnect: false)
            XCTAssertTrue(page.actions.contains(PocketKeyCustodyPresentation.entryAction),
                          "the recorder's own page offers no way to see its key, so the only "
                              + "place it was ever visible was the moment it was minted")

        case "a new phone with the same Apple Account can recover it":
            guard let recoveryToken = PocketRecoveryToken(advertisedName: Self.recorderName)
            else { return XCTFail("this recorder's name is not a usable recovery index") }
            let recovered = await recovery.key(under: recoveryToken)
            let attachRecord = try await custodyKey()
            XCTAssertEqual(recovered, attachRecord,
                           "the synchronised copy is absent or disagrees with the attach "
                               + "record, so a replaced phone finds nothing")
            // The recovery index is NOT the attach identity. A name can be copied; it may
            // never be what custody is addressed by on the connect path.
            XCTAssertNotEqual(recoveryToken.value,
                              Self.recorderId.uuidString.lowercased(),
                              "the recovery index and the attach address are the same value, "
                                  + "so the broadcast name has become an identity")

        case "a phone that has never seen this recorder connects with the key I already own":
            // THE RECORD THAT WAS WRITTEN AND NEVER READ. The attach record is addressed by
            // the CoreBluetooth peripheral UUID, which iOS generates PER DEVICE PER APP — so
            // on a replaced phone it is ALWAYS absent, and the state that follows an absent
            // attach record is the one the app renders as the MINT OFFER. Without a reader for
            // the synchronised copy, replacing a phone walked the owner into writing a second
            // key to a recorder they already owned: told it belongs to another app if the
            // firmware refuses, or silently re-keyed (and its WiFi password changed) if it
            // does not. Modelled here as exactly that state — an EMPTY attach store beside the
            // synchronised record the mint wrote.
            guard let stack else { throw BrineStepError("no recorder was staged") }
            let keyBefore = stack.keyHeldByRecorder
            let newPhone = InMemoryPocketSecretStore()
            let onTheNewPhone = RecordingDeviceAttachment(
                makeCentral: stack.factory,
                secrets: newPhone,
                recovery: recovery,
                deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 5),
                log: log)
            // A PLAIN TAP. No consent value, so this path CANNOT mint — if the recovery copy
            // is not read, the only reachable answer is the setup screen.
            let recovered = await onTheNewPhone.attach(peripheralIdentifier: stack.deviceId,
                                                       advertisedName: stack.deviceName)
            guard case .adopted = recovered else {
                return XCTFail("a phone holding only the synchronised copy produced "
                                   + String(describing: recovered)
                                   + " — which is the screen that offers to mint a SECOND key "
                                   + "for a recorder this owner already owns")
            }
            XCTAssertEqual(stack.keyHeldByRecorder, keyBefore,
                           "connecting with the recovered key changed what the recorder is "
                               + "holding, so the recovery path re-keyed the hardware")
            let offered = Set(stack.commandsWritten
                .filter { $0.hasPrefix("SK&") }
                .map { String($0.dropFirst("SK&".count)) })
            XCTAssertEqual(offered.count, 1,
                           "the recorder was offered \(offered.count) different keys, so the "
                               + "recovery path sent it something new")
            let filed = try PocketAuthenticatedIdentity(
                peripheralIdentifier: Self.recorderId.uuidString)
            let nowLocal = await newPhone.secret(for: filed)
            XCTAssertNotNil(nowLocal,
                            "the recovered key was not filed locally, so every later connect "
                                + "on this phone repeats the lookup")

        case "it doesn't promise me a key on my next phone when there isn't one":
            // `keep` reports `.deviceOnly` whenever there is no per-unit recovery index or the
            // synchronised write failed, and that outcome had no readers: the screen promised
            // "a new iPhone finds it on its own" either way. The one owner who genuinely has
            // to write their key down was the one being told they did not have to.
            let custodyForCopy = PocketKeyCustody(attachStore: secrets, recoveryStore: recovery)
            let realToken = PocketRecoveryToken(advertisedName: Self.recorderName)
            let synced = await custodyForCopy.hasRecoveryCopy(realToken)
            XCTAssertTrue(synced,
                          "custody reports no synchronised copy after a completed mint")
            let syncedWithoutIndex = await custodyForCopy.hasRecoveryCopy(nil)
            XCTAssertFalse(syncedWithoutIndex,
                           "custody claims a synchronised copy for a recorder that has no "
                               + "per-unit recovery index at all")
            let promise = PocketKeyCustodyPresentation.whereItIsKept(hasRecoveryCopy: true)
            let noPromise = PocketKeyCustodyPresentation.whereItIsKept(hasRecoveryCopy: false)
            XCTAssertNotEqual(promise, noPromise,
                              "the screen says the same thing whether or not the synchronised "
                                  + "copy exists, so it is a promise rather than a report")
            XCTAssertTrue(promise.contains("finds it on its own"),
                          "the synchronised wording no longer states the §10 promise")
            XCTAssertFalse(noPromise.contains("finds it on its own"),
                           "the device-only wording still promises that a new iPhone recovers "
                               + "the key by itself, which is exactly what did not happen")
            XCTAssertTrue(noPromise.contains("THIS iPhone only"),
                          "the device-only wording does not tell the owner the key is not "
                              + "anywhere else")

        case "the key is not shown until I ask for it":
            XCTAssertFalse(PocketKeyCustodyPresentation.isRevealedByDefault,
                           "the custody screen renders the key on arrival, which puts it in "
                               + "every app-switcher snapshot of that screen")
            XCTAssertTrue(PocketKeyCustodyPresentation.everyLine
                .contains(PocketKeyCustodyPresentation.revealAction))
            // AND IT IS NOT ON THE SETUP CEREMONY. Design §3.4 keeps reveal/copy/share/export
            // off the setup screens; this is a separate, deliberately-reached screen.
            let ceremony = PocketSetupPresentation.all
                .flatMap { [$0.title, $0.body] + $0.actions }.joined(separator: " ").lowercased()
            for word in ["reveal", "copy", "share", "export"] {
                XCTAssertFalse(ceremony.contains(word),
                               "the setup ceremony offers to \(word) a credential")
            }

        case "forgetting the recorder removes both copies of the key":
            let identity = try PocketAuthenticatedIdentity(
                peripheralIdentifier: Self.recorderId.uuidString)
            guard let recoveryToken = PocketRecoveryToken(advertisedName: Self.recorderName)
            else { return XCTFail("this recorder's name is not a usable recovery index") }
            let custody = PocketKeyCustody(attachStore: secrets, recoveryStore: recovery)
            await custody.forget(identity, recoveryToken: recoveryToken)
            let attachAfter = await secrets.secret(for: identity)
            let recoveryAfter = await recovery.key(under: recoveryToken)
            XCTAssertNil(attachAfter, "the attach record survived being forgotten")
            XCTAssertNil(recoveryAfter,
                         "the synchronised copy survived being forgotten, so \"forgetting "
                             + "this recorder deletes FoundryX's key for it\" is false on "
                             + "every other device the owner has")

        // ── credential hygiene ──────────────────────────────────────────────
        case "the key appears nowhere in the captured output":
            guard let captured = capturedOutput else {
                throw BrineStepError("no output was captured")
            }
            guard let key = try await custodyKey() else {
                throw BrineStepError("no key was minted, so this search is vacuous")
            }
            XCTAssertFalse(captured.contains(key),
                           "the recorder's session key was printed or logged")
            let password = PocketSessionKeyMint.accessPointPassword(for: key) ?? ""
            XCTAssertFalse(password.isEmpty)
            XCTAssertFalse(captured.contains(password),
                           "the derived WiFi password — which is literally half the session "
                               + "key — was printed or logged")

        case "the key appears in no line any of these screens can display":
            guard let key = try await custodyKey() else {
                throw BrineStepError("no key was minted, so this search is vacuous")
            }
            for line in Self.everyMintLine {
                XCTAssertFalse(line.contains(key), "a rendered line carries the key")
                XCTAssertFalse(line.contains(String(key.prefix(8))),
                               "a rendered line carries the derived WiFi password")
            }
            // The outcome value is printable and must carry nothing either.
            XCTAssertFalse(String(describing: outcome ?? .unrecognised).contains(key))

        case "the captured output is not empty, so the search is not vacuous":
            XCTAssertFalse((capturedOutput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
                           "nothing was captured, so the search above proves nothing")

        // ── the reset guidance ──────────────────────────────────────────────
        case "it tells me what it costs me before it tells me how":
            let titles = PocketFactoryResetPresentation.sections.map(\.title)
            guard let costIndex = titles.firstIndex(where: { $0.lowercased().contains("cost") }),
                  let stepsIndex = titles.firstIndex(where: { $0.lowercased().contains("gesture") })
            else { return XCTFail("the reset guidance has no cost section or no steps") }
            XCTAssertLessThan(costIndex, stepsIndex,
                              "the steps come before the cost, so somebody skimming for the "
                                  + "instructions performs a destructive gesture without "
                                  + "reading what it destroys")
            XCTAssertTrue(PocketFactoryResetPresentation.costFirst.contains("synced"),
                          "the cost paragraph does not mention unsynced recordings")

        case "it says Solleva cannot do it for me":
            XCTAssertTrue(PocketFactoryResetPresentation.sollevaCannotDoIt.contains("can't do this"),
                          "the guidance implies the app is performing the reset")

        case "it says Solleva cannot check whether it worked":
            XCTAssertTrue(PocketFactoryResetPresentation.sollevaCannotVerifyIt
                .contains("can't tell you whether it worked"),
                          "the guidance implies the app can confirm a reset it cannot observe")

        case "it says where the steps came from":
            XCTAssertTrue(PocketFactoryResetPresentation.provenance.contains("maker's guide"))
            XCTAssertTrue(PocketFactoryResetPresentation.provenance.contains("hasn't verified"),
                          "unverified steps are presented as Solleva's own claim")

        // ── the honesty rules ───────────────────────────────────────────────
        case "none of them says the recorder is recording or in range":
            for line in Self.everyMintLine {
                for banned in UnifiedDeviceListPresentation.bannedProximityWords {
                    XCTAssertFalse(line.contains(banned),
                                   "\"\(banned)\" appears in setup copy. A BLE peripheral "
                                       + "stops advertising while another app holds it, so a "
                                       + "recorder on the table would read \"not in range\"")
                }
                XCTAssertFalse(line.lowercased().contains("is recording now"),
                               "setup copy claims to know whether the recorder is recording")
            }

        case "none of them puts this recorder on my lock screen":
            XCTAssertFalse(PocketOnboardingCapabilities.hasLiveRecordingSurface,
                           "a record-then-sync recorder declared a live recording surface")
            XCTAssertEqual(PocketOnboardingCapabilities.delivery, .pullAfterTheFact)
            for line in Self.everyMintLine {
                for banned in ["Live Activity", "lock screen", "Dynamic Island"] {
                    XCTAssertFalse(line.contains(banned),
                                   "setup copy promises \"\(banned)\" for a device that has "
                                       + "no live surface at all")
                }
            }

        case "none of them reports a battery level Solleva did not just read":
            // The confirmation screen's numbers come from the session that just ran. Nothing
            // in this copy carries a number at all, which is what makes that impossible to
            // fake in a string.
            for line in Self.everyMintLine {
                XCTAssertFalse(line.contains("%"),
                               "setup copy carries a percentage — the only battery figure this "
                                   + "app may show is one it read on the live session: "
                                   + "\"\(line)\"")
            }

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    /// EVERY LINE THIS WHOLE FLOW CAN RENDER. The honesty and hygiene gates are held over the
    /// POPULATION rather than over whichever strings a test author remembered, so a new
    /// sentence cannot slip past them.
    private static var everyMintLine: [String] {
        PocketMintConsentPresentation.everyLine
            + PocketMintRefusedPresentation.everyLine
            + PocketMintNotVerifiedPresentation.everyLine
            + PocketFactoryResetPresentation.everyLine
            + PocketKeyCustodyPresentation.everyLine
    }

    // MARK: capture

    /// Run `body` with the process's own stdout and stderr redirected into a file, and return
    /// what landed there. A FILE rather than a pipe on purpose: a pipe's buffer can fill and
    /// wedge the very code under test.
    private func captureProcessOutput(_ body: () async -> Void) async -> String {
        let url = sandbox.appendingPathComponent("captured-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let sink = open(url.path, O_WRONLY | O_APPEND)
        guard sink >= 0 else {
            await body()
            return ""
        }
        fflush(stdout); fflush(stderr)
        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        dup2(sink, STDOUT_FILENO)
        dup2(sink, STDERR_FILENO)
        await body()
        fflush(stdout); fflush(stderr)
        dup2(savedOut, STDOUT_FILENO)
        dup2(savedErr, STDERR_FILENO)
        close(savedOut); close(savedErr); close(sink)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// `DoorLog` funnels its writes onto the main thread, so its entries are only readable
    /// after the main queue has caught up with the chain that produced them.
    private func settle() async throws {
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 20_000_000)
            await MainActor.run {}
        }
    }
}
