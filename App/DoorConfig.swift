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
        guard let url = UserDefaults.standard.string(forKey: urlKey),
              let bearer = keychainGet() else { return nil }
        return DoorConfig(url: url, bearer: bearer)
    }
    static func save(_ c: DoorConfig) {
        UserDefaults.standard.set(c.url, forKey: urlKey)
        keychainSet(c.bearer)
    }
    private static func keychainGet() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let d = item as? Data, let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }
    private static func keychainSet(_ token: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
