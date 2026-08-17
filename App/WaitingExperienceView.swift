// WaitingExperienceView — the ONE shared SwiftUI component for every user-visible
// wait longer than ~1s (perf track WS-C). It binds a `WaitingExperienceModel` (the
// pure, unit-tested model in FoundryXKit) to Grain UI and does exactly what the model
// says: names the wait honestly, shows a REAL determinate bar only where the model
// has honest counts (sync), otherwise elapsed-aware phase text (never a fake bar), and
// rotates one genuinely-true tip every few seconds.
//
// Timing (elapsed + tip rotation) is driven entirely by a TimelineView — there is NO
// Timer, so nothing to invalidate and no retain cycle to leak. Reduce Motion is
// honored: the tip cross-fades (never slides) and the rotation animation is dropped.
//
// Two forms:
//   • default (card)  — recap generation, door fetch, transcription-pending, titling.
//   • `compact: true`  — the one-line sync/backfill banner (dot + text + thin bar).

import SwiftUI
import Grain

struct WaitingExperienceView: View {
    let model: WaitingExperienceModel
    var compact: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Captured once when the view first appears (stable across TimelineView redraws) —
    // the anchor the elapsed-aware phase text and tip rotation are measured from.
    @State private var start = Date()

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(start))
            if compact { compactBody(elapsed: elapsed) } else { cardBody(elapsed: elapsed) }
        }
    }

    // MARK: - Card form

    private func cardBody(elapsed: TimeInterval) -> some View {
        let copy = model.copy
        let tip = model.tip(elapsed: elapsed)
        return VStack(alignment: .leading, spacing: GrainSpacing.x3) {
            HStack(spacing: GrainSpacing.x2) {
                GrainSpinner(size: 16)
                Text(copy.headline)
                    .grainTextStyle(.title)
                    .foregroundStyle(GrainColor.ink)
            }
            Text(model.statusLine(elapsed: elapsed))
                .grainTextStyle(.body)
                .foregroundStyle(GrainColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let fraction = model.progress.fraction {
                GrainProgress(value: fraction)
            }
            Divider().overlay(GrainColor.borderFaint)
            tipView(tip.text)
        }
        .padding(GrainSpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GrainColor.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: GrainRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GrainRadius.card, style: .continuous)
                .strokeBorder(GrainColor.borderHairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(copy.headline). \(model.statusLine(elapsed: elapsed))")
    }

    // MARK: - Compact form (sync/backfill banner)

    private func compactBody(elapsed: TimeInterval) -> some View {
        let copy = model.copy
        let tip = model.tip(elapsed: elapsed)
        return VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            HStack(spacing: GrainSpacing.x2) {
                Circle()
                    .fill(model.progress.isDeterminate ? GrainColor.amber : GrainColor.sage)
                    .frame(width: GrainSpacing.x2, height: GrainSpacing.x2)
                Text(model.statusLine(elapsed: elapsed))
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
                Spacer(minLength: GrainSpacing.x2)
            }
            if let fraction = model.progress.fraction {
                GrainProgress(value: fraction)
            }
            tipView(tip.text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(copy.headline). \(model.statusLine(elapsed: elapsed))")
    }

    // MARK: - Rotating tip (subtle cross-fade; no timer)

    @ViewBuilder private func tipView(_ text: String) -> some View {
        Text(text)
            .grainTextStyle(.caption)
            .foregroundStyle(GrainColor.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .id(text)
            .transition(.opacity)
            .animation(reduceMotion ? nil : GrainMotion.slow, value: text)
    }
}

// MARK: - DEV-only screenshot proof harness (`-Screen waiting <kind>`)

/// A launch-arg-driven single-state proof surface (WS-C), mirroring the app's other
/// `-Screen` screenshot harnesses. No manager/network — renders one honest-wait state
/// full-screen on the Grain background so the simulator can capture it. No effect in a
/// normal launch (only reachable behind the `-Screen waiting` argument in RootView).
struct WaitingExperienceProof: View {
    let kind: WaitKind

    private var model: WaitingExperienceModel {
        switch kind {
        case .recap:
            return WaitingExperienceModel(kind: .recap, onDevice: true,
                                          stats: WaitingLibraryStats(conversationCount: 1284))
        case .title:
            return WaitingExperienceModel(kind: .title, onDevice: true)
        case .transcription:
            return WaitingExperienceModel(kind: .transcription, onDevice: true)
        case .doorFetch:
            return WaitingExperienceModel(kind: .doorFetch, onDevice: false)
        case .sync:
            return WaitingExperienceModel(kind: .sync, onDevice: false,
                                          progress: .determinate(done: 214, total: 1210),
                                          stats: WaitingLibraryStats(conversationCount: 1284,
                                                                     segmentsOnComputer: 9021))
        }
    }

    var body: some View {
        VStack(spacing: GrainSpacing.x6) {
            Spacer()
            WaitingExperienceView(model: model)
            if kind == .sync {
                // Also show the REAL capture-screen strip (WS-B) — the fixed-height,
                // one-line sync row. `.immediate` config so the single-frame screenshot
                // captures the syncing presentation without waiting out the debounce.
                SyncStatusStripView(
                    content: SyncStripContent(
                        hasCaptures: true,
                        syncing: true,
                        progress: .determinate(done: 214, total: 1210),
                        syncingText: WaitingExperienceModel(
                            kind: .sync, onDevice: false,
                            progress: .determinate(done: 214, total: 1210)).statusLine(elapsed: 0),
                        settledText: SyncStripCopy.allSaved(destination: .computer),
                        settledIsPending: false),
                    config: .immediate)
                    .padding(.vertical, GrainSpacing.x2)
                    .background(GrainColor.surface)
                    .clipShape(RoundedRectangle(cornerRadius: GrainRadius.card, style: .continuous))
            }
            Spacer()
        }
        .padding(GrainSpacing.x4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .grainBackground()
    }

    /// Parse the kind that follows the `waiting` token, defaulting to recap.
    static func kind(from args: [String]) -> WaitKind {
        guard let i = args.firstIndex(of: "waiting"), i + 1 < args.count else { return .recap }
        switch args[i + 1] {
        case "title": return .title
        case "transcription": return .transcription
        case "door", "doorFetch": return .doorFetch
        case "sync": return .sync
        default: return .recap
        }
    }
}
