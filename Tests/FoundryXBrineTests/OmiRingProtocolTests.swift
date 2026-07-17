import XCTest
@testable import FoundryXKit

/// OmiRingProtocol codec — byte-exact vectors built from the firmware's wire shapes
/// (omi firmware storage.c + the reference client ring_protocol.dart).
final class OmiRingProtocolTests: XCTestCase {

    // MARK: builders (the firmware's encoding, independently re-stated)

    static func statusBytes(used: UInt32, unread: UInt32, free: UInt32, rtc: UInt32) -> Data {
        var d = Data()
        for v in [used, unread, free, rtc] {
            d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
        }
        return d
    }

    static func be64(_ v: UInt64) -> [UInt8] { stride(from: 56, through: 0, by: -8).map { UInt8((v >> UInt64($0)) & 0xFF) } }
    static func be32(_ v: UInt32) -> [UInt8] { stride(from: 24, through: 0, by: -8).map { UInt8((v >> UInt32($0)) & 0xFF) } }

    static func infoBytes(readSeq: UInt64, writeSeq: UInt64, capacity: UInt32, dropped: UInt64, packetSize: UInt16) -> Data {
        var b: [UInt8] = [0x02]
        b += be64(readSeq); b += be64(writeSeq); b += be32(capacity); b += be64(dropped)
        b += [UInt8(packetSize >> 8), UInt8(packetSize & 0xFF)]
        return Data(b)
    }

    static func doneBytes(status: UInt8, nextSeq: UInt64) -> Data {
        Data([0x04, status] + be64(nextSeq))
    }

    static func readBeginBytes(startSeq: UInt64, count: UInt32) -> Data {
        Data([0x05] + be64(startSeq) + be32(count))
    }

    /// One 444-byte ring record: [ts u32 BE][440B payload of [size][frame]… + 0-padding].
    static func record(ts: UInt32, frames: [[UInt8]]) -> Data {
        var payload: [UInt8] = []
        for f in frames { payload.append(UInt8(f.count)); payload += f }
        precondition(payload.count < OmiRingProtocol.audioPayloadBytes)
        payload += [UInt8](repeating: 0, count: OmiRingProtocol.audioPayloadBytes - payload.count)
        return Data(be32(ts) + payload)
    }

    // MARK: status

    func testParseStatusLittleEndian() {
        let s = OmiRingProtocol.parseStatus(Self.statusBytes(used: 0x01020304, unread: 42, free: 7, rtc: 1))
        XCTAssertEqual(s, .init(usedBytes: 0x01020304, unreadPackets: 42, freeBytes: 7, rtcValid: 1))
    }

    func testParseStatusTooShortIsNil() {
        // An old-firmware storage protocol answers with a different (shorter/other)
        // shape — the caller must SKIP sync, never misread it.
        XCTAssertNil(OmiRingProtocol.parseStatus(Data([1, 2, 3, 4, 5, 6, 7, 8])))
        XCTAssertNil(OmiRingProtocol.parseStatus(Data()))
    }

    // MARK: info / done / read-begin / ack

    func testParseInfoBigEndian() {
        let i = OmiRingProtocol.parseInfo(Self.infoBytes(readSeq: 100, writeSeq: 250, capacity: 4096, dropped: 3, packetSize: 444))
        XCTAssertEqual(i?.readSeq, 100)
        XCTAssertEqual(i?.writeSeq, 250)
        XCTAssertEqual(i?.capacityPackets, 4096)
        XCTAssertEqual(i?.droppedPackets, 3)
        XCTAssertEqual(i?.packetSize, 444)
    }

    func testParseInfoRejectsWrongOpcodeOrTruncation() {
        var bad = Self.infoBytes(readSeq: 1, writeSeq: 2, capacity: 3, dropped: 0, packetSize: 444)
        bad[bad.startIndex] = 0x03
        XCTAssertNil(OmiRingProtocol.parseInfo(bad))
        XCTAssertNil(OmiRingProtocol.parseInfo(Self.infoBytes(readSeq: 1, writeSeq: 2, capacity: 3, dropped: 0, packetSize: 444).prefix(30)))
    }

    func testParseDone() {
        let d = OmiRingProtocol.parseDone(Self.doneBytes(status: 0, nextSeq: 0xDEADBEEF))
        XCTAssertEqual(d?.nextSeq, 0xDEADBEEF)
        XCTAssertEqual(d?.isOk, true)
        XCTAssertEqual(OmiRingProtocol.parseDone(Self.doneBytes(status: 9, nextSeq: 5))?.isOk, false)
        XCTAssertNil(OmiRingProtocol.parseDone(Data([0x04, 0])))   // truncated
    }

    func testParseReadBegin() {
        let rb = OmiRingProtocol.parseReadBegin(Self.readBeginBytes(startSeq: 77, count: 12))
        XCTAssertEqual(rb?.transferStartSeq, 77)
        XCTAssertEqual(rb?.packetCount, 12)
    }

    func testParseAck() {
        XCTAssertEqual(OmiRingProtocol.parseAck(Data([0x01, 0x00])), 0)
        XCTAssertEqual(OmiRingProtocol.parseAck(Data([0x01, 0x09])), 9)
        XCTAssertNil(OmiRingProtocol.parseAck(Data([0x02, 0x00])))
    }

    // MARK: commands

    func testCommandEncodings() {
        XCTAssertEqual(OmiRingProtocol.readCommand(startSeq: 0x0102030405060708),
                       Data([0x11, 1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertEqual(OmiRingProtocol.readCommand(startSeq: 1, packetCount: 2),
                       Data([0x11, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2]))
        XCTAssertEqual(OmiRingProtocol.advanceCommand(newReadSeq: 0x0A),
                       Data([0x12, 0, 0, 0, 0, 0, 0, 0, 0x0A]))
        XCTAssertEqual(OmiRingProtocol.infoCommand, Data([0x10]))
        XCTAssertEqual(OmiRingProtocol.stopCommand, Data([0x03]))
    }

    // MARK: audio payload

    func testParseAudioPayloadFramesAndPadding() {
        let f1: [UInt8] = [0xAA, 0xBB, 0xCC]
        let f2: [UInt8] = [0x11, 0x22]
        var payload: [UInt8] = [3] + f1 + [0, 0] + [2] + f2   // zero padding between frames
        payload += [UInt8](repeating: 0, count: OmiRingProtocol.audioPayloadBytes - payload.count)
        let frames = OmiRingProtocol.parseAudioPayload(Data(payload))
        XCTAssertEqual(frames, [Data(f1), Data(f2)])
    }

    func testParseAudioPayloadBoundaryOverflowRule() {
        // Firmware rule: a trailing size byte whose frame would cross the block
        // boundary is STALE (the frame went to the next block) — must not be parsed.
        var payload = [UInt8](repeating: 0, count: OmiRingProtocol.audioPayloadBytes)
        payload[OmiRingProtocol.audioPayloadBytes - 3] = 10   // claims 10 bytes; only 2 remain
        XCTAssertEqual(OmiRingProtocol.parseAudioPayload(Data(payload)), [])
        // Exactly-fits is ALSO stale under the firmware's `>=` overflow rule.
        var exact = [UInt8](repeating: 0, count: OmiRingProtocol.audioPayloadBytes)
        exact[OmiRingProtocol.audioPayloadBytes - 3] = 2
        exact[OmiRingProtocol.audioPayloadBytes - 2] = 0x77
        exact[OmiRingProtocol.audioPayloadBytes - 1] = 0x88
        XCTAssertEqual(OmiRingProtocol.parseAudioPayload(Data(exact)), [])
    }

    func testRecordFramesStripsTimestamp() {
        let rec = Self.record(ts: 1_752_700_000, frames: [[1, 2, 3], [4, 5]])
        XCTAssertEqual(OmiRingProtocol.recordTimestamp(rec), 1_752_700_000)
        XCTAssertEqual(OmiRingProtocol.recordFrames(rec), [Data([1, 2, 3]), Data([4, 5])])
    }

    // MARK: reassembler

    func testReassemblerHandlesUnalignedChunks() {
        let r1 = Self.record(ts: 10, frames: [[1, 1]])
        let r2 = Self.record(ts: 11, frames: [[2, 2, 2]])
        let all = r1 + r2
        let re = OmiRingRecordReassembler()
        // Feed in awkward chunk sizes (BLE notifications are MTU-bound, not record-bound).
        var idx = all.startIndex
        for size in [100, 344, 300, 144] {
            let end = all.index(idx, offsetBy: size)
            re.append(all[idx..<end])
            idx = end
        }
        XCTAssertEqual(idx, all.endIndex)
        var records: [Data] = []
        records += re.drainRecords()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(OmiRingProtocol.recordTimestamp(records[0]), 10)
        XCTAssertEqual(OmiRingProtocol.recordTimestamp(records[1]), 11)
        XCTAssertEqual(re.pendingBytes, 0)
    }

    func testReassemblerKeepsPartialTail() {
        let r = Self.record(ts: 1, frames: [[9]])
        let re = OmiRingRecordReassembler()
        re.append(r.prefix(400))
        XCTAssertEqual(re.drainRecords(), [])
        XCTAssertEqual(re.pendingBytes, 400)
        re.append(r.suffix(44))
        XCTAssertEqual(re.drainRecords().count, 1)
    }
}
