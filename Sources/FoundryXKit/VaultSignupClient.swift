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
                                  idToken: idToken)
        guard let id = (json["checkout_attempt_id"] as? String) ?? (json["id"] as? String), !id.isEmpty else {
            throw VaultSignupError.malformedResponse
        }
        let url = (json["checkout_url"] as? String).flatMap(URL.init(string:))
        return VaultCheckoutAttempt(id: id, checkoutURL: url)
    }

    public func reconcile(attemptId: String, idToken: String?) async throws -> VaultProvisionStatus {
        let json = try await post("signup/reconcile",
                                  body: ["checkout_attempt_id": attemptId],
                                  idToken: idToken)
        return try Self.status(from: json)
    }

    public func exchangeReturn(ticket: String, idToken: String?) async throws -> VaultProvisionStatus {
        let json = try await post("app/return", body: ["ticket": ticket], idToken: idToken)
        return try Self.status(from: json)
    }

    // MARK: - wire

    private func post(_ path: String, body: [String: String], idToken: String?) async throws -> [String: Any] {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let idToken, !idToken.isEmpty {
            req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VaultSignupError.server
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VaultSignupError.malformedResponse
        }
        return obj
    }

    /// Parse the shared {status, cell_url?, handoff?} shape into a VaultProvisionStatus.
    static func status(from json: [String: Any]) throws -> VaultProvisionStatus {
        let raw = (json["status"] as? String)?.lowercased() ?? "pending"
        switch raw {
        case "ready", "live", "active":
            guard let cellURL = json["cell_url"] as? String,
                  let handoff = (json["handoff"] as? String) ?? (json["door_bearer"] as? String),
                  !cellURL.isEmpty, !handoff.isEmpty else {
                throw VaultSignupError.malformedResponse
            }
            return .ready(cellURL: cellURL, handoff: handoff)
        case "provisioning", "building", "setting_up":
            return .provisioning
        default:
            return .pending
        }
    }
}

public enum VaultSignupError: Error, Equatable, Sendable {
    case server
    case malformedResponse
}
