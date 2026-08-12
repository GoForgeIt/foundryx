// PocketKeyCustody.swift — THE THING THAT MAKES MINTING SURVIVABLE.
//
// WHY THIS FILE GATES THE MINT RATHER THAN DECORATING IT. The decoded command surface of this
// firmware has no reset, no unpair, and no key-read opcode: `BAT FW LIST REC SK SPACE STE T U
// WF WIFI WIFIC WIFIO WIFIS`. So a session key that is lost is not an inconvenience — the
// recorder is a brick that no app, including the maker's, can talk to. Nick's own bench unit is
// in exactly that state: minted 2026-08-06, key not kept.
//
// Proposal §10 named the mitigation ("Keychain-stored, sync via iCloud Keychain across the
// user's devices, and user-exportable — they own it, it's also their WiFi pass") and it had
// ZERO callers, which means it did not exist. Minting without it would be shipping the brick.
//
// TWO RECORDS, FOR TWO DIFFERENT JOBS, AND THE DIFFERENCE IS THE WHOLE DESIGN.
//
//   1. THE ATTACH RECORD — `KeychainPocketSecretStore`, addressed by the CoreBluetooth
//      peripheral UUID, device-only, never synchronised. This is what `restore` reads on every
//      connect. It stays exactly as the security review left it: iOS generates that UUID PER
//      DEVICE PER APP, so a synced copy of it would be unreachable on another phone BY
//      CONSTRUCTION — it would buy nothing and put the credential in Apple's escrow.
//
//   2. THE RECOVERY RECORD — this file, addressed by the recorder's own broadcast serial, and
//      synchronised. The peripheral UUID is unstable across phones; the serial in
//      `PKT01_BLUE_26079bc5` is not. That is why the SAME item cannot do both jobs, and why
//      syncing the attach record was correctly refused while syncing this one is the point.
//
// AND THE LINE THAT SEPARATES THEM FROM THE IDENTITY RULES. The broadcast name is display
// metadata and MUST NOT be an identity for attach — a name can be copied, and two recorders
// answering to one name would cross their custody. It is used here as a RECOVERY INDEX only:
// nothing in the attach path reads it, a recovery hit is never adopted automatically, and the
// key it returns still has to be accepted by the recorder before anything is remembered. A
// wrong recovery hit therefore costs a refused key and a message, not a mixed-up device.

import Foundation
#if canImport(Security)
import Security
#endif

/// The index a recovery record is filed under: the recorder's own broadcast serial, not the
/// phone's handle for it.
///
/// It is a VALIDATED value rather than a `String` so a caller cannot file a recovery record
/// under an empty string, a path fragment, or something a device supplied unbounded.
public struct PocketRecoveryToken: Hashable, Sendable {
    public let value: String

    /// `nil` for a name that cannot serve as a stable index. Vendors put the serial in the
    /// broadcast name (`PKT01_<COLOUR>_<serial>`); anything without one is not indexable, and
    /// filing it under a bare model name would collide every unit of that model.
    public init?(advertisedName: String) {
        let trimmed = advertisedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard trimmed.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else {
            return nil
        }
        // A name with no distinguishing segment is a MODEL, not a unit. Filing two units of the
        // same model under one index is the collision this refuses to create.
        let segments = trimmed.split(whereSeparator: { $0 == "_" || $0 == "-" })
        guard segments.count >= 2, segments.last!.count >= 4 else { return nil }
        self.value = trimmed
    }
}

/// Where a recovery copy lives. Separate from `PocketSecretStore` on purpose: they have
/// different addresses, different accessibility classes, and different failure meanings, and a
/// single protocol would let a caller confuse them.
public protocol PocketKeyRecoveryStore: Sendable {
    func save(_ key: String, under token: PocketRecoveryToken) async throws
    func key(under token: PocketRecoveryToken) async throws -> String?
    func remove(_ token: PocketRecoveryToken) async throws
}

public actor InMemoryPocketKeyRecoveryStore: PocketKeyRecoveryStore {
    private var values: [String: Data] = [:]
    private var tags: [String: Data] = [:]
    public init() {}
    public func save(_ key: String, under token: PocketRecoveryToken) throws {
        guard PocketSecretRecord.isValid(key) else { throw PocketSecretStoreError.unavailable }
        let tag = PocketSecretRecord.newTag()
        tags[token.value] = tag
        values[token.value] = PocketSecretRecord.encode(secret: key, tag: tag)
    }
    public func key(under token: PocketRecoveryToken) -> String? {
        guard let blob = values[token.value], let tag = tags[token.value] else { return nil }
        return PocketSecretRecord.decode(blob, tag: tag)
    }
    public func remove(_ token: PocketRecoveryToken) {
        values[token.value] = nil
        tags[token.value] = nil
    }
}

/// THE ONLY SYNCHRONISED ITEM THIS APP WRITES, AND THE ONE THE §10 MITIGATION IS.
///
/// `kSecAttrSynchronizable` is set TRUE here deliberately, and the accessibility class is
/// `AfterFirstUnlock` rather than `…ThisDeviceOnly` because a synchronisable item may not be
/// device-only. That is the whole trade: this record leaves the device, on purpose, so that a
/// replaced phone is not a dead recorder. It is addressed by the recorder's serial, which is
/// the same on every one of the owner's devices — the exact property the attach record lacks
/// and the reason syncing THAT one was refused.
public actor KeychainPocketKeyRecoveryStore: PocketKeyRecoveryStore {
    public static let defaultService = "com.foundryx.pocket.session-key-recovery"
    private let service: String
    public init(service: String = defaultService) { self.service = service }

#if canImport(Security)
    private func address(_ token: PocketRecoveryToken) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: token.value,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
    }
#endif

    public func save(_ key: String, under token: PocketRecoveryToken) throws {
#if canImport(Security)
        guard PocketSecretRecord.isValid(key) else { throw PocketSecretStoreError.unavailable }
        let tag = PocketSecretRecord.newTag()
        let purged = SecItemDelete(address(token) as CFDictionary)
        guard purged == errSecSuccess || purged == errSecItemNotFound else {
            throw PocketSecretStoreError.unavailable
        }
        var add = address(token)
        add[kSecValueData as String] = PocketSecretRecord.encode(secret: key, tag: tag)
        add[kSecAttrGeneric as String] = tag
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw PocketSecretStoreError.unavailable
        }
#else
        throw PocketSecretStoreError.unavailable
#endif
    }

    public func key(under token: PocketRecoveryToken) throws -> String? {
#if canImport(Security)
        var query = address(token)
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

    public func remove(_ token: PocketRecoveryToken) throws {
#if canImport(Security)
        let status = SecItemDelete(address(token) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PocketSecretStoreError.unavailable
        }
#endif
    }
}

/// What a mint's custody step achieved — reported as a value because the two halves fail
/// independently and mean different things.
public enum PocketCustodyOutcome: Equatable, Sendable {
    /// Both records were written. This is the only state a mint may be reported complete from.
    case durable
    /// The attach record was written and the recovery copy was not. The recorder works on THIS
    /// phone and a replaced phone would not find it, so this is a partial success and is said
    /// out loud rather than rounded up.
    case deviceOnly
    /// Nothing was kept. Nothing may be sent to the recorder after this.
    case notKept
}

/// THE CUSTODY SEAM, AS ONE OBJECT, so a mint cannot write one record and forget the other.
public actor PocketKeyCustody {
    private let attachStore: any PocketSecretStore
    private let recoveryStore: any PocketKeyRecoveryStore

    public init(attachStore: any PocketSecretStore = KeychainPocketSecretStore(),
                recoveryStore: any PocketKeyRecoveryStore = KeychainPocketKeyRecoveryStore()) {
        self.attachStore = attachStore
        self.recoveryStore = recoveryStore
    }

    /// Both records, attach first. The attach record is the one that makes the recorder usable
    /// at all; the recovery copy is what makes a replaced phone survivable.
    ///
    /// THE MINT DELIBERATELY DOES NOT CALL THIS, and that is not an oversight to be tidied up.
    /// `PocketOnboardingCoordinator.provisionFactoryFresh` writes the attach record BEFORE the
    /// `APP&SK&` write (so there is no window in which the recorder holds a key this phone does
    /// not) and the recovery record AFTER the recorder has accepted it (so a mint the recorder
    /// REFUSES cannot clobber a recovery record this owner already had for that serial). Those
    /// two writes straddle the radio; one call cannot.
    public func keep(_ key: String,
                     for identity: PocketAuthenticatedIdentity,
                     recoveryToken: PocketRecoveryToken?) async -> PocketCustodyOutcome {
        do { try await attachStore.save(key, for: identity) }
        catch { return .notKept }
        guard let recoveryToken else { return .deviceOnly }
        do { try await recoveryStore.save(key, under: recoveryToken) }
        catch { return .deviceOnly }
        return .durable
    }

    /// THE OWNER LOOKING AT THEIR OWN KEY. There is no other read path in the app: the attach
    /// path reads custody itself and never hands the value outward.
    public func reveal(for identity: PocketAuthenticatedIdentity) async -> String? {
        (try? await attachStore.secret(for: identity)) ?? nil
    }

    /// A NEW PHONE MEETING A RECORDER THIS OWNER ALREADY OWNS. The returned key is a CANDIDATE,
    /// never an adoption: the recorder still has to accept it, which is what keeps a recovery
    /// index keyed by a copyable broadcast name from becoming an identity claim.
    ///
    /// The shipped reader is `PocketOnboardingCoordinator.restoreFromRecoveryCopy`, which runs
    /// on every connect where the attach record is empty — the state a replaced phone is always
    /// in, because the attach record is addressed by a per-app peripheral UUID.
    public func recoveredKey(for token: PocketRecoveryToken) async -> String? {
        (try? await recoveryStore.key(under: token)) ?? nil
    }

    /// WHETHER THE SYNCHRONISED COPY ACTUALLY EXISTS — asked so a screen can say what is true
    /// instead of what was intended.
    ///
    /// `keep` returns `.deviceOnly` whenever there is no recovery token (a recorder whose
    /// broadcast name carries no per-unit serial) or the synchronised write failed, and that
    /// outcome had no readers: the mint reported success and the custody screen went on
    /// promising "a new iPhone finds it on its own" for a key that never left the device. This
    /// answers from the store rather than from a remembered flag, so the promise cannot drift
    /// away from the record.
    ///
    /// The value is read and discarded; nothing but the yes/no leaves this actor.
    public func hasRecoveryCopy(_ token: PocketRecoveryToken?) async -> Bool {
        guard let token else { return false }
        return ((try? await recoveryStore.key(under: token)) ?? nil) != nil
    }

    /// Forgetting a recorder forgets BOTH records. A recovery copy that outlived the attach
    /// record would silently re-adopt a recorder the owner told the app to forget.
    public func forget(_ identity: PocketAuthenticatedIdentity,
                       recoveryToken: PocketRecoveryToken?) async {
        try? await attachStore.remove(for: identity)
        if let recoveryToken { try? await recoveryStore.remove(recoveryToken) }
    }
}

// MARK: - Copy: showing the owner their own key

/// THE SCREEN §10 ASKED FOR AND NOBODY BUILT.
///
/// NOTE WHERE THIS IS AND IS NOT. Design §3.4 forbids any reveal, copy, share, or export
/// affordance ON THE SETUP SCREEN, and it is right to: a person mid-ceremony has no reason to
/// see a credential, and putting one there trains them to screenshot it. §3.4 also says
/// explicitly that surfacing the value is "a separately owned security change, not a setup
/// step". This is that separately owned change: its own screen, reached deliberately from a
/// recorder the owner already owns, never rendered as part of the ceremony, and never
/// pre-expanded — `PocketKeyCustodyPresentation.isRevealedByDefault` is `false` and the view
/// has to ask for the value.
public enum PocketKeyCustodyPresentation {

    /// The entry point, on the recorder's own page.
    public static let entryAction = "See this recorder's key"

    public static let title = "This recorder's key"

    /// WHY THE OWNER SHOULD CARE, IN CONSEQUENCE TERMS RATHER THAN IN SECURITY TERMS.
    public static let whyItMatters =
        "This is the key Solleva set your recorder up with. The recorder has no way to be "
        + "reset from an app and no way to hand this key back, so if every copy of it is lost, "
        + "nothing can connect to the recorder again. Keep it somewhere you'd keep a password."

    /// WHERE IT IS KEPT, ANSWERED FROM THE RECORD RATHER THAN FROM THE INTENTION.
    ///
    /// The synchronised copy does not always get written: a recorder whose broadcast name
    /// carries no per-unit serial has no recovery index at all, and the synchronised write can
    /// fail on its own. Custody reports that as `.deviceOnly` — and this screen used to state
    /// the iCloud promise unconditionally anyway, so the one owner who most needed to write
    /// their key down was the one being told they did not have to.
    public static func whereItIsKept(hasRecoveryCopy: Bool) -> String {
        hasRecoveryCopy
            ? "Solleva keeps it in your iCloud Keychain, so a new iPhone signed in to the same "
                + "Apple Account finds it on its own. This screen is here for the times that "
                + "isn't enough."
            : "This key is on THIS iPhone only. Solleva couldn't put it in your iCloud "
                + "Keychain, so a new iPhone won't find it on its own — write it down or keep "
                + "it in your password manager. Without it, nothing can connect to this "
                + "recorder again."
    }

    /// The synchronised wording, named so callers that genuinely mean "the promise as written"
    /// — the population gates below — do not spell it a second time.
    public static let whereItIsKept = whereItIsKept(hasRecoveryCopy: true)

    /// The recorder's WiFi password is the first eight characters — a genuinely useful fact
    /// that proposal §10 asked for and design §3.4 kept off the setup screen.
    public static let wifiPasswordNote =
        "The first 8 characters are also the recorder's own WiFi password."

    public static let revealAction = "Show the key"
    public static let hideAction = "Hide the key"
    public static let copyAction = "Copy the key"
    public static let copiedConfirmation = "Copied."
    public static let doneAction = "Done"

    /// HIDDEN UNTIL ASKED FOR. A screen that renders a credential on arrival is a credential in
    /// every app-switcher snapshot of that screen.
    public static let isRevealedByDefault = false

    /// What the screen says when custody has nothing for this recorder — which is a real state
    /// after a restore from a backup that predates the mint.
    public static let missingLine =
        "Solleva doesn't have a key for this recorder on this iPhone."

    /// The screen as it is drawn for a recorder whose synchronised copy exists — or does not.
    /// The view is handed the answer the store gave; there is no default that quietly asserts
    /// the happier one.
    public static func sections(hasRecoveryCopy: Bool) -> [PocketEducationSection] {
        [
            .init(title: "Why this matters", body: whyItMatters),
            .init(title: "Where Solleva keeps it",
                  body: whereItIsKept(hasRecoveryCopy: hasRecoveryCopy)),
            .init(title: "Your recorder's WiFi", body: wifiPasswordNote),
        ]
    }

    public static let sections: [PocketEducationSection] = sections(hasRecoveryCopy: true)

    /// Every line this screen can render, IN BOTH CUSTODY STATES. The credential-hygiene and
    /// honesty gates are held over this POPULATION, so a new sentence cannot smuggle a key in
    /// and the device-only wording cannot escape them by being the branch nobody listed.
    public static var everyLine: [String] {
        [entryAction, title, revealAction, hideAction, copyAction, copiedConfirmation,
         doneAction, missingLine]
            + sections(hasRecoveryCopy: true).flatMap { [$0.title, $0.body] }
            + sections(hasRecoveryCopy: false).flatMap { [$0.title, $0.body] }
    }
}
