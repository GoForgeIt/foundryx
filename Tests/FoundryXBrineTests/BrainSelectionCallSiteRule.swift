import Foundation

/// WHY THIS FILE EXISTS.
///
/// `RootGate.destination(…)` decides where a finished voice note lands, and the rung that
/// degrades a chosen-but-unresolved brain to a PAIRED vault is the fix for live data loss:
/// captures were routed to a phone-only no-op that self-issued ACKs and advanced the durable
/// upload watermark, so bytes never moved and could never be re-sent.
///
/// That rung is decided in `RootGate` — which `swift test` executes — but it is ARMED by one
/// argument written in `App/RootView.swift`, which `swift test` CANNOT COMPILE AT ALL. The only
/// thing holding that argument was a SUBSTRING assertion:
///
///     XCTAssertTrue(rootView.contains("cellPaired: cells.isPaired"))
///
/// An adversarial cross-vendor review (Codex 5.6 sol) produced the one-line mutation that
/// defeats it, and it was confirmed by reading the source:
///
///     cellPaired: cells.isPaired && false)
///
/// That line STILL CONTAINS the asserted substring. The suite stays green, and the paired-vault
/// rung becomes unreachable in the shipping app — the original defect, restored, invisibly.
/// A check that reports success whether or not the harm occurred is not a check.
///
/// So the DECISION — what counts as an acceptable arming of that argument — lives HERE, in a
/// pure function over source text that Brine can execute, instead of in a substring the mutation
/// survives. The test feeds it the real `App/RootView.swift` AND a family of mutants, and
/// requires the real one green and every mutant RED.
public enum BrainSelectionCallSiteRule {

    public enum Verdict: Equatable {
        /// The call site is present and the argument is an unconditioned predicate.
        case ok(argument: String)
        /// `RootGate.destination(` does not appear — the routing decision left this file.
        case callSiteMissing
        /// The call site is there but names no `cellPaired:` argument.
        case argumentMissing
        /// The argument is present but has been CONDITIONED or replaced by a constant —
        /// this is the mutation family that made the old substring check vacuous.
        case argumentNeutralised(argument: String, offendingToken: String)
    }

    /// Tokens that turn a live predicate into something that can never arm the rung. `!= nil` is
    /// deliberately NOT here: it is how an optional-returning resolver is asked, and it stays
    /// live. Boolean operators and literals are, because each of them can pin the argument to a
    /// constant while leaving the identifier text in place for a substring check to find.
    static let forbidden = ["&&", "||", "true", "false", "??", "? "]

    /// The argument text as written, or nil when the call site or the argument is absent.
    public static func cellPairedArgument(in source: String) -> String? {
        guard let argumentList = destinationArgumentList(in: source) else { return nil }
        guard let range = argumentList.range(of: "cellPaired:") else { return nil }
        return argumentList[range.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n)"))
    }

    public static func verdict(for source: String) -> Verdict {
        guard let argumentList = destinationArgumentList(in: source) else { return .callSiteMissing }
        guard argumentList.contains("cellPaired:") else { return .argumentMissing }
        guard let argument = cellPairedArgument(in: source), !argument.isEmpty else {
            return .argumentMissing
        }
        for token in forbidden where argument.contains(token) {
            return .argumentNeutralised(argument: argument, offendingToken: token)
        }
        return .ok(argument: argument)
    }

    /// The text BETWEEN the parentheses of the `RootGate.destination(` call, found by balancing
    /// parens rather than by reading to the first `)` — the argument may itself be a call, and a
    /// naive scan would truncate it and read as "neutralised" for the wrong reason.
    private static func destinationArgumentList(in source: String) -> String? {
        guard let call = source.range(of: "RootGate.destination(") else { return nil }
        var depth = 0
        var index = source.index(before: call.upperBound)   // the opening paren
        var out = ""
        while index < source.endIndex {
            let character = source[index]
            if character == "(" {
                depth += 1
                if depth == 1 {
                    index = source.index(after: index)
                    continue
                }
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return out }
            }
            out.append(character)
            index = source.index(after: index)
        }
        return nil   // unbalanced — treat as absent rather than guess
    }
}
