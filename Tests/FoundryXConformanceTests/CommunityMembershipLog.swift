import Foundation
import CryptoKit

/// The community's signed membership log, written by this harness.
///
/// ## Why the fixture has to write one at all
///
/// The relay's enrolment step (`crates/foundry-relay/src/membership.rs`) does not read a
/// table and holds no cache: it reads `communities/<community_pid>.log` out of the
/// deployment directory and FOLDS it, on every connection, with `Roster::project`. A
/// deployment that binds a host to a community it holds no signed log for cannot say who
/// is in it, and the fail-closed answer to "I cannot say" is no — so a fixture that writes
/// bindings and no log is a fixture whose every client is refused.
///
/// ## The three things the fold checks, and why entry zero is not decoration
///
/// `Roster::project` gives an entry effect only when all three hold, and
/// `membership::fold` adds a fourth on top:
///
///  1. **signed** — the signature covers the entry under `fx/auth/membership/v1`;
///  2. **chained** — `seq == position` and `prev` is the previous entry's digest, thirty-two
///     zero bytes at entry zero;
///  3. **entitled** — entry zero must be a `Found` whose signer IS its owner; every later
///     membership act must be signed by a member who holds the admit authority (`founder`
///     or `admin`) AT THAT POINT in the fold;
///  4. **founding binds** — `entries[0].kind == Found && entries[0].owner.pid() ==
///     community_pid`. Reading a file by its NAME and trusting its contents is trusting
///     whoever could write the file, so a log founded by any other key authorizes nobody
///     here however well-signed it is.
///
/// That last one is why `RelayProcessFixture.communityPid` can no longer be a made-up
/// string of `ab`s: the community's identity IS its founding key, so the pid the bindings
/// file carries has to be the x-only public half of the key that signed entry zero.
///
/// ## Two entries, not one
///
/// The community founder and the connecting client are DIFFERENT principals here, which
/// costs one extra entry and buys two things: the fold's `Admit` entitlement path is
/// actually exercised (a one-entry log where the founder is also the client would leave it
/// unexercised), and the client's key is a plain member rather than the community's own
/// key — which is what a real door presenting a location's key looks like.
struct CommunityMembershipLog {

    /// One line of the log, in `foundry-spaces`' own strict format.
    ///
    /// The reader knows eleven field names, refuses a twelfth by name, requires the line to
    /// begin `seq=`, and refuses a repeated field — so this is rendered from the same
    /// ordered list the signature covers rather than assembled ad hoc.
    struct Entry {
        let seq: UInt64
        let kind: String
        let space: String
        let ownerWire: String
        let subject: String
        let subjectPid: String
        let role: String
        let horizon: String
        let ownedBySpace: Bool
        let prevHex: String
        let signerPid: String
        let signatureHex: String

        fileprivate var body: FoundrySigning.CanonicalBody {
            FoundrySigning.membershipBody(seq: seq, kind: kind, space: space, ownerWire: ownerWire,
                                          subject: subject, subjectPid: subjectPid, role: role,
                                          horizon: horizon, ownedBySpace: ownedBySpace,
                                          prevHex: prevHex, signerPid: signerPid)
        }

        /// What the NEXT entry carries as its `prev`: `SHA-256(canonical(body))` — over the
        /// canonical encoding alone, NOT over the pre-image. `Entry::digest` in
        /// `foundry-spaces` hashes `foundry_signing::canonical(&body)` with no domain tag
        /// and no format version in front of it, and a digest that included them would
        /// break the chain at entry one with no signature failing.
        var digestHex: String {
            Array(SHA256.hash(data: Data(body.canonicalBytes)))
                .map { String(format: "%02x", $0) }.joined()
        }

        var line: String {
            let pairs: [(String, String)] = [
                ("seq", String(seq)),
                ("kind", kind),
                ("space", space),
                ("owner", ownerWire),
                ("subject", subject),
                ("subject_pid", subjectPid),
                ("role", role),
                ("horizon", horizon),
                ("owned_by_space", ownedBySpace ? "1" : "0"),
                ("prev", prevHex),
                ("signer", signerPid),
            ]
            return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: " ") + " sig=\(signatureHex)"
        }
    }

    static let zeroDigest = String(repeating: "00", count: 32)

    /// The whole file: a community founded by `founder`, which then admits `member`.
    ///
    /// The founder's key IS the community pid — see the type's note on the founding
    /// binding — so the caller does not pass the pid separately and cannot pass one that
    /// disagrees with the key that signed entry zero.
    static func text(founder: Secp256k1.SigningKey,
                     memberPid: String,
                     memberName: String) -> String {
        let community = founder.publicKeyHex
        let owner = "organisation:\(community)"

        let found = signed(seq: 0, kind: "found", space: community, ownerWire: owner,
                           subject: "founder", subjectPid: community,
                           // `founder` is one of the two roles `holds_admit_authority`
                           // reads, and entry one is only entitled because of it.
                           role: "founder", horizon: "forward", ownedBySpace: false,
                           prevHex: zeroDigest, key: founder)

        let admit = signed(seq: 1, kind: "admit", space: community, ownerWire: owner,
                           subject: memberName, subjectPid: memberPid,
                           role: "member", horizon: "forward", ownedBySpace: false,
                           prevHex: found.digestHex, key: founder)

        return found.line + "\n" + admit.line + "\n"
    }

    private static func signed(seq: UInt64, kind: String, space: String, ownerWire: String,
                               subject: String, subjectPid: String, role: String,
                               horizon: String, ownedBySpace: Bool, prevHex: String,
                               key: Secp256k1.SigningKey) -> Entry {
        // The SIGNER is the key's own public half, never a value passed in: an entry that
        // could claim to have been signed by somebody else would not verify, and building
        // one here would only produce a fixture that fails for a reason nobody meant.
        let body = FoundrySigning.membershipBody(
            seq: seq, kind: kind, space: space, ownerWire: ownerWire, subject: subject,
            subjectPid: subjectPid, role: role, horizon: horizon, ownedBySpace: ownedBySpace,
            prevHex: prevHex, signerPid: key.publicKeyHex)
        return Entry(seq: seq, kind: kind, space: space, ownerWire: ownerWire, subject: subject,
                     subjectPid: subjectPid, role: role, horizon: horizon,
                     ownedBySpace: ownedBySpace, prevHex: prevHex, signerPid: key.publicKeyHex,
                     signatureHex: FoundrySigning.sign(key, tag: FoundrySigning.membershipTag, body: body))
    }
}
