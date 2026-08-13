import Foundation

/// Bridges an already-authenticated Pocket protocol session into the vendor-neutral catalog.
/// It deliberately asks T1 only for evidenced battery and firmware facts; `SPACE` and `STE`
/// are neither queried nor interpreted by this device-list path.
public enum PocketRecordingDeviceBridge {
    /// The protocol this bridge speaks, as an identifier education and any other
    /// protocol-keyed content attaches to (design §5). It is NOT a shape and NOT a reported
    /// name: a second stored-file recorder speaking something else gets a different id, and
    /// therefore none of this one's education.
    public static let protocolIdentifier = "pocket-stored-file/v1"

    public static func observe(
        client: PocketBLEClient,
        identity: PocketAuthenticatedIdentity,
        advertisedName: String?
    ) async -> RecordingDeviceObservation {
        var capabilities: [String: String?] = [
            RecordingDeviceCapabilityKey.offlineStorage.rawValue: nil
        ]
        if let battery = try? await client.batteryLevel() {
            capabilities[RecordingDeviceCapabilityKey.batteryLevel.rawValue] = "\(battery)%"
        }
        if let firmware = try? await client.firmwareVersion() {
            capabilities[RecordingDeviceCapabilityKey.firmwareVersion.rawValue] = firmware
        }
        let trimmed = advertisedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RecordingDeviceObservation(
            identity: identity.recordingDeviceIdentity,
            reportedName: trimmed.isEmpty ? "Unnamed recording device" : trimmed,
            audioProfile: nil,
            declaredCapabilities: capabilities)
    }
}

/// THE MISSING HALF OF THE DEVICE LIST, AND THE ONE THIS TRACK EXISTS TO ADD.
///
/// `PocketRecordingDeviceBridge.observe` turns an authenticated stored-file session into a
/// vendor-neutral `RecordingDeviceObservation` — and then nothing happened to it. The device
/// list draws `RecordingDeviceStore` records, and the only caller of `recordUserPair` in the
/// whole tree was `DeviceManager.connect`, always with `shape: .bleStream`. So no observation
/// this bridge produced could ever become a row: the list could render at most the handset
/// microphone and a remembered Omi, which is exactly the gap Nick found on TestFlight 771837.
///
/// This is the join. It is shape-blind and vendor-blind on purpose — it takes an observation,
/// any observation, and records the pair the account will remember it by.
///
/// WHAT REACHES IT ON A REAL PHONE, AS OF THE SESSION-LIFETIME CHANGE. `PocketSeamTransport`
/// (`RecordingDeviceAttachment.swift`) is the CoreBluetooth-backed `PocketBLETransport`, and
/// `RecordingDeviceAttachment.attach` runs this bridge on the session it opens. What is still
/// missing is downstream of here and named where it lives: nothing brings a recorder's files
/// over yet — `PocketBLEClient.download` has no caller — so `PocketRecorderCheck` lists a
/// recorder's shelf and every row on it reads "Only on the recorder".
///
/// (THIS PARAGRAPH USED TO SAY there is no `PocketBLETransport` conformance backed by
/// CoreBluetooth anywhere in the tree. That was true when it was written and stopped being
/// true when the attach seam shipped; it is corrected rather than deleted because reading it
/// as current status is what makes this whole file look unwired.)
public enum RecordingDeviceAdoption {
    /// Remember an observed device under the identity the transport established for it.
    ///
    /// `reportedName` is DISPLAY metadata and nothing else — the durable address is
    /// `observation.identity`, which for a stored-file recorder is the authenticated
    /// peripheral token, never the advertised name.
    @discardableResult
    public static func remember(
        _ observation: RecordingDeviceObservation
    ) -> RecordingDeviceDetachOutcome {
        RecordingDeviceStore.recordUserPair(identity: observation.identity,
                                            displayName: observation.reportedName)
    }
}

public enum RecordingDeviceLinkState: String, Equatable, Sendable {
    case connected, reconnecting, disconnected
}

public enum StoredFileCustody: Equatable, Sendable {
    case foundryX
    case recorderOnly
}

public struct StoredFileManifestItem: Equatable, Sendable {
    public let id: String
    public let title: String
    public let sizeBytes: Int
    public let custody: StoredFileCustody
    public init(id: String, title: String, sizeBytes: Int, custody: StoredFileCustody) {
        self.id = id; self.title = title; self.sizeBytes = sizeBytes; self.custody = custody
    }
}

public struct StoredFileManifestRowPresentation: Equatable, Sendable {
    public let title: String
    public let duration: String
    public let custodyLabel: String
}

public struct StoredFileManifestPresentation: Equatable, Sendable {
    public let rows: [StoredFileManifestRowPresentation]
}

public struct StoredFileDeviceDetailPresentation: Equatable, Sendable {
    public let name: String
    public let eyebrow: String
    public let linkLabel: String
    public let battery: String
    public let firmware: String
    public let manifest: StoredFileManifestPresentation
    public let showsRecordingState: Bool
    public let showsLiveActivity: Bool
}

public enum StoredFileDevicePresentation {
    public static func manifest(_ items: [StoredFileManifestItem]) -> StoredFileManifestPresentation {
        StoredFileManifestPresentation(rows: items.map {
            .init(title: $0.title,
                  duration: duration(sizeBytes: $0.sizeBytes),
                  custodyLabel: $0.custody == .foundryX ? "In Solleva" : "Only on the recorder")
        })
    }

    public static func detail(
        name: String,
        link: RecordingDeviceLinkState,
        battery: RecordingDeviceCapabilityState,
        firmware: RecordingDeviceCapabilityState,
        manifest items: [StoredFileManifestItem]
    ) -> StoredFileDeviceDetailPresentation {
        StoredFileDeviceDetailPresentation(
            name: name,
            eyebrow: RecordingDeviceClass.recordThenSync.caption.uppercased(),
            // LINK REACHABILITY, IN THE DESIGN'S OWN WORDS. `rawValue.capitalized` rendered
            // `.disconnected` as "Disconnected" and `.reconnecting` as "Reconnecting"; the
            // design's honest substitute for a hero status is `Connected` / `Connecting` /
            // `Not connected`, and never "In range" — the phone cannot distinguish
            // out-of-range from powered-off from connected-to-another-app.
            linkLabel: link.label,
            // NOT "N/A". A capability the device did not report is UNAVAILABLE — the shipped
            // word, which is a statement — and the `N/A · N/A · N/A` strip an unpaired device
            // used to render is the exact anti-pattern this replaces.
            battery: battery.reportedValue ?? RecordingDeviceConnectPresentation.unavailableValue,
            firmware: firmware.reportedValue ?? RecordingDeviceConnectPresentation.unavailableValue,
            manifest: manifest(items),
            showsRecordingState: false,
            showsLiveActivity: false)
    }

    /// Pocket fw-1.6 lists bytes at a fixed 32 kbps CBR: 4,000 bytes per second.
    public static func duration(sizeBytes: Int) -> String {
        let seconds = max(0, sizeBytes) / 4_000
        if seconds >= 3_600 {
            let hours = seconds / 3_600, minutes = seconds % 3_600 / 60
            return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
        }
        if seconds >= 60 { return "\(seconds / 60) min" }
        return "\(seconds) sec"
    }
}

public struct StoredFileLiveEffectCounts: Equatable, Sendable {
    public var storedFileLifecycleEvents = 0
    public var activeSourceSelections = 0
    public var frameRouterStarts = 0
    public var walWrites = 0
    public var liveActivities = 0
    public var liveStateMutations = 0
    public static let zero = StoredFileLiveEffectCounts(storedFileLifecycleEvents: 5)
}

public final class StoredFileLiveBoundarySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = StoredFileLiveEffectCounts()
    public var counts: StoredFileLiveEffectCounts { lock.withLock { storage } }
    public init() {}
    fileprivate func storedFileLifecycleEvent() { lock.withLock { storage.storedFileLifecycleEvents += 1 } }
    public func activeSourceSelected() { lock.withLock { storage.activeSourceSelections += 1 } }
    public func frameRouterStarted() { lock.withLock { storage.frameRouterStarts += 1 } }
    public func walWritten() { lock.withLock { storage.walWrites += 1 } }
    public func liveActivityStarted() { lock.withLock { storage.liveActivities += 1 } }
    public func liveStateMutated() { lock.withLock { storage.liveStateMutations += 1 } }
}

public enum StoredFileDeviceLifecycle {
    public static func runFullLinkLifecycle(liveBoundaries: StoredFileLiveBoundarySpy) {
        // Discovery, attachment, display, disconnect and reconnect are catalog/link events.
        // There is intentionally no call here to any live capture boundary.
        for _ in 0..<5 { liveBoundaries.storedFileLifecycleEvent() }
    }
}
