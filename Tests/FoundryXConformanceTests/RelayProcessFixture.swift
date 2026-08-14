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
    private(set) var boundHost: String = "bound.example"

    /// The key that FOUNDED this deployment's community, and therefore the community's
    /// own identity.
    ///
    /// It used to be the literal `ababab…`, and that stopped working when the relay grew
    /// enrolment: `membership::fold` requires entry zero of `communities/<pid>.log` to be a
    /// `Found` whose owner's pid EQUALS the pid the deployment bound the host to, so the
    /// bindings file and the log's founding key are two spellings of one key. A made-up pid
    /// has no key, so no log can be founded under it, so nobody can be enrolled in it.
    private(set) var communityKey = Secp256k1.SigningKey.generate()

    /// The community the bound host resolves to — the founding key's x-only public half.
    var communityPid: String { communityKey.publicKeyHex }

    /// The conforming client's own key and location. A DIFFERENT principal from the
    /// community: it is admitted by the founder in entry one of the signed log, which is
    /// what a door presenting a location's key actually looks like.
    private(set) var identity = ConnectIdentity(key: Secp256k1.SigningKey.generate(),
                                                locationId: "loc-conformance-01")

    /// The deployment directory this run created. The relay reads its configuration, its
    /// community logs and its seam log out of here, so a harness that owns the directory
    /// can read what the door decided without the door having to expose a route for it.
    private(set) var deploymentDir: URL?

    /// Where this deployment's door writes what it decided —
    /// `seam_log::auth_log_path` = `<deployment>/seam/auth.log`.
    ///
    /// It is derived from the deployment directory rather than configured, because the
    /// relay's configuration register is closed at three keys and this is not a fourth.
    var seamLogPath: URL? { deploymentDir?.appendingPathComponent("seam").appendingPathComponent("auth.log") }

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

        // ---- THE COMMUNITY'S SIGNED MEMBERSHIP LOG ---------------------------------
        // The relay resolves enrolment by FOLDING this file, per connection, with no cache
        // and no short-circuit. A deployment that binds a host to a community it holds no
        // signed log for is refused (`MembershipError::Unreadable`), so this is not
        // optional decoration: without it every client — conforming or not — is denied.
        let communities = dir.appendingPathComponent("communities")
        try FileManager.default.createDirectory(at: communities, withIntermediateDirectories: true)
        try CommunityMembershipLog.text(founder: communityKey,
                                        memberPid: identity.identityKeyHex,
                                        memberName: "conformance-client")
            .write(to: communities.appendingPathComponent("\(communityPid).log"),
                   atomically: true, encoding: .utf8)

        // ---- THE COMMUNITY'S BAN LIST ----------------------------------------------
        // N2's ban gate (foundry `c8e1b23c`, `crates/foundry-relay/src/ban.rs`) runs
        // IMMEDIATELY after the proof and BEFORE enrolment, and it FAILS CLOSED on an
        // ABSENT list: `ban::decide` reads `<deployment>/bans/<pid>.bans` and an unreadable
        // file DENIES — "a deployment that cannot say who is barred cannot say nobody is".
        // The relay is RIGHT and this target does not ask for it to be weakened.
        //
        // What it means here is that the deployment now owes a SECOND file per community,
        // of the same class as `bindings.toml` and the membership log, and a deployment
        // that omits it refuses EVERY client — conforming or not. That is not a deduction:
        // with this fixture unchanged, foundry `08db3546` served 4 of 5 and its child
        // `c8e1b23c` served 2 of 5, and the door's own seam named the conjunct
        // `ban-store-unreadable` on both `check-ban` and `admit-connection`.
        //
        // The list is EMPTY OF PRINCIPALS on purpose. A conformance deployment bars
        // nobody; what it must be able to do is SAY so. The comment line is content, so
        // this is a list the relay can read rather than a zero-byte file nobody meant.
        let bans = dir.appendingPathComponent("bans")
        try FileManager.default.createDirectory(at: bans, withIntermediateDirectories: true)
        try "# this conformance deployment bars nobody, and can say so\n"
            .write(to: bans.appendingPathComponent("\(communityPid).bans"),
                   atomically: true, encoding: .utf8)
        deploymentDir = dir

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

        // ---- THE CLIENT CAN NOW BE ISSUED SOMETHING TO SIGN ------------------------
        // Set HERE and nowhere else, because this is the first instant both halves are
        // known: the relay was asked for `:0` and has just printed the port it got, and
        // the bound host is this fixture's own. Since foundry main 6de3bb3c the connect
        // proof covers a challenge THE DEPLOYMENT ISSUED, so an identity without this is
        // an identity that cannot open a door — and `ConnectIdentity` refuses rather than
        // fetching against port zero, so forgetting it is a named failure, not a 403.
        identity.challengeSource = ConnectIdentity.ChallengeSource(port: port, host: boundHost)
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
