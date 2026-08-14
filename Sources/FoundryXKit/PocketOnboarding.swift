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
    /// THE PROOF LEG. `MCU&SK&OK` is an acknowledgement, not evidence that the recorder kept
    /// what it was sent. Reading the recorder's own access-point credentials back is: the
    /// password it reports is derived from the key it is HOLDING, so a recorder that answered
    /// yes and went on using another app's key cannot produce ours.
    ///
    /// Throwing here means UNPROVEN, never REFUSED. The two are different answers and the
    /// coordinator keeps them apart.
    func accessPointReadback() async throws -> PocketAccessPointReadback
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
    /// CUSTODY THREW ON THE WAY IN, WHICH IS NOT THE SAME ANSWER AS "THERE IS NO KEY".
    ///
    /// `store.secret` throws for a Keychain that is locked, that answers a status this app does
    /// not recognise, or that holds an item this build can no longer decode. Flattening that
    /// into `nil` used to make it indistinguishable from a recorder FoundryX has never
    /// provisioned — and `nil` is the state the UI turns into the MINT OFFER. So a transient
    /// storage error proposed a second `APP&SK&` write to a recorder this app had itself
    /// provisioned, whose key was sitting in the Keychain the whole time.
    ///
    /// Nothing is written to the recorder in this state, and no key is minted from it.
    case custodyUnreadable
    /// THE MINT WAS REFUSED. The recorder heard the new key and kept the one it already has —
    /// which is the SAFE answer to U1, and the one that means another app owns this recorder.
    /// Distinct from `.indeterminate`, which is the recorder never answering at all.
    case mintRefused
    /// THE MINT WAS ACKNOWLEDGED AND COULD NOT BE PROVEN. The recorder said `MCU&SK&OK` and
    /// then would not report access-point credentials that match the key we sent. The key is
    /// KEPT — the recorder may well be holding it — but setup is not reported complete, because
    /// a bare acknowledgement is not evidence.
    case mintNotVerified
    /// CUSTODY REFUSED THE KEY BEFORE THE RECORDER WAS ASKED FOR ANYTHING FURTHER.
    case keyNotKept
}

public actor PocketOnboardingCoordinator {
    private let client: any PocketOnboardingClient
    private let store: any PocketSecretStore
    /// The synchronised recovery copy (§10). Optional because the RESTORE path does not need
    /// it and the mint path must not be able to skip it silently — a mint with no recovery
    /// store reports `.deviceOnly` custody rather than pretending it is durable everywhere.
    private let recovery: (any PocketKeyRecoveryStore)?
    private let recoveryToken: PocketRecoveryToken?
    private var pending: (String, PocketAuthenticatedIdentity, PocketOnboardingConfirmation)?

    public init(client: any PocketOnboardingClient,
                store: any PocketSecretStore,
                recovery: (any PocketKeyRecoveryStore)? = nil,
                recoveryToken: PocketRecoveryToken? = nil) {
        self.client = client
        self.store = store
        self.recovery = recovery
        self.recoveryToken = recoveryToken
    }

    /// MINT A KEY AND BECOME THIS RECORDER'S FIRST OWNER.
    ///
    /// The candidate is generated HERE, by `PocketSessionKeyMint`, and no caller may supply
    /// one: a key whose alphabet the caller chose is a key whose first eight characters may
    /// not be a legal WPA passphrase, and a key a caller could pass is a key a caller could
    /// hard-code. `provisionFactoryFresh` below still takes a candidate because the flow's
    /// steps are asserted individually, but the app reaches minting only through this door.
    public func mintFactoryFresh(identity: PocketAuthenticatedIdentity?,
                                 consent: PocketMintConsent) async -> PocketOnboardingState {
        guard let candidate = try? PocketSessionKeyMint.generate() else {
            // No cryptographic randomness means no key. Inventing one from a weaker source
            // would be the single worst thing this file could do.
            return .quarantined
        }
        return await provisionFactoryFresh(identity: identity, candidate: candidate,
                                           consent: consent)
    }

    /// ONE KEY, ONE TIME, ONLY WITH CONSENT, NEVER SENT BEFORE IT IS KEPT, AND NEVER REPORTED
    /// AS SUCCESS ON A BARE ACK.
    ///
    /// The order is the security property:
    ///
    ///   1. `consent` — a value only an explicit owner confirmation can construct. Because U1
    ///      is open (a keyed recorder may silently re-key), an unattended mint is a possibly
    ///      destructive write and may not be reachable by accident.
    ///   2. CUSTODY, BEFORE THE RADIO. The candidate goes into the Keychain FIRST. If custody
    ///      refuses it, the recorder is never asked and nothing is written — `.keyNotKept`.
    ///   3. authenticate — the one `APP&SK&` write. A refusal is `.mintRefused` and stops; a
    ///      silence is `.indeterminate` and stops. Neither is retried, and no second key is
    ///      ever sent.
    ///   4. the synchronised recovery copy, once the recorder has ACCEPTED the key.
    ///   5. READ BACK — `APP&WIFI`, and the reported password must equal the first eight
    ///      characters of the key we just sent. Anything else is `.mintNotVerified`.
    ///   6. confirm — battery and firmware, so the confirmation screen shows real numbers.
    ///
    /// WHY CUSTODY MOVED IN FRONT OF THE WRITE. It used to run last: authenticate, read back,
    /// read battery, read firmware, and only then save. Each of those is a bounded but real
    /// BLE round trip, so for up to ~24 seconds of radio I/O the only copy of a live credential
    /// was a local variable. A jetsam kill, a crash, a swipe-away or a flat battery in that
    /// window left the recorder holding a key nothing in the world had — and this firmware has
    /// no reset, no unpair and no key-read opcode, so that recorder is scrap. `PocketSessionKey
    /// Entry` already got this right for a key the owner typed ("an app that authenticates with
    /// a key it cannot store is an app that works exactly once"); the path where the key cannot
    /// be re-derived was the one that persisted last.
    ///
    /// After step 3, the key is KEPT on every remaining path — including `.mintNotVerified` and
    /// `.indeterminate` — because a key the recorder has and this phone does not is a brick.
    /// The ONE path that takes it back out is an explicit refusal, where the recorder has said
    /// it is holding somebody else's key and ours is therefore worthless.
    public func provisionFactoryFresh(identity: PocketAuthenticatedIdentity?,
                                      candidate: String,
                                      consent: PocketMintConsent) async -> PocketOnboardingState {
        _ = consent
        guard let identity, PocketSessionKeyMint.isWireAndWiFiSafe(candidate) else {
            return .quarantined
        }

        // ── CUSTODY FIRST ───────────────────────────────────────────────────────────────
        // The attach record is what makes this recorder usable at all, and it is written
        // before the recorder can possibly be holding the key. There is no window.
        do { try await store.save(candidate, for: identity) }
        catch {
            await client.close()
            return .keyNotKept
        }

        switch await client.authenticate(secret: candidate) {
        case .accepted:
            break
        case .rejected:
            // ANOTHER APP OWNS THIS RECORDER. It is holding a key that is not ours, so the
            // candidate is worthless and is taken back out of custody — leaving it there would
            // make every later tap restore a key the hardware has already refused. Nothing was
            // changed on the recorder, one key was sent, and no second one will be.
            try? await store.remove(for: identity)
            await client.close()
            return .mintRefused
        case .indeterminate:
            // THE KEY STAYS IN CUSTODY. The write may have landed and the answer may simply
            // not have come back; discarding it here is exactly the brick this order exists to
            // prevent. A recorder that never took it is unharmed by us holding a key for it.
            await client.close()
            return .indeterminate
        }

        // THE RECOVERY COPY, ONCE THE RECORDER HAS SAID YES. It is written second, not first,
        // because it is addressed by the recorder's SERIAL: a mint the recorder refuses must
        // not clobber a recovery record this owner already had for that serial.
        await keepRecoveryCopy(candidate)

        // THE ACK IS NOT THE PROOF. Everything below runs on a session the recorder has
        // already said yes on, so a failure here is never re-interpreted as a refusal.
        let proven: Bool
        if let readback = try? await client.accessPointReadback() {
            proven = readback.provesPossession(ofSessionKey: candidate)
        } else {
            proven = false
        }
        guard proven else {
            // The recorder MAY be holding this key, and custody already has it. Setup is not
            // reported complete, and nothing is taken back.
            await client.close()
            return .mintNotVerified
        }

        guard let confirmation = try? await client.confirmation() else {
            // The key is proven to be on the recorder and it is in custody. The ceremony just
            // cannot show real numbers.
            await client.close()
            return .indeterminate
        }
        return .ready(batteryPercent: confirmation.batteryPercent,
                      firmware: confirmation.firmware)
    }

    /// The synchronised half of custody, best effort and REPORTED rather than assumed. A mint
    /// whose recovery copy did not land still works on this phone, so it is not a failure — but
    /// it is not the §10 promise either, and `PocketKeyCustodyPresentation` words the screen
    /// from whether this record actually exists rather than from an assumption that it does.
    @discardableResult
    private func keepRecoveryCopy(_ key: String) async -> PocketCustodyOutcome {
        guard let recovery, let recoveryToken else { return .deviceOnly }
        do { try await recovery.save(key, under: recoveryToken) }
        catch { return .deviceOnly }
        return .durable
    }

    /// Shipping reconnect order: restore FoundryX custody first. No speculative fresh write.
    ///
    /// A REFUSED KEY AND A BROKEN LINK ARE DIFFERENT ANSWERS, and this is the only place that
    /// can tell them apart. `.rejected` is the recorder answering something other than
    /// `MCU&SK&OK` — it heard the key and said no. `.indeterminate` is the handshake never
    /// completing at all, and so is a confirmation read that fails after the key was accepted.
    /// Collapsing both into `.recoveryRequired` is what makes a UI say "that key was refused"
    /// to someone whose recorder simply walked out of range.
    ///
    /// AND A STORE THAT THREW IS NOT A STORE THAT IS EMPTY. `try?` used to flatten both into
    /// `nil`, and `nil` is what the UI turns into the mint offer — so a locked Keychain, an
    /// unrecognised OSStatus, or an item written by a previous tag scheme proposed a second
    /// `APP&SK&` write against a recorder this app had provisioned itself, whose key was in the
    /// Keychain the entire time. That is `.custodyUnreadable`, and nothing mints from it.
    public func restore(identity: PocketAuthenticatedIdentity) async -> PocketOnboardingState {
        let held: String?
        do { held = try await store.secret(for: identity) }
        catch {
            await client.close()
            return .custodyUnreadable
        }
        guard let secret = held else {
            return await restoreFromRecoveryCopy(identity: identity)
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

    /// THE READER THE §10 RECOVERY RECORD NEVER HAD, AND THE REASON A REPLACED PHONE IS NOT A
    /// DEAD RECORDER.
    ///
    /// The attach record is addressed by the CoreBluetooth peripheral UUID, which iOS generates
    /// PER DEVICE PER APP: the owner's next iPhone gets a different one for the same physical
    /// recorder, so `store.secret` finds nothing there BY CONSTRUCTION. Without this lookup the
    /// next state is `.coexistenceAvailable`, which the UI renders as the mint offer — so an
    /// owner who replaced their phone was walked into writing a SECOND key to a recorder they
    /// already owned, either being told it belongs to another app (U1 refuses) or silently
    /// re-keying it and changing its WiFi password (U1 accepts). The key was in their
    /// synchronised Keychain the whole time. The record was written and never read, which is
    /// the same "zero callers, so it does not exist" defect §10 was called out for.
    ///
    /// A RECOVERY HIT IS A CANDIDATE, NEVER AN ADOPTION. It is indexed by the recorder's own
    /// broadcast serial, which is copyable and is therefore not an identity: the recorder still
    /// has to ACCEPT the key before anything is remembered. A wrong hit costs a refused key and
    /// a message — the same cost as the owner typing a key from another recorder — and lands
    /// back on `.coexistenceAvailable`, where the mint decision is still the owner's to make.
    private func restoreFromRecoveryCopy(
        identity: PocketAuthenticatedIdentity
    ) async -> PocketOnboardingState {
        guard let recovery, let recoveryToken,
              let recovered = try? await recovery.key(under: recoveryToken) else {
            return .coexistenceAvailable
        }
        switch await client.authenticate(secret: recovered) {
        case .accepted:
            break
        case .rejected:
            return .coexistenceAvailable
        case .indeterminate:
            await client.close()
            return .indeterminate
        }
        // FILE IT LOCALLY so the next connect on this phone is an ordinary restore. Best
        // effort: the key is already durable in the synchronised record, so a failure here
        // costs one repeated lookup, not the credential.
        try? await store.save(recovered, for: identity)
        guard let confirmation = try? await client.confirmation() else {
            await client.close()
            return .indeterminate
        }
        return .ready(batteryPercent: confirmation.batteryPercent, firmware: confirmation.firmware)
    }

    /// Retries only the same Keychain write; it never writes to the recorder.
    ///
    /// A BACKSTOP, AND NO LONGER A ROUTE THE SHIPPED MINT CAN REACH. `pending` was set when a
    /// recorder had ACCEPTED a key that custody then refused (design §3.7). Custody now runs
    /// BEFORE the `APP&SK&` write, so a key the Keychain will not keep is never offered to the
    /// recorder and that state cannot arise from `provisionFactoryFresh`. The retry is kept —
    /// working, and wired to a real screen — because it is the safety net that catches this
    /// class of bug if that ordering is ever reversed again, and a net that has rotted is worse
    /// than none.
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

    /// THE ONLY WAY THE KEY LEAVES THIS COORDINATOR, AND IT EXISTS FOR ONE STATE.
    ///
    /// `nil` unless a mint was ACCEPTED BY THE RECORDER and custody refused it — design §3.7,
    /// where the recorder is holding a credential whose only copy in the world is in memory.
    /// The caller that reads it is the attachment, so its own retry has something to retry;
    /// there is no other caller, and the value goes nowhere but back into the custody seam.
    ///
    /// It deliberately does not return the confirmation, so nothing can mistake reading this
    /// for "setup succeeded".
    public func mintedKeyPendingCustody() -> String? { pending?.0 }

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
        actions: [retryAction, PocketSessionKeyEntryPresentation.entryAction])
    /// DESIGN §3.7 — THE ONE SCREEN IN THE APP WHERE CLOSING IT LOSES SOMETHING FOREVER.
    ///
    /// The recorder took the key and this iPhone could not store it. There is no reset opcode
    /// and no key-read opcode in this firmware, so if the app dies here the recorder is holding
    /// a credential nothing in the world has a copy of, and nothing can connect to it again.
    ///
    /// It used to read "Setup didn't finish. Try again before you close this." — which is what
    /// a person closes. The consequence paragraph is the whole point: the user will reflexively
    /// dismiss this screen unless told what dismissing it costs. And there is deliberately no
    /// Skip, no Continue anyway, and no second provisioning attempt: sending a second key to a
    /// recorder already holding one is how the first key becomes unrecoverable twice over.
    public static let acceptedNotDurable = PocketSetupPresentation(
        title: "Setup is not complete",
        body: "The recorder accepted a key, but this iPhone couldn't save it. Setup is not "
            + "complete. Keep Solleva open and retry secure storage."
            + "\n\nThe key is in memory only. No second key was sent, and none will be."
            + "\n\nIf Solleva closes now, this key is gone. The recorder keeps it, and nothing "
            + "will be able to connect to it again.",
        actions: [retrySecureStorageAction])

    /// NAMED, because the screen that routes it matches on this constant and a literal on both
    /// sides is a routing bug that compiles — on the one screen where a dead button loses the
    /// owner their recorder.
    public static let retrySecureStorageAction = "Retry secure storage"

    /// THE PLAIN RETRY, NAMED FOR THE SAME REASON. On the two storage screens it is wired to a
    /// real second attempt rather than to a dismiss, and the screen that routes it matches on
    /// this constant.
    public static let retryAction = "Try again"
    public static let ready = PocketSetupPresentation(title: "Pocket is ready.", body: "", actions: ["Done"])
    public static let indeterminate = PocketSetupPresentation(
        title: "Setup didn't finish", body: "Solleva couldn't determine this recorder's setup.", actions: [retryAction])
    public static let keepBothApps = PocketSetupPresentation(
        title: "Keep both apps",
        body: "Solleva won't reset your recorder. Both apps can use the same recorder. They connect one at a time.",
        actions: ["Advanced instructions", "Reset and start over"])
    public static let quarantined = PocketSetupPresentation(
        title: "Can't verify this Pocket", body: "Solleva can't safely match this recorder to secure custody.", actions: [])
    /// WHAT ACTUALLY SHIPS TODAY (DESIGN-pocket-connect.md §3.6). T2 req 3 disables production
    /// provisioning until an evidenced firmware-compatible key alphabet and a security-reviewed
    /// entropy policy exist, so the setup ceremony is reachable and says so rather than
    /// offering a "Set up" button that cannot complete. The second paragraph is the only
    /// reassurance that is knowable: a claim about FoundryX's own behaviour.
    ///
    /// WHAT THIS SCREEN IS NOW. It used to say "Setup isn't available yet", because minting a
    /// key was gated and a tap on a recorder Solleva held no key for could honestly go nowhere
    /// else. Minting is wired — with owner consent and with a read-back proof (see
    /// `PocketKeyMint.swift`) — so that sentence would now be false, and a false reassurance is
    /// worse than the gate it described.
    ///
    /// The state it still serves is the one it always actually served from the help link:
    /// nobody tapped a recorder, so there is no recorder to set up. The reassurance survives
    /// unchanged because it is still the only knowable thing — nothing was connected, so
    /// nothing was written.
    public static let setupUnavailable = PocketSetupPresentation(
        title: "Nothing is set up yet",
        body: "Solleva hasn't connected to a recorder from here, so there's nothing to set up "
            + "on this screen. Go back and tap your recorder in the list."
            + "\n\nYour recorder is untouched. Solleva sent it nothing."
            + "\n\nIf another app already set this recorder up, you can enter the key it was "
            + "set up with.",
        actions: ["See what's connected", PocketSessionKeyEntryPresentation.entryAction])

    /// THIS iPHONE'S SECURE STORAGE REFUSED THE KEY, SO THE RECORDER WAS NEVER ASKED.
    ///
    /// It is a reassurance rather than an apology on purpose: the ordering that produced this
    /// screen is the one that makes the whole mint survivable. The key is written to the
    /// Keychain BEFORE it is written to the recorder, so a storage failure costs a retry and
    /// nothing else — where the old order would have left the recorder holding a credential
    /// this phone had no copy of, on hardware with no reset and no key-read opcode.
    public static let keyNotKept = PocketSetupPresentation(
        title: "This iPhone couldn't store the key",
        body: "Solleva stores a new key on this iPhone before it sends it to the recorder, so "
            + "the recorder can never end up holding a key this iPhone doesn't have."
            + "\n\nThis iPhone's secure storage refused it, so Solleva stopped there. Your "
            + "recorder is untouched — Solleva sent it nothing.",
        actions: [retryAction])

    /// CUSTODY EXISTS AND COULD NOT BE READ — WHICH IS NOT "THERE IS NO KEY".
    ///
    /// This is the screen that stands between a locked or unreadable Keychain and the mint
    /// offer. Solleva may hold this recorder's key and simply be unable to read it right now;
    /// minting from that state would send a SECOND key to a recorder Solleva itself set up,
    /// which either fails as "another app owns this" or silently re-keys the recorder and
    /// changes its WiFi password. So this screen offers a retry, never a new key.
    public static let custodyUnreadable = PocketSetupPresentation(
        title: "Solleva can't read its own key right now",
        body: "Solleva may already have this recorder's key on this iPhone and couldn't read it "
            + "just now. That can happen before the iPhone has been unlocked since it restarted."
            + "\n\nSolleva sent the recorder nothing, and it won't make a new key from here — a "
            + "new key could replace the one the recorder is already using."
            + "\n\nUnlock this iPhone and try again.",
        actions: [retryAction, PocketSessionKeyEntryPresentation.entryAction])

    /// THE RECORDER NEVER ANSWERED THE KEY SOLLEVA IS ALREADY HOLDING — AND SILENCE PROVES
    /// NOTHING, WHICH IS THE WHOLE REASON THIS SCREEN HAS THE ACTIONS IT HAS.
    ///
    /// WHAT WENT WRONG WITHOUT IT. `PocketOnboardingCoordinator.restore` sends the key custody
    /// holds and reads the answer. This firmware answers a key it does not hold with SILENCE,
    /// not with `MCU&SK&FAIL`, so the 8-second control deadline expires, `authenticate` throws,
    /// `PocketProtocolOnboardingClient` maps every non-refusal to `.indeterminate`, and the
    /// attach comes back `.unreachable(.handshakeUnanswered)`. That was an inline caption
    /// reading "Tap it again", and the key stayed in custody — correctly — so the next tap sent
    /// the same unusable key and got the same silence. The only screen that can REPLACE a key
    /// hung off `.setupUnavailable`, which means "Solleva holds no key", so a recorder Solleva
    /// held a bad key for could not reach it from anywhere. Reported on unit
    /// PKT01_BLUE_26079bc5, whose correct key a Mac in the same room used to list five days and
    /// pull a whole recording while the app said the device had stopped answering.
    ///
    /// WHY THE KEY IS NOT DELETED HERE, AND WHY THERE IS NO "FORGET THIS RECORDER" BUTTON.
    /// A REFUSAL is proof: the recorder heard the key and said no, so it is worthless and
    /// `PocketSessionKeyEntryCoordinator` takes it straight back out of custody. SILENCE is not
    /// proof of anything — a sleeping recorder, one busy with another app, and one holding a
    /// different key are the same nothing from this side of the radio. And custody may be the
    /// only copy of that key in the world: this firmware has no reset opcode and no key-read
    /// opcode, so on a recorder Solleva minted for, a one-tap "forget" is a one-tap brick, on a
    /// screen produced by evidence that proves nothing. The escape is therefore to REPLACE the
    /// key with one the owner is holding — which the entry path already does, since
    /// `PocketSecretStore.save` overwrites — and the deletion nobody can undo is not offered.
    ///
    /// WHAT IT DOES NOT SAY. It does not say the key is wrong, because Solleva does not know
    /// that; it says Solleva cannot tell, and names the possibilities. It shows no key and
    /// offers no way to look at one — `PocketSetupPresentation.all` is the population the
    /// no-reveal gate is held over, and this value is in it.
    public static let handshakeUnanswered = PocketSetupPresentation(
        title: "Your recorder didn't answer",
        body: "Solleva already has a key for this recorder. It sent that key, the recorder "
            + "said nothing back, and Solleva stopped there."
            + "\n\nSolleva can't tell you why. A recorder that is asleep, switched off, or "
            + "busy with another app answers exactly the same way as one that was set up with "
            + "a different key — with nothing at all."
            + "\n\nSo the key is still here, untouched. Try the recorder again, or enter the "
            + "key it was set up with; a key you enter takes the place of the one Solleva has.",
        actions: [retryAction, PocketSessionKeyEntryPresentation.entryAction])

    public static let all = [setup, didNotFinish, acceptedNotDurable, ready, indeterminate,
                             keepBothApps, quarantined, setupUnavailable, keyNotKept,
                             custodyUnreadable, handshakeUnanswered]
}

public struct PocketEducationSection: Equatable, Sendable {
    public let title: String
    public let body: String
}

public struct PocketDeviceEducation: Equatable, Sendable {
    public let sections: [PocketEducationSection]
    public let claimsTelemetry: Bool
    public static let presentation = PocketDeviceEducation(sections: [
        .init(title: "Is it recording?", body: "Check the light on the recorder. Solleva doesn't show recording state yet."),
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
        + "16-character session key. Enter it here and Solleva will connect with it."

    /// SAID FIRST AND SAID PLAINLY, because it is the sentence that saves someone twenty
    /// minutes of looking for a screen that does not exist.
    public static let vendorAppDoesNotShowIt =
        "The vendor app never shows you this key. It receives the key while it pairs and keeps "
        + "it to itself — there is no screen in it, or in Solleva, that displays the value. "
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
    /// exists, and each says so, because "Solleva sent it nothing" is the one reassurance
    /// this whole screen can actually make good on.
    public static func line(for defect: PocketSessionKeyDefect) -> String {
        switch defect {
        case .empty:
            return "Enter the recorder's 16-character session key. "
                + "Solleva hasn't sent the recorder anything."
        case .wrongLength(let count):
            return "A session key is exactly 16 characters, and that one is \(count). "
                + "Solleva hasn't sent the recorder anything."
        case .notPlainText:
            return "A session key is 16 plain text characters, and that one has characters the "
                + "recorder's protocol can't carry. Solleva hasn't sent the recorder anything."
        }
    }

    /// THE RECORDER HEARD IT AND SAID NO. This is the `MCU&SK&OK` that never came, and it is
    /// deliberately NOT worded as a connection problem: the link was fine, which is exactly
    /// what makes "try again closer to the recorder" the wrong advice here.
    public static let refusedByRecorderLine =
        "That key was refused by the recorder. Solleva reached it and it did not accept this "
        + "key — check you captured the key for this recorder and not for another one."

    /// The link, and only the link. Distinct from `refusedByRecorderLine` by construction.
    ///
    /// IT NO LONGER BLAMES DISTANCE. It used to end "Bring it closer and try again", which was
    /// reported against a recorder lying on the back of the phone. Nothing in this app can
    /// measure distance, and out-of-range, powered-off and connected-to-another-app are the
    /// same silence from here.
    public static let linkFailedLine =
        "Solleva couldn't reach the recorder to try that key. Wake the recorder up and try "
        + "again."

    /// The Keychain refused the write, so nothing was offered to the recorder either.
    public static let keyNotKeptLine =
        "This iPhone couldn't store that key securely, so Solleva didn't send it to the "
        + "recorder. Try again."

    /// The key worked and the ACCOUNT could not keep the result — a lost user decision, said
    /// out loud rather than shown as a recorder that silently never appears.
    public static let notRememberedLine =
        "That key worked, but Solleva couldn't save this recorder to your account. Try again."

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
