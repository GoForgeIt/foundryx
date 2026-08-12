import XCTest
import Foundation

/// T13 / A5 — THE PERSISTED IDENTIFIER FRONTIER IS BYTE-UNCHANGED, AND THE MANIFEST'S
/// SIZE IS ASSERTED.
///
/// ## What this grades, and why a rename here is not a rename
///
/// A5's own disposition names the failure it exists to stop: *"a silent identity reset on
/// every installed desktop"*. A symbol rename is a refactor. A rename of a string that has
/// already been WRITTEN TO DISK on a device we do not own is a data migration wearing a
/// refactor's clothes, and it fails silently — the decode returns `nil`, the app writes a
/// fresh file, and the user's state is simply gone. Nothing in this repository could see
/// that before this file: `NounAlignmentCensusTests` grades the retired NOUNS, the Rust
/// `noun-lint`'s `[scope]` derives from `Cargo.toml:members` and reaches no Swift file at
/// all, and the compiler is happy either way because both spellings compile.
///
/// ## The frontier is DERIVED from the source and compared to a PINNED manifest
///
/// `evidence/t13/identifier-frontier.tsv` is the manifest: one row per persisted
/// identifier, `kind<TAB>path<TAB>literal`. It is an ORACLE HELD OUTSIDE THE CODE IT
/// GRADES — a checked-in file, not a constant beside the thing it pins, because an
/// expectation kept beside its subject moves with the mutation and the mutation survives.
///
/// Three assertions, and they fail on three different things ON PURPOSE:
///
///   1. `testTheFrontierIsByteUnchanged` — the derived set equals the manifest set, BYTE
///      for byte. A renamed `CodingKey` appears as one row present in the source and
///      absent from the manifest, and is NAMED.
///   2. `testTheManifestSizeIsAsserted` — the manifest's ROW COUNT equals the derived
///      count, per kind and in total. A DISAPPEARANCE is as much a failure as a change,
///      and set-equality alone would report a deletion as one missing row rather than as a
///      frontier that shrank. The counts are re-derived on every run and pinned nowhere.
///   3. `testTheDerivationIsNotVacuous` — every kind derived a NON-EMPTY population, and
///      every manifest row was MATCHED by the derivation. Without this, a derivation that
///      silently stopped finding anything would agree perfectly with a manifest somebody
///      then regenerated from it, and this file would grade nothing at all. A manifest row
///      that matches no site is DEAD and is also a failure, so the table cannot quietly
///      grow permissions nobody needs.
///
/// ## What this frontier IS, and — measured — what it EXCLUDES
///
/// KIND `coding-key`   every `case` inside every `enum CodingKeys: String, CodingKey` in
///                     `Sources/FoundryXKit`, with its explicit raw value when it has one.
///                     These are the JSON object keys already written to every installed
///                     device. `AppPlacement.doorTier` is one of them.
/// KIND `on-disk-name` every persisted file-name literal (`.json`, `.bin`, `.sqlite3`,
///                     `.plist`) in `Sources/FoundryXKit`. These are the paths an upgrade
///                     must still find.
///
/// NOT IN THIS FRONTIER, stated rather than implied away: Keychain service and account
/// strings, `UserDefaults` key literals, and every identifier under `App/`, `Widget/` and
/// `UITests/`. They are persisted too. They are not derived here, so this file makes no
/// claim about them, and A5 is covered for the two kinds above and no further. Naming the
/// exclusion is the measurement; a frontier that quietly meant "whatever I happened to
/// parse" would be the completeness-by-enumeration non-sequitur this program refuses.
final class IdentifierFrontierTests: XCTestCase {

    // MARK: - The tree

    private static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // Tests/FoundryXBrineTests/<file>
        return url
    }

    private static let derivationRoot = "Sources/FoundryXKit"
    private static let manifestPath = "evidence/t13/identifier-frontier.tsv"

    private struct Row: Hashable, Comparable {
        let kind: String
        let path: String
        let literal: String

        var line: String { "\(kind)\t\(path)\t\(literal)" }

        static func < (a: Row, b: Row) -> Bool { a.line < b.line }
    }

    private static func swiftFiles() throws -> [URL] {
        let base = repoRoot().appendingPathComponent(derivationRoot, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            XCTFail("REFUSED: \(derivationRoot) is not a directory under \(repoRoot().path). "
                  + "A derivation that walked nothing would report an empty frontier and agree "
                  + "with a manifest nobody could then falsify.")
            return []
        }
        guard let walk = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func relativePath(_ url: URL) -> String {
        let root = repoRoot().path.hasSuffix("/") ? repoRoot().path : repoRoot().path + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
    }

    // MARK: - The derivation

    /// `//` and `/* … */` are removed; string literals are LEFT INTACT, because a
    /// persisted name IS a string literal. A `//` inside a string is not a comment.
    private static func stripComments(_ source: String) -> String {
        var out = ""
        var inString = false
        var inLineComment = false
        var inBlockComment = false
        var previous: Character? = nil
        var escaped = false
        for character in source {
            if inLineComment {
                if character == "\n" { inLineComment = false; out.append(character) }
                previous = character
                continue
            }
            if inBlockComment {
                if previous == "*" && character == "/" { inBlockComment = false; previous = nil; continue }
                if character == "\n" { out.append(character) }
                previous = character
                continue
            }
            if inString {
                out.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                previous = character
                continue
            }
            if previous == "/" && character == "/" { out.removeLast(); inLineComment = true; previous = nil; continue }
            if previous == "/" && character == "*" { out.removeLast(); inBlockComment = true; previous = nil; continue }
            if character == "\"" { inString = true }
            out.append(character)
            previous = character
        }
        return out
    }

    /// Every `case` inside every `enum CodingKeys: String, CodingKey { … }`, with its
    /// explicit raw value where one is written. `case tab, openCaptureId` yields two rows;
    /// `case doorTier = "door_tier"` yields `doorTier = "door_tier"`, because BOTH halves
    /// are on the frontier — the Swift name is what code reads and the raw value is what
    /// the file on the device contains.
    private static func codingKeyRows(_ source: String, path: String) -> [Row] {
        var rows: [Row] = []
        let text = Array(stripComments(source))
        let needle = Array("enum CodingKeys")
        var index = 0
        while index + needle.count <= text.count {
            guard Array(text[index..<(index + needle.count)]) == needle else { index += 1; continue }
            // Only a `String`-backed CodingKey enum persists a spelling.
            var cursor = index + needle.count
            var header = ""
            while cursor < text.count && text[cursor] != "{" { header.append(text[cursor]); cursor += 1 }
            guard header.contains("String"), cursor < text.count else { index += 1; continue }
            // Balance braces to find the body.
            var depth = 0
            var body = ""
            while cursor < text.count {
                let character = text[cursor]
                if character == "{" { depth += 1; if depth == 1 { cursor += 1; continue } }
                if character == "}" { depth -= 1; if depth == 0 { break } }
                body.append(character)
                cursor += 1
            }
            for rawLine in body.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("case ") else { continue }
                let declarations = String(line.dropFirst("case ".count))
                for declaration in declarations.split(separator: ",") {
                    let spelled = declaration.trimmingCharacters(in: .whitespaces)
                    guard !spelled.isEmpty else { continue }
                    rows.append(Row(kind: "coding-key", path: path, literal: spelled))
                }
            }
            index = cursor
        }
        return rows
    }

    private static let persistedExtensions = ["json", "bin", "sqlite3", "plist"]

    /// Every string literal whose contents end in a persisted file extension.
    private static func onDiskNameRows(_ source: String, path: String) -> [Row] {
        var rows: [Row] = []
        let text = Array(stripComments(source))
        var index = 0
        while index < text.count {
            guard text[index] == "\"" else { index += 1; continue }
            var cursor = index + 1
            var literal = ""
            var escaped = false
            var closed = false
            while cursor < text.count {
                let character = text[cursor]
                if escaped { literal.append(character); escaped = false; cursor += 1; continue }
                if character == "\\" { escaped = true; cursor += 1; continue }
                if character == "\"" { closed = true; break }
                if character == "\n" { break }
                literal.append(character)
                cursor += 1
            }
            // A literal that is ONLY an extension (`".json"`) is not a persisted NAME, and
            // counting it as one is not a nicety. MEASURED: the A5 deletion mutation
            // rewrote `"recording-devices.json"` as `"recording-devices" + ".json"`, and
            // without this guard the derivation SWAPPED one row for another and the SIZE
            // assertion stayed green at 173 == 173 — the disappearance was absorbed by an
            // artefact of the derivation. The stem must be non-empty.
            if closed, persistedExtensions.contains(where: {
                literal.hasSuffix("." + $0) && literal.count > $0.count + 1
            }) {
                rows.append(Row(kind: "on-disk-name", path: path, literal: literal))
            }
            index = closed ? cursor + 1 : index + 1
        }
        return rows
    }

    private static func derivedFrontier() throws -> [Row] {
        var rows: Set<Row> = []
        for file in try swiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let path = relativePath(file)
            for row in codingKeyRows(source, path: path) { rows.insert(row) }
            for row in onDiskNameRows(source, path: path) { rows.insert(row) }
        }
        return rows.sorted()
    }

    // MARK: - The manifest

    private static func manifestRows() throws -> [Row] {
        let url = repoRoot().appendingPathComponent(manifestPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("REFUSED: the pinned frontier manifest \(manifestPath) does not exist. "
                  + "There is nothing to compare the source against, and a comparison against "
                  + "an absent oracle is not a pass.")
            return []
        }
        var rows: [Row] = []
        for rawLine in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 3 else {
                XCTFail("REFUSED: malformed manifest row (expected kind<TAB>path<TAB>literal): \(line)")
                continue
            }
            rows.append(Row(kind: fields[0], path: fields[1], literal: fields[2]))
        }
        return rows.sorted()
    }

    // MARK: - The three assertions

    func testTheFrontierIsByteUnchanged() throws {
        let derived = Set(try Self.derivedFrontier())
        let pinned = Set(try Self.manifestRows())
        let added = derived.subtracting(pinned).sorted()
        let removed = pinned.subtracting(derived).sorted()

        if !added.isEmpty || !removed.isEmpty {
            var report = "IDENTIFIER FRONTIER: \(derived.count) derived, \(pinned.count) pinned, "
                       + "\(added.count) present in source and NOT pinned, "
                       + "\(removed.count) pinned and NOT present in source.\n"
            for row in added { report += "  CHANGED-OR-ADDED  \(row.line)\n" }
            for row in removed { report += "  MISSING-FROM-SOURCE  \(row.line)\n" }
            report += "A persisted identifier that moved is a data migration, not a rename: "
                    + "every installed device already has the old spelling on disk."
            XCTFail(report)
        }
    }

    func testTheManifestSizeIsAsserted() throws {
        let derived = try Self.derivedFrontier()
        let pinned = try Self.manifestRows()

        var derivedByKind: [String: Int] = [:]
        for row in derived { derivedByKind[row.kind, default: 0] += 1 }
        var pinnedByKind: [String: Int] = [:]
        for row in pinned { pinnedByKind[row.kind, default: 0] += 1 }

        let kinds = Set(derivedByKind.keys).union(pinnedByKind.keys).sorted()
        for kind in kinds {
            XCTAssertEqual(
                derivedByKind[kind] ?? 0, pinnedByKind[kind] ?? 0,
                "FRONTIER SIZE: kind `\(kind)` derived \(derivedByKind[kind] ?? 0) row(s) and the "
              + "manifest pins \(pinnedByKind[kind] ?? 0). A DISAPPEARANCE is as much a failure as "
              + "a change — set equality alone would report a deleted literal as one missing row "
              + "rather than as a frontier that shrank.")
        }
        XCTAssertEqual(
            derived.count, pinned.count,
            "FRONTIER SIZE: \(derived.count) identifier(s) derived from \(Self.derivationRoot), "
          + "\(pinned.count) pinned in \(Self.manifestPath). Both numbers are re-derived on every "
          + "run and neither is written in this file.")
    }

    func testTheDerivationIsNotVacuous() throws {
        let derived = try Self.derivedFrontier()
        let pinned = try Self.manifestRows()

        var byKind: [String: Int] = [:]
        for row in derived { byKind[row.kind, default: 0] += 1 }
        for kind in ["coding-key", "on-disk-name"] {
            XCTAssertGreaterThan(
                byKind[kind] ?? 0, 0,
                "VACUOUS: the derivation found ZERO `\(kind)` rows in \(Self.derivationRoot). "
              + "A derivation that stops finding anything agrees perfectly with a manifest "
              + "regenerated from it, and grades nothing at all.")
        }
        let derivedSet = Set(derived)
        let dead = pinned.filter { !derivedSet.contains($0) }
        XCTAssertTrue(
            dead.isEmpty,
            "DEAD MANIFEST ROW(S) — pinned but matched by no site, so the table is growing "
          + "permissions nobody needs:\n" + dead.map { "  " + $0.line }.joined(separator: "\n"))

        print("IDENTIFIER FRONTIER: \(try Self.swiftFiles().count) file(s) walked, "
            + "\(derived.count) frontier identifier(s) derived "
            + "(" + byKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "), "
            + "\(pinned.count) pinned, \(dead.count) dead manifest row(s).")
    }
}
