// FoundationModelsTitler — the REAL on-device title/summary engine behind the
// LocalTitleSummary seam (onboarding track 20260705T1100, Phase 3; locked decision
// #2: Apple Foundation Models where available, NO MLX fallback — phones without
// Apple-Intelligence hardware honestly stay untitled and get the upgrade prompt).
//
// Lives in the App target (not FoundryXKit/SPM) so tests drive the seam with a
// fake; this class only ever runs on-device.

import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
public final class FoundationModelsTitler: LocalTitleSummary, @unchecked Sendable {
    public init() {}

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func titleAndSummary(for transcript: String) async throws -> (title: String, summary: String) {
        // Bound the prompt to the model's small context; the head of a conversation
        // names it well enough.
        let bounded = String(transcript.prefix(6_000))
        // Time it (fm-title span) AND bound it: on-device turns have hung in the
        // wild, and a wedged titler must not stall summaries forever — a 20s
        // timeout surfaces it as a clean error the caller can fall back from.
        let span = PerfSpan(name: "fm-title")
        let result = try await PerfHook.timed("fm-title") {
            try await withPerfTimeout("fm-title", ms: 20_000) {
                let session = LanguageModelSession()
                let title = try await session.respond(
                    to: "Give a 3–6 word title for this conversation transcript. Reply with ONLY the title, no quotes.\n\n\(bounded)"
                ).content.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                let summary = try await session.respond(
                    to: "Summarize this conversation in 1–2 plain sentences. Reply with ONLY the summary.\n\n\(bounded)"
                ).content.trimmingCharacters(in: .whitespacesAndNewlines)
                return (title, summary)
            }
        }
        // CONTENT-FREE usage: a title/summary was generated. ms only — never the
        // transcript, the title, or the summary text.
        UsageHook.generation(kind: "title", ms: span.elapsedMs())
        return result
    }

    /// The LIVE rolling-title refresh (track 20260717T1015): a SINGLE model turn —
    /// never the summary — on the debounced mid-recording cadence. Bounded prompt,
    /// bounded time (a wedged turn surfaces as a clean error the manager backs off
    /// from; the heuristic title keeps the screen honest meanwhile).
    public func liveTitle(for transcript: String) async throws -> String {
        let bounded = String(transcript.prefix(6_000))
        let span = PerfSpan(name: "fm-live-title")
        let title = try await PerfHook.timed("fm-live-title") {
            try await withPerfTimeout("fm-live-title", ms: 15_000) {
                let session = LanguageModelSession()
                return try await session.respond(
                    to: "Give a 3–6 word title for this in-progress conversation transcript. Reply with ONLY the title, no quotes.\n\n\(bounded)"
                ).content.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            }
        }
        // CONTENT-FREE usage: a live title was generated. ms only.
        UsageHook.generation(kind: "live-title", ms: span.elapsedMs())
        return title
    }
}
#endif

/// The wiring-time factory: the system titler where the OS has Foundation Models,
/// else nil — LocalBackend then leaves conversations honestly untitled (the
/// upgrade-prompt state).
public func makeSystemTitler() -> LocalTitleSummary? {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
        return FoundationModelsTitler()
    }
    #endif
    return nil
}
