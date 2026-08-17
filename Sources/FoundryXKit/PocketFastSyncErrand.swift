// PocketFastSyncErrand.swift — THE CONSTRUCTOR `PocketFastSyncCoordinator` NEVER HAD.
//
// WHAT WAS MISSING, MEASURED. `PocketFastSyncCoordinator` shipped complete: six evidence gates
// in order, the seven-step control choreography on `PocketBLEClient`, both entry points' copy
// written, eight green Brine scenarios. And this repository's own reachability register said,
// in its own words, `pocket-fast-sync-coordinator` -> `"unreachable"`, *"constructed only in its
// own feature test"*, with `pocket-ble-fast-sync-control` -> `"undetermined"` beside it and the
// remedy printed in the row: *"the way to find out is to make the coordinator reachable."*
// `grep FastSync App/*.swift` returned nothing at all. This file is that constructor, and the
// three protocol conformers a real phone needs.
//
// THE THREE DEFECTS THIS FILE IS DOWNSTREAM OF, all fixed before it was written, because with
// any one of them in place a first attempt on real hardware fails for the wrong reason:
//
//   1. THE PASSWORD. `PocketSessionKeyMint` derived the access-point password as
//      `sessionKey.prefix(8)`. Real hardware (2026-08-16, `PKT01_BLUE_26079bc5`, fw 1.6) reports
//      `PD9QQDJ8` for key `PD9QQDJ6KM3PJDFC` — the EIGHTH character disagrees — so the
//      possession gate refused the owner's own recorder. The readback is now the authority and
//      the join uses what the recorder said. (`PocketKeyMint.swift`,
//      `PocketFastSyncHardwareEvidenceTests`.)
//   2. THE READINESS POLL. `prepare()` asked three times with no delay; pocket-libre allows 90
//      seconds. Measured: `WIFIO, WIFIS, WIFIS, WIFIS` in 0.2 s, then "malformed response".
//   3. THE ORDERING. Status `1` means "ready for file transfer" and the recorder only reaches
//      it AFTER a client joins, so waiting for `1` before joining was a deadlock by
//      construction. The choreography is now four steps and the join is between them.
//
// WHAT THIS FILE DELIBERATELY DOES NOT DO.
//
//   * IT PROMISES NO SPEED. No WiFi throughput has ever been measured off a Pocket by anyone;
//     the `~150×` in the design notes is arithmetic over a figure its own source tags `[GUESS]`.
//     `PocketFastSyncProgress.quantitativeClaim` stays nil without `measuredRate`, and nothing
//     here supplies one.
//   * IT INVENTS NO ENDPOINT. `PROTOCOL.md:149` says "HTTP endpoint: TBD" and nobody has
//     confirmed it, so `endpoint` is a PARAMETER with no default. Absent one, this errand
//     refuses BEFORE touching the radio and says so in a sentence — a legible outcome, not a
//     phone sitting on a recorder's network waiting for a URL that does not answer.
//   * IT ISSUES NO DELETE. Same promise as the Bluetooth leg, for the same reason.

import Foundation

#if canImport(NetworkExtension)
import NetworkExtension
#endif

// MARK: - Joining the recorder's own network

/// THE PHONE'S SIDE OF THE JOIN.
///
/// iOS will not let an app associate to an access point without
/// `com.apple.developer.networking.HotspotConfiguration` in the entitlements AND in the
/// provisioning profile — and a missing profile entitlement fails at SIGNING, not at runtime.
/// The entitlement is now in `App/FoundryX.entitlements`.
///
/// `isSupported` is a fact about the BUILD, not a preference: on macOS — where `swift test`
/// runs — there is no `NEHotspotConfigurationManager`, so this reports false and the coordinator
/// stops at its own `E-iOS-AP` gate with a sentence, rather than throwing from a platform shim.
public struct PocketHotspotJoiner: PocketSoftAPJoining {

    public init() {}

    public static var isSupported: Bool {
#if canImport(NetworkExtension) && os(iOS)
        return true
#else
        return false
#endif
    }

    public func join(_ accessPoint: PocketAccessPoint) async throws {
#if canImport(NetworkExtension) && os(iOS)
        let configuration = NEHotspotConfiguration(ssid: accessPoint.ssid,
                                                   passphrase: accessPoint.password,
                                                   isWEP: false)
        // THE RECORDER'S NETWORK IS NOT SOMEWHERE TO LIVE. `joinOnce` means iOS drops it when
        // the app goes away instead of adding a network the owner's phone will prefer forever.
        configuration.joinOnce = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                // ALREADY-ASSOCIATED IS A JOIN, NOT A FAILURE. iOS reports `.alreadyAssociated`
                // when the phone is on that network already, which is the state a retry is in.
                if let error = error as? NEHotspotConfigurationError, error == .alreadyAssociated {
                    return continuation.resume()
                }
                if let error { return continuation.resume(throwing: error) }
                continuation.resume()
            }
        }
#else
        throw PocketFastSyncGap.iOSAccessPoint
#endif
    }

    // WHAT PUTS THE PHONE BACK, AND WHY THERE IS NO `leave()` HERE.
    //
    // A `removeConfiguration(forSSID:)` was written and then deleted rather than shipped
    // uncalled — an unreached method is the exact defect this whole file exists to close, and
    // adding a `leave()` step to `PocketSoftAPJoining` would have been a behaviour nobody can
    // test until a recorder is on a desk. What DOES put the phone back is measured: the errand
    // always runs `control.cleanup()` (`APP&WIFIC`), which was verified on hardware to return
    // the recorder's status to `0` and take the access point away — and `joinOnce` means iOS
    // does not keep a network the app asked for once for the owner to fall back onto. If a
    // bench run shows a phone still clinging to a vanished access point, THAT is when the
    // method comes back, wired.
}

// MARK: - Fetching the file

/// ONE GET, WITH A DEADLINE, OVER A NETWORK NOBODY HAS CONFIRMED.
///
/// The deadline is the whole design. The address the recorder serves files from is unmeasured,
/// so the likeliest outcome of the first real attempt is a socket that never answers — and a
/// pull with no timeout turns that into a phone parked on a recorder's network with its own
/// internet gone. `URLSession`'s default is 60 s per request and 7 DAYS per resource; both are
/// set here.
public struct PocketFastSyncHTTPPuller: PocketHTTPPulling {
    private let timeout: TimeInterval

    public init(timeoutSeconds: TimeInterval = 30) {
        self.timeout = timeoutSeconds
    }

    public func pull(_ endpoint: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // The recorder is a bare access point with no route to anywhere; a session that could
        // use a cached response would be answering a question about a different network.
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.allowsCellularAccess = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: endpoint)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PocketFastSyncGap.httpFailed
        }
        guard !data.isEmpty else { throw PocketFastSyncGap.httpFailed }
        return data
    }
}

// MARK: - The address nobody has confirmed

/// WHERE A POCKET SERVES ITS FILES FROM, AS A SINGLE PLACE THAT SAYS "NOBODY KNOWS".
///
/// `PROTOCOL.md:149` — the reference decode's own WiFi section — reads: *"IP: Likely
/// `192.168.4.1` (ESP32 SoftAP default). HTTP endpoint: TBD (needs probing once connected to
/// AP)."* "Likely" and "TBD" are not an address. Shipping `192.168.4.1/download` as a default
/// would make every failure look like a broken recorder instead of an unanswered question, and
/// the first person to see it would have no way to tell those apart.
///
/// So this is `nil`, and the whole surface reads it: the button is disabled with a sentence
/// under it, the errand refuses before touching the radio, and the coordinator's `E-WIFI-ENDPOINT`
/// gate refuses again behind that. The day the bench run in Step 3 P4 measures the URL, this
/// constant is the one line that changes.
public enum PocketFastSyncEndpoint {
    public static let measured: URL? = nil

    /// What answering it would take, kept next to the absence so the two travel together.
    public static let howItGetsMeasured =
        "Join the recorder's access point from a Mac while pocket-libre holds it open, and "
        + "record the URL the file actually comes from."
}

// MARK: - What has been measured

extension PocketFastSyncEvidence {

    /// EVERY GATE, ANSWERED FROM WHAT SOMEBODY ACTUALLY OBSERVED — and `false` wherever nobody
    /// has. This is the single place a claim about the hardware enters the shipping path.
    ///
    ///   * `stockControlTrace` — TRUE. `WIFIO -> WIFIS(3) -> WIFIC -> WIFIS(0)` was run against
    ///     `PKT01_BLUE_26079bc5` on fw 1.6 on 2026-08-16 and the status codes moved as legended
    ///     (`foundry-hearth/reference/pocket-ble-protocol.md`). This is the gate that was
    ///     genuinely unknown a day ago.
    ///   * `closureSafety` — TRUE, and it is a property of the FILE, not of the pipe. The
    ///     recording is one the recorder LISTED; the Bluetooth leg already pulls exactly those
    ///     on exactly this assumption (`PocketBringOver.swift`, `closureEvidence: true`).
    ///     Holding the WiFi transport to a stricter rule than the transport it replaces would
    ///     name the wrong blocker on a person's screen.
    ///   * `endpoint` / `endpointHardwareProvenance` — WHATEVER THE CALLER MEASURED, and
    ///     nothing when nobody has. `PROTOCOL.md:149` is still "HTTP endpoint: TBD".
    ///   * `iOSAccessPointJoin` — a fact about this BUILD: can it join an access point at all.
    ///   * `measuredRate` — FALSE, permanently, until somebody times a real transfer. It is
    ///     what keeps `quantitativeClaim` nil, and it is why no screen can print `~150×`.
    public static func asMeasured(endpoint: URL? = nil,
                                  canJoinAccessPoints: Bool = PocketHotspotJoiner.isSupported)
    -> PocketFastSyncEvidence {
        PocketFastSyncEvidence(stockControlTrace: true,
                               closureSafety: true,
                               endpoint: endpoint,
                               endpointHardwareProvenance: endpoint != nil,
                               iOSAccessPointJoin: canJoinAccessPoints,
                               measuredRate: false)
    }
}

#if canImport(CoreBluetooth)

// MARK: - The errand

/// ONE RECORDING, OVER THE RECORDER'S OWN NETWORK, LANDING WHERE A BLUETOOTH PULL LANDS.
public enum PocketFastSyncErrand {

    /// What one attempt established. The capture id travels for the same reason
    /// `PocketBringOverOutcome` carries it: without it the conversation is a correct capture
    /// directory nothing in the running app knows exists.
    public struct Result: Sendable {
        public let outcome: PocketFastSyncOutcome
        public let captureID: String?
        /// The sentence to show a person. Never a gap's raw value, never a number.
        public var message: String { PocketFastSyncPresentation.message(for: outcome) }
    }

    public static func run(
        peripheralIdentifier id: UUID,
        advertisedName: String,
        recording: PocketRecording,
        endpoint: URL?,
        custody: any PocketRecorderFileCustody = PocketRecorderFileStore(),
        secrets: any PocketSecretStore = KeychainPocketSecretStore(),
        attachment: RecordingDeviceAttachment = RecordingDeviceAttachment(),
        destination: PocketBringOver.Destination = .init(),
        joiner: any PocketSoftAPJoining = PocketHotspotJoiner(),
        http: any PocketHTTPPulling = PocketFastSyncHTTPPuller()
    ) async -> Result {
        let evidence = PocketFastSyncEvidence.asMeasured(endpoint: endpoint)
        // BEFORE THE RADIO IS TOUCHED. Two of the six gates are knowable without a recorder,
        // and opening a session to arrive at the same refusal costs the owner battery and the
        // recorder its time. The coordinator asks them again — this is a shortcut, not the
        // authority — which is why the SAME outcome vocabulary is returned.
        guard evidence.endpoint != nil, evidence.endpointHardwareProvenance else {
            return Result(outcome: .unavailable(.endpoint), captureID: nil)
        }
        guard evidence.iOSAccessPointJoin else {
            return Result(outcome: .unavailable(.iOSAccessPoint), captureID: nil)
        }

        let session = await attachment.withAuthenticatedSession(
            peripheralIdentifier: id, advertisedName: advertisedName
        ) { client, identity -> Result in
            guard let sessionKey = (try? await secrets.secret(for: identity)) ?? nil else {
                return Result(outcome: .failed(.identityMismatch), captureID: nil)
            }
            let handoff = CustodyHandoff(identity: identity.recordingDeviceIdentity,
                                         advertisedName: advertisedName,
                                         recording: recording,
                                         custody: custody,
                                         destination: destination)
            // THE EXISTENTIAL IS BOUND HERE, AND IT IS BOUND TO `PocketBLEClient`. The
            // reachability register could not see which conformer a `any
            // PocketFastSyncControlling` dispatches to; this is the line that decides it, and
            // `PocketFastSyncControlConformerTests` holds that there is exactly one conformer
            // to decide between.
            let control: any PocketFastSyncControlling = client
            let coordinator = PocketFastSyncCoordinator(joiner: joiner, http: http,
                                                        handoff: handoff, control: control)
            let outcome = await coordinator.run(identityMatches: true,
                                                sessionKey: sessionKey,
                                                request: recording.request,
                                                evidence: evidence)
            return Result(outcome: outcome, captureID: await handoff.captureID())
        }
        switch session {
        case .ran(let result):
            return result
        case .unavailable:
            // THE ATTACH SEAM'S OWN ANSWER, in this surface's vocabulary: nothing was moved and
            // nothing was left switched on, because no session ever opened.
            return Result(outcome: .failed(.identityMismatch), captureID: nil)
        }
    }

    /// THE SINK, AND IT IS NOT A NEW ONE. `PocketBringOver.keep(payload:…)` is the same custody
    /// commit, the same import and the same receipt a Bluetooth pull runs; this actor exists
    /// only to carry the four facts that identify the file across the coordinator's `accept`.
    private actor CustodyHandoff: PocketFastSyncHandoff {
        private let identity: RecordingDeviceIdentity
        private let advertisedName: String
        private let recording: PocketRecording
        private let custody: any PocketRecorderFileCustody
        private let destination: PocketBringOver.Destination
        private var kept: String?

        init(identity: RecordingDeviceIdentity, advertisedName: String,
             recording: PocketRecording, custody: any PocketRecorderFileCustody,
             destination: PocketBringOver.Destination) {
            self.identity = identity; self.advertisedName = advertisedName
            self.recording = recording; self.custody = custody; self.destination = destination
        }

        func accept(_ payload: Data) async throws {
            let outcome = await PocketBringOver.keep(payload: payload,
                                                     from: identity,
                                                     advertisedName: advertisedName,
                                                     recording: recording,
                                                     custody: custody,
                                                     destination: destination)
            guard let id = outcome.captureID else {
                // CUSTODY REFUSED, so this is not a completed transfer. Throwing is what makes
                // the coordinator say `validationFailed` instead of `completed` — a fast sync
                // that "succeeded" with nothing kept is the shape this whole surface is
                // written to prevent.
                throw PocketFastSyncGap.validationFailed
            }
            kept = id
        }

        func captureID() -> String? { kept }
    }
}

#endif
