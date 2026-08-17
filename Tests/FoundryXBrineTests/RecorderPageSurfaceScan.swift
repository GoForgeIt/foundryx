import Foundation

/// READING THE RECORDER PAGE'S OWN SOURCE — the only way this suite can reach it.
///
/// `swift test` compiles the SPM package. It cannot compile `App/`, so the page a person
/// opens to look at what their recorder is holding is invisible to every behavioural test
/// in this repository. Two rules that the whole Pocket surface is built on are therefore
/// unheld:
///
///   * every sentence a person reads comes from a kit presentation type, never from a
///     SwiftUI body — because a sentence typed into a body is a second, unasserted
///     implementation of the app's voice, and Brine cannot see it;
///   * every colour comes from a Grain token, never from a `Color(…)` mixed on the spot.
///
/// Both were being kept by hand. `RecordingDevicePageView` had already broken the first one
/// twice — `Text("Use this device for capture")` and `Button("Cancel", …)` — and nothing in
/// 1428 tests could say so.
///
/// ## Why this is a lexer over the DECLARATION rather than a grep over the file
///
/// `App/DeviceScreen.swift` is 1900 lines and holds four view types and two models. A grep
/// for `Text("` over the file cannot tell the recorder page from the device list, so it
/// would either fail on somebody else's screen or pass on this one. This extracts the
/// balanced-brace body of a NAMED type and rules only over that.
///
/// ## Stated limits
///
/// It is a lexer, not a parser. It knows nothing of `#if`, so a body behind a false `#if`
/// is still scanned — the safe direction, since a line invented behind a compile flag is
/// still a line invented. String interpolation is treated as literal content, which is also
/// the safe direction: `Text("Hello \(name)")` is a sentence written into the body whether
/// or not the interpolation is code.
enum RecorderPageSurface {

    // MARK: - The population

    /// The file the recorder page is written in.
    static let pageFile = "App/DeviceScreen.swift"

    /// The file that mounts the page's states for the build's pictures.
    static let proofFile = "App/RecorderPageProof.swift"

    /// The test that takes those pictures.
    static let proofTestFile = "UITests/RecorderPageProofUITests.swift"

    /// The script that tells the build to take them.
    static let gatesScript = "scripts/ci-gates.sh"

    /// EVERY VIEW TYPE THAT IS THE RECORDER PAGE, with the file it lives in. The proof view
    /// is in the population deliberately: a sentence invented there would appear in the
    /// build's picture of the page and would be read as the page's own.
    static let renderedTypes: [(type: String, file: String)] = [
        ("RecordingDevicePageView", pageFile),
        ("RecorderPageProof", proofFile),
    ]

    /// The kit presentation types the page is allowed to take its words from. Existence is
    /// asserted over this list, so "no sentence is written into the page" cannot pass on a
    /// page that says nothing at all.
    static let presentationTypes = [
        "RecordingDevicePage",
        "RecordingDeviceConnectPresentation",
        "RecordingDeviceAttachPresentation",
        "PocketRecorderCheckPresentation",
        "PocketBringOverPresentation",
        "PocketKeyCustodyPresentation",
        "PocketRecorderCustodyPromise",
        "DeviceMetricsPresentation",
    ]

    // MARK: - Reading a file

    static func text(of relativePath: String) throws -> String {
        let url = AppSourceTree.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: AppSourceTree.repoRoot.appendingPathComponent(relativePath).path)
    }

    // MARK: - One type's declaration

    /// The balanced-brace body of `type`'s declaration, COMMENTS REMOVED and string
    /// literals INTACT. `nil` when the file holds no such declaration — which is itself a
    /// failure at every call site, never a quiet skip.
    static func declarationBody(of type: String, in fileText: String) -> String? {
        let source = AppSourceTree.withoutComments(of: fileText)
        let chars = Array(source)
        guard let start = declarationStart(of: type, in: source) else { return nil }

        // Find the opening brace of the declaration, then balance — ignoring braces that
        // live inside a string literal.
        var i = start
        while i < chars.count, chars[i] != "{" { i += 1 }
        guard i < chars.count else { return nil }

        var depth = 0
        var body = String()
        var inString = false
        var inMultiline = false
        while i < chars.count {
            let c = chars[i]
            if inMultiline {
                if c == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                    inMultiline = false
                    body.append("\"\"\"")
                    i += 3
                    continue
                }
            } else if inString {
                if c == "\\" {
                    body.append(c)
                    if i + 1 < chars.count { body.append(chars[i + 1]) }
                    i += 2
                    continue
                }
                if c == "\"" || c == "\n" { inString = false }
            } else if c == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                inMultiline = true
                body.append("\"\"\"")
                i += 3
                continue
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    body.append(c)
                    return body
                }
            }
            body.append(c)
            i += 1
        }
        return nil
    }

    private static func declarationStart(of type: String, in source: String) -> Int? {
        let pattern = "\\b(?:struct|class|enum|extension)\\s+"
            + NSRegularExpression.escapedPattern(for: type) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = source as NSString
        guard let m = regex.firstMatch(in: source,
                                       range: NSRange(location: 0, length: ns.length))
        else { return nil }
        // NSString UTF-16 offsets and the Character array agree for this source, which is
        // plain ASCII apart from prose in comments — and comments are already gone.
        return Array(source.prefix(m.range.location)).count
    }

    // MARK: - The sentences a body writes

    /// One string literal found in a declaration body, with the code immediately before it.
    struct Literal {
        let value: String
        /// Up to 80 characters of code immediately preceding the opening quote, with
        /// whitespace collapsed — enough to name the argument position.
        let preceding: String
    }

    /// The argument positions where a string literal is NOT a sentence a person reads.
    /// Every one of these is an identifier the machine consumes, never rendered.
    private static let nonUserFacingOpeners = [
        "accessibilityIdentifier(",
        "systemName:",
        "forKey:",
        "identifier:",
    ]

    static func stringLiterals(in body: String) -> [Literal] {
        var out: [Literal] = []
        let chars = Array(body)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\"" else { i += 1; continue }
            let openedAt = i
            var value = String()
            if i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                i += 3
                while i < chars.count {
                    if chars[i] == "\"", i + 2 < chars.count,
                       chars[i + 1] == "\"", chars[i + 2] == "\"" {
                        i += 3
                        break
                    }
                    value.append(chars[i])
                    i += 1
                }
            } else {
                i += 1
                while i < chars.count {
                    if chars[i] == "\\" {
                        value.append(chars[i])
                        if i + 1 < chars.count { value.append(chars[i + 1]) }
                        i += 2
                        continue
                    }
                    if chars[i] == "\"" || chars[i] == "\n" { i += 1; break }
                    value.append(chars[i])
                    i += 1
                }
            }
            let from = max(0, openedAt - 80)
            let preceding = String(chars[from..<openedAt])
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .joined(separator: " ")
            out.append(Literal(value: value, preceding: preceding))
        }
        return out
    }

    /// A literal is a SENTENCE A PERSON READS unless it is empty or sits in one of the
    /// machine-consumed argument positions above.
    static func isUserFacing(_ literal: Literal) -> Bool {
        if literal.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        let trailing = literal.preceding.replacingOccurrences(of: " ", with: "")
        for opener in nonUserFacingOpeners
        where trailing.hasSuffix(opener.replacingOccurrences(of: " ", with: "")) {
            return false
        }
        return true
    }

    // MARK: - The colours a body mixes

    /// Every place a body names `Color` itself — `Color(…)` mixed on the spot, or
    /// `Color.red` taken from the system. `GrainColor.ink` is NOT a match: the word
    /// boundary before `Color` does not fall inside `GrainColor`.
    static func mixedColours(in body: String) -> [String] {
        let code = AppSourceTree.code(of: body)
        guard let regex = try? NSRegularExpression(pattern: "\\bColor\\s*[(.]") else { return [] }
        let ns = code as NSString
        return regex.matches(in: code, range: NSRange(location: 0, length: ns.length)).map {
            // The name plus a little context, so the failure can be acted on.
            let start = max(0, $0.range.location - 30)
            let length = min(ns.length - start, $0.range.length + 40)
            return ns.substring(with: NSRange(location: start, length: length))
                .replacingOccurrences(of: "\n", with: " ")
        }
    }

    /// Every Grain token a body paints. The EXISTENCE half of the colour rule.
    static func grainTokens(in body: String) -> [String] {
        matches(of: "\\bGrain(?:Color|Spacing|Radius|Shadow)\\s*\\.\\s*[A-Za-z0-9_]+", in: body)
    }

    /// Every kit presentation value a body renders. The EXISTENCE half of the words rule.
    static func presentationReferences(in body: String) -> [String] {
        let alternatives = presentationTypes
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return matches(of: "\\b(?:\(alternatives))\\s*\\.\\s*[A-Za-z0-9_]+", in: body)
    }

    private static func matches(of pattern: String, in body: String) -> [String] {
        let code = AppSourceTree.code(of: body)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = code as NSString
        return regex.matches(in: code, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// A shell function's balanced-brace body. `ci-gates.sh` is not Swift, so the Swift
    /// declaration reader above does not find `phase_uiproof() {` — and ruling over the whole
    /// file would let a mention in a comment, or in a different phase entirely, satisfy the
    /// wiring assertion.
    static func shellFunctionBody(_ name: String, in script: String) -> String? {
        guard let start = script.range(of: "\(name)() {") else { return nil }
        var depth = 0
        var body = String()
        for c in script[start.lowerBound...] {
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { return body }
            }
            body.append(c)
        }
        return nil
    }

    // MARK: - The states, derived from the enum rather than listed here

    /// Every state the UI proof actually opens, read out of its own `open("…")` calls.
    ///
    /// THIS IS THE OTHER HALF OF THE POPULATION, AND WITHOUT IT THE GATE IS VACUOUS. Deriving
    /// the states from the enum and then checking the proof against them holds one direction
    /// only: deleting a case deletes its own expectation, so a state can be dropped and the
    /// suite stays green — measured, not assumed (the first version of this gate passed with
    /// `errandRunning` removed). Pinning the two sets EQUAL means neither file can shrink
    /// alone: drop a case and the proof photographs a state the page cannot be in; drop a
    /// visit and a state ships unseen.
    static func statesTheProofOpens() throws -> [String] {
        guard exists(proofTestFile) else { return [] }
        // Comments stripped, string literals INTACT — the state name IS a string literal, so
        // the code-only reader (which blanks them) would find every call and no name.
        let source = AppSourceTree.withoutComments(of: try text(of: proofTestFile))
        guard let regex = try? NSRegularExpression(pattern: "open\\(\"([A-Za-z0-9_]+)\"\\)")
        else { return [] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// The cases of `RecorderPageProofState`, in declaration order.
    ///
    /// DERIVED, NEVER LISTED. A list of state names kept in this file would move with the
    /// mutation it is supposed to catch: deleting a state and deleting its expectation would
    /// be the same edit. The enum is the population; everything else is checked against it.
    static func proofStates() throws -> [String] {
        guard exists(proofFile) else { return [] }
        let body = declarationBody(of: "RecorderPageProofState",
                                   in: try text(of: proofFile)) ?? ""
        return matches(of: "\\bcase\\s+[a-zA-Z0-9_]+", in: body)
            .map { $0.replacingOccurrences(of: "case", with: "")
                     .trimmingCharacters(in: .whitespaces) }
    }
}
