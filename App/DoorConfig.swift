import Foundation
import Security

public struct DoorConfig: Equatable {
    public let url: String
    public let bearer: String
    public init?(url: String, bearer: String) {
        guard URL(string: url) != nil, !bearer.isEmpty else { return nil }
        self.url = url; self.bearer = bearer
    }
    public var doorURL: URL { URL(string: url)! }
}

/// Door URL + bearer persisted in the iOS Keychain (token) + UserDefaults (url).
enum DoorConfigStore {
    private static let service = "com.goforgeit.foundryx.door"
    private static let urlKey = "foundryx.door.url"

    static func load() -> DoorConfig? {
        guard let scoped = CaptureAccountScope.currentScopedPreferences(),
              let url = UserDefaults.standard.string(
                forKey: scoped.key(urlKey)),
              let bearer = keychainGet(scope: scoped.scope) else { return nil }
        return DoorConfig(url: url, bearer: bearer)
    }
    @discardableResult
    static func save(_ c: DoorConfig) -> Bool {
        guard let scoped = CaptureAccountScope.currentScopedPreferences(),
              keychainSet(c.bearer, scope: scoped.scope) else { return false }
        UserDefaults.standard.set(c.url, forKey: scoped.key(urlKey))
        return true
    }
    private static func keychainGet(scope: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: scope,
                                kSecMatchLimit as String: kSecMatchLimitOne,
                                kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let d = item as? Data, let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }
    private static func keychainSet(_ token: String, scope: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: scope]
        let deleteStatus = SecItemDelete(base as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound
        else { return false }
        var add = base; add[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
