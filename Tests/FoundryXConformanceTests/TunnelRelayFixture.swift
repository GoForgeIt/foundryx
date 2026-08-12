import Foundation
import CryptoKit

/// A REAL blind tunnel-splice relay process, for the P1 predicate (T25 A6).
///
/// ## Why this is a second relay fixture and not a reuse of `RelayProcessFixture`
///
/// `RelayProcessFixture` starts `foundry-relay`, which serves P3 (`GET /p3`) — host
/// binding, version negotiation, session tokens. The client path P1 is about
/// (`HostResolver` -> `DoorConnection.connect` / `RelayTransport`) does not speak P3
/// at all: it sends a `{"role":"client","tunnel_id":…}` Hello to the BLIND
/// tunnel-splice relay, which is a different binary (`foundryx-relay-server`, crate
/// `foundryx-tunnel`). Pointing P1 at `foundry-relay` would produce a refusal caused
/// by talking to the wrong server, and a refusal from the wrong cause would report
/// P1 CLOSED while the fail-open it exists to catch was never exercised. That is the
/// exact trade this track refuses, so the two relays are two fixtures.
///
/// ## No skip, and no default path
///
/// Same discipline as `RelayProcessFixture`: the binary is named by a configuration
/// key, never defaulted, and its absence is a REFUSAL rather than an `XCTSkip`.
enum TunnelFixtureError: Error, CustomStringConvertible {
    case noConfigurationKey(String)
    case binaryMissing(String)
    case wrongIdentifier(resolved: String, ruled: String)
    case didNotListen(String)
    case io(String)

    var description: String {
        switch self {
        case .noConfigurationKey(let k):
            return """
            no tunnel relay was named. \(k) is required: this harness reads no default \
            path, because a harness that picked one would be conforming against a binary \
            nobody chose. THIS IS THE REFUSAL, NOT A SKIP — a run without the tunnel relay is red.
            """
        case .binaryMissing(let p):
            return "the configuration key names \(p), and there is no file there. Build it first (cargo build -p foundryx-tunnel --bin foundryx-relay-server)."
        case .wrongIdentifier(let resolved, let ruled):
            return "the configuration key resolves to a file named \(resolved); the identifier this component ships under is \(ruled)"
        case .didNotListen(let why):
            return "the tunnel relay never reported a listening address: \(why)"
        case .io(let m):
            return m
        }
    }
}

/// The configuration key that names the blind tunnel relay binary.
let TUNNEL_BIN_KEY = "FOUNDRYX_CONFORMANCE_TUNNEL_BIN"

/// The identifier this component ships under, checked so a rename upstream is a loud
/// failure here rather than a harness that silently starts something else.
let RULED_TUNNEL_IDENTIFIER = "foundryx-relay-server"

final class TunnelRelayFixture {
    private(set) var pid: Int32 = 0
    private(set) var imageDigest: String = ""
    private(set) var wsURL: URL = URL(string: "ws://127.0.0.1:0")!

    /// Every pid this harness started. Teardown terminates by these values only —
    /// there is no pattern to kill by anywhere in this file.
    private(set) var startedPids: [Int32] = []

    private var process: Process?

    func start() throws {
        guard let binPath = ProcessInfo.processInfo.environment[TUNNEL_BIN_KEY], !binPath.isEmpty else {
            throw TunnelFixtureError.noConfigurationKey(TUNNEL_BIN_KEY)
        }
        let binURL = URL(fileURLWithPath: binPath)
        guard FileManager.default.isExecutableFile(atPath: binURL.path) else {
            throw TunnelFixtureError.binaryMissing(binURL.path)
        }
        guard binURL.lastPathComponent == RULED_TUNNEL_IDENTIFIER else {
            throw TunnelFixtureError.wrongIdentifier(resolved: binURL.lastPathComponent,
                                                     ruled: RULED_TUNNEL_IDENTIFIER)
        }
        imageDigest = try Self.digest(of: binURL)

        let p = Process()
        p.executableURL = binURL
        var env = ProcessInfo.processInfo.environment
        // Ephemeral ports on loopback only. The host-registry control plane is bound
        // too (the binary always starts it) but is NOT used: P1 drives the client
        // against a gateway FIXTURE whose response body this test controls, which is
        // the only way to present an ABSENT `machine_id` at all.
        env["FOUNDRYX_RELAY_BIND"] = "127.0.0.1:0"
        env["FOUNDRYX_RELAY_HTTP_BIND"] = "127.0.0.1:0"
        env["FOUNDRYX_OIDC_AUDIENCES"] = "foundryx-conformance"
        // Open door registration: the relay's own comment says security in this mode
        // comes from "the phone PINNING the door's static key" — which is precisely
        // the property P1 measures, so the mode must be the one that relies on it.
        env["FOUNDRYX_RELAY_BEARER"] = ""
        p.environment = env
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do { try p.run() } catch { throw TunnelFixtureError.io("the tunnel relay could not be started: \(error)") }
        process = p
        pid = p.processIdentifier
        startedPids.append(pid)

        wsURL = try Self.readWSURL(from: err, deadline: Date().addingTimeInterval(15))
    }

    private static func digest(of url: URL) throws -> String {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw TunnelFixtureError.io("could not read the tunnel relay image at \(url.path) to digest it")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The relay prints `BLIND tunnel-splice up on ws://127.0.0.1:<port>` on stderr
    /// once it holds the socket. Parsed from the process's own output — the only
    /// place the number is knowable when `:0` was asked for.
    private static func readWSURL(from pipe: Pipe, deadline: Date) throws -> URL {
        var buffered = ""
        while Date() < deadline {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.02); continue }
            buffered += String(decoding: chunk, as: UTF8.self)
            for line in buffered.split(separator: "\n") {
                guard line.contains("tunnel-splice up on ") else { continue }
                guard let r = line.range(of: "ws://") else { continue }
                let tail = line[r.lowerBound...]
                let urlText = tail.prefix(while: { !$0.isWhitespace })
                guard let u = URL(string: String(urlText)) else { continue }
                return u
            }
        }
        throw TunnelFixtureError.didNotListen("nothing matching `tunnel-splice up on` arrived on stderr within the wait")
    }

    struct TeardownReport {
        var pidCandidatesExamined = 0
        var stillRunning: [Int32] = []
    }

    /// Terminate by CAPTURED PID ONLY.
    @discardableResult
    func teardown() -> TeardownReport {
        var report = TeardownReport()
        for target in startedPids {
            report.pidCandidatesExamined += 1
            kill(target, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if startedPids.allSatisfy({ kill($0, 0) != 0 }) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        report.stillRunning = startedPids.filter { kill($0, 0) == 0 }
        return report
    }
}
