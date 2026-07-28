import Foundation

/// A source-level guard for the app's user-facing voice-note vocabulary.
///
/// This intentionally scans source instead of runtime views because SwiftPM does not compile
/// `App/`. The scanner is conservative: a string is treated as user-facing unless it is in a
/// specifically excluded source context or is one of the narrow, explained conversation uses
/// below.
public enum VoiceNotesLanguage {
    private struct Literal {
        let value: String
        let line: String
        /// A `"""` block rather than a plain quoted string.
        let isMultiline: Bool
    }

    /// Deliberate multi-person uses. Each anchor is narrow enough that an unrelated library
    /// label cannot slip through merely because it contains the word "conversation".
    private static let allowedConversationAnchors: [(anchor: String, reason: String)] = [
        // Speaker recognition describes identifying a person when they speak with the owner.
        ("this voice will be recognized in future conversations",
         "speaker recognition is genuinely about future multi-person conversations"),
        // Propagation applies a person's identity across earlier diarized, multi-speaker audio.
        ("this voice also matches", "speaker propagation is a diarization workflow"),
        // This is the confirmation receipt for the same speaker-propagation workflow.
        ("updated the matching past conversations",
         "speaker propagation is a diarization workflow"),
        // The agent is invoked by saying its name while people are speaking together.
        ("say this name in a conversation",
         "agent invocation happens inside a genuine spoken conversation"),
        // This setting controls grading of a live context window, not the saved-note library.
        ("raw conversation window",
         "the council grades a multi-person live context window"),
        // The speaker sheet applies a known person's name to other diarized audio.
        ("also matches", "speaker matching is a diarization workflow"),
    ]

    /// Returns the contents of string literals that use the retired vocabulary.
    ///
    /// Exclusions are limited to comments, DEBUG/dev-harness branches, launch arguments,
    /// accessibility identifiers, diagnostics, and the deliberate multi-person uses above.
    /// Files whose entire job is BUILDING MODEL PROMPTS. Their literals are instructions
    /// to a model, not copy anyone reads — and "conversation" inside an instruction is
    /// load-bearing vocabulary. Rewriting it to "voice note" would change what the model
    /// is being asked to do, so these are excluded from the language sweep by design.
    ///
    /// Each entry needs a reason, and the exclusion is SELF-POLICING: it applies only
    /// while the file still renders nothing (see `isPromptEngine`). The moment someone
    /// puts a SwiftUI view in one of these, the exclusion lapses and the guard resumes
    /// scanning it — so this cannot quietly become a place to hide user-facing copy.
    ///
    /// Note the deliberate asymmetry with `AmbientNotifier.swift`: that file has no view
    /// either, but its literals are NOTIFICATION TEXT the user reads, so it is not listed
    /// here and is fully scanned.
    static let promptEngineFiles: [String: String] = [
        "FoundationModelsTitler.swift": "builds the on-device title/summary prompts",
        "FoundationModelsGate.swift": "builds the ambient actionable-moment prompt",
        "CategoryTagger.swift": "builds the category-assignment prompt",
        "RecapComposer.swift": "builds the recap prompt",
    ]

    /// Is `fileName` a prompt engine that currently renders nothing?
    ///
    /// The second half is the safeguard: a listed file that grows a SwiftUI view is no
    /// longer purely a prompt engine, and its literals go back under the sweep.
    public static func isPromptEngine(fileName: String, source: String) -> Bool {
        guard promptEngineFiles[fileName] != nil else { return false }
        return !source.contains(": View") && !source.contains("some View")
    }

    public static func offendingStringLiterals(in source: String) -> [String] {
        // AmbientDebugView is the council/gate diagnostic readout linked from Settings.
        if source.contains("struct AmbientDebugView: View") { return [] }

        let visibleSource = excludingDebugAndHarnessBranches(from: source)
        return literals(in: visibleSource)
            .filter { isUserFacing($0) }
            .filter { containsRetiredVocabulary($0.value) }
            .filter { allowedConversationReason(for: $0.value) == nil }
            .map(\.value)
    }

    private static func containsRetiredVocabulary(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return retiredVocabulary.firstMatch(in: value, range: range) != nil
    }

    private static let retiredVocabulary = try! NSRegularExpression(
        pattern: #"(?i)\b(record|recording|recordings|conversation|conversations)\b"#)

    private static func allowedConversationReason(for value: String) -> String? {
        let lowered = value.lowercased()
        return allowedConversationAnchors.first {
            lowered.contains($0.anchor)
        }?.reason
    }

    private static func isUserFacing(_ literal: Literal) -> Bool {
        let value = literal.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = literal.line.lowercased()

        // Launch arguments are dev-harness controls, never copy. Exclude companion values on
        // the same predicate line too, such as `-Screen` + `recording`.
        if value.hasPrefix("-")
            || line.contains(".contains(\"-")
            || line.contains("firstindex(of: \"-") {
            return false
        }

        // Identifiers are test contracts. Accessibility labels remain user-facing and scan.
        if line.contains(".accessibilityidentifier(") { return false }

        // Logs, assertions, and diagnostics are intentionally not product language.
        let diagnosticMarkers = [
            "print(", "debugprint(", "nslog(", "os_log(", "logger.",
            "log?.", ".info(", ".debug(", ".warning(", ".error(",
            "assert(", "assertionfailure(", "precondition(", "fatalerror(",
        ]
        if diagnosticMarkers.contains(where: line.contains) { return false }

        // Multi-line literals are model PROMPTS, not rendered copy.
        //
        // Verified rather than assumed: of the multi-line literals in App/, zero are passed
        // to Text/Label/GrainButton/navigationTitle/accessibilityLabel — every one is a
        // prompt or template body. Rendered copy in this codebase is always a single-line
        // literal, so this exclusion costs the guard no real coverage.
        //
        // It also matters that these are NOT rewritten: "conversation" inside an
        // instruction to a model is load-bearing vocabulary, and swapping it for
        // "voice note" changes what the model is being asked to do. This replaced a set
        // of line-specific exclusions that would have silently stopped matching the first
        // time a prompt was reworded.
        if literal.isMultiline { return false }

        // Internal launch-state routing. The persisted/raw case name must not be renamed.
        if line.contains("case \"recording\": return .recordingactive") { return false }

        return true
    }

    private struct ConditionalFrame {
        let parentExcluded: Bool
        let isHarnessConditional: Bool
        var branchExcluded: Bool
    }

    /// Blank excluded branches while preserving line numbers for useful source context.
    private static func excludingDebugAndHarnessBranches(from source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var frames: [ConditionalFrame] = []
        var excluded = false
        var kept: [String] = []
        kept.reserveCapacity(lines.count)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") {
                let condition = String(trimmed.dropFirst(4)).uppercased()
                let harness = condition.contains("DEBUG")
                    || condition.contains("PERF_HARNESS")
                frames.append(ConditionalFrame(
                    parentExcluded: excluded,
                    isHarnessConditional: harness,
                    branchExcluded: excluded || harness))
                excluded = frames.last?.branchExcluded ?? excluded
                kept.append("")
                continue
            }
            if trimmed.hasPrefix("#elseif "), !frames.isEmpty {
                var frame = frames.removeLast()
                let condition = String(trimmed.dropFirst(8)).uppercased()
                frame.branchExcluded = frame.parentExcluded
                    || (frame.isHarnessConditional
                        && (condition.contains("DEBUG")
                            || condition.contains("PERF_HARNESS")))
                frames.append(frame)
                excluded = frame.branchExcluded
                kept.append("")
                continue
            }
            if trimmed == "#else", !frames.isEmpty {
                var frame = frames.removeLast()
                frame.branchExcluded = frame.parentExcluded || !frame.isHarnessConditional
                frames.append(frame)
                excluded = frame.branchExcluded
                kept.append("")
                continue
            }
            if trimmed == "#endif", !frames.isEmpty {
                let frame = frames.removeLast()
                excluded = frame.parentExcluded
                kept.append("")
                continue
            }
            kept.append(excluded ? "" : line)
        }
        return kept.joined(separator: "\n")
    }

    /// Lightweight Swift lexer for ordinary and multiline string literals. It skips nested
    /// block comments and line comments, handles escaped quotes, and keeps the source line
    /// that opened each literal so exclusions stay precise.
    private static func literals(in source: String) -> [Literal] {
        let bytes = Array(source.utf8)
        let lines = source.components(separatedBy: "\n")
        var result: [Literal] = []
        var index = 0
        var lineNumber = 1
        var blockCommentDepth = 0

        func matches(_ bytes: [UInt8], at index: Int, _ token: [UInt8]) -> Bool {
            guard index + token.count <= bytes.count else { return false }
            return Array(bytes[index..<(index + token.count)]) == token
        }

        while index < bytes.count {
            if blockCommentDepth > 0 {
                if matches(bytes, at: index, [47, 42]) {
                    blockCommentDepth += 1
                    index += 2
                } else if matches(bytes, at: index, [42, 47]) {
                    blockCommentDepth -= 1
                    index += 2
                } else {
                    if bytes[index] == 10 { lineNumber += 1 }
                    index += 1
                }
                continue
            }

            if matches(bytes, at: index, [47, 47]) {
                while index < bytes.count, bytes[index] != 10 { index += 1 }
                continue
            }
            if matches(bytes, at: index, [47, 42]) {
                blockCommentDepth = 1
                index += 2
                continue
            }

            guard bytes[index] == 34 else {
                if bytes[index] == 10 { lineNumber += 1 }
                index += 1
                continue
            }

            let openingLine = lineNumber
            let multiline = matches(bytes, at: index, [34, 34, 34])
            let quoteCount = multiline ? 3 : 1
            index += quoteCount
            let contentStart = index

            while index < bytes.count {
                if bytes[index] == 10 { lineNumber += 1 }
                if !multiline, bytes[index] == 92 {
                    index = min(bytes.count, index + 2)
                    continue
                }
                let closing = multiline
                    ? matches(bytes, at: index, [34, 34, 34])
                    : bytes[index] == 34
                if closing {
                    let value = String(decoding: bytes[contentStart..<index], as: UTF8.self)
                    let context = lines.indices.contains(openingLine - 1)
                        ? lines[openingLine - 1]
                        : ""
                    result.append(Literal(value: value, line: context, isMultiline: multiline))
                    index += quoteCount
                    break
                }
                index += 1
            }
        }
        return result
    }
}
