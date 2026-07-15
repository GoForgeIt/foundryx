/// The small, UI-free slice the ambient recording pill renders. Reusing the
/// Live Activity's indicator tint keeps both surfaces on the same phase semantics.
public struct RecordingPillPresentation: Equatable, Sendable {
    public let word: String
    public let tone: CaptureIndicatorTint

    public static func make(from phase: CaptureActivityPhase) -> RecordingPillPresentation {
        switch phase {
        case .idle:
            return RecordingPillPresentation(word: "Listening", tone: .neutral)
        case .recordingActive:
            return RecordingPillPresentation(word: "Recording", tone: .recording)
        case .paused:
            return RecordingPillPresentation(word: "Paused", tone: .paused)
        }
    }
}
