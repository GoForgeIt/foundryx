// AppleSignIn — native Sign in with Apple (track 20260705T1100, Phase 6, locked
// decision #5: Apple leads the forced login — App Store rule + name/email on 100%
// of installs). ASAuthorizationController yields a provider-signed id_token
// (iss=appleid.apple.com, aud=<bundle id>) the relay verifies exactly like
// Google/MS. TWO Apple-specific truths this file owns:
//   • name + email arrive ONLY on the very first authorization — captured here
//     into AuthIdentity or lost forever;
//   • Apple id_tokens are short-lived with NO refresh — fine for the phone-only
//     tier (one signup POST, then fully offline); the ongoing relay-bearer path
//     ("My computer") keeps Google/MS until the account backend mints its own
//     long-lived tokens.

import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class AppleSignInCoordinator: NSObject {
    private var continuation: CheckedContinuation<AuthIdentity, Error>?

    func run() async throws -> AuthIdentity {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        defer { continuation = nil }
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            continuation?.resume(throwing: AuthError.noIdToken)
            return
        }
        // First-authorization-only fields — persist NOW or they never come again.
        let name = cred.fullName.flatMap { pn -> String? in
            let joined = [pn.givenName, pn.familyName].compactMap { $0 }.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        let email = cred.email ?? Self.emailClaim(token)
        continuation?.resume(returning: AuthIdentity(
            provider: AuthProvider.apple.rawValue,
            idToken: token,
            refreshToken: nil,                                   // Apple: no refresh
            expiresAt: Date().addingTimeInterval(9 * 60),        // ~10 min validity
            email: email,
            name: name))
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        defer { continuation = nil }
        if let e = error as? ASAuthorizationError, e.code == .canceled {
            continuation?.resume(throwing: AuthError.cancelled)
        } else {
            continuation?.resume(throwing: AuthError.providerError(error.localizedDescription))
        }
    }

    /// Base64url-decode the id_token payload and read `email` (repeat sign-ins
    /// omit `cred.email` but the token still carries the claim).
    static func emailClaim(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["email"] as? String
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if canImport(UIKit)
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
#endif
