import Foundation

/// READING `scripts/ci-gates.sh` AS A SHELL SCRIPT, NOT AS A BAG OF LINES.
///
/// WHY THIS EXISTS (review round 13, M13-1). `RecordingSurfaceRenderingLedgerTests` held
/// *"the pipeline actually runs the rendered-attribution proof"* with a `contains` over the
/// WHOLE FILE. That asks whether the string is somewhere in the script — not whether it is on
/// the command the script executes. And the most likely way an `-only-testing:` case dies is
/// not deletion, it is being commented out with a note:
///
/// ```sh
///   # temporarily disabled while the simulator is flaky — re-enable
///   # -only-testing:FoundryXUITests/RecordingDeviceProofUITests/testTheRecorder…
///   if xcodebuild test -project FoundryX.xcodeproj …
/// ```
///
/// The proof then never runs and every gate stays green (MUT-R13-P2, SURVIVED). Deleting the
/// line reds; disabling it did not. So the gate now reads the script the way the shell does:
/// comments removed, and scoped to the body of the one function that runs the proof.
///
/// STATED LIMITS. This is a lexer, not a shell parser. It knows single quotes, double quotes
/// and backslash escapes, and it treats `#` as a comment opener only where the shell does —
/// at the start of a line or after whitespace, outside quotes (so `${#items[@]}` and `$#`
/// survive). It knows nothing of heredocs (`<<EOF`), which `ci-gates.sh` does not use; a
/// commented line INSIDE a heredoc would be stripped, which errs toward a smaller executed
/// set and therefore toward a RED gate. `functionBody` follows this file's own convention —
/// `name() {` on its own line, closing `}` in column 0 — and returns `nil` rather than
/// guessing when it cannot find both, so a rename is a loud failure rather than a vacuous
/// pass.
enum ShellSource {

    /// The script with every `#` comment removed, newlines and quoted `#`s preserved.
    static func withoutComments(of script: String) -> String {
        enum State { case code, singleQuote, doubleQuote, comment }
        var state = State.code
        var out = String()
        out.reserveCapacity(script.count)
        let chars = Array(script)
        var i = 0
        var previous: Character? = nil          // the last character of the SOURCE, comments included
        while i < chars.count {
            let c = chars[i]
            switch state {
            case .code:
                if c == "#", previous == nil || previous == "\n" || previous == " " || previous == "\t" {
                    state = .comment
                } else if c == "'" {
                    state = .singleQuote
                    out.append(c)
                } else if c == "\"" {
                    state = .doubleQuote
                    out.append(c)
                } else if c == "\\", i + 1 < chars.count {
                    out.append(c)
                    out.append(chars[i + 1])
                    previous = chars[i + 1]
                    i += 2
                    continue
                } else {
                    out.append(c)
                }
            case .singleQuote:
                // No escapes inside single quotes — the literal ends at the next `'`.
                out.append(c)
                if c == "'" { state = .code }
            case .doubleQuote:
                out.append(c)
                if c == "\\", i + 1 < chars.count {
                    out.append(chars[i + 1])
                    previous = chars[i + 1]
                    i += 2
                    continue
                }
                if c == "\"" { state = .code }
            case .comment:
                if c == "\n" {
                    out.append(c)
                    state = .code
                }
            }
            previous = c
            i += 1
        }
        return out
    }

    /// The body of `name() { … }`, or `nil` when the function or its closing brace is absent.
    static func functionBody(_ name: String, in script: String) -> String? {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let opener = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(name)() {")
        }) else { return nil }
        guard let closer = lines[(opener + 1)...].firstIndex(where: { $0 == "}" }) else { return nil }
        return lines[(opener + 1)..<closer].joined(separator: "\n")
    }

    /// Every `-only-testing:` argument in the given text, as the identifiers `xcodebuild`
    /// would receive. Run this over a function body that has had its comments removed and
    /// what comes back is the set of cases that function actually executes.
    static func onlyTestingArguments(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"-only-testing:([^\s\\]+)"#) else {
            return []
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return Set(matches.map { ns.substring(with: $0.range(at: 1)) })
    }
}
