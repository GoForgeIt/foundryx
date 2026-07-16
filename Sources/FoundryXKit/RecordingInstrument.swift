// RecordingInstrument — the durable logic behind the recording screen's ring,
// provisional title, and recording pill (track 20260713T0903,
// features/recording-instrument.feature). Pure functions; the views render them.

import Foundation

/// The ring's inputs while recording. Presentation stays in Grain; these rules
/// stay testable.
public enum RecordingRingModel {
    /// A conversation never completes — the ring holds mid-band while recording.
    public static let order: Double = 0.35

    /// Live meter level → ring energy. Paused is a near-still shimmer (0.03),
    /// never dead (the instrument is alive, not broken).
    public static func energy(meterLevel: Double, paused: Bool) -> Double {
        guard !paused else { return 0.03 }
        return min(1.0, max(0.05, meterLevel))
    }
}

/// A long recording earns a provisional name partway through, from what has
/// actually been said. Pure function of the transcript HEAD, so the name never
/// rewrites itself as the conversation grows (no layout jumping).
public enum ProvisionalLiveTitle {
    /// Words required before a name is offered (a couple of words is not a name).
    public static let minimumWords = 8
    /// Words the name keeps from the head.
    public static let titleWords = 6

    public static func title(from transcript: String) -> String? {
        let words = transcript.split(separator: " ").map(String.init)
        guard words.count >= minimumWords else { return nil }
        return words.prefix(titleWords).joined(separator: " ") + "…"
    }
}

/// The recording pill's visibility. While the full-screen recording surface is
/// MINIMIZED the pill is the ONLY way back, so it shows on EVERY screen (including the
/// capture tab). Otherwise the original rule holds: show only when recording away from
/// the capture page (the capture page IS the instrument). When recording and NOT
/// minimized the full-screen cover is up and paints over the pill regardless.
public enum RecordingPillState {
    public static func visible(recordingActive: Bool, onCaptureTab: Bool,
                               minimized: Bool = false) -> Bool {
        recordingActive && (minimized || !onCaptureTab)
    }
}
