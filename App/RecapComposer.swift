// FoundationModelsRecapComposer — the on-device model behind the RecapComposer
// seam (features/conversation-recaps.feature). Same law as the titler/tagger:
// Apple Foundation Models where available, no fabrication — the model is asked
// to summarize + draw insights STRICTLY from the conversations given, and a
// phone without the model falls back to the deterministic composition (which is
// already genuinely useful).

import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
final class FoundationModelsRecapComposer: RecapComposer, @unchecked Sendable {
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func compose(_ conversations: [RecapConversation],
                 span: RecapSpan) async -> (narrative: String, insights: [String])? {
        guard isAvailable, !conversations.isEmpty else { return nil }
        // CONTENT-FREE usage: time the recap generation. ms + the conversation COUNT
        // only — never the titles, summaries, narrative, or insight text.
        let genSpan = PerfSpan(name: "recap")
        defer {
            UsageHook.generation(kind: "recap", ms: genSpan.elapsedMs(),
                                 extraNums: ["conversation_count": Double(conversations.count)])
        }
        // Feed the model ONLY the real titles + summaries (bounded), and instruct
        // it to draw strictly from them.
        let material = conversations.prefix(40).map { c -> String in
            let s = c.summary.isEmpty ? c.title : c.summary
            return "- \(c.title.isEmpty ? "Untitled" : c.title): \(s)"
        }.joined(separator: "\n")
        let periodWord: String
        switch span {
        case .day: periodWord = "today"
        case .week, .weekToDate: periodWord = "this week"
        }
        let session = LanguageModelSession()
        // Narrative: a warm, specific 2-4 sentence recap.
        guard let narrative = try? await session.respond(
            to: """
            Here are my conversations from \(periodWord):
            \(material)

            Write a warm, specific 2 to 4 sentence recap of \(periodWord), drawing \
            ONLY from these conversations. No preamble, no bullet points, no \
            invented details. Reply with only the recap.
            """
        ).content.trimmingCharacters(in: .whitespacesAndNewlines), !narrative.isEmpty
        else { return nil }

        // Insights: a few connections/follow-ups, one per line.
        let insightsRaw = (try? await session.respond(
            to: """
            From the same conversations from \(periodWord):
            \(material)

            List up to 5 useful insights: connections between conversations, \
            things to follow up on, or notable decisions. Draw ONLY from these \
            conversations, never invent. One insight per line, no numbering, no \
            bullets. If there are none, reply with nothing.
            """
        ).content) ?? ""
        let insights = insightsRaw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-•*0123456789. "))) }
            .filter { !$0.isEmpty }
            .prefix(6)

        return (narrative, Array(insights))
    }
}
#endif

/// Wiring-time factory: the system composer where the OS has Foundation Models,
/// else nil — the deterministic composition (still useful) then stands.
func makeSystemRecapComposer() -> RecapComposer? {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
        let c = FoundationModelsRecapComposer()
        return c.isAvailable ? c : nil
    }
    #endif
    return nil
}
