// RecordingDeviceStore — account-scoped memory of the recording devices a person owns
// (track 20260725T2306_device_agnostic_recording_source, task T2).
//
// WHAT WAS WRONG BEFORE. The shipped pairing lives in THREE DEVICE-GLOBAL UserDefaults
// keys (`DeviceManager.savedKey` and friends). Every account on a handset therefore shared
// one paired device, one "last connected", and one implicit active choice. This file makes
// that state account-scoped, keeps at most one device active, and makes an explicit detach
// stick against everything automatic — relaunch, state restoration, a radio that comes
// back — because "I unplugged this" is a user decision the app must not quietly reverse.
//
// THREE RULES WORTH STATING OUT LOUD.
//
//   1. `acct-none` IS A SCOPE, not an absence. A device paired while signed out is
//      RETAINED there rather than assigned to whichever account happens to sign in during
//      the upgrade; `RecordingDeviceHold.adopt` is the one explicit rule that moves it, it
//      runs once, and it marks the hold consumed so a second account gets nothing.
//
//   2. THE LEGACY PAIRING IS NEVER DELETED. A device paired before this track must survive
//      the upgrade without a physical re-pair, and a migration that removes its own source
//      cannot be re-run or audited.
//
//   3. ACTIVE SELECTION CANNOT SEE THE SHAPE. Preference, then readiness, then recency,
//      then a stable identity tiebreak. `RecordingDeviceShape` is absent from the
//      comparison by construction, and that is asserted by permuting the shapes of a
//      remembered set rather than by reading the code.

import Foundation
import CryptoKit

// MARK: - The durable record

/// One remembered recording device, inside ONE account's scope.
public struct RecordingDeviceRecord: Codable, Equatable, Sendable {
    public let identity: RecordingDeviceIdentity
    public var displayName: String
    public var lastConnected: Date?
    /// The USER detached this device. Nothing automatic — relaunch, state restoration,
    /// a returning radio — may re-arm it; only a user reconnect clears this.
    public var userDetached: Bool
    /// The USER chose this device. Preference beats readiness ordering; vendor identity
    /// never enters the comparison at all.
    public var userPreferred: Bool

    public init(identity: RecordingDeviceIdentity,
                displayName: String,
                lastConnected: Date? = nil,
                userDetached: Bool = false,
                userPreferred: Bool = false) {
        self.identity = identity
        self.displayName = displayName
        self.lastConnected = lastConnected
        self.userDetached = userDetached
        self.userPreferred = userPreferred
    }
}

public enum RecordingDeviceStoreError: Error, LocalizedError, Equatable {
    case noResolvableAccountScope
    case wrongScope(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .noResolvableAccountScope:
            return "No account scope could be resolved for the recording-device store"
        case .wrongScope(let scope):
            return "Recording-device operation is not valid in scope \(scope)"
        case .unreadable(let detail):
            return "Recording-device records could not be read: \(detail)"
        }
    }
}

// MARK: - The store

public final class RecordingDeviceStore {
    public let scope: String
    public let root: URL
    private let fileName = "recording-devices.json"
    private let lock = NSLock()

    public init(root: URL, scope: String) {
        self.root = root
        self.scope = scope
    }

    /// The store for whatever account is current — including the signed-out
    /// `acct-none` scope, which is a first-class scope, not an absence.
    /// `nil` when the scope cannot be resolved at all: fail closed, never guess.
    public static func current() -> RecordingDeviceStore? {
        guard let binding = CaptureAccountScope.currentAccountBinding() else { return nil }
        return RecordingDeviceStore(root: binding.root, scope: binding.scope)
    }

    public var isSignedOutScope: Bool { scope == CaptureAccountScope.signedOutScope }

    public var fileURL: URL { root.appendingPathComponent(fileName) }

    public func records() throws -> [RecordingDeviceRecord] {
        lock.lock(); defer { lock.unlock() }
        return try readLocked()
    }

    private func readLocked() throws -> [RecordingDeviceRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { return [] }
            return try JSONDecoder().decode([RecordingDeviceRecord].self, from: data)
        } catch {
            // A corrupt file is NOT "no devices". Reporting it as empty would silently
            // un-pair every device the person owns.
            throw RecordingDeviceStoreError.unreadable(error.localizedDescription)
        }
    }

    private func writeLocked(_ records: [RecordingDeviceRecord]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: fileURL, options: .atomic)
    }

    public func replaceAll(_ records: [RecordingDeviceRecord]) throws {
        lock.lock(); defer { lock.unlock() }
        try writeLocked(records)
    }

    @discardableResult
    public func upsert(_ record: RecordingDeviceRecord) throws -> RecordingDeviceRecord {
        lock.lock(); defer { lock.unlock() }
        var records = try readLocked()
        if let index = records.firstIndex(where: { $0.identity == record.identity }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try writeLocked(records)
        return record
    }

    public func remove(_ identity: RecordingDeviceIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        try writeLocked(try readLocked().filter { $0.identity != identity })
    }

    /// The user detached this device.
    public func detach(_ identity: RecordingDeviceIdentity) throws {
        try mutate(identity) { $0.userDetached = true }
    }

    /// The user reconnected this device — the only thing that clears a detach.
    public func reconnect(_ identity: RecordingDeviceIdentity) throws {
        try mutate(identity) { $0.userDetached = false }
    }

    /// The user chose this device. At most one device is preferred at a time.
    public func prefer(_ identity: RecordingDeviceIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        var records = try readLocked()
        for index in records.indices {
            records[index].userPreferred = records[index].identity == identity
        }
        try writeLocked(records)
    }

    private func mutate(_ identity: RecordingDeviceIdentity,
                        _ change: (inout RecordingDeviceRecord) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var records = try readLocked()
        guard let index = records.firstIndex(where: { $0.identity == identity }) else { return }
        change(&records[index])
        try writeLocked(records)
    }
}

// MARK: - Detach recorded from the transport layer

public enum RecordingDeviceDetachOutcome: Equatable, Sendable {
    case recorded(scope: String)
    /// Loud, typed, never silent: the detach could not be persisted.
    case unavailable(String)
}

extension RecordingDeviceStore {
    /// Called from the transport when the USER detaches. A device the store has never seen
    /// is remembered as detached, so a detach issued before the record exists is not lost.
    @discardableResult
    public static func recordUserDetach(
        identity: RecordingDeviceIdentity,
        displayName: String
    ) -> RecordingDeviceDetachOutcome {
        guard let store = current() else {
            return .unavailable(RecordingDeviceStoreError.noResolvableAccountScope
                .errorDescription ?? "no account scope")
        }
        do {
            if try store.records().contains(where: { $0.identity == identity }) {
                try store.detach(identity)
            } else {
                try store.upsert(RecordingDeviceRecord(
                    identity: identity, displayName: displayName, userDetached: true))
            }
            return .recorded(scope: store.scope)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    @discardableResult
    public static func recordUserReconnect(
        identity: RecordingDeviceIdentity
    ) -> RecordingDeviceDetachOutcome {
        guard let store = current() else {
            return .unavailable(RecordingDeviceStoreError.noResolvableAccountScope
                .errorDescription ?? "no account scope")
        }
        do {
            try store.reconnect(identity)
            return .recorded(scope: store.scope)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}

// MARK: - Legacy pairing migration

public enum RecordingDeviceMigrationOutcome: Equatable, Sendable {
    case adopted(RecordingDeviceIdentity)
    case alreadyAdopted
    case nothingToAdopt
}

public enum RecordingDeviceMigration {
    /// Carry the shipped DEVICE-GLOBAL Omi pairing into the account-scoped store.
    /// Idempotent, and the legacy defaults are never deleted — a device paired before
    /// this track must survive the upgrade without a physical re-pair.
    @discardableResult
    public static func adoptLegacyPairing(
        defaults: UserDefaults,
        into store: RecordingDeviceStore
    ) throws -> RecordingDeviceMigrationOutcome {
        guard let peripheralID = defaults.string(forKey: DeviceManager.savedKey),
              !peripheralID.isEmpty else {
            return .nothingToAdopt
        }
        let identity = RecordingDeviceIdentity(shape: .bleStream, hardwareToken: peripheralID)
        guard try !store.records().contains(where: { $0.identity == identity }) else {
            return .alreadyAdopted
        }
        let stamp = defaults.double(forKey: DeviceManager.savedDateKey)
        try store.upsert(RecordingDeviceRecord(
            identity: identity,
            displayName: defaults.string(forKey: DeviceManager.savedNameKey) ?? "Recording device",
            lastConnected: stamp > 0 ? Date(timeIntervalSinceReferenceDate: stamp) : nil))
        // The legacy keys are deliberately LEFT IN PLACE — see rule 2 in the file header.
        return .adopted(identity)
    }
}

// MARK: - The signed-out hold

public enum RecordingDeviceHoldOutcome: Equatable, Sendable {
    case adopted([RecordingDeviceIdentity])
    case nothingHeld
    case alreadyConsumed
}

public enum RecordingDeviceHold {
    /// The `acct-none` store: where a device paired while signed out is RETAINED, without
    /// being assigned to an arbitrary account.
    public static func signedOutStore(container: URL) -> RecordingDeviceStore {
        RecordingDeviceStore(
            root: container.appendingPathComponent(CaptureAccountScope.signedOutScope,
                                                   isDirectory: true),
            scope: CaptureAccountScope.signedOutScope)
    }

    /// The EXPLICIT migration rule: the first account to sign in after a signed-out hold
    /// adopts it, and the hold is marked consumed so a second account gets nothing.
    /// Signed-out records never cross into an account any other way.
    /// Written into the signed-out scope once a hold has been handed to an account, so a
    /// SECOND account signing in on the same handset inherits nothing.
    static let consumedMarkerName = "recording-devices.hold-consumed"

    @discardableResult
    public static func adopt(
        into store: RecordingDeviceStore,
        container: URL
    ) throws -> RecordingDeviceHoldOutcome {
        guard !store.isSignedOutScope else {
            throw RecordingDeviceStoreError.wrongScope(store.scope)
        }
        let hold = signedOutStore(container: container)
        let marker = hold.root.appendingPathComponent(consumedMarkerName)
        if FileManager.default.fileExists(atPath: marker.path) {
            return .alreadyConsumed
        }
        let held = try hold.records()
        guard !held.isEmpty else { return .nothingHeld }

        var adopted: [RecordingDeviceIdentity] = []
        for record in held where try !store.records().contains(where: { $0.identity == record.identity }) {
            try store.upsert(record)
            adopted.append(record.identity)
        }
        // Consume BEFORE clearing, so a crash between the two leaves the hold visible but
        // already claimed rather than silently re-adoptable by the next account.
        try FileManager.default.createDirectory(at: hold.root, withIntermediateDirectories: true)
        try Data(store.scope.utf8).write(to: marker, options: .atomic)
        try hold.replaceAll([])
        return .adopted(adopted)
    }
}

// MARK: - Active selection

public enum RecordingDeviceActivation {
    /// At most one device is active. A detached device never is. Among the remembered
    /// devices that are READY, the user's preference wins; failing that, the most
    /// recently connected; failing that, a stable tiebreak on the identity.
    ///
    /// Vendor identity and device shape are ABSENT from this comparison by construction —
    /// that is the whole point, and it is asserted by substitution, not by inspection.
    public static func active(
        among records: [RecordingDeviceRecord],
        ready: Set<RecordingDeviceIdentity>
    ) -> RecordingDeviceRecord? {
        records
            .filter { !$0.userDetached && ready.contains($0.identity) }
            .max { left, right in
                if left.userPreferred != right.userPreferred { return right.userPreferred }
                let leftSeen = left.lastConnected ?? .distantPast
                let rightSeen = right.lastConnected ?? .distantPast
                if leftSeen != rightSeen { return leftSeen < rightSeen }
                return left.identity.hardwareToken > right.identity.hardwareToken
            }
    }
}

// MARK: - The privacy reference

/// An opaque, account-scoped reference to a device. It carries no display name and no raw
/// hardware identifier, and two accounts holding the SAME physical device derive different
/// references, so device status cannot correlate people across accounts.
public struct DeviceRef: Hashable, Sendable, Codable {
    public let hex: String
    public init(hex: String) { self.hex = hex }
}

public enum DeviceStatusWithheldReason: String, Equatable, Sendable, Codable {
    case noAccountKey = "no_account_key"
}

public enum DeviceStatusEmission: Equatable, Sendable {
    case emit(DeviceRef)
    /// No outbound record at all. Recorded locally, typed, never a fabricated ref.
    case withheld(DeviceStatusWithheldReason)
}

/// The account secret the reference is keyed on. Named explicitly so it can never drift
/// into an enumerable scope name.
public protocol AccountKeyMaterialProviding: Sendable {
    func accountKeyMaterial() -> String?
}

/// Production: the provider-qualified material on the signed-in identity.
public struct SignedInAccountKeyMaterial: AccountKeyMaterialProviding {
    public init() {}
    public func accountKeyMaterial() -> String? { AuthStore.load()?.accountKeyMaterial }
}

public enum DeviceRefDerivation {
    /// Domain separation, so this HMAC can never collide with another use of the same
    /// account secret.
    public static let domain = "foundryx.device-ref.v1"

    /// HMAC-SHA256 over the device identity, keyed by a secret derived from the ACCOUNT
    /// KEY MATERIAL under a separated domain, truncated to 128 bits and rendered as hex.
    ///
    /// HONEST LIMIT. The plan names `accountKeyMaterial` as the key source, and for an
    /// email-fallback identity that material is guessable by someone who knows the address.
    /// What this construction does buy — and what R7 asks for — is that ONE account's
    /// device status cannot be correlated with another account's: the same physical device
    /// derives different references under different accounts, and the reference carries
    /// neither the display name nor the raw hardware identifier. It is not claimed to be
    /// unguessable.
    public static func ref(for identity: RecordingDeviceIdentity,
                           accountKeyMaterial: String) -> DeviceRef {
        let secret = SymmetricKey(data: Data("\(domain)|key|\(accountKeyMaterial)".utf8))
        let code = HMAC<SHA256>.authenticationCode(
            for: Data("\(domain)|device|\(identity.storageKey)".utf8), using: secret)
        return DeviceRef(hex: code.prefix(16).map { String(format: "%02x", $0) }.joined())
    }

    /// No secret ⇒ NO outbound record. Not a placeholder, not a scope-derived stand-in:
    /// a typed local outcome that says exactly why nothing was sent.
    public static func emission(
        for identity: RecordingDeviceIdentity,
        keyMaterial: AccountKeyMaterialProviding
    ) -> DeviceStatusEmission {
        guard let material = keyMaterial.accountKeyMaterial(),
              !material.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .withheld(.noAccountKey)
        }
        return .emit(ref(for: identity, accountKeyMaterial: material))
    }
}
