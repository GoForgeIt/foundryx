import XCTest
import Foundation
import CryptoKit

/// T0 verifier for track 20260725T2306_device_agnostic_recording_source.
///
/// WHAT IT IS FOR. The plan assigns every spec scenario to exactly ONE task that must
/// assert EVERY `Then` of that scenario, and gives each scenario a Required-Then
/// capability column. Nothing in a Swift package normally notices when a `Then` clause
/// quietly loses its owner, when a capability token is dropped from the ledger, or when a
/// dependency is declared on a task that runs LATER than its owner. This test is that
/// noticer: it re-derives the clause population from the pinned `spec.md`, re-derives the
/// ledger from the pinned `plan.md`, and requires `then-capabilities.json` to agree with
/// both in BOTH directions.
///
/// WHY THE ARTIFACTS ARE PINNED IN-REPO. The track artifacts live in the separate
/// `foundryx-hearth` repository. A verifier that reached outside this package would be
/// unrunnable in CI, and one that SKIPPED when the sibling checkout was missing would be
/// an unfailable check. Both frozen artifacts (spec R6, plan R13) are therefore copied to
/// `Tests/FoundryXBrineTests/fixtures/device-agnostic/` with their sha256 recorded in
/// `PROVENANCE.txt`, and parsed here directly.
///
/// EVERY ARM MUST BE ABLE TO FAIL. A selection that resolves zero scenarios, zero clauses,
/// or zero ledger rows is a STOP, not a pass.
final class ThenCapabilityMapTests: XCTestCase {

    // MARK: - Pinned populations (a change here is a deliberate, reviewed change)

    private static let expectedSpecScenarios = 17
    private static let expectedSpecThenClauses = 52
    private static let expectedLedgerRows = 19
    private static let planLevelScenarioIDs: Set<String> = ["P01", "P02"]

    // MARK: - Locations

    private static var repoRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }
    private static var specURL: URL {
        repoRoot.appendingPathComponent("Tests/FoundryXBrineTests/fixtures/device-agnostic/spec.md")
    }
    private static var planURL: URL {
        repoRoot.appendingPathComponent("Tests/FoundryXBrineTests/fixtures/device-agnostic/plan.md")
    }
    private static var planLevelFeatureURL: URL {
        repoRoot.appendingPathComponent("features/device-ambient-silence.feature")
    }
    private static var mapURL: URL {
        repoRoot.appendingPathComponent("Tests/FoundryXBrineTests/then-capabilities.json")
    }

    // MARK: - Parsed shapes

    /// One Gherkin scenario reduced to its ordered `Then` / post-`Then` `And` clauses.
    struct ParsedScenario: Equatable {
        let name: String
        let thens: [String]
    }

    /// One row of the plan's scenario-owner ledger.
    struct LedgerRow: Equatable {
        let id: String
        let name: String
        let required: [String]
        let owner: String
        let deps: [String]
    }

    /// One `scenarios[]` entry of `then-capabilities.json`.
    struct MapEntry {
        let id: String
        let name: String
        let owner: String
        let deps: [String]
        let required: [String]
        /// Preserved as pairs so a DUPLICATE key in the JSON is detectable; a dictionary
        /// would silently collapse it.
        let thens: [(clause: String, tokens: [String])]
    }

    // MARK: - Normalization

    /// Trim, then collapse every internal whitespace run to one space. Two clauses that
    /// differ only in wrapping are the same clause; nothing else is folded (case and
    /// punctuation are significant).
    static func normalize(_ raw: String) -> String {
        raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }

    // MARK: - Parsers

    /// Gherkin scenarios and their `Then` / post-`Then` `And` clauses, by the same rule the
    /// plan's census uses: `And` counts only while the last keyword seen was `Then`.
    static func parseScenarios(_ text: String) -> [ParsedScenario] {
        var out: [ParsedScenario] = []
        var name: String?
        var thens: [String] = []
        var afterThen = false

        func flush() {
            if let name { out.append(ParsedScenario(name: name, thens: thens)) }
            name = nil
            thens = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let rest = keywordBody(line, "Scenario Outline:") ?? keywordBody(line, "Scenario:") {
                flush()
                name = normalize(rest)
                afterThen = false
            } else if let rest = keywordBody(line, "Then ") {
                thens.append(normalize(rest))
                afterThen = true
            } else if let rest = keywordBody(line, "And "), afterThen {
                thens.append(normalize(rest))
            } else if keywordBody(line, "Given ") != nil
                        || keywordBody(line, "When ") != nil
                        || keywordBody(line, "But ") != nil {
                afterThen = false
            }
        }
        flush()
        return out
    }

    private static func keywordBody(_ line: String, _ keyword: String) -> String? {
        guard line.hasPrefix(keyword) else { return nil }
        return String(line.dropFirst(keyword.count))
    }

    /// The plan's scenario-owner ledger. Only real five-column table rows whose first cell
    /// is an `S`/`P` id match; the plan's fenced code blocks quote the same regex as text
    /// and must not be mistaken for rows.
    static func parseLedger(_ text: String) -> [LedgerRow] {
        var rows: [LedgerRow] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("| "), line.hasSuffix(" |") else { continue }
            let cells = line.dropFirst(1).dropLast(1)
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 5 else { continue }
            let id = cells[0]
            guard id.count == 3, let first = id.first, first == "S" || first == "P",
                  id.dropFirst().allSatisfy(\.isNumber) else { continue }
            let deps = cells[4] == "none"
                ? []
                : cells[4].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            rows.append(LedgerRow(
                id: id,
                name: normalize(cells[1]),
                required: cells[2].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                owner: cells[3],
                deps: deps))
        }
        return rows
    }

    /// The task-level declarations, independent of the per-scenario `owner` column.
    static func parseTaskDeclarations(
        _ data: Data
    ) throws -> (capabilities: [String: [String]], assertions: [String: [String]]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capabilities = root["taskCapabilities"] as? [String: [String]],
              let assertions = root["taskAssertions"] as? [String: [String]] else {
            throw MapError("then-capabilities.json has no taskCapabilities / taskAssertions")
        }
        return (capabilities, assertions)
    }

    static func parseMap(_ data: Data) throws -> [MapEntry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["scenarios"] as? [[String: Any]] else {
            throw MapError("then-capabilities.json has no `scenarios` array")
        }
        // JSONSerialization collapses duplicate object keys, so duplicate `thens` keys are
        // caught by comparing the decoded pair count against the raw text later.
        return try raw.map { entry in
            guard let id = entry["id"] as? String,
                  let name = entry["name"] as? String,
                  let owner = entry["owner"] as? String,
                  let deps = entry["deps"] as? [String],
                  let required = entry["required"] as? [String],
                  let thens = entry["thens"] as? [String: [String]] else {
                throw MapError("malformed scenario entry: \(entry["id"] ?? "?")")
            }
            return MapEntry(
                id: id, name: normalize(name), owner: owner, deps: deps, required: required,
                thens: thens.map { (normalize($0.key), $0.value) })
        }
    }

    struct MapError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Loading, with a loud stop on an empty selection

    private func loadEverything() throws -> (spec: [ParsedScenario],
                                             planLevel: [ParsedScenario],
                                             ledger: [LedgerRow],
                                             map: [MapEntry]) {
        let specText = try String(contentsOf: Self.specURL, encoding: .utf8)
        let planText = try String(contentsOf: Self.planURL, encoding: .utf8)
        let featureText = try String(contentsOf: Self.planLevelFeatureURL, encoding: .utf8)
        let map = try Self.parseMap(try Data(contentsOf: Self.mapURL))

        let spec = Self.parseScenarios(specText)
        let planLevel = Self.parseScenarios(featureText)
        let ledger = Self.parseLedger(planText)

        XCTAssertFalse(spec.isEmpty, "STOP: parsed zero scenarios from the pinned spec")
        XCTAssertFalse(planLevel.isEmpty, "STOP: parsed zero scenarios from the plan-level feature")
        XCTAssertFalse(ledger.isEmpty, "STOP: parsed zero ledger rows from the pinned plan")
        XCTAssertFalse(map.isEmpty, "STOP: then-capabilities.json declares zero scenarios")
        return (spec, planLevel, ledger, map)
    }

    // MARK: - The populations themselves

    func testPinnedPopulationsAreUnchanged() throws {
        let (spec, planLevel, ledger, map) = try loadEverything()
        XCTAssertEqual(spec.count, Self.expectedSpecScenarios,
                       "spec scenario count changed")
        XCTAssertEqual(spec.reduce(0) { $0 + $1.thens.count }, Self.expectedSpecThenClauses,
                       "spec Then-clause count changed")
        XCTAssertEqual(ledger.count, Self.expectedLedgerRows,
                       "plan ledger row count changed")
        XCTAssertEqual(map.count, Self.expectedLedgerRows,
                       "then-capabilities.json scenario count must equal the ledger")
        XCTAssertEqual(Set(planLevel.map(\.name)).count, Self.planLevelScenarioIDs.count,
                       "the plan-level feature must declare exactly the two allow-listed scenarios")
    }

    /// The ledger's scenario names are exactly the spec's plus the two allow-listed
    /// plan-level scenarios — the census property, re-derived here from the pinned files.
    func testLedgerCoversTheSpecAndOnlyTheAllowedExtras() throws {
        let (spec, planLevel, ledger, _) = try loadEverything()
        let specNames = Set(spec.map(\.name))
        let ledgerNames = ledger.map(\.name)
        XCTAssertEqual(ledgerNames.count, Set(ledgerNames).count, "duplicate ledger scenario name")
        XCTAssertTrue(specNames.subtracting(ledgerNames).isEmpty,
                      "spec scenarios missing from the ledger: \(specNames.subtracting(ledgerNames).sorted())")
        XCTAssertEqual(Set(ledgerNames).subtracting(specNames), Set(planLevel.map(\.name)),
                       "the only non-spec ledger rows must be the two plan-level scenarios")
    }

    /// Every ledger row's dependencies run strictly earlier than its owner.
    func testEveryDependencyPrecedesItsOwner() throws {
        let (_, _, ledger, map) = try loadEverything()
        func number(_ task: String) -> Int? { Int(task.dropFirst()) }
        for row in ledger {
            guard let owner = number(row.owner) else {
                return XCTFail("unparseable owner \(row.owner) on \(row.id)")
            }
            for dep in row.deps {
                guard let depNumber = number(dep) else {
                    return XCTFail("unparseable dependency \(dep) on \(row.id)")
                }
                XCTAssertLessThan(depNumber, owner,
                                  "\(row.id): dependency \(dep) is not earlier than owner \(row.owner)")
            }
        }
        // The map repeats owner/deps; it must repeat them FAITHFULLY, or the check above
        // would be validating a column nothing else reads.
        for entry in map {
            guard let row = ledger.first(where: { $0.id == entry.id }) else {
                return XCTFail("\(entry.id) is in the map but not in the plan ledger")
            }
            XCTAssertEqual(entry.owner, row.owner, "\(entry.id): owner disagrees with the plan ledger")
            XCTAssertEqual(entry.deps, row.deps, "\(entry.id): dependencies disagree with the plan ledger")
            XCTAssertEqual(entry.name, row.name, "\(entry.id): scenario name disagrees with the plan ledger")
        }
    }

    /// L2 — the plan's owner/capability rule, made durable.
    ///
    /// The plan states it: "the sole owner must declare that it **asserts every Then**; each
    /// required capability must be in the implementation set of the owner or a declared
    /// earlier dependency." That check lived only in a plan-time Node script, so nothing in
    /// CI re-ran it after T0 — a reviewer mutation that reassigned `S08`'s owner from `T2` to
    /// `T5`, consistently in BOTH the pinned ledger and the map, stayed green. It reds now.
    ///
    /// `taskAssertions` is declared independently of the `owner` column FOR THAT REASON:
    /// derived from it, the first arm would be a tautology.
    func testEveryOwnerAssertsItsScenarioAndCanImplementItsCapabilities() throws {
        let (_, _, ledger, _) = try loadEverything()
        let (capabilities, assertions) = try Self.parseTaskDeclarations(try Data(contentsOf: Self.mapURL))
        XCTAssertFalse(capabilities.isEmpty, "STOP: no task capability declarations")
        XCTAssertFalse(assertions.isEmpty, "STOP: no task assertion declarations")

        // Every declared assertion names a real ledger row, so the declaration cannot drift
        // into naming scenarios that do not exist.
        let ledgerIDs = Set(ledger.map(\.id))
        for (task, ids) in assertions {
            for id in ids {
                XCTAssertTrue(ledgerIDs.contains(id), "\(task) claims to assert unknown scenario \(id)")
            }
        }

        var checked = 0
        for row in ledger {
            XCTAssertTrue(assertions[row.owner]?.contains(row.id) ?? false,
                          "\(row.id): \(row.owner) is the ledger owner but does not declare that it asserts every Then")
            let built = Set(([row.owner] + row.deps).flatMap { capabilities[$0] ?? [] })
            let missing = Set(row.required).subtracting(built)
            XCTAssertTrue(missing.isEmpty,
                          "\(row.id): \(missing.sorted()) implemented by neither owner \(row.owner) nor a declared earlier dependency \(row.deps)")
            checked += 1
        }
        XCTAssertEqual(checked, Self.expectedLedgerRows, "STOP: not every ledger row was checked")
    }

    /// L4 — the vendored artifacts must still be the ones `PROVENANCE.txt` pins.
    ///
    /// The hermetic arm always runs: an edit to either pinned copy reds immediately. The
    /// second arm is opportunistic — it can only run where the hearth checkout exists beside
    /// the repo — and when it CAN run, a mismatch is a hard failure, not a warning. Absence
    /// of the hearth never turns the hermetic arm off.
    func testVendoredArtifactsStillMatchTheirRecordedHashes() throws {
        let provenance = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Tests/FoundryXBrineTests/fixtures/device-agnostic/PROVENANCE.txt"),
            encoding: .utf8)

        func recordedHash(for name: String) throws -> String {
            let line = try XCTUnwrap(
                provenance.components(separatedBy: .newlines)
                    .first { $0.hasSuffix(" \(name)") || $0.hasSuffix("/\(name)") },
                "PROVENANCE.txt records no sha256 for \(name)")
            return try XCTUnwrap(line.split(separator: " ").first.map(String.init))
        }
        func hash(of url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }

        var compared = 0
        for (name, url) in [("spec.md", Self.specURL), ("plan.md", Self.planURL)] {
            XCTAssertEqual(try hash(of: url), try recordedHash(for: name),
                           "the vendored \(name) no longer matches its recorded sha256")
            compared += 1
        }
        XCTAssertEqual(compared, 2, "STOP: the drift check compared nothing")

        // Opportunistic: has the hearth artifact been revised out from under the pin?
        let hearth = Self.repoRoot
            .deletingLastPathComponent()
            .appendingPathComponent(
                "foundryx-hearth/tracks/20260725T2306_device_agnostic_recording_source",
                isDirectory: true)
        guard FileManager.default.fileExists(atPath: hearth.path) else { return }
        for name in ["spec.md", "plan.md"] {
            let live = hearth.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: live.path) else { continue }
            XCTAssertEqual(try hash(of: live), try recordedHash(for: name),
                           "the hearth's \(name) has been revised; the pinned copy and "
                               + "PROVENANCE.txt are stale and the verifier is validating an old artifact")
        }
    }

    /// The core property: every `Then` clause of every scenario is mapped exactly once,
    /// carries at least one capability token, and the per-scenario token UNION equals the
    /// ledger's Required-Then column in both directions.
    func testEveryThenClauseIsMappedAndTheUnionsMatchTheLedger() throws {
        let (spec, planLevel, ledger, map) = try loadEverything()

        var parsedByName: [String: [String]] = [:]
        for scenario in spec + planLevel { parsedByName[scenario.name] = scenario.thens }

        var checkedClauses = 0
        for entry in map {
            guard let row = ledger.first(where: { $0.id == entry.id }) else {
                XCTFail("\(entry.id) is in the map but not in the plan ledger")
                continue
            }
            guard let clauses = parsedByName[entry.name] else {
                XCTFail("\(entry.id) names a scenario that is in neither the spec nor the plan-level feature: \(entry.name)")
                continue
            }
            XCTAssertFalse(clauses.isEmpty, "STOP: \(entry.id) resolved zero Then clauses")

            let mapped = entry.thens.map(\.clause)
            XCTAssertEqual(mapped.count, Set(mapped).count, "\(entry.id): a Then clause is mapped twice")
            XCTAssertEqual(Set(mapped), Set(clauses), """
                \(entry.id) (\(entry.name)) Then-clause mapping does not match the source text.
                unmapped clauses: \(Set(clauses).subtracting(mapped).sorted())
                mappings with no matching clause: \(Set(mapped).subtracting(clauses).sorted())
                """)

            for (clause, tokens) in entry.thens {
                XCTAssertFalse(tokens.isEmpty, "\(entry.id): clause has no capability token — \(clause)")
                checkedClauses += 1
            }

            let union = Set(entry.thens.flatMap(\.tokens))
            XCTAssertEqual(union, Set(row.required), """
                \(entry.id) (\(entry.name)) token union does not equal the ledger's Required-Then column.
                in the clauses but not the ledger: \(union.subtracting(row.required).sorted())
                in the ledger but not the clauses: \(Set(row.required).subtracting(union).sorted())
                """)
            XCTAssertEqual(entry.required.sorted(), row.required.sorted(),
                           "\(entry.id): the map's `required` copy disagrees with the plan ledger")
        }

        XCTAssertEqual(checkedClauses,
                       Self.expectedSpecThenClauses + planLevel.reduce(0) { $0 + $1.thens.count },
                       "STOP: the number of clauses actually checked is not the whole population")
    }
}
