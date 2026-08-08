import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

/// The identity shared by Pocket custody and the device list. Neither component is display data.
public struct PocketAuthenticatedIdentity: Hashable, Sendable, Codable {
    public let peripheralIdentifier: String
    public let sessionKeyFingerprint: String

    public init(peripheralIdentifier: String, sessionSecret: String) throws {
        let peripheral = peripheralIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peripheral.isEmpty, sessionSecret.utf8.count == 16,
              sessionSecret.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw PocketIdentityError.missingOrInvalidComponent
        }
        self.peripheralIdentifier = peripheral.lowercased()
        self.sessionKeyFingerprint = SHA256.hash(data: Data(sessionSecret.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The exact `hardwareToken` T3 supplies to `RecordingDeviceIdentity(.filePull, ...)`.
    /// Keeping composition here prevents custody and list identity from drifting apart.
    public var hardwareToken: String {
        "\(peripheralIdentifier)/\(sessionKeyFingerprint)"
    }

    public var storageKey: String { "filePull/\(hardwareToken)" }
}

public enum PocketIdentityError: Error, Equatable, Sendable {
    case missingOrInvalidComponent
    case mismatchedComponents
}

public enum PocketSecretStoreError: Error, Equatable, Sendable { case unavailable }

public protocol PocketSecretStore: Sendable {
    func save(_ secret: String, for identity: PocketAuthenticatedIdentity) async throws
    func secret(for identity: PocketAuthenticatedIdentity) async throws -> String?
}

public actor InMemoryPocketSecretStore: PocketSecretStore {
    private var values: [String: String] = [:]
    public init() {}
    public func save(_ secret: String, for identity: PocketAuthenticatedIdentity) throws {
        values[identity.storageKey] = secret
    }
    public func secret(for identity: PocketAuthenticatedIdentity) -> String? {
        values[identity.storageKey]
    }
}

/// Production custody. The account is the authenticated composite identity, never a local name.
public actor KeychainPocketSecretStore: PocketSecretStore {
    public static let defaultService = "com.foundryx.pocket.session-secret"
    private let service: String
    public init(service: String = defaultService) { self.service = service }

    public func save(_ secret: String, for identity: PocketAuthenticatedIdentity) throws {
#if canImport(Security)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identity.storageKey,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        var add = base
        attributes.forEach { add[$0] = $1 }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(base as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
                throw PocketSecretStoreError.unavailable
            }
        } else if status != errSecSuccess {
            throw PocketSecretStoreError.unavailable
        }
#else
        throw PocketSecretStoreError.unavailable
#endif
    }

    public func secret(for identity: PocketAuthenticatedIdentity) throws -> String? {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identity.storageKey,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw PocketSecretStoreError.unavailable
        }
        return value
#else
        return nil
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
        guard let identity,
              (try? PocketAuthenticatedIdentity(peripheralIdentifier: identity.peripheralIdentifier,
                                                sessionSecret: candidate)) == identity else {
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
    public func restore(identity: PocketAuthenticatedIdentity) async -> PocketOnboardingState {
        guard let secret = try? await store.secret(for: identity) else {
            return .coexistenceAvailable
        }
        guard await client.authenticate(secret: secret) == .accepted,
              let confirmation = try? await client.confirmation() else {
            await client.close()
            return .recoveryRequired
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
    public static let didNotFinish = PocketSetupPresentation(
        title: "Set up Pocket", body: "Setup didn't finish. Try again before you close this.", actions: ["Try again"])
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
    public static let all = [setup, didNotFinish, acceptedNotDurable, ready, indeterminate, keepBothApps, quarantined]
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

public enum PocketRecordingDelivery: Equatable, Sendable { case pullAfterTheFact }
public enum PocketOnboardingCapabilities {
    public static let delivery: PocketRecordingDelivery = .pullAfterTheFact
    public static let hasLiveRecordingSurface = false
}
