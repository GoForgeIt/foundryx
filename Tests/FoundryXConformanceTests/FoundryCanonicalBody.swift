import Foundation
import CryptoKit

/// The signed-object formats this client has to reproduce from the outside.
///
/// Two of them, and they are separate purposes on purpose:
///
///  * `fx/relay/connect/v1` — the connect frame the relay's auth middle verifies
///    (`crates/foundry-relay/src/identity.rs`).
///  * `fx/auth/membership/v1` — an entry in a community's signed membership log, which
///    the relay folds to decide enrolment (`crates/foundry-spaces/src/entry.rs`).
///
/// Signing a connect frame under the membership purpose, or the reverse, is exactly the
/// substitution domain separation exists to prevent, and the relay refuses it — so the two
/// tags are two constants here rather than one parameter with a comment.
///
/// ## The encoder is LENGTH-PREFIXED, and this file does not concatenate by hand
///
/// `foundry-signing`'s canonical encoder writes every variable-length field as its length
/// (`u32`, big-endian) followed by its bytes, so the boundary between two adjacent fields
/// cannot shift and `("ab","c")` and `("a","bc")` do not encode alike. Reproducing that
/// with string concatenation would reintroduce precisely the ambiguity the encoder exists
/// to remove, so [`CanonicalBody`] is a type with an ordered field list and one encoder,
/// the same shape the Rust side has.
enum FoundrySigning {

    /// The purpose a client signs its relay connect-frame under.
    /// `identity::TAG_CONNECT`.
    static let connectTag = "fx/relay/connect/v1"

    /// The purpose a community's membership entry is signed under.
    /// `foundry_spaces::log::MEMBERSHIP_TAG`.
    static let membershipTag = "fx/auth/membership/v1"

    /// The scheme the origin inside a connect frame carries. `identity::ORIGIN_SCHEME` is
    /// `wss://` unconditionally — a relay serving the product is behind TLS, and the
    /// client signs the address it believes it reached, so this stays `wss://` even when
    /// the conformance hop is a plaintext loopback socket. Signing `ws://` here produces a
    /// signature the relay refuses, and refuses with the same bytes as everything else.
    static let originScheme = "wss://"

    /// `u16`, big-endian, INSIDE the pre-image. `foundry_signing::FORMAT_VERSION`.
    static let formatVersion: UInt16 = 1

    /// A typed body: a kind and ordered named fields. Not a dictionary — the ORDER is
    /// part of the encoding, and a dictionary would make it depend on hashing.
    struct CanonicalBody {
        let kind: String
        private(set) var fields: [(name: String, value: String)] = []

        init(kind: String) { self.kind = kind }

        func with(_ name: String, _ value: String) -> CanonicalBody {
            var copy = self
            copy.fields.append((name: name, value: value))
            return copy
        }

        /// `lp(kind) ‖ u32_be(field count) ‖ (lp(name) ‖ lp(value))*`, where `lp(x)` is
        /// `u32_be(x.utf8.count) ‖ x.utf8`.
        var canonicalBytes: [UInt8] {
            var out: [UInt8] = []
            out += FoundrySigning.lengthPrefixed(kind)
            out += FoundrySigning.bigEndian(UInt32(fields.count))
            for field in fields {
                out += FoundrySigning.lengthPrefixed(field.name)
                out += FoundrySigning.lengthPrefixed(field.value)
            }
            return out
        }
    }

    static func lengthPrefixed(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return bigEndian(UInt32(bytes.count)) + bytes
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// `domain_tag ‖ u16_be(format_version) ‖ canonical(body)` — and nothing else.
    static func preimage(tag: String, body: CanonicalBody) -> [UInt8] {
        Array(tag.utf8)
            + [UInt8(formatVersion >> 8), UInt8(formatVersion & 0xFF)]
            + body.canonicalBytes
    }

    /// The bytes BIP-340 actually signs.
    ///
    /// **Double SHA-256, and this is not a mistake.** `foundry_signing::sign` computes
    /// `digest = SHA-256(preimage)` and hands that to `k256`'s `Signer::try_sign`, whose
    /// implementation is `try_sign_digest(Sha256::new_with_prefix(msg))` — so the message
    /// BIP-340 ends up over is `SHA-256(digest)`. Read out of
    /// `k256-0.13.4/src/schnorr/signing.rs:225-228` and `:180-183`, and confirmed against a
    /// signature produced by that crate over this exact body. Signing the single hash
    /// produces a proof the relay refuses, with bytes identical to every other refusal.
    static func message(tag: String, body: CanonicalBody) -> [UInt8] {
        let digest = Array(SHA256.hash(data: Data(preimage(tag: tag, body: body))))
        return Array(SHA256.hash(data: Data(digest)))
    }

    static func sign(_ key: Secp256k1.SigningKey, tag: String, body: CanonicalBody) -> String {
        key.signBIP340(message: message(tag: tag, body: body))
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: the two bodies

    /// `identity::connect_body`. Seven fields, in this order, each one carried as its own
    /// canonical field rather than concatenated into a prologue string.
    ///
    /// The sixth field was `nonce` until foundry main `6de3bb3c` made the value the RELAY'S
    /// to issue. It is renamed IN PLACE — same position, same order, same encoder — because
    /// the field NAME is inside the length-prefixed pre-image: a client still writing `nonce`
    /// signs a different message and its proof simply does not verify. MEASURED, not
    /// reasoned about — putting `nonce` back here while everything else stayed correct made
    /// the door decide `unproven-identity`, which on the wire is the same 403 as every other
    /// refusal. See `ConnectIdentity` for where the value now comes from.
    static func connectBody(identityKeyHex: String,
                            normalizedHost: String,
                            communityPid: String,
                            negotiatedVersion: UInt16,
                            locationId: String,
                            challengeHex: String,
                            timestamp: UInt64) -> CanonicalBody {
        CanonicalBody(kind: "fx.relay.connect")
            .with("identity", identityKeyHex)
            .with("origin", originScheme + normalizedHost)
            .with("community", communityPid)
            .with("version", String(negotiatedVersion))
            .with("location", locationId)
            .with("challenge", challengeHex)
            .with("timestamp", String(timestamp))
    }

    /// `foundry_spaces::entry::body_of`. Every field of the entry except the signature.
    static func membershipBody(seq: UInt64,
                               kind: String,
                               space: String,
                               ownerWire: String,
                               subject: String,
                               subjectPid: String,
                               role: String,
                               horizon: String,
                               ownedBySpace: Bool,
                               prevHex: String,
                               signerPid: String) -> CanonicalBody {
        CanonicalBody(kind: "fx.space.membership.entry")
            .with("seq", String(seq))
            .with("kind", kind)
            .with("space", space)
            .with("owner", ownerWire)
            .with("subject", subject)
            .with("subject_pid", subjectPid)
            .with("role", role)
            .with("horizon", horizon)
            .with("owned_by_space", ownedBySpace ? "1" : "0")
            .with("prev", prevHex)
            .with("signer", signerPid)
    }
}
