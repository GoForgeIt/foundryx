import XCTest
import Foundation
@testable import FoundryXKit

/// The calm processing chip (track 20260626): `ConversationProgress.resolve` folds the
/// local WAL sync stage + the door pipeline stage into one ordered, user-legible
/// progression so the user can SEE motion instead of a flat "Saved".
final class ConversationProgressTests: XCTestCase {

    private func resolve(_ wal: CaptureStage, streaming: Bool = false,
                         door: CaptureLifecycleStage = .stored,
                         hasTitle: Bool = false, cached: Bool = false) -> ConversationProgress {
        ConversationProgress.resolve(wal: wal, streaming: streaming, door: door,
                                     hasTitle: hasTitle, hasCachedTranscript: cached)
    }

    func testRecordingWhileStreaming() {
        XCTAssertEqual(resolve(.recording, streaming: true), .recording)
        XCTAssertEqual(resolve(.savedOnPhone, streaming: true), .recording,
                       "a segment flushed mid-stream still reads as Recording")
    }

    func testSavedOnPhoneThenComputer() {
        XCTAssertEqual(resolve(.savedOnPhone, streaming: false), .savedOnPhone)
        XCTAssertEqual(resolve(.savedToComputer, door: .stored), .savedToComputer)
    }

    func testPhoneTierLabelsNeverSayComputer() {
        // Phone-only tier: there is NO computer — segments are durable on the phone —
        // so "saved to computer" / generic "transcribing" would be a lie.
        XCTAssertEqual(ConversationProgress.savedToComputer.label(local: true), "Saved on phone")
        XCTAssertEqual(ConversationProgress.transcribing.label(local: true), "Transcribing on this phone…")
        // Computer-brain tier keeps the desktop vocabulary.
        XCTAssertEqual(ConversationProgress.savedToComputer.label(local: false), "Saved to computer")
        XCTAssertEqual(ConversationProgress.transcribing.label(local: false), "Transcribing…")
        // Shared labels are brain-agnostic.
        for local in [true, false] {
            XCTAssertEqual(ConversationProgress.recording.label(local: local), "Recording")
            XCTAssertEqual(ConversationProgress.ready.label(local: local), "Ready")
            XCTAssertEqual(ConversationProgress.savedOnPhone.label(local: local), "Saved on phone")
        }
    }

    func testDoorPipelineProgression() {
        XCTAssertEqual(resolve(.savedToComputer, door: .transcribing), .transcribing)
        // in_lore but not yet transcribed reads as Transcribing… (something IS happening).
        XCTAssertEqual(resolve(.savedToComputer, door: .inLore, hasTitle: false), .transcribing)
        // …and as Ready once a Kiln title exists.
        XCTAssertEqual(resolve(.savedToComputer, door: .inLore, hasTitle: true), .ready)
        XCTAssertEqual(resolve(.savedToComputer, door: .transcribed), .ready)
        XCTAssertEqual(resolve(.savedToComputer, door: .organized), .ready)
        XCTAssertEqual(resolve(.savedToComputer, door: .failed), .failed)
    }

    func testCachedTranscriptIsAlwaysReady() {
        // A cached transcript is the strongest signal — even a pruned capture (whose
        // WAL now reports "recording" because its audio is gone) reads as Ready.
        XCTAssertEqual(resolve(.recording, cached: true), .ready)
        XCTAssertEqual(resolve(.savedToComputer, door: .stored, cached: true), .ready)
    }

    func testLabelsAreCalm() {
        XCTAssertEqual(ConversationProgress.recording.label, "Recording")
        XCTAssertEqual(ConversationProgress.savedOnPhone.label, "Saved on phone")
        XCTAssertEqual(ConversationProgress.savedToComputer.label, "Saved to computer")
        XCTAssertEqual(ConversationProgress.transcribing.label, "Transcribing…")
        XCTAssertEqual(ConversationProgress.ready.label, "Ready")
        XCTAssertTrue(ConversationProgress.failed.needsRetry)
    }

    // MARK: - stepper step states (the visible "where is this" progress)

    private typealias Step = ConversationProgress.Step

    func testTranscribingStepperMarksPastDoneCurrentActiveFutureAhead() {
        let p = ConversationProgress.transcribing
        XCTAssertEqual(p.state(of: .recorded), .done)
        XCTAssertEqual(p.state(of: .saved), .done)
        XCTAssertEqual(p.state(of: .transcribing), .active)
        XCTAssertEqual(p.state(of: .ready), .pending)
    }

    func testReadyStepperIsAllDone() {
        for step in Step.allCases {
            XCTAssertEqual(ConversationProgress.ready.state(of: step), .done)
        }
    }

    func testFailedStepperMarksTranscribingFailed() {
        let p = ConversationProgress.failed
        XCTAssertEqual(p.state(of: .recorded), .done)
        XCTAssertEqual(p.state(of: .saved), .done)
        XCTAssertEqual(p.state(of: .transcribing), .failed)
        XCTAssertEqual(p.state(of: .ready), .pending)
    }

    func testSavedOnPhoneStepperIsOnTheSavedStep() {
        let p = ConversationProgress.savedOnPhone
        XCTAssertEqual(p.state(of: .recorded), .done)
        XCTAssertEqual(p.state(of: .saved), .active)
        XCTAssertEqual(p.state(of: .transcribing), .pending)
    }

    func testStepLabelsAreTierHonest() {
        XCTAssertEqual(Step.saved.label(local: false), "Saved to computer")
        XCTAssertEqual(Step.saved.label(local: true), "Saved on phone")
        XCTAssertEqual(Step.transcribing.label(local: true), "Transcribing on phone")
    }
}
