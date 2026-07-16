#if DEBUG
import Foundation

/// Phase 4 — on-device-model latency bench. `-BenchModel` drives the real system
/// titler over three transcript sizes (1k / 8k / 32k chars) so we can see how
/// FoundationModels title+summarize latency scales on a chosen simulated iPhone,
/// and confirm the timeout guard (fm-title, 20s) bounds a wedged turn instead of
/// hanging. Each run emits an fm-title span (via the titler's own PerfHook.timed)
/// plus a `bench-model` NSLog line the sim-perf harness can read. Skips cleanly
/// where FoundationModels isn't available (older OS / unsupported simulator).
enum BenchModel {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-BenchModel") else { return }
        guard let titler = makeSystemTitler() else {
            NSLog("bench-model: FoundationModels unavailable — skipping")
            return
        }
        let sizes = [1_000, 8_000, 32_000]
        Task {
            for size in sizes {
                // ~46 chars/sentence → repeat to hit the target length.
                let transcript = String(
                    repeating: "This is a benchmark sentence about a meeting and next steps. ",
                    count: max(1, size / 60))
                let span = PerfSpan(name: "bench-fm-title-\(size)")
                do {
                    _ = try await titler.titleAndSummary(for: transcript)
                    NSLog("bench-model: fm-title chars=%d ms=%d", size, span.elapsedMs())
                } catch {
                    // A PerfTimeout here IS the finding — the 20s guard fired instead of hanging.
                    NSLog("bench-model: fm-title chars=%d FAILED after %dms (%@)",
                          size, span.elapsedMs(), "\(error)")
                }
            }
            NSLog("bench-model: done")
        }
    }
}
#endif
