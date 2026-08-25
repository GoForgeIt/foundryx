import XCTest
@testable import FoundryXKit

/// Unit coverage for the LOCAL-FIRST speaker-confirm seam (track 20260717T1600):
/// the pending overlay (render truth), the ts-guarded dequeue (latest-wins integrity),
/// the background ship + drain disposition classification, the cache write-through, and
/// the local-first phase controller.
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

    private func outcome(name: String = "Nick", offered: [OfferedCapture] = []) -> ConfirmOutcome {
        ConfirmOutcome(captureId: "cap-1", slotLabel: "speaker_1", status: "confirmed",
                       speakerId: "sp-9", speakerName: name, offeredCaptures: offered)
    }

    private func inferredTranscript(name: String? = "Alex") -> SpeakerTranscript {
        // Strong confidence (≥ the reveal floor) so the inferred name renders under the
        // reveal gate; the overlay then flips the slot to confirmed (always revealed).
        SpeakerTranscript(
            speakers: [CaptureSpeaker(slot: "speaker_1", status: .inferred, name: name, inferScore: 0.92)],
            segments: [TranscriptSegment(seq: 0, text: "Hi.", speaker: "speaker_1")])
    }

    private func entry(slot: String = "speaker_1", name: String? = nil,
                       speakerId: String? = nil, ts: UInt64 = 1) -> SpeakerConfirmQueue.Entry {
        SpeakerConfirmQueue.Entry(captureId: "cap-1", slot: slot, name: name, speakerId: speakerId, ts: ts)
    }

    // MARK: pending overlay (the local render truth)

    func testOverlayNamedConfirmRendersTheSavedName() {
        let rendered = inferredTranscript().applyingPendingConfirms([entry(name: "Dana")])
        XCTAssertEqual(rendered.displayLabel(for: "speaker_1"), "Dana")
        XCTAssertTrue(rendered.speaker(for: "speaker_1").isConfirmed)
    }

    func testOverlayBareConfirmKeepsTheInferredName() {
        // A bare confirm (no typed name) keeps the inferred label but flips to confirmed.
        let rendered = inferredTranscript(name: "Alex").applyingPendingConfirms([entry(name: nil)])
        XCTAssertEqual(rendered.displayLabel(for: "speaker_1"), "Alex")
        XCTAssertTrue(rendered.speaker(for: "speaker_1").isConfirmed)
    }

    func testOverlayForAnUnknownSlotAppendsAConfirmedSpeaker() {
        let base = SpeakerTranscript(
            speakers: [], segments: [TranscriptSegment(seq: 0, text: "Hi.", speaker: "speaker_1")])
        let rendered = base.applyingPendingConfirms([entry(name: "Dana", speakerId: "sp-1")])
        XCTAssertEqual(rendered.displayLabel(for: "speaker_1"), "Dana")
        XCTAssertTrue(rendered.speaker(for: "speaker_1").isConfirmed)
    }

    func testOverlayEmptyIsIdentity() {
        let base = inferredTranscript()
        XCTAssertEqual(base.applyingPendingConfirms([]), base)
    }

    // MARK: ts-guarded remove (latest-wins integrity)

    func testTsGuardedRemoveKeepsANewerEntry() {
        // An OLD ship's ACK (its ts) must not dequeue a NEWER rename made meanwhile.
        let oldTs = SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_1",
                                                name: "Nic", baseDir: dir)
        let newTs = SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_1",
                                                name: "Nicholas", baseDir: dir)
        XCTAssertNotEqual(oldTs, newTs, "each enqueue mints a distinct ts")
        SpeakerConfirmQueue.remove(captureId: "cap-1", slot: "speaker_1", ifTsMatches: oldTs, baseDir: dir)
        let pending = SpeakerConfirmQueue.pending(baseDir: dir)
        XCTAssertEqual(pending.count, 1, "the newer rename survives a stale ACK")
        XCTAssertEqual(pending.first?.name, "Nicholas")
    }

    func testTsGuardedRemoveDropsTheMatchingEntry() {
        let ts = SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_1", name: "Dana", baseDir: dir)
        SpeakerConfirmQueue.remove(captureId: "cap-1", slot: "speaker_1", ifTsMatches: ts, baseDir: dir)
        XCTAssertTrue(SpeakerConfirmQueue.pending(baseDir: dir).isEmpty)
    }

    // MARK: confirm intent (review P1 — a typed name must never ride the old speakerId)

    func testIntentTypedNameIsNameOnly() {
        // Renaming a tentatively-matched speaker: ship the NAME only. Lore resolves
        // speakerId OVER name, so carrying the old id would silently confirm the wrong
        // speaker and drop the typed name.
        let speaker = CaptureSpeaker(slot: "speaker_1", status: .inferred, name: "Alex",
                                     inferScore: 0.8, inferredSpeakerId: "sp-alex")
        let intent = SpeakerConfirmIntent.make(typedName: "Dana", speaker: speaker)
        XCTAssertEqual(intent.name, "Dana")
        XCTAssertNil(intent.speakerId, "a typed name must not ride the inferred speakerId")
    }

    func testIntentTypedNameEqualToInferredIsStillNameOnly() {
        // Even typing the SAME name as the inference is a name-only confirm (a harmless
        // merge-by-name), never the id path.
        let speaker = CaptureSpeaker(slot: "speaker_1", status: .inferred, name: "Alex",
                                     inferScore: 0.8, inferredSpeakerId: "sp-alex")
        let intent = SpeakerConfirmIntent.make(typedName: "Alex", speaker: speaker)
        XCTAssertEqual(intent.name, "Alex")
        XCTAssertNil(intent.speakerId)
    }

    func testIntentBlankNameIsABareConfirmOnTheInferredId() {
        // No typed name (blank/whitespace) = bare confirm of the existing match: ship the
        // known speakerId, no name.
        let speaker = CaptureSpeaker(slot: "speaker_1", status: .inferred, name: "Alex",
                                     inferScore: 0.8, inferredSpeakerId: "sp-alex")
        for blank in [nil, "", "   "] as [String?] {
            let intent = SpeakerConfirmIntent.make(typedName: blank, speaker: speaker)
            XCTAssertNil(intent.name)
            XCTAssertEqual(intent.speakerId, "sp-alex")
        }
    }

    func testIntentBareConfirmPrefersConfirmedIdOverInferred() {
        let speaker = CaptureSpeaker(slot: "speaker_1", status: .confirmed, name: "Alex",
                                     confirmedSpeakerId: "sp-confirmed")
        let intent = SpeakerConfirmIntent.make(typedName: nil, speaker: speaker)
        XCTAssertEqual(intent.speakerId, "sp-confirmed")
    }

    // MARK: late-offer surfacing (review P2#2 — no double-surface behind the sheet)

    func testLateOfferSuppressedWhileSheetPresenting() {
        XCTAssertFalse(SpeakerLateOffer.shouldSurface(offeredCount: 3, sheetPresenting: true),
                       "the sheet owns the offer within its flash window — no late banner")
        XCTAssertTrue(SpeakerLateOffer.shouldSurface(offeredCount: 3, sheetPresenting: false),
                      "after the sheet dismissed, the late banner surfaces the offer")
        XCTAssertFalse(SpeakerLateOffer.shouldSurface(offeredCount: 0, sheetPresenting: false),
                       "no offer, no banner")
    }

    // MARK: monotonic ts (review P3#4 — enqueueAll shares the strictly-increasing mint)

    func testEnqueueAllMintsMonotonicTimestamps() {
        // A bulk apply immediately followed by an interactive rename on the same slot must
        // hand out a STRICTLY GREATER ts, so a stale bulk ACK can't dequeue the rename.
        SpeakerConfirmQueue.enqueueAll(
            [(captureId: "cap-1", slot: "speaker_1", speakerId: "sp-x")], baseDir: dir)
        let bulkTs = SpeakerConfirmQueue.pending(baseDir: dir).first { $0.slot == "speaker_1" }?.ts
        let renameTs = SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_1",
                                                   name: "Dana", baseDir: dir)
        XCTAssertNotNil(bulkTs)
        XCTAssertGreaterThan(renameTs, bulkTs!, "the later enqueue's ts must strictly exceed the bulk ts")
    }

    // MARK: ship disposition classification

    func testClassifyMapsErrorsToDispositions() {
        XCTAssertEqual(SpeakerShipDisposition.classify(DoorError.unauthorized), .authExpired)
        XCTAssertEqual(SpeakerShipDisposition.classify(DoorError.http(400)), .rejected(400))
        XCTAssertEqual(SpeakerShipDisposition.classify(DoorError.http(404)), .rejected(404))
        XCTAssertEqual(SpeakerShipDisposition.classify(DoorError.http(500)), .transient,
                       "5xx is transient — the Mac is up but momentarily unhappy; retry")
        XCTAssertEqual(SpeakerShipDisposition.classify(DoorError.transport("x")), .transient)
    }

    // MARK: background ship (the interactive silent sync leg)

    func testBackgroundShipAckDequeuesWritesThroughAndPostsSynced() async {
        // A cache exists so the write-through has something to update.
        TranscriptCacheStore.save(
            CachedTranscript(transcript: "Hi.", title: nil, summary: nil,
                             segments: [TranscriptSegment(seq: 0, text: "Hi.", speaker: "speaker_1")],
                             speakers: [CaptureSpeaker(slot: "speaker_1", status: .inferred, name: "Alex")],
                             fetchedAt: 0),
            captureId: "cap-1", baseDir: dir)
        let ts = SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_1", name: "Dana", baseDir: dir)
        let ok = outcome(name: "Dana")
        let baseDir = dir!
        let synced = await awaitingSynced {
            await SpeakerConfirmFlow.backgroundShip(
                captureId: "cap-1", slot: "speaker_1", name: "Dana", speakerId: nil,
                ts: ts, baseDir: baseDir, ship: { ok })
        }
        XCTAssertEqual(synced?.speakerName, "Dana", "the synced notification carries the outcome")
        XCTAssertTrue(SpeakerConfirmQueue.pending(baseDir: dir).isEmpty, "the ACK dequeues the intent")
        let cached = TranscriptCacheStore.load(captureId: "cap-1", baseDir: dir)
        XCTAssertEqual(cached?.speakers.first(where: { $0.slot == "speaker_1" })?.name, "Dana",
                       "the ACK writes the confirmed name through to the cache")
        XCTAssertEqual(cached?.speakers.first(where: { $0.slot == "speaker_1" })?.status, .confirmed)
    }

    func testBackgroundShipRejectDropsAndPostsRejected() async {
        let ts = SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_1", name: "Dana", baseDir: dir)
        var rejectedName: String?
        let obs = NotificationCenter.default.addObserver(
            forName: .foundryxSpeakerConfirmRejected, object: nil, queue: .main) { note in
                rejectedName = note.userInfo?["name"] as? String
            }
        defer { NotificationCenter.default.removeObserver(obs) }
        let result = await SpeakerConfirmFlow.backgroundShip(
            captureId: "cap-1", slot: "speaker_1", name: "Dana", speakerId: nil,
            ts: ts, baseDir: dir, ship: { throw DoorError.http(400) })
        XCTAssertNil(result, "a rejection yields no reconcilable outcome")
        XCTAssertTrue(SpeakerConfirmQueue.pending(baseDir: dir).isEmpty, "a rejection drops the intent")
        // Give the main-queue notification a beat to deliver.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rejectedName, "Dana")
    }

    func testBackgroundShipTransientKeepsQueued() async {
        let ts = SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_1", name: "Dana", baseDir: dir)
        let result = await SpeakerConfirmFlow.backgroundShip(
            captureId: "cap-1", slot: "speaker_1", name: "Dana", speakerId: nil,
            ts: ts, baseDir: dir, ship: { throw DoorError.transport("down") })
        XCTAssertNil(result)
        XCTAssertEqual(SpeakerConfirmQueue.pending(baseDir: dir).count, 1,
                       "an unreachable Mac keeps the intent for the drain to re-ship")
    }

    func testBackgroundShipDeadlineIsTransientAndKeepsQueued() async {
        let ts = SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_1", name: "Dana", baseDir: dir)
        let ok = outcome()
        let start = Date()
        let result = await SpeakerConfirmFlow.backgroundShip(
            captureId: "cap-1", slot: "speaker_1", name: "Dana", speakerId: nil,
            ts: ts, baseDir: dir, deadline: 0.2,
            ship: {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }   // never cancellable
                return ok
            })
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the deadline must bound a hung ship")
        XCTAssertEqual(SpeakerConfirmQueue.pending(baseDir: dir).count, 1, "the intent stays queued")
    }

    /// The sheet's fast-network offer window: a background ACK that carries offers surfaces
    /// them (the sheet transitions to the offer instead of dismissing).
    func testBackgroundShipSurfacesAnOffer() async {
        let ts = SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_1", name: "Dana", baseDir: dir)
        let offered = [OfferedCapture(captureId: "cap-2", slotLabel: "speaker_0", score: 0.9)]
        let ok = outcome(name: "Dana", offered: offered)
        let result = await SpeakerConfirmFlow.backgroundShip(
            captureId: "cap-1", slot: "speaker_1", name: "Dana", speakerId: nil,
            ts: ts, baseDir: dir, ship: { ok })
        XCTAssertEqual(result?.offeredCaptures.count, 1, "the offer is available within the flash window")
    }

    // MARK: write-through helper

    func testWriteThroughIsNoOpWithoutACache() {
        // No cache saved for cap-1 → nothing to write through, no crash, no file created.
        TranscriptCacheStore.confirmSpeaker(captureId: "cap-1", slot: "speaker_1",
                                            name: "Dana", speakerId: "sp-9", baseDir: dir)
        XCTAssertNil(TranscriptCacheStore.load(captureId: "cap-1", baseDir: dir))
    }

    // MARK: drain classification

    func testDrainSyncsAndContinues() async {
        SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_0", baseDir: dir)
        SpeakerConfirmQueue.enqueue(captureId: "cap-2", slot: "speaker_1", baseDir: dir)
        let synced = Counter()
        let ok = outcome()
        await SpeakerConfirmFlow.drainPending(
            baseDir: dir, ship: { _ in ok },
            onSynced: { _, _ in await synced.bump() },
            onAuthExpired: { XCTFail("no auth failure here") })
        XCTAssertTrue(SpeakerConfirmQueue.pending(baseDir: dir).isEmpty)
        let count = await synced.value
        XCTAssertEqual(count, 2, "every synced entry fires onSynced and is dequeued")
    }

    func testDrainRejectDropsAndContinues() async {
        SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_0", name: "bad", baseDir: dir)
        SpeakerConfirmQueue.enqueue(captureId: "cap-2", slot: "speaker_1", name: "good", baseDir: dir)
        let rejected = Counter()
        let synced = Counter()
        let ok = outcome()
        await SpeakerConfirmFlow.drainPending(
            baseDir: dir,
            ship: { e in
                if e.name == "bad" { throw DoorError.http(422) }
                return ok
            },
            onSynced: { _, _ in await synced.bump() },
            onRejected: { _ in await rejected.bump() },
            onAuthExpired: { XCTFail("no auth failure here") })
        let r = await rejected.value, s = await synced.value
        XCTAssertEqual(r, 1, "the rejected entry is dropped")
        XCTAssertEqual(s, 1, "the drain CONTINUES past a rejection to the good entry")
        XCTAssertTrue(SpeakerConfirmQueue.pending(baseDir: dir).isEmpty, "both entries resolved")
    }

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

    func testDrainStopsOnTransientAndKeepsQueued() async {
        SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_0", baseDir: dir)
        SpeakerConfirmQueue.enqueue(captureId: "cap-2", slot: "speaker_1", baseDir: dir)
        let calls = Counter()
        await SpeakerConfirmFlow.drainPending(
            baseDir: dir,
            ship: { _ in await calls.bump(); throw DoorError.transport("down") },
            onAuthExpired: { XCTFail("transport is not auth") })
        let shipCalls = await calls.value
        XCTAssertEqual(shipCalls, 1, "a transport failure stops the pass (retry next drain)")
        XCTAssertEqual(SpeakerConfirmQueue.pending(baseDir: dir).count, 2, "nothing lost")
    }

    // MARK: controller (local-first phases)

    @MainActor
    func testControllerSavesLocallyWithoutWaitingOnTheWire() async throws {
        let controller = SpeakerConfirmController(baseDir: dir, deadline: 5, successDwell: 0.05)
        var confirmedOutcome: ConfirmOutcome?
        let ok = outcome(name: "Dana")
        let start = Date()
        // A ship that never answers within the test — the local save must NOT wait on it.
        let resolved = await controller.confirm(
            captureId: "cap-1", slot: "speaker_1", name: "Dana",
            ship: {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return ok
            },
            onConfirmed: { confirmedOutcome = $0 })
        // ⚠ CHANGED WITH AC5b, AND THE OLD EXPECTATION ENCODED THE DEFECT. This asserted
        // `.confirmed` -- "the local save resolves to confirmed immediately" -- which is
        // exactly what made a confirmation that NEVER REACHED the Mac indistinguishable from
        // one that did. The save is still local-first and still does not block on the wire
        // (the next assertion); what it no longer does is CLAIM the second place has it.
        XCTAssertEqual(resolved, .pendingSync, "a local save is not a landing")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "the save must not block on the wire")
        XCTAssertEqual(confirmedOutcome?.speakerName, "Dana", "the optimistic hook fires with the local outcome")
        XCTAssertEqual(SpeakerConfirmQueue.pending(baseDir: dir).count, 1,
                       "the intent is durably queued for the background ship")
        // ⚠ AND IT MUST NOT CLEAR. The dwell clears a `.confirmed` check back to the row's
        // own rendering, which is right for a LANDED confirmation. This ship never returns, so
        // the row stays `pendingSync` -- if it cleared on a timer the owner would be left with
        // a row that looks settled while nothing ever reached the Mac.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.phase(for: "speaker_1"), .pendingSync,
                       "an unshipped confirmation keeps saying so; it does not time out into silence")
    }

    @MainActor
    func testControllerBackgroundAckDequeues() async throws {
        let controller = SpeakerConfirmController(baseDir: dir, deadline: 5, successDwell: 0.05)
        let ok = outcome(name: "Dana")
        _ = await controller.confirm(
            captureId: "cap-1", slot: "speaker_1", name: "Dana",
            ship: { ok })
        // The background ship (detached) ACKs and dequeues — poll for it.
        var dequeued = false
        for _ in 0..<200 where !dequeued {
            if SpeakerConfirmQueue.pending(baseDir: dir).isEmpty { dequeued = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(dequeued, "the background ACK dequeues the intent")
    }

    // MARK: helpers

    /// Run `body` and return the ConfirmOutcome delivered by a `foundryxSpeakerConfirmSynced`
    /// notification during it (nil if none arrived).
    private func awaitingSynced(_ body: () async -> Void) async -> ConfirmOutcome? {
        final class Box: @unchecked Sendable { var value: ConfirmOutcome? }
        let box = Box()
        let obs = NotificationCenter.default.addObserver(
            forName: .foundryxSpeakerConfirmSynced, object: nil, queue: .main) { note in
                box.value = note.userInfo?["outcome"] as? ConfirmOutcome
            }
        defer { NotificationCenter.default.removeObserver(obs) }
        await body()
        for _ in 0..<40 where box.value == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return box.value
    }
}

actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
