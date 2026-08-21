import Foundation
import Darwin

/// A REAL HTTP gateway, serving `GET /host/resolve` on a loopback port.
///
/// ## Why a fixture rather than the shipped host-registry control plane
///
/// The shipped control plane (`foundryx-tunnel::host_api`) derives `machine_id` from a
/// registered door and is identity-gated by OIDC. It cannot be made to answer with a
/// *missing* `machine_id`, and a missing `machine_id` is exactly case (i) of P1 — the
/// case the client fails open on. A predicate that could not present that response
/// could not exercise the defect, so the gateway is a fixture whose body this test
/// controls. `spec.md` §5.1 names this: *"Against the real relay, with a real gateway
/// fixture"* — the RELAY is real, the gateway is a fixture, and this is that fixture.
///
/// It is a real server on a real socket answering a real `URLSession` request from the
/// real `HostResolver`; nothing about the client under test is injected or stubbed.
final class GatewayFixture {
    /// The response body served for `GET /host/resolve`, verbatim.
    private let body: String
    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private var thread: Thread?
    private var stopping = false
    /// How many `/host/resolve` requests were actually served. A case that never
    /// reached the gateway is not a case that ran, and this is how that is known
    /// rather than assumed.
    private(set) var resolveRequestsServed = 0
    private let lock = NSLock()

    init(body: String) {
        self.body = body
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func start() throws {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw GatewayFixtureError.io("socket() failed: \(errno)") }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(0).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw GatewayFixtureError.io("bind() failed: \(errno)") }
        guard Darwin.listen(listenFD, 8) == 0 else { throw GatewayFixtureError.io("listen() failed: \(errno)") }

        // Read the port the OS chose, rather than picking one and hoping it is free.
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &actual) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(listenFD, sa, &len)
            }
        }
        guard got == 0 else { throw GatewayFixtureError.io("getsockname() failed: \(errno)") }
        port = actual.sin_port.bigEndian

        let t = Thread { [weak self] in self?.serveLoop() }
        t.stackSize = 512 * 1024
        thread = t
        t.start()
    }

    private func serveLoop() {
        while true {
            lock.lock(); let done = stopping; lock.unlock()
            if done { return }
            let fd = Darwin.accept(listenFD, nil, nil)
            if fd < 0 { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            var head = ""
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            while !head.contains("\r\n\r\n") {
                let n = Darwin.recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                head += String(decoding: buf[0..<n], as: UTF8.self)
            }
            let response: String
            if head.hasPrefix("GET /host/resolve") {
                lock.lock(); resolveRequestsServed += 1; lock.unlock()
                let bytes = Array(body.utf8).count
                response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bytes)\r\nConnection: close\r\n\r\n\(body)"
            } else {
                response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            let payload = Array(response.utf8)
            var sent = 0
            while sent < payload.count {
                let n = payload.withUnsafeBufferPointer { b in
                    Darwin.send(fd, b.baseAddress! + sent, payload.count - sent, 0)
                }
                if n <= 0 { break }
                sent += n
            }
            close(fd)
        }
    }

    func stop() {
        lock.lock(); stopping = true; lock.unlock()
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    var requestsServed: Int {
        lock.lock(); defer { lock.unlock() }
        return resolveRequestsServed
    }

    // MARK: the two response shapes P1 drives

    /// Case (i): `machine_id` ABSENT.
    ///
    /// Until 2026-08-13 `HostResolver` read `(obj["machine_id"] as? String) ?? ""`,
    /// `hexToData("")` returned nil on its `!hex.isEmpty` guard, and the RelayConfig
    /// carried `expectedDoorStatic: nil` — the phone dialled unpinned. Since the pin
    /// became mandatory this body makes `resolveRelayConfig` throw
    /// `HostResolveError.hostCannotBePinned` and no RelayConfig is produced at all.
    static func absentIdentity(tunnelId: String) -> GatewayFixture {
        GatewayFixture(body: #"{"tunnel_id":"\#(tunnelId)","label":"conformance-host"}"#)
    }

    /// Case (ii): `machine_id` PRESENT but not the responder's static public key.
    static func wrongIdentity(tunnelId: String, machineIdHex: String) -> GatewayFixture {
        GatewayFixture(body: #"{"tunnel_id":"\#(tunnelId)","label":"conformance-host","machine_id":"\#(machineIdHex)"}"#)
    }
}

enum GatewayFixtureError: Error, CustomStringConvertible {
    case io(String)
    var description: String { if case .io(let m) = self { return m }; return "gateway fixture error" }
}
