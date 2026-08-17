// RecorderPageCopyAndTokenGateTests — NO LINE AND NO COLOUR IS INVENTED IN A SWIFTUI BODY.
//
// Step 10's second half. The first half is the render proof
// (`UITests/RecordingDevicePageProofUITests`, wired into `phase_uiproof`), which shows the page
// actually draws. This is the half that stops it drawing something nobody wrote down.
//
// WHY THIS IS WORTH A GATE AND NOT A CONVENTION. Every claim this repository makes about the
// recorder page's copy is made over a POPULATION — `PocketRecorderCheckPresentation.everyLine`,
// `PocketBringOverPresentation.everyLine`, `PocketRecorderCostPresentation.everyLine` and the
// rest. The promise gate scans them for retired sentences; the language lexer scans them for
// retired words. A string typed directly into a `Text(...)` in a view body is in NONE of those
// populations, so it is invisible to all of them at once — and it is invisible in exactly the
// way that matters, because a line somebody typed in a hurry in a body is precisely the line
// most likely to over-promise. One such literal was still on this page when this file was
// written (`Text("Use this device for capture")`); it now lives on `RecordingDevicePage`.
//
// THE SAME ARGUMENT FOR COLOUR. Grain owns the palette. A `Color(red:green:blue:)` or a
// `Color("SomeAsset")` painted in this body is a colour that no theme switch reaches and no
// contrast review ever saw.
//
// PAIRED EXISTENCE, ON BOTH HALVES. A prohibition over a population nobody checked is non-empty
// passes on an empty file, and this file is a source scan — the cheapest possible thing to
// accidentally point at nothing. So it asserts that the page DOES paint Grain tokens and DOES
// render kit-owned strings before it asserts what it does not do.
import XCTest
@testable import FoundryXKit

final class RecorderPageCopyAndTokenGateTests: XCTestCase {

    /// `withoutComments`, NOT `code`, AND THE DIFFERENCE IS THE WHOLE TEST.
    ///
    /// Comments must go: `App/DeviceScreen.swift` explains at length why certain sentences are
    /// forbidden, quoting them, and a scan over raw text would red on the explanation.
    ///
    /// But STRINGS MUST STAY, and `AppSourceTree.code(of:)` blanks them — it drops the literal
    /// AND its quotes, so `Text("anything")` arrives here as `Text()`. My first two attempts at
    /// this test used `code(of:)` and were therefore incapable of seeing a literal at all; the
    /// mutation that invents a line passed both times. `withoutComments(of:)` is the transform
    /// that keeps what this gate is about.
    private func deviceScreen() throws -> String {
        let url = AppSourceTree.repoRoot.appendingPathComponent("App/DeviceScreen.swift")
        let raw = try String(contentsOf: url, encoding: .utf8)
        return AppSourceTree.withoutComments(of: raw)
    }

    /// EVERY SENTENCE ON THIS PAGE COMES FROM THE KIT.
    func testNoUserFacingStringIsWrittenInAViewBody() throws {
        let code = try deviceScreen()

        // PAIRED EXISTENCE FIRST: the page really does render kit-owned copy. Without this, a
        // `DeviceScreen.swift` that had been emptied, renamed or moved would pass silently.
        let kitRendered = ["PocketRecorderCheckPresentation.", "PocketBringOverPresentation.",
                           "PocketRecorderCostPresentation.", "RecordingDevicePage."]
            .filter { code.contains($0) }
        XCTAssertEqual(kitRendered.count, 4,
                       "the recorder page renders copy from only \(kitRendered) — this scan is "
                           + "pointed at a file that is no longer the recorder page")

        // AND NOW THE PROHIBITION. A kit constant reads `Text(RecordingDevicePage.x)` and
        // carries no quote; a literal reads `Text("…")`. With comments gone and strings intact,
        // the presence of `Text("` IS the signal. An interpolation is caught by the same rule
        // and should be — a sentence assembled in a body is as invisible to the copy
        // populations as one typed there.
        var invented: [String] = []
        var rest = code[...]
        while let hit = rest.range(of: "Text(\"") {
            let after = rest[hit.upperBound...]
            guard let close = after.range(of: "\"") else { break }
            invented.append(String(after[..<close.lowerBound]))
            rest = after[close.upperBound...]
        }
        XCTAssertEqual(invented, [],
                       "the recorder page writes \(invented) directly into a SwiftUI body. A "
                           + "line typed into a view is in none of the `everyLine` populations, "
                           + "so the promise gate, the language lexer and every copy review are "
                           + "all blind to it at once. Put it on the kit's presentation type.")

        // THE POSITIVE CONTROL, SITED ON THE REAL PATH: the same detector, after the same
        // transform, must see a literal that is genuinely there. Sited anywhere else it proves
        // nothing about the scan above — which is exactly how the first version of this test
        // shipped green over a deliberately invented line.
        let probe = AppSourceTree.withoutComments(of: "Text(\"a line nobody wrote down\")")
        XCTAssertTrue(probe.contains("Text(\"a line nobody wrote down\")"),
                      "POSITIVE CONTROL FAILED: the transform this scan uses does not preserve "
                          + "a literal that is deliberately present, so the empty result above "
                          + "proves nothing")
    }

    /// EVERY COLOUR ON THIS PAGE IS A GRAIN TOKEN.
    func testNoColourIsInventedInAViewBody() throws {
        let code = try deviceScreen()

        // PAIRED EXISTENCE: the page paints Grain tokens, and plenty of them.
        let grainTokens = code.components(separatedBy: "GrainColor.").count - 1
        XCTAssertGreaterThan(grainTokens, 10,
                             "the recorder page paints \(grainTokens) Grain colour token(s) — "
                                 + "this scan is not looking at a page that draws anything")

        // THE PROHIBITION: no `Color(` that is not a Grain one. `GrainColor.x` is a property
        // access and carries no parenthesis, so any `Color(` at all is a colour built here.
        var raw: [String] = []
        var rest = code[...]
        while let hit = rest.range(of: "Color(") {
            let start = rest[..<hit.lowerBound]
            let isGrain = start.hasSuffix("Grain")
            if !isGrain {
                let tail = rest[hit.lowerBound...].prefix(48)
                raw.append(String(tail))
            }
            rest = rest[hit.upperBound...]
        }
        XCTAssertEqual(raw, [],
                       "the recorder page builds its own colour(s): \(raw). A colour painted in "
                           + "a body is one no theme switch reaches and no contrast review saw.")
    }
}
