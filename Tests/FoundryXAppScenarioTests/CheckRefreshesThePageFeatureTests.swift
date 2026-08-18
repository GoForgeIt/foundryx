import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryX

/// `features/the-recorder-page-re-reads-what-an-errand-changed.feature`
///
/// WHAT THIS LANE HOLDS THAT NOTHING ELSE COULD, MEASURED RATHER THAN ASSERTED.
///
/// On 2026-08-17, against `ac0bbe2`, two one-line edits to `App/DeviceScreen.swift` were run:
///
///   * `.onChange(of: check.isChecking) { guard !checking else { return } … }` → `guard checking`
///     — the re-read fires on the RISING edge, so a finished check's numbers reach the page
///     never. `swift test --disable-sandbox --filter FoundryXBrineTests`: **1536 executed, 5
///     skipped, 0 failures**, byte-identical to the clean baseline. `scripts/ci-gates.sh
///     appscenarios` as it then stood: **7 executed, 0 failures**.
///   * `refreshedInput = refreshed` → `_ = await …` — the disk read runs and its result reaches
///     no surface. Same: 1536 / 0.
///
/// The seven `contains()` assertions that were supposed to hold this behaviour all passed,
/// because every string they name was still in the file. A string can be present while the
/// value it produces reaches nobody.
///
/// SO THIS SUITE ASSERTS ON A VALUE, NOT ON A FILE. It builds the real `RecorderPageModel`
/// over the real `PocketRecorderCheckModel` — the two objects `RecordingDevicePageView` holds —
/// drives real errands over a scripted radio inside the shipping app's process on the iOS
/// runtime, and reads `model.page(pushed:)`, which is the presentation the body renders 1:1.
/// There is no string here for a mutation to satisfy: the numbers are in the presentation or
/// they are not.
///
/// THE MUTATIONS THIS ANSWERS TO, each proven to turn it red:
///   * fire the re-read from `beginErrand` instead of `finishErrand` — scenario 1 red;
///   * drop the re-read's result on the floor (`_ = await …`) — scenario 1 red;
///   * delete `onErrandFinished?()` from `finishErrand` — scenarios 1, 2 and 4 red;
///   * make `RecordingDevicePageFacts.readings` always return the re-read (the shipped latch)
///     — scenario 3 red;
///   * lump a store that throws in with a device the store does not hold — scenario 4 red.
final class CheckRefreshesThePageFeatureTests: XCTestCase {

    /// Held so `tearDown` can reach it. One scenario here DAMAGES this account's device file on
    /// purpose — it is the only way to reach the condition `RecordingDeviceStore.records()`
    /// throws on — and that file is process-global state every other suite in this bundle
    /// reads. Leaving it corrupt turned `RecorderPageBringOverFeatureTests` red on the first
    /// run of this suite, which is the right way round for a test bundle to find out.
    private var world: PageReReadWorld?

    /// The DEBUG radio seam is process-global, so it is cleared whatever the scenario did.
    override func tearDown() async throws {
        await world?.putBackWhatTheseScenariosBroke()
        world = nil
        await MainActor.run { PocketRecorderCheckModel.attachmentFactoryForScenarios = nil }
        try await super.tearDown()
    }

    func testTheRecorderPageReReadsWhatAnErrandChanged() async throws {
        let world = await PageReReadWorld()
        self.world = world
        let result = try await BrineFeatureRunner.run(
            "the-recorder-page-re-reads-what-an-errand-changed",
            registry: StepRegistry(PageReReadSteps.make(world)))
        // THE POPULATION IS PINNED. A runner that only asserts "nothing failed" is green once
        // the scenarios have been deleted.
        XCTAssertEqual(result.passed, 4, "all four scenarios must run and pass")
    }
}

// MARK: - Steps

private enum PageReReadSteps {
    static func make(_ world: PageReReadWorld) -> [StepDefinition] {
        let givens = [
            "a remembered recorder whose page has never been told anything",
            "a remembered recorder holding a recording Solleva has already taken into its keeping",
            "a recorder page that has re-read what a check wrote",
        ]
        let whens = [
            "I ask that recorder what it is holding",
            "that recording is removed from the recorder",
            "the list behind that page pushes a newer reading",
            "this account's record of that recorder can no longer be read",
        ]
        let thens = [
            "that page shows the charge and the firmware the recorder just answered",
            "no fact on that page still offers to go and ask",
            "that page shows more free space than it showed before the removal",
            "that page shows the newer reading",
            "that page says it could not read what this account has saved for that recorder",
            "that page still shows the last numbers the recorder gave",
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

/// `@MainActor` because both models are.
@MainActor
private final class PageReReadWorld {

    private static let secret = "0123456789abcdef"
    private static let recorderName = "PKT01_BLUE_26079bc5"
    private static let day = "2026-03-28"
    private static let timestamp = "20260328001919"

    /// THE TWO OBJECTS `RecordingDevicePageView` HOLDS, built the way it builds them: one
    /// `@StateObject` over the page model, and the errand model reached through it.
    private var check = PocketRecorderCheckModel()
    private var model: RecorderPageModel!

    private let library: URL
    private let manager: CaptureManager
    private let secrets = InMemoryPocketSecretStore()
    private let recovery = InMemoryPocketKeyRecoveryStore()
    /// The fake's peripheral and central hold their stack `unowned`, so releasing one while an
    /// in-flight session still refers to it is a crash rather than a failure.
    private var stacks: [FakePocketBLEStack] = []
    private var stack: FakePocketBLEStack!
    private var identifier = UUID()
    private var identity = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "")

    /// WHAT THE LIST PUSHED INTO THE PAGE. Kept separately from what the page renders, because
    /// every claim here is that the page shows something this value does NOT — a scenario that
    /// re-composed the pushed value from the store between the errand and the claim would prove
    /// nothing at all.
    private var pushed = RecordingDeviceListInput(identity: .init(shape: .filePull,
                                                                  hardwareToken: ""),
                                                  displayName: "")
    private var conversationsBefore: Set<String> = []
    private var freeSpaceBefore: String?
    /// The account device file one scenario deliberately corrupts, and the bytes it held.
    private var damagedStore: (url: URL, bytes: Data?)?

    /// PUT THE PROCESS BACK. `RecordingDeviceStore` is account-scoped global state shared by
    /// every suite in this bundle, and one scenario here breaks it on purpose.
    func putBackWhatTheseScenariosBroke() {
        guard let damaged = damagedStore else { return }
        if let bytes = damaged.bytes {
            try? bytes.write(to: damaged.url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: damaged.url)
        }
        damagedStore = nil
    }

    init() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("page-reread-library-\(UUID().uuidString)", isDirectory: true)
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
        guard let url = Bundle(for: CheckRefreshesThePageFeatureTests.self)
            .url(forResource: "pocket-fw16-3s", withExtension: "mp3") else {
            throw BrineStepError("the Pocket audio fixture is not in the scenario bundle")
        }
        return try Data(contentsOf: url)
    }

    // MARK: Given

    func given(_ phrase: String) async throws {
        switch phrase {
        case "a remembered recorder whose page has never been told anything":
            try await stageRecorderAndPage()
            // THE STATE UNDER TEST, ASSERTED RATHER THAN ASSUMED. If the page already carried a
            // number here, "a finished check puts one there" would pass for the wrong reason.
            for line in model.page(pushed: pushed).readings where line.value != nil {
                throw BrineStepError(
                    "\(line.label) already reads \(line.value ?? "") before anything asked the "
                        + "recorder anything — this scenario is not measuring the re-read")
            }

        case "a remembered recorder holding a recording Solleva has already taken into its keeping":
            try await stageRecorderAndPage()
            try await runCheck()
            conversationsBefore = notesInLibrary()
            check.bringOver(hardwareToken: identifier.uuidString,
                            advertisedName: Self.recorderName,
                            into: manager)
            try await AppScenarioHost.settle(
                untilTrue: { !self.check.isBringingOver && !self.check.isChecking },
                describing: "the transfer to finish")
            // THE CEILING OF THE SHIPPED SAFETY PREDICATE, written by the shipped writer: the
            // `.lore-confirmed` marker the retention sweep is built to preserve. Without it the
            // removal is refused for the right reason and this scenario would prove nothing.
            TranscriptCacheStore.save(
                CachedTranscript(transcript: "hello", title: nil, summary: nil, fetchedAt: 1),
                captureId: try requireCaptureID(), baseDir: library, markConfirmed: true)
            // A CHECK RE-TAKES THE STAGE SNAPSHOT, which is what lets the shelf state that the
            // recording is now safe elsewhere — and therefore what makes it removable at all.
            try await runCheck()
            freeSpaceBefore = try requireReading("Free space").value
            guard freeSpaceBefore != nil else {
                throw BrineStepError(
                    "the page carries no free-space figure before the removal, so \"it shows "
                        + "more afterwards\" would be a comparison against nothing")
            }

        case "a recorder page that has re-read what a check wrote":
            try await stageRecorderAndPage()
            try await runCheck()
            guard try requireReading("Battery").value != nil else {
                throw BrineStepError("the page never re-read the check's numbers, so there is "
                                        + "no re-read for this scenario to be about")
            }

        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    // MARK: When

    func when(_ phrase: String) async throws {
        switch phrase {
        case "I ask that recorder what it is holding":
            try await runCheck()

        case "that recording is removed from the recorder":
            try await errand(describing: "the removal") {
                // THE PAGE'S OWN CALL, with the page's own arguments — the gesture behind the
                // destructive button, not a kit function invoked directly.
                check.removeFromRecorder(id: "\(Self.day)/\(Self.timestamp)",
                                         hardwareToken: identifier.uuidString,
                                         advertisedName: Self.recorderName)
                try await AppScenarioHost.settle(untilTrue: { !self.check.isRemoving },
                                                 describing: "the removal to finish")
                guard !stack.shelf.contains(where: { $0.timestamp == Self.timestamp }) else {
                    throw BrineStepError(
                        "the recorder still holds the recording, so nothing freed any room and "
                            + "this scenario cannot be about a figure that changed. The app "
                            + "said: " + (check.removalMessage ?? "(nothing)"))
                }
            }

        case "the list behind that page pushes a newer reading":
            // THE LATCH, EXERCISED EXACTLY AS THE LIST PRODUCES IT: a value composed later,
            // carrying a reading heard AFTER everything the page's own re-read found.
            let newest = (model.live(pushed: pushed).readings.values.map(\.observedAt).max()
                            ?? Date())
            pushed = pushed.withReadings([
                RecordingDeviceCapabilityKey.batteryLevel.rawValue:
                    RecordingDeviceReading(value: "41%",
                                           observedAt: newest.addingTimeInterval(60)),
            ])

        case "this account's record of that recorder can no longer be read":
            guard let store = RecordingDeviceStore.current() else {
                throw BrineStepError("no account scope, so there is no record to damage")
            }
            // NOT DELETED — DAMAGED. An absent file is "no devices", which `readLocked()`
            // answers with an empty list on purpose; a file that is there and will not decode
            // is the condition that throws, and it is the one the page used to swallow.
            damagedStore = (store.fileURL, try? Data(contentsOf: store.fileURL))
            try Data("{ not json".utf8).write(to: store.fileURL, options: .atomic)
            // AND THEN AN ERRAND ENDS, which is the only thing that ever asks. This one cannot
            // reach the recorder, so nothing writes a reading — the page's numbers are exactly
            // the ones it already had, and the only thing that can change is what it says
            // about how well it knows them.
            stack.reachability.refusesToConnect = true
            try await runCheck()
            // AND PUT IT BACK IMMEDIATELY, inside the step that broke it.
            //
            // THIS IS NOT TIDINESS, IT IS THE ONLY SAFE WINDOW. `RecordingDeviceStore` is
            // account-scoped state on the simulator's own disk, shared by every suite in this
            // bundle AND SURVIVING THE PROCESS: the first run that left it corrupt took
            // `RecorderPageBringOverFeatureTests` down with it, and the run after that failed
            // before it started, because the damaged file was still sitting in the app
            // container. The page has already taken its answer by now — `runCheck` waits for
            // the re-read to land — so every claim below reads a model whose outcome is
            // `.storeUnreadable` over a store that is whole again.
            putBackWhatTheseScenariosBroke()

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    // MARK: Then

    func then(_ phrase: String) async throws {
        switch phrase {
        case "that page shows the charge and the firmware the recorder just answered":
            // THE PUSHED VALUE IS STILL BLANK, stated at the moment of the claim, so this can
            // only pass because the page re-read what the check wrote.
            for line in RecordingDevicePage.resolve(pushed).readings where line.value != nil {
                throw BrineStepError(
                    "the value the list pushed already carries \(line.label) — this scenario "
                        + "is no longer measuring the re-read")
            }
            guard try requireReading("Battery").value == "72%" else {
                throw BrineStepError(
                    "the page shows battery \(try requireReading("Battery").value ?? "nothing") "
                        + "one moment after a session measured 72% and wrote it to this "
                        + "phone's disk. The number is on the disk and the page never read it")
            }
            guard try requireReading("Firmware").value == "1.6" else {
                throw BrineStepError(
                    "the page shows firmware "
                        + "\(try requireReading("Firmware").value ?? "nothing"), not what the "
                        + "recorder answered")
            }
            guard try requireReading("Battery").observedAgo != nil else {
                throw BrineStepError("the page states a number with no statement of when it "
                                        + "was read")
            }

        case "no fact on that page still offers to go and ask":
            let readings = model.page(pushed: pushed).readings
            guard !readings.isEmpty else {
                throw BrineStepError("the page renders no readings, so this prohibition is "
                                        + "vacuous")
            }
            for line in readings where line.action != nil {
                throw BrineStepError("\(line.label) still offers \"\(line.action ?? "")\" over "
                                        + "a fact this session just measured")
            }

        case "that page shows more free space than it showed before the removal":
            let now = try requireReading("Free space").value
            guard let before = freeSpaceBefore, let now else {
                throw BrineStepError("the page has no free-space figure to compare")
            }
            guard now != before else {
                throw BrineStepError(
                    "the page still says free space is \(before) after a removal that freed "
                        + "room on the recorder and wrote the new figure to this account's "
                        + "store. The one number a person watches while they clear space is "
                        + "the one number that did not move")
            }
            guard try megabytesFree(now) > megabytesFree(before) else {
                throw BrineStepError("free space went from \(before) to \(now) across a "
                                        + "removal — the wrong way")
            }

        case "that page shows the newer reading":
            guard try requireReading("Battery").value == "41%" else {
                throw BrineStepError(
                    "the page shows battery \(try requireReading("Battery").value ?? "nothing") "
                        + "while the list has pushed a reading heard a minute later. The "
                        + "page's own re-read has latched and every value the list pushes is "
                        + "discarded for the life of the screen")
            }

        case "that page says it could not read what this account has saved for that recorder":
            guard let note = model.page(pushed: pushed).factsNote else {
                throw BrineStepError(
                    "this account's device file cannot be decoded, the page went and found "
                        + "that out, and it says nothing about it — it renders the numbers it "
                        + "already had under \"read N minutes ago\", which is a claim to have "
                        + "just checked them")
            }
            guard note == RecordingDevicePageFacts.factsUnreadableNote else {
                throw BrineStepError("the page says \"\(note)\", which is not the sentence the "
                                        + "kit owns for this")
            }

        case "that page still shows the last numbers the recorder gave":
            // THE OTHER HALF, AND THE REASON THE NOTE IS A NOTE. Blanking the strip would be a
            // page throwing away the only true thing it has because it failed to confirm it.
            guard try requireReading("Battery").value == "72%" else {
                throw BrineStepError(
                    "the page dropped the battery the recorder actually stated because it "
                        + "could not re-read this account's file")
            }

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    // MARK: The shipped path, driven

    /// A recorder on the radio, remembered by the account, with the page's two models built
    /// over it the way `RecordingDevicePageView.init` builds them.
    private func stageRecorderAndPage() async throws {
        let audio = try Self.fixtureMP3()
        identifier = UUID()
        let made = FakePocketBLEStack(
            deviceId: identifier,
            deviceName: Self.recorderName,
            acceptedSecret: Self.secret,
            // A FILE BIG ENOUGH FOR THE PAGE'S OWN WORDS TO MOVE WHEN IT LEAVES.
            //
            // The free-space line reads "47.9 MB free of 59.6 MB" — one decimal of a megabyte,
            // so ~102 KB of resolution. The 3-second fixture is 12 KB, and a recorder freeing
            // 12 KB honestly prints the same sentence it printed before. Asserting the number
            // changed would then be asserting nothing, whatever the page did.
            //
            // THE LISTED SIZE AND THE TRANSFERRED BYTES DIVERGE BY DESIGN HERE, which is a
            // shape this fixture exists to model: real firmware answers `LIST&<day>` and
            // `U&<file>` from two different places and nothing on the wire makes them agree.
            // `announcedSizeBytes` is the true content length, so the transfer completes.
            inventory: [.init(date: Self.day, timestamp: Self.timestamp,
                              sizeBytes: 2_000_000, content: audio,
                              announcedSizeBytes: audio.count)])
        stacks.append(made)
        stack = made
        try await secrets.save(
            Self.secret,
            for: try PocketAuthenticatedIdentity(peripheralIdentifier: identifier.uuidString))
        // THE ADDRESS THE SHIPPED CHECK WRITES UNDER: `PocketAuthenticatedIdentity` lowercases
        // the peripheral identifier, so a record kept under the uppercase form `UUID.uuidString`
        // prints is a different device and every write lands nowhere.
        identity = RecordingDeviceIdentity(shape: .filePull,
                                           hardwareToken: identifier.uuidString.lowercased())
        RecordingDeviceStore.recordUserPair(identity: identity, displayName: Self.recorderName)
        guard let store = RecordingDeviceStore.current() else {
            throw BrineStepError("no account scope, so the recorder has nowhere to be "
                                    + "remembered")
        }
        // STATED, NOT ASSUMED: the armed sweep must not run at the tail of these checks, or the
        // removal scenario's When would not be the only thing that removed anything.
        try store.disarmAutoClear(identity)

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

        // THE PAGE, COMPOSED THE WAY THE APP COMPOSES IT: off the account's store, through the
        // unified projection, into the value a `NavigationLink` would carry.
        let inputs = UnifiedDeviceListComposition.inputs(
            remembered: try store.records(), captureSources: [])
        guard let input = inputs.first(where: { $0.identity == identity }) else {
            throw BrineStepError("the projection dropped the recorder the account remembers")
        }
        pushed = input
        check = PocketRecorderCheckModel()
        model = RecorderPageModel(check: check, identity: identity, isSavedOmi: false)
    }

    /// The page's own call, with the page's own arguments.
    private func runCheck() async throws {
        try await errand(describing: "the check") {
            check.run(hardwareToken: identifier.uuidString, advertisedName: Self.recorderName,
                      library: manager.captureLibraryRoot, stages: manager.captureStages(),
                      brain: .myComputer)
            try await AppScenarioHost.settle(
                untilTrue: { !self.check.isChecking && !self.check.isRemoving },
                describing: "the check to finish")
        }
    }

    /// RUN AN ERRAND AND WAIT FOR THE RE-READ IT CAUSED, and never for the assertion itself.
    ///
    /// THE COUNT IS SAMPLED BEFORE THE ERRAND STARTS, and getting that wrong is what made this
    /// suite's first run report three timeouts against a working fix. The re-read's disk read
    /// is detached, so it can land either side of the errand flag dropping; sampling after the
    /// errand had already settled meant that whenever it landed EARLY the wait could never be
    /// satisfied — and whenever it landed late the wait passed. A flaky instrument that agrees
    /// with you half the time is worse than one that never runs.
    ///
    /// IT WAITS ON THE COUNT, NOT ON THE CLAIM. A settle that waited for the assertion to
    /// become true would be an assertion that cannot fail, only time out.
    private func errand(describing what: String,
                        _ body: () async throws -> Void) async throws {
        let before = model.factsGeneration
        try await body()
        try await AppScenarioHost.settle(
            untilTrue: { self.model.factsGeneration > before },
            describing: "the page to re-read what \(what) changed")
    }

    private func requireReading(_ label: String) throws -> RecordingDeviceReadingLine {
        let page = model.page(pushed: pushed)
        guard let line = page.readings.first(where: { $0.label == label }) else {
            throw BrineStepError("the page renders no \"\(label)\" reading at all — it renders "
                                    + "\(page.readings.map(\.label))")
        }
        return line
    }

    /// "47.9 MB free of 59.6 MB" → 47.9. The page's own words, read back as a number, so the
    /// comparison is over what the owner sees rather than over a field behind it.
    private func megabytesFree(_ sentence: String) throws -> Double {
        guard let first = sentence.split(separator: " ").first,
              let value = Double(first) else {
            throw BrineStepError("the free-space line reads \"\(sentence)\", which states no "
                                    + "number this scenario can compare")
        }
        return value
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
