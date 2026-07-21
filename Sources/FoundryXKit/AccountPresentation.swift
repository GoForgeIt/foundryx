/// The Account section's identity block (Settings → Account). A pure, tested slice
/// so the row reliably shows WHO is signed in — the account name when the provider
/// surfaced one, otherwise the email — and flips to a "Not signed in / Sign in"
/// affordance the instant sign-out clears the session. UI-free by design; the
/// SwiftUI row renders exactly this.
public struct AccountPresentation: Equatable, Sendable {
    public let isSignedIn: Bool
    /// The main line. Signed in: the name when known, else the email, else a bare
    /// "Signed in". Signed out: "Not signed in".
    public let primary: String
    /// The email, shown UNDER the name — only when a distinct name is the primary.
    public let secondary: String?
    /// "Signed in with Google/Microsoft/Apple", when the provider is known.
    public let providerLine: String?

    public static func make(signedIn: Bool, email: String?, name: String?, provider: String?) -> AccountPresentation {
        guard signedIn else {
            return AccountPresentation(isSignedIn: false, primary: "Not signed in",
                                       secondary: nil, providerLine: nil)
        }
        let cleanEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let providerLine = providerLabel(provider).map { "Signed in with \($0)" }
        if let n = cleanName {
            // Show the email under the name, unless the "name" IS the email (some
            // providers echo the address as the name — no point printing it twice).
            return AccountPresentation(isSignedIn: true, primary: n,
                                       secondary: (cleanEmail == n ? nil : cleanEmail),
                                       providerLine: providerLine)
        }
        return AccountPresentation(isSignedIn: true, primary: cleanEmail ?? "Signed in",
                                   secondary: nil, providerLine: providerLine)
    }

    static func providerLabel(_ provider: String?) -> String? {
        switch provider?.lowercased() {
        case "google": return "Google"
        case "microsoft": return "Microsoft"
        case "apple": return "Apple"
        case .some(let other) where !other.isEmpty: return other.prefix(1).uppercased() + other.dropFirst()
        default: return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
