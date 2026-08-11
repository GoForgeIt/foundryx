import Foundation
#if canImport(Security)
import Security
#endif

/// The identity shared by Pocket custody and the device list. Neither component is display data.
public struct PocketAuthenticatedIdentity: Hashable, Sendable, Codable {
    public let peripheralIdentifier: String

    /// This is deliberately constructible from discovery state on a cold launch.
    /// The session secret is record data, never part of the record's address.
    public init(peripheralIdentifier: String) throws {
        let peripheral = peripheralIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peripheral.isEmpty else {
            throw PocketIdentityError.missingOrInvalidComponent
        }
        self.peripheralIdentifier = peripheral.lowercased()
    }

    public var recordingDeviceIdentity: RecordingDeviceIdentity {
        RecordingDeviceIdentity(shape: .filePull, hardwareToken: peripheralIdentifier)
    }

    public var storageKey: String { recordingDeviceIdentity.storageKey }
}

public enum PocketIdentityError: Error, Equatable, Sendable {
    case missingOrInvalidComponent
    case mismatchedComponents
}

public enum PocketSecretStoreError: Error, Equatable, Sendable { case unavailable }

public protocol PocketSecretStore: Sendable {
    func save(_ secret: String, for identity: PocketAuthenticatedIdentity) async throws
    func secret(for identity: PocketAuthenticatedIdentity) async throws -> String?
    /// FORGETTING A KEY IS PART OF CUSTODY, NOT AN EXTRA.
    ///
    /// A key is written before the recorder has been asked — it must be, because `restore`
    /// reads custody to decide what to send. So a key that turns out to be WRONG is already
    /// stored by the time the recorder says no, and a store that can only ever accumulate
    /// leaves that wrong key in place for every future attach. This existed on
    /// `PairingSecretStore` and was simply missing here.
    ///
    /// Removing an absent key succeeds. Callers use this to undo, not to check.
    func remove(for identity: PocketAuthenticatedIdentity) async throws
}

/// The Keychain store's shape without the Keychain: the same encoded blob, the same separately
/// held tag, the same decode on the way out. Holding the secret as a bare `String` here would
/// make the two stores agree about the contract and disagree about the record.
public actor InMemoryPocketSecretStore: PocketSecretStore {
    private struct Record: Sendable {
        /// What the Keychain would encrypt.
        let blob: Data
        /// What the Keychain would leave in cleartext metadata. Random, so it says nothing.
        let tag: Data
    }
    private var values: [String: Record] = [:]
    public init() {}
    public func save(_ secret: String, for identity: PocketAuthenticatedIdentity) throws {
        guard PocketSecretRecord.isValid(secret) else { throw PocketSecretStoreError.unavailable }
        let tag = PocketSecretRecord.newTag()
        values[identity.storageKey] = Record(
            blob: PocketSecretRecord.encode(secret: secret, tag: tag), tag: tag)
    }
    public func secret(for identity: PocketAuthenticatedIdentity) -> String? {
        guard let record = values[identity.storageKey] else { return nil }
        return PocketSecretRecord.decode(record.blob, tag: record.tag)
    }
    public func remove(for identity: PocketAuthenticatedIdentity) {
        values[identity.storageKey] = nil
    }
}

/// THE ONE VALIDATOR. Internal rather than private since `PocketSessionKeyEntry` — the owner
/// typing in a key their recorder was already provisioned with — must refuse a malformed
/// candidate through the SAME predicate the Keychain seam enforces. A second spelling of
/// "16 ASCII bytes" is how a field starts accepting something the store will later reject.
///
/// AND THE RECORD ENCODING, WHICH DELIBERATELY DERIVES NOTHING FROM THE SECRET.
///
/// This used to bind the item together with `SHA256(secret)`, written into `kSecAttrGeneric`.
/// On iOS only `kSecValueData` is encrypted under the item's protection class; ATTRIBUTES sit
/// in the keychain database's cleartext metadata. An unsalted digest of a 16-character
/// credential in cleartext metadata is recoverable exactly where the credential is not, and
/// how brute-forceable it is depends entirely on the vendor's key alphabet — the very thing
/// that is unevidenced, and the very reason `provisionFactoryFresh` is gated.
///
/// So the binding is now a RANDOM tag: the cleartext attribute is 16 bytes of noise that say
/// nothing about the key, and the same tag is carried inside the encrypted blob. Tampering
/// with either half still fails the check; reading the cleartext half teaches an attacker
/// nothing at all.
enum PocketSecretRecord {
    static let tagLength = 16

    static func isValid(_ secret: String) -> Bool {
        secret.utf8.count == 16 && secret.unicodeScalars.allSatisfy(\.isASCII)
    }

    /// Random, per save. Never derived from the secret, and never reused across saves.
    static func newTag() -> Data {
        var bytes = [UInt8](repeating: 0, count: tagLength)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &generator) }
        return Data(bytes)
    }

    /// The encrypted half: the tag, then the secret. Reading this requires the item's class
    /// key; reading `kSecAttrGeneric` does not, which is why only the tag lives there.
    static func encode(secret: String, tag: Data) -> Data {
        tag + Data(secret.utf8)
    }

    /// `nil` when the blob does not carry the tag the cleartext attribute claims, or when what
    /// is left is not a key this app would have stored.
    static func decode(_ data: Data, tag: Data) -> String? {
        guard tag.count == tagLength, data.count > tagLength else { return nil }
        guard data.prefix(tagLength) == tag else { return nil }
        guard let value = String(data: data.dropFirst(tagLength), encoding: .utf8),
              isValid(value) else { return nil }
        return value
    }
}

/// Production custody. The account is the authenticated composite identity, never a local name.
public actor KeychainPocketSecretStore: PocketSecretStore {
    public static let defaultService = "com.foundryx.pocket.session-secret"
    private let service: String
    public init(service: String = defaultService) { self.service = service }

#if canImport(Security)
    /// The item's address. `kSecAttrSynchronizable` is deliberately ABSENT so a caller has to
    /// say which world it means — `SynchronizableAny` when matching, nothing when adding.
    private func address(_ identity: PocketAuthenticatedIdentity) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identity.storageKey
        ]
    }
#endif

    /// THIS ITEM IS DEVICE-ONLY AND IT DOES NOT GO TO iCLOUD.
    ///
    /// It used to set `kSecAttrSynchronizable: true`, which replicated the recorder credential
    /// to iCloud Keychain and to every device on the Apple ID — keyed by
    /// `filePull/<CoreBluetooth peripheral UUID>`. That identifier is generated per device PER
    /// APP: the same physical recorder has a different UUID on the owner's iPad, so the synced
    /// copy is unreachable there BY CONSTRUCTION. The sync bought nothing and put the key in
    /// Apple's escrow and in every keychain backup. It also forced the accessibility class off
    /// `…ThisDeviceOnly`, since synchronizable items may not be device-only.
    ///
    /// `AfterFirstUnlockThisDeviceOnly` keeps the availability the attach path had — an attach
    /// can run whenever the app can run — and drops the replication.
    public func save(_ secret: String, for identity: PocketAuthenticatedIdentity) throws {
#if canImport(Security)
        guard PocketSecretRecord.isValid(secret) else { throw PocketSecretStoreError.unavailable }
        let tag = PocketSecretRecord.newTag()
        // Delete FIRST, across both worlds. `synchronizable` is part of a keychain item's
        // primary key, so adding a device-only item beside a legacy synced one would leave
        // TWO items for this recorder and a `MatchLimitOne` read picking arbitrarily.
        var purge = address(identity)
        purge[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let purged = SecItemDelete(purge as CFDictionary)
        guard purged == errSecSuccess || purged == errSecItemNotFound else {
            throw PocketSecretStoreError.unavailable
        }
        var add = address(identity)
        add[kSecValueData as String] = PocketSecretRecord.encode(secret: secret, tag: tag)
        add[kSecAttrGeneric as String] = tag
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw PocketSecretStoreError.unavailable
        }
#else
        throw PocketSecretStoreError.unavailable
#endif
    }

    public func secret(for identity: PocketAuthenticatedIdentity) throws -> String? {
#if canImport(Security)
        // `SynchronizableAny` on the READ so an item a previous build synced is still found —
        // and can therefore be overwritten or removed rather than stranded.
        var query = address(identity)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let tag = item[kSecAttrGeneric as String] as? Data,
              let value = PocketSecretRecord.decode(data, tag: tag) else {
            throw PocketSecretStoreError.unavailable
        }
        return value
#else
        return nil
#endif
    }

    /// Undoing a save. An absent item is a success: the caller wants the key GONE, and it is.
    public func remove(for identity: PocketAuthenticatedIdentity) throws {
#if canImport(Security)
        var query = address(identity)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PocketSecretStoreError.unavailable
        }
#endif
    }
}

public enum PocketOnboardingAuthentication: Equatable, Sendable {
    case accepted
    case rejected
    case indeterminate
}

public struct PocketOnboardingConfirmation: Equatable, Sendable {
    public let batteryPercent: Int
    public let firmware: String
    public init(batteryPercent: Int, firmware: String) {
        self.batteryPercent = batteryPercent
        self.firmware = firmware
    }
}

public protocol PocketOnboardingClient: Sendable {
    func authenticate(secret: String) async -> PocketOnboardingAuthentication
    func confirmation() async throws -> PocketOnboardingConfirmation
    func close() async
}

public enum PocketOnboardingState: Equatable, Sendable {
    case setup
    case working
    case ready(batteryPercent: Int, firmware: String)
    case acceptedNotDurable
    case coexistenceAvailable
    case quarantined
    case indeterminate
    case recoveryRequired
}

public actor PocketOnboardingCoordinator {
    private let client: any PocketOnboardingClient
    private let store: any PocketSecretStore
    private var pending: (String, PocketAuthenticatedIdentity, PocketOnboardingConfirmation)?

    public init(client: any PocketOnboardingClient, store: any PocketSecretStore) {
        self.client = client
        self.store = store
    }

    /// Called only for a factory-fresh unit after the firmware alphabet/entropy gate is met.
    public func provisionFactoryFresh(identity: PocketAuthenticatedIdentity?, candidate: String) async -> PocketOnboardingState {
        guard let identity, PocketSecretRecord.isValid(candidate) else {
            return .quarantined
        }
        guard await client.authenticate(secret: candidate) == .accepted else {
            await client.close()
            return .indeterminate
        }
        guard let confirmation = try? await client.confirmation() else {
            await client.close()
            return .indeterminate
        }
        do {
            try await store.save(candidate, for: identity)
            return .ready(batteryPercent: confirmation.batteryPercent, firmware: confirmation.firmware)
        } catch {
            pending = (candidate, identity, confirmation)
            await client.close()
            return .acceptedNotDurable
        }
    }

    /// Shipping reconnect order: restore FoundryX custody first. No speculative fresh write.
    ///
    /// A REFUSED KEY AND A BROKEN LINK ARE DIFFERENT ANSWERS, and this is the only place that
    /// can tell them apart. `.rejected` is the recorder answering something other than
    /// `MCU&SK&OK` — it heard the key and said no. `.indeterminate` is the handshake never
    /// completing at all, and so is a confirmation read that fails after the key was accepted.
    /// Collapsing both into `.recoveryRequired` is what makes a UI say "that key was refused"
    /// to someone whose recorder simply walked out of range.
    public func restore(identity: PocketAuthenticatedIdentity) async -> PocketOnboardingState {
        guard let secret = try? await store.secret(for: identity) else {
            return .coexistenceAvailable
        }
        switch await client.authenticate(secret: secret) {
        case .accepted:
            break
        case .rejected:
            await client.close()
            return .recoveryRequired
        case .indeterminate:
            await client.close()
            return .indeterminate
        }
        guard let confirmation = try? await client.confirmation() else {
            await client.close()
            return .indeterminate
        }
        return .ready(batteryPercent: confirmation.batteryPercent, firmware: confirmation.firmware)
    }

    /// Retries only the same Keychain write; it never writes to the recorder.
    public func retrySecureStorage() async -> PocketOnboardingState {
        guard let pending else { return .recoveryRequired }
        do {
            try await store.save(pending.0, for: pending.1)
            self.pending = nil
            return .ready(batteryPercent: pending.2.batteryPercent, firmware: pending.2.firmware)
        } catch {
            return .acceptedNotDurable
        }
    }

    public func abandon() { pending = nil }
}

public struct PocketSetupPresentation: Equatable, Sendable {
    public let title: String
    public let body: String
    public let actions: [String]

    public static let setup = PocketSetupPresentation(
        title: "Set up Pocket", body: "Keep the recorder nearby.", actions: ["Set up"])
    /// WHERE A REFUSED KEY LANDS, AND WHY IT IS NOT A DEAD END.
    ///
    /// `RecordingDeviceAttachment` returns `.recoveryRequired` when the recorder heard a key
    /// and said no — including the key the owner just typed one character wrong. The only
    /// action here used to be "Try again", which closes the sheet, and the field could only be
    /// reached from `.setupUnavailable`, which a recorder that HAS a stored key never returns.
    /// One typo therefore locked the recorder out of the only path that could fix it. The
    /// entry action is what makes a mistyped key a retry rather than a wall.
    public static let didNotFinish = PocketSetupPresentation(
        title: "Set up Pocket",
        body: "Setup didn't finish. Try again before you close this.",
        actions: ["Try again", PocketSessionKeyEntryPresentation.entryAction])
    public static let acceptedNotDurable = PocketSetupPresentation(
        title: "Set up Pocket",
        body: "Setup didn't finish. Try again before you close this.",
        actions: ["Try again"])
    public static let ready = PocketSetupPresentation(title: "Pocket is ready.", body: "", actions: ["Done"])
    public static let indeterminate = PocketSetupPresentation(
        title: "Setup didn't finish", body: "FoundryX couldn't determine this recorder's setup.", actions: ["Try again"])
    public static let keepBothApps = PocketSetupPresentation(
        title: "Keep both apps",
        body: "FoundryX won't reset your recorder. Both apps can use the same recorder. They connect one at a time.",
        actions: ["Advanced instructions", "Reset and start over"])
    public static let quarantined = PocketSetupPresentation(
        title: "Can't verify this Pocket", body: "FoundryX can't safely match this recorder to secure custody.", actions: [])
    /// WHAT ACTUALLY SHIPS TODAY (DESIGN-pocket-connect.md §3.6). T2 req 3 disables production
    /// provisioning until an evidenced firmware-compatible key alphabet and a security-reviewed
    /// entropy policy exist, so the setup ceremony is reachable and says so rather than
    /// offering a "Set up" button that cannot complete. The second paragraph is the only
    /// reassurance that is knowable: a claim about FoundryX's own behaviour.
    ///
    /// THE GATE IS STILL SHUT, AND THE SCREEN STILL SAYS SO. What the second action adds is
    /// the case §3.6 never covered: an owner whose recorder was ALREADY provisioned by another
    /// app is not waiting on FoundryX to mint anything — they hold the key already, and had no
    /// way to hand it over. Entering an existing key is not generating one, so this affordance
    /// leaves the minting gate exactly where T2 req 3 put it.
    public static let setupUnavailable = PocketSetupPresentation(
        title: "Setup isn't available yet",
        body: "FoundryX can't safely generate a key for this recorder yet. Setup is turned off "
            + "until that's settled.\n\nYour recorder is untouched. FoundryX sent it nothing."
            + "\n\nIf another app already set this recorder up, you can enter the key it was "
            + "set up with.",
        actions: ["See what's connected", PocketSessionKeyEntryPresentation.entryAction])
    public static let all = [setup, didNotFinish, acceptedNotDurable, ready, indeterminate,
                             keepBothApps, quarantined, setupUnavailable]
}

public struct PocketEducationSection: Equatable, Sendable {
    public let title: String
    public let body: String
}

public struct PocketDeviceEducation: Equatable, Sendable {
    public let sections: [PocketEducationSection]
    public let claimsTelemetry: Bool
    public static let presentation = PocketDeviceEducation(sections: [
        .init(title: "Is it recording?", body: "Check the light on the recorder. FoundryX doesn't show recording state yet."),
        .init(title: "The light", body: "Solid amber — Recording\nBlue — Connected\nRed — Charging"),
        .init(title: "The button", body: "Press once — Start or stop\nHold 3 seconds — Turn it off"),
        .init(title: "The switch", body: "Normal — Everything around you\nCall — Phone calls only")
    ], claimsTelemetry: false)
}

// MARK: - Entering a key the recorder was already provisioned with

/// WHY A CANDIDATE WAS REFUSED BEFORE THE RADIO WAS TOUCHED. The spec asks the field to say
/// WHICH — "a session key is 16 characters" is actionable, "that didn't work" is not — so the
/// defect is a value the presentation words, never a free-form string assembled at the call
/// site where the candidate is in scope.
///
/// NOTE WHAT IT DOES NOT CARRY: the candidate. A length is not a credential; the characters
/// are. Every case here is safe to render, log and compare.
public enum PocketSessionKeyDefect: Equatable, Sendable {
    case empty
    /// How many characters were offered — never which ones.
    case wrongLength(Int)
    case notPlainText
}

/// The copy for the key-entry path, beside the rest of the Pocket presentation constants for
/// the same reason they are here: `swift test` cannot compile `App/`, so a sentence invented
/// in a SwiftUI body is a second, unasserted implementation of the app's voice.
///
/// THE HONEST FACT THIS COPY EXISTS TO CARRY. The vendor Pocket app never displays the session
/// key. It RECEIVES the key during pairing and keeps it; there is no screen anywhere in it
/// that shows you the value, and there is no sniffing shortcut that will recover it, because
/// the key is something the app WRITES rather than something the recorder broadcasts. So the
/// only way to obtain it is a one-time Bluetooth HCI capture — a developer-level procedure,
/// documented by Pocket Libre, and this copy says that outright rather than implying a
/// consumer flow and sending someone hunting through a settings screen that does not have it.
public enum PocketSessionKeyEntryPresentation {

    /// The affordance on the §3.6 screen. It promises only what this path does: entering a key
    /// that already exists. It does not offer to create one.
    public static let entryAction = "I already have this recorder's key"

    public static let title = "Enter your recorder's key"

    public static let fieldLabel = "Session key"
    /// A SHAPE, NOT AN EXAMPLE. A specimen key in a placeholder is a credential-shaped string
    /// people paste by accident.
    public static let fieldPrompt = "16 characters"
    public static let submitAction = "Use this key"

    /// HOW FAR ALONG, NEVER HOW IT READS. The field hides what is typed — it is a credential,
    /// and a plain field hands it to third-party keyboards and to the window snapshot iOS
    /// writes on backgrounding — so this is the only feedback someone transcribing 16
    /// characters out of a packet trace gets. A COUNT is not a credential, for exactly the
    /// reason `PocketSessionKeyDefect.wrongLength` carries an `Int` and not the string.
    public static func progress(entered count: Int) -> String {
        "\(count) of 16 characters"
    }

    public static let intro =
        "If another app already set this recorder up, that app and this one can use the same "
        + "16-character session key. Enter it here and FoundryX will connect with it."

    /// SAID FIRST AND SAID PLAINLY, because it is the sentence that saves someone twenty
    /// minutes of looking for a screen that does not exist.
    public static let vendorAppDoesNotShowIt =
        "The vendor app never shows you this key. It receives the key while it pairs and keeps "
        + "it to itself — there is no screen in it, or in FoundryX, that displays the value. "
        + "The only way to read it is to capture it once from a Bluetooth HCI trace while the "
        + "vendor app connects."

    public static let macCaptureRoute =
        "On a Mac or iPhone — use PacketLogger, which ships with Apple's Additional Tools for "
        + "Xcode. Start a capture, open the vendor app, let it connect to the recorder, then "
        + "search the trace for APP&SK&. The 16 characters after it are the key."

    public static let androidCaptureRoute =
        "On Android — turn on Bluetooth HCI snoop log in Developer Options, connect with the "
        + "vendor app, then pull btsnoop_hci.log off the phone and open it in Wireshark. "
        + "Search it for APP&SK& the same way."

    /// The shortcut people reach for first, ruled out explicitly.
    public static let noShortcut =
        "Scanning or sniffing the recorder will not find it. A sniffer only sees what the "
        + "recorder sends on its own connection, and the key is something the app writes."

    public static let attribution =
        "Both procedures are documented by Pocket Libre, the open protocol project this "
        + "recorder support is built on."

    /// The guidance as the view draws it, in order. A view that renders `sections` cannot skip
    /// one of the two routes without the population assertion noticing.
    public static let sections: [PocketEducationSection] = [
        .init(title: "The vendor app doesn't show it", body: vendorAppDoesNotShowIt),
        .init(title: "Capturing it on macOS or iOS", body: macCaptureRoute),
        .init(title: "Capturing it on Android", body: androidCaptureRoute),
        .init(title: "There's no shortcut", body: noShortcut),
        .init(title: "Where this comes from", body: attribution),
    ]

    // MARK: what a rejection says

    /// REFUSED WITHOUT TOUCHING THE RECORDER. Each of these is produced before a transport
    /// exists, and each says so, because "FoundryX sent it nothing" is the one reassurance
    /// this whole screen can actually make good on.
    public static func line(for defect: PocketSessionKeyDefect) -> String {
        switch defect {
        case .empty:
            return "Enter the recorder's 16-character session key. "
                + "FoundryX hasn't sent the recorder anything."
        case .wrongLength(let count):
            return "A session key is exactly 16 characters, and that one is \(count). "
                + "FoundryX hasn't sent the recorder anything."
        case .notPlainText:
            return "A session key is 16 plain text characters, and that one has characters the "
                + "recorder's protocol can't carry. FoundryX hasn't sent the recorder anything."
        }
    }

    /// THE RECORDER HEARD IT AND SAID NO. This is the `MCU&SK&OK` that never came, and it is
    /// deliberately NOT worded as a connection problem: the link was fine, which is exactly
    /// what makes "try again closer to the recorder" the wrong advice here.
    public static let refusedByRecorderLine =
        "That key was refused by the recorder. FoundryX reached it and it did not accept this "
        + "key — check you captured the key for this recorder and not for another one."

    /// The link, and only the link. Distinct from `refusedByRecorderLine` by construction.
    public static let linkFailedLine =
        "FoundryX couldn't reach the recorder to try that key. Bring it closer and try again."

    /// The Keychain refused the write, so nothing was offered to the recorder either.
    public static let keyNotKeptLine =
        "This iPhone couldn't store that key securely, so FoundryX didn't send it to the "
        + "recorder. Try again."

    /// The key worked and the ACCOUNT could not keep the result — a lost user decision, said
    /// out loud rather than shown as a recorder that silently never appears.
    public static let notRememberedLine =
        "That key worked, but FoundryX couldn't save this recorder to your account. Try again."

    /// The tapped device is not a record-then-sync recorder at all, so it has no session key.
    public static let notARecorderLine =
        "That device doesn't record on its own, so it has no session key to enter."

    /// Every line and every section body this surface can render. The credential-hygiene gate
    /// and the "names both routes" gate are both held over this POPULATION rather than over
    /// whichever string a test author remembered.
    public static var everyLine: [String] {
        sections.flatMap { [$0.title, $0.body] }
            + [entryAction, title, fieldLabel, fieldPrompt, submitAction, intro,
               refusedByRecorderLine, linkFailedLine, keyNotKeptLine, notRememberedLine,
               notARecorderLine,
               progress(entered: 0), progress(entered: 16),
               line(for: .empty), line(for: .wrongLength(15)), line(for: .notPlainText)]
    }
}

/// The candidate an owner typed, judged by the SHIPPED predicate.
public enum PocketSessionKey {

    /// Leading and trailing whitespace is dropped and nothing else is. A key copied out of a
    /// trace almost always arrives with a newline on it, and refusing that as "17 characters"
    /// would be the app being wrong about the one thing it is asking the person to be right
    /// about. Interior characters are never touched — the credential is what it is.
    public static func normalised(_ candidate: String) -> String {
        candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` when the candidate is well formed. The verdict comes from `PocketSecretRecord`,
    /// the same predicate `PocketSecretStore.save` enforces, so the field can never accept
    /// something custody will later reject.
    public static func defect(in candidate: String) -> PocketSessionKeyDefect? {
        let value = normalised(candidate)
        if PocketSecretRecord.isValid(value) { return nil }
        if value.isEmpty { return .empty }
        guard value.unicodeScalars.allSatisfy(\.isASCII) else { return .notPlainText }
        // All-ASCII, so the character count and the byte count agree and the number the
        // person is being told matches the number they can count on screen.
        return .wrongLength(value.count)
    }
}

public enum PocketRecordingDelivery: Equatable, Sendable { case pullAfterTheFact }
public enum PocketOnboardingCapabilities {
    public static let delivery: PocketRecordingDelivery = .pullAfterTheFact
    public static let hasLiveRecordingSurface = false
}
