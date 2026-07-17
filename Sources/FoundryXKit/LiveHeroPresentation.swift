// LiveHeroPresentation — the durable decision behind the Capture tab's hero slot
// (track 20260717T0600, features/recording-instrument.feature). The recording hero
// tile IS the live tile: while a recording is active (or an ambient source is
// connected) the hero slot renders a full-hero-size live recording tile instead of the
// "Record a conversation" call to action. Pure function; CaptureScreen renders it.

import Foundation

/// Which tile the Capture tab's hero slot shows, and — for the live tile — exactly what
/// it may show. Kept pure so the surface's behavior is pinned by unit-backed scenarios
/// (the compact `recordingInstrument` strip is gone; this is the one hero slot).
public enum LiveHeroPresentation {

    /// The live recording tile's content flags. A connected source with no active WAL
    /// still gets a live tile — it just degrades (no elapsed clock, no recorder behind
    /// it), keeping the meter/status affordances the old strip provided.
    public struct LiveTile: Equatable, Sendable {
        /// An authoritative capture session start exists (`active.status.startedAt`), so
        /// the paused-aware elapsed clock is shown. False for a connected-but-idle source.
        public var showsElapsed: Bool
        /// A live recorder exists behind the tile → the tile is tappable to open the
        /// full recording screen, and the Pause/Resume control is shown.
        public var hasRecorder: Bool
        /// Whether capture is currently paused (the ring settles; the clock freezes).
        public var paused: Bool

        public init(showsElapsed: Bool, hasRecorder: Bool, paused: Bool) {
            self.showsElapsed = showsElapsed
            self.hasRecorder = hasRecorder
            self.paused = paused
        }
    }

    /// What the hero slot renders.
    public enum Slot: Equatable, Sendable {
        /// The calm "Record a conversation" call to action (not recording, no source).
        case recordCTA
        /// The full-hero-size live recording tile.
        case liveTile(LiveTile)
    }

    /// Resolve the hero slot. `isShowingCapture` is the existing gate
    /// (`sourcePresentation.isConnected || isRecordingMic`): true → the live tile owns
    /// the slot; false → the hero CTA. `hasActiveSession` is `manager.active != nil`.
    public static func slot(isShowingCapture: Bool,
                            hasActiveSession: Bool,
                            isRecordingMic: Bool,
                            isPaused: Bool) -> Slot {
        guard isShowingCapture else { return .recordCTA }
        return .liveTile(LiveTile(
            showsElapsed: hasActiveSession,
            hasRecorder: hasActiveSession || isRecordingMic,
            paused: isPaused))
    }
}
