import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// `features/pocket-download-survives-the-clock.feature`, driven against the SHIPPED
/// `RecordingDeviceAttachment` -> `PocketSeamTransport` -> `PocketBLEClient.download` chain,
/// with the radio replaying a transfer that was actually captured off the owner's recorder.
///
/// WHY A HAND-WRITTEN HAPPY PATH WAS NOT ENOUGH, AND IS THE REASON THIS DEFECT SHIPPED.
/// Every download scenario in this repository handed the client a list of chunks that arrived
/// in zero wall-clock seconds. The failure being guarded here is made ONLY of elapsed time —
/// the transfer outliving a deadline that was armed during an earlier, already-satisfied wait —
/// so against a recorder with no clock it is not a bug that is missed, it is a bug that cannot
/// be written down. The timings below come out of
/// `fixtures/pocket/pocket-fw16-ble-download-trace.json`: 82 real chunk lengths and the 81 real
/// gaps between them, captured 2026-08-18 from PKT01_BLUE_26079bc5 on firmware 1.6.
final class PocketDownloadSurvivesTheClockFeatureTests: XCTestCase {
    func testPocketDownloadSurvivesTheClockFeature() async throws {
        let world = PocketDownloadClockWorld()
        let result = try await BrineFeatureRunner.run(
            "pocket-download-survives-the-clock",
            registry: StepRegistry(PocketDownloadClockSteps.make(world)))
        XCTAssertEqual(result.passed, 3)
    }
}

private enum PocketDownloadClockSteps {
    static func make(_ world: PocketDownloadClockWorld) -> [StepDefinition] {
        let givens = [
            "a recorder replaying the captured transfer, whose longest silence is far inside the deadline",
            "a recorder that announces a size and then stops sending partway through",
            "a recorder that sends its end-of-transfer frame after the last audio chunk"
        ]
        let whens = [
            "the recording is brought over",
            "two recordings are brought over on one session"
        ]
        let thens = [
            "every announced byte arrives and the recording is kept",
            "the transfer fails as a download timeout rather than as an unreadable recording",
            "both arrive whole and neither command reads the terminator as its answer"
        ]
        var steps = givens.map { phrase in
            defineStep(phrase) { context, _, _ in await world.given(phrase); return context }
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

/// THE CAPTURED TRACE, READ AT RUN TIME.
///
/// Read by repo path, exactly the way `PocketBringOverWorld.fixtureMP3()` reads the audio
/// fixture beside it — `fixtures/pocket` is in `Package.swift`'s `exclude:` list, so nothing
/// here is a bundle resource. If the file is missing this REFUSES rather than substituting
/// invented timings, because a scenario that silently falls back to made-up numbers is exactly
/// the shape of gate this feature exists to replace.
private enum PocketCapturedTrace {
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

    /// Run B, pass 1: two downloads on ONE session with no re-subscribe, and the SLOWEST of the
    /// three captured transfers — 934 ms end to end with a largest inter-chunk gap of 116 ms.
    /// The slowest one is the honest one to build a deadline scenario on.
    static func slowestCapturedTransfer() throws -> Transfer {
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

    /// How long after the last audio chunk `MCU&OFF` landed. The WORST of the three
    /// observations, so a scenario is not tuned to the friendliest one.
    static func worstTerminatorDelaySeconds() throws -> TimeInterval {
        let root = try json()
        guard let measurements = root["measurements"] as? [String: Any],
              let terminator = measurements["terminator"] as? [String: Any],
              let offsets = terminator["ms_after_last_audio_chunk"] as? [Double],
              let worst = offsets.max()
        else { throw BrineStepError("the captured BLE trace states no terminator offset") }
        return worst / 1_000
    }

    /// Real MPEG-2 Layer III bytes, cycled up to the length the trace announced. The first byte
    /// is the sync word, which is what the device sends (`preamble_bytes_before_sync_word: 0`).
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

private actor PocketDownloadClockWorld {
    private static let secret = "0123456789abcdef"
    private static let date = "2026-08-07"
    private static let firstTimestamp = "20260807142852"
    private static let secondTimestamp = "20260807153240"

    private var stack: FakePocketBLEStack?
    private var attachment: RecordingDeviceAttachment?
    private var identifier = UUID()

    private var delivered: [Int] = []
    private var failure: PocketProtocolError?
    private var sessionOpened = false
    /// How long the transfer itself took, measured from the moment the session was open. It is
    /// asserted on, because "a stall is eventually reported" is true of a bound of any size and
    /// says nothing about WHICH bound applied.
    private var transferSeconds: TimeInterval = 0

    func given(_ phrase: String) async {
        delivered = []
        failure = nil
        sessionOpened = false
        transferSeconds = 0
        identifier = UUID()

        switch phrase {
        case "a recorder replaying the captured transfer, whose longest silence is far inside the deadline":
            guard let transfer = try? PocketCapturedTrace.slowestCapturedTransfer(),
                  let payload = try? PocketCapturedTrace.payload(ofLength: transfer.announcedBytes),
                  let terminator = try? PocketCapturedTrace.worstTerminatorDelaySeconds()
            else { return }
            await build(inventory: [.init(date: Self.date, timestamp: Self.firstTimestamp,
                                    sizeBytes: payload.count, content: payload)],
                  timing: .init(gapsSeconds: transfer.gapsSeconds,
                                lengths: transfer.lengths,
                                terminatorAfterSeconds: terminator),
                  // EVERY DEADLINE HERE IS SHORTER THAN THE TRANSFER AND LONGER THAN EVERY
                  // SILENCE IN IT. 0.5 s covers the largest captured gap (116.4 ms) more than
                  // four times over, while the transfer itself runs 934 ms — so the ONLY way to
                  // fail this is to be bounded by something other than the silence.
                  //
                  // Both budgets are named, and the idle gap is deliberately small enough that
                  // the timers armed by the audio reads themselves mature DURING the transfer.
                  // That is what makes the scenario able to see a timer that outlives the wait
                  // it was armed for: at the shipped 25 s idle gap those timers all mature long
                  // after any test has finished, and a client that kills the wrong waiter looks
                  // exactly like one that does not.
                  deadlines: .init(powerOn: 5, connect: 5, discovery: 5,
                                   control: 0.5, downloadIdleGap: 0.5))

        case "a recorder that announces a size and then stops sending partway through":
            guard let payload = try? PocketCapturedTrace.payload(ofLength: 4_880) else { return }
            await build(inventory: [.init(date: Self.date, timestamp: Self.firstTimestamp,
                                    sizeBytes: payload.count, content: payload,
                                    // IT PROMISES FOUR TIMES WHAT IT SENDS, then goes quiet —
                                    // no error frame, because there is no frame for this on the
                                    // wire.
                                    announcedSizeBytes: payload.count * 4)],
                  timing: .init(gapsSeconds: [0.002], lengths: nil,
                                terminatorAfterSeconds: nil),
                  deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 2,
                                   downloadIdleGap: 0.4))

        case "a recorder that sends its end-of-transfer frame after the last audio chunk":
            guard let payload = try? PocketCapturedTrace.payload(ofLength: 2_440),
                  let terminator = try? PocketCapturedTrace.worstTerminatorDelaySeconds()
            else { return }
            await build(inventory: [
                .init(date: Self.date, timestamp: Self.firstTimestamp,
                      sizeBytes: payload.count, content: payload),
                .init(date: Self.date, timestamp: Self.secondTimestamp,
                      sizeBytes: payload.count, content: payload)
            ],
                  timing: .init(gapsSeconds: [0.001], lengths: [244],
                                terminatorAfterSeconds: terminator),
                  deadlines: .init(powerOn: 5, connect: 5, discovery: 5, control: 2))

        default: break
        }
    }

    private func build(inventory: [FakePocketBLEStack.ScriptedRecording],
                       timing: FakePocketBLEStack.DownloadWireTiming,
                       deadlines: RecordingDeviceAttachment.Deadlines) async {
        let stack = FakePocketBLEStack(deviceId: identifier,
                                       deviceName: "PKT01_BLUE_26079bc5",
                                       acceptedSecret: Self.secret,
                                       inventory: inventory,
                                       downloadTiming: timing)
        let secrets = InMemoryPocketSecretStore()
        if let identity = try? PocketAuthenticatedIdentity(
            peripheralIdentifier: identifier.uuidString) {
            try? await secrets.save(Self.secret, for: identity)
        }
        self.stack = stack
        attachment = RecordingDeviceAttachment(makeCentral: stack.factory, secrets: secrets,
                                               recovery: nil, deadlines: deadlines)
    }

    func when(_ phrase: String) async throws {
        guard let attachment, let stack else { throw BrineStepError("no recorder was staged") }
        let timestamps: [String]
        switch phrase {
        case "two recordings are brought over on one session":
            timestamps = [Self.firstTimestamp, Self.secondTimestamp]
        default:
            timestamps = [Self.firstTimestamp]
        }
        let outcome = await attachment.withAuthenticatedSession(
            peripheralIdentifier: identifier, advertisedName: stack.deviceName
        ) { client, _ -> ([Int], PocketProtocolError?, TimeInterval) in
            let startedAt = Date()
            var counts: [Int] = []
            for timestamp in timestamps {
                if !counts.isEmpty {
                    // THE GAP A SECOND BRING-OVER REALLY HAS. `MCU&OFF` lands 0.086-11.078 ms
                    // after the last chunk; the next command on a real errand is at least a
                    // custody commit and an import behind that. Without this wait the fake's
                    // terminator would race the next `APP&U&` write and the scenario would
                    // sometimes pass for the wrong reason — the frame arriving during the audio
                    // phase, where it is discarded, instead of while the control channel is
                    // being read.
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
                do {
                    var bytes = 0
                    _ = try await client.download(
                        .init(date: Self.date, timestamp: timestamp),
                        ceilingBytes: PocketBringOver.maximumBytes
                    ) { chunk in bytes += chunk.count }
                    counts.append(bytes)
                } catch let error as PocketProtocolError {
                    return (counts, error, Date().timeIntervalSince(startedAt))
                } catch {
                    return (counts, .transportFailure, Date().timeIntervalSince(startedAt))
                }
            }
            return (counts, nil, Date().timeIntervalSince(startedAt))
        }
        guard case .ran(let result) = outcome else {
            throw BrineStepError("the session never opened: \(String(describing: outcome))")
        }
        sessionOpened = true
        delivered = result.0
        failure = result.1
        transferSeconds = result.2
    }

    func then(_ phrase: String) async throws {
        XCTAssertTrue(sessionOpened, "the session never opened")
        switch phrase {
        case "every announced byte arrives and the recording is kept":
            let transfer = try PocketCapturedTrace.slowestCapturedTransfer()
            XCTAssertNil(failure,
                         "the captured transfer — every silence in which is under a quarter of "
                             + "the deadline — failed with \(String(describing: failure)). A "
                             + "per-event budget that kills a healthy stream is a wall-clock "
                             + "bound on the whole transfer wearing a per-event name, and at "
                             + "~18 KB/s the owner's largest recording is tens of minutes.")
            XCTAssertEqual(delivered, [transfer.announcedBytes])

        case "the transfer fails as a download timeout rather than as an unreadable recording":
            // A SHORTFALL AND A SILENCE ARE DIFFERENT ANSWERS. `.malformedResponse` is what this
            // client says when the recorder's own numbers do not add up, and it becomes
            // "Solleva couldn't read this recording"; a recorder that simply stopped talking has
            // said nothing wrong and must not be reported that way.
            XCTAssertEqual(failure, .timeout(.download),
                           "a recorder that went quiet mid-transfer was reported as "
                               + "\(String(describing: failure))")
            XCTAssertNotEqual(failure, .malformedResponse)
            XCTAssertEqual(delivered, [], "a failed transfer reported delivered bytes")
            // AND IT WAS THE TRANSFER'S OWN BOUND THAT APPLIED, not a command's. The recorder
            // was staged with a 0.4 s idle-gap budget and a 2 s control budget; a client that
            // still bounds audio by the control number takes at least 2 s to notice. Without
            // this the scenario would be satisfied by a bound of ANY size, which is the shape
            // of gate that let one flat number cover every wait in the first place.
            XCTAssertLessThan(transferSeconds, 1.5,
                              "the silence was noticed after \(transferSeconds) s, which is the "
                                  + "control round-trip budget rather than the 0.4 s idle-gap "
                                  + "budget this recorder was staged with")

        case "both arrive whole and neither command reads the terminator as its answer":
            XCTAssertNil(failure,
                         "the second download on the same session failed with "
                             + "\(String(describing: failure)). MCU&OFF lands on the CONTROL "
                             + "characteristic after the announced byte count is already "
                             + "satisfied, so a client that never drains it hands that frame to "
                             + "the next command as its answer — which breaks a second "
                             + "bring-over and the shelf re-read inside removeRecording.")
            XCTAssertEqual(delivered, [2_440, 2_440])

        default: XCTFail("Unhandled assertion: \(phrase)")
        }
    }
}
