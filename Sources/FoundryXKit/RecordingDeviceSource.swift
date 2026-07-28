// RecordingDeviceSource — the capability-based model beneath the ONE device list.
//
// T1 RED STUB (track 20260725T2306_device_agnostic_recording_source). The type surface is
// declared so `features/device-agnostic-source.feature` can be wired and RUN; every body
// below is deliberately unimplemented so the scenarios fail against real assertions
// rather than against a missing symbol. The next commit implements them.

import Foundation

// MARK: - Shape

/// HOW a recording device delivers audio to the handset. This is a TRANSPORT fact, not a
/// vendor fact: "Omi" is one instance of `.bleStream`, never a case of its own.
public enum RecordingDeviceShape: String, Codable, Sendable, Equatable, CaseIterable {
    /// The device streams encoded audio frames to the handset over BLE.
    case bleStream
    /// The handset records from a Bluetooth audio INPUT ROUTE the device provides.
    case audioRoute
    /// The handset's own microphone.
    case builtInMic
}

/// WHICH code path turns a shape's bytes into capture frames.
public enum RecordingDeviceAdapter: String, Sendable, Equatable {
    case bleFrameStream
    case handsetInputRoute
}

// MARK: - Capabilities

/// An OPEN capability key. A device may declare a key this build has never heard of; that
/// must neither crash discovery nor grow a vendor branch, so the key space is strings.
public struct RecordingDeviceCapabilityKey: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let firmwareVersion = RecordingDeviceCapabilityKey("firmware-version")
    public static let gapRecovery = RecordingDeviceCapabilityKey("gap-recovery")
    public static let batteryLevel = RecordingDeviceCapabilityKey("battery-level")
    public static let offlineStorage = RecordingDeviceCapabilityKey("offline-storage")

    /// The keys this build has a meaning for. Everything else is representable but
    /// explicitly NOT understood.
    public static let understood: Set<RecordingDeviceCapabilityKey> =
        [.firmwareVersion, .gapRecovery, .batteryLevel, .offlineStorage]
}

public enum RecordingDeviceCapabilityState: Equatable, Sendable {
    /// Declared, with a value the device reported.
    case reported(String)
    /// Declared, no value (a boolean capability the device simply has).
    case present
    /// NOT declared. The honest answer; never a plausible default.
    case unavailable
    /// Declared under a key this build has no meaning for. Unavailable to the user, but
    /// kept rather than dropped so the fact is legible.
    case notUnderstood(String)

    public var isAvailable: Bool {
        switch self {
        case .reported, .present: return true
        case .unavailable, .notUnderstood: return false
        }
    }

    /// The value the device reported, or `nil`. Never fabricated.
    public var reportedValue: String? {
        if case .reported(let value) = self { return value }
        return nil
    }
}

/// Exactly what the device declared, and nothing else.
public struct RecordingDeviceCapabilities: Equatable, Sendable {
    public let declared: [String: String?]
    public init(declared: [String: String?] = [:]) { self.declared = declared }

    public func state(of key: RecordingDeviceCapabilityKey) -> RecordingDeviceCapabilityState {
        _ = key
        return .unavailable   // T1 RED STUB
    }

    /// Declared keys this build has no meaning for.
    public var unrecognizedKeys: [String] { [] }   // T1 RED STUB
}

// MARK: - Audio format and the one eligibility rule

public struct RecordingDeviceAudioProfile: Equatable, Sendable, Codable {
    public let codec: String
    public let sampleRateHz: Int
    public let channels: Int
    public let frameMilliseconds: Int

    public init(codec: String, sampleRateHz: Int, channels: Int, frameMilliseconds: Int) {
        self.codec = codec
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.frameMilliseconds = frameMilliseconds
    }
}

public enum RecordingDeviceRefusalReason: Equatable, Sendable {
    case noAudioFormatDeclared
    case unsupportedCodec(String)
    case unusableSampleRate(Int)
    case unusableFraming(milliseconds: Int, channels: Int)
    case audioStoppedBeingUsable(String)

    /// User-facing, actionable, and brand-free: the caller supplies the device's own
    /// reported name; this text never does.
    public var actionableReason: String { "" }   // T1 RED STUB
}

public enum RecordingDeviceEligibility: Equatable, Sendable {
    case eligible
    case refused(RecordingDeviceRefusalReason)

    public var isEligible: Bool { if case .eligible = self { return true }; return false }
    public var refusal: RecordingDeviceRefusalReason? {
        if case .refused(let reason) = self { return reason }
        return nil
    }
}

// MARK: - Identity, observation, entry

/// A stable, persistable device identity. `hardwareToken` is the transport's own handle
/// (a BLE peripheral identifier, an audio-route uid) — never a display name.
public struct RecordingDeviceIdentity: Hashable, Sendable, Codable {
    public let shape: RecordingDeviceShape
    public let hardwareToken: String
    public init(shape: RecordingDeviceShape, hardwareToken: String) {
        self.shape = shape
        self.hardwareToken = hardwareToken
    }
    /// Stable across launches and safe as a storage key.
    public var storageKey: String { "\(shape.rawValue)/\(hardwareToken)" }
}

/// What one discovery provider reports about one device.
public struct RecordingDeviceObservation: Equatable, Sendable {
    public let identity: RecordingDeviceIdentity
    public let reportedName: String
    public let audioProfile: RecordingDeviceAudioProfile?
    public let declaredCapabilities: [String: String?]

    public init(identity: RecordingDeviceIdentity,
                reportedName: String,
                audioProfile: RecordingDeviceAudioProfile?,
                declaredCapabilities: [String: String?] = [:]) {
        self.identity = identity
        self.reportedName = reportedName
        self.audioProfile = audioProfile
        self.declaredCapabilities = declaredCapabilities
    }
}

/// One row of the ONE list, after the catalog has evaluated it.
public struct RecordingDeviceEntry: Identifiable, Equatable, Sendable {
    public var id: RecordingDeviceIdentity { identity }
    public let identity: RecordingDeviceIdentity
    public let displayName: String
    public let capabilities: RecordingDeviceCapabilities
    public let audioProfile: RecordingDeviceAudioProfile?
    public let adapter: RecordingDeviceAdapter
    public let eligibility: RecordingDeviceEligibility

    public init(identity: RecordingDeviceIdentity,
                displayName: String,
                capabilities: RecordingDeviceCapabilities,
                audioProfile: RecordingDeviceAudioProfile?,
                adapter: RecordingDeviceAdapter,
                eligibility: RecordingDeviceEligibility) {
        self.identity = identity
        self.displayName = displayName
        self.capabilities = capabilities
        self.audioProfile = audioProfile
        self.adapter = adapter
        self.eligibility = eligibility
    }

    public var shape: RecordingDeviceShape { identity.shape }
}

/// One source of observations. A provider knows a transport, never a vendor.
public protocol RecordingDeviceDiscovering: AnyObject, Sendable {
    var shape: RecordingDeviceShape { get }
    func observeDevices() -> [RecordingDeviceObservation]
}

// MARK: - The catalog

public enum RecordingSourceCatalog {

    /// Codecs the capture pipeline can carry.
    public static let supportedCodecs: Set<String> = []   // T1 RED STUB

    public static func adapter(for shape: RecordingDeviceShape) -> RecordingDeviceAdapter {
        _ = shape
        return .handsetInputRoute   // T1 RED STUB
    }

    /// The ONE eligibility rule, applied identically to every shape and every name.
    public static func eligibility(
        of profile: RecordingDeviceAudioProfile?
    ) -> RecordingDeviceEligibility {
        _ = profile
        return .refused(.noAudioFormatDeclared)   // T1 RED STUB
    }

    public static func evaluate(_ observation: RecordingDeviceObservation) -> RecordingDeviceEntry {
        RecordingDeviceEntry(
            identity: observation.identity,
            displayName: observation.reportedName,
            capabilities: RecordingDeviceCapabilities(),
            audioProfile: observation.audioProfile,
            adapter: .handsetInputRoute,
            eligibility: .refused(.noAudioFormatDeclared))   // T1 RED STUB
    }

    /// Merge every provider's observations into ONE list. Every observation yields an
    /// entry — a refused device is still SHOWN, with its reason — and the order is a
    /// total order over name and identity, never over shape or vendor.
    public static func merge(_ observations: [RecordingDeviceObservation]) -> [RecordingDeviceEntry] {
        _ = observations
        return []   // T1 RED STUB
    }

    public static func merge(_ providers: [RecordingDeviceDiscovering]) -> [RecordingDeviceEntry] {
        merge(providers.flatMap { $0.observeDevices() })
    }
}

// MARK: - Device-agnostic reconnect

public enum RecordingDeviceLinkLossCause: Equatable, Sendable {
    /// The link went away on its own (out of range, device reboot, radio blip).
    case system
    /// The user detached the device.
    case userDetach
}

public enum RecordingDeviceReconnectDecision: Equatable, Sendable {
    case reissuePendingConnect
    case stayDetached
}

/// The shape-independent reconnect contract. For `.bleStream` it must make exactly the
/// decision the shipped `OmiReconnectPolicy` already makes, so the existing CoreBluetooth
/// chain keeps its behavior while stopping being vendor-shaped.
public enum RecordingDeviceReconnectPolicy {

    public static func onLinkLoss(
        cause: RecordingDeviceLinkLossCause,
        armed: Bool
    ) -> RecordingDeviceReconnectDecision {
        _ = (cause, armed)
        return .stayDetached   // T1 RED STUB
    }

    /// A manual reconnect is a distinct USER gesture: it re-arms a device the user
    /// previously detached.
    public static func onUserReconnect() -> RecordingDeviceReconnectDecision {
        .stayDetached   // T1 RED STUB
    }
}
