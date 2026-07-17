// OmiRingProtocol — the Omi wearable's onboard-storage RING protocol (firmware
// 3.0.20+), pure codec. Implemented 1:1 from the vendored Omi repo:
//   client:   omi/app/lib/services/devices/ring_protocol.dart
//   firmware: omi/omi/firmware/omi/src/lib/core/storage.c
//
// The device buffers audio to an SD-backed ring whenever it has NO BLE connection
// (firmware transport.c pusher(): `else if (!conn) → write_to_storage()`). On
// reconnect the app reads the ring STATUS (a plain characteristic read), asks for
// INFO (read/write sequence numbers), streams the unread span with READ, and then
// ADVANCEs the device's read pointer past what it consumed — so nothing is pulled
// twice and nothing unread is ever destroyed (we never send CLEAR).
//
// Wire shapes (all confirmed against the firmware source):
//   status read (control char 30295782): 16B LITTLE-endian
//       [usedBytes:u32][unreadPackets:u32][freeBytes:u32][rtcValid:u32]
//   NOTIFY_INFO  (0x02): ≥31B, BIG-endian
//       [0x02][readSeq:u64][writeSeq:u64][capacityPackets:u32][droppedPackets:u64][packetSize:u16]
//   NOTIFY_READ_BEGIN (0x05): ≥13B [0x05][transferStartSeq:u64 BE][packetCount:u32 BE]
//   NOTIFY_DATA  (0x03): [0x03][raw ring bytes …] — unaligned chunks; reassemble
//       into 444-byte records = [rtcTimestamp:u32 BE][440B audio payload]
//       audio payload = [size:u8][opus frame:size]…, 0x00 = padding; a trailing
//       size byte whose frame would cross the 440B boundary is stale (firmware
//       overflow rule — parse uses `>=`).
//   NOTIFY_DONE  (0x04): ≥10B [0x04][status:u8][nextSeq:u64 BE]
//   NOTIFY_ACK   (0x01): [0x01][status:u8] (reply to ADVANCE / CLEAR)
//   commands (written to data char 30295781):
//       INFO=0x10, READ=0x11 [startSeq:u64 BE][optional count:u32 BE],
//       ADVANCE=0x12 [newReadSeq:u64 BE], CLEAR=0x13, STOP=0x03

import Foundation

public enum OmiRingProtocol {
    public static let recordSize = 444
    public static let timestampBytes = 4
    public static let audioPayloadBytes = recordSize - timestampBytes   // 440

    public static let notifyAck: UInt8 = 0x01
    public static let notifyInfo: UInt8 = 0x02
    public static let notifyData: UInt8 = 0x03
    public static let notifyDone: UInt8 = 0x04
    public static let notifyReadBegin: UInt8 = 0x05

    public static let cmdInfo: UInt8 = 0x10
    public static let cmdRead: UInt8 = 0x11
    public static let cmdAdvance: UInt8 = 0x12
    public static let cmdClear: UInt8 = 0x13
    public static let cmdStop: UInt8 = 0x03

    public struct RingStatus: Equatable, Sendable {
        public let usedBytes: UInt32
        public let unreadPackets: UInt32
        public let freeBytes: UInt32
        public let rtcValid: UInt32
        public init(usedBytes: UInt32, unreadPackets: UInt32, freeBytes: UInt32, rtcValid: UInt32) {
            self.usedBytes = usedBytes; self.unreadPackets = unreadPackets
            self.freeBytes = freeBytes; self.rtcValid = rtcValid
        }
    }

    public struct RingInfo: Equatable, Sendable {
        public let readSeq: UInt64
        public let writeSeq: UInt64
        public let capacityPackets: UInt32
        public let droppedPackets: UInt64
        public let packetSize: UInt16
    }

    public struct ReadBegin: Equatable, Sendable {
        public let transferStartSeq: UInt64
        public let packetCount: UInt32
    }

    public struct Done: Equatable, Sendable {
        public let status: UInt8
        public let nextSeq: UInt64
        public var isOk: Bool { status == 0 }
    }

    // MARK: parsing

    /// The 16-byte LITTLE-endian status read (control characteristic). nil = too
    /// short, i.e. an old-firmware storage protocol — the caller SKIPS offline sync.
    public static func parseStatus(_ d: Data) -> RingStatus? {
        guard d.count >= 16 else { return nil }
        return RingStatus(usedBytes: le32(d, 0), unreadPackets: le32(d, 4),
                          freeBytes: le32(d, 8), rtcValid: le32(d, 12))
    }

    public static func parseInfo(_ d: Data) -> RingInfo? {
        guard d.count >= 31, d[d.startIndex] == notifyInfo else { return nil }
        return RingInfo(readSeq: be64(d, 1), writeSeq: be64(d, 9),
                        capacityPackets: be32(d, 17), droppedPackets: be64(d, 21),
                        packetSize: be16(d, 29))
    }

    public static func parseReadBegin(_ d: Data) -> ReadBegin? {
        guard d.count >= 13, d[d.startIndex] == notifyReadBegin else { return nil }
        return ReadBegin(transferStartSeq: be64(d, 1), packetCount: be32(d, 9))
    }

    public static func parseDone(_ d: Data) -> Done? {
        guard d.count >= 10, d[d.startIndex] == notifyDone else { return nil }
        return Done(status: d[d.index(d.startIndex, offsetBy: 1)], nextSeq: be64(d, 2))
    }

    /// ACK status byte (reply to ADVANCE/CLEAR); nil if not an ACK notification.
    public static func parseAck(_ d: Data) -> UInt8? {
        guard d.count >= 2, d[d.startIndex] == notifyAck else { return nil }
        return d[d.index(d.startIndex, offsetBy: 1)]
    }

    /// A ring record's leading RTC timestamp (u32 BE, unix seconds; 0 = RTC invalid).
    public static func recordTimestamp(_ record: Data) -> UInt32 {
        guard record.count >= timestampBytes else { return 0 }
        return be32(record, 0)
    }

    /// Split a record's 440-byte audio payload into Opus frames:
    /// [size:u8][frame:size]…, 0x00 = padding. Firmware overflow rule: at the block
    /// boundary a trailing size byte may be written WITHOUT its frame (the frame
    /// went to the next block) — bytes after it are stale, so the bound check is `>=`.
    public static func parseAudioPayload(_ audio: Data) -> [Data] {
        var frames: [Data] = []
        var offset = 0
        let bytes = [UInt8](audio)
        while offset < bytes.count - 1 {
            let size = Int(bytes[offset])
            if size == 0 { offset += 1; continue }
            if offset + 1 + size >= bytes.count { break }
            frames.append(Data(bytes[(offset + 1)...(offset + size)]))
            offset += size + 1
        }
        return frames
    }

    /// Frames from one full 444B record (timestamp stripped).
    public static func recordFrames(_ record: Data) -> [Data] {
        guard record.count >= recordSize else { return [] }
        return parseAudioPayload(record.subdata(in: record.index(record.startIndex, offsetBy: timestampBytes)..<record.endIndex))
    }

    // MARK: command encoding

    public static func readCommand(startSeq: UInt64, packetCount: UInt32? = nil) -> Data {
        var d = Data([cmdRead])
        appendBE64(&d, startSeq)
        if let n = packetCount, n > 0 { appendBE32(&d, n) }
        return d
    }

    public static func advanceCommand(newReadSeq: UInt64) -> Data {
        var d = Data([cmdAdvance])
        appendBE64(&d, newReadSeq)
        return d
    }

    public static var infoCommand: Data { Data([cmdInfo]) }
    public static var stopCommand: Data { Data([cmdStop]) }

    // MARK: byte helpers (offsets relative to d.startIndex)

    private static func byte(_ d: Data, _ i: Int) -> UInt8 { d[d.index(d.startIndex, offsetBy: i)] }
    private static func le32(_ d: Data, _ i: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(byte(d, i + $1)) << (8 * UInt32($1))) }
    }
    private static func be16(_ d: Data, _ i: Int) -> UInt16 {
        (UInt16(byte(d, i)) << 8) | UInt16(byte(d, i + 1))
    }
    private static func be32(_ d: Data, _ i: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(byte(d, i + $1)) }
    }
    private static func be64(_ d: Data, _ i: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(byte(d, i + $1)) }
    }
    private static func appendBE32(_ d: inout Data, _ v: UInt32) {
        d.append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }
    private static func appendBE64(_ d: inout Data, _ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { d.append(UInt8((v >> UInt64(shift)) & 0xFF)) }
    }
}

/// Reassembles unaligned NOTIFY_DATA chunks (0x03 opcode already stripped) into
/// whole 444-byte ring records. Leftover bytes wait for the next append.
public final class OmiRingRecordReassembler {
    private var buffer = Data()
    public init() {}

    public func append(_ bytes: Data) { buffer.append(bytes) }

    /// Pop all complete records currently buffered.
    public func drainRecords() -> [Data] {
        var out: [Data] = []
        while buffer.count >= OmiRingProtocol.recordSize {
            out.append(buffer.prefix(OmiRingProtocol.recordSize))
            buffer.removeFirst(OmiRingProtocol.recordSize)
        }
        return out
    }

    public var pendingBytes: Int { buffer.count }
}
