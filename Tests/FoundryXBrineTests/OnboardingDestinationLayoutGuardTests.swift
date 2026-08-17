import XCTest
import Foundation
@testable import FoundryXKit

/// FX-4(b) — THE VAULT-CHOICE LAYOUT MUST PICK ONE ALIGNMENT.
///
/// "Where your notes live" (`App/OnboardingEndingViews.swift`,
/// `OnboardingDestinationStep`) is a `VStack(alignment: .leading)` — title, blurb and the
/// tier comparison all hug the left edge. Its three choice buttons
/// ("Set up my Vault" / "Keep my notes on this phone" / "I'll use my computer",
/// `OnboardingFlowPlan.swift:206-208`) sit in a nested `VStack(spacing:)` with NO
/// alignment argument, and a `VStack`'s default alignment is `.center`. `GrainButton`
/// hugs its title's width (`GrainButtonStyle.makeBody` sets a height and horizontal
/// padding but never `maxWidth`), so three buttons of three different widths end up
/// centred relative to each other inside a shrink-wrapped box that is itself pinned to
/// the left. Nick: "centered in a left aligned box".
///
/// `swift test` cannot compile `App/`, so this reads the real file the same way
/// `ChatAlignmentRegressionGuardTests` reads the vendored `GrainMessageBubble.swift` and
/// `AppSourceTree` reads `App/`. Its stated limit: it proves the DECLARED alignment, not
/// rendered pixels — but the declared alignment is precisely what was wrong.
final class OnboardingDestinationLayoutGuardTests: XCTestCase {

    private static let destinationFile = "App/OnboardingEndingViews.swift"

    // MARK: - A tiny reader for `VStack(…) { … }`

    struct StackDecl: Equatable {
        /// The `alignment:` argument as written (`"leading"`, `"center"`, …), or nil when
        /// the call declares none — which for a `VStack` silently means `.center`.
        let alignment: String?
        /// The trailing-closure body, so callers can ask what the stack contains.
        let body: String
    }

    /// Every `VStack(…) { … }` in `source`, outermost-first, with its declared alignment.
    static func verticalStacks(in source: String) -> [StackDecl] {
        var found: [StackDecl] = []
        var search = source.startIndex
        while let hit = source.range(of: "VStack(", range: search..<source.endIndex) {
            search = hit.upperBound
            // Match the argument list's parens.
            var depth = 1
            var i = hit.upperBound
            while i < source.endIndex, depth > 0 {
                if source[i] == "(" { depth += 1 }
                if source[i] == ")" { depth -= 1 }
                i = source.index(after: i)
            }
            guard depth == 0 else { continue }
            let arguments = String(source[hit.upperBound..<source.index(before: i)])
            // The trailing closure must open next (whitespace aside).
            var j = i
            while j < source.endIndex, source[j] == " " || source[j] == "\n" {
                j = source.index(after: j)
            }
            guard j < source.endIndex, source[j] == "{" else { continue }
            var braces = 0
            var k = j
            var end: String.Index?
            while k < source.endIndex {
                if source[k] == "{" { braces += 1 }
                if source[k] == "}" {
                    braces -= 1
                    if braces == 0 { end = k; break }
                }
                k = source.index(after: k)
            }
            guard let end else { continue }
            found.append(StackDecl(alignment: alignmentArgument(in: arguments),
                                   body: String(source[source.index(after: j)..<end])))
        }
        return found
    }

    /// `alignment: .leading` → `"leading"`. Absent → nil.
    static func alignmentArgument(in arguments: String) -> String? {
        guard let key = arguments.range(of: "alignment:") else { return nil }
        let rest = arguments[key.upperBound...].drop { $0 == " " }
        guard rest.first == "." else { return nil }
        let name = rest.dropFirst().prefix { $0.isLetter }
        return name.isEmpty ? nil : String(name)
    }

    /// The destination step's source, comments stripped and literals kept.
    static func destinationStepSource() throws -> String {
        let text = try OnboardingAmbientNudgeHonestyTests.appSource(destinationFile)
        guard let start = text.range(of: "struct OnboardingDestinationStep") else {
            throw BrineStepError("\(destinationFile) no longer declares OnboardingDestinationStep")
        }
        return String(text[start.lowerBound...])
    }

    /// The screen's own column (the outermost stack holding the choices) and the stack the
    /// buttons actually live in (the innermost one), identified by the fact that only these
    /// buttons are titled from `BrainChoice.destinationLabel`.
    static func screenAndButtonStacks(in source: String) throws -> (screen: StackDecl, buttons: StackDecl) {
        let holding = verticalStacks(in: source).filter { $0.body.contains("destinationLabel") }
        guard holding.count >= 2,
              let screen = holding.max(by: { $0.body.count < $1.body.count }),
              let buttons = holding.min(by: { $0.body.count < $1.body.count }) else {
            throw BrineStepError(
                "could not find both the screen column and the button stack around " +
                "BrainChoice.destinationLabel in \(destinationFile) (found \(holding.count) " +
                "VStacks containing it) — this guard can no longer read the screen")
        }
        return (screen, buttons)
    }

    // MARK: - The guard

    /// Scenario: the choice buttons use the SAME alignment as the screen they sit on.
    ///
    /// Both halves matter. A missing `alignment:` is the actual defect — a `VStack` with
    /// no alignment centres its children — so an absent argument fails here even before
    /// the comparison, rather than being read as "whatever the outer stack says".
    func testTheChoiceButtonsShareTheScreensAlignment() throws {
        let (screen, buttons) = try Self.screenAndButtonStacks(in: try Self.destinationStepSource())
        XCTAssertNotNil(
            buttons.alignment,
            "the destination step's button stack declares no alignment, so SwiftUI centres " +
            "the three buttons relative to each other inside a shrink-wrapped box that is " +
            "itself pinned to the screen's leading edge — “centered in a left aligned box”. " +
            "Declare alignment: .\(screen.alignment ?? "leading") on the button VStack.")
        XCTAssertEqual(
            buttons.alignment, screen.alignment,
            "the destination step's buttons are aligned .\(buttons.alignment ?? "center") " +
            "inside a screen aligned .\(screen.alignment ?? "center") — the container and " +
            "its buttons must agree on ONE alignment")
    }

    /// Scenario: the button stack spans the column, so a button's leading edge lands on the
    /// same left edge as the title rather than on the edge of a box sized to the longest
    /// title. Without this the stack still shrink-wraps; with it the declared alignment is
    /// what the user actually sees.
    func testTheButtonStackSpansTheColumn() throws {
        let (_, buttons) = try Self.screenAndButtonStacks(in: try Self.destinationStepSource())
        let source = try Self.destinationStepSource()
        guard let stackEnd = source.range(of: buttons.body)?.upperBound else {
            XCTFail("could not locate the button stack's modifiers")
            return
        }
        let modifiers = String(source[stackEnd...].prefix(220))
        XCTAssertTrue(modifiers.contains("maxWidth: .infinity"),
                      "the button stack does not span the column, so it shrink-wraps to the " +
                      "widest button and the declared alignment is invisible. Modifiers were:" +
                      "\n\(modifiers)")
    }

    /// Falsification (the method `ChatAlignmentRegressionGuardTests` uses): remove the
    /// alignment argument from the REAL source in memory and require this guard's own
    /// reader to go red. A guard that cannot detect the regression it names is measuring
    /// nothing.
    func testTheGuardDetectsTheAlignmentBeingRemoved() throws {
        let real = try Self.destinationStepSource()
        let (screen, buttons) = try Self.screenAndButtonStacks(in: real)
        guard let alignment = buttons.alignment else {
            XCTFail("the real source already has no alignment on the button stack — fix that " +
                    "first; this falsification has nothing to remove")
            return
        }
        // The button stack is the only `VStack(alignment:…, spacing: GrainSpacing.x2)` in
        // this struct, so this rewrites exactly it — back to the shape that shipped.
        let mutant = real.replacingOccurrences(
            of: "VStack(alignment: .\(alignment), spacing: GrainSpacing.x2) {",
            with: "VStack(spacing: GrainSpacing.x2) {")
        XCTAssertNotEqual(mutant, real,
                          "the mutation did not apply — the button stack no longer matches the " +
                          "shape this falsification removes, so it proves nothing")
        let (_, mutantButtons) = try Self.screenAndButtonStacks(in: mutant)
        XCTAssertNil(mutantButtons.alignment,
                     "the reader did NOT notice the removed alignment — it cannot go red for " +
                     "the FX-4(b) regression and must not be kept as a green row")
        XCTAssertNotEqual(mutantButtons.alignment, screen.alignment,
                          "the reader reports the mutant as still agreeing with the screen")
    }

    /// Falsification, second direction: the reader really can tell two alignments apart,
    /// so `testTheChoiceButtonsShareTheScreensAlignment` is not passing because everything
    /// parses as nil.
    func testTheReaderDistinguishesAlignments() {
        XCTAssertEqual(Self.alignmentArgument(in: "alignment: .leading, spacing: 8"), "leading")
        XCTAssertEqual(Self.alignmentArgument(in: "alignment: .center"), "center")
        XCTAssertEqual(Self.alignmentArgument(in: "alignment: .trailing, spacing: x2"), "trailing")
        XCTAssertNil(Self.alignmentArgument(in: "spacing: GrainSpacing.x2"))
        let stacks = Self.verticalStacks(in: """
            VStack(alignment: .leading, spacing: 4) {
                Text("a")
                VStack(spacing: 2) { Text("b") }
            }
            """)
        XCTAssertEqual(stacks.count, 2, "the reader did not find both nested stacks")
        XCTAssertEqual(stacks.first?.alignment, "leading")
        XCTAssertNil(stacks.last?.alignment)
    }
}
