// AudioLevel — the cheap phone-side audio-level signal that powers BOTH the live
// meter (req 8) and silence-gap auto-segmentation (req 9), from a SINGLE source of
// truth so the bars the user sees and the boundaries the segmenter draws are the
// same signal.
//
// Why frame-size, not a full Opus→PCM decode: Omi streams Opus with VBR + DTX, so
// frame *byte size* already tracks audio energy — silence/DTX comfort-noise frames
// are a handful of bytes, speech frames are much larger. That gives a useful 0…1
// level for free, keeps the phone thin (the spec's "no decode on the phone";
// authoritative STT decodes server-side from the forwarded raw Opus), pulls in no
// native libopus dependency, and stays pure-Swift so the segmenter is unit-tested
// door-free on macOS. `opusFrameLevel` is the one swappable seam: a real
// swift-opus RMS decode can replace it later without touching the meter or
// segmenter.

import Foundation

/// Map one Opus frame to a 0…1 audio level from its byte size (VBR/DTX proxy).
/// Tiny DTX/silence frames → ~0; full speech frames → ~1.
public func opusFrameLevel(_ frame: Data) -> Float {
    // Below `silenceBytes` is comfort-noise / DTX; at/above `voiceBytes` is a full
    // speech frame. Tuned to Omi's typical 16 kHz Opus framing; clamped to 0…1.
    let silenceBytes = 10.0
    let voiceBytes = 80.0
    let v = (Double(frame.count) - silenceBytes) / (voiceBytes - silenceBytes)
    return Float(min(1.0, max(0.0, v)))
}

/// A boundary the segmenter draws in the continuous ambient stream.
public enum SegmentEvent: Equatable, Sendable {
    case opened   // first voice after idle → a conversation begins
    case closed   // silence has exceeded the gap → the conversation ends
}

/// Silence-gap auto-segmentation (req 9, à la Omi). Fed the same per-frame level
/// that drives the meter; when voice has been quiet for longer than `silenceGap`
/// it emits `.closed` (the owner rotates to a new conversation). The first voice
/// after a close emits `.opened`. Pure + clock-injectable so it's deterministically
/// testable without sleeping out a real 2-minute gap.
public final class SilenceSegmenter: @unchecked Sendable {
    /// Quiet span (seconds) that ends a conversation. User-configurable (default ~2m).
    public var silenceGap: TimeInterval
    /// Levels below this count as silence.
    public var silenceThreshold: Float

    private enum State { case idle, open }
    private var state: State = .idle
    private var lastVoice: TimeInterval?

    public init(silenceGap: TimeInterval = 120, silenceThreshold: Float = 0.08) {
        self.silenceGap = silenceGap
        self.silenceThreshold = silenceThreshold
    }

    /// Feed one frame's `level` observed at time `t` (seconds, monotonic). Returns a
    /// boundary event, or nil if the conversation state is unchanged.
    public func observe(level: Float, at t: TimeInterval) -> SegmentEvent? {
        if level >= silenceThreshold {            // voice
            lastVoice = t
            if state == .idle { state = .open; return .opened }
            return nil
        }
        // silence: close only if we were mid-conversation and the gap is exceeded
        if state == .open, let lv = lastVoice, (t - lv) >= silenceGap {
            state = .idle
            return .closed
        }
        return nil
    }

    /// Back to "no conversation open" (fresh stream / device reconnect).
    public func reset() { state = .idle; lastVoice = nil }

    /// Bump the voice baseline without changing open/closed state — used after a
    /// deliberate pause so the paused interval isn't mistaken for a silence gap.
    public func noteActive(at t: TimeInterval) { lastVoice = t }
}

/// Thread-safe peak-level mailbox between the off-main frame path and the main-thread
/// meter timer. The frame callback records levels (no main hop per frame); the timer
/// drains the peak ~12×/s to drive the bars.
final class LevelBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    func record(_ v: Float) { lock.lock(); if v > peak { peak = v }; lock.unlock() }
    func drainPeak() -> Float { lock.lock(); let p = peak; peak = 0; lock.unlock(); return p }
}
