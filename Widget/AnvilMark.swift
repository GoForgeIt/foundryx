// AnvilMark — the FoundryX brand mark (a stylized anvil), drawn as a resolution-
// independent SwiftUI `Path` so it stays crisp at Dynamic-Island-tiny sizes AND tints
// cleanly to a state color. This is the SINGLE source of truth for the capture
// indicator's icon across every Live Activity surface (compact / minimal / expanded +
// lock screen).
//
// This is the REAL brand mark, not a stand-in: `AnvilShape` is the exact anvil path from
// the FoundryX logo (`foundry/src-tauri/icons/foundry-source.svg` — the same silhouette as
// `AppIcon.appiconset/icon-1024.png`), ported vertex-for-vertex from its 1024 viewBox.
//
// WHY a Path and not the PNG icon: the app icon is a full-bleed gradient PNG — it can't be
// tinted red/blue and reads as mud at 16–20pt in the compact pill. Porting the logo's
// vector path gives us the SAME shape as the icon while staying mono, tintable, and always
// sharp — so recording→red, paused→blue, idle→gray all work on the real mark.

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

/// The REAL FoundryX anvil silhouette — the exact single closed path from the brand logo
/// (`foundry/src-tauri/icons/foundry-source.svg`, which is the app-icon mark), ported vert-
/// for-vert and normalized from its 1024×1024 viewBox so it scales to any frame and tints
/// to a state colour. One solid mass: long tapered horn (left), flat work surface, the
/// right-hand heel step, a narrow waist, and the splayed trapezoidal base.
struct AnvilShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        // Map raw logo coordinates (0…1024 viewBox) into `rect`.
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x / 1024) * w, y: rect.minY + (y / 1024) * h)
        }
        var path = Path()
        path.move(to: p(140, 380))                              // horn tip (left point)
        path.addQuadCurve(to: p(300, 295), control: p(200, 320))// horn curves up to the face
        path.addLine(to: p(760, 295))                           // flat work surface
        path.addLine(to: p(760, 410))                           // heel drops (right)
        path.addLine(to: p(656, 410))
        path.addQuadCurve(to: p(620, 460), control: p(644, 442))// step in to the waist
        path.addLine(to: p(620, 600))
        path.addLine(to: p(880, 600))                           // base flares out (right)
        path.addLine(to: p(900, 660))
        path.addLine(to: p(900, 720))
        path.addLine(to: p(124, 720))                           // base underside
        path.addLine(to: p(124, 660))
        path.addLine(to: p(144, 600))                           // base flares (left)
        path.addLine(to: p(404, 600))
        path.addLine(to: p(404, 460))
        path.addQuadCurve(to: p(368, 410), control: p(380, 442))// waist back up to the face
        path.addLine(to: p(196, 410))
        path.addQuadCurve(to: p(140, 380), control: p(168, 408))// underside of the horn
        path.closeSubpath()
        return path
    }
}
