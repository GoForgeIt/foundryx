import XCTest
import Foundation
@testable import FoundryXKit

/// Speaker-name confirms survive a hub blip: the intent is written to disk the instant
/// the user acts, retried on the drain, and dropped once it ships — never lost, never a
/// scary error (track 20260710T2030 follow-up).
final class SpeakerConfirmQueueTests: XCTestCase {

    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("scq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testEnqueuePersistsAndRemoveDequeues() throws {
        let dir = try tmp()
        XCTAssertTrue(SpeakerConfirmQueue.pending(baseDir: dir).isEmpty, "starts empty")

        SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "S1", name: "Nick", baseDir: dir)
        SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "S2", speakerId: "spk-9", baseDir: dir)
        let pending = SpeakerConfirmQueue.pending(baseDir: dir)
        XCTAssertEqual(pending.count, 2, "both intents durably queued")
        XCTAssertEqual(pending.first { $0.slot == "S1" }?.name, "Nick")
        XCTAssertEqual(pending.first { $0.slot == "S2" }?.speakerId, "spk-9")

        // A queue survives being re-read from disk (durable across app launches).
        XCTAssertEqual(SpeakerConfirmQueue.pending(baseDir: dir).count, 2)

        // Shipping one dequeues only it.
        SpeakerConfirmQueue.remove(captureId: "cap-1", slot: "S1", baseDir: dir)
        let after = SpeakerConfirmQueue.pending(baseDir: dir)
        XCTAssertEqual(after.map(\.slot), ["S2"], "only the shipped slot is dropped")

        // Draining the last one removes the file entirely (clean empty state).
        SpeakerConfirmQueue.remove(captureId: "cap-1", slot: "S2", baseDir: dir)
        XCTAssertTrue(SpeakerConfirmQueue.pending(baseDir: dir).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SpeakerConfirmQueue.url(baseDir: dir).path),
                       "empty queue leaves no file behind")
    }

    func testLatestIntentPerSlotWins() throws {
        let dir = try tmp()
        // Rename, then rename again before the first shipped: the latest name wins, one entry.
        SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "S1", name: "Nic", baseDir: dir)
        SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "S1", name: "Nicholas", baseDir: dir)
        let pending = SpeakerConfirmQueue.pending(baseDir: dir)
        XCTAssertEqual(pending.count, 1, "de-duped by (captureId, slot)")
        XCTAssertEqual(pending.first?.name, "Nicholas", "latest intent supersedes the earlier one")
    }

    // MARK: - Batch APIs (apply-to-N-past-conversations, collapsed to ONE read/write)

    /// `enqueueAll` records every intent in ONE atomic write; a pre-existing intent for a
    /// touched slot is superseded (latest-wins), never duplicated.
    func testEnqueueAllPersistsAllEntriesLatestWins() throws {
        let dir = try tmp()
        // A stale intent for a slot the batch also touches — must be superseded, not doubled.
        SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "S1", name: "old", baseDir: dir)

        SpeakerConfirmQueue.enqueueAll([
            (captureId: "cap-1", slot: "S1", speakerId: "spk-1"),
            (captureId: "cap-2", slot: "S1", speakerId: "spk-1"),
            (captureId: "cap-3", slot: "S2", speakerId: "spk-1"),
        ], baseDir: dir)

        let pending = SpeakerConfirmQueue.pending(baseDir: dir)
        XCTAssertEqual(pending.count, 3, "all batched intents present, the stale slot superseded (no dup)")
        let byKey = Dictionary(pending.map { ("\($0.captureId)/\($0.slot)", $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byKey["cap-1/S1"]?.speakerId, "spk-1", "batch intent replaced the stale one")
        XCTAssertNil(byKey["cap-1/S1"]?.name, "assign-to-existing batch carries no name")
        XCTAssertEqual(byKey["cap-2/S1"]?.speakerId, "spk-1")
        XCTAssertEqual(byKey["cap-3/S2"]?.speakerId, "spk-1")

        // Durable across a re-read from disk (a single write left a valid file).
        XCTAssertEqual(SpeakerConfirmQueue.pending(baseDir: dir).count, 3)
    }

    /// `removeAll` drops EXACTLY the given keys in one write; unknown keys are ignored and
    /// untouched intents remain.
    func testRemoveAllDropsExactlyTheGivenKeys() throws {
        let dir = try tmp()
        SpeakerConfirmQueue.enqueueAll([
            (captureId: "cap-1", slot: "S1", speakerId: "spk-1"),
            (captureId: "cap-2", slot: "S1", speakerId: "spk-1"),
            (captureId: "cap-3", slot: "S2", speakerId: "spk-1"),
        ], baseDir: dir)

        SpeakerConfirmQueue.removeAll([
            (captureId: "cap-1", slot: "S1"),
            (captureId: "cap-3", slot: "S2"),
            (captureId: "cap-9", slot: "S9"),   // not queued — ignored, no effect
        ], baseDir: dir)

        let remaining = SpeakerConfirmQueue.pending(baseDir: dir)
        XCTAssertEqual(remaining.map { "\($0.captureId)/\($0.slot)" }, ["cap-2/S1"],
                       "exactly the given keys removed; the rest untouched")
    }

    /// Empty batches are inert — they never clobber an existing queue.
    func testBatchEmptyIsNoOp() throws {
        let dir = try tmp()
        SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "S1", name: "Nick", baseDir: dir)
        SpeakerConfirmQueue.enqueueAll([], baseDir: dir)
        XCTAssertEqual(SpeakerConfirmQueue.pending(baseDir: dir).count, 1, "empty enqueueAll leaves the queue untouched")
        SpeakerConfirmQueue.removeAll([], baseDir: dir)
        XCTAssertEqual(SpeakerConfirmQueue.pending(baseDir: dir).count, 1, "empty removeAll leaves the queue untouched")
    }
}
