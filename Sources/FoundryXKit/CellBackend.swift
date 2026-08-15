// CellBackend — the hosted-cell brain (rung 3, track 20260705T1100 §5).
//
// A cell serves the SAME FoundryX door surface as the desktop ("my computer") —
// `/foundryx/chat`, `/foundryx/capture/{id}/{finalize,status,content,audio}`,
// `/foundryx/models`, approvals — but over a DIRECT public HTTPS URL instead of the
// blind relay (a cell has a public address, so there is no NAT to tunnel and no relay
// in the path). That makes rung 3 the DoorClient's plain LAN-direct path (relay = nil)
// pointed at `https://foundry-cell-<tenant>.fly.dev`, with the door grant — the user's
// verified sign-in id_token OR a pasted static door bearer — in the `Authorization`
// header. DoorClient already speaks every one of those endpoints and already conforms
// to CaptureBackend, so CellBackend REUSES it verbatim: zero duplicated endpoint or
// wire-type logic. CellBackend's own job is only to (1) validate + normalize the cell
// URL, (2) resolve the grant into a bearer, and (3) hand back a DoorTarget/DoorClient
// the whole app (capture pipeline, chat, model picker) drives exactly like the desktop.

import Foundation

public enum CellBackendError: Error, Equatable, Sendable {
    /// The entered text isn't a usable URL.
    case invalidURL
    /// A cell must be reached over HTTPS (public internet, verified grant) — never
    /// plaintext HTTP. Fail loud rather than downgrade silently.
    case insecureScheme
    /// The pairing selected id_token auth but no live id_token is available (signed
    /// out / refresh failed), or bearer auth with an empty token.
    case missingAuth
}

/// The hosted-cell brain. Conforms to `CaptureBackend` (finalize / status / content)
/// by delegating to a `DoorClient` built for the cell; also exposes that `door` +
/// `target` so chat and the model picker reuse the identical door surface.
public struct CellBackend: CaptureBackend, @unchecked Sendable {
    /// The DoorTarget aimed at the cell (direct HTTPS, no relay).
    public let target: DoorTarget
    /// The concrete door client the app drives for chat / models / approvals.
    public let door: DoorClient

    public init(target: DoorTarget, log: DoorLog? = .shared) {
        self.target = target
        self.door = DoorClient(target: target, log: log)
    }

    /// Build a CellBackend for a cell URL + resolved bearer. Validates the URL is a
    /// well-formed HTTPS address.
    public init(cellURL: String, bearer: String, log: DoorLog? = .shared) throws {
        let target = try Self.makeTarget(cellURL: cellURL, bearer: bearer)
        self.init(target: target, log: log)
    }

    // MARK: - CaptureBackend (delegates to the cell's door)

    public func finalize(captureId: String, meta: ConversationMeta?) async throws {
        try await door.finalize(captureId: captureId, meta: meta)
    }

    public func captureStatus(captureId: String) async throws -> CaptureStatusResponse {
        try await door.captureStatus(captureId: captureId)
    }

    public func captureContent(captureId: String) async throws -> CaptureContent {
        try await door.captureContent(captureId: captureId)
    }

    // MARK: - pure target construction (the testable core)

    /// Normalize a user-entered cell URL: trim, tolerate a trailing slash, and REQUIRE
    /// https. A bare "host" with no scheme is treated as https. Throws on anything that
    /// can't become a valid https URL.
    public static func normalizedURL(_ raw: String) throws -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw CellBackendError.invalidURL }
        // A scheme-less entry ("foundry-cell-x.fly.dev") is assumed https.
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), url.host != nil else {
            throw CellBackendError.invalidURL
        }
        guard scheme == "https" else { throw CellBackendError.insecureScheme }
        return url
    }

    /// The DoorTarget for a cell: normalized HTTPS base + bearer, relay = nil (direct),
    /// useMux = false (no multiplexed relay connection to a cell). This is the ONE place
    /// rung 3 differs from the desktop door — everything downstream is shared DoorClient.
    public static func makeTarget(cellURL: String, bearer: String) throws -> DoorTarget {
        guard !bearer.isEmpty else { throw CellBackendError.missingAuth }
        let url = try normalizedURL(cellURL)
        return DoorTarget(baseURL: url, bearer: bearer, relay: nil, useMux: false)
    }

    /// Resolve a stored `CellConfig` + the live id_token into a DoorTarget. id_token
    /// auth uses the supplied live token (nil ⇒ missingAuth); bearer auth uses the
    /// stored secret. This is what RootView calls to build the cell brain on launch.
    public static func resolveTarget(config: CellConfig, idToken: String?) throws -> DoorTarget {
        switch config.auth {
        case .idToken:
            guard let token = idToken, !token.isEmpty else { throw CellBackendError.missingAuth }
            return try makeTarget(cellURL: config.url, bearer: token)
        case .bearer(let token):
            return try makeTarget(cellURL: config.url, bearer: token)
        }
    }
}
