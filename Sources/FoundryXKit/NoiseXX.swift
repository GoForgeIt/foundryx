// NoiseXX.swift — a from-scratch `Noise_XX_25519_ChaChaPoly_BLAKE2s` INITIATOR,
// interop-exact with the Rust `snow`-based door/relay
// (`~/Development/foundry/crates/foundryx-relay/src/lib.rs`). This is the phone's
// half of FoundryX's blind E2E relay channel (M5 R1b): the door is the responder,
// the phone is the initiator. After the 3-message XX handshake we Split() into two
// transport CipherStates and frame Noise transport messages over the relay WS.
//
// Crypto building blocks:
//   • X25519        — CryptoKit `Curve25519.KeyAgreement` (raw 32-byte keys).
//   • ChaCha20Poly1305 — CryptoKit `ChaChaPoly` (12-byte nonce = 4 zero bytes +
//                     64-bit LE counter in the last 8; 16-byte tag).
//   • BLAKE2s-256   — `BlakeHash.BLAKE2s` (pure Swift, RFC 7693).
//   • HMAC + HKDF   — hand-rolled HMAC-BLAKE2s (RFC 2104, 64-byte block) + Noise's
//                     HMAC-based KDF (NOT CryptoKit HKDF, NOT BLAKE2's native keying).
//
// Interop notes baked in to match snow EXACTLY (verified against golden vectors in
// NoiseXXVectorTests):
//   • `h` init: the protocol name is >32 bytes → `h = BLAKE2s(name)`.
//   • Empty prologue: still MixHash(empty) once after init.
//   • MixHash on EVERY message in/out; `h` is the AEAD associated-data, mixed AFTER
//     the (cipher)text it authenticates (encrypt → mixHash(ciphertext)).
//   • Transport split: initiator send-key = first Split key, recv-key = second.
//   • Nonce resets to 0 in each direction after Split.

import Foundation
import CryptoKit
import BlakeHash

// MARK: - BLAKE2s primitives (hash + HMAC + Noise HKDF)

enum NoiseHash {
    static let hashLen = 32   // BLAKE2s-256 digest
    static let blockLen = 64  // BLAKE2s block (for HMAC padding)

    /// Unkeyed BLAKE2s-256.
    static func hash(_ data: Data) -> Data {
        BLAKE2s.hash(data, digestLength: hashLen)
    }

    /// HMAC-BLAKE2s (RFC 2104), the standard HMAC construction over BLAKE2s — this is
    /// what Noise's KDF requires, distinct from BLAKE2's native keyed mode.
    static func hmac(key: Data, data: Data) -> Data {
        var k = key
        if k.count > blockLen { k = hash(k) }
        if k.count < blockLen { k.append(Data(repeating: 0, count: blockLen - k.count)) }

        var ipad = Data(repeating: 0x36, count: blockLen)
        var opad = Data(repeating: 0x5c, count: blockLen)
        for i in 0..<blockLen {
            ipad[i] ^= k[i]
            opad[i] ^= k[i]
        }
        let inner = hash(ipad + data)
        return hash(opad + inner)
    }

    /// Noise HKDF (HMAC-based, matches snow's `Hash::hkdf`): returns `outputs` keys.
    static func hkdf(chainingKey: Data, ikm: Data, outputs: Int) -> [Data] {
        let tempKey = hmac(key: chainingKey, data: ikm)
        let o1 = hmac(key: tempKey, data: Data([0x01]))
        if outputs == 1 { return [o1] }
        let o2 = hmac(key: tempKey, data: o1 + Data([0x02]))
        if outputs == 2 { return [o1, o2] }
        let o3 = hmac(key: tempKey, data: o2 + Data([0x03]))
        return [o1, o2, o3]
    }
}

// MARK: - CipherState (ChaCha20-Poly1305 with a 64-bit nonce counter)

public final class NoiseCipherState {
    private var key: SymmetricKey?
    private var n: UInt64 = 0

    func initializeKey(_ key: Data) {
        self.key = SymmetricKey(data: key)
        self.n = 0
    }

    var hasKey: Bool { key != nil }

    /// TEST ONLY: the raw 32-byte transport key, to assert Split() parity vs snow.
    var exposedKeyForTesting: Data? {
        key.map { $0.withUnsafeBytes { Data($0) } }
    }

    /// 12-byte ChaChaPoly nonce: 4 zero bytes + 64-bit little-endian counter.
    private static func nonceBytes(_ n: UInt64) -> Data {
        var d = Data(repeating: 0, count: 4)
        d.append(Data(withUnsafeBytes(of: n.littleEndian) { Data($0) }))
        return d
    }

    public func encryptWithAd(ad: Data, plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        let nonce = try ChaChaPoly.Nonce(data: Self.nonceBytes(n))
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: ad)
        n &+= 1
        // snow wire layout: ciphertext || 16-byte tag (the SealedBox combined form
        // is nonce||ciphertext||tag, so assemble ciphertext+tag explicitly).
        return sealed.ciphertext + sealed.tag
    }

    public func decryptWithAd(ad: Data, ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard ciphertext.count >= 16 else { throw NoiseError.shortCiphertext }
        let ct = ciphertext.prefix(ciphertext.count - 16)
        let tag = ciphertext.suffix(16)
        let nonce = try ChaChaPoly.Nonce(data: Self.nonceBytes(n))
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        let pt = try ChaChaPoly.open(box, using: key, authenticating: ad)
        n &+= 1
        return pt
    }
}

// MARK: - SymmetricState (h, ck; MixHash / MixKey / EncryptAndHash / DecryptAndHash)

final class NoiseSymmetricState {
    private(set) var h: Data
    private var ck: Data
    let cipher = NoiseCipherState()

    init(protocolName: String) {
        let nameBytes = Data(protocolName.utf8)
        // Protocol name "Noise_XX_25519_ChaChaPoly_BLAKE2s" is >32 bytes → h = BLAKE2s(name).
        if nameBytes.count <= NoiseHash.hashLen {
            var padded = nameBytes
            padded.append(Data(repeating: 0, count: NoiseHash.hashLen - nameBytes.count))
            h = padded
        } else {
            h = NoiseHash.hash(nameBytes)
        }
        ck = h
    }

    func mixHash(_ data: Data) {
        h = NoiseHash.hash(h + data)
    }

    func mixKey(_ ikm: Data) {
        let out = NoiseHash.hkdf(chainingKey: ck, ikm: ikm, outputs: 2)
        ck = out[0]
        cipher.initializeKey(out[1].prefix(32))
    }

    func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ct = try cipher.encryptWithAd(ad: h, plaintext: plaintext)
        mixHash(ct)
        return ct
    }

    func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let pt = try cipher.decryptWithAd(ad: h, ciphertext: ciphertext)
        mixHash(ciphertext)
        return pt
    }

    /// Split() → (cs1, cs2). Initiator: cs1 = send, cs2 = recv.
    func split() -> (NoiseCipherState, NoiseCipherState) {
        let out = NoiseHash.hkdf(chainingKey: ck, ikm: Data(), outputs: 2)
        let c1 = NoiseCipherState(); c1.initializeKey(out[0].prefix(32))
        let c2 = NoiseCipherState(); c2.initializeKey(out[1].prefix(32))
        return (c1, c2)
    }

    var handshakeHash: Data { h }
}

// MARK: - HandshakeState (XX initiator)

public enum NoiseError: Error, Equatable {
    case shortCiphertext
    case badMessageLength
    case handshakeNotComplete
    case alreadyComplete
}

/// The phone's Noise_XX **initiator**. Drive it message-by-message:
///   1. `writeMessage(payload:)`  → msg1 (e)
///   2. `readMessage(_:)`         ← msg2 (e, ee, s, es)
///   3. `writeMessage(payload:)`  → msg3 (s, se)
///   4. `split()`                 → (send, recv) transport CipherStates
public final class NoiseXXInitiator {
    private let sym: NoiseSymmetricState

    // Local static (s) + ephemeral (e); remote ephemeral (re) + static (rs).
    private let s: Curve25519.KeyAgreement.PrivateKey
    private let sPub: Data
    private let e: Curve25519.KeyAgreement.PrivateKey
    private let ePub: Data
    private var re: Data?
    private var rs: Data?

    private var messageIndex = 0
    private var complete = false

    public static let protocolName = "Noise_XX_25519_ChaChaPoly_BLAKE2s"

    /// `staticPrivate` — the phone's 32-byte X25519 static private key (its durable
    /// Noise identity). `fixedEphemeral` — TEST ONLY: pin the ephemeral to reproduce
    /// golden vectors; nil in production (a fresh random ephemeral per handshake).
    public init(staticPrivate: Data, fixedEphemeral: Data? = nil, prologue: Data = Data()) throws {
        sym = NoiseSymmetricState(protocolName: Self.protocolName)
        sym.mixHash(prologue) // empty prologue: snow still MixHashes once.

        s = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivate)
        sPub = s.publicKey.rawRepresentation
        if let fe = fixedEphemeral {
            e = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: fe)
        } else {
            e = Curve25519.KeyAgreement.PrivateKey()
        }
        ePub = e.publicKey.rawRepresentation
    }

    private func dh(_ priv: Curve25519.KeyAgreement.PrivateKey, _ pubRaw: Data) throws -> Data {
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubRaw)
        let shared = try priv.sharedSecretFromKeyAgreement(with: pub)
        return shared.withUnsafeBytes { Data($0) }
    }

    /// Write the next handshake message (msg1 then msg3 for the initiator).
    public func writeMessage(payload: Data = Data()) throws -> Data {
        guard !complete else { throw NoiseError.alreadyComplete }
        var out = Data()
        switch messageIndex {
        case 0:
            // msg1: -> e
            out.append(ePub)
            sym.mixHash(ePub)
            out.append(try sym.encryptAndHash(payload))
        case 2:
            // msg3: -> s, se
            out.append(try sym.encryptAndHash(sPub))            // s (encrypted; has_key now true)
            guard let re else { throw NoiseError.handshakeNotComplete }
            sym.mixKey(try dh(s, re))                           // se
            out.append(try sym.encryptAndHash(payload))
            let _ = re // silence
            complete = true
        default:
            throw NoiseError.badMessageLength
        }
        messageIndex += 1
        return out
    }

    /// Read the next handshake message (msg2 for the initiator). Returns the decrypted payload.
    public func readMessage(_ message: Data) throws -> Data {
        guard !complete else { throw NoiseError.alreadyComplete }
        guard messageIndex == 1 else { throw NoiseError.badMessageLength }
        // msg2: <- e, ee, s, es
        guard message.count >= 32 else { throw NoiseError.badMessageLength }
        var idx = message.startIndex

        let reBytes = Data(message[idx..<message.index(idx, offsetBy: 32)])
        idx = message.index(idx, offsetBy: 32)
        re = reBytes
        sym.mixHash(reBytes)                                    // e
        sym.mixKey(try dh(e, reBytes))                          // ee

        // s: encrypted static (32 + 16 tag) since has_key is true.
        let encStaticLen = 32 + 16
        guard message.distance(from: idx, to: message.endIndex) >= encStaticLen else {
            throw NoiseError.badMessageLength
        }
        let encStatic = Data(message[idx..<message.index(idx, offsetBy: encStaticLen)])
        idx = message.index(idx, offsetBy: encStaticLen)
        let rsBytes = try sym.decryptAndHash(encStatic)         // s
        rs = rsBytes
        sym.mixKey(try dh(e, rsBytes))                          // es

        // remaining = encrypted payload.
        let rest = Data(message[idx..<message.endIndex])
        let payload = try sym.decryptAndHash(rest)
        messageIndex += 1
        return payload
    }

    public var isComplete: Bool { complete }

    /// The remote (door) static public key learned during the handshake — the phone
    /// can pin it across reconnects (the door's stable Noise identity).
    public var remoteStaticPublic: Data? { rs }

    /// The final symmetric handshake hash (channel binding; matches snow's get_handshake_hash).
    public var handshakeHash: Data { sym.handshakeHash }

    /// Split into transport CipherStates. Returns `(send, recv)` for the initiator.
    public func split() throws -> (send: NoiseCipherState, recv: NoiseCipherState) {
        guard complete else { throw NoiseError.handshakeNotComplete }
        let (c1, c2) = sym.split()
        return (c1, c2)
    }
}

/// The Noise_XX **responder** (the door's role). Provided so Swift code/tests can run
/// a full initiator↔responder round-trip without the Rust relay; the production door
/// is snow-based, and NoiseXXVectorTests proves byte-for-byte parity with it.
public final class NoiseXXResponder {
    private let sym: NoiseSymmetricState
    private let s: Curve25519.KeyAgreement.PrivateKey
    private let sPub: Data
    private let e: Curve25519.KeyAgreement.PrivateKey
    private let ePub: Data
    private var re: Data?
    private var rs: Data?
    private var messageIndex = 0
    private var complete = false

    public init(staticPrivate: Data, fixedEphemeral: Data? = nil, prologue: Data = Data()) throws {
        sym = NoiseSymmetricState(protocolName: NoiseXXInitiator.protocolName)
        sym.mixHash(prologue)
        s = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivate)
        sPub = s.publicKey.rawRepresentation
        if let fe = fixedEphemeral {
            e = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: fe)
        } else {
            e = Curve25519.KeyAgreement.PrivateKey()
        }
        ePub = e.publicKey.rawRepresentation
    }

    private func dh(_ priv: Curve25519.KeyAgreement.PrivateKey, _ pubRaw: Data) throws -> Data {
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubRaw)
        return try priv.sharedSecretFromKeyAgreement(with: pub).withUnsafeBytes { Data($0) }
    }

    /// Read the next handshake message (msg1 then msg3 for the responder).
    public func readMessage(_ message: Data) throws -> Data {
        guard !complete else { throw NoiseError.alreadyComplete }
        switch messageIndex {
        case 0:
            // msg1: <- e
            guard message.count >= 32 else { throw NoiseError.badMessageLength }
            let reBytes = Data(message.prefix(32))
            re = reBytes
            sym.mixHash(reBytes)
            let payload = try sym.decryptAndHash(Data(message.dropFirst(32)))
            messageIndex += 1
            return payload
        case 2:
            // msg3: <- s, se
            var idx = message.startIndex
            let encStaticLen = 32 + 16
            guard message.count >= encStaticLen else { throw NoiseError.badMessageLength }
            let encStatic = Data(message[idx..<message.index(idx, offsetBy: encStaticLen)])
            idx = message.index(idx, offsetBy: encStaticLen)
            let rsBytes = try sym.decryptAndHash(encStatic)     // s
            rs = rsBytes
            sym.mixKey(try dh(e, rsBytes))                      // se
            let payload = try sym.decryptAndHash(Data(message[idx..<message.endIndex]))
            complete = true
            messageIndex += 1
            return payload
        default:
            throw NoiseError.badMessageLength
        }
    }

    /// Write the next handshake message (msg2 for the responder).
    public func writeMessage(payload: Data = Data()) throws -> Data {
        guard !complete else { throw NoiseError.alreadyComplete }
        guard messageIndex == 1 else { throw NoiseError.badMessageLength }
        // msg2: -> e, ee, s, es
        var out = Data()
        out.append(ePub)
        sym.mixHash(ePub)                                       // e
        guard let re else { throw NoiseError.handshakeNotComplete }
        sym.mixKey(try dh(e, re))                               // ee
        out.append(try sym.encryptAndHash(sPub))               // s (encrypted; has_key now true)
        sym.mixKey(try dh(s, re))                               // es
        out.append(try sym.encryptAndHash(payload))
        messageIndex += 1
        return out
    }

    public var isComplete: Bool { complete }
    public var remoteStaticPublic: Data? { rs }
    public var handshakeHash: Data { sym.handshakeHash }

    /// Split into transport CipherStates. Returns `(send, recv)` for the RESPONDER —
    /// note the responder's send = the initiator's recv (= Split key 2), and the
    /// responder's recv = the initiator's send (= Split key 1).
    public func split() throws -> (send: NoiseCipherState, recv: NoiseCipherState) {
        guard complete else { throw NoiseError.handshakeNotComplete }
        let (c1, c2) = sym.split()
        return (c2, c1)
    }
}
