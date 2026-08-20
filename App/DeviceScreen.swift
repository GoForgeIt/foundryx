import SwiftUI
import Grain

/// The Devices screen — ONE LIST (track
/// 20260810T2158_unified_recording_device_list_wires_pocket_and_omi, building
/// `DESIGN-pocket-connect.md` §2).
///
/// WHAT THIS REPLACED, AND WHY IT WAS NOT COSMETIC. On TestFlight 771837 this screen opened
/// on an Omi HERO BLOCK — a vendor name, a "Not paired" state, and a Battery / Signal /
/// Firmware strip reading `N/A · N/A · N/A` — above a separate `CAPTURE SOURCES` section,
/// with no Pocket anywhere. The design's rule is one sentence long:
///
///   "One list. Four shapes. Same row grammar for all of them … Class is a caption you read,
///    never a section you get sorted into. Grouping by class would quietly turn 'one list'
///    into 'one list, vendors first.'"
///
/// A hero block IS "vendors first". So there is no hero, no capture-sources split, and no
/// section header any device gets sorted under. Every device — the handset's own microphone, a
/// Bluetooth headset, an Omi, a Pocket — is a peer row: a name, a chevron, and one line
/// reading `<class> · <state>`.
///
/// THIS VIEW DERIVES NOTHING. Every string it shows comes from `UnifiedDeviceListPresentation`
/// / `RecordingDevicePage` / `RecordingDeviceConnectPresentation` in FoundryXKit, which
/// `features/unified-recording-device-list.feature` drives directly — so the values Brine
/// asserts ARE the values on screen. A SwiftUI body that re-derived any of this copy would be
/// a second, untested implementation of it, and `swift test` cannot compile `App/` to notice.
///
/// ORDER IS NOT DECIDED HERE. `UnifiedDeviceListPresentation.rows` merges through
/// `RecordingSourceCatalog.merge`, whose comparison cannot see the shape. There is no `sorted`
/// and no `Section` in this file, deliberately.
struct DeviceScreen: View {
    @ObservedObject var device: DeviceManager
    @ObservedObject var manager: CaptureManager
    @ObservedObject var sources: CaptureSourceRegistry
    /// Computer pairing = the existing sign-in → resolve-designated-host flow
    /// (SignInView / RemoteSession) — reused here, not rebuilt.
    @ObservedObject var remote: RemoteSession
    /// WHERE A BROUGHT-OVER RECORDING WILL END UP. Passed in rather than read here: this is
    /// the SAME account preference the Settings brain picker owns (`SettingsScreen` holds the
    /// `BrainStore` that pushed this screen), and a second reader of one preference is how two
    /// preferences meaning the same thing start.
    let brain: BrainChoice

    @StateObject private var list = RecordingDeviceListModel()
    @State private var showingComputerPairing = false
    @State private var showingConnect = false
    @State private var showingEducation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                educationHeader
                deviceList
                connectAffordance
                computerMemorySection
            }
            .padding(.horizontal, GrainSpacing.x4)
            .padding(.bottom, GrainSpacing.x8)
        }
        .grainBackground()
        .navigationBarTitleDisplayMode(.inline)
        // Power the central + auto-reconnect only for a REMEMBERED, enabled Omi. With no
        // saved device, opening this page arms NOTHING (no scan, no CB restoration) —
        // first-time pairing is the explicit connect affordance below.
        .onAppear {
            if device.saved != nil, sources.isEnabled(CaptureSourceDescriptor.omiId) {
                device.start()
            }
            refresh()
        }
        // A user-initiated pairing scan that found nothing must not keep scanning after
        // the page is dismissed (a lingering scan re-arms the radio + CB restoration).
        .onDisappear {
            device.stopScanIfScanning()
        }
        .onChange(of: device.connectionState) { _ in
            syncOmiConnection()
            refresh()
        }
        .onChange(of: device.batteryLevel) { _ in refresh() }
        .onChange(of: device.saved) { _ in refresh() }
        .onChange(of: sources.sources) { _ in refresh() }
        .sheet(isPresented: $showingComputerPairing) {
            SignInView(remote: remote) { showingComputerPairing = false }
        }
        // THE ORPHANED VIEW'S FIRST PRESENTER. `PocketOnboardingView` shipped with nothing
        // anywhere in the tree referencing it; the connect affordance is what reaches it.
        .sheet(isPresented: $showingConnect) {
            RecordingDeviceConnectSheet(device: device) {
                showingConnect = false
                refresh()
            }
        }
        // "What's the difference?" IS A QUESTION ABOUT CLASSES, so it gets the class answer.
        // It used to open one vendor's LED legend — "Solid amber — Recording, Blue —
        // Connected" — on a screen whose stated premise is that no screen switches on vendor.
        .sheet(isPresented: $showingEducation) {
            NavigationStack {
                RecordingDeviceClassExplanationView { showingEducation = false }
            }
        }
    }

    private func refresh() {
        list.refresh(sources: sources.sources,
                     omi: device.saved,
                     omiLink: omiLink,
                     omiBattery: device.batteryLevel,
                     recordingIdentity: recordingIdentity)
    }

    private func syncOmiConnection() {
        if case .connected = device.connectionState {
            sources.setOmiConnected(true)
        } else {
            sources.setOmiConnected(false)
        }
    }

    // MARK: - The one distinction, said before the rows

    /// Said out loud ABOVE the list, because the whole list is organised around it and a
    /// caption on a row is not where a person learns a new concept.
    private var educationHeader: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            Text(UnifiedDeviceListPresentation.educationLead)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showingEducation = true
            } label: {
                HStack(spacing: GrainSpacing.x1) {
                    Text(UnifiedDeviceListPresentation.educationLink)
                        .grainTextStyle(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(GrainColor.forgeBlue)
                    Image(systemName: "chevron.right")
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.forgeBlue)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, GrainSpacing.x3)
        .overlay(alignment: .bottom) { hairline }
    }

    // MARK: - The one list

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(list.rows) { row in
                NavigationLink {
                    // Deferred for the same reason the conversation row's detail is: a
                    // NavigationLink's destination is a @ViewBuilder evaluated WITH the link,
                    // once per row on every body pass of the screen carrying it.
                    LazyView { devicePage(for: row.identity) }
                } label: {
                    deviceRow(row)
                }
                .buttonStyle(.plain)
            }

            if list.rows.isEmpty {
                Text(RecordingDeviceConnectPresentation.emptyLine)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, GrainSpacing.x3)
            }
        }
    }

    /// THE ROW GRAMMAR, and it is the same one for all four shapes: a name, a chevron, and one
    /// line reading `<class> · <state>`. No vendor badge, no per-family icon, no per-shape
    /// ordering, no section header.
    private func deviceRow(_ row: UnifiedDeviceRow) -> some View {
        HStack(spacing: GrainSpacing.x3) {
            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                Text(row.displayName)
                    .grainTextStyle(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(GrainColor.ink)

                Text(row.detailLine)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: GrainSpacing.x2)

            Image(systemName: "chevron.right")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)
        }
        .padding(.vertical, GrainSpacing.x3)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recording-device-row")
        .overlay(alignment: .bottom) { hairline }
    }

    @ViewBuilder
    private func devicePage(for identity: RecordingDeviceIdentity) -> some View {
        if let input = list.input(for: identity) {
            RecordingDevicePageView(input: input,
                                    device: device,
                                    manager: manager,
                                    sources: sources,
                                    isSavedOmi: isSavedOmi(identity),
                                    brain: brain,
                                    onChange: refresh)
        } else {
            // The device left the list while its page was being pushed. Say so rather than
            // render an empty page about a device that is no longer there.
            Text(RecordingDeviceConnectPresentation.emptyLine)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)
                .padding(GrainSpacing.x4)
        }
    }

    // MARK: - The one connection affordance

    private var connectAffordance: some View {
        Button {
            showingConnect = true
        } label: {
            Text(RecordingDeviceConnectPresentation.affordanceTitle)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.grain(.filled))
        .accessibilityIdentifier("connect-a-recording-device")
        .padding(.top, GrainSpacing.x4)
    }

    // MARK: - Computer memory

    private var computerMemorySection: some View {
        let pres = ComputerMemoryPresentation.resolve(.resolve(remote: remote))
        return VStack(alignment: .leading, spacing: 0) {
            DeviceSectionLabel("Computer memory")
                .padding(.top, GrainSpacing.x6)
                .padding(.bottom, GrainSpacing.x1)

            HStack(alignment: .top, spacing: GrainSpacing.x3) {
                DeviceIconTile(icon: pres.isConnected ? .check : .device,
                               foreground: pres.isConnected ? GrainColor.sage : GrainColor.forgeBlue)

                VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                    Text(pres.title)
                        .grainTextStyle(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(GrainColor.ink)
                    Text(pres.subtitle)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: GrainSpacing.x1)

                HStack(spacing: GrainSpacing.x1) {
                    // Offline pill is muted/grey (not amber); paired is green.
                    GrainStatusDot(pres.isConnected ? .running : .stopped, size: .sm)
                    Text(pres.statusLabel)
                        .grainTextStyle(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(pres.isConnected ? GrainColor.sage : GrainColor.textFaint)
                }
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityElement(children: .combine)
            }
            .padding(.vertical, GrainSpacing.x2)
            .frame(minHeight: 54)
            .overlay(alignment: .top) { hairline }
            .overlay(alignment: .bottom) { hairline }

            // Full-width pairing action: primary connect when unpaired, secondary
            // disconnect when paired. Both open the existing pairing/connection
            // surface (SignInView → RemoteSession resolve) — no Settings redirect.
            Button {
                showingComputerPairing = true
            } label: {
                Text(pres.actionTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.grain(pres.actionIsPrimary ? .filled : .outlined))
            .padding(.top, GrainSpacing.x3)

            HStack(alignment: .top, spacing: GrainSpacing.x2) {
                Image(grain: .key)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                Text(pres.footer)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, GrainSpacing.x2)
        }
    }

    // MARK: - Derived state (link facts only — never a claim about recording)

    /// LINK REACHABILITY, from the shipped connection state. `.scanning` is not a fact about
    /// this device's link at all, so it reads as not connected rather than as a state of its
    /// own — the design's hero status has exactly three answers.
    private var omiLink: RecordingDeviceLinkState {
        switch device.connectionState {
        case .connected:  return .connected
        case .connecting: return .reconnecting
        case .scanning, .disconnected, .idle, .poweredOff: return .disconnected
        }
    }

    /// Which device is making audio right now, if any. `nil` while nothing is recording — the
    /// list never guesses, and a record-then-sync device discards this even when it is set.
    private var recordingIdentity: RecordingDeviceIdentity? {
        guard manager.active != nil, !manager.isPaused else { return nil }
        if manager.isRecordingMic {
            return RecordingDeviceIdentity(
                shape: .builtInMic,
                hardwareToken: UnifiedDeviceListComposition.handsetToken)
        }
        guard let saved = device.saved, case .connected = device.connectionState else { return nil }
        return RecordingDeviceIdentity(shape: .bleStream, hardwareToken: saved.id.uuidString)
    }

    private func isSavedOmi(_ identity: RecordingDeviceIdentity) -> Bool {
        guard let saved = device.saved else { return false }
        return identity == RecordingDeviceIdentity(shape: .bleStream,
                                                   hardwareToken: saved.id.uuidString)
    }

    private var hairline: some View {
        Rectangle()
            .fill(GrainColor.borderFaint)
            .frame(height: 1)
    }
}

// MARK: - The list model

/// Reads the ACCOUNT-SCOPED remembered devices off disk and composes them with this handset's
/// own capture sources into the one list.
///
/// OFF THE MAIN ACTOR, DELIBERATELY. `RecordingDeviceStore.current()` resolves the account
/// binding — a process-wide lock plus an on-disk admission-registry read — and then decodes a
/// JSON file. Doing that inside a body pass is the per-row main-actor disk read `LazyView`
/// exists to prevent; doing it once per state change, on a utility queue, is the answer.
@MainActor
final class RecordingDeviceListModel: ObservableObject {
    @Published private(set) var rows: [UnifiedDeviceRow] = []
    private var inputs: [RecordingDeviceIdentity: RecordingDeviceListInput] = [:]

    func input(for identity: RecordingDeviceIdentity) -> RecordingDeviceListInput? {
        inputs[identity]
    }

    /// `elapsed` is deliberately absent: this list refreshes on state change, not on a
    /// one-second tick, so it has no live clock to print and a frozen one would be a lie. The
    /// row reads `Live · Recording now` — the fact, without a duration it cannot keep true.
    func refresh(sources: [CaptureSourceDescriptor],
                 omi: SavedOmi?,
                 omiLink: RecordingDeviceLinkState,
                 omiBattery: Int?,
                 recordingIdentity: RecordingDeviceIdentity?) {
        var link: [RecordingDeviceIdentity: RecordingDeviceLinkState] = [:]
        var battery: [RecordingDeviceIdentity: Int] = [:]
        if let omi {
            let identity = RecordingDeviceIdentity(shape: .bleStream,
                                                   hardwareToken: omi.id.uuidString)
            link[identity] = omiLink
            if let omiBattery { battery[identity] = omiBattery }
        }
        Task.detached(priority: .utility) {
            let remembered = UnifiedDeviceListComposition.rememberedForCurrentAccount()
            let composed = UnifiedDeviceListComposition.inputs(
                remembered: remembered,
                captureSources: sources,
                link: link,
                batteryPercent: battery,
                recording: recordingIdentity)
            let rows = UnifiedDeviceListPresentation.rows(composed)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inputs = Dictionary(composed.map { ($0.identity, $0) },
                                         uniquingKeysWith: { _, latest in latest })
                self.rows = rows
            }
        }
    }
}

// MARK: - One device's own page

/// The slots a live device fills with recording state, filled with what is true instead
/// (design §2's honest-substitute table, and §6a's resting state).
///
/// IT USED TO BE `private`, WHICH MADE IT UNPHOTOGRAPHABLE. Reaching this page in a simulator
/// means a remembered recorder, a Bluetooth radio and a device in the room — so nothing in any
/// build had ever rendered it, and "never ship UI without simulator proof" was a habit somebody
/// had to remember on the one screen in this app that cannot be reached without hardware.
/// `RecorderPageProof` mounts THIS type — not a copy of it — with a scripted check model, and
/// `phase_uiproof` photographs each of its states.
struct RecordingDevicePageView: View {
    let input: RecordingDeviceListInput
    @ObservedObject var device: DeviceManager
    /// THE ONE THAT OWNS THE CAPTURE LIBRARY. A bring-over writes a finished conversation into
    /// this manager's base directory, and the manager has to be TOLD — `loadExisting()` only
    /// runs when a manager is built, so a conversation created while the app is already open is
    /// invisible until the next launch unless somebody hands it over.
    @ObservedObject var manager: CaptureManager
    @ObservedObject var sources: CaptureSourceRegistry
    /// Whether this is the ONE remembered Omi, which is a fact about the live pairing path and
    /// nothing else. It used to double as "can this device be connected at all" — see
    /// `canReachDevice` below for why that was wrong.
    let isSavedOmi: Bool
    /// The brain that is on, which decides the one sentence the shelf says about where a
    /// brought-over copy goes. `LocalBackend` saves with `markConfirmed: false`, so on the
    /// phone-only tier `safe elsewhere` can never be true and the copy borrows no other tier's
    /// promise.
    let brain: BrainChoice
    let onChange: () -> Void

    @State private var showingEducation = false
    @State private var confirmingForget = false

    // WHAT THE ACCOUNT HOLDS FOR THIS RECORDER NOW, as opposed to when the row was opened, IS
    // NOT STATE ON THIS VIEW ANY MORE.
    //
    // THE DEFECT IT CLOSED. `input` is captured when the row's `NavigationLink` is pushed
    // (`DeviceScreen.devicePage(for:)`), and a check writes the recorder's charge, its
    // firmware and how full it is straight to the account's store. Nothing re-read it:
    // `RecordingDeviceListModel.refresh` fires only on the Omi's connection state, its
    // battery, `saved` or `sources`, and a check on a record-then-sync recorder touches none
    // of those. So the shelf filled with recordings while Battery, Free space and Firmware
    // each went on offering "Connect and check now" over numbers already on this phone's disk.
    //
    // AND WHY IT MOVED. It was `@State private var refreshedInput: RecordingDeviceListInput?`,
    // rendered as `refreshedInput ?? input` — a latch, in a `View`, which is to say in the one
    // place no test in this repository can execute. Two one-line mutations to it shipped green
    // through `swift test` AND the app-hosted lane on 2026-08-17. It is `RecorderPageModel`
    // now; see that file's header.

    // `confirmingRemovalOf` USED TO LIVE HERE, holding the ID of the recording a removal was
    // being confirmed for. The removal is no longer fired from a row, so the page no longer
    // owns that question: it belongs to `PocketRecordingDetailSheet`, which is about exactly
    // one recording and therefore needs no ID to keep the confirmation and its subject in
    // agreement. Deleted rather than left as unread state.

    /// WHICH RECORDING THE OWNER OPENED, by the recorder's own `<date>/<timestamp>`.
    ///
    /// THE ID RATHER THAN THE PAGE VALUE, on purpose. The page is derived from the shelf
    /// reading, and the shelf reading changes underneath an open sheet — a bring-over started
    /// from this sheet re-reads custody and the recording moves from "only on the recorder" to
    /// "in Solleva". Holding the derived value would freeze the sheet on the state the tap
    /// happened in, so the one screen that exists to say where a recording is would go on
    /// saying the old answer while the transfer it started was landing.
    @State private var inspecting: String?
    /// §10 custody. The key is fetched from the Keychain only when the owner asks for it, and
    /// it does not outlive the sheet that showed it.
    @State private var showingKeyCustody = false
    @State private var revealedKey: String?
    @State private var didCopyKey = false
    @State private var keyCustodyFoundNothing = false
    /// Whether the SYNCHRONISED (§10) copy of this recorder's key exists, asked of the store
    /// when the screen opens. `false` renders the sentence that tells the owner to write the
    /// key down, which is the safe direction to be wrong in.
    @State private var recoveryCopyExists = false
    /// The maker's reset ceremony, reached from the shelf's own cost line.
    @State private var showingFactoryReset = false
    /// What the recorder said it is holding, the last time this screen asked it.
    /// Whether this app is still the thing in front of the owner. A backgrounded transfer is
    /// an errand nobody is watching, and it stops — see the `onChange` at the end of `body`.
    @Environment(\.scenePhase) private var scenePhase
    ///
    /// INJECTABLE, WITH THE LIVE MODEL AS THE DEFAULT. Every production call site gets the
    /// same freshly-built model it always did; the proof mount hands in one whose published
    /// state is already the state being photographed, because a simulator has no radio and
    /// therefore no other way to reach an answered shelf.
    ///
    /// ONE `@StateObject`, AND THE CHECK IS REACHED THROUGH IT. Two of them cannot be wired to
    /// each other — the second's initialiser cannot see the first — and the page's whole fix
    /// is that wiring: `RecorderPageModel` has to be told when an errand ends.
    @StateObject private var model: RecorderPageModel

    /// The errand model, unchanged for every reader in this body. It is the SAME object the
    /// page's model holds, so `check.detail`, `check.isRemoving` and the rest read exactly what
    /// they always did.
    private var check: PocketRecorderCheckModel { model.check }

    init(input: RecordingDeviceListInput,
         device: DeviceManager,
         manager: CaptureManager,
         sources: CaptureSourceRegistry,
         isSavedOmi: Bool,
         brain: BrainChoice,
         onChange: @escaping () -> Void,
         check: PocketRecorderCheckModel = PocketRecorderCheckModel()) {
        self.input = input
        _device = ObservedObject(wrappedValue: device)
        _manager = ObservedObject(wrappedValue: manager)
        _sources = ObservedObject(wrappedValue: sources)
        self.isSavedOmi = isSavedOmi
        // NO DEFAULT, and Step 10's hand-written init silently dropped it. The memberwise init
        // it replaced carried `brain`; once this one existed, every call site had to pass it
        // explicitly and the proof mount is one of them.
        self.brain = brain
        self.onChange = onChange
        _model = StateObject(wrappedValue: RecorderPageModel(check: check,
                                                            identity: input.identity,
                                                            isSavedOmi: isSavedOmi))
    }

    /// DOES THIS BUILD HAVE A TRANSPORT THAT CAN ACTUALLY ATTACH THIS DEVICE?
    ///
    /// THIS USED TO BE `isSavedOmi`, WHICH IS THE BUG. `isSavedOmi` compares against
    /// `RecordingDeviceIdentity(shape: .bleStream, …)`, so it is false for EVERY `.filePull`
    /// recorder by construction — and `resolve` only appends connect/disconnect inside
    /// `if canConnect`. The result: once a Pocket was adopted, its page carried no connect
    /// action at all, and the only surface in the whole app that could ever reach it again was
    /// the "Connect a recording device" scan sheet. A remembered recorder with no way to reach
    /// it is a device the app forgot how to talk to.
    ///
    /// A remembered record-then-sync recorder has one now: `RecordingDeviceAttachment
    /// .withAuthenticatedSession`, which `PocketRecorderCheck.run` opens and closes. It offers
    /// "Connect and check now" — the shipped copy for this class — and what it does is exactly
    /// what it says: it connects, reads the shelf, and disconnects. It does NOT bring anything
    /// over, and design §6c's absence of a bring-over button is untouched.
    private var canReachDevice: Bool { model.canReach(input) }

    /// EVERY SLOT DECIDED IN THE KIT. This view passed `hasEducation: shape == .filePull` and
    /// `canForget: shape != .builtInMic` — two shape branches on a screen whose whole rule is
    /// that no surface switches on shape. Education now follows the negotiated protocol and
    /// forget follows the store record, both inside `resolve`, where Brine can hold them.
    /// THE DEVICE AS IT IS NOW, not as it was when the row was opened.
    ///
    /// IT TAKES THE CURRENT `input` EVERY TIME, which is what ended the latch. This read
    /// `refreshedInput ?? input`: the first errand to finish made `refreshedInput` non-nil and
    /// from that instant every value the list pushed into this page was discarded for the life
    /// of the screen. `RecordingDevicePageFacts.readings` now picks the later of the two.
    private var live: RecordingDeviceListInput { model.live(pushed: input) }

    /// THE ONLY LIVE STATE A RECORD-THEN-SYNC RECORDER HAS, and the decision is the kit's.
    ///
    /// A check opens its own session and closes it again, so this page has no link to report
    /// and never had one — `input.link` is `.disconnected` for every `.filePull` identity by
    /// construction. What it does have is a check: one running, or one that answered at an
    /// instant this phone's clock recorded. `swift test` cannot compile `App/`, so the choice
    /// between the three lives in `RecordingDeviceCheckState` where Brine can hold it.
    private var checkState: RecordingDeviceCheckState { model.checkState(pushed: input) }

    /// THE WHOLE PAGE AS ONE VALUE, decided in `RecorderPageModel` where the app-hosted
    /// scenarios can execute it. Not one branch of it is taken here.
    private var page: RecordingDevicePagePresentation { model.page(pushed: input) }

    /// THE PAGE, WALKED IN THE ORDER THE KIT DECIDED — never in the order these statements
    /// happen to be written in.
    ///
    /// THE DEFECT THIS CLOSES, in Nick's words about his own recorder page: *"there is lots of
    /// scrolling to get to any of the important controls or information."* His unit was holding
    /// nineteen recordings, and the bring-over, the fast sync, the reset and the auto-clear
    /// were all drawn UNDERNEATH all nineteen rows, because they were written inside the shelf
    /// that lists them. The shelf is the only band here with no ceiling. Every other band is a
    /// fixed number of lines; that one is a row per recording, and a control after it sits at a
    /// distance decided by how full somebody's recorder is.
    ///
    /// AND WHY THE ORDER IS A VALUE. `swift test` cannot compile `App/`, so an order expressed
    /// as eleven statements in a `VStack` is invisible to every test in this repository — which
    /// is exactly how the controls got under the list and stayed there through a shipped build.
    /// `RecorderPageLayout.order` is an array Brine reads; this walks it.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(RecorderPageLayout.order, id: \.self) { band in
                    self.band(band)
                }
            }
            .padding(.horizontal, GrainSpacing.x4)
            .padding(.bottom, GrainSpacing.x8)
        }
        .grainBackground()
        .navigationTitle(input.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingEducation) {
            NavigationStack {
                PocketOnboardingView(screen: .education) { _ in showingEducation = false }
            }
        }
        .sheet(isPresented: $showingFactoryReset) {
            NavigationStack {
                PocketOnboardingView(screen: .factoryReset) { _ in showingFactoryReset = false }
            }
        }
        .sheet(isPresented: $showingKeyCustody, onDismiss: {
            // THE REVEALED VALUE DIES WITH THE SHEET. Holding it in view state past the screen
            // that showed it keeps a live credential in the hierarchy for no reason.
            revealedKey = nil
            didCopyKey = false
            keyCustodyFoundNothing = false
            recoveryCopyExists = false
        }) {
            NavigationStack {
                PocketOnboardingView(screen: .keyCustody) { _ in showingKeyCustody = false }
                    .keyCustody(revealed: revealedKey,
                                didCopy: didCopyKey,
                                knownMissing: keyCustodyFoundNothing,
                                hasRecoveryCopy: recoveryCopyExists,
                                onReveal: { toggleRevealedKey() },
                                onCopy: { copyRevealedKey() })
            }
        }
        // THE WARNING THIS DEVICE'S CLASS EARNS. The key sentence is a claim about custody
        // FoundryX only has for a recorder it provisioned; showing it for a Bluetooth route
        // was a destructive-sounding promise about a key that does not exist.
        .alert(RecordingDevicePage.forgetAction, isPresented: $confirmingForget) {
            Button(RecordingDevicePage.cancelAction, role: .cancel) {}
            Button(RecordingDevicePage.forgetAction, role: .destructive) { forget() }
        } message: {
            // THE COST, IN THE SAME TERMS AS THE RESET. Forgetting deletes this app's key, so
            // every recording the recorder still holds ALONE becomes unreachable - and until
            // this line shipped the confirmation stated the mechanism and never the number.
            Text(PocketRecorderCostPresentation.forgetMessage(warning: page.forgetWarning,
                                                              presences: check.presences))
        }
        // ONE RECORDING, OPENED. The list is where a person finds a recording; this is where
        // they can do anything with it. It resolves the page on every redraw rather than
        // capturing it at the tap, so a transfer started inside the sheet moves the sheet's own
        // three places while it lands.
        .sheet(isPresented: Binding(get: { inspecting != nil },
                                    set: { if !$0 { inspecting = nil } })) {
            NavigationStack {
                PocketRecordingDetailSheet(
                    page: inspecting.flatMap { check.detailPage(for: $0, brain: brain) },
                    brain: brain,
                    // THE ERRAND THIS PAGE IS ABOUT, not "something is busy". It used to be
                    // three ORed flags, which disabled this page's actions for another
                    // recording's transfer and could say nothing about which — and which is
                    // why the only place progress could be drawn was the top of the page
                    // behind it.
                    progress: inspecting.map {
                        PocketErrandProgressPresentation.progress(check.inFlight, for: $0)
                    } ?? .idle,
                    onBringOver: { id in
                        check.bringOver(id: id,
                                        hardwareToken: input.identity.hardwareToken,
                                        advertisedName: input.displayName,
                                        into: manager)
                    },
                    onRemove: { id in
                        check.removeFromRecorder(id: id,
                                                 hardwareToken: input.identity.hardwareToken,
                                                 advertisedName: input.displayName)
                    },
                    onClose: { inspecting = nil })
            }
        }
        // LEAVING THE PAGE STOPS SOME ERRANDS AND NOT OTHERS, AND THIS BODY DOES NOT GET TO
        // DECIDE WHICH.
        //
        // THIS USED TO READ `.onDisappear { check.cancel() }` — unconditional — which is the
        // defect: a bring-over measured at 18-36 KB/s is exactly the errand a person walks away
        // from, and walking away killed it. A check still stops (its answer has no page left to
        // land on) and so does a removal (destructive work must not outlive the screen that
        // authorised it); a transfer does not, because the bytes are the point.
        //
        // The rule is `PocketErrandDeparturePolicy`, in the kit, for the reason the scene-phase
        // rule is: nothing in this repository can execute a SwiftUI modifier, so a rule written
        // here is a rule nothing can hold.
        .onDisappear { check.departed() }
        // A SCREENSHOT IS NOT A DEPARTURE, AND THIS VIEW DOES NOT GET TO DECIDE THAT.
        //
        // This used to read `if phase != .active { check.cancel() }`. iOS reports `.inactive`
        // for a screenshot, Control Center, the app switcher and a notification banner — none
        // of which is the owner leaving — so the one gesture a person makes to SHOW somebody
        // their transfer running was the gesture that killed it.
        //
        // The rule now lives in `PocketErrandScenePhasePolicy` and the survival in
        // `PocketBackgroundLease`, both in the kit, because nothing in this repository can
        // execute a SwiftUI body — which is precisely how that comparison shipped untested.
        .onChange(of: scenePhase) { phase in
            check.sceneChanged(to: PocketErrandScenePhase(phase))
        }
        // AND THE LIST BEHIND THIS PAGE, whenever this page has re-read the account's facts.
        //
        // THE RE-READ ITSELF IS NOT WIRED HERE ANY MORE. It was:
        //
        //     .onChange(of: check.isChecking) { checking in
        //         guard !checking else { return }
        //         reReadWhatTheCheckWrote()
        //     }
        //
        // — an edge comparison inside a body nothing in this repository can execute. Inverting
        // that one `!` moved the re-read to the RISING edge, so a finished check's numbers
        // reached the page never, and it shipped green through `swift test` (1536/0) AND the
        // app-hosted lane (7/0) on 2026-08-17. It covered one of the five errands besides.
        // `PocketRecorderCheckModel.finishErrand` is the one stop all five pass through, and
        // `RecorderPageModel` listens there. What is left here is telling the LIST: its rows
        // carry the same battery this errand measured and it composes them from the same
        // store, so leaving it stale would put two answers to one question on two screens a
        // back-swipe apart.
        .onChange(of: model.factsGeneration) { _ in onChange() }
    }

    /// ONE BAND. The dispatch is exhaustive over `RecorderPageBand`, so a band added to the
    /// layout does not compile until this page draws something for it — which is the half a
    /// source scan cannot give you.
    @ViewBuilder
    private func band(_ band: RecorderPageBand) -> some View {
        switch band {
        case .header:            header
        case .recordingIndicator: recordingIndicator
        case .readings:          readingsStrip
        case .capabilities:      capabilityStrip
        case .captureToggle:     captureToggle
        case .actions:           actions
        case .shelfHeadline:     shelfHeadline
        case .shelfControls:     shelfControls
        // THE COST OF STARTING OVER IS A PAGE-LEVEL FACT, NOT A CONSEQUENCE OF A SUCCESSFUL
        // LISTING. This section used to live inside `if let detail = check.detail`, so it
        // appeared only after a check had REACHED the recorder — which made two of its own
        // states unreachable. `resetGate` answers `shelfObservedAt == nil` with "Check the
        // recorder first", and `costLine(nil)` says Solleva has not checked what the recorder
        // is holding; neither could ever be drawn, because both describe the state before the
        // first successful check.
        case .resetGate:         resetGate
        // A SETTING, NOT PART OF THE SHELF. The shelf draws only after the owner has asked a
        // recorder what it is holding, and whether THIS recorder clears itself is a standing
        // choice a person must be able to see and change without opening a Bluetooth session
        // first. Nested inside the shelf, the one control the ruling calls "owner-armed" would
        // have been invisible until the radio answered.
        case .autoClear:         autoClearControl
        case .shelfRows:         shelfRows
        }
    }

    /// THE SINGLE MOST IMPORTANT SENTENCE IN THE DESIGN. It occupies the band where a live
    /// device carries record / pause / stop; the empty space is not blanked, it is occupied by
    /// the true fact.
    @ViewBuilder
    private var recordingIndicator: some View {
        if let sentence = page.recordingIndicatorSentence {
            Text(sentence)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("recorder-light-sentence")
                .padding(.vertical, GrainSpacing.x3)
                .overlay(alignment: .bottom) { hairline }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            // The CLASS, as an eyebrow. A caption you read — never a section you were sorted
            // into, and never a vendor word.
            Text(page.classCaption.uppercased())
                .grainTextStyle(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(GrainColor.forgeBlue)

            // LINK REACHABILITY ONLY. Never "In range": this phone cannot distinguish
            // out-of-range from powered-off from connected-to-another-app.
            Text(page.status)
                .grainTextStyle(.title)
                .foregroundStyle(GrainColor.ink)
                .accessibilityIdentifier("recording-device-status")
        }
        .padding(.vertical, GrainSpacing.x3)
        .overlay(alignment: .bottom) { hairline }
    }

    /// WHAT THE RECORDER SAID, AND HOW OLD IT IS — rendered 1:1 from
    /// `RecordingDevicePagePresentation.readings`. Not one string in this body is invented:
    /// the label, the number, the age and the action all come from the kit, because
    /// `swift test` cannot compile `App/` and a line written here is a second, unasserted
    /// implementation of the app's voice.
    ///
    /// TWO STATES AND NO THIRD. A fact that was read shows its value with the moment it was
    /// read beside it. A fact nobody has ever asked shows NO number — not a dash, not `0%`,
    /// not the shipped word `Unavailable` — and offers the action that would go and ask. The
    /// second state is a button, because a stated absence with no way to end it is a shrug.
    ///
    /// SAID ONCE, NOT ONCE PER FACT — and this is a layout change, not a change of what is
    /// said. Three facts stacked as three full-width rows each carrying its own copy of "read
    /// just now", or its own copy of the SAME "Connect and check now" button, is the page Nick
    /// was shown. `RecordingDeviceReadingPresentation.strip(_:)` decides what the whole strip
    /// shares; the numbers sit side by side as tiles, the one moment they were read is stated
    /// under them once, and the one errand that would go and ask is offered once.
    @ViewBuilder
    private var readingsStrip: some View {
        if !page.readings.isEmpty {
            let strip = RecordingDeviceReadingPresentation.strip(page.readings)
            VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                // THE NUMBERS, SIDE BY SIDE. Value above label, which is the order a person
                // reads a figure in — the label is what it is, and the figure is what they
                // opened the page for.
                if !strip.read.isEmpty {
                    HStack(alignment: .top, spacing: GrainSpacing.x4) {
                        ForEach(Array(strip.read.enumerated()), id: \.offset) { _, line in
                            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                                if let value = line.value {
                                    Text(value)
                                        .grainTextStyle(.body)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(GrainColor.ink)
                                }
                                Text(line.label)
                                    .grainTextStyle(.caption)
                                    .foregroundStyle(GrainColor.textMuted)
                                // THE AGE IS NOT OPTIONAL DECORATION. A number with no
                                // statement of when it was read is the `Unavailable` defect
                                // with a number painted over it. It is drawn per tile ONLY
                                // when the strip has no single moment to state for them all.
                                if strip.sharedAge == nil, let ago = line.observedAgo {
                                    Text(ago)
                                        .grainTextStyle(.caption)
                                        .foregroundStyle(GrainColor.textFaint)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                // ONE MOMENT, STATED ONCE, when one check read all of them.
                if let shared = strip.sharedAge {
                    Text(shared)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                }

                // AND WHEN THE PHONE COULD NOT READ THIS ACCOUNT'S OWN RECORD OF THEM, THAT.
                //
                // Directly under the age, because it is the age it qualifies: the numbers are
                // still the last thing the recorder said, and `observedAgo` above would
                // otherwise be the page claiming it had just gone and confirmed them. The
                // sentence is the kit's — `RecordingDevicePageFacts.factsUnreadableNote` —
                // and which of the three re-read outcomes earns it is decided there too.
                if let note = page.factsNote {
                    Text(note)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("recorder-facts-note")
                }

                // WHAT NOBODY HAS ASKED FOR YET, NAMED — never dropped — and ONE way to ask.
                if !strip.unread.isEmpty {
                    HStack(alignment: .top, spacing: GrainSpacing.x4) {
                        ForEach(Array(strip.unread.enumerated()), id: \.offset) { _, line in
                            Text(line.label)
                                .grainTextStyle(.caption)
                                .foregroundStyle(GrainColor.textFaint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let ask = strip.askAction {
                        Button(ask) { perform(ask) }
                            .buttonStyle(.grain(.outlined))
                    }
                }
            }
            .padding(.vertical, GrainSpacing.x3)
            .overlay(alignment: .bottom) { hairline }
        }
    }

    /// What this device DECLARED it can do — for a recorder, that it has storage of its own.
    /// There is no `Signal` column: RSSI is meaningful only while streaming.
    ///
    /// AND NO STRIP AT ALL when there is nothing true to put in it. This screen used to draw
    /// four rows for every device, so the iPhone's own microphone reported Battery, Firmware,
    /// Gap recovery and Offline storage as `Unavailable` — the `N/A · N/A · N/A` strip that
    /// started this track, respelled in the shipped word. Battery and firmware have left this
    /// strip entirely: they were never capabilities, they were readings with nowhere to live,
    /// and they are in `readingsStrip` above.
    @ViewBuilder
    private var capabilityStrip: some View {
        if !page.capabilities.isEmpty || page.capabilityNote != nil { capabilityLines }
    }

    private var capabilityLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(page.capabilities.enumerated()), id: \.offset) { _, line in
                HStack {
                    Text(line.label)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                    Spacer(minLength: GrainSpacing.x2)
                    Text(line.value)
                        .grainTextStyle(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(line.isAvailable ? GrainColor.ink : GrainColor.textFaint)
                }
                .padding(.vertical, GrainSpacing.x2)
                .accessibilityElement(children: .combine)
            }

            if let note = page.capabilityNote {
                Text(note)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, GrainSpacing.x2)
            }
        }
        .padding(.top, GrainSpacing.x2)
        .overlay(alignment: .bottom) { hairline }
    }

    /// The per-source availability toggle that used to live in the deleted CAPTURE SOURCES
    /// section. It belongs to ONE device, so it lives on that device's page — the control did
    /// not go away, the section it was sorted into did.
    @ViewBuilder
    private var captureToggle: some View {
        if let source = matchingSource, source.canToggle {
            Toggle(isOn: Binding(
                get: { source.enabled },
                set: { sources.setEnabled(source.id, $0); onChange() }
            )) {
                Text(RecordingDevicePage.captureToggleTitle)
                    .grainTextStyle(.body)
                    .foregroundStyle(GrainColor.ink)
            }
            .tint(GrainColor.forgeBlue)
            .padding(.vertical, GrainSpacing.x3)
            .overlay(alignment: .bottom) { hairline }
        }
    }

    private var matchingSource: CaptureSourceDescriptor? {
        if isSavedOmi {
            return sources.sources.first { $0.id == CaptureSourceDescriptor.omiId }
        }
        return sources.sources.first {
            UnifiedDeviceListComposition.identity(for: $0) == input.identity
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            ForEach(Array(page.actions.enumerated()), id: \.offset) { index, title in
                Button {
                    perform(title)
                } label: {
                    Text(title).frame(maxWidth: .infinity)
                }
                .buttonStyle(.grain(index == 0 ? .filled : .outlined))
            }
        }
        .padding(.top, GrainSpacing.x4)
    }

    /// WHAT THE RECORDER SAID IT IS HOLDING, rendered 1:1 from the kit's
    /// `StoredFileDeviceDetailPresentation` — the presentation that shipped with zero callers
    /// in `App/` while `features/pocket-file-pull-device.feature` asserted over it. Not one
    /// string here is invented in this body.
    ///
    /// IT DRAWS NOTHING UNTIL THE OWNER ASKS. A panel that appeared on its own would be this
    /// screen deciding to open a Bluetooth session every time somebody looked at it.
    /// THE SHELF'S HEADLINE: what a check is doing, or the reason it could not, or that the
    /// recorder answered and is holding nothing.
    ///
    /// IT IS ITS OWN BAND, ABOVE THE CONTROLS AND ABOVE THE LIST. Until this split, the title,
    /// the controls and the list were one `VStack` — which is why "bring one over" was drawn
    /// below however many recordings the recorder happened to be holding.
    @ViewBuilder
    private var shelfHeadline: some View {
        if check.isChecking || check.detail != nil || check.message != nil {
            VStack(alignment: .leading, spacing: 0) {
                Text(PocketRecorderCheckPresentation.sectionTitle)
                    .grainTextStyle(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(GrainColor.forgeBlue)
                    .padding(.bottom, GrainSpacing.x2)

                if check.isChecking {
                    HStack(spacing: GrainSpacing.x2) {
                        ProgressView().tint(GrainColor.forgeBlue)
                        Text(PocketRecorderCheckPresentation.checkingLine)
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textMuted)
                    }
                    .padding(.vertical, GrainSpacing.x2)
                }

                // A REASON, NEVER AN EMPTY PANEL. "The recorder answered and is holding
                // nothing" and "the app never reached the recorder" are different facts, and
                // rendering both as a blank list is how the second gets read as the first.
                if let message = check.message {
                    Text(message)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, GrainSpacing.x2)
                }

                // THE ANSWERED-AND-EMPTY CASE BELONGS TO THE HEADLINE, because when it is true
                // there are no rows at all and a list band drawn for it would be a heading over
                // nothing.
                if let detail = check.detail, detail.manifest.rows.isEmpty {
                    Text(PocketRecorderCheckPresentation.emptyLine)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, GrainSpacing.x2)
                }
            }
            .padding(.top, GrainSpacing.x6)
        }
    }

    /// EVERYTHING A PERSON CAN DO WITH WHAT THE RECORDER IS HOLDING, ABOVE THE LIST OF IT.
    ///
    /// These three were written inside the shelf's `VStack`, after the `ForEach` that draws a
    /// row per recording. On Nick's unit that put them under nineteen rows — far enough down
    /// that he reported the page as having no controls at all.
    @ViewBuilder
    private var shelfControls: some View {
        if check.detail != nil {
            VStack(alignment: .leading, spacing: 0) {
                bringOver
                fastSync
                removalReport
            }
        }
    }

    /// WHAT THE RECORDER SAID IT IS HOLDING, rendered 1:1 from the kit's
    /// `StoredFileDeviceDetailPresentation` — the presentation that shipped with zero callers
    /// in `App/` while `features/pocket-file-pull-device.feature` asserted over it. Not one
    /// string here is invented in this body.
    ///
    /// IT IS THE LAST BAND ON THE PAGE, and that is the whole point of `RecorderPageLayout`:
    /// it is the only band whose length is a property of somebody's hardware rather than of
    /// this design.
    @ViewBuilder
    private var shelfRows: some View {
        if let detail = check.detail {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(detail.manifest.rows.enumerated()), id: \.offset) { _, row in
                    // THE ROW IS THE CONTROL, AND UNTIL THIS IT WAS NOT ONE.
                    //
                    // THE DEFECT, MEASURED ON NICK'S OWN UNIT. This was a `VStack` of `HStack`s
                    // and the only interactive thing it ever carried was `Remove it from the
                    // recorder`, drawn behind `isOffered` — which is FALSE for all nineteen of
                    // his recordings, because not one of them has been brought over. So on the
                    // one device this page was built for, not a single row had a single
                    // interactive element: nineteen things a person could read and none they
                    // could touch.
                    //
                    // TAPPING IT OPENS THE PAGE ABOUT THAT RECORDING, which is also where the
                    // second half of the same gap is closed: `Bring over` takes
                    // `PocketBringOver.offeredNext`'s pick and there was no way to say "that
                    // one". The whole decision — what the page says, and which of the two
                    // actions this recording actually admits — is
                    // `PocketRecordingDetailPresentation`, in the kit, because a rule written
                    // in a body is a rule no test in this repository can read.
                    Button {
                        inspecting = row.id
                    } label: {
                    // TWO LINES, EACH WITH THE WHOLE WIDTH. What the recording IS on the
                    // first; where it is on the second.
                    //
                    // THE DEFECT THE PHOTOGRAPH CAUGHT, and it would have shipped unseen: the
                    // three places first went in a column beside the size, which left them
                    // half a screen to fit in, and SwiftUI wrapped them INSIDE THE WORDS —
                    // "Unknow / n", "Elsewhe / re", "Recor / der". Legible copy, illegible
                    // layout. They get the full width now, and each place is pinned to one
                    // line that scales down rather than breaking.
                    VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                        HStack(alignment: .firstTextBaseline, spacing: GrainSpacing.x3) {
                            Text(row.title)
                                .grainTextStyle(.body)
                                .foregroundStyle(GrainColor.ink)
                            Spacer(minLength: GrainSpacing.x2)
                            // THE RECORDER'S OWN KILOBYTES. This used to be `row.duration`,
                            // which divided them by an unmeasured 4,000 bytes/second and
                            // printed "44 min" on all nineteen of Nick's rows. Step 3 renamed
                            // the field precisely so this merge could not put the invented
                            // minutes back.
                            Text(row.size)
                                .grainTextStyle(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(GrainColor.textMuted)
                                .fixedSize()
                        }

                        // WHERE THIS RECORDING IS, ON EVERY ROW, IN THREE PLACES — AND ONCE
                        // EACH.
                        //
                        // THIS USED TO BE FOUR LINES FOR THREE FACTS. `row.presenceLabel`
                        // ("Only on the recorder") sat above the three `row.places` lines it
                        // is DERIVED FROM ("On the recorder: Yes - just now" and the rest),
                        // and every one of those lines was full width. Nineteen of those is
                        // the page Nick was shown. Not one of the three places is dropped —
                        // they are the evidence that deleting a recording is safe — so the
                        // derived summary is what left, and the places are on one line with
                        // the age they share stated once beneath.
                        HStack(alignment: .firstTextBaseline, spacing: GrainSpacing.x3) {
                            ForEach(Array(row.presenceBlock.chips.enumerated()),
                                    id: \.offset) { _, chip in
                                HStack(spacing: GrainSpacing.x1) {
                                    Text(chip.place)
                                        .foregroundStyle(GrainColor.textFaint)
                                    Text(chip.answer)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(chip.isHeld
                                                         ? GrainColor.ink
                                                         : GrainColor.textFaint)
                                }
                                .grainTextStyle(.caption)
                                // ONE LINE, ALWAYS. A place that wraps is a place that reads
                                // as two facts; scaling is the honest way to lose nothing.
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            }
                            Spacer(minLength: 0)
                        }

                        // THE SPINNER IS ON THE ROW THE OWNER TAPPED.
                        //
                        // NICK: "if I do go back to the home screen, well, it is loading, it
                        // should show the loading spinner on the specific recording that I
                        // clicked to bring over not just at the top." It could not: the model
                        // had one in-flight flag per KIND of errand and no subject on any of
                        // them, so a page-level spinner was the only honest thing to draw.
                        // WHICH row spins is `PocketErrandProgressPresentation`, in the kit,
                        // and a row only ever spins for ITS OWN recording — a row that spun
                        // for somebody else's transfer would be a lie about where the bytes
                        // are going.
                        if case .thisRecording(let line) = PocketErrandProgressPresentation
                            .progress(check.inFlight, for: row.id) {
                            HStack(spacing: GrainSpacing.x2) {
                                ProgressView().tint(GrainColor.forgeBlue)
                                Text(line)
                                    .grainTextStyle(.caption)
                                    .foregroundStyle(GrainColor.textMuted)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                        }

                        HStack(alignment: .firstTextBaseline, spacing: GrainSpacing.x3) {
                            if let age = row.presenceBlock.ageLine {
                                Text(age)
                                    .grainTextStyle(.caption)
                                    .foregroundStyle(GrainColor.textFaint)
                            }
                            Spacer(minLength: GrainSpacing.x2)
                            // THE DESTRUCTIVE CONTROL LEFT THE ROW, and it did not lose its
                            // gate on the way out. It was the row's only interactive element
                            // and it is drawn behind `isOffered`, so on a recorder where
                            // nothing has been brought over the row had nothing at all. It now
                            // lives on the page about ONE recording, still behind the SAME
                            // predicate — `PocketRecordingDetailPresentation.removalRefusal`
                            // calls `isOffered(for:)` rather than re-deriving it — and beside
                            // the sentence saying why it is absent, which the row never had.
                            //
                            // This is what says the row leads somewhere. It is a glyph rather
                            // than a word because the row already carries five facts and a
                            // sixth would be read as a sixth fact.
                            Image(systemName: "chevron.right")
                                .imageScale(.small)
                                .foregroundStyle(GrainColor.textFaint)
                        }
                    }
                    .padding(.vertical, GrainSpacing.x2)
                    // THE WHOLE ROW IS THE TARGET, not just the glyph and the words. Without
                    // this the gaps between the five facts are dead space in the middle of a
                    // control.
                    .contentShape(Rectangle())
                    // ^ the Button's LABEL ends here. The modifiers below belong to the Button
                    // itself, and the row's content is deliberately left at its original
                    // indentation so this change reads as "the same row, now pressable" rather
                    // than as ninety rewritten lines.
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    // THE ROW'S ADDRESS IS THE RECORDER'S OWN NAME FOR THE FILE. A combined
                    // accessibility element has a label assembled out of five facts, which is
                    // not something a proof can name; this is what lets the simulator run open
                    // a SPECIFIC row and assert what that row's page offers. It is an
                    // identifier, not a sentence — nothing renders it.
                    .accessibilityIdentifier(row.id)
                    .overlay(alignment: .bottom) { hairline }
                }

                Text(PocketRecorderCheckPresentation.sectionNote)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, GrainSpacing.x3)

                // WHERE THE COPY GOES, IN THE TERMS OF THE BRAIN THAT IS ON. On the phone-only
                // tier this says so, and does not borrow the computer's sentence for a
                // durability the code cannot deliver there.
                Text(PocketRecorderCheckPresentation.destinationNote(for: brain))
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, GrainSpacing.x2)
            }
            .padding(.top, GrainSpacing.x4)
        }
    }

    /// WHAT THE RECORDER ANSWERED WHEN IT WAS ASKED TO REMOVE SOMETHING.
    ///
    /// It reports THREE different nos - the recorder refused, the recorder said yes and the
    /// recording is still on it, or Solleva could not reach it at all - because those are three
    /// different things to do next. Every sentence comes from the kit.
    @ViewBuilder
    private var removalReport: some View {
        if check.isRemoving {
            HStack(spacing: GrainSpacing.x2) {
                ProgressView().tint(GrainColor.forgeBlue)
                Text(PocketRemoveFromRecorderPresentation.action)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
            }
            .padding(.top, GrainSpacing.x2)
        }
        if let outcome = check.removalMessage {
            Text(outcome)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, GrainSpacing.x2)
        }
    }

    /// THE OWNER-ARMED AUTOMATIC CLEAR - OFF BY DEFAULT, AND FOR THIS RECORDER ONLY.
    ///
    /// It is not offered at all on a brain with nowhere other than this phone to put a copy:
    /// on that tier nothing can ever satisfy the predicate, so a toggle would be a control that
    /// can never fire. The sentence beside it states, in itself, what "synced" is trusted to
    /// mean and WHICH destination satisfied it - and the line under it says out loud that
    /// turning it on does not reach back over what is already here.
    @ViewBuilder
    private var autoClearControl: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            if let explanation = PocketRemoveFromRecorderPresentation
                .autoClearExplanation(for: brain) {
                Toggle(isOn: Binding(
                    get: { check.autoClearArmed },
                    set: { check.setAutoClear($0, hardwareToken: input.identity.hardwareToken) }
                )) {
                    Text(PocketRemoveFromRecorderPresentation.autoClearTitle)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.ink)
                }
                .tint(GrainColor.forgeBlue)
                Text(explanation)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                Text(PocketRemoveFromRecorderPresentation.autoClearNotRetroactiveLine)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(PocketRemoveFromRecorderPresentation.autoClearUnavailableLine)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, GrainSpacing.x4)
        .onAppear { check.readAutoClear(hardwareToken: input.identity.hardwareToken) }
    }

    /// STARTING THE RECORDER OVER, WITH ITS COST, AND IT NEVER DISABLES ITSELF.
    ///
    /// It is the owner's recorder. A shelf reading that has gone stale is a reason to LOOK
    /// again - so it changes the PRIMARY ACTION to "Check the recorder first" and leaves the
    /// button enabled. An app that takes away the way out precisely when it is least sure is
    /// the shape this exists to refuse.
    @ViewBuilder
    private var resetGate: some View {
        let gate = PocketRecorderCostPresentation.resetGate(
            shelfObservedAt: check.shelfObservedAt, now: Date(), presences: check.presences)
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            Text(gate.cost)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if gate.primaryAction == PocketRecorderCostPresentation.checkFirstAction {
                    check.run(hardwareToken: input.identity.hardwareToken,
                              advertisedName: input.displayName,
                              library: manager.captureLibraryRoot,
                              stages: manager.captureStages(),
                              brain: brain)
                } else {
                    showingFactoryReset = true
                }
            } label: {
                Text(gate.primaryAction).frame(maxWidth: .infinity)
            }
            .buttonStyle(.grain(.outlined))
            .disabled(!gate.isEnabled)
        }
        .padding(.top, GrainSpacing.x4)
    }

    /// THE CALLER `PocketBLEClient.download` NEVER HAD.
    ///
    /// It offers ONE file — `PocketBringOver.offered`, the smallest on the newest day — because
    /// a long recording is hours over BLE and the first file anybody ever pulls off a Pocket
    /// should be one that finishes. There is no recording pill, no Live Activity and no live
    /// state touched anywhere below: the file existed on the recorder before this phone was
    /// involved, and `features/pocket-durable-sync.feature` holds that boundary.
    @ViewBuilder
    private var bringOver: some View {
        if check.offeredRecording != nil {
            Button {
                check.bringOver(hardwareToken: input.identity.hardwareToken,
                                advertisedName: input.displayName,
                                into: manager)
            } label: {
                Text(PocketBringOverPresentation.actionTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.grain(.outlined))
            // THE CONTROL AND THE SENTENCE UNDER IT NOW COME FROM THE SAME RULE.
            //
            // This read `.disabled(check.isBringingOver || check.isChecking)` — two of the
            // three busy flags — so during a REMOVAL it stayed live directly above a band
            // whose own words are "It can only do one at a time". A tap there began a second
            // errand, which overwrites `inFlight` and with it the identity of the errand
            // already running: the removal's row stopped spinning, this one's started, and the
            // single `finishErrand` that followed wrote one `errand.stop` under the wrong
            // subject and the wrong `about=`.
            .disabled(!PocketErrandProgressPresentation.admitsANewErrand(check.inFlight))
            .padding(.top, GrainSpacing.x3)

            // THE THIRD SURFACE, AND IT WAS THE ONE NICK WAS ACTUALLY LOOKING AT.
            //
            // This read `if check.isBringingOver` — true for ANY transfer — under a button
            // that offers exactly one file, `PocketBringOver.offered`'s pick. So asking for a
            // different recording from that recording's own page made this band say "Bringing
            // this recording over…" beneath a button about a file nothing was happening to.
            // It asks the SAME rule the row and the sheet ask, with the offered recording's
            // own token, so the three cannot disagree about which recording is moving. When
            // the errand is somebody else's it says so in words instead of spinning, which is
            // also the sentence that explains why the button above it is disabled.
            if let offered = check.offeredRecording {
                let progress = PocketErrandProgressPresentation
                    .bandProgress(check.inFlight,
                                  for: PocketRecordingDetailPresentation.fileToken(offered))
                if let line = progress.line {
                    HStack(spacing: GrainSpacing.x2) {
                        if progress.isThisRecording {
                            ProgressView().tint(GrainColor.forgeBlue)
                        }
                        Text(line)
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, GrainSpacing.x2)
                }
            }

            // WHAT HAPPENED, IN WORDS, INCLUDING WHEN NOTHING WAS KEPT. A bring-over that
            // silently did nothing is indistinguishable from one that worked.
            if let outcome = check.bringOverMessage {
                Text(outcome)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, GrainSpacing.x2)
            }
        }
    }

    /// THE ENTRY POINT `PocketFastSyncCoordinator` NEVER HAD.
    ///
    /// The coordinator, its six evidence gates, the recorder-side choreography and both
    /// entry points' copy all shipped months ago and were driven by eight green scenarios —
    /// while `grep FastSync App/*.swift` returned NOTHING and the reachability register said
    /// `unreachable`, "constructed only in its own feature test". This is the button.
    ///
    /// WHY IT CAN BE DISABLED AND STILL BE HERE. Nobody has ever confirmed the address a
    /// Pocket serves its files from (`PROTOCOL.md:149`, "HTTP endpoint: TBD"), and this phone
    /// can only join an access point where the hotspot entitlement is live. When either is
    /// missing the button says so IN WORDS underneath itself rather than disappearing: a
    /// capability that vanishes is indistinguishable from one that was never built, which is
    /// the exact confusion that let this stay unwired.
    @ViewBuilder
    private var fastSync: some View {
        if check.offeredRecording != nil {
            Button {
                check.fastSync(hardwareToken: input.identity.hardwareToken,
                               advertisedName: input.displayName,
                               into: manager,
                               brain: brain)
            } label: {
                Text(PocketFastSyncPresentation.settings.primaryAction)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.grain(.outlined))
            // THE FOURTH CONTROL, and the source gate found it rather than a reading did.
            //
            // It ORed the same two busy flags the bring-over button did, so during a REMOVAL it
            // was live — and `fastSync`'s own guard did refuse a removal, which makes this the
            // worse half of the pair: not a second errand, but a button that looks enabled and
            // whose tap is dropped in silence. Both spellings are now the one rule, so a
            // control and the entry point behind it cannot disagree about whether the radio is
            // free. The capability half — whether a fast sync can run here AT ALL — is a
            // different question and stays exactly where it was.
            .disabled(!PocketErrandProgressPresentation.admitsANewErrand(check.inFlight)
                      || !PocketRecorderCheckModel.fastSyncCanRun)
            .padding(.top, GrainSpacing.x2)

            Text(PocketRecorderCheckModel.fastSyncCanRun
                 ? PocketFastSyncPresentation.sheetWarning
                 // BEFORE ANY ATTEMPT, NOT AFTER ONE. This used to render the OUTCOME line,
                 // which says Solleva "used Bluetooth" and that "nothing was left switched on"
                 // — under a button that has never run, on a page where nothing was tried.
                 : PocketFastSyncPresentation.endpointUnmeasuredBeforeAnyAttemptLine)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, GrainSpacing.x2)
        }
    }

    private func perform(_ title: String) {
        switch title {
        case RecordingDevicePage.educationAction:
            showingEducation = true
        case PocketKeyCustodyPresentation.entryAction:
            showingKeyCustody = true
            checkForRecoveryCopy()
        case RecordingDevicePage.forgetAction:
            confirmingForget = true
        case RecordingDevicePage.disconnectAction:
            sources.setEnabled(CaptureSourceDescriptor.omiId, false)
            onChange()
        // A RECORD-THEN-SYNC RECORDER'S CONNECT IS NOT THE OMI'S, AND SHARING THIS BRANCH WAS
        // A LIVE HAZARD. `connectAndCheckAction` is only ever offered for `.recordThenSync`,
        // and this arm enabled the OMI capture source — so the moment a Pocket page got a
        // connect action, tapping it would have turned on a different device's live capture.
        // It was unreachable only because `canConnect` was hard-coded to `isSavedOmi`.
        case RecordingDevicePage.connectAndCheckAction:
            // THE SAFETY EVIDENCE, HANDED OVER AT THE CALL. Without it every row's "safe
            // elsewhere" is honestly `Unknown` and every recording counts toward the reset's
            // cost - which is the right default and the wrong answer for a phone that is in
            // fact holding them.
            check.run(hardwareToken: input.identity.hardwareToken,
                      advertisedName: input.displayName,
                      library: manager.captureLibraryRoot,
                      stages: manager.captureStages(),
                      brain: brain)
        case RecordingDevicePage.connectAction:
            if sources.isEnabled(CaptureSourceDescriptor.omiId) {
                device.reconnect()
            } else {
                sources.setEnabled(CaptureSourceDescriptor.omiId, true)
            }
            onChange()
        default:
            break
        }
    }

    /// §10 CUSTODY, READ ON DEMAND. The value comes out of the Keychain when the owner asks
    /// and goes into no message, no log and no outcome — the same discipline the key-entry
    /// field is held to. Tapping again hides it.
    private func toggleRevealedKey() {
        guard revealedKey == nil else {
            revealedKey = nil
            didCopyKey = false
            keyCustodyFoundNothing = false
            return
        }
        let token = input.identity.hardwareToken
        Task {
            guard let identity = try? PocketAuthenticatedIdentity(peripheralIdentifier: token)
            else { return }
            let held = await PocketKeyCustody().reveal(for: identity)
            revealedKey = held
            // ASKED AND FOUND NOTHING is a different sentence from "you haven't asked yet",
            // and it is the one a person restoring a phone from an old backup needs.
            keyCustodyFoundNothing = held == nil
        }
    }

    /// ASK THE STORE RATHER THAN ASSUME. Custody reports `.deviceOnly` whenever the recorder's
    /// broadcast name carries no per-unit serial or the synchronised write failed, and this
    /// screen used to promise iCloud recovery either way.
    private func checkForRecoveryCopy() {
        let name = input.displayName
        Task {
            recoveryCopyExists = await PocketKeyCustody()
                .hasRecoveryCopy(PocketRecoveryToken(advertisedName: name))
        }
    }

    private func copyRevealedKey() {
        guard let revealedKey else { return }
        UIPasteboard.general.string = revealedKey
        didCopyKey = true
    }

    private func forget() {
        // OFFERED ONLY FOR A DEVICE THE STORE REMEMBERS, so it cannot be a no-op behind a
        // destructive confirmation. Belt and braces: the action is absent otherwise.
        guard input.isRemembered else { return }
        if isSavedOmi {
            device.forget()
        }
        // A device the ACCOUNT remembers is forgotten from the account's own store too —
        // otherwise it is back on the next refresh.
        //
        // THE TASK INHERITS THE MAIN ACTOR ON PURPOSE. `onChange` is a main-actor callback
        // owned by the screen above; handing it to a DETACHED task makes it a `sending`
        // closure crossing an isolation boundary, which does not compile — and `swift test`
        // cannot compile `App/` to say so. Only the disk write is detached.
        let identity = input.identity
        let displayName = input.displayName
        Task {
            await Self.forgetInTheStore(identity)
            // AND BOTH CUSTODY RECORDS. "Forgetting this recorder deletes FoundryX's key for
            // it" is a promise on the confirmation alert, and a synchronised recovery copy
            // that outlived the attach record would keep the key on every one of the owner's
            // devices after they were told it was gone.
            if let pocketIdentity = try? PocketAuthenticatedIdentity(
                peripheralIdentifier: identity.hardwareToken) {
                await PocketKeyCustody().forget(
                    pocketIdentity,
                    recoveryToken: PocketRecoveryToken(advertisedName: displayName))
            }
            onChange()
        }
    }

    /// The store write, off the main actor: `current()` resolves the account binding (a
    /// process-wide lock plus an on-disk registry read) and then rewrites a JSON file.
    private static func forgetInTheStore(_ identity: RecordingDeviceIdentity) async {
        await Task.detached(priority: .utility) {
            try? RecordingDeviceStore.current()?.remove(identity)
        }.value
    }

    private var hairline: some View {
        Rectangle()
            .fill(GrainColor.borderFaint)
            .frame(height: 1)
    }
}

// MARK: - One recording, opened

/// THE PAGE ABOUT ONE RECORDING ON A RECORDER — the thing this app did not have.
///
/// WHAT IT IS FOR. The shelf is a list of what a recorder is holding, and a list is where a
/// person FINDS a recording. Until this existed there was nowhere to go from there: the row
/// carried one control, gated on a predicate false for every recording on the measured device,
/// and the page's own `Bring over` took `PocketBringOver.offeredNext`'s pick — so an owner
/// looking at the recording they made this morning had no way to ask for that one.
///
/// EVERY WORD AND EVERY DECISION IS `PocketRecordingDetailPresentation`. This body chooses
/// nothing: which of the two actions this recording admits, and the sentence explaining the one
/// it does not, are computed in the kit where `swift test` can hold them. The removal it offers
/// runs through the SAME `isOffered(for:)` the shelf row ran through and the same
/// `confirmation(for:)` the page-level alert used, moved here rather than copied — the
/// confirmation now lives on the view that owns the gesture, so there is one of it.
///
/// `page == nil` IS A STATE, NOT AN ERROR TO SWALLOW. The listing is restated on every check
/// while the safety readings are restated only on a check that reached the recorder, so one
/// good check followed by one failed one leaves rows with no readings behind them. The sheet
/// says so, in the line the removal path already earned for exactly that state, rather than
/// rendering an empty page with two dead buttons.
struct PocketRecordingDetailSheet: View {
    let page: PocketRecordingDetailPage?
    let brain: BrainChoice
    /// WHAT THE ERRAND IN FLIGHT MEANS FOR THIS RECORDING. One radio and one errand, so this
    /// is still "the page cannot ask for a second thing" — but it now knows whether the thing
    /// running is about the recording this page IS, which is the difference between showing
    /// the owner their transfer and greying a button out at them.
    let progress: PocketErrandProgress
    let onBringOver: (String) -> Void
    let onRemove: (String) -> Void
    let onClose: () -> Void

    /// PER-SHEET, AND A BOOL IS CORRECT HERE. On the page this had to be an ID, because one
    /// page has many rows and a Bool plus a "current row" is two pieces of state that can
    /// disagree on the one gesture that cannot be undone. This sheet IS one recording, so the
    /// identity is the sheet's and there is nothing for a second value to disagree with.
    @State private var confirmingRemoval = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GrainSpacing.x6) {
                if let page {
                    facts(of: page)
                    places(of: page)
                    actions(of: page)
                    notes(of: page)
                } else {
                    Text(PocketRemoveFromRecorderPresentation.cannotActOnThisNowLine)
                        .grainTextStyle(.body)
                        .foregroundStyle(GrainColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, GrainSpacing.x4)
            .padding(.vertical, GrainSpacing.x6)
        }
        .grainBackground()
        // THE SHEET IS ADDRESSABLE AS A CONTAINER, and this is not cosmetic. iOS keeps the
        // presenting page in the accessibility tree underneath a sheet, so a proof that asked
        // the APPLICATION whether "Bring over" is on screen was answered by the shelf's own
        // bring-over control sitting behind this one — measured, on the first simulator run of
        // this screen. Every assertion about what THIS page offers is scoped to this element.
        .accessibilityIdentifier("recording-detail-sheet")
        .navigationTitle(page?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(PocketRecordingDetailPresentation.closeAction) { onClose() }
            }
        }
        // IT ASKS FIRST, AND IT ASKS HERE. This alert used to hang off the whole recorder page
        // because the tap did; the tap moved, so it moved with it. Same three sentences, same
        // `confirmation(for:)` that names where the copy already is.
        .alert(PocketRemoveFromRecorderPresentation.action,
               isPresented: $confirmingRemoval) {
            Button(PocketRemoveFromRecorderPresentation.cancelConfirmAction,
                   role: .cancel) { confirmingRemoval = false }
            Button(PocketRemoveFromRecorderPresentation.confirmAction, role: .destructive) {
                confirmingRemoval = false
                guard let token = page?.fileToken else { return }
                onRemove(token)
                // THE SAME RULE THE TRANSFER CONSULTS, and it answers differently here: this
                // ends with the recording gone from the recorder, and this surface resolves
                // the page live — so staying would leave the owner reading "Solleva can't act
                // on that recording right now" as the reward for a deletion that worked.
                if !PocketRecordingDetailAction.removeFromRecorder.leavesThePageOpen {
                    onClose()
                }
            }
        } message: {
            Text(PocketRemoveFromRecorderPresentation.confirmation(for: brain))
        }
    }

    /// WHAT THE RECORDING IS: when it was made, how big it is, and the recorder's own name for
    /// it. All three are values the recorder reported; not one is a sentence this file wrote.
    @ViewBuilder
    private func facts(of page: PocketRecordingDetailPage) -> some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            ForEach(Array(page.facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .firstTextBaseline, spacing: GrainSpacing.x3) {
                    Text(fact.label)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                    Spacer(minLength: GrainSpacing.x2)
                    Text(fact.value)
                        .grainTextStyle(.body)
                        .foregroundStyle(GrainColor.ink)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    /// THE THREE PLACES, ONE PER LINE, EACH WITH ITS OWN AGE — the long form the shelf row had
    /// to give up to fit nineteen of itself on a screen. There is one recording here and no
    /// list to get past, so nothing is compressed.
    ///
    /// AND NO SUMMARY ABOVE THEM. `PocketPresencePresentation.label` is DERIVED from these
    /// three; drawing both is the same fact twice, which is the defect the row's own gate
    /// exists to catch. One recording does not make it acceptable.
    @ViewBuilder
    private func places(of page: PocketRecordingDetailPage) -> some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            Text(PocketRecordingDetailPresentation.placesHeading)
                .grainTextStyle(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(GrainColor.forgeBlue)
            ForEach(Array(page.places.enumerated()), id: \.offset) { _, line in
                Text(PocketPresencePresentation.oneLine(line))
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// ONLY THE ACTIONS THIS RECORDING ADMITS. The list comes from the kit; this body has no
    /// `if` of its own to get wrong, which is the whole reason the decision is over there.
    @ViewBuilder
    private func actions(of page: PocketRecordingDetailPage) -> some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x3) {
            // WHAT IS HAPPENING, WHERE THE OWNER ASKED FOR IT.
            //
            // NICK: "if I could click on an individual recording and click bring over, it
            // should show me the loading screen right there rather than taking me back to the
            // home screen." This sheet used to close itself the instant the transfer was asked
            // for, on the reasoning that the page behind it reports the errand — which is true
            // and is the wrong trade: the owner asked HERE. The spinner is for THIS recording
            // only; an errand about another one gets the sentence and no spinner, because a
            // spinner here would claim these bytes are moving and they are not.
            if let line = progress.line {
                HStack(spacing: GrainSpacing.x2) {
                    if progress.isThisRecording { ProgressView().tint(GrainColor.forgeBlue) }
                    Text(line)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(page.actions, id: \.self) { action in
                Button {
                    switch action {
                    case .bringItOver:
                        // THE OWNER SAID "THAT ONE".
                        onBringOver(page.fileToken)
                        // WHETHER THIS PAGE STAYS is `PocketRecordingDetailAction`'s rule, in
                        // the kit, because `swift test` cannot compile `App/`. A transfer
                        // keeps the page — its progress belongs where the tap was.
                        if !action.leavesThePageOpen { onClose() }
                    case .removeFromRecorder:
                        // A DESTRUCTIVE ACTION IS ONLY ASKED FOR ONCE IT IS CONFIRMED, so
                        // nothing closes here: the alert below is what carries it out and what
                        // applies the same rule afterwards.
                        confirmingRemoval = true
                    }
                } label: {
                    Text(action.title).frame(maxWidth: .infinity)
                }
                .buttonStyle(.grain(action.isDestructive ? .text : .filled))
                .disabled(progress.blocksAnAction)
            }
        }
    }

    /// WHY AN ACTION IS NOT HERE. The row's rule was "the predicate itself rather than a
    /// disabled button", which is right and was only half of it: nineteen rows offered nothing
    /// and said nothing about why. These are the sentences.
    @ViewBuilder
    private func notes(of page: PocketRecordingDetailPage) -> some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            ForEach(Array(page.notes.enumerated()), id: \.offset) { _, note in
                Text(note)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - "Connect and check now", and the session it opens

/// THE APP SIDE OF ONE CHECK.
///
/// It owns nothing but the tap: whether the radio is busy, what the recorder said, and the one
/// line a check that did not reach an answer earns. Every string comes from
/// `PocketRecorderCheckPresentation`; every decision comes from `PocketRecorderCheck`.
///
/// WHY THIS EXISTS AT ALL. `PocketBLEClient.listDates` / `listRecordings` shipped implemented
/// and unit-tested with NO caller outside `Tests/`, because the one path in the app that
/// reached an authenticated recorder closed the session before returning. This is the first
/// production caller of either, and the panel above is where their answer lands.
@MainActor
final class PocketRecorderCheckModel: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var detail: StoredFileDeviceDetailPresentation?
    @Published private(set) var message: String?

    /// THE BRING-OVER LIVES ON THIS MODEL RATHER THAN A SECOND ONE, because it is the same
    /// recorder, the same radio and the same panel: two models would be two ideas of whether
    /// the radio is busy, and the one thing this screen must never do is open a second session
    /// on top of a live one.
    @Published private(set) var isBringingOver = false
    @Published private(set) var bringOverMessage: String?

    /// THE ERRAND IN FLIGHT, AND WHICH RECORDING IT IS ABOUT.
    ///
    /// NICK, WATCHING HIS OWN PAGE: "if I could click on an individual recording and click
    /// bring over, it should show me the loading screen right there rather than taking me back
    /// to the home screen, and then if I do go back to the home screen, well, it is loading, it
    /// should show the loading spinner on the specific recording that I clicked to bring over
    /// not just at the top."
    ///
    /// THE THREE FLAGS ABOVE CANNOT DO THAT. `isBringingOver` says a transfer is running and
    /// says nothing about WHICH of nineteen recordings it is running for, so the only place a
    /// spinner could honestly go was the top of the page — and the sheet the owner tapped had
    /// to close itself and send them back there to see it. It is the same missing per-recording
    /// identity that made the rows inert.
    ///
    /// It is set at `beginErrand` and cleared at `finishErrand`, which are the ONE start and
    /// the ONE stop every errand on this page passes through, so a spinner cannot outlive the
    /// errand it belongs to. What a surface DRAWS from it is
    /// `PocketErrandProgressPresentation`, in the kit, because `swift test` cannot compile
    /// `App/` and a rule written in a SwiftUI body is a rule nothing here can hold.
    @Published private(set) var inFlight: PocketErrandInFlight?
    /// The file a tap would ask for, or `nil` when there is nothing to offer. It is the ONLY
    /// reason the check reads the unpresented shelf: durations and titles cannot be ordered.
    @Published private(set) var offeredRecording: PocketRecording?

    /// WHERE EVERY LISTED RECORDING IS, as of the last check. The reset's cost and the forget
    /// confirmation both read this, so the number a person is shown before a destructive
    /// gesture is the SAME reading the rows are drawn from - never a second count.
    /// nil ⇒ NOBODY HAS READ THIS RECORDER'S SHELF, which is the state every freshly opened
    /// page is in — nothing checks a recorder until the owner taps. It is DISTINCT from `[]`,
    /// a shelf that was read and is holding nothing, and keeping them distinct is what stops
    /// the Forget confirmation reassuring a person about a recorder Solleva never spoke to.
    @Published private(set) var presences: [PocketRecordingPresence]?
    /// When the recorder last answered a listing. `nil` means it never has on this screen, and
    /// a stale or absent reading changes the reset's primary action, never its enabled state.
    @Published private(set) var shelfObservedAt: Date?

    /// WHAT TO TELL WHEN AN ERRAND HAS FINISHED CHANGING THINGS.
    ///
    /// `RecorderPageModel` sets this and re-reads the account's facts for this recorder. It is
    /// a callback rather than a published flag on purpose: a flag has an EDGE, and an edge is a
    /// comparison somebody has to get the right way round in a SwiftUI body that nothing in
    /// this repository can execute. The shipped page did get it right (`guard !checking`) and
    /// inverting that one character shipped green through every gate this app has.
    var onErrandFinished: (() -> Void)?

    /// A REMOVAL IS IN FLIGHT. Same model as the check and the bring-over for the same reason:
    /// one radio, one idea of whether it is busy.
    @Published private(set) var isRemoving = false
    /// What the recorder answered, in words — including "it said yes and it is still there",
    /// which is the outcome a client that trusted the acknowledgement could not report.
    @Published private(set) var removalMessage: String?
    /// Whether THIS recorder's automatic clearing is armed. Read from the account's device
    /// record, which is where the ruling's "recorder-scoped" lives; `false` until read, which
    /// is also the correct default for a recorder nobody ever armed.
    @Published private(set) var autoClearArmed = false

    /// WHICH RECORDINGS THIS PHONE HAS PULLED OVER SINCE THIS SCREEN OPENED, and when.
    ///
    /// THIS IS WHAT MAKES THE ARMED CONTROL NON-RETROACTIVE STRUCTURALLY RATHER THAN BY
    /// PROMISE. Nothing in this app enumerates a recorder's shelf and clears what looks safe —
    /// the armed path is offered exactly one candidate set, the recordings the OWNER pulled
    /// over after arming, each with the instant its transfer landed. A backlog recording that
    /// nobody touched is not in this map, so no armed control can reach it, and that is a
    /// property of the data flow rather than of a check somebody has to remember to write.
    private var syncedThisSession: [String: Date] = [:]

    /// WHERE A BROUGHT-OVER FILE GOES, and what makes a row able to say "In Solleva". The
    /// check consults it too — a custody label that was not asked is a guess.
    private let custody = PocketRecorderFileStore()

    /// WHAT THE RECORDER LAST SAID IT IS HOLDING, in the protocol's own fields.
    ///
    /// This is the read model's SOURCE, and keeping it is what lets a bring-over restate the
    /// shelf without opening a second session for facts the first one already paid for. It is
    /// cleared whenever an errand starts, because a listing from a recorder we are in the
    /// middle of re-asking is not a listing.
    private var shelfRecordings: [PocketRecording] = []

    /// THE SAFETY EVIDENCE THE LAST CHECK WAS BUILT WITH, kept so a bring-over can restate the
    /// shelf with the SAME authority the session used. Rebuilding it from a second reading of
    /// the brain and the library would be a second opinion on "is this safe", and the delete
    /// ruling is explicit that two answers to that question is how a recording gets lost.
    private var durability: PocketCaptureDurability?
    /// WHAT THE SAFETY EVIDENCE IS BUILT FROM, kept so it can be built AGAIN.
    ///
    /// `PocketCaptureDurability` holds a SNAPSHOT of capture stages taken at check time. That
    /// is right for resolving one shelf cheaply and wrong for every question asked afterwards:
    /// a recording brought over AFTER the check cannot be in the snapshot, so its stage is nil
    /// forever and it can never become safe elsewhere on this page — no matter how long the
    /// drain runs. The shelf column said so, and the owner-armed clear, which reads the same
    /// reading, could therefore never clear the recording it was armed for.
    private var evidenceBasis: (library: URL, brain: BrainChoice)?

    /// THE RADIO THE IN-FLIGHT ERRAND IS HOLDING, and the Task driving it.
    ///
    /// THE DEFECT THESE CLOSE. Both used to be unnamed: the attachment was built inline as an
    /// argument and the Task was discarded, so nothing in the app had a reference to either.
    /// Navigating away mid-pull therefore left the Task running, the `CBCentralManager` open
    /// and the connection up, reporting to a screen that no longer existed — and the model
    /// went on believing it was checking, so the next tap was refused by its own busy guard.
    private var attachment: RecordingDeviceAttachment?
    private var errand: Task<Void, Never>?
    /// THE TRANSFER JOB, WHICH IS NOT THE PAGE'S AND NOT THIS MODEL'S EITHER.
    ///
    /// It is held so a genuine STOP — the system taking the background time back, or the owner
    /// walking away from an errand that must not outlive the screen — can reach the radio the
    /// queue opened. It is NOT held so a departure can kill it: `departed()` leaves a transfer
    /// running, and the errand's tail keeps its own strong hold on everything the conversation
    /// needs to land. `nil` whenever no transfer is in flight.
    private var transfers: PocketTransferQueue?
    /// Which errand is running (`shelf` / `bring-over`), and the token that makes
    /// `errand.stop` fire EXACTLY ONCE — whether the errand finished or the owner left.
    private var runningErrandSubject: String?

    /// THE BACKGROUND TIME AN ERRAND IS HOLDING.
    ///
    /// A bring-over is the slowest thing this app does — a Bluetooth file pull that can run for
    /// minutes — and the one thing a person reliably does while it runs is put the phone down.
    /// Without this the system suspends the process seconds after the app leaves the screen:
    /// the `CBCentralManager` callbacks stop, the `Task` never resumes, and the page comes back
    /// having quietly done nothing. Taken at `beginErrand` and released at `finishErrand`,
    /// which are the ONE start and the ONE stop every errand on this page passes through.
    private let lease: PocketBackgroundLease

    /// Whether an errand is currently protected. Read by `sceneChanged(to:)` and by the
    /// app-hosted scenarios, which is the only lane able to execute any of this.
    var isHoldingBackgroundTime: Bool { lease.isHeld }

    #if DEBUG
    /// THE SYSTEM'S BACKGROUND-TIME BUDGET IS THE SECOND THING A SCENARIO CANNOT OWN.
    ///
    /// Same seam, same reason and same `#if DEBUG` door as the radio above: a hermetic run
    /// cannot make iOS refuse an assertion or take one back, and those are exactly the two
    /// states the honest half of this fix is about. Everything else — when time is taken, that
    /// it is taken once, that every exit path gives it back — stays the shipped code.
    nonisolated(unsafe) static var backgroundTimeForScenarios: PocketBackgroundTime?
    #endif

    /// Test seam: how many times the shelf read model has been REBUILT. The acceptance
    /// instrument for this surface's command/query split, and the same idiom
    /// `CaptureManager.rebuildCountForTests` is (`Sources/FoundryXKit/CaptureManager.swift`):
    /// a stored, published read model whose recomputation has exactly one choke point, so
    /// "the view never recomputes the shelf on its own" is a number rather than a hope.
    /// Internal — reachable only from the app-hosted scenario bundle's `@testable import`.
    private(set) var shelfRebuildCountForTests = 0

    #if DEBUG
    /// THE RADIO IS THE ONE THING A SCENARIO CANNOT OWN, SO IT IS THE ONE THING INJECTED.
    ///
    /// Everything else this model touches — the check, the inventory read, the ordering that
    /// picks which file is offered, the presentation that turns an outcome into a sentence —
    /// stays the shipped code, running in the shipped app's process. What no hermetic run can
    /// have is a Bluetooth recorder, so the app-hosted scenario lane hands in an attachment
    /// built over `FakePocketBLEStack` (the same scripted radio the hostless suite drives) and
    /// changes nothing else.
    ///
    /// WHY NOT AN INITIALISER PARAMETER. This model is created by `@StateObject` inside the
    /// view that owns it, which is the arrangement that makes it survive redraws; threading a
    /// dependency through that would mean the shipping view carrying a parameter that exists
    /// only for tests. A DEBUG-only static is the seam this app already uses for the harness
    /// hooks it cannot avoid (`-SyntheticMic`, `-SyntheticOmi`, `CaptureAccountScope
    /// .setAccountForTests`), and `#if DEBUG` means the Release binary has no such door.
    nonisolated(unsafe) static var attachmentFactoryForScenarios:
        (@Sendable () -> RecordingDeviceAttachment)?
    #endif

    /// The production constructor. Every call site that is not the proof mount uses it, and it
    /// is the default argument of `RecordingDevicePageView.init`.
    init() {
        lease = PocketBackgroundLease(time: Self.backgroundTime())
        // THE SYSTEM TOOK THE TIME BACK. The lease has already handed the assertion in by the
        // time this runs — not doing so is what gets an app terminated — so the process is
        // about to be suspended and the errand cannot make progress. It STOPS, and says so,
        // rather than being frozen mid-transfer with the page claiming it is working.
        lease.onExpiry = { [weak self] in
            self?.cancel(outcome: PocketErrandScenePhasePolicy.stoppedWithoutBackgroundTimeToken)
        }
    }

    /// The background-time budget this model leases from: the system's, unless a scenario
    /// running inside a DEBUG build has supplied one.
    private static func backgroundTime() -> PocketBackgroundTime {
        #if DEBUG
        if let supplied = backgroundTimeForScenarios { return supplied }
        #endif
        return .live
    }

    #if DEBUG || PERF_HARNESS
    /// THE PROOF MOUNT'S CONSTRUCTOR — a model already in the state being photographed.
    ///
    /// The three states this page can be in are reached, in life, by a Bluetooth session with
    /// a recorder on the desk. A simulator has no radio, so a proof that had to CAUSE those
    /// states could photograph exactly one of them: the resting one. This sets the same
    /// published properties the live path sets, so the pictures are of the shipped body
    /// rendering the shipped presentation values, and only the cause is scripted.
    ///
    /// It sets no behaviour. `run` and `bringOver` are untouched, and a proof that taps
    /// anything gets the real code path or nothing.
    /// - Parameter proofShelfAnsweredAt: when the recorder answered the listing being
    ///   photographed. WITHOUT IT THE PICTURE CONTRADICTS ITSELF: the header states what a
    ///   check is doing, so a mount that hands over an answered shelf and no instant
    ///   photographs "Not checked yet" above a list of files the recorder just named.
    /// - Parameter proofShelf: the listing the panel was built from, and
    ///   `proofPresences`: where each of those recordings is, in the SAME order.
    ///
    ///   THEY ARE NOT DECORATION AND THE PICTURE IS WRONG WITHOUT THEM. The page about one
    ///   recording is resolved from these two — `detailPage(for:)` asks
    ///   `PocketRecordingDetailPresentation.located`, which pairs an id in the listing with the
    ///   reading at its index — and a mount that handed over a rendered panel and neither of
    ///   its sources photographs every row opening onto "Solleva can't act on that recording
    ///   right now". That is a real state and it is the WRONG one: it is what a page shows
    ///   after a failed check, not what a shelf that just answered shows.
    init(proofIsChecking: Bool = false,
         proofDetail: StoredFileDeviceDetailPresentation? = nil,
         proofMessage: String? = nil,
         proofOfferedRecording: PocketRecording? = nil,
         proofShelfAnsweredAt: Date? = nil,
         proofShelf: [PocketRecording] = [],
         proofPresences: [PocketRecordingPresence]? = nil) {
        // A PHOTOGRAPH RUNS NO ERRAND, so it never takes any time — but the lease must exist
        // or the model has a stored property this initialiser leaves unset.
        lease = PocketBackgroundLease(time: Self.backgroundTime())
        isChecking = proofIsChecking
        detail = proofDetail
        message = proofMessage
        offeredRecording = proofOfferedRecording
        shelfObservedAt = proofShelfAnsweredAt
        shelfRecordings = proofShelf
        presences = proofPresences
    }
    #endif

    /// The attachment this model opens sessions with: the production one unless a scenario
    /// running inside a DEBUG build has supplied a radio.
    /// - Parameter log: the DoorLog that already reaches the relay. NO DEFAULT, and that is
    ///   the fix. It defaulted to `nil` while its sibling 450 lines down this same file
    ///   defaulted to `.shared` — so the slowest and most failure-prone path in the app was
    ///   the one whose telemetry was thrown away. `RecordingDeviceAttachment` logs the exact
    ///   `RecordingDeviceUnreachableReason` a tap stopped on, and with `log: nil` every one of
    ///   those lines went nowhere; a required parameter is how that cannot recur by omission.
    /// `nonisolated` because `PocketTransferQueue.AttachmentFactory` is `@Sendable` and the
    /// queue builds a FRESH attachment per session from inside its own actor, off the main
    /// actor. Nothing here touches main-actor state: the DEBUG door is already
    /// `nonisolated(unsafe)` and the production branch is a constructor.
    nonisolated private static func makeAttachment(log: DoorLog) -> RecordingDeviceAttachment {
        #if DEBUG
        if let factory = attachmentFactoryForScenarios { return factory() }
        #endif
        return RecordingDeviceAttachment(log: log)
    }

    /// - Parameter hardwareToken: the DURABLE address of a stored-file recorder, which is the
    ///   authenticated peripheral identifier (`PocketAuthenticatedIdentity`) and never the
    ///   advertised name. A token that is not one is not a recorder this can reach, and it says
    ///   so rather than silently doing nothing.
    /// - Parameter library: the capture library this phone's conversations live in, so a row
    ///   can say a recording is SAFE ELSEWHERE from the `.lore-confirmed` marker the retention
    ///   sweep is written to preserve.
    /// - Parameter stages: a memory-only snapshot of what the app already knows about each
    ///   capture's upload stage - the predicate's floor. Taken on the main actor at the call
    ///   and resolved against off-main, so a shelf of N recordings costs no per-row hop.
    /// - Parameter brain: which brain is on. REQUIRED, with no default, because it is what
    ///   decides whether a segment upload-ack is evidence of anywhere other than this phone.
    ///   See `BrainChoice.uploadAckProvesAnotherPlace`.
    func run(hardwareToken: String, advertisedName: String,
             library: URL, stages: [String: CaptureStage], brain: BrainChoice) {
        guard PocketErrandProgressPresentation.admitsANewErrand(inFlight) else { return }
        guard let identifier = UUID(uuidString: hardwareToken) else {
            message = PocketRecorderCheckPresentation.notThisRecorderLine
            detail = nil
            offeredRecording = nil
            presences = nil
            shelfObservedAt = nil
            return
        }
        isChecking = true
        message = nil
        // INVALIDATION, NOT A REBUILD. A listing from a recorder we are in the middle of
        // re-asking is not a listing, so the read model goes to "unknown" rather than sitting
        // there stale. It is deliberately NOT counted as a rebuild: nothing was recomputed.
        detail = nil
        offeredRecording = nil
        shelfRecordings = []
        presences = nil
        shelfObservedAt = nil
        beginErrand(PocketErrandCommand.shelfSubject)
        // A FRESH ATTACHMENT PER CHECK. An attachment's `teardown()` retires its own link and
        // generation, so reusing one is a session that can never come back up. NAMED, rather
        // than built inline as an argument, because `cancel()` has to be able to reach it.
        let attachment = Self.makeAttachment(log: DoorLog.shared)
        self.attachment = attachment
        let custody = self.custody
        let identity = Self.custodyIdentity(for: hardwareToken)
        // THE SAFETY EVIDENCE, BUILT ONCE PER CHECK AND KEPT. `brain` is what withdraws the
        // stage floor on the phone-only tier, where an upload-ack means "durably on this
        // phone" and nothing more.
        let durability = PocketCaptureDurability(baseDir: library, stages: stages, brain: brain)
        self.durability = durability
        self.evidenceBasis = (library: library, brain: brain)
        errand = Task { [weak self] in
            // THE SHELF IS ASKED FOR HERE AND NOWHERE ELSE. Choosing which file to bring over
            // needs the recorder's own fields, not the row titles; reading it on a second
            // session would be a second Bluetooth connection for facts this one already had.
            let shelf = PocketRecorderShelfNote()
            let outcome = await PocketRecorderCheck.run(peripheralIdentifier: identifier,
                                                        advertisedName: advertisedName,
                                                        custody: custody,
                                                        durability: durability,
                                                        attachment: attachment,
                                                        shelf: shelf)
            // THE OWNER LEFT WHILE THIS RAN. `cancel()` has already torn the radio down, said
            // so in the command stream and released the screen's state; publishing here would
            // be an answer to a question nobody is still asking.
            guard let self, !Task.isCancelled else { return }
            self.errand = nil
            self.attachment = nil
            self.message = PocketRecorderCheckPresentation.message(for: outcome)
            self.shelfRecordings = shelf.recordings
            if case .checked(let panel) = outcome {
                // THE CHECK ALREADY RESOLVED EVERY PLACE, off the main actor, inside the
                // session. Re-resolving here would be a second answer to "is this safe", which
                // is the shape the delete ruling forbids — so the panel it built is STATED, not
                // recomputed. `rebuildShelf` exists for the other case: custody moved after the
                // session closed and nothing but this phone's disk can know it.
                await self.stateShelf(panel, identity: identity, presences: panel.manifest.rows.map(\.presence))
            }
            // BUSY UNTIL THE SHELF IS ACTUALLY RESTATED, and this order is load-bearing. The
            // shipped code dropped `isChecking` and THEN awaited the offer, so for one
            // suspension the page said the check was finished while it was still deciding what
            // to offer — a window in which the button is enabled over a shelf that is not
            // there yet. It also makes every observer of this flag race the offer.
            self.isChecking = false
            self.finishErrand(outcome: Self.token(for: outcome))
            // THE ARMED PATH RUNS ON A CHECK TOO, AND THAT IS WHAT MAKES IT WORK AT ALL.
            //
            // "Synced" means CONFIRMED, which is a state a recording reaches minutes after its
            // transfer finishes — the drain has to run and the upload has to be acknowledged.
            // So at the end of a bring-over the answer is always "not proven safe yet", and a
            // sweep that only ran there would clear nothing on the transfer it was armed for
            // and, on a shelf the owner never re-checks, nothing ever.
            //
            // A check re-takes the stage snapshot by construction, so this is the moment the
            // evidence can finally exist. The candidate set is unchanged and still tight: only
            // recordings THIS owner pulled over since the page opened, each put to the same
            // predicate an explicit tap meets.
            await self.clearWhatTheArmedControlAllows(hardwareToken: hardwareToken,
                                                      advertisedName: advertisedName)
        }
    }

    /// THE ONE PLACE THE SHELF READ MODEL IS RECOMPUTED.
    ///
    /// STORED, NEVER COMPUTED IN THE VIEW — the `CaptureManager.rebuildVisibleCaptures` idiom,
    /// and for the same reason: the custody column costs one disk stat per listed file, and a
    /// SwiftUI body that derived it would pay that on every invalidation. So it is recomputed
    /// when a COMMAND says custody moved, and at no other time.
    ///
    /// THE RE-READ CARRIES THE SAFETY EVIDENCE TOO. A bring-over that landed changes BOTH of a
    /// row's phone-side facts — this phone now holds it, and once the drain and finalize have
    /// run it becomes safe elsewhere — so re-reading without the evidence would redraw the row
    /// it just changed as `Unknown` and put the recording straight back into the reset's cost.
    /// It is the SAME `PocketShelfReadModel.presences` the session itself used, so the shelf
    /// after a transfer and the shelf during a check cannot disagree about whether a recording
    /// is safe. Two answers to that question is how a recording gets lost.
    /// RE-TAKE THE STAGE SNAPSHOT THE SAFETY PREDICATE STANDS ON.
    ///
    /// Called before every re-read that follows a transfer. `captureStages()` is an in-memory
    /// read on the main actor — the same call the check itself makes at its call site — so this
    /// costs no disk; what it buys is that a capture which landed since the check exists at all
    /// in the evidence the shelf is resolved against.
    private func refreshEvidence(from manager: CaptureManager) {
        guard let basis = evidenceBasis else { return }
        durability = PocketCaptureDurability(baseDir: basis.library,
                                             stages: manager.captureStages(),
                                             brain: basis.brain)
    }

    private func rebuildShelf(_ panel: StoredFileDeviceDetailPresentation,
                              identity: RecordingDeviceIdentity) async {
        let resolved = await PocketShelfReadModel.presences(shelfRecordings,
                                                            identity: identity,
                                                            custody: custody,
                                                            durability: durability,
                                                            askedAt: Date())
        await stateShelf(panel, identity: identity,
                         presences: shelfRecordings.map {
                             resolved["\($0.date)/\($0.timestamp)"] ?? .nothingAsked
                         })
    }

    /// THE ONE PLACE THE PAGE'S SHELF STATE IS PUBLISHED. Every field that describes the shelf
    /// moves together or not at all: a manifest whose rows disagree with `presences` is a page
    /// where the row says one thing and the reset's cost says another.
    private func stateShelf(_ panel: StoredFileDeviceDetailPresentation,
                            identity: RecordingDeviceIdentity,
                            presences: [PocketRecordingPresence]) async {
        shelfRebuildCountForTests += 1
        var byID: [String: PocketRecordingPresence] = [:]
        for (recording, presence) in zip(shelfRecordings, presences) {
            // BUILT, NOT INTERPOLATED — the same rule the bring-over's `fileToken` follows and
            // for the same reason: `features/voice-notes-language.feature` scans this file's
            // string LITERALS for retired words, and an interpolation carrying the identifier
            // `recording` reads to that lexer as user-facing copy about a "recording".
            byID[recording.date + "/" + recording.timestamp] = presence
        }
        detail = panel.withManifest(PocketInventoryReader.manifest(shelfRecordings,
                                                                   presences: byID))
        // THE SHELF WAS ANSWERED. Both facts come from the one reading: the cost of a reset,
        // and how old that cost is. A check that did NOT reach the recorder leaves both alone,
        // so a stale number is never redrawn as a fresh one.
        self.presences = presences
        self.shelfObservedAt = Date()
        // THE NEXT ONE, not the same one forever. `offered(_:)` is ordering only, and
        // ordering is stable — so bringing a file over and re-reading the shelf re-elected
        // the same winner, and a person with a backlog could bring over exactly one
        // recording per recorder for the life of the device, paying a Bluetooth session
        // each time to be handed the file they already had.
        //
        // Custody is the authority on what is already here; asking it is one disk read per
        // listed file and no radio time at all, and it is the SAME authority the bring-over
        // itself consults, so the shelf cannot disagree with the transfer about what we hold.
        self.offeredRecording = await PocketBringOver.offeredNext(
            shelfRecordings,
            custody: self.custody,
            identity: identity)
    }

    /// THE CUSTODY IDENTITY, DERIVED THE WAY CUSTODY ITSELF DERIVES IT.
    ///
    /// THE DEFECT THIS CLOSES, found by the scenario that counts sessions. Custody addresses a
    /// file by `PocketRecorderFileKey`, whose device component comes from
    /// `PocketAuthenticatedIdentity` — and that type LOWERCASES the peripheral identifier
    /// (`Sources/FoundryXKit/PocketOnboarding.swift:17`). This model was building
    /// `RecordingDeviceIdentity(shape:.filePull, hardwareToken:)` from the RAW token instead.
    /// Handed the uppercase form `UUID.uuidString` produces, every `alreadyHeld` question was
    /// asked about a device key custody has never written, so the answer was always no: the
    /// shelf claimed "Only on the recorder" for a file sitting on this phone, and
    /// `offeredNext` — the whole of the fix that stopped the recorder re-offering the same
    /// recording forever — excluded nothing and re-offered it anyway.
    ///
    /// One derivation, in one place, so the shelf cannot disagree with the transfer about what
    /// we hold. The fallback is unreachable for any token this model accepts (`run` has already
    /// parsed it as a UUID) and exists so this function is total rather than optional.
    private static func custodyIdentity(for hardwareToken: String) -> RecordingDeviceIdentity {
        (try? PocketAuthenticatedIdentity(peripheralIdentifier: hardwareToken))?
            .recordingDeviceIdentity
            ?? RecordingDeviceIdentity(shape: .filePull, hardwareToken: hardwareToken)
    }

    // MARK: - The command path

    /// `errand.start`, recorded before the radio is touched so a run that never came back is
    /// still legible as a run that was attempted.
    /// - Parameter about: the recorder's OWN name for the file this errand is for,
    ///   `<date>/<timestamp>`, or `nil` when the errand is about the recorder itself. It is
    ///   what puts the spinner on the row the owner tapped, and what lets the live log say
    ///   which of nineteen recordings a transfer that never came back was for.
    private func beginErrand(_ subject: String, about recording: String? = nil) {
        runningErrandSubject = subject
        inFlight = PocketErrandInFlight(subject: subject, recordingId: recording)
        // BACKGROUND TIME IS TAKEN HERE BECAUSE THIS IS WHERE EVERY ERRAND BEGINS. Five entry
        // points reach it — the check, the bring-over, both removal paths and the fast sync —
        // and taking the assertion at each of them instead would be four chances to forget.
        // A refusal is not an error: the errand runs unprotected, and `sceneChanged(to:)` then
        // reads that as "an actual departure stops this", which is the truth.
        lease.begin(subject: subject)
        DoorLog.shared.command(PocketErrandCommand.start, subject: subject, about: recording)
    }

    /// `errand.stop`, EXACTLY ONCE per start. Guarded by the subject token rather than by a
    /// flag on the Task, because the two ways an errand ends — it finished, or the owner walked
    /// away — both arrive here and only one of them may write.
    private func finishErrand(outcome: String) {
        // THE RELEASE IS OUTSIDE THE GUARD, AND THAT IS DELIBERATE. `errand.stop` is written
        // exactly once per start; the background time must be given back on EVERY path that
        // could possibly hold it, including one that raced the token. `end()` is silent when
        // nothing is held, and an assertion that outlives its errand is how iOS kills the app.
        lease.end()
        // THE SPINNER IS PUT OUT OUTSIDE THE GUARD, FOR THE SAME REASON THE TIME IS GIVEN BACK
        // OUTSIDE IT. A spinner that outlives its errand is this page's oldest defect wearing a
        // new hat — `isChecking` stuck true is what made the busy guard refuse every subsequent
        // tap forever — so every path that could possibly have set it clears it, including one
        // that raced the token.
        let recording = inFlight?.recordingId
        inFlight = nil
        guard let subject = runningErrandSubject else { return }
        runningErrandSubject = nil
        // THE STOP NAMES THE SAME RECORDING THE START DID, so a start and a stop can be paired
        // in the live log without counting lines — which is the only way to read a page that
        // ran five errands about four files.
        DoorLog.shared.command(PocketErrandCommand.stop, subject: subject,
                               about: recording, outcome: outcome)
        // AND THE PAGE GOES AND RE-READS WHAT THAT ERRAND CHANGED.
        //
        // THIS IS THE CHOKE POINT AND THAT IS WHY IT IS HERE. The page used to re-read on the
        // falling edge of `isChecking`, which covered exactly one of the five errands that
        // reach this function — so a REMOVAL, whose whole purpose is to reclaim room and which
        // re-reads how full the recorder is on its own session
        // (`PocketRecorderClearing.swift`, `recordObservedFacts` on `.removed`), wrote a fresh
        // free-space figure to the account's store while the one number the owner was staring
        // at sat frozen on the screen they were staring at it on.
        //
        // ONCE PER ERRAND, INSIDE THE TOKEN GUARD, so a cancel that raced the finish cannot
        // fire it twice — and an errand that never started cannot fire it at all.
        onErrandFinished?()
    }

    /// A CLOSED TOKEN, never the diagnostic sentence. The wire form is space-separated
    /// `key=value`, so an outcome carrying spaces would corrupt every parser downstream — and
    /// the reason in full is already an `error` entry written by `RecordingDeviceAttachment`.
    private static func token(for outcome: PocketRecorderCheckOutcome) -> String {
        switch outcome {
        case .checked:              return DoorLog.succeeded
        case .inventoryFailed:      return "inventory-refused"
        case .unavailable(let attach):
            switch attach {
            case .unreachable:      return "unreachable"
            case .live, .unrecognised, .adopted, .adoptionNotPersisted:
                return "not-this-recorder"
            default:                return "setup-unavailable"
            }
        }
    }

    // THE BRING-OVER'S TOKEN MAPPING USED TO BE HERE, over a `PocketBringOverOutcome`. The
    // transfer is a queue now and what it ends on is a `PocketTransferPhase`, so the mapping
    // moved to `PocketTransferFollowThrough` in the kit — where, unlike here, a test can
    // execute it.

    /// EVERY OUTCOME OF A REMOVAL GETS ITS OWN TOKEN, and the three that are not a success are
    /// three DIFFERENT diagnoses: the owner had no proof, the recorder said no, or the recorder
    /// said yes and kept the file. Folding them into one word is how "it didn't work" becomes
    /// unanswerable at three in the morning.
    /// The command path's word for a fast sync. It exists for the same reason the other three
    /// do: `finishErrand` records an outcome, and a leg with no mapping cannot be told apart in
    /// the log from one that never ran.
    static func token(for outcome: PocketFastSyncOutcome) -> String {
        switch outcome {
        case .completed:            return DoorLog.succeeded
        case .keptBluetooth:        return "kept-bluetooth"
        case .paused:               return "paused"
        case .cancelled:            return "cancelled"
        case .unavailable(let gap): return "unavailable:\(gap.rawValue)"
        case .failed(let gap):      return "failed:\(gap.rawValue)"
        }
    }
    private static func token(for outcome: PocketRemovalOutcome) -> String {
        switch outcome {
        case .removed:               return DoorLog.succeeded
        case .notProvenSafe:         return "not-proven-safe"
        case .theRecorderRefused:    return "recorder-refused"
        case .stillListedAfterwards: return "still-listed"
        case .unavailable:           return "recorder-unavailable"
        case .failed:                return "removal-failed"
        }
    }

    /// THE SCREEN WENT AWAY MID-ERRAND.
    ///
    /// Mirrors `RecordingDeviceAttachModel.cancel()` and closes the same hole one layer over:
    /// this model held no reference to either the attachment or the Task, so leaving the
    /// recorder page mid-pull left a `CBCentralManager` connected to a device nobody was
    /// looking at, a Task publishing into a dead screen, and `isChecking` stuck true — which
    /// the model's own busy guard then read as "a check is already running" forever.
    ///
    /// Idempotent, and silent when there is nothing to stop: `onDisappear` and a `scenePhase`
    /// drop can both fire for one departure.
    /// - Parameter outcome: the closed token the command record carries. It defaults to the
    ///   deliberate departure, and the scene path passes its own so a transfer that ran out of
    ///   background time can be told apart in the log from one the owner walked away from.
    /// THE OWNER LEFT THE PAGE, AND WHAT THAT MEANS DEPENDS ON THE ERRAND.
    ///
    /// Wiring only: it asks `PocketErrandDeparturePolicy` and does what it says. The asymmetry
    /// it implements — a check stops, a transfer does not — is the surface half of "a bring-over
    /// is a durable queued job", and the reason it is not a comparison written in the
    /// `.onDisappear` above is that `swift test` cannot compile `App/`.
    func departed() {
        // THE SECOND ARGUMENT IS A FACT, NOT A DECISION. `transfers` is non-nil exactly while a
        // `PocketTransferQueue` is driving this errand, which is what tells a durable Bluetooth
        // transfer apart from the fast sync that shares its subject token.
        switch PocketErrandDeparturePolicy.decide(inFlight, isDurableJob: transfers != nil) {
        case .stopTheErrand:
            cancel()
        case .leaveItRunning:
            // NOTHING, AND THAT IS THE CHANGE. The queue owns its own radio and its own task;
            // this model holds neither for a transfer, so there is nothing here to release and
            // nothing to tear down. The errand's tail keeps its strong hold on the capture
            // owner, so the conversation is adopted whether or not this page comes back.
            return
        }
    }

    func cancel(outcome: String = "left-the-page") {
        // UNCHANGED, AND ON PURPOSE. A removal or a fast sync in flight is NOT stopped here —
        // it never was — and it must not have its background time taken away either, or
        // walking away would suspend the very errand this guard declines to cancel. Every
        // errand releases through `finishErrand`.
        guard isChecking || isBringingOver else { return }
        // A STOPPED TRANSFER SAYS SO. `left-the-page` is a closed LOG token and is never
        // rendered; without this line the owner who locked their phone during an hours-long
        // pull comes back to a page showing nothing happened and no reason why. Only the
        // bring-over earns a sentence: a stopped CHECK costs nothing and leaves the page in
        // exactly the state a person who has not tapped anything expects.
        if isBringingOver { bringOverMessage = PocketBringOverPresentation.leftTheRecorderLine }
        errand?.cancel()
        errand = nil
        attachment?.teardown()
        attachment = nil
        // AND THE QUEUE, WHICH OWNS ITS OWN RADIO. Cancelling the Task above does not reach
        // inside the actor — the per-file work is unstructured by construction — so a stop that
        // did not say so here would leave a `CBCentralManager` connected and bytes landing for
        // an errand this model has already declared over. `stopAll()` is the queue's own stop:
        // it cancels the work, THEN tears the session down, and custody discards the partial.
        if let transfers {
            self.transfers = nil
            Task { await transfers.stopAll() }
        }
        isChecking = false
        isBringingOver = false
        finishErrand(outcome: outcome)
    }

    /// THE APP MOVED, AND WHAT THAT MEANS FOR AN ERRAND IN FLIGHT.
    ///
    /// THE DEFECT THIS REPLACES was one comparison in the view — `if phase != .active {
    /// check.cancel() }` — and iOS reports `.inactive` for a SCREENSHOT, Control Center, the
    /// app switcher and a notification banner. So photographing the progress killed the
    /// transfer, which is exactly what Nick hit on his own phone with recordings waiting.
    ///
    /// The rule itself is `PocketErrandScenePhasePolicy`, in the kit, because `swift test`
    /// cannot compile `App/` and a decision written in a SwiftUI body is a decision nothing can
    /// hold. What is left here is the wiring: ask, and do what it says.
    func sceneChanged(to phase: PocketErrandScenePhase) {
        switch PocketErrandScenePhasePolicy.decide(phase: phase,
                                                   isHoldingBackgroundTime: lease.isHeld) {
        case .carryOn:
            return
        // NOT HOLDING TIME AND NO LONGER ON SCREEN. The process is about to be suspended
        // whatever this model wants, so the errand stops and says so — with its OWN token, so
        // the log can tell "the system would not let it finish" from "the owner walked away".
        case .stopTheErrand:
            cancel(outcome: PocketErrandScenePhasePolicy.stoppedWithoutBackgroundTimeToken)
        }
    }

    /// ONE FILE, ON ONE SESSION, AND THE SHELF RESTATED FROM THIS PHONE'S OWN DISK.
    ///
    /// WHAT THIS USED TO DO AND WHY IT WAS WRONG. It ended by calling `self.run(…)` — a second
    /// full attach (power-on gate, connect, discovery, key handshake), a second `LIST_DIRS` and
    /// a second `LIST&` per day — to learn ONE fact the phone's own disk already knew: that the
    /// file it had just written is here. One tap therefore cost TWO authenticated sessions, and
    /// the second asked the recorder a question whose answer could not have changed.
    ///
    /// The re-read is still not cosmetic — custody is the only thing that knows whether the
    /// file landed, so the row's "In Solleva" still comes from asking the disk rather than from
    /// this method having been optimistic. It just asks the DISK, which is the authority, and
    /// not the radio, which is not.
    /// - Parameter manager: the capture owner the finished conversation is handed to. Without
    ///   this the recording would be a complete, correct, pending-finalize capture directory
    ///   that NOTHING in the running app knows exists — `loadExisting()` runs once, at
    ///   construction — so it would sit there un-uploaded until the next launch. Handing it
    ///   over is one call, and it is the only line of this whole leg that is about the app
    ///   rather than about the recording.
    func bringOver(hardwareToken: String, advertisedName: String, into manager: CaptureManager) {
        guard let recording = offeredRecording else { return }
        bringOver(recording: recording, hardwareToken: hardwareToken,
                  advertisedName: advertisedName, into: manager)
    }

    /// THE OWNER ASKED FOR THAT ONE.
    ///
    /// THE DEFECT THIS CLOSES. The only bring-over this app had took
    /// `PocketBringOver.offeredNext`'s pick — smallest first, minus what this phone holds —
    /// which is a good default and was the ONLY thing anybody could ask for. A person looking
    /// at the recording they made this morning could not ask for it; they could ask for
    /// whatever the comparator elected, once, and then again.
    ///
    /// - Parameter id: the recorder's OWN name for the file, `<date>/<timestamp>`, carried from
    ///   the row rather than re-derived from a title. The lookup is
    ///   `PocketRecordingDetailPresentation.located`, which is the SAME call the detail page
    ///   was built from — so the recording that gets asked for is the one the sheet was
    ///   describing, not whatever shares its index.
    ///
    /// EVERY EXIT SAYS SOMETHING, like the removal's. A shelf that cannot answer for this id is
    /// reachable — the listing is restated on every check while the readings are restated only
    /// on a check that reached the recorder — and a tap that returned in silence there would be
    /// a control that looks live, does nothing, and explains nothing.
    func bringOver(id: String, hardwareToken: String, advertisedName: String,
                   into manager: CaptureManager) {
        guard let found = PocketRecordingDetailPresentation.located(id,
                                                                    among: shelfRecordings,
                                                                    presences: presences) else {
            bringOverMessage = PocketRemoveFromRecorderPresentation.cannotActOnThisNowLine
            return
        }
        bringOver(recording: found.recording, hardwareToken: hardwareToken,
                  advertisedName: advertisedName, into: manager)
    }

    /// EVERYTHING KNOWN ABOUT ONE LISTED RECORDING, AND THE ACTIONS IT ADMITS.
    ///
    /// `nil` when the shelf cannot answer for this id, which the sheet renders as the line that
    /// says so. Nothing is decided here: the whole page is
    /// `PocketRecordingDetailPresentation.page`, in the kit, where `swift test` can hold it.
    func detailPage(for id: String,
                    brain: BrainChoice,
                    now: Date = Date()) -> PocketRecordingDetailPage? {
        guard let found = PocketRecordingDetailPresentation.located(id,
                                                                    among: shelfRecordings,
                                                                    presences: presences)
        else { return nil }
        return PocketRecordingDetailPresentation.page(for: found.recording,
                                                      presence: found.presence,
                                                      brain: brain,
                                                      now: now)
    }

    private func bringOver(recording: PocketRecording, hardwareToken: String,
                           advertisedName: String, into manager: CaptureManager) {
        guard PocketErrandProgressPresentation.admitsANewErrand(inFlight) else { return }
        guard let identifier = UUID(uuidString: hardwareToken) else {
            bringOverMessage = PocketRecorderCheckPresentation.notThisRecorderLine
            return
        }
        isBringingOver = true
        bringOverMessage = nil
        // THE ERRAND CARRIES THE RECORDING IT IS FOR. Not the offered pick and not an index —
        // the recorder's own name for the file the owner actually asked for, which is what
        // puts the spinner on their row instead of at the top of the page.
        // BUILT, NOT INTERPOLATED. `features/voice-notes-language.feature` scans this file's
        // string LITERALS for retired words, and an interpolation carrying the identifier
        // `recording` reads to that lexer as user-facing copy about a "recording". The token is
        // the recorder's own name for the file either way.
        let fileToken = recording.date + "/" + recording.timestamp
        beginErrand(PocketErrandCommand.bringOverSubject, about: fileToken)
        let custody = self.custody
        let identity = Self.custodyIdentity(for: hardwareToken)
        let panel = detail
        // THE TRANSFER IS A JOB, NOT A FIELD ON THIS SCREEN.
        //
        // THIS USED TO BE `PocketBringOver.run` — one file, one session, no retry, no progress
        // and no stop — with the attachment parked on `self` so `cancel()` could kill it, which
        // is precisely what leaving the page did. `PocketTransferQueue` owns its OWN attachment
        // per session (a torn-down one is retired permanently, so reusing one is the flap
        // shape), retries a lost recorder on the shipped 60/120/240/300 presence schedule, and
        // reports progress denominated in the recorder's own `MCU&U&` announcement. Not one of
        // those decisions is made here; this is the construction and the hand-off.
        let queue = PocketTransferQueue(
            peripheralIdentifier: identifier,
            advertisedName: advertisedName,
            custody: custody,
            // THE OWNER'S OWN LIBRARY, ASKED FOR RATHER THAN GUESSED. The conversation must land
            // in the directory this manager hydrates from; resolving it independently happens to
            // agree today and is not guaranteed to.
            destination: .init(baseDir: manager.captureLibraryRoot),
            makeAttachment: { Self.makeAttachment(log: DoorLog.shared) })
        self.transfers = queue
        let reporter = PocketTransferProgressReporter()
        errand = Task { [weak self] in
            // EVERY PHASE THIS SCREEN IS ENTITLED TO SEE, and no more. The sink is called
            // synchronously on the radio path — roughly a reading per BLE notification — so the
            // coalescing rule decides what is worth a `@Published` write, in the kit, where it
            // can be executed.
            await queue.observePhases { [weak self] _, phase in
                guard reporter.admit(phase) else { return }
                Task { @MainActor in
                    self?.bringOverMessage = PocketTransferQueuePresentation.line(for: phase)
                }
            }
            await queue.enqueue([recording])
            await queue.run()
            // WHAT THE QUEUE ENDED UP SAYING ABOUT THIS ONE RECORDING. A queue that lost its
            // item cannot have finished it, and reporting silence there would be the inert-tap
            // shape every other exit on this page was written to refuse.
            let phase = await queue.snapshot.first?.phase
                ?? .failed(PocketBringOverPresentation.transferIncompleteLine)
            let follow = PocketTransferFollowThrough.decide(phase)

            // THE DURABLE HALF, AND IT IS OUTSIDE `guard let self` ON PURPOSE. This is the
            // hand-off that makes the recording exist for the running app: without it the
            // conversation is a complete, correct capture directory nothing knows about —
            // `loadExisting()` runs once, at construction — and it sits un-uploaded until the
            // next launch. It used to sit BEHIND `guard let self, !Task.isCancelled`, so
            // leaving the page mid-transfer lost the conversation even when every byte landed.
            if let captureID = follow.adoptCaptureID {
                manager.adoptCompletedCapture(captureId: captureID)
                // CUSTODY MOVED, AND THAT IS WHAT INVALIDATES THE SHELF. The command is
                // recorded first and the read model recomputed second, so the record of what
                // happened cannot be lost to whatever the recompute does next.
                DoorLog.shared.command(PocketErrandCommand.custodyCommit,
                                       subject: fileToken,
                                       outcome: DoorLog.succeeded)
            }

            // THE PAGE HALF. Skipped when there is no page — which is not a failure, it is the
            // whole point of the errand outliving one.
            guard let self else { return }
            self.errand = nil
            self.attachment = nil
            self.transfers = nil
            self.bringOverMessage = follow.line
            if follow.custodyMoved {
                // THE SYNC INSTANT, RECORDED BEFORE ANYTHING READS IT. The armed control's
                // candidate set is exactly this map, and its whole job is to answer "did this
                // land after the owner armed this recorder".
                self.syncedThisSession[fileToken] = Date()
                // THE EVIDENCE IS RE-TAKEN BEFORE THE SHELF IS RE-READ. Without this the row
                // for the recording that just landed is resolved against a snapshot taken
                // before it existed.
                self.refreshEvidence(from: manager)
                if let panel { await self.rebuildShelf(panel, identity: identity) }
            }
            // BUSY UNTIL THE SHELF HAS CAUGHT UP — see the same note in `run`. Dropped before
            // the rebuild, the page would offer a "Bring it over" button over a shelf that
            // still names the file it has just finished bringing over.
            self.isBringingOver = false
            self.finishErrand(outcome: follow.outcomeToken ?? "transfer-incomplete")
            // THE ARMED PATH, AND IT RUNS ONLY AFTER THE RADIO IS FREE. It clears nothing on
            // its own beyond the one recording the owner just pulled over, and only if that
            // recording's own shelf reading now says Solleva holds it somewhere else.
            await self.clearWhatTheArmedControlAllows(hardwareToken: hardwareToken,
                                                     advertisedName: advertisedName)
        }
    }

    // MARK: - Taking a recording off the recorder

    /// READ THIS RECORDER'S ARMED CONTROL. Called when the page appears, so a toggle can draw
    /// its real state instead of a default that happens to look like one.
    func readAutoClear(hardwareToken: String) {
        autoClearArmed = RecordingDeviceStore
            .autoClear(for: Self.custodyIdentity(for: hardwareToken)).isArmed
    }

    /// THE OWNER ARMED — OR DISARMED — THIS ONE RECORDER.
    ///
    /// The instant is written on arming and DISCARDED on disarming, so switching it off and on
    /// again cannot inherit an older arming and reach back over everything that synced in
    /// between. It writes one record: arming the recorder you carry daily does not arm the one
    /// holding something you have not filed yet.
    func setAutoClear(_ armed: Bool, hardwareToken: String) {
        let identity = Self.custodyIdentity(for: hardwareToken)
        guard let store = RecordingDeviceStore.current() else { return }
        do {
            if armed { try store.armAutoClear(identity, at: Date()) }
            else { try store.disarmAutoClear(identity) }
            autoClearArmed = (try? store.autoClear(for: identity).isArmed) ?? false
        } catch {
            // FAIL CLOSED AND SAY SO. A control that could not be written must not draw as on.
            autoClearArmed = false
            removalMessage = PocketRemoveFromRecorderPresentation.notProvenSafeLine
        }
    }

    /// TAKE ONE RECORDING OFF THE RECORDER, BECAUSE A PERSON TAPPED IT.
    ///
    /// - Parameter id: the recorder's OWN name for the file, `<date>/<timestamp>`, carried on
    ///   the row rather than re-derived from a title or from a row's position in an array. This
    ///   firmware spells its timestamps two different ways on one device and the spelling has
    ///   to reach the wire verbatim.
    ///
    /// THE SAFETY READING IS THE ONE THE ROW WAS DRAWN FROM. It is looked up out of
    /// `presences` — the published read model — and handed straight to the errand, which hands
    /// it to `PocketDeleteConsent`'s failable factory. Nothing here recomputes it.
    func removeFromRecorder(id: String, hardwareToken: String, advertisedName: String) {
        guard PocketErrandProgressPresentation.admitsANewErrand(inFlight) else { return }
        // EVERY EXIT SAYS SOMETHING. This guard used to `return` in silence, and the state it
        // catches is REACHABLE: `shelfRecordings` is restated on EVERY check while `presences`
        // and `detail` are only restated on a check that reached the recorder, so one good
        // check followed by one failed one leaves the page drawing the old rows over no
        // readings. Every tap on the destructive button then did nothing and explained nothing.
        guard let index = shelfRecordings.firstIndex(where: {
            $0.date + "/" + $0.timestamp == id
        }), let presence = presences?[safe: index] else {
            removalMessage = PocketRemoveFromRecorderPresentation.cannotActOnThisNowLine
            return
        }
        guard let identifier = UUID(uuidString: hardwareToken) else {
            removalMessage = PocketRecorderCheckPresentation.notThisRecorderLine
            return
        }
        let recording = shelfRecordings[index]
        isRemoving = true
        removalMessage = nil
        beginErrand(PocketErrandCommand.removalSubject, about: id)
        let attachment = Self.makeAttachment(log: DoorLog.shared)
        self.attachment = attachment
        let identity = Self.custodyIdentity(for: hardwareToken)
        let panel = detail
        errand = Task { [weak self] in
            let outcome = await PocketRemoveFromRecorder.run(
                peripheralIdentifier: identifier,
                advertisedName: advertisedName,
                recording: recording,
                presence: presence,
                provenance: .ownerChose,
                attachment: attachment)
            guard let self, !Task.isCancelled else { return }
            self.errand = nil
            self.attachment = nil
            self.removalMessage = PocketRemoveFromRecorderPresentation.message(for: outcome)
            await self.absorb(outcome, of: recording, panel: panel, identity: identity)
            self.isRemoving = false
            self.finishErrand(outcome: Self.token(for: outcome))
        }
    }

    /// THE ARMED CONTROL'S ONE PRODUCTION CALLER.
    ///
    /// It considers ONLY recordings this owner pulled over since the screen opened — never the
    /// shelf — so nothing here can reach a backlog nobody touched. Each candidate is put to the
    /// SAME predicate an explicit tap meets, with the instant its transfer actually landed, and
    /// `PocketAutoClear.decision` refuses anything that synced before the control was armed.
    private func clearWhatTheArmedControlAllows(hardwareToken: String,
                                                advertisedName: String) async {
        guard PocketErrandProgressPresentation.admitsANewErrand(inFlight) else { return }
        guard let identifier = UUID(uuidString: hardwareToken) else { return }
        let identity = Self.custodyIdentity(for: hardwareToken)
        let control = RecordingDeviceStore.autoClear(for: identity)
        guard control.isArmed else { return }
        guard let presences else { return }
        for (index, recording) in shelfRecordings.enumerated() {
            guard let presence = presences[safe: index] else { continue }
            let token = recording.date + "/" + recording.timestamp
            guard let syncedAt = syncedThisSession[token] else { continue }
            guard control.decision(syncedAt: syncedAt, presence: presence) == .clears else {
                continue
            }
            isRemoving = true
            beginErrand(PocketErrandCommand.removalSubject, about: token)
            let attachment = Self.makeAttachment(log: DoorLog.shared)
            self.attachment = attachment
            let panel = detail
            let outcome = await PocketRemoveFromRecorder.run(
                peripheralIdentifier: identifier,
                advertisedName: advertisedName,
                recording: recording,
                presence: presence,
                provenance: .ownerArmedThisRecorder,
                attachment: attachment)
            self.attachment = nil
            removalMessage = PocketRemoveFromRecorderPresentation.message(for: outcome)
            await absorb(outcome, of: recording, panel: panel, identity: identity)
            isRemoving = false
            finishErrand(outcome: Self.token(for: outcome))
            // ONE AT A TIME, like every other errand this screen runs. A loop that opened a
            // session per recording without letting the first one settle is the shape the
            // transfer contract already refuses.
            break
        }
    }

    /// WHAT A REMOVAL CHANGES ON THIS PAGE. Only a recording that is genuinely gone leaves the
    /// shelf — a refusal and a "it said yes and it is still there" both leave the row where it
    /// is, because it is still on the recorder.
    private func absorb(_ outcome: PocketRemovalOutcome,
                        of recording: PocketRecording,
                        panel: StoredFileDeviceDetailPresentation?,
                        identity: RecordingDeviceIdentity) async {
        guard case .removed = outcome else { return }
        let token = recording.date + "/" + recording.timestamp
        DoorLog.shared.command(PocketErrandCommand.recorderRemoval,
                               subject: token,
                               outcome: DoorLog.succeeded)
        syncedThisSession[token] = nil
        shelfRecordings.removeAll { $0.date + "/" + $0.timestamp == token }
        if let panel { await rebuildShelf(panel, identity: identity) }
    }
}

private extension Array {
    /// Index or nil. The shelf and its readings move together in `stateShelf`, and a crash is
    /// not the right answer if some future edit ever lets them disagree by one.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

@MainActor
extension PocketRecorderCheckModel {

    // MARK: - Fast sync: the same errand over the recorder's own network

    #if DEBUG
    /// THE TWO THINGS A HERMETIC RUN CANNOT OWN ON THIS PATH — a WiFi association and a server
    /// on an address nobody has confirmed — plus the custody store the fake radio's key lives
    /// in. Same shape, same reason and same `#if DEBUG` as `attachmentFactoryForScenarios`:
    /// the Release binary has no such door.
    struct FastSyncScenarioSeam: Sendable {
        let endpoint: URL?
        let joiner: any PocketSoftAPJoining
        let http: any PocketHTTPPulling
        let secrets: any PocketSecretStore
        init(endpoint: URL?, joiner: any PocketSoftAPJoining, http: any PocketHTTPPulling,
             secrets: any PocketSecretStore) {
            self.endpoint = endpoint; self.joiner = joiner; self.http = http; self.secrets = secrets
        }
    }
    nonisolated(unsafe) static var fastSyncSeamForScenarios: FastSyncScenarioSeam?
    #endif

    /// WHETHER A TAP COULD DO ANYTHING TODAY, asked of the evidence rather than of a hope.
    ///
    /// Two facts, both measured: is there a confirmed address to fetch from
    /// (`PocketFastSyncEndpoint.measured`, still nil — `PROTOCOL.md:149` says "TBD"), and can
    /// this build join an access point at all (`PocketHotspotJoiner.isSupported`, which needs
    /// the hotspot entitlement and an iOS runtime).
    static var fastSyncCanRun: Bool {
        #if DEBUG
        if let seam = fastSyncSeamForScenarios { return seam.endpoint != nil }
        #endif
        return PocketFastSyncEndpoint.measured != nil && PocketHotspotJoiner.isSupported
    }

    /// ONE RECORDING, OVER THE RECORDER'S OWN WIFI, INTO THE SAME CUSTODY.
    ///
    /// It shares `isBringingOver` with the Bluetooth leg on purpose: they are the same recorder
    /// and the same radio, and two ideas of "busy" is how a second session gets opened on top
    /// of a live one. The hand-off to `CaptureManager` and the shelf re-read are the Bluetooth
    /// path's, verbatim — a fast-synced recording is not a second kind of recording.
    /// - Parameter brain: which brain is on. Carried for the SAME reason `run` carries it —
    ///   the shelf re-read at the end of this errand resolves the safety predicate, and a
    ///   default here would be a decision about whether a recording is safe.
    func fastSync(hardwareToken: String, advertisedName: String, into manager: CaptureManager,
                  brain: BrainChoice) {
        guard PocketErrandProgressPresentation.admitsANewErrand(inFlight) else { return }
        guard let recording = offeredRecording else { return }
        guard let identifier = UUID(uuidString: hardwareToken) else {
            bringOverMessage = PocketRecorderCheckPresentation.notThisRecorderLine
            return
        }
        isBringingOver = true
        bringOverMessage = nil
        // ONE TAP IS ONE ERRAND ON THIS PATH TOO. All four of these lines were missing, and
        // each one is a hole Step 4 had already closed on the Bluetooth leg: without
        // `beginErrand`/`finishErrand` the command path records nothing, so a fast sync is
        // invisible in the log a person is asked to send when it goes wrong; without the
        // attachment being NAMED and stored, `cancel()` cannot reach the radio it opened; and
        // without the `Task` being assigned to `errand`, leaving the page does not stop it.
        // The tap looked identical to `bringOver` and behaved like none of it.
        beginErrand(PocketErrandCommand.bringOverSubject,
                    about: recording.date + "/" + recording.timestamp)
        let attachment = Self.makeAttachment(log: DoorLog.shared)
        self.attachment = attachment
        let custody = self.custody
        let identity = Self.custodyIdentity(for: hardwareToken)
        let panel = detail
        var endpoint = PocketFastSyncEndpoint.measured
        var joiner: any PocketSoftAPJoining = PocketHotspotJoiner()
        var http: any PocketHTTPPulling = PocketFastSyncHTTPPuller()
        var secrets: any PocketSecretStore = KeychainPocketSecretStore()
        #if DEBUG
        if let seam = Self.fastSyncSeamForScenarios {
            endpoint = seam.endpoint; joiner = seam.joiner
            http = seam.http; secrets = seam.secrets
        }
        #endif
        let resolvedEndpoint = endpoint
        errand = Task { [weak self] in
            let result = await PocketFastSyncErrand.run(
                peripheralIdentifier: identifier,
                advertisedName: advertisedName,
                recording: recording,
                endpoint: resolvedEndpoint,
                custody: custody,
                secrets: secrets,
                attachment: attachment,
                destination: .init(baseDir: manager.captureLibraryRoot),
                joiner: joiner,
                http: http)
            guard let self, !Task.isCancelled else { return }
            self.errand = nil
            self.attachment = nil
            self.bringOverMessage = result.message
            if let captureID = result.captureID {
                manager.adoptCompletedCapture(captureId: captureID)
                let fileToken = recording.date + "/" + recording.timestamp
                DoorLog.shared.command(PocketErrandCommand.custodyCommit,
                                       subject: fileToken,
                                       outcome: DoorLog.succeeded)
                // THE SAME SYNC INSTANT THE BLUETOOTH LEG WRITES. Without this line a
                // fast-synced recording is invisible to the owner-armed clear FOREVER: that
                // sweep's candidate set is exactly this map, so a recorder armed by its owner
                // would never clear anything the fast path brought over.
                self.syncedThisSession[fileToken] = Date()
                self.refreshEvidence(from: manager)
                if let panel { await self.rebuildShelf(panel, identity: identity) }
            }
            self.isBringingOver = false
            self.finishErrand(outcome: Self.token(for: result.outcome))
            // THE SHELF IS RE-READ FOR THE SAME REASON THE BLUETOOTH LEG RE-READS IT: custody is
            // the only thing that knows whether the file landed, and the row's "In Solleva" has
            // to come from asking the disk rather than from this method having been optimistic.
            self.run(hardwareToken: hardwareToken, advertisedName: advertisedName,
                     library: manager.captureLibraryRoot, stages: manager.captureStages(),
                     brain: brain)
            await self.clearWhatTheArmedControlAllows(hardwareToken: hardwareToken,
                                                      advertisedName: advertisedName)
        }
    }
}

// MARK: - The one connection affordance's destination

/// "Connect a recording device" — one affordance, one list of whatever answered, and the
/// record-then-sync setup ceremony. Every string here is the shipped brand-free copy from
/// `RecordingDeviceConnectPresentation`; the scan rows show only the name each device
/// BROADCASTS, because a broadcast name is genuinely all the app knows before it connects.
private struct RecordingDeviceConnectSheet: View {
    @ObservedObject var device: DeviceManager
    let onDismiss: () -> Void

    @StateObject private var attach = RecordingDeviceAttachModel()
    /// THE DISCLOSURE'S STATE, AND NOTHING ELSE. `RecordingDeviceScanFilter` owns the rule;
    /// this is only whether the person has asked to see what it folded.
    @State private var showingUnnamed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // NOTHING IS PINNED ABOVE WHAT ANSWERED THE SCAN. A hardcoded "Set up
                    // Pocket" row used to sit here, first, carrying a CLASS caption for a
                    // device the app had never connected to — a brand name above a person's
                    // actual device, which is "vendors first" in the one place the design
                    // draws two rows that read identically.
                    // WHAT THE SCAN TURNED UP, MINUS THE INTERCHANGEABLE ROWS — and the rule
                    // lives in the kit, where `swift test` can hold it, rather than as a
                    // `filter` typed into this body. A room full of BLE advertisers produced a
                    // list that was mostly identical `Unnamed recording device` rows; they are
                    // FOLDED behind a count, never dropped, and only ever when there is
                    // something named to fold them behind (see `RecordingDeviceScanFilter`).
                    ForEach(scan.visible) { found in
                        Button {
                            // THE TAP THAT RUNS THE ADOPTION CHAIN. It used to go straight to
                            // `device.connect`, which records a `.bleStream` pair and then
                            // hunts for one vendor's audio service — so a stored-file recorder
                            // could be tapped and would still never become a row, because
                            // nothing in the app had ever reached `PocketBLEClient`,
                            // `PocketRecordingDeviceBridge.observe` or
                            // `RecordingDeviceAdoption.remember`. This is that chain, and the
                            // shipped pairing path is what it falls back to for a device that
                            // turns out to speak live audio instead.
                            attach.attach(found, using: device, onAdopted: onDismiss)
                        } label: {
                            // PRE-CONNECT, THE ONLY FACT IS THE BROADCAST NAME — no class, no
                            // battery, no capabilities. Class appears the moment the transport
                            // establishes which protocol the device actually speaks.
                            row(title: found.name.isEmpty
                                    ? RecordingDeviceConnectPresentation.unnamedDeviceName
                                    : found.name,
                                detail: attach.attaching == found.id
                                    ? (attach.attachPhase?.line
                                        ?? RecordingDeviceAttachPresentation.connectingLine)
                                    : "Bluetooth · Tap to connect")
                        }
                        .buttonStyle(.plain)
                        .disabled(attach.attaching != nil)
                    }

                    // THE FOLD, SAID OUT LOUD AND REVERSIBLE IN ONE TAP. A device that
                    // broadcasts no name is still reachable from this screen — that is the
                    // whole difference between decluttering a list and making somebody's
                    // recorder unpairable.
                    if let hidden = scan.hiddenLine {
                        Button {
                            showingUnnamed = true
                        } label: {
                            HStack(spacing: GrainSpacing.x1) {
                                Text(hidden)
                                    .grainTextStyle(.caption)
                                    .foregroundStyle(GrainColor.textMuted)
                                Text(RecordingDeviceConnectPresentation.showUnnamedAction)
                                    .grainTextStyle(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(GrainColor.forgeBlue)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("show-unnamed-devices")
                        .padding(.vertical, GrainSpacing.x3)
                    } else if showingUnnamed, wouldFoldSomething {
                        Button {
                            showingUnnamed = false
                        } label: {
                            Text(RecordingDeviceConnectPresentation.hideUnnamedAction)
                                .grainTextStyle(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(GrainColor.forgeBlue)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("hide-unnamed-devices")
                        .padding(.vertical, GrainSpacing.x3)
                    }

                    // WHAT THE TAP ESTABLISHED, WHEN IT ESTABLISHED NOTHING. Every string
                    // comes from the kit; a failure that leaves the row looking untouched is
                    // how "I tapped it and nothing happened" gets shipped.
                    if let message = attach.inlineMessage {
                        Text(message)
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("recording-device-attach-message")
                            .padding(.vertical, GrainSpacing.x3)
                    }

                    // `scan.visible`, NOT `device.discovered`: the empty state has to be about
                    // what is on screen. It can only differ when the fold is active, and the
                    // fold is only ever active when something named is showing — so this can
                    // never say "nothing found" over a list that has rows in it.
                    if scan.visible.isEmpty {
                        HStack(spacing: GrainSpacing.x2) {
                            if isScanning { ProgressView().tint(GrainColor.forgeBlue) }
                            Text(isScanning
                                 ? RecordingDeviceConnectPresentation.scanningLine
                                 : RecordingDeviceConnectPresentation.emptyLine)
                                .grainTextStyle(.caption)
                                .foregroundStyle(GrainColor.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, GrainSpacing.x3)
                    }

                    // WHY THE ROWS SAY SO LITTLE, said out loud rather than left to be read
                    // as a shortcoming (design §3.1).
                    Text(RecordingDeviceConnectPresentation.broadcastNameNote)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, GrainSpacing.x4)

                    Text(RecordingDeviceConnectPresentation.routePairingNote)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, GrainSpacing.x3)

                    // THE ORPHANED VIEW'S PRESENTER, AS AN ANSWER RATHER THAN AN ENTRY POINT.
                    // `PocketOnboardingView` shipped with zero references anywhere in the
                    // tree. It is reached from here — the question a person whose recorder
                    // never appears actually has — and it lands on §3.6, "Setup isn't
                    // available yet", because that is where the ceremony honestly stops today
                    // (T2 req 3 gates provisioning). Design §7 Q1 is explicit that a
                    // discoverable entry point which cannot connect anything is its own kind
                    // of trap, so this is a link to an explanation, not a setup row.
                    NavigationLink {
                        SetupUnavailableExplanation(onClose: onDismiss)
                    } label: {
                        HStack(spacing: GrainSpacing.x1) {
                            Text(RecordingDeviceConnectPresentation.setupHelpLink)
                                .grainTextStyle(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(GrainColor.forgeBlue)
                            Image(systemName: "chevron.right")
                                .grainTextStyle(.caption)
                                .foregroundStyle(GrainColor.forgeBlue)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("why-isnt-my-recorder-here")
                    .padding(.top, GrainSpacing.x3)
                }
                .padding(.horizontal, GrainSpacing.x4)
                .padding(.bottom, GrainSpacing.x8)
            }
            .grainBackground()
            .navigationTitle(RecordingDeviceConnectPresentation.connectSheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            // WHERE THE CHAIN HONESTLY STOPS, REACHED BY THE TAP RATHER THAN BY A LINK.
            //
            // A recorder FoundryX has never provisioned comes back `.setupUnavailable`: the
            // protocol client reached it, the shipped custody restore ran, and FoundryX holds
            // no key for it — and it may not mint one, because T2 req 3 gates provisioning
            // until an evidenced key alphabet and a security-reviewed entropy policy exist.
            // The §3.6 screen is that fact, in the user's words, including the only
            // reassurance that is knowable: the recorder was sent nothing.
            //
            // AND THE ONE WAY PAST IT THAT DOES NOT MOVE THE GATE. An owner whose recorder
            // was already set up by another app HOLDS the key; they were never waiting on
            // FoundryX to generate one. `entryAction` swaps this destination for the entry
            // field, which validates against the shipped predicate, puts the key in the
            // shipped Keychain seam, and re-runs the same `RecordingDeviceAttachment` a tap
            // runs. Nothing here calls `provisionFactoryFresh`.
            .navigationDestination(isPresented: $attach.showingCeremony) {
                PocketOnboardingView(screen: attach.ceremonyScreen) { title in
                    // THE ROUTING IS ON THE MODEL, NOT IN THIS CLOSURE, AND THAT IS THE POINT.
                    //
                    // It used to be a `switch` written here, inside a SwiftUI `body`. Nothing in
                    // this repository can execute a `body`: `swift test` cannot compile `App/`
                    // at all, and the app-hosted lane drives models rather than views. So the
                    // table that decides which button does what was the one part of this flow
                    // with no test of any kind — and a missing row in it is exactly how a key
                    // the recorder never answered became a screen with no way off it.
                    // `ceremonyAction` is that table, on an object a scenario can call.
                    if attach.ceremonyAction(title) == .closeTheSheet {
                        attach.dismissCeremony()
                        onDismiss()
                    }
                }
                .keyEntry(message: attach.keyEntryMessage,
                          isSubmitting: attach.submittingKey,
                          onSubmit: { attach.submitExistingKey($0) })
                .keyCustody(revealed: attach.revealedKey,
                            didCopy: attach.didCopyKey,
                            hasRecoveryCopy: attach.recoveryCopyExists,
                            onReveal: { attach.revealKeyForCurrentRecorder() },
                            onCopy: { attach.copyRevealedKey() })
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onDismiss() }
                }
            }
        }
        .onAppear { device.startScan() }
        .onDisappear {
            device.stopScanIfScanning()
            attach.cancel()
        }
    }

    private var isScanning: Bool {
        if case .scanning = device.connectionState { return true }
        return false
    }

    /// What this sheet draws. A COMPUTED PROPERTY rather than a `let` in the body so the rule
    /// is applied in exactly one place and the `else if` below cannot drift from the `ForEach`
    /// above it.
    private var scan: RecordingDeviceScanList {
        RecordingDeviceScanFilter.resolve(device.discovered, showingUnnamed: showingUnnamed)
    }

    /// Whether folding would actually hold anything back — asked of the SAME function that
    /// does the folding, so "Hide" cannot appear over a list that hiding would not change.
    private var wouldFoldSomething: Bool {
        RecordingDeviceScanFilter.resolve(device.discovered,
                                          showingUnnamed: false).hiddenUnnamedCount > 0
    }

    private func row(title: String, detail: String) -> some View {
        HStack(spacing: GrainSpacing.x3) {
            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                Text(title)
                    .grainTextStyle(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(GrainColor.ink)
                Text(detail)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
            }
            Spacer(minLength: GrainSpacing.x2)
            Image(systemName: "chevron.right")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)
        }
        .padding(.vertical, GrainSpacing.x3)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(GrainColor.borderFaint).frame(height: 1)
        }
    }
}

#if DEBUG
/// THE TWO THINGS A HERMETIC RUN CANNOT OWN, AND NOTHING ELSE. Declared at file scope rather
/// than nested inside the `@MainActor` model so that it is a plain `Sendable` value a scenario
/// can build off the main actor.
struct RecordingDeviceScenarioSeam: Sendable {
    let makeCentral: @Sendable (BLEEventSink, DispatchQueue, String?) -> BLECentral
    let secrets: any PocketSecretStore
    let recovery: (any PocketKeyRecoveryStore)?
    let deadlines: RecordingDeviceAttachment.Deadlines

    init(makeCentral: @escaping @Sendable (BLEEventSink, DispatchQueue, String?) -> BLECentral,
         secrets: any PocketSecretStore,
         recovery: (any PocketKeyRecoveryStore)? = nil,
         deadlines: RecordingDeviceAttachment.Deadlines = .init()) {
        self.makeCentral = makeCentral
        self.secrets = secrets
        self.recovery = recovery
        self.deadlines = deadlines
    }
}
#endif

// MARK: - The tap, and the chain it runs

/// THE APP SIDE OF THE ADOPTION CHAIN.
///
/// `RecordingDeviceAttachment` owns the radio work and returns what the transport actually
/// ESTABLISHED. This model owns nothing but the tap: which row is busy, which ceremony a tap
/// landed on, and the fall-through to the shipped pairing path. It derives no copy — every
/// string it shows comes from `RecordingDeviceAttachPresentation`.
///
/// THE FALL-THROUGH IS THE REASON OMI STILL PAIRS. `.live` hands the tap straight to
/// `DeviceManager.connect`, unchanged — a stored-file leg that could swallow an Omi pairing
/// would be a bad trade for a device class nobody can attach yet.
///
/// `.unrecognised` IS NOT PART OF THAT FALL-THROUGH, and used to be. A device that connected
/// and spoke nothing this build knows was handed to the live pairing path and the sheet was
/// dismissed as though it had been adopted, with no message — the reported "tapping it just
/// cycles back to the list". It now earns its own line and the sheet stays where it is.
@MainActor
final class RecordingDeviceAttachModel: ObservableObject {
    /// The row currently being attached, so it can say `Connecting…` and the rest can be
    /// disabled. One radio, one tap at a time.
    @Published private(set) var attaching: UUID?
    /// How far the in-flight attach has got. Nil when nothing is attaching.
    @Published private(set) var attachPhase: RecordingDeviceAttachPhase?
    /// The relay-bound log, kept from the tap that opened this ceremony so the key-entry leg
    /// can report into the same channel. `submitExistingKey` has no `DeviceManager` in scope
    /// — and a key attempt that fails is precisely the failure worth being able to read.
    private var diagnosticLog: DoorLog?
    @Published private(set) var inlineMessage: String?
    @Published var showingCeremony = false
    @Published private(set) var ceremonyScreen: PocketOnboardingView.Screen = .setupUnavailable
    /// What the last submitted key earned, worded by `PocketSessionKeyEntryPresentation`.
    @Published private(set) var keyEntryMessage: String?
    @Published private(set) var submittingKey = false
    /// §10 custody: the key the owner asked to see, and whether they just copied it. Held for
    /// the life of one screen and cleared when it closes.
    @Published private(set) var revealedKey: String?
    @Published private(set) var didCopyKey = false
    /// Whether the synchronised (§10) copy of this recorder's key actually exists. Asked of
    /// the store when the custody screen is shown, never assumed — `false` renders the sentence
    /// that tells the owner to write the key down, which is the safe direction to be wrong in.
    @Published private(set) var recoveryCopyExists = false

    private var attachment: RecordingDeviceAttachment?
    /// The device the ceremony on screen belongs to. A key is entered for ONE recorder, and
    /// this is the only place that remembers which.
    private var ceremonyTarget: (id: UUID, name: String)?
    private var onAdopted: (() -> Void)?

    #if DEBUG
    /// THE RADIO AND THE KEYCHAIN — the two things a hermetic run cannot own — AND NOTHING
    /// ELSE. Same shape and same justification as `PocketRecorderCheckModel
    /// .attachmentFactoryForScenarios`: this model is a `@StateObject` created inside the view
    /// that owns it, so a dependency threaded through its initialiser would be a parameter on
    /// the shipping view that exists only for tests. `#if DEBUG` means the Release binary has
    /// no such door, and `leak` proves that over the shipped binary.
    ///
    /// THE KEYCHAIN HAS TO BE IN HERE TOO, unlike the recorder page's seam. The app-scenario
    /// host is built `CODE_SIGNING_ALLOWED=NO`, so a real `KeychainPocketSecretStore` answers
    /// `errSecMissingEntitlement` — every scenario would then assert against a custody failure
    /// rather than against the handshake it is about.
    nonisolated(unsafe) static var scenarioSeam: RecordingDeviceScenarioSeam?
    #endif

    /// The attachment every path in this model opens a link with: the production one unless a
    /// scenario running inside a DEBUG build has supplied a radio and a custody store.
    /// - Parameter log: the relay-bound log. Defaulted to the shared instance so a caller
    ///   that has none still reports somewhere, and accepted explicitly so the device screen
    ///   can hand over the very log its `DeviceManager` was built with.
    private static func makeAttachment(log: DoorLog? = .shared) -> RecordingDeviceAttachment {
        #if DEBUG
        if let seam = scenarioSeam {
            return RecordingDeviceAttachment(makeCentral: seam.makeCentral,
                                             secrets: seam.secrets,
                                             recovery: seam.recovery,
                                             deadlines: seam.deadlines)
        }
        #endif
        return RecordingDeviceAttachment(log: log)
    }

    /// The same substitution for the one path that does not build an attachment itself.
    private static func makeKeyEntryCoordinator(
        log: DoorLog?,
        onPhase: @escaping @Sendable (RecordingDeviceAttachPhase) -> Void
    ) -> PocketSessionKeyEntryCoordinator {
        #if DEBUG
        if let seam = scenarioSeam {
            return .live(secrets: seam.secrets, makeCentral: seam.makeCentral,
                         deadlines: seam.deadlines, onPhase: onPhase)
        }
        #endif
        return .live(log: log, onPhase: onPhase)
    }

    func attach(_ found: DiscoveredDevice,
                using device: DeviceManager,
                onAdopted: @escaping () -> Void) {
        guard attaching == nil else { return }
        attaching = found.id
        inlineMessage = nil
        keyEntryMessage = nil
        self.diagnosticLog = device.diagnosticLog
        let attachment = Self.makeAttachment(log: device.diagnosticLog)
        self.attachment = attachment
        let name = found.name
        let id = found.id
        ceremonyTarget = (id, name)
        self.onAdopted = onAdopted
        // A REAL POCKET TAKES LONG ENOUGH HERE TO LOOK LIKE NOTHING HAPPENED. Seven distinct
        // steps ran behind one static "Connecting…", so an owner watching a slow radio, a
        // slow service discovery and a slow key handshake saw exactly the same word for all
        // of them — and reasonably concluded the tap had done nothing.
        attachPhase = .wakingRadio
        attachment.observePhases { [weak self] phase in
            Task { @MainActor in self?.attachPhase = phase }
        }
        Task {
            let outcome = await attachment.attach(peripheralIdentifier: id, advertisedName: name)
            self.attaching = nil
            self.attachPhase = nil
            self.attachment = nil
            self.inlineMessage = RecordingDeviceAttachPresentation.inlineMessage(for: outcome)
            switch outcome {
            case .adopted:
                onAdopted()
            case .setupUnavailable:
                // A TAP GOT AS FAR AS "SOLLEVA HOLDS NO KEY FOR THIS ONE" AND STOPPED THERE.
                // Nothing was written. What comes next is a DECISION screen, not a mint: the
                // owner is told what Solleva will do, what it cannot predict, and what it
                // could cost them, and only their confirmation constructs the consent value a
                // mint needs.
                self.ceremonyScreen = .mintConsent
                self.showingCeremony = true
            case .mintRefused:
                self.ceremonyScreen = .mintRefused
                self.showingCeremony = true
            case .mintNotVerified:
                self.ceremonyScreen = .mintNotVerified
                self.showingCeremony = true
            case .keyNotKept:
                // NOTHING WAS SENT. Custody refused the key before the recorder was asked,
                // which is what doing custody first buys.
                self.ceremonyScreen = .keyNotKept
                self.showingCeremony = true
            case .custodyUnreadable:
                // NOT THE MINT OFFER. FoundryX may hold this recorder's key and could not read
                // it; offering to make a new one here is how a locked Keychain turns into a
                // second key written to a recorder FoundryX itself set up.
                self.ceremonyScreen = .custodyUnreadable
                self.showingCeremony = true
            case .keyAcceptedNotDurable:
                // THE ATTACHMENT IS RETAINED, exactly as `confirmMintAfterOwnerConsent` does.
                // It is holding the only copy of a key the recorder has accepted, and this
                // screen's only action (`retryPendingCustody`) reads it — dropping the object
                // here would leave the §3.7 screen up with a button that returns immediately
                // and a recorder nothing can ever connect to.
                self.attachment = attachment
                self.ceremonyScreen = .acceptedNotDurable
                self.showingCeremony = true
            case .recoveryRequired:
                self.ceremonyScreen = .didNotFinish
                self.showingCeremony = true
            // THE REPORTED DEADLOCK, AND THE ROUTE THAT ENDS IT.
            //
            // Solleva holds a key for this recorder and the recorder never answered it. This
            // used to fall into the `break` below: an inline caption reading "Tap it again",
            // and nothing else — so the next tap restored the same key, got the same silence,
            // and produced the same caption, forever. The one screen that can REPLACE a key
            // hung off `.setupUnavailable`, which means "Solleva holds no key", and is
            // therefore the one state a recorder with a stored key can never reach.
            //
            // THE KEY IS NOT TOUCHED HERE. Silence is not evidence it is wrong (see
            // `PocketSetupPresentation.handshakeUnanswered`), so the screen offers the two
            // moves that cannot lose anything — ask again, or hand over a key that replaces
            // this one — and the caption is cleared because this is a whole screen now, not an
            // aside behind it.
            case .unreachable(.handshakeUnanswered):
                self.inlineMessage = nil
                self.ceremonyScreen = .handshakeUnanswered
                self.showingCeremony = true
            case .live:
                // THE SHIPPED PAIRING PATH, UNTOUCHED. This is the branch an Omi takes.
                device.connect(found)
                onAdopted()
            case .unrecognised, .adoptionNotPersisted, .unreachable:
                // NOT AN ADOPTION, SO NOT A DISMISSAL. `.unrecognised` used to share the
                // branch above: a device that connected and spoke nothing this build knows was
                // handed to the live pairing path and the sheet closed with no message, which
                // is what "tapping it just cycles back to the list" was. The line assigned to
                // `inlineMessage` above stays on screen and the sheet stays open.
                break
            }
        }
    }

    /// Whether the ceremony handled a tap itself, or whether the sheet should close.
    enum CeremonyDisposition: Equatable { case handled, closeTheSheet }

    /// WHICH BUTTON DOES WHAT, AS A FUNCTION RATHER THAN AS A `switch` INSIDE A `body`.
    ///
    /// Every action on every ceremony screen arrives here as its own title, matched against the
    /// NAMED constant the kit words the button from — a literal on one side and a constant on
    /// the other is a routing bug that compiles, on screens where a dead button is the whole
    /// difference between an owner keeping their recorder and losing it.
    ///
    /// `.closeTheSheet` is the honest default: a title with no row here is a screen whose
    /// action this model does not implement, and dismissing is the one response that cannot
    /// leave somebody staring at a button that does nothing.
    @discardableResult
    func ceremonyAction(_ title: String) -> CeremonyDisposition {
        switch title {
        case PocketSessionKeyEntryPresentation.entryAction:
            showKeyEntry()
        // THE ONE TAP THAT CAN WRITE A KEY TO A RECORDER. It is the confirm action on the
        // consent screen and nothing else — every other title here either navigates or closes.
        case PocketMintConsentPresentation.confirmAction:
            confirmMintAfterOwnerConsent()
        case PocketMintConsentPresentation.resetAction:
            showFactoryReset()
        // DESIGN §3.7. The recorder is holding a key this phone could not store, and this is
        // the one action that can still save it. It retries the Keychain; it never sends a
        // second key.
        case PocketSetupPresentation.retrySecureStorageAction:
            retrySecureStorageForAcceptedKey()
        case PocketFactoryResetPresentation.retryAction:
            showMintConsent()
        // "TRY AGAIN" IS A RETRY ON EVERY SCREEN THAT OFFERS IT — AND THE ALLOWLIST THAT USED TO
        // GUARD THIS ROW WAS ITSELF THE DEFECT.
        //
        // It read `where ceremonyScreen == .keyNotKept || .custodyUnreadable ||
        // .handshakeUnanswered`, so the FOURTH screen carrying the same word — `.didNotFinish`,
        // which is what a recorder that REFUSED the key Solleva holds lands on — fell through to
        // `default` and CLOSED THE WHOLE CONNECT SHEET. Its body says "Try again before you close
        // this" and its first, primary button closed it. A screen-conditional route is a table
        // that has to be edited every time a screen gains an action, and the edit that was missed
        // is exactly this class of defect: a capability that exists, is tested, and is orphaned
        // from the one state a user actually lands in.
        //
        // It is safe from every state by construction: `retryPlainAttach` leaves `mint:` at its
        // default, so a retry cannot write a key from anywhere. And it reports honestly — with no
        // recorder in hand there is nothing to retry, so the sheet closes rather than leaving a
        // button that does nothing.
        case PocketSetupPresentation.retryAction,
             // "Try connecting again" now TRIES CONNECTING. It used to hand the owner back to the
             // consent screen, which is not a connection attempt and is not what the word says —
             // and on `.mintNotVerified` the plain attach is the very question the screen leaves
             // open, because it restores the key just minted and finds out whether the recorder
             // is holding it after all.
             PocketMintNotVerifiedPresentation.retryAction:
            return retryPlainAttach() ? .handled : .closeTheSheet
        case PocketKeyCustodyPresentation.entryAction:
            showKeyCustody()
        default:
            return .closeTheSheet
        }
        return .handled
    }

    func dismissCeremony() {
        showingCeremony = false
        // A REVEALED KEY DOES NOT OUTLIVE THE SCREEN THAT REVEALED IT.
        revealedKey = nil
        didCopyKey = false
    }

    /// The owner said they already have this recorder's key. Swap the consent screen for the
    /// field — nothing is minted on this path.
    func showKeyEntry() {
        keyEntryMessage = nil
        ceremonyScreen = .enterExistingKey
    }

    /// The maker's reset gesture, with the cost stated before the steps. Solleva cannot perform
    /// it and cannot verify it, and the copy says both.
    func showFactoryReset() { ceremonyScreen = .factoryReset }

    /// Back to the decision, from the reset guidance or from an unproven mint.
    func showMintConsent() { ceremonyScreen = .mintConsent }

    /// THE ONLY MINT IN THE APP, AND THE ONLY CONSTRUCTION OF CONSENT.
    ///
    /// It is reachable from exactly one place: the confirm action on the consent screen, which
    /// the owner has to tap after reading what Solleva will do, what it cannot predict, and
    /// what it could cost them. `PocketMintConsent` has no other factory and no public
    /// initialiser, and `attach`'s `mint:` parameter defaults to `nil`, so no other call site
    /// in this app can write a key to a recorder — by omission or otherwise.
    func confirmMintAfterOwnerConsent() {
        guard let target = ceremonyTarget, !submittingKey else { return }
        submittingKey = true
        keyEntryMessage = nil
        let attachment = Self.makeAttachment()
        self.attachment = attachment
        Task {
            let outcome = await attachment.attach(
                peripheralIdentifier: target.id,
                advertisedName: target.name,
                mint: .ownerConfirmedAfterReadingTheConsequences())
            self.submittingKey = false
            self.attachment = nil
            switch outcome {
            case .adopted:
                // THE KEY IS SHOWN ONLY AFTER IT IS DURABLE. Custody wrote the attach record
                // BEFORE the recorder was ever asked, so the custody screen cannot promise a
                // value the Keychain does not hold — and `refreshRecoveryCopyState` asks the
                // store whether the SYNCHRONISED copy landed too, rather than assuming it did.
                self.ceremonyScreen = .keyCustody
                self.refreshRecoveryCopyState()
            case .mintRefused:       self.ceremonyScreen = .mintRefused
            case .mintNotVerified:   self.ceremonyScreen = .mintNotVerified
            case .keyNotKept:        self.ceremonyScreen = .keyNotKept
            case .custodyUnreadable: self.ceremonyScreen = .custodyUnreadable
            case .keyAcceptedNotDurable:
                // DESIGN §3.7. THE ATTACHMENT IS DELIBERATELY NOT RELEASED HERE: it is holding
                // the only copy of a key the recorder has already accepted, and dropping it is
                // the irreversible loss the screen warns about.
                self.attachment = attachment
                self.ceremonyScreen = .acceptedNotDurable
            case .recoveryRequired:  self.ceremonyScreen = .didNotFinish
            case .setupUnavailable, .live, .unrecognised, .adoptionNotPersisted, .unreachable:
                // The confirmed mint never ran to a conclusion — the link went, or the device
                // turned out not to be a recorder at all. `didNotFinish` says exactly that and
                // offers a retry; it does not claim a key was sent or that one was refused.
                self.ceremonyScreen = .didNotFinish
            }
        }
    }

    /// DESIGN §3.7's ONLY ACTION. It retries the KEYCHAIN and nothing else — no second key is
    /// sent, ever. The attachment still holds the accepted key; if the write lands, the same
    /// object re-runs the ordinary restore path and the recorder is finally adopted.
    func retrySecureStorageForAcceptedKey() {
        guard let attachment, !submittingKey else { return }
        submittingKey = true
        Task {
            let outcome = await attachment.retryPendingCustody()
            self.submittingKey = false
            switch outcome {
            case .adopted:
                self.attachment = nil
                self.ceremonyScreen = .keyCustody
                self.refreshRecoveryCopyState()
            case .none, .some(.keyAcceptedNotDurable):
                // STILL NOT DURABLE, AND THE KEY IS STILL HELD. The screen stays exactly where
                // it is, saying exactly what it said, because nothing about the situation has
                // changed and pretending otherwise would invite the person to close it.
                self.ceremonyScreen = .acceptedNotDurable
            case .some:
                // The key IS durable now; whatever else went wrong is an ordinary attach
                // failure and is no longer the irreversible state.
                self.attachment = nil
                self.ceremonyScreen = .didNotFinish
            }
        }
    }

    /// THE "TRY AGAIN" THAT IS A REAL SECOND TAP, AND IT IS A PLAIN ONE — `mint:` is left at
    /// its default, so this cannot write a new key by construction.
    ///
    /// It is the honest retry for every state whose cause can change without the owner doing
    /// anything. `.custodyUnreadable` may simply have been a locked Keychain, and the same tap
    /// now restores and adopts. `.keyNotKept` re-runs the restore, finds no key (nothing was
    /// ever stored, because custody refused it before the recorder was asked), and lands back
    /// on the CONSENT screen — so a second mint still costs the owner an explicit confirmation
    /// rather than inheriting the first one. `.handshakeUnanswered` is the third: a recorder
    /// that was asleep or busy answers the next attempt, and the key it never answered is still
    /// in custody to be tried with.
    ///
    /// (It was called `retryAfterStorageFailure`. The name described two of its three callers
    /// and would have made the third read as a category error.)
    ///
    /// - Returns: whether a retry actually STARTED. `false` means there is no recorder this
    ///   ceremony belongs to (the §3.6 screen reached from the help link) or one is already in
    ///   flight, and the caller turns that into an honest dismissal rather than a button that
    ///   silently does nothing — which is the same failure, one level down, as the allowlist
    ///   this now replaces.
    @discardableResult
    func retryPlainAttach() -> Bool {
        guard let target = ceremonyTarget, !submittingKey else { return false }
        submittingKey = true
        let attachment = Self.makeAttachment()
        self.attachment = attachment
        Task {
            let outcome = await attachment.attach(peripheralIdentifier: target.id,
                                                  advertisedName: target.name)
            self.submittingKey = false
            self.attachment = nil
            switch outcome {
            case .adopted:
                self.dismissCeremony()
                self.onAdopted?()
            case .setupUnavailable:   self.ceremonyScreen = .mintConsent
            case .keyNotKept:         self.ceremonyScreen = .keyNotKept
            case .custodyUnreadable:  self.ceremonyScreen = .custodyUnreadable
            case .mintRefused:        self.ceremonyScreen = .mintRefused
            case .mintNotVerified:    self.ceremonyScreen = .mintNotVerified
            case .keyAcceptedNotDurable:
                self.attachment = attachment
                self.ceremonyScreen = .acceptedNotDurable
            // A RETRY THAT FAILED THE SAME WAY SAYS SO AND STAYS PUT. Falling into
            // `.didNotFinish` below would swap the one screen that offers the key field for one
            // that does not, so the second attempt would be strictly worse than the first —
            // which is how a "Try again" button becomes the trap it was meant to open.
            case .unreachable(.handshakeUnanswered):
                self.ceremonyScreen = .handshakeUnanswered
            case .recoveryRequired, .live, .unrecognised, .adoptionNotPersisted, .unreachable:
                self.ceremonyScreen = .didNotFinish
            }
        }
        return true
    }

    /// §10 CUSTODY. The value comes from the Keychain on demand and lives in this object only
    /// while the screen that shows it is up. It is never put into a message, a log, or an
    /// outcome — the same discipline the entry field is held to.
    func revealKeyForCurrentRecorder() {
        guard revealedKey == nil else {
            revealedKey = nil
            didCopyKey = false
            return
        }
        guard let target = ceremonyTarget else { return }
        Task {
            guard let identity = try? PocketAuthenticatedIdentity(
                peripheralIdentifier: target.id.uuidString) else { return }
            self.revealedKey = await PocketKeyCustody().reveal(for: identity)
        }
    }

    func copyRevealedKey() {
        guard let revealedKey else { return }
        UIPasteboard.general.string = revealedKey
        didCopyKey = true
    }

    func showKeyCustody() {
        revealedKey = nil
        didCopyKey = false
        ceremonyScreen = .keyCustody
        refreshRecoveryCopyState()
    }

    /// ASK THE STORE, DO NOT ASSUME. `PocketKeyCustody.keep` reports `.deviceOnly` whenever the
    /// recorder's broadcast name carries no per-unit serial or the synchronised write failed,
    /// and the custody screen used to promise iCloud recovery either way — telling the one
    /// owner who genuinely has to write their key down that they do not have to.
    private func refreshRecoveryCopyState() {
        guard let target = ceremonyTarget else {
            recoveryCopyExists = false
            return
        }
        let token = PocketRecoveryToken(advertisedName: target.name)
        Task {
            self.recoveryCopyExists = await PocketKeyCustody().hasRecoveryCopy(token)
        }
    }

    /// ONE SUBMITTED KEY, THROUGH THE KIT AND NOWHERE ELSE.
    ///
    /// The value goes straight into `PocketSessionKeyEntryCoordinator` and is not retained,
    /// echoed, logged, or put into any message here. Every string this method can show comes
    /// from `PocketSessionKeyEntryPresentation.line(for:)`, which is worded from an outcome
    /// that carries no credential.
    func submitExistingKey(_ key: String) {
        guard let target = ceremonyTarget, !submittingKey else { return }
        submittingKey = true
        keyEntryMessage = nil
        // The key leg is the same seven-step attach as a tap on the list, so it says the
        // same things while it works. Seeded before the first report so the button never
        // sits on its idle label after a tap.
        attachPhase = .wakingRadio
        let coordinator = Self.makeKeyEntryCoordinator(log: diagnosticLog) { [weak self] phase in
            Task { @MainActor in self?.attachPhase = phase }
        }
        Task {
            let outcome = await coordinator
                .submit(key: key, peripheralIdentifier: target.id, advertisedName: target.name)
            self.submittingKey = false
            self.attachPhase = nil
            if case .adopted = outcome {
                self.showingCeremony = false
                self.onAdopted?()
            } else {
                self.keyEntryMessage = PocketSessionKeyEntryPresentation.line(for: outcome)
            }
        }
    }

    /// The sheet went away mid-attach. Drop the probe's link rather than leave a central
    /// holding a connection to a device nobody is looking at any more.
    func cancel() {
        attachment?.teardown()
        attachment = nil
        attaching = nil
    }
}

// MARK: - The §3.6 screen reached as an ANSWER rather than by a tap

/// "Why isn't my recorder here?" lands on the same §3.6 screen a tap lands on, but WITHOUT a
/// device: nothing has been connected, so there is no recorder a key could be entered for.
/// The entry action therefore pops back to the scan list — where the device you have to tap
/// actually is — instead of opening a field that has nothing to submit to.
private struct SetupUnavailableExplanation: View {
    let onClose: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PocketOnboardingView(screen: .setupUnavailable) { title in
            if title == PocketSessionKeyEntryPresentation.entryAction {
                dismiss()
            } else {
                onClose()
            }
        }
    }
}

// MARK: - "What's the difference?"

/// THE ONE DISTINCTION, ANSWERED IN CLASS TERMS. This link used to open Pocket's hardware
/// education, so a person holding an Omi and an iPhone tapped "Some devices record with your
/// phone. Some record on their own. What's the difference?" and landed on one vendor's LED
/// legend. Every string here comes from `RecordingDeviceClassExplanation`, which is brand-free
/// by construction and asserted as such.
private struct RecordingDeviceClassExplanationView: View {
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(RecordingDeviceClassExplanation.sections.enumerated()),
                        id: \.offset) { _, section in
                    Text(section.title.uppercased())
                        .grainTextStyle(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(GrainColor.forgeBlue)
                        .padding(.bottom, GrainSpacing.x1)
                    Text(section.body)
                        .grainTextStyle(.body)
                        .foregroundStyle(GrainColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, GrainSpacing.x6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(GrainSpacing.x4)
        }
        .grainBackground()
        .navigationTitle(RecordingDeviceClassExplanation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { onClose() }
            }
        }
    }
}

// MARK: - Shared device presentation

private struct DeviceSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .grainTextStyle(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(GrainColor.textFaint)
    }
}

private struct DeviceIconTile: View {
    let icon: GrainIcon
    var foreground: Color = GrainColor.forgeBlue

    var body: some View {
        Image(grain: icon)
            .grainTextStyle(.body)
            .foregroundStyle(foreground)
            .frame(width: GrainSpacing.x8, height: GrainSpacing.x8)
            .background {
                RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous)
                    .fill(GrainColor.forgeBlueBg)
            }
            .overlay {
                RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous)
                    .strokeBorder(GrainColor.forgeBlueBorder, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}
