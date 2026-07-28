// RecordingSurfacePresentation — the ONE rendered recording-device experience, and the
// honest copy that goes with it
// (track 20260725T2306_device_agnostic_recording_source, task T5).
//
// WHAT T5 OWNS, AND WHY IT IS A VALUE LAYER. Everything below is pure and total: the one
// connection affordance, the one list, per-device capabilities, the refusal, the timeline's
// attribution of a conversation to the device that recorded it, and the gap-recovery
// sentence. The App target renders these 1:1 (the house rule `DevicePagePresentation`
// already follows), so the values the Brine driver asserts ARE the values that ship — a
// SwiftUI body that re-derived any of them would be a second, untested implementation of the
// same copy.
//
// FOUR THINGS THIS FILE REFUSES TO DO.
//
//   1. INVENT A CAPABILITY. A capability the device did not declare renders as unavailable,
//      never as a plausible default. The shipped device page hard-coded a firmware string
//      ("2.4.1") for every connected device; that is a fabricated value about a device that
//      never reported one, and it is gone.
//   2. RANK BY FAMILY. The list order comes from `RecordingSourceCatalog.merge`, which sorts
//      by reported name and identity and cannot see the shape. The controls the list offers
//      are DATA (`RecordingDeviceListControl`), so "no reachable control hides a device by
//      family" is a property of a value a test can evaluate rather than a claim about a
//      screenshot.
//   3. GUESS WHAT RECORDED A CONVERSATION. Attribution is total over
//      `CaptureDeviceProvenance`. Each of its five answers gets its own sentence, including
//      the two that mean "I cannot tell you" — and those two carry their diagnostic, because
//      a surface that renders "Unknown device" with nothing else has told the user a fact
//      they can do nothing with.
//   4. CALL A RECOVERABLE GAP UNRECOVERABLE. `.nothingToRecover` means the device still holds
//      that audio for the next reconnect. Rendering it as loss is the failure the whole gap
//      window exists to prevent, and `GapRecoveryCopy` is asserted never to emit the loss
//      phrase for it.

import Foundation

// MARK: - The ONE list

/// One honest capability line for a device.
public struct RecordingDeviceCapabilityLine: Equatable, Sendable {
    public let label: String
    /// The value the device REPORTED, or the unavailable word. Never fabricated.
    public let value: String
    public let isAvailable: Bool

    public init(label: String, value: String, isAvailable: Bool) {
        self.label = label
        self.value = value
        self.isAvailable = isAvailable
    }
}

/// One row of the one list.
public struct RecordingDeviceRowPresentation: Equatable, Sendable, Identifiable {
    public var id: RecordingDeviceIdentity { identity }
    public let identity: RecordingDeviceIdentity
    /// The device's OWN reported name. Copy about a specific device uses the name the device
    /// gave; only generic copy is written here, and that copy is brand-free.
    public let displayName: String
    public let capabilities: [RecordingDeviceCapabilityLine]
    /// nil ⇒ connectable. Non-nil ⇒ an actionable, brand-free reason, shown IN the list — a
    /// refused device that vanished would leave the user with a device that simply never
    /// appears and nothing to do about it.
    public let refusal: String?

    public var isConnectable: Bool { refusal == nil }

    public init(identity: RecordingDeviceIdentity,
                displayName: String,
                capabilities: [RecordingDeviceCapabilityLine],
                refusal: String?) {
        self.identity = identity
        self.displayName = displayName
        self.capabilities = capabilities
        self.refusal = refusal
    }
}

/// A control the rendered list offers, expressed as DATA.
///
/// The spec forbids a filter, default, or collapsed group that hides a device because of its
/// family. "There is no such control" is only checkable if the controls are enumerable, so
/// they are — and `hidesADeviceByFamily` is a total function over them.
public struct RecordingDeviceListControl: Equatable, Sendable {
    /// What the control removes from the list, if anything.
    public enum Hiding: Equatable, Sendable {
        case none
        /// Removes every device of a connection shape. This is the forbidden one.
        case byShape(RecordingDeviceShape)
        /// Removes devices whose reported name matches — also forbidden: a vendor filter is a
        /// family filter with extra steps.
        case byNameSubstring(String)
    }
    public let title: String
    public let hiding: Hiding

    public init(title: String, hiding: Hiding) {
        self.title = title
        self.hiding = hiding
    }
}

public enum RecordingDeviceConnectPresentation {

    // MARK: Generic copy — brand-free, by inspection AND by assertion

    /// The ONE recording-device connection affordance in the rendered app.
    public static let affordanceTitle = "Connect a recording device"
    public static let listTitle = "Recording devices"
    public static let emptyLine = "No recording devices found yet. Put yours in pairing mode."
    public static let scanningLine = "Looking for recording devices…"
    public static let unavailableValue = "Unavailable"

    /// Every piece of generic copy this surface can render, so "generic device copy names no
    /// vendor" is checked over a POPULATION rather than over whichever strings a test author
    /// happened to remember.
    public static let genericCopy: [String] = [
        affordanceTitle, listTitle, emptyLine, scanningLine, unavailableValue,
    ] + capabilityLabels

    /// The capabilities the list shows, in a fixed order, with their labels.
    public static let capabilityOrder: [RecordingDeviceCapabilityKey] = [
        .batteryLevel, .firmwareVersion, .gapRecovery, .offlineStorage,
    ]

    public static func label(for key: RecordingDeviceCapabilityKey) -> String {
        switch key {
        case .batteryLevel:    return "Battery"
        case .firmwareVersion: return "Firmware"
        case .gapRecovery:     return "Gap recovery"
        case .offlineStorage:  return "Offline storage"
        default:               return key.rawValue
        }
    }

    public static var capabilityLabels: [String] { capabilityOrder.map(label(for:)) }

    /// The word shown for a capability the device HAS but reported no value for.
    public static let availableValue = "Available"

    // MARK: The list

    public static func capabilityLines(
        _ capabilities: RecordingDeviceCapabilities
    ) -> [RecordingDeviceCapabilityLine] {
        capabilityOrder.map { key in
            switch capabilities.state(of: key) {
            case .reported(let value):
                return RecordingDeviceCapabilityLine(label: label(for: key), value: value,
                                                     isAvailable: true)
            case .present:
                return RecordingDeviceCapabilityLine(label: label(for: key), value: availableValue,
                                                     isAvailable: true)
            case .unavailable, .notUnderstood:
                // A capability this build has no meaning for is unavailable TO THE USER, and
                // it is still not a value we may invent one for.
                return RecordingDeviceCapabilityLine(label: label(for: key),
                                                     value: unavailableValue, isAvailable: false)
            }
        }
    }

    public static func row(_ entry: RecordingDeviceEntry) -> RecordingDeviceRowPresentation {
        RecordingDeviceRowPresentation(
            identity: entry.identity,
            displayName: entry.displayName,
            capabilities: capabilityLines(entry.capabilities),
            refusal: entry.eligibility.refusal?.actionableReason)
    }

    /// The ONE list, in the catalog's own order. Nothing is removed here: a refused device is
    /// listed WITH its reason.
    public static func rows(_ entries: [RecordingDeviceEntry]) -> [RecordingDeviceRowPresentation] {
        entries.map(row)
    }

    /// The controls the list offers. Empty, and that is the point — the spec allows sorting,
    /// labels, and badges, none of which remove a row.
    public static let controls: [RecordingDeviceListControl] = []

    /// Would any reachable control remove a device from the list because of its family?
    /// Total over the control set, so adding a shape or name filter makes this true.
    public static func hidesADeviceByFamily(
        controls: [RecordingDeviceListControl] = controls,
        list: [RecordingDeviceRowPresentation]
    ) -> Bool {
        for control in controls {
            switch control.hiding {
            case .none:
                continue
            case .byShape(let shape):
                if list.contains(where: { $0.identity.shape == shape }) { return true }
            case .byNameSubstring(let needle):
                if list.contains(where: {
                    $0.displayName.range(of: needle, options: .caseInsensitive) != nil
                }) { return true }
            }
        }
        return false
    }
}

// MARK: - What recorded a conversation, on the timeline

/// The timeline's answer for one conversation.
public struct CaptureAttribution: Equatable, Sendable {
    /// The name shown against the conversation.
    public let deviceName: String
    /// Non-nil when the name is NOT an answer — something the user can act on instead of a
    /// bare "Unknown device".
    public let diagnostic: String?
    /// True when the two on-disk surfaces disagree about this capture — see
    /// `CaptureAttributionPresentation`'s note on the Record button.
    public let surfacesDisagree: Bool

    public var isKnown: Bool { diagnostic == nil }

    public init(deviceName: String, diagnostic: String? = nil, surfacesDisagree: Bool = false) {
        self.deviceName = deviceName
        self.diagnostic = diagnostic
        self.surfacesDisagree = surfacesDisagree
    }
}

public enum CaptureAttributionPresentation {

    /// Shown when the app genuinely cannot name the recorder. Always accompanied by a
    /// diagnostic — "Unknown device" on its own is a shrug.
    public static let unknownDeviceName = "Unknown device"

    /// THE TWO SURFACES, AND WHICH ONE WINS (review round 9, M2).
    ///
    /// A capture directory carries two facts about its source and they answer different
    /// questions:
    ///
    ///   * `.capture-source` — the SELECTED source kind (`omi` / `phoneMic`), written from
    ///     `CaptureSettings.captureSource` at `beginSession`. It is byte-frozen: every
    ///     conversation recorded before device records shipped depends on it.
    ///   * `.capture-device.json` — the ACTUAL recorder, resolved from what the capture
    ///     manager says is recording.
    ///
    /// THEY CAN DISAGREE, on a first-class path. The Record button, the Action Button and the
    /// Siri intent all call `startMicRecording()` without touching `captureSource` — that is
    /// deliberate (the phone mic is a MANUAL record source; only an Omi activation flows to
    /// `selectCaptureSource`). So "an external device is the selected source, the user taps
    /// Record" produces a capture whose marker says `omi` and whose device record says
    /// `builtInMic`.
    ///
    /// **The device record wins, here and everywhere.** It answers the question the timeline
    /// is asking — *what made this recording* — and it agrees with what the live surface said
    /// while it was being made (`CaptureLiveStatus.sourceLabel` keys off `isRecordingMic`
    /// first too). The marker's answer is *what the user had selected*, which is a different
    /// and still-true fact; it keeps its bytes and its meaning, and the disagreement is
    /// reported (`surfacesDisagree`) rather than quietly resolved.
    public static func attribution(for provenance: CaptureDeviceProvenance,
                                   legacySourceMarker: String?) -> CaptureAttribution {
        switch provenance {
        case .identified(let context):
            let expected = CaptureDeviceSidecar.sourceMarker(for: context.identity.shape)
            return CaptureAttribution(
                deviceName: context.displayName,
                diagnostic: nil,
                surfacesDisagree: legacySourceMarker != nil && legacySourceMarker != expected)

        case .legacyPreMigration, .undatable:
            // THE LEGACY ARM, RENDERED. A conversation recorded before device records shipped
            // is not missing anything: its `.capture-source` marker is a complete answer for
            // what it is, and it renders through the SAME label function the live surface uses
            // so the archive and the app cannot drift apart. (Round 8, L3: this clause is what
            // "a legacy Omi recording still renders 'Omi'" actually means — the rendered
            // label, not the marker bytes.)
            return CaptureAttribution(deviceName: legacyDisplayName(forMarker: legacySourceMarker))

        case .unknownPostMigration(let diagnostic):
            return CaptureAttribution(deviceName: unknownDeviceName, diagnostic: diagnostic)

        case .unreadableRecord(let diagnostic):
            return CaptureAttribution(deviceName: unknownDeviceName, diagnostic: diagnostic)
        }
    }

    /// The production path a timeline row takes: read both surfaces off disk and answer.
    public static func attribution(captureId: String, baseDir: URL) -> CaptureAttribution {
        attribution(for: CaptureDeviceSidecar.provenance(captureId: captureId, baseDir: baseDir),
                    legacySourceMarker: CaptureManager.capturedSourceOnDisk(captureId,
                                                                            baseDir: baseDir))
    }

    /// The label a pre-device-record conversation carries, from the shipped marker. Routed
    /// through `CaptureLiveStatus.sourceLabel` so the archive says exactly what the live
    /// surface said while it was recording.
    public static func legacyDisplayName(forMarker marker: String?) -> String {
        guard let marker, let kind = CaptureSourceKind(rawValue: marker) else {
            // No marker at all: an era we cannot name a source for either. Still not a
            // fabricated device name.
            return unknownDeviceName
        }
        return CaptureLiveStatus.sourceLabel(source: kind, isRecordingMic: false)
    }
}

// MARK: - What became of the audio recorded during a gap

public enum GapRecoveryCopy {

    /// The phrase that means AUDIO IS GONE. It may appear for exactly one outcome.
    public static let lossPhrase = "was not recoverable"

    /// Total over the outcome. Every arm is a sentence a person can act on, and the three
    /// "still on the device" cases say so instead of borrowing the loss phrase.
    public static func line(for outcome: GapRecoveryOutcome) -> String {
        switch outcome {
        case .recovered(_, let frames):
            return "Audio recorded while your device was disconnected has been added to this "
                + "conversation (\(frames) frames)."
        case .partiallyRecovered(_, let frames, let reason):
            return "Some of the audio recorded while your device was disconnected has been "
                + "added (\(frames) frames); the rest is still on the device and will come "
                + "back on the next connection (\(reason))."
        case .nothingBuffered:
            return "Nothing was recorded while your device was disconnected, so no audio is "
                + "missing from this conversation."
        case .nothingToRecover(let reason):
            // NOT A LOSS. The span is sitting on the device.
            return "Audio from the disconnection is still on your device and will be collected "
                + "on the next connection (\(reason))."
        case .unrecoverable(let reason):
            return "Audio from the disconnection \(lossPhrase) (\(reason))."
        }
    }

    /// Whether this outcome's line is allowed to contain the loss phrase.
    public static func isLoss(_ outcome: GapRecoveryOutcome) -> Bool { outcome.isLoss }
}

// MARK: - N7: which account a gap outcome is rendered into

/// The decision T5 makes about a gap-recovery report.
public enum GapRecoveryRenderDecision: Equatable, Sendable {
    case show(String)
    /// The account whose audio this is about is no longer the exposed one. Dropped from every
    /// surface, with a reason, rather than rendered into somebody else's timeline.
    case withheld(reason: String)
}

public enum GapRecoveryRendering {

    /// N7, DECIDED (carried from the T3 review, measured by T4's seam suite).
    ///
    /// THE HAZARD. `closeAudioExposure` clears the sync engine, the hold, and the live hold,
    /// but never the gap window. The `cancelPeripheralConnection` it issues drives
    /// `didDisconnect`, which closes the window honestly — so the outcome is not lost. But
    /// both the outcome and the source state are published from that same callback AFTER the
    /// account's audio exposure has been claimed closed, and only the state is suppressed.
    /// T4 measured exactly this: the `.stopped` is gated, the gap outcome sails through.
    ///
    /// THE DECISION. A gap outcome describes ONE account's audio, so it is rendered into that
    /// account or into nothing. The report carries the scope the window was opened under; if
    /// the exposed account has changed by the time it arrives, it is withheld. Rendering it
    /// into "whatever account is current" would put one person's recording history in front of
    /// another person — the same class of leak the account-scoped store exists to prevent, and
    /// arriving through a callback rather than through storage does not make it a different
    /// one.
    ///
    /// WHY NOT SUPPRESS IT AT THE PUBLISHER INSTEAD. Because the outcome is still TRUE, and a
    /// diagnostic reader investigating a torn-down account needs it. Withholding is a rendering
    /// decision with a stated reason; deleting it would be a fourth silent state in a type
    /// built so that "I could not answer" is a value.
    public static func decide(_ report: GapRecoveryReport,
                              currentScope: String?) -> GapRecoveryRenderDecision {
        guard let opened = report.accountScope else {
            return .withheld(reason:
                "this gap outcome carries no account, so there is no timeline it belongs to")
        }
        guard opened == currentScope else {
            return .withheld(reason:
                "the account whose audio this describes is no longer the one on screen")
        }
        return .show(GapRecoveryCopy.line(for: report.outcome))
    }
}
