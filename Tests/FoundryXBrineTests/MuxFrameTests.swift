import XCTest
@testable import FoundryXKit

/// Wire framing for the multiplexed door transport. Must stay byte-exact with the Rust
/// door's encode/decode (`[turn_id u64 LE][kind u8][payload]`).
final class MuxFrameTests: XCTestCase {

    func testEncodeDecodeRoundTrip() {
        let f = encodeMuxFrame(turnId: 0x0102_0304_0506_0708, kind: .responseFrame, payload: Data([9, 9, 9]))
        let d = decodeMuxFrame(f)
        XCTAssertEqual(d?.turnId, 0x0102_0304_0506_0708)
        XCTAssertEqual(d?.kind, MuxKind.responseFrame.rawValue)
        XCTAssertEqual(d?.payload, Data([9, 9, 9]))
    }

    func testTurnIdIsLittleEndian() {
        // turn_id 1 → first byte 0x01, rest 0 (matches Rust to_le_bytes()).
        let f = encodeMuxFrame(turnId: 1, kind: .request, payload: Data())
        let bytes = [UInt8](f)
        XCTAssertEqual(Array(bytes.prefix(8)), [1, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(bytes[8], MuxKind.request.rawValue)
    }

    func testEmptyPayload() {
        let f = encodeMuxFrame(turnId: 7, kind: .responseEnd, payload: Data())
        XCTAssertEqual(f.count, 9) // 8 (turn) + 1 (kind) + 0
        XCTAssertEqual(decodeMuxFrame(f)?.payload, Data())
        XCTAssertEqual(decodeMuxFrame(f)?.kind, MuxKind.responseEnd.rawValue)
    }

    func testTruncatedReturnsNil() {
        XCTAssertNil(decodeMuxFrame(Data()))
        XCTAssertNil(decodeMuxFrame(Data([1, 2, 3])))
        XCTAssertNil(decodeMuxFrame(Data(repeating: 0, count: 8))) // need ≥9
    }

    func testDecodeFromNonZeroBasedSlice() {
        // A frame sitting inside a larger buffer (sliced Data) must still decode.
        let f = encodeMuxFrame(turnId: 42, kind: .responseFrame, payload: Data([1, 2]))
        let slice = (Data([0xFF, 0xFF]) + f).dropFirst(2)
        let d = decodeMuxFrame(slice)
        XCTAssertEqual(d?.turnId, 42)
        XCTAssertEqual(d?.payload, Data([1, 2]))
    }
}
