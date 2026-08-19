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

    func testEachTierGetsItsOwnLabelsAndNoOthers() {
        // Phone-only tier: there is NO second place — segments are durable on the phone —
        // so "saved to computer" / generic "transcribing" would be a lie.
        XCTAssertEqual(ConversationProgress.savedToComputer.label(destination: .phone), "Saved on phone")
        XCTAssertEqual(ConversationProgress.transcribing.label(destination: .phone), "Transcribing on this phone…")
        // Computer-brain tier keeps the desktop vocabulary.
        XCTAssertEqual(ConversationProgress.savedToComputer.label(destination: .computer), "Saved to computer")
        XCTAssertEqual(ConversationProgress.transcribing.label(destination: .computer), "Transcribing…")
        // THE CELL IS ITS OWN TIER — this is the line the Bool could not express, and the
        // reason a Vault owner's chip used to say "Saved to computer".
        XCTAssertEqual(ConversationProgress.savedToComputer.label(destination: .vault), "Saved to your Vault")
        XCTAssertNotEqual(ConversationProgress.savedToComputer.label(destination: .vault),
                          ConversationProgress.savedToComputer.label(destination: .computer))
        // Shared labels are tier-agnostic — they name no place, so they cannot name a wrong one.
        for destination in CaptureDestination.allCases {
            XCTAssertEqual(ConversationProgress.recording.label(destination: destination), "Taking a note")
            XCTAssertEqual(ConversationProgress.ready.label(destination: destination), "Ready")
            XCTAssertEqual(ConversationProgress.savedOnPhone.label(destination: destination), "Saved on phone")
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

    /// THE CONVENIENCE THAT DEFAULTED TO A COMPUTER IS GONE. This read
    /// `ConversationProgress.savedToComputer.label` — a property whose body was
    /// `label(local: false)`, i.e. a chip that named a Mac chosen by nobody. Every call
    /// site now says which tier it means.
    func testLabelsAreCalm() {
        XCTAssertEqual(ConversationProgress.recording.label(destination: .computer), "Taking a note")
        XCTAssertEqual(ConversationProgress.savedOnPhone.label(destination: .computer), "Saved on phone")
        XCTAssertEqual(ConversationProgress.savedToComputer.label(destination: .computer), "Saved to computer")
        XCTAssertEqual(ConversationProgress.transcribing.label(destination: .computer), "Transcribing…")
        XCTAssertEqual(ConversationProgress.ready.label(destination: .computer), "Ready")
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
        XCTAssertEqual(Step.saved.label(destination: .computer), "Saved to computer")
        XCTAssertEqual(Step.saved.label(destination: .phone), "Saved on phone")
        XCTAssertEqual(Step.saved.label(destination: .vault), "Saved to your Vault")
        XCTAssertEqual(Step.transcribing.label(destination: .phone), "Transcribing on phone")
        // THE POPULATION, not three remembered spellings: every step, every tier, and no
        // two tiers sharing a sentence that names a place.
        for step in Step.allCases {
            let byTier = CaptureDestination.allCases.map { step.label(destination: $0) }
            XCTAssertFalse(byTier.contains(where: \.isEmpty))
            if byTier.contains(where: { $0.localizedCaseInsensitiveContains("computer") }) {
                XCTAssertNotEqual(step.label(destination: .vault),
                                  step.label(destination: .computer),
                                  "the \(step) step gives the Vault the computer's words")
            }
        }
    }
}
