// VaultSignupClient — the live implementation of the VaultSignupService seam, talking to
// the deployed foundry-signup service (Cloud Run). The endpoints (track T-RETURN-RECON):
//   POST /signup/checkout-attempt  {plan, ...}          → {checkout_attempt_id, checkout_url?}
//   POST /signup/reconcile         Bearer id_token       → {status, cell_url?, handoff?}
//   POST /app/return               {ticket}              → {status, cell_url?, handoff?}
// Status strings: "pending" | "provisioning" | "ready". `ready` carries cell_url + handoff.
//
// Wire shape mirrors AccountClient: identity-only body, Bearer id_token when present, no
// content ever. The hermetic funnel test stubs the VaultSignupService seam directly and
// never touches this client or the network; VaultSignupClientTests proves the wire shape
// against a URLProtocol stub.

import Foundation

public struct VaultSignupClient: VaultSignupService {
    /// The deployed service base, e.g. https://foundry-signup-449450484577.us-central1.run.app
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func createCheckoutAttempt(plan: VaultPlan, idToken: String?) async throws -> VaultCheckoutAttempt {
        let json = try await post("signup/checkout-attempt",
                                  body: ["plan": plan.rawValue],
                                  idToken: idToken,
                                  requiresCredential: true)
        guard let id = (json["checkout_attempt_id"] as? String) ?? (json["id"] as? String), !id.isEmpty else {
            throw VaultSignupError.malformedResponse
        }
        let url = (json["checkout_url"] as? String).flatMap(URL.init(string:))
        return VaultCheckoutAttempt(id: id, checkoutURL: url)
    }

    public func reconcile(attemptId: String, idToken: String?) async throws -> VaultProvisionStatus {
        let json = try await post("signup/reconcile",
                                  body: ["checkout_attempt_id": attemptId],
                                  idToken: idToken,
                                  requiresCredential: true)
        // CREDENTIALED: this call is authenticated with a verified id_token, so a
        // `ready` answer is expected to carry the door credential. One that does
        // not is a Vault we cannot open, and it is reported as such.
        return try Self.status(from: json, credentialed: true)
    }

    public func exchangeReturn(ticket: String, idToken: String?) async throws -> VaultProvisionStatus {
        let json = try await post("app/return", body: ["ticket": ticket],
                                  idToken: idToken, requiresCredential: false)
        // UNCREDENTIALED: the return ticket travels through a browser and the OS,
        // so the server deliberately withholds the door credential here. A `ready`
        // answer with no credential is the CONTRACT on this path, not a fault —
        // it means "go ask the authenticated endpoint", which is exactly what the
        // funnel does with `.pending`.
        return try Self.status(from: json, credentialed: false)
    }

    // MARK: - wire

    private func post(_ path: String, body: [String: String], idToken: String?,
                      requiresCredential: Bool) async throws -> [String: Any] {
        if requiresCredential, idToken?.isEmpty != false {
            // Do not knowingly send the headerless request that production maps to 401.
            throw VaultSignupError.credentialUnavailable
        }
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let idToken, !idToken.isEmpty {
            req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw VaultSignupError.server }
        if http.statusCode == 401 || http.statusCode == 403 {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let reason = ((object?["reason"] as? String)
                ?? (object?["error"] as? String)
                ?? (object?["message"] as? String) ?? "").lowercased()
            if reason.contains("expired") { throw VaultSignupError.credentialExpired }
            if reason.contains("present the google id_token") {
                throw VaultSignupError.credentialUnavailable
            }
            throw VaultSignupError.requestRejected
        }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let reason = (object?["reason"] as? String)
                ?? (object?["error"] as? String)
                ?? (object?["message"] as? String)
            if let reason, !reason.isEmpty { throw VaultSignupError.provisioning(reason) }
            throw VaultSignupError.server
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VaultSignupError.malformedResponse
        }
        return obj
    }

    /// Parse the shared {status, cell_url?, handoff?} shape into a VaultProvisionStatus.
    ///
    /// `credentialed` says whether this response was supposed to carry the door
    /// credential. It matters because a `ready` with no credential means two
    /// completely different things on the two endpoints, and collapsing them is
    /// what made the pairing failure invisible: this used to THROW
    /// `.malformedResponse` in both cases, and the funnel routed that throw into
    /// the branch reserved for network blips — so the phone sat on "Setting up…"
    /// forever and quietly went back to recording locally.
    static func status(from json: [String: Any], credentialed: Bool) throws -> VaultProvisionStatus {
        let raw = (json["status"] as? String)?.lowercased() ?? "pending"
        switch raw {
        case "ready", "live", "active":
            let cellURL = (json["cell_url"] as? String) ?? ""
            let handoff = ((json["handoff"] as? String) ?? (json["door_bearer"] as? String)) ?? ""
            if !cellURL.isEmpty, !handoff.isEmpty {
                return .ready(cellURL: cellURL, handoff: handoff)
            }
            // Uncredentialed (the return-ticket exchange): the credential was
            // never going to be here. `.pending` sends the funnel straight to the
            // authenticated reconcile, which is where it is issued.
            guard credentialed else { return .pending }
            // Credentialed: the Vault says it is ready and we have no way in.
            // TERMINAL and VISIBLE — never a throw the caller can mistake for a
            // dropped connection.
            return .failed(.cannotOpenVault)
        case "provisioning", "building", "setting_up":
            return .provisioning
        case "pending":
            return .pending
        case "failed":
            let reason = (json["reason"] as? String) ?? (json["error"] as? String)
                ?? (json["message"] as? String)
            if let reason, reason.lowercased().contains("already exists") {
                return .failed(.alreadyExists)
            }
            if let reason, !reason.isEmpty { return .failed(.server(reason)) }
            return .failed(.provisioningFailed)
        case "suspended":
            return .failed(.suspended)
        case "unentitled":
            return .failed(.notEntitled)
        case "vault_absent":
            // The hosted Vault was deliberately deleted and the ACCOUNT kept, so
            // there is nothing to connect to yet and nothing has gone wrong. The
            // authenticated reconcile provisions a replacement, so this is a
            // "ask again", not a failure — and NOT `.unknown`, which would put
            // "something went wrong" in front of someone whose Vault is simply
            // being rebuilt.
            return .pending
        default:
            // An unrecognised status is TERMINAL, not progress. The old `default:
            // return .pending` meant any status this build had not heard of — including
            // every one above — rendered as an eternal "Checking your payment…". A
            // paying user sat in that spinner for five hours. Surfacing an unknown state
            // is recoverable; spinning on it is not.
            return .failed(.unknown(raw))
        }
    }
}

public enum VaultSignupError: Error, Equatable, Sendable {
    case server
    case provisioning(String)
    case malformedResponse
    /// The server REJECTED our bearer (401/403). Distinct from `.server` because the
    /// remedy is different and the old code could not tell them apart: `reconcileOnForeground`
    /// treated every thrown error as a passing network blip and silently kept waiting, so
    /// a phone signing with an hour-old (expired) id_token retried forever, invisibly.
    /// Every reconcile from the owner's phone on 2026-07-28 returned 401 and none of them
    /// surfaced anything.
    case unauthorized
    case credentialUnavailable
    case credentialExpired
    case requestRejected
}
