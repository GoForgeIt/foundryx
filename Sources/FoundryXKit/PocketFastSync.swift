import Foundation

public struct PocketFastSyncEvidence: Sendable, Equatable {
    public let stockControlTrace: Bool
    public let closureSafety: Bool
    public let endpoint: URL?
    public let endpointHardwareProvenance: Bool
    public let iOSAccessPointJoin: Bool
    public let measuredRate: Bool
    public init(stockControlTrace: Bool = false, closureSafety: Bool = false, endpoint: URL? = nil,
                endpointHardwareProvenance: Bool = false, iOSAccessPointJoin: Bool = false,
                measuredRate: Bool = false) {
        self.stockControlTrace = stockControlTrace; self.closureSafety = closureSafety
        self.endpoint = endpoint; self.endpointHardwareProvenance = endpointHardwareProvenance
        self.iOSAccessPointJoin = iOSAccessPointJoin; self.measuredRate = measuredRate
    }
}

public enum PocketFastSyncGap: String, Error, Sendable, Equatable {
    case identityMismatch = "Pocket identity does not match secure custody"
    case credentialMismatch = "Pocket WiFi credential did not agree with secure custody"
    case closureSafety = "E-POCKET-CLOSURE"
    case stockControl = "E-WIFI-CONTROL"
    case endpoint = "E-WIFI-ENDPOINT"
    case iOSAccessPoint = "E-iOS-AP"
    case joinFailed = "Pocket WiFi join failed"
    /// THE RECORDER NEVER SAID A CLIENT HAD JOINED. Its own status stayed at "waiting for a
    /// client" past the budget — a different fact from a join this phone knows failed, and one
    /// that used to be reported as a malformed response.
    case recorderNeverReady = "Pocket recorder never reported a joined client"
    case httpFailed = "Pocket WiFi transfer failed"
    case validationFailed = "Pocket WiFi payload validation failed"
}

public struct PocketFastSyncPresentation: Sendable, Equatable {
    public let title: String
    public let body: String
    public let primaryAction: String
    public let passwordLabel: String
    public let hasPasswordField: Bool
    public static let setup = PocketFastSyncPresentation(
        title: "FAST SYNC", body: offerBody,
        primaryAction: "Turn on Fast sync", passwordLabel: "Already known", hasPasswordField: false)

    /// WHAT THE OFFER SAYS, AND WHY IT NO LONGER SAYS "MUCH FASTER".
    ///
    /// It asks `PocketMeasuredFigures` whether anyone has timed this, and nobody has: the WiFi
    /// transfer has never been performed — the HTTP endpoint the device serves files from is
    /// still UNCONFIRMED upstream in pocket-libre — and the Bluetooth leg was never timed
    /// either, because the 2026-08-16 bench deliberately refused `APP&U` on the owner's own
    /// recorder. The "~150x" behind the old sentence is a flagged guess.
    ///
    /// So the offer states the MECHANISM, which is true and is also the part a person needs:
    /// their phone is about to leave its network. A superlative is the prose form of the same
    /// unmeasured number, and hedging it ("often much faster") would be the guess with a hedge
    /// in front of it.
    static var offerBody: String {
        guard PocketMeasuredFigures.fastSyncOfferMayClaimSpeed else {
            return "Uses the recorder's own WiFi instead of Bluetooth. "
                + "Your phone leaves its normal network while it runs."
        }
        return "Much faster for long backlogs. Your phone leaves its normal network while it runs."
    }
    public static let settings = PocketFastSyncPresentation(
        title: "Fast sync", body: "Uses the recorder's WiFi. Your phone leaves its normal network while it runs.",
        primaryAction: "Use recorder WiFi", passwordLabel: "Already known", hasPasswordField: false)
    public static let sheetWarning = "Your phone leaves its normal WiFi while this runs. Internet may be unavailable until it reconnects."

    // MARK: - What an attempt is allowed to say afterwards

    /// WHAT HAPPENED, IN WORDS, INCLUDING WHEN NOTHING HAPPENED.
    ///
    /// Every one of these is a sentence about the RECORDING and the recorder. None of them is a
    /// number, because there is no measured number to print: no WiFi throughput has ever been
    /// taken off a Pocket by anyone, and the `~150×` that circulates in the design notes is
    /// arithmetic over a figure its own source tags `[GUESS]`. `everyLine` below is the
    /// population a scenario holds that rule over, so a line added later cannot escape it.
    public static let succeededLine =
        "This recording is now in Solleva. It's still on the recorder too."
    public static let keptBluetoothLine =
        "Left on Bluetooth. Nothing was moved and your phone stayed on its own network."
    /// THE HONEST STATE OF THE WORLD TODAY. Nobody has ever confirmed the address the recorder
    /// serves its files from — `PROTOCOL.md:149` says "HTTP endpoint: TBD" — so this is the
    /// line a real recorder earns until somebody measures it, and it says what is missing
    /// rather than blaming the recorder.
    public static let endpointUnmeasuredLine =
        "Solleva doesn't know where this recorder serves its files yet, so it used Bluetooth. "
        + "Nothing was left switched on."
    public static let cannotJoinLine =
        "This phone can't join the recorder's network, so nothing was moved."
    public static let notThisRecorderLine =
        "That network isn't this recorder's, so Solleva didn't join it."
    public static let neverReadyLine =
        "The recorder never saw this phone join its network. Nothing was moved, and the "
        + "recorder is back on Bluetooth."
    public static let transferFailedLine =
        "The transfer didn't finish, so nothing was kept. The recording is still on the "
        + "recorder — try again when it's nearby."

    /// EVERY STRING THIS FAMILY CAN PUT IN FRONT OF A PERSON.
    ///
    /// It did not exist, and that absence was load-bearing. The gates that scan copy
    /// populations take the union of the families' `everyLine`, so a family without one is a
    /// family the gates CANNOT SEE — which is how `setup.body` shipped opening with "Much
    /// faster for long backlogs" while `PocketFastSyncProgress` two types below was carefully
    /// refusing to print a rate without `measuredRate`. The same claim, one screen earlier, in
    /// words instead of digits, where nothing was looking.
    ///
    /// THIS IS THE UNION OF TWO STEPS' POPULATIONS, resolved by hand. Step 3 enumerated the
    /// two presentations FIELD BY FIELD — including `passwordLabel`, which the other side
    /// omitted — so that the measured-figure gate scans every string a person can read. Step 8
    /// added the eight outcome sentences below, which Step 3 had no way to know about. Taking
    /// either side whole drops the other's rows: Step 3's alone stops the outcome lines being
    /// scanned, and Step 8's alone stops `passwordLabel` being scanned AND re-hardcodes the
    /// unmeasured speed claim into `setup.body`. Neither loss is visible at a call site.
    public static var everyLine: [String] {
        [setup, settings].flatMap { [$0.title, $0.body, $0.primaryAction, $0.passwordLabel] }
            + [sheetWarning, succeededLine, keptBluetoothLine, endpointUnmeasuredLine,
               cannotJoinLine, notThisRecorderLine, neverReadyLine, transferFailedLine]
    }

    /// The line an outcome earns. Nothing here renders a `PocketFastSyncGap`'s raw value: those
    /// are engineering names (`E-WIFI-ENDPOINT`) and putting one on a person's screen is how a
    /// gate becomes a shrug.
    public static func message(for outcome: PocketFastSyncOutcome) -> String {
        switch outcome {
        case .completed:                    return succeededLine
        case .keptBluetooth:                return keptBluetoothLine
        case .paused, .cancelled:           return keptBluetoothLine
        case .unavailable(let gap), .failed(let gap):
            switch gap {
            case .endpoint:                                 return endpointUnmeasuredLine
            case .iOSAccessPoint, .joinFailed:              return cannotJoinLine
            case .identityMismatch, .credentialMismatch:    return notThisRecorderLine
            case .recorderNeverReady:                       return neverReadyLine
            case .closureSafety, .stockControl,
                 .httpFailed, .validationFailed:            return transferFailedLine
            }
        }
    }
}

public struct PocketFastSyncProgress: Sendable, Equatable {
    public let count: String
    public let states: [String]
    public let quantitativeClaim: String?
    public init(completed: Int, total: Int, measuredRate: Bool, measuredClaim: String? = nil) {
        count = "\(completed) of \(total)"
        states = completed > 0 && completed < total ? ["Over", "Now", "Waiting"] : []
        quantitativeClaim = measuredRate ? measuredClaim : nil
    }
}

public struct PocketAccessPoint: Sendable, Equatable { public let ssid: String; public let password: String }
public protocol PocketSoftAPJoining: Sendable { func join(_ accessPoint: PocketAccessPoint) async throws }
public protocol PocketHTTPPulling: Sendable { func pull(_ endpoint: URL) async throws -> Data }
public protocol PocketFastSyncHandoff: Sendable { func accept(_ payload: Data) async throws }

/// THE RECORDER'S SIDE OF THE SWAP, IN FOUR STEPS THAT CANNOT BE REORDERED.
///
/// IT USED TO BE ONE STEP, `prepare(_:)`, AND THAT WAS THE BUG. `PROTOCOL.md:139-143` legends
/// the access point's status codes: `3` = "AP created, waiting for client connection", `2` =
/// "client connecting", `1` = "ready for file transfer". So `1` is a statement ABOUT A JOINED
/// CLIENT — and `prepare()` waited for `1` before the coordinator had asked anything to join.
/// Both this client and the reference Python one were ordered to deadlock, and the measured
/// proof is in `PocketFastSyncControlOrderingTests`: against a scripted recorder that behaves
/// the way real hardware does, the old shape wrote `WIFIO`, `WIFIS`, `WIFIS`, `WIFIS` in 0.2
/// seconds and gave up while the access point sat at `3`, waiting for a phone nobody had told
/// to join.
///
/// Splitting the choreography is what makes the ordering a property of the TYPE rather than of
/// a comment: there is no way to express "wait for ready, then join" against this protocol.
public protocol PocketFastSyncControlling: Sendable {
    /// `APP&WIFI` — what the recorder says its own network is called and what its password is.
    /// A plain read: it enables no radio and joins nothing.
    ///
    /// It returns the READBACK rather than a credential, because the readback is the type that
    /// refuses to hand its password to anything that has not first proved the recorder is
    /// holding our key — and because the password that joins is the recorder's own, never one
    /// derived from the session key. (`PocketKeyMint.swift` records the hardware session that
    /// settled that, and what it cost.)
    func reportedAccessPoint() async throws -> PocketAccessPointReadback
    /// `APP&U&WIFI` -> `APP&WIFIO`: the radio comes up and starts waiting for somebody.
    func openAccessPoint() async throws
    /// Poll `APP&WIFIS` until the recorder says a client has joined and it is ready to serve.
    /// - Parameter seconds: how long the recorder is allowed to take. The reference client
    ///   allows 90 (`pocket-libre/src/pocket_libre/cli.py:1035`, `wifi_wait_ready(timeout=90)`).
    func awaitClientJoined(withinSeconds seconds: TimeInterval) async throws
    /// Select the file and start the transfer on the WiFi side.
    func beginTransfer(_ request: PocketRecordingRequest) async throws
    /// `APP&WIFIC`. Runs on EVERY exit, including the ones that never got as far as opening
    /// anything — leaving a recorder with its access point up is the one side effect this
    /// errand can have on somebody's desk.
    func cleanup() async
}

public enum PocketFastSyncOutcome: Sendable, Equatable {
    case completed, keptBluetooth, paused, cancelled, unavailable(PocketFastSyncGap), failed(PocketFastSyncGap)
}

public actor PocketFastSyncCoordinator {
    private let joiner: any PocketSoftAPJoining
    private let http: any PocketHTTPPulling
    private let handoff: any PocketFastSyncHandoff
    private let control: any PocketFastSyncControlling
    public init(joiner: any PocketSoftAPJoining, http: any PocketHTTPPulling,
                handoff: any PocketFastSyncHandoff, control: any PocketFastSyncControlling) {
        self.joiner = joiner; self.http = http; self.handoff = handoff; self.control = control
    }

    public func keepUsingBluetooth() -> PocketFastSyncOutcome { .keptBluetooth }

    /// HOW LONG THE RECORDER IS ALLOWED TO NOTICE A PHONE HAS JOINED IT — ninety seconds, the
    /// same budget the reference client allows (`pocket-libre/src/pocket_libre/cli.py:1035`).
    ///
    /// It is a defaulted PARAMETER, not an environment knob and not a constant a caller has to
    /// know to override: the correct value is the reference one, and a scenario that wants to
    /// watch the budget run out passes a small number in the open.
    public static let readinessBudgetSeconds: TimeInterval = 90

    /// ONE RECORDING, OVER THE RECORDER'S OWN NETWORK, WITH THE RECORDER PUT BACK AFTERWARDS.
    ///
    /// The order below is the whole point of this function and it is the reference trace's
    /// order (`PROTOCOL.md:97-131`), which is NOT the order this code used to run in:
    ///
    ///   1. is this recorder ours — asked of a plain read, before any radio is enabled;
    ///   2. is there evidence that each leg of this can work at all;
    ///   3. the access point comes up and starts waiting for a client;
    ///   4. THE PHONE JOINS — while the recorder is at status `3`, waiting for exactly that;
    ///   5. only now the recorder is asked whether it is ready, for up to `readinessSeconds`;
    ///   6. the file is selected and served;
    ///   7. cleanup, on every path out, including the ones that failed before step 3.
    ///
    /// - Parameter sessionKey: never joined with. It is the question asked of the recorder's
    ///   own readback, and the readback's answer is what the join uses.
    public func run(identityMatches: Bool,
                    sessionKey: String,
                    request: PocketRecordingRequest = .init(date: "candidate", timestamp: "candidate"),
                    evidence: PocketFastSyncEvidence,
                    readinessSeconds: TimeInterval = PocketFastSyncCoordinator.readinessBudgetSeconds)
    async -> PocketFastSyncOutcome {
        guard identityMatches else { return .failed(.identityMismatch) }
        guard sessionKey.utf8.count == PocketSessionKeyMint.length else {
            return .failed(.identityMismatch)
        }
        // NOTHING IS ENABLED YET. `reportedAccessPoint()` is a read on the authenticated
        // session, so a recorder that turns out not to be ours costs it no radio and leaves
        // nothing up — which is why the credential question is asked here rather than after
        // the access point exists.
        let readback: PocketAccessPointReadback
        do { readback = try await control.reportedAccessPoint() }
        catch { return .failed(.credentialMismatch) }
        // THE ONE QUESTION, AND THE ONLY WAY THE PASSWORD COMES OUT. A recorder that answers
        // with a password our key cannot account for hands out nothing, so there is no path
        // from here to a join on a recorder we did not recognise.
        guard let credentials = readback.credentials(provenBy: sessionKey) else {
            return .failed(.credentialMismatch)
        }

        guard evidence.closureSafety else { return .unavailable(.closureSafety) }
        guard evidence.stockControlTrace else { return .unavailable(.stockControl) }
        guard let endpoint = evidence.endpoint, evidence.endpointHardwareProvenance else {
            return .unavailable(.endpoint)
        }
        guard evidence.iOSAccessPointJoin else { return .unavailable(.iOSAccessPoint) }

        var outcome: PocketFastSyncOutcome?
        do { try await control.openAccessPoint() }
        catch { outcome = .failed(.stockControl) }

        if outcome == nil {
            // STEP 4, AND IT IS BEFORE STEP 5 ON PURPOSE. The recorder is sitting at status
            // `3` — "waiting for client connection" — and this is the client.
            do { try await joiner.join(credentials) }
            catch { outcome = .failed(.joinFailed) }
        }
        if outcome == nil {
            do { try await control.awaitClientJoined(withinSeconds: readinessSeconds) }
            catch { outcome = .failed(.recorderNeverReady) }
        }
        if outcome == nil {
            do { try await control.beginTransfer(request) }
            catch { outcome = .failed(.stockControl) }
        }
        var payload: Data?
        if outcome == nil {
            // THE JOIN CAN SUCCEED AND THIS CAN STILL FAIL, and that is a KNOWN outcome rather
            // than a surprise: nobody has ever confirmed which URL the recorder serves files
            // from (`PROTOCOL.md:149`, "HTTP endpoint: TBD"). A puller that hung here would
            // turn an unmeasured fact into a phone that never comes back; the shipped puller
            // carries its own deadline and this maps whatever it throws to one named gap.
            do { payload = try await http.pull(endpoint) }
            catch { outcome = .failed(.httpFailed) }
        }
        if outcome == nil, let payload {
            do { try await handoff.accept(payload); outcome = .completed }
            catch { outcome = .failed(.validationFailed) }
        }
        await control.cleanup()
        return outcome ?? .failed(.validationFailed)
    }
}
