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
            XCTAssertEqual(result.passed, 15,
                           "device-rendered-surface must run all 15 scenarios "
                               + "(10 plain + 3 S01 rows + 2 S02 rows)")
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

    /// The base a conversation row composes its recorder into — the same shape
    /// `App/CaptureScreen.swift` hands `metaLine`.
    private static let rowBase = "3:04 – 3:21 PM · 17 min"

    /// EVERY RENDERED ANSWER, OVER PROVENANCE × WHAT THE DISK CAN NAME — and the one property
    /// that decides which of them may be printed with nothing beside it.
    ///
    /// THE POPULATION USED TO EXCLUDE THE MARKER BEING ABSENT, and that is where the bug
    /// lived: every case below paired a pre-record provenance with a READABLE
    /// `.capture-source` marker, so the arm that runs when nothing on disk names a source —
    /// the oldest part of every upgrading archive, and every capture too damaged to date —
    /// was never evaluated here at all.
    ///
    /// THE PROPERTY. A name may stand alone exactly when the classifier warrants it standing
    /// alone: a device it identified, or an era it could establish. Every other answer must
    /// arrive with the reason the app can say no more, and the conversation row — which has
    /// no room for a reason — must print nothing for it. `metaLine` IS that row, so "stands
    /// alone" is measured through what the row does rather than through a flag that claims it.
    func testOnlyAnAnswerTheClassifierWarrantsIsPrintedWithNothingBesideIt() {
        let context = CaptureDeviceContext(
            identity: RecordingDeviceIdentity(shape: .audioRoute, hardwareToken: "route-1"),
            displayName: "Field Recorder", accountScope: "acct-x")
        let unreadableMarker = "a-source-kind-this-build-has-no-meaning-for"
        // (provenance, what `.capture-source` says, may this name stand alone)
        let cases: [(CaptureDeviceProvenance, String?, Bool)] = [
            (.identified(context), "phoneMic", true),
            (.legacyPreMigration, CaptureSourceKind.omi.rawValue, true),
            (.legacyPreMigration, CaptureSourceKind.phoneMic.rawValue, true),
            // The era is ESTABLISHED — a durable start before the epoch — so saying it is an
            // answer even though nothing names a source.
            (.legacyPreMigration, nil, true),
            (.legacyPreMigration, unreadableMarker, true),
            // The era is NOT establishable. Neither arm may be printed bare.
            (.undatable(diagnostic: "no durable start and no dated id"),
             CaptureSourceKind.omi.rawValue, false),
            (.undatable(diagnostic: "no durable start and no dated id"), nil, false),
            (.unknownPostMigration(diagnostic: "the record failed to write"), "omi", false),
            (.unreadableRecord(diagnostic: "the record could not be understood"), "omi", false),
        ]
        XCTAssertEqual(Set(cases.map(\.2)).count, 2, "the fixture itself is degenerate")

        // What a recording the classifier COULD place before device tracking is called. Any
        // other cell rendering this same name is claiming that era without having established
        // it — the failure mode this matrix exists to catch, held without pinning the copy.
        let establishedEra = CaptureAttributionPresentation.attribution(
            for: .legacyPreMigration, legacySourceMarker: nil).deviceName

        for (provenance, marker, mayStandAlone) in cases {
            let disk = marker ?? "no marker"
            let rendered = CaptureAttributionPresentation.attribution(for: provenance,
                                                                      legacySourceMarker: marker)
            XCTAssertFalse(rendered.deviceName.isEmpty, "\(provenance)/\(disk) rendered no name")

            let row = CaptureAttributionPresentation.metaLine(Self.rowBase, attribution: rendered)
            XCTAssertEqual(row != Self.rowBase, mayStandAlone,
                           "\(provenance)/\(disk) renders \"\(rendered.deviceName)\" and the "
                               + "conversation row says \"\(row)\" — a row prints a name exactly "
                               + "when that name is an answer on its own")
            if mayStandAlone {
                XCTAssertTrue(row.contains(rendered.deviceName),
                              "\(provenance)/\(disk): the row appended something other than the "
                                  + "name it was given")
            } else {
                XCTAssertFalse(rendered.diagnostic?.isEmpty ?? true,
                               "\(provenance)/\(disk) renders \"\(rendered.deviceName)\" with no "
                                   + "reason beside it — a name the app cannot stand behind, "
                                   + "standing on its own, is the shrug a reader can do nothing "
                                   + "with")
                if case .legacyPreMigration = provenance {} else {
                    XCTAssertNotEqual(rendered.deviceName, establishedEra,
                                      "\(provenance)/\(disk) is described exactly as a recording "
                                          + "the classifier COULD place before device tracking, "
                                          + "which is a claim about an era it could not establish")
                }
            }
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

    // MARK: unit — the recording that cannot be placed in an era, from both sides

    /// DIRECTION ONE: THE ERA IS NEVER ASSERTED WITHOUT WARRANT.
    ///
    /// `.undatable` is the classifier saying, in its own words, that *whether this recording
    /// predates device records is not knowable*. Reading it as pre-upgrade is the conservative
    /// INTERNAL choice — it is why a capture with no record is never accused of losing one —
    /// and it is not a licence to tell the reader an era as a fact. This reds if an undatable
    /// recording is described the way an established one is, and it reds if the conversation
    /// row — which has no room for the hedge — prints anything for it at all.
    func testAnUndatableRecordingIsNeverGivenAnEraTheClassifierCouldNotEstablish() {
        let established = CaptureAttributionPresentation.attribution(for: .legacyPreMigration,
                                                                     legacySourceMarker: nil)
        for marker in [nil, CaptureSourceKind.omi.rawValue, CaptureSourceKind.phoneMic.rawValue]
                as [String?] {
            let rendered = CaptureAttributionPresentation.attribution(
                for: .undatable(diagnostic: "no durable start and no dated id"),
                legacySourceMarker: marker)
            XCTAssertNotEqual(
                rendered.deviceName, established.deviceName,
                "an undatable recording (\(marker ?? "no marker")) is described exactly as one "
                    + "the classifier could place before device tracking — the era is the one "
                    + "thing it said it could not know")
            XCTAssertEqual(
                CaptureAttributionPresentation.metaLine(Self.rowBase, attribution: rendered),
                Self.rowBase,
                "the conversation row prints \"\(rendered.deviceName)\" for a recording the "
                    + "classifier could not place, with no room for the hedge that would make "
                    + "it honest")
        }

        // NON-VACUOUS, BOTH WAYS. An era the classifier DID establish is still said out loud,
        // and it is not the unknown-device shrug — otherwise "never says the era" would be
        // satisfiable by a surface that says nothing anywhere, which is the silence the shrug
        // was standing in for.
        XCTAssertNotEqual(
            CaptureAttributionPresentation.metaLine(Self.rowBase, attribution: established),
            Self.rowBase,
            "a recording the classifier placed before device tracking says nothing on its own "
                + "row, so the assertions above hold a surface that has simply gone quiet")
        XCTAssertNotEqual(established.deviceName,
                          CaptureAttributionPresentation.unknownDeviceName,
                          "a recording from an era that kept no device identity is reported as a "
                              + "device the app cannot name — nothing about it went missing")
    }

    /// DIRECTION TWO: WHAT IS RENDERED INSTEAD IS NOT A SHRUG.
    ///
    /// The classifier writes the sentence that says why this recording cannot be placed, and
    /// the arm that renders it used to pattern-match `.undatable` together with
    /// `.legacyPreMigration` and bind nothing — so the payload was built and dropped one call
    /// before the only surface that could show it. This reds if that sentence stops reaching
    /// the reader, and it reds if the answer goes back to being a bare name.
    func testAnUndatableRecordingCarriesTheClassifiersOwnReasonRatherThanShrugging() {
        let built = "this recording carries no durable start and no dated id, so whether it "
            + "predates device records is not knowable; it is read as pre-upgrade"
        for marker in [nil, CaptureSourceKind.omi.rawValue] as [String?] {
            let rendered = CaptureAttributionPresentation.attribution(
                for: .undatable(diagnostic: built), legacySourceMarker: marker)
            XCTAssertEqual(
                rendered.diagnostic, built,
                "the classifier explained itself and the surface rendered "
                    + "\(rendered.diagnostic.map { "\"\($0)\"" } ?? "no reason at all") beside "
                    + "\"\(rendered.deviceName)\" (\(marker ?? "no marker")) — a reader who "
                    + "wants to know why nothing is named has nowhere to go")
            XCTAssertFalse(
                rendered.isKnown,
                "an undatable recording is presented as an answer the app can stand behind")
            XCTAssertFalse(rendered.deviceName.isEmpty,
                           "the hedged answer has no name to hedge (\(marker ?? "no marker"))")
        }

        // THE REAL SENTENCE, FROM THE REAL CLASSIFIER, THROUGH THE PRODUCTION READ PATH — so
        // this cannot pass on a diagnostic that only a test constructs.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-undatable-\(UUID().uuidString)", isDirectory: true)
        let captureId = "mic-restored-with-no-stamp"
        do {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(captureId, isDirectory: true),
                withIntermediateDirectories: true)
        } catch {
            return XCTFail("could not stage an undatable capture: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        guard case .undatable(let classifiersReason) = CaptureDeviceSidecar.provenance(
                captureId: captureId, baseDir: dir) else {
            return XCTFail("the staged capture is datable after all, so this check never "
                               + "reaches the arm it is about")
        }
        let rendered = CaptureAttributionPresentation.attribution(captureId: captureId,
                                                                  baseDir: dir)
        XCTAssertEqual(rendered.diagnostic, classifiersReason,
                       "the production read path renders "
                           + "\(rendered.diagnostic.map { "\"\($0)\"" } ?? "no reason") for a "
                           + "capture the classifier described as \"\(classifiersReason)\"")
    }

    /// A BLUETOOTH AUDIO-ROUTE RECORDER MUST NOT BE CALLED "PHONE" (T5, S01).
    ///
    /// It records through the phone-mic path, so from inside `CaptureManager` it is
    /// indistinguishable from the built-in microphone — and every conversation made with one
    /// was therefore attributed to the handset. The registry knows which route is active and
    /// hands it in. This asserts all three arms of the seam, including the control that a
    /// plain Record-button conversation is STILL the handset.
    @MainActor
    func testTheAudioRouteArmNamesTheRouteAndNotThePhone() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-route-arm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = CaptureManager(
            target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x"),
            baseDir: dir, source: SeamTestSource(), finalize: { _, _ in })

        // (a) External stream: no route, not recording mic — the remembered device answers.
        manager.selectCaptureSource(.omi)
        XCTAssertEqual(manager.recordingSourceForAttribution, .externalStream)

        // (b) The handset's own microphone: the phone-mic path with NO route. The control that
        // makes (c) mean something — without it, a seam that always reported a route would
        // pass (c) and re-introduce T4's bug in the other direction.
        manager.selectCaptureSource(.phoneMic)
        XCTAssertEqual(manager.recordingSourceForAttribution, .handsetMicrophone,
                       "a plain Record-button conversation must stay the handset's own mic")

        // (c) The same phone-mic path WITH a route: the device the user connected.
        manager.activeAudioRoute = { (token: "route-uid-1", displayName: "Field Recorder") }
        XCTAssertEqual(manager.recordingSourceForAttribution,
                       .handsetAudioRoute(token: "route-uid-1", displayName: "Field Recorder"),
                       "a Bluetooth audio-route recorder was attributed to the phone")

        // And the composition root turns that into the ROUTE's identity and name, so the
        // timeline says what the user connected.
        let binding = CaptureAccountScope.currentAccountBinding()
        let resolution = OmiRestorationComposition.resolveDeviceContext(
            binding: binding,
            activeDevice: .noneActive(reason: .nothingRemembered),
            recording: manager.recordingSourceForAttribution)
        let context = try XCTUnwrap(resolution.context,
                                    "an audio-route recording could not be attributed at all")
        XCTAssertEqual(context.identity,
                       RecordingDeviceIdentity(shape: .audioRoute, hardwareToken: "route-uid-1"))
        XCTAssertEqual(context.displayName, "Field Recorder")
        XCTAssertEqual(CaptureAttributionPresentation.attribution(
            for: .identified(context),
            legacySourceMarker: CaptureSourceKind.phoneMic.rawValue).deviceName,
                       "Field Recorder")
    }

    /// M2 — "no active device" is FIVE different facts, and a consumer must be able to tell
    /// them apart by `switch` rather than by substring-matching English.
    ///
    /// T5 handed T6 these as free-form sentences and called them "the substrate R3's
    /// distinction needs". T6 has to render three of them differently against R6's
    /// three-minute bound, and it cannot branch on prose. This drives the REAL resolver into
    /// every arm it has and asserts the CASE — the sentence is checked separately, and only
    /// for the properties a sentence owes (present, distinct, no account scope leaked).
    @MainActor
    func testEveryWayOfHavingNoActiveDeviceIsItsOwnValue() throws {
        let world = try DeviceRenderedSurfaceWorld()
        defer { Task { await world.cleanup() } }

        // (a) No binding at all — a background relaunch before first unlock. Not a statement
        // about devices, and must never be confused with one.
        try world.freshHandset()
        XCTAssertEqual(
            OmiRestorationComposition.activeExternalDevice(binding: nil, attached: nil),
            .noneActive(reason: .noAccountScope))

        // (b) Signed in, nothing ever remembered.
        try world.signIn("m2-empty")
        let binding = try XCTUnwrap(world.binding)
        XCTAssertEqual(
            OmiRestorationComposition.activeExternalDevice(
                binding: binding, attached: nil, defaults: world.legacyDefaults),
            .noneActive(reason: .nothingRemembered))

        // (c) One device remembered, the transport has nothing attached.
        let identity = RecordingDeviceIdentity(shape: .bleStream, hardwareToken: "m2-token-1")
        guard case .recorded = RecordingDeviceStore.recordUserPair(identity: identity,
                                                                   displayName: "Trail Mic") else {
            return XCTFail("the pairing was not recorded")
        }
        XCTAssertEqual(
            OmiRestorationComposition.activeExternalDevice(
                binding: binding, attached: nil, defaults: world.legacyDefaults),
            .noneActive(reason: .rememberedButNoneAttached(count: 1)),
            "a remembered-but-absent device reads as 'nothing remembered', which is an "
                + "onboarding state and would send a paired user back through first run")

        // (d) That device attached, and explicitly detached by this account.
        let attached = SavedOmi(id: try XCTUnwrap(UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")),
                                name: "Trail Mic", lastConnected: nil)
        let attachedIdentity = RecordingDeviceIdentity(shape: .bleStream,
                                                       hardwareToken: attached.id.uuidString)
        guard case .recorded = RecordingDeviceStore.recordUserPair(identity: attachedIdentity,
                                                                   displayName: "Trail Mic") else {
            return XCTFail("the second pairing was not recorded")
        }
        // Control FIRST: while it is attached and not detached, it IS active — so (d) below is
        // a statement about detaching and not about a resolver that never activates anything.
        XCTAssertNotNil(
            OmiRestorationComposition.activeExternalDevice(
                binding: binding, attached: attached, defaults: world.legacyDefaults).record,
            "the attached, remembered, undetached device is not active — the control failed")
        guard case .recorded = RecordingDeviceStore.recordUserDetach(identity: attachedIdentity,
                                                                     displayName: "Trail Mic") else {
            return XCTFail("the detach was not recorded")
        }
        XCTAssertEqual(
            OmiRestorationComposition.activeExternalDevice(
                binding: binding, attached: attached, defaults: world.legacyDefaults),
            .noneActive(reason: .attachedButDetached),
            "a device the user detached reads the same as one that was never there")

        // (e) THE FAULT, DRIVEN THROUGH THE REAL RESOLVER — not constructed. A truncated
        // write, a bad sector or a half-restored backup lands here, and an earlier version of
        // this test only ever built the value by hand: a mutation that routed the catch arm
        // into `.nothingRemembered` SURVIVED it. Corrupting the file on disk is what makes the
        // arm reachable, and reaching it is the whole point — reporting an unreadable store as
        // "no devices" silently un-pairs everything the person owns.
        let store = try world.store()
        try Data("{ this is not JSON".utf8).write(to: store.fileURL, options: .atomic)
        let faulted = OmiRestorationComposition.activeExternalDevice(
            binding: binding, attached: attached, defaults: world.legacyDefaults)
        guard case .noneActive(let faultReason) = faulted, faultReason.isFault else {
            return XCTFail(
                "an unreadable recording-device store resolved to \(faulted) — anything other "
                    + "than the fault arm tells a person their devices are gone")
        }
        XCTAssertFalse(faultReason.sentence.contains(binding.scope),
                       "the fault sentence leaks the account scope it is about")
        // And the CONTEXT resolution refuses rather than attributing to nothing.
        let blocked = OmiRestorationComposition.resolveDeviceContext(
            binding: binding, activeDevice: faulted, recording: .externalStream)
        XCTAssertNil(blocked.context,
                     "an external stream was attributed to a device while the store that "
                         + "names devices could not be read")
        try FileManager.default.removeItem(at: store.fileURL)

        let unreadable = OmiRestorationComposition.NoActiveDeviceReason
            .storeUnreadable(redactedError: "the file could not be decoded")
        let all: [OmiRestorationComposition.NoActiveDeviceReason] = [
            .noAccountScope, .nothingRemembered, .rememberedButNoneAttached(count: 1),
            .attachedButDetached, unreadable,
        ]
        XCTAssertEqual(all.filter(\.isFault), [unreadable],
                       "an unreadable store must be distinguishable from an empty one — "
                           + "reporting it as 'no devices' silently un-pairs everything the "
                           + "person owns")
        // The copy still exists and still says five different things.
        XCTAssertEqual(Set(all.map(\.sentence)).count, 5,
                       "two of the five reasons say the same thing to a user")
        for reason in all {
            XCTAssertFalse(reason.sentence.isEmpty, "\(reason) has no sentence")
            XCTAssertFalse(reason.sentence.contains("acct-"),
                           "\(reason)'s sentence leaks an account scope")
        }
        // The count is CARRIED, not baked into a sentence a consumer would have to parse.
        guard case .rememberedButNoneAttached(let count) =
                OmiRestorationComposition.NoActiveDeviceReason.rememberedButNoneAttached(count: 3) else {
            return XCTFail("the count is not readable from the value")
        }
        XCTAssertEqual(count, 3)
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

    /// N7, PRODUCER SIDE — a real `DeviceManager` and what it actually delivered.
    var gapManager: DeviceManager?
    var deliveredReports = GapReportBox()
    /// The account the window was opened under, remembered by the SCENARIO so the assertion
    /// compares against something the manager was never handed at close time.
    var scopeAtGapOpen: String?

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
        gapManager = nil
        deliveredReports = GapReportBox()
        scopeAtGapOpen = nil

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

    // MARK: The gap-outcome PRODUCER, driven through the real DeviceManager (N7)
    //
    // WHY THIS EXISTS. Everything else N7 asserts drives `GapRecoveryRendering.decide` over a
    // report the SCENARIO hand-built. That proves the decision and nothing upstream of it —
    // and `DeviceManager.closeGapWindow` is the one place a gap outcome reaches anybody in
    // production. Review round 11 stamped every delivered report `accountScope: nil` — the
    // state in which EVERY gap outcome from a real device is withheld from its own account
    // forever, silently, because withholding is the fail-closed default — and the mutation
    // SURVIVED the whole 69-test `Device|Gap` population: no test in the repo read
    // `accountScope` off a manager-produced report, and the composition gate held the wiring
    // with a source-text search that a `nil` argument satisfies. These drive the real producer.

    /// Stand up the real producer and capture everything it delivers.
    ///
    /// `DeviceManager()` builds no `CBCentralManager` (only `start()` does), so this is
    /// hermetic; `runOnBleQueueForTests` is the same seam the gap-recovery funnel tests use.
    func startGapProducer(tellingItAbout scope: String?) {
        let manager = DeviceManager()
        let box = deliveredReports
        manager.onGapRecoveryOutcome = { box.append($0) }
        if let scope { manager.setAccountScopeForGapOutcomes(scope) }
        gapManager = manager
        // GROUND TRUTH HELD BY THE SCENARIO, not re-read from the manager at assert time —
        // an assertion that asks the manager what it thinks the answer is cannot fail.
        scopeAtGapOpen = scope
    }

    /// A producer wired the way a composition root wires it, and KEEPING IT CURRENT.
    ///
    /// M3 — `setAccountScopeForGapOutcomes` is a snapshot, and `RootView` took it once, in
    /// `init`, from a `let`. `DeviceManager` is a process singleton that outlives the view
    /// tree that built it: a launch while signed out pushes `nil` and nothing ever pushes
    /// again, and a sign-out tears the tab tree down without rebuilding it, so the previous
    /// owner's scope stays on the manager for the life of the process.
    func startGapProducerThatFollowsTheAccount() {
        let manager = DeviceManager()
        let box = deliveredReports
        manager.onGapRecoveryOutcome = { box.append($0) }
        manager.followAccountScopeChanges()
        gapManager = manager
        scopeAtGapOpen = scope
    }

    func signOut() throws {
        try CaptureAccountScope.signOutForTests()
        keyMaterial.material = nil
    }

    func openProducerGapWindow(interrupting captureId: String) throws {
        guard let manager = gapManager else {
            throw BrineStepError("no recording device was stood up")
        }
        manager.setInterruptedCapture(captureId)
        manager.runOnBleQueueForTests { manager.beginGapSyncWindow() }
    }

    func closeProducerGapWindow() throws {
        guard let manager = gapManager else {
            throw BrineStepError("no recording device was stood up")
        }
        manager.runOnBleQueueForTests {
            manager.closeGapWindow(.engineFinished(.synced(records: 1, frames: 60)))
        }
    }

    func theOneDeliveredReport() throws -> GapRecoveryReport {
        let all = deliveredReports.all
        guard all.count == 1 else {
            throw BrineStepError(
                "the recording device delivered \(all.count) gap reports, not 1: \(all)")
        }
        return all[0]
    }

    // MARK: Recording, through the real CaptureManager

    /// Record and FINALIZE a conversation through the real capture path, with the production
    /// composition closure. `route` non-nil drives the Bluetooth audio-route arm — the one
    /// that used to attribute a Field Recorder's conversations to "Phone".
    func recordAndFinalize(recording: CaptureRecordingSource,
                           activeDevice: OmiRestorationComposition.ActiveDeviceResolution) async throws -> String {
        let source = SeamTestSource()
        let finalized = FinalizedBox()
        // THE ONE LINE THAT MAKES THIS DRIVER REACH THE REAL FINALIZE — and the answer to the
        // open item T5 recorded as unexplained (review round 11 §4 cracked it; this is its
        // fix). `CaptureSettings.omiCaptureDesiredState` is an ACCOUNT preference, and a fresh
        // account's snapshot carries no value for it, which the accessor maps `.absent →
        // .paused`. `CaptureManager.init` does `isPaused = (omiCaptureDesiredState == .paused)`,
        // so UNDER AN ACCOUNT BINDING THE MANAGER IS BORN PAUSED. A paused manager skips the
        // whole `if !isPaused { … sessionVoicedFrames += 1 }` block, so `sessionVoicedFrames`
        // stays 0 however many voiced Opus packets are fed in, `hasUploadSubstance(voicedFrames: 0)`
        // is false, and the capture is stamped `.discarded` — "below min-substance bar: 0 voiced
        // frame(s)". Without a binding the same read resolves `.listening`, which is why
        // `CaptureFinalizeTests` (door-free, unbound) never saw it. The difference was never
        // about the finalize lane at all.
        //
        // This is a stated INTENT, not a bypass: production's own gesture for "start listening"
        // writes exactly this preference (`CaptureManager` sets it `.listening` on resume), and
        // a user who has not asked to listen has nothing to finalize.
        CaptureSettings.omiCaptureDesiredState = .listening
        let manager = CaptureManager(
            target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x"),
            baseDir: baseDir,
            source: source,
            finalize: { id, _ in await finalized.append(id) })
        guard !manager.isPaused else {
            throw BrineStepError(
                "the manager was born PAUSED under this account binding, so no frame it is fed "
                    + "will ever be counted as voiced and the capture will be discarded before "
                    + "finalize — the desired-state preference did not take")
        }
        // The SHAPE of the production wiring: the manager hands in what is recording, and the
        // composition root answers from the account-scoped store. Nothing is defaulted.
        // THE MANAGER'S OWN ANSWER IS LOAD-BEARING. An earlier version of this closure ignored
        // what the manager handed in and used the scenario's value, which made every S01 row
        // pass for a reason other than the one it names: a mutation to
        // `recordingSourceForAttribution` could not have reddened any of them. For the arms
        // whose manager state production actually produces (an external stream), the two must
        // AGREE, and disagreeing is a failure rather than a silent substitution.
        manager.captureDeviceContext = { [weak self] asked in
            guard let self else { return .blocked(reason: "the world went away") }
            let effective: CaptureRecordingSource
            if case .externalStream = recording {
                guard asked == recording else {
                    return .blocked(reason:
                        "the manager says it is recording \(asked) while the scenario is driving "
                            + "\(recording) — the seam under test was bypassed")
                }
                effective = asked
            } else {
                // The handset arms need registry state this driver does not stand up; the
                // route seam itself is asserted directly in
                // `testTheAudioRouteArmNamesTheRouteAndNotThePhone`.
                effective = recording
            }
            return OmiRestorationComposition.resolveDeviceContext(
                binding: self.binding, activeDevice: activeDevice, recording: effective)
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
        // WHAT THIS ASSERTS. The conversation went through the production path end to end: the
        // manager opened it on a real speech onset, wrote its device record, took real voiced
        // Opus frames, wrote a segment, stamped `.ended-deliberately`, passed production's OWN
        // substance gate, and REACHED THE FINALIZE. Nothing here is bypassed — the finalize
        // gate ("audio durably on the desktop") is satisfied by writing the `.ack` siblings the
        // WAL itself writes, which is the house door-free technique `CaptureFinalizeTests` uses.
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
        // THE HALF T5 COULD NOT PREVIOUSLY DISCHARGE. A discarded capture is not a finalized
        // one, and the reason is printed rather than left for the next reader to re-derive.
        let discardMarker = closed.appendingPathComponent(".discarded")
        if FileManager.default.fileExists(atPath: discardMarker.path) {
            let why = (try? String(contentsOf: discardMarker, encoding: .utf8)) ?? "(no reason written)"
            throw BrineStepError(
                "the conversation was DISCARDED before finalize — \"\(why)\". A capture the "
                    + "substance gate throws away is never handed to the finalize lane, so "
                    + "nothing downstream ever attributes it")
        }
        let posted = await finalized.all
        guard posted.contains(id) else {
            throw BrineStepError(
                "the production capture path did not finalize this conversation: it finalized "
                    + "\(posted.isEmpty ? "nothing" : posted.description)")
        }
        finalizedConversations.append(contentsOf: posted)
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

    /// S08's two recordings, and the only difference between them: one carries a durable
    /// start the classifier can place before device tracking, the other carries no durable
    /// start and no stamp in its id. NEITHER has a device record or a `.capture-source`
    /// marker, so nothing on disk names a source for either — which is the population the
    /// rendered answer used to shrug at.
    static let s08DatableId = "mic-20240101-000000-LEGACY01"
    static let s08UndatableId = "mic-restored-with-no-stamp"

    /// One of S08's recordings, taken out of the history the launch step BUILT rather than
    /// recomputed here — so these checks are about what the rendered list says.
    @MainActor
    static func s08Row(_ w: DeviceRenderedSurfaceWorld, _ id: String) throws -> CaptureAttribution {
        guard let row = w.historyRows.first(where: { $0.captureId == id }) else {
            throw BrineStepError(
                "the rendered history does not contain \(id) at all "
                    + "(\(w.historyRows.map(\.captureId)))")
        }
        return row.attribution
    }

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

            defineCheck("exactly one recording-device connection affordance is offered") { _, _, _ in
                // The affordance is a VALUE, and there is one of it. A second entry point
                // would be a second string here, and a vendor-specific one would name a
                // vendor — both are checkable, which a screenshot is not.
                let affordance = RecordingDeviceConnectPresentation.affordanceTitle
                guard !affordance.isEmpty else {
                    throw BrineStepError("there is no connection affordance at all")
                }
                try assertNamesNoVendor(affordance, what: "the connection affordance")
            },

            defineCheck("all devices are offered together without a vendor or family choice") { _, _, _ in
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

            defineCheck("no list control that hides a device by family is offered") { _, _, _ in
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
                // THIS NOW REACHES THE FINALIZE, and the clause is discharged on its own
                // rather than jointly with `CaptureFinalizeTests`. T5 recorded the reason it
                // could not as unexplained; review round 11 cracked it (the manager was born
                // PAUSED under an account binding, so no frame was ever counted as voiced and
                // production's substance gate discarded the capture) and `recordAndFinalize`
                // now sets the account's desired state the way the production resume gesture
                // does. See the comment there.
                let (id, baseDir) = try await MainActor.run {
                    (try XCTUnwrapOrThrow(w.connectedConversation, "no conversation was opened"),
                     w.baseDir!)
                }
                let finalized = await MainActor.run { w.finalizedConversations }
                guard finalized.contains(id) else {
                    throw BrineStepError(
                        "the conversation was never handed to the finalize lane — finalized: "
                            + "\(finalized.isEmpty ? "nothing" : finalized.description)")
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

                // AND IT REACHES THE ROW. This is the exact composition
                // `App/CaptureScreen.swift` puts into the conversation card's meta line, so
                // this clause is now a statement about what a person sees rather than about a
                // value nothing calls. `RecordingSurfaceRenderingLedgerTests` is what holds
                // the App-side call site, which `swift test` cannot compile.
                let row = CaptureAttributionPresentation.metaLine("3:04 – 3:21 PM · 17 min",
                                                                   attribution: attribution)
                guard row.contains(name) else {
                    throw BrineStepError(
                        "the conversation row says \"\(row)\" and never names the device that "
                            + "recorded it")
                }
                // An unnameable recorder does NOT put a shrug on the row — the row has no
                // space for the diagnostic that would make it an answer.
                let hedged = CaptureAttributionPresentation.metaLine(
                    "3:04 – 3:21 PM",
                    attribution: CaptureAttribution(
                        deviceName: CaptureAttributionPresentation.unknownDeviceName,
                        diagnostic: "its device record went missing"))
                guard !hedged.contains(CaptureAttributionPresentation.unknownDeviceName) else {
                    throw BrineStepError(
                        "the row prints \"\(CaptureAttributionPresentation.unknownDeviceName)\" "
                            + "with nothing a user can act on")
                }
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

        defineCheck("the device experience reports both capabilities as unavailable") { _, _, _ in
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

        defineCheck("the gap sentence for that outcome says the audio was not recoverable") { _, _, _ in
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

        defineCheck("the gap sentence for that outcome does not say the audio was not recoverable") { _, _, _ in
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

        defineCheck("the legacy history keeps its attribution without onboarding") { _, _, _ in
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

        defineCheck("its recording history keeps its attribution") { _, _, _ in
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

        // MARK: S08 — an era the app can establish, and one it cannot
        //
        // THE POPULATION. Every conversation an upgrading user already owns predates the
        // device record, and the oldest of them predate the `.capture-source` marker too, so
        // nothing on disk names a source for them. Alongside those sits a different animal:
        // a capture with no durable start and no stamp in its id, which the classifier
        // itself says it CANNOT place in an era. The two look identical on disk — no record,
        // no marker — and they are not the same answer, so they must not be given the same
        // sentence. The first is a fact; the second would be a guess wearing a fact's clothes.

        defineStep("an account's history contains a recording from before device tracking with nothing on disk naming its source") { ctx, _, _ in
            try await MainActor.run {
                try w.freshHandset()
                try w.signIn("s08-owner")
                // No device record AND no source marker. `seedConversation` stamps a durable
                // start of NOW, which is before the migration epoch, so the REAL classifier
                // answers `.legacyPreMigration` — the era is established, not assumed.
                try w.seedConversation(id: DeviceRenderedSurfaceSteps.s08DatableId,
                                       device: nil, sourceTag: nil)
                guard case .legacyPreMigration = CaptureDeviceSidecar.provenance(
                        captureId: DeviceRenderedSurfaceSteps.s08DatableId, baseDir: w.baseDir) else {
                    throw BrineStepError(
                        "the seeded recording is not classified pre-migration, so this scenario "
                            + "never reaches the arm it is about")
                }
                guard CaptureManager.capturedSourceOnDisk(DeviceRenderedSurfaceSteps.s08DatableId,
                                                          baseDir: w.baseDir) == nil else {
                    throw BrineStepError(
                        "the seeded recording still names a source on disk — the case under "
                            + "test (nothing on disk to name it by) is not set up")
                }
            }
            return ctx
        },

        defineStep("it also contains a recording nothing on disk can date") { ctx, _, _ in
            try await MainActor.run {
                // Made the way a restored capture is: a note directory with no durable start
                // metadata and an id carrying no parseable stamp. Filesystem dates are
                // forbidden to the classifier, so there is nothing left to date it by.
                let dir = w.baseDir.appendingPathComponent(
                    DeviceRenderedSurfaceSteps.s08UndatableId, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data([1, 2, 3, 4]).write(
                    to: dir.appendingPathComponent("seg-000000000000.opus"))
                guard case .undatable = CaptureDeviceSidecar.provenance(
                        captureId: DeviceRenderedSurfaceSteps.s08UndatableId, baseDir: w.baseDir) else {
                    throw BrineStepError(
                        "the sibling recording is datable after all, so the undatable arm is "
                            + "never reached")
                }
            }
            return ctx
        },

        defineCheck("the datable older recording is described as recorded before device tracking rather than as an unknown device") { _, _, _ in
            let attribution = try await MainActor.run {
                try DeviceRenderedSurfaceSteps.s08Row(w, DeviceRenderedSurfaceSteps.s08DatableId)
            }
            guard attribution.deviceName != CaptureAttributionPresentation.unknownDeviceName else {
                throw BrineStepError(
                    "a recording made before device tracking is reported as a device the app "
                        + "cannot name — nothing about it went missing, and that shrug stands "
                        + "in front of every conversation a legacy user owns")
            }
            guard attribution.deviceName.range(of: "before device",
                                               options: .caseInsensitive) != nil else {
                throw BrineStepError(
                    "it is described as \"\(attribution.deviceName)\", which says nothing about "
                        + "the era that IS the answer for it")
            }
            // NON-VACUOUS: a legacy recording whose shipped marker DOES name a source keeps
            // that name, so this is a statement about the unnameable ones.
            let named = CaptureAttributionPresentation.attribution(
                for: .legacyPreMigration, legacySourceMarker: CaptureSourceKind.omi.rawValue)
            guard named.deviceName == "Omi" else {
                throw BrineStepError(
                    "every legacy recording now renders the era sentence, including the ones "
                        + "whose shipped marker is an answer — this check is vacuous")
            }
        },

        defineCheck("its conversation row carries that description") { _, _, _ in
            let attribution = try await MainActor.run {
                try DeviceRenderedSurfaceSteps.s08Row(w, DeviceRenderedSurfaceSteps.s08DatableId)
            }
            // The exact composition `App/CaptureScreen.swift` puts on the conversation card.
            let base = "3:04 – 3:21 PM · 17 min"
            let row = CaptureAttributionPresentation.metaLine(base, attribution: attribution)
            guard row.contains(attribution.deviceName) else {
                throw BrineStepError(
                    "the conversation row says \"\(row)\" — a legacy user's whole timeline goes "
                        + "back to saying nothing at all about where its recordings came from")
            }
        },

        defineCheck("the undatable recording is not described as belonging to that era") { _, _, _ in
            let (datable, undatable) = try await MainActor.run {
                () -> (CaptureAttribution, CaptureAttribution) in
                (try DeviceRenderedSurfaceSteps.s08Row(w, DeviceRenderedSurfaceSteps.s08DatableId),
                 try DeviceRenderedSurfaceSteps.s08Row(w, DeviceRenderedSurfaceSteps.s08UndatableId))
            }
            guard undatable.deviceName != datable.deviceName else {
                throw BrineStepError(
                    "a recording the app cannot date is described exactly as one it CAN place "
                        + "before device tracking (\"\(undatable.deviceName)\") — the era is the "
                        + "one thing the classifier said was not knowable about it")
            }
            guard undatable.deviceName.range(of: "before device",
                                             options: .caseInsensitive) == nil else {
                throw BrineStepError(
                    "it claims an era in its own words: \"\(undatable.deviceName)\"")
            }
        },

        defineCheck("the undatable recording carries the reason it cannot be placed in an era") { _, _, _ in
            let (provenance, rendered) = try await MainActor.run {
                () -> (CaptureDeviceProvenance, CaptureAttribution) in
                (CaptureDeviceSidecar.provenance(captureId: DeviceRenderedSurfaceSteps.s08UndatableId,
                                                 baseDir: w.baseDir),
                 try DeviceRenderedSurfaceSteps.s08Row(w, DeviceRenderedSurfaceSteps.s08UndatableId))
            }
            guard case .undatable(let built) = provenance else {
                throw BrineStepError("the undatable recording is classified \(provenance)")
            }
            // THE PAYLOAD THE COMBINED ARM THREW AWAY. The classifier writes the sentence
            // explaining why this recording cannot be placed; the surface must render THAT
            // one — not a generic substitute, and not nothing.
            guard rendered.diagnostic == built else {
                throw BrineStepError(
                    "the classifier explained itself — \"\(built)\" — and the surface rendered "
                        + "\(rendered.diagnostic.map { "\"\($0)\"" } ?? "no reason at all") "
                        + "beside \"\(rendered.deviceName)\"")
            }
        },

        defineCheck("no conversation row speaks for the undatable recording") { _, _, _ in
            let (undatable, datable) = try await MainActor.run {
                () -> (CaptureAttribution, CaptureAttribution) in
                (try DeviceRenderedSurfaceSteps.s08Row(w, DeviceRenderedSurfaceSteps.s08UndatableId),
                 try DeviceRenderedSurfaceSteps.s08Row(w, DeviceRenderedSurfaceSteps.s08DatableId))
            }
            let base = "3:04 – 3:21 PM · 17 min"
            let row = CaptureAttributionPresentation.metaLine(base, attribution: undatable)
            guard row == base else {
                throw BrineStepError(
                    "the conversation row says \"\(row)\" for a recording the classifier could "
                        + "not place — the row has no room for the hedge that would make that "
                        + "honest, so it may say nothing at all")
            }
            // NON-VACUOUS: the row DOES speak for the recording whose era is established, so
            // this is a statement about the undatable one and not about a row that has gone
            // silent for everything.
            guard CaptureAttributionPresentation.metaLine(base, attribution: datable) != base else {
                throw BrineStepError("no row says anything about any recording — the check above "
                                         + "cannot fail")
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

        // MARK: N7 — the PRODUCER side: what a real DeviceManager actually delivers

        defineStep("a recording device that has been told which account it is recording for") { ctx, _, _ in
            try await MainActor.run {
                try w.freshHandset()
                try w.signIn("n7-producer-a")
                w.firstAccountScope = w.scope
                w.startGapProducer(tellingItAbout: w.scope)
            }
            return ctx
        },

        defineStep("a recording device that was never told which account it is recording for") { ctx, _, _ in
            try await MainActor.run {
                try w.freshHandset()
                try w.signIn("n7-producer-untold")
                w.firstAccountScope = w.scope
                w.startGapProducer(tellingItAbout: nil)
            }
            return ctx
        },

        defineStep("a recording device that keeps track of which account it is recording for") { ctx, _, _ in
            try await MainActor.run {
                try w.freshHandset()
                try w.signIn("n7-follow-a")
                w.firstAccountScope = w.scope
                w.startGapProducerThatFollowsTheAccount()
            }
            return ctx
        },

        defineStep("that account signs out and a different account signs in") { ctx, _, _ in
            try await MainActor.run {
                try w.signOut()
                try w.signIn("n7-follow-b")
                guard w.scope != w.firstAccountScope else {
                    throw BrineStepError("the second account resolved to the same scope as the first")
                }
            }
            return ctx
        },

        defineStep("that account signs out") { ctx, _, _ in
            try await MainActor.run {
                try w.signOut()
                guard w.scope == CaptureAccountScope.signedOutScope else {
                    throw BrineStepError(
                        "signing out left the scope at \"\(w.scope)\" — nobody signed out")
                }
            }
            return ctx
        },

        defineCheck("the delivered outcome names the account that is signed in now") { _, _, _ in
            try await MainActor.run {
                let report = try w.theOneDeliveredReport()
                let now = w.scope
                guard now != w.firstAccountScope else {
                    throw BrineStepError(
                        "the account never actually changed — this check would pass without "
                            + "the device following anything")
                }
                guard let delivered = report.accountScope else {
                    throw BrineStepError(
                        "the recording device delivered a gap outcome carrying NO account")
                }
                guard delivered == now else {
                    throw BrineStepError(
                        "the outcome names \"\(delivered)\" and the account signed in now is "
                            + "\"\(now)\" — the device is still answering for the previous "
                            + "owner, so every gap outcome this handset produces from here on "
                            + "is withheld from the person actually using it")
                }
            }
        },

        defineCheck("the delivered outcome does not name the account that signed out") { _, _, _ in
            try await MainActor.run {
                let report = try w.theOneDeliveredReport()
                let left = try XCTUnwrapOrThrow(w.firstAccountScope, "no account ever signed in")
                guard report.accountScope != left else {
                    throw BrineStepError(
                        "a window opened AFTER \"\(left)\" signed out was stamped with that "
                            + "account anyway — the device is still answering for somebody who "
                            + "is no longer using it")
                }
                // NON-VACUOUS: the same producer DOES stamp an account when there is one, so
                // this is a statement about sign-out and not about a stamp that never happens.
                guard report.accountScope != nil else {
                    throw BrineStepError(
                        "the outcome names nothing at all — signing out is not the same as "
                            + "never having been told, and collapsing them loses the "
                            + "signed-out container's own audio")
                }
            }
        },

        defineCheck("that outcome is withheld from the account that signed out") { _, _, _ in
            try await MainActor.run {
                let report = try w.theOneDeliveredReport()
                let left = try XCTUnwrapOrThrow(w.firstAccountScope, "no account ever signed in")
                guard case .withheld = GapRecoveryRendering.decide(report, currentScope: left) else {
                    throw BrineStepError(
                        "audio recorded after \"\(left)\" signed out would be rendered into "
                            + "that account's timeline if they signed back in")
                }
                // NON-VACUOUS: it IS rendered to the scope it actually opened under.
                guard case .show = GapRecoveryRendering.decide(
                        report, currentScope: report.accountScope) else {
                    throw BrineStepError("nothing is ever rendered — the withholding proves nothing")
                }
            }
        },

        defineStep("a conversation is interrupted and its gap window opens") { ctx, _, _ in
            try await MainActor.run {
                try w.openProducerGapWindow(interrupting: "cap-n7-producer")
            }
            return ctx
        },

        defineStep("the account this handset records for changes before the window closes") { ctx, _, _ in
            try await MainActor.run {
                try w.signIn("n7-producer-b")
                guard w.scope != w.firstAccountScope else {
                    throw BrineStepError("the second account resolved to the same scope as the first")
                }
                // What production does on an account change (M3). The window is ALREADY OPEN
                // and was tagged at open, so this must not change what the outcome is about —
                // otherwise a device that changes hands mid-window would hand the new owner
                // the previous owner's recording history.
                w.gapManager?.setAccountScopeForGapOutcomes(w.scope)
            }
            return ctx
        },

        defineStep("the gap window closes") { ctx, _, _ in
            try await MainActor.run { try w.closeProducerGapWindow() }
            return ctx
        },

        defineCheck("the delivered outcome names the account the window opened under") { _, _, _ in
            try await MainActor.run {
                let report = try w.theOneDeliveredReport()
                let expected = try XCTUnwrapOrThrow(
                    w.scopeAtGapOpen, "the scenario never recorded which account it told the device about")
                guard let delivered = report.accountScope else {
                    throw BrineStepError(
                        "the recording device delivered a gap outcome carrying NO account. "
                            + "Every outcome it produces is therefore withheld from the account "
                            + "whose audio it is about — forever, and silently, because "
                            + "withholding is the fail-closed default")
                }
                guard delivered == expected else {
                    throw BrineStepError(
                        "the outcome names account \"\(delivered)\" and the window opened under "
                            + "\"\(expected)\" — a gap window answers for the account it opened "
                            + "under, not for whoever is on screen when it closes")
                }
            }
        },

        defineCheck("that outcome is withheld from the account now on screen") { _, _, _ in
            try await MainActor.run {
                let report = try w.theOneDeliveredReport()
                let current = w.scope
                guard current != report.accountScope else {
                    throw BrineStepError(
                        "the account on screen is still the one the window opened under — this "
                            + "check would pass without deciding anything")
                }
                guard case .withheld(let reason) = GapRecoveryRendering.decide(
                        report, currentScope: current) else {
                    throw BrineStepError(
                        "one account's recording history was rendered into the next account's "
                            + "timeline")
                }
                guard !reason.isEmpty else {
                    throw BrineStepError("the outcome vanished without a reason")
                }
                // NON-VACUOUS: the same report IS rendered to its own account, so the
                // withholding above is a decision about the account and not a renderer that
                // never shows anything.
                guard case .show = GapRecoveryRendering.decide(
                        report, currentScope: report.accountScope) else {
                    throw BrineStepError(
                        "the outcome is withheld even from its own account — nothing is ever "
                            + "rendered, so the withholding above proves nothing")
                }
            }
        },

        defineCheck("the delivered outcome names no account") { _, _, _ in
            try await MainActor.run {
                let report = try w.theOneDeliveredReport()
                guard report.accountScope == nil else {
                    throw BrineStepError(
                        "a device nobody told which account it was recording for delivered an "
                            + "outcome stamped \"\(report.accountScope!)\" — it invented one")
                }
            }
        },

        defineCheck("that outcome is withheld with a reason rather than rendered into the account on screen") { _, _, _ in
            try await MainActor.run {
                let report = try w.theOneDeliveredReport()
                let current = w.scope
                guard current != CaptureAccountScope.signedOutScope else {
                    throw BrineStepError(
                        "there is no account on screen at all — the check has nothing to withhold from")
                }
                guard case .withheld(let reason) = GapRecoveryRendering.decide(
                        report, currentScope: current) else {
                    throw BrineStepError(
                        "an outcome that names no account was rendered into whatever account "
                            + "happened to be on screen")
                }
                guard !reason.isEmpty else {
                    throw BrineStepError("the outcome vanished without a reason")
                }
            }
        },
    ]
}

/// Thread-safe collector: `DeviceManager` publishes gap reports on its BLE queue.
final class GapReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GapRecoveryReport] = []
    func append(_ report: GapRecoveryReport) {
        lock.lock(); storage.append(report); lock.unlock()
    }
    var all: [GapRecoveryReport] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
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
