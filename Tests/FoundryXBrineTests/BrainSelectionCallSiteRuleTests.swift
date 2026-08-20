import XCTest
@testable import FoundryXKit

/// THE GUARD THAT COULD NOT FAIL, AND THE PROOF THAT THIS ONE CAN.
///
/// `BrainSelectionCompositionTests` held the arming of the paired-vault rung with
/// `XCTAssertTrue(rootView.contains("cellPaired: cells.isPaired"))`. An adversarial
/// cross-vendor review produced the one-line mutation that walks straight through it —
/// `cellPaired: cells.isPaired && false)` still CONTAINS that substring — and it was
/// confirmed by reading the source. The rung is unreachable in the shipping app and the
/// suite stays green, because `swift test` cannot compile `App/`.
///
/// So the decision moved into `BrainSelectionCallSiteRule`, and this file is the
/// ANTI-VACUITY PROOF for it: the real `App/RootView.swift` must be accepted, and every
/// member of the neutralising mutation family must be REJECTED. A rule that accepted the
/// mutants would be the same theatre wearing a different hat.
final class BrainSelectionCallSiteRuleTests: XCTestCase {

    /// A stand-in for the shape the real call site has, so the mutants below differ from
    /// the accepted text in exactly ONE way.
    private func callSite(cellPairedArgument: String) -> String {
        """
        let dest = RootGate.destination(signedIn: remote.isSignedIn,
                                        splashElapsed: enteredApp,
                                        brain: brains.choice,
                                        hostResolved: remote.makeDoorTarget() != nil,
                                        letStraightIn: WelcomePrefs.letStraightIn(),
                                        cellPaired: \(cellPairedArgument))
        return AnyView(bodyContent(dest))
        """
    }

    // MARK: - the positive control

    func testAnUnconditionedPredicateIsAccepted() {
        let source = callSite(cellPairedArgument: "cells.isPaired")
        XCTAssertEqual(BrainSelectionCallSiteRule.verdict(for: source),
                       .ok(argument: "cells.isPaired"))
    }

    func testAResolverCallIsAcceptedBecauseItStaysLive() {
        // `!= nil` is how an optional-returning resolver is asked. It must NOT be
        // mistaken for a neutralising token, or the rule would forbid the very shape
        // that makes the gate and the body agree.
        let argument = "CellBackend.usableTarget(config: cells.config, idToken: token) != nil"
        let source = callSite(cellPairedArgument: argument)
        XCTAssertEqual(BrainSelectionCallSiteRule.verdict(for: source), .ok(argument: argument))
    }

    // MARK: - THE MUTATION FAMILY. Each of these must be RED.

    func testTheReviewsExactMutationIsRejected() {
        // THIS IS THE ONE THE OLD SUBSTRING CHECK LET THROUGH.
        let source = callSite(cellPairedArgument: "cells.isPaired && false")
        guard case .argumentNeutralised(_, let token) =
                BrainSelectionCallSiteRule.verdict(for: source) else {
            return XCTFail("`cells.isPaired && false` was ACCEPTED — this rule is as vacuous "
                           + "as the substring check it replaced")
        }
        XCTAssertEqual(token, "&&")
    }

    func testEveryNeutralisingMutantIsRejected() {
        let mutants = [
            "cells.isPaired && false",
            "false",
            "true",
            "cells.isPaired || false",
            "cells.isPaired ? false : false",
        ]
        for mutant in mutants {
            let verdict = BrainSelectionCallSiteRule.verdict(for: callSite(cellPairedArgument: mutant))
            guard case .argumentNeutralised = verdict else {
                return XCTFail("the mutant `cellPaired: \(mutant)` was ACCEPTED (verdict "
                               + "\(verdict)) — it pins the rung to a constant while leaving "
                               + "the call site looking intact")
            }
        }
    }

    func testARemovedCallSiteIsRejectedRatherThanSilentlyPassing() {
        XCTAssertEqual(BrainSelectionCallSiteRule.verdict(for: "return AnyView(bodyContent(dest))"),
                       .callSiteMissing)
    }

    func testACallSiteThatDropsTheArgumentIsRejected() {
        let source = """
        let dest = RootGate.destination(signedIn: remote.isSignedIn,
                                        brain: brains.choice)
        """
        XCTAssertEqual(BrainSelectionCallSiteRule.verdict(for: source), .argumentMissing)
    }

    // MARK: - and the real file, which is the point of all of the above

    func testTheShippingAppArmsTheRungWithALivePredicate() throws {
        let source = try Self.appSource("App/RootView.swift")
        let verdict = BrainSelectionCallSiteRule.verdict(for: source)
        guard case .ok = verdict else {
            return XCTFail("""
            App/RootView.swift no longer arms the paired-vault rung with a live predicate \
            (verdict: \(verdict)). That rung is the fix for captures being routed to a \
            phone-only no-op that self-issued ACKs and advanced the durable upload watermark \
            — bytes that never moved and could never be re-sent. `swift test` cannot compile \
            `App/`, so this rule is the only thing that can see it.
            """)
        }
    }

    /// Read a file out of the app target, which is NOT part of the SPM package.
    static func appSource(_ relativePath: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        while root.pathComponents.count > 1 {
            root.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
                break
            }
        }
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
