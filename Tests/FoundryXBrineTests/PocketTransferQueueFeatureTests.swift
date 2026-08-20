import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// `features/pocket-transfer-queue.feature`, driven against the SHIPPED
/// `PocketTransferQueue` -> `PocketBringOver.bringOver(on:)` -> `PocketBLEClient.download`
/// chain, with the radio replaying the transfer captured off the owner's recorder
/// (`fixtures/pocket/pocket-fw16-ble-download-trace.json`: 82 real chunk lengths, 81 real
/// gaps, largest silence 116.4 ms).
///
/// WHAT EACH SCENARIO CAN FAIL ON, because a gate that cannot fail is worse than no gate:
///
///   * ONE SESSION FOR A QUEUE OF TWO is held by counting `SK&` frames the fake recorder
///     actually received — open a session per item and the count is 2, red.
///   * PROGRESS is held over EVERY reading the queue published: monotonic, never past the
///     announced total, ending exactly on it — and the denominator is asserted to be the
///     `MCU&U&` announcement while the LISTED size is staged as a deliberately different
///     number (the listing-unit trap: listing 4 -> 19,770 bytes). Point the denominator at
///     `recording.sizeBytes`, red. Delete the announce callback, red.
///   * A STOP leaves no `.partial`, no `.mp3` and no receipt for the stopped item — remove
///     `writer.abandon()` from the cancel path, red — and the stopped item is never offered
///     again, so a `stopOne` that is a no-op is red on the recorder's own command transcript.
///   * BACKOFF is held as the interval SEQUENCE 60/120/240 through an injected sleeper —
///     a constant-zero backoff, or one that never resets on presence, is red.
final class PocketTransferQueueFeatureTests: XCTestCase {
    func testPocketTransferQueueFeature() async throws {
        let world = PocketTransferQueueWorld()
        let result = try await BrineFeatureRunner.run(
            "pocket-transfer-queue",
            registry: StepRegistry(PocketTransferQueueSteps.make(world)))
        XCTAssertEqual(result.passed, 3)
    }
}

private enum PocketTransferQueueSteps {
    static func make(_ world: PocketTransferQueueWorld) -> [StepDefinition] {
        let givens = [
            "a recorder holding two recordings queued for transfer, replaying the captured trace",
            "a recorder that drops the link partway through a transfer and stays away",
        ]
        let whens = [
            "the queue runs",
            "the first recording is stopped partway through",
        ]
        let thens = [
            "both recordings arrive on a single authenticated session",
            "each recording's progress climbs to exactly the announced total and never past it",
            "the denominator is the announced byte count, never the listed size",
            "the stopped recording leaves no partial file and no conversation",
            "the other recording still arrives whole on a fresh session",
            "the stopped recording is not offered to the queue again",
            "the waits between retries follow the shipped backoff schedule",
            "every retry wait says the transfer starts again from the beginning",
            "the recording ends reported as not brought over, with nothing kept",
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

/// THE CAPTURED TRACE, READ AT RUN TIME — the same repo-path mechanism the download-clock
/// feature uses. If the file is missing this REFUSES rather than substituting invented
/// timings.
private enum TransferQueueTrace {
    struct Transfer {
        let announcedBytes: Int
        let lengths: [Int]
        let gapsSeconds: [TimeInterval]
    }

    private static func json() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/pocket/pocket-fw16-ble-download-trace.json")
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrineStepError("the captured BLE trace is not a JSON object")
        }
        return object
    }

    /// Run B's last pass: the slowest captured transfer — and run B is itself the measured
    /// proof this feature stands on, TWO downloads on ONE session with no re-subscribe.
    static func capturedTransfer() throws -> Transfer {
        let root = try json()
        guard let runs = root["runs"] as? [String: Any],
              let runB = runs["B_two_downloads_one_session_no_resubscribe"] as? [String: Any],
              let passes = runB["passes"] as? [[String: Any]],
              let pass = passes.last,
              let announced = pass["announced_bytes"] as? Int,
              let chunks = pass["chunks"] as? [String: Any],
              let lengths = chunks["lengths"] as? [Int],
              let gaps = chunks["inter_chunk_gaps_ms"] as? [Double]
        else { throw BrineStepError("the captured BLE trace has no run-B pass to replay") }
        guard lengths.reduce(0, +) == announced else {
            throw BrineStepError("the captured chunk lengths do not sum to the announced size")
        }
        return Transfer(announcedBytes: announced, lengths: lengths,
                        gapsSeconds: gaps.map { $0 / 1_000 })
    }

    static func worstTerminatorDelaySeconds() throws -> TimeInterval {
        let root = try json()
        guard let measurements = root["measurements"] as? [String: Any],
              let terminator = measurements["terminator"] as? [String: Any],
              let offsets = terminator["ms_after_last_audio_chunk"] as? [Double],
              let worst = offsets.max()
        else { throw BrineStepError("the captured BLE trace states no terminator offset") }
        return worst / 1_000
    }

    /// Real MPEG-2 Layer III bytes, cycled to the announced length. The first byte is the
    /// sync word (`preamble_bytes_before_sync_word: 0` in the trace), so delivered == announced.
    static func payload(ofLength length: Int) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/pocket/pocket-fw16-3s.mp3")
        let one = try Data(contentsOf: url)
        guard !one.isEmpty else { throw BrineStepError("the Pocket audio fixture is empty") }
        var many = Data()
        many.reserveCapacity(length)
        while many.count < length { many.append(one) }
        return many.prefix(length)
    }
}

/// Every phase reading the queue ever published, in arrival order, under a lock — so the
/// progress claims are held over the POPULATION of readings rather than the final one.
private final class PhaseLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(PocketRecordingRequest, PocketTransferPhase)] = []
    func note(_ request: PocketRecordingRequest, _ phase: PocketTransferPhase) {
        lock.withLock { entries.append((request, phase)) }
    }
    func all() -> [(PocketRecordingRequest, PocketTransferPhase)] {
        lock.withLock { entries }
    }
    func transfers(for request: PocketRecordingRequest) -> [(delivered: Int, announced: Int)] {
        lock.withLock {
            entries.compactMap { entry in
                guard entry.0 == request,
                      case .transferring(let delivered, let announced) = entry.1
                else { return nil }
                return (delivered, announced)
            }
        }
    }
}

/// The waits the queue asked for, without sitting through them.
private final class SleepLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var intervals: [TimeInterval] = []
    func note(_ seconds: TimeInterval) { lock.withLock { intervals.append(seconds) } }
    func all() -> [TimeInterval] { lock.withLock { intervals } }
}

private actor PocketTransferQueueWorld {
    private static let secret = "0123456789abcdef"
    private static let day = "2026-08-07"
    private static let firstTimestamp = "20260807142852"
    private static let secondTimestamp = "20260807153240"
    /// THE LISTING-UNIT TRAP, STAGED ON PURPOSE. The recorder LISTS this recording as 4 — a
    /// number that is not bytes (measured: listing 4 -> 19,770 announced bytes) — so the
    /// queued `PocketRecording.sizeBytes` carries 4 KB while the wire announces 19,770. A
    /// progress denominator read from anything but the `MCU&U&` announcement cannot agree
    /// with the announced total, and the scenario asserts exactly that disagreement.
    private static let listedBytes = 4 * 1_024

    private var stack: FakePocketBLEStack?
    private var identifier = UUID()
    private var secrets = InMemoryPocketSecretStore()
    private var custodyRoot: URL?
    private var custody: PocketRecorderFileStore?
    private var library: URL?
    private var queue: PocketTransferQueue?
    private var phases = PhaseLedger()
    private var sleeps = SleepLedger()
    private var queued: [PocketRecording] = []
    private var announcedBytes = 0

    private var firstRequest: PocketRecordingRequest {
        .init(date: Self.day, timestamp: Self.firstTimestamp)
    }
    private var secondRequest: PocketRecordingRequest {
        .init(date: Self.day, timestamp: Self.secondTimestamp)
    }

    // MARK: - Given

    func given(_ phrase: String) async throws {
        phases = PhaseLedger()
        sleeps = SleepLedger()
        secrets = InMemoryPocketSecretStore()
        identifier = UUID()
        queued = []
        let unique = UUID().uuidString
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pocket-transfer-queue-\(unique)")
        custodyRoot = root
        custody = PocketRecorderFileStore(root: root)
        let captures = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pocket-transfer-library-\(unique)", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        library = captures

        let transfer = try TransferQueueTrace.capturedTransfer()
        let payload = try TransferQueueTrace.payload(ofLength: transfer.announcedBytes)
        announcedBytes = transfer.announcedBytes

        switch phrase {
        case "a recorder holding two recordings queued for transfer, replaying the captured trace":
            try await stage(
                inventory: [
                    .init(date: Self.day, timestamp: Self.firstTimestamp,
                          sizeBytes: payload.count, content: payload),
                    .init(date: Self.day, timestamp: Self.secondTimestamp,
                          sizeBytes: payload.count, content: payload),
                ],
                timing: .init(gapsSeconds: transfer.gapsSeconds,
                              lengths: transfer.lengths,
                              terminatorAfterSeconds:
                                try TransferQueueTrace.worstTerminatorDelaySeconds()))
            queued = [
                PocketRecording(date: Self.day, timestamp: Self.firstTimestamp,
                                sizeBytes: Self.listedBytes),
                PocketRecording(date: Self.day, timestamp: Self.secondTimestamp,
                                sizeBytes: Self.listedBytes),
            ]

        case "a recorder that drops the link partway through a transfer and stays away":
            try await stage(
                inventory: [
                    .init(date: Self.day, timestamp: Self.firstTimestamp,
                          sizeBytes: payload.count, content: payload),
                ],
                timing: .init(gapsSeconds: [0.001],
                              lengths: transfer.lengths,
                              terminatorAfterSeconds: nil,
                              dropLinkAfterChunks: 40))
            queued = [
                PocketRecording(date: Self.day, timestamp: Self.firstTimestamp,
                                sizeBytes: Self.listedBytes),
            ]

        default:
            throw BrineStepError("unhandled Given: \(phrase)")
        }
    }

    private func stage(inventory: [FakePocketBLEStack.ScriptedRecording],
                       timing: FakePocketBLEStack.DownloadWireTiming) async throws {
        let made = FakePocketBLEStack(deviceId: identifier,
                                      deviceName: "PKT01_BLUE_26079bc5",
                                      acceptedSecret: Self.secret,
                                      inventory: inventory,
                                      downloadTiming: timing)
        stack = made
        try await secrets.save(
            Self.secret,
            for: try PocketAuthenticatedIdentity(peripheralIdentifier: identifier.uuidString))
    }

    private func makeQueue() throws -> PocketTransferQueue {
        guard let stack, let custody, let library else {
            throw BrineStepError("no recorder was staged")
        }
        let factory = stack.factory
        let secrets = self.secrets
        let sleepLedger = sleeps
        let phaseLedger = phases
        let made = PocketTransferQueue(
            peripheralIdentifier: identifier,
            advertisedName: stack.deviceName,
            custody: custody,
            destination: .init(baseDir: library),
            makeAttachment: {
                // A FRESH ATTACHMENT PER SESSION, exactly as production must: `teardown()`
                // retires an attachment permanently.
                RecordingDeviceAttachment(
                    makeCentral: factory, secrets: secrets, recovery: nil,
                    deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 2))
            },
            sleeper: { seconds in sleepLedger.note(seconds) })
        queue = made
        return made
    }

    // MARK: - When

    func when(_ phrase: String) async throws {
        let queue = try makeQueue()
        let ledger = phases
        await queue.observePhases { request, phase in ledger.note(request, phase) }
        await queue.enqueue(queued)

        switch phrase {
        case "the queue runs":
            await queue.run()

        case "the first recording is stopped partway through":
            let running = Task { await queue.run() }
            // WAIT FOR REAL BYTES OF THE FIRST RECORDING, then stop it. The captured transfer
            // runs ~0.9 s end to end, so a stop issued at the first published reading lands
            // mid-transfer, not after it.
            let target = firstRequest
            var sawTransfer = false
            for _ in 0..<1_000 {
                if let last = phases.transfers(for: target).last, last.delivered > 0,
                   last.delivered < last.announced / 2 {
                    sawTransfer = true
                    break
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard sawTransfer else {
                running.cancel()
                throw BrineStepError("the first recording never started transferring")
            }
            await queue.stop(target)
            await running.value

        default:
            throw BrineStepError("unhandled When: \(phrase)")
        }
    }

    // MARK: - Then

    func then(_ phrase: String) async throws {
        switch phrase {
        case "both recordings arrive on a single authenticated session":
            let commands = try requireCommands()
            XCTAssertEqual(commands.filter { $0.hasPrefix("SK&") }.count, 1,
                           "a queue of two opened \(commands.filter { $0.hasPrefix("SK&") }.count) "
                               + "authenticated sessions; the whole point of the sequential "
                               + "queue is back-to-back pulls on ONE session, which the "
                               + "hardware measurement says is possible")
            XCTAssertEqual(commands.filter { $0.hasPrefix("U&") }.count, 2,
                           "two recordings were queued and the recorder was not asked for two")
            let finals = try await finalPhases()
            guard case .broughtOver = finals[firstRequest] else {
                return XCTFail("the first recording ended \(String(describing: finals[firstRequest]))")
            }
            guard case .broughtOver = finals[secondRequest] else {
                return XCTFail("the second recording ended \(String(describing: finals[secondRequest]))")
            }
            let kept = try keptFiles(extension: "mp3")
            XCTAssertEqual(kept.count, 2, "custody holds \(kept.count) recordings, not two")
            let payload = try TransferQueueTrace.payload(ofLength: announcedBytes)
            for file in kept {
                XCTAssertEqual(try Data(contentsOf: file), payload,
                               "what is on disk is not the bytes the recorder sent")
            }

        case "each recording's progress climbs to exactly the announced total and never past it":
            for request in [firstRequest, secondRequest] {
                let readings = phases.transfers(for: request)
                XCTAssertFalse(readings.isEmpty,
                               "no progress was ever published for \(request.timestamp) — "
                                   + "the announced total and the delivered count are computed "
                                   + "on the radio path, and publishing them is this feature")
                var previous = 0
                for reading in readings {
                    XCTAssertGreaterThanOrEqual(reading.delivered, previous,
                                                "progress went backwards")
                    XCTAssertLessThanOrEqual(reading.delivered, reading.announced,
                                             "progress claimed more bytes than the recorder "
                                                 + "announced")
                    previous = reading.delivered
                }
                XCTAssertEqual(readings.last?.delivered, announcedBytes,
                               "the transfer completed but progress never reached the "
                                   + "announced total")
            }

        case "the denominator is the announced byte count, never the listed size":
            XCTAssertNotEqual(announcedBytes, Self.listedBytes,
                              "the fixture no longer stages the listing-unit disagreement, so "
                                  + "this assertion cannot discriminate")
            for request in [firstRequest, secondRequest] {
                for reading in phases.transfers(for: request) {
                    XCTAssertEqual(reading.announced, announcedBytes,
                                   "a progress reading was denominated in \(reading.announced) "
                                       + "— the MCU&U& announcement is \(announcedBytes) and "
                                       + "the LISTED size is \(Self.listedBytes), a different "
                                       + "unit nothing may be sized from")
                }
            }

        case "the stopped recording leaves no partial file and no conversation":
            let finals = try await finalPhases()
            XCTAssertEqual(finals[firstRequest], .stopped,
                           "the stopped recording ended \(String(describing: finals[firstRequest]))")
            XCTAssertEqual(try keptFiles(extension: "partial"), [],
                           "a stopped transfer left a half-written partial behind")
            let kept = try keptFiles(extension: "mp3")
            XCTAssertFalse(kept.contains { $0.path.contains(Self.firstTimestamp) },
                           "a stopped transfer left custody claiming the file")
            XCTAssertEqual(try keptFiles(extension: "capture")
                               .filter { $0.path.contains(Self.firstTimestamp) }, [],
                           "a stopped transfer left a conversation receipt")

        case "the other recording still arrives whole on a fresh session":
            let finals = try await finalPhases()
            guard case .broughtOver = finals[secondRequest] else {
                return XCTFail("the second recording ended "
                                   + "\(String(describing: finals[secondRequest])) — a stop of "
                                   + "ONE recording must not stop the queue")
            }
            let payload = try TransferQueueTrace.payload(ofLength: announcedBytes)
            let kept = try keptFiles(extension: "mp3")
                .filter { $0.path.contains(Self.secondTimestamp) }
            XCTAssertEqual(kept.count, 1)
            if let only = kept.first {
                XCTAssertEqual(try Data(contentsOf: only), payload)
            }
            // The stop tore the first session down — `teardown()` and `retire` are permanent
            // by construction — so the rest of the queue must have earned a fresh handshake.
            let commands = try requireCommands()
            XCTAssertEqual(commands.filter { $0.hasPrefix("SK&") }.count, 2,
                           "the queue continued without re-authenticating a session the stop "
                               + "had already retired")

        case "the stopped recording is not offered to the queue again":
            guard let queue else { throw BrineStepError("no queue ran") }
            let asksBefore = try requireCommands().filter {
                $0.hasPrefix("U&\(Self.day)&\(Self.firstTimestamp)")
            }.count
            // Re-derivation re-offers the shelf; the owner's stop must survive it.
            await queue.enqueue(queued)
            await queue.run()
            let asksAfter = try requireCommands().filter {
                $0.hasPrefix("U&\(Self.day)&\(Self.firstTimestamp)")
            }.count
            XCTAssertEqual(asksAfter, asksBefore,
                           "re-deriving the queue asked the recorder for a recording the "
                               + "owner stopped — a stop that un-presses itself is not a stop")

        case "the waits between retries follow the shipped backoff schedule":
            XCTAssertEqual(sleeps.all().map { Int($0) }, [60, 120, 240],
                           "the waits between retries were \(sleeps.all()) — the shipped "
                               + "presence schedule is 60/120/240(/300 cap), and a queue that "
                               + "hammers a recorder that left is the thing backoff exists to "
                               + "prevent")

        case "every retry wait says the transfer starts again from the beginning":
            let waits = phases.all().filter {
                if case .waitingToRetry = $0.1 { return true }
                return false
            }
            XCTAssertFalse(waits.isEmpty, "no retry wait was ever published")
            for (_, phase) in waits {
                guard let line = PocketTransferQueuePresentation.line(for: phase) else {
                    return XCTFail("a retry wait renders no sentence at all")
                }
                XCTAssertTrue(
                    line.contains("start again from the beginning"),
                    "a retry's sentence — \"\(line)\" — does not say the restart is from "
                        + "zero. The wire admits no offset and custody keeps no partial; a "
                        + "retry line that implies a resume is a lie about what the retry "
                        + "costs")
            }

        case "the recording ends reported as not brought over, with nothing kept":
            let finals = try await finalPhases()
            guard case .failed = finals[firstRequest] else {
                return XCTFail("a recorder that left mid-transfer ended "
                                   + "\(String(describing: finals[firstRequest])) rather than "
                                   + "reported failed")
            }
            XCTAssertEqual(try keptFiles(extension: "partial"), [],
                           "a dropped transfer left a half-written partial behind")
            XCTAssertEqual(try keptFiles(extension: "mp3"), [],
                           "a dropped transfer left custody claiming a file that never "
                               + "finished")

        default:
            XCTFail("Unhandled assertion: \(phrase)")
        }
    }

    // MARK: - Plumbing

    private func requireCommands() throws -> [String] {
        guard let stack else { throw BrineStepError("no recorder was staged") }
        return stack.commandsWritten
    }

    private func finalPhases() async throws -> [PocketRecordingRequest: PocketTransferPhase] {
        guard let queue else { throw BrineStepError("no queue ran") }
        var result: [PocketRecordingRequest: PocketTransferPhase] = [:]
        for item in await queue.snapshot { result[item.recording.request] = item.phase }
        return result
    }

    private func keptFiles(extension ext: String) throws -> [URL] {
        guard let custodyRoot else { throw BrineStepError("no custody root was staged") }
        guard let files = FileManager.default.enumerator(
            at: custodyRoot, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { $0 as? URL }.filter { $0.pathExtension == ext }
    }
}
