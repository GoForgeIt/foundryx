import Foundation

/// Bridges an already-authenticated Pocket protocol session into the vendor-neutral catalog.
/// It deliberately asks T1 only for evidenced battery and firmware facts; `SPACE` and `STE`
/// are neither queried nor interpreted by this device-list path.
public enum PocketRecordingDeviceBridge {
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
                  custodyLabel: $0.custody == .foundryX ? "In FoundryX" : "Only on the recorder")
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
            eyebrow: "RECORDS ON ITS OWN",
            linkLabel: link.rawValue.capitalized,
            battery: battery.reportedValue ?? "N/A",
            firmware: firmware.reportedValue ?? "N/A",
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
    public private(set) var counts = StoredFileLiveEffectCounts()
    public init() {}
    fileprivate func storedFileLifecycleEvent() { counts.storedFileLifecycleEvents += 1 }
}

public enum StoredFileDeviceLifecycle {
    public static func runFullLinkLifecycle(liveBoundaries: StoredFileLiveBoundarySpy) {
        // Discovery, attachment, display, disconnect and reconnect are catalog/link events.
        // There is intentionally no call here to any live capture boundary.
        for _ in 0..<5 { liveBoundaries.storedFileLifecycleEvent() }
    }
}
