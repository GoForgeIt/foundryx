import Foundation

/// **P2 and P3** (`spec.md` §5.2, §5.3) — the two predicates that read the shipped
/// property list rather than the wire.
///
/// ## Which plist, and why this one
///
/// §5.2 says to read *"the **built app bundle's** `Info.plist` (not `project.yml`: the
/// plist is what ships and what iOS enforces; `App/Info.plist` is checked-in generated
/// output)"*. `App/Info.plist` is that generated output, committed. It is what these
/// predicates read, and the drift leg the same section demands — *"Separately assert
/// that `project.yml` and the built plist agree"* — is what keeps that safe: if the
/// generated artifact ever stops matching its source, P2 says so instead of quietly
/// reading a stale file.
///
/// **Named rather than folded in:** reading the plist out of a fully linked `.app`
/// produced by `xcodebuild` is NOT done here. That is A7's and A8's obligation, and
/// both are **DEFER** in this track's `criteria-disposition.md`. A9 asserts the three
/// predicates execute and are RED; it does not re-own A7's enumeration contract.
enum BundlePredicates {

    /// The repository root, found from this file rather than from a working directory,
    /// which is the same `#filePath`-relative mechanism the feature files use.
    static func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // FoundryXConformanceTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    static func shippedPlistURL() -> URL {
        repoRoot().appendingPathComponent("App/Info.plist")
    }

    private static func loadPlist() throws -> [String: Any] {
        let url = shippedPlistURL()
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw BundlePredicateError.io("the shipped plist is not readable at \(url.path)")
        }
        guard let obj = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw BundlePredicateError.io("the shipped plist at \(url.path) is not a dictionary")
        }
        return obj
    }

    /// A scheme-bearing string value, e.g. `ws://…`. Anything without `://` is not a URL.
    private static func scheme(of value: Any) -> String? {
        guard let s = value as? String, let r = s.range(of: "://") else { return nil }
        let sch = String(s[s.startIndex..<r.lowerBound])
        return sch.isEmpty ? nil : sch.lowercased()
    }

    // MARK: - P2 — plaintext gateway URL

    /// **P2.** Enumerate EVERY URL-valued key under the endpoint dictionaries and assert
    /// each scheme is TLS.
    ///
    /// The trap §5.2 names: *"A predicate that inspects `GatewayHTTPURL` — the key whose
    /// name matches the fix's name — **returns GREEN at the baseline**. It would report
    /// the fix closed while the plaintext leg it was written to catch survives one key
    /// away."* So this enumerates rather than looks up, and reports the count and names
    /// of what it inspected, which is what makes the one-key form detectable.
    static func p2() -> PredicateOutcome {
        var lines: [String] = []
        let plist: [String: Any]
        do { plist = try loadPlist() } catch {
            return PredicateOutcome(name: "P2", title: "plaintext gateway URL", status: .refused,
                                    casesExecuted: 0, output: "REFUSED: \(error)")
        }
        guard let endpoints = plist["FoundryXOAuth"] as? [String: Any] else {
            return PredicateOutcome(name: "P2", title: "plaintext gateway URL", status: .refused,
                                    casesExecuted: 0,
                                    output: "REFUSED: the endpoint dictionary `FoundryXOAuth` is absent from the shipped plist; a predicate that inspected nothing must not report a status")
        }

        var inspected: [(String, String, String)] = []   // key, scheme, value
        for key in endpoints.keys.sorted() {
            guard let sch = scheme(of: endpoints[key]!) else { continue }
            inspected.append((key, sch, endpoints[key] as? String ?? ""))
        }
        // A predicate that inspected nothing is a bug, not a pass.
        guard !inspected.isEmpty else {
            return PredicateOutcome(name: "P2", title: "plaintext gateway URL", status: .refused,
                                    casesExecuted: 0,
                                    output: "REFUSED: no URL-valued key was found under `FoundryXOAuth`. Zero inspected is a predicate bug, not a clean bill of health.")
        }

        let tls: Set<String> = ["https", "wss"]
        let plaintext = inspected.filter { !tls.contains($0.1) }
        lines.append("keys inspected: \(inspected.count) — \(inspected.map { "\($0.0)=\($0.1)://" }.joined(separator: ", "))")

        // The drift leg: source and shipped artifact must agree.
        let driftNote: String
        do {
            let yml = try String(contentsOf: repoRoot().appendingPathComponent("project.yml"), encoding: .utf8)
            var disagreeing: [String] = []
            for (key, _, value) in inspected where !value.isEmpty {
                if !yml.contains(value) { disagreeing.append("\(key) (shipped \(value) appears nowhere in project.yml)") }
            }
            driftNote = disagreeing.isEmpty
                ? "project.yml and the shipped plist agree on every inspected key"
                : "DRIFT between project.yml and the shipped plist: \(disagreeing.joined(separator: "; "))"
        } catch {
            driftNote = "the source/artifact agreement leg could not be read: \(error)"
        }
        lines.append(driftNote)

        if plaintext.isEmpty {
            lines.append("every inspected endpoint is TLS — P2 CLOSED")
            return PredicateOutcome(name: "P2", title: "plaintext gateway URL", status: .closed,
                                    casesExecuted: inspected.count, output: lines.joined(separator: "\n"))
        }
        lines.append("PLAINTEXT endpoints still shipping: \(plaintext.map { "\($0.0)=\($0.2)" }.joined(separator: ", ")) — P2 OPEN")
        return PredicateOutcome(name: "P2", title: "plaintext gateway URL", status: .open,
                                casesExecuted: inspected.count, output: lines.joined(separator: "\n"))
    }

    // MARK: - P3 — disabled ATS

    /// **P3.** Read the full `NSAppTransportSecurity` dictionary.
    ///
    /// The trap §5.3 names: *"A predicate that greps for `NSAllowsArbitraryLoads`
    /// **returns GREEN at the baseline today** and would report this fix closed — while
    /// the plaintext relay leg P2 catches is precisely what the surviving exception
    /// domain exists to permit. Unfailable. Forbidden."* So the arbitrary-loads key is
    /// only ONE conjunct here; the exception domains are enumerated and their flags read.
    static func p3() -> PredicateOutcome {
        var lines: [String] = []
        let plist: [String: Any]
        do { plist = try loadPlist() } catch {
            return PredicateOutcome(name: "P3", title: "disabled ATS", status: .refused,
                                    casesExecuted: 0, output: "REFUSED: \(error)")
        }
        guard let ats = plist["NSAppTransportSecurity"] as? [String: Any] else {
            return PredicateOutcome(name: "P3", title: "disabled ATS", status: .refused,
                                    casesExecuted: 0,
                                    output: "REFUSED: `NSAppTransportSecurity` is absent from the shipped plist, so this predicate read nothing and must not report a status in either direction")
        }

        var findings: [String] = []
        let arbitrary = (ats["NSAllowsArbitraryLoads"] as? Bool) ?? false
        lines.append("NSAllowsArbitraryLoads: \(ats["NSAllowsArbitraryLoads"] == nil ? "absent" : String(describing: ats["NSAllowsArbitraryLoads"]!))")
        if arbitrary { findings.append("NSAllowsArbitraryLoads is true") }

        let domains = (ats["NSExceptionDomains"] as? [String: Any]) ?? [:]
        lines.append("exception domains found: \(domains.count) — \(domains.keys.sorted().joined(separator: ", "))")
        let lowering = ["NSExceptionAllowsInsecureHTTPLoads",
                        "NSExceptionAllowsInsecureHTTPSLoads",
                        "NSThirdPartyExceptionAllowsInsecureHTTPLoads"]
        for name in domains.keys.sorted() {
            let d = (domains[name] as? [String: Any]) ?? [:]
            let flags = d.keys.sorted().map { "\($0)=\(String(describing: d[$0]!))" }.joined(separator: " ")
            lines.append("  \(name): \(flags)")
            for key in lowering where (d[key] as? Bool) == true {
                findings.append("\(name) carries \(key)=true")
            }
            if let minTLS = d["NSExceptionMinimumTLSVersion"] as? String, minTLS != "TLSv1.2", minTLS != "TLSv1.3" {
                findings.append("\(name) lowers the minimum TLS version to \(minTLS)")
            }
        }

        if findings.isEmpty {
            lines.append("no arbitrary-loads key and no exception domain permits an insecure load — P3 CLOSED")
            return PredicateOutcome(name: "P3", title: "disabled ATS", status: .closed,
                                    casesExecuted: domains.count + 1, output: lines.joined(separator: "\n"))
        }
        lines.append("ATS is still lowered: \(findings.joined(separator: "; ")) — P3 OPEN")
        return PredicateOutcome(name: "P3", title: "disabled ATS", status: .open,
                                casesExecuted: domains.count + 1, output: lines.joined(separator: "\n"))
    }
}

enum BundlePredicateError: Error, CustomStringConvertible {
    case io(String)
    var description: String { if case .io(let m) = self { return m }; return "bundle predicate error" }
}
