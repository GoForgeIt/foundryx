// CaptureLiveStatus — pure projection helpers that turn the CaptureManager's live
// state into the small slices the Live Activity + home-screen widget render. Kept pure
// (no SwiftUI, no ActivityKit) so the source-label / last-finished derivation is shared
// between the Live Activity ContentState and the App-Group widget snapshot, and is
// unit-testable without UI.

import Foundation

public enum CaptureLiveStatus {
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
