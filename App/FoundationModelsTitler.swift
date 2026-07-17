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
    /// The session-scoped wedge breaker, SHARED across every titler instance and call site
    /// (SummaryBackfill, capture-finalize, the live rolling title). A wedge detected anywhere
    /// refuses the next on-device turn EVERYWHERE, so a wedged model costs one ~86s runaway
    /// per cool-down — not a fresh one per call site. See ModelWedgeBreaker for the machine.
    public static let breaker = ModelWedgeBreaker()

    private let breaker: ModelWedgeBreaker
    public init(breaker: ModelWedgeBreaker = FoundationModelsTitler.breaker) { self.breaker = breaker }

    /// The SHARPENED title ask (track 20260717T1500, Nick: "make sure the prompt
    /// actually gives a good summary of what has happened so far rather than just
    /// recent words"). The `transcript` is already the WHOLE-conversation bounded
    /// head+tail; the instruction makes the model name the conversation's overall
    /// TOPIC/PURPOSE, not echo the latest lines. The external (Fireworks) refresh is
    /// prompted door-side with the same intent, over the same whole-conversation history.
    static func titlePrompt(transcript: String, inProgress: Bool = false) -> String {
        let subject = inProgress ? "an in-progress conversation" : "a conversation"
        return """
        Below is the full transcript of \(subject) so far. Read the WHOLE transcript, \
        then in 3 to 6 words name what the conversation is fundamentally ABOUT — its main \
        topic or purpose across the entire discussion, NOT just the most recent lines and \
        NOT a quote of the last thing said. Reply with ONLY the title: no quotes, no \
        punctuation, no preamble.

        TRANSCRIPT:
        \(transcript)
        """
    }

    public var isAvailable: Bool {
        // Availability is about HARDWARE (Apple-Intelligence support), NOT health — the breaker
        // never flips this false. Refusal happens inside the turn methods, so callers that gate
        // on availability (SummaryBackfill) still route through the breaker's typed refusal.
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Run one on-device turn behind the shared wedge breaker: refuse instantly while OPEN
    /// (a fast, typed `ModelWedgedError` — never another detached ~86s CPU runaway), close on
    /// success, trip on a `PerfTimeout` wedge (rethrown unchanged so SummaryBackfill's wedge
    /// handling still stops its pass), and free the half-open probe slot on a transient error.
    private func guarded<T>(_ op: () async throws -> T) async throws -> T {
        switch breaker.admit() {
        case .refused(let remainingMs, let emitSpan):
            // Content-free: name + remaining cool-down only, throttled to at most once a minute.
            if emitSpan { PerfHook.span("fm-breaker-open", ms: remainingMs) }
            throw ModelWedgedError(cooldownRemainingMs: remainingMs)
        case .proceed, .probe:
            break   // CLOSED, or the single half-open probe — run the turn and report its outcome.
        }
        do {
            let result = try await op()
            breaker.recordSuccess()
            return result
        } catch let timeout as PerfTimeout {
            // The turn WEDGED (deadline fired; the op is now an orphan burning CPU until it
            // finishes on its own). Trip the breaker so the NEXT turn — anywhere — refuses.
            // The trip span always emits (low volume: one per wedge).
            let remaining = breaker.tripWedge()
            PerfHook.span("fm-breaker-open", ms: remaining)
            throw timeout
        } catch {
            // A non-wedge transient failure. If this was the single half-open probe, free the
            // slot so the next call re-probes — a transient blip must not strand the breaker.
            breaker.releaseProbe()
            throw error
        }
    }

    public func titleAndSummary(for transcript: String) async throws -> (title: String, summary: String) {
        // Bound the prompt to the model's small context; the head of a conversation
        // names it well enough.
        let bounded = String(transcript.prefix(6_000))
        // Time it (fm-title span) AND bound it: on-device turns have hung in the
        // wild, and a wedged titler must not stall summaries forever — a 20s
        // timeout surfaces it as a clean error the caller can fall back from.
        let span = PerfSpan(name: "fm-title")
        let result = try await guarded {
            try await PerfHook.timed("fm-title") {
                try await withPerfTimeout("fm-title", ms: 20_000) {
                    let session = LanguageModelSession()
                    let title = try await session.respond(
                        to: Self.titlePrompt(transcript: bounded)
                    ).content.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                    let summary = try await session.respond(
                        to: "Summarize this conversation in 1–2 plain sentences. Reply with ONLY the summary.\n\n\(bounded)"
                    ).content.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (title, summary)
                }
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
    /// from; the heuristic title keeps the screen honest meanwhile). Behind the SAME
    /// wedge breaker: a mid-recording cadence against a wedged model would otherwise
    /// stack a fresh ~86s detached CPU runaway per refresh tick.
    public func liveTitle(for transcript: String) async throws -> String {
        let bounded = String(transcript.prefix(6_000))
        let span = PerfSpan(name: "fm-live-title")
        let title = try await guarded {
            try await PerfHook.timed("fm-live-title") {
                try await withPerfTimeout("fm-live-title", ms: 15_000) {
                    let session = LanguageModelSession()
                    return try await session.respond(
                        to: Self.titlePrompt(transcript: bounded, inProgress: true)
                    ).content.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                }
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
