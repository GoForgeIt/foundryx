import SwiftUI
import Grain

// THE RECORDER PAGE, MOUNTED SO A BUILD CAN PHOTOGRAPH IT.
//
// WHY THIS FILE EXISTS
// --------------------
// `RecordingDevicePageView` is the page a person opens to look at what their recorder is
// holding. Nothing in any build had ever rendered it. Reaching it in life needs a remembered
// record-then-sync recorder in the account's store, a Bluetooth radio, and the recorder itself
// on the desk — so `phase_uiproof` photographed the recording surface, the actions list, the
// deletion choice, the vault funnel and the device LIST, and never this. "Never ship UI without
// simulator proof" was, on this one screen, a habit somebody had to remember.
//
// WHAT IS REAL HERE, AND WHAT IS SCRIPTED
// ---------------------------------------
// The view is the shipped one — this file constructs `RecordingDevicePageView`, not a copy of
// it, so a line or a colour that changes on the page changes in the picture. Every sentence in
// the picture is resolved by `RecordingDevicePage` / `PocketRecorderCheckPresentation` /
// `PocketBringOverPresentation` / `StoredFileDevicePresentation` from FoundryXKit, and every
// shelf row is built by `PocketInventoryReader.manifest` and `StoredFileDevicePresentation
// .detail` — the same two calls the live check makes.
//
// Scripted: the CAUSE. A simulator has no radio, so the published state of
// `PocketRecorderCheckModel` is set directly rather than reached by opening a session. No
// behaviour is replaced: `run` and `bringOver` are untouched, and a tap gets the real path.
//
// THE FIXTURE IS THE MEASURED DEVICE. `PKT01_BLUE_26079bc5`, firmware 1.6, the unit these
// frames were read off on 2026-08-16 — including the two timestamp formats that coexist on it
// (bare `20260807142852` and prefixed `PH260811175026`), which nothing in the design had
// accounted for and which a picture is a cheap way to keep honest.
//
// COMPILED OUT OF A SHIPPING BUILD. Same class as `-MainPreview`, `-WelcomePreview` and the
// other `-Screen` mounts: a launch argument that renders a surface over seeded data has no
// business in a shipping binary.
#if DEBUG || PERF_HARNESS

/// The states the recorder page can be in, and the population every gate over this page is
/// held to.
///
/// ADDING A CASE IS THE WHOLE EDIT. `RecorderPageRenderedFeatureTests` derives the states from
/// this enum rather than listing them, so a state added here is a state the UI proof must
/// visit and the mount must handle before the suite is green again.
///
/// WHAT IS NOT HERE, STATED RATHER THAN IMPLIED AWAY. The delivery plan's third named state is
/// "stale shelf with a gated reset". The gated reset is Step 5's work (`PocketPresence`, and a
/// reset that disables itself when the shelf is stale); it is not on `main`, so this file does
/// not invent it. `shelfAnswered` is the state `main` can actually be in, and when Step 5
/// lands, its state is one case added here.
enum RecorderPageProofState: String, CaseIterable {
    /// The owner has not asked. The page carries its header, its capability strip and its
    /// actions, and no shelf at all — a panel that appeared on its own would be this screen
    /// opening a Bluetooth session every time somebody looked at it.
    case neverAsked
    /// The errand is running: the radio is busy and the page says which errand it is.
    case errandRunning
    /// The recorder answered. The shelf carries what it is holding, one row already in
    /// Solleva and the rest only on the recorder, with the bring-over offer and the custody
    /// promise beneath it.
    case shelfAnswered

    /// The state a launch argument named, or `nil`.
    ///
    /// NEVER A FALLBACK. A misspelled state that quietly rendered the resting page would make
    /// the proof photograph the wrong screen and pass, which is the failure mode this whole
    /// step exists to remove.
    static func named(_ raw: String?) -> RecorderPageProofState? {
        guard let raw else { return nil }
        return RecorderPageProofState(rawValue: raw)
    }
}

/// The data the picture is taken over. DATA, NOT COPY — every one of these is a value the
/// recorder itself reports (a name, a date, an instant, a byte count, a firmware string), and
/// not one is a sentence a person reads. The sentences are all resolved by the kit.
enum RecorderPageProofFixture {

    /// Nick's unit, read on 2026-08-16: `APP&FW` → `MCU&FW&1.6`, `APP&BAT` → `MCU&BAT&58`.
    static let deviceName = "PKT01_BLUE_26079bc5"
    static let firmwareVersion = "1.6"
    static let batteryPercent = "58%"

    /// A UUID, because the page's own guard rejects a hardware token that is not one.
    static let hardwareToken = "26079BC5-0000-4000-8000-000000000001"

    static var identity: RecordingDeviceIdentity {
        RecordingDeviceIdentity(shape: .filePull, hardwareToken: hardwareToken)
    }

    /// THE LINK IS PART OF THE STATE, and getting it wrong made the first run of this proof
    /// fail for the right reason: with the link pinned `.connected`, the resting page offered
    /// `Disconnect` rather than `Connect and check now`, because `RecordingDevicePage.resolve`
    /// offers the connect action only while the link is down. A recorder nobody has asked
    /// anything is a recorder this phone has no session with, so `neverAsked` is disconnected —
    /// which is also §6a's resting state, capability strip reading Unavailable and the note
    /// saying the link is why. The two states that follow have a session open, so their strip
    /// carries the values the recorder actually reported.
    static func input(for state: RecorderPageProofState) -> RecordingDeviceListInput {
        let connected = state != .neverAsked
        // EXACTLY WHAT `UnifiedDeviceListComposition.inputs` WOULD DECLARE, AND NOTHING MORE.
        //
        // The first version of this fixture declared battery and firmware unconditionally, and
        // the very first picture it took showed `Battery 58%` and `Firmware 1.6` directly above
        // a note reading "Battery and firmware read Unavailable because FoundryX isn't connected
        // to this recorder right now" — a page contradicting itself in four lines. That is not a
        // state this app can be in: battery and firmware come from per-identity maps the
        // composition fills only while a session is live, so a disconnected recorder has
        // neither. Offline storage is a CLASS fact and survives the link being down; gap
        // recovery is declared by nothing for this class, so it reads Unavailable, which is the
        // honest word.
        //
        // A proof that photographs impossible states teaches the reviewer to distrust the
        // pictures, which costs more than not having them.
        var declared: [String: String?] = [
            RecordingDeviceCapabilityKey.offlineStorage.rawValue: String?.none,
        ]
        if connected {
            declared[RecordingDeviceCapabilityKey.batteryLevel.rawValue] = batteryPercent
            declared[RecordingDeviceCapabilityKey.firmwareVersion.rawValue] = firmwareVersion
        }
        // WHAT THE RECORDER HAS SAID, on the one state where it has said anything.
        //
        // Until this existed the proof photographed the readings strip's "nobody has asked"
        // branch in all three states and its "here is the number, and when it was read" branch
        // in none — so the half of that strip a person sees after every successful check was
        // the half no picture had ever shown. It is seeded only for `shelfAnswered` because
        // that is the only state in which a check has come back: a recorder mid-check has not
        // answered yet, and `neverAsked` is the state whose whole content is that nobody has.
        var readings: [String: RecordingDeviceReading] = [:]
        if state == .shelfAnswered {
            readings = [
                RecordingDeviceCapabilityKey.batteryLevel.rawValue:
                    RecordingDeviceReading(value: batteryPercent, observedAt: listedAt),
                RecordingDeviceCapabilityKey.firmwareVersion.rawValue:
                    RecordingDeviceReading(value: firmwareVersion, observedAt: listedAt),
                RecordingDeviceCapabilityKey.freeSpace.rawValue:
                    RecordingDeviceReading(
                        value: RecordingDeviceReadingPresentation.freeSpace(
                            usedKilobytes: 2_000_000, capacityKilobytes: 8_000_000),
                        observedAt: listedAt),
            ]
        }
        return RecordingDeviceListInput(
            identity: identity,
            displayName: deviceName,
            declaredCapabilities: declared,
            link: connected ? .connected : .disconnected,
            lastConnected: nil,
            isRemembered: true,
            negotiatedProtocol: PocketRecordingDeviceBridge.protocolIdentifier,
            readings: readings)
    }

    /// THREE RECORDINGS, IN BOTH TIMESTAMP FORMATS THE DEVICE ACTUALLY USES. Sizes are bytes;
    /// the wire reports kilobytes and the listing parser converts, and getting that unit wrong
    /// once already cost a whole set of durations.
    static let recordings: [PocketRecording] = [
        PocketRecording(date: "2026-08-11", timestamp: "PH260811175026", sizeBytes: 2_764_000),
        PocketRecording(date: "2026-08-07", timestamp: "20260807142852", sizeBytes: 14_400_000),
        PocketRecording(date: "2026-08-07", timestamp: "20260807093015", sizeBytes: 480_000),
    ]

    /// The one file this phone can PROVE it holds. Custody is asked per file in life; here it
    /// is one entry, so the picture carries both custody labels rather than three of the same.
    static let heldFileIDs: Set<String> = ["2026-08-07/20260807093015"]

    /// WHERE EACH RECORDING IS, AS THE THREE-PLACE READING THE SHELF IS ACTUALLY DRAWN FROM.
    ///
    /// THIS IS WHAT PUTS THE DESTRUCTIVE AFFORDANCE IN THE PHOTOGRAPH, and it is seeded
    /// deliberately UNEVEN. Exactly one recording is `safeElsewhere: .yes`, so exactly one row
    /// renders "Remove it from the recorder" — which means the picture shows the gate working
    /// in BOTH directions on one screen, rather than a page where every row happens to agree.
    /// A proof where the affordance is present on all rows or absent from all rows cannot tell
    /// a working gate from a deleted `if`.
    ///
    /// The other two carry `neverAsked` for both phone-side places, which is the honest state
    /// of a recording nobody has asked custody about — never `no`, which would be a claim.
    static let presences: [String: PocketRecordingPresence] = [
        "2026-08-07/20260807093015": PocketRecordingPresence(
            onRecorder: PocketPlaceReading(answer: .yes, observedAt: listedAt),
            onThisPhone: PocketPlaceReading(answer: .yes, observedAt: listedAt),
            safeElsewhere: PocketPlaceReading(answer: .yes, observedAt: listedAt)),
    ]

    /// When the recorder answered the listing, so every place carries its own age.
    static let listedAt = Date(timeIntervalSince1970: 1_786_000_000)

    /// The shelf, built by the two kit calls the live check makes and by nothing else.
    static var detail: StoredFileDeviceDetailPresentation {
        StoredFileDevicePresentation.detail(
            name: deviceName,
            link: .connected,
            battery: .reported(batteryPercent),
            firmware: .reported(firmwareVersion),
            manifest: PocketInventoryReader.manifest(recordings,
                                                     presences: presences,
                                                     listedAt: listedAt))
    }

    /// The file a tap would ask for, chosen by the shipped comparator rather than picked here.
    static var offered: PocketRecording? {
        PocketBringOver.offered(
            recordings,
            excluding: Set(recordings.filter { heldFileIDs.contains("\($0.date)/\($0.timestamp)") }
                .map(\.request)))
    }

    // THE COLLABORATORS THE PAGE NEEDS, BUILT HERE RATHER THAN IN THE VIEW. Two of them carry
    // string literals — a loopback door URL and a bearer that reaches nothing — and a literal
    // in a view's own declaration is exactly what the gate over this surface forbids. They are
    // configuration, so they live with the rest of the configuration.
    @MainActor
    static func makeDeviceManager() -> DeviceManager { DeviceManager(log: nil) }

    @MainActor
    static func makeCaptureManager() -> CaptureManager {
        CaptureManager(
            target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "local"),
            log: nil,
            source: ReplaySource(frames: []),
            attachToSourcesImmediately: false)
    }

    @MainActor
    static func makeSourceRegistry() -> CaptureSourceRegistry {
        CaptureSourceRegistry(phoneMicAvailable: false)
    }

    @MainActor
    static func check(for state: RecorderPageProofState) -> PocketRecorderCheckModel {
        switch state {
        case .neverAsked:
            return PocketRecorderCheckModel()
        case .errandRunning:
            return PocketRecorderCheckModel(proofIsChecking: true)
        case .shelfAnswered:
            // WHEN THE RECORDER ANSWERED, because the header states what a check is doing. A
            // shelf handed over with no instant photographs "Not checked yet" above a list of
            // files the recorder has just named — a page contradicting itself in two lines,
            // which is the failure this file's own header says teaches a reviewer to distrust
            // the pictures.
            return PocketRecorderCheckModel(proofDetail: detail,
                                            proofOfferedRecording: offered,
                                            proofShelfAnsweredAt: listedAt)
        }
    }
}

/// The mount. It builds the three collaborators the page needs and hands the page a check
/// model already in the state being photographed.
struct RecorderPageProof: View {
    let state: RecorderPageProofState

    @StateObject private var device = RecorderPageProofFixture.makeDeviceManager()
    @StateObject private var manager = RecorderPageProofFixture.makeCaptureManager()
    @StateObject private var sources = RecorderPageProofFixture.makeSourceRegistry()

    var body: some View {
        NavigationStack {
            RecordingDevicePageView(input: RecorderPageProofFixture.input(for: state),
                                   device: device,
                                   manager: manager,
                                   sources: sources,
                                   isSavedOmi: false,
                                   // THE TIER THAT CAN ACTUALLY SATISFY THE SAFETY PREDICATE.
                                   // On `.justMyPhone` there is nowhere else for a copy to go,
                                   // so the auto-clear control is absent by design and the
                                   // Remove affordance can never be offered — the photograph
                                   // would show a page with the destructive half missing and
                                   // still pass.
                                   brain: .myComputer,
                                   onChange: {},
                                   check: RecorderPageProofFixture.check(for: state))
        }
        .accessibilityIdentifier("recorder-page-proof")
    }
}

#endif
