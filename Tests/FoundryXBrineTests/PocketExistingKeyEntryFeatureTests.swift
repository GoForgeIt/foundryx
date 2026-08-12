import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for `features/pocket-existing-key-entry.feature` (track
/// 20260811T0411_pocket_existing_key_entry).
///
/// WHAT IS REAL HERE. The shipped `RecordingDeviceAttachment` over the same BLE seam
/// `CoreBluetoothCentral` wraps, the real `PocketBLEClient` handshake, the real
/// `PocketOnboardingCoordinator.restore`, the real `PocketRecordingDeviceBridge.observe`, the
/// real `RecordingDeviceAdoption.remember`, an account-scoped `RecordingDeviceStore` in a
/// sandboxed container, and the shipped `PocketSessionKeyEntryPresentation` copy. Injected:
/// the radio and the secret store, the two things a hermetic suite cannot own.
///
/// THE TWO SCENARIOS THAT CARRY THE MOST WEIGHT ARE THE NEGATIVE ONES. "A malformed key is
/// refused before the recorder is sent a single byte" is checked against the transport's own
/// record of every `APP&…` command it received — and closed against vacuity by submitting a
/// WELL-FORMED key at the end of the same scenario and watching that record fill. "The key
/// reaches no log, error, or diagnostic" redirects the process's own stdout and stderr into a
/// file for the duration of the submission and searches the result, alongside the `DoorLog`
/// the attachment writes to and every string the outcome and the screen can render.
final class PocketExistingKeyEntryFeatureTests: ProcessGlobalStateTestCase {

    @MainActor
    func testPocketExistingKeyEntryFeature() async throws {
        let world = try ExistingKeyEntryWorld()
        do {
            let result = try await BrineFeatureRunner.run(
                "pocket-existing-key-entry",
                registry: StepRegistry(ExistingKeyEntrySteps.make(world: world)))
            // Pin the POPULATION: the runner asserts only that nothing FAILED, so deleting a
            // scenario would otherwise leave this suite green.
            XCTAssertEqual(result.passed, 8,
                           "pocket-existing-key-entry must run all 8 scenarios — one per "
                               + "acceptance criterion in the track spec: the key is kept and "
                               + "the recorder is adopted, a malformed key writes zero bytes, "
                               + "a refused key is not a link failure, the key reaches no "
                               + "output, the guidance names both capture routes, and the "
                               + "setup-unavailable screen still stands — plus the two the "
                               + "security review added: a refused key is undone so a typo is "
                               + "survivable, and the key is never on screen in the clear")
        } catch {
            world.cleanup()
            throw error
        }
        world.cleanup()
    }

    // MARK: unit — the validator is the SHIPPED one, and it is total

    /// The field may not accept anything custody will later reject, and may not reject
    /// anything custody would have kept. Held as an equivalence over both predicates rather
    /// than as two independently-drifting spellings of "16 ASCII bytes".
    func testTheFieldValidatorIsTheSamePredicateCustodyEnforces() {
        let candidates = [
            "", " ", "short", "0123456789abcde", "0123456789abcdef", "0123456789abcdefg",
            "A!b2-C_d.E?9+x=Z", "  A!b2-C_d.E?9+x=Z  ", "0123456789abcde\u{00E9}",
            "🔑🔑🔑🔑🔑🔑🔑🔑", "0123456789abcdef\n",
        ]
        var accepted = 0
        for candidate in candidates {
            let normalised = PocketSessionKey.normalised(candidate)
            let wellFormed = PocketSessionKey.defect(in: candidate) == nil
            XCTAssertEqual(wellFormed, PocketSecretRecord.isValid(normalised),
                           "the entry field and the Keychain seam disagree about a candidate — "
                               + "a field that accepts what `save` will refuse is a field that "
                               + "sends a recorder a key it can never store")
            if wellFormed { accepted += 1 }
        }
        XCTAssertEqual(accepted, 4,
                       "the fixture no longer contains well-formed candidates, so the "
                           + "equivalence above is being satisfied by rejecting everything")
    }

    /// A defect must SAY WHICH. Held over every case, so a new one cannot ship wordless.
    func testEveryRejectionSaysWhatIsWrongAndThatNothingWasSent() {
        let defects: [PocketSessionKeyDefect] = [.empty, .wrongLength(0), .wrongLength(17),
                                                 .notPlainText]
        for defect in defects {
            let line = PocketSessionKeyEntryPresentation.line(for: defect)
            XCTAssertFalse(line.isEmpty, "\(defect) renders nothing at all")
            XCTAssertTrue(line.contains("hasn't sent the recorder anything"),
                          "\"\(line)\" refuses a key without saying the one thing that is "
                              + "knowable and reassuring — that the recorder was untouched")
        }
        XCTAssertTrue(PocketSessionKeyEntryPresentation.line(for: .wrongLength(17)).contains("17"),
                      "a wrong-length refusal does not say how many characters were entered, "
                          + "which is the whole of \"say which\"")
    }

    /// A REFUSED KEY IS NOT A LINK FAILURE. The two lines must be different sentences, and the
    /// refusal may not borrow the vocabulary of a connection problem.
    func testARefusedKeyAndABrokenLinkAreDifferentSentences() {
        let refused = PocketSessionKeyEntryPresentation.refusedByRecorderLine
        let link = PocketSessionKeyEntryPresentation.linkFailedLine
        XCTAssertNotEqual(refused, link)
        for phrase in ["not connected", "couldn't reach", "closer", "out of range"] {
            XCTAssertFalse(refused.lowercased().contains(phrase),
                           "\"\(refused)\" says \"\(phrase)\" — the link was fine, and telling "
                               + "someone to move closer when the recorder refused their key "
                               + "is the collapse this criterion exists to prevent")
        }
        XCTAssertTrue(refused.lowercased().contains("refused"))
    }

    /// THE APP MUST ACTUALLY REACH THE ENTRY PATH. `swift test` cannot compile `App/`, so
    /// nothing else connects "the coordinator works" to "a person can get to it" — which is
    /// precisely how `provisionFactoryFresh` and `RecordingDeviceAdoption.remember` each
    /// shipped with zero non-test callers.
    func testTheSetupUnavailableScreenActuallyReachesTheKeyEntryPath() throws {
        let device = try Self.appFile("App/DeviceScreen.swift")
        XCTAssertTrue(device.contains("PocketSessionKeyEntryCoordinator"),
                      "nothing in the Devices screen builds the key-entry coordinator, so a "
                          + "key typed into the field could not reach custody or the chain")
        XCTAssertTrue(device.contains("PocketSessionKeyEntryPresentation"),
                      "the outcome of a submitted key is being worded in the view instead of "
                          + "in the kit, where it can be asserted")
        XCTAssertTrue(device.contains("PocketOnboardingView(screen: .setupUnavailable)"),
                      "the §3.6 screen is no longer reachable from the connect sheet")

        let onboarding = try Self.appFile("App/PocketOnboardingView.swift")
        XCTAssertTrue(onboarding.contains("enterExistingKey"),
                      "the onboarding view renders no key-entry screen")
        XCTAssertTrue(onboarding.contains("PocketSessionKeyEntryPresentation.sections"),
                      "the guidance is being retyped in the view rather than drawn from the "
                          + "presentation type the feature asserts")
    }

    /// CREDENTIAL HYGIENE, HELD STATICALLY OVER `App/` TOO. A key that never reaches a log in
    /// the kit can still be printed by a view, and no kit test would see it.
    func testNoAppSideFileLogsOrPrintsTheKeyItHolds() throws {
        let loggers = ["print(", "NSLog(", "os_log", "debugPrint(", ".info(", ".warn(",
                       ".error(", "logger."]
        for url in try AppSourceTree.appSideSwiftFiles() {
            let text = AppSourceTree.withoutComments(
                of: try String(contentsOf: url, encoding: .utf8))
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let statement = String(line)
                guard loggers.contains(where: { statement.contains($0) }) else { continue }
                for holder in ["sessionKey", "candidateKey", "enteredKey"] {
                    XCTAssertFalse(statement.contains(holder),
                                   "\(AppSourceTree.relativePath(url)) puts `\(holder)` into a "
                                       + "logging call: \(statement.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }

    // MARK: unit — what custody leaves in CLEARTEXT

    /// ON iOS ONLY `kSecValueData` IS ENCRYPTED. Attributes — `kSecAttrGeneric` among them —
    /// live in the keychain database's cleartext metadata. This item used to bind itself
    /// together with an unsalted `SHA256(secret)` written into exactly that attribute, so the
    /// digest of a 16-character credential was recoverable precisely where the credential was
    /// not, and its brute-force cost depended entirely on the vendor's key alphabet — the one
    /// thing that is unevidenced, and the reason `provisionFactoryFresh` is gated at all.
    func testTheCleartextHalfOfTheRecordIsDerivedFromNothing() {
        let secret = "Zq7!vK3-wR9_pL2x"
        let tags = (0..<64).map { _ in PocketSecretRecord.newTag() }
        for tag in tags {
            XCTAssertEqual(tag.count, PocketSecretRecord.tagLength)
            XCTAssertFalse(tag.allSatisfy { $0 == 0 }, "the tag is all zeroes, so it binds nothing")
        }
        XCTAssertEqual(Set(tags).count, tags.count,
                       "two saves produced the same tag, so it is not random")

        // THE PROPERTY THAT MATTERS: the cleartext half must not be a function of the secret.
        // A digest would make these two equal.
        let first = PocketSecretRecord.newTag()
        let second = PocketSecretRecord.newTag()
        XCTAssertNotEqual(first, second,
                          "the same secret produces the same cleartext attribute twice, which "
                              + "is what a digest of the secret does — and what makes the "
                              + "attribute worth attacking")

        // And the binding still binds: a blob that does not carry the tag is refused.
        let encoded = PocketSecretRecord.encode(secret: secret, tag: first)
        XCTAssertEqual(PocketSecretRecord.decode(encoded, tag: first), secret)
        XCTAssertNil(PocketSecretRecord.decode(encoded, tag: second),
                     "a value blob decoded against the wrong tag was accepted, so the "
                         + "integrity binding does nothing")
        XCTAssertNil(PocketSecretRecord.decode(encoded.dropLast(), tag: first),
                     "a truncated value blob was accepted")
        XCTAssertFalse(encoded.prefix(PocketSecretRecord.tagLength).elementsEqual(Data(secret.utf8).prefix(PocketSecretRecord.tagLength)),
                       "the blob leads with the secret rather than the tag")
    }

    /// THE RECORDER CREDENTIAL DOES NOT GO TO iCLOUD. It used to set
    /// `kSecAttrSynchronizable: true`, replicating the key to iCloud Keychain and to every
    /// device on the Apple ID — keyed by `filePull/<CoreBluetooth peripheral UUID>`, an
    /// identifier generated per device PER APP, so the synced copy is unreachable on any other
    /// device by construction. It bought nothing and put the key in Apple's escrow and in
    /// every keychain backup. Synchronizable items may also not be `…ThisDeviceOnly`, which is
    /// why this was the only Keychain writer in the app on a weakened accessibility class.
    func testTheRecorderCredentialIsDeviceOnlyAndNotSynchronised() throws {
        let url = AppSourceTree.repoRoot
            .appendingPathComponent("Sources/FoundryXKit/PocketOnboarding.swift")
        let code = AppSourceTree.code(of: try String(contentsOf: url, encoding: .utf8))
        XCTAssertFalse(code.contains("kSecAttrSynchronizable as String: kCFBooleanTrue"),
                       "the recorder's session key is written as a synchronizable item, so it "
                           + "replicates to iCloud Keychain and to devices where its "
                           + "peripheral-UUID account name can never match")
        XCTAssertTrue(code.contains("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"),
                      "the key is stored on an accessibility class that leaves the device")
        XCTAssertTrue(code.contains("SecItemDelete"),
                      "`PocketSecretStore` still cannot delete, so a key the recorder refuses "
                          + "is permanent for that peripheral")
        XCTAssertTrue(code.contains("kSecAttrSynchronizableAny"),
                      "the read and delete queries no longer match an item a previous build "
                          + "synced, so such an item is stranded rather than replaced")
    }

    /// FORGETTING IS PART OF THE CONTRACT, held on the PROTOCOL rather than on one store: a
    /// conformer that cannot delete is a conformer that turns a typo into a permanent one.
    func testCustodyCanForgetAKeyItWasGiven() async throws {
        let store = InMemoryPocketSecretStore()
        let identity = try PocketAuthenticatedIdentity(
            peripheralIdentifier: "3AB19F42-2C71-4E0D-9F41-6D2B8A5C7E10")
        try await store.save("Zq7!vK3-wR9_pL2x", for: identity)
        let held = await store.secret(for: identity)
        XCTAssertNotNil(held, "the store did not keep the key, so removing it proves nothing")
        try await store.remove(for: identity)
        let after = await store.secret(for: identity)
        XCTAssertNil(after, "custody kept a key it was told to forget")
        // Removing an absent key is a success: the caller wants it gone, and it is.
        try await store.remove(for: identity)
    }

    private static func appFile(_ relative: String) throws -> String {
        let url = AppSourceTree.repoRoot.appendingPathComponent(relative)
        return AppSourceTree.withoutComments(of: try String(contentsOf: url, encoding: .utf8))
    }
}

// MARK: - World

@MainActor
private final class ExistingKeyEntryWorld {

    private let token = UUID().uuidString
    private let sandbox: URL
    private let container: URL
    private let scopeDefaultsName: String
    private let legacyDefaultsName: String
    private let scopeDefaults: UserDefaults
    private let legacyDefaults: UserDefaults

    /// The recorder the OTHER app already provisioned. `acceptedSecret` is the key it was set
    /// up with, and it is the only key its firmware answers `MCU&SK&OK` to.
    private var stack: FakePocketBLEStack?
    private var secrets = InMemoryPocketSecretStore()
    /// The log the shipped attachment writes to, so "no log line carries the key" is a claim
    /// about the app's own logging seam rather than about a sink the test invented.
    private var log = DoorLog()
    private var outcome: PocketSessionKeyEntryOutcome?
    private var lastDefectLine: String?
    private var linkFailureOutcome: PocketSessionKeyEntryOutcome?
    private var capturedOutput: String?
    private var storedSecretMatched: Bool?
    private var scenario = 0

    private static let recorderName = "PKT07_BLUE_3ab19f42"
    private static let recorderId = UUID(uuidString: "3AB19F42-2C71-4E0D-9F41-6D2B8A5C7E10")!
    /// A recorder id the radio cannot hand back, which is how a genuine LINK failure is
    /// produced through the shipped code rather than by stubbing an outcome.
    private static let unreachableId = UUID(uuidString: "0000DEAD-2C71-4E0D-9F41-6D2B8A5C7E10")!

    /// The key the other app set this recorder up with. Sixteen ASCII characters, distinctive
    /// enough that a substring search over captured output means something.
    private static let provisionedKey = "Zq7!vK3-wR9_pL2x"
    /// Well formed and simply not this recorder's key.
    private static let wrongKey = "Aa1@Bb2#Cc3$Dd4%"

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-existing-key-entry-\(token)", isDirectory: true)
        container = sandbox.appendingPathComponent("documents/foundryx-captures", isDirectory: true)
        scopeDefaultsName = "foundryx.existing-key-entry.scope.\(token)"
        legacyDefaultsName = "foundryx.existing-key-entry.legacy.\(token)"
        guard let scope = UserDefaults(suiteName: scopeDefaultsName),
              let legacy = UserDefaults(suiteName: legacyDefaultsName) else {
            throw BrineStepError("could not create isolated UserDefaults suites")
        }
        scopeDefaults = scope
        legacyDefaults = legacy
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        CaptureAccountScope.setContainerForTests(container)
        CaptureAccountScope.setApplicationSupportRootForTests(
            sandbox.appendingPathComponent("application-support", isDirectory: true))
        CaptureAccountScope.setDefaultsForTests(scopeDefaults)
    }

    func cleanup() {
        try? CaptureAccountScope.signOutForTests()
        CaptureAccountScope.resetTestEnvironment()
        scopeDefaults.removePersistentDomain(forName: scopeDefaultsName)
        legacyDefaults.removePersistentDomain(forName: legacyDefaultsName)
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: Given

    func given(_ phrase: String) async throws {
        outcome = nil
        lastDefectLine = nil
        linkFailureOutcome = nil
        capturedOutput = nil
        storedSecretMatched = nil
        switch phrase {
        case "a signed-in account and a recorder that was set up by another app":
            // A FRESH ACCOUNT PER SCENARIO. `RecordingDeviceStore` is account-scoped, so a
            // shared sign-in would let the scenario that adopts the recorder satisfy the two
            // scenarios that assert the account remembers NOTHING.
            scenario += 1
            CaptureAccountScope.setAccountForTests(
                email: "existing-key-\(token)-\(scenario)@example.com")
            guard let binding = CaptureAccountScope.currentAccountBinding(),
                  binding.scope != CaptureAccountScope.signedOutScope else {
                throw BrineStepError("signing in did not leave the signed-out scope")
            }
            stack = FakePocketBLEStack(deviceId: Self.recorderId,
                                       deviceName: Self.recorderName,
                                       acceptedSecret: Self.provisionedKey)
            // EMPTY ON PURPOSE. FoundryX holds no key for this recorder — which, until §3.6
            // lifts, is the state every recorder in the world is in.
            secrets = InMemoryPocketSecretStore()
            log = DoorLog()

        case "the shipped key-entry guidance":
            break

        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    // MARK: When (the chain is asynchronous end to end — a radio, a handshake, a keychain)

    func whenAsync(_ phrase: String) async throws {
        switch phrase {
        case "I enter the key that recorder was set up with":
            outcome = await submit(Self.provisionedKey)

        case "I enter a key that is the wrong length":
            outcome = await submit(String(Self.provisionedKey.dropLast()))
            lastDefectLine = PocketSessionKeyEntryPresentation.line(for: outcome!)

        case "I enter a key that is not plain text":
            outcome = await submit("Zq7!vK3-wR9_pL2\u{00E9}")
            lastDefectLine = PocketSessionKeyEntryPresentation.line(for: outcome!)

        case "I enter a well-formed key that recorder was not set up with":
            outcome = await submit(Self.wrongKey)

        case "I enter the key that recorder was set up with while every output is captured":
            capturedOutput = await captureProcessOutput {
                self.outcome = await self.submit(Self.provisionedKey)
            }
            try await settle()
            capturedOutput = (capturedOutput ?? "") + "\n" + log.dump()

        case "I tap that recorder without entering a key":
            // THE SHIPPED TAP, UNCHANGED. No key is submitted, so this must still land on the
            // §3.6 screen exactly as it did before this track existed.
            guard let stack else { throw BrineStepError("no recorder was staged") }
            // `recovery: nil` KEEPS THIS HERMETIC. With no attach record, `restore` now
            // consults the SYNCHRONISED recovery record — a real Keychain item under the
            // shipped default — and this scenario's claim is about a phone that holds nothing
            // for this recorder at all.
            let attachment = RecordingDeviceAttachment(
                makeCentral: stack.factory, secrets: secrets, recovery: nil,
                deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 5), log: log)
            let attached = await attachment.attach(peripheralIdentifier: stack.deviceId,
                                                   advertisedName: stack.deviceName)
            guard attached == .setupUnavailable else {
                throw BrineStepError("a recorder FoundryX holds no key for produced "
                                         + String(describing: attached))
            }

        default:
            throw BrineStepError("unhandled async When: \(phrase)")
        }
    }

    /// The production coordinator, over the production attachment, over the fake radio. The
    /// ONLY injected things are the radio and the secret store.
    private func submit(_ key: String,
                        peripheralIdentifier: UUID? = nil) async -> PocketSessionKeyEntryOutcome {
        guard let stack else { return .linkFailed("no recorder was staged") }
        let coordinator = PocketSessionKeyEntryCoordinator.live(
            secrets: secrets,
            makeCentral: stack.factory,
            deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 5),
            log: log)
        return await coordinator.submit(key: key,
                                        peripheralIdentifier: peripheralIdentifier
                                            ?? stack.deviceId,
                                        advertisedName: stack.deviceName)
    }

    // MARK: Then

    func then(_ phrase: String) async throws {
        switch phrase {

        // ── the key is kept and the recorder is adopted ──────────────────────
        case "FoundryX keeps that key in secure custody":
            let identity = try PocketAuthenticatedIdentity(
                peripheralIdentifier: Self.recorderId.uuidString)
            let stored = await secrets.secret(for: identity)
            storedSecretMatched = stored == Self.provisionedKey
            XCTAssertEqual(storedSecretMatched, true,
                           "the key the owner entered is not in custody, so the recorder would "
                               + "have to be set up again on every launch. (The value itself is "
                               + "deliberately not printed here.)")

        case "the recorder is adopted through the shipped chain":
            guard case .adopted(let identity, let displayName, let negotiated) = outcome else {
                throw BrineStepError("entering the recorder's own key produced "
                                         + String(describing: outcome)
                                         + " instead of adopting it")
            }
            XCTAssertEqual(identity.shape, .filePull,
                           "the adopted device is not a stored-file recorder")
            XCTAssertEqual(displayName, Self.recorderName)
            XCTAssertEqual(negotiated, PocketRecordingDeviceBridge.protocolIdentifier,
                           "the class came from something other than the protocol the "
                               + "transport actually negotiated")
            guard let stack else { throw BrineStepError("no recorder was staged") }
            XCTAssertTrue(stack.commandsWritten.contains { $0.hasPrefix("SK&") },
                          "nothing was ever offered to the recorder, so \"adopted\" is being "
                              + "decided without a handshake: \(stack.commandsWritten)")
            XCTAssertTrue(stack.commandsWritten.contains("BAT"),
                          "the shipped chain reads battery and firmware after the key is "
                              + "accepted, and this run read neither — the adoption did not "
                              + "come through `PocketOnboardingCoordinator.restore`")

        case "the redrawn list shows it as a peer row reading \"Records on its own · Not connected\"":
            let remembered = UnifiedDeviceListComposition.rememberedForCurrentAccount(
                defaults: legacyDefaults)
            let rows = UnifiedDeviceListPresentation.rows(
                UnifiedDeviceListComposition.inputs(remembered: remembered, captureSources: []))
            XCTAssertEqual(rows.map(\.detailLine), ["Records on its own · Not connected"],
                           "entering the key did not put the recorder into the unified list — "
                               + "rows: \(rows.map(\.displayName))")
            XCTAssertEqual(rows.first?.displayName, Self.recorderName)

        // ── a malformed key writes zero bytes ────────────────────────────────
        case "FoundryX sent that recorder nothing at all":
            guard let stack else { throw BrineStepError("no recorder was staged") }
            XCTAssertEqual(stack.commandsWritten, [],
                           "\"FoundryX hasn't sent the recorder anything\" is a claim this "
                               + "refusal makes, and this path wrote \(stack.commandsWritten) "
                               + "to the device")
            XCTAssertFalse(stack.isConnected,
                           "the app opened a link to the recorder to refuse a key it could "
                               + "judge without one")

        case "it tells me a session key is sixteen characters and how many I entered":
            guard case .malformed(.wrongLength(let count)) = outcome else {
                throw BrineStepError("a short key produced " + String(describing: outcome))
            }
            XCTAssertEqual(count, 15)
            let line = try XCTUnwrap(lastDefectLine)
            XCTAssertTrue(line.contains("16") && line.contains("15"),
                          "\"\(line)\" does not say what a key is and what was entered")

        case "nothing was written to secure custody either":
            let identity = try PocketAuthenticatedIdentity(
                peripheralIdentifier: Self.recorderId.uuidString)
            let stored = await secrets.secret(for: identity)
            XCTAssertNil(stored,
                         "a refused candidate reached the Keychain seam — the refusal is "
                             + "supposed to happen before anything is persisted")

        case "it tells me the key has characters the recorder's protocol cannot carry":
            guard case .malformed(.notPlainText) = outcome else {
                throw BrineStepError("a non-ASCII key produced " + String(describing: outcome))
            }
            let line = try XCTUnwrap(lastDefectLine)
            XCTAssertTrue(line.contains("plain text"),
                          "\"\(line)\" does not say what is wrong with the characters")

        case "a well-formed key does reach the recorder, so this refusal is not vacuous":
            // NON-VACUITY. Every "zero bytes" claim above is worthless unless this same
            // transport records a write when the candidate IS well formed.
            guard let stack else { throw BrineStepError("no recorder was staged") }
            let accepted = await submit(Self.provisionedKey)
            guard case .adopted = accepted else {
                throw BrineStepError("a well-formed key produced " + String(describing: accepted))
            }
            XCTAssertTrue(stack.commandsWritten.contains { $0.hasPrefix("SK&") },
                          "even a well-formed key wrote nothing, so the transport under test "
                              + "records no writes at all and every zero-bytes assertion in "
                              + "this scenario is vacuous")

        // ── refused is not the same as unreachable ───────────────────────────
        case "the recorder was asked and refused it":
            guard let stack else { throw BrineStepError("no recorder was staged") }
            XCTAssertTrue(stack.commandsWritten.contains { $0.hasPrefix("SK&") },
                          "a well-formed key was never offered to the recorder, so \"refused\" "
                              + "is being decided without asking: \(stack.commandsWritten)")
            XCTAssertFalse(stack.commandsWritten.contains("BAT"),
                           "the chain kept going after the recorder said no")

        case "FoundryX says the recorder refused that key":
            XCTAssertEqual(outcome, .refusedByRecorder,
                           "a key the recorder said no to produced "
                               + String(describing: outcome))
            XCTAssertEqual(PocketSessionKeyEntryPresentation.line(for: outcome!),
                           PocketSessionKeyEntryPresentation.refusedByRecorderLine)

        case "that is a different answer from the one a recorder it cannot reach produces":
            // A REAL LINK FAILURE THROUGH THE REAL CODE: a peripheral the central cannot hand
            // back. Nothing here is stubbed, so the two answers diverge inside the shipped
            // attachment rather than in the test's imagination.
            let unreachable = await submit(Self.wrongKey,
                                           peripheralIdentifier: Self.unreachableId)
            linkFailureOutcome = unreachable
            guard case .linkFailed = unreachable else {
                throw BrineStepError("a recorder the radio cannot hand back produced "
                                         + String(describing: unreachable))
            }
            XCTAssertNotEqual(PocketSessionKeyEntryPresentation.line(for: unreachable),
                              PocketSessionKeyEntryPresentation.line(for: .refusedByRecorder),
                              "a refused key and an unreachable recorder read the same — the "
                                  + "one distinction this criterion exists to hold")

        case "it never tells me the recorder is not connected":
            let line = PocketSessionKeyEntryPresentation.refusedByRecorderLine
            for phrase in ["not connected", "couldn't reach", "bring it closer"] {
                XCTAssertFalse(line.lowercased().contains(phrase),
                               "\"\(line)\" says \"\(phrase)\" — the link was fine and the "
                                   + "recorder refused the key")
            }
            XCTAssertTrue(PocketSessionKeyEntryPresentation.linkFailedLine
                .lowercased().contains("couldn't reach"),
                          "the link-failure line no longer describes a link failure, so the "
                              + "assertion above is vacuous")

        case "the account does not remember that recorder":
            let identity = try PocketAuthenticatedIdentity(
                peripheralIdentifier: Self.recorderId.uuidString).recordingDeviceIdentity
            let records = UnifiedDeviceListComposition.rememberedForCurrentAccount(
                defaults: legacyDefaults)
            XCTAssertFalse(records.contains { $0.identity == identity },
                           "a recorder that refused the key was added to the account anyway")

        // ── a refused key is undone, so a typo is survivable ─────────────────
        case "the key the recorder refused is not left in secure custody":
            // THE KEY HAD TO GO IN BEFORE THE RECORDER COULD BE ASKED — `restore` reads
            // custody to decide what to send — so this is about it coming back OUT. Left in
            // place, every later tap restores the refused key, is refused again, and returns
            // `.recoveryRequired` rather than `.setupUnavailable`, which is the state the
            // entry field used to be unreachable from.
            XCTAssertEqual(outcome, .refusedByRecorder,
                           "this step is checking the cleanup after a refusal and the "
                               + "submission produced " + String(describing: outcome))
            let identity = try PocketAuthenticatedIdentity(
                peripheralIdentifier: Self.recorderId.uuidString)
            let stored = await secrets.secret(for: identity)
            XCTAssertNil(stored,
                         "the key the recorder rejected is still in custody. One mistyped "
                             + "character would be permanent: the wrong key is what every "
                             + "later attach restores and offers")

        case "the screen a refused key lands on still offers to let me enter a key":
            // A REFUSAL IS NOT A DEAD END. `RecordingDeviceAttachment` answers a refused key
            // with `.recoveryRequired`, which the Devices screen shows as `didNotFinish`. If
            // the only action there is "Try again" — which closes the sheet — the person who
            // mistyped a character has no way back to the field at all.
            XCTAssertTrue(
                PocketSetupPresentation.didNotFinish.actions
                    .contains(PocketSessionKeyEntryPresentation.entryAction),
                "the screen a refused key lands on offers "
                    + "\(PocketSetupPresentation.didNotFinish.actions) and no way back to the "
                    + "field, so a single typo locks the recorder out of the only path that "
                    + "could correct it")
            XCTAssertEqual(PocketSetupPresentation.didNotFinish.actions.first, "Try again",
                           "the shipped first action was displaced")

        // ── the key is never on screen in the clear ──────────────────────────
        case "the field hides the key as I type it":
            let view = try Self.appFile("App/PocketOnboardingView.swift")
            XCTAssertTrue(view.contains("SecureField(PocketSessionKeyEntryPresentation.fieldPrompt"),
                          "the session key is typed into a plain field. A credential in "
                              + "cleartext is read aloud by VoiceOver, captured by screen "
                              + "recording and mirroring, and photographed into the window "
                              + "snapshot iOS writes on every backgrounding")
            XCTAssertFalse(view.contains("TextField(PocketSessionKeyEntryPresentation"),
                           "a plain TextField still renders the key somewhere on this screen")
            XCTAssertTrue(view.contains(".privacySensitive()"),
                          "the field is not marked privacy sensitive, so no container "
                              + "redaction can ever reach it")

        case "the screen is covered before the app is put in the background":
            let view = try Self.appFile("App/PocketOnboardingView.swift")
            XCTAssertTrue(view.contains("Environment(\\.scenePhase)"),
                          "nothing on this screen observes the scene phase, so the snapshot "
                              + "iOS writes to disk on backgrounding contains the field")
            XCTAssertTrue(view.contains("scenePhase != .active"),
                          "the cover is keyed to something other than \"not frontmost\". iOS "
                              + "takes its window picture as the app goes INACTIVE, so a "
                              + "cover that waits for .background is already too late")

        case "the field does not hand what I type to a third-party keyboard":
            let view = try Self.appFile("App/PocketOnboardingView.swift")
            // Secure entry is the ONLY thing that makes iOS fall back to the system keyboard.
            // A keyboard extension with Full Access has network, and would otherwise receive
            // all 16 characters.
            XCTAssertTrue(view.contains("SecureField"),
                          "without secure entry every character reaches whatever keyboard "
                              + "extension is installed")
            XCTAssertTrue(view.contains(".textContentType(.password)"),
                          "the field does not opt out of keyboard learning")
            XCTAssertTrue(view.contains(".keyboardType(.asciiCapable)"),
                          "the field can produce characters the recorder's protocol cannot "
                              + "carry, which is a refusal the person cannot see coming")

        case "the field does not keep the key after it is submitted":
            let view = try Self.appFile("App/PocketOnboardingView.swift")
            XCTAssertTrue(view.contains("sessionKeyDraft = \"\""),
                          "the draft is never cleared, so the credential stays in view state "
                              + "for as long as the screen is up")

        case "it tells me how many characters I have entered without showing them":
            // The count is the only feedback secure entry leaves. It must be a COUNT.
            XCTAssertEqual(PocketSessionKeyEntryPresentation.progress(entered: 9),
                           "9 of 16 characters")
            XCTAssertFalse(
                PocketSessionKeyEntryPresentation.progress(entered: Self.provisionedKey.count)
                    .contains(Self.provisionedKey),
                "the progress line carries the candidate itself")
            let view = try Self.appFile("App/PocketOnboardingView.swift")
            XCTAssertTrue(view.contains("PocketSessionKeyEntryPresentation.progress(entered:"),
                          "the count is being worded in the view rather than in the kit, "
                              + "where it can be asserted")

        // ── credential hygiene ───────────────────────────────────────────────
        case "the key appears nowhere in the captured output":
            let captured = try XCTUnwrap(capturedOutput)
            XCTAssertFalse(captured.contains(Self.provisionedKey),
                           "the session key was written to stdout, stderr or the app's own "
                               + "DoorLog. It is a credential; it belongs in the Keychain and "
                               + "on the recorder's characteristic and nowhere else")

        case "the key appears in no outcome value the app can render or print":
            let rendered = [String(describing: outcome as Any),
                            String(reflecting: outcome as Any),
                            PocketSessionKeyEntryPresentation.line(for: outcome!) ?? ""]
                .joined(separator: "\n")
            XCTAssertFalse(rendered.contains(Self.provisionedKey),
                           "an outcome value carries the key, so any `print` of it anywhere "
                               + "in the app leaks the credential")
            for defect in [PocketSessionKeyDefect.empty, .wrongLength(15), .notPlainText] {
                XCTAssertFalse(
                    PocketSessionKeyEntryPresentation.line(for: defect)
                        .contains(Self.provisionedKey))
            }

        case "the key appears in no line this screen can display":
            let everything = (PocketSessionKeyEntryPresentation.everyLine
                + PocketSetupPresentation.all.flatMap { [$0.title, $0.body] + $0.actions })
                .joined(separator: "\n")
            XCTAssertFalse(everything.contains(Self.provisionedKey))
            XCTAssertFalse(everything.contains(Self.wrongKey))

        case "the captured output is not empty, so the search is not vacuous":
            let captured = try XCTUnwrap(capturedOutput)
            XCTAssertTrue(captured.contains("adopted a stored-file recorder"),
                          "the adoption produced no log line at all, so \"the key is not in "
                              + "the captured output\" is satisfied by there being no output. "
                              + "Captured: \(captured.count) characters")

        // ── the guidance ─────────────────────────────────────────────────────
        case "it states outright that the vendor app never shows the key":
            let body = PocketSessionKeyEntryPresentation.vendorAppDoesNotShowIt
            XCTAssertTrue(body.contains("never shows you this key"),
                          "the guidance does not say the one thing that saves someone hunting "
                              + "for a screen that does not exist: \"\(body)\"")
            XCTAssertTrue(Self.guidance.contains("no screen in it, or in Solleva"),
                          "the guidance implies there is a screen somewhere that displays the "
                              + "key")
            XCTAssertTrue(Self.guidance.contains("HCI"),
                          "the guidance does not say what the capture actually is")

        case "it names the macOS and iOS capture route":
            let route = PocketSessionKeyEntryPresentation.macCaptureRoute
            for term in ["PacketLogger", "Additional Tools for Xcode", "APP&SK&"] {
                XCTAssertTrue(route.contains(term),
                              "the macOS/iOS route does not name \(term): \"\(route)\"")
            }

        case "it names the Android capture route":
            let route = PocketSessionKeyEntryPresentation.androidCaptureRoute
            for term in ["Bluetooth HCI snoop log", "Developer Options", "btsnoop_hci.log",
                         "Wireshark"] {
                XCTAssertTrue(route.contains(term),
                              "the Android route does not name \(term): \"\(route)\"")
            }

        case "it rules out finding the key by sniffing the recorder":
            let line = PocketSessionKeyEntryPresentation.noShortcut
            XCTAssertTrue(line.lowercased().contains("sniff"),
                          "the shortcut people reach for first is not ruled out: \"\(line)\"")
            XCTAssertTrue(line.contains("the app writes"),
                          "the guidance rules the shortcut out without saying WHY it cannot "
                              + "work — the key is written by the app, not sent by the "
                              + "recorder: \"\(line)\"")

        case "it attributes the procedure to Pocket Libre's documentation":
            XCTAssertTrue(PocketSessionKeyEntryPresentation.attribution.contains("Pocket Libre"),
                          "the procedure is presented as FoundryX's own claim rather than "
                              + "attributed to the documentation it came from")

        case "it shows no example key and offers no way to reveal, copy, or export one":
            let all = Self.guidance.lowercased()
            for word in ["reveal", "copy", "share", "export"] {
                XCTAssertFalse(all.contains(word),
                               "the key-entry screen offers to \(word) a credential")
            }
            XCTAssertFalse(
                PocketSessionKeyEntryPresentation.fieldPrompt.count == 16
                    && PocketSessionKeyEntryPresentation.fieldPrompt.unicodeScalars
                        .allSatisfy(\.isASCII),
                "the field's placeholder is itself a well-formed 16-character key — a "
                    + "credential-shaped string people paste by accident")

        // ── a tap alone is still a dead stop, and still writes nothing ───────
        case "the app stops and explains instead of adding a row":
            // WHAT REPLACED §3.6. Minting is wired now, so "setup is turned off" would be a
            // false sentence. What a tap earns instead is the CONSENT screen: it explains what
            // Solleva will do, says outright that it cannot predict what an already-keyed
            // recorder does with a second key, and states the cost — and nothing is written
            // until the owner taps the confirm action on it.
            XCTAssertEqual(PocketMintConsentPresentation.actions.first,
                           PocketMintConsentPresentation.confirmAction,
                           "the decision screen no longer leads with the decision")
            XCTAssertTrue(PocketMintConsentPresentation.whatSollevaDoesNotKnow
                .lowercased().contains("can't tell you"),
                          "the consent screen no longer admits the thing that makes consent "
                              + "necessary — that nobody knows what an already-keyed recorder "
                              + "does with a second key")
            XCTAssertTrue(PocketMintConsentPresentation.whatItCouldCost.contains("other app"),
                          "the consent screen does not state the cost it is asking the owner "
                              + "to accept")
            XCTAssertTrue(PocketSetupPresentation.setupUnavailable.body.contains("sent it nothing"))
            let records = UnifiedDeviceListComposition.rememberedForCurrentAccount(
                defaults: legacyDefaults)
            XCTAssertTrue(records.isEmpty,
                          "a tap with no key entered added a row anyway: "
                              + "\(records.map(\.displayName))")

        case "the screen still offers to let me enter a key I already have":
            XCTAssertTrue(
                PocketMintConsentPresentation.actions
                    .contains(PocketSessionKeyEntryPresentation.entryAction),
                "the screen a tap lands on offers no way to enter an existing key, so the "
                    + "whole path is unreachable from the only screen a real tap reaches")
            XCTAssertTrue(
                PocketSetupPresentation.setupUnavailable.actions
                    .contains(PocketSessionKeyEntryPresentation.entryAction),
                "the help screen offers no way to enter an existing key either")
            XCTAssertEqual(PocketSetupPresentation.setupUnavailable.actions.first,
                           "See what's connected",
                           "the shipped first action was displaced")

        case "no key is minted without an explicit confirmation from me":
            // THE GATE THIS TRACK MUST NOT LOSE — RE-AIMED, NOT RELAXED.
            //
            // It used to read "`provisionFactoryFresh` has zero callers", which was the right
            // gate while minting was disabled and is a vacuous one now that minting is the
            // feature. The invariant that actually protects the owner is that a mint cannot
            // happen without their confirmation, and it is held here in three places at once:
            //
            //   1. AT RUNTIME. This scenario just ran the shipped `RecordingDeviceAttachment`
            //      over a real handshake with no consent, and the transport's own record of
            //      every `APP&…` byte is asserted empty by the step below.
            //   2. IN THE TYPE SYSTEM. `PocketMintConsent` has no public initialiser and one
            //      factory, so no call site can conjure one; `attach`'s `mint:` parameter
            //      defaults to nil, so no call site can mint by omission.
            //   3. IN `App/`. The consent value may be constructed in exactly ONE place, and
            //      that place must be the confirm action's own handler.
            let minting = try Self.appSideConsentConstructionSites()
            XCTAssertEqual(minting.count, 1,
                           "owner consent for a key mint is constructed in \(minting.count) "
                               + "places — \(minting). Exactly one screen may be able to "
                               + "authorise writing a key to somebody's recorder")
            let screen = try Self.appFile("App/DeviceScreen.swift")
            XCTAssertTrue(
                screen.contains("case PocketMintConsentPresentation.confirmAction:\n")
                    || screen.contains("PocketMintConsentPresentation.confirmAction"),
                "nothing in the Devices screen routes the consent screen's confirm action, so "
                    + "either the mint is unreachable or it is reached by something else")
            XCTAssertFalse(screen.contains("mint: .ownerConfirmedAfterReadingTheConsequences()\n            }"),
                           "a mint is being issued outside the confirmation handler")

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    private static var guidance: String {
        PocketSessionKeyEntryPresentation.everyLine.joined(separator: "\n")
    }

    /// An app-side file with its comments stripped. `swift test` cannot compile `App/`, so the
    /// only way to hold a claim about what the SCREEN does is to read what it says.
    private static func appFile(_ relative: String) throws -> String {
        let url = AppSourceTree.repoRoot.appendingPathComponent(relative)
        return AppSourceTree.withoutComments(of: try String(contentsOf: url, encoding: .utf8))
    }

    /// Every `App/` file that can CONSTRUCT owner consent for a key mint — which, because
    /// `PocketMintConsent` has no public initialiser, is every place in the rendered app that
    /// is able to authorise writing a key to a recorder.
    ///
    /// It is deliberately a count of construction SITES rather than of files: two call sites in
    /// one file is still two ways to mint.
    private static func appSideConsentConstructionSites() throws -> [String] {
        var sites: [String] = []
        for url in try AppSourceTree.appSideSwiftFiles() {
            let text = AppSourceTree.withoutComments(
                of: try String(contentsOf: url, encoding: .utf8))
            let needle = "ownerConfirmedAfterReadingTheConsequences()"
            var searched = text[...]
            while let found = searched.range(of: needle) {
                sites.append(AppSourceTree.relativePath(url))
                searched = searched[found.upperBound...]
            }
        }
        return sites
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

// MARK: - Steps

private enum ExistingKeyEntrySteps {
    static func make(world: ExistingKeyEntryWorld) -> [StepDefinition] {
        let givens = [
            "a signed-in account and a recorder that was set up by another app",
            "the shipped key-entry guidance",
        ]
        let asyncWhens = [
            "I enter the key that recorder was set up with",
            "I enter a key that is the wrong length",
            "I enter a key that is not plain text",
            "I enter a well-formed key that recorder was not set up with",
            "I enter the key that recorder was set up with while every output is captured",
            "I tap that recorder without entering a key",
        ]
        let thens = [
            "FoundryX keeps that key in secure custody",
            "the recorder is adopted through the shipped chain",
            "the redrawn list shows it as a peer row reading \"Records on its own · Not connected\"",
            "FoundryX sent that recorder nothing at all",
            "it tells me a session key is sixteen characters and how many I entered",
            "nothing was written to secure custody either",
            "it tells me the key has characters the recorder's protocol cannot carry",
            "a well-formed key does reach the recorder, so this refusal is not vacuous",
            "the recorder was asked and refused it",
            "FoundryX says the recorder refused that key",
            "that is a different answer from the one a recorder it cannot reach produces",
            "it never tells me the recorder is not connected",
            "the account does not remember that recorder",
            "the key the recorder refused is not left in secure custody",
            "the screen a refused key lands on still offers to let me enter a key",
            "the field hides the key as I type it",
            "the screen is covered before the app is put in the background",
            "the field does not hand what I type to a third-party keyboard",
            "the field does not keep the key after it is submitted",
            "it tells me how many characters I have entered without showing them",
            "the key appears nowhere in the captured output",
            "the key appears in no outcome value the app can render or print",
            "the key appears in no line this screen can display",
            "the captured output is not empty, so the search is not vacuous",
            "it states outright that the vendor app never shows the key",
            "it names the macOS and iOS capture route",
            "it names the Android capture route",
            "it rules out finding the key by sniffing the recorder",
            "it attributes the procedure to Pocket Libre's documentation",
            "it shows no example key and offers no way to reveal, copy, or export one",
            "the app stops and explains instead of adding a row",
            "the screen still offers to let me enter a key I already have",
            "no key is minted without an explicit confirmation from me",
        ]
        var steps = givens.map { phrase in
            defineStep(phrase) { context, _, _ in
                try await world.given(phrase)
                return context
            }
        }
        steps += asyncWhens.map { phrase in
            defineStep(phrase) { context, _, _ in
                try await world.whenAsync(phrase)
                return context
            }
        }
        steps += thens.map { phrase in
            defineCheck(phrase) { _, _, _ in
                try await world.then(phrase)
            }
        }
        return steps
    }
}
