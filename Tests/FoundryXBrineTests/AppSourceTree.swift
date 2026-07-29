import Foundation

/// READING THE APP TARGET'S SOURCE, HONESTLY.
///
/// `swift test` compiles the SPM package only — it cannot see `App/`, `Widget/` or
/// `UITests/` at all. Several gates in this suite therefore hold App-side facts by reading
/// the files, and two of them (`RecordingSurfaceRenderingLedgerTests`,
/// `DeviceCompositionRootGateTests`) had grown their own private, subtly-wrong versions of
/// the same walk. Review round 12 (L12-1) named both defects:
///
///   * the walk was `contentsOfDirectory` on `App/` alone — NOT recursive, and blind to
///     `Widget/` and `UITests/`, while the finding it answered had counted references across
///     all three. A rendering wired from `Widget/`, or from a future `App/` subdirectory,
///     would not have moved the ledger;
///   * comment stripping removed only lines whose TRIMMED text began with `//`, so a
///     trailing comment or a `/* … */` block naming a type counted as a rendering — prose
///     satisfying a gate about code.
///
/// This is that walk, in one place, with the string/comment states a Swift file actually
/// has. Its stated limits: it is a lexer, not a parser (it knows nothing of `#if`, so code
/// behind a false `#if` still counts as a reference), and a raw string's contents are
/// treated as string contents — which is the safe direction, since a type named inside a
/// string literal is not a rendering either.
enum AppSourceTree {

    /// The repo root, from this file's own path (`Tests/FoundryXBrineTests/…`).
    static var repoRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    /// Every directory holding source the App target ships or proves itself with. The
    /// ledger's two directions and the composition-root bans all apply across all of it.
    static let appSideDirectories = ["App", "Widget", "UITests"]

    /// Every `.swift` file under `appSideDirectories`, RECURSIVELY, as repo-relative paths.
    static func appSideSwiftFiles() throws -> [URL] {
        var files: [URL] = []
        for directory in appSideDirectories {
            let base = repoRoot.appendingPathComponent(directory, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let walk = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// A repo-relative path, for a failure message that can be acted on.
    static func relativePath(_ url: URL) -> String {
        let root = repoRoot.path.hasSuffix("/") ? repoRoot.path : repoRoot.path + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
    }

    /// The file with every COMMENT removed and string literals left intact.
    ///
    /// Use this for checks about identifiers the app actually writes — accessibility ids,
    /// call spellings — where a string literal IS the thing being held.
    static func withoutComments(of text: String) -> String {
        scan(text, blankingStrings: false)
    }

    /// The file's CODE: every comment removed AND every string literal blanked.
    ///
    /// Comments are removed because prose names types constantly and a mention in prose is
    /// not a rendering. String literals are blanked for the same reason and with the same
    /// direction of error: a type name inside a string — a UI-proof identifier, a log line —
    /// is not a use of the type.
    static func code(of text: String) -> String {
        scan(text, blankingStrings: true)
    }

    private static func scan(_ text: String, blankingStrings: Bool) -> String {
        enum State { case code, lineComment, blockComment, string, multilineString }
        var state = State.code
        var blockDepth = 0
        var out = String()
        out.reserveCapacity(text.count)
        let chars = Array(text)
        var i = 0
        func peek(_ offset: Int) -> Character? {
            let j = i + offset
            return j < chars.count ? chars[j] : nil
        }
        while i < chars.count {
            let c = chars[i]
            switch state {
            case .code:
                if c == "/", peek(1) == "/" {
                    state = .lineComment
                    i += 2
                } else if c == "/", peek(1) == "*" {
                    state = .blockComment
                    blockDepth = 1
                    i += 2
                } else if c == "\"", peek(1) == "\"", peek(2) == "\"" {
                    state = .multilineString
                    if !blankingStrings { out.append("\"\"\"") }
                    i += 3
                } else if c == "\"" {
                    state = .string
                    if !blankingStrings { out.append(c) }
                    i += 1
                } else {
                    out.append(c)
                    i += 1
                }
            case .lineComment:
                if c == "\n" {
                    out.append(c)
                    state = .code
                }
                i += 1
            case .blockComment:
                // Swift block comments NEST.
                if c == "/", peek(1) == "*" {
                    blockDepth += 1
                    i += 2
                } else if c == "*", peek(1) == "/" {
                    blockDepth -= 1
                    i += 2
                    if blockDepth == 0 { state = .code }
                } else {
                    if c == "\n" { out.append(c) }
                    i += 1
                }
            case .string:
                if c == "\\" {
                    if !blankingStrings, let next = peek(1) {
                        out.append(c)
                        out.append(next)
                    }
                    i += 2                      // an escape, including \" and \(…)
                } else if c == "\"" || c == "\n" {
                    // A newline inside a single-line string means the literal was never
                    // closed on this line (an interpolation we skipped, say) — recover at
                    // the line break rather than swallowing the rest of the file.
                    if c == "\n" || !blankingStrings { out.append(c) }
                    state = .code
                    i += 1
                } else {
                    if !blankingStrings { out.append(c) }
                    i += 1
                }
            case .multilineString:
                if c == "\\" {
                    if !blankingStrings, let next = peek(1) {
                        out.append(c)
                        out.append(next)
                    }
                    i += 2
                } else if c == "\"", peek(1) == "\"", peek(2) == "\"" {
                    if !blankingStrings { out.append("\"\"\"") }
                    state = .code
                    i += 3
                } else {
                    if c == "\n" || !blankingStrings { out.append(c) }
                    i += 1
                }
            }
        }
        return out
    }

    /// The App-side files whose CODE mentions `type` as a whole word.
    static func filesReferencing(_ type: String) throws -> [String] {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: type))\\b"
        return try filesMatching(pattern)
    }

    /// The App-side files whose CODE contains `needle` literally.
    static func filesContaining(_ needle: String) throws -> [String] {
        try filesMatching(NSRegularExpression.escapedPattern(for: needle))
    }

    private static func filesMatching(_ pattern: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        var hits: [String] = []
        for file in try appSideSwiftFiles() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let stripped = code(of: text)
            let ns = stripped as NSString
            if regex.firstMatch(in: stripped, range: NSRange(location: 0, length: ns.length)) != nil {
                hits.append(relativePath(file))
            }
        }
        return hits.sorted()
    }
}
