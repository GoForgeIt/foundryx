// RecordingDeviceSource — the capability-based model beneath the ONE device list
// (track 20260725T2306_device_agnostic_recording_source, task T1).
//
// THE ONE THING THIS FILE EXISTS TO PREVENT. The shipped capture-source model reasons in
// VENDOR terms: `CaptureSourceCategory` has an `.omi` case, an `.omi`-first priority
// ladder, and an "Omi wearable" seed row. Whether an external Bluetooth recorder can be
// listed, connected, and recorded from must instead depend on WHAT IT CAN DO — the audio
// format it declares — and on nothing else. Omi is the first proving instance of
// `.bleStream`, never a branch.
//
// So there is exactly ONE eligibility rule (`eligibility(of:)`), applied identically to
// every shape and every name; exactly ONE merge (`merge(_:)`) that yields one entry per
// observation in an order derived from name and identity, never from shape or vendor; and
// capabilities that are reported ONLY as declared — an absent capability is `.unavailable`,
// never a plausible default, and a capability this build has never heard of is kept as
// `.notUnderstood` rather than dropped or turned into a vendor branch.

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
    /// The device records independently and later supplies completed stored files.
    case filePull
}

/// WHICH code path turns a shape's bytes into capture frames.
public enum RecordingDeviceAdapter: String, Sendable, Equatable {
    case bleFrameStream
    case handsetInputRoute
    /// Classification only. Retrieval belongs to the stored-file sync track.
    case storedFileSync
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
    /// HOW MUCH ROOM IS LEFT, which is a READING and not a capability: `offlineStorage` says
    /// the device has storage of its own, and rendered as "Available" it was standing in for
    /// a number nobody was asking for. `APP&SPACE` answers it.
    public static let freeSpace = RecordingDeviceCapabilityKey("free-space")

    /// The keys this build has a meaning for. Everything else is representable but
    /// explicitly NOT understood.
    public static let understood: Set<RecordingDeviceCapabilityKey> =
        [.firmwareVersion, .gapRecovery, .batteryLevel, .offlineStorage, .freeSpace]
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
        // NOT DECLARED is the only honest answer for a capability the device never
        // mentioned. Note the double optional: `declared[k]` is `.some(nil)` when the
        // device declared a valueless capability and `nil` when it declared nothing.
        guard let value = declared[key.rawValue] else { return .unavailable }
        guard RecordingDeviceCapabilityKey.understood.contains(key) else {
            return .notUnderstood(key.rawValue)
        }
        guard let value else { return .present }
        return .reported(value)
    }

    /// Declared keys this build has no meaning for. Kept, not dropped: losing them would
    /// make a device look less capable than it is, and inventing a case for each would be
    /// the vendor branch this track exists to remove.
    public var unrecognizedKeys: [String] {
        declared.keys
            .filter { !RecordingDeviceCapabilityKey.understood.contains(RecordingDeviceCapabilityKey($0)) }
            .sorted()
    }
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
    public var actionableReason: String {
        switch self {
        case .noAudioFormatDeclared:
            return "This device did not report an audio format, so it cannot be recorded "
                + "from. Check that it is in recording mode and try connecting again."
        case .unsupportedCodec(let codec):
            return "This device records in a format this app cannot read (\(codec)). "
                + "Choose another recording device."
        case .unusableSampleRate(let rate):
            return "This device records at \(rate) Hz, which is too low to transcribe. "
                + "Check its recording quality setting, or choose another device."
        case .unusableFraming(let milliseconds, let channels):
            return "This device reported an audio layout this app cannot read "
                + "(\(milliseconds) ms, \(channels) channels). Choose another recording device."
        case .audioStoppedBeingUsable(let detail):
            return "This device stopped sending usable audio (\(detail)). Audio recorded "
                + "before that is kept. Reconnect it, or choose another device."
        }
    }
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
    /// WHAT THIS DEVICE STATED ON THIS SESSION, each with the instant it stated it.
    ///
    /// SEPARATE FROM `declaredCapabilities` ON PURPOSE, and not a widening of it. A declared
    /// capability is a claim about what a device CAN do and it survives the link going down;
    /// a reading is a measurement that was true at a moment and is stale the second after.
    /// Folding free space into the capability map would put a number that decays by the hour
    /// in the same bag as `offline-storage: Available`, which does not decay at all.
    public let readings: [String: RecordingDeviceReading]

    public init(identity: RecordingDeviceIdentity,
                reportedName: String,
                audioProfile: RecordingDeviceAudioProfile?,
                declaredCapabilities: [String: String?] = [:],
                readings: [String: RecordingDeviceReading] = [:]) {
        self.identity = identity
        self.reportedName = reportedName
        self.audioProfile = audioProfile
        self.declaredCapabilities = declaredCapabilities
        self.readings = readings
    }

    /// The same observation with one more reading folded in. Used where a fact is asked for
    /// AFTER the rest of the observation was taken — free space, which is deliberately the
    /// last thing asked on any session because the command can retire it.
    public func withReading(_ reading: RecordingDeviceReading,
                            for key: String) -> RecordingDeviceObservation {
        var merged = readings
        merged[key] = reading
        return RecordingDeviceObservation(identity: identity,
                                          reportedName: reportedName,
                                          audioProfile: audioProfile,
                                          declaredCapabilities: declaredCapabilities,
                                          readings: merged)
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
    public var isStoredFileUsable: Bool {
        shape == .filePull && capabilities.state(of: .offlineStorage).isAvailable
    }
    public var isLiveSourceCandidate: Bool {
        shape != .filePull && eligibility.isEligible
    }
}

/// One source of observations. A provider knows a transport, never a vendor.
public protocol RecordingDeviceDiscovering: AnyObject, Sendable {
    var shape: RecordingDeviceShape { get }
    func observeDevices() -> [RecordingDeviceObservation]
}

// MARK: - The catalog

public enum RecordingSourceCatalog {

    /// Codecs the capture pipeline can carry. A set, not a switch, so adding one is data.
    public static let supportedCodecs: Set<String> = ["opus", "pcm16"]

    /// Below this the audio cannot be transcribed usefully; it is the narrowband telephony
    /// rate, which is also the floor an HFP audio route delivers.
    public static let minimumSampleRateHz = 8_000
    /// The frame lengths the capture WAL can carry.
    public static let frameMillisecondRange = 1...120

    /// A TRANSPORT mapping. `.bleStream` receives frames FROM the device; the other two
    /// shapes are recorded BY the handset from a selected input route.
    public static func adapter(for shape: RecordingDeviceShape) -> RecordingDeviceAdapter {
        switch shape {
        case .bleStream: return .bleFrameStream
        case .audioRoute, .builtInMic: return .handsetInputRoute
        case .filePull: return .storedFileSync
        }
    }

    /// The ONE eligibility rule. It reads the declared audio format and NOTHING else — not
    /// the shape, not the reported name, not the hardware token. That is what makes
    /// eligibility capability-based rather than vendor-based, and it is asserted by
    /// substitution rather than by inspection (see the invariance test).
    public static func eligibility(
        of profile: RecordingDeviceAudioProfile?
    ) -> RecordingDeviceEligibility {
        guard let profile else { return .refused(.noAudioFormatDeclared) }
        guard supportedCodecs.contains(profile.codec.lowercased()) else {
            return .refused(.unsupportedCodec(profile.codec))
        }
        guard profile.sampleRateHz >= minimumSampleRateHz else {
            return .refused(.unusableSampleRate(profile.sampleRateHz))
        }
        guard profile.channels >= 1,
              frameMillisecondRange.contains(profile.frameMilliseconds) else {
            return .refused(.unusableFraming(milliseconds: profile.frameMilliseconds,
                                             channels: profile.channels))
        }
        return .eligible
    }

    public static func evaluate(_ observation: RecordingDeviceObservation) -> RecordingDeviceEntry {
        RecordingDeviceEntry(
            identity: observation.identity,
            displayName: observation.reportedName,
            capabilities: RecordingDeviceCapabilities(declared: observation.declaredCapabilities),
            audioProfile: observation.audioProfile,
            adapter: adapter(for: observation.identity.shape),
            eligibility: eligibility(of: observation.audioProfile))
    }

    /// Merge every provider's observations into ONE list. Every observation yields an
    /// entry — a refused device is still SHOWN, with its reason, because hiding it would
    /// leave the user with a device that simply never appears — and the order is a total
    /// order over the reported name and then the stable identity. Shape is deliberately
    /// absent from the comparison: sorting by family is how "one list" quietly becomes
    /// "one list, vendors first".
    public static func merge(_ observations: [RecordingDeviceObservation]) -> [RecordingDeviceEntry] {
        observations
            .map(evaluate)
            .sorted {
                let left = $0.displayName.lowercased(), right = $1.displayName.lowercased()
                if left != right { return left < right }
                return $0.identity.storageKey < $1.identity.storageKey
            }
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

    /// The only reason not to re-arm is the user having detached the device. A transient
    /// system drop always re-issues the standing pending connect, which is precisely what
    /// `OmiReconnectPolicy.onDisconnect(autoConnect:)` already decides for the BLE lane —
    /// asserted over the whole input cross-product, not assumed.
    public static func onLinkLoss(
        cause: RecordingDeviceLinkLossCause,
        armed: Bool
    ) -> RecordingDeviceReconnectDecision {
        switch cause {
        case .userDetach: return .stayDetached
        case .system: return armed ? .reissuePendingConnect : .stayDetached
        }
    }

    /// A manual reconnect is a distinct USER gesture: it re-arms a device the user
    /// previously detached. Nothing on the automatic path may reach this decision.
    public static func onUserReconnect() -> RecordingDeviceReconnectDecision {
        .reissuePendingConnect
    }
}
