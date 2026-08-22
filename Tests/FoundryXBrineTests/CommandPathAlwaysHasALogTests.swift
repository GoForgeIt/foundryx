import XCTest
@testable import FoundryXKit

/// AC5 of `20260816T2154_pocket_one_tap_is_one_session_and_the_command_path_logs`:
/// *"`makeAttachment(log:)` has no `nil` default and both call sites pass `DoorLog.shared`."*
///
/// ## The defect this exists to prevent, which was LIVE on main until 2026-08-22
///
/// One of the two `makeAttachment` overloads read `log: DoorLog? = .shared`. That LOOKS like it
/// satisfies AC5 — the default is the shared log, so the common case reports — and it does not.
/// **The hole is the optionality, not the default.**
///
/// `DeviceManager.diagnosticLog` is `DoorLog?`, and one call site passed it straight through to a
/// `RecordingDeviceAttachment` that stores `DoorLog?` and reports through `log?.record(…)`. A
/// `nil` arriving there is not an error and not a crash — **it is silence.** AC3 of the same
/// track (*every `errand.start`, `errand.stop` and `custody.commit` produces a command record*)
/// could therefore fail with nothing failing, which is this codebase's most-repeated defect
/// class stated exactly.
///
/// ## Why this is a source scan
///
/// `swift test` cannot compile `App/`, so a rule about a signature in a SwiftUI model has no
/// other executable home — the same reasoning as the journey track's AC9 scan. A rule written
/// only in a review comment is a rule nothing in this repository can enforce.
final class CommandPathAlwaysHasALogTests: XCTestCase {

    private func deviceScreenSource() throws -> String {
        // Walk up from this file to the package root, the way the other source-scanning suites do.
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("App/DeviceScreen.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("App/DeviceScreen.swift not found from \(#filePath)")
    }

    /// **EXISTENCE FIRST.** A scan that finds no declarations proves nothing, and would report
    /// "no optional-defaulted log" on an empty file, a moved file, or a typo in the pattern.
    func testTheScanActuallyFindsTheDeclarationsItJudges() throws {
        let source = try deviceScreenSource()
        let declarations = source.components(separatedBy: "func makeAttachment(").count - 1
        XCTAssertGreaterThanOrEqual(
            declarations, 1,
            "the scan found NO `makeAttachment(` declarations, so the prohibition below would "
            + "pass vacuously — the file moved, was renamed, or the pattern is wrong")
    }

    /// **NO `makeAttachment` MAY TAKE AN OPTIONAL LOG.**
    ///
    /// Checked on the declaration line itself rather than over the whole file, so an unrelated
    /// `DoorLog?` elsewhere cannot mask or manufacture a failure.
    func testNoMakeAttachmentTakesAnOptionalLog() throws {
        let source = try deviceScreenSource()
        var offenders: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            guard text.contains("func makeAttachment(") else { continue }
            if text.contains("DoorLog?") {
                offenders.append(text.trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
        a `makeAttachment` takes an OPTIONAL log, so a `nil` can reach an attachment that \
        reports through `log?.record(…)` and the command path goes silent without failing:
        \(offenders.joined(separator: "\n"))
        """)
    }

    /// **AND NO CALL SITE MAY OMIT IT.** Removing the optional but leaving a non-optional default
    /// would re-open the same hole one step further out, and would still read as safe.
    func testEveryCallSiteNamesItsLog() throws {
        let source = try deviceScreenSource()
        var bare: [Int] = []
        for (i, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(line)
            guard text.contains("makeAttachment("), !text.contains("func makeAttachment(") else { continue }
            if text.contains("makeAttachment()") { bare.append(i + 1) }
        }
        XCTAssertTrue(bare.isEmpty,
                      "makeAttachment() is called without naming a log at line(s) "
                      + "\(bare.map(String.init).joined(separator: ", ")) — a defaulted log is a "
                      + "log nobody chose, which is how the optional one survived review")
    }

    // THE RESIDUAL, RECORDED RATHER THAN ASSERTED AWAY.
    //
    // `RecordingDeviceAttachment` still stores `DoorLog?` internally. That is outside this
    // track's scope and is NOT fixed here, so the guarantee currently rests on every caller in
    // `App/` being correct rather than on the type system. Making that field non-optional is the
    // change that would move it.
    //
    // This was very nearly a fifth test asserting `XCTAssertTrue(true)` with the note in its doc
    // comment — a check that cannot fail, in a file whose whole subject is checks that cannot
    // fail. A comment is the honest home for a fact nobody is testing.
}
