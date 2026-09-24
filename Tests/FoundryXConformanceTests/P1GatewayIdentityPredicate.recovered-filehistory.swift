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
/// - **(i) `machine_id` absent.** `HostResolver.swift:94` reads
///   `(obj["machine_id"] as? String) ?? ""`; `hexToData("")` returns nil on the
///   `!hex.isEmpty` guard at `:60`; `RelayConfig.expectedDoorStatic` is therefore nil.
///   Both consumers are conditional — `RelayTransport.swift:109`
///   `if let expected = config.expectedDoorStatic { … }` and `DoorConnection.swift:286`
///   `if let expected = config.expectedDoorStatic, initiator.remoteStaticPublic != expected`
///   — so **no pin is checked and the channel completes**. This is the fail-open.
/// - **(ii) `machine_id` present but wrong.** The pin is non-nil and mismatches, so
///   the client throws `RelayError.doorIdentityMismatch` and refuses.
///
/// **CLOSED iff the client refuses in BOTH.** At the pinned baseline case (i) proceeds,
/// so P1 is **OPEN (RED)** — which is what makes it a gate. Running only case (ii)
/// would report a refusal and hide the defect entirely, which is why the case count is
/// asserted rather than the outcome alone.
///
/// ## Two things this predicate refuses to do
///
/// 1. **A transport failure is not a refusal.** A case counts as *refused* only when
///    the client threw `RelayError.doorIdentityMismatch` — the identity refusal itself.
///    Any other error means the case could not be driven, and the predicate REFUSES
///    rather than publishing a status. Counting a dead relay as "the client refused"
///    would report P1 CLOSED on a rig that never tested anything.
/// 2. **A rig that refuses everything must not pass.** Before the two cases, a
///    POSITIVE CONTROL drives the *correct* `machine_id` and requires the channel to
///    complete. Without it, a broken door or a mis-parsed relay URL would make every
///    case "refuse" and P1 would report CLOSED — the fix reported as landed because
///    the harness stopped working.
enum P1GatewayIdentityPredicate {

    struct CaseResult {
        let name: String
        /// True only when the client refused *on door identity*.
        let refused: Bool
        let detail: String
    }

    private enum Drive {
        case completed(pinned: Bool, doorSawHandshake: Bool)
        case refusedOnIdentity(pinned: Bool, doorSawHandshake: Bool)
        /// The client refused BEFORE dialling, because the gateway's answer could not
        /// be turned into a door key at all (`HostResolveError.hostCannotBePinned`).
        ///
        /// This is a STRONGER refusal than `refusedOnIdentity`, not a weaker one: no
        /// relay connection is opened and no handshake is attempted, so there is no
        /// window in which a channel exists unpinned. It is a separate case because
        /// rule 1 of this predicate — "a transport failure is not a refusal" — would
        /// otherwise classify it as a rig failure and publish no status, which is
        /// exactly what happened the first time the client was fixed.
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
            return refuse("the POSITIVE CONTROL was refused at resolve: \(why). The door's own machine_id was served and the client would not even build a config from it, so every refusal below would be meaningless.", cases: 0)
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
                detail: "the client REFUSED on door identity (expectedDoorStatic pinned=\(pinned))"))
        case .refusedAtResolve(let why):
            cases.append(CaseResult(name: "absent-identity", refused: true,
                detail: "the client REFUSED AT RESOLVE and never dialled — \(why)"))
        case .failed(let e):
            return refuse("case absent-identity could not be driven: \(e)", cases: 0)
        }
        transcript.append("case absent-identity: \(cases[0].detail)")

        // ---- case (ii): an identity that is present but is not the door's ---------
        switch await drive(relayURL: relayURL, identity: .wrong) {
        case .completed(let pinned, _):
            cases.append(CaseResult(name: "wrong-identity", refused: false,
                detail: "the client COMPLETED the channel (expectedDoorStatic pinned=\(pinned))"))
        case .refusedOnIdentity(let pinned, _):
            cases.append(CaseResult(name: "wrong-identity", refused: true,
                detail: "the client REFUSED on door identity (expectedDoorStatic pinned=\(pinned))"))
        case .refusedAtResolve(let why):
            cases.append(CaseResult(name: "wrong-identity", refused: true,
                detail: "the client REFUSED AT RESOLVE and never dialled — \(why)"))
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
                guard case .hostCannotBePinned(let why) = e else { throw e }
                // The client refused the DESIGNATION rather than the handshake. Prove
                // the gateway was actually asked before crediting the refusal — a
                // refusal produced without reaching the fixture would be a rig fault
                // wearing a refusal's name.
                guard gateway.requestsServed >= 1 else {
                    return .failed("the client refused with hostCannotBePinned(\(why)) but the gateway fixture served no /host/resolve request — the refusal did not come from the response under test")
                }
                return .refusedAtResolve(why)
            }

            guard gateway.requestsServed >= 1 else {
                return .failed("the gateway fixture served no /host/resolve request — the drive did not reach it")
            }
            // `RelayConfig.expectedDoorStatic` is not optional, so a config that exists
            // is pinned by construction — there is no longer a `pinned=false` config to
            // observe. The flag is kept so the transcript still reports it explicitly.
            let pinned = true
            // The pin the client ended up with must match what the gateway said, or the
            // drive tested something other than what it set up.
            switch identity {
            case .absent where pinned:
                return .failed("the gateway omitted machine_id but the client still built a pin — the case did not set up what it claims")
            case .wrong where !pinned, .correct where !pinned:
                return .failed("the gateway supplied a machine_id but the client built no pin — the case did not set up what it claims")
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
