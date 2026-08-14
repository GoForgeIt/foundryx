import XCTest
import Foundation

/// THE REACHABILITY GATE — does production code EVER CALL the logic the scenarios prove?
///
/// ## The defect class
///
/// Brine scenarios drive INJECTED FAKES, correctly and by design, so logic can be proven
/// without hardware. Nothing in that arrangement asserts that shipping code ever calls the
/// logic. Green therefore proves the code is RIGHT, not that it is REACHED. Four instances in
/// one day: a complete, tested `PocketBLEClient.download` with zero callers under `App/` while
/// all eight Pocket feature files passed; `PocketDurableSync` / `PocketFastSyncCoordinator`
/// written, tested, uncalled, and reported delivered; five `StoredFileLiveBoundarySpy` counters
/// with zero write sites guarding a lifecycle that is a five-line stub; and, in the sibling
/// repository, a field added to a handler the client never calls.
///
/// ## Why a register rather than a rule
///
/// "Every public symbol must have a caller" is unshippable noise — a library target's job is
/// to publish symbols an app has not called yet, and a gate that reds on all of them gets
/// deleted. `registers/production-reachability.json` is a CURATED table: capabilities somebody
/// decided must be reached, each with the production call site that proves it. Its own header
/// carries the reasoning; this file is only the checker.
///
/// ## Both directions, always
///
/// A row that matches nothing is a failure (dead declaration, dead caller) and a capability
/// that starts being reached while the register says it is not is also a failure. The
/// `NounAlignmentCensus` residue rows and the P3 contract register's `served` equality are the
/// same shape, and the three-valued verdict is borrowed outright from the second.
///
/// ## The third verdict is the point
///
/// `reachable` / `unreachable` / `undetermined`. Three false reds in one day came from a
/// checker that could not tell "nothing calls this" from "I cannot see who calls this". A text
/// register cannot follow a protocol existential and cannot read another repository; both are
/// recorded as `undetermined` WITH THE REASON, and `undetermined` is never a pass.
///
/// ## Not satisfiable by a test
///
/// A caller inside `Tests/`, `TestSupport/` or `UITests/` is not production reachability. It is
/// enforced structurally: the root lists are asserted disjoint, and a declared caller that
/// resolves under a non-production root is a named hard failure rather than a satisfied row.
final class ProductionReachabilityRegisterTests: XCTestCase {

    // MARK: - The register, as declared

    private struct Site: Decodable {
        /// The id of an entry point or another capability whose FILE holds this call.
        let via: String?
        /// A production file that is NOT a registered node. Honest, and yields `undetermined`.
        let unregisteredProductionFile: String?
        /// A call the register cannot follow at all (protocol existential, dynamic dispatch).
        /// The value is the REASON, which is printed in the report.
        let dynamic: String?
        let dependsOn: String?
        /// A fragment of the calling LINE. A site is verified only when the line carrying this
        /// anchor ALSO carries the capability's `call_pattern` — an anchor alone can be
        /// satisfied by prose-shaped code that never calls anything.
        let anchor: String?
        /// How many lines the anchor is expected to match. Declared so a second, unrelated
        /// occurrence is a diff somebody has to make rather than a silently wider licence.
        let sites: Int?
        let whyNotLinked: String?

        enum CodingKeys: String, CodingKey {
            case via
            case unregisteredProductionFile = "unregistered_production_file"
            case dynamic
            case dependsOn = "depends_on"
            case anchor
            case sites
            case whyNotLinked = "why_not_linked"
        }

        var expectedSites: Int { sites ?? 1 }
    }

    private struct EntryPoint: Decodable {
        let id: String
        let path: String
        let anchor: String
        let why: String
    }

    private struct Capability: Decodable {
        let id: String
        let name: String
        /// `nil` for a capability whose definition this checker cannot read (another repo).
        let declaredIn: String?
        let declarationAnchor: String?
        let unreadableBecause: String?
        let callPattern: String
        /// When true, the pattern must appear NOWHERE in this repository — the row's only
        /// measurable local fact, and the thing that goes red the day it changes.
        let absentLocally: Bool?
        let reachedFrom: [Site]
        let testedFrom: [String]?
        let verdict: String
        let why: String

        enum CodingKeys: String, CodingKey {
            case id, name, verdict, why
            case declaredIn = "declared_in"
            case declarationAnchor = "declaration_anchor"
            case unreadableBecause = "unreadable_because"
            case callPattern = "call_pattern"
            case absentLocally = "absent_locally"
            case reachedFrom = "reached_from"
            case testedFrom = "tested_from"
        }
    }

    private struct Register: Decodable {
        let productionRoots: [String]
        let nonProductionRoots: [String]
        let entryPoints: [EntryPoint]
        let capabilities: [Capability]
        let verdictCounts: [String: Int]
        let minimumCapabilities: Int
        let minimumEntryPoints: Int

        enum CodingKeys: String, CodingKey {
            case productionRoots = "production_roots"
            case nonProductionRoots = "non_production_roots"
            case entryPoints = "entry_points"
            case capabilities
            case verdictCounts = "verdict_counts"
            case minimumCapabilities = "minimum_capabilities"
            case minimumEntryPoints = "minimum_entry_points"
        }
    }

    // MARK: - Loading

    private static let registerPath = "Tests/FoundryXBrineTests/registers/production-reachability.json"

    private static func loadRegister() throws -> Register {
        let url = AppSourceTree.repoRoot.appendingPathComponent(registerPath)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Register.self, from: data)
    }

    /// A file's CODE — comments removed, string literals blanked. Reused from `AppSourceTree`
    /// rather than reimplemented: two private copies of this walk had already drifted apart
    /// once in this suite (review round 12, L12-1). A capability named in a comment is not
    /// called, and a capability named inside a string literal — a log line, a UI-proof
    /// identifier, another gate's `code.contains("…")` assertion — is not called either.
    ///
    /// Cached because the undeclared-caller scan asks every capability about every production
    /// file: without it the suite re-lexes the whole tree once per row.
    private final class CodeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String?] = [:]
        func code(at relativePath: String) -> String? {
            lock.lock()
            if let hit = storage[relativePath] { lock.unlock(); return hit }
            lock.unlock()
            let url = AppSourceTree.repoRoot.appendingPathComponent(relativePath)
            let stripped = (try? String(contentsOf: url, encoding: .utf8)).map { AppSourceTree.code(of: $0) }
            lock.lock(); storage[relativePath] = stripped; lock.unlock()
            return stripped
        }
    }
    private static let codeCache = CodeCache()
    private static func code(at relativePath: String) -> String? { codeCache.code(at: relativePath) }

    private static func swiftFiles(under roots: [String]) -> [String] {
        var out: [String] = []
        for root in roots {
            let base = AppSourceTree.repoRoot.appendingPathComponent(root, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let walk = FileManager.default.enumerator(at: base,
                                                            includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                out.append(AppSourceTree.relativePath(url))
            }
        }
        return out.sorted()
    }

    private static func lines(in relativePath: String, containing needle: String) -> [String] {
        guard let source = code(at: relativePath) else { return [] }
        return source.components(separatedBy: "\n").filter { $0.contains(needle) }
    }

    private static func filesUnder(_ roots: [String], whoseCodeContains needle: String) -> [String] {
        swiftFiles(under: roots).filter { (code(at: $0) ?? "").contains(needle) }
    }

    // MARK: - Population, before contents

    /// NON-VACUOUS FIRST. A register that lost its rows, or a walk that read the wrong tree,
    /// reports a clean pass over nothing.
    func testTheRegisterAndTheTreeAreBothPopulated() throws {
        let register = try Self.loadRegister()
        XCTAssertGreaterThanOrEqual(
            register.capabilities.count, register.minimumCapabilities,
            "the reachability register declares \(register.capabilities.count) capabilities and "
                + "its own floor is \(register.minimumCapabilities). A register that shrank is a "
                + "gate that stopped asking, and it looks exactly like a pass.")
        XCTAssertGreaterThanOrEqual(register.entryPoints.count, register.minimumEntryPoints,
                                    "no entry points — every capability would be undetermined")

        let production = Self.swiftFiles(under: register.productionRoots)
        XCTAssertGreaterThan(production.count, 50,
            "the walk found \(production.count) production Swift files under "
                + "\(register.productionRoots.joined(separator: ", ")); it is reading the wrong "
                + "tree, and every verdict computed over it is meaningless")
        print("REACHABILITY: \(register.capabilities.count) capabilities, "
              + "\(register.entryPoints.count) entry point(s), "
              + "\(production.count) production files examined")

        // Every id is unique — two rows sharing an id makes `via` ambiguous and silently
        // resolves to whichever the decoder saw first.
        var seen = Set<String>()
        for id in register.entryPoints.map(\.id) + register.capabilities.map(\.id) {
            XCTAssertTrue(seen.insert(id).inserted, "duplicate register id: \(id)")
        }
    }

    /// THE PROPERTY THAT MAKES THIS GATE UNSATISFIABLE BY A TEST. If the two root lists ever
    /// overlap, a caller in `Tests/` becomes production reachability and the whole register is
    /// worth nothing.
    func testProductionAndTestRootsAreDisjoint() throws {
        let register = try Self.loadRegister()
        let overlap = Set(register.productionRoots).intersection(register.nonProductionRoots)
        XCTAssertTrue(overlap.isEmpty,
            "\(overlap.sorted()) is declared BOTH production and non-production. A test caller "
                + "would then count as production reachability, which is the one thing this "
                + "register exists to forbid.")
        XCTAssertFalse(register.productionRoots.isEmpty, "no production roots declared")
        XCTAssertFalse(register.nonProductionRoots.isEmpty, "no non-production roots declared")
    }

    // MARK: - Dead rows, in both directions

    /// A row whose declaration no longer exists is DEAD — it asserts nothing while looking like
    /// a guarantee. The same failure the noun census's residue rows have.
    func testEveryDeclaredCapabilityStillExists() throws {
        let register = try Self.loadRegister()
        for capability in register.capabilities {
            guard let path = capability.declaredIn else {
                XCTAssertNotNil(capability.unreadableBecause,
                    "\(capability.id) declares no `declared_in` and gives no "
                        + "`unreadable_because`. A capability this checker cannot read must SAY "
                        + "why it cannot read it.")
                XCTAssertEqual(capability.verdict, "undetermined",
                    "\(capability.id) has a definition this checker cannot read, so the only "
                        + "honest verdict is `undetermined` — it declares `\(capability.verdict)`")
                continue
            }
            guard let anchor = capability.declarationAnchor else {
                return XCTFail("\(capability.id) declares a file but no `declaration_anchor`")
            }
            XCTAssertNotNil(Self.code(at: path),
                            "\(capability.id): \(path) does not exist or is not readable")
            let matches = Self.lines(in: path, containing: anchor)
            XCTAssertEqual(matches.count, 1, """
            DEAD ROW — \(capability.id) declares `\(anchor)` in \(path) and the file's CODE \
            carries it \(matches.count) time(s), not once. A register row that matches nothing \
            is a permission nobody needs; one that matches twice has grown wider than it says.
            """)
        }
    }

    /// A declared caller that no longer calls is the OTHER direction of the same failure, and
    /// it is the one that catches a refactor quietly orphaning a capability again.
    func testEveryDeclaredCallSiteStillCalls() throws {
        let register = try Self.loadRegister()
        let nodes = try Self.nodePaths(register)
        for capability in register.capabilities {
            for site in capability.reachedFrom {
                if site.dynamic != nil { continue }          // graded in the verdict, not here
                guard let path = try Self.sitePath(site, capability: capability, nodes: nodes) else { continue }
                guard let anchor = site.anchor else {
                    return XCTFail("\(capability.id): a call site in \(path) declares no `anchor`")
                }
                let matched = Self.lines(in: path, containing: anchor)
                XCTAssertEqual(matched.count, site.expectedSites, """
                \(capability.id): \(path) declares \(site.expectedSites) call site(s) anchored at \
                `\(anchor)` and carries \(matched.count). Either the caller was renamed or moved \
                (this capability may now be ORPHANED — the whole defect this register exists for) \
                or a second site appeared and nobody recorded it.
                """)
                for line in matched {
                    XCTAssertTrue(line.contains(capability.callPattern), """
                    \(capability.id): the anchored line in \(path) does not contain the call \
                    pattern `\(capability.callPattern)`:
                      \(line.trimmingCharacters(in: .whitespaces))
                    An anchor that is not on a calling line proves the file mentions something, \
                    not that it calls it.
                    """)
                }
            }
        }
    }

    /// A `via` or an `unregistered_production_file` under `Tests/` is not reachability. This is
    /// the structural half of "not satisfiable by a test": it is a NAMED failure, not a row that
    /// quietly passes.
    func testNoDeclaredCallerLivesInATestTarget() throws {
        let register = try Self.loadRegister()
        let nodes = try Self.nodePaths(register)
        for capability in register.capabilities {
            for site in capability.reachedFrom {
                if site.dynamic != nil { continue }
                guard let path = try Self.sitePath(site, capability: capability, nodes: nodes) else { continue }
                let root = path.components(separatedBy: "/").first ?? path
                XCTAssertFalse(register.nonProductionRoots.contains(root), """
                \(capability.id) declares its production caller at \(path), which is under the \
                NON-PRODUCTION root `\(root)`. A caller inside a test target is the exact thing \
                this register exists to refuse: it is how eight green feature files coexisted \
                with a protocol client no shipping code ever called.
                """)
                XCTAssertTrue(register.productionRoots.contains(root), """
                \(capability.id) declares a caller at \(path), which is under no declared \
                production root (\(register.productionRoots.joined(separator: ", "))). \
                Reachability from an unclassified tree is not a fact this register can hold.
                """)
            }
        }
        // And the entry points themselves, which are the axioms everything chains to.
        for entry in register.entryPoints {
            let root = entry.path.components(separatedBy: "/").first ?? entry.path
            XCTAssertTrue(register.productionRoots.contains(root),
                          "entry point \(entry.id) is at \(entry.path), outside every production root")
            let matched = Self.lines(in: entry.path, containing: entry.anchor)
            XCTAssertEqual(matched.count, 1, """
            entry point \(entry.id) anchors on `\(entry.anchor)` in \(entry.path) and the file's \
            CODE carries it \(matched.count) time(s). An entry point is an AXIOM — if it stopped \
            existing, every verdict below it is computed from nothing.
            """)
        }
    }

    // MARK: - The verdicts, recomputed

    private enum Verdict: String {
        case reachable, unreachable, undetermined
    }

    private struct Computed {
        let verdict: Verdict
        let explanation: String
    }

    private static func nodePaths(_ register: Register) throws -> [String: String] {
        var out: [String: String] = [:]
        for entry in register.entryPoints { out[entry.id] = entry.path }
        for capability in register.capabilities {
            if let path = capability.declaredIn { out[capability.id] = path }
        }
        return out
    }

    /// The file a site's call lives in, or `nil` when the site is not a file-shaped one.
    private static func sitePath(_ site: Site, capability: Capability,
                                 nodes: [String: String]) throws -> String? {
        if let path = site.unregisteredProductionFile { return path }
        guard let via = site.via else {
            XCTFail("\(capability.id): a call site names neither `via`, "
                    + "`unregistered_production_file` nor `dynamic`")
            return nil
        }
        guard let path = nodes[via] else {
            XCTFail("""
            \(capability.id) is declared reached from `\(via)`, which is not a registered entry \
            point or capability (or is a capability this checker cannot read). A `via` that \
            resolves to nothing proves nothing — declare it as an \
            `unregistered_production_file` and take the `undetermined` verdict honestly.
            """)
            return nil
        }
        return path
    }

    /// Recompute each capability's verdict from the source text, memoised, cycle-safe.
    ///
    /// CONTAINMENT IS FILE-LEVEL and stated as such in the register: a node is a file, so a call
    /// inside a dead function of a live file still counts as reached from that file. Function
    /// level needs a parser, and a lexer pretending to have one would be a worse lie than a
    /// stated limit.
    private static func computeVerdicts(_ register: Register) throws -> [String: Computed] {
        let nodes = try nodePaths(register)
        let entryIDs = Set(register.entryPoints.map(\.id))
        var byID: [String: Capability] = [:]
        for capability in register.capabilities { byID[capability.id] = capability }

        var memo: [String: Computed] = [:]
        var onStack: [String] = []

        func resolve(_ id: String) -> Computed {
            if entryIDs.contains(id) {
                return Computed(verdict: .reachable, explanation: "entry point")
            }
            if let hit = memo[id] { return hit }
            if onStack.contains(id) {
                let cycle = (onStack + [id]).joined(separator: " -> ")
                return Computed(verdict: .undetermined,
                                explanation: "a cycle in the register (\(cycle)); a cycle proves "
                                           + "nothing about reaching an entry point")
            }
            guard let capability = byID[id] else {
                return Computed(verdict: .undetermined, explanation: "unknown node `\(id)`")
            }
            onStack.append(id)
            defer { onStack.removeLast() }

            if capability.reachedFrom.isEmpty {
                let result = Computed(verdict: .unreachable,
                                      explanation: "no production call site is declared, and none "
                                                 + "was found by the scan")
                memo[id] = result
                return result
            }

            var best = Verdict.unreachable
            var reasons: [String] = []
            for site in capability.reachedFrom {
                if let why = site.dynamic {
                    best = best == .reachable ? .reachable : .undetermined
                    reasons.append("dynamic: \(why)")
                    if let dependency = site.dependsOn {
                        let upstream = resolve(dependency)
                        reasons.append("its named holder `\(dependency)` computes "
                                       + "\(upstream.verdict.rawValue)")
                    }
                    continue
                }
                guard let path = (try? sitePath(site, capability: capability, nodes: nodes)) ?? nil else {
                    best = best == .reachable ? .reachable : .undetermined
                    reasons.append("a call site that resolves to no file")
                    continue
                }
                // The site must still CALL, or it contributes nothing. (The dedicated test
                // above reports this as its own named failure; here it only affects reach.)
                let anchored = site.anchor.map { lines(in: path, containing: $0) } ?? []
                let calls = anchored.contains { $0.contains(capability.callPattern) }
                if !calls {
                    reasons.append("the declared site in \(path) no longer calls "
                                   + "`\(capability.callPattern)`")
                    continue
                }
                if site.unregisteredProductionFile != nil {
                    best = best == .reachable ? .reachable : .undetermined
                    reasons.append("called from \(path), which is production but is not a "
                                   + "registered node — whether IT is reached is unknown"
                                   + (site.whyNotLinked.map { " (\($0))" } ?? ""))
                    continue
                }
                let upstream = resolve(site.via ?? "")
                switch upstream.verdict {
                case .reachable:
                    best = .reachable
                    reasons.append("called from \(path), which is reachable")
                case .undetermined:
                    if best != .reachable { best = .undetermined }
                    reasons.append("called from \(path), whose own reachability is undetermined")
                case .unreachable:
                    reasons.append("called from \(path), which is itself unreachable")
                }
            }
            let result = Computed(verdict: best, explanation: reasons.joined(separator: "; "))
            memo[id] = result
            return result
        }

        var out: [String: Computed] = [:]
        for capability in register.capabilities { out[capability.id] = resolve(capability.id) }
        return out
    }

    /// THE GATE. Computed verdict must EQUAL the declared one, per capability, both directions.
    func testEveryCapabilityComputesTheVerdictItDeclares() throws {
        let register = try Self.loadRegister()
        let computed = try Self.computeVerdicts(register)

        for capability in register.capabilities {
            guard let result = computed[capability.id] else {
                return XCTFail("\(capability.id) produced no verdict")
            }
            // A cross-repository row has no local call graph; its declared verdict is checked
            // in `testEveryDeclaredCapabilityStillExists` and its local absence below.
            if capability.declaredIn == nil { continue }
            XCTAssertEqual(result.verdict.rawValue, capability.verdict, """
            \(capability.id) — "\(capability.name)"
              declared: \(capability.verdict)
              computed: \(result.verdict.rawValue)
              because:  \(result.explanation)
            \(Self.adviceFor(declared: capability.verdict, computed: result.verdict))
            """)
        }
    }

    private static func adviceFor(declared: String, computed: Verdict) -> String {
        switch (declared, computed) {
        case ("reachable", .unreachable):
            return "THE CAPABILITY IS NOW ORPHANED. Something renamed, moved or deleted its only "
                 + "production caller, and every scenario that drives it through an injected fake "
                 + "is still green. Restore the caller, or change this row to `unreachable` and "
                 + "say so out loud."
        case ("reachable", .undetermined):
            return "The chain to an entry point is broken somewhere the register cannot see. This "
                 + "is NOT a claim that nothing calls it — register the missing link, or record "
                 + "the site as an `unregistered_production_file` with a reason."
        case ("unreachable", .reachable):
            return "GOOD NEWS THE REGISTER HAS NOT ABSORBED. Somebody wired this up. Promote the "
                 + "row to `reachable`, cite the caller, and move it out of the red roster."
        case ("unreachable", .undetermined):
            return "The row claims nothing reaches it, but the checker found something it could "
                 + "not follow. Say which."
        case ("undetermined", .reachable):
            return "The question has been answered. Promote the row and delete the excuse."
        case ("undetermined", .unreachable):
            return "The checker can now see that nothing reaches this. Demote the row to "
                 + "`unreachable` — an honest red beats a standing question."
        default:
            return ""
        }
    }

    /// The counts, as EQUALITY. A bound would let the unreachable roster grow by one without
    /// anybody moving the register, which is exactly how four capabilities reached `main`
    /// unreached. This is also the test that prints the roster out loud.
    func testTheVerdictRosterIsExactlyWhatTheRegisterDeclares() throws {
        let register = try Self.loadRegister()
        let computed = try Self.computeVerdicts(register)

        var tally: [String: Int] = ["reachable": 0, "unreachable": 0, "undetermined": 0]
        for capability in register.capabilities { tally[capability.verdict, default: 0] += 1 }

        for (verdict, declared) in register.verdictCounts.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(tally[verdict] ?? 0, declared, """
            the register declares \(declared) `\(verdict)` capabilit(ies) and its rows carry \
            \(tally[verdict] ?? 0). Counts here are EQUALITY, never a bound: a roster that can \
            grow by one without a diff is how this defect class shipped four times in a day.
            """)
        }
        XCTAssertEqual(Set(tally.keys), Set(register.verdictCounts.keys),
                       "a verdict was used that the counts block does not declare")

        // THE HONEST RED, SAID OUT LOUD. These are shipped capabilities that no production code
        // reaches, and shipped questions nobody has answered. They are recorded rather than
        // omitted, and this print is what makes them impossible to forget.
        let red = register.capabilities.filter { $0.verdict != "reachable" }
        print("REACHABILITY: \(tally["reachable"] ?? 0) reachable, "
              + "\(tally["unreachable"] ?? 0) UNREACHABLE, "
              + "\(tally["undetermined"] ?? 0) UNDETERMINED")
        for capability in red {
            let detail = computed[capability.id]?.explanation ?? ""
            print("REACHABILITY: \(capability.verdict.uppercased()) — \(capability.id): "
                  + "\(capability.name)\n              \(detail)")
        }
    }

    // MARK: - The scan, which is what makes a row unable to lie

    /// A capability declared UNREACHABLE that acquires a production caller must move the
    /// register. Without this the red roster is a comment: rows would sit there claiming a
    /// capability is dead long after somebody wired it up, and the gate would never notice.
    ///
    /// The declaring file itself is excluded — internal recursion is not external reach — and
    /// that exclusion is the one stated hole in this scan.
    func testNothingDeclaredUnreachableHasQuietlyAcquiredAProductionCaller() throws {
        let register = try Self.loadRegister()
        for capability in register.capabilities where capability.verdict == "unreachable" {
            let found = Self.filesUnder(register.productionRoots,
                                        whoseCodeContains: capability.callPattern)
                .filter { $0 != capability.declaredIn }
            XCTAssertEqual(found, [], """
            \(capability.id) is declared UNREACHABLE and \(found.count) production file(s) now \
            contain `\(capability.callPattern)`:
            \(found.map { "  " + $0 }.joined(separator: "\n"))
            Somebody wired it up. Promote the row to `reachable`, cite the caller, and move the \
            verdict counts. (If the match is not really a call, sharpen `call_pattern` — but say \
            why in the row.)
            """)
        }
    }

    /// The witness half: where a row declares `tested_from`, it is compared for EQUALITY against
    /// a scan of the non-production roots. That is what turns "green tests prove nothing" into a
    /// number — five test files driving a lifecycle no production file drives is a fact, not a
    /// complaint — and it goes red when a test is added or deleted without a look at this row.
    func testTheTestWitnessesAreExactlyWhatEachRowDeclares() throws {
        let register = try Self.loadRegister()
        for capability in register.capabilities {
            guard let declared = capability.testedFrom else { continue }
            let found = Self.filesUnder(register.nonProductionRoots,
                                        whoseCodeContains: capability.callPattern)
            XCTAssertEqual(found, declared.sorted(), """
            \(capability.id) declares \(declared.count) test witness(es) and the scan found \
            \(found.count):
              declared: \(declared.sorted())
              found:    \(found)
            `tested_from` is the measured contrast this register exists to publish — the tests \
            that DO drive a capability nothing production reaches. It is equality on purpose.
            """)
            if capability.verdict == "unreachable" {
                print("REACHABILITY: \(capability.id) — \(found.count) test file(s) drive it, "
                      + "0 production files reach it")
            }
        }
    }

    /// A row that says the callee lives somewhere this checker cannot read has exactly one
    /// locally measurable fact, and this is it. The day the pattern appears in this repository,
    /// the row must be given a real verdict instead of an excuse.
    func testCrossRepositoryRowsAreStillAbsentFromThisRepository() throws {
        let register = try Self.loadRegister()
        for capability in register.capabilities where capability.absentLocally == true {
            let everywhere = Self.filesUnder(register.productionRoots + register.nonProductionRoots,
                                             whoseCodeContains: capability.callPattern)
            XCTAssertEqual(everywhere, [], """
            \(capability.id) declares `absent_locally` — the callee is in another repository and \
            nothing here mentions `\(capability.callPattern)`. It now appears in:
            \(everywhere.map { "  " + $0 }.joined(separator: "\n"))
            That is a real local fact and the row must state a real verdict rather than \
            `undetermined`.
            """)
            XCTAssertEqual(capability.verdict, "undetermined",
                "\(capability.id) is unreadable from here; `undetermined` is the only honest "
                    + "verdict, and it declares `\(capability.verdict)`")
        }
    }
}
