// CaptureActivityAttributes — the ActivityKit contract for the capture Live Activity
// (lock-screen banner + Dynamic Island). SHARED source: compiled into BOTH the app
// target (which requests/updates/ends the activity via `Activity`) and the widget
// extension (which renders it via `ActivityConfiguration`). It carries the smallest
// slice of CaptureManager state that the Live Activity UI needs — NOT the whole
// capture model — so a per-state-change update stays tiny.
//
// ActivityKit landed in iOS 16.1; the app's deployment target is 16.0, so every use
// site is `@available(iOS 16.1, *)`-guarded.

import Foundation

/// The three DISTINCT capture phases the Live Activity renders — the fix for the
/// "in a conversation while paused/idle" bug. Derived from REAL capture activity, not
/// merely from the session/connection being armed:
///   - `.recordingActive`: voiced audio is actually being captured RIGHT NOW (recent
///     voice within the active-voice window) and not paused. Only in this phase does the
///     UI show a running elapsed timer + a live "capturing" banner.
///   - `.paused`: capture is open but the user paused it (device stays connected). No
///     running timer, no "conversation in progress".
///   - `.idle`: the source is connected/armed (a session may even be open) but NO active
///     voiced conversation is in progress — an extended silence or armed-but-idle. Shown
///     as "Listening", NOT as a live conversation with a ticking timer.
///
/// Lives here (NOT in CaptureLiveStatus.swift) because THIS file is the one compiled into
/// the widget extension, which must render the phase. Kept outside the ActivityKit guard
/// so the app + tests (macOS) can also derive/assert it.
public enum CaptureActivityPhase: String, Codable, Sendable, Hashable {
    case recordingActive
    case paused
    case idle

    /// True only while voiced audio is actively being captured — the ONLY phase that
    /// shows a running elapsed timer + "capturing" affordance.
    public var isActivelyRecording: Bool { self == .recordingActive }
}

// ActivityKit's runtime is iOS-only even though the module imports on macOS — gate on
// `os(iOS)` so the SwiftPM macOS build (tests/CI) doesn't try to resolve it.
#if canImport(ActivityKit) && os(iOS)
import ActivityKit

@available(iOS 16.1, *)
public struct CaptureActivityAttributes: ActivityAttributes {
    /// The dynamic, push-or-locally-updated slice of state the Live Activity renders.
    /// Keep this MINIMAL — ActivityKit serializes it on every update and over APNs in
    /// the (future) push path, so big payloads (transcripts, level arrays) stay out.
    public struct ContentState: Codable, Hashable {
        /// The DISTINCT capture phase: RECORDING-ACTIVE vs PAUSED vs LISTENING/IDLE. This
        /// is the fix for the "in a conversation while paused/idle" bug — it's derived
        /// from REAL voiced-capture activity (recent voice), not from the session merely
        /// being armed. Everything the UI shows keys off this, not a raw "isRecording".
        public var phase: CaptureActivityPhase
        /// True while a conversation is ACTIVELY being captured (voiced audio now). Kept
        /// as a convenience mirror of `phase == .recordingActive` for terse render sites.
        public var isRecording: Bool { phase == .recordingActive }
        /// True while capture is open but the user paused it (device stays connected).
        public var isPaused: Bool { phase == .paused }
        /// Human source label for the banner ("Omi" / "Phone").
        public var sourceLabel: String
        /// SF Symbol for the active source (drives the compact/minimal icon).
        public var sourceSymbol: String
        /// Wall-clock instant the CURRENT active-voice run began — the UI derives a live
        /// elapsed timer from this (`Text(timerInterval:)`) so it ticks WITHOUT a
        /// per-second activity update. ONLY set while `.recordingActive`: nil when paused
        /// or listening, so the timer never runs during silence or while armed-but-idle
        /// (the bug). Re-anchored when voice resumes after a silence lull.
        public var startedAt: Date?
        /// A COARSE, stepped level 0…3 (a few discrete bars) for the live indicator —
        /// updated ~1×/sec, NEVER at audio-frame rate (Live Activities are snapshot-
        /// rendered; frame-rate updates are throttled + battery-costly). nil when not
        /// actively recording.
        public var levelStep: Int?
        /// The latest live transcript line(s) for the ACTIVE conversation, already
        /// TRUNCATED for the small surfaces. Empty when not recording / unavailable — the
        /// UI then shows nothing extra. Throttled (~1–2s / on segment finalize), NEVER at
        /// audio-frame rate.
        public var transcriptLine: String
        /// The most-recently FINISHED conversation's display title (shown when idle).
        public var lastFinishedTitle: String?
        /// When that last conversation finished — drives a relative-time string.
        public var lastFinishedAt: Date?

        public init(phase: CaptureActivityPhase = .idle,
                    sourceLabel: String = "Phone",
                    sourceSymbol: String = "mic.fill",
                    startedAt: Date? = nil,
                    levelStep: Int? = nil,
                    transcriptLine: String = "",
                    lastFinishedTitle: String? = nil,
                    lastFinishedAt: Date? = nil) {
            self.phase = phase
            self.sourceLabel = sourceLabel
            self.sourceSymbol = sourceSymbol
            self.startedAt = startedAt
            self.levelStep = levelStep
            self.transcriptLine = transcriptLine
            self.lastFinishedTitle = lastFinishedTitle
            self.lastFinishedAt = lastFinishedAt
        }
    }

    /// Static (per-activity) attributes. Capture has none that vary per activity today;
    /// a stable marker keeps the type non-empty + future-proof.
    public var kind: String

    public init(kind: String = "foundryx.capture") {
        self.kind = kind
    }
}
#endif
