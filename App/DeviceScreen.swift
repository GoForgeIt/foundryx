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
        case PocketKeyCustodyPresentation.entryAction:
            showingKeyCustody = true
            checkForRecoveryCopy()
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
                                    ? RecordingDeviceAttachPresentation.connectingLine
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
                    switch title {
                    case PocketSessionKeyEntryPresentation.entryAction:
                        attach.showKeyEntry()
                    // THE ONE TAP THAT CAN WRITE A KEY TO A RECORDER. It is the confirm action
                    // on the consent screen and nothing else — every other title here either
                    // navigates or closes.
                    case PocketMintConsentPresentation.confirmAction:
                        attach.confirmMintAfterOwnerConsent()
                    case PocketMintConsentPresentation.resetAction:
                        attach.showFactoryReset()
                    // DESIGN §3.7. The recorder is holding a key this phone could not store,
                    // and this is the one action that can still save it. It retries the
                    // Keychain; it never sends a second key.
                    case PocketSetupPresentation.retrySecureStorageAction:
                        attach.retrySecureStorageForAcceptedKey()
                    case PocketFactoryResetPresentation.retryAction,
                         PocketMintNotVerifiedPresentation.retryAction:
                        attach.showMintConsent()
                    // THE TWO STORAGE SCREENS RETRY FOR REAL. Their situation is the one that
                    // genuinely changes on its own — an iPhone gets unlocked, a Keychain
                    // answers — so "Try again" here re-runs the ordinary tap rather than
                    // closing the sheet. Matched on the screen as well as the title because
                    // several screens share the word and a dead button on the screen standing
                    // between an owner and their recorder is the failure this whole path
                    // exists to avoid.
                    case PocketSetupPresentation.retryAction
                        where attach.ceremonyScreen == .keyNotKept
                            || attach.ceremonyScreen == .custodyUnreadable:
                        attach.retryAfterStorageFailure()
                    case PocketKeyCustodyPresentation.entryAction:
                        attach.showKeyCustody()
                    default:
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
        let attachment = RecordingDeviceAttachment()
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

    /// THE ACTION ON THE TWO STORAGE SCREENS, AND IT IS A PLAIN TAP — `mint:` is left at its
    /// default, so this cannot write a key by construction.
    ///
    /// It is the honest retry for both states. `.custodyUnreadable` may simply have been a
    /// locked Keychain, and the same tap now restores and adopts. `.keyNotKept` re-runs the
    /// restore, finds no key (nothing was ever stored, because custody refused it before the
    /// recorder was asked), and lands back on the CONSENT screen — so a second mint still costs
    /// the owner an explicit confirmation rather than inheriting the first one.
    func retryAfterStorageFailure() {
        guard let target = ceremonyTarget, !submittingKey else { return }
        submittingKey = true
        let attachment = RecordingDeviceAttachment()
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
            case .recoveryRequired, .live, .unrecognised, .adoptionNotPersisted, .unreachable:
                self.ceremonyScreen = .didNotFinish
            }
        }
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
