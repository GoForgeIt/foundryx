// Artifacts — the artifact-viewer pipeline (track 20260713T0906 AC3): chat/run
// outputs that are FILES render in-app when we honestly can (Markdown, HTML,
// images) and say so honestly when we can't. Type detection + the fetch seam are
// pure/testable here; App/ArtifactViewers.swift renders the result.
//
// Fetching rides the SAME door file-route pattern the app already uses for
// capture files (DoorClient.captureAudio / captureContent): a relay-aware
// bearer-authenticated GET where 404 means "not available" (nil), never an
// error page. That pattern is reproduced behind the ArtifactSource seam
// (DoorArtifactSource) — DoorClient internals stay untouched; tests drive a
// double.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Type detection

/// What the app can render in-place. Detection is by filename extension first
/// (the honest signal when present), then MIME type; anything else is
/// `.unsupported` — which still gets a truthful row + export, never a blank pane.
public enum ArtifactKind: Equatable, Sendable {
    case markdown, html, image, unsupported

    public static func detect(filename: String, mime: String? = nil) -> ArtifactKind {
        // Strip a query string ("chart.png?ts=1") before reading the extension.
        let name = filename.split(separator: "?").first.map(String.init) ?? filename
        let parts = name.split(separator: ".")
        if parts.count > 1, let ext = parts.last?.lowercased() {
            switch ext {
            case "md", "markdown":
                return .markdown
            case "html", "htm":
                return .html
            case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff":
                return .image
            default:
                break   // unknown extension → let the MIME type decide
            }
        }
        if let mime = mime?.lowercased() {
            if mime.hasPrefix("image/") { return .image }
            if mime.contains("markdown") { return .markdown }
            if mime.contains("html") { return .html }
        }
        return .unsupported
    }
}

/// A fetched artifact, classified and ready to render.
public struct LoadedArtifact: Equatable, Sendable {
    public let kind: ArtifactKind
    public let filename: String
    public let data: Data

    public init(kind: ArtifactKind, filename: String, data: Data) {
        self.kind = kind
        self.filename = filename
        self.data = data
    }
}

// MARK: - Fetch seam

/// The door's run-artifact route contract, one place (the desktop serves
/// GET /foundryx/run-artifact/<name>, bearer-gated; names are single safe
/// segments by construction — the door refuses anything else at routing time).
public enum RunArtifactRoute {
    public static func path(name: String) -> String {
        "/foundryx/run-artifact/\(name)"
    }
}

/// The seam over the door file route. Production: DoorArtifactSource (below).
/// Tests: a double. `nil` = the door answered 404 — the file isn't available
/// (pruned, or never produced) — distinct from a transport failure (throw).
public protocol ArtifactSource: Sendable {
    func fetchArtifact(path: String) async throws -> Data?
}

/// The render-ready outcome of an artifact fetch.
public enum ArtifactLoadState: Equatable, Sendable {
    case loaded(LoadedArtifact)
    /// The door said 404 — honest "isn't available", not an error.
    case unavailable
    case failed(String)
}

public enum ArtifactLoader {
    /// Fetch `path` through the seam and classify it. `filename`/`mime` override
    /// what the path implies (for routes whose last component isn't a filename).
    public static func load(
        path: String, filename: String? = nil, mime: String? = nil,
        from source: any ArtifactSource
    ) async -> ArtifactLoadState {
        let pathName = path.split(separator: "?").first
            .flatMap { $0.split(separator: "/").last }
            .map(String.init) ?? path
        let name = filename ?? pathName
        do {
            guard let data = try await source.fetchArtifact(path: path) else {
                return .unavailable
            }
            return .loaded(LoadedArtifact(
                kind: ArtifactKind.detect(filename: name, mime: mime),
                filename: name, data: data))
        } catch {
            if let de = error as? DoorError {
                switch de {
                case .unauthorized: return .failed("401 unauthorized")
                case .http(let code): return .failed("HTTP \(code)")
                case .transport(let msg): return .failed(msg)
                }
            }
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - Production source (door file route)

/// Fetch artifact bytes over the door, exactly the way capture files already
/// travel (the captureAudio/captureContent pattern): E2E relay tunnel when
/// configured (interactive channel — this is a user-facing read), LAN-direct
/// bearer GET otherwise; 404 → nil. Reuses DoorTarget/RelayHTTP as-is —
/// DoorClient internals untouched.
public final class DoorArtifactSource: ArtifactSource, @unchecked Sendable {
    private let target: DoorTarget
    private let session: URLSession
    private let log: DoorLog?

    public init(target: DoorTarget, session: URLSession = .shared, log: DoorLog? = nil) {
        self.target = target
        self.session = session
        self.log = log
    }

    public func fetchArtifact(path: String) async throws -> Data? {
        if let relay = target.relay?.interactive() {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "GET",
                path: path,
                session: session, log: log, useMux: target.useMux)
            if resp.status == 401 { throw DoorError.unauthorized }
            if resp.status == 404 { return nil }
            guard resp.status == 200 else { throw DoorError.http(resp.status) }
            return resp.body
        }
        let s = target.baseURL.absoluteString
        let base = s.hasSuffix("/") ? String(s.dropLast()) : s
        guard let url = URL(string: "\(base)\(path)") else {
            throw DoorError.transport("bad artifact url")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 60
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else {
            throw DoorError.transport("non-HTTP response")
        }
        if http.statusCode == 401 { throw DoorError.unauthorized }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw DoorError.http(http.statusCode) }
        return data
    }
}
