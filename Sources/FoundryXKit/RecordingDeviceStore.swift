// RecordingDeviceStore — account-scoped memory of the recording devices a person owns.
//
// T2 RED STUB (track 20260725T2306_device_agnostic_recording_source). Types are declared
// so `features/device-account-scope.feature` can be wired and RUN; every body is
// unimplemented so the scenarios fail on real assertions, not on a missing symbol.

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
    public static func current() -> RecordingDeviceStore? { nil }   // T2 RED STUB

    public var isSignedOutScope: Bool { scope == CaptureAccountScope.signedOutScope }

    public var fileURL: URL { root.appendingPathComponent(fileName) }

    public func records() throws -> [RecordingDeviceRecord] { [] }   // T2 RED STUB

    public func replaceAll(_ records: [RecordingDeviceRecord]) throws {}   // T2 RED STUB

    @discardableResult
    public func upsert(_ record: RecordingDeviceRecord) throws -> RecordingDeviceRecord {
        record   // T2 RED STUB
    }

    public func remove(_ identity: RecordingDeviceIdentity) throws {}   // T2 RED STUB

    /// The user detached this device.
    public func detach(_ identity: RecordingDeviceIdentity) throws {}   // T2 RED STUB

    /// The user reconnected this device — the only thing that clears a detach.
    public func reconnect(_ identity: RecordingDeviceIdentity) throws {}   // T2 RED STUB

    /// The user chose this device. At most one device is preferred at a time.
    public func prefer(_ identity: RecordingDeviceIdentity) throws {}   // T2 RED STUB
}

// MARK: - Detach recorded from the transport layer

public enum RecordingDeviceDetachOutcome: Equatable, Sendable {
    case recorded(scope: String)
    /// Loud, typed, never silent: the detach could not be persisted.
    case unavailable(String)
}

extension RecordingDeviceStore {
    @discardableResult
    public static func recordUserDetach(
        identity: RecordingDeviceIdentity,
        displayName: String
    ) -> RecordingDeviceDetachOutcome {
        .unavailable("unimplemented")   // T2 RED STUB
    }

    @discardableResult
    public static func recordUserReconnect(
        identity: RecordingDeviceIdentity
    ) -> RecordingDeviceDetachOutcome {
        .unavailable("unimplemented")   // T2 RED STUB
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
        .nothingToAdopt   // T2 RED STUB
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
    @discardableResult
    public static func adopt(
        into store: RecordingDeviceStore,
        container: URL
    ) throws -> RecordingDeviceHoldOutcome {
        .nothingHeld   // T2 RED STUB
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
        nil   // T2 RED STUB
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

    public static func ref(for identity: RecordingDeviceIdentity,
                           accountKeyMaterial: String) -> DeviceRef {
        _ = (identity, accountKeyMaterial)
        return DeviceRef(hex: "")   // T2 RED STUB
    }

    public static func emission(
        for identity: RecordingDeviceIdentity,
        keyMaterial: AccountKeyMaterialProviding
    ) -> DeviceStatusEmission {
        _ = (identity, keyMaterial)
        return .withheld(.noAccountKey)   // T2 RED STUB
    }
}
