// PerfOverlayView — the in-app performance overlay (track 20260717T0600 T3).
//
// Compact, Grain-styled pills at the very top of the screen, one per recent perf span
// or hang ("capture-hydrate 820 ms"), newest on top, capped at a few, auto-expiring.
// Rendered ONLY when Settings → DIAGNOSTICS → "Show performance overlay" is on
// (DEFAULT OFF). It observes PerfOverlayModel.shared, which is fed READ-ONLY from the
// perf tap in PerfMetricsSubscriber — the overlay never sits on the emission path, so
// telemetry ships identically whether it is on or off.
//
// Non-interactive except dismiss: the container is transparent and captures no taps, so
// content underneath stays fully usable; only a pill itself is tappable (tap to dismiss).

import SwiftUI
import Combine
import Grain
// FoundryXKit types (PerfOverlayModel/PerfPill) are same-module in the App target.

struct PerfOverlayView: View {
    @ObservedObject private var model = PerfOverlayModel.shared

    /// A 1s tick so pills fade out on their TTL even when no new span arrives. The
    /// subscription exists ONLY while pills are on screen (see body) — `autoconnect()`
    /// stops the underlying timer when its last subscriber goes away, so an OFF/empty
    /// overlay costs zero wakeups for the app's lifetime (review P2-1).
    private let sweep = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: GrainSpacing.x1) {
            ForEach(model.pills) { pill in
                pillView(pill)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // The TTL sweep rides a zero-size child that exists only while pills do:
            // no pills → no subscriber → no timer. Re-subscribes when the next pill lands.
            if !model.pills.isEmpty {
                Color.clear.frame(width: 0, height: 0)
                    .onReceive(sweep) { _ in model.expireNow() }
            }
        }
        .padding(.top, GrainSpacing.x1)
        .frame(maxWidth: .infinity)      // top-aligned band; transparent between pills
        .animation(.easeInOut(duration: 0.2), value: model.pills)
        // Defense-in-depth (review P3-2): with no pills the whole band is provably
        // hit-transparent; with pills, SwiftUI's default already limits hits to the
        // pills' own contentShapes (tap-to-dismiss stays alive).
        .allowsHitTesting(!model.pills.isEmpty)
        .accessibilityHidden(model.pills.isEmpty)
    }

    private func pillView(_ pill: PerfPill) -> some View {
        HStack(spacing: GrainSpacing.x1) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 10))
                .foregroundStyle(GrainColor.forgeBlue)
                .accessibilityHidden(true)
            Text(pill.text)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .monospacedDigit()
        }
        .padding(.horizontal, GrainSpacing.x3)
        .padding(.vertical, GrainSpacing.x1)
        .background(Capsule().fill(GrainColor.surfaceElevated))
        .overlay(Capsule().strokeBorder(GrainColor.border, lineWidth: 1))
        .contentShape(Capsule())          // only the pill captures a tap
        .onTapGesture { model.dismiss(pill.id) }
        .accessibilityLabel("performance \(pill.text). Tap to dismiss.")
    }
}
