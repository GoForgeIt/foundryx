// AccountClient — the phone side of the account/waitlist pipeline (onboarding
// track 20260705T1100, decisions #5/#7). On first successful sign-in the app
// POSTs an identity-only signup event to the relay's control plane; a waitlist
// tap POSTs the upgrade-intent flag. The relay verifies the id_token and derives
// the account from it — the body only ever carries profile the phone knows
// (name, locale, device, build). NEVER conversation content.
//
// Apple note (decision #5): Apple surfaces name+email ONLY on the very first
// authorization — the sign-in path must pass the name through immediately or
// it is lost forever.

import Foundation

public struct AccountClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    /// `baseURL` = the relay control-plane (RemoteConfig.gatewayHTTPURL).
    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// POST /account/signup. Returns true on a 2xx (best-effort — a failure is
    /// retried on the next launch via the once-flag staying unset).
    @discardableResult
    public func postSignup(idToken: String, name: String?) async -> Bool {
        await postSignup(
            idToken: idToken,
            name: name,
            generation: 0)
    }

    @discardableResult
    public func postSignup(
        idToken: String,
        name: String?,
        generation: UInt64
    ) async -> Bool {
        _ = generation
        return await post("account/signup", idToken: idToken, name: name)
    }

    /// POST /account/waitlist — the one-tap upgrade-intent flag (no form).
    @discardableResult
    public func postWaitlist(idToken: String) async -> Bool {
        await postWaitlist(idToken: idToken, generation: 0)
    }

    @discardableResult
    public func postWaitlist(
        idToken: String,
        generation: UInt64
    ) async -> Bool {
        _ = generation
        return await post("account/waitlist", idToken: idToken, name: nil)
    }

    /// POST /account/delete — the Apple-required in-app account deletion (track T-STOREFRONT).
    /// `scope` is one of "hostedVault" (tear down the cell, keep the account) or "everywhere"
    /// (delete the account + every Vault). The relay verifies the id_token and derives the
    /// account from it; the body carries only the scope. Throws on a non-2xx so the deletion
    /// model can surface a retryable failure rather than a silent no-op.
    public func deleteAccount(scope: AccountDeletionScope, idToken: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("account/delete"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["scope": scope.rawValue])
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AccountDeletionError.server
        }
    }

    private func post(_ path: String, idToken: String, name: String?) async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: Self.profileBody(name: name))
        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// The identity-only profile: what the phone knows about itself. No content,
    /// no email (the relay takes the account from the VERIFIED token only).
    static func profileBody(name: String?) -> [String: String] {
        var body: [String: String] = [
            "locale": Locale.current.identifier,
            "device_model": deviceModel(),
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            body["app_build"] = build
        }
        if let name, !name.isEmpty { body["name"] = name }
        return body
    }

    static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    // ── once-per-account gating (pure, tested) ──────────────────────────────

    /// True only for the currently active generation when its scoped completion
    /// marker is not true. Identity is deliberately not accepted here: activation
    /// sealed the sole historical dynamic read into the scoped snapshot.
    public static func shouldPostSignup(generation: UInt64) -> Bool {
        shouldPostSignup(
            snapshot: AccountPreferences.currentSnapshot(),
            generation: generation)
    }

    public static func shouldPostSignup(
        snapshot: AccountPreferenceSnapshot?,
        generation: UInt64
    ) -> Bool {
        guard let snapshot, snapshot.generation == generation else {
            return false
        }
        return snapshot.presence(
            for: AccountPreferenceCatalog.signupPosted) != .value(true)
    }

    @discardableResult
    public static func completeSignupPost(
        succeeded: Bool,
        generation: UInt64
    ) -> AccountPreferenceWriteResult {
        guard succeeded else { return .rejected }
        return AccountPreferences.write(
            true,
            for: AccountPreferenceCatalog.signupPosted,
            generation: generation)
    }
}
