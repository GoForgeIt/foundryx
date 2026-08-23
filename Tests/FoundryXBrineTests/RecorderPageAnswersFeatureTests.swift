import XCTest
import Foundation
@testable import FoundryXKit

/// **THE INVARIANT: no control on the recorder surface returns in silence.**
///
/// Every control either changes what is on the screen or says why it did not, so "I tapped it and
/// nothing happened" stops being a state the app can be in.
///
/// WHY A GATE AND NOT THREE FIXES. The same shape was found four times independently — N4, N9,
/// N10, N13 — in one file, and in each case the correct handling already existed a few lines away.
/// Three point fixes leave the fourth to be found by an owner.
///
/// THE EXCLUSION RULE, AND WHY IT IS NOT A LOOPHOLE. Read literally over every bare `return`, this
/// invariant flags sound defensive code: `copyRevealedKey`'s `guard let revealedKey else { return }`
/// whose button is rendered only inside `if let revealedKey` (`App/PocketOnboardingView.swift:222`,
/// button at `:234`), and `forget()`'s `guard input.isRemembered` precondition. A gate that fires
/// on those is one somebody silences by adding copy no person can ever see. So:
///
/// > A `guard` whose condition is the SAME VALUE that gates whether the control is rendered is a
/// > PRECONDITION, not a violation.
///
/// EVERY EXCLUSION IS PRINTED WITH ITS REASON. A gate whose skips are invisible stops covering
/// things silently — which is this track's own defect, one altitude up, in the instrument.
final class RecorderPageAnswersFeatureTests: XCTestCase {

    /// Guards excluded by the rule above, each with the value that gates its control's rendering.
    /// Adding a row here is a deliberate act and shows up in the gate's output on every run.
    private static let precondition: [String: String] = [
        "copyRevealedKey": "revealedKey — the Copy button is inside `if let revealedKey` "
            + "(PocketOnboardingView.swift:222, button :234), so this guard is unreachable from "
            + "the UI",
        "forget": "input.isRemembered — the Forget action is not emitted for a device the store "
            + "does not remember (UnifiedDeviceListPresentation.resolve), so this is a "
            + "precondition behind a destructive confirmation",
    ]

    /// The declared control population. **An EXACT number, never a bound** — the spec is explicit
    /// that a "no bare returns" predicate passes perfectly on a file with no controls, so the
    /// existence assertion is what stops this gate being satisfied by finding nothing.
    private static let declaredControlCount = 10

    func testNoControlOnTheRecorderPageReturnsInSilence() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let screen = root.appendingPathComponent("App/DeviceScreen.swift")
        let source = try String(contentsOf: screen)

        // NON-VACUITY ON THE SCAN ITSELF: a scan that read nothing cannot report that nothing is
        // wrong, and the two failures are named separately so the reason is never guessed.
        XCTAssertFalse(source.isEmpty, "App/DeviceScreen.swift read as empty — the scan read nothing")

        let lines = source.components(separatedBy: "\n")
        var controls = 0
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
            if t.contains("Button(") || t.contains("Toggle(") { controls += 1 }
        }

        XCTAssertEqual(controls, Self.declaredControlCount,
                       "the recorder surface has \(controls) controls, not "
                           + "\(Self.declaredControlCount). Raise this DELIBERATELY and check the "
                           + "new control answers — never adjust it to make the gate pass")
        XCTAssertGreaterThan(controls, 0,
                             "zero controls found — a 'no silent control' claim over an empty "
                                 + "population is vacuous")

        // THE POPULATION IS CONTROL ACTIONS, NOT EVERY FUNCTION. A first version of this gate
        // scanned every bare `return` in the file and produced 41 hits, almost all in helpers and
        // async tasks that no tap ever reaches — `forgetInTheStore`, `sceneChanged`, `absorb`.
        // That is the gate flagging sound code, which is the failure this rule exists to avoid.
        // The spec says "every Button / Toggle / tap action", so the scan starts from the
        // controls and follows them to the functions they call.
        var actionNames = Set<String>()
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
            guard t.contains("Button(") || t.contains("Toggle(") || t.contains("action:")
                    || t.contains("onReveal:") || t.contains("onCopy:") else { continue }
            // `{ foo() }` / `{ foo(bar) }` — the identifier a control invokes.
            var rest = Substring(t)
            while let brace = rest.firstIndex(of: "{") {
                rest = rest[rest.index(after: brace)...]
                let call = rest.drop(while: { $0 == " " })
                let name = String(call.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
                if !name.isEmpty, call.dropFirst(name.count).first == "(" { actionNames.insert(name) }
            }
        }
        XCTAssertFalse(actionNames.isEmpty,
                       "no control actions were found — the scan cannot report that no control "
                           + "returns in silence if it located no controls")

        // THE STATE THE INVARIANT IS ABOUT. Collected from the file rather than hardcoded, so a
        // new @State added tomorrow counts without anyone remembering to list it here.
        var stateNames = Set<String>()
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("@State"), let r = t.range(of: "var ") else { continue }
            let name = String(t[r.upperBound...].prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
            if !name.isEmpty { stateNames.insert(name) }
        }
        XCTAssertFalse(stateNames.isEmpty,
                       "no @State was found — the scan cannot tell a silent return from one that "
                           + "changed the page if it does not know what the page's state is")

        // A RETURN IS JUDGED BY ITS BLOCK, NOT ITS LINE. The second version of this gate flagged
        // `keyCustodyFoundNothing = true; return` — the N10 FIX — because it only looked at the
        // return itself. What the invariant actually asks is whether the path taken changed the
        // page, so the scan walks back to the opening of the enclosing block and asks whether
        // anything on the way assigned to state.
        func blockMutatesState(endingAt idx: Int) -> Bool {
            var depth = 0
            var i = idx
            while i >= 0 {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                depth += t.filter { $0 == "}" }.count
                depth -= t.filter { $0 == "{" }.count
                if depth < 0 { return false }        // reached this block's opening brace
                if i != idx, !t.hasPrefix("//"), !t.hasPrefix("///") {
                    for name in stateNames where t.hasPrefix(name + " =") || t.contains(" \(name) = ") {
                        _ = name
                        return true
                    }
                }
                i -= 1
            }
            return false
        }

        var inlineViolations: [String] = []
        // INLINE CONTROL BODIES, WHICH THE NAME-BASED SCAN ABOVE CANNOT SEE.
        //
        // MEASURED in implementation review: five controls in this file do not call a named
        // function — their action is written inline over several lines, or is a `Binding`'s
        // setter. Two of them (the remove-from-recorder confirm and cancel) contain
        // `guard let token = page?.fileToken else { return }`, which is EXACTLY the shape this
        // invariant is about, and the name-based scan was blind to all five.
        //
        // So the region from a `Button(`/`Toggle(` line to the close of its body is scanned too.
        var inlineRegions: [(Int, Int)] = []
        for (n, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
            guard t.contains("Button(") || t.contains("Toggle(") else { continue }
            var depth = 0
            var started = false
            var i = n
            while i < lines.count, i < n + 40 {
                let u = lines[i]
                depth += u.filter { $0 == "(" || $0 == "{" }.count
                depth -= u.filter { $0 == ")" || $0 == "}" }.count
                started = started || depth > 0
                if started, depth <= 0 { break }
                i += 1
            }
            if i > n { inlineRegions.append((n, i)) }
        }
        XCTAssertFalse(inlineRegions.isEmpty,
                       "no control bodies were located — the inline scan covers nothing")

        for (start, end) in inlineRegions {
            for n in start...min(end, lines.count - 1) {
                let t = lines[n].trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
                let isBare = t == "return" || t.hasSuffix("{ return }") || t == "else { return }"
                guard isBare, !blockMutatesState(endingAt: n) else { continue }
                inlineViolations.append("  inline control body at line \(n + 1) — a bare return "
                                            + "that sets no state and no message")
            }
        }

        var violations: [String] = []
        var excluded: [String] = []
        var currentFunc = ""
        for (n, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: "private func ") ?? t.range(of: "func ") {
                let rest = t[r.upperBound...]
                currentFunc = String(rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
            }
            guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
            guard actionNames.contains(currentFunc) else { continue }
            let isBare = t == "return" || t.hasSuffix("{ return }") || t == "else { return }"
            guard isBare else { continue }
            if blockMutatesState(endingAt: n) { continue }
            if let why = Self.precondition[currentFunc] {
                excluded.append("  \(currentFunc) (line \(n + 1)) — EXCLUDED: \(why)")
            } else {
                violations.append("  \(currentFunc) (line \(n + 1)) — a bare return that sets no "
                                      + "state and no message")
            }
        }

        // The exclusions are printed on EVERY run, pass or fail. An exclusion nobody can see is
        // how a gate quietly stops covering something.
        if !excluded.isEmpty {
            print("[recorder-page-answers] preconditions excluded by the reachability rule:\n"
                      + excluded.joined(separator: "\n"))
        }

        // N13'S REGRESSION GUARD, AND WHAT IT IS NOT.
        //
        // MEASURED: deleting `dismiss()` from `forget()` leaves this whole gate green, because the
        // gate is about bare returns and a missing dismissal is not one. So N13 had no guard at
        // all until this assertion, and would have regressed silently.
        //
        // THIS IS A SOURCE GUARD, NOT A BEHAVIOURAL PROOF. `swift test` cannot compile `App/`, so
        // nothing in this target can push the page and observe it pop. It asserts the call site
        // exists and is ordered after `onChange()`; that it actually pops belongs in the
        // `appscenarios` phase, which hosts App/ on the iOS runtime. Saying so here is the
        // difference between a guard and a claim.
        let forgetBody: String = {
            guard let start = source.range(of: "private func forget() {") else { return "" }
            let after = source[start.upperBound...]
            guard let end = after.range(of: "\n    }") else { return String(after.prefix(2000)) }
            return String(after[..<end.lowerBound])
        }()
        XCTAssertFalse(forgetBody.isEmpty, "forget() was not found — the N13 guard read nothing")
        XCTAssertTrue(forgetBody.contains("dismiss()"),
                      "forget() does not dismiss, so the owner is left on the page of a device "
                          + "that no longer exists — same name, same status, same Forget button")
        if let d = forgetBody.range(of: "dismiss()"), let c = forgetBody.range(of: "onChange()") {
            XCTAssertTrue(c.lowerBound < d.lowerBound,
                          "forget() dismisses BEFORE onChange(), so the owner lands on a list "
                              + "still showing the row they just forgot")
        }

        XCTAssertEqual(violations + Array(Set(inlineViolations)).sorted(), [],
                       "a control on the recorder surface returns in silence — it neither changes "
                           + "the page nor says why it did not:\n"
                           + violations.joined(separator: "\n"))
    }
}
