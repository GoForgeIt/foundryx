// AnswerBrief — the decision-brief structure an answer can carry (track
// 20260714T1800 §7, fullflow2 "Relay decision brief", :2363). When an answer's
// text is organized as Recommendation / Why / Source sections, the answer
// surface renders it as a structured brief; anything else keeps the plain
// free-text layout. Pure parser here; App/AnswerSurfaceView.swift renders it.

import Foundation

/// The parsed decision brief: one recommendation, its why-bullets, and
/// (optionally) the source it rests on.
public struct AnswerBrief: Equatable, Sendable {
    public let recommendation: String
    public let why: [String]
    public let source: String?

    public init(recommendation: String, why: [String], source: String? = nil) {
        self.recommendation = recommendation
        self.why = why
        self.source = source
    }

    /// Parse answer text into a brief. Headings are lines reading
    /// "Recommendation" / "Why" / "Source" (case-insensitive; markdown "#"s,
    /// "**…**" emphasis, and a trailing ":" are tolerated). Why items are the
    /// section's lines with any "-"/"*"/"•" bullet marker stripped. Returns
    /// nil unless there is a non-empty recommendation AND at least one why
    /// bullet — everything else stays the plain answer layout.
    public static func parse(_ text: String) -> AnswerBrief? {
        enum Section { case none, recommendation, why, source }
        var section = Section.none
        var recommendation: [String] = []
        var why: [String] = []
        var source: [String] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            switch headingKind(line) {
            case "recommendation": section = .recommendation; continue
            case "why": section = .why; continue
            case "source": section = .source; continue
            default: break
            }
            switch section {
            case .none: continue   // preamble before any heading is not brief content
            case .recommendation: recommendation.append(line)
            case .why: why.append(stripBullet(line))
            case .source: source.append(line)
            }
        }

        let rec = recommendation.joined(separator: " ")
        let bullets = why.filter { !$0.isEmpty }
        guard !rec.isEmpty, !bullets.isEmpty else { return nil }
        let src = source.joined(separator: " ")
        return AnswerBrief(recommendation: rec, why: bullets,
                           source: src.isEmpty ? nil : src)
    }

    /// "## **Recommendation:**" → "recommendation"; non-headings → nil.
    private static func headingKind(_ line: String) -> String? {
        var s = Substring(line)
        while s.first == "#" { s = s.dropFirst() }
        var t = s.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("*") { t.removeFirst() }
        while t.hasSuffix("*") { t.removeLast() }
        if t.hasSuffix(":") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "recommendation": return "recommendation"
        case "why": return "why"
        case "source", "sources": return "source"
        default: return nil
        }
    }

    private static func stripBullet(_ line: String) -> String {
        var s = Substring(line)
        if let first = s.first, "-*•–".contains(first) {
            s = s.dropFirst()
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// The brief's section labels — one place, so the surface and its tests agree.
public enum AnswerBriefCopy {
    public static let recommendation = "Recommendation"
    public static let why = "Why"
    public static let source = "Source"
}
