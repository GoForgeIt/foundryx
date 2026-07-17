import XCTest
@testable import FoundryXKit

/// Unit coverage for the speaker-confirm feedback seam (track 20260717T0900):
/// the durable + deadline-bounded flow, failure classification, the sheet reaction,
/// the per-slot phase controller, and the 401-aware drain.
final class SpeakerConfirmFlowTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func outcome(offered: [OfferedCapture] = []) -> ConfirmOutcome {
        ConfirmOutcome(captureId: "cap-1", slotLabel: "speaker_1", status: "confirmed",
                       speakerId: "sp-9", speakerName: "Nick", offeredCaptures: offered)
    }

    // MARK: flow

    func testSuccessDequeuesIntent() async {
        let expected = outcome()
        let result = await SpeakerConfirmFlow.run(
            captureId: "cap-1", slot: "speaker_1", baseDir: dir, ship: { expected })
        guard case .success(let got) = result else { return XCTFail("expected success") }
        XCTAssertEqual(got, expected)
        XCTAssertTrue(SpeakerConfirmQueue.pending(baseDir: dir).isEmpty,
                      "an acknowledged confirm must not stay queued")
    }

    func testTransportFailureKeepsIntentQueued() async {
        let result = await SpeakerConfirmFlow.run(
            captureId: "cap-1", slot: "speaker_1", name: "Dana", baseDir: dir,
            ship: { throw DoorError.transport("down") })
        XCTAssertEqual(result, .failure(.unreachable))
        let pending = SpeakerConfirmQueue.pending(baseDir: dir)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.slot, "speaker_1")
        XCTAssertEqual(pending.first?.name, "Dana")
    }

    func testAuthExpiredClassifiedAndNotRetryable() async {
        let result = await SpeakerConfirmFlow.run(
            captureId: "cap-1", slot: "speaker_1", baseDir: dir,
            ship: { throw DoorError.unauthorized })
        XCTAssertEqual(result, .failure(.authExpired))
        XCTAssertFalse(SpeakerConfirmPresentation.failureCopy(.authExpired).retryable,
                       "retrying an expired sign-in cannot help until re-auth")
        XCTAssertEqual(SpeakerConfirmQueue.pending(baseDir: dir).count, 1)
    }

    func testRejectedClassified() async {
        let result = await SpeakerConfirmFlow.run(
            captureId: "cap-1", slot: "speaker_1", baseDir: dir,
            ship: { throw DoorError.http(500) })
        XCTAssertEqual(result, .failure(.rejected(500)))
        XCTAssertTrue(SpeakerConfirmPresentation.failureCopy(.rejected(500)).retryable)
    }

    func testDeadlineResolvesHungShipToUnreachable() async {
        let start = Date()
        let result = await SpeakerConfirmFlow.run(
            captureId: "cap-1", slot: "speaker_1", baseDir: dir, deadline: 0.2,
            ship: {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return ConfirmOutcome(captureId: "", slotLabel: "", status: "",
                                      speakerId: "", speakerName: "")
            })
        XCTAssertEqual(result, .failure(.unreachable),
                       "a hung round trip must resolve honestly, never a dead button")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5,
                          "the deadline must actually bound the wait")
        XCTAssertEqual(SpeakerConfirmQueue.pending(baseDir: dir).count, 1,
                       "the intent must survive for the drain to re-ship")
    }

    /// Adversarial-review P1 regression: the production relay leg can park on a
    /// continuation that IGNORES Task cancellation (the mux turn — the exact b230
    /// lost-response hang). The deadline must resume the caller anyway; a
    /// group-structured race would await the hung child forever and fail this test.
    func testDeadlineBoundsANonCancellableHang() async {
        let start = Date()
        let result = await SpeakerConfirmFlow.run(
            captureId: "cap-1", slot: "speaker_1", baseDir: dir, deadline: 0.2,
            ship: {
                // Parks forever; never observes cancellation (unlike Task.sleep).
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return ConfirmOutcome(captureId: "", slotLabel: "", status: "",
                                      speakerId: "", speakerName: "")
            })
        XCTAssertEqual(result, .failure(.unreachable))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5,
                          "a non-cancellable transport hang must not defeat the deadline")
        XCTAssertEqual(SpeakerConfirmQueue.pending(baseDir: dir).count, 1,
                       "the intent stays queued for the drain")
    }

    func testFailureCopySaysSavedOnPhone() {
        for failure: SpeakerConfirmFailure in [.authExpired, .unreachable, .rejected(500)] {
            let copy = SpeakerConfirmPresentation.failureCopy(failure)
            XCTAssertTrue(copy.message.lowercased().contains("saved on your phone"),
                          "\(failure): honest copy must say where the change lives")
        }
    }

    // MARK: sheet reaction

    func testSheetReactionDismissesOnPlainSuccess() {
        XCTAssertEqual(SpeakerConfirmPresentation.sheetReaction(.success(outcome())), .dismiss)
    }

    func testSheetReactionShowsOfferWhenPastCapturesMatched() {
        let offered = outcome(offered: [OfferedCapture(captureId: "cap-2", slotLabel: "speaker_0", score: 0.9)])
        XCTAssertEqual(SpeakerConfirmPresentation.sheetReaction(.success(offered)),
                       .showOffer(offered))
    }

    func testSheetReactionStaysOpenOnFailure() {
        XCTAssertEqual(SpeakerConfirmPresentation.sheetReaction(.failure(.unreachable)),
                       .stayOpen(.unreachable))
    }

    // MARK: controller phases

    @MainActor
    func testControllerFlipsToInFlightImmediatelyThenConfirmed() async throws {
        let controller = SpeakerConfirmController(baseDir: dir, deadline: 5, successDwell: 0.05)
        let gate = ShipGate()
        let expected = outcome()
        var confirmedOutcome: ConfirmOutcome?
        let task = Task { @MainActor in
            await controller.confirm(
                captureId: "cap-1", slot: "speaker_1",
                ship: { await gate.wait(); return expected },
                onConfirmed: { confirmedOutcome = $0 })
        }
        // The tap must read as in-flight BEFORE the ship resolves.
        var sawInFlight = false
        for _ in 0..<200 where !sawInFlight {
            if controller.phase(for: "speaker_1") == .inFlight { sawInFlight = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(sawInFlight, "phase must be .inFlight while the round trip runs")
        await gate.open()
        let resolved = await task.value
        XCTAssertEqual(resolved, .confirmed)
        XCTAssertEqual(confirmedOutcome, expected, "optimistic hook fires on acknowledgment")
        XCTAssertTrue(SpeakerConfirmQueue.pending(baseDir: dir).isEmpty)
        // The confirmed check lingers briefly, then clears back to the row's rendering.
        var cleared = false
        for _ in 0..<200 where !cleared {
            if controller.phase(for: "speaker_1") == .idle { cleared = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(cleared, "the transient confirmed phase must clear after its dwell")
    }

    @MainActor
    func testControllerFailurePhaseIsSticky() async {
        let controller = SpeakerConfirmController(baseDir: dir, deadline: 5)
        let resolved = await controller.confirm(
            captureId: "cap-1", slot: "speaker_1",
            ship: { throw DoorError.transport("down") })
        XCTAssertEqual(resolved, .failed(.unreachable))
        XCTAssertEqual(controller.phase(for: "speaker_1"), .failed(.unreachable),
                       "a failure stays visible until the user retries or moves on")
    }

    // MARK: drain

    func testDrainStopsAndSignalsOnAuthExpired() async {
        SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_0", baseDir: dir)
        SpeakerConfirmQueue.enqueue(captureId: "cap-2", slot: "speaker_1", baseDir: dir)
        let calls = Counter()
        var authExpired = false
        await SpeakerConfirmFlow.drainPending(
            baseDir: dir,
            ship: { _ in await calls.bump(); throw DoorError.unauthorized },
            onAuthExpired: { authExpired = true })
        let shipCalls = await calls.value
        XCTAssertEqual(shipCalls, 1, "a 401 must stop the pass, not hammer every entry")
        XCTAssertTrue(authExpired, "the re-auth seam must fire instead of a silent loop")
        XCTAssertEqual(SpeakerConfirmQueue.pending(baseDir: dir).count, 2,
                       "the confirms are kept for after re-authentication")
    }

    func testDrainShipsAndDequeuesOnSuccess() async {
        SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_0", baseDir: dir)
        SpeakerConfirmQueue.enqueue(captureId: "cap-2", slot: "speaker_1", baseDir: dir)
        await SpeakerConfirmFlow.drainPending(
            baseDir: dir, ship: { _ in }, onAuthExpired: { XCTFail("no auth failure here") })
        XCTAssertTrue(SpeakerConfirmQueue.pending(baseDir: dir).isEmpty)
    }
}

/// Async-safe manual gate: `wait()` suspends until `open()`.
actor ShipGate {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func open() {
        opened = true
        continuations.forEach { $0.resume() }
        continuations = []
    }
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }
}

actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
