import Foundation

/// The return type of an external-dependency predicate (T25 `spec.md` §5).
///
/// `plan.md` §7.1's exchange has five acts; this spec "fixes act 3's return type: the
/// author supplies a *claim*; the *status* is the exit code of a named predicate that
/// we run at that SHA". This is that status, as a value rather than as prose.
///
/// A predicate is `closed` when the fix it names is actually in place, `open` (RED)
/// when it is not, and `refused` when the predicate could not be run at all. REFUSED
/// IS NOT OPEN AND IT IS NOT CLOSED: a probe that could not execute must not publish
/// a value in either direction, which is the discipline that keeps a broken harness
/// from being recorded as a finding about the subject.
enum PredicateStatus: String, Equatable {
    case closed = "CLOSED"
    case open = "OPEN"      // RED
    case refused = "REFUSED"
}

struct PredicateOutcome {
    /// `P1` / `P2` / `P3`, as `spec.md` §5 names them.
    let name: String
    let title: String
    let status: PredicateStatus
    /// How many cases the predicate actually drove. Asserted as a number by the
    /// criteria that own each predicate — never inferred from the absence of a failure.
    let casesExecuted: Int
    /// The predicate's own captured output, recorded with the result. A9 requires the
    /// three reds to be "recorded with their output"; this is that output.
    let output: String

    var isRed: Bool { status == .open }

    var line: String {
        "\(name) \(status.rawValue) casesExecuted=\(casesExecuted) — \(title)"
    }
}
