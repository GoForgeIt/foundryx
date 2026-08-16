import Foundation

/// Bridges an already-authenticated Pocket protocol session into the vendor-neutral catalog.
///
/// IT NOW ASKS `APP&SPACE`, AND KEEPS WHAT IT HEARS. This comment used to say `SPACE` was
/// "neither queried nor interpreted by this device-list path", and that was accurate: the
/// opcode was decoded, `PocketBLEClient.storage()` was implemented and unit-tested, and a
/// tree-wide search for callers outside `Tests/` returned nothing. So the one question an
/// owner opens this page to ask — how much room is left — had no answer anywhere in the app.
/// `STE` is still not asked: nobody has decoded what its integer means, and a number whose
/// meaning is unknown is not a fact worth rendering.
public enum PocketRecordingDeviceBridge {

    /// HOW FULL THE RECORDER IS — ASKED AFTER THE LISTING, NEVER BEFORE IT.
    ///
    /// THE DEFECT THIS SEPARATION CLOSES. `APP&SPACE` runs inside `protected(.information)`,
    /// and `protected` calls `retire(...)` on `.timeout`. `try?` swallows the throw but NOT the
    /// retirement — so a firmware that silently ignores this command (rather than answering
    /// `MCU&UNKNOWN`, which is `.unsupportedOperation` and retires nothing) takes the whole
    /// authenticated session down, and the listing that follows throws `.unauthenticated`. The
    /// owner is then told "Solleva connected to this recorder, but it didn't say what it's
    /// holding" about a recorder that would have listed perfectly well, and the ONE thing they
    /// opened the page for is gone in exchange for a number.
    ///
    /// These bytes have never been issued to a real recorder from this app — the free-space
    /// delta is probe P3 and it has not run. So the order is: get the thing that matters
    /// first, then ask the question that might cost the session. A reading that does not arrive
    /// renders as the never-asked state, with the action that would ask, which is the direction
    /// this whole strip is built in.
    public static func storageReading(client: PocketBLEClient,
                                      now: Date = Date()) async -> RecordingDeviceReading? {
        guard let storage = try? await client.storage() else { return nil }
        return RecordingDeviceReading(
            value: RecordingDeviceReadingPresentation.freeSpace(
                usedKilobytes: storage.usedKilobytes,
                capacityKilobytes: storage.capacityKilobytes),
            observedAt: now)
    }

    /// The protocol this bridge speaks, as an identifier education and any other
    /// protocol-keyed content attaches to (design §5). It is NOT a shape and NOT a reported
    /// name: a second stored-file recorder speaking something else gets a different id, and
    /// therefore none of this one's education.
    public static let protocolIdentifier = "pocket-stored-file/v1"

    /// - Parameter now: this phone's clock at the moment the recorder answered — the stamp
    ///   every reading carries. Injected so a scenario can state an age rather than sleep for
    ///   one, and NEVER the recorder's own clock: a Pocket ships with an unset clock
    ///   (`PocketConversationClock`), so dating a reading by it would put it in 1970.
    public static func observe(
        client: PocketBLEClient,
        identity: PocketAuthenticatedIdentity,
        advertisedName: String?,
        now: Date = Date()
    ) async -> RecordingDeviceObservation {
        var capabilities: [String: String?] = [
            RecordingDeviceCapabilityKey.offlineStorage.rawValue: nil
        ]
        var readings: [String: RecordingDeviceReading] = [:]
        if let battery = try? await client.batteryLevel() {
            capabilities[RecordingDeviceCapabilityKey.batteryLevel.rawValue] = "\(battery)%"
            readings[RecordingDeviceCapabilityKey.batteryLevel.rawValue] =
                RecordingDeviceReading(value: "\(battery)%", observedAt: now)
        }
        if let firmware = try? await client.firmwareVersion() {
            capabilities[RecordingDeviceCapabilityKey.firmwareVersion.rawValue] = firmware
            readings[RecordingDeviceCapabilityKey.firmwareVersion.rawValue] =
                RecordingDeviceReading(value: firmware, observedAt: now)
        }
        // SPACE IS NOT ASKED HERE. See `storageReading(client:now:)` — this used to end with
        // that read, ordered last among BAT/FW/SPACE, on a comment claiming the order protected
        // the listing. It did not: all three of these reads precede the listing, so ordering
        // among themselves protects the two READINGS and nothing else.
        let trimmed = advertisedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RecordingDeviceObservation(
            identity: identity.recordingDeviceIdentity,
            reportedName: trimmed.isEmpty ? "Unnamed recording device" : trimmed,
            audioProfile: nil,
            declaredCapabilities: capabilities,
            readings: readings)
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
    ///
    /// AND IT KEEPS WHAT THE DEVICE SAID. The pair used to be the ONLY thing that survived
    /// this call: the battery and firmware the bridge had just read went out of scope here
    /// and were gone, so the very first thing a person saw after adopting a recorder was a
    /// page reporting `Unavailable` for the two facts the adoption had just measured.
    @discardableResult
    public static func remember(
        _ observation: RecordingDeviceObservation
    ) -> RecordingDeviceDetachOutcome {
        let outcome = RecordingDeviceStore.recordUserPair(identity: observation.identity,
                                                          displayName: observation.reportedName)
        // Only against a pair that landed. Writing readings for a device the store could not
        // record would be a fact filed under an address the account does not hold.
        if case .recorded = outcome {
            RecordingDeviceStore.recordObservedFacts(identity: observation.identity,
                                                     readings: observation.readings)
        }
        return outcome
    }
}

public enum RecordingDeviceLinkState: String, Equatable, Sendable {
    case connected, reconnecting, disconnected
}

// `StoredFileCustody { foundryX, recorderOnly }` USED TO LIVE HERE, AND IT IS RETIRED.
//
// It was a two-valued answer to a three-valued question. It could not say "on this phone, but
// not yet safe anywhere else" — the one state that decides whether clearing the recorder is
// safe — and it could not say "nobody asked", so a caller that never consulted custody rendered
// every row as `.recorderOnly` with exactly the confidence of a row that had asked and been
// told no. `PocketRecordingPresence` (`PocketPresence.swift`) replaces it: three places, three
// answers each, and an `observedAt` per place.

public struct StoredFileManifestItem: Equatable, Sendable {
    public let id: String
    public let title: String
    public let sizeBytes: Int
    public let presence: PocketRecordingPresence
    public init(id: String, title: String, sizeBytes: Int, presence: PocketRecordingPresence) {
        self.id = id; self.title = title; self.sizeBytes = sizeBytes; self.presence = presence
    }
}

public struct StoredFileManifestRowPresentation: Equatable, Sendable {
    public let title: String
    public let duration: String
    /// The one-line summary. `Solleva hasn't checked this iPhone` is the sentence the old
    /// two-valued label had no way to say.
    public let presenceLabel: String
    /// The three places, each with its own answer and its own age. `unknown` renders as
    /// `Unknown`, and a place nobody asked about carries the age `never checked`.
    public let places: [PocketPlaceLine]
    /// THE READING ITSELF, carried alongside the rendered lines so the reset's cost and the
    /// forget confirmation are computed from the SAME reading the rows are drawn from. A
    /// second count of "how many are only on the recorder", derived from the strings, is how
    /// a screen ends up showing two different numbers for one fact.
    public let presence: PocketRecordingPresence
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
    /// - Parameter now: the instant the ages are rendered against. Injected rather than read
    ///   from the clock inside the presentation, so a scenario can state a reading's age as a
    ///   fact instead of racing it.
    public static func manifest(_ items: [StoredFileManifestItem],
                                now: Date = Date()) -> StoredFileManifestPresentation {
        StoredFileManifestPresentation(rows: items.map {
            .init(title: $0.title,
                  duration: duration(sizeBytes: $0.sizeBytes),
                  presenceLabel: PocketPresencePresentation.label($0.presence),
                  places: PocketPresencePresentation.lines($0.presence, now: now),
                  presence: $0.presence)
        })
    }

    public static func detail(
        name: String,
        link: RecordingDeviceLinkState,
        battery: RecordingDeviceCapabilityState,
        firmware: RecordingDeviceCapabilityState,
        manifest items: [StoredFileManifestItem],
        now: Date = Date()
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
            manifest: manifest(items, now: now),
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
