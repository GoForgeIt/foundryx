import Foundation
import Darwin

/// A client, written from the operator's side of the wire.
///
/// This deliberately speaks raw bytes rather than reusing any FoundryXKit transport.
/// The obligation is to prove what the RELAY does when a client behaves a given way,
/// and a client built out of the same types the relay's counterpart uses would agree
/// with it by construction. Here the request is written out in full, so a
/// non-conforming client is a different string rather than a mocked-out branch.
struct P3Client {
    let port: UInt16

    struct Exchange {
        /// Exactly what came back, byte for byte. The refusal comparison is on this.
        var bytes: Data
        /// Whether the connection was closed by the peer without any reply at all.
        var closedWithoutReply: Bool
        /// How long the exchange took, for the element that is about a bound.
        var elapsed: TimeInterval

        var text: String { String(decoding: bytes, as: UTF8.self) }
        var upgraded: Bool { text.hasPrefix("HTTP/1.1 101 ") }
        var refused: Bool { text.hasPrefix("HTTP/1.1 403 ") }
        var sessionToken: String? {
            for line in text.split(separator: "\r\n") where line.lowercased().hasPrefix("x-foundry-session-token:") {
                return line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        /// Any header that names a negotiated protocol version. Element 2 turns on
        /// whether one exists at all, so this asks the response rather than the source.
        var negotiatedVersionHeader: String? {
            for line in text.split(separator: "\r\n") {
                let lower = line.lowercased()
                guard lower.contains("version") || lower.hasPrefix("sec-websocket-protocol:") else { continue }
                return String(line)
            }
            return nil
        }
    }

    /// Open a real TCP connection, write `request`, and read whatever comes back until
    /// the head is complete, the peer closes, or `readTimeout` elapses. Sending nothing
    /// (`request` empty) is how the auth-window element is driven.
    func exchange(request: String, readTimeout: TimeInterval = 3.0) throws -> Exchange {
        let started = Date()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw P3ClientError.io("socket() failed: \(errno)") }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw P3ClientError.io("connect() to 127.0.0.1:\(port) failed: \(errno)") }

        var tv = timeval(tv_sec: Int(readTimeout), tv_usec: Int32((readTimeout - floor(readTimeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        if !request.isEmpty {
            let payload = Array(request.utf8)
            var sent = 0
            while sent < payload.count {
                let n = payload.withUnsafeBufferPointer { buf in
                    Darwin.send(fd, buf.baseAddress! + sent, payload.count - sent, 0)
                }
                guard n > 0 else { throw P3ClientError.io("send() failed: \(errno)") }
                sent += n
            }
        }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(readTimeout)
        var peerClosed = false
        while Date() < deadline {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n > 0 {
                out.append(contentsOf: buf[0..<n])
                if String(decoding: out, as: UTF8.self).contains("\r\n\r\n") { break }
                continue
            }
            if n == 0 { peerClosed = true; break }
            break // timeout or error: report what we have, do not spin
        }
        return Exchange(bytes: out,
                        closedWithoutReply: peerClosed && out.isEmpty,
                        elapsed: Date().timeIntervalSince(started))
    }

    // MARK: the request shapes

    /// The conforming request: the relay's one route, the address, and the client's pin
    /// of the community it expects to reach.
    static func conforming(host: String, community: String) -> String {
        "GET /p3 HTTP/1.1\r\nHost: \(host)\r\nx-foundry-community-pid: \(community)\r\n"
            + "x-foundry-protocol-offer: 1\r\n\r\n"
    }

    /// NON-CONFORMING FIXTURE, case 1: a client that names no community. It cannot
    /// detect a silently re-pointed address, which is exactly why the contract requires
    /// the pin. If this is admitted the feature is worthless, so it must be refused.
    static func namingNoCommunity(host: String) -> String {
        "GET /p3 HTTP/1.1\r\nHost: \(host)\r\nx-foundry-protocol-offer: 1\r\n\r\n"
    }

    /// NON-CONFORMING FIXTURE, case 2: a client that asserts a community rather than
    /// one the address is bound to.
    static func namingWrongCommunity(host: String) -> String {
        "GET /p3 HTTP/1.1\r\nHost: \(host)\r\nx-foundry-community-pid: \(String(repeating: "cd", count: 32))\r\n"
            + "x-foundry-protocol-offer: 1\r\n\r\n"
    }
}

enum P3ClientError: Error, CustomStringConvertible {
    case io(String)
    var description: String { if case .io(let m) = self { return m }; return "client error" }
}
