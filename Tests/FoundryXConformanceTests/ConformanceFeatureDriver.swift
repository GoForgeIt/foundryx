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

/// The census that replaces a UNIVERSAL NOBODY COUNTED.
///
/// Until 2026-08-13 `features/p3-conformance.feature` opened by asserting *"there is no
/// injected responder anywhere in this target"*. That sentence was FALSE the whole time:
/// `DoorFixture.swift` constructs a `NoiseXXResponder` in this process and completes a
/// real msg1/msg2/msg3 handshake with the client, because P1's observable is whether the
/// client proceeds against a real counterpart. Nothing went red, because nothing counted.
///
/// The true claim is narrower and has TWO halves, and both are counted here rather than
/// written down:
///
///  1. this target constructs a KNOWN NUMBER of in-process handshake peers (today 1), so
///     adding one — which is exactly what moving the hermetic prologue oracle in here
///     would do — is RED and names the file; and deleting the one there is is RED too;
///  2. the sources that DRIVE THE FIVE CONTRACT ELEMENTS construct NONE. That is what
///     "no injected peer stands in for the relay" actually means, and a single total
///     would be satisfied by moving a peer from one file into the element drive.
///
/// ## The rename trap, and why the needles are read out of FoundryXKit
///
/// A census with a hardcoded `"NoiseXXResponder("` needle silently counts zero the day
/// the type is renamed — the failure mode where a check keeps passing because it stopped
/// looking. So the peer type names are RESOLVED FROM `Sources/FoundryXKit/NoiseXX.swift`
/// at run time and the census REFUSES (throws) if that file declares none. A rename moves
/// both sides together; a deletion is loud.
///
/// ## WHAT THIS CENSUS CANNOT SEE — named, because the number would otherwise read as a
/// claim it does not support
///
/// This is a LEXICAL census of DIRECT constructor call sites in this one directory. It is
/// not a call graph and it is not a statement about which peers run. Specifically:
///
///  * **THE TARGET ALREADY USES A PEER IT DOES NOT CONSTRUCT HERE.** P1 dials through the
///    production client, which builds an initiator inside FoundryXKit
///    (`Sources/FoundryXKit/RelayTransport.swift`, `Sources/FoundryXKit/DoorConnection.swift`).
///    So "one site" is true and "one peer" would be false. The report says which.
///  * a `typealias`, a `.init(…)` under contextual typing, a captured `.init`, a factory
///    that returns a peer, or a construction split across two lines is not matched;
///  * a rename that keeps the `NoiseXX` prefix moves both sides together and is invisible
///    to the count, which is the intent; a rename that drops the prefix on ONE type leaves
///    the other resolving, so the non-empty guard still passes and the count drops — which
///    is why the count is asserted against a declared number rather than against zero.
///
/// What it does cover is the thing worth guarding: a peer appearing next to the element
/// drive, and the declared number moving without the code moving with it.
enum ConformancePeerCensus {

    /// The handshake peer types, taken from FoundryXKit's own source rather than from a
    /// literal here.
    static func peerTypeNames() throws -> [String] {
        let url = ConformanceFeatureDriver.repoRoot
            .appendingPathComponent("Sources/FoundryXKit/NoiseXX.swift")
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ConformanceStepError("the peer census could not read \(url.path); it publishes no count from a run that never read the declarations")
        }
        let text = String(decoding: data, as: UTF8.self)
        var names: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            let tokens = trimmed.split(separator: " ").map(String.init)
            for (i, token) in tokens.enumerated() where ["class", "struct", "actor"].contains(token) {
                guard i + 1 < tokens.count else { continue }
                let ident = String(tokens[i + 1].prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                if ident.hasPrefix("NoiseXX"), !names.contains(ident) { names.append(ident) }
            }
        }
        guard !names.isEmpty else {
            throw ConformanceStepError("the peer census found no handshake peer type declared in Sources/FoundryXKit/NoiseXX.swift. A census with nothing to look for reports zero and proves nothing.")
        }
        return names.sorted()
    }

    /// Construction sites of any peer type, in the given files. `file:line — needle`.
    static func sites(in files: [URL]) throws -> [String] {
        let needles = try peerTypeNames().map { $0 + "(" }
        var hits: [String] = []
        for f in files {
            guard let data = FileManager.default.contents(atPath: f.path) else {
                throw ConformanceStepError("the peer census could not read \(f.path)")
            }
            let text = String(decoding: data, as: UTF8.self)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                for needle in needles {
                    guard let at = line.range(of: needle) else { continue }
                    // The names appear in this file's own prose and in string literals
                    // that report them. A census that counted those would count itself.
                    if at.lowerBound > line.startIndex,
                       line[line.index(before: at.lowerBound)] == "\"" { continue }
                    hits.append("\(f.lastPathComponent):\(n + 1) — \(needle)")
                }
            }
        }
        return hits.sorted()
    }

    static func targetSwiftFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: ConformanceFeatureDriver.targetSources,
                                                    includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The sources that drive the five contract elements. Named explicitly, and each one
    /// is required to exist: a set resolved by pattern could go empty after a rename and
    /// the "constructs none" leg would pass over nothing.
    static func elementDriveSources(_ names: [String]) throws -> [URL] {
        var urls: [URL] = []
        for name in names {
            let url = ConformanceFeatureDriver.targetSources.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ConformanceStepError("the element-drive census names \(name), which is not on disk. A census over a file that does not exist reports zero peers and proves nothing.")
            }
            urls.append(url)
        }
        return urls
    }
}

/// The declared half of the contract-element comparison.
struct ContractElementRegister {
    struct Row: Decodable {
        let id: String
        let name: String
        let served: Bool
        /// The per-question declaration, for the elements whose verdict is a
        /// conjunction. Absent for the elements that are a single question.
        let parts: [String: String]?
    }
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
