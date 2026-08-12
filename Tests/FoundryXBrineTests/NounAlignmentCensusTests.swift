import XCTest
import Foundation

/// T13 / A1 — the phone speaks the desktop's ruled nouns, counted PER OCCURRENCE.
///
/// ## Why per-occurrence, and why this file spells nothing it forbids
///
/// The noun registry (`foundry:docs/noun-registry.md`) rules two renames that reach this
/// repository by reference: the shipped tunnel splice crate (`relay` → `foundryx-tunnel`)
/// and the desktop's outbound dialer (`door` → the host dialer). Its own census rule is
/// that a file-level census "would license every miss inside" a file that also carries a
/// frozen name, so each surviving occurrence must be matched to the entry that licenses
/// it and an occurrence matching none is a miss.
///
/// The registry's `[scope]` block derives from `Cargo.toml:members`, so the Rust lint that
/// enforces this cannot see a single Swift file. This census is that reach, and it is the
/// reason the drift it found could sit here undetected through a rename in the other
/// repository.
///
/// The retired forms are ASSEMBLED AT RUNTIME rather than written out. A census whose own
/// source spells the tokens it forbids has to exclude itself, and an exclusion is the one
/// place a real miss can hide. Assembling them means this file needs no carve-out at all,
/// and `testTheCensusSpellsNothingItForbids` keeps that true.
final class NounAlignmentCensusTests: XCTestCase {

    /// Assembled, never spelled. `separator` is `-` for the deployed/hyphenated spelling
    /// and `_` for the Rust/identifier spelling.
    private static func retiredForms() -> [String] {
        let stem = "foundryx"
        let retiredSenses = ["relay", "door"]
        var forms: [String] = []
        for sense in retiredSenses {
            for separator in ["-", "_"] {
                forms.append(stem + separator + sense)
            }
        }
        // The retired dialer TYPE from the registry's `door` row (`retired_forms`).
        forms.append("Door" + "Dialer")
        return forms
    }

    /// The occurrences that survive, each with the reason that licenses it. This is the
    /// registry's residue table, for this repository. An occurrence that matches no row is
    /// a miss; a row that matches no occurrence is dead and is also a failure, so the table
    /// cannot quietly grow permissions nobody needs.
    private struct Residue {
        let path: String
        let reason: String
    }
    private static let licensedResidue: [Residue] = [
        Residue(path: "Tests/FoundryXBrineTests/RelayTransportTests.swift",
                reason: "the retired form is the THING UNDER TEST: `XCTAssertNotEqual(cfg.tunnelId, …)` "
                      + "names the value a tunnel id must never be hardcoded to. Renaming it would "
                      + "weaken the assertion into one about a value nobody would write."),
    ]

    private static let searchRoots = ["Sources", "App", "Widget", "Tests", "UITests", "features", "TestSupport"]

    private static func repoRoot() -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // Tests/FoundryXBrineTests/<file> -> repo root
        return url.path
    }

    private struct Hit {
        let relativePath: String
        let line: Int
        let form: String
    }

    /// Walks the roots and returns every occurrence, plus the number of files examined.
    private static func census() -> (hits: [Hit], filesExamined: Int) {
        let root = repoRoot()
        let fm = FileManager.default
        let forms = retiredForms()
        var hits: [Hit] = []
        var filesExamined = 0

        for sub in searchRoots {
            let dir = (root as NSString).appendingPathComponent(sub)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let walker = fm.enumerator(atPath: dir) else { continue }
            for case let name as String in walker {
                let full = (dir as NSString).appendingPathComponent(name)
                var entryIsDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &entryIsDir), !entryIsDir.boolValue else { continue }
                guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
                filesExamined += 1
                let relative = sub + "/" + name
                for (index, lineText) in text.components(separatedBy: "\n").enumerated() {
                    for form in forms where lineText.contains(form) {
                        hits.append(Hit(relativePath: relative, line: index + 1, form: form))
                    }
                }
            }
        }
        return (hits, filesExamined)
    }

    /// NON-VACUOUS FIRST. A census over zero files reports clean, so the population is
    /// asserted before its contents are.
    func testTheCensusActuallyExaminedTheRepository() {
        let (_, filesExamined) = Self.census()
        XCTAssertGreaterThan(filesExamined, 100,
            "the census examined \(filesExamined) files; it is reading the wrong tree, and a clean "
            + "result over an empty population means nothing")
        print("NOUN CENSUS: examined \(filesExamined) files under \(Self.searchRoots.joined(separator: ", "))")
    }

    /// A1 — every surviving retired-form occurrence is licensed by a named row.
    func testEveryRetiredFormOccurrenceIsLicensed() {
        let (hits, filesExamined) = Self.census()
        let licensedPaths = Set(Self.licensedResidue.map(\.path))

        let unlicensed = hits.filter { !licensedPaths.contains($0.relativePath) }
        let rendered = unlicensed
            .map { "  \($0.relativePath):\($0.line) — \($0.form)" }
            .joined(separator: "\n")

        print("NOUN CENSUS: \(filesExamined) files, \(hits.count) retired-form occurrence(s), "
              + "\(hits.count - unlicensed.count) licensed, \(unlicensed.count) unlicensed")

        XCTAssertTrue(unlicensed.isEmpty, """
        \(unlicensed.count) retired-form occurrence(s) with no licensing row. The desktop renamed \
        these under the noun registry; a reference here that still spells the retired form points \
        at something that no longer exists:
        \(rendered)
        """)

        // A row that licenses nothing is a permission nobody needs; it would let a real miss in
        // later without a diff anyone would notice.
        for residue in Self.licensedResidue {
            XCTAssertTrue(hits.contains { $0.relativePath == residue.path },
                "the residue row for \(residue.path) licenses no occurrence — delete the row")
        }
    }

    /// A13 — the replacement is the RULED spelling, not merely a different one.
    ///
    /// macOS-gated because the dialer fixture it reads is (FoundryXDoorTests spawns a real
    /// process, which iOS has no `Foundation.Process` for).
    #if os(macOS)
    func testTheDialerFixtureNamesTheRuledIdentifier() {
        let ruled = "foundryx_host_dialer"
        XCTAssertEqual(FoundryXDoorTests.ruledDialerIdentifier, ruled,
            "the dialer identifier must be the registry's `door` row spelling (loser_became = \"host dialer\")")
        for form in Self.retiredForms() {
            XCTAssertFalse(ruled.contains(form), "the ruled identifier still contains the retired form \(form)")
        }
        XCTAssertEqual((FoundryXDoorTests.hostDialerExample as NSString).lastPathComponent, ruled,
            "the configured dialer binary is not the ruled identifier — a fixture pointed at a "
            + "binary the desktop no longer builds is the defect this criterion exists to catch")
    }
    #endif

    /// Keeps the no-carve-out property true: this file must not spell what it forbids.
    func testTheCensusSpellsNothingItForbids() {
        guard let ownSource = try? String(contentsOfFile: #filePath, encoding: .utf8) else {
            return XCTFail("could not read this file's own source at \(#filePath)")
        }
        for form in Self.retiredForms() {
            XCTAssertFalse(ownSource.contains(form),
                "this census spells \(form), so it would need a self-exclusion — and an exclusion is "
                + "where a real miss hides. Assemble the token instead.")
        }
    }
}
