// RollingTitleDemo — the DEV-only proof harness for the ROLLING live title (track
// 20260717T1015, `-RollingTitleDemo`). A scripted live transcriber replays a known
// conversation — one that OPENS on a kitchen-renovation budget and DRIFTS to
// contractor permits — through the REAL pipeline (CaptureManager pump → whole-
// conversation heuristic → arbiter → published `liveTitle`), so a simulator UI test
// can watch the title form from the whole context and evolve without a live mic
// speaking scripted lines. DEBUG-only; production always wires the real factory.

#if DEBUG
import Foundation
import AVFoundation

final class ScriptedLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    static func factory() -> LiveTranscriberFactory { { ScriptedLiveTranscriber() } }

    let transcript: AsyncStream<LiveTranscript>
    private let publish: AsyncStream<LiveTranscript>.Continuation
    private var task: Task<Void, Never>?
    // Mirrors the real transcribers: a bounded display tail + the whole-conversation
    // titling context. Mutated only on the replay task.
    private var finalized = ""
    private var ctx = RollingTitleContext()

    /// A conversation that MOVES: the old last-segment title would end up naming
    /// only the permits tail; the whole-conversation title must keep the kitchen
    /// budget it opened on.
    private static let script: [String] = [
        "Okay so the big topic today is the kitchen renovation budget.",
        "The kitchen budget has to cover cabinets, counters, and the island.",
        "I think the kitchen renovation lands around forty thousand total.",
        "The budget number scares me a little but the kitchen needs it.",
        "We could phase the renovation to spread the budget over the year.",
        "Appliances are the other budget line we keep forgetting about.",
        "Anyway the lighting plan also needs picking before demo starts.",
        "There was that showroom with the pendant lights we liked.",
        "Flooring samples are still sitting in the hallway by the door.",
        "Now the contractor said the timeline depends entirely on permits.",
        "Permits in this county apparently take six weeks minimum.",
        "So the contractor wants to file the permits paperwork this week.",
        "If permits slip, the contractor timeline pushes into June.",
        "The contractor will send the permits checklist tomorrow morning.",
    ]

    init() {
        var cont: AsyncStream<LiveTranscript>.Continuation!
        self.transcript = AsyncStream { cont = $0 }
        self.publish = cont
    }

    func start() async throws {
        task = Task { [weak self] in
            for line in Self.script {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled else { return }
                self.emitFinal(line)
            }
        }
    }

    private func emitFinal(_ line: String) {
        finalized = LiveTranscriptBuffer.boundedTail(
            finalized.isEmpty ? line : finalized + " " + line)
        ctx.ingest(final: line)
        publish.yield(LiveTranscript(finalizedText: finalized, volatileTail: "",
                                     titleContext: ctx.text))
    }

    func append(_ pcm: AVAudioPCMBuffer) {}

    func finish() async -> String {
        task?.cancel()
        publish.yield(LiveTranscript(finalizedText: finalized, volatileTail: "",
                                     isComplete: true, titleContext: ctx.text))
        publish.finish()
        return finalized
    }
}

/// The scripted EXTERNAL (Fireworks-shaped) live-title refresh for the proof harness
/// (track 20260717T1500). Stands in for the door's `/foundryx/capture/<id>/live-title`
/// route so the simulator can watch the two-tier flow WITHOUT a real desktop: the
/// instant heuristic placeholder appears, then on the backoff this returns a sharper
/// WHOLE-conversation title that outranks it. Content-aware over the passed history so
/// the sharpen visibly tracks where the conversation has gone. DEBUG-only.
enum ScriptedExternalTitle {
    static func closure() -> @Sendable (String, String, Int) async throws -> String? {
        { _, history, _ in
            // A touch of latency, like a real external round-trip.
            try? await Task.sleep(nanoseconds: 250_000_000)
            let h = history.lowercased()
            if h.contains("contractor") || h.contains("permits") {
                return "Kitchen Reno: Budget and Permits"
            }
            return "Kitchen Renovation Budget Plan"
        }
    }
}
#endif
