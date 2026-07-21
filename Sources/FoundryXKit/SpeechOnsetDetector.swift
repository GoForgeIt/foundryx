/// Decides when an AMBIENT listening window has heard enough real speech to open a
/// conversation — so the Omi can stay connected and "Listening" without minting an
/// empty "Untitled conversation" for every stretch of silence or one-off noise.
///
/// Fed one per-frame voiced/silent decision (the SAME `level >= silenceThreshold`
/// the segmenter uses). It fires ONCE, when a run of voiced frames — tolerating the
/// brief dips inside natural speech — crosses `framesToOpen`. An isolated transient
/// (a door slam, a cough, a chair scrape: a handful of voiced frames then quiet)
/// decays back below the bar and never opens a conversation.
///
/// Pure + value-typed so it's deterministically testable without audio. The onset is
/// backfilled by the router's pre-roll ring, so nothing said before the gate trips is
/// lost from the recording.
public struct SpeechOnsetDetector: Equatable, Sendable {
    /// Voiced frames a run must reach to declare speech. ~10 ≈ 0.2 s at the Omi's
    /// ~50 frames/s — above any percussive transient, below the shortest real word.
    public static let defaultFramesToOpen = 10
    /// Consecutive SILENT frames that decay the voiced run back to zero. ~20 ≈ 0.4 s —
    /// long enough to bridge the micro-gaps inside a phrase, short enough that a brief
    /// noise burst followed by quiet resets instead of accumulating toward an onset.
    public static let defaultResetAfterSilentFrames = 20

    public let framesToOpen: Int
    public let resetAfterSilentFrames: Int

    private var voicedRun = 0
    private var silentRun = 0
    private var fired = false

    public init(framesToOpen: Int = SpeechOnsetDetector.defaultFramesToOpen,
                resetAfterSilentFrames: Int = SpeechOnsetDetector.defaultResetAfterSilentFrames) {
        self.framesToOpen = framesToOpen
        self.resetAfterSilentFrames = resetAfterSilentFrames
    }

    /// Feed one frame's voiced/silent decision. Returns `true` exactly once — on the
    /// frame the accumulated voiced run first crosses `framesToOpen`. Stays `true`-free
    /// afterward until `reset()` re-arms it for the next listening window.
    public mutating func observe(voiced: Bool) -> Bool {
        if fired { return false }
        if voiced {
            voicedRun += 1
            silentRun = 0
        } else {
            silentRun += 1
            if silentRun >= resetAfterSilentFrames { voicedRun = 0 }
        }
        if voicedRun >= framesToOpen {
            fired = true
            return true
        }
        return false
    }

    /// Re-arm for a fresh listening window (a new conversation ended → back to Listening).
    public mutating func reset() {
        voicedRun = 0
        silentRun = 0
        fired = false
    }
}
