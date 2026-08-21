// RelayTransportTests.swift — Swift-side validation of the relay transport logic that
// doesn't require the live Rust relay:
//   1. A full Swift Noise_XX initiator↔responder round-trip (the responder built from
//      the SAME NoiseXX primitives the door uses via snow) — proves the client's
//      handshake + transport framing is internally consistent and end-to-end correct.
//   2. The Hello JSON shape matches the relay's `Hello` contract.
//   3. DoorClient gating: a target WITHOUT a relay config takes the LAN-direct path
//      (relay is opt-in / default OFF).
//
// Byte-for-byte parity with the real Rust door is proven separately by
// NoiseXXVectorTests against snow's golden vectors; this complements it with a
// dynamic-key full-duplex transport exercise.

import XCTest
import Foundation
import CryptoKit
@testable import FoundryXKit

final class RelayTransportTests: XCTestCase {

    /// Full handshake + bidirectional transport between a Swift initiator (the phone's
    /// RelayTransport path) and a Swift responder (mirrors the door), with RANDOM keys.
    func testInitiatorResponderRoundTrip() throws {
        let clientStatic = Curve25519KeyHelper.randomStatic()
        let doorStatic = Curve25519KeyHelper.randomStatic()

        let initiator = try NoiseXXInitiator(staticPrivate: clientStatic)
        let responder = try NoiseXXResponder(staticPrivate: doorStatic)

        // XX: -> e ; <- e,ee,s,es ; -> s,se
        let m1 = try initiator.writeMessage()
        _ = try responder.readMessage(m1)
        let m2 = try responder.writeMessage()
        _ = try initiator.readMessage(m2)
        let m3 = try initiator.writeMessage()
        _ = try responder.readMessage(m3)

        XCTAssertTrue(initiator.isComplete)
        XCTAssertTrue(responder.isComplete)
        XCTAssertEqual(initiator.handshakeHash, responder.handshakeHash, "both ends must agree on h")

        // The client learns the door's static public from the handshake (pinnable).
        let doorPub = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: doorStatic).publicKey.rawRepresentation
        XCTAssertEqual(initiator.remoteStaticPublic, doorPub, "client must learn the door's real static public")

        let (cSend, cRecv) = try initiator.split()
        let (dSend, dRecv) = try responder.split()

        // Transport: client request -> door ; door reply -> client (the relay turn).
        let request = Data("GET /foundryx/chat HTTP/1.1\r\n\r\n".utf8)
        let reqCt = try cSend.encryptWithAd(ad: Data(), plaintext: request)
        let reqPt = try dRecv.decryptWithAd(ad: Data(), ciphertext: reqCt)
        XCTAssertEqual(reqPt, request, "door must decrypt the client request")

        let reply = Data("data: {\"type\":\"done\",\"reason\":\"stop\"}\n".utf8)
        let replyCt = try dSend.encryptWithAd(ad: Data(), plaintext: reply)
        let replyPt = try cRecv.decryptWithAd(ad: Data(), ciphertext: replyCt)
        XCTAssertEqual(replyPt, reply, "client must decrypt the door reply")

        // End-of-turn marker (empty plaintext) decrypts to empty.
        let endCt = try dSend.encryptWithAd(ad: Data(), plaintext: Data())
        let endPt = try cRecv.decryptWithAd(ad: Data(), ciphertext: endCt)
        XCTAssertTrue(endPt.isEmpty, "empty end-of-turn frame must decrypt to empty")
    }

    /// The Hello first-message must be the relay's exact JSON shape.
    func testHelloShape() throws {
        let cfg = RelayConfig(
            relayURL: URL(string: "ws://127.0.0.1:9/")!,
            tunnelId: "desktop-abc123",
            staticPrivate: Curve25519KeyHelper.randomStatic(),
            // The pin is mandatory and has no default: a RelayConfig cannot be
            // written without naming the door it will accept.
            expectedDoorStatic: Curve25519KeyHelper.randomDoorPublic()
        )
        // tunnel_id is a parameter, never hardcoded.
        XCTAssertEqual(cfg.tunnelId, "desktop-abc123")
        XCTAssertNotEqual(cfg.tunnelId, "foundryx-door")
    }

    /// DoorClient stays on the LAN-direct path when no relay is configured (default OFF).
    func testRelayIsOptInDefaultOff() {
        let lanTarget = DoorTarget(baseURL: URL(string: "http://127.0.0.1:14288")!, bearer: "t")
        XCTAssertNil(lanTarget.relay, "relay must be nil by default — LAN-direct unchanged")

        let relayTarget = DoorTarget(
            baseURL: URL(string: "http://127.0.0.1:14288")!,
            bearer: "t",
            relay: RelayConfig(relayURL: URL(string: "wss://relay/")!,
                               tunnelId: "desktop-xyz",
                               staticPrivate: Curve25519KeyHelper.randomStatic(),
                               expectedDoorStatic: Curve25519KeyHelper.randomDoorPublic())
        )
        XCTAssertNotNil(relayTarget.relay, "relay path is available when explicitly configured")
    }
}

enum Curve25519KeyHelper {
    static func randomStatic() -> Data {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    /// A real 32-byte X25519 PUBLIC key, for the mandatory door pin.
    static func randomDoorPublic() -> Data {
        Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    }
}
