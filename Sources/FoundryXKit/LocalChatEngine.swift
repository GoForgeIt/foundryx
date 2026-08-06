// LocalChatEngine — phone-only chat over the WHOLE local library (onboarding track
// 20260705T1100, Phase 4; locked decisions #1 + #6). The on-device LLM answers with
// the phone's own transcripts as context: lexical retrieval across every cached
// conversation under a tight character budget (the more compelling demo, honestly
// disclaimed). No tools, no egress — and the surface carries a persistent honesty
// notice + the one-tap waitlist button (AccountClient.postWaitlist).
//
// The LLM is a seam (`LocalChatModel`); the real engine is Apple Foundation Models
// (FoundationModelsChat, App target). No MLX fallback: on phones without Apple
// Intelligence the chat surface shows the upgrade prompt instead.

import Foundation

/// The on-device chat LLM seam.
public protocol LocalChatModel: Sendable {
    var isAvailable: Bool { get }
    func respond(to prompt: String) async throws -> String
}

/// One retrieved library snippet feeding the prompt.
public struct LibrarySnippet: Equatable, Sendable {
    public let captureId: String
    public let title: String
    public let text: String
}

/// Lexical retrieval across every conversation the phone knows (cards + cached
/// transcripts). Pure and deterministic — scoring is term overlap, recency breaks
/// ties. v1 by design: good enough to make whole-library answers real; embeddings
/// arrive with a real brain.
public enum LocalLibraryRetriever {
    /// All conversations with readable text, newest first.
    static func corpus(baseDir: URL) -> [(captureId: String, title: String, text: String, startedAt: UInt64)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter(\.hasDirectoryPath).compactMap { dir in
            let id = dir.lastPathComponent
            let card = ConversationCardStore.load(captureId: id, baseDir: baseDir)
            let text = TranscriptCacheStore.load(captureId: id, baseDir: baseDir)?.transcript
                ?? card?.provisionalTranscript ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (id, card?.title ?? "Untitled", text, card?.startedAt ?? 0)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    /// Top conversations for a question, bounded by `budget` characters of snippet
    /// text overall. Every returned snippet shares at least one term with the
    /// question (no padding with irrelevant text).
    public static func retrieve(question: String, baseDir: URL, budget: Int = 6_000) -> [LibrarySnippet] {
        let qTerms = terms(question)
        guard !qTerms.isEmpty else { return [] }
        let scored = corpus(baseDir: baseDir)
            .map { entry -> (score: Int, entry: (captureId: String, title: String, text: String, startedAt: UInt64)) in
                let tTerms = terms(entry.title + " " + entry.text)
                return (qTerms.intersection(tTerms).count, entry)
            }
            .filter { $0.score > 0 }
            .sorted { ($0.score, $0.entry.startedAt) > ($1.score, $1.entry.startedAt) }

        var out: [LibrarySnippet] = []
        var used = 0
        for (_, e) in scored {
            guard used < budget else { break }
            let slice = String(e.text.prefix(min(1_500, budget - used)))
            used += slice.count
            out.append(LibrarySnippet(captureId: e.captureId, title: e.title, text: slice))
        }
        return out
    }

    static func terms(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 })
    }
}

/// Composes retrieval + the on-device LLM into an answer over the whole library.
public struct LocalChatEngine: Sendable {
    private let baseDir: URL
    private let model: LocalChatModel

    public init(baseDir: URL, model: LocalChatModel) {
        self.baseDir = baseDir
        self.model = model
    }

    public var isAvailable: Bool { model.isAvailable }

    /// Answer a question using snippets from ACROSS the library. Returns the answer
    /// and the capture ids it drew on (the "more than the open conversation" proof,
    /// surfaced as context chips later).
    public func answer(_ question: String) async throws -> (text: String, drewOn: [String]) {
        let snippets = LocalLibraryRetriever.retrieve(question: question, baseDir: baseDir)
        let context = snippets
            .map { "[\($0.title)]\n\($0.text)" }
            .joined(separator: "\n---\n")
        let prompt = """
        You are FoundryX's on-device assistant. Answer from the user's own \
        conversation transcripts below. If they don't contain the answer, say so plainly.

        TRANSCRIPTS:
        \(context.isEmpty ? "(none relevant)" : context)

        QUESTION: \(question)
        """
        let text = try await model.respond(to: prompt)
        return (text, snippets.map(\.captureId))
    }
}

/// The chat surface contract (rendered by the UI, tested here): the honesty notice
/// is PERSISTENT and the waitlist button sits right on the chat surface (locked
/// decision #1 verbatim).
public enum LocalChatPresentation {
    public static let honestyNotice =
        "Answers run entirely on your phone and may be inaccurate or hallucinate. " +
        "For accurate, cited answers across all your voice notes, upgrade to Solleva " +
        "(Cloud or your computer)."
    public static let waitlistButtonTitle = "Join the waitlist"
    /// The upgrade prompt shown instead of chat on phones without Apple Intelligence
    /// (locked decision #2 — transcribe-only tier, no MLX fallback).
    public static let noAppleIntelligencePrompt =
        "Your phone can make voice notes; smarter summaries and chat need a brain — " +
        "join the Cloud waitlist or connect your computer."
}
