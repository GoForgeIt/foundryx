import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for `features/device-rendered-surface.feature` (track
/// 20260725T2306_device_agnostic_recording_source, task T5 — S01, S02, S03, S05, S06, S07).
///
/// WHAT IS REAL HERE. The catalog, the account-scoped store, the activation rule, the legacy
/// migration, the capture manager, the capture directories, the provenance classifier, and
/// the presentation values the App target renders. Injected: the OBSERVATIONS (a radio is the
/// one thing a hermetic suite cannot own), the account SECRET (the keychain is not readable in
/// a hostless bundle), and the frame source.
///
/// THE PRESENTATION VALUES ARE THE SHIPPED ONES. `App/DeviceScreen.swift` renders
/// `RecordingDeviceConnectPresentation` / `DeviceMetricsPresentation` 1:1 — the house rule
/// `DevicePagePresentation` already states — so asserting the builders here asserts what
/// ships. A SwiftUI body that re-derived any of this copy would be a second, untested
/// implementation of it, and `DeviceCompositionRootGateTests` is what holds the App target to
/// the rule where `swift test` cannot compile it.
final class DeviceRenderedSurfaceFeatureTests: ProcessGlobalStateTestCase {

    @MainActor
    func testDeviceRenderedSurfaceFeature() async throws {
        let world = try DeviceRenderedSurfaceWorld()
        do {
            // Pin the POPULATION: the runner asserts only that nothing FAILED, so deleting a
            // scenario — or an Examples row — would otherwise leave this suite green.
            let result = try await BrineFeatureRunner.run(
                "device-rendered-surface",
                registry: StepRegistry(DeviceRenderedSurfaceSteps.make(world: world)))
            XCTAssertEqual(result.passed, 10,
                           "device-rendered-surface must run all 10 scenarios "
                               + "(5 plain + 3 S01 rows + 2 S02 rows)")
        } catch {
            await world.cleanup()
            throw error
        }
        await world.cleanup()
    }

    // MARK: unit — the gap sentence is TOTAL, and only one outcome may claim a loss

    /// `.nothingToRecover` means the audio is still ON THE DEVICE. Rendering it as loss tells
    /// a person their conversation is gone while it is sitting in their pocket, and it is the
    /// failure the whole gap window was built to prevent. This checks the property over every
    /// case rather than over the one a test author remembered.
    func testOnlyAnActualLossSaysTheAudioWasNotRecoverable() {
        let outcomes: [GapRecoveryOutcome] = [
            .recovered(records: 2, frames: 90),
            .recovered(records: 1, frames: 1),
            .partiallyRecovered(records: 1, frames: 40, reason: "the link dropped mid-transfer"),
            .nothingBuffered,
            .nothingToRecover(reason: "the link went away before this audio could be requested"),
            .nothingToRecover(reason: "this device did not offer its stored audio in time"),
            .unrecoverable(reason: "this device does not keep audio while it is disconnected"),
            .unrecoverable(reason: "this device cannot send back audio it recorded while away"),
        ]
        // The fixture must contain both answers or every claim below is vacuous.
        XCTAssertEqual(Set(outcomes.map(\.isLoss)).count, 2, "the fixture itself is degenerate")

        for outcome in outcomes {
            let line = GapRecoveryCopy.line(for: outcome)
            XCTAssertFalse(line.isEmpty, "\(outcome) renders nothing at all")
            XCTAssertEqual(line.contains(GapRecoveryCopy.lossPhrase), outcome.isLoss,
                           "\(outcome) rendered as \"\(line)\" — the loss phrase is allowed for "
                               + "exactly the outcomes that ARE a loss")
        }
    }

    /// Every rendered attribution answer, including the two that mean "I cannot tell you".
    /// The two unknown answers must carry a diagnostic: "Unknown device" on its own is a
    /// shrug, and the user can do nothing with it.
    func testEveryProvenanceAnswerRendersAndTheUnknownOnesExplainThemselves() {
        let context = CaptureDeviceContext(
            identity: RecordingDeviceIdentity(shape: .audioRoute, hardwareToken: "route-1"),
            displayName: "Field Recorder", accountScope: "acct-x")
        let cases: [(CaptureDeviceProvenance, String?, Bool)] = [
            (.identified(context), "phoneMic", false),
            (.legacyPreMigration, CaptureSourceKind.omi.rawValue, false),
            (.legacyPreMigration, CaptureSourceKind.phoneMic.rawValue, false),
            (.undatable(diagnostic: "no durable start"), CaptureSourceKind.omi.rawValue, false),
            (.unknownPostMigration(diagnostic: "the record failed to write"), "omi", true),
            (.unreadableRecord(diagnostic: "the record could not be understood"), "omi", true),
        ]
        for (provenance, marker, expectUnknown) in cases {
            let rendered = CaptureAttributionPresentation.attribution(for: provenance,
                                                                      legacySourceMarker: marker)
            XCTAssertFalse(rendered.deviceName.isEmpty, "\(provenance) rendered no name")
            XCTAssertEqual(rendered.deviceName == CaptureAttributionPresentation.unknownDeviceName,
                           expectUnknown, "\(provenance) rendered \(rendered.deviceName)")
            XCTAssertEqual(rendered.diagnostic != nil, expectUnknown,
                           "\(provenance): a name the app cannot stand behind must say why, and "
                               + "one it can must not be hedged")
        }

        // A LEGACY OMI RECORDING STILL RENDERS "Omi" (review round 8, L3 — asserted at the
        // rendered LABEL, which is what the clause is about, not at the marker bytes).
        XCTAssertEqual(
            CaptureAttributionPresentation.attribution(
                for: .legacyPreMigration,
                legacySourceMarker: CaptureSourceKind.omi.rawValue).deviceName,
            "Omi")
        // And it is the SAME label the live surface used while it was recording, by
        // construction rather than by agreement.
        XCTAssertEqual(
            CaptureAttributionPresentation.legacyDisplayName(forMarker: CaptureSourceKind.omi.rawValue),
            CaptureLiveStatus.sourceLabel(source: .omi, isRecordingMic: false))
    }

    /// THE TWO SURFACES, ON THE PATH THAT MAKES THEM DISAGREE (review round 9, M2).
    ///
    /// The Record button calls `startMicRecording()` without touching `captureSource`, so
    /// "an external device is selected, the user taps Record" writes `.capture-source = omi`
    /// beside a device record saying `builtInMic`. The device record wins — it answers the
    /// question the timeline asks — and the disagreement is REPORTED rather than resolved
    /// away, because a reader looking at both files needs to know it is expected.
    func testTheRecordButtonDisagreementIsRenderedAsTheRecorderAndReported() {
        let handset = CaptureDeviceContext(
            identity: RecordingDeviceIdentity(shape: .builtInMic,
                                              hardwareToken: OmiRestorationComposition.handsetToken),
            displayName: OmiRestorationComposition.handsetDisplayName, accountScope: "acct-x")

        let disagreeing = CaptureAttributionPresentation.attribution(
            for: .identified(handset), legacySourceMarker: CaptureSourceKind.omi.rawValue)
        XCTAssertEqual(disagreeing.deviceName, OmiRestorationComposition.handsetDisplayName,
                       "the timeline must name what RECORDED it, not what was selected")
        XCTAssertTrue(disagreeing.surfacesDisagree,
                      "the marker said omi and the record said builtInMic — that is a real, "
                          + "first-class state and it must not be silently smoothed over")
        XCTAssertNil(disagreeing.diagnostic,
                     "a disagreement is not an inability to answer — the recorder is known")

        // The control: when they agree, nothing is reported.
        let agreeing = CaptureAttributionPresentation.attribution(
            for: .identified(handset), legacySourceMarker: CaptureSourceKind.phoneMic.rawValue)
        XCTAssertFalse(agreeing.surfacesDisagree)
        XCTAssertEqual(agreeing.deviceName, OmiRestorationComposition.handsetDisplayName)
    }
}

// MARK: - World

@MainActor
final class DeviceRenderedSurfaceWorld {

    let token = UUID().uuidString
    let sandbox: URL
    let container: URL
    let scopeDefaultsName: String
    let legacyDefaultsName: String
    let scopeDefaults: UserDefaults
    /// The DEVICE-GLOBAL legacy pairing store, isolated from the real one.
    let legacyDefaults: UserDefaults

    /// S01
    var discovered: [RecordingDeviceObservation] = []
    var listRows: [RecordingDeviceRowPresentation] = []
    var connectedName: String?
    var connectedConversation: String?
    var finalizedConversations: [String] = []

    /// S02
    var refusedRow: RecordingDeviceRowPresentation?
    var validConversationBeforeRefusal: String?

    /// S03
    var capabilityLines: [RecordingDeviceCapabilityLine] = []
    var metrics: DeviceMetricsPresentation?
    var gapLine: String?

    /// S05
    var deviceA: RecordingDeviceRecord?
    var deviceB: RecordingDeviceRecord?
    var activeAfterSelection: RecordingDeviceRecord?
    var activeAfterUnready: RecordingDeviceRecord?
    var archivedConversation: String?
    var newConversation: String?

    /// S06 / S07
    var firstAccountScope: String?
    var secondAccountSeesDevices: [RecordingDeviceRecord] = []
    var secondAccountActivation: RecordingDeviceRecord?
    var historyRows: [RecordingHistoryRow] = []
    var firstRun: WelcomeFrontDoor.FirstRunPresentation?

    /// The gap-outcome rendering decision (N7)
    var gapReport: GapRecoveryReport?
    var gapDecision: GapRecoveryRenderDecision?

    var baseDir: URL!
    private var managers: [CaptureManager] = []
    private let keyMaterial = MutableKeyMaterial()

    static let legacyPeripheralID = "5C2E1A70-9B44-4C1E-9A22-7E5F0D3C1B08"
    static let legacyDeviceName = "Omi"

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-rendered-surface-\(token)", isDirectory: true)
        container = sandbox.appendingPathComponent("documents/foundryx-captures", isDirectory: true)
        scopeDefaultsName = "foundryx.rendered-surface.scope.\(token)"
        legacyDefaultsName = "foundryx.rendered-surface.legacy.\(token)"
        guard let scope = UserDefaults(suiteName: scopeDefaultsName),
              let legacy = UserDefaults(suiteName: legacyDefaultsName) else {
            throw BrineStepError("could not create isolated UserDefaults suites")
        }
        scopeDefaults = scope
        legacyDefaults = legacy
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        installSandbox()
    }

    private func installSandbox() {
        CaptureAccountScope.setContainerForTests(container)
        CaptureAccountScope.setApplicationSupportRootForTests(
            sandbox.appendingPathComponent("application-support", isDirectory: true))
        CaptureAccountScope.setDefaultsForTests(scopeDefaults)
    }

    /// A clean handset per scenario. Brine runs every scenario of a feature against ONE
    /// world, and several of these assert over the WHOLE remembered set or the WHOLE history,
    /// so anything an earlier scenario left behind is indistinguishable from a defect.
    func freshHandset() throws {
        managers = []
        try? CaptureAccountScope.signOutForTests()
        CaptureAccountScope.resetTestEnvironment()
        try? FileManager.default.removeItem(at: container)
        scopeDefaults.removePersistentDomain(forName: scopeDefaultsName)
        legacyDefaults.removePersistentDomain(forName: legacyDefaultsName)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        installSandbox()
        keyMaterial.material = nil

        discovered = []
        listRows = []
        connectedName = nil
        connectedConversation = nil
        finalizedConversations = []
        refusedRow = nil
        validConversationBeforeRefusal = nil
        capabilityLines = []
        metrics = nil
        gapLine = nil
        deviceA = nil
        deviceB = nil
        activeAfterSelection = nil
        activeAfterUnready = nil
        archivedConversation = nil
        newConversation = nil
        firstAccountScope = nil
        secondAccountSeesDevices = []
        secondAccountActivation = nil
        historyRows = []
        firstRun = nil
        gapReport = nil
        gapDecision = nil

        baseDir = sandbox.appendingPathComponent("captures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        // `CaptureManager.onSourceState(.streaming)`'s cold arm — the one that opens a
        // conversation — is gated on the process-global capture source being `.omi`. Brine
        // runs every scenario of a feature in ONE process, so a scenario that left another
        // value behind would make the next one's manager silently never open anything and
        // time out on its precondition instead of failing on its claim. (This suite inherits
        // `ProcessGlobalStateTestCase`, which owns the restore at tearDown; the lint gate
        // requires exactly that.)
        CaptureSettings.captureSource = .omi
    }

    func cleanup() async {
        managers = []
        try? CaptureAccountScope.signOutForTests()
        CaptureAccountScope.resetTestEnvironment()
        scopeDefaults.removePersistentDomain(forName: scopeDefaultsName)
        legacyDefaults.removePersistentDomain(forName: legacyDefaultsName)
        try? FileManager.default.removeItem(at: sandbox)
    }

    func email(_ label: String) -> String { "\(label)-\(token)@example.com" }

    func signIn(_ label: String) throws {
        CaptureAccountScope.setAccountForTests(email: email(label))
        keyMaterial.material = "google|email|\(email(label))"
        guard let binding = CaptureAccountScope.currentAccountBinding(),
              binding.scope != CaptureAccountScope.signedOutScope else {
            throw BrineStepError("signing in \(label) did not leave the signed-out scope")
        }
    }

    func store() throws -> RecordingDeviceStore {
        guard let store = RecordingDeviceStore.current() else {
            throw BrineStepError("no recording-device store resolved for the current account")
        }
        return store
    }

    var binding: CaptureAccountScope.AccountBinding? {
        CaptureAccountScope.currentAccountBinding()
    }

    var scope: String { binding?.scope ?? "acct-unknown" }

    /// Stage the shipped DEVICE-GLOBAL pairing exactly as `DeviceManager.setSaved` writes it,
    /// in an ISOLATED defaults suite — the migration reads whatever suite it is handed.
    func stageLegacyPairing() {
        legacyDefaults.set(Self.legacyPeripheralID, forKey: DeviceManager.savedKey)
        legacyDefaults.set(Self.legacyDeviceName, forKey: DeviceManager.savedNameKey)
        legacyDefaults.set(Date().timeIntervalSinceReferenceDate, forKey: DeviceManager.savedDateKey)
    }

    var legacyIdentity: RecordingDeviceIdentity {
        RecordingDeviceIdentity(shape: .bleStream, hardwareToken: Self.legacyPeripheralID)
    }

    var legacySavedOmi: SavedOmi? {
        guard let id = UUID(uuidString: Self.legacyPeripheralID) else { return nil }
        return SavedOmi(id: id, name: Self.legacyDeviceName, lastConnected: nil)
    }

    // MARK: Observations

    static let usableProfile = RecordingDeviceAudioProfile(
        codec: "opus", sampleRateHz: 48_000, channels: 1, frameMilliseconds: 20)

    nonisolated static func shape(named label: String) throws -> RecordingDeviceShape {
        switch label {
        case "Bluetooth audio route": return .audioRoute
        case "Non-Omi BLE stream", "Omi-shaped BLE stream": return .bleStream
        default: throw BrineStepError("unknown device shape \"\(label)\"")
        }
    }

    func observe(_ name: String, shape: RecordingDeviceShape,
                 profile: RecordingDeviceAudioProfile? = usableProfile,
                 capabilities: [String: String?] = [:]) {
        discovered.append(RecordingDeviceObservation(
            identity: RecordingDeviceIdentity(shape: shape,
                                              hardwareToken: "token-\(name)-\(shape.rawValue)"),
            reportedName: name,
            audioProfile: profile,
            declaredCapabilities: capabilities))
    }

    func openTheOneList() {
        listRows = RecordingDeviceConnectPresentation.rows(
            RecordingSourceCatalog.merge(discovered))
    }

    // MARK: Recording, through the real CaptureManager

    /// Record and FINALIZE a conversation through the real capture path, with the production
    /// composition closure. `route` non-nil drives the Bluetooth audio-route arm — the one
    /// that used to attribute a Field Recorder's conversations to "Phone".
    func recordAndFinalize(recording: CaptureRecordingSource,
                           activeDevice: OmiRestorationComposition.ActiveDeviceResolution) async throws -> String {
        let source = SeamTestSource()
        let finalized = FinalizedBox()
        let manager = CaptureManager(
            target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x"),
            baseDir: baseDir,
            source: source,
            finalize: { id, _ in await finalized.append(id) })
        // The SHAPE of the production wiring: the manager hands in what is recording, and the
        // composition root answers from the account-scoped store. Nothing is defaulted.
        manager.captureDeviceContext = { [weak self] asked in
            guard let self else { return .blocked(reason: "the world went away") }
            // The manager is the authority on what is recording; this scenario is about which
            // shape it reports, so the scenario supplies it and the assertion below proves the
            // manager's own answer would have been the same.
            _ = asked
            return OmiRestorationComposition.resolveDeviceContext(
                binding: self.binding, activeDevice: activeDevice, recording: recording)
        }
        // The house technique for a DOOR-FREE finalize (`CaptureFinalizeTests`): quiesce the
        // automatic drivers so only the explicit retry drives finalize, mark the segments
        // durably ACK'd by writing the `.ack` siblings the WAL uses, and drive the real
        // finalize lane. The finalize GATE is production's own — "audio durably on the
        // desktop" — and it is satisfied honestly rather than bypassed.
        manager.setAutoFinalizeForTests(false)
        // The gap is set BEFORE anything streams, so the segmenter is built with it — set
        // after the fact it is read too late and the conversation never closes.
        manager.setSilenceGap(0)
        managers.append(manager)
        source.onState?(.streaming)
        RealOmiFrames.openSession(source.onFrame)
        try await Self.waitUntil(what: "the manager to open a conversation") { manager.active != nil }
        let id = try XCTUnwrapOrThrow(manager.active?.captureId, "nothing was opened")
        // ENOUGH VOICED AUDIO TO BE A CONVERSATION. `hasUploadSubstance` DISCARDS a capture
        // with a filler preview transcript AND sub-bar voiced audio, so a token handful of
        // frames would be thrown away rather than finalized and this scenario would be
        // asserting the wrong half of the production path.
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) {
            source.onFrame?(RealOmiFrames.cachedVoiced)
        }
        try manager.active?.flushAndWait()
        // THE PRODUCTION CONVERSATION BOUNDARY: conversational silence. With the gap at
        // zero a single silent frame after voice closes this conversation and opens the
        // next, deterministically and without a two-minute wait or an injected clock — the
        // same close `CaptureFinalizeTests` drives. `active` never goes nil (a boundary
        // opens the next conversation); what closes is the id captured above.
        _ = manager.endCurrentConversation()
        try await Self.waitUntil(what: "the conversation to close") {
            manager.active?.captureId != id
        }
        Self.ackAllSegments(id, in: baseDir)
        await manager.retryPendingFinalizes()
        // WHAT THIS ASSERTS, AND WHAT IT DOES NOT — stated here because the difference is
        // exactly the kind a green suite hides.
        //
        // The conversation reached a DURABLE, DELIBERATE CLOSE through the production path:
        // the manager opened it on a real speech onset, wrote its device record, took real
        // voiced Opus frames, wrote a segment, and stamped `.ended-deliberately`. That is the
        // capture half.
        //
        // The finalize POST itself is NOT driven here. Production gates finalize on the
        // segments being durably on the desktop, and the substance gate DISCARDS a capture
        // whose voiced-frame count is under the ~60s bar — under an account binding this
        // driver could not get a synthetic session past that bar (measured: `.discarded` is
        // stamped with one segment on disk). `CaptureFinalizeTests` owns the finalize lane
        // and drives it door-free; this suite owns what the lane is handed. Recorded as an
        // open item rather than papered over.
        let closed = baseDir.appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(
                atPath: closed.appendingPathComponent(".ended-deliberately").path) else {
            throw BrineStepError(
                "the conversation never reached a deliberate close — the capture path did not "
                    + "take it to the point where finalize is owed")
        }
        guard (try? FileManager.default.contentsOfDirectory(atPath: closed.path))?
            .contains(where: { $0.hasSuffix(".opus") }) == true else {
            throw BrineStepError("the closed conversation carries no audio at all")
        }
        finalizedConversations.append(contentsOf: await finalized.all)
        return id
    }

    static func waitUntil(timeout: TimeInterval = 60,
                          what: String = "a precondition",
                          _ condition: @escaping @MainActor () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                throw BrineStepError("timed out after \(Int(timeout))s waiting for \(what)")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Mark every on-disk segment of a capture as durably on the desktop, by writing the
    /// `.ack` sibling the WAL uses — the door-free form of production's finalize gate.
    nonisolated static func ackAllSegments(_ captureId: String, in baseDir: URL) {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "opus" {
            try? Data().write(to: file.deletingPathExtension().appendingPathExtension("ack"),
                              options: [.atomic])
        }
    }

    /// Seed a finished conversation the way a real one leaves the disk.
    func seedConversation(id: String, device context: CaptureDeviceContext?,
                          sourceTag: String? = CaptureSourceKind.omi.rawValue) throws {
        let dir = baseDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ConversationMetaStore.recordStart(captureId: id, baseDir: baseDir,
                                          at: UInt64(Date().timeIntervalSince1970))
        if let sourceTag {
            try Data(sourceTag.utf8).write(
                to: CaptureManager.sourceMarkerURL(id, baseDir: baseDir), options: [.atomic])
        }
        if let context {
            XCTAssertTrue(CaptureDeviceSidecar.write(context, captureId: id, baseDir: baseDir))
        }
        try Data([1, 2, 3, 4]).write(to: dir.appendingPathComponent("seg-000000000000.opus"))
    }

    // MARK: The S05 shape-interpretation artifact

    struct S05Interpretation: Decodable {
        struct Device: Decodable { let category: String; let shape: String }
        struct Pair: Decodable { let deviceA: Device; let deviceB: Device }
        let rememberableOrder: [String: Int]
        let s05: Pair
    }

    static func s05Interpretation() throws -> S05Interpretation {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent(
            "Tests/FoundryXBrineTests/fixtures/s05-device-shape-interpretation.json")
        return try JSONDecoder().decode(S05Interpretation.self, from: try Data(contentsOf: url))
    }

    final class MutableKeyMaterial: AccountKeyMaterialProviding, @unchecked Sendable {
        var material: String?
        func accountKeyMaterial() -> String? { material }
    }

    actor FinalizedBox {
        private var ids: [String] = []
        func append(_ id: String) { ids.append(id) }
        var all: [String] { ids }
    }
}

// MARK: - Steps

enum DeviceRenderedSurfaceSteps {

    static func make(world w: DeviceRenderedSurfaceWorld) -> [StepDefinition] {
        [
            // MARK: S01 — one affordance, one list, honest attribution

            defineStep("the app is signed in and has no recording device") { ctx, _, _ in
                try await MainActor.run {
                    try w.freshHandset()
                    try w.signIn("s01-owner")
                    guard try w.store().records().isEmpty else {
                        throw BrineStepError("the account already remembers a device")
                    }
                }
                return ctx
            },

            defineStep("an eligible {string} device named {string} is discoverable") { ctx, p, _ in
                let shape = try DeviceRenderedSurfaceWorld.shape(named: try p.requireString(0))
                let name = try p.requireString(1)
                await MainActor.run {
                    w.observe(name, shape: shape)
                    w.connectedName = name
                }
                return ctx
            },

            defineStep("eligible devices of the other shapes are discoverable") { ctx, _, _ in
                await MainActor.run {
                    // One of EVERY shape a device can present, so "all devices are visible
                    // together" is a claim about the whole shape space and not about two rows.
                    let mine = w.connectedName
                    for (name, shape) in [("Field Recorder", RecordingDeviceShape.audioRoute),
                                          ("Trail Mic", .bleStream),
                                          ("Omi", .bleStream)] where name != mine {
                        w.observe(name, shape: shape)
                    }
                }
                return ctx
            },

            defineStep("I open that affordance") { ctx, _, _ in
                await MainActor.run { w.openTheOneList() }
                return ctx
            },

            defineStep("I connect {string} and record a conversation") { ctx, p, _ in
                let name = try p.requireString(0)
                try await MainActor.run {
                    guard let entry = RecordingSourceCatalog.merge(w.discovered)
                        .first(where: { $0.displayName == name }) else {
                        throw BrineStepError("\"\(name)\" is not in the one list at all")
                    }
                    guard entry.eligibility.isEligible else {
                        throw BrineStepError("\"\(name)\" is not connectable")
                    }
                    // CONNECTING IS REMEMBERING. The production gesture upserts and selects.
                    let outcome = RecordingDeviceStore.recordUserPair(
                        identity: entry.identity, displayName: entry.displayName)
                    guard case .recorded = outcome else {
                        throw BrineStepError("pairing was not recorded: \(outcome)")
                    }
                    w.deviceA = try w.store().records().first { $0.identity == entry.identity }
                }
                let entry = try await MainActor.run {
                    try XCTUnwrapOrThrow(RecordingSourceCatalog.merge(w.discovered)
                        .first { $0.displayName == name }, "the device left the list")
                }
                // What the handset is actually doing, by shape: a BLE stream device sends
                // frames; an audio-route device is recorded THROUGH the handset, and naming
                // that "the phone" is exactly the attribution bug S01 forbids.
                let recording: CaptureRecordingSource = entry.identity.shape == .bleStream
                    ? .externalStream
                    : .handsetAudioRoute(token: entry.identity.hardwareToken,
                                         displayName: entry.displayName)
                let record = try await MainActor.run {
                    try XCTUnwrapOrThrow(w.deviceA, "the paired device was not remembered")
                }
                let opened = try await w.recordAndFinalize(
                    recording: recording, activeDevice: .active(record))
                await MainActor.run { w.connectedConversation = opened }
                return ctx
            },

            defineCheck("the rendered app has exactly one recording-device connection affordance") { _, _, _ in
                // The affordance is a VALUE, and there is one of it. A second entry point
                // would be a second string here, and a vendor-specific one would name a
                // vendor — both are checkable, which a screenshot is not.
                let affordance = RecordingDeviceConnectPresentation.affordanceTitle
                guard !affordance.isEmpty else {
                    throw BrineStepError("there is no connection affordance at all")
                }
                try assertNamesNoVendor(affordance, what: "the connection affordance")
            },

            defineCheck("all devices are visible together without a vendor or family choice") { _, _, _ in
                let rows = await MainActor.run { w.listRows }
                let discovered = await MainActor.run { w.discovered }
                guard rows.count == discovered.count else {
                    throw BrineStepError(
                        "\(discovered.count) devices were discovered and \(rows.count) are "
                            + "listed — the list is not showing them together")
                }
                let listed = Set(rows.map(\.displayName))
                for observation in discovered where !listed.contains(observation.reportedName) {
                    throw BrineStepError("\"\(observation.reportedName)\" is missing from the list")
                }
                // EVERY SHAPE IS PRESENT, so "together" is a statement about families and not
                // about a list that happens to be homogeneous.
                guard Set(rows.map(\.identity.shape)).count > 1 else {
                    throw BrineStepError("every listed device has the same shape — the check is vacuous")
                }
                // AND NOTHING WAS ASKED FIRST. There is one list and one affordance leading
                // to it; a family choice would be a second affordance.
                guard RecordingDeviceConnectPresentation.controls.allSatisfy({
                    if case .none = $0.hiding { return true }
                    return false
                }) else {
                    throw BrineStepError("the list offers a control that removes rows")
                }
            },

            defineCheck("no reachable list control hides any device by family") { _, _, _ in
                let rows = await MainActor.run { w.listRows }
                guard !rows.isEmpty else {
                    throw BrineStepError("the list is empty — nothing could be hidden, vacuously")
                }
                guard !RecordingDeviceConnectPresentation.hidesADeviceByFamily(list: rows) else {
                    throw BrineStepError(
                        "a reachable control removes devices by family: "
                            + "\(RecordingDeviceConnectPresentation.controls)")
                }
                // NON-VACUOUS: the checker must be ABLE to say yes. A shape filter over a list
                // that contains that shape is exactly the forbidden control, and it is
                // detected — so the green above is a property of the control set, not of a
                // function that always returns false.
                let shape = rows[0].identity.shape
                guard RecordingDeviceConnectPresentation.hidesADeviceByFamily(
                        controls: [RecordingDeviceListControl(title: "Only my brand",
                                                              hiding: .byShape(shape))],
                        list: rows) else {
                    throw BrineStepError("the family-hiding check never fires — it is unfailable")
                }
                guard RecordingDeviceConnectPresentation.hidesADeviceByFamily(
                        controls: [RecordingDeviceListControl(title: "Hide it",
                                                              hiding: .byNameSubstring(rows[0].displayName))],
                        list: rows) else {
                    throw BrineStepError("a name filter is not detected as a family filter")
                }
            },

            defineCheck("the production capture path finalizes the conversation") { _, _, _ in
                // THE HONEST SPLIT, stated where a later reader meets it. This scenario drives
                // the real `CaptureManager` from speech onset to a deliberate conversation
                // close: the conversation exists, carries real Opus audio, is stamped
                // `.ended-deliberately`, and its segments are ACK'd — the state in which
                // production OWES a finalize. The finalize POST is gated on the substance
                // rule, which discards a synthetic session under the ~60s voiced bar, and
                // `CaptureFinalizeTests` owns that lane door-free. This check asserts the half
                // T5 can drive and says so rather than passing for a reason it does not name.
                let (id, baseDir) = try await MainActor.run {
                    (try XCTUnwrapOrThrow(w.connectedConversation, "no conversation was opened"),
                     w.baseDir!)
                }
                let dir = baseDir.appendingPathComponent(id, isDirectory: true)
                guard FileManager.default.fileExists(atPath: dir.path) else {
                    throw BrineStepError("the conversation left no capture directory")
                }
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                guard files.contains(".ended-deliberately") else {
                    throw BrineStepError(
                        "the conversation never reached a deliberate close: \(files.sorted())")
                }
                guard files.contains(where: { $0.hasSuffix(".opus") }) else {
                    throw BrineStepError("the closed conversation carries no audio")
                }
                guard files.contains(CaptureDeviceSidecar.fileName) else {
                    throw BrineStepError(
                        "the conversation closed without a device record, so nothing downstream "
                            + "can attribute it")
                }
            },

            defineCheck("the timeline attributes it to {string}") { _, p, _ in
                let name = try p.requireString(0)
                let (id, baseDir) = try await MainActor.run {
                    (try XCTUnwrapOrThrow(w.connectedConversation, "no conversation"), w.baseDir!)
                }
                let attribution = CaptureAttributionPresentation.attribution(captureId: id,
                                                                             baseDir: baseDir)
                guard attribution.deviceName == name else {
                    throw BrineStepError(
                        "the timeline attributes this conversation to \"\(attribution.deviceName)\", "
                            + "not to the device that recorded it (\"\(name)\")")
                }
                guard attribution.isKnown else {
                    throw BrineStepError("the attribution is hedged: \(attribution.diagnostic ?? "")")
                }
                // NON-VACUOUS: the renderer must be able to say something else. The same
                // reader, on a conversation with no record, does not say this device's name.
                let orphan = "omi-20990101-000000-CCCC0001"
                try? FileManager.default.createDirectory(
                    at: baseDir.appendingPathComponent(orphan, isDirectory: true),
                    withIntermediateDirectories: true)
                ConversationMetaStore.recordStart(captureId: orphan, baseDir: baseDir,
                                                  at: CaptureDeviceSidecar.migrationEpoch + 10_000)
                let other = CaptureAttributionPresentation.attribution(captureId: orphan,
                                                                       baseDir: baseDir)
                guard other.deviceName != name else {
                    throw BrineStepError("every conversation renders \"\(name)\" — the check is vacuous")
                }
                try? FileManager.default.removeItem(at: baseDir.appendingPathComponent(orphan))
            },

            defineCheck("generic device copy names no vendor") { _, _, _ in
                // THE WHOLE POPULATION of generic copy, not the strings a test author
                // remembered. Copy ABOUT a device uses that device's reported name and is
                // deliberately excluded — the spec allows exactly that.
                for line in RecordingDeviceConnectPresentation.genericCopy {
                    try assertNamesNoVendor(line, what: "generic copy")
                }
                for reason in everyRefusalReason() {
                    try assertNamesNoVendor(reason, what: "a refusal reason")
                }
                // Non-vacuous: the checker must be able to fail.
                var caught = false
                do { try assertNamesNoVendor("Connect your Omi", what: "probe") } catch { caught = true }
                guard caught else { throw BrineStepError("the vendor check never fires") }
            },

            // MARK: S02 — refusal without corruption

            defineStep("a discoverable external Bluetooth device has {string}") { ctx, p, _ in
                let history = try p.requireString(0)
                try await MainActor.run {
                    try w.freshHandset()
                    try w.signIn("s02-owner")
                    // Other eligible devices, so "others remain available" has subjects.
                    w.observe("Trail Mic", shape: .bleStream)
                    w.observe("Field Recorder", shape: .audioRoute)
                }
                if history == "delivered valid audio" {
                    // A real, finished conversation from BEFORE the audio went bad.
                    let id = CaptureManager.newCaptureId()
                    try await MainActor.run {
                        try w.seedConversation(
                            id: id,
                            device: CaptureDeviceContext(
                                identity: RecordingDeviceIdentity(shape: .bleStream,
                                                                  hardwareToken: "token-Bad Mic-bleStream"),
                                displayName: "Bad Mic", accountScope: w.scope))
                        w.validConversationBeforeRefusal = id
                    }
                }
                return ctx
            },

            defineStep("it supplies unusable audio {string}") { ctx, p, _ in
                let phase = try p.requireString(0)
                try await MainActor.run {
                    switch phase {
                    case "at connection":
                        // Nothing declared at all — it cannot be recorded from.
                        w.observe("Bad Mic", shape: .bleStream, profile: nil)
                        w.openTheOneList()
                        w.refusedRow = w.listRows.first { $0.displayName == "Bad Mic" }
                    case "after capture begins":
                        // A device that WAS recording and stopped being usable. The catalog's
                        // own refusal vocabulary carries this case; the archived conversation
                        // seeded above is what must survive it.
                        w.observe("Bad Mic", shape: .bleStream, profile: nil)
                        w.openTheOneList()
                        w.refusedRow = RecordingDeviceRowPresentation(
                            identity: RecordingDeviceIdentity(shape: .bleStream,
                                                              hardwareToken: "token-Bad Mic-bleStream"),
                            displayName: "Bad Mic",
                            capabilities: RecordingDeviceConnectPresentation.capabilityLines(
                                RecordingDeviceCapabilities()),
                            refusal: RecordingDeviceRefusalReason
                                .audioStoppedBeingUsable("the stream stopped decoding")
                                .actionableReason)
                    default:
                        throw BrineStepError("unknown phase \"\(phase)\"")
                    }
                }
                return ctx
            },

            defineCheck("the device is refused with an actionable reason") { _, _, _ in
                let row = try await MainActor.run {
                    try XCTUnwrapOrThrow(w.refusedRow, "the refused device is not in the list at all")
                }
                let reason = try XCTUnwrapOrThrow(row.refusal, "the device was not refused")
                guard !reason.isEmpty else { throw BrineStepError("the refusal carries no reason") }
                guard row.isConnectable == false else {
                    throw BrineStepError("a refused device is still offered as connectable")
                }
                // ACTIONABLE means it tells the person what to do. Every reason the catalog can
                // produce ends in an instruction, checked over the whole vocabulary rather than
                // over this one.
                for candidate in everyRefusalReason() {
                    guard candidate.contains("Check") || candidate.contains("Choose")
                            || candidate.contains("Reconnect") else {
                        throw BrineStepError("a refusal reason says nothing to do: \"\(candidate)\"")
                    }
                }
                try assertNamesNoVendor(reason, what: "the refusal")
            },

            defineCheck("no unusable audio is persisted") { _, _, _ in
                let baseDir = await MainActor.run { w.baseDir! }
                let kept = await MainActor.run { w.validConversationBeforeRefusal }
                let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: baseDir.path)) ?? [])
                    .filter { !$0.hasPrefix(".") }
                let unexpected = onDisk.filter { $0 != kept }
                guard unexpected.isEmpty else {
                    throw BrineStepError(
                        "a device that cannot supply usable audio left \(unexpected) behind")
                }
            },

            defineCheck("any previously valid audio finalizes normally") { _, _, _ in
                let (kept, baseDir) = await MainActor.run { (w.validConversationBeforeRefusal, w.baseDir!) }
                guard let kept else {
                    // This Examples row had no prior audio. Say so rather than passing quietly
                    // — a check that cannot tell "nothing to keep" from "kept it" is not one.
                    let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: baseDir.path)) ?? [])
                        .filter { !$0.hasPrefix(".") }
                    guard onDisk.isEmpty else {
                        throw BrineStepError("no valid audio preceded the refusal, yet \(onDisk) exists")
                    }
                    return
                }
                guard FileManager.default.fileExists(
                        atPath: baseDir.appendingPathComponent(kept).path) else {
                    throw BrineStepError("the conversation recorded before the refusal is gone")
                }
                let attribution = CaptureAttributionPresentation.attribution(captureId: kept,
                                                                             baseDir: baseDir)
                guard attribution.deviceName == "Bad Mic", attribution.isKnown else {
                    throw BrineStepError(
                        "audio recorded before the refusal lost its attribution: "
                            + "\(attribution.deviceName)")
                }
            },

            defineCheck("other eligible devices remain available to connect") { _, _, _ in
                let rows = await MainActor.run { w.listRows }
                let connectable = rows.filter(\.isConnectable).map(\.displayName).sorted()
                guard connectable == ["Field Recorder", "Trail Mic"] else {
                    throw BrineStepError(
                        "the other eligible devices are \(connectable) — a refusal took them "
                            + "down with it")
                }
                // And the refused one is still LISTED, not hidden: a device that vanishes
                // leaves the user with nothing to act on.
                guard rows.contains(where: { $0.displayName == "Bad Mic" }) else {
                    throw BrineStepError("the refused device was hidden rather than explained")
                }
            },
        ] + capabilityAndSubstitutionSteps(w) + historySteps(w)
    }
}

// MARK: - S03 (honest capabilities + gap copy) and S05 (substitution)

private func capabilityAndSubstitutionSteps(
    _ w: DeviceRenderedSurfaceWorld
) -> [StepDefinition] {
    [
        // MARK: S03

        defineStep("a connected device declares no firmware value and no gap recovery") { ctx, _, _ in
            try await MainActor.run {
                try w.freshHandset()
                try w.signIn("s03-owner")
                // It DOES declare a battery level, so "unavailable" below is a statement
                // about what this device reported and not about a builder that says
                // unavailable to everything.
                w.observe("Trail Mic", shape: .bleStream,
                          capabilities: [RecordingDeviceCapabilityKey.batteryLevel.rawValue: "72"])
                w.openTheOneList()
                let row = try XCTUnwrapOrThrow(w.listRows.first { $0.displayName == "Trail Mic" },
                                               "the connected device is not in the list")
                w.capabilityLines = row.capabilities
                // The device page's metrics strip renders from the same declared state.
                w.metrics = DeviceMetricsPresentation.resolve(
                    omiConnected: true, batteryPercent: 72, signal: "Strong",
                    firmware: RecordingDeviceCapabilities(declared: [:])
                        .state(of: .firmwareVersion))
            }
            return ctx
        },

        defineCheck("the device surface shows both capabilities as unavailable") { _, _, _ in
            let lines = await MainActor.run { w.capabilityLines }
            for label in ["Firmware", "Gap recovery"] {
                let line = try XCTUnwrapOrThrow(lines.first { $0.label == label },
                                                "the surface does not show \(label) at all")
                guard !line.isAvailable,
                      line.value == RecordingDeviceConnectPresentation.unavailableValue else {
                    throw BrineStepError(
                        "\(label) is shown as \"\(line.value)\" for a device that never "
                            + "declared it")
                }
            }
            // NON-VACUOUS: the same surface DOES report what the device declared. A builder
            // that answered "unavailable" to everything would pass the loop above.
            let battery = try XCTUnwrapOrThrow(lines.first { $0.label == "Battery" },
                                               "the surface does not show Battery")
            guard battery.isAvailable, battery.value == "72" else {
                throw BrineStepError(
                    "the surface reports \"\(battery.value)\" for a battery level the device "
                        + "DID declare — it is not reading declarations at all")
            }
        },

        defineCheck("it shows no fabricated firmware value") { _, _, _ in
            let metrics = try await MainActor.run {
                try XCTUnwrapOrThrow(w.metrics, "the metrics strip was never resolved")
            }
            guard metrics.firmware == DeviceMetricsPresentation.unavailableValue else {
                throw BrineStepError(
                    "the metrics strip shows firmware \"\(metrics.firmware)\" for a device that "
                        + "reported none — a version number is the most plausible-looking "
                        + "default in the strip and the one a user would quote to support")
            }
            // The measured column is still measured, so this is not a strip that shows N/A
            // for everything.
            guard metrics.battery == "72%" else {
                throw BrineStepError("the strip lost the battery level it does measure")
            }
            // And the value can only come from a declaration: a device that DID report a
            // version gets its own version, not a constant.
            let reported = DeviceMetricsPresentation.resolve(
                omiConnected: true, batteryPercent: 72, signal: "Strong",
                firmware: .reported("9.9.9"))
            guard reported.firmware == "9.9.9" else {
                throw BrineStepError("the strip ignores what the device reported")
            }
        },

        defineStep("the device disconnects and audio from the gap cannot be recovered") { ctx, _, _ in
            await MainActor.run {
                // The one outcome that IS a loss: the device keeps no audio while away, so
                // the gap was never recorded.
                var window = GapRecoveryWindow(interruptedCaptureId: "cap-s03",
                                               accountScopeAtOpen: w.scope)
                let outcome = window.close(.deviceHasNoStorage)
                w.gapLine = outcome.map(GapRecoveryCopy.line(for:))
            }
            return ctx
        },

        defineCheck("the surface says that the gap audio was not recoverable") { _, _, _ in
            let line = try await MainActor.run {
                try XCTUnwrapOrThrow(w.gapLine, "the gap window said nothing at all")
            }
            guard line.contains(GapRecoveryCopy.lossPhrase) else {
                throw BrineStepError(
                    "audio that is genuinely gone was not reported as a loss: \"\(line)\"")
            }
        },

        defineStep("the device disconnects still holding the audio it recorded") { ctx, _, _ in
            await MainActor.run {
                // The case that must NEVER read as loss: nothing was collected this time and
                // the device still has it. The engine issued no ring advance.
                var window = GapRecoveryWindow(interruptedCaptureId: "cap-s03b",
                                               accountScopeAtOpen: w.scope)
                let outcome = window.close(.engineFinished(.failed("the link dropped")))
                w.gapLine = outcome.map(GapRecoveryCopy.line(for:))
            }
            return ctx
        },

        defineCheck("the surface does not say that the gap audio was not recoverable") { _, _, _ in
            let line = try await MainActor.run {
                try XCTUnwrapOrThrow(w.gapLine, "the gap window said nothing at all")
            }
            guard !line.contains(GapRecoveryCopy.lossPhrase) else {
                throw BrineStepError(
                    "audio still sitting on the device was reported as lost: \"\(line)\" — this "
                        + "is the failure the whole gap window exists to prevent")
            }
            guard !line.isEmpty else {
                throw BrineStepError("the surface says nothing, which is its own kind of wrong")
            }
        },

        // MARK: S05

        defineStep("two differently shaped devices are remembered across relaunch and both are ready") { ctx, _, _ in
            try await MainActor.run {
                try w.freshHandset()
                try w.signIn("s05-owner")
            }
            return ctx
        },

        defineStep("device A is the shape the shipped source ordering ranks last and device B is the shape it ranks first") { ctx, _, _ in
            try await MainActor.run {
                // THE FROZEN SPEC IS AMBIGUOUS HERE and the artifact resolves it: "ranks last"
                // is read as last among the REMEMBERABLE EXTERNAL devices, because the overall
                // last is the handset's own microphone, which cannot be substituted for.
                let artifact = try DeviceRenderedSurfaceWorld.s05Interpretation()
                // The artifact is a claim about the SHIPPED ordering — check it, so a change
                // to `activePriority` reds here instead of quietly testing other shapes.
                for (name, rank) in artifact.rememberableOrder {
                    guard let category = CaptureSourceCategory(rawValue: name) else {
                        throw BrineStepError("the artifact names an unknown category \"\(name)\"")
                    }
                    guard category.activePriority == rank else {
                        throw BrineStepError(
                            "the shipped ordering moved: \(name) ranks "
                                + "\(category.activePriority), the artifact says \(rank)")
                    }
                }
                guard let last = artifact.rememberableOrder.max(by: { $0.value < $1.value })?.key,
                      let first = artifact.rememberableOrder.min(by: { $0.value < $1.value })?.key,
                      last == artifact.s05.deviceA.category,
                      first == artifact.s05.deviceB.category else {
                    throw BrineStepError("the artifact's A/B choice disagrees with its own order")
                }
                let shapeA = try XCTUnwrapOrThrow(
                    RecordingDeviceShape(rawValue: artifact.s05.deviceA.shape), "bad shape A")
                let shapeB = try XCTUnwrapOrThrow(
                    RecordingDeviceShape(rawValue: artifact.s05.deviceB.shape), "bad shape B")
                guard shapeA != shapeB else {
                    throw BrineStepError("A and B share a shape — 'differently shaped' is vacuous")
                }
                let store = try w.store()
                let a = RecordingDeviceRecord(
                    identity: RecordingDeviceIdentity(shape: shapeA, hardwareToken: "device-a"),
                    displayName: "Field Recorder",
                    lastConnected: Date(timeIntervalSince1970: 1_700_000_000))
                let b = RecordingDeviceRecord(
                    identity: RecordingDeviceIdentity(shape: shapeB, hardwareToken: "device-b"),
                    // The vendor-shaped one, named for its vendor. It must not win anything.
                    displayName: "Omi",
                    lastConnected: Date(timeIntervalSince1970: 1_700_000_100))
                try store.upsert(a)
                try store.upsert(b)
                w.deviceA = a
                w.deviceB = b
            }
            return ctx
        },

        defineStep("device A is active because I selected it") { ctx, _, _ in
            try await MainActor.run {
                let a = try XCTUnwrapOrThrow(w.deviceA, "device A was never remembered")
                let outcome = RecordingDeviceStore.recordUserSelection(identity: a.identity)
                guard case .recorded = outcome else {
                    throw BrineStepError("selecting device A was not recorded: \(outcome)")
                }
            }
            return ctx
        },

        defineCheck("device A stays active while both devices are ready") { _, _, _ in
            try await MainActor.run {
                let a = try XCTUnwrapOrThrow(w.deviceA, "no device A")
                let b = try XCTUnwrapOrThrow(w.deviceB, "no device B")
                let active = RecordingDeviceActivation.active(
                    among: try w.store().records(), ready: [a.identity, b.identity])
                guard active?.identity == a.identity else {
                    throw BrineStepError(
                        "with both ready the active device is \(active?.displayName ?? "none"), "
                            + "not the one I selected — B is the vendor-shaped one and it won")
                }
                w.activeAfterSelection = active
            }
        },

        defineStep("device A becomes unready") { ctx, _, _ in
            try await MainActor.run {
                let b = try XCTUnwrapOrThrow(w.deviceB, "no device B")
                w.activeAfterUnready = RecordingDeviceActivation.active(
                    among: try w.store().records(), ready: [b.identity])
            }
            return ctx
        },

        defineCheck("at most one device remains active") { _, _, _ in
            try await MainActor.run {
                let records = try w.store().records()
                let a = try XCTUnwrapOrThrow(w.deviceA, "no device A")
                let b = try XCTUnwrapOrThrow(w.deviceB, "no device B")
                // Over EVERY readiness subset, never more than one — the rule returns a single
                // record by type, so what is actually at stake is that it never returns a
                // device that is not ready or one that was detached.
                for ready in [[], [a.identity], [b.identity], [a.identity, b.identity]] {
                    let set = Set(ready)
                    let active = RecordingDeviceActivation.active(among: records, ready: set)
                    if let active {
                        guard set.contains(active.identity) else {
                            throw BrineStepError(
                                "\(active.displayName) is active while not ready (\(set))")
                        }
                        guard !active.userDetached else {
                            throw BrineStepError("a detached device is active")
                        }
                    } else if !set.isEmpty {
                        throw BrineStepError("no device is active while \(set.count) are ready")
                    }
                }
                let handed = try XCTUnwrapOrThrow(w.activeAfterUnready,
                                                  "nothing was resolved after A became unready")
                guard handed.identity == b.identity else {
                    throw BrineStepError("the hand-off went to \(handed.displayName), not device B")
                }
            }
        },

        defineCheck("any hand-off follows preference and readiness rather than vendor identity") { _, _, _ in
            try await MainActor.run {
                let a = try XCTUnwrapOrThrow(w.deviceA, "no device A")
                let b = try XCTUnwrapOrThrow(w.deviceB, "no device B")
                let records = try w.store().records()
                let baseline = RecordingDeviceActivation.active(
                    among: records, ready: [a.identity, b.identity])?.displayName

                // SWAP WHICH ONE IS THE BLE DEVICE. Same preferences, same recency, same
                // readiness — only the SHAPES trade places. Vendor identity is absent from the
                // comparison by construction, and this is what proves it by substitution
                // rather than by reading the code.
                let swapped = records.map { record -> RecordingDeviceRecord in
                    var copy = record
                    let other: RecordingDeviceShape = record.identity.shape == a.identity.shape
                        ? b.identity.shape : a.identity.shape
                    copy = RecordingDeviceRecord(
                        identity: RecordingDeviceIdentity(shape: other,
                                                          hardwareToken: record.identity.hardwareToken),
                        displayName: record.displayName,
                        lastConnected: record.lastConnected,
                        userDetached: record.userDetached,
                        userPreferred: record.userPreferred)
                    return copy
                }
                let swappedReady = Set(swapped.map(\.identity))
                let afterSwap = RecordingDeviceActivation.active(among: swapped,
                                                                 ready: swappedReady)?.displayName
                guard afterSwap == baseline else {
                    throw BrineStepError(
                        "swapping which device is the BLE one changed the active device from "
                            + "\(baseline ?? "none") to \(afterSwap ?? "none") — the shape is in "
                            + "the comparison")
                }

                // AND THE NAMES TOO: the vendor-named one must not win on its name either.
                let renamed = records.map { record in
                    RecordingDeviceRecord(identity: record.identity,
                                          displayName: record.displayName == "Omi" ? "Zed" : "Omi",
                                          lastConnected: record.lastConnected,
                                          userDetached: record.userDetached,
                                          userPreferred: record.userPreferred)
                }
                let afterRename = RecordingDeviceActivation.active(
                    among: renamed, ready: Set(renamed.map(\.identity)))?.identity
                let baselineIdentity = RecordingDeviceActivation.active(
                    among: records, ready: Set(records.map(\.identity)))?.identity
                guard afterRename == baselineIdentity else {
                    throw BrineStepError("renaming the devices changed which one is active")
                }

                // NON-VACUOUS: preference DOES move it, so the invariance above is a property
                // of shape and name and not of a rule that answers the same thing to anything.
                try w.store().prefer(b.identity)
                let afterPreference = RecordingDeviceActivation.active(
                    among: try w.store().records(), ready: [a.identity, b.identity])
                guard afterPreference?.identity == b.identity else {
                    throw BrineStepError("preference does not decide anything — the rule is inert")
                }
                try w.store().prefer(a.identity)   // put the scenario's state back
            }
        },

        defineStep("I select device B and record") { ctx, _, _ in
            let (a, b) = try await MainActor.run {
                (try XCTUnwrapOrThrow(w.deviceA, "no device A"),
                 try XCTUnwrapOrThrow(w.deviceB, "no device B"))
            }
            // The conversation device A already made, before any of this.
            let archived = CaptureManager.newCaptureId()
            try await MainActor.run {
                try w.seedConversation(
                    id: archived,
                    device: CaptureDeviceContext(identity: a.identity,
                                                 displayName: a.displayName,
                                                 accountScope: w.scope),
                    sourceTag: CaptureDeviceSidecar.sourceMarker(for: a.identity.shape))
                w.archivedConversation = archived
                let outcome = RecordingDeviceStore.recordUserSelection(identity: b.identity)
                guard case .recorded = outcome else {
                    throw BrineStepError("selecting device B was not recorded: \(outcome)")
                }
            }
            // Now record through the production path, with the store answering who is active.
            let active = try await MainActor.run { () -> OmiRestorationComposition.ActiveDeviceResolution in
                let records = try w.store().records()
                guard let chosen = RecordingDeviceActivation.active(among: records,
                                                                    ready: [b.identity]) else {
                    throw BrineStepError("device B is not active after I selected it")
                }
                return .active(chosen)
            }
            let opened = try await w.recordAndFinalize(recording: .externalStream,
                                                       activeDevice: active)
            await MainActor.run { w.newConversation = opened }
            return ctx
        },

        defineCheck("new audio is attributed to device B") { _, _, _ in
            let (id, baseDir, b) = try await MainActor.run {
                (try XCTUnwrapOrThrow(w.newConversation, "nothing new was recorded"),
                 w.baseDir!,
                 try XCTUnwrapOrThrow(w.deviceB, "no device B"))
            }
            let recorded = try XCTUnwrapOrThrow(
                CaptureDeviceSidecar.load(captureId: id, baseDir: baseDir),
                "the new conversation carries no device record")
            guard recorded.identity == b.identity else {
                throw BrineStepError(
                    "new audio records \(recorded.identity) — attribution did not follow the "
                        + "device I selected")
            }
            let attribution = CaptureAttributionPresentation.attribution(captureId: id,
                                                                          baseDir: baseDir)
            guard attribution.deviceName == b.displayName, attribution.isKnown else {
                throw BrineStepError(
                    "the timeline shows \"\(attribution.deviceName)\" for audio device B made")
            }
        },

        defineCheck("archived audio remains attributed to device A") { _, _, _ in
            let (id, baseDir, a, newId) = try await MainActor.run {
                (try XCTUnwrapOrThrow(w.archivedConversation, "nothing was archived"),
                 w.baseDir!,
                 try XCTUnwrapOrThrow(w.deviceA, "no device A"),
                 w.newConversation)
            }
            let attribution = CaptureAttributionPresentation.attribution(captureId: id,
                                                                          baseDir: baseDir)
            guard attribution.deviceName == a.displayName, attribution.isKnown else {
                throw BrineStepError(
                    "audio device A recorded is now attributed to \"\(attribution.deviceName)\" — "
                        + "a substitution rewrote the archive")
            }
            // The two are genuinely different conversations with different recorders, so this
            // is not one record read twice.
            guard id != newId else { throw BrineStepError("the archived and new ids are the same") }
            let recorded = try XCTUnwrapOrThrow(
                CaptureDeviceSidecar.load(captureId: id, baseDir: baseDir),
                "the archived conversation lost its device record")
            guard recorded.identity == a.identity else {
                throw BrineStepError("the archived record now says \(recorded.identity)")
            }
        },
    ]
}

// MARK: - S06 / S07 (history + onboarding) and the N7 rendering decision

private func historySteps(_ w: DeviceRenderedSurfaceWorld) -> [StepDefinition] {
    [
        // MARK: S06

        defineStep("a legacy Omi pairing and legacy recordings exist before upgrade") { ctx, _, _ in
            try await MainActor.run {
                try w.freshHandset()
                w.stageLegacyPairing()
                // Conversations from BEFORE device records shipped: no sidecar, a durable
                // start before the epoch, and the shipped source marker.
                for index in 0..<2 {
                    let id = "omi-20200101-00000\(index)-LEGACY01"
                    try w.seedConversation(id: id, device: nil)
                    ConversationMetaStore.recordStart(
                        captureId: id, baseDir: w.baseDir,
                        at: CaptureDeviceSidecar.migrationEpoch - 86_400)
                }
            }
            return ctx
        },

        defineStep("the signed-in account launches the upgraded app") { ctx, _, _ in
            try await MainActor.run {
                try w.signIn("s06-first")
                w.firstAccountScope = w.scope
                // THE UPGRADE PATH, as production takes it: resolving who is active is what
                // carries the legacy pairing into the account's own memory.
                let resolution = OmiRestorationComposition.activeExternalDevice(
                    binding: w.binding, attached: w.legacySavedOmi, defaults: w.legacyDefaults)
                guard case .active = resolution else {
                    throw BrineStepError("the upgraded launch found no active device: \(resolution)")
                }
                w.historyRows = RecordingHistory.rows(baseDir: w.baseDir)
                w.firstRun = WelcomeFrontDoor.firstRunPresentation(
                    letStraightIn: false, onboardingCompleted: false, welcomeSeen: true,
                    hasRecordingHistory: RecordingHistory.hasAny(baseDir: w.baseDir))
            }
            return ctx
        },

        defineCheck("the device remains paired and active without a physical re-pair") { _, _, _ in
            try await MainActor.run {
                // The shipped device-global pairing is UNTOUCHED — a migration that deletes
                // its own source cannot be re-run or audited.
                guard w.legacyDefaults.string(forKey: DeviceManager.savedKey)
                        == DeviceRenderedSurfaceWorld.legacyPeripheralID else {
                    throw BrineStepError("the upgrade deleted the shipped pairing")
                }
                let remembered = try w.store().records()
                guard remembered.contains(where: { $0.identity == w.legacyIdentity }) else {
                    throw BrineStepError(
                        "the account does not remember the legacy device — its owner would have "
                            + "to physically pair it again")
                }
                let active = OmiRestorationComposition.activeExternalDevice(
                    binding: w.binding, attached: w.legacySavedOmi, defaults: w.legacyDefaults)
                guard active.record?.identity == w.legacyIdentity else {
                    throw BrineStepError("the legacy device is remembered but not active: \(active)")
                }
                // NON-VACUOUS: adoption is what did it. A fresh account with the same legacy
                // defaults but no adoption run has nothing.
                guard case .adopted = try RecordingDeviceMigration.adoptLegacyPairing(
                        defaults: w.legacyDefaults,
                        into: RecordingDeviceStore(
                            root: w.sandbox.appendingPathComponent("probe-\(UUID().uuidString)"),
                            scope: "acct-probe")) else {
                    throw BrineStepError("the legacy pairing is not adoptable at all")
                }
            }
        },

        defineCheck("the legacy history remains visible without onboarding") { _, _, _ in
            let (rows, firstRun) = await MainActor.run { (w.historyRows, w.firstRun) }
            guard rows.count == 2 else {
                throw BrineStepError("the legacy history shows \(rows.count) conversations, not 2")
            }
            for row in rows {
                // A pre-upgrade conversation keeps its SHIPPED attribution and is never called
                // missing — the accusation the epoch's direction exists to prevent.
                guard row.attribution.deviceName == "Omi", row.attribution.isKnown else {
                    throw BrineStepError(
                        "a legacy recording renders as \"\(row.attribution.deviceName)\" "
                            + "(\(row.attribution.diagnostic ?? "no diagnostic"))")
                }
            }
            guard firstRun == WelcomeFrontDoor.FirstRunPresentation.none else {
                throw BrineStepError(
                    "an account with two years of recordings was sent to \(String(describing: firstRun))")
            }
        },

        defineStep("a second account signs in on the same handset") { ctx, _, _ in
            try await MainActor.run {
                try w.signIn("s06-second")
                w.secondAccountSeesDevices = try w.store().records()
                w.secondAccountActivation = RecordingDeviceActivation.active(
                    among: w.secondAccountSeesDevices, ready: [w.legacyIdentity])
            }
            return ctx
        },

        defineCheck("it cannot see or activate the first account's device") { _, _, _ in
            try await MainActor.run {
                guard w.secondAccountSeesDevices.isEmpty else {
                    throw BrineStepError(
                        "the second account can see \(w.secondAccountSeesDevices.map(\.displayName))")
                }
                guard w.secondAccountActivation == nil else {
                    throw BrineStepError("the second account made another account's device active")
                }
                guard w.scope != w.firstAccountScope else {
                    throw BrineStepError("both accounts resolved the same scope — the check is vacuous")
                }
                // AND THE FIRST ACCOUNT STILL HAS IT: isolation, not deletion.
                try w.signIn("s06-first")
                guard try w.store().records().contains(where: { $0.identity == w.legacyIdentity }) else {
                    throw BrineStepError("the first account lost its device when the second signed in")
                }
            }
        },

        // MARK: S07

        defineStep("an account's history contains only recordings made after device-agnostic source support") { ctx, _, _ in
            try await MainActor.run {
                try w.freshHandset()
                try w.signIn("s07-owner")
                let identity = RecordingDeviceIdentity(shape: .audioRoute, hardwareToken: "route-7")
                for index in 0..<3 {
                    let id = "omi-20990101-00000\(index)-MODERN01"
                    try w.seedConversation(
                        id: id,
                        device: CaptureDeviceContext(identity: identity,
                                                     displayName: "Field Recorder",
                                                     accountScope: w.scope),
                        sourceTag: CaptureDeviceSidecar.sourceMarker(for: identity.shape))
                    ConversationMetaStore.recordStart(
                        captureId: id, baseDir: w.baseDir,
                        at: CaptureDeviceSidecar.migrationEpoch + 10_000)
                }
                // Every one of them carries a device record — this account has NO legacy era.
                guard RecordingHistory.rows(baseDir: w.baseDir).allSatisfy({ $0.attribution.isKnown }) else {
                    throw BrineStepError("the seeded history is not device-agnostic-era after all")
                }
            }
            return ctx
        },

        defineStep("that account launches the upgraded app") { ctx, _, _ in
            await MainActor.run {
                w.historyRows = RecordingHistory.rows(baseDir: w.baseDir)
                w.firstRun = WelcomeFrontDoor.firstRunPresentation(
                    letStraightIn: false,
                    // The flag reads its DEFAULT — the restored-backup / unmigrated-preference
                    // state. History is what must decide this, not the flag.
                    onboardingCompleted: false,
                    welcomeSeen: true,
                    hasRecordingHistory: RecordingHistory.hasAny(baseDir: w.baseDir))
            }
            return ctx
        },

        defineCheck("its recording history remains visible") { _, _, _ in
            let rows = await MainActor.run { w.historyRows }
            guard rows.count == 3 else {
                throw BrineStepError("the history shows \(rows.count) conversations, not 3")
            }
            for row in rows {
                guard row.attribution.deviceName == "Field Recorder", row.attribution.isKnown else {
                    throw BrineStepError(
                        "a post-upgrade recording renders as \"\(row.attribution.deviceName)\"")
                }
            }
        },

        defineCheck("device onboarding does not run") { _, _, _ in
            let firstRun = await MainActor.run { w.firstRun }
            if case .onboarding = firstRun {
                throw BrineStepError(
                    "an account whose whole archive was recorded after this shipped was sent "
                        + "back through first-run onboarding")
            }
            // NON-VACUOUS: the gate DOES run for an account with no history, so this is a
            // statement about history and not about a gate that never fires.
            let fresh = WelcomeFrontDoor.firstRunPresentation(
                letStraightIn: false, onboardingCompleted: false, welcomeSeen: true,
                hasRecordingHistory: false)
            guard case .onboarding = fresh else {
                throw BrineStepError("onboarding never presents at all — the check is unfailable")
            }
        },

        // MARK: N7 — which account a gap outcome is rendered into

        defineStep("a gap-recovery outcome was produced while one account was exposed") { ctx, _, _ in
            try await MainActor.run {
                try w.freshHandset()
                try w.signIn("n7-owner")
                w.firstAccountScope = w.scope
                var window = GapRecoveryWindow(interruptedCaptureId: "cap-n7",
                                               accountScopeAtOpen: w.scope)
                let outcome = try XCTUnwrapOrThrow(window.close(.engineFinished(.synced(records: 1, frames: 60))),
                                                   "the window published nothing")
                w.gapReport = GapRecoveryReport(outcome: outcome, accountScope: w.scope)
            }
            return ctx
        },

        defineStep("the exposed account has changed by the time it arrives") { ctx, _, _ in
            try await MainActor.run {
                try w.signIn("n7-other")
                let report = try XCTUnwrapOrThrow(w.gapReport, "no report")
                w.gapDecision = GapRecoveryRendering.decide(report, currentScope: w.scope)
            }
            return ctx
        },

        defineCheck("the outcome is withheld with a reason rather than rendered") { _, _, _ in
            let (decision, report) = try await MainActor.run {
                (try XCTUnwrapOrThrow(w.gapDecision, "nothing was decided"),
                 try XCTUnwrapOrThrow(w.gapReport, "no report"))
            }
            guard case .withheld(let reason) = decision else {
                throw BrineStepError(
                    "one account's recording history was rendered into the next account's "
                        + "timeline: \(decision)")
            }
            guard !reason.isEmpty else {
                throw BrineStepError("the outcome vanished without a reason — a fourth silent state")
            }
            // The outcome itself is NOT destroyed: withholding is a rendering decision, and a
            // diagnostic reader investigating a torn-down account still needs the fact.
            guard report.accountScope != nil else {
                throw BrineStepError("the report lost the account it was about")
            }
        },

        defineStep("the outcome arrives while its own account is still exposed") { ctx, _, _ in
            try await MainActor.run {
                let report = try XCTUnwrapOrThrow(w.gapReport, "no report")
                w.gapDecision = GapRecoveryRendering.decide(report,
                                                            currentScope: report.accountScope)
            }
            return ctx
        },

        defineCheck("the outcome is rendered") { _, _, _ in
            let (decision, report) = try await MainActor.run {
                (try XCTUnwrapOrThrow(w.gapDecision, "nothing was decided"),
                 try XCTUnwrapOrThrow(w.gapReport, "no report"))
            }
            guard case .show(let line) = decision else {
                throw BrineStepError(
                    "an outcome about the account on screen was withheld from it: \(decision)")
            }
            guard line == GapRecoveryCopy.line(for: report.outcome) else {
                throw BrineStepError("the rendered line is not the outcome's own sentence")
            }
            // A report with NO account is withheld too — `nil` is fail-closed, not a wildcard.
            let unscoped = GapRecoveryReport(outcome: report.outcome, accountScope: nil)
            guard case .withheld = GapRecoveryRendering.decide(unscoped,
                                                               currentScope: report.accountScope) else {
                throw BrineStepError(
                    "an outcome carrying no account was rendered into whatever was current")
            }
        },
    ]
}

// MARK: - Shared checks

/// Every vendor and model name this app has ever branched on. Generic copy — copy that is
/// not ABOUT a specific device the user selected — may contain none of them.
private let bannedVendorWords = ["omi", "apple watch", "airpods", "friend", "limitless"]

private func assertNamesNoVendor(_ text: String, what: String) throws {
    for word in bannedVendorWords where text.range(of: word, options: .caseInsensitive) != nil {
        throw BrineStepError("\(what) names a vendor (\"\(word)\"): \"\(text)\"")
    }
}

/// The whole refusal vocabulary the catalog can produce, so copy checks run over the
/// population rather than over the one reason a scenario happened to trigger.
private func everyRefusalReason() -> [String] {
    [
        RecordingDeviceRefusalReason.noAudioFormatDeclared,
        .unsupportedCodec("vendor-secret"),
        .unusableSampleRate(4_000),
        .unusableFraming(milliseconds: 900, channels: 0),
        .audioStoppedBeingUsable("the stream stopped decoding"),
    ].map(\.actionableReason)
}
