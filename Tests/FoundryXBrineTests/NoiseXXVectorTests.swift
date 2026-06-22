// NoiseXXVectorTests.swift — the GO/NO-GO interop gate for the iOS Noise client.
//
// Feeds the Swift `NoiseXXInitiator` the EXACT fixed keys snow used to produce the
// golden handshake vectors (crates/foundryx-relay/tests/handshake_vectors.json,
// copied into the test bundle) and asserts, byte-for-byte:
//   • msg1 / msg2-payload / msg3 bytes
//   • the final symmetric handshake hash `h`
//   • the two Split() transport keys
//   • a transport-mode request encrypt + response decrypt round-trip
//
// If these match, every intermediate MixHash / MixKey / EncryptAndHash step agreed
// with snow too — the channel will interoperate with the real door. No relay, no
// network: pure vector parity.

import XCTest
import Foundation
@testable import FoundryXKit

final class NoiseXXVectorTests: XCTestCase {

    struct Vectors: Decodable {
        let params: String
        let init_static_priv: String
        let init_ephemeral_priv: String
        let resp_static_priv: String
        let resp_ephemeral_priv: String
        let msg1_payload: String
        let msg2_payload: String
        let msg3_payload: String
        let msg1: String
        let msg2: String
        let msg3: String
        let handshake_hash: String
        let split_key_1: String
        let split_key_2: String
        let request_pt: String
        let request_ct: String
        let response_pt: String
        let response_ct: String
    }

    static func hex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    func loadVectors() throws -> Vectors {
        // Locate the fixture next to this source file (mirrors the door-test pattern;
        // robust whether or not SPM treats it as a bundled resource).
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.appendPathComponent("fixtures/handshake_vectors.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    func testSwiftMatchesSnowByteForByte() throws {
        let v = try loadVectors()
        XCTAssertEqual(v.params, NoiseXXInitiator.protocolName)

        let initiator = try NoiseXXInitiator(
            staticPrivate: Self.hex(v.init_static_priv),
            fixedEphemeral: Self.hex(v.init_ephemeral_priv)
        )

        // msg1: initiator writes (e + encrypted empty payload).
        let msg1 = try initiator.writeMessage(payload: Self.hex(v.msg1_payload))
        XCTAssertEqual(msg1.hexString, v.msg1, "msg1 mismatch — Swift initiator diverged from snow at the first message")

        // msg2: feed snow's responder msg2 bytes; assert decrypted payload matches.
        let p2 = try initiator.readMessage(Self.hex(v.msg2))
        XCTAssertEqual(p2.hexString, v.msg2_payload, "msg2 decrypted payload mismatch")

        // msg3: initiator writes (encrypted static + se + encrypted empty payload).
        let msg3 = try initiator.writeMessage(payload: Self.hex(v.msg3_payload))
        XCTAssertEqual(msg3.hexString, v.msg3, "msg3 mismatch — static/se or h-as-AAD ordering diverged from snow")

        // The remote (door) static the initiator decrypted from msg2.
        XCTAssertEqual(initiator.remoteStaticPublic?.count, 32, "should have learned the door's 32-byte static public")

        // Final handshake hash.
        XCTAssertEqual(initiator.handshakeHash.hexString, v.handshake_hash, "final handshake hash mismatch")

        // Split keys (initiator send=key1, recv=key2).
        let (send, recv) = try initiator.split()
        XCTAssertEqual(send.exposedKeyForTesting?.hexString, v.split_key_1, "split key 1 (initiator send) mismatch")
        XCTAssertEqual(recv.exposedKeyForTesting?.hexString, v.split_key_2, "split key 2 (initiator recv) mismatch")

        // Transport round-trip vs snow's recorded ciphertexts.
        let reqCt = try send.encryptWithAd(ad: Data(), plaintext: Self.hex(v.request_pt))
        XCTAssertEqual(reqCt.hexString, v.request_ct, "transport request ciphertext mismatch (nonce 0, send key)")

        let respPt = try recv.decryptWithAd(ad: Data(), ciphertext: Self.hex(v.response_ct))
        XCTAssertEqual(respPt.hexString, v.response_pt, "transport response decrypt mismatch (nonce 0, recv key)")
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
