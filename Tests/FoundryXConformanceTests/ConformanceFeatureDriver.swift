import XCTest
import Foundation
import BrineSwiftCore

/// This target's OWN feature driver.
///
/// It deliberately does not use `Tests/FoundryXBrineTests/BrineFeatureRunner.swift`,
/// whose header declares it a "hermetic runner (no real network, no real hardware;
/// every seam is injected)". `FoundryXConformanceTests` is a separate target in
/// `Package.swift` and cannot see that type at all, which is what makes the
/// separation a fact of the build graph rather than a convention — merge the two and
/// this file stops compiling.
///
/// The one behaviour it adds over the hermetic runner: it asserts an EXECUTED count
/// and refuses to report a pass for zero work, the same discipline
/// `scripts/ci-gates.sh` enforces at its tail with "RESOLVED PHASE LIST RAN NOTHING —
/// this is a gate bug, not a pass".
enum ConformanceFeatureDriver {

    /// Repo root is three parents up from this file (Tests/FoundryXConformanceTests/…).
    static var repoRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    static var targetSources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    static func featureText(_ name: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("features/\(name).feature"), encoding: .utf8)
    }

    @discardableResult
    static func run(_ name: String, registry: StepRegistry, expectedScenarios: Int) async throws -> RunResult {
        let parsed = parseFeatureText(try featureText(name))
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed for \(name)")

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry,
                                             resources: [], collector: { collected.append($0) })

        var failures: [String] = []
        var executed = 0
        for ev in collected {
            guard case .object(let o) = ev, case .string("scenario_end")? = o["type"] else { continue }
            executed += 1
            guard case .string(let status)? = o["status"], status != "passed" else { continue }
            let nm: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(nm): \(err)")
        }

        // THE EXECUTED COUNT, ASSERTED AS A NUMBER. A filter that matches nothing, a
        // renamed feature file, or a target that silently stopped being built all
        // produce zero scenarios and a green suite otherwise.
        XCTAssertGreaterThan(executed, 0,
                             "\(name): ZERO SCENARIOS EXECUTED — this is a gate bug, not a pass")
        XCTAssertEqual(executed, expectedScenarios,
                       "\(name): executed \(executed) scenarios, expected \(expectedScenarios). A scenario that stopped running is not a pass.")
        XCTAssertEqual(result.skipped, 0,
                       "\(name): \(result.skipped) scenarios were skipped. Absence of a relay is a RED, not a skip.")
        XCTAssertTrue(failures.isEmpty, "\(name) scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "\(name): expected 0 failed scenarios")
        return result
    }
}

/// A plain step-failure error whose message surfaces verbatim in the scenario diff.
struct ConformanceStepError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The census that keeps this target honest about the repo's own default.
///
/// `Tests/FoundryXBrineTests/` carries 30 `XCTSkip` sites; each reports green on a
/// machine that cannot run the test it guards. This target may contain none, and the
/// rule is asserted as a COUNT over its own sources rather than trusted to review.
enum ConformanceSkipCensus {
    static func skipSites() throws -> [String] {
        let dir = ConformanceFeatureDriver.targetSources
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        // The needle is ASSEMBLED AT RUNTIME so that this census does not count its
        // own matcher. The first run of this feature failed exactly that way: the line
        // holding the literal was itself a hit. Excluding this file by name would have
        // been the other repair, and it is the wrong one — it would make a real skip
        // added here invisible to the only check that looks for one.
        let needle = "XCTSk" + "ip"
        var hits: [String] = []
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // The census counts CALL SITES. The name also appears in the prose of
                // this target, naming the pattern it refuses, so a comment line is not
                // an offence and neither is an occurrence inside a string literal.
                guard let at = line.range(of: needle) else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if at.lowerBound > line.startIndex,
                   line[line.index(before: at.lowerBound)] == "\"" { continue }
                hits.append("\(f.lastPathComponent):\(n + 1)")
            }
        }
        return hits
    }

    /// Named so a reader can tell the census looked at something. A census over zero
    /// files reports zero offences and is indistinguishable from a clean one.
    static func filesExamined() throws -> Int {
        try FileManager.default.contentsOfDirectory(at: ConformanceFeatureDriver.targetSources,
                                                   includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.count
    }
}

/// The declared half of the contract-element comparison.
struct ContractElementRegister {
    struct Row: Decodable { let id: String; let name: String; let served: Bool }
    private struct File: Decodable { let elements: [Row] }
    let rows: [Row]

    static func load() throws -> ContractElementRegister {
        let url = ConformanceFeatureDriver.targetSources
            .appendingPathComponent("registers/p3-contract-elements.json")
        let data = try Data(contentsOf: url)
        return ContractElementRegister(rows: try JSONDecoder().decode(File.self, from: data).elements)
    }

    var servedIds: Set<String> { Set(rows.filter { $0.served }.map { $0.id }) }
}
