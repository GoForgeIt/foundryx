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
//      `CaptureDeviceProvenance`. Each of its five answers gets its own sentence, and every
//      answer that is not one the classifier can stand behind carries its diagnostic, because
//      a surface that renders "Unknown device" with nothing else has told the user a fact
//      they can do nothing with. Nor is every failure to name a device the same failure: a
//      recording the classifier PLACED before device records is not an unknown device, it is
//      a recording from an era that kept none, and it says so — while a recording it could
//      not place is given neither that era nor the shrug, because "which era is this" is the
//      precise thing it reported it could not know.
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

/// WHAT THE CONNECT SHEET ACTUALLY DRAWS, once the peripherals that broadcast no name have
/// been dealt with.
///
/// THE REPORT. "There's too many unnamed Bluetooth devices. Can we hide anything that doesn't
/// have a name? They're just busy and kind of get in the way." A room full of BLE advertisers
/// produced a scan list where most rows were the same interchangeable
/// `Unnamed recording device`, and the one row the person was looking for was somewhere in it.
///
/// AND WHY THEY ARE NOT SIMPLY DROPPED. The sheet's own copy says FoundryX cannot tell what a
/// device is until it connects to it — that is `broadcastNameNote`, and it is true. Some real
/// recorders broadcast no name at all until they are connected, so a blanket permanent hide
/// would make a legitimate device *unpairable* while telling its owner "no recording devices
/// found yet". That is a strictly worse defect than a busy list.
///
/// SO THE RULE IS TWO-PART, AND BOTH PARTS MATTER:
///
///   1. UNNAMED ROWS ARE FOLDED ONLY WHEN THERE IS SOMETHING NAMED TO FOLD THEM BEHIND. If
///      nothing in range broadcasts a name, the unnamed devices ARE the list — hiding them
///      would leave an empty sheet in front of somebody whose recorder is right there.
///   2. THE FOLD IS ALWAYS DISCLOSED AND ALWAYS REVERSIBLE. The sheet says how many it is
///      holding back and offers to show them. Nothing here can make a device unreachable; the
///      worst it can do is cost one tap.
public struct RecordingDeviceScanList: Equatable, Sendable {
    /// The rows to draw, in the order the scan produced them.
    public let visible: [DiscoveredDevice]
    /// How many unnamed devices are being held back. Zero when none are.
    public let hiddenUnnamedCount: Int

    public init(visible: [DiscoveredDevice], hiddenUnnamedCount: Int) {
        self.visible = visible
        self.hiddenUnnamedCount = hiddenUnnamedCount
    }

    /// The disclosure line, or nil when there is nothing to disclose.
    public var hiddenLine: String? {
        hiddenUnnamedCount == 0
            ? nil
            : RecordingDeviceConnectPresentation.unnamedHiddenLine(count: hiddenUnnamedCount)
    }
}

public enum RecordingDeviceScanFilter {

    /// A device broadcasts a name when it broadcasts something other than whitespace.
    /// `DeviceManager` stores `p.name ?? ""`, and a name of `" "` is not a name.
    public static func broadcastsAName(_ device: DiscoveredDevice) -> Bool {
        !device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// - Parameter showingUnnamed: the disclosure's state. `true` is the person having asked
    ///   to see everything, and it always shows everything — there is no state of this screen
    ///   in which a discovered device cannot be reached.
    public static func resolve(_ discovered: [DiscoveredDevice],
                               showingUnnamed: Bool) -> RecordingDeviceScanList {
        let named = discovered.filter(broadcastsAName)
        let unnamed = discovered.count - named.count
        // NOTHING NAMED ⇒ NOTHING TO FOLD BEHIND. This is the branch that keeps a nameless
        // recorder pairable, and it is the reason this is a function rather than a `filter`.
        guard !named.isEmpty, !showingUnnamed else {
            return RecordingDeviceScanList(visible: discovered, hiddenUnnamedCount: 0)
        }
        return RecordingDeviceScanList(visible: named, hiddenUnnamedCount: unnamed)
    }
}

public enum RecordingDeviceConnectPresentation {

    // MARK: Generic copy — brand-free, by inspection AND by assertion

    /// The ONE recording-device connection affordance in the rendered app.
    public static let affordanceTitle = "Connect a recording device"
    public static let listTitle = "Recording devices"
    /// The title of the affordance's DESTINATION (design §3.1). It is not `listTitle`: the
    /// list is the devices you have, the sheet is the one device you are adding, and the two
    /// were shipped swapped.
    public static let connectSheetTitle = "Connect a device"
    public static let emptyLine = "No recording devices found yet. Put yours in pairing mode."
    public static let scanningLine = "Looking for recording devices…"
    public static let unavailableValue = "Unavailable"

    /// PRE-CONNECT, THE ONLY FACT IS THE BROADCAST NAME (design §3.1). Said out loud, because
    /// a scan row that shows only a name reads like a shortcoming unless the reason is given.
    public static let broadcastNameNote =
        "These are the names each device broadcasts. FoundryX can't tell what a device is, "
        + "or what it can do, until it connects to it."

    /// Design §3.1, verbatim in substance: an input route is paired by iOS, not here.
    public static let routePairingNote =
        "Headphones and earbuds don't get set up here. Pair them in iPhone Settings and they "
        + "show up in your device list on their own."

    /// The answer for a person whose recorder never appears — which, for a stored-file
    /// recorder, is every person today. It leads to the §3.6 screen ("Setup isn't available
    /// yet"), NOT to a branded setup row pinned above whatever answered the scan: a
    /// discoverable entry point that cannot connect anything is its own kind of trap
    /// (design §7 Q1), and a vendor name above the scan results is "vendors first".
    public static let setupHelpLink = "Why isn't my recorder here?"

    /// What a device that advertises NO name is called in a scan list (design §3.1, T3 req 8).
    ///
    /// It lives here rather than in the view for the same reason every other line above does:
    /// `App/`'s copy is scanned by the voice-notes language guard, which retires the word
    /// "recording" from user-facing app literals — and this surface is the one place the word
    /// is not retired, because a recording DEVICE is what it is. Keeping the string in the kit
    /// keeps the guard meaningful for the rest of `App/` instead of forcing an exception into
    /// it, and keeps this screen's copy in the one place `genericCopy` can assert over.
    public static let unnamedDeviceName = "Unnamed recording device"

    /// What the sheet says about the rows it is FOLDING rather than showing.
    ///
    /// It is a count and not a list, because the whole point is that these rows are
    /// interchangeable to look at: every one of them renders `unnamedDeviceName`.
    public static func unnamedHiddenLine(count: Int) -> String {
        count == 1 ? "1 device with no name is hidden"
                   : "\(count) devices with no name are hidden"
    }

    /// The disclosure. It is the reason the fold is not a deletion.
    public static let showUnnamedAction = "Show"
    /// And back again, so the list a person just uncluttered can be uncluttered again.
    public static let hideUnnamedAction = "Hide"

    /// Every piece of generic copy this surface can render, so "generic device copy names no
    /// vendor" is checked over a POPULATION rather than over whichever strings a test author
    /// happened to remember.
    public static let genericCopy: [String] = [
        affordanceTitle, listTitle, connectSheetTitle, emptyLine, scanningLine, unavailableValue,
        unnamedDeviceName, broadcastNameNote, routePairingNote, setupHelpLink,
        unnamedHiddenLine(count: 1), unnamedHiddenLine(count: 4),
        showUnnamedAction, hideUnnamedAction,
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

    /// The capability lines for a device whose strip is NOT a class fact — only the ones it
    /// actually declared, so a device with nothing to report renders no strip at all.
    ///
    /// WHY THIS EXISTS. `capabilityLines` renders all four keys and says `Unavailable` for the
    /// ones a device never declared. For a record-then-sync recorder that is the point: design
    /// §6a draws exactly that, with a note saying the LINK is why. For a built-in microphone
    /// it is the `N/A · N/A · N/A` strip in a different word — four rows of "Unavailable" for
    /// four things a phone microphone does not have and never will.
    public static func reportedCapabilityLines(
        _ capabilities: RecordingDeviceCapabilities
    ) -> [RecordingDeviceCapabilityLine] {
        capabilityLines(capabilities).filter(\.isAvailable)
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
    /// Non-nil when the name is NOT a device this app can name — something the user can act
    /// on instead of a bare "Unknown device".
    public let diagnostic: String?
    /// True when the two on-disk surfaces disagree about this capture — see
    /// `CaptureAttributionPresentation`'s note on the Record button.
    public let surfacesDisagree: Bool
    /// True when `deviceName` is a complete statement on its own and needs no diagnostic
    /// beside it to be honest — an ERA the classifier ESTABLISHED, not a hedged device name.
    ///
    /// THE WORD "ESTABLISHED" IS THE WHOLE CONTENT OF THIS FLAG. It may be set only where the
    /// classifier proved the era from something durable that travels with the data. Setting
    /// it for `.undatable` — which is the classifier saying in its own words that the era is
    /// NOT knowable — puts an era claim on the one surface that has no room for the hedge
    /// that would qualify it, which is trading a wrong shrug for a wrong claim.
    public let standsAlone: Bool

    /// The app can name the device that made this recording.
    public var isKnown: Bool { diagnostic == nil }

    /// May a cramped surface — the conversation row's meta line — print this name with
    /// nothing beside it?
    public var isRenderableWithoutDiagnostic: Bool { isKnown || standsAlone }

    public init(deviceName: String, diagnostic: String? = nil, surfacesDisagree: Bool = false,
                standsAlone: Bool = false) {
        self.deviceName = deviceName
        self.diagnostic = diagnostic
        self.surfacesDisagree = surfacesDisagree
        self.standsAlone = standsAlone
    }
}

public enum CaptureAttributionPresentation {

    /// Shown when the app genuinely cannot name the recorder — something recorded this and it
    /// cannot say what. Always accompanied by a diagnostic; on its own it is a shrug.
    public static let unknownDeviceName = "Unknown device"

    /// Shown for a recording the classifier PLACED before device records shipped, when
    /// nothing on disk names a source for it either.
    ///
    /// It is not the unknown-device answer and must never be rendered as one: "Unknown
    /// device" means a device made this and we cannot say which, and for these there was no
    /// device identity to keep in the first place. Nothing went missing, which is the
    /// accusation the whole era distinction exists to avoid making — in front of every
    /// conversation an upgrading user already owns.
    public static let preDeviceTrackingName = "Recorded before device tracking"

    /// Why a recording from that era carries no device name. It is not a hedge on the era —
    /// the era is the answer — it is what a reader gets when they ask why nothing more
    /// specific is there.
    public static let preDeviceTrackingDiagnostic =
        "no device identity was kept when this was recorded, so nothing about it is missing"

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

        case .legacyPreMigration:
            // THE LEGACY ARM, RENDERED. A conversation recorded before device records shipped
            // is not missing anything: its `.capture-source` marker is a complete answer for
            // what it is, and it renders through the SAME label function the live surface uses
            // so the archive and the app cannot drift apart. (Round 8, L3: this clause is what
            // "a legacy Omi recording still renders 'Omi'" actually means — the rendered
            // label, not the marker bytes.)
            //
            // WITHOUT A MARKER, THE ERA IS THE ANSWER. Recordings old enough predate the
            // marker too, and those rendered `unknownDeviceName` with no diagnostic at all —
            // the bare shrug this file's own rule forbids, on the row AND in the detail
            // header, in front of a whole archive. The era is a fact the classifier
            // ESTABLISHED here (a durable start before the epoch), it is short enough for the
            // row, and it arrives with the reason there is nothing more precise to say.
            if let named = legacySourceLabel(forMarker: legacySourceMarker) {
                return CaptureAttribution(deviceName: named)
            }
            return CaptureAttribution(deviceName: preDeviceTrackingName,
                                      diagnostic: preDeviceTrackingDiagnostic,
                                      standsAlone: true)

        case .undatable(let diagnostic):
            // THE PAYLOAD THIS ARM USED TO THROW AWAY. `.undatable` was matched together with
            // `.legacyPreMigration` and bound nothing, so the sentence the classifier had
            // already written — why this recording cannot be placed in an era — was built and
            // discarded one call before the only surface that could show it.
            //
            // AND IT IS NOT THE LEGACY ANSWER. Reading an undatable capture as pre-upgrade is
            // the conservative INTERNAL choice: it is why such a capture is never accused of
            // losing a device record it may never have been owed. It is not a licence to tell
            // the reader an era as a fact, and the marker cannot be promoted to an answer
            // either — the marker names the SELECTED source, which equals the recorder only
            // in the era this recording cannot be shown to belong to (see the Record-button
            // note above). So whatever is true is rendered, the classifier's own sentence
            // goes with it, and nothing here stands alone: the conversation row prints
            // nothing rather than a claim it cannot qualify.
            return CaptureAttribution(
                deviceName: legacySourceLabel(forMarker: legacySourceMarker) ?? unknownDeviceName,
                diagnostic: diagnostic,
                standsAlone: false)

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

    /// THE TIMELINE ROW'S QUIET META LINE, with the recorder appended.
    ///
    /// This is the function the App target calls, and it exists so the composition is a tested
    /// value rather than string arithmetic inside a SwiftUI body. Review round 11's H2 was that
    /// nothing in the shipped app ever showed a user which device recorded a conversation —
    /// the bug this whole track exists to fix — while the record claimed the surface was
    /// rendered.
    ///
    /// AN UNKNOWN RECORDER SAYS NOTHING HERE, deliberately. The row has no room to explain
    /// itself, and "Unknown device" without its diagnostic is the shrug this file's own rule
    /// forbids; the detail header carries the hedge and the reason. So the row appends only
    /// when the name it would print is honest ON ITS OWN — a device the app can name, or an
    /// era it established. The second is why this is not simply `isKnown`: a legacy archive
    /// would otherwise say nothing whatever about where any of its recordings came from,
    /// which is the silence the shrug was standing in for.
    public static func metaLine(_ base: String, attribution: CaptureAttribution?) -> String {
        guard let attribution, attribution.isRenderableWithoutDiagnostic,
              !attribution.deviceName.isEmpty else {
            return base
        }
        return base.isEmpty ? attribution.deviceName : "\(base) · \(attribution.deviceName)"
    }

    /// The source label the shipped `.capture-source` marker names, or nil when nothing on
    /// disk names one. Routed through `CaptureLiveStatus.sourceLabel` so the archive says
    /// exactly what the live surface said while it was recording.
    ///
    /// OPTIONAL, BECAUSE ITS TWO CALLERS ANSWER "NOTHING NAMES A SOURCE" DIFFERENTLY: an era
    /// the classifier established says the era, and one it could not says it cannot say.
    /// Folding that decision in here — as the old `legacyDisplayName` did, by returning the
    /// unknown-device name — is what gave both of them the same wrong answer.
    public static func legacySourceLabel(forMarker marker: String?) -> String? {
        guard let marker, let kind = CaptureSourceKind(rawValue: marker) else { return nil }
        return CaptureLiveStatus.sourceLabel(source: kind, isRecordingMic: false)
    }
}

// MARK: - The account's recording history, and what recorded each conversation

/// One row of the rendered history.
public struct RecordingHistoryRow: Equatable, Sendable, Identifiable {
    public var id: String { captureId }
    public let captureId: String
    public let attribution: CaptureAttribution

    public init(captureId: String, attribution: CaptureAttribution) {
        self.captureId = captureId
        self.attribution = attribution
    }
}

public enum RecordingHistory {

    /// Every conversation in this account's capture root, newest first, each with what
    /// recorded it.
    ///
    /// ERA IS NOT A FILTER. A conversation recorded before device records shipped and one
    /// recorded after are both history; the difference shows up only in the attribution
    /// sentence. Filtering by era here is how a legacy-only user's archive would disappear on
    /// upgrade — the exact thing R5 forbids.
    public static func rows(baseDir: URL) -> [RecordingHistoryRow] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: baseDir.path)) ?? [])
            // ONE rule for what a conversation directory is, and it is `CaptureLibrary`'s —
            // the same predicate `isEmpty` uses. Two scans with two rules is how "you have no
            // recordings" and "here are your recordings" come to disagree, and this file
            // would be the second one.
            .filter(CaptureLibrary.isNoteDirectory)
            .filter { name in
                var isDir: ObjCBool = false
                let path = baseDir.appendingPathComponent(name, isDirectory: true).path
                return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
            // Newest first, by the id's own embedded start time — the same ordering rule the
            // resume scan uses, so history and resume cannot disagree about which is newest.
            .sorted { a, b in
                let ta = CaptureIdTime.startedAt(fromCaptureId: a) ?? 0
                let tb = CaptureIdTime.startedAt(fromCaptureId: b) ?? 0
                return ta != tb ? ta > tb : a > b
            }
        return names.map {
            RecordingHistoryRow(
                captureId: $0,
                attribution: CaptureAttributionPresentation.attribution(captureId: $0,
                                                                        baseDir: baseDir))
        }
    }

    /// Does this account have any recording history at all? The durable evidence that its
    /// owner has already connected something and used it — see `OnboardingGate`. Delegates
    /// to `CaptureLibrary` rather than counting `rows`, so the two answers are the same
    /// answer by construction and not by agreement.
    public static func hasAny(baseDir: URL) -> Bool {
        !CaptureLibrary.isEmpty(baseDir: baseDir)
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
