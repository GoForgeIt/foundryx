// CategoryTagger — the on-device model behind the CategoryAutoTagger seam
// (track 20260713T0902). Same law as the titler: Apple Foundation Models where
// available, NO fallback heuristics — a phone without the model simply files
// nothing automatically, and the user's own filing always wins anyway.

import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
final class FoundationModelsCategoryTagger: CategoryAutoTagger, @unchecked Sendable {
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func suggest(title: String?, transcript: String?,
                 from categories: [ConversationCategory]) async -> String? {
        guard isAvailable, !categories.isEmpty else { return nil }
        let names = categories.map(\.name)
        let body = [title, transcript.map { String($0.prefix(3_000)) }]
            .compactMap { $0 }.joined(separator: "\n")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let session = LanguageModelSession()
        let reply = try? await session.respond(
            to: """
            File this conversation under exactly one of these categories: \
            \(names.joined(separator: ", ")). \
            Reply with ONLY the category name, or NONE if none clearly fits.

            \(body)
            """
        ).content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reply, reply.uppercased() != "NONE" else { return nil }
        // Only a category we actually offered may land.
        return names.first { $0.compare(reply, options: .caseInsensitive) == .orderedSame }
    }
}
#endif

/// Wiring-time factory: the system tagger where the OS has Foundation Models,
/// else nil — conversations then stay honestly unfiled until the user files them.
func makeSystemCategoryTagger() -> CategoryAutoTagger? {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
        let tagger = FoundationModelsCategoryTagger()
        return tagger.isAvailable ? tagger : nil
    }
    #endif
    return nil
}
