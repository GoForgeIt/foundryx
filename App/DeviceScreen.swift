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
private struct RecordingDevicePageView: View {
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
    @StateObject private var check = PocketRecorderCheckModel()

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
    private var canReachDevice: Bool {
        isSavedOmi || (input.deviceClass == .recordThenSync && input.isRemembered)
    }

    /// EVERY SLOT DECIDED IN THE KIT. This view passed `hasEducation: shape == .filePull` and
    /// `canForget: shape != .builtInMic` — two shape branches on a screen whose whole rule is
    /// that no surface switches on shape. Education now follows the negotiated protocol and
    /// forget follows the store record, both inside `resolve`, where Brine can hold them.
    private var page: RecordingDevicePagePresentation {
        RecordingDevicePage.resolve(input, canConnect: canReachDevice)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let sentence = page.recordingIndicatorSentence {
                    // THE SINGLE MOST IMPORTANT SENTENCE IN THE DESIGN. It occupies the band
                    // where a live device carries record / pause / stop; the empty space is
                    // not blanked, it is occupied by the true fact.
                    Text(sentence)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("recorder-light-sentence")
                        .padding(.vertical, GrainSpacing.x3)
                        .overlay(alignment: .bottom) { hairline }
                }
                capabilityStrip
                captureToggle
                actions
                recorderShelf
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
            Button("Cancel", role: .cancel) {}
            Button(RecordingDevicePage.forgetAction, role: .destructive) { forget() }
        } message: {
            // THE COST, IN THE SAME TERMS AS THE RESET. Forgetting deletes this app's key, so
            // every recording the recorder still holds ALONE becomes unreachable - and until
            // this line shipped the confirmation stated the mechanism and never the number.
            Text(PocketRecorderCostPresentation.forgetMessage(warning: page.forgetWarning,
                                                              presences: check.presences))
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

    /// Battery / Firmware / Gap recovery / Offline storage, in the shipped `capabilityOrder`,
    /// for a record-then-sync recorder — and for a live device, only what it declared. There
    /// is no `Signal` column: RSSI is meaningful only while streaming.
    ///
    /// AND NO STRIP AT ALL when there is nothing true to put in it. This screen used to draw
    /// four rows for every device, so the iPhone's own microphone reported Battery, Firmware,
    /// Gap recovery and Offline storage as `Unavailable` — the `N/A · N/A · N/A` strip that
    /// started this track, respelled in the shipped word.
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
                Text("Use this device for capture")
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
    @ViewBuilder
    private var recorderShelf: some View {
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

                if let detail = check.detail {
                    if detail.manifest.rows.isEmpty {
                        Text(PocketRecorderCheckPresentation.emptyLine)
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, GrainSpacing.x2)
                    } else {
                        ForEach(Array(detail.manifest.rows.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .firstTextBaseline, spacing: GrainSpacing.x3) {
                                VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                                    Text(row.title)
                                        .grainTextStyle(.body)
                                        .foregroundStyle(GrainColor.ink)
                                    // WHERE THIS RECORDING IS, ON EVERY ROW, IN THREE PLACES.
                                    // It read "Only on the recorder" for every row in every
                                    // build until the bring-over shipped, and then it could
                                    // only ever say one of two things - never "on this phone
                                    // but not yet safe anywhere else", and never "nobody
                                    // asked". Each place carries its own answer and its own
                                    // age, and every string comes from the kit.
                                    Text(row.presenceLabel)
                                        .grainTextStyle(.caption)
                                        .foregroundStyle(GrainColor.textFaint)
                                    ForEach(Array(row.places.enumerated()), id: \.offset) { _, place in
                                        Text(placeLine(place))
                                            .grainTextStyle(.caption)
                                            .foregroundStyle(GrainColor.textFaint)
                                    }
                                }
                                Spacer(minLength: GrainSpacing.x2)
                                Text(row.duration)
                                    .grainTextStyle(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(GrainColor.textMuted)
                            }
                            .padding(.vertical, GrainSpacing.x2)
                            .accessibilityElement(children: .combine)
                            .overlay(alignment: .bottom) { hairline }
                        }
                    }

                    bringOver

                    Text(PocketRecorderCheckPresentation.sectionNote)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, GrainSpacing.x3)

                    // WHERE THE COPY GOES, IN THE TERMS OF THE BRAIN THAT IS ON. On the
                    // phone-only tier this says so, and does not borrow the computer's
                    // sentence for a durability the code cannot deliver there.
                    Text(PocketRecorderCheckPresentation.destinationNote(for: brain))
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, GrainSpacing.x2)

                    resetGate
                }
            }
            .padding(.top, GrainSpacing.x6)
        }
    }

    /// ONE PLACE, AS A LINE. Composed from the kit's own three fields so no sentence about
    /// where a recording is exists only inside a SwiftUI body.
    /// THE KIT'S SPELLING, not this screen's. A conversation that came off a recorder renders
    /// the same three places on the detail screen, and two interpolations of the same three
    /// fields is how the two screens start disagreeing about a recording nobody moved.
    private func placeLine(_ place: PocketPlaceLine) -> String {
        PocketPresencePresentation.oneLine(place)
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
                              stages: manager.captureStages())
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
            .disabled(check.isBringingOver || check.isChecking)
            .padding(.top, GrainSpacing.x3)

            if check.isBringingOver {
                HStack(spacing: GrainSpacing.x2) {
                    ProgressView().tint(GrainColor.forgeBlue)
                    Text(PocketBringOverPresentation.inProgressLine)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                }
                .padding(.top, GrainSpacing.x2)
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
                      stages: manager.captureStages())
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
    /// The file a tap would ask for, or `nil` when there is nothing to offer. It is the ONLY
    /// reason the check reads the unpresented shelf: durations and titles cannot be ordered.
    @Published private(set) var offeredRecording: PocketRecording?

    /// WHERE EVERY LISTED RECORDING IS, as of the last check. The reset's cost and the forget
    /// confirmation both read this, so the number a person is shown before a destructive
    /// gesture is the SAME reading the rows are drawn from - never a second count.
    @Published private(set) var presences: [PocketRecordingPresence] = []
    /// When the recorder last answered a listing. `nil` means it never has on this screen, and
    /// a stale or absent reading changes the reset's primary action, never its enabled state.
    @Published private(set) var shelfObservedAt: Date?

    /// WHERE A BROUGHT-OVER FILE GOES, and what makes a row able to say "In Solleva". The
    /// check consults it too — a custody label that was not asked is a guess.
    private let custody = PocketRecorderFileStore()

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

    /// The attachment this model opens sessions with: the production one unless a scenario
    /// running inside a DEBUG build has supplied a radio.
    /// - Parameter log: the DoorLog that already reaches the relay. Passing it is the whole
    ///   difference between a failure the owner can only screenshot and one that can be read
    ///   afterwards: `RecordingDeviceAttachment` logs the exact reason a tap stopped, and
    ///   with `log: nil` every one of those lines was thrown away.
    private static func makeAttachment(log: DoorLog? = nil) -> RecordingDeviceAttachment {
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
    func run(hardwareToken: String, advertisedName: String,
             library: URL, stages: [String: CaptureStage]) {
        guard !isChecking, !isBringingOver else { return }
        guard let identifier = UUID(uuidString: hardwareToken) else {
            message = PocketRecorderCheckPresentation.notThisRecorderLine
            detail = nil
            offeredRecording = nil
            presences = []
            shelfObservedAt = nil
            return
        }
        isChecking = true
        detail = nil
        message = nil
        offeredRecording = nil
        presences = []
        shelfObservedAt = nil
        let durability = PocketCaptureDurability(baseDir: library, stages: stages)
        Task {
            // A FRESH ATTACHMENT PER CHECK, which is `run`'s default. An attachment's
            // `teardown()` retires its own link and generation, so reusing one is a session
            // that can never come back up.
            //
            // THE SHELF IS ASKED FOR HERE AND NOWHERE ELSE. Choosing which file to bring over
            // needs the recorder's own fields, not the row titles; reading it on a second
            // session would be a second Bluetooth connection for facts this one already had.
            let shelf = PocketRecorderShelfNote()
            let outcome = await PocketRecorderCheck.run(peripheralIdentifier: identifier,
                                                        advertisedName: advertisedName,
                                                        custody: self.custody,
                                                        durability: durability,
                                                        attachment: Self.makeAttachment(),
                                                        shelf: shelf)
            self.isChecking = false
            self.message = PocketRecorderCheckPresentation.message(for: outcome)
            if case .checked(let panel) = outcome {
                self.detail = panel
                // THE SHELF WAS ANSWERED. Both facts come from the one reading: the cost of a
                // reset, and how old that cost is. A check that did NOT reach the recorder
                // leaves both alone, so a stale number is never redrawn as a fresh one.
                self.presences = panel.manifest.rows.map(\.presence)
                self.shelfObservedAt = Date()
            }
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
                shelf.recordings,
                custody: self.custody,
                identity: RecordingDeviceIdentity(shape: .filePull, hardwareToken: hardwareToken))
        }
    }

    /// ONE FILE, ON ONE SESSION, AND THEN THE SHELF IS READ AGAIN.
    ///
    /// The re-read is not cosmetic: custody is the only thing that knows whether the file
    /// landed, so the row's "In Solleva" has to come from asking the disk again rather than
    /// from this method having been optimistic.
    /// - Parameter manager: the capture owner the finished conversation is handed to. Without
    ///   this the recording would be a complete, correct, pending-finalize capture directory
    ///   that NOTHING in the running app knows exists — `loadExisting()` runs once, at
    ///   construction — so it would sit there un-uploaded until the next launch. Handing it
    ///   over is one call, and it is the only line of this whole leg that is about the app
    ///   rather than about the recording.
    func bringOver(hardwareToken: String, advertisedName: String, into manager: CaptureManager) {
        guard !isChecking, !isBringingOver else { return }
        guard let recording = offeredRecording else { return }
        guard let identifier = UUID(uuidString: hardwareToken) else {
            bringOverMessage = PocketRecorderCheckPresentation.notThisRecorderLine
            return
        }
        isBringingOver = true
        bringOverMessage = nil
        Task {
            let outcome = await PocketBringOver.run(peripheralIdentifier: identifier,
                                                    advertisedName: advertisedName,
                                                    recording: recording,
                                                    custody: self.custody,
                                                    attachment: Self.makeAttachment(),
                                                    // THE OWNER'S OWN LIBRARY, ASKED FOR RATHER
                                                    // THAN GUESSED. The conversation must land in
                                                    // the directory this manager hydrates from;
                                                    // resolving it independently happens to
                                                    // agree today and is not guaranteed to.
                                                    destination: .init(
                                                        baseDir: manager.captureLibraryRoot))
            self.isBringingOver = false
            self.bringOverMessage = PocketBringOverPresentation.message(for: outcome)
            // THE HAND-OFF. From here it is the ordinary drain and the ordinary finalize — the
            // same two an Omi or phone-mic conversation runs, with nothing Pocket-shaped in
            // either of them.
            if let captureID = outcome.captureID {
                manager.adoptCompletedCapture(captureId: captureID)
            }
            // THE RE-READ CARRIES THE SAFETY EVIDENCE TOO. A bring-over that landed changes
            // BOTH of a row's phone-side facts — this phone now holds it, and once the drain
            // and finalize have run it becomes safe elsewhere — so re-reading without the
            // evidence would redraw the row it just changed as `Unknown` and put the recording
            // straight back into the reset's cost.
            self.run(hardwareToken: hardwareToken, advertisedName: advertisedName,
                     library: manager.captureLibraryRoot, stages: manager.captureStages())
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
