import SwiftUI
import Grain

/// Live audio-level meter (req 8): a moving bar graph of recent levels so the user
/// can SEE the Omi is hearing sound — bars rise with volume. Driven by the same
/// cheap Opus-frame level signal that feeds silence-gap segmentation, so what you
/// see is what the segmenter acts on. Dims when paused (we're deliberately not
/// listening).
struct LevelMeterView: View {
    /// Recent levels, oldest → newest, each 0…1.
    let levels: [Float]
    var active: Bool = true

    var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let spacing: CGFloat = 2
            let barWidth = max(1, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(active ? GrainColor.forgeBlue : GrainColor.inkTertiary)
                        .frame(width: barWidth,
                               height: max(2, CGFloat(level) * geo.size.height))
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.linear(duration: 0.08), value: levels)
        }
        .frame(height: 40)
    }
}
