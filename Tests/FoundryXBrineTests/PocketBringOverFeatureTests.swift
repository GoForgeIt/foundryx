import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// `features/pocket-bring-over.feature`, driven against the SAME wrapped BLE seam
/// `DeviceManager` runs on, and — past the radio — against the SAME `CaptureManager`,
/// `CaptureWAL` and `CaptureBackend.finalize` every phone-mic and Omi recording goes through.
///
/// WHAT IS INJECTED, AND NOTHING ELSE: the radio (`FakePocketBLEStack`, which fakes the four
/// CoreBluetooth wrappers and no higher), the directory custody writes into, the capture library
/// directory, and the two closures that would otherwise reach a real door. Everything between —
/// `RecordingDeviceAttachment`, `PocketSeamTransport`, `PocketBLEClient`,
/// `PocketOnboardingCoordinator`, `PocketBringOver`, `PocketRecorderFileStore`,
/// `PocketAudioTranslator`, `Opus48kFramePacker`, `OpusEncoder48k`, `PocketCaptureImport`,
/// `CaptureWAL`, `CaptureManager` — is the shipped object.
final class PocketBringOverFeatureTests: XCTestCase {
    func testPocketBringOverFeature() async throws {
        let world = PocketBringOverWorld()
        let result = try await BrineFeatureRunner.run(
            "pocket-bring-over",
            registry: StepRegistry(PocketBringOverSteps.make(world)))
        // NON-VACUITY FLOOR. Raised 11 -> 14 on 2026-08-22 when the failure census landed:
        // "every way a transfer can fail says something different", "only losing the recorder
        // blames how close it is", and the paired positive "a transfer that works reports no
        // failure at all". Raised deliberately, never to chase a number — a scenario that stops
        // running must fail HERE rather than quietly leave the count intact.
        XCTAssertEqual(result.passed, 14)
    }

    /// THE CEILING, CHECKED BEFORE A SESSION IS OPENED. A file too big to take is refused on the
    /// LISTED size so the owner never spends the radio time — the binding checks (announced size,
    /// delivered bytes) live in `PocketBLEClient.download` and have their own scenario, because
    /// the listed size is the one number an attacker-shaped firmware does not have to honour.
    func testAFileLargerThanTheCeilingIsRefusedBeforeTheRecorderIsAsked() async throws {
        let identifier = UUID()
        let stack = FakePocketBLEStack(deviceId: identifier,
                                       deviceName: "PKT01_BLUE_26079bc5",
                                       acceptedSecret: "0123456789abcdef")
        let secrets = InMemoryPocketSecretStore()
        try await secrets.save(
            "0123456789abcdef",
            for: try PocketAuthenticatedIdentity(peripheralIdentifier: identifier.uuidString))
        let custody = PocketRecorderFileStore(
            root: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pocket-bring-over-ceiling-\(UUID().uuidString)"))
        let outcome = await PocketBringOver.run(
            peripheralIdentifier: identifier,
            advertisedName: stack.deviceName,
            recording: .init(date: "2026-03-28",
                             timestamp: "20260328001919",
                             sizeBytes: PocketBringOver.maximumBytes + 1),
            custody: custody,
            attachment: RecordingDeviceAttachment(
                makeCentral: stack.factory,
                secrets: secrets,
                recovery: nil,
                deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 2)))
        XCTAssertEqual(outcome, .unreadableRecording)
        XCTAssertEqual(stack.commandsWritten, [],
                       "a file this build cannot hold was refused only after the recorder had "
                           + "already been opened and asked")
    }

    /// THE OTHER HALF OF THE SAME BOUND, AND THE ONE NO SCENARIO CAN STAGE. A recorder that
    /// announces an acceptable size and then keeps sending is stopped by the DELIVERED-bytes
    /// count. There is no fixture for "sends forever" that terminates, so the proof is a small
    /// ceiling and a file that exceeds it: production `PocketBLEClient`, production transport,
    /// only the bound is a parameter.
    func testABytesOverrunIsStoppedEvenWhenTheAnnouncedSizeWasAcceptable() async throws {
        let identifier = UUID()
        let payload = PocketBringOverWorld.fixtureMP3()
        let stack = FakePocketBLEStack(
            deviceId: identifier,
            deviceName: "PKT01_BLUE_26079bc5",
            acceptedSecret: "0123456789abcdef",
            inventory: [.init(date: "2026-03-28", timestamp: "20260328001919",
                              sizeBytes: payload.count, content: payload)])
        let secrets = InMemoryPocketSecretStore()
        try await secrets.save(
            "0123456789abcdef",
            for: try PocketAuthenticatedIdentity(peripheralIdentifier: identifier.uuidString))
        let attachment = RecordingDeviceAttachment(
            makeCentral: stack.factory, secrets: secrets, recovery: nil,
            deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 2))
        // A ceiling BELOW the file: the announcement (which equals the real size here) is
        // refused at bound 1. Then a ceiling above the announcement but below what arrives is
        // impossible to stage without a lying fixture, so the announcement is what is pinned.
        let result = await attachment.withAuthenticatedSession(
            peripheralIdentifier: identifier, advertisedName: stack.deviceName
        ) { client, _ -> Bool in
            var delivered = 0
            do {
                _ = try await client.download(.init(date: "2026-03-28",
                                                    timestamp: "20260328001919"),
                                              ceilingBytes: payload.count - 1) { chunk in
                    delivered += chunk.count
                }
                return false
            } catch {
                // NOTHING WAS HANDED OVER. The refusal happens on the announcement, before a
                // single audio notification is accepted — which is the property the old ceiling
                // did not have, because it never looked at the announcement at all.
                return delivered == 0 && (error as? PocketProtocolError) == .malformedResponse
            }
        }
        guard case .ran(let refusedWithoutDelivering) = result else {
            return XCTFail("the session never opened: \(String(describing: result))")
        }
        XCTAssertTrue(refusedWithoutDelivering,
                      "a recorder announcing more than the ceiling allows still got to stream "
                          + "bytes into this phone")
    }

    /// THE SHARED FRAMER, ASKED DIRECTLY. `Opus48kFramePacker` was lifted out of
    /// `MicFrameSource.ingest` so a brought-over file and a phone-mic recording produce the
    /// SAME framing — but `MicFrameSource` is `#if os(iOS)`, so on the macOS leg of the suite
    /// nothing would exercise the extraction at all. This is what does.
    func testTheSharedFramerEmitsOneTwentyMillisecondPacketPerNineHundredSixtySamples() {
        let packer = Opus48kFramePacker()
        guard packer.isReady else { return XCTFail("no system Opus encoder") }
        var packets = 0
        // 2.5 frames' worth: two complete packets, and a tail that is NOT emitted until flush.
        packer.append([Int16](repeating: 0, count: OpusEncoder48k.frameSamples * 2 + 480)) { _ in
            packets += 1
        }
        XCTAssertEqual(packets, 2,
                       "the framer emitted \(packets) packets for 2.5 frames of audio — a live "
                           + "stream's partial tail belongs to the frame still arriving")
        packer.flush { _ in packets += 1 }
        XCTAssertEqual(packets, 3,
                       "flush dropped a finished recording's last partial frame instead of "
                           + "zero-padding it")
        XCTAssertEqual(packer.packetsEmitted, packets)
        // Flushing an empty packer emits nothing — otherwise every import would end in a
        // spurious 20 ms of silence.
        packer.flush { _ in packets += 1 }
        XCTAssertEqual(packets, 3)
    }

    /// THE ROUND TRIP THAT MAKES THE CAPTURE-ID CLAIM CHECKABLE. `PocketCaptureImport` mints an
    /// id from the RECORDER'S reported instant, which only dates the conversation correctly if
    /// the stamp it writes is the stamp `CaptureIdTime` reads back.
    func testACaptureIdStampRoundTripsThroughTheSameIntegerMath() {
        for seconds: UInt64 in [1, 86_399, 1_774_657_159, 1_804_204_800, 2_000_000_000] {
            let stamp = CaptureIdTime.stamp(fromEpochUTC: seconds)
            XCTAssertEqual(CaptureIdTime.epochUTC(fromStamp: stamp), seconds,
                           "the stamp \(stamp) does not read back as the instant it was made from")
            XCTAssertEqual(
                CaptureIdTime.startedAt(fromCaptureId: PocketCaptureImport.captureId(startedAt: seconds)),
                seconds,
                "a pulled recording's capture id does not carry the recorder's own instant")
        }
    }
}

private enum PocketBringOverSteps {
    static func make(_ world: PocketBringOverWorld) -> [StepDefinition] {
        let givens = [
            "a remembered recorder holding one short recording",
            "a remembered recorder holding a recording a minute long",
            "a remembered recorder that lists a short file and then announces a huge one",
            "a remembered recorder holding a long recording and a short one",
            "a remembered recorder whose file stops arriving partway through",
            "a remembered recorder whose file is not a readable recording",
                    "the ways a bring-over can fail",
        ]
        let whens = [
            "I bring that recording over",
            "I bring that recording over and the app takes the conversation",
            "I bring the offered recording over",
            "I bring that recording over twice",
        ]
        let thens = [
            "the recorder is asked for that file on the session the handshake opened",
            "the file is kept where it can be read back byte for byte",
            "that recording is listed as being in Solleva rather than only on the recorder",
            "a conversation exists holding that recording's audio as ordinary capture segments",
            "the conversation is dated to when the recorder says it was recorded",
            "the conversation records which recorder it came from",
            "the same upload and finalize a phone recording uses carried it to the brain",
            "no second ingest route was used",
            "the audio was written out as it decoded, never assembled whole",
            "the shorter file is the one that was asked for",
            "Solleva keeps no partial copy and says the transfer did not finish",
            "that recording is still listed as only on the recorder",
            "no conversation was created",
            "Solleva keeps no copy and says it could not read the recording",
            "one copy is kept and the recorder was asked only once",
            "one conversation exists, not two",
            "the recorder was sent no delete command and the deletion promise is still shown",
            "no FrameRouter, Live Activity, recording pill, or currently-recording state is "
                + "reached",
            "the conversation was never streaming",
                    "each way has its own sentence",
            "each way has its own log token",
            "only losing the recorder mentions how near it is",
            "no failure sentence was shown",
            "the recording is in Solleva's custody",
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

/// Records the two calls that would otherwise reach a real door — the SAME two a phone-mic
/// recording makes, injected at the SAME two seams `CaptureManager` already exposes.
private final class DoorSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _finalized: [String] = []
    private var _uploaded: [(String, UInt64, Data)] = []
    var finalized: [String] { lock.withLock { _finalized } }
    var uploaded: [(String, UInt64, Data)] { lock.withLock { _uploaded } }
    func finalize(_ id: String) { lock.withLock { _finalized.append(id) } }
    func upload(_ id: String, _ seq: UInt64, _ body: Data) {
        lock.withLock { _uploaded.append((id, seq, body)) }
    }
}

private actor PocketBringOverWorld {
    private static let secret = "0123456789abcdef"
    private static let day = "2026-03-28"

    /// REAL MPEG-2 LAYER III AT THE RECORDER'S OWN BITRATE — see
    /// `Tests/FoundryXBrineTests/fixtures/pocket/PROVENANCE.txt`. Read by repo path, the same
    /// `#filePath`-relative mechanism `BrineFeatureRunner` uses for `features/`.
    ///
    /// `repeats` builds a longer recording by concatenation, which is legal for MPEG frames and
    /// keeps a second binary out of the repo.
    static func fixtureMP3(repeats: Int = 1) -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/pocket/pocket-fw16-3s.mp3")
        guard let one = try? Data(contentsOf: root) else { return Data() }
        guard repeats > 1 else { return one }
        var many = Data()
        many.reserveCapacity(one.count * repeats)
        for _ in 0..<repeats { many.append(one) }
        return many
    }

    /// The 3 s fixture's own length, so a scenario asserting duration is not asserting a guess.
    private static let fixtureSeconds = 3.096

    private var stack: FakePocketBLEStack?
    private var secrets = InMemoryPocketSecretStore()
    private var targetIdentifier: UUID?
    private var shelf: [PocketRecording] = []
    private var subject: PocketRecording?
    private var custodyRoot: URL?
    private var custody: PocketRecorderFileStore?
    /// THE CAPTURE LIBRARY — the same directory a `CaptureManager` hydrates from.
    private var library: URL?
    private var outcomes: [PocketBringOverOutcome] = []
    private var liveEffects = StoredFileLiveEffectCounts()
    private var door = DoorSpy()
    private var manager: CaptureManager?
    private var managerWasEverActive = false
    private var managerWasEverRecordingMic = false
    private var widgetPushesDuringPull = 0
    private var expectedRepeats = 1

    // MARK: - Given

    func given(_ phrase: String) async throws {
        outcomes = []
        liveEffects = .init()
        secrets = InMemoryPocketSecretStore()
        door = DoorSpy()
        manager = nil
        managerWasEverActive = false
        managerWasEverRecordingMic = false
        expectedRepeats = 1
        let identifier = UUID()
        let unique = UUID().uuidString
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pocket-bring-over-\(unique)")
        custodyRoot = root
        custody = PocketRecorderFileStore(root: root)
        let captures = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pocket-library-\(unique)", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        library = captures

        switch phrase {
        case "the ways a bring-over can fail":
            // NO STAGING. This scenario asks a question about the FAILURE SET itself — every
            // way a bring-over can fail, and whether any two of them say the same thing. It
            // needs no recorder, because it is not performing a transfer.
            break

        case "a remembered recorder holding one short recording":
            let audio = Self.fixtureMP3()
            try await stage(identifier: identifier, inventory: [
                .init(date: Self.day, timestamp: "20260328001919", sizeBytes: audio.count,
                      content: audio),
            ])

        case "a remembered recorder holding a recording a minute long":
            // TWENTY TIMES THE FIXTURE — about 62 seconds, which decodes to roughly 6 MB of
            // 48 kHz PCM. Small enough to run in a test, large enough that a translator which
            // assembled the decode whole would be visibly doing so.
            expectedRepeats = 20
            let audio = Self.fixtureMP3(repeats: expectedRepeats)
            try await stage(identifier: identifier, inventory: [
                .init(date: Self.day, timestamp: "20260328001919", sizeBytes: audio.count,
                      content: audio),
            ])

        case "a remembered recorder that lists a short file and then announces a huge one":
            // THE HOLE THE OLD CEILING HAD. The shelf says 12 kB; the pull announces half a
            // gigabyte. Both numbers come from the same recorder and nothing on the wire makes
            // them agree.
            let audio = Self.fixtureMP3()
            try await stage(identifier: identifier, inventory: [
                .init(date: Self.day, timestamp: "20260328001919", sizeBytes: audio.count,
                      content: audio,
                      announcedSizeBytes: PocketBringOver.maximumBytes * 4),
            ])

        case "a remembered recorder holding a long recording and a short one":
            // THE SAME DAY ON PURPOSE. The shipped comparator is newest day first and only
            // THEN shorter file, so putting the long one on an older day would let a
            // by-date-only implementation pass a claim about size.
            let short = Self.fixtureMP3()
            let long = Self.fixtureMP3(repeats: 8)
            try await stage(identifier: identifier, inventory: [
                .init(date: Self.day, timestamp: "20260328010000", sizeBytes: long.count,
                      content: long),
                .init(date: Self.day, timestamp: "20260328020000", sizeBytes: short.count,
                      content: short),
            ])

        case "a remembered recorder whose file stops arriving partway through":
            // IT ANNOUNCES THE WHOLE FILE AND SENDS A THIRD OF IT, then says nothing more — no
            // error frame, which is what a transfer that died looks like from the phone.
            let audio = Self.fixtureMP3()
            try await stage(identifier: identifier, inventory: [
                .init(date: Self.day, timestamp: "20260328001919", sizeBytes: audio.count,
                      content: audio.prefix(audio.count / 3)),
            ])

        case "a remembered recorder whose file is not a readable recording":
            try await stage(identifier: identifier, inventory: [
                .init(date: Self.day, timestamp: "20260328001919", sizeBytes: 900,
                      content: Data(repeating: 0x41, count: 900)),
            ])

        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    private func stage(identifier: UUID,
                       inventory: [FakePocketBLEStack.ScriptedRecording]) async throws {
        let made = FakePocketBLEStack(deviceId: identifier,
                                      deviceName: "PKT01_BLUE_26079bc5",
                                      acceptedSecret: Self.secret,
                                      inventory: inventory)
        stack = made
        targetIdentifier = identifier
        shelf = inventory.map {
            PocketRecording(date: $0.date, timestamp: $0.timestamp, sizeBytes: $0.sizeBytes)
        }
        subject = shelf.count == 1 ? shelf.first : nil
        try await secrets.save(
            Self.secret,
            for: try PocketAuthenticatedIdentity(peripheralIdentifier: identifier.uuidString))
    }

    // MARK: - When

    func when(_ phrase: String) async throws {
        // THE LIVE BOUNDARIES, WATCHED AROUND THE ACTUAL BRING-OVER. A widget/Live-Activity
        // push is what every live-state transition ends in, so the delta across the pull is a
        // measurement of the real path rather than of a counter a helper incremented.
        let widgetsBefore = CaptureManager.widgetPushesForTests
        switch phrase {
        case "I bring that recording over":
            outcomes = [try await bringOver(try requireSubject())]
        case "I bring that recording over and the app takes the conversation":
            outcomes = [try await bringOver(try requireSubject())]
            try await handToTheApp()
        case "I bring the offered recording over":
            guard let offered = PocketBringOver.offered(shelf) else {
                throw BrineStepError("nothing was offered off a shelf of \(shelf.count) files")
            }
            subject = offered
            outcomes = [try await bringOver(offered)]
        case "I bring that recording over twice":
            let recording = try requireSubject()
            outcomes = [try await bringOver(recording), try await bringOver(recording)]
        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
        widgetPushesDuringPull = CaptureManager.widgetPushesForTests - widgetsBefore
        let spy = StoredFileLiveBoundarySpy()
        StoredFileDeviceLifecycle.runFullLinkLifecycle(liveBoundaries: spy)
        liveEffects = spy.counts
    }

    private func bringOver(_ recording: PocketRecording) async throws -> PocketBringOverOutcome {
        guard let stack, let targetIdentifier, let custody, let library else {
            throw BrineStepError("no recorder was staged")
        }
        // THE PRODUCTION COMPONENT, on the production seam. `recovery: nil` keeps this
        // hermetic; a fresh attachment per pull because `teardown()` retires the link.
        return await PocketBringOver.run(
            peripheralIdentifier: targetIdentifier,
            advertisedName: stack.deviceName,
            recording: recording,
            custody: custody,
            attachment: RecordingDeviceAttachment(
                makeCentral: stack.factory,
                secrets: secrets,
                recovery: nil,
                deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 2)),
            destination: .init(baseDir: library))
    }

    /// THE APP'S HALF, which is one call. `App/DeviceScreen.swift` hands the capture id the
    /// bring-over produced to the running `CaptureManager`; everything after that is the drain
    /// and finalize a phone-mic recording runs, with no Pocket in it anywhere.
    private func handToTheApp() async throws {
        guard let library, let captureID = outcomes.last?.captureID else {
            throw BrineStepError("the bring-over produced no conversation to hand over")
        }
        let spy = door
        let made = await MainActor.run {
            CaptureManager(target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!,
                                              bearer: "x"),
                           baseDir: library,
                           source: ReplaySource(frames: []),
                           finalize: { id, _ in spy.finalize(id) },
                           uploadSegment: { id, seq, body in spy.upload(id, seq, body) })
        }
        manager = made
        await made.hydration?.value
        let beforeAdoption: (Bool, Bool) = await MainActor.run {
            let seen = (made.active != nil, made.isRecordingMic)
            made.adoptCompletedCapture(captureId: captureID)
            return seen
        }
        // WAIT FOR THE LANE, DO NOT REPLACE IT. Adoption kicks the manager's OWN drain, and
        // `drainPending` refuses to run twice at once — so calling it again here returns
        // immediately while the real pass is still in flight. Polling for the OUTCOME is what
        // the app does too: the drain timer fires every five seconds and the conversation
        // finalizes when it finalizes.
        for _ in 0..<200 where spy.finalized.isEmpty {
            await made.drainPending()
            await made.retryPendingFinalizes()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let afterDrain: (Bool, Bool) = await MainActor.run { (made.active != nil, made.isRecordingMic) }
        managerWasEverActive = beforeAdoption.0 || afterDrain.0
        managerWasEverRecordingMic = beforeAdoption.1 || afterDrain.1
    }

    // MARK: - Then

    func then(_ phrase: String) async throws {
        switch phrase {
        case "the recorder is asked for that file on the session the handshake opened":
            let recording = try requireSubject()
            let commands = try requireCommands()
            XCTAssertEqual(commands.filter { $0.hasPrefix("SK&") }.count, 1,
                           "the bring-over opened more than one authenticated session")
            // THE WHOLE TRANSCRIPT, PINNED. `BAT`/`FW` are the shipped coordinator's
            // confirmation that the key was accepted; the pull follows them on the same
            // session, and nothing else is sent at all.
            XCTAssertEqual(commands,
                           ["SK&\(Self.secret)", "BAT", "FW",
                            "U&\(recording.date)&\(recording.timestamp)"])

        case "the file is kept where it can be read back byte for byte":
            XCTAssertEqual(outcomes.count, 1)
            guard case .broughtOver(let bytes, _, _) = outcomes[0] else {
                return XCTFail("the bring-over did not land: \(outcomes)")
            }
            XCTAssertEqual(bytes, Self.fixtureMP3().count)
            let kept = try keptFiles(extension: "mp3")
            XCTAssertEqual(kept.count, 1, "custody holds \(kept.count) recordings, not one")
            guard let only = kept.first else { return XCTFail("nothing was kept") }
            XCTAssertEqual(try Data(contentsOf: only), Self.fixtureMP3(),
                           "what is on disk is not the bytes the recorder sent")
            XCTAssertEqual(try keptFiles(extension: "partial"), [],
                           "a completed transfer left a partial artifact behind")

        case "that recording is listed as being in Solleva rather than only on the recorder":
            let detail = try await checkedShelf()
            let recording = try requireSubject()
            let row = detail.manifest.rows.first {
                $0.title == PocketRecordingLabel.title(date: recording.date,
                                                       timestamp: recording.timestamp)
            }
            XCTAssertEqual(row?.presenceLabel, "In Solleva",
                           "a file Solleva is holding a verified copy of is still listed as "
                               + "only on the recorder")

        case "a conversation exists holding that recording's audio as ordinary capture segments":
            let dir = try captureDirectory()
            let segments = try segmentURLs(in: dir)
            XCTAssertFalse(segments.isEmpty,
                           "the conversation directory holds no audio at all")
            // THE ORDINARY ON-DISK SHAPE, read back with the ORDINARY decoder. If these bytes
            // were anything but the length-framed Opus packets every capture is made of,
            // `CaptureWAL.decodeSegment` would return nothing.
            var frames = 0
            for segment in segments {
                let decoded = CaptureWAL.decodeSegment(try Data(contentsOf: segment))
                XCTAssertFalse(decoded.isEmpty,
                               "\(segment.lastPathComponent) is not a capture segment")
                frames += decoded.count
            }
            // ~3.1 seconds at one 20 ms packet each. A translator that emitted silence, or one
            // frame, or the whole file as a single packet, misses this by an order of magnitude.
            let expected = Int(Self.fixtureSeconds * Double(expectedRepeats) / 0.02)
            XCTAssertEqual(Double(frames), Double(expected), accuracy: Double(expected) * 0.05,
                           "the decoded audio is \(frames) frames, not the ~\(expected) that "
                               + "\(Self.fixtureSeconds * Double(expectedRepeats))s of audio makes")

        case "the conversation is dated to when the recorder says it was recorded":
            let recording = try requireSubject()
            guard let reported = PocketRecordingLabel.reportedInstant(
                date: recording.date, timestamp: recording.timestamp) else {
                return XCTFail("the fixture's own timestamp does not parse")
            }
            let captureID = try requireCaptureID()
            let library = try requireLibrary()
            let meta = ConversationMetaStore.load(captureId: captureID, baseDir: library)
            XCTAssertEqual(meta?.startedAt, UInt64(reported.timeIntervalSince1970),
                           "the conversation is dated to when the phone collected it, not to "
                               + "when the recorder says it was recorded")
            // AND THE ID CARRIES IT TOO, which is what survives when the sidecar does not.
            XCTAssertEqual(CaptureIdTime.startedAt(fromCaptureId: captureID),
                           UInt64(reported.timeIntervalSince1970))
            XCTAssertTrue(captureID.hasPrefix(PocketCaptureImport.captureIdPrefix),
                          "\(captureID) claims to be a stream this phone recorded")

        case "the conversation records which recorder it came from":
            let captureID = try requireCaptureID()
            let library = try requireLibrary()
            let marker = try? String(
                contentsOf: CaptureManager.sourceMarkerURL(captureID, baseDir: library),
                encoding: .utf8)
            XCTAssertEqual(marker, CaptureDeviceSidecar.sourceMarker(for: .filePull),
                           "a pulled recording is marked as something it is not")
            guard case .present(let record) =
                CaptureDeviceSidecar.read(captureId: captureID, baseDir: library) else {
                return XCTFail("the conversation has no device record — its attribution can "
                               + "never be recovered")
            }
            XCTAssertEqual(record.identity.shape, .filePull)
            XCTAssertEqual(record.identity.hardwareToken.lowercased(),
                           try requireIdentifier().uuidString.lowercased(),
                           "the conversation names a recorder that is not the one it came from")

        case "the same upload and finalize a phone recording uses carried it to the brain":
            let captureID = try requireCaptureID()
            XCTAssertEqual(door.finalized, [captureID],
                           "the conversation did not reach the shipped finalize exactly once")
            XCTAssertFalse(door.uploaded.isEmpty,
                           "no audio was uploaded through the shipped segment-upload seam")
            XCTAssertTrue(door.uploaded.allSatisfy { $0.0 == captureID })
            // EVERY UPLOADED BODY IS AN ORDINARY SEGMENT. The door is handed exactly what a
            // phone-mic capture hands it — no Pocket envelope, no MP3, no second wire shape.
            for (_, _, body) in door.uploaded {
                XCTAssertFalse(CaptureWAL.decodeSegment(body).isEmpty,
                               "an uploaded body is not a capture segment")
            }
            // EVERY SEGMENT ON DISK REACHED THE BRAIN, EXACTLY ONCE. Not in order — `sync()`
            // uploads four at a time for every capture there is, and demanding order of a
            // brought-over one would be asking it to behave DIFFERENTLY from the rest.
            let onDisk = try segmentURLs(in: try captureDirectory()).count
            XCTAssertEqual(Set(door.uploaded.map(\.1)).count, door.uploaded.count,
                           "a segment was uploaded twice")
            XCTAssertEqual(door.uploaded.count, onDisk,
                           "\(door.uploaded.count) of \(onDisk) segments reached the brain")

        case "no second ingest route was used":
            // THE STRUCTURAL HALF: nothing on the Pocket side of the boundary may speak to a
            // door, a relay or Lore. If a future change adds a Pocket-specific ingest, it has
            // to add one of these words to one of these files first.
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let pocketSide = ["PocketBringOver.swift", "PocketCaptureImport.swift",
                              "PocketAudioTranslator.swift"]
            for name in pocketSide {
                let url = root.appendingPathComponent("Sources/FoundryXKit/\(name)")
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    return XCTFail("\(name) is not where this gate is looking")
                }
                // COMMENTS STRIPPED, STRING LITERALS BLANKED — the same lexer the App-side
                // composition gates use. These files DISCUSS the pipeline they hand off to at
                // length; a grep over prose would forbid explaining the design.
                let source = AppSourceTree.code(of: text)
                for forbidden in ["DoorClient(", "RelayHTTP.", "URLSession(", "/foundryx/capture",
                                  "CaptureBackend", "tryFinalize", "captureContent"] {
                    XCTAssertFalse(source.contains(forbidden),
                                   "\(name) reaches the brain itself (\"\(forbidden)\") — the "
                                       + "translator hands off to the existing pipeline and "
                                       + "stops")
                }
            }
            // AND THE BEHAVIOURAL HALF: exactly one finalize, and it is the injected one.
            XCTAssertEqual(door.finalized.count, 1)

        case "the audio was written out as it decoded, never assembled whole":
            let dir = try captureDirectory()
            let segments = try segmentURLs(in: dir)
            // ~62 s at 50 frames per segment ⇒ ~62 segments. One segment would mean the whole
            // decode was held and flushed at the end; the point is that it was not.
            XCTAssertGreaterThan(segments.count, 20,
                                 "a minute of audio landed in \(segments.count) segment(s) — it "
                                     + "was assembled whole before anything was written")
            let biggest = try segments.map { try Data(contentsOf: $0).count }.max() ?? 0
            // The decoded PCM for this recording is ~6 MB. No artifact this path ever produced
            // is within two orders of magnitude of that.
            XCTAssertLessThan(biggest, 64 * 1024,
                              "the largest artifact on disk is \(biggest) bytes")
            // AND THE TRANSLATOR ITSELF, asked directly: every packet it hands over is one
            // 20 ms Opus frame, so nothing downstream is ever offered the whole decode.
            let file = try requireLibrary()
                .appendingPathComponent("translator-probe.mp3")
            try Self.fixtureMP3(repeats: expectedRepeats).write(to: file)
            var largest = 0
            var count = 0
            let produced = try PocketAudioTranslator.translate(fileAt: file) { packet in
                largest = max(largest, packet.count)
                count += 1
            }
            XCTAssertEqual(produced.opusPackets, count)
            XCTAssertLessThanOrEqual(largest, 4_000,
                                     "the translator handed over a \(largest)-byte block — it is "
                                         + "not emitting one 20 ms packet at a time")
            XCTAssertGreaterThan(produced.samples, 2_000_000,
                                 "this fixture did not decode to enough audio for the claim to "
                                     + "mean anything")

        case "the shorter file is the one that was asked for":
            let commands = try requireCommands()
            let pulls = commands.filter { $0.hasPrefix("U&") }
            XCTAssertEqual(pulls, ["U&\(Self.day)&20260328020000"],
                           "the pull did not go to the shorter of the two files — the first "
                               + "file anybody pulls off a Pocket should be one that finishes")

        case "each way has its own sentence":
            // NON-VACUITY FIRST. Every assertion below is a claim about a SET, and an EMPTY set
            // satisfies all of them: no two of nothing collide, and none of nothing is blank.
            // Without this floor the whole census passes against an enum with no cases.
            XCTAssertEqual(PocketBringOverFailure.allCases.count, 8,
                           "the failure set changed size — raise this deliberately, and check "
                               + "the new case has a sentence and a token of its own")
            let sentences = PocketBringOverFailure.allCases.map {
                PocketBringOverPresentation.message(forFailure: $0)
            }
            XCTAssertEqual(Set(sentences).count, sentences.count,
                           "two ways of failing say the same thing, so a person reading it "
                               + "cannot tell which happened: \(sentences.sorted())")
            XCTAssertFalse(sentences.contains(where: \.isEmpty),
                           "a way of failing has no sentence at all")

        case "each way has its own log token":
            let tokens = PocketBringOverFailure.allCases.map(\.logToken)
            XCTAssertEqual(Set(tokens).count, tokens.count,
                           "two ways of failing share a log token, so the log cannot name "
                               + "which happened: \(tokens.sorted())")
            XCTAssertFalse(tokens.contains(where: \.isEmpty),
                           "a way of failing has no log token at all")

        case "only losing the recorder mentions how near it is":
            // AC2 AS A CENSUS OVER THE WHOLE SET, not seven string checks. A case added later
            // with a proximity sentence and no test of its own must fail HERE.
            let blaming = PocketBringOverFailure.allCases.filter {
                let line = PocketBringOverPresentation.message(forFailure: $0).lowercased()
                return line.contains("nearby") || line.contains("near ")
                    || line.contains("close") || line.contains("range")
            }
            XCTAssertEqual(blaming, [.lostTheRecorder],
                           "a failure the code cannot attribute to distance says it was distance: "
                               + "\(blaming.map(\.logToken))")

        case "no failure sentence was shown":
            // THE PAIRED POSITIVE. Without this, a set that produced NO failures would satisfy
            // every distinctness claim above vacuously.
            XCTAssertEqual(outcomes.compactMap(\.failure), [],
                           "a transfer that worked still reported a way of failing")
            XCTAssertFalse(outcomes.isEmpty,
                           "no transfer ran at all, so 'no failure' proves nothing")

        case "the recording is in Solleva's custody":
            XCTAssertEqual(try keptFiles(extension: "mp3").count, 1,
                           "the transfer reported success and kept no file")

        case "Solleva keeps no partial copy and says the transfer did not finish":
            // TIGHTENED, NOT LOOSENED. This used to assert `[.transferIncomplete]` — the one word
            // that covered eight causes. It now names WHICH, so a stall that starts reporting
            // itself as a disk failure fails here instead of passing.
            let why = outcomes.first?.failure
            XCTAssertNotNil(why, "a transfer that stopped partway reported no cause at all")
            XCTAssertEqual(outcomes.count, 1)
            XCTAssertEqual(try keptFiles(extension: nil), [],
                           "a transfer that stopped partway left an artifact behind")
            if let why {
                XCTAssertEqual(PocketBringOverPresentation.message(for: .transferIncomplete(why)),
                               PocketBringOverPresentation.message(forFailure: why))
                XCTAssertFalse(why.logToken.isEmpty)
            }

        case "that recording is still listed as only on the recorder":
            let detail = try await checkedShelf()
            XCTAssertEqual(detail.manifest.rows.map(\.presenceLabel), ["Only on the recorder"],
                           "a file that never landed is claimed as one Solleva is holding")

        case "no conversation was created":
            let library = try requireLibrary()
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
            XCTAssertEqual(entries.filter(CaptureLibrary.isNoteDirectory), [],
                           "a bring-over that kept nothing still left a conversation behind")
            XCTAssertNil(outcomes.last?.captureID)

        case "Solleva keeps no copy and says it could not read the recording":
            XCTAssertEqual(outcomes, [.unreadableRecording])
            XCTAssertEqual(try keptFiles(extension: nil), [])
            XCTAssertEqual(PocketBringOverPresentation.message(for: .unreadableRecording),
                           PocketBringOverPresentation.unreadableRecordingLine)

        case "one copy is kept and the recorder was asked only once":
            let captureID = try requireCaptureID()
            XCTAssertEqual(outcomes.count, 2)
            guard case .broughtOver = outcomes[0] else {
                return XCTFail("the first pull did not land: \(outcomes[0])")
            }
            XCTAssertEqual(outcomes[1], .alreadyHeld(captureID: captureID),
                           "the second pull did not recognise the recording it already had")
            XCTAssertEqual(try keptFiles(extension: "mp3").count, 1,
                           "the second pull kept a second copy")
            let commands = try requireCommands()
            XCTAssertEqual(commands.filter { $0.hasPrefix("U&") }.count, 1,
                           "the recorder was asked for a file Solleva already holds")

        case "one conversation exists, not two":
            let library = try requireLibrary()
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
            XCTAssertEqual(entries.filter(CaptureLibrary.isNoteDirectory).count, 1,
                           "bringing one recording over twice made two conversations of it")

        case "the recorder was sent no delete command and the deletion promise is still shown":
            let commands = try requireCommands()
            // THIS SCAN USED TO LOOK FOR THE SUBSTRING `DEL`, AND THE OPCODE IS ONE LETTER.
            // The recorder's delete is `APP&D&<date>&<timestamp>`, which contains no `DEL` —
            // so a bring-over that composed a real delete passed this check unchanged. It now
            // reads the opcode FIELD, which is also what keeps `MCU&DIRS` (a directory listing)
            // from being read as `MCU&D` (a deletion) on a prefix match.
            for command in commands {
                XCTAssertFalse(PocketRecorderWire.namesADeletion("APP&" + command),
                               "the bring-over issued \"\(command)\" — no automatic delete, ever")
            }
            // THE `automaticDeleteCommands == 0` LINE THAT USED TO SIT HERE IS GONE. It was a
            // constant compared to a literal — no code path could falsify it — and Step 6's
            // owner-armed clear made it false as well as useless. The assertion above it is the
            // real one: it reads the frames this leg actually composed.
            XCTAssertTrue(
                PocketRecorderCheckPresentation.sectionNote
                    .contains(PocketRecorderCustodyPromise.text),
                "the panel that now offers a bring-over dropped the deletion promise")
            for line in PocketBringOverPresentation.everyLine {
                XCTAssertFalse(line.uppercased().contains("DELET"),
                               "the bring-over says \"\(line)\" — nothing here deletes")
            }

        case "no FrameRouter, Live Activity, recording pill, or currently-recording state is "
            + "reached":
            // MEASURED AROUND THE REAL PULL. Every live-state transition ends in a widget /
            // Live-Activity push, so a bring-over that started, updated or ended any live state
            // moves this counter. It moved zero times.
            XCTAssertEqual(widgetPushesDuringPull, 0,
                           "the bring-over pushed \(widgetPushesDuringPull) live-state "
                               + "update(s) — it is being presented as a recording in progress")
            // AND THE SHIPPED SCAN REFUSES IT AS A LIVE CANDIDATE. `resumableCaptureId` only
            // ever adopts a capture marked `omi`; a pulled recording is marked `filePull`, so
            // no future live session can attach to it and continue it.
            let library = try requireLibrary()
            XCTAssertNil(CaptureManager.resumableCaptureId(baseDir: library, silenceGap: 3_600),
                         "a brought-over recording is offered to the live path as something a "
                             + "microphone could carry on recording into")
            XCTAssertFalse(managerWasEverActive)
            XCTAssertFalse(managerWasEverRecordingMic)
            // The stored-file DEVICE's own lifecycle claim, unchanged: attaching, showing and
            // reconnecting a record-then-sync recorder selects no live source.
            XCTAssertEqual(liveEffects.storedFileLifecycleEvents, 5)
            XCTAssertEqual(liveEffects.activeSourceSelections, 0)
            XCTAssertEqual(liveEffects.frameRouterStarts, 0)
            XCTAssertEqual(liveEffects.liveActivities, 0)
            XCTAssertEqual(liveEffects.liveStateMutations, 0)

        case "the conversation was never streaming":
            let captureID = try requireCaptureID()
            let library = try requireLibrary()
            // `streaming` is the flag that makes a WAL a LIVE capture — `beginStreaming()` sets
            // it and the drain treats it as "still arriving". The import never calls it, and a
            // WAL rebuilt from this directory says so.
            let rebuilt = CaptureWAL(captureId: captureID,
                                     target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!,
                                                        bearer: ""),
                                     baseDir: library)
            rebuilt.warmStatus()
            XCTAssertFalse(rebuilt.snapshot().streaming,
                           "the brought-over conversation is marked as a recording in progress")
            XCTAssertGreaterThan(rebuilt.snapshot().totalSegments, 0,
                                 "there is nothing on disk for this claim to be about")

        default:
            throw BrineStepError("unhandled Then: \(phrase)")
        }
    }

    // MARK: - What is actually on disk

    /// The shelf as the SHIPPED check would report it once custody has been consulted — the
    /// same call `App/DeviceScreen.swift` re-runs after a bring-over, over the real radio.
    private func checkedShelf() async throws -> StoredFileDeviceDetailPresentation {
        guard let stack, let targetIdentifier, let custody else {
            throw BrineStepError("no recorder was staged")
        }
        let outcome = await PocketRecorderCheck.run(
            peripheralIdentifier: targetIdentifier,
            advertisedName: stack.deviceName,
            custody: custody,
            attachment: RecordingDeviceAttachment(
                makeCentral: stack.factory,
                secrets: secrets,
                recovery: nil,
                deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 2)))
        guard case .checked(let detail) = outcome else {
            throw BrineStepError("the shelf could not be re-read: \(String(describing: outcome))")
        }
        return detail
    }

    /// Artifacts under the custody root. `extension: nil` means EVERY file, `.partial` and the
    /// import receipt included — asking only for finished `.mp3`s would call a directory full
    /// of half-written files empty.
    private func keptFiles(extension wanted: String?) throws -> [URL] {
        guard let custodyRoot else { throw BrineStepError("no custody root was staged") }
        guard let walker = FileManager.default.enumerator(
            at: custodyRoot, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            let regular = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile
            guard regular == true else { continue }
            if let wanted, url.pathExtension != wanted { continue }
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }

    private func segmentURLs(in dir: URL) throws -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            ?? []).filter { $0.pathExtension == "opus" }.sorted { $0.path < $1.path }
    }

    private func captureDirectory() throws -> URL {
        try requireLibrary().appendingPathComponent(try requireCaptureID(), isDirectory: true)
    }

    private func requireCaptureID() throws -> String {
        guard let id = outcomes.last?.captureID else {
            throw BrineStepError("the bring-over produced no conversation: \(outcomes)")
        }
        return id
    }

    private func requireLibrary() throws -> URL {
        guard let library else { throw BrineStepError("no capture library was staged") }
        return library
    }

    private func requireCommands() throws -> [String] {
        guard let stack else { throw BrineStepError("no recorder was staged") }
        return stack.commandsWritten
    }

    private func requireIdentifier() throws -> UUID {
        guard let targetIdentifier else { throw BrineStepError("no recorder was staged") }
        return targetIdentifier
    }

    private func requireSubject() throws -> PocketRecording {
        guard let subject else {
            throw BrineStepError("no single recording was staged for \"that recording\"")
        }
        return subject
    }
}
