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

    /// The provider's stable OIDC subject. Unlike email, this remains present for
    /// later Apple authorizations and survives address changes.
    public var stableSubject: String? {
        (Self.claims(from: idToken)?["sub"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    /// Minimal provider-qualified material used by CaptureAccountScope. JWT parsing
    /// stays here beside the persisted identity; storage never decodes tokens itself.
    public var accountKeyMaterial: String? {
        guard let provider = AuthProvider(rawValue: provider) else { return nil }
        if let stableSubject {
            return "\(provider.rawValue)|sub|\(stableSubject)"
        }
        let fallback = email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        return fallback.map { "\(provider.rawValue)|email|\($0)" }
    }

    static func claims(from jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

public enum AuthError: Error, LocalizedError {
    case notConfigured(String)
    case cancelled
    case providerError(String)
    case noIdToken
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return "Sign-in not configured: \(s)"
        case .cancelled: return "Sign-in was cancelled"
        case .providerError(let s): return "Sign-in failed: \(s)"
        case .noIdToken: return "Provider returned no id_token"
        case .persistence(let s): return "Sign-in could not secure local data: \(s)"
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

    public init(config: OAuthConfig = .fromBundle(), bundleID: String = Bundle.main.bundleIdentifier ?? "com.goforgeit.foundryx", log: DoorLog? = .shared) {
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
    public func signIn(
        _ provider: AuthProvider,
        recoveryProgress: @escaping @Sendable (DeletionSignInRecoveryEvent) -> Void = { _ in }
    ) async throws -> AuthIdentity {
        if provider == .apple {
            let id = try await AppleSignInCoordinator().run()
            try await saveRecoveringInterruptedDeletion(id, recoveryProgress: recoveryProgress)
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
        try await saveRecoveringInterruptedDeletion(token, recoveryProgress: recoveryProgress)
        return token
    }

    private func saveRecoveringInterruptedDeletion(
        _ identity: AuthIdentity,
        recoveryProgress: @escaping @Sendable (DeletionSignInRecoveryEvent) -> Void
    ) async throws {
        try await AuthStore.save(identity, recoveryProgress: recoveryProgress)
    }

    static func persistAfterRecoveringInterruptedDeletion(
        identity: AuthIdentity,
        persist: @Sendable (AuthIdentity) throws -> Void,
        recover: @Sendable () async throws -> Void
    ) async throws {
        do {
            try persist(identity)
        } catch let error as CaptureAccountScopeError {
            guard case .deletionCleanupPending = error else { throw error }
            do {
                try await recover()
                DeletionRecorder.shared.emit(
                    "account.signin.cleanup_completed", "ok")
                try persist(identity)
            } catch let recoveryError as CaptureAccountScopeError {
                throw recoveryError
            } catch {
                DeletionRecorder.shared.emit(
                    "account.signin.refused", "cleanup_failed \(error)")
                throw CaptureAccountScopeError.deletionCleanupPending(
                    ownerScope: (try? CaptureAccountScope.key(for: identity))
                        ?? "unknown")
            }
        }
    }

    /// A currently-valid id_token for the signed-in account, refreshing via the
    /// stored refresh token when expired. `nil` when signed out / unrefreshable.
    public func currentIdToken() async throws -> String? {
        guard let id = try AuthStore.loadFallibly() else { return nil }
        if id.expiresAt > Date().addingTimeInterval(60) {
            return id.idToken
        }
        guard let provider = AuthProvider(rawValue: id.provider),
              let clientID = config.clientID(for: provider),
              let refresh = id.refreshToken else { return nil }
        do {
            let fresh = try await refreshToken(provider, clientID: clientID, refresh: refresh)
            try await AuthStore.save(fresh)
            return fresh.idToken
        } catch {
            log?.error("id_token refresh failed: \(error)")
            throw error
        }
    }

    public func signOut() throws { try AuthStore.clear() }
    public var signedInEmail: String? { AuthStore.load()?.email }
    public var signedInIdentity: AuthIdentity? { AuthStore.load() }
    public func restorePersistedIdentity() async throws -> AuthIdentity? {
        // A keychain that CANNOT ANSWER is not an error to show the user. Launching
        // while the device is locked returns errSecInteractionNotAllowed, and a
        // simulator/test host returns errSecMissingEntitlement — in both cases
        // `loadFallibly()` throws, `restore()` catches it, and the sign-in screen
        // displayed "Sign-in could not secure local data: reading identity failed".
        // Nothing is wrong: the identity is simply unreadable right now. Return nil so
        // the caller keeps its mirror-derived state, exactly as it already does for a
        // locked launch (Nick 2026-07-28, seen on the launch screen).
        //
        // Crucially this does NOT confirm sign-out: only a READABLE keychain miss may
        // do that, or a locked relaunch would strand an authenticated account.
        switch AuthStore.identityPresence() {
        case .unreadableLocked, .unreadable:
            return nil
        case .absent, .present:
            break
        }
        guard let identity = try AuthStore.loadFallibly() else {
            try CaptureAccountScope.confirmSignedOutAfterReadableKeychain()
            return nil
        }
        try await CaptureAccountScope.restorePersistedIdentity(identity)
        return identity
    }
    /// Lock-screen-safe "is anyone signed in?" — the UserDefaults mirror first (the
    /// keychain is unreadable while the device is locked, exactly when a bluetooth
    /// background relaunch needs the answer), keychain as the fallback for installs
    /// that signed in before the mirror existed.
    public static var hasPersistedSignIn: Bool {
        CaptureAccountScope.hasPersistedActiveScope
    }
    /// Display name when the provider surfaced one (Apple: first auth only; Google/
    /// Microsoft: parsed from the id_token on sign-in).
    public var signedInName: String? { AuthStore.load()?.name }
    /// The provider of the signed-in identity ("google"/"microsoft"/"apple").
    public var signedInProvider: String? { AuthStore.load()?.provider }

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
        let name = Self.nameFromIdToken(idToken)
        return AuthIdentity(
            provider: provider.rawValue,
            idToken: idToken,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            email: email,
            name: name
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
        guard let obj = AuthIdentity.claims(from: jwt) else { return nil }
        return (obj["email"] as? String) ?? (obj["preferred_username"] as? String)
    }
    private static func nameFromIdToken(_ jwt: String) -> String? {
        guard let obj = AuthIdentity.claims(from: jwt) else { return nil }
        if let n = (obj["name"] as? String)?.nonEmpty { return n }
        let full = "\((obj["given_name"] as? String) ?? "") \((obj["family_name"] as? String) ?? "")"
            .trimmingCharacters(in: .whitespaces)
        return full.nonEmpty
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
    /// UserDefaults MIRROR of "someone is signed in" — no secret, just a boolean.
    /// Needed because the keychain item is unreadable while the device is LOCKED,
    /// and the bluetooth-central background relaunch (state restoration) must
    /// decide whether recording is authorized exactly then (phone in pocket).
    /// Self-healing for pre-existing installs: any successful keychain load also
    /// stamps it.
    static let signedInMirrorKey = "foundryx.auth.signed-in"
    #if DEBUG || PERF_HARNESS
    nonisolated(unsafe) private static var identityEraseForTests:
        (() -> AccountSurfaceOutcome)?
    static func setIdentityEraseForTests(
        _ erase: (() -> AccountSurfaceOutcome)?
    ) {
        identityEraseForTests = erase
    }
    #endif

    static func save(
        _ id: AuthIdentity,
        recoveryProgress: @escaping @Sendable (DeletionSignInRecoveryEvent) -> Void = { _ in }
    ) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(id)
        } catch {
            throw AuthError.persistence("identity encoding failed: \(error.localizedDescription)")
        }
        let activation = try await CaptureAccountScope.beginActivation(
            for: id, recoveryProgress: recoveryProgress)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            CaptureAccountScope.rollbackActivation(activation)
            throw securityError(operation: "saving identity", status: status)
        }
        // Filesystem ownership and chat/capture migration must finish before ACTIVE
        // is published. A failure intentionally leaves the durable state pending.
        try await CaptureAccountScope.completeActivation(activation)
    }

    /// Optional presentation lookup. Security-sensitive restoration uses
    /// `loadFallibly()` so a locked keychain is never confused with sign-out.
    static func load() -> AuthIdentity? {
        try? loadFallibly()
    }

    /// Whether an identity is stored, distinguishing the reasons the keychain may not
    /// say. Presence alone is not enough: "no identity" and "cannot read the identity"
    /// have opposite safe answers, and a DEVICE-LOCKED keychain must never be mistaken
    /// for sign-out (that strands authenticated audio in the signed-out scope).
    enum IdentityPresence {
        /// errSecItemNotFound — genuinely never signed in on this install.
        case absent
        /// An identity is stored and readable.
        case present
        /// The device is locked; an identity may well exist. Fail closed.
        case unreadableLocked
        /// The keychain cannot answer at all for a non-lock reason — notably
        /// errSecMissingEntitlement (-34018) in a test host. Not a locked device.
        case unreadable(OSStatus)
    }

    static func identityPresence() -> IdentityPresence {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var item: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &item) {
        case errSecSuccess: return .present
        case errSecItemNotFound: return .absent
        case errSecInteractionNotAllowed, errSecAuthFailed: return .unreadableLocked
        case let status: return .unreadable(status)
        }
    }

    static func loadFallibly() throws -> AuthIdentity? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw securityError(operation: "reading identity", status: status)
        }
        guard let data = item as? Data else {
            throw AuthError.persistence("reading identity returned invalid keychain data")
        }
        do {
            return try JSONDecoder().decode(AuthIdentity.self, from: data)
        } catch {
            throw AuthError.persistence(
                "decoding identity failed: \(error.localizedDescription)")
        }
    }

    static func clear() throws {
        let previousBinding = CaptureAccountScope.currentAccountBinding()
        let detachSnapshot = AccountSurfaceRegistry.captureDetachSnapshot()
        let previous = try CaptureAccountScope.beginSignOut()
        let detached = AccountSurfaceRegistry.detachAll(previous: previousBinding)
        if let failure = detached.sorted(by: { $0.key.rawValue < $1.key.rawValue })
            .first(where: { !$0.value.isTerminalSuccess }) {
            CaptureAccountScope.rollbackSignOut(previousScope: previous)
            let restoration = AccountSurfaceRegistry.restoreDetachSnapshot(detachSnapshot)
            if let restored = CaptureAccountScope.currentAccountBinding() {
                _ = AccountSurfaceRegistry.attachAll(restored)
            }
            guard restoration.isTerminalSuccess else {
                throw AuthError.persistence(
                    "detaching \(failure.key.rawValue) failed and restoring detached state failed: \(restoration)")
            }
            throw AuthError.persistence(
                "detaching \(failure.key.rawValue) failed: \(failure.value)")
        }
        guard eraseIdentityCredential().isTerminalSuccess else {
            CaptureAccountScope.rollbackSignOut(previousScope: previous)
            let restoration = AccountSurfaceRegistry.restoreDetachSnapshot(detachSnapshot)
            if let restored = CaptureAccountScope.currentAccountBinding() {
                _ = AccountSurfaceRegistry.attachAll(restored)
            }
            guard restoration.isTerminalSuccess else {
                throw AuthError.persistence(
                    "clearing identity failed and restoring detached state failed: \(restoration)")
            }
            throw AuthError.persistence("clearing identity failed")
        }
        try CaptureAccountScope.completeSignOut()
    }

    static func eraseIdentityCredential() -> AccountSurfaceOutcome {
        #if DEBUG || PERF_HARNESS
        if let identityEraseForTests { return identityEraseForTests() }
        #endif
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(base as CFDictionary)
        switch status {
        case errSecSuccess: return .done
        case errSecItemNotFound: return .alreadyClean
        #if DEBUG || PERF_HARNESS
        case errSecMissingEntitlement:
            // Hostless iOS tests have no keychain entitlement. Release builds do not
            // carry this exception and therefore fail closed on the same status.
            return .alreadyClean
        #endif
        default:
            return .failed(
                securityError(operation: "clearing identity", status: status)
                    .localizedDescription)
        }
    }

    private static func securityError(operation: String, status: OSStatus) -> AuthError {
        let detail = SecCopyErrorMessageString(status, nil) as String?
            ?? "OSStatus \(status)"
        return .persistence("\(operation) failed: \(detail)")
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
