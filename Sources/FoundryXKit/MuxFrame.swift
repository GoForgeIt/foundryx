// MuxFrame.swift — wire framing for the MULTIPLEXED door transport (M5 R1c, dormant).
//
// Today each door turn opens a fresh relay connection + Noise XX handshake + one
// request/response (RelayTransport.roundTrip). Multiplexing runs MANY turns over ONE
// persistent connection: each Noise transport message carries one MUX FRAME so the door
// can demultiplex concurrent turns. The relay stays BLIND — it only ever sees the Noise
// ciphertext; the turn_id lives inside the encrypted payload.
//
// Frame layout (interop-EXACT with the Rust door's encode/decode in
// crates/foundryx-tunnel/src/lib.rs — `[turn_id u64 LE][kind u8][payload…]`):
//
//   ┌──────────────────────┬────────┬───────────────┐
//   │ turn_id: UInt64 LE    │ kind:u8│ payload bytes │
//   │ (8 bytes)             │        │ (0+)          │
//   └──────────────────────┴────────┴───────────────┘
//
// One mux frame == one Noise transport message == one relay WS binary frame.

import Foundation

/// The kind byte of a mux frame. The phone is the INITIATOR: it sends `request` /
/// `cancel` and receives `responseFrame` / `responseEnd`.
public enum MuxKind: UInt8, Sendable, Equatable {
    case request = 0
    case responseFrame = 1
    case responseEnd = 2
    case cancel = 3
}

/// Encode one mux frame: `[turn_id u64 LE][kind u8][payload]`. Little-endian to match
/// the Rust door's `turn_id.to_le_bytes()`.
public func encodeMuxFrame(turnId: UInt64, kind: UInt8, payload: Data) -> Data {
    var out = Data(capacity: 9 + payload.count)
    for i in 0..<8 { out.append(UInt8((turnId >> (8 * UInt64(i))) & 0xff)) }
    out.append(kind)
    out.append(payload)
    return out
}

/// Convenience over `encodeMuxFrame` taking a typed `MuxKind`.
public func encodeMuxFrame(turnId: UInt64, kind: MuxKind, payload: Data) -> Data {
    encodeMuxFrame(turnId: turnId, kind: kind.rawValue, payload: payload)
}

/// Decode one mux frame. Returns `nil` for a short/garbage frame (fewer than 9 bytes).
public func decodeMuxFrame(_ data: Data) -> (turnId: UInt64, kind: UInt8, payload: Data)? {
    guard data.count >= 9 else { return nil }
    let bytes = [UInt8](data) // normalize indices (data may be a non-zero-based slice)
    var turnId: UInt64 = 0
    for i in 0..<8 { turnId |= UInt64(bytes[i]) << (8 * UInt64(i)) }
    let kind = bytes[8]
    let payload = bytes.count > 9 ? Data(bytes[9...]) : Data()
    return (turnId, kind, payload)
}
