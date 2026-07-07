import Foundation
import AuthenticationServices
import CryptoKit
import Security

// FoundryX phone sign-in (M5 R1b). "Continue with Google" / "Continue with
// Microsoft" — the SAME accounts the user uses for Foundry. A native OAuth
// (ASWebAuthenticationSession + PKCE, NO client secret on device) yields the
// provider's OIDC id_token; the hosted gateway verifies THAT directly against
// Google/Microsoft public keys and derives the account from the verified email,
// so the phone never holds a Foundry-issued credential and the relay stays blind.
//
// NOT YET COMPILE-VERIFIED in CI — written against the documented Apple APIs;
// validate in Xcode. Activation needs the OAuth client-ids (see the track's
// oauth-client-setup.md) supplied via Info.plist (FoundryXOAuth dict).

public enum AuthProvider: String, Sendable, CaseIterable {
    case apple
    case google
    case microsoft
}

public struct AuthIdentity: Sendable, Codable {
    public let provider: String
    public let idToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let email: String?
    /// Display name — Apple surfaces it ONLY on the very first authorization
    /// (track 20260705T1100 decision #5), so it is captured here or lost.
    public let name: String?

    public init(provider: String, idToken: String, refreshToken: String?,
                expiresAt: Date, email: String?, name: String? = nil) {
        self.provider = provider
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.email = email
        self.name = name
    }

    // Tolerate identities stored before `name` existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        idToken = try c.decode(String.self, forKey: .idToken)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }
}

public enum AuthError: Error, LocalizedError {
    case notConfigured(String)
    case cancelled
    case providerError(String)
    case noIdToken

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return "Sign-in not configured: \(s)"
        case .cancelled: return "Sign-in was cancelled"
        case .providerError(let s): return "Sign-in failed: \(s)"
        case .noIdToken: return "Provider returned no id_token"
        }
    }
}

/// OAuth client config, read from the app's Info.plist `FoundryXOAuth` dict so the
/// (non-secret, PKCE) client-ids are build-time configuration, not source. Keys:
///   GoogleIOSClientID   e.g. "NNN-xxxx.apps.googleusercontent.com"
///   MicrosoftClientID   the Entra app (client) GUID
///   MicrosoftTenant     tenant id or "organizations" / "common" (default "organizations")
public struct OAuthConfig: Sendable {
    public let googleClientID: String?
    public let microsoftClientID: String?
    public let microsoftTenant: String

    public init(googleClientID: String?, microsoftClientID: String?, microsoftTenant: String) {
        self.googleClientID = googleClientID
        self.microsoftClientID = microsoftClientID
        self.microsoftTenant = microsoftTenant
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> OAuthConfig {
        let dict = bundle.object(forInfoDictionaryKey: "FoundryXOAuth") as? [String: Any] ?? [:]
        let g = (dict["GoogleIOSClientID"] as? String)?.nonEmpty
        let m = (dict["MicrosoftClientID"] as? String)?.nonEmpty
        let tenant = (dict["MicrosoftTenant"] as? String)?.nonEmpty ?? "organizations"
        return OAuthConfig(googleClientID: g, microsoftClientID: m, microsoftTenant: tenant)
    }

    public func clientID(for provider: AuthProvider) -> String? {
        switch provider {
        case .apple: return nil          // native ASAuthorization flow — no OAuth client
        case .google: return googleClientID
        case .microsoft: return microsoftClientID
        }
    }

    /// The iOS redirect URI. Google uses the reversed client id scheme; Microsoft
    /// uses the MSAL-standard `msauth.<bundle-id>://auth` form.
    public func redirectURI(for provider: AuthProvider, bundleID: String) -> String? {
        switch provider {
        case .apple:
            return nil                   // native flow — no redirect
        case .google:
            guard let cid = googleClientID else { return nil }
            // "NNN-xxxx.apps.googleusercontent.com" → reversed scheme.
            let reversed = cid
                .replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
            return "com.googleusercontent.apps.\(reversed):/oauth2redirect"
        case .microsoft:
            return "msauth.\(bundleID)://auth"
        }
    }
}

public final class FoundryAuth: NSObject, @unchecked Sendable {
    private let config: OAuthConfig
    private let bundleID: String
    private let log: DoorLog?

    public init(config: OAuthConfig = .fromBundle(), bundleID: String = Bundle.main.bundleIdentifier ?? "com.goforgeit.foundryx", log: DoorLog? = nil) {
        self.config = config
        self.bundleID = bundleID
        self.log = log
    }

    /// Whether at least one provider is configured (drives the sign-in UI).
    public func isConfigured(_ provider: AuthProvider) -> Bool {
        if provider == .apple { return true }   // native, no client-id needed
        return config.clientID(for: provider) != nil
    }

    /// Run the interactive OAuth flow for `provider`, persist the identity, and
    /// return it. Throws `AuthError.notConfigured` if the client-id is missing.
    @MainActor
    public func signIn(_ provider: AuthProvider) async throws -> AuthIdentity {
        if provider == .apple {
            let id = try await AppleSignInCoordinator().run()
            AuthStore.save(id)
            return id
        }
        guard let clientID = config.clientID(for: provider) else {
            throw AuthError.notConfigured("\(provider.rawValue) client id not set in Info.plist FoundryXOAuth")
        }
        guard let redirect = config.redirectURI(for: provider, bundleID: bundleID),
              let redirectURL = URL(string: redirect) else {
            throw AuthError.notConfigured("redirect URI")
        }
        let verifier = Self.pkceVerifier()
        let challenge = Self.pkceChallenge(verifier)
        let state = Self.randomURLSafe(24)
        let scheme = redirectURL.scheme!

        let authURL = try authorizeURL(provider, clientID: clientID, redirect: redirect, challenge: challenge, state: state)
        let callback = try await present(authURL: authURL, scheme: scheme)
        guard let code = Self.queryValue(callback, "code") else {
            throw AuthError.providerError(Self.queryValue(callback, "error") ?? "no authorization code")
        }
        let token = try await exchange(provider, clientID: clientID, code: code, verifier: verifier, redirect: redirect)
        AuthStore.save(token)
        return token
    }

    /// A currently-valid id_token for the signed-in account, refreshing via the
    /// stored refresh token when expired. `nil` when signed out / unrefreshable.
    public func currentIdToken() async -> String? {
        guard let id = AuthStore.load() else { return nil }
        if id.expiresAt > Date().addingTimeInterval(60) {
            return id.idToken
        }
        guard let provider = AuthProvider(rawValue: id.provider),
              let clientID = config.clientID(for: provider),
              let refresh = id.refreshToken else { return nil }
        do {
            let fresh = try await refreshToken(provider, clientID: clientID, refresh: refresh)
            AuthStore.save(fresh)
            return fresh.idToken
        } catch {
            log?.error("id_token refresh failed: \(error)")
            return nil
        }
    }

    public func signOut() { AuthStore.clear() }
    public var signedInEmail: String? { AuthStore.load()?.email }
    /// Display name when the provider surfaced one (Apple: first auth only).
    public var signedInName: String? { AuthStore.load()?.name }

    // MARK: provider endpoints

    private func authorizeURL(_ provider: AuthProvider, clientID: String, redirect: String, challenge: String, state: String) throws -> URL {
        var comps: URLComponents
        switch provider {
        case .apple:
            throw AuthError.providerError("apple uses the native flow")
        case .google:
            comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        case .microsoft:
            comps = URLComponents(string: "https://login.microsoftonline.com/\(config.microsoftTenant)/oauth2/v2.0/authorize")!
        }
        // Scopes differ by provider: Google rejects the `offline_access` SCOPE
        // (it uses the `access_type=offline` PARAM below for refresh tokens);
        // Microsoft REQUIRES the `offline_access` scope to return a refresh token.
        let scope = provider == .microsoft
            ? "openid email profile offline_access"
            : "openid email profile"
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: provider == .microsoft ? "prompt" : "access_type",
                  value: provider == .microsoft ? "select_account" : "offline"),
        ]
        guard let url = comps.url else { throw AuthError.providerError("bad authorize URL") }
        return url
    }

    private func tokenEndpoint(_ provider: AuthProvider) -> URL {
        switch provider {
        case .apple: preconditionFailure("apple uses the native flow, never the PKCE token endpoint")
        case .google: return URL(string: "https://oauth2.googleapis.com/token")!
        case .microsoft: return URL(string: "https://login.microsoftonline.com/\(config.microsoftTenant)/oauth2/v2.0/token")!
        }
    }

    private func exchange(_ provider: AuthProvider, clientID: String, code: String, verifier: String, redirect: String) async throws -> AuthIdentity {
        let form = [
            "client_id": clientID,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": redirect,
            "code_verifier": verifier,
        ]
        return try await postToken(provider, form: form, fallbackRefresh: nil)
    }

    private func refreshToken(_ provider: AuthProvider, clientID: String, refresh: String) async throws -> AuthIdentity {
        let form = [
            "client_id": clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ]
        return try await postToken(provider, form: form, fallbackRefresh: refresh)
    }

    private func postToken(_ provider: AuthProvider, form: [String: String], fallbackRefresh: String?) async throws -> AuthIdentity {
        var req = URLRequest(url: tokenEndpoint(provider))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.providerError("token endpoint \( (resp as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = obj["id_token"] as? String else {
            throw AuthError.noIdToken
        }
        let refresh = (obj["refresh_token"] as? String) ?? fallbackRefresh
        let expiresIn = (obj["expires_in"] as? Double) ?? 3300
        let email = Self.emailFromIdToken(idToken)
        return AuthIdentity(
            provider: provider.rawValue,
            idToken: idToken,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            email: email
        )
    }

    // MARK: ASWebAuthenticationSession

    @MainActor
    private func present(authURL: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { callback, error in
                if let error = error {
                    let ns = error as NSError
                    if ns.domain == ASWebAuthenticationSessionError.errorDomain,
                       ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        cont.resume(throwing: AuthError.cancelled)
                    } else {
                        cont.resume(throwing: AuthError.providerError(error.localizedDescription))
                    }
                    return
                }
                guard let callback = callback else {
                    cont.resume(throwing: AuthError.providerError("no callback URL"))
                    return
                }
                cont.resume(returning: callback)
            }
            session.presentationContextProvider = AuthPresenter.shared
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                cont.resume(throwing: AuthError.providerError("could not start auth session"))
            }
        }
    }

    // MARK: helpers

    private static func pkceVerifier() -> String { randomURLSafe(64) }
    private static func pkceChallenge(_ verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
    }
    private static func randomURLSafe(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
    private static func formEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
    private static func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
    private static func emailFromIdToken(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["email"] as? String) ?? (obj["preferred_username"] as? String)
    }
}

/// Presentation anchor for ASWebAuthenticationSession.
final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthPresenter()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

/// Keychain-backed store for the signed-in identity (id_token + refresh).
enum AuthStore {
    private static let service = "com.goforgeit.foundryx.auth"
    private static let account = "identity"

    static func save(_ id: AuthIdentity) {
        guard let data = try? JSONEncoder().encode(id) else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
    static func load() -> AuthIdentity? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let d = item as? Data else { return nil }
        return try? JSONDecoder().decode(AuthIdentity.self, from: d)
    }
    static func clear() {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
