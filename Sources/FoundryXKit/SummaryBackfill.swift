// SummaryBackfill — the bounded, ONE-TIME on-device summary backfill for the home
// list (track 20260715T1459 T2, AC3). Older terminal cards can sit on the home list
// with a title but no summary line until each is opened. This pass fills a bounded
// number of them from the cached transcript, on-device, so the home isn't a wall of
// title-only cards. Fill-on-open (ConversationFacesView) remains the fallback for the
// rest and for anything recorded after the pass ran.
//
// It is IDEMPOTENT and cheap-to-skip: a marker file in the captures dir stops it
// re-running on every list appear, and it never re-summarizes a card that already has
// a summary. Where the OS has no on-device model (`titler` nil / unavailable), it does
// nothing AND writes no marker — so it runs the day Foundation Models becomes available.

import Foundation

public enum SummaryBackfill {
    /// Versioned so a future, wider backfill can re-run once by bumping the name.
    static let markerName = "summary-backfill.v1.done"

    /// Fill missing card summaries for the visible captures, bounded to `limit`.
    ///
    /// - captureIds: the visible list, newest-first (the caller's order is preserved).
    /// - transcript / cardSummary: pure reads over what the phone holds (the manager's
    ///   `searchText` / `cardMeta().summary`), injected so this stays testable + off-main.
    ///
    /// Returns the number of cards it filled. Writes the done-marker only after a real
    /// pass over a non-empty list — an empty list (first paint before load) leaves the
    /// marker unwritten so the next call still runs.
    @discardableResult
    public static func run(captureIds: [String],
                           baseDir: URL,
                           titler: LocalTitleSummary?,
                           transcript: @escaping @Sendable (String) -> String?,
                           cardSummary: @escaping @Sendable (String) -> String?,
                           limit: Int = 12) async -> Int {
        guard let titler, titler.isAvailable else { return 0 }
        guard !captureIds.isEmpty else { return 0 }
        let marker = baseDir.appendingPathComponent(markerName)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return 0 }

        var filled = 0
        // `deferred` = we saw an unsummarized card whose transcript ISN'T on the phone yet
        // (recent cards fetch their transcript on open; older cards may have pruned ones).
        // If any card was deferred we do NOT burn the one-time marker — otherwise a first
        // pass that fills 0 (transcripts not cached yet) would stop the backfill forever and
        // leave those cards title-only. The marker is only written once the addressable set
        // is exhausted (nothing left to defer), so it converges instead of misfiring once.
        var deferred = false
        // The on-device model can WEDGE — a 20s+ non-cooperative turn that surfaces as a
        // `PerfTimeout` from `withPerfTimeout`. If it does, STOP the pass immediately: calling
        // the wedged model the other 11 times pins the CPU for minutes (and this pass re-fires
        // on every list appear). We leave the one-time marker UNWRITTEN so the backfill runs
        // again once the model recovers.
        var wedged = false
        for id in captureIds {
            if Task.isCancelled { return filled }   // .task(id:) re-fires: don't double-run
            if filled >= limit { break }
            if let existing = cardSummary(id), !existing.isEmpty { continue }   // skip summarized
            guard let text = transcript(id), !text.isEmpty else { deferred = true; continue }
            let result: (title: String, summary: String)
            do {
                result = try await titler.titleAndSummary(for: text)
            } catch is PerfTimeout {
                wedged = true; break   // model wedged — do NOT keep hammering it this pass
            } catch is ModelWedgedError {
                // The session breaker is OPEN (a wedge was already seen — here or at another call
                // site). Treat it exactly like a fresh wedge: STOP the pass and leave the one-time
                // marker unwritten, so the backfill re-runs once the model recovers. Refusal must
                // never burn the marker (that would strand these cards as permanently un-backfilled).
                wedged = true; break
            } catch {
                continue   // a per-card transient failure: skip this card, keep the pass going
            }
            let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { continue }
            ConversationCardStore.merge(captureId: id, baseDir: baseDir, summary: summary)
            filled += 1
        }
        // Model wedged mid-pass: return WITHOUT burning the one-time marker so the backfill
        // is re-runnable once the model is healthy again.
        if wedged { return filled }
        // One-time marker ONLY when nothing was deferred — i.e. every unsummarized card that
        // could be filled was. Pruned-transcript cards that never get an on-phone transcript
        // keep the backfill re-runnable, but each re-run is cheap (skips summarized, no model
        // work when there's nothing fillable) and fill-on-open remains the per-card guarantee.
        if !deferred { try? Data().write(to: marker, options: .atomic) }
        return filled
    }
}
