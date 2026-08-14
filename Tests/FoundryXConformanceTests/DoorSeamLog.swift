import Foundation

/// The door's CQRS seam log, read from the deployment directory this harness created.
///
/// ## Why an element reads a file at all, when every other one reads a socket
///
/// Every refusal this relay makes writes the SAME BYTES — one `REFUSAL_RESPONSE` constant,
/// no per-cause status, phrase, header or length, across all eighteen causes
/// (`serve::RefusalCause::ALL`). That is deliberate and it is load-bearing: it is what
/// stops an unauthenticated caller using the door as an oracle for "is this key enrolled
/// here". This target must not ask for it to be weakened.
///
/// But it has a cost, and the cost lands exactly on `host-binding-before-upgrade`. On the
/// wire, "nobody bound that address" and "your proof did not verify" and "your offer was
/// gibberish" are one answer, so a drive that only observes a 403 at an unbound address is
/// satisfied by a relay that refused for a reason that has nothing to do with host
/// binding. The element's claim is not "the unbound address was refused" — it is "host-bound
/// tenancy is what was ESTABLISHED, before the socket upgraded".
///
/// The relay answers that question, in a place a caller on the wire cannot reach: it
/// records, per connection, which SEAM took the decision (`admit-connection` on the command
/// side, `resolve-principal` on the query side), the normalized host it derived, and — on a
/// refusal — the CONJUNCT that decided. The sink is a file inside the deployment directory
/// (`seam/auth.log`), and **no HTTP route serves it**, for the same reason the counters are
/// not served. This harness owns the deployment directory, so it can read what the door
/// wrote without the door growing a route that would undo the generic refusal.
///
/// ## The in-process counter, and why it is not what this uses
///
/// `Serving::resolver_lookups_attempted()` exists for this kind of question, and it is not
/// reachable here: it is an accessor on an in-process handle, this harness holds a spawned
/// PROCESS, and no route exposes it. It would also answer a different question than the one
/// this element asks — `tenancy::resolve_binding` records the lookup FIRST, "before anything
/// can return early", so a BOUND and an UNBOUND host both move it and only a host refused
/// by the guard ABOVE the lookup (an empty one) leaves it still. The seam log names the
/// deciding conjunct, which is the thing that actually separates the causes.
///
/// ## What this file must not become
///
/// A reader of this log can tell every refusal apart, so nothing here may be exported to a
/// client that is meant to be outside. It is read by the harness, from a directory the
/// harness made, about a relay the harness started.
enum DoorSeamLog {

    /// One decision the door took about one connection. Only the fields this target reads
    /// are declared; a record that grows a field is not this reader's business.
    struct Entry: Decodable {
        /// `query` or `command`. The CQRS split, in the record.
        let side: String
        /// `prove-identity`, `resolve-principal`, or `admit-connection`.
        let seam: String
        /// A digest of the pre-upgrade request head, `conn:<16 hex>` — which connection,
        /// without being the connection.
        let connectionBinding: String
        /// The NORMALIZED host the relay derived. Empty when it refused before normalizing.
        let host: String
        let communityPid: String
        let negotiatedVersion: String
        /// `accept` or `refuse`.
        let outcome: String
        /// Which conjunct decided. Empty exactly when the outcome is an accept.
        let decidingConjunct: String
        let resolvedPrincipal: String
        let resolvedRole: String
    }

    /// The seam this target's host-binding element reads: the command that admits or
    /// refuses the connection.
    static let admitConnection = "admit-connection"
    /// The query that resolves a proven key to a member of the community.
    static let resolvePrincipal = "resolve-principal"
    /// The conjunct the door names when a well-formed host is one the deployment does not
    /// bind — `serve::RefusalCause::UnmappedHost.name()`.
    static let unmappedHost = "unmapped-host"
    static let accept = "accept"
    static let refuse = "refuse"

    /// Every decision in the log, in the order they were written.
    ///
    /// An absent or unreadable log THROWS. It is not an empty list: "the door decided
    /// nothing" and "the harness could not read what it decided" are different facts, and
    /// returning `[]` for the second would let a part quietly report `unmet` from a probe
    /// that never happened.
    static func read(at url: URL?) throws -> [Entry] {
        guard let url else {
            throw ConformanceStepError("the harness has no deployment directory, so it cannot read what the door decided")
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ConformanceStepError("""
            the door's seam log is not at \(url.path). The relay writes one record per decision \
            to `<deployment>/seam/auth.log` and opens the sink PER DECISION, so an absent file \
            means no decision was taken — not that the decisions were clean.
            """)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var out: [Entry] = []
        for (index, line) in String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)) else {
                throw ConformanceStepError("the door's seam log line \(index + 1) is not a decision this reader knows: \(line)")
            }
            out.append(entry)
        }
        return out
    }
}
