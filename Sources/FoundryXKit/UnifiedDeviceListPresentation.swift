// UnifiedDeviceListPresentation — the ONE device list the Devices screen draws, and the
// honest substitutes a record-then-sync device gets where a live device shows recording
// state (track 20260810T2158_unified_recording_device_list_wires_pocket_and_omi, from
// DESIGN-pocket-connect.md §2).
//
// THE ONE RULE THIS FILE EXISTS TO ENFORCE, in the design's own words:
//
//   "One list. Four shapes. Same row grammar for all of them: name, chevron, then one line
//    reading <class> · <state>. Sort is the shipped merge() order — displayName.lowercased()
//    then storageKey, with shape DELIBERATELY ABSENT from the comparison. … Class is a
//    caption you read, never a section you get sorted into. Grouping by class would quietly
//    turn 'one list' into 'one list, vendors first.'"
//
// The shipped screen contradicted that with an Omi HERO BLOCK above a CAPTURE SOURCES
// section — vendors first, with a Battery / Signal / Firmware strip reading `N/A · N/A ·
// N/A` for a device that had never reported anything. Both are gone. What replaces them:
//
//   1. ORDER COMES FROM `RecordingSourceCatalog.merge` AND NOWHERE ELSE. `rows(_:)` does not
//      sort; it merges, and merge cannot see the shape. A shape-first ordering introduced
//      anywhere reds `unified-recording-device-list.feature`'s first scenario.
//   2. CLASS IS DERIVED FROM SHAPE, ONCE. `deviceClass(for:)` mirrors `adapter(for:)`; no
//      surface switches on shape, on vendor, or on reported name.
//   3. A RECORD-THEN-SYNC DEVICE NEVER MAKES A CLAIM ABOUT RECORDING. Hand one a
//      `.recording(elapsed:)` and it renders its LINK reachability instead — the phone is
//      not in the loop, so "recording now" is not a fact it has. That is a property of this
//      builder, not a discipline asked of its callers.
//   4. BATTERY APPEARS IN A ROW ONLY WHEN THE CAPABILITY IS `.reported`. Absent otherwise —
//      not "N/A", not "0%". The device PAGE renders the four shipped capability lines with
//      the shipped word "Unavailable", which is a statement, not a value.
//   5. "IN RANGE" IS NOT A WORD ANY SURFACE HERE CAN SAY. The phone cannot distinguish
//      out-of-range from powered-off from connected-to-another-app, and a BLE peripheral
//      typically stops advertising while another app holds it — so a Pocket sitting on the
//      table in the vendor app's hands would read "not in range". Link reachability only.

import Foundation

// MARK: - The one distinction a user ever sees

/// Some recording devices hear what you hear THROUGH your phone; others record entirely by
/// themselves and hand the audio over later. That single split is the only device
/// distinction any FoundryX screen shows, and every screen derives from it rather than from
/// a brand name.
public enum RecordingDeviceClass: String, Sendable, Equatable, CaseIterable, Codable {
    case live
    case recordThenSync

    /// The caption in a row's second line. A caption you READ — never a section you get
    /// sorted into.
    public var caption: String {
        switch self {
        case .live:           return "Live"
        case .recordThenSync: return "Records on its own"
        }
    }

    /// May a device of this class contribute a Live Activity, a Dynamic Island presence, a
    /// recording pill or a lock-screen control?
    ///
    /// NO, FOR RECORD-THEN-SYNC, IN ANY STATE — including mid-sync. A file transfer is not a
    /// recording and must never be dressed as one.
    public var mayContributeLiveSurface: Bool { self == .live }

    /// May a device page of this class carry a record / pause / stop control? Only if the
    /// phone is in the loop while the audio is being made.
    public var carriesRecordControl: Bool { self == .live }
}

public extension RecordingSourceCatalog {
    /// THE ONE DERIVED FUNCTION. It mirrors `adapter(for:)` exactly — a transport fact in,
    /// the only user-visible distinction out. Nothing else in the app may switch on shape.
    static func deviceClass(for shape: RecordingDeviceShape) -> RecordingDeviceClass {
        switch shape {
        case .bleStream, .audioRoute, .builtInMic: return .live
        case .filePull:                            return .recordThenSync
        }
    }
}

public extension RecordingDeviceLinkState {
    /// LINK REACHABILITY, AND NOTHING ELSE. Never "In range": see rule 5 in the file header.
    var label: String {
        switch self {
        case .connected:    return "Connected"
        case .reconnecting: return "Connecting"
        case .disconnected: return "Not connected"
        }
    }
}

/// What a LIVE device is doing right now. A record-then-sync device is handed this too — and
/// the builder discards it, because the phone has no way to know.
public enum RecordingDeviceLiveActivity: Equatable, Sendable {
    /// Nothing beyond the link fact.
    case none
    /// An input route the handset could record from, but is not recording from now.
    case availableAsInput
    /// This device is making audio right now, and has been for `elapsed`.
    ///
    /// `elapsed` IS OPTIONAL, AND THAT IS NOT A CONVENIENCE. A list that refreshes on state
    /// change rather than on a one-second tick has no live clock to print, and a frozen
    /// "12:04" is a worse answer than no clock at all. So the fact ("recording now") and the
    /// duration are separable, and only a surface that actually ticks supplies the second.
    case recording(elapsed: String?)
}

// MARK: - One device, as the screen knows it right now

/// Everything the app knows about ONE device at the moment the list is drawn. Deliberately
/// a value: the composition that builds these is testable, and the SwiftUI body renders
/// them 1:1 rather than re-deriving any of it.
public struct RecordingDeviceListInput: Equatable, Sendable, Identifiable {
    public var id: RecordingDeviceIdentity { identity }
    public let identity: RecordingDeviceIdentity
    public let displayName: String
    /// EXACTLY what the device declared. An absent key is absent, never a plausible default.
    public let declaredCapabilities: [String: String?]
    public let audioProfile: RecordingDeviceAudioProfile?
    public let link: RecordingDeviceLinkState
    public let liveActivity: RecordingDeviceLiveActivity
    public let lastConnected: Date?
    /// Does the ACCOUNT'S STORE hold a record for this device? Only then is there anything to
    /// forget. A route the handset merely offers is not something FoundryX remembers, holds a
    /// key for, or can un-remember — offering "Forget" for one is a destructive-sounding
    /// warning attached to a no-op.
    public let isRemembered: Bool
    /// The protocol the transport client NEGOTIATED with this device, if it ever connected to
    /// it. Education attaches to this and to nothing else (design §5): not to the shape, and
    /// never to the reported name. `nil` means no connection has established what this device
    /// speaks, so no device-education bundle can honestly be offered for it.
    public let negotiatedProtocol: String?

    public init(identity: RecordingDeviceIdentity,
                displayName: String,
                declaredCapabilities: [String: String?] = [:],
                audioProfile: RecordingDeviceAudioProfile? = nil,
                link: RecordingDeviceLinkState = .disconnected,
                liveActivity: RecordingDeviceLiveActivity = .none,
                lastConnected: Date? = nil,
                isRemembered: Bool = false,
                negotiatedProtocol: String? = nil) {
        self.identity = identity
        self.displayName = displayName
        self.declaredCapabilities = declaredCapabilities
        self.audioProfile = audioProfile
        self.link = link
        self.liveActivity = liveActivity
        self.lastConnected = lastConnected
        self.isRemembered = isRemembered
        self.negotiatedProtocol = negotiatedProtocol
    }

    public var deviceClass: RecordingDeviceClass {
        RecordingSourceCatalog.deviceClass(for: identity.shape)
    }
}

/// ONE row of the ONE list. Same grammar for every shape: a name, and one line reading
/// `<class> · <state>`.
public struct UnifiedDeviceRow: Equatable, Sendable, Identifiable {
    public var id: RecordingDeviceIdentity { identity }
    public let identity: RecordingDeviceIdentity
    public let displayName: String
    public let deviceClass: RecordingDeviceClass
    /// The state half of line 2. For a record-then-sync device this is a fact about the
    /// LINK, never about recording.
    public let state: String
    /// The battery value the device REPORTED, or nil. Never "N/A", never "0%".
    public let battery: String?

    public init(identity: RecordingDeviceIdentity,
                displayName: String,
                deviceClass: RecordingDeviceClass,
                state: String,
                battery: String?) {
        self.identity = identity
        self.displayName = displayName
        self.deviceClass = deviceClass
        self.state = state
        self.battery = battery
    }

    public var classCaption: String { deviceClass.caption }

    /// Line 2, whole. `Live · Connected · Battery 84%` / `Records on its own · Not connected`.
    public var detailLine: String {
        var parts = [classCaption, state]
        if let battery { parts.append("Battery \(battery)") }
        return parts.joined(separator: UnifiedDeviceListPresentation.separator)
    }

    /// Does this row contribute anything to a Live Activity / Dynamic Island / pill /
    /// lock-screen surface? A record-then-sync device: never, in any state.
    public var contributesLiveSurface: Bool { deviceClass.mayContributeLiveSurface }
}

// MARK: - The list

public enum UnifiedDeviceListPresentation {

    /// The separator between the parts of line 2 — the same one the timeline's meta line uses.
    public static let separator = " · "

    /// The education line above the list, and the link that opens it. The whole list is
    /// organised around this one sentence, so it is said before the rows rather than left
    /// for the user to infer from captions.
    public static let educationLead =
        "Some devices record with your phone. Some record on their own."
    public static let educationLink = "What's the difference?"

    /// A live device that is an input route the handset could record from.
    public static let availableAsInputState = "Available as an input"
    /// A live device that is making audio right now.
    public static let recordingNowState = "Recording now"

    /// THE ORDER, AND WHERE IT COMES FROM. This function does not sort. It builds
    /// observations and hands them to `RecordingSourceCatalog.merge`, whose comparison is
    /// `displayName.lowercased()` then `storageKey` and which CANNOT SEE THE SHAPE. Sorting
    /// or grouping by class here is exactly how "one list" becomes "one list, vendors first".
    public static func rows(_ inputs: [RecordingDeviceListInput]) -> [UnifiedDeviceRow] {
        var byIdentity: [RecordingDeviceIdentity: RecordingDeviceListInput] = [:]
        for input in inputs { byIdentity[input.identity] = input }
        let observations = inputs.map {
            RecordingDeviceObservation(identity: $0.identity,
                                       reportedName: $0.displayName,
                                       audioProfile: $0.audioProfile,
                                       declaredCapabilities: $0.declaredCapabilities)
        }
        return RecordingSourceCatalog.merge(observations).compactMap { entry in
            byIdentity[entry.identity].map { row(entry: entry, input: $0) }
        }
    }

    public static func row(entry: RecordingDeviceEntry,
                           input: RecordingDeviceListInput) -> UnifiedDeviceRow {
        let deviceClass = RecordingSourceCatalog.deviceClass(for: entry.shape)
        return UnifiedDeviceRow(
            identity: entry.identity,
            displayName: entry.displayName,
            deviceClass: deviceClass,
            state: state(deviceClass: deviceClass, link: input.link, activity: input.liveActivity),
            battery: reportedBattery(entry.capabilities))
    }

    /// THE HONEST SUBSTITUTE, AS A FUNCTION RATHER THAN A DISCIPLINE.
    ///
    /// A record-then-sync device gets its LINK reachability whatever activity it is handed.
    /// The caller cannot make it claim to be recording, because the phone genuinely does not
    /// know: the recorder does not say, and this iPhone never hears it live.
    public static func state(deviceClass: RecordingDeviceClass,
                             link: RecordingDeviceLinkState,
                             activity: RecordingDeviceLiveActivity) -> String {
        guard deviceClass == .live else { return link.label }
        switch activity {
        case .recording(let elapsed):
            guard let elapsed, !elapsed.isEmpty else { return recordingNowState }
            return recordingNowState + separator + elapsed
        case .availableAsInput:
            return availableAsInputState
        case .none:
            return link.label
        }
    }

    /// Battery for a ROW: only what the device actually reported.
    ///
    /// `.present` (declared, no value) yields nothing here — "the device has a battery" is
    /// not a percentage, and the strip that printed `N/A` for one is what this replaces.
    public static func reportedBattery(_ capabilities: RecordingDeviceCapabilities) -> String? {
        capabilities.state(of: .batteryLevel).reportedValue
    }

    // MARK: The Settings entry subtitle

    /// CLASS COUNTS, NO VENDOR WORD. The shipped subtitle was `"Omi connected"` — a vendor
    /// name hardcoded into the one line a user reads before deciding whether to open the
    /// page at all. This says what is there in the terms the whole screen is organised
    /// around, and it is brand-free by construction: nothing but the counts reaches it.
    public static func settingsSubtitle(_ rows: [UnifiedDeviceRow]) -> String {
        let live = rows.filter { $0.deviceClass == .live }.count
        let recordThenSync = rows.count - live
        var parts: [String] = []
        if live > 0 { parts.append("\(live) live") }
        if recordThenSync > 0 { parts.append("\(recordThenSync) records on its own") }
        guard !parts.isEmpty else { return RecordingDeviceConnectPresentation.emptyLine }
        return parts.joined(separator: ", ")
    }

    /// The words a scan-list or a device page may NOT use about a link this phone cannot
    /// observe. Held over the population rather than over whichever string a test author
    /// happened to remember.
    public static let bannedProximityWords = ["In range", "in range", "Out of range"]
}

// MARK: - "What's the difference?"

public struct RecordingDeviceClassSection: Equatable, Sendable {
    public let title: String
    public let body: String
    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// WHAT THE HEADER LINK OPENS, AND WHY IT IS NOT A VENDOR'S LED LEGEND.
///
/// The list's one organising sentence is "Some devices record with your phone. Some record on
/// their own." — and its link used to open Pocket's hardware education: "Solid amber —
/// Recording, Blue — Connected, Red — Charging". That answers a question about DEVICE CLASSES
/// with one vendor's light, on a screen whose whole premise is that no screen switches on
/// vendor. This is the class answer, in the design's own words, and it names no brand.
public enum RecordingDeviceClassExplanation {
    public static let title = "Two kinds of recording device"

    public static let sections: [RecordingDeviceClassSection] = [
        RecordingDeviceClassSection(
            title: RecordingDeviceClass.live.caption,
            body: "These hear what you hear through your phone. The phone is in the loop the "
                + "whole time, so it knows when a recording is running, it can start and stop "
                + "it, and it can show you a timer."),
        RecordingDeviceClassSection(
            title: RecordingDeviceClass.recordThenSync.caption,
            body: "These record entirely by themselves, with no phone involved and often no "
                + "phone nearby, and hand the finished audio over later when you ask for it. "
                + "Your phone can't tell you whether one is recording right now — the light "
                + "on the device is the only recording indicator there is."),
    ]

    /// Every line this screen can render, so "it names no vendor" is held over the population.
    public static var everyLine: [String] {
        [title] + sections.flatMap { [$0.title, $0.body] }
    }
}

// MARK: - Device education, attached to the PROTOCOL

/// One device-education bundle, and the protocol it is true of.
public struct RecordingDeviceEducationBundle: Equatable, Sendable {
    /// The protocol the transport client negotiated. NOT a shape and NOT a reported name.
    public let protocolIdentifier: String
    public let title: String
    public let sections: [PocketEducationSection]

    public init(protocolIdentifier: String, title: String, sections: [PocketEducationSection]) {
        self.protocolIdentifier = protocolIdentifier
        self.title = title
        self.sections = sections
    }
}

/// EDUCATION ATTACHES TO THE PROTOCOL, NEVER TO THE SHAPE (design §5).
///
/// The device page used to offer "How this recorder works" for every `.filePull` device and
/// then render one vendor's button timings and LED legend. Pair any second stored-file
/// recorder — whose light means something else, or which has no light — and its page taught
/// that vendor's hardware. That is a lie, and it is the exact failure §5 exists to prevent:
/// *"A second record-then-sync device does not inherit Pocket's LED legend — that would be a
/// lie — and does not get an empty page either."*
///
/// So this is a LOOKUP, keyed by the protocol a transport client actually negotiated. A
/// device whose protocol has no bundle renders no education row at all — which is also what
/// makes the substitution test in §1 meaningful rather than accidentally satisfied.
public enum RecordingDeviceEducationCatalog {

    public static let bundles: [RecordingDeviceEducationBundle] = [
        RecordingDeviceEducationBundle(
            protocolIdentifier: PocketRecordingDeviceBridge.protocolIdentifier,
            title: "How your recorder works",
            sections: PocketDeviceEducation.presentation.sections),
    ]

    /// The bundle for a negotiated protocol, or nil. `nil` in, `nil` out — a device nothing
    /// has connected to has established no protocol, so there is nothing true to teach.
    public static func bundle(for protocolIdentifier: String?) -> RecordingDeviceEducationBundle? {
        guard let protocolIdentifier else { return nil }
        return bundles.first { $0.protocolIdentifier == protocolIdentifier }
    }
}

// MARK: - The device page

/// One device's own page. The slots a live device fills with recording state are filled here
/// with what is true instead — see DESIGN-pocket-connect.md §2's honest-substitute table.
public struct RecordingDevicePagePresentation: Equatable, Sendable {
    public let displayName: String
    /// `Live` / `Records on its own` — the eyebrow above the status.
    public let classCaption: String
    /// LINK REACHABILITY ONLY: `Connected` / `Connecting` / `Not connected`.
    public let status: String
    /// The band where a live device carries record / pause / stop. Non-nil for a
    /// record-then-sync device, and it is the design's single most important sentence.
    public let recordingIndicatorSentence: String?
    /// The capability strip, selected BY CLASS (design §2's table).
    ///
    /// A record-then-sync device gets all four shipped `capabilityOrder` lines, `Unavailable`
    /// included, because §6a's resting state is exactly that plus the note saying the link is
    /// why. A live device gets only what it actually declared — an iPhone microphone has no
    /// battery, no firmware, no gap recovery and no offline storage, and printing four
    /// permanently-`Unavailable` rows for it is `N/A · N/A · N/A` respelled.
    ///
    /// `Signal` appears in no strip: RSSI is meaningful only while streaming.
    public let capabilities: [RecordingDeviceCapabilityLine]
    /// Why the capabilities read Unavailable, when the reason is the link rather than the
    /// device. Absent while connected, and absent for a class whose strip carries no
    /// `Unavailable` line to explain.
    public let capabilityNote: String?
    public let showsRecordControl: Bool
    public let showsLiveActivity: Bool
    /// The actions offered, in order.
    public let actions: [String]
    /// The warning the forget action confirms against, in the terms of THIS device's class.
    /// nil when nothing is offered to forget.
    public let forgetWarning: String?

    public init(displayName: String,
                classCaption: String,
                status: String,
                recordingIndicatorSentence: String?,
                capabilities: [RecordingDeviceCapabilityLine],
                capabilityNote: String?,
                showsRecordControl: Bool,
                showsLiveActivity: Bool,
                actions: [String],
                forgetWarning: String? = nil) {
        self.displayName = displayName
        self.classCaption = classCaption
        self.status = status
        self.recordingIndicatorSentence = recordingIndicatorSentence
        self.capabilities = capabilities
        self.capabilityNote = capabilityNote
        self.showsRecordControl = showsRecordControl
        self.showsLiveActivity = showsLiveActivity
        self.actions = actions
        self.forgetWarning = forgetWarning
    }
}

public enum RecordingDevicePage {

    /// THE SINGLE MOST IMPORTANT SENTENCE IN THE DESIGN, verbatim. It occupies the band
    /// where a live device carries record / pause / stop. The empty space is not blanked; it
    /// is occupied by the true fact.
    public static let recorderIndicatorSentence =
        "FoundryX can't tell whether this recorder is recording right now. It doesn't say, "
        + "and this iPhone never hears it live. The light on the device is the only recording "
        + "indicator there is: solid amber means recording."

    /// Why the strip reads Unavailable while the link is down — a fact about FoundryX, not
    /// an accusation about the recorder.
    public static let disconnectedCapabilityNote =
        "Battery and firmware read Unavailable because FoundryX isn't connected to this "
        + "recorder right now — not because the recorder is off."

    public static let connectAndCheckAction = "Connect and check now"
    public static let educationAction = "How this recorder works"
    public static let forgetAction = "Forget this recorder"
    public static let disconnectAction = "Disconnect"
    public static let connectAction = "Connect"

    /// THE PER-DEVICE AVAILABILITY TOGGLE, AND THE WAY OUT OF A DESTRUCTIVE ALERT.
    ///
    /// Both were typed straight into `RecordingDevicePageView`'s body —
    /// `Text("Use this device for capture")` and `Button("Cancel", role: .cancel)` — on a
    /// screen whose stated rule is that every sentence comes from here. `swift test` cannot
    /// compile `App/`, so no test in this repository could see either one, and the file's own
    /// header says "THIS VIEW DERIVES NOTHING" three hundred lines above the first of them.
    /// They are here now, and `the-recorder-page-is-rendered-and-held-to-its-words.feature`
    /// is what stops the next one.
    public static let captureToggleTitle = "Use this device for capture"

    /// The word on the button that does nothing. It is still a word a person reads, and a
    /// prohibition with an exception for short strings is not a prohibition.
    public static let cancelAction = "Cancel"

    /// Forgetting a record-then-sync recorder is a real lockout, so it says so (design §6a).
    ///
    /// IT IS A CLAIM ABOUT A KEY, so it may only be shown for a device FoundryX actually
    /// provisioned. It was being shown for a Bluetooth audio route, where FoundryX holds no
    /// key at all — a destructive-sounding warning about custody it does not have.
    public static let forgetWarning =
        "Forgetting this recorder deletes FoundryX's key for it. It doesn't reset the "
        + "recorder, and the key can't be put back. FoundryX would no longer be able to "
        + "connect to it."

    /// The same gesture for a LIVE device, worded from what is true of one: FoundryX holds no
    /// key for a device the phone streams from or records through, so forgetting it is
    /// FoundryX un-remembering it and nothing more.
    public static let liveForgetWarning =
        "FoundryX will forget this device. Nothing changes on the device itself, and nothing "
        + "already saved is deleted. You can add it again from \""
        + RecordingDeviceConnectPresentation.affordanceTitle + "\"."

    /// The warning THIS device's class earns. Never the key sentence for a device whose key
    /// FoundryX never had.
    public static func forgetWarning(for deviceClass: RecordingDeviceClass) -> String {
        deviceClass == .recordThenSync ? forgetWarning : liveForgetWarning
    }

    /// A BRING-OVER IS OFFERED NOW, AND NOT ON THIS PAGE.
    ///
    /// This constant used to read `bringOverIsNotOfferedYet = false` and carried design §6c's
    /// reason: the download path had never run end to end, and "a button that always fails is
    /// worse than an honest absence". `PocketBringOver` is that path with a caller, so the
    /// decision is reversed here deliberately rather than left to rot beside a shipped button.
    ///
    /// WHERE IT LIVES IS THE OTHER HALF. The action belongs to a RECORDER'S SHELF — it needs a
    /// file to ask for, which only a check that opened a session has — so it is rendered from
    /// `PocketBringOverPresentation` on the shelf panel, and `resolve` still offers no such
    /// action. The page's action list is pinned by its own gate for exactly that reason.
    public static let bringOverIsOffered = true

    /// - Parameters:
    ///   - canConnect: whether this build has a transport that can actually attach this
    ///     device. FALSE IS NOT A DEGRADED STATE, it is the honest one: an action that cannot
    ///     complete is worse than its absence (design §6c), and today only a remembered
    ///     BLE-stream device has a transport wired into the app.
    ///
    /// TWO THINGS THIS FUNCTION DECIDES THAT ITS CALLER USED TO, WRONGLY:
    ///
    ///   * EDUCATION, from `input.negotiatedProtocol` and nothing else. The caller passed
    ///     `shape == .filePull` while the comment above the line said education attaches to
    ///     the protocol — so any second stored-file recorder inherited one vendor's LED
    ///     legend. A device whose protocol has no bundle gets no row.
    ///   * FORGET, from `input.isRemembered`. The caller passed `shape != .builtInMic`, so a
    ///     Bluetooth route was offered a "deletes FoundryX's key" warning for a key that does
    ///     not exist, over a store record that does not exist, and the row came straight back.
    public static func resolve(_ input: RecordingDeviceListInput,
                               canConnect: Bool = true) -> RecordingDevicePagePresentation {
        let deviceClass = input.deviceClass
        let declared = RecordingDeviceCapabilities(declared: input.declaredCapabilities)
        let connected = input.link == .connected
        // THE STRIP IS A CLASS FACT (design §2's table). Only a record-then-sync device's
        // strip states `Unavailable` for something it could report when connected; a live
        // device shows what it declared, and an iPhone microphone therefore shows no strip
        // rather than four rows of "Unavailable" for things it does not have.
        let capabilities = deviceClass == .recordThenSync
            ? RecordingDeviceConnectPresentation.capabilityLines(declared)
            : RecordingDeviceConnectPresentation.reportedCapabilityLines(declared)

        var actions: [String] = []
        if canConnect {
            if connected {
                actions.append(disconnectAction)
            } else {
                actions.append(deviceClass == .recordThenSync ? connectAndCheckAction
                                                              : connectAction)
            }
        }
        let education = RecordingDeviceEducationCatalog.bundle(for: input.negotiatedProtocol)
        if education != nil { actions.append(educationAction) }
        // §10 CUSTODY, WHERE THE OWNER CAN ACTUALLY FIND IT.
        //
        // A minted key that is lost is dead hardware: this firmware's decoded command surface
        // has no reset, no unpair and no key-read opcode, so nothing — not this app, not the
        // maker's — can talk to the recorder again. The mitigation named in proposal §10 was a
        // recoverable, owner-visible key, and it had zero callers, which is to say it did not
        // exist. It exists here, on the page for the recorder it belongs to.
        //
        // GATED ON BOTH FACTS THE ACTION CLAIMS. Only a record-then-sync recorder has a
        // session key at all, and only a REMEMBERED one has custody that could hold it — the
        // same pair `forgetWarning` is gated on, for the same reason: an action that talks
        // about "this recorder's key" must not appear for a device whose key was never minted.
        if deviceClass == .recordThenSync && input.isRemembered {
            actions.append(PocketKeyCustodyPresentation.entryAction)
        }
        if input.isRemembered { actions.append(forgetAction) }

        return RecordingDevicePagePresentation(
            displayName: input.displayName,
            classCaption: deviceClass.caption,
            status: input.link.label,
            recordingIndicatorSentence: deviceClass.carriesRecordControl
                ? nil
                : recorderIndicatorSentence,
            capabilities: capabilities,
            // The note explains an `Unavailable` the LINK is responsible for. Only the
            // record-then-sync strip has one, and only while the link is down.
            capabilityNote: deviceClass == .recordThenSync && !connected
                ? disconnectedCapabilityNote
                : nil,
            showsRecordControl: deviceClass.carriesRecordControl,
            showsLiveActivity: deviceClass.mayContributeLiveSurface,
            actions: actions,
            forgetWarning: input.isRemembered ? forgetWarning(for: deviceClass) : nil)
    }
}

// MARK: - Composing the list out of what this handset and this account actually have

public enum UnifiedDeviceListComposition {

    /// The handset's own microphone, as an identity. The same token
    /// `OmiRestorationComposition` attributes handset recordings to, so the device the list
    /// shows and the device the archive names are the same device.
    public static let handsetToken = "handset"

    /// Everything this account remembers plus everything this handset can record through,
    /// as ONE set of inputs. Order is not decided here — `rows(_:)` merges.
    ///
    /// - Parameters:
    ///   - remembered: the account-scoped store's records (an Omi, a Pocket, anything else
    ///     the user paired). Vendor never enters; shape is carried only so class can be
    ///     derived from it.
    ///   - captureSources: the handset's own registry. Its `.omi` rows are DELIBERATELY
    ///     skipped: an Omi is a remembered device, and listing it twice — once as a device
    ///     and once as a "capture source" — is the split this track removes.
    public static func inputs(
        remembered: [RecordingDeviceRecord],
        captureSources: [CaptureSourceDescriptor],
        link: [RecordingDeviceIdentity: RecordingDeviceLinkState] = [:],
        batteryPercent: [RecordingDeviceIdentity: Int] = [:],
        firmware: [RecordingDeviceIdentity: String] = [:],
        negotiatedProtocol: [RecordingDeviceIdentity: String] = [:],
        recording: RecordingDeviceIdentity? = nil,
        elapsed: String? = nil
    ) -> [RecordingDeviceListInput] {
        var inputs: [RecordingDeviceListInput] = []
        var seen: Set<RecordingDeviceIdentity> = []

        for record in remembered {
            let identity = record.identity
            guard seen.insert(identity).inserted else { continue }
            var declared: [String: String?] = [:]
            if let percent = batteryPercent[identity] {
                declared[RecordingDeviceCapabilityKey.batteryLevel.rawValue] = "\(percent)%"
            }
            if let version = firmware[identity] {
                declared[RecordingDeviceCapabilityKey.firmwareVersion.rawValue] = version
            }
            // A record-then-sync device has storage of its own — that is what makes it one.
            // It is a CLASS fact, not a live reading, so it survives the link being down;
            // and "Available" is not a measure of free space, which the education says.
            if identity.shape == .filePull {
                declared[RecordingDeviceCapabilityKey.offlineStorage.rawValue] = .some(nil)
            }
            inputs.append(RecordingDeviceListInput(
                identity: identity,
                displayName: record.displayName,
                declaredCapabilities: declared,
                link: link[identity] ?? .disconnected,
                liveActivity: activity(for: identity, recording: recording, elapsed: elapsed,
                                       ready: link[identity] == .connected),
                lastConnected: record.lastConnected,
                // IT CAME OUT OF THE STORE, so there is genuinely something to un-remember.
                isRemembered: true,
                negotiatedProtocol: negotiatedProtocol[identity]))
        }

        for source in captureSources {
            guard let identity = identity(for: source), seen.insert(identity).inserted else {
                continue
            }
            inputs.append(RecordingDeviceListInput(
                identity: identity,
                displayName: source.displayName,
                link: source.connection.isReady ? .connected : .disconnected,
                liveActivity: activity(for: identity, recording: recording, elapsed: elapsed,
                                       ready: source.connection.isReady),
                // A ROUTE THE HANDSET OFFERS IS NOT A DEVICE THE ACCOUNT REMEMBERS. There is
                // no store record behind it, so there is nothing to forget: `remove` would
                // match nothing and the row would be back on the next refresh.
                isRemembered: false,
                negotiatedProtocol: negotiatedProtocol[identity]))
        }
        return inputs
    }

    /// A capture-source row's device identity, or nil when it is not a device this list can
    /// speak for.
    ///
    /// `.omi` is nil because an Omi is a REMEMBERED device and arrives through the store —
    /// giving it a second identity here is how it would appear twice. `.appleWatch` is nil
    /// because it is a scaffold with no capture path: listing it as `Live · Not connected`
    /// would claim a link that has never existed.
    public static func identity(for source: CaptureSourceDescriptor) -> RecordingDeviceIdentity? {
        switch source.category {
        case .phoneMic:
            return RecordingDeviceIdentity(shape: .builtInMic, hardwareToken: handsetToken)
        case .bluetoothMic:
            return RecordingDeviceIdentity(shape: .audioRoute,
                                           hardwareToken: source.routeUID ?? source.id)
        case .omi, .appleWatch:
            return nil
        }
    }

    private static func activity(for identity: RecordingDeviceIdentity,
                                 recording: RecordingDeviceIdentity?,
                                 elapsed: String?,
                                 ready: Bool) -> RecordingDeviceLiveActivity {
        if identity == recording { return .recording(elapsed: elapsed) }
        // An input ROUTE that is ready but idle is available as an input; a streaming device
        // that is merely connected says so through its link instead.
        if ready, identity.shape == .builtInMic || identity.shape == .audioRoute {
            return .availableAsInput
        }
        return .none
    }

    /// The account's remembered devices, with the legacy device-global Omi pairing adopted
    /// on the way past — idempotently, and without ever deleting the legacy keys.
    ///
    /// WITHOUT THE ADOPTION an upgrading user who paired an Omi before the account-scoped
    /// store existed would open Devices and not see the device they are holding, because
    /// their account store is empty until something else migrates it.
    ///
    /// DISK I/O. Call it off the main actor.
    public static func rememberedForCurrentAccount(
        defaults: UserDefaults = .standard
    ) -> [RecordingDeviceRecord] {
        guard let store = RecordingDeviceStore.current() else { return [] }
        _ = try? RecordingDeviceMigration.adoptLegacyPairing(defaults: defaults, into: store)
        return (try? store.records()) ?? []
    }
}
