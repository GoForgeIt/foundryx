// SyncStatusStripView — the calm, one-line "your data is safe" strip under the capture
// header (UX-polish WS-B).
//
// THE PROBLEM IT FIXES: the old strip swapped between a one-line message, a THREE-line
// waiting card (status + bar + rotating tip), and nothing at all — so every time a sync
// started or stopped the slot's height changed and shoved the whole conversation list
// down, with no animation and no debounce. Brief drains flickered it.
//
// THE FIX — four guarantees, all here:
//   1. NO LAYOUT SHIFT. Whenever there are captures the strip is a CONSTANT-height
//      single row. Every presentation renders at exactly `Metrics.totalHeight`; only the
//      row's CONTENT changes, so nothing below ever moves. The determinate bar is a
//      fixed-width element that lives INSIDE the row (shorter than the row), so its
//      presence or absence changes no height.
//   2. SMOOTH TRANSITIONS. Content changes cross-fade (opacity) on a Grain motion token,
//      keyed on the presentation. Reduce Motion drops the animation (a hard cut, never a
//      slide). The empty-library collapse animates height + fade, never snaps.
//   3. DEBOUNCE + 4. MINIMUM SHOW are owned by the pure `SyncBarPresenter` (FoundryXKit),
//      driven here from a TimelineView tick — no Timer, nothing to leak.

import SwiftUI
import Grain
// (FoundryXKit types are same-module — the App target compiles Sources/FoundryXKit directly)

/// The honest ingredients the strip renders. Computed by the caller from live sync
/// state so the strip itself has no knowledge of the capture pipeline. Every string is
/// real copy from `WaitingExperienceModel` / the existing sync messages — never invented.
struct SyncStripContent: Equatable {
    /// Whether there are any captures at all — when false the strip collapses to nothing.
    var hasCaptures: Bool
    /// The raw "a determinate segment drain is active" signal fed to the presenter.
    var syncing: Bool
    /// The honest determinate fraction for the inline bar (nil ⇒ no bar).
    var progress: WaitProgress?
    /// The honest status line to show WHILE syncing (paired with the bar).
    var syncingText: String
    /// The status line to show when settled (pending detail, or "all saved").
    var settledText: String
    /// Whether the settled content still reflects pending work (amber dot) vs the calm
    /// all-saved state (sage dot).
    var settledIsPending: Bool

    /// The empty, no-captures content (strip collapsed).
    static let empty = SyncStripContent(
        hasCaptures: false, syncing: false, progress: nil,
        syncingText: "", settledText: "", settledIsPending: false)
}

struct SyncStatusStripView: View {
    let content: SyncStripContent
    /// Hysteresis thresholds — the default 1.5s/3s contract; `.immediate` for proofs.
    var config: SyncBarPresenter.Config

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The pure hysteresis machine + its last-emitted presentation. The machine's phase
    // is the ONLY mutable state; the view is a thin binding over it.
    @State private var presenter: SyncBarPresenter
    @State private var presentation: SyncBarPresentation = .settled
    // Stable anchor for the TimelineView cadence (captured once; nothing to invalidate).
    @State private var start = Date()

    // P2-1 (implement.review.md): the row height SCALES with the user's text size
    // (relative to the caption style it renders) so large Dynamic Type / AX sizes are
    // never vertically clipped. It stays CONSTANT across presentations at any given
    // text size — the no-layout-shift guarantee is per-size, anchored to the same
    // `SyncStripLayout.rowHeight` base the tests pin.
    @ScaledMetric(relativeTo: .caption) private var scaledRowHeight = CGFloat(SyncStripLayout.rowHeight)

    private enum Metrics {
        // The row/height geometry lives in FoundryXKit (`SyncStripLayout`) so the view and
        // the tests share ONE source of truth for the no-layout-shift guarantee.
        static let topPadding = CGFloat(SyncStripLayout.topPadding)
        static let bottomPadding = CGFloat(SyncStripLayout.bottomPadding)
        /// Inline determinate bar width (trailing, fixed).
        static let barWidth: CGFloat = 64
    }

    /// The strip's fixed outer height — constant for a given text size, so content below
    /// the strip can NEVER move regardless of which presentation is on screen.
    private var totalHeight: CGFloat { scaledRowHeight + Metrics.topPadding + Metrics.bottomPadding }

    init(content: SyncStripContent, config: SyncBarPresenter.Config = .default) {
        self.content = content
        self.config = config
        _presenter = State(initialValue: SyncBarPresenter(config: config))
    }

    var body: some View {
        strip
            // The ticker only exists while the hysteresis has pending work to resolve (a
            // pending appear-delay or a min-show hold). When the strip is idle — the common
            // "all saved" state on an always-visible screen — there is NO timer at all, so
            // no wakeups. A real signal change re-mounts it via `needsTicking` below.
            .overlay { if needsTicking { ticker } }
            // React immediately to a real signal change (don't wait for the next tick).
            .onChange(of: content.syncing) { _ in advance(now: Date()) }
            .onAppear { advance(now: Date()) }
            // Empty-library collapse: animate height + fade to zero, never a snap.
            .frame(height: content.hasCaptures ? totalHeight : 0)
            .opacity(content.hasCaptures ? 1 : 0)
            .clipped()
            .animation(reduceMotion ? nil : GrainMotion.normal, value: content.hasCaptures)
    }

    /// The strip needs a tick source only while a threshold is pending: syncing is active
    /// (appear-delay may elapse) or the bar is up (min-show may elapse). Otherwise idle.
    private var needsTicking: Bool { content.syncing || presentation == .syncing }

    /// An invisible TimelineView used purely as a leak-free tick source — no Timer to
    /// retain, and it unmounts the instant `needsTicking` goes false.
    private var ticker: some View {
        TimelineView(.periodic(from: start, by: 0.5)) { context in
            Color.clear
                .onChange(of: context.date) { now in advance(now: now) }
        }
    }

    // MARK: - The fixed-height row

    private var strip: some View {
        ZStack(alignment: .leading) {
            rowContent
                // A fresh identity per presentation makes the content swap a cross-fade.
                .id(presentation)
                .transition(.opacity)
        }
        .frame(height: scaledRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.top, Metrics.topPadding)
        .padding(.bottom, Metrics.bottomPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var rowContent: some View {
        HStack(spacing: GrainSpacing.x2) {
            Circle()
                .fill(dotColor)
                .frame(width: GrainSpacing.x2, height: GrainSpacing.x2)
            Text(text)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: GrainSpacing.x2)
            if presentation == .syncing, let fraction = content.progress?.fraction {
                GrainProgress(value: fraction)
                    .frame(width: Metrics.barWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Presentation-derived content

    private var text: String {
        switch presentation {
        case .syncing: return content.syncingText
        case .settled: return content.settledText
        }
    }

    private var dotColor: Color {
        switch presentation {
        case .syncing: return GrainColor.amber
        case .settled: return content.settledIsPending ? GrainColor.amber : GrainColor.sage
        }
    }

    private var accessibilityLabel: String { text }

    // MARK: - Advance

    private func advance(now: Date) {
        let next = presenter.step(syncing: content.syncing, now: now)
        guard next != presentation else { return }
        withAnimation(reduceMotion ? nil : GrainMotion.normal) { presentation = next }
    }
}
