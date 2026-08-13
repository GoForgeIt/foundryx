// RelayTransport.swift — the phone's blind E2E relay path (M5 R1b). When configured
// (and ONLY then), an HTTP turn to the door is tunneled through the personal
// reachability relay over a Noise_XX channel the relay cannot read, instead of the
// LAN-direct HTTP path. Off-LAN reachability without the relay ever seeing plaintext.
//
// Wire protocol (interop-exact with crates/foundryx-tunnel/src/lib.rs):
//   1. Open a WebSocket to the relay URL.
//   2. FIRST message = Text JSON Hello `{"role":"client","tunnel_id":"…","bearer":null}`.
//   3. Noise_XX initiator handshake: send msg1 (binary), recv msg2, send msg3.
//      One WebSocket binary message == one Noise message (snow adds no length prefix).
//   4. Transport: encrypt the raw HTTP request bytes, send as one binary frame; read
//      binary reply frames, decrypt each, until an empty-plaintext frame (end-of-turn).
//
// The `tunnelId` is a PARAMETER (not hardcoded): it must be per-DESKTOP-machine
// (stable, derived from the door's persisted Noise static identity) so a hosted
// manager can route the phone to the user's DESIGNATED host without another logged-in
// machine stealing the tunnel. The phone's own Noise static key is its initiator
// identity; the door's static public is learned + pinnable from the handshake.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the relay lives + which desktop tunnel to claim + the phone's Noise identity.
public struct RelayConfig: Sendable {
    /// The relay WebSocket URL, e.g. `wss://relay.example.com` (or `ws://` for local/dev).
    public let relayURL: URL
    /// Per-DESKTOP-machine tunnel id (stable; derived from the door's Noise static key).
    public let tunnelId: String
    /// The phone's 32-byte X25519 Noise static private key (its durable initiator identity).
    public let staticPrivate: Data
    /// THE PIN — the door's expected static public key (channel auth across reconnects).
    ///
    /// NOT optional, and not defaulted. It was both until 2026-08-13, and that is the
    /// whole of the fail-open: `nil` had a spelling here, both dial sites read it with
    /// `if let`, and a configuration built from a gateway answer that carried no door
    /// key dialled with no identity check at all. Making the type non-optional means an
    /// unpinned dial cannot be WRITTEN — the compiler is the guard, at the one point
    /// every dial passes through, rather than a check each new call site must remember.
    ///
    /// A caller that has no key does not get to pass `nil`; it has to refuse (see
    /// `HostResolver.doorStaticKey(fromMachineId:)`).
    public let expectedDoorStatic: Data

    public init(relayURL: URL, tunnelId: String, staticPrivate: Data, expectedDoorStatic: Data) {
        self.relayURL = relayURL
        self.tunnelId = tunnelId
        self.staticPrivate = staticPrivate
        self.expectedDoorStatic = expectedDoorStatic
    }

    /// The first 8 hex characters of the pinned door key — enough to tell two doors
    /// apart in a log without writing a key into one.
    public var pinnedDoorPrefix: String {
        expectedDoorStatic.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The INTERACTIVE channel: same relay, key, and door-key pin, but the tunnel id
    /// suffixed `-chat`. Chat turns + transcript fetches dial this so they splice
    /// through the door's dedicated interactive pool and never queue behind bulk
    /// capture sync (which keeps using the base tunnel). Mirrors the door's
    /// `interactive_tunnel_id` (base + "-chat").
    public func interactive() -> RelayConfig {
        RelayConfig(
            relayURL: relayURL,
            tunnelId: "\(tunnelId)-chat",
            staticPrivate: staticPrivate,
            expectedDoorStatic: expectedDoorStatic
        )
    }
}

public enum RelayError: Error, Equatable {
    case socketClosed
    case handshakeFailed(String)
    case doorIdentityMismatch
    case nonBinaryFrame
}

/// One blind E2E turn over the relay: open tunnel → Noise handshake → encrypt the
/// HTTP request → read decrypted reply frames until the empty end-marker.
public final class RelayTransport: NSObject, @unchecked Sendable {
    private let config: RelayConfig
    private let session: URLSession
    private let log: DoorLog?

    public init(config: RelayConfig,
                session: URLSession = URLSession(configuration: .ephemeral),
                log: DoorLog? = nil) {
        self.config = config
        self.session = session
        self.log = log
    }

    /// Send raw `requestBytes` (a complete HTTP/1.1 request) E2E through the relay and
    /// collect the decrypted reply frames in order (the door's response, possibly in
    /// several frames), stopping at the door's empty end-of-turn marker.
    public func roundTrip(requestBytes: Data) async throws -> [Data] {
        let task = session.webSocketTask(with: config.relayURL)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        // 1. Hello (Text JSON) — FIRST message, before the handshake.
        let hello: [String: Any?] = ["role": "client", "tunnel_id": config.tunnelId, "bearer": nil]
        let helloData = try JSONSerialization.data(withJSONObject: hello.compactMapValues { $0 } as [String: Any])
        // Preserve an explicit null bearer to match the relay's `Hello` shape.
        let helloJSON = String(data: helloData, encoding: .utf8) ?? "{}"
        let helloWithBearer = helloJSON.contains("\"bearer\"")
            ? helloJSON
            : helloJSON.replacingOccurrences(of: "}", with: ",\"bearer\":null}")
        try await task.send(.string(helloWithBearer))
        log?.info("→ relay Hello tunnel=\(config.tunnelId)")

        // 2. Noise_XX initiator handshake.
        let initiator = try NoiseXXInitiator(staticPrivate: config.staticPrivate)
        let msg1 = try initiator.writeMessage()
        try await task.send(.data(msg1))
        let msg2 = try await recvBinary(task)
        _ = try initiator.readMessage(msg2)
        let msg3 = try initiator.writeMessage()
        try await task.send(.data(msg3))

        // THE PIN. Unconditional: `expectedDoorStatic` is not optional, so there is no
        // "if requested" left to write and no configuration that can skip this.
        guard initiator.remoteStaticPublic == config.expectedDoorStatic else {
            throw RelayError.doorIdentityMismatch
        }
        let (send, recv) = try initiator.split()
        log?.info("✓ relay Noise handshake complete (door \(config.pinnedDoorPrefix) pinned)")

        // 3. Transport: encrypt the request, read reply frames until empty plaintext.
        let reqCt = try send.encryptWithAd(ad: Data(), plaintext: requestBytes)
        try await task.send(.data(reqCt))

        var frames: [Data] = []
        while true {
            let ct = try await recvBinary(task)
            let pt = try recv.decryptWithAd(ad: Data(), ciphertext: ct)
            if pt.isEmpty { break } // end-of-turn marker
            frames.append(pt)
        }
        log?.info("✓ relay turn complete (\(frames.count) reply frame(s))")
        return frames
    }

    private func recvBinary(_ task: URLSessionWebSocketTask) async throws -> Data {
        switch try await task.receive() {
        case .data(let d): return d
        case .string: throw RelayError.nonBinaryFrame
        @unknown default: throw RelayError.nonBinaryFrame
        }
    }
}
