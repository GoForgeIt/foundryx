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
    /// WHAT IS BEING WAITED FOR. The tier is NOT an argument here — see below.
    let kind: WaitKind
    var progress: WaitProgress = .indeterminate
    var stats: WaitingLibraryStats = .none
    var compact: Bool = false

    /// THE TIER IS READ, NEVER PASSED (X3).
    ///
    /// This view used to take a fully-built `WaitingExperienceModel`, which meant every
    /// call site wrote `WaitingExperienceModel(kind: …, destination: destination)` by hand
    /// — nine of them. Changing ONE of those arguments to `.computer` restored the false
    /// wait a Vault owner used to read, compiled, shipped, and left every suite green,
    /// because `swift test` cannot compile `App/`. There is now no destination argument at
    /// any call site to get wrong: the value is written once at the root from the kit's own
    /// mapping and read here.
    @Environment(\.captureDestination) private var destination

    private var model: WaitingExperienceModel {
        WaitingExperienceModel(kind: kind, destination: destination,
                               progress: progress, stats: stats)
    }

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

    /// The tier this ONE screenshot is of. The proof harness is the only place that names
    /// a tier by hand, because photographing a specific tier is its entire purpose.
    private var proofDestination: CaptureDestination {
        switch kind {
        case .recap, .title, .onDeviceTitle, .transcription: return .phone
        case .doorFetch, .sync: return .computer
        }
    }

    private var proofProgress: WaitProgress {
        kind == .sync ? .determinate(done: 214, total: 1210) : .indeterminate
    }

    private var proofStats: WaitingLibraryStats {
        switch kind {
        case .recap: return WaitingLibraryStats(conversationCount: 1284)
        case .sync:  return WaitingLibraryStats(conversationCount: 1284, segmentsOnComputer: 9021)
        default:     return .none
        }
    }

    var body: some View {
        VStack(spacing: GrainSpacing.x6) {
            Spacer()
            WaitingExperienceView(kind: kind, progress: proofProgress, stats: proofStats)
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
                            kind: .sync, destination: proofDestination,
                            progress: proofProgress).statusLine(elapsed: 0),
                        settledText: SyncStripCopy.allSaved(destination: proofDestination),
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
        .environment(\.captureDestination, proofDestination)
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
