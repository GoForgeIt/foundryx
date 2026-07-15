// CellStore — the phone's PAIRED hosted cell (rung 3, track 20260705T1100 §3/§5).
// Mirrors BrainStore/DoorConfigStore: the cell's public HTTPS URL + which grant the
// phone presents (its Google/Microsoft sign-in id_token, verified server-side, OR a
// pasted static door bearer). Reconnects to the same cell on launch; UNPAIRING clears
// it (revocation = the server-side door bearer also rotates). Switching is additive,
// never destructive — leaving the cell keeps every local conversation readable.
//
// Persistence split (same discipline as DoorConfigStore): the URL + auth MODE live in
// UserDefaults; a pasted bearer is a secret and lives in the Keychain.

import Foundation
import Security

/// How the phone authenticates to its cell's door.
public enum CellAuth: Equatable, Sendable {
    /// Present the live sign-in id_token (RemoteSession.idToken) — the cell verifies
    /// it (Google/Microsoft OIDC). No secret stored on the phone; rotates for free.
    case idToken
    /// Present a static door bearer the user pasted (the tenant-volume door token).
    /// Stored in the Keychain. Server-side rotation revokes it.
    case bearer(String)

    /// The wire tag persisted in UserDefaults (the bearer VALUE lives in Keychain).
    var mode: String {
        switch self {
        case .idToken: return "idToken"
        case .bearer: return "bearer"
        }
    }
}

/// A paired cell: its public HTTPS base URL + the grant the phone presents.
public struct CellConfig: Equatable, Sendable {
    /// e.g. "https://foundry-cell-acme.fly.dev" — the `/foundryx/*` paths append onto it.
    public let url: String
    public let auth: CellAuth

    public init(url: String, auth: CellAuth) {
        self.url = url
        self.auth = auth
    }
}

/// Durable cell pairing. Reactive (mirrors BrainStore) so RootView re-evaluates the
/// destination the instant a pairing is saved or cleared.
public final class CellStore: ObservableObject, @unchecked Sendable {
    private static let urlKey = "foundryx.cell.url"
    private static let modeKey = "foundryx.cell.authMode"
    private static let keychainService = "com.goforgeit.foundryx.cell"

    private let defaults: UserDefaults

    /// The currently paired cell, or nil when unpaired.
    @Published public private(set) var config: CellConfig?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.config = Self.load(defaults: defaults)
    }

    /// True when a cell is paired (rung 3 is the active/available brain).
    public var isPaired: Bool { config != nil }

    /// Save + publish a pairing. A pasted bearer is written to the Keychain; the
    /// id_token mode stores no secret (the live token is supplied at connect time).
    public func pair(_ config: CellConfig) {
        defaults.set(config.url, forKey: Self.urlKey)
        defaults.set(config.auth.mode, forKey: Self.modeKey)
        switch config.auth {
        case .idToken:
            Self.keychainDelete(service: Self.keychainService)
        case .bearer(let token):
            Self.keychainSet(token, service: Self.keychainService)
        }
        self.config = config
    }

    /// Revocation: forget the cell entirely (also drop any stored bearer). The
    /// server-side door bearer rotates independently.
    public func unpair() {
        defaults.removeObject(forKey: Self.urlKey)
        defaults.removeObject(forKey: Self.modeKey)
        Self.keychainDelete(service: Self.keychainService)
        config = nil
    }

    // MARK: - persistence

    private static func load(defaults: UserDefaults) -> CellConfig? {
        guard let url = defaults.string(forKey: urlKey),
              let mode = defaults.string(forKey: modeKey) else { return nil }
        switch mode {
        case "idToken":
            return CellConfig(url: url, auth: .idToken)
        case "bearer":
            guard let token = keychainGet(service: keychainService) else { return nil }
            return CellConfig(url: url, auth: .bearer(token))
        default:
            return nil
        }
    }

    // MARK: - Keychain (same shape as DoorConfigStore)

    private static func keychainGet(service: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let d = item as? Data, let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }

    private static func keychainSet(_ token: String, service: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func keychainDelete(service: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
    }
}
