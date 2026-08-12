import Foundation
import CryptoKit

/// A REAL relay process, started by this harness and torn down by the pid it captured.
///
/// ## Why this is not a stub, and why there is no skip
///
/// `Tests/FoundryXBrineTests/BrineFeatureRunner.swift:10` declares itself a
/// "hermetic runner (no real network, no real hardware; every seam is injected)".
/// A conformance obligation cannot be met inside it: the responder would be ours.
/// This fixture is the opposite — it spawns the shipped relay binary, opens real
/// TCP connections to it, and reads what really came back.
///
/// The repo's established pattern for a test that needs a real counterpart is
/// `XCTSkip` (30 sites in `Tests/FoundryXBrineTests/`, e.g. `FoundryXDoorTests.swift:42`).
/// Every one of them reports green on a machine that cannot run the test. There are
/// none here, and `ConformanceSkipCensus` asserts that as a count.
///
/// ## The binary is resolved, never spelled
///
/// The relay's crate and binary name move under the noun registry's S3 ruling, so a
/// literal path in this file would rot into a green that points at nothing. The
/// binary comes from a configuration key, and the resolved file's name is checked
/// against the identifier the registry rules. Absent key, absent file, or a file
/// under another name is a REFUSAL naming what was missing — never a skip.
enum RelayFixtureError: Error, CustomStringConvertible {
    case noConfigurationKey(String)
    case binaryMissing(String)
    case wrongIdentifier(resolved: String, ruled: String)
    case didNotListen(String)
    case io(String)

    var description: String {
        switch self {
        case .noConfigurationKey(let k):
            return """
            no relay was named. \(k) is required: this harness reads no default path, \
            because a harness that picked one would be conforming against a binary nobody chose. \
            THIS IS THE REFUSAL, NOT A SKIP — a run without a relay is red.
            """
        case .binaryMissing(let p):
            return "the configuration key names \(p), and there is no file there. Build it first (cargo build -p foundry-relay --bin foundry-relay)."
        case .wrongIdentifier(let resolved, let ruled):
            return "the configuration key resolves to a file named \(resolved); the identifier the noun registry rules for this component is \(ruled)"
        case .didNotListen(let why):
            return "the relay process never reported a listening address: \(why)"
        case .io(let m):
            return m
        }
    }
}

/// The configuration key that names the relay binary. Read from the process
/// environment, exactly the way the relay itself reads `AUTH_TIMEOUT`.
let RELAY_BIN_KEY = "FOUNDRYX_CONFORMANCE_RELAY_BIN"

/// The identifier the noun registry rules for this component. The registry lives in
/// the `foundry` repository (`docs/noun-registry.md`); this is the spelling it pins,
/// and the check exists so that a rename there is a loud failure here rather than a
/// harness that silently starts something else.
let RULED_RELAY_IDENTIFIER = "foundry-relay"

final class RelayProcessFixture {
    private(set) var pid: Int32 = 0
    private(set) var imageDigest: String = ""
    private(set) var port: UInt16 = 0
    private(set) var communityPid: String = String(repeating: "ab", count: 32)
    private(set) var boundHost: String = "bound.example"

    /// Every scratch directory this harness created, so teardown enumerates what the
    /// RUN made rather than one path somebody remembered. A leak counter that checks
    /// a known path counts fewer candidates than the run created — the shape behind a
    /// scratch leak that filled a disk once already.
    private(set) var scratchDirs: [URL] = []
    /// Every pid this harness started, for the same reason. Teardown terminates by
    /// these values only. There is no pattern match anywhere in this file.
    private(set) var startedPids: [Int32] = []

    private var process: Process?
    private var stdoutPipe: Pipe?

    // MARK: bring-up

    func start() throws {
        guard let binPath = ProcessInfo.processInfo.environment[RELAY_BIN_KEY], !binPath.isEmpty else {
            throw RelayFixtureError.noConfigurationKey(RELAY_BIN_KEY)
        }
        let binURL = URL(fileURLWithPath: binPath)
        guard FileManager.default.isExecutableFile(atPath: binURL.path) else {
            throw RelayFixtureError.binaryMissing(binURL.path)
        }
        guard binURL.lastPathComponent == RULED_RELAY_IDENTIFIER else {
            throw RelayFixtureError.wrongIdentifier(resolved: binURL.lastPathComponent,
                                                    ruled: RULED_RELAY_IDENTIFIER)
        }

        imageDigest = try Self.digest(of: binURL)

        let dir = try makeScratchDir()
        // The FILE half of the deployment. `relay.auth_frame_timeout_seconds` is
        // deployed from the process environment under the identifier AUTH_TIMEOUT and
        // writing it here is the relay's own refusal, so it is not written here.
        let relayToml = """
        relay.session_token_lifetime_seconds = "3600"
        relay.reserved_serving_zone = "relay.example"

        """
        try relayToml.write(to: dir.appendingPathComponent("relay.toml"), atomically: true, encoding: .utf8)
        try "\(boundHost) = \"\(communityPid)\"\n"
            .write(to: dir.appendingPathComponent("bindings.toml"), atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = binURL
        p.arguments = ["--config-dir", dir.path, "--bind", "127.0.0.1:0"]
        var env = ProcessInfo.processInfo.environment
        env["AUTH_TIMEOUT"] = String(authTimeoutSeconds)
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { throw RelayFixtureError.io("the relay could not be started: \(error)") }
        process = p
        stdoutPipe = out
        pid = p.processIdentifier
        startedPids.append(pid)

        port = try Self.readListeningPort(from: out, deadline: Date().addingTimeInterval(10))
    }

    /// What the deployment is configured with, so a scenario that waits on the relay's
    /// auth window waits on the number the relay was really given.
    let authTimeoutSeconds = 2

    private func makeScratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-p3-conformance-\(ProcessInfo.processInfo.processIdentifier)-\(scratchDirs.count)")
        try? FileManager.default.removeItem(at: dir)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw RelayFixtureError.io("could not make the deployment directory: \(error)") }
        scratchDirs.append(dir)
        return dir
    }

    private static func digest(of url: URL) throws -> String {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw RelayFixtureError.io("could not read the relay image at \(url.path) to digest it")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The relay prints `foundry-relay: listening on 127.0.0.1:<port>` once it holds
    /// the socket, which is the only place the number is knowable when `:0` was asked
    /// for. Parsed from the process's own stdout — not guessed, and not slept for.
    private static func readListeningPort(from pipe: Pipe, deadline: Date) throws -> UInt16 {
        var buffered = ""
        while Date() < deadline {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.02); continue }
            buffered += String(decoding: chunk, as: UTF8.self)
            for line in buffered.split(separator: "\n") {
                guard line.contains("listening on") else { continue }
                guard let colon = line.lastIndex(of: ":"),
                      let n = UInt16(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                else { continue }
                return n
            }
        }
        throw RelayFixtureError.didNotListen("nothing matching `listening on` arrived on stdout within the wait")
    }

    // MARK: teardown

    struct TeardownReport {
        var pidCandidatesExamined = 0
        var stillRunning: [Int32] = []
        var scratchCandidatesExamined = 0
        var stillPresent: [String] = []
    }

    /// Terminate by CAPTURED PID ONLY. A pattern kill has taken down production and a
    /// CI build in this ecosystem; there is no pattern here to kill by.
    @discardableResult
    func teardown() -> TeardownReport {
        var report = TeardownReport()
        for target in startedPids {
            report.pidCandidatesExamined += 1
            kill(target, SIGTERM)
        }
        process?.waitUntilExit()
        // Give the OS a bounded moment to reap, then ASK rather than assume.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if startedPids.allSatisfy({ kill($0, 0) != 0 }) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        report.stillRunning = startedPids.filter { kill($0, 0) == 0 }

        for dir in scratchDirs {
            report.scratchCandidatesExamined += 1
            try? FileManager.default.removeItem(at: dir)
            if FileManager.default.fileExists(atPath: dir.path) { report.stillPresent.append(dir.path) }
        }
        return report
    }
}
