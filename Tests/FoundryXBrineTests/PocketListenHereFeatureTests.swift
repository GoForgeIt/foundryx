import XCTest
import Foundation
import AVFoundation
import BrineSwiftCore
@testable import FoundryXKit

/// Drives `features/a-recording-from-a-recorder-plays-here.feature` against REAL seams:
///
///  • `PocketRecorderFileStore` — the SHIPPED custody, holding the SHIPPED MP3 fixture
///    (`fixtures/pocket/pocket-fw16-3s.mp3`, real MPEG-2 Layer III at the recorder's own
///    32 kbps / 16 kHz), with the SHIPPED `noteConversation` receipt. Nothing about "this
///    phone is holding it" is faked; the bytes are on the disk this test owns.
///  • `PocketLocalPlayback.source(forCapture:pocketRoot:)` — the one decision about where
///    playback goes, which the app's Listen tap now consults before anything else.
///  • `AVAudioPlayer` over the held file — "plays" means a real decoder produced a real
///    duration from real recorder-shaped audio, not that a boolean was set.
///  • `DoorClient.captureAudio` over a URLProtocol stub that COUNTS requests and refuses
///    every one of them. "Never asked the computer" is a count of zero taken from the same
///    instrument that reads one or more in the two scenarios where the door IS the answer —
///    so the zero cannot come from a stub that was never armed.
///  • `PocketCaptureDurability` + `PocketDurability.durableElsewhere` — Step 5's predicate,
///    read rather than recomputed.
///  • `AccountSurfaceRegistry.eraseAll` — the SHIPPED account deletion, over a real
///    directory tree, so "the recordings go with the account" is pinned rather than assumed
///    from the fact that `pocket-recordings` happens to live under `binding.root`.
final class PocketListenHereFeatureTests: XCTestCase {

    func testARecordingFromARecorderPlaysHereFeature() async throws {
        let world = ListenHereWorld()
        defer { world.tearDown() }
        let registry = StepRegistry(ListenHereSteps.make(world: world))

        let parsed = parseFeatureText(try Self.featureText())
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry,
                                             resources: [], collector: { collected.append($0) })
        var failures: [String] = []
        for ev in collected {
            guard case .object(let o) = ev,
                  case .string("scenario_end")? = o["type"],
                  case .string(let status)? = o["status"], status != "passed" else { continue }
            let nm: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(nm): \(err)")
        }
        XCTAssertTrue(failures.isEmpty,
                      "a-recording-from-a-recorder-plays-here scenarios failed:\n"
                      + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
        XCTAssertEqual(result.passed, parsed.features[0].scenarios.count,
                       "all scenarios should pass")
    }

    private static func featureText() throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return try String(
            contentsOf: root.appendingPathComponent(
                "features/a-recording-from-a-recorder-plays-here.feature"))
    }
}

/// A URLProtocol stub scoped to THIS test that COUNTS every request and refuses all of them.
/// The count is the instrument "Solleva never asked the computer for it" is read from, and
/// the refusal is what makes the local path's success meaningful: if playback reached the
/// door at all, there are no bytes anywhere for it to play.
final class ListenHereStubProtocol: URLProtocol {
    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests = 0
    static var requests: Int { lock.withLock { _requests } }
    static func reset() { lock.withLock { _requests = 0 } }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { _requests += 1 }
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
    override func stopLoading() {}
}

private final class ListenHereWorld: @unchecked Sendable {

    /// REAL MPEG-2 LAYER III AT THE RECORDER'S OWN BITRATE — see
    /// `fixtures/pocket/POCKET-AUDIO-PROVENANCE.txt`. 3.096 s, 12,384 bytes.
    private static func fixtureMP3() -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/pocket/pocket-fw16-3s.mp3")
        return (try? Data(contentsOf: url)) ?? Data()
    }
    private static let fixtureSeconds = 3.096

    private let token = UUID().uuidString.lowercased()
    private lazy var sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("foundryx-listen-here-\(token)", isDirectory: true)
    /// The ACCOUNT ROOT. `pocket-recordings` sits under it exactly as
    /// `CaptureAccountScope.privateURL(for:)` puts it under `currentRoot()`.
    private lazy var accountRoot = sandbox.appendingPathComponent("acct-0000000000000009",
                                                                  isDirectory: true)
    private lazy var pocketRoot = accountRoot.appendingPathComponent("pocket-recordings",
                                                                     isDirectory: true)
    /// The capture library — the directory a `CaptureManager` hydrates from.
    private lazy var libraryRoot = accountRoot.appendingPathComponent("captures", isDirectory: true)

    private let identity = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "PKT01-LISTEN")
    private let now = Date(timeIntervalSince1970: 1_776_000_000)

    // What a scenario set up.
    private var captureID = ""
    private var custody: PocketRecorderFileStore?
    private var durability: PocketCaptureDurability?

    // What the Listen tap produced.
    private var source: ConversationAudioSource?
    private var playedSeconds: Double?
    private var outcome: AudioPlaybackPresentation.Outcome?
    private var presentedText: String?

    // What the row rendered.
    private var presence: PocketRecordingPresence?

    // What deletion left behind.
    private var pocketRootSurvivedDeletion: Bool?

    func tearDown() { try? FileManager.default.removeItem(at: sandbox) }

    private func reset() {
        try? FileManager.default.removeItem(at: sandbox)
        try? FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: pocketRoot, withIntermediateDirectories: true)
        ListenHereStubProtocol.reset()
        captureID = ""; custody = PocketRecorderFileStore(root: pocketRoot); durability = nil
        source = nil; playedSeconds = nil; outcome = nil; presentedText = nil
        presence = nil; pocketRootSurvivedDeletion = nil
    }

    /// Put a recording into custody the way the bring-over does: stream the bytes through the
    /// shipped writer, commit (which re-reads them), then write the shipped receipt.
    @discardableResult
    private func hold(timestamp: String, captureID id: String, bytes: Data) async throws -> URL {
        let store = try XCTUnwrap(custody)
        let key = PocketRecorderFileKey(identity: identity, date: "2026-08-14", timestamp: timestamp)
        let writer = try await store.beginKeeping(key)
        try writer.write(bytes)
        _ = try writer.commit()
        await store.noteConversation(id, for: key)
        return store.url(for: key)
    }

    // MARK: - Given

    func given(_ phrase: String) async throws {
        reset()
        switch phrase {
        case "a recording brought off a recorder, whose original file is on this iPhone":
            captureID = PocketCaptureImport.captureId(startedAt: 1_775_000_000,
                                                      uniqueSuffix: "aaaabbbb")
            try await hold(timestamp: "20260814090000", captureID: captureID,
                           bytes: Self.fixtureMP3())

        case "a recording brought off a recorder, whose original file is on this iPhone, "
            + "confirmed in the person's library":
            captureID = PocketCaptureImport.captureId(startedAt: 1_775_000_000,
                                                      uniqueSuffix: "ccccdddd")
            try await hold(timestamp: "20260814091500", captureID: captureID,
                           bytes: Self.fixtureMP3())
            // The door path's own write: the cached transcript AND the `.lore-confirmed`
            // marker the retention sweep is written to preserve. This is Step 5's CEILING.
            TranscriptCacheStore.save(
                CachedTranscript(transcript: "hello", title: nil, summary: nil, fetchedAt: 1),
                captureId: captureID, baseDir: libraryRoot, markConfirmed: true)
            durability = PocketCaptureDurability(baseDir: libraryRoot, stages: [:])

        case "a recording brought off a recorder, whose original file is on this iPhone but "
            + "cannot be played":
            captureID = PocketCaptureImport.captureId(startedAt: 1_775_000_000,
                                                      uniqueSuffix: "eeeeffff")
            // Custody holds it and proved the bytes round-tripped — custody never claimed they
            // were AUDIO. This is the file that must not be blamed on the computer.
            try await hold(timestamp: "20260814093000", captureID: captureID,
                           bytes: Data(repeating: 0x41, count: 4_096))

        case "a conversation this phone recorded with its own microphone":
            captureID = "cap-20260814-101010-micmicmi"

        case "a recording that came off a recorder, whose original file this phone is not holding":
            // A pulled capture id with NOTHING in custody: the prefix alone is never evidence.
            captureID = PocketCaptureImport.captureId(startedAt: 1_775_000_000,
                                                      uniqueSuffix: "99998888")

        case "the computer that holds the other recordings can't be reached":
            // The stub refuses every request already; this Given names the state the scenario
            // is about rather than changing it, and must not reset the recording just seeded.
            break

        default:
            throw BrineStepError("Unhandled given: \(phrase)")
        }
    }

    /// The `And` line above arrives as its own step AFTER a Given that seeded state, so it must
    /// not call `reset()`. Routed separately for exactly that reason.
    func andGiven(_ phrase: String) async throws {
        switch phrase {
        case "the computer that holds the other recordings can't be reached":
            break
        default:
            throw BrineStepError("Unhandled and-given: \(phrase)")
        }
    }

    // MARK: - When

    func when(_ phrase: String) async throws {
        switch phrase {
        case "I tap Listen on that recording":
            await tapListen()

        case "the account's data is deleted":
            try deleteAccount()

        default:
            throw BrineStepError("Unhandled when: \(phrase)")
        }
    }

    /// THE SHIPPED LISTEN TAP. The decision is `PocketLocalPlayback.source`; the local branch
    /// plays through the shipped `player(forHeldFile:)`; the computer branch is the existing
    /// `DoorClient.captureAudio` call, unchanged. There is no third branch, which is what makes
    /// "never asked the computer" a property of the switch rather than of this test.
    private func tapListen() async {
        let decided = PocketLocalPlayback.source(forCapture: captureID, pocketRoot: pocketRoot)
        source = decided
        switch decided {
        case .heldOnThisPhone(let url):
            if let player = PocketLocalPlayback.player(forHeldFile: url) {
                playedSeconds = player.duration
            } else {
                setOutcome(.heldButUnreadable)
            }
        case .onTheComputer:
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [ListenHereStubProtocol.self]
            let client = DoorClient(
                target: DoorTarget(baseURL: URL(string: "http://door.test")!, bearer: "tok"),
                session: URLSession(configuration: cfg))
            do {
                if let bytes = try await client.captureAudio(captureId: captureID), !bytes.isEmpty {
                    playedSeconds = 0
                } else {
                    setOutcome(.unavailable)
                }
            } catch {
                setOutcome(AudioPlaybackPresentation.failurePresentation(for: error))
            }
        }
    }

    private func setOutcome(_ o: AudioPlaybackPresentation.Outcome) {
        outcome = o
        let copy = AudioPlaybackPresentation.copy(for: o)
        presentedText = [copy.title, copy.subtitle].compactMap { $0 }.joined(separator: " — ")
    }

    /// THE SHIPPED ACCOUNT DELETION, over a real tree.
    private func deleteAccount() throws {
        let name = "foundryx.listen-here.\(token)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        CaptureWidgetSnapshotStore.setDefaultsForTesting(defaults)
        AuthStore.setIdentityEraseForTests { .alreadyClean }
        AccountLiveActivityBoundary.endAllForTests = { .alreadyClean }
        defer {
            AccountLiveActivityBoundary.endAllForTests = nil
            AuthStore.setIdentityEraseForTests(nil)
            CaptureWidgetSnapshotStore.resetDefaultsForTesting()
            defaults.removePersistentDomain(forName: name)
        }
        let binding = CaptureAccountScope.AccountBinding(
            root: accountRoot, scope: "acct-0000000000000009", generation: 1)
        _ = AccountSurfaceRegistry.eraseAll(binding, defaults: defaults)
        pocketRootSurvivedDeletion = FileManager.default.fileExists(atPath: pocketRoot.path)
    }

    // MARK: - Then

    func then(_ phrase: String) async throws {
        switch phrase {
        case "the recording plays":
            guard let seconds = playedSeconds else {
                throw BrineStepError("nothing played; outcome=\(String(describing: outcome)) "
                                     + "source=\(String(describing: source))")
            }
            guard abs(seconds - Self.fixtureSeconds) < 0.2 else {
                throw BrineStepError("played \(seconds)s, expected the fixture's "
                                     + "\(Self.fixtureSeconds)s of real audio")
            }

        case "Solleva never asked the computer for it":
            guard ListenHereStubProtocol.requests == 0 else {
                throw BrineStepError("the computer was asked \(ListenHereStubProtocol.requests) "
                                     + "time(s) for a recording that is on this iPhone")
            }

        case "Solleva asks the computer for it":
            guard source == .onTheComputer else {
                throw BrineStepError("expected the computer, got \(String(describing: source))")
            }
            guard ListenHereStubProtocol.requests > 0 else {
                throw BrineStepError("the computer was never asked — the request counter this "
                                     + "feature reads its zeroes from does not move at all")
            }

        case "the row says the recording is on this iPhone":
            try requirePlace(PocketPresencePresentation.onThisPhonePlace,
                             reads: PocketPresencePresentation.yesAnswer)

        case "the row says the recording is safe elsewhere":
            try requirePlace(PocketPresencePresentation.safeElsewherePlace,
                             reads: PocketPresencePresentation.yesAnswer)
            guard try requirePresence().isDurableElsewhere else {
                throw BrineStepError("the row said safe but the predicate says otherwise")
            }

        case "the row does not claim to know whether the recording is still on the recorder":
            try requirePlace(PocketPresencePresentation.onRecorderPlace,
                             reads: PocketPresencePresentation.unknownAnswer)

        case "the age of a place nobody asked about is shown as never checked":
            let line = try requireLine(PocketPresencePresentation.onRecorderPlace)
            guard line.age == PocketPresencePresentation.neverCheckedAge else {
                throw BrineStepError("an unasked place aged '\(line.age)', not "
                                     + "'\(PocketPresencePresentation.neverCheckedAge)'")
            }

        case "Solleva says it could not play the recording that is on this iPhone":
            guard outcome == .heldButUnreadable else {
                throw BrineStepError("expected .heldButUnreadable, got "
                                     + "\(String(describing: outcome))")
            }
            let copy = AudioPlaybackPresentation.copy(for: .heldButUnreadable)
            guard let shown = presentedText,
                  shown == [copy.title, copy.subtitle].compactMap({ $0 }).joined(separator: " — ")
            else { throw BrineStepError("the row did not render the held-file copy") }
            guard (copy.subtitle ?? "").contains("this iPhone") else {
                throw BrineStepError("the held-file copy does not say where the file is")
            }

        case "it does not say the computer can't be reached":
            let shown = try XCTUnwrap(presentedText)
            // OVER THE POPULATION, not over one remembered string: the held-file copy must
            // share no line with any copy that talks about the computer.
            let computerLines = [AudioPlaybackPresentation.Outcome.unreachable, .unavailable]
                .flatMap { o -> [String] in
                    let c = AudioPlaybackPresentation.copy(for: o)
                    return [c.title, c.subtitle].compactMap { $0 }
                }
            for line in computerLines where shown.contains(line) {
                throw BrineStepError("a file on this iPhone was reported with the computer's "
                                     + "line: '\(line)'")
            }
            guard Set(AudioPlaybackPresentation.everyLine).count
                    == AudioPlaybackPresentation.everyLine.count else {
                throw BrineStepError("two playback outcomes render the same line, so 'distinct "
                                     + "from the computer's sentence' cannot mean anything")
            }

        case "the row says Solleva keeps the original here and cannot free that space yet":
            guard case .heldOnThisPhone = PocketLocalPlayback.source(forCapture: captureID,
                                                                    pocketRoot: pocketRoot) else {
                throw BrineStepError("this scenario's recording is not held here at all")
            }
            let line = PocketLocalCopyPresentation.keptHereLine
            guard line.contains("this iPhone"), line.lowercased().contains("free") else {
                throw BrineStepError("the kept-here line does not name what is kept or that "
                                     + "the space cannot be freed: '\(line)'")
            }

        case "no recording brought off a recorder is left on this iPhone":
            guard let survived = pocketRootSurvivedDeletion else {
                throw BrineStepError("the account was never deleted")
            }
            guard !survived else {
                throw BrineStepError("pocket-recordings survived account deletion at "
                                     + pocketRoot.path)
            }

        default:
            throw BrineStepError("Unhandled then: \(phrase)")
        }
    }

    // MARK: - The row

    /// Resolved LAZILY at assertion time from the same seams the app uses, so a scenario that
    /// only reads the row does not have to tap anything first.
    private func requirePresence() throws -> PocketRecordingPresence {
        if let presence { return presence }
        let held = PocketLocalPlayback.heldFile(forCapture: captureID, in: pocketRoot)
        let resolved = PocketLocalPlayback.presence(forCapture: captureID,
                                                    heldFile: held,
                                                    recorderListedAt: nil,
                                                    durability: durability,
                                                    askedAt: now)
        presence = resolved
        return resolved
    }

    private func requireLine(_ place: String) throws -> PocketPlaceLine {
        let lines = PocketPresencePresentation.lines(try requirePresence(), now: now)
        guard let line = lines.first(where: { $0.place == place }) else {
            throw BrineStepError("the row has no line for '\(place)'")
        }
        return line
    }

    private func requirePlace(_ place: String, reads expected: String) throws {
        let line = try requireLine(place)
        guard line.answer == expected else {
            throw BrineStepError("'\(place)' reads '\(line.answer)', expected '\(expected)'")
        }
    }
}

private enum ListenHereSteps {
    static func make(world: ListenHereWorld) -> [StepDefinition] {
        let givens = [
            "a recording brought off a recorder, whose original file is on this iPhone",
            "a recording brought off a recorder, whose original file is on this iPhone, "
                + "confirmed in the person's library",
            "a recording brought off a recorder, whose original file is on this iPhone but "
                + "cannot be played",
            "a conversation this phone recorded with its own microphone",
            "a recording that came off a recorder, whose original file this phone is not holding",
        ]
        let andGivens = [
            "the computer that holds the other recordings can't be reached",
        ]
        let whens = [
            "I tap Listen on that recording",
            "the account's data is deleted",
        ]
        let thens = [
            "the recording plays",
            "Solleva never asked the computer for it",
            "Solleva asks the computer for it",
            "the row says the recording is on this iPhone",
            "the row says the recording is safe elsewhere",
            "the row does not claim to know whether the recording is still on the recorder",
            "the age of a place nobody asked about is shown as never checked",
            "Solleva says it could not play the recording that is on this iPhone",
            "it does not say the computer can't be reached",
            "the row says Solleva keeps the original here and cannot free that space yet",
            "no recording brought off a recorder is left on this iPhone",
        ]
        var steps = givens.map { phrase in
            defineStep(phrase) { context, _, _ in try await world.given(phrase); return context }
        }
        steps += andGivens.map { phrase in
            defineStep(phrase) { context, _, _ in try await world.andGiven(phrase); return context }
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
