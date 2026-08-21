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

    /// THREE RED, **read from the RECORDED baseline rather than from a live run of HEAD.**
    ///
    /// ## Re-pinned 2026-08-21, and why
    ///
    /// This used to re-derive "three reds" by running the predicates against HEAD, which made
    /// it an **anti-gate**: it could only pass while all three defects were still unfixed.
    /// Landing the mandatory door pin closed P1, so A9 went red *because the fix landed*, and
    /// its message read as an accusation against a predicate that was working perfectly.
    ///
    /// That is backwards. A9's subject is a HISTORICAL FACT — *at the baseline, before any
    /// reply was solicited, three predicates were executed and three were red* — and a
    /// historical fact does not stop being true when the defect is fixed.
    ///
    /// The branch that closed P1 deliberately did NOT touch this, recorded that nothing had
    /// been softened, and left the call to the integrator
    /// (`evidence/mandatory-client-pin/06-full-suite-differential.log`). This is that decision.
    ///
    /// **NOTHING IS SOFTENED.** The baseline is now read where it is immutable, and the live
    /// half of the claim — that P1 now REFUSES in both cases — is held by
    /// `P1ConformanceTests.testP1IsClosedBecauseTheClientRefusesInBothCases`. Both directions
    /// are still asserted, each by the check that can actually observe it.
    ///
    /// **THE PAIRED EXISTENCE ASSERTION IS THE POINT.** A check that reads a file looking for
    /// the absence of something passes vacuously when the file is missing or empty. So this
    /// asserts the record EXISTS and NAMES all three predicates first, and only then that each
    /// was OPEN. Delete the evidence and this goes red rather than quiet.
    func testAllThreePredicatesAreRedAtTheBaseline() throws {
        let record = BundlePredicates.repoRoot()
            .appendingPathComponent("evidence/mandatory-client-pin/02-P1-baseline-OPEN-before-the-fix.log")

        guard let text = try? String(contentsOf: record, encoding: .utf8), !text.isEmpty else {
            return XCTFail(
                """
                The baseline-red record is missing or empty at \(record.path).
                A9's entire subject is that record. Without it there is no evidence the gate \
                could ever fail, and this assertion must NOT pass by finding nothing.
                """)
        }

        // EXISTENCE FIRST, over the same population the prohibition below reads.
        for name in ["P1", "P2", "P3"] {
            XCTAssertTrue(text.contains("A9 baseline-red record: \(name) ["),
                "the baseline record does not contain \(name) at all; three predicates must be RECORDED before three can be red")
        }

        // ...then the redness of each, read from that same record.
        for name in ["P1", "P2", "P3"] {
            XCTAssertTrue(text.contains("A9 baseline-red record: \(name) [OPEN]"),
                """
                A9 requires all three predicates RED at the pinned baseline, and the recorded \
                baseline does not show \(name) as OPEN. A predicate that was green at the \
                baseline cannot fail and is therefore not a gate (spec.md §7 item 4).
                """)
        }

        print("=== A9 baseline-red record, read from \(record.lastPathComponent) ===")
        print(text)
    }

    /// The live leg, kept deliberately: the three predicates still EXECUTE against HEAD.
    ///
    /// Re-pinning the baseline to evidence must not quietly stop the predicates running — that
    /// would trade one vacuous pass for another. This asserts execution and says nothing about
    /// colour, which is what makes it safe to keep while the colours legitimately change.
    func testAllThreePredicatesStillExecuteAgainstHead() throws {
        let outcomes = try runAllThree()
        XCTAssertEqual(outcomes.count, 3,
            "three predicates must still execute against HEAD; \(outcomes.count) did")
        for o in outcomes {
            print("=== A9 live record: \(o.name) [\(o.status.rawValue)] casesExecuted=\(o.casesExecuted) ===")
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
