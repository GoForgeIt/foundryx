import XCTest
@testable import FoundryXKit

/// OmiOfflineSyncEngine — the ring-sync state machine against a MOCKED link
/// (recorded commands + frames; no CoreBluetooth).
final class OmiOfflineSyncTests: XCTestCase {

    private final class MockLink {
        var commands: [OmiOfflineSyncEngine.Command] = []
        var frames: [Data] = []
        var outcome: OmiOfflineSyncEngine.Outcome?
        var finishCount = 0

        func wire(_ e: OmiOfflineSyncEngine) {
            e.emit = { [weak self] in self?.commands.append($0) }
            e.emitFrame = { [weak self] in self?.frames.append($0) }
            e.finished = { [weak self] in self?.outcome = $0; self?.finishCount += 1 }
        }
    }

    private func makeEngine() -> (OmiOfflineSyncEngine, MockLink) {
        let e = OmiOfflineSyncEngine()
        let link = MockLink()
        link.wire(e)
        return (e, link)
    }

    private func status(unread: UInt32) -> Data {
        OmiRingProtocolTests.statusBytes(used: unread * 444, unread: unread, free: 1_000_000, rtc: 1)
    }

    // MARK: happy path

    func testFullSyncHappyPath() {
        let (e, link) = makeEngine()
        e.begin()
        XCTAssertEqual(link.commands, [.readStatus])

        e.statusResult(status(unread: 3))
        XCTAssertEqual(link.commands, [.readStatus, .requestInfo])

        e.notification(OmiRingProtocolTests.infoBytes(readSeq: 10, writeSeq: 13, capacity: 4096, dropped: 0, packetSize: 444))
        XCTAssertEqual(link.commands.last, .read(startSeq: 10))

        e.notification(OmiRingProtocolTests.readBeginBytes(startSeq: 10, count: 3))

        // Three records, streamed as 0x03-prefixed unaligned chunks.
        let records = OmiRingProtocolTests.record(ts: 100, frames: [[1, 1], [2, 2]])
            + OmiRingProtocolTests.record(ts: 101, frames: [[3, 3]])
            + OmiRingProtocolTests.record(ts: 102, frames: [[4], [5], [6]])
        var idx = records.startIndex
        while idx < records.endIndex {
            let end = records.index(idx, offsetBy: min(180, records.distance(from: idx, to: records.endIndex)))
            e.notification(Data([0x03]) + records[idx..<end])
            idx = end
        }
        XCTAssertEqual(link.frames, [Data([1, 1]), Data([2, 2]), Data([3, 3]), Data([4]), Data([5]), Data([6])],
                       "gap frames must come out in recorded order")

        e.notification(OmiRingProtocolTests.doneBytes(status: 0, nextSeq: 13))
        XCTAssertEqual(link.commands.last, .advance(seq: 13), "advance to the firmware's nextSeq — the dedupe point")
        XCTAssertNil(link.outcome, "not settled until the advance is ACK'd")

        e.notification(Data([0x01, 0x00]))   // ACK ok
        XCTAssertEqual(link.outcome, .synced(records: 3, frames: 6))
        XCTAssertEqual(link.finishCount, 1)
        XCTAssertFalse(e.isActive)
    }

    // MARK: empty / unsupported

    func testNothingToSyncWhenRingEmpty() {
        let (e, link) = makeEngine()
        e.begin()
        e.statusResult(status(unread: 0))
        XCTAssertEqual(link.outcome, .nothingToSync)
        XCTAssertEqual(link.commands, [.readStatus], "no info/read issued for an empty ring")
    }

    func testOldFirmwareStatusSkipsSync() {
        let (e, link) = makeEngine()
        e.begin()
        e.statusResult(Data([1, 2, 3, 4]))   // not ring-shaped
        guard case .unsupportedProtocol = link.outcome else {
            return XCTFail("expected unsupportedProtocol, got \(String(describing: link.outcome))")
        }
        XCTAssertEqual(link.commands, [.readStatus])
    }

    func testStatusReadFailureFails() {
        let (e, link) = makeEngine()
        e.begin()
        e.statusResult(nil)
        XCTAssertEqual(link.outcome, .failed("storage status read failed"))
    }

    func testInfoWithNoUnreadSpanSettlesEmpty() {
        let (e, link) = makeEngine()
        e.begin()
        e.statusResult(status(unread: 5))
        e.notification(OmiRingProtocolTests.infoBytes(readSeq: 9, writeSeq: 9, capacity: 64, dropped: 0, packetSize: 444))
        XCTAssertEqual(link.outcome, .nothingToSync)
    }

    // MARK: aborts — never lose, never double-pull

    func testStallBeforeAnyRecordFailsWithoutAdvance() {
        let (e, link) = makeEngine()
        e.begin()
        e.statusResult(status(unread: 2))
        e.stalled()
        XCTAssertEqual(link.outcome, .failed("stalled (no storage activity)"))
        XCTAssertFalse(link.commands.contains { if case .advance = $0 { return true }; return false },
                       "nothing consumed ⇒ NO advance — the device keeps its unread cache")
        XCTAssertTrue(link.commands.contains(.stopTransfer))
    }

    func testAbortMidTransferAdvancesOnlyOverConsumedRecords() {
        let (e, link) = makeEngine()
        e.begin()
        e.statusResult(status(unread: 10))
        e.notification(OmiRingProtocolTests.infoBytes(readSeq: 40, writeSeq: 50, capacity: 64, dropped: 0, packetSize: 444))
        e.notification(OmiRingProtocolTests.readBeginBytes(startSeq: 40, count: 10))
        let two = OmiRingProtocolTests.record(ts: 1, frames: [[7]]) + OmiRingProtocolTests.record(ts: 2, frames: [[8]])
        e.notification(Data([0x03]) + two)
        XCTAssertEqual(link.frames.count, 2)

        e.budgetExhausted()
        XCTAssertTrue(link.commands.contains(.stopTransfer))
        XCTAssertEqual(link.commands.last, .advance(seq: 42), "advance EXACTLY past the 2 fully-consumed records")
        XCTAssertEqual(link.outcome, .aborted(records: 2, frames: 2, reason: "sync budget exhausted"))
    }

    func testLinkDropMidTransferNeverAdvances() {
        let (e, link) = makeEngine()
        e.begin()
        e.statusResult(status(unread: 4))
        e.notification(OmiRingProtocolTests.infoBytes(readSeq: 0, writeSeq: 4, capacity: 64, dropped: 0, packetSize: 444))
        e.notification(Data([0x03]) + OmiRingProtocolTests.record(ts: 1, frames: [[1]]))
        e.linkDropped()
        XCTAssertEqual(link.outcome, .aborted(records: 1, frames: 1, reason: "link dropped"))
        XCTAssertFalse(link.commands.contains { if case .advance = $0 { return true }; return false },
                       "no link ⇒ no advance write is possible; prefer re-pull over blind advance")
        XCTAssertFalse(link.commands.contains(.stopTransfer), "no link ⇒ nothing to write")
    }

    func testFirmwareClampedReadBeginRebasesAdvance() {
        // The firmware may clamp our start seq (ring overwrote it). The abort-advance
        // must be based on the CLAMPED start, not what we asked for.
        let (e, link) = makeEngine()
        e.begin()
        e.statusResult(status(unread: 8))
        e.notification(OmiRingProtocolTests.infoBytes(readSeq: 100, writeSeq: 108, capacity: 64, dropped: 4, packetSize: 444))
        e.notification(OmiRingProtocolTests.readBeginBytes(startSeq: 104, count: 4))   // clamped
        e.notification(Data([0x03]) + OmiRingProtocolTests.record(ts: 1, frames: [[1]]))
        e.budgetExhausted()
        XCTAssertEqual(link.commands.last, .advance(seq: 105))
    }

    // MARK: robustness

    func testIgnoresUnknownOpcodesAndDataOutsideTransfer() {
        let (e, link) = makeEngine()
        e.begin()
        e.statusResult(status(unread: 1))
        e.notification(Data([0xEE, 1, 2, 3]))                         // unknown opcode
        e.notification(Data([0x03]) + Data(repeating: 9, count: 50))  // data before transfer began
        XCTAssertEqual(link.frames, [])
        XCTAssertNil(link.outcome)
        XCTAssertTrue(e.isActive)
    }

    func testFinishedFiresExactlyOnce() {
        let (e, link) = makeEngine()
        e.begin()
        e.statusResult(status(unread: 0))
        e.stalled()
        e.linkDropped()
        e.budgetExhausted()
        XCTAssertEqual(link.finishCount, 1)
    }

    func testBeginIsIdempotent() {
        let (e, link) = makeEngine()
        e.begin()
        e.begin()
        XCTAssertEqual(link.commands, [.readStatus])
    }
}
