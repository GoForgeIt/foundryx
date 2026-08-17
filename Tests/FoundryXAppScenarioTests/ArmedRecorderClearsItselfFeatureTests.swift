import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryX

/// `features/an-armed-recorder-actually-clears-itself.feature`.
///
/// WHY THIS LANE AND NOT THE HOSTLESS ONE. `clearWhatTheArmedControlAllows` is a private method
/// on `PocketRecorderCheckModel`, which lives in `App/DeviceScreen.swift`. `swift test` cannot
/// compile `App/`, so every scenario the owner-armed clear shipped with drives
/// `PocketAutoClear.decision` — a PURE FUNCTION over a reading somebody handed it. Nothing
/// anywhere drove the thing that decides which recordings to hand it, opens the session and
/// composes the frame.
///
/// AND THAT IS WHERE THE DEFECT WAS. The sweep read `presences`, which is resolved against a
/// `PocketCaptureDurability` built at CHECK time from a stage SNAPSHOT — so a recording brought
/// over AFTER that check has no stage in the snapshot at all and can never become safe
/// elsewhere on that page, no matter how long the drain runs. Its one caller was the tail of a
/// bring-over, which is the single instant the evidence provably cannot exist. Every pure-
/// function scenario stayed green while the behaviour they describe removed nothing, ever.
///
/// Everything below except the radio is the shipped object, in the shipped app's process: the
/// app's model, `PocketRemoveFromRecorder.run`, `PocketDeleteConsent`, the real
/// `RecordingDeviceStore`, the real `PocketCaptureDurability`, and the real command ledger the
/// assertion reads.
final class ArmedRecorderClearsItselfFeatureTests: XCTestCase {

    override func tearDown() async throws {
        await MainActor.run { PocketRecorderCheckModel.attachmentFactoryForScenarios = nil }
        try await super.tearDown()
    }

    func testAnArmedRecorderActuallyClearsItself() async throws {
        let world = await ArmedClearWorld()
        let result = try await BrineFeatureRunner.run(
            "an-armed-recorder-actually-clears-itself",
            registry: StepRegistry(ArmedClearSteps.make(world)))
        XCTAssertEqual(result.passed, 2, "both scenarios must run and pass")
    }
}

private enum ArmedClearSteps {
    static func make(_ world: ArmedClearWorld) -> [StepDefinition] {
        let givens = [
            "a remembered recorder holding one recording, with automatic clearing armed",
            "a remembered recorder holding one recording, with automatic clearing left alone",
        ]
        let whens = [
            "I bring that recording over",
            "Solleva confirms it is safe on my computer",
            "Solleva checks that recorder again",
        ]
        let thens = [
            "Solleva asked that recorder to remove that recording",
            "it is gone from the recorder's own shelf",
            "Solleva never asked that recorder to remove anything",
            "the recording is still on the recorder's own shelf",
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

@MainActor
private final class ArmedClearWorld {

    private static let secret = "0123456789abcdef"
    private static let recorderName = "PKT01_BLUE_26079bc5"
    private static let day = "2026-03-28"
    private static let timestamp = "20260328001919"

    private let check = PocketRecorderCheckModel()
    private let library: URL
    private let manager: CaptureManager
    private let secrets = InMemoryPocketSecretStore()
    private let recovery = InMemoryPocketKeyRecoveryStore()
    private var stacks: [FakePocketBLEStack] = []
    private var identifier = UUID()
    private var identity: RecordingDeviceIdentity?
    private var conversationsBefore: Set<String> = []
    private var mark: PocketRecorderCommandLedger.Mark?

    init() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("armed-clear-library-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = root
        manager = CaptureManager(
            target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x"),
            baseDir: root,
            source: ReplaySource(frames: []),
            finalize: { _, _ in },
            uploadSegment: { _, _, _ in })
    }

    private static func fixtureMP3() throws -> Data {
        guard let url = Bundle(for: ArmedRecorderClearsItselfFeatureTests.self)
            .url(forResource: "pocket-fw16-3s", withExtension: "mp3") else {
            throw BrineStepError("the Pocket audio fixture is not in the scenario bundle")
        }
        return try Data(contentsOf: url)
    }

    // MARK: Given

    func given(_ phrase: String) async throws {
        let armed: Bool
        switch phrase {
        case "a remembered recorder holding one recording, with automatic clearing armed":
            armed = true
        case "a remembered recorder holding one recording, with automatic clearing left alone":
            armed = false
        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }

        let audio = try Self.fixtureMP3()
        identifier = UUID()
        let made = FakePocketBLEStack(
            deviceId: identifier,
            deviceName: Self.recorderName,
            acceptedSecret: Self.secret,
            inventory: [.init(date: Self.day, timestamp: Self.timestamp,
                              sizeBytes: audio.count, content: audio)])
        stacks.append(made)
        try await secrets.save(
            Self.secret,
            for: try PocketAuthenticatedIdentity(peripheralIdentifier: identifier.uuidString))
        let identity = RecordingDeviceIdentity(shape: .filePull,
                                               hardwareToken: identifier.uuidString.lowercased())
        self.identity = identity
        RecordingDeviceStore.recordUserPair(identity: identity, displayName: Self.recorderName)

        // THE CONTROL IS ARMED THROUGH THE SHIPPED STORE, at an instant BEFORE the transfer —
        // arming is not retroactive, so an arming stamped after the sync would refuse for the
        // right reason and this scenario would pass while proving nothing.
        if let store = RecordingDeviceStore.current() {
            if armed {
                try store.armAutoClear(identity, at: Date().addingTimeInterval(-60))
            } else {
                // STATED, NOT ASSUMED. `off` is the default, and saying so here is what makes
                // the second scenario a control rather than a scenario that forgot a step.
                try store.disarmAutoClear(identity)
            }
        } else {
            throw BrineStepError("no account scope, so the armed control has nowhere to live")
        }

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

        // THE FIRST CHECK. The page has to have asked before it can bring anything over, and it
        // is this check whose stage snapshot the old code was still resolving against minutes
        // later.
        try await runCheck()
    }

    // MARK: When

    func when(_ phrase: String) async throws {
        switch phrase {
        case "I bring that recording over":
            conversationsBefore = notesInLibrary()
            check.bringOver(hardwareToken: identifier.uuidString,
                            advertisedName: Self.recorderName,
                            into: manager)
            try await AppScenarioHost.settle(
                untilTrue: { !self.check.isBringingOver && !self.check.isChecking },
                describing: "the transfer and the re-read that follows it to finish")

        case "Solleva confirms it is safe on my computer":
            // THE CEILING OF THE SHIPPED PREDICATE, written by the shipped writer: the
            // `.lore-confirmed` marker the retention sweep is built to preserve. This is the
            // door path's own write, not a flag invented for the test.
            let captureID = try requireCaptureID()
            TranscriptCacheStore.save(
                CachedTranscript(transcript: "hello", title: nil, summary: nil, fetchedAt: 1),
                captureId: captureID, baseDir: library, markConfirmed: true)
            // THE MARK IS TAKEN HERE, so the assertion counts only frames composed by the
            // sweep that follows — never the bring-over's own commands.
            mark = await PocketRecorderCommandLedger.shared.mark()

        case "Solleva checks that recorder again":
            try await runCheck()

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    // MARK: Then

    func then(_ phrase: String) async throws {
        switch phrase {
        case "Solleva asked that recorder to remove that recording":
            let deletes = try await composedDeletes()
            guard deletes.count == 1 else {
                throw BrineStepError(
                    "the armed recorder composed \(deletes.count) deletion(s) — the control was "
                        + "armed, the recording was brought over and its copy was confirmed, "
                        + "and the sweep still asked for nothing")
            }
            guard deletes[0].frame.hasSuffix("&\(Self.day)&\(Self.timestamp)") else {
                throw BrineStepError("the frame \(deletes[0].frame) does not name the recording "
                                        + "that was brought over")
            }

        case "it is gone from the recorder's own shelf":
            guard !(try shelfTimestamps()).contains(Self.timestamp) else {
                throw BrineStepError("the recorder's own shelf still lists the recording")
            }

        case "Solleva never asked that recorder to remove anything":
            let deletes = try await composedDeletes()
            guard deletes.isEmpty else {
                throw BrineStepError(
                    "a recorder nobody armed composed \(deletes.count) deletion(s): "
                        + "\(deletes.map(\.frame))")
            }

        case "the recording is still on the recorder's own shelf":
            guard (try shelfTimestamps()).contains(Self.timestamp) else {
                throw BrineStepError("the recording left a recorder nobody armed")
            }

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    // MARK: Fixture

    /// THE PAGE'S OWN CALL, with the page's own arguments — including a stage snapshot taken
    /// NOW. That freshness is the fix under test.
    private func runCheck() async throws {
        check.run(hardwareToken: identifier.uuidString, advertisedName: Self.recorderName,
                  library: manager.captureLibraryRoot, stages: manager.captureStages(),
                  brain: .myComputer)
        try await AppScenarioHost.settle(untilTrue: { !self.check.isChecking && !self.check.isRemoving },
                                         describing: "the check and any armed sweep to finish")
    }

    private func composedDeletes() async throws -> [PocketRecorderComposedCommand] {
        guard let mark else { throw BrineStepError("no ledger mark was taken") }
        return await PocketRecorderCommandLedger.shared.composed(since: mark)
            .filter(\.namesADeletion)
    }

    private func shelfTimestamps() throws -> [String] {
        (check.detail?.manifest.rows ?? []).map { row in
            String(row.id.split(separator: "/").last ?? "")
        }
    }

    private func notesInLibrary() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? [])
            .filter(CaptureLibrary.isNoteDirectory))
    }

    private func requireCaptureID() throws -> String {
        let made = notesInLibrary().subtracting(conversationsBefore)
        guard made.count == 1, let only = made.first else {
            throw BrineStepError("bringing one recording over produced \(made.count) new "
                                    + "conversation(s), not one")
        }
        return only
    }
}
