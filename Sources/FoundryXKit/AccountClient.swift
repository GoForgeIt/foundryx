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
        await post("account/signup", idToken: idToken, name: name)
    }

    /// POST /account/waitlist — the one-tap upgrade-intent flag (no form).
    @discardableResult
    public func postWaitlist(idToken: String) async -> Bool {
        await post("account/waitlist", idToken: idToken, name: nil)
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

    /// UserDefaults key marking that this account's signup event was durably
    /// accepted by the relay. Unset ⇒ post (again) on the next sign-in/restore —
    /// a failed POST self-heals.
    public static func signupPostedKey(for account: String) -> String {
        "foundryx.account.signup-posted.\(account.lowercased())"
    }

    /// True when a signup POST should fire for this sign-in.
    public static func shouldPostSignup(account: String, defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: signupPostedKey(for: account))
    }

    public static func markSignupPosted(account: String, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: signupPostedKey(for: account))
    }
}
