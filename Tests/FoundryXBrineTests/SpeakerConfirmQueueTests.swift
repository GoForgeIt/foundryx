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
}
