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
        /// True while a conversation is actively being captured (and not paused).
        public var isRecording: Bool
        /// True while capture is open but the user paused it (device stays connected).
        public var isPaused: Bool
        /// Human source label for the banner ("Omi" / "Phone").
        public var sourceLabel: String
        /// SF Symbol for the active source (drives the compact/minimal icon).
        public var sourceSymbol: String
        /// Wall-clock instant the active conversation started — the UI derives a live
        /// elapsed timer from this (`Text(timerInterval:)`) so it ticks WITHOUT a
        /// per-second activity update.
        public var startedAt: Date?
        /// A coarse 0…1 level for the live indicator (throttled — updated every few
        /// seconds, NEVER at audio frame rate). nil when not recording.
        public var level: Double?
        /// The most-recently FINISHED conversation's display title (shown when idle).
        public var lastFinishedTitle: String?
        /// When that last conversation finished — drives a relative-time string.
        public var lastFinishedAt: Date?

        public init(isRecording: Bool = false,
                    isPaused: Bool = false,
                    sourceLabel: String = "Phone",
                    sourceSymbol: String = "mic.fill",
                    startedAt: Date? = nil,
                    level: Double? = nil,
                    lastFinishedTitle: String? = nil,
                    lastFinishedAt: Date? = nil) {
            self.isRecording = isRecording
            self.isPaused = isPaused
            self.sourceLabel = sourceLabel
            self.sourceSymbol = sourceSymbol
            self.startedAt = startedAt
            self.level = level
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
