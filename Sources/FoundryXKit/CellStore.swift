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

    private let defaults: UserDefaults
    private let keychainService: String

    /// The currently paired cell, or nil when unpaired.
    @Published public private(set) var config: CellConfig?

    public init(
        defaults: UserDefaults = .standard,
        keychainService: String = "com.goforgeit.foundryx.cell"
    ) {
        self.defaults = defaults
        self.keychainService = keychainService
        self.config = Self.load(defaults: defaults, keychainService: keychainService)
    }

    /// True when a cell is paired (rung 3 is the active/available brain).
    public var isPaired: Bool { config != nil }

    /// Save + publish a pairing. A pasted bearer is written to the Keychain; the
    /// id_token mode stores no secret (the live token is supplied at connect time).
    @discardableResult
    public func pair(_ config: CellConfig) -> Bool {
        guard let scoped = CaptureAccountScope.currentScopedPreferences() else {
            return false
        }
        switch config.auth {
        case .idToken:
            // Best-effort cleanup of any stale bearer for THIS scope. There is no
            // secret to store in idToken mode, so a failed delete of a possibly
            // absent item must not fail the pairing — doing so made a live Vault
            // unreachable on any host whose Keychain returns an error at all.
            // Anything left behind is this same account's own scoped item and is
            // never read in idToken mode.
            _ = Self.keychainDelete(
                service: keychainService,
                scope: scoped.scope)
        case .bearer(let token):
            guard Self.keychainSet(
                token,
                service: keychainService,
                scope: scoped.scope) else { return false }
        }
        defaults.set(config.url, forKey: scoped.key(Self.urlKey))
        defaults.set(config.auth.mode, forKey: scoped.key(Self.modeKey))
        self.config = config
        return true
    }

    /// Revocation: forget the cell entirely (also drop any stored bearer). The
    /// server-side door bearer rotates independently.
    @discardableResult
    public func unpair() -> Bool {
        guard let scoped = CaptureAccountScope.currentScopedPreferences() else {
            return false
        }
        defaults.removeObject(forKey: scoped.key(Self.urlKey))
        defaults.removeObject(forKey: scoped.key(Self.modeKey))
        guard Self.keychainDelete(
            service: keychainService,
            scope: scoped.scope) else { return false }
        config = nil
        return true
    }

    /// Re-read the complete pairing after the account owner changes. A blocked
    /// transition resolves to nil immediately and never consults an unscoped key.
    public func reloadForIdentityTransition() {
        config = Self.load(
            defaults: defaults,
            keychainService: keychainService)
    }

    // MARK: - persistence

    private static func load(
        defaults: UserDefaults,
        keychainService: String
    ) -> CellConfig? {
        guard let scoped = CaptureAccountScope.currentScopedPreferences(),
              let url = defaults.string(forKey: scoped.key(urlKey)),
              let mode = defaults.string(forKey: scoped.key(modeKey)) else {
            return nil
        }
        switch mode {
        case "idToken":
            return CellConfig(url: url, auth: .idToken)
        case "bearer":
            guard let token = keychainGet(
                service: keychainService,
                scope: scoped.scope) else { return nil }
            return CellConfig(url: url, auth: .bearer(token))
        default:
            return nil
        }
    }

    // MARK: - Keychain (same shape as DoorConfigStore)

    private static func keychainGet(service: String, scope: String) -> String? {
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

    private static func keychainSet(
        _ token: String,
        service: String,
        scope: String
    ) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: scope]
        let deleteStatus = SecItemDelete(base as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound
        else { return false }
        var add = base; add[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func keychainDelete(
        service: String,
        scope: String
    ) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: scope]
        let status = SecItemDelete(base as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
