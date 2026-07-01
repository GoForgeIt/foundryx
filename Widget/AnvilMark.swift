// AnvilMark — the FoundryX brand mark (a stylized anvil), drawn as a resolution-
// independent SwiftUI `Path` so it stays crisp at Dynamic-Island-tiny sizes AND tints
// cleanly to a state color. This is the SINGLE source of truth for the capture
// indicator's icon across every Live Activity surface (compact / minimal / expanded +
// lock screen).
//
// WHY a Path and not the app icon: `AppIcon.appiconset/icon-1024.png` is a full-bleed,
// gradient-backed 1024px PNG — it can't be tinted red/blue and reads as mud at 20pt in
// the compact pill. A vector template gives us a mono, tintable, always-sharp mark.
//
// SWAP-IN FOR A REAL ANVIL ASSET (one line): if a designer drops an anvil *template*
// asset (a monochrome PDF or a "Render As: Template Image" PNG) into an asset catalog
// that the WIDGET target compiles — e.g. add `Widget/Assets.xcassets` with an `anvil`
// image set, then add that catalog to the FoundryXWidget target's `sources` in
// project.yml — replace the `Path { … }`-based `shape` below with:
//     Image("anvil").resizable().scaledToFit()
// Everything else (tint, pulse, sizing, all call sites) stays exactly as-is because they
// go through this ONE view.

import SwiftUI

/// The tintable anvil brand mark. Fills with `.foregroundStyle`/`.tint` like an SF Symbol.
struct AnvilMark: View {
    var body: some View {
        // The tintable shape. To adopt a real asset, swap ONLY this line (see file header).
        AnvilShape()
            .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - state-driven indicator (color + pulse)

extension CaptureIndicatorTint {
    /// The SwiftUI color for this abstract tint — the ONE bridge from the pure, testable
    /// `CaptureIndicatorTint` (defined in FoundryXKit) to a rendered `Color`.
    var color: Color {
        switch self {
        case .recording: return .red
        case .paused:    return .blue
        case .neutral:   return .secondary
        }
    }
}

/// The capture status indicator: the anvil brand mark, tinted per phase and — while
/// actively recording — PULSING (a subtle scale/opacity breathe). Every Live Activity
/// surface renders this instead of a bare dot/symbol, so the state→color/pulse rule lives
/// in exactly one place.
///
/// Battery-safety: the pulse is a single lightweight SwiftUI `repeatForever` animation on a
/// static view, applied ONLY when `phase.indicatorPulses` (recording). On iOS 17+ it uses
/// `.symbolEffect(.pulse)`-style motion; we implement it with a plain opacity/scale animation
/// so it works on the `Path`-based mark too. There is NO per-frame timer and NO push to
/// drive it — the animation runs locally in the render process and stops the instant the
/// phase leaves recording. Paused/idle are steady (no animation object at all).
struct CaptureIndicator: View {
    let phase: CaptureActivityPhase
    /// Point size of the mark (compact pill is tiny; expanded/lock screen larger).
    var size: CGFloat = 18

    @State private var pulsing = false

    var body: some View {
        AnvilMark()
            .frame(width: size, height: size)
            .foregroundStyle(phase.indicatorTint.color)
            .opacity(phase.indicatorPulses ? (pulsing ? 0.55 : 1.0) : 1.0)
            .scaleEffect(phase.indicatorPulses ? (pulsing ? 0.9 : 1.0) : 1.0)
            .animation(phase.indicatorPulses
                       ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                       : .default,
                       value: pulsing)
            .onAppear { if phase.indicatorPulses { pulsing = true } }
            // If the snapshot re-renders in a different phase, (re)arm or halt the breathe.
            .onChange(of: phase) { newPhase in
                pulsing = newPhase.indicatorPulses
            }
            .accessibilityHidden(true)
    }
}

/// A stylized anvil silhouette in a unit square (matches the app icon's form: a horn-ended
/// top face, a waist, and a splayed base). Normalized 0…1 so it scales to any frame.
struct AnvilShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var path = Path()

        // Top face (the body + pointed horn on the left).
        path.move(to: p(0.12, 0.34))       // horn tip
        path.addLine(to: p(0.30, 0.26))    // top-left of face
        path.addLine(to: p(0.88, 0.26))    // top-right of face
        path.addLine(to: p(0.88, 0.40))    // right edge down
        path.addLine(to: p(0.62, 0.40))    // step in toward the waist
        path.addLine(to: p(0.58, 0.44))
        path.addLine(to: p(0.42, 0.44))
        path.addLine(to: p(0.38, 0.40))
        path.addLine(to: p(0.30, 0.40))
        path.addLine(to: p(0.18, 0.42))    // underside of the horn
        path.closeSubpath()

        // Waist (the narrow stem under the face).
        path.move(to: p(0.42, 0.44))
        path.addLine(to: p(0.58, 0.44))
        path.addLine(to: p(0.56, 0.66))
        path.addLine(to: p(0.44, 0.66))
        path.closeSubpath()

        // Base (the splayed foot).
        path.move(to: p(0.30, 0.66))
        path.addLine(to: p(0.70, 0.66))
        path.addLine(to: p(0.78, 0.78))
        path.addLine(to: p(0.22, 0.78))
        path.closeSubpath()

        return path
    }
}
