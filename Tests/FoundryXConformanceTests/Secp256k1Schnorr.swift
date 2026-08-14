import Foundation
import CryptoKit

/// BIP-340 Schnorr over secp256k1, written here rather than imported.
///
/// ## Why this exists at all
///
/// The relay's auth middle (`crates/foundry-relay/src/identity.rs`) refuses a connection
/// that cannot prove possession of the key it presents, and the proof is a BIP-340
/// Schnorr signature over secp256k1. `10-system-design.md:445` REJECTS Ed25519 by name,
/// so there is no second scheme to fall back to: a client that cannot make this
/// signature cannot be admitted, and the three elements that turn on admission cannot be
/// driven.
///
/// ## Why it is not a dependency
///
/// This package holds no secp256k1 primitive of any kind — `grep -rn secp256k1 Sources
/// Tests` is empty, CryptoKit ships P-256 and Curve25519 and neither is this curve, and
/// swift-crypto does not carry secp256k1 either. So the choice was between adding a
/// third-party package to a security-bearing target and writing the primitive where it
/// can be read. It is written here, and the reasons are specific rather than a
/// preference:
///
///  * **This target's whole discipline is a client that does not agree with the relay by
///    construction.** `P3Client`'s own header says it "deliberately speaks raw bytes
///    rather than reusing any FoundryXKit transport", because "a client built out of the
///    same types the relay's counterpart uses would agree with it by construction". The
///    same argument reaches the signature: signing with the relay's own crate would prove
///    that crate agrees with itself.
///  * **It is test-only and it is not a package dependency.** Nothing shipped links this
///    file. Adding a SwiftPM dependency would put a third-party curve implementation into
///    `Package.swift`, where the shipped library and the app resolve it too.
///  * **The oracle is external and unforgiving.** A signature this file gets wrong is
///    refused by a relay built from another language's implementation (`k256`), so there
///    is no shape of this file that is quietly wrong and green. That is a stronger check
///    than a self-test, and it is the check this target already runs.
///
/// If a shipped consumer ever needs secp256k1, THAT is the moment to weigh a vetted
/// dependency — this file is scoped to the conformance client and should not grow into
/// one.
///
/// ## What the relay actually verifies, taken from its source and not from prose
///
/// `foundry-signing`'s two entry points do this and nothing else:
///
/// ```text
/// preimage = domain_tag_utf8 ‖ u16_be(FORMAT_VERSION=1) ‖ canonical(body)
/// digest   = SHA-256(preimage)
/// signature = k256::schnorr::SigningKey::sign(digest)
/// ```
///
/// and `k256 0.13.4`'s `Signer::try_sign(msg)` is
/// `try_sign_digest(Sha256::new_with_prefix(msg))` → `sign_raw(SHA-256(msg), [0u8; 32])`.
///
/// **So the message BIP-340 signs is `SHA-256(SHA-256(preimage))` — the digest is hashed
/// AGAIN — and the auxiliary randomness is thirty-two ZERO bytes, which makes the whole
/// signature deterministic.** Both facts were read out of
/// `~/.cargo/registry/.../k256-0.13.4/src/schnorr/signing.rs:97-130,180-183`, not assumed;
/// the single-hash reading and a random-aux reading both produce a signature the relay
/// refuses, and they are refused with the SAME bytes as every other cause, so getting
/// this wrong is indistinguishable on the wire from not having tried.
///
/// The domain tag is a PREFIX INSIDE THE PRE-IMAGE. It is not the BIP-340 tag: the
/// BIP-340 tags are the scheme's own three (`BIP0340/aux`, `BIP0340/nonce`,
/// `BIP0340/challenge`) and they are not configurable.
enum Secp256k1 {

    // MARK: the curve

    /// p = 2^256 − 2^32 − 977. The field's characteristic.
    static let p = U256(l0: 0xFFFF_FFFE_FFFF_FC2F,
                        l1: 0xFFFF_FFFF_FFFF_FFFF,
                        l2: 0xFFFF_FFFF_FFFF_FFFF,
                        l3: 0xFFFF_FFFF_FFFF_FFFF)

    /// The group order.
    static let n = U256(l0: 0xBFD2_5E8C_D036_4141,
                        l1: 0xBAAE_DCE6_AF48_A03B,
                        l2: 0xFFFF_FFFF_FFFF_FFFE,
                        l3: 0xFFFF_FFFF_FFFF_FFFF)

    /// p = 2^256 − C. Reduction folds the high half back in by multiplying by C.
    static let reductionConstant: UInt64 = 0x1_0000_03D1

    static let gX = U256(l0: 0x59F2_815B_16F8_1798,
                         l1: 0x029B_FCDB_2DCE_28D9,
                         l2: 0x55A0_6295_CE87_0B07,
                         l3: 0x79BE_667E_F9DC_BBAC)

    static let gY = U256(l0: 0x9C47_D08F_FB10_D4B8,
                         l1: 0xFD17_B448_A685_5419,
                         l2: 0x5DA4_FBFC_0E11_08A8,
                         l3: 0x483A_DA77_26A3_C465)

    // MARK: the two things a client needs

    /// A signing key, and the x-only public half the relay reads as a principal id.
    struct SigningKey {
        /// The normalized secret scalar `d`: BIP-340 keeps the one whose public point has
        /// an even y, so the x-only public key determines the point without a sign byte.
        fileprivate let d: U256
        /// The public point, cached. Deriving it costs a scalar multiplication and every
        /// signature needs it.
        fileprivate let publicPoint: AffinePoint

        /// The x-only public key, 64 lower-case hex characters — the encoding BIP-340
        /// uses, the encoding `Pid` carries, and the encoding
        /// `identity::IDENTITY_HEADER` is checked against.
        let publicKeyHex: String

        /// A key from 32 bytes of secret material. Refuses zero and anything ≥ n, which
        /// are not secret keys.
        init?(secretBytes: [UInt8]) {
            guard secretBytes.count == 32 else { return nil }
            let raw = U256(bigEndian: secretBytes)
            guard !raw.isZero, U256.compare(raw, Secp256k1.n) < 0 else { return nil }
            let point = Secp256k1.scalarMultiplyBase(raw)
            // BIP-340: if the public point has an odd y, use n − d instead, so that the
            // x-only encoding is unambiguous.
            if point.y.isEven {
                self.d = raw
                self.publicPoint = point
            } else {
                self.d = Secp256k1.subModN(Secp256k1.n, raw)
                self.publicPoint = AffinePoint(x: point.x, y: Secp256k1.fpSub(Secp256k1.p, point.y))
            }
            self.publicKeyHex = self.publicPoint.x.hexString
        }

        /// A fresh key from the system's randomness.
        static func generate() -> SigningKey {
            while true {
                var bytes = [UInt8](repeating: 0, count: 32)
                for i in 0..<32 { bytes[i] = UInt8.random(in: 0...255) }
                if let key = SigningKey(secretBytes: bytes) { return key }
            }
        }

        /// Sign `message` under BIP-340, with the thirty-two zero bytes of auxiliary
        /// randomness `k256`'s `Signer` impl uses. Deterministic, and byte-identical to
        /// what the relay's own crate would have produced for the same key and message.
        func signBIP340(message: [UInt8]) -> [UInt8] {
            Secp256k1.sign(d: d, publicPoint: publicPoint, message: message)
        }
    }

    /// `SHA-256(tag) ‖ SHA-256(tag) ‖ data`, hashed — BIP-340's tagged hash.
    static func taggedHash(_ tag: String, _ data: [UInt8]) -> [UInt8] {
        let t = Array(SHA256.hash(data: Data(tag.utf8)))
        return Array(SHA256.hash(data: Data(t + t + data)))
    }

    private static func sign(d: U256, publicPoint: AffinePoint, message: [UInt8]) -> [UInt8] {
        let auxRand = [UInt8](repeating: 0, count: 32)
        // t = d XOR tagged_hash("BIP0340/aux", aux)
        let auxHash = taggedHash("BIP0340/aux", auxRand)
        let dBytes = d.bigEndianBytes
        var t = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { t[i] = dBytes[i] ^ auxHash[i] }

        let pxBytes = publicPoint.x.bigEndianBytes
        let rand = taggedHash("BIP0340/nonce", t + pxBytes + message)
        // BIP-340 reduces mod n here; `k256` refuses a value ≥ n instead. The two agree
        // on every input either will ever see (they differ with probability ~2^-128) and
        // reducing is the spec's own text.
        let k0 = reduceModN(U256(bigEndian: rand))
        // A zero nonce is not a signature. It cannot be reached from a hash in practice;
        // it is refused rather than silently producing a value the relay would reject.
        precondition(!k0.isZero, "BIP-340 produced a zero nonce, which is not signable")

        let rPoint = scalarMultiplyBase(k0)
        let k = rPoint.y.isEven ? k0 : subModN(n, k0)
        let rxBytes = rPoint.x.bigEndianBytes

        let e = reduceModN(U256(bigEndian: taggedHash("BIP0340/challenge", rxBytes + pxBytes + message)))
        let s = addModN(k, mulModN(e, d))
        return rxBytes + s.bigEndianBytes
    }

    // MARK: field arithmetic, mod p

    fileprivate static func fpAdd(_ a: U256, _ b: U256) -> U256 {
        let (sum, carry) = U256.addingReportingOverflow(a, b)
        if carry || U256.compare(sum, p) >= 0 { return U256.wrappingSubtract(sum, p) }
        return sum
    }

    fileprivate static func fpSub(_ a: U256, _ b: U256) -> U256 {
        let (diff, borrow) = U256.subtractingReportingOverflow(a, b)
        if borrow { return U256.wrappingAdd(diff, p) }
        return diff
    }

    fileprivate static func fpMul(_ a: U256, _ b: U256) -> U256 {
        let product = U256.multipliedFullWidth(a, b)
        return reduceModP(hi: product.hi, lo: product.lo)
    }

    fileprivate static func fpSquare(_ a: U256) -> U256 { fpMul(a, a) }

    /// `hi·2^256 + lo` reduced mod p, using p = 2^256 − C: the high half folds back in as
    /// `hi·C`, which is at most 289 bits, so two folds and a conditional subtract finish
    /// it. No division anywhere.
    private static func reduceModP(hi: U256, lo: U256) -> U256 {
        let (folded, overflow) = U256.multipliedBySmall(hi, reductionConstant)
        var (r, carry) = U256.addingReportingOverflow(lo, folded)
        var top = overflow &+ (carry ? 1 : 0)
        while top != 0 {
            let piece = top.multipliedFullWidth(by: reductionConstant)
            let addend = U256(l0: piece.low, l1: piece.high, l2: 0, l3: 0)
            (r, carry) = U256.addingReportingOverflow(r, addend)
            top = carry ? 1 : 0
        }
        while U256.compare(r, p) >= 0 { r = U256.wrappingSubtract(r, p) }
        return r
    }

    /// `a^(p−2) mod p`, which is `a^-1` for every non-zero a. Square-and-multiply over the
    /// exponent's bits — a small number of these run per signature and none is on a path
    /// where its cost matters.
    private static func fpInverse(_ a: U256) -> U256 {
        let exponent = U256.wrappingSubtract(p, U256(l0: 2, l1: 0, l2: 0, l3: 0))
        var result = U256(l0: 1, l1: 0, l2: 0, l3: 0)
        var index = 255
        while index >= 0 {
            result = fpSquare(result)
            if exponent.bit(index) { result = fpMul(result, a) }
            index -= 1
        }
        return result
    }

    // MARK: scalar arithmetic, mod n

    fileprivate static func addModN(_ a: U256, _ b: U256) -> U256 {
        let (sum, carry) = U256.addingReportingOverflow(a, b)
        if carry || U256.compare(sum, n) >= 0 { return U256.wrappingSubtract(sum, n) }
        return sum
    }

    fileprivate static func subModN(_ a: U256, _ b: U256) -> U256 {
        let (diff, borrow) = U256.subtractingReportingOverflow(a, b)
        if borrow { return U256.wrappingAdd(diff, n) }
        return diff
    }

    fileprivate static func mulModN(_ a: U256, _ b: U256) -> U256 {
        let product = U256.multipliedFullWidth(a, b)
        return modN(hi: product.hi, lo: product.lo)
    }

    fileprivate static func reduceModN(_ a: U256) -> U256 {
        modN(hi: U256.zero, lo: a)
    }

    /// `hi·2^256 + lo mod n`, bit by bit. n has no special form, so there is no folding
    /// trick here — and there does not need to be: this runs three times per signature
    /// while the field multiply runs thousands of times.
    private static func modN(hi: U256, lo: U256) -> U256 {
        var r = U256.zero
        var index = 511
        while index >= 0 {
            let bit = index >= 256 ? hi.bit(index - 256) : lo.bit(index)
            let (shifted, carriedOut) = U256.shiftedLeftOne(r)
            r = shifted
            if bit { r.l0 |= 1 }
            // The value in hand is `carriedOut·2^256 + r`. A carry out means it exceeds
            // 2^256 > n, so one subtraction always suffices — the invariant r < n going in
            // makes 2r+1 < 2n, and 2n − n is n.
            if carriedOut || U256.compare(r, n) >= 0 { r = U256.wrappingSubtract(r, n) }
            index -= 1
        }
        return r
    }

    // MARK: the group

    fileprivate struct AffinePoint {
        var x: U256
        var y: U256
    }

    /// Jacobian coordinates: `(X : Y : Z)` stands for the affine `(X/Z², Y/Z³)`, and
    /// `Z == 0` is the point at infinity. Inversion is what costs; Jacobian arithmetic
    /// needs exactly one, at the very end.
    private struct JacobianPoint {
        var x: U256
        var y: U256
        var z: U256
        static let infinity = JacobianPoint(x: U256.one, y: U256.one, z: U256.zero)
        var isInfinity: Bool { z.isZero }
    }

    private static func double(_ point: JacobianPoint) -> JacobianPoint {
        if point.isInfinity || point.y.isZero { return .infinity }
        let a = fpSquare(point.y)
        let b = fpMul(fpMul(point.x, a), U256(l0: 4, l1: 0, l2: 0, l3: 0))
        let c = fpMul(fpSquare(a), U256(l0: 8, l1: 0, l2: 0, l3: 0))
        let d = fpMul(fpSquare(point.x), U256(l0: 3, l1: 0, l2: 0, l3: 0))
        let x3 = fpSub(fpSquare(d), fpAdd(b, b))
        let y3 = fpSub(fpMul(d, fpSub(b, x3)), c)
        let z3 = fpMul(fpAdd(point.y, point.y), point.z)
        return JacobianPoint(x: x3, y: y3, z: z3)
    }

    /// Jacobian + affine. The only point ever added here is the generator, which is
    /// affine, so the mixed form is the whole of what is needed.
    private static func addMixed(_ point: JacobianPoint, _ other: AffinePoint) -> JacobianPoint {
        if point.isInfinity { return JacobianPoint(x: other.x, y: other.y, z: U256.one) }
        let zz = fpSquare(point.z)
        let u2 = fpMul(other.x, zz)
        let s2 = fpMul(fpMul(other.y, point.z), zz)
        if u2 == point.x {
            if s2 == point.y { return double(point) }
            return .infinity
        }
        let h = fpSub(u2, point.x)
        let hh = fpSquare(h)
        let i = fpMul(hh, U256(l0: 4, l1: 0, l2: 0, l3: 0))
        let j = fpMul(h, i)
        let r = fpAdd(fpSub(s2, point.y), fpSub(s2, point.y))
        let v = fpMul(point.x, i)
        let x3 = fpSub(fpSub(fpSquare(r), j), fpAdd(v, v))
        let y1j = fpMul(point.y, j)
        let y3 = fpSub(fpMul(r, fpSub(v, x3)), fpAdd(y1j, y1j))
        let z3 = fpSub(fpSub(fpSquare(fpAdd(point.z, h)), zz), hh)
        return JacobianPoint(x: x3, y: y3, z: z3)
    }

    fileprivate static func scalarMultiplyBase(_ scalar: U256) -> AffinePoint {
        let generator = AffinePoint(x: gX, y: gY)
        var accumulator = JacobianPoint.infinity
        var index = 255
        while index >= 0 {
            accumulator = double(accumulator)
            if scalar.bit(index) { accumulator = addMixed(accumulator, generator) }
            index -= 1
        }
        precondition(!accumulator.isInfinity, "a scalar in 1..<n never multiplies the generator to infinity")
        let zInverse = fpInverse(accumulator.z)
        let zInverse2 = fpSquare(zInverse)
        return AffinePoint(x: fpMul(accumulator.x, zInverse2),
                           y: fpMul(accumulator.y, fpMul(zInverse2, zInverse)))
    }
}

// MARK: - 256-bit unsigned integers

/// Four 64-bit limbs, least significant first. Enough arithmetic for one curve and not a
/// general-purpose big integer: every operation here is one the signature needs.
struct U256: Equatable, Hashable {
    var l0: UInt64
    var l1: UInt64
    var l2: UInt64
    var l3: UInt64

    static let zero = U256(l0: 0, l1: 0, l2: 0, l3: 0)
    static let one = U256(l0: 1, l1: 0, l2: 0, l3: 0)

    /// From 32 bytes, most significant first — the encoding every key, scalar and hash on
    /// this wire uses.
    init(bigEndian bytes: [UInt8]) {
        precondition(bytes.count == 32, "a 256-bit value is 32 bytes")
        func word(_ start: Int) -> UInt64 {
            var out: UInt64 = 0
            for i in start..<(start + 8) { out = (out << 8) | UInt64(bytes[i]) }
            return out
        }
        self.l3 = word(0)
        self.l2 = word(8)
        self.l1 = word(16)
        self.l0 = word(24)
    }

    init(l0: UInt64, l1: UInt64, l2: UInt64, l3: UInt64) {
        self.l0 = l0; self.l1 = l1; self.l2 = l2; self.l3 = l3
    }

    var bigEndianBytes: [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        for (slot, word) in [l3, l2, l1, l0].enumerated() {
            for byte in 0..<8 { out[slot * 8 + byte] = UInt8((word >> (56 - 8 * byte)) & 0xFF) }
        }
        return out
    }

    var hexString: String { bigEndianBytes.map { String(format: "%02x", $0) }.joined() }

    var isZero: Bool { l0 == 0 && l1 == 0 && l2 == 0 && l3 == 0 }
    var isEven: Bool { l0 & 1 == 0 }

    func limb(_ index: Int) -> UInt64 {
        switch index {
        case 0: return l0
        case 1: return l1
        case 2: return l2
        default: return l3
        }
    }

    func bit(_ index: Int) -> Bool { (limb(index >> 6) >> UInt64(index & 63)) & 1 == 1 }

    static func compare(_ a: U256, _ b: U256) -> Int {
        for i in stride(from: 3, through: 0, by: -1) {
            let x = a.limb(i), y = b.limb(i)
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    static func addingReportingOverflow(_ a: U256, _ b: U256) -> (U256, Bool) {
        var out = U256.zero
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (partial, overflow1) = a.limb(i).addingReportingOverflow(b.limb(i))
            let (total, overflow2) = partial.addingReportingOverflow(carry)
            out.setLimb(i, total)
            carry = (overflow1 || overflow2) ? 1 : 0
        }
        return (out, carry == 1)
    }

    static func subtractingReportingOverflow(_ a: U256, _ b: U256) -> (U256, Bool) {
        var out = U256.zero
        var borrow: UInt64 = 0
        for i in 0..<4 {
            let (partial, underflow1) = a.limb(i).subtractingReportingOverflow(b.limb(i))
            let (total, underflow2) = partial.subtractingReportingOverflow(borrow)
            out.setLimb(i, total)
            borrow = (underflow1 || underflow2) ? 1 : 0
        }
        return (out, borrow == 1)
    }

    static func wrappingAdd(_ a: U256, _ b: U256) -> U256 { addingReportingOverflow(a, b).0 }
    static func wrappingSubtract(_ a: U256, _ b: U256) -> U256 { subtractingReportingOverflow(a, b).0 }

    static func shiftedLeftOne(_ a: U256) -> (U256, Bool) {
        var out = U256.zero
        var carry: UInt64 = 0
        for i in 0..<4 {
            let word = a.limb(i)
            out.setLimb(i, (word << 1) | carry)
            carry = word >> 63
        }
        return (out, carry == 1)
    }

    /// `a · small`, where `small` is under 2^34 — the low 256 bits and the overflow, which
    /// fits comfortably in one limb.
    static func multipliedBySmall(_ a: U256, _ small: UInt64) -> (U256, UInt64) {
        var out = U256.zero
        var carry: UInt64 = 0
        for i in 0..<4 {
            let wide = a.limb(i).multipliedFullWidth(by: small)
            let (total, overflow) = wide.low.addingReportingOverflow(carry)
            out.setLimb(i, total)
            carry = wide.high &+ (overflow ? 1 : 0)
        }
        return (out, carry)
    }

    /// The full 512-bit product, as its two halves. Schoolbook; correctness over speed,
    /// and the reduction that follows is what makes the field arithmetic cheap.
    static func multipliedFullWidth(_ a: U256, _ b: U256) -> (hi: U256, lo: U256) {
        var w = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let wide = a.limb(i).multipliedFullWidth(by: b.limb(j))
                let (s1, o1) = w[i + j].addingReportingOverflow(wide.low)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                w[i + j] = s2
                // `wide.high` is at most 2^64 − 2, so adding the two carry bits to it
                // cannot itself overflow.
                carry = wide.high &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            var k = i + 4
            while carry != 0 && k < 8 {
                let (sum, overflow) = w[k].addingReportingOverflow(carry)
                w[k] = sum
                carry = overflow ? 1 : 0
                k += 1
            }
        }
        return (hi: U256(l0: w[4], l1: w[5], l2: w[6], l3: w[7]),
                lo: U256(l0: w[0], l1: w[1], l2: w[2], l3: w[3]))
    }

    private mutating func setLimb(_ index: Int, _ value: UInt64) {
        switch index {
        case 0: l0 = value
        case 1: l1 = value
        case 2: l2 = value
        default: l3 = value
        }
    }
}
