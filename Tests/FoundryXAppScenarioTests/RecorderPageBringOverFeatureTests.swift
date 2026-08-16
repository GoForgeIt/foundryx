import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryX

/// THE FIRST SCENARIOS IN THIS REPO THAT EXECUTE `App/`.
///
/// `PocketRecorderCheckModel` lives in `App/DeviceScreen.swift`. Until this file existed
/// nothing could run it: `swift test` and `FoundryXiOSTests` both compile the FoundryXKit
/// library alone, so the model that decides which recording the app offers, that passes
/// custody to the check, and that re-reads the shelf after a transfer had no test coverage of
/// any kind — while `features/pocket-bring-over.feature` reported seven green scenarios about
/// the machinery underneath it.
///
/// Every object below except the radio is the shipped one, running in the shipped app's
/// process: the app's model, `PocketRecorderCheck.run`, `PocketInventoryReader`,
/// `PocketBringOver.run`, `PocketRecorderFileStore`, `StoredFileDevicePresentation`. The radio
/// is `FakePocketBLEStack` — the same scripted recorder the hostless suite drives — reaching
/// the model through the one DEBUG seam on `PocketRecorderCheckModel`.
///
/// THE MUTATIONS THESE SCENARIOS ANSWER TO, all of them edits to `App/DeviceScreen.swift`:
///   * drop `offeredRecording = PocketBringOver.offered(…)` from `run` and the app offers
///     nothing to bring over, which is `PocketBLEClient.download`'s original defect exactly;
///   * drop `custody: self.custody` from the check and every row claims to be only on the
///     recorder forever, including the one this phone is holding;
///   * drop the `self.run(…)` re-read at the end of `bringOver` and the shelf never learns
///     that the file landed.
/// None of the three moves any existing gate.
final class RecorderPageBringOverFeatureTests: XCTestCase {

    /// The DEBUG radio seam is process-global, so it is cleared whatever the scenario did — a
    /// leaked factory would hand the next suite a recorder it never staged.
    override func tearDown() async throws {
        await MainActor.run { PocketRecorderCheckModel.attachmentFactoryForScenarios = nil }
        try await super.tearDown()
    }

    func testSollevasRecorderPageBringsARecordingOver() async throws {
        let world = await RecorderPageWorld()
        let result = try await BrineFeatureRunner.run(
            "a-recorders-page-offers-to-bring-a-recording-over",
            registry: StepRegistry(RecorderPageSteps.make(world)))
        // THE POPULATION IS PINNED. A runner that only asserts "nothing failed" is green once
        // the scenarios have been deleted — the same shape of hole this lane exists to close.
        XCTAssertEqual(result.passed, 6, "all six scenarios must run and pass")
    }
}

// MARK: - Steps

private enum RecorderPageSteps {
    static func make(_ world: RecorderPageWorld) -> [StepDefinition] {
        let givens = [
            "a remembered recorder holding one recording",
            "a remembered recorder holding nothing",
        ]
        let whens = [
            "Solleva asks that recorder what it is holding",
            "I bring the offered recording over",
            "Solleva sends what it is holding",
        ]
        let thens = [
            "that recorder's page says how full it is and when that was read",
            "nothing on that page says a fact is unavailable",
            "Solleva says what is on the recorder",
            "Solleva offers to bring that recording over",
            "Solleva offers nothing to bring over",
            "Solleva says it kept the recording",
            "the recorder's shelf now says that recording is in Solleva",
            "Solleva's conversations include the one that came off the recorder",
            "it is not presented as a recording in progress",
            "that conversation's audio was uploaded and the conversation was finalized",
            "the audio that went up is the ordinary audio every recording sends",
        ]
        var steps = givens.map { phrase in
            defineStep(phrase) { context, _, _ in try await world.given(phrase); return context }
        }
        steps += whens.map { phrase in
            defineStep(phrase) { context, _, _ in try await world.when(phrase); return context }
        }
        steps += thens.map { phrase in
            defineCheck(phrase) { _, _, _ in try await world.then(phrase) }
        }
        return steps
    }
}

// MARK: - The world one scenario stages

/// `@MainActor` because `PocketRecorderCheckModel` is — it is an `ObservableObject` the app
/// creates and mutates on the main actor, and a world that hopped actors to reach it would be
/// exercising a different threading story than the one that ships.
@MainActor
private final class RecorderPageWorld {
    private static let secret = "0123456789abcdef"
    private static let recorderName = "PKT01_BLUE_26079bc5"
    private static let day = "2026-03-28"
    private static let timestamp = "20260328001919"

    /// REAL AUDIO, AND IT HAS TO BE. This fixture used to be `0xFF 0xF3` followed by a run of
    /// `0x41` — two bytes that satisfy the sync-word check and nothing else — which was enough
    /// while the app's bring-over stopped at custody. It stops there no longer: the app now
    /// DECODES what it pulled and writes a conversation, so a fixture that is not audio would
    /// make every one of these scenarios assert the failure path.
    ///
    /// MPEG-2 Layer III, 32 kbps CBR mono at 16 kHz — the recorder's own format. Carried in the
    /// app-scenario bundle as a RESOURCE, because this lane runs inside the shipping app on a
    /// simulator and cannot reach the repository by `#filePath` the way the hostless suite does.
    private static func fixtureMP3() throws -> Data {
        guard let url = Bundle(for: RecorderPageBringOverFeatureTests.self)
            .url(forResource: "pocket-fw16-3s", withExtension: "mp3") else {
            throw BrineStepError("the Pocket audio fixture is not in the scenario bundle")
        }
        return try Data(contentsOf: url)
    }

    /// THE APP'S OWN MODEL. Not a stand-in with the same shape — the type `App/DeviceScreen
    /// .swift` creates with `@StateObject` on the recorder page.
    private let check = PocketRecorderCheckModel()

    /// THE APP'S CAPTURE OWNER, built the way the app builds it, on a library this scenario
    /// owns. Everything about it is shipped except the two closures that would otherwise reach
    /// a real door — the same two seams `CaptureManager` already exposes for a phone recording.
    private let library: URL
    private let door = ScenarioDoor()
    private let manager: CaptureManager

    /// THE CONVERSATIONS THAT WERE ALREADY THERE when this scenario's bring-over started.
    ///
    /// One world serves every scenario in the feature — that is the runner's shape, and it is
    /// the right one here because the app's model is a `@StateObject` that survives a screen's
    /// life too. So the library ACCUMULATES: after the third bring-over it holds three
    /// conversations, all of them real. "The only conversation in the library" is therefore the
    /// wrong question; "the one THIS scenario produced" is the right one, and it is the
    /// difference between these two sets.
    private var conversationsBeforeBringOver: Set<String> = []

    init() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recorder-page-library-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = root
        let spy = door
        manager = CaptureManager(
            target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x"),
            baseDir: root,
            source: ReplaySource(frames: []),
            finalize: { id, _ in spy.finalize(id) },
            uploadSegment: { id, seq, body in spy.upload(id, seq, body) })
    }

    /// EVERY recorder this world has ever stood up, kept for the world's whole life. The
    /// fake's peripheral and central hold their stack `unowned`, so releasing one while any
    /// in-flight session still refers to it is a crash rather than a test failure — and the
    /// scenario that would trip it is precisely the one where a check is slow.
    private var stacks: [FakePocketBLEStack] = []
    private var identifier = UUID()
    private let secrets = InMemoryPocketSecretStore()
    private let recovery = InMemoryPocketKeyRecoveryStore()

    // MARK: Given

    func given(_ phrase: String) async throws {
        switch phrase {
        case "a remembered recorder holding one recording":
            let audio = try Self.fixtureMP3()
            try await stageRecorder(holding: [
                .init(date: Self.day, timestamp: Self.timestamp, sizeBytes: audio.count,
                      content: audio),
            ])
        case "a remembered recorder holding nothing":
            try await stageRecorder(holding: [])
        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    /// Stand a recorder up, put the key for it where the shipped attachment will look, and
    /// point the APP'S model at that radio. Everything after this line is production code.
    private func stageRecorder(holding inventory: [FakePocketBLEStack.ScriptedRecording])
        async throws {
        identifier = UUID()
        let made = FakePocketBLEStack(deviceId: identifier,
                                      deviceName: Self.recorderName,
                                      acceptedSecret: Self.secret,
                                      inventory: inventory)
        stacks.append(made)
        try await secrets.save(
            Self.secret,
            for: try PocketAuthenticatedIdentity(peripheralIdentifier: identifier.uuidString))
        // "REMEMBERED" WAS FIXTURE PROSE UNTIL NOW, and it is a real part of the state under
        // test. On a phone, a recorder's page exists only because the ACCOUNT STORE holds a
        // record for it — that record is what the device list draws, what the page's inputs
        // are projected from, and (as of Step 7) what carries the facts a check learned. The
        // scenarios above never needed it because they read `check.detail` directly; a
        // scenario about the PAGE does, and a fixture that says "remembered" while the store
        // is empty is a fixture describing something else.
        RecordingDeviceStore.recordUserPair(
            identity: RecordingDeviceIdentity(shape: .filePull,
                                              hardwareToken: identifier.uuidString.lowercased()),
            displayName: Self.recorderName)
        let secrets = self.secrets
        let recovery = self.recovery
        PocketRecorderCheckModel.attachmentFactoryForScenarios = {
            RecordingDeviceAttachment(
                makeCentral: made.factory,
                secrets: secrets,
                recovery: recovery,
                deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 5),
                log: nil)
        }
    }

    // MARK: When

    func when(_ phrase: String) async throws {
        switch phrase {
        // THE APP'S ENTRY POINT, WITH THE APP'S ARGUMENTS. `hardwareToken` is the peripheral
        // identifier, which is exactly what `input.identity.hardwareToken` carries on the page.
        case "Solleva asks that recorder what it is holding":
            // THE SAME TWO ARGUMENTS THE SHIPPING PAGE PASSES, from the same manager: the
            // capture library the `.lore-confirmed` marker lives in, and the memory-only
            // stage snapshot. Omitting them would drive a DIFFERENT call than `DeviceScreen`
            // makes, which is the gap this whole scenario file exists to close.
            check.run(hardwareToken: identifier.uuidString, advertisedName: Self.recorderName,
                      library: manager.captureLibraryRoot, stages: manager.captureStages())
            try await AppScenarioHost.settle(untilTrue: { !self.check.isChecking },
                                             describing: "the check to finish")

        case "I bring the offered recording over":
            conversationsBeforeBringOver = notesInLibrary()
            check.bringOver(hardwareToken: identifier.uuidString,
                            advertisedName: Self.recorderName,
                            into: manager)
            // BOTH FLAGS, because `bringOver` ends by re-running the check — and the whole
            // point of the last Then is that it does. Waiting on `isBringingOver` alone would
            // read the shelf mid-re-read and the scenario would be a race.
            try await AppScenarioHost.settle(
                untilTrue: { !self.check.isBringingOver && !self.check.isChecking },
                describing: "the bring-over and the shelf re-read that follows it")

        // THE APP'S OWN LANE, NOT A SUBSTITUTE FOR IT. `drainPending` is what the manager's
        // five-second timer calls for every pending capture there is; adoption already kicked
        // it, and `drainPending` refuses to run twice at once, so this waits for the OUTCOME
        // rather than replacing the pass already in flight.
        case "Solleva sends what it is holding":
            // WAIT FOR THIS SCENARIO'S CONVERSATION, not for "something finalized" — the world
            // is shared, so earlier scenarios' captures are already in this spy.
            let pending = try requireCaptureID()
            for _ in 0..<300 where !door.finalized.contains(pending) {
                await manager.drainPending()
                await manager.retryPendingFinalizes()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    // MARK: Then

    func then(_ phrase: String) async throws {
        switch phrase {
        case "Solleva says what is on the recorder":
            guard let detail = check.detail else {
                throw BrineStepError(
                    "the app's model produced no shelf at all. Its message was: "
                        + (check.message ?? "(none)"))
            }
            guard detail.name.isEmpty == false else {
                throw BrineStepError("the shelf named no recorder")
            }

        case "Solleva offers to bring that recording over":
            guard let offered = check.offeredRecording else {
                throw BrineStepError(
                    "the recorder is holding a recording and the app offered nothing to bring "
                        + "over. `PocketBringOver.offered` works — the hostless suite proves "
                        + "that, and proved it while nothing on earth called it — so what is "
                        + "missing is the CALLER in App/DeviceScreen.swift. The shelf the app "
                        + "did read: \(check.detail?.manifest.rows.count ?? 0) row(s)")
            }
            guard offered.timestamp == Self.timestamp else {
                throw BrineStepError("the app offered \(offered.timestamp), not the recording "
                                        + "on the recorder (\(Self.timestamp))")
            }

        // THE SIMULATOR PROOF FOR STEP 7, and the only lane that can give one.
        //
        // The check runs inside the shipping app's process, through the app's own model, and
        // this step then builds the recorder's page THE WAY THE SCREEN BUILDS IT — off the
        // account store, through `UnifiedDeviceListComposition`, into `RecordingDevicePage`.
        // Nothing here is a stand-in: if `PocketRecorderCheck` stopped keeping what the
        // recorder said, or the projection stopped carrying it, or the page stopped rendering
        // it, this is red and the hostless suite is not.
        case "that recorder's page says how full it is and when that was read":
            let page = try recorderPage()
            guard let space = page.readings.first(where: { $0.label == "Free space" }) else {
                throw BrineStepError(
                    "the recorder's page renders no free-space reading at all — it renders "
                        + "\(page.readings.map(\.label))")
            }
            // 61,032 KB reported, 12,000 used ⇒ 49,032 free. Both numbers came off the
            // recorder over the radio seam; only the subtraction happened here.
            guard space.value == "47.9 MB free of 59.6 MB" else {
                throw BrineStepError(
                    "the page says free space is \(space.value ?? "(nothing)") — the recorder "
                        + "reported \(FakePocketBLEStack.usedKilobytes) KB used of "
                        + "\(FakePocketBLEStack.capacityKilobytes) KB")
            }
            guard let ago = space.observedAgo, ago.hasPrefix("read ") else {
                throw BrineStepError(
                    "the page states a number with no statement of when it was read")
            }
            // PAIRED EXISTENCE for the prohibition below: the battery is a second fact this
            // same session measured, so "nothing says unavailable" cannot pass on a blank pane.
            guard page.readings.first(where: { $0.label == "Battery" })?.value == "72%" else {
                throw BrineStepError("the page did not keep the battery this session read")
            }

        case "nothing on that page says a fact is unavailable":
            let page = try recorderPage()
            var lines = [page.displayName, page.classCaption, page.status] + page.actions
            lines += [page.capabilityNote, page.recordingIndicatorSentence, page.forgetWarning]
                .compactMap { $0 }
            lines += page.capabilities.flatMap { [$0.label, $0.value] }
            lines += page.readings
                .flatMap { [$0.label, $0.value, $0.observedAgo, $0.action] }.compactMap { $0 }
            for banned in [RecordingDeviceConnectPresentation.unavailableValue,
                           DeviceMetricsPresentation.unavailableValue] {
                guard !lines.contains(where: { $0.contains(banned) }) else {
                    throw BrineStepError(
                        "the recorder's page says \"\(banned)\" one second after a session "
                            + "that measured the facts it is talking about")
                }
            }

        case "Solleva offers nothing to bring over":
            guard check.offeredRecording == nil else {
                throw BrineStepError(
                    "the recorder is holding nothing and the app still offered to bring "
                        + "something over")
            }

        case "Solleva says it kept the recording":
            guard check.bringOverMessage == PocketBringOverPresentation.broughtOverLine else {
                throw BrineStepError(
                    "the app said \"\(check.bringOverMessage ?? "(nothing at all)")\" rather "
                        + "than that it kept the recording")
            }

        // THE LOAD-BEARING ONE. Custody is a fact about this phone's disk, and the only way
        // the page can state it is if the app (a) hands `custody` to the check and (b) asks
        // again after a transfer. Remove either from App/DeviceScreen.swift and this is red;
        // nothing else in the repository moves.
        case "the recorder's shelf now says that recording is in Solleva":
            let rows = check.detail?.manifest.rows ?? []
            guard let row = rows.first else {
                throw BrineStepError("the shelf has no rows after the bring-over — the app "
                                        + "never re-read it")
            }
            // THE FACT, NOT ONE REMEMBERED STRING. This used to compare against the literal
            // "In Solleva", which was the whole two-valued custody vocabulary. Now the phone
            // and "safe elsewhere" are SEPARATE places, so a file that has landed but has not
            // yet been finalized and confirmed truthfully reads "In Solleva, on this iPhone
            // only" — and asserting the old literal would fail on a row that is RIGHT. What
            // this scenario means is that the phone answered YES, so that is what it asks.
            guard row.presence.onThisPhone.isYes else {
                throw BrineStepError(
                    "the row still reads \"\(row.presenceLabel)\" after the file landed "
                        + "(on this phone: \(row.presence.onThisPhone.answer.rawValue)). Either "
                        + "the app never asked custody, or it never re-read the shelf")
            }
            // AND IT IS STILL SAID IN WORDS. A presence nothing renders is a fact the person
            // never sees, which is the half of this that a struct assertion alone cannot hold.
            guard row.presenceLabel.contains("In Solleva") else {
                throw BrineStepError(
                    "the phone answered yes and the row says \"\(row.presenceLabel)\"")
            }

        // THE CLAIM THE WHOLE LEG IS FOR: it is a CONVERSATION, in the library the app's own
        // capture owner hydrates from, holding the audio that came off the recorder.
        case "Solleva's conversations include the one that came off the recorder":
            let captureID = try requireCaptureID()
            guard manager.captures.contains(where: { $0.captureId == captureID }) else {
                throw BrineStepError(
                    "the app brought a recording over and its capture owner does not know the "
                        + "conversation exists. `PocketCaptureImport` writes a correct directory "
                        + "either way — what is missing is `adoptCompletedCapture` in "
                        + "App/DeviceScreen.swift, and until the next launch nothing would "
                        + "upload it or show it")
            }
            let segments = try segments(of: captureID)
            guard !segments.isEmpty else {
                throw BrineStepError("the conversation holds no audio")
            }
            // ORDINARY SEGMENTS, read back with the ORDINARY decoder — if these were anything
            // but the length-framed Opus packets every capture is made of, this returns nothing.
            var frames = 0
            for segment in segments {
                let decoded = CaptureWAL.decodeSegment(try Data(contentsOf: segment))
                guard !decoded.isEmpty else {
                    throw BrineStepError("\(segment.lastPathComponent) is not a capture segment")
                }
                frames += decoded.count
            }
            // ~3.1 s of audio at one 20 ms packet each. Silence, one frame, or the whole file as
            // a single packet all miss this by an order of magnitude.
            guard (120...200).contains(frames) else {
                throw BrineStepError("the conversation holds \(frames) frames of audio, not the "
                                        + "~155 that 3.1 seconds makes")
            }

        case "it is not presented as a recording in progress":
            let captureID = try requireCaptureID()
            guard manager.active == nil, !manager.isRecordingMic else {
                throw BrineStepError("bringing a file over put the app into a live recording")
            }
            guard let wal = manager.captures.first(where: { $0.captureId == captureID }) else {
                throw BrineStepError("the conversation is not in the library")
            }
            wal.warmStatus()
            guard !wal.status.streaming else {
                throw BrineStepError("the brought-over conversation is marked as still arriving")
            }
            // AND THE SHIPPED SCAN REFUSES IT AS A LIVE CANDIDATE: `resumableCaptureId` only
            // adopts a capture marked `omi`, and a pulled recording is marked `filePull`, so no
            // microphone session can ever attach and carry on recording into it.
            guard CaptureManager.resumableCaptureId(baseDir: library, silenceGap: 3_600) == nil
            else {
                throw BrineStepError("the app offers a brought-over recording to the live path")
            }

        // SCOPED TO THIS SCENARIO'S CONVERSATION, because the world is shared and the manager
        // drains EVERY pending capture in its library — including the ones earlier scenarios
        // brought over, which is itself the correct behaviour and not something to suppress.
        case "that conversation's audio was uploaded and the conversation was finalized":
            let captureID = try requireCaptureID()
            let finalized = door.finalized.filter { $0 == captureID }
            guard finalized.count == 1 else {
                throw BrineStepError(
                    "the conversation reached finalize \(finalized.count) time(s) — it must reach "
                        + "the shipped finalize exactly once, through the same `CaptureBackend` "
                        + "seam a phone recording uses")
            }
            let uploaded = door.uploaded.filter { $0.0 == captureID }
            guard !uploaded.isEmpty else {
                throw BrineStepError("no audio reached the shipped segment-upload seam")
            }
            let onDisk = try segments(of: captureID).count
            guard Set(uploaded.map(\.1)).count == uploaded.count, uploaded.count == onDisk else {
                throw BrineStepError("\(uploaded.count) of \(onDisk) segments reached the brain")
            }

        case "the audio that went up is the ordinary audio every recording sends":
            let captureID = try requireCaptureID()
            let bodies = door.uploaded.filter { $0.0 == captureID }
            guard !bodies.isEmpty else {
                throw BrineStepError("nothing was uploaded for this conversation")
            }
            for (_, _, body) in bodies where CaptureWAL.decodeSegment(body).isEmpty {
                throw BrineStepError(
                    "an uploaded body is not a capture segment — the brain is being handed a "
                        + "second wire shape for this one source")
            }

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    // MARK: What the app produced

    /// THE RECORDER'S PAGE, COMPOSED THE WAY THE SCREEN COMPOSES IT.
    ///
    /// `RecordingDevicePageView` reads `RecordingDeviceListModel`'s input for this identity and
    /// calls `RecordingDevicePage.resolve`; the model in turn builds those inputs from
    /// `UnifiedDeviceListComposition.rememberedForCurrentAccount()`. Both of those are the
    /// shipped functions, so this is the same chain with the SwiftUI body removed — which is
    /// the most of it a scenario can drive, and it is the half that decides every string.
    private func recorderPage() throws -> RecordingDevicePagePresentation {
        let identity = RecordingDeviceIdentity(shape: .filePull,
                                               hardwareToken: identifier.uuidString.lowercased())
        let inputs = UnifiedDeviceListComposition.inputs(
            remembered: UnifiedDeviceListComposition.rememberedForCurrentAccount(),
            captureSources: [])
        guard let input = inputs.first(where: { $0.identity == identity }) else {
            throw BrineStepError(
                "the account does not remember the recorder this scenario just checked — it "
                    + "remembers \(inputs.map(\.identity.hardwareToken))")
        }
        return RecordingDevicePage.resolve(input)
    }

    private func notesInLibrary() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? [])
            .filter(CaptureLibrary.isNoteDirectory))
    }

    /// The conversation THIS scenario's bring-over produced.
    private func requireCaptureID() throws -> String {
        let made = notesInLibrary().subtracting(conversationsBeforeBringOver)
        guard made.count == 1, let only = made.first else {
            throw BrineStepError(
                "bringing one recording over produced \(made.count) new conversation(s), not "
                    + "one (the library held \(conversationsBeforeBringOver.count) before)")
        }
        return only
    }

    private func segments(of captureID: String) throws -> [URL] {
        let dir = library.appendingPathComponent(captureID, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: dir,
                                                              includingPropertiesForKeys: nil))
            ?? []).filter { $0.pathExtension == "opus" }.sorted { $0.path < $1.path }
    }
}

/// The two calls that would otherwise reach a real door, recorded — the SAME two a phone-mic
/// recording makes, injected at the SAME two seams `CaptureManager` already exposes.
private final class ScenarioDoor: @unchecked Sendable {
    private let lock = NSLock()
    private var _finalized: [String] = []
    private var _uploaded: [(String, UInt64, Data)] = []
    var finalized: [String] { lock.lock(); defer { lock.unlock() }; return _finalized }
    var uploaded: [(String, UInt64, Data)] { lock.lock(); defer { lock.unlock() }; return _uploaded }
    func finalize(_ id: String) { lock.lock(); _finalized.append(id); lock.unlock() }
    func upload(_ id: String, _ seq: UInt64, _ body: Data) {
        lock.lock(); _uploaded.append((id, seq, body)); lock.unlock()
    }
}
