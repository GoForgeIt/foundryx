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
        title: "FAST SYNC", body: "Much faster for long backlogs. Your phone leaves its normal network while it runs.",
        primaryAction: "Turn on Fast sync", passwordLabel: "Already known", hasPasswordField: false)
    public static let settings = PocketFastSyncPresentation(
        title: "Fast sync", body: "Uses the recorder's WiFi. Your phone leaves its normal network while it runs.",
        primaryAction: "Use recorder WiFi", passwordLabel: "Already known", hasPasswordField: false)
    public static let sheetWarning = "Your phone leaves its normal WiFi while this runs. Internet may be unavailable until it reconnects."
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
public protocol PocketFastSyncControlling: Sendable {
    func prepare(_ request: PocketRecordingRequest) async throws
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

    public func run(identityMatches: Bool, sessionKey: String, reportedSSID: String,
                    reportedPassword: String, request: PocketRecordingRequest = .init(date: "candidate", timestamp: "candidate"),
                    evidence: PocketFastSyncEvidence) async -> PocketFastSyncOutcome {
        guard identityMatches else { return .failed(.identityMismatch) }
        guard sessionKey.utf8.count == 16 else { return .failed(.identityMismatch) }
        let derived = String(sessionKey.prefix(8))
        guard reportedPassword == derived else { return .failed(.credentialMismatch) }
        guard evidence.closureSafety else { return .unavailable(.closureSafety) }
        guard evidence.stockControlTrace else { return .unavailable(.stockControl) }
        guard let endpoint = evidence.endpoint, evidence.endpointHardwareProvenance else { return .unavailable(.endpoint) }
        guard evidence.iOSAccessPointJoin else { return .unavailable(.iOSAccessPoint) }
        do { try await control.prepare(request) }
        catch { return .failed(.stockControl) }
        var outcome: PocketFastSyncOutcome?
        do { try await joiner.join(.init(ssid: reportedSSID, password: derived)) }
        catch { outcome = .failed(.joinFailed) }
        var payload: Data?
        if outcome == nil {
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
