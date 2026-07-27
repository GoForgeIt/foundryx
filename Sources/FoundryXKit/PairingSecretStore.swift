import Foundation
import Security

enum PairingSecretUpdateResult: Equatable, Sendable {
    case updated
    case notFound
    case failed
}

enum PairingSecretReadResult: Equatable, Sendable {
    case found(String)
    case notFound
    case unavailable
    case failed
}

enum PairingSecretRemovalResult: Equatable, Sendable {
    case removed
    case notFound
    case unavailable
    case failed

    var succeeded: Bool {
        self == .removed || self == .notFound
    }
}

/// The secure-storage boundary for account-scoped Cell and Door pairing secrets.
///
/// Production uses `SystemPairingSecretStore`; tests inject a scripted store so
/// failure paths are deterministic instead of depending on an OS Keychain outage.
protocol PairingSecretStore: Sendable {
    func read(service: String, account: String) -> String?
    func inspect(service: String, account: String) -> PairingSecretReadResult
    func update(
        _ value: String,
        service: String,
        account: String
    ) -> PairingSecretUpdateResult
    func add(_ value: String, service: String, account: String) -> Bool
    func remove(service: String, account: String) -> Bool
    func removeExplicitOwner(
        service: String,
        account: String
    ) -> PairingSecretRemovalResult
}

struct SystemPairingSecretStore: PairingSecretStore {
    init() {}

    func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(
            query as CFDictionary,
            &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func update(
        _ value: String,
        service: String,
        account: String
    ) -> PairingSecretUpdateResult {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        switch status {
        case errSecSuccess:
            return .updated
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed
        }
    }

    func add(_ value: String, service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func remove(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

extension PairingSecretStore {
    func replace(_ value: String, service: String, account: String) -> Bool {
        switch update(value, service: service, account: account) {
        case .updated:
            return true
        case .notFound:
            return add(value, service: service, account: account)
        case .failed:
            return false
        }
    }
}

extension SystemPairingSecretStore {
    func inspect(
        service: String,
        account: String
    ) -> PairingSecretReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return .failed
            }
            return .found(value)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed, errSecNotAvailable:
            return .unavailable
        default:
            return .failed
        }
    }

    func removeExplicitOwner(
        service: String,
        account: String
    ) -> PairingSecretRemovalResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        switch SecItemDelete(query as CFDictionary) {
        case errSecSuccess:
            return .removed
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed, errSecNotAvailable:
            return .unavailable
        default:
            return .failed
        }
    }
}
