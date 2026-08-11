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
                                    sources: sources,
                                    isSavedOmi: isSavedOmi(identity),
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
    @ObservedObject var sources: CaptureSourceRegistry
    /// Only the remembered Omi has a transport in this build, so only it may offer connect /
    /// disconnect. A record-then-sync recorder gets an honest absence rather than a button
    /// that cannot complete (design §6c).
    let isSavedOmi: Bool
    let onChange: () -> Void

    @State private var showingEducation = false
    @State private var confirmingForget = false

    /// EVERY SLOT DECIDED IN THE KIT. This view passed `hasEducation: shape == .filePull` and
    /// `canForget: shape != .builtInMic` — two shape branches on a screen whose whole rule is
    /// that no surface switches on shape. Education now follows the negotiated protocol and
    /// forget follows the store record, both inside `resolve`, where Brine can hold them.
    private var page: RecordingDevicePagePresentation {
        RecordingDevicePage.resolve(input, canConnect: isSavedOmi)
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
        // THE WARNING THIS DEVICE'S CLASS EARNS. The key sentence is a claim about custody
        // FoundryX only has for a recorder it provisioned; showing it for a Bluetooth route
        // was a destructive-sounding promise about a key that does not exist.
        .alert(RecordingDevicePage.forgetAction, isPresented: $confirmingForget) {
            Button("Cancel", role: .cancel) {}
            Button(RecordingDevicePage.forgetAction, role: .destructive) { forget() }
        } message: {
            Text(page.forgetWarning ?? "")
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

    private func perform(_ title: String) {
        switch title {
        case RecordingDevicePage.educationAction:
            showingEducation = true
        case RecordingDevicePage.forgetAction:
            confirmingForget = true
        case RecordingDevicePage.disconnectAction:
            sources.setEnabled(CaptureSourceDescriptor.omiId, false)
            onChange()
        case RecordingDevicePage.connectAction, RecordingDevicePage.connectAndCheckAction:
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
        Task {
            await Self.forgetInTheStore(identity)
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

// MARK: - The one connection affordance's destination

/// "Connect a recording device" — one affordance, one list of whatever answered, and the
/// record-then-sync setup ceremony. Every string here is the shipped brand-free copy from
/// `RecordingDeviceConnectPresentation`; the scan rows show only the name each device
/// BROADCASTS, because a broadcast name is genuinely all the app knows before it connects.
private struct RecordingDeviceConnectSheet: View {
    @ObservedObject var device: DeviceManager
    let onDismiss: () -> Void

    @StateObject private var attach = RecordingDeviceAttachModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // NOTHING IS PINNED ABOVE WHAT ANSWERED THE SCAN. A hardcoded "Set up
                    // Pocket" row used to sit here, first, carrying a CLASS caption for a
                    // device the app had never connected to — a brand name above a person's
                    // actual device, which is "vendors first" in the one place the design
                    // draws two rows that read identically.
                    ForEach(device.discovered) { found in
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
                                    ? RecordingDeviceAttachPresentation.connectingLine
                                    : "Bluetooth · Tap to connect")
                        }
                        .buttonStyle(.plain)
                        .disabled(attach.attaching != nil)
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

                    if device.discovered.isEmpty {
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
                    if title == PocketSessionKeyEntryPresentation.entryAction {
                        attach.showKeyEntry()
                    } else {
                        attach.dismissCeremony()
                        onDismiss()
                    }
                }
                .keyEntry(message: attach.keyEntryMessage,
                          isSubmitting: attach.submittingKey,
                          onSubmit: { attach.submitExistingKey($0) })
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

// MARK: - The tap, and the chain it runs

/// THE APP SIDE OF THE ADOPTION CHAIN.
///
/// `RecordingDeviceAttachment` owns the radio work and returns what the transport actually
/// ESTABLISHED. This model owns nothing but the tap: which row is busy, which ceremony a tap
/// landed on, and the fall-through to the shipped pairing path. It derives no copy — every
/// string it shows comes from `RecordingDeviceAttachPresentation`.
///
/// THE FALL-THROUGH IS THE REASON OMI STILL PAIRS. `.live` and `.unrecognised` hand the tap
/// straight to `DeviceManager.connect`, unchanged, and so does every failure of the probe
/// itself — a stored-file leg that could swallow an Omi pairing would be a bad trade for a
/// device class nobody can attach yet.
@MainActor
final class RecordingDeviceAttachModel: ObservableObject {
    /// The row currently being attached, so it can say `Connecting…` and the rest can be
    /// disabled. One radio, one tap at a time.
    @Published private(set) var attaching: UUID?
    @Published private(set) var inlineMessage: String?
    @Published var showingCeremony = false
    @Published private(set) var ceremonyScreen: PocketOnboardingView.Screen = .setupUnavailable
    /// What the last submitted key earned, worded by `PocketSessionKeyEntryPresentation`.
    @Published private(set) var keyEntryMessage: String?
    @Published private(set) var submittingKey = false

    private var attachment: RecordingDeviceAttachment?
    /// The device the ceremony on screen belongs to. A key is entered for ONE recorder, and
    /// this is the only place that remembers which.
    private var ceremonyTarget: (id: UUID, name: String)?
    private var onAdopted: (() -> Void)?

    func attach(_ found: DiscoveredDevice,
                using device: DeviceManager,
                onAdopted: @escaping () -> Void) {
        guard attaching == nil else { return }
        attaching = found.id
        inlineMessage = nil
        keyEntryMessage = nil
        let attachment = RecordingDeviceAttachment()
        self.attachment = attachment
        let name = found.name
        let id = found.id
        ceremonyTarget = (id, name)
        self.onAdopted = onAdopted
        Task {
            let outcome = await attachment.attach(peripheralIdentifier: id, advertisedName: name)
            self.attaching = nil
            self.attachment = nil
            self.inlineMessage = RecordingDeviceAttachPresentation.inlineMessage(for: outcome)
            switch outcome {
            case .adopted:
                onAdopted()
            case .setupUnavailable:
                self.ceremonyScreen = .setupUnavailable
                self.showingCeremony = true
            case .recoveryRequired:
                self.ceremonyScreen = .didNotFinish
                self.showingCeremony = true
            case .live, .unrecognised:
                // THE SHIPPED PAIRING PATH, UNTOUCHED. This is the branch an Omi takes.
                device.connect(found)
                onAdopted()
            case .adoptionNotPersisted, .unreachable:
                break
            }
        }
    }

    func dismissCeremony() { showingCeremony = false }

    /// The owner said they already have this recorder's key. Swap the §3.6 screen for the
    /// field — the gated screen itself is untouched and still what an unentered tap lands on.
    func showKeyEntry() {
        keyEntryMessage = nil
        ceremonyScreen = .enterExistingKey
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
        Task {
            let outcome = await PocketSessionKeyEntryCoordinator.live()
                .submit(key: key, peripheralIdentifier: target.id, advertisedName: target.name)
            self.submittingKey = false
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
