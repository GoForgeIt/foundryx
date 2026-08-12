import XCTest

/// T25 **A9** — *"All three predicates are RED at the pinned baseline, before any reply
/// is solicited. The negative control for the whole handshake: **three predicates
/// executed, three RED**, recorded with their output."*
///
/// This is the artifact `spec.md` §4 item 5 calls *"the baseline-red record … the
/// artifact that proves the handshake's gate can fail"*.
///
/// ## Why this is the criterion that matters most
///
/// Every other criterion in this track measures the FIX. This one measures the GATE.
/// A handshake whose predicates were never red proves nothing about the reply: if P2
/// had been written as a lookup of `GatewayHTTPURL`, or P3 as a grep for
/// `NSAllowsArbitraryLoads`, both would report the fix CLOSED at a baseline where the
/// plaintext relay leg and the insecure exception domain are both still shipping.
/// §5.2 and §5.3 name those two forms and forbid them. This test is what would catch
/// them.
///
/// The falsifying mutations the spec names, and which assertion each one reddens:
///
/// - *"Run the check after a predicate has been softened to pass at the baseline: the
///   three-RED assertion goes red naming which predicate came back green"*
///   -> `testAllThreePredicatesAreRedAtTheBaseline`, which names the predicate.
/// - *"solicit the author's reply before recording the baseline reds; the ordering
///   assertion goes red"* -> `testTheBaselineRedsPrecedeAnyReply`.
final class A9BaselineRedTests: XCTestCase {

    /// The three predicates, executed. P1 is the behavioural one and reuses the single
    /// run `P1World` performed — asserting over a second, separate run would let the
    /// count pass on one run and the redness on another.
    private func runAllThree() throws -> [PredicateOutcome] {
        let world = P1World.shared
        world.ensureRun()
        if let why = world.bringUpFailure {
            XCTFail("P1 could not be driven, so the three-predicate negative control did not run: \(why)")
            throw HardRefusal.refused
        }
        guard let p1 = world.outcome else {
            XCTFail("P1 produced no outcome")
            throw HardRefusal.refused
        }
        let outcomes = [p1, BundlePredicates.p2(), BundlePredicates.p3()]
        for o in outcomes where o.status == .refused {
            XCTFail("\(o.name) REFUSED rather than producing a status. A REFUSED predicate is neither red nor green, and the all-red record must not be assembled from one:\n\(o.output)")
            throw HardRefusal.refused
        }
        return outcomes
    }

    /// THREE PREDICATES EXECUTED — asserted as a number, never as the absence of a failure.
    func testThreePredicatesAreExecuted() throws {
        let outcomes = try runAllThree()
        XCTAssertEqual(outcomes.count, 3,
            "the handshake has three predicates (P1, P2, P3) and the negative control must execute all of them; \(outcomes.count) executed")
        XCTAssertEqual(Set(outcomes.map(\.name)), ["P1", "P2", "P3"],
            "the three executed predicates must be P1, P2 and P3; got \(outcomes.map(\.name).sorted())")
    }

    /// THREE RED. Softening any predicate to pass at the baseline reddens here, and the
    /// message NAMES the one that came back green — *"the one signal that separates
    /// 'the fix landed' from 'the gate stopped working'"*.
    func testAllThreePredicatesAreRedAtTheBaseline() throws {
        let outcomes = try runAllThree()
        let green = outcomes.filter { !$0.isRed }
        XCTAssertTrue(green.isEmpty,
            """
            A9 requires all three predicates RED at the pinned baseline. \
            \(green.count) came back GREEN: \(green.map(\.name).joined(separator: ", ")).
            A predicate that is green at the baseline cannot fail and is therefore not a \
            gate (spec.md §7 item 4). Fix the predicate; do not proceed to solicit a reply.
            \(outcomes.map { "\($0.line)\n\($0.output)" }.joined(separator: "\n---\n"))
            """)
        // "recorded with their output" — emitted on every run, not only on failure.
        for o in outcomes {
            print("=== A9 baseline-red record: \(o.name) [\(o.status.rawValue)] casesExecuted=\(o.casesExecuted) ===")
            print(o.output)
        }
    }

    /// The ordering leg: the reds are recorded BEFORE any reply is solicited.
    ///
    /// Falsifiable by construction — drop a reply record at the declared path and this
    /// goes red. *"a predicate first exercised against a claimed fix has never been
    /// shown to fail."*
    func testTheBaselineRedsPrecedeAnyReply() throws {
        let replyRecord = BundlePredicates.repoRoot()
            .appendingPathComponent("evidence/t25-handshake/author-reply.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: replyRecord.path),
            """
            A reply record already exists at \(replyRecord.path), so the baseline reds \
            recorded by this run were NOT taken before the author was asked. A predicate \
            first exercised against a claimed fix has never been shown to fail, and the \
            negative control it produces is worthless. Record the baseline reds first.
            """)
    }
}
