// RelayHTTP — the ONE place door-bound HTTP requests are carried over the blind
// E2E relay tunnel (M5 R1b). In remote mode the DoorTarget's `baseURL` is NOMINAL:
// it names the relay's HTTP control port (host registry + /diag/log), which has NO
// /foundryx/* routes — those live behind the Noise tunnel on the desktop door. So a
// plain URLSession POST to baseURL returns 404. Every door request (chat, capture
// segment upload, finalize, status) must instead go E2E through `RelayTransport`:
// open the tunnel, Noise-handshake with the door, send the raw HTTP request as
// ciphertext, and read the door's response back. This helper builds that raw
// request and parses the door's HTTP status + body from the decrypted reply frames.

import Foundation

public enum RelayHTTP {
    public struct Response: Sendable {
        public let status: Int
        public let body: Data
    }

    /// Perform one request/response over the relay tunnel. `path` is the door path
    /// (e.g. "/foundryx/capture"); `extraHeaders` are any door-specific headers
    /// (e.g. X-Capture-Id). The Authorization bearer is always added.
    public static func roundTrip(
        relay: RelayConfig,
        bearer: String,
        method: String,
        path: String,
        extraHeaders: [String: String] = [:],
        contentType: String? = nil,
        accept: String? = nil,
        body: Data? = nil,
        session: URLSession,
        log: DoorLog? = .shared,
        useMux: Bool = false
    ) async throws -> Response {
        let reqBytes = rawRequest(method: method, path: path, bearer: bearer,
                                  extraHeaders: extraHeaders, contentType: contentType,
                                  accept: accept, body: body)
        // Mux: ride the shared persistent connection (same request bytes / reply frames as
        // RelayTransport, just multiplexed over one socket). Per-turn path otherwise.
        let frames = useMux
            ? try await DoorConnectionPool.shared.turn(config: relay, request: reqBytes, log: log)
            : try await RelayTransport(config: relay, session: session, log: log)
                .roundTrip(requestBytes: reqBytes)
        var buf = Data()
        for f in frames { buf.append(f) }
        return try parseResponse(buf)
    }

    /// Build a complete HTTP/1.1 request the door can parse off the tunnel. The door
    /// reads Content-Length and closes the connection per turn (Connection: close).
    static func rawRequest(
        method: String, path: String, bearer: String,
        extraHeaders: [String: String], contentType: String?,
        accept: String?, body: Data?
    ) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: door\r\n"
        head += "Authorization: Bearer \(bearer)\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        if let accept { head += "Accept: \(accept)\r\n" }
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }

    /// Parse "HTTP/1.1 <code> ..." + body (everything after the CRLFCRLF header
    /// terminator). The door's responses are small (status/JSON) or an SSE stream;
    /// either way the caller gets the status and the raw body bytes.
    static func parseResponse(_ raw: Data) throws -> Response {
        let terminator = Data("\r\n\r\n".utf8)
        guard let r = raw.range(of: terminator) else {
            throw DoorError.transport("relay: no HTTP header terminator in \(raw.count)B reply")
        }
        let headerData = raw.subdata(in: raw.startIndex..<r.lowerBound)
        let body = raw.subdata(in: r.upperBound..<raw.endIndex)
        let headerText = String(decoding: headerData, as: UTF8.self)
        guard let statusLine = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).first else {
            throw DoorError.transport("relay: empty response head")
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else {
            throw DoorError.transport("relay: bad status line '\(statusLine)'")
        }
        return Response(status: code, body: body)
    }
}
