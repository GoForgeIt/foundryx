import XCTest
import Foundation
import FoundryXKit

/// Chat surfaces + artifacts (features/chat-answer-and-artifacts.feature, track
/// 20260713T0906): the ambient-answer surface model (feedback that starts
/// unselected, "sources consulted" semantics, continue-in-chat seeding), the
/// agent-run legibility pieces (step tiles, the >4-step fold, the hosted-venue
/// line), and the artifact pipeline (type detection + the ArtifactSource seam
/// driven by a test double over the door file-route pattern).
final class ChatAnswerArtifactsTests: XCTestCase {

    // MARK: - Answer surface

    private func sampleAnswer() -> AmbientAnswer {
        AmbientAnswer(
            title: "The relay decision",
            text: "You chose the blind Noise relay over LAN-only on June 30.",
            sources: [
                AnswerSource(title: "Architecture call", dateLabel: "Jun 30"),
                AnswerSource(title: "Relay follow-up", dateLabel: "Jul 2"),
            ])
    }

    // Scenario: an ambient answer opens with the answer and its sources
    func testAnswerCarriesTextAndSources() {
        let answer = sampleAnswer()
        XCTAssertFalse(answer.text.isEmpty)
        XCTAssertEqual(answer.sources.count, 2)
        XCTAssertEqual(answer.sources[0].chipText, "Architecture call · Jun 30")
    }

    // Scenario: an ambient answer opens with the answer and its sources
    // ("the surface never calls them citations")
    func testAnswerCopySaysSourcesConsultedNeverCitations() {
        XCTAssertTrue(AnswerCopy.sourcesLabel.lowercased().contains("sources consulted"),
                      "the chips row is 'sources consulted' semantics")
        for line in AnswerCopy.all {
            XCTAssertFalse(line.lowercased().contains("citation"),
                           "answer-surface copy must never say 'citations': \(line)")
        }
    }

    // Scenario: answer feedback starts unselected
    func testFeedbackStartsUnselected() {
        let feedback = AnswerFeedback()
        XCTAssertEqual(feedback.rating, AnswerRating.none,
                       "the system never rates itself — toggles start unselected")
        XCTAssertEqual(feedback.note, "")
    }

    // Scenario: tapping a feedback toggle selects it and tapping again clears it
    func testToggleSelectsAndReTapClears() {
        var feedback = AnswerFeedback()
        feedback.toggle(.helpful)
        XCTAssertEqual(feedback.rating, .helpful)
        feedback.toggle(.helpful)
        XCTAssertEqual(feedback.rating, AnswerRating.none, "re-tap deselects")
    }

    // Scenario: switching feedback replaces the prior choice
    func testSwitchingFeedbackReplacesPriorChoice() {
        var feedback = AnswerFeedback()
        feedback.toggle(.helpful)
        feedback.toggle(.notUseful)
        XCTAssertEqual(feedback.rating, .notUseful)
    }

    // Scenario: I can attach a note to an answer
    func testNoteIsKeptWithFeedback() {
        var feedback = AnswerFeedback()
        feedback.note = "also pull the cost comparison"
        feedback.toggle(.helpful)
        XCTAssertEqual(feedback.note, "also pull the cost comparison")
    }

    // Scenario: continuing in chat seeds a session with the answer
    func testContinueInChatSeedCarriesTheAnswer() {
        let answer = sampleAnswer()
        let seed = answer.chatSeed()
        XCTAssertTrue(seed.contains(answer.text), "the session is seeded with the answer")
        XCTAssertTrue(seed.contains(answer.title))
    }

    // Scenario: continuing in chat seeds a session with the answer
    // ("my note rides along when I wrote one")
    func testContinueInChatSeedIncludesTheNote() {
        let answer = sampleAnswer()
        XCTAssertTrue(answer.chatSeed(note: "check the cost side too")
            .contains("check the cost side too"))
        XCTAssertFalse(answer.chatSeed(note: "   ").contains("note"),
                       "a blank note adds nothing")
    }

    // MARK: - Agent-run legibility

    // Scenario: run steps appear as tiles as they happen
    func testStepTileFromRunningActivityHasNoOutcomeYet() {
        let running = ChatViewModel.ToolActivity(
            id: "c1", name: "bash", args: #"{"command":"ls -la"}"#)
        let tile = RunStepTile(activity: running)
        XCTAssertTrue(tile.title.contains("ls -la"), "the tile names the tool action")
        XCTAssertNil(tile.outcome, "no outcome until the step finishes")
        XCTAssertTrue(tile.isRunning)
    }

    // Scenario: run steps appear as tiles as they happen
    // ("once the step finishes the tile carries a one-line outcome")
    func testStepTileCarriesOneLineOutcome() {
        let done = ChatViewModel.ToolActivity(
            id: "c2", name: "bash", args: #"{"command":"ls"}"#,
            resultContent: "total 4\ndrwxr-xr-x  2 nick staff\n-rw-r--r--  1 nick staff")
        let tile = RunStepTile(activity: done)
        XCTAssertEqual(tile.outcome, "total 4", "the outcome is one line")
        XCTAssertFalse(tile.isRunning)
    }

    func testOutcomeLineSkipsBlanksAndCapsLength() {
        XCTAssertEqual(RunStepTile.outcomeLine("\n\n  first real line\nsecond"),
                       "first real line")
        XCTAssertEqual(RunStepTile.outcomeLine(""), "done",
                       "an empty result still reads as a finished step")
        let long = String(repeating: "x", count: 300)
        let capped = RunStepTile.outcomeLine(long)
        XCTAssertNotNil(capped)
        XCTAssertLessThanOrEqual(capped!.count, 121)
        XCTAssertTrue(capped!.hasSuffix("…"))
    }

    // Scenario: long runs fold their older steps
    func testSevenStepsFoldThreeBehindLabel() {
        let layout = RunStepFold.layout(stepCount: 7)
        XCTAssertEqual(layout.foldedCount, 3)
        XCTAssertEqual(layout.visible, 3..<7, "the four most recent steps stay visible")
        XCTAssertEqual(layout.foldLabel, "3 more steps")
    }

    // Scenario: short runs show every step unfolded
    func testFourOrFewerStepsNeverFold() {
        for n in 0...4 {
            let layout = RunStepFold.layout(stepCount: n)
            XCTAssertEqual(layout.foldedCount, 0, "\(n) steps must not fold")
            XCTAssertEqual(layout.visible, 0..<n)
            XCTAssertNil(layout.foldLabel)
        }
    }

    func testFiveStepsFoldExactlyOneWithSingularLabel() {
        let layout = RunStepFold.layout(stepCount: 5)
        XCTAssertEqual(layout.foldedCount, 1)
        XCTAssertEqual(layout.foldLabel, "1 more step")
    }

    // Scenario: hosted runs say where they run
    func testHostedRunStatesVenueAndTrialPlainly() {
        XCTAssertEqual(RunVenue.hostedLine(run: 1, of: 10, venue: "Foundry Cloud"),
                       "Run 1 of 10 · runs on Foundry Cloud")
        XCTAssertEqual(RunVenue.hostedLine(run: 9, of: 10, venue: "Foundry Cloud"),
                       "Run 9 of 10 · runs on Foundry Cloud")
    }

    // Scenario: a finished run shows findings and takes a follow-up
    // (the findings text is the run's final assistant message — pin that the
    //  view model exposes it once a turn completes, same session continuing)
    func testFinishedRunExposesFindingsFromTheViewModel() {
        let model = ChatViewModel()
        model.beginUserTurn("remind me to send Sarah the deck Friday")
        model.apply(.toolCall(callId: "t1", name: "bash", args: #"{"command":"cal"}"#))
        model.apply(.toolResult(callId: "t1", content: "Fri free at 9:00", isError: false))
        model.apply(.assistantDelta(text: "Done. Reminder set for Friday 9:00."))
        model.apply(.done(reason: "end_turn"))
        XCTAssertEqual(model.turnState, .completed(reason: "end_turn"))
        XCTAssertTrue(model.assistantText.contains("Reminder set"),
                      "the findings summary is there to render")
    }

    // MARK: - Artifact type detection

    // Scenario: a Markdown file from a run renders in-app
    func testMarkdownDetection() {
        XCTAssertEqual(ArtifactKind.detect(filename: "report.md"), .markdown)
        XCTAssertEqual(ArtifactKind.detect(filename: "REPORT.MARKDOWN"), .markdown)
        XCTAssertEqual(ArtifactKind.detect(filename: "download", mime: "text/markdown"),
                       .markdown, "mime decides when the name has no extension")
    }

    // Scenario: an HTML file from a run renders in-app
    func testHTMLDetection() {
        XCTAssertEqual(ArtifactKind.detect(filename: "page.html"), .html)
        XCTAssertEqual(ArtifactKind.detect(filename: "page.htm"), .html)
        XCTAssertEqual(ArtifactKind.detect(filename: "blob", mime: "text/html"), .html)
    }

    // Scenario: an image from a run renders in-app
    func testImageDetection() {
        for name in ["chart.png", "photo.JPG", "pic.jpeg", "anim.gif",
                     "img.webp", "shot.heic"] {
            XCTAssertEqual(ArtifactKind.detect(filename: name), .image, name)
        }
        XCTAssertEqual(ArtifactKind.detect(filename: "raw", mime: "image/png"), .image)
    }

    // Scenario: unsupported files say so honestly and offer export
    func testUnknownTypesAreUnsupported() {
        XCTAssertEqual(ArtifactKind.detect(filename: "data.csv"), .unsupported)
        XCTAssertEqual(ArtifactKind.detect(filename: "doc.pdf"), .unsupported)
        XCTAssertEqual(ArtifactKind.detect(filename: "mystery"), .unsupported)
        XCTAssertEqual(ArtifactKind.detect(filename: "blob", mime: "application/pdf"),
                       .unsupported)
    }

    func testKnownExtensionWinsOverMime() {
        XCTAssertEqual(ArtifactKind.detect(filename: "notes.md", mime: "application/octet-stream"),
                       .markdown)
        XCTAssertEqual(ArtifactKind.detect(filename: "chart.png?ts=1"), .image,
                       "a query string doesn't hide the extension")
    }

    // MARK: - ArtifactSource seam (door file route pattern, test double)

    /// Test double for the door file route — the seam production fills with
    /// DoorArtifactSource (same relay-aware GET pattern as capture transcript/audio).
    private struct StubArtifactSource: ArtifactSource {
        let data: Data?
        let error: Bool
        func fetchArtifact(path: String) async throws -> Data? {
            if error { throw DoorError.transport("tunnel down") }
            return data
        }
    }

    // Scenario: a Markdown file from a run renders in-app (fetch leg)
    func testLoaderFetchesAndClassifiesThroughTheSeam() async {
        let md = Data("# Findings\n\nFriday is packed.".utf8)
        let state = await ArtifactLoader.load(
            path: "/foundryx/files/run-42/findings.md",
            from: StubArtifactSource(data: md, error: false))
        guard case .loaded(let artifact) = state else {
            return XCTFail("expected .loaded, got \(state)")
        }
        XCTAssertEqual(artifact.kind, .markdown)
        XCTAssertEqual(artifact.filename, "findings.md",
                       "the filename comes off the door path")
        XCTAssertEqual(artifact.data, md, "bytes round-trip untouched")
    }

    // Scenario: a missing artifact is reported honestly
    func testMissingArtifactIsUnavailableNotAnError() async {
        let state = await ArtifactLoader.load(
            path: "/foundryx/files/run-42/gone.md",
            from: StubArtifactSource(data: nil, error: false))
        XCTAssertEqual(state, .unavailable, "a 404 (nil) is 'not available', not a failure")
    }

    func testTransportFailureSurfacesAsFailedWithDetail() async {
        let state = await ArtifactLoader.load(
            path: "/foundryx/files/run-42/findings.md",
            from: StubArtifactSource(data: nil, error: true))
        guard case .failed = state else {
            return XCTFail("expected .failed, got \(state)")
        }
    }

    func testLoaderRespectsExplicitFilenameAndMime() async {
        let state = await ArtifactLoader.load(
            path: "/foundryx/files/run-7/blob",
            filename: "chart",
            mime: "image/png",
            from: StubArtifactSource(data: Data([0x89]), error: false))
        guard case .loaded(let artifact) = state else {
            return XCTFail("expected .loaded, got \(state)")
        }
        XCTAssertEqual(artifact.kind, .image)
    }
}
