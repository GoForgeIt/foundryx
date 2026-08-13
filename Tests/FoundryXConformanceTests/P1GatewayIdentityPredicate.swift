import Foundation
import FoundryXKit

/// **P1 — gateway-identity discard** (`spec.md` §5.1), the behavioural predicate.
///
/// ## What is observed, and what is refused as a substitute
///
/// The spec is explicit about the observable and about the cheap forms it forbids:
///
///   > **Not acceptable as a substitute:** any check that the client *logs*
///   > `pinned=false`, or that the pin code path exists. The defect is that the client
///   > proceeds; only proceeding-or-not is the observable.
///
/// So this predicate does not read a log line and does not grep for the pin. It runs
/// the REAL client — `HostResolver.resolveRelayConfig` to build the config from a real
/// gateway response, then `NoiseRelayChannel.connect` to dial a REAL blind relay with a
/// REAL Noise door on the far side — and records whether a channel came back.
///
/// ## The two cases, and why both are needed
///
/// - **(i) `machine_id` absent.** The gateway names a host and carries no door key.
/// - **(ii) `machine_id` present but wrong.** The pin mismatches the door's static, so
///   the client throws `RelayError.doorIdentityMismatch` and refuses.
///
/// **CLOSED iff the client refuses in BOTH.** Running only case (ii) would report a
/// refusal and hide the defect entirely, which is why the case count is asserted
/// rather than the outcome alone.
///
/// ## What case (i) used to do, and what it does now (2026-08-13)
///
/// This predicate was written against a client that FAILED OPEN in case (i), and it
/// recorded that fail-open live: `HostResolver.swift:94` read
/// `(obj["machine_id"] as? String) ?? ""`, `hexToData("")` answered `nil`,
/// `RelayConfig.expectedDoorStatic` was therefore `nil`, and both consumers were
/// conditional (`RelayTransport.swift`, `DoorConnection.swift` both `if let`), so no
/// pin was checked and **the channel completed**. The recorded transcript read
/// *"case absent-identity: the client COMPLETED the channel"* and P1 was **OPEN**.
///
/// The mandatory-pin change closes it, and closes it EARLIER than this predicate
/// originally looked: `expectedDoorStatic` is no longer optional, so a gateway answer
/// that carries no door key cannot produce a `RelayConfig` at all, and
/// `resolveRelayConfig` throws `HostResolveError.hostCannotBePinned` before a socket is
/// opened. **A refusal at resolve is the strongest form of this refusal, not a weaker
/// one** — there is no configuration in existence to dial, so no unpinned channel can
/// be reached by any later code path. It is counted as a refusal, and the transcript
/// says WHICH KIND of refusal each case produced so the two can never be confused.
///
/// ## Three things this predicate refuses to do
///
/// 1. **A transport failure is not a refusal.** A case counts as *refused* only when
///    the client refused ON IDENTITY — either `RelayError.doorIdentityMismatch` at the
///    handshake, or `HostResolveError.hostCannotBePinned` at the resolve. Any other
///    error means the case could not be driven, and the predicate REFUSES rather than
///    publishing a status. Counting a dead relay as "the client refused" would report
///    P1 CLOSED on a rig that never tested anything.
/// 2. **A rig that refuses everything must not pass.** Before the two cases, a
///    POSITIVE CONTROL drives the *correct* `machine_id` and requires the channel to
///    complete. Without it, a broken door or a mis-parsed relay URL would make every
///    case "refuse" and P1 would report CLOSED — the fix reported as landed because
///    the harness stopped working.
/// 3. **A resolve-time refusal must not be allowed to swallow case (ii).** Case (ii)
///    is required to refuse AT THE HANDSHAKE: it presents a well-formed key, so it must
///    survive resolve, reach the relay, and be rejected on the door's static. A client
///    that started refusing every answer at resolve would satisfy case (i) and is red
///    here — which is what keeps "refuses" from collapsing into "never connects".
enum P1GatewayIdentityPredicate {

    struct CaseResult {
        let name: String
        /// True only when the client refused *on door identity*.
        let refused: Bool
        let detail: String
    }

    private enum Drive {
        case completed(pinned: Bool, doorSawHandshake: Bool)
        /// Refused at the HANDSHAKE, on the door's static key
        /// (`RelayError.doorIdentityMismatch`).
        case refusedOnIdentity(pinned: Bool, doorSawHandshake: Bool)
        /// Refused at the RESOLVE, because the gateway's answer carried nothing that
        /// could be pinned (`HostResolveError.hostCannotBePinned`). No `RelayConfig`
        /// exists, so no dial happened and none can.
        case refusedAtResolve(String)
        case failed(String)
    }

    static func run(relayURL: URL) async -> PredicateOutcome {
        var transcript: [String] = []

        func refuse(_ why: String, cases: Int) -> PredicateOutcome {
            PredicateOutcome(name: "P1", title: "gateway-identity discard (behavioural)",
                             status: .refused, casesExecuted: cases,
                             output: (transcript + ["REFUSED: \(why)"]).joined(separator: "\n"))
        }

        // ---- POSITIVE CONTROL: the correct identity must COMPLETE -----------------
        // Non-vacuity first. If this cannot complete, nothing below means anything.
        switch await drive(relayURL: relayURL, identity: .correct) {
        case .completed(let pinned, _):
            transcript.append("positive control (correct machine_id): the client completed the channel, pinned=\(pinned) — the rig can reach transport mode, so a later refusal is a REFUSAL and not a broken harness")
        case .refusedOnIdentity(let pinned, _):
            return refuse("the POSITIVE CONTROL was refused on door identity (pinned=\(pinned)). The door's own static public key was presented and the client still rejected it, so every refusal below would be meaningless.", cases: 0)
        case .refusedAtResolve(let why):
            return refuse("the POSITIVE CONTROL was refused at RESOLVE: \(why). The door's own static public key was presented and the client would not even build a configuration from it, so every refusal below would be a client that refuses everything.", cases: 0)
        case .failed(let e):
            return refuse("the POSITIVE CONTROL could not be driven: \(e). No status is published from a rig that never worked.", cases: 0)
        }

        // ---- case (i): the gateway returns no `machine_id` at all ------------------
        var cases: [CaseResult] = []
        switch await drive(relayURL: relayURL, identity: .absent) {
        case .completed(let pinned, _):
            cases.append(CaseResult(name: "absent-identity", refused: false,
                detail: "the client COMPLETED the channel (expectedDoorStatic pinned=\(pinned))"))
        case .refusedOnIdentity(let pinned, _):
            cases.append(CaseResult(name: "absent-identity", refused: true,
                detail: "the client REFUSED on door identity at the handshake (expectedDoorStatic pinned=\(pinned))"))
        case .refusedAtResolve(let why):
            cases.append(CaseResult(name: "absent-identity", refused: true,
                detail: "the client REFUSED at resolve and never dialled — no RelayConfig was built, so no unpinned channel exists to reach (\(why))"))
        case .failed(let e):
            return refuse("case absent-identity could not be driven: \(e)", cases: 0)
        }
        transcript.append("case absent-identity: \(cases[0].detail)")

        // ---- case (ii): an identity that is present but is not the door's ---------
        // This one must survive resolve and be refused AT THE HANDSHAKE. A client that
        // refused it at resolve would be refusing well-formed keys, i.e. not connecting
        // at all rather than pinning, and that is a refusal of the predicate.
        switch await drive(relayURL: relayURL, identity: .wrong) {
        case .completed(let pinned, _):
            cases.append(CaseResult(name: "wrong-identity", refused: false,
                detail: "the client COMPLETED the channel (expectedDoorStatic pinned=\(pinned))"))
        case .refusedOnIdentity(let pinned, _):
            cases.append(CaseResult(name: "wrong-identity", refused: true,
                detail: "the client REFUSED on door identity (expectedDoorStatic pinned=\(pinned))"))
        case .refusedAtResolve(let why):
            return refuse("case wrong-identity was refused at RESOLVE: \(why). That case presents a WELL-FORMED door key; it has to reach the relay and be rejected on the door's static, or 'the client refuses' has collapsed into 'the client never connects' and the pin is no longer what is being measured.", cases: 1)
        case .failed(let e):
            return refuse("case wrong-identity could not be driven: \(e)", cases: 1)
        }
        transcript.append("case wrong-identity: \(cases[1].detail)")

        let refusedAll = cases.allSatisfy { $0.refused }
        let proceeded = cases.filter { !$0.refused }.map { $0.name }
        transcript.append("cases executed: \(cases.count)")
        transcript.append(refusedAll
            ? "the client refused in every case — P1 CLOSED"
            : "the client PROCEEDED in \(proceeded.count) of \(cases.count) case(s): \(proceeded.joined(separator: ", ")) — a channel reached transport mode with no door identity checked. P1 OPEN")

        return PredicateOutcome(
            name: "P1",
            title: "gateway-identity discard (behavioural)",
            status: refusedAll ? .closed : .open,
            casesExecuted: cases.count,
            output: transcript.joined(separator: "\n"))
    }

    private enum Identity { case absent, wrong, correct }

    /// One drive end to end: park a real door, stand up the gateway fixture, resolve
    /// through the REAL `HostResolver`, and dial through the REAL client.
    private static func drive(relayURL: URL, identity: Identity) async -> Drive {
        let tunnelId = "conformance-p1-\(UInt32.random(in: 0..<UInt32.max))"
        do {
            let door = try DoorFixture(relayURL: relayURL, tunnelId: tunnelId)
            try door.startParked()
            defer { door.stop() }
            // Let the door reach the relay's parked set before the client claims it.
            // The relay itself waits up to 5s for a door, so this is a courtesy.
            try await Task.sleep(nanoseconds: 400 * 1_000_000)

            let gateway: GatewayFixture
            switch identity {
            case .absent:  gateway = GatewayFixture.absentIdentity(tunnelId: tunnelId)
            case .wrong:   gateway = GatewayFixture.wrongIdentity(tunnelId: tunnelId, machineIdHex: DoorFixture.someOtherMachineIdHex())
            case .correct: gateway = GatewayFixture.wrongIdentity(tunnelId: tunnelId, machineIdHex: door.staticPublicHex)
            }
            try gateway.start()
            defer { gateway.stop() }

            let remote = RemoteConfig(gatewayHTTPURL: gateway.baseURL, relayWSURL: relayURL)
            let resolver = HostResolver(remote: remote)
            let config: RelayConfig
            do {
                config = try await resolver.resolveRelayConfig(idToken: "conformance-fixture-token")
            } catch let e as HostResolveError {
                // A refusal ON IDENTITY, one leg earlier than the handshake: the answer
                // carried nothing pinnable, so no configuration was built and there is
                // no dial. Any OTHER HostResolveError (a 404, a bad body) is a drive
                // that did not reach the subject and is not counted as a refusal.
                guard case .hostCannotBePinned = e else {
                    return .failed("the resolve failed for a reason that is not the pin: \(e)")
                }
                guard gateway.requestsServed >= 1 else {
                    return .failed("the client refused before the gateway was ever asked — the refusal is not about the answer under test")
                }
                guard !door.sawHandshake else {
                    return .failed("the client refused at resolve and the door STILL saw a handshake — something dialled without a configuration")
                }
                return .refusedAtResolve("\(e.errorDescription ?? "\(e)")")
            }

            guard gateway.requestsServed >= 1 else {
                return .failed("the gateway fixture served no /host/resolve request — the drive did not reach it")
            }
            // A configuration EXISTS, so by construction it carries a pin: since
            // 2026-08-13 `RelayConfig.expectedDoorStatic` is not optional. The name is
            // kept so the transcript stays comparable with the recorded baseline.
            let pinned = true
            // The pin the client ended up with must match what the gateway said, or the
            // drive tested something other than what it set up.
            switch identity {
            case .absent:
                return .failed("the gateway omitted machine_id and the client STILL built a configuration with a pin of \(config.expectedDoorStatic.count) bytes — it invented an identity nobody named, which is worse than the fail-open this case was written for")
            default: break
            }

            do {
                let channel = try await NoiseRelayChannel.connect(config: config)
                _ = channel
                return .completed(pinned: pinned, doorSawHandshake: door.sawHandshake)
            } catch RelayError.doorIdentityMismatch {
                return .refusedOnIdentity(pinned: pinned, doorSawHandshake: door.sawHandshake)
            } catch {
                // NOT a refusal. The client failed for a reason that is not the pin,
                // so this drive proves nothing about the pin.
                return .failed("the client failed for a reason that is not door identity: \(error)")
            }
        } catch {
            return .failed("\(error)")
        }
    }
}
