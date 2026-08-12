import Foundation
import CryptoKit
import FoundryXKit

/// A REAL door on the other side of the blind relay: it dials in as `role:"door"`,
/// parks under a tunnel id, and runs a genuine Noise_XX responder.
///
/// ## Why the door is real rather than mocked
///
/// P1's observable is *"the client proceeds or does not"*, and "proceeds" means a Noise
/// channel actually reached transport mode against a counterpart. A mocked door could
/// only report what it was told to report. This one holds a real X25519 static key,
/// completes a real handshake, and its `staticPublic` is the ground truth the two P1
/// cases are built from: case (ii)'s "wrong identity" is wrong *relative to this key*,
/// and case (i)'s absent identity is the one the client never checks against it.
///
/// `NoiseXXResponder` is FoundryXKit's own responder, and `NoiseXXVectorTests` proves it
/// byte-for-byte identical to the production snow-based door — so using it here is
/// using the door's algorithm, not a re-implementation of it.
final class DoorFixture: NSObject, URLSessionWebSocketDelegate {
    let staticPrivate: Data
    let staticPublicHex: String
    let tunnelId: String
    private let relayURL: URL

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var responder: NoiseXXResponder?

    /// Set once the responder has completed msg1/msg2/msg3. The client's outcome is
    /// read independently of this — it is recorded so a run can say whether the door
    /// ever saw a handshake at all.
    private(set) var handshakeCompleted = false
    private let lock = NSLock()

    init(relayURL: URL, tunnelId: String) throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        self.staticPrivate = key.rawRepresentation
        self.staticPublicHex = key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        self.tunnelId = tunnelId
        self.relayURL = relayURL
        super.init()
    }

    /// Dial the relay, park, and serve exactly one spliced handshake.
    func startParked() throws {
        let cfg = URLSessionConfiguration.ephemeral
        let s = URLSession(configuration: cfg)
        session = s
        let t = s.webSocketTask(with: relayURL)
        task = t
        t.resume()

        let hello: [String: Any] = ["role": "door", "tunnel_id": tunnelId, "bearer": NSNull()]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: hello), as: UTF8.self)
        let r = try NoiseXXResponder(staticPrivate: staticPrivate)
        responder = r

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await t.send(.string(json))
                // msg1 <- e
                let msg1 = try await Self.recvBinary(t)
                _ = try r.readMessage(msg1)
                // msg2 -> e, ee, s, es
                try await t.send(.data(try r.writeMessage()))
                // msg3 <- s, se
                let msg3 = try await Self.recvBinary(t)
                _ = try r.readMessage(msg3)
                self.markHandshakeCompleted()
                // Hold the socket open so the client's channel is genuinely live; the
                // client's own outcome is what P1 reads, and a door that hung up early
                // would make a completed channel look like a refusal.
                while true {
                    if (try? await t.receive()) == nil { return }
                }
            } catch {
                return
            }
        }
    }

    var sawHandshake: Bool {
        lock.lock(); defer { lock.unlock() }
        return handshakeCompleted
    }

    /// Non-async so the lock is never taken from an async context (Swift 6 makes
    /// `NSLock.lock()` unavailable there).
    private func markHandshakeCompleted() {
        lock.lock(); handshakeCompleted = true; lock.unlock()
    }

    private static func recvBinary(_ task: URLSessionWebSocketTask) async throws -> Data {
        switch try await task.receive() {
        case .data(let d): return d
        case .string(let s): return Data(s.utf8)
        @unknown default: throw DoorFixtureError.io("unknown websocket frame kind")
        }
    }

    func stop() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    /// A 64-hex machine id that is a VALID X25519 public key encoding but is NOT this
    /// door's. Case (ii) needs the pin to be *present and wrong*, not malformed — a
    /// malformed one would fail the `hexToData` guard and collapse into case (i).
    static func someOtherMachineIdHex() -> String {
        Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
    }
}

enum DoorFixtureError: Error, CustomStringConvertible {
    case io(String)
    var description: String { if case .io(let m) = self { return m }; return "door fixture error" }
}
