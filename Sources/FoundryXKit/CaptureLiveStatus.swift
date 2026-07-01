// CaptureLiveStatus — pure projection helpers that turn the CaptureManager's live
// state into the small slices the Live Activity + home-screen widget render. Kept pure
// (no SwiftUI, no ActivityKit) so the source-label / last-finished derivation is shared
// between the Live Activity ContentState and the App-Group widget snapshot, and is
// unit-testable without UI.

import Foundation

// NOTE: `CaptureActivityPhase` (the RECORDING-ACTIVE / PAUSED / IDLE enum) lives in
// CaptureActivityAttributes.swift — the file SHARED into the widget extension — because
// the widget must render the phase. The *derivation* helpers below stay app-side (the
// widget only ever receives an already-computed phase).

public enum CaptureLiveStatus {
    /// The active-voice window (seconds): a capture is `.recordingActive` only while
    /// voiced audio was heard within this recent span. Past it — during an extended
    /// silence while the Omi stays armed — the phase drops to `.idle` (LISTENING), so the
    /// Live Activity stops claiming an in-progress conversation + freezes the timer. Kept
    /// well below the 120s silence-gap that CLOSES a conversation: the conversation stays
    /// open (segmentation is unchanged), but the *live indicator* reflects real voice.
    /// Tunable.
    public static let activeVoiceWindow: TimeInterval = 12

    /// Pure phase derivation — the single source of truth for RECORDING-ACTIVE vs PAUSED
    /// vs IDLE, shared by the Live Activity ContentState and the widget snapshot and
    /// unit-tested without any UI. `hasActiveSession` = a capture WAL is open;
    /// `isPaused` = the user paused; `lastVoicedAt`/`now` gate the recent-voice window.
    public static func phase(hasActiveSession: Bool,
                             isPaused: Bool,
                             lastVoicedAt: TimeInterval?,
                             now: TimeInterval,
                             window: TimeInterval = activeVoiceWindow) -> CaptureActivityPhase {
        if isPaused && hasActiveSession { return .paused }
        guard hasActiveSession else { return .idle }
        guard let voiced = lastVoicedAt, now - voiced <= window else { return .idle }
        return .recordingActive
    }

    /// The number of discrete steps in the coarse level bar (0…`levelSteps`). A few bars,
    /// NOT a smooth VU meter — Live Activities are snapshot-rendered and frame-rate updates
    /// are throttled + battery-costly, so the level is a low-frequency pulse.
    public static let levelSteps = 3

    /// Map a 0…1 level onto a COARSE 0…`levelSteps` bucket for the stepped bar. Clamped;
    /// rounds so mid-level reads as a middle bar. Updated ~1×/sec, never at frame rate.
    public static func levelStep(fromLevel level: Double) -> Int {
        let clamped = Swift.min(1, Swift.max(0, level))
        return Int((clamped * Double(levelSteps)).rounded())
    }

    /// Character budget for the truncated transcript on each surface.
    public static let transcriptCharsLockScreen = 90
    public static let transcriptCharsExpanded = 64

    /// Truncate a live transcript for the small Live Activity surfaces: keep the TAIL
    /// (the newest words — what's being said now) up to `maxChars`, collapse whitespace,
    /// and prefix an ellipsis when clipped. Empty in → empty out (UI shows nothing extra).
    public static func truncatedTranscript(_ text: String, maxChars: Int) -> String {
        let collapsed = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .joined(separator: " ")
        guard collapsed.count > maxChars else { return collapsed }
        let tail = String(collapsed.suffix(max(0, maxChars - 1)))
        return "…" + tail
    }
    /// Human label for the active capture source ("Omi" / "Phone").
    public static func sourceLabel(source: CaptureSourceKind, isRecordingMic: Bool) -> String {
        if isRecordingMic { return "Phone" }
        switch source {
        case .omi:      return "Omi"
        case .phoneMic: return "Phone"
        }
    }

    /// SF Symbol for the active capture source.
    public static func sourceSymbol(source: CaptureSourceKind, isRecordingMic: Bool) -> String {
        if isRecordingMic { return "mic.fill" }
        switch source {
        case .omi:      return "antenna.radiowaves.left.and.right"
        case .phoneMic: return "mic.fill"
        }
    }
}
