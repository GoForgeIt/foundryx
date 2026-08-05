import XCTest
import Foundation
import FoundryXKit

/// UX prototype realignment — chat-answer lane (track 20260714T1800,
/// features/chat-answer-and-artifacts.feature). Step definitions for:
///   - "the chat composer invites the user with 'Ask FoundryX'"
///   - "a failed send reads calmly, never a code"
///   - "an answer with a recommendation renders the decision brief"
///   - "a finished agent run folds into a finding"
/// All assertions drive the REAL presentation logic the App views render
/// (ChatSendFailure / AnswerBrief / AgentRunFinding + the real ChatViewModel).
final class ChatAnswerRealignmentTests: XCTestCase {

    // MARK: - Scenario: the chat composer invites the user with "Ask FoundryX"

    func testComposerPlaceholderReadsAskFoundryX() {
        XCTAssertEqual(ChatCopy.composerPlaceholder, "Ask FoundryX")
    }

    // MARK: - Scenario: a failed send reads calmly, never a code

    // "Given my computer cannot be reached … the chat says 'Your computer
    // couldn't be reached.'"
    func testTransportFailureReadsAsUnreachableComputer() {
        XCTAssertEqual(ChatSendFailure.calmMessage(for: DoorError.transport("connect refused")),
                       "Your computer couldn't be reached.")
        let urlError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        XCTAssertEqual(ChatSendFailure.calmMessage(for: urlError),
                       "Your computer couldn't be reached.")
    }

    // "And a rejected send says 'That didn't go through — try again.'"
    //
    // 502 used to stand in for "some HTTP failure" here. It no longer can: the door
    // deliberately means something specific by 502 and 503 — it could not reach its
    // kiln-session, versus it holds none at all — and the send now says WHICH, because
    // "try again" is the wrong advice for a Kiln that isn't running
    // (features/chat-turn-always-ends.feature owns that distinction, with a scenario each).
    // A genuinely unclassified server failure is what this scenario is about, so it is
    // asserted on one: 500. The mapping's force is unchanged.
    func testRejectedSendReadsAsTryAgain() {
        XCTAssertEqual(ChatSendFailure.calmMessage(for: DoorError.http(500)),
                       "That didn't go through — try again.")
        XCTAssertEqual(ChatSendFailure.calmMessage(for: DoorError.unauthorized),
                       "That didn't go through — try again.")
        XCTAssertEqual(ChatSendFailure.emptyReply,
                       "That didn't go through — try again.")
    }

    // The two the door is specific about, asserted here as well as in the feature that owns
    // them — this file is where a future edit to `calmMessage` is most likely to be made, and
    // it should not be possible to collapse them back into "try again" without a red here.
    func testTheDoorsTwoKilnStatesReadDifferently() {
        XCTAssertEqual(ChatSendFailure.calmMessage(for: DoorError.http(503)),
                       "Kiln isn't running on your computer.")
        XCTAssertEqual(ChatSendFailure.calmMessage(for: DoorError.http(502)),
                       "Your computer couldn't reach Kiln.")
        XCTAssertNotEqual(ChatSendFailure.calmMessage(for: DoorError.http(503)),
                          ChatSendFailure.calmMessage(for: DoorError.http(502)))
    }

    // "And the thread never shows 'DoorError', 'HTTP', or a bracketed code"
    func testCalmCopyNeverLeaksACode() {
        let errors: [Error] = [
            DoorError.transport("relay: no HTTP header terminator in 90B reply"),
            DoorError.http(500),
            DoorError.unauthorized,
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
            NSError(domain: "kiln.session", code: -7),
        ]
        for error in errors {
            let calm = ChatSendFailure.calmMessage(for: error)
            for forbidden in ["DoorError", "HTTP", "[", "]", "401", "500", "code"] {
                XCTAssertFalse(calm.contains(forbidden),
                               "calm copy must never show '\(forbidden)': \(calm)")
            }
        }
    }

    // "And the technical detail goes to the door log instead"
    func testLogDetailKeepsTheEngineeringTruth() {
        XCTAssertEqual(ChatSendFailure.logDetail(for: DoorError.http(502)), "HTTP 502")
        XCTAssertEqual(ChatSendFailure.logDetail(for: DoorError.unauthorized),
                       "401 unauthorized (bad token)")
        XCTAssertEqual(ChatSendFailure.logDetail(for: DoorError.transport("connect refused")),
                       "connect refused")
        let ns = NSError(domain: "kiln.session", code: -7,
                         userInfo: [NSLocalizedDescriptionKey: "session lost"])
        XCTAssertTrue(ChatSendFailure.logDetail(for: ns).contains("[kiln.session -7]"),
                      "the domain/code detail belongs in the log")
    }

    // "When I send a message and it fails" — drive the REAL view model the way
    // ChatScreen does on a thrown turn: the calm copy lands as the turn's
    // refused reason (rendered by the thread), never a raw code.
    func testFailedTurnLandsCalmCopyInTheThread() {
        let model = ChatViewModel()
        model.beginUserTurn("compare the relay options")
        let calm = ChatSendFailure.calmMessage(for: DoorError.transport("connect refused"))
        model.setConnection(.error(detail: calm))
        model.apply(.error(code: "", reason: calm))

        guard case .refused(let reason) = model.turnState else {
            return XCTFail("a failed send reads as a refused turn, got \(model.turnState)")
        }
        XCTAssertEqual(reason, "Your computer couldn't be reached.")
        for forbidden in ["DoorError", "HTTP", "["] {
            XCTAssertFalse((reason ?? "").contains(forbidden))
        }
    }

    // MARK: - Scenario: an answer with a recommendation renders the decision brief

    private let briefText = """
    Recommendation
    Choose the blind Noise relay for the July launch.

    Why
    - Preserves end-to-end encryption.
    - Adds about 40 ms.
    - Gives the server no visibility.

    Source
    Architecture call, June 30. Three related conversations confirm the constraint.
    """

    // "Then I see a Recommendation section with the recommended call"
    func testBriefParsesRecommendation() throws {
        let brief = try XCTUnwrap(AnswerBrief.parse(briefText))
        XCTAssertEqual(brief.recommendation,
                       "Choose the blind Noise relay for the July launch.")
    }

    // "And the reasons render as Why bullets"
    func testBriefParsesWhyBullets() throws {
        let brief = try XCTUnwrap(AnswerBrief.parse(briefText))
        XCTAssertEqual(brief.why, [
            "Preserves end-to-end encryption.",
            "Adds about 40 ms.",
            "Gives the server no visibility.",
        ])
    }

    // "And the Source section names where it came from"
    func testBriefParsesSource() throws {
        let brief = try XCTUnwrap(AnswerBrief.parse(briefText))
        XCTAssertEqual(brief.source,
                       "Architecture call, June 30. Three related conversations confirm the constraint.")
    }

    // Markdown-ish headings ("## Recommendation", "**Why:**", "* bullet") parse too.
    func testBriefAcceptsMarkdownHeadings() throws {
        let text = """
        ## Recommendation
        Ship it.

        **Why:**
        * It works.

        ## Source
        The launch call.
        """
        let brief = try XCTUnwrap(AnswerBrief.parse(text))
        XCTAssertEqual(brief.recommendation, "Ship it.")
        XCTAssertEqual(brief.why, ["It works."])
        XCTAssertEqual(brief.source, "The launch call.")
    }

    // "And an answer without that structure keeps the plain answer layout"
    func testPlainAnswerDoesNotParseAsABrief() {
        XCTAssertNil(AnswerBrief.parse(
            "Use the blind Noise relay. You chose it over LAN-only on June 30."))
        XCTAssertNil(AnswerBrief.parse(""))
        XCTAssertNil(AnswerBrief.parse("Recommendation\n\nWhy\nSource"),
                     "empty sections are not a brief")
    }

    // MARK: - Scenario: a finished agent run folds into a finding

    private func finishedSevenStepModel() -> ChatViewModel {
        let model = ChatViewModel()
        model.beginUserTurn("Compare the relay options and write a short report.")
        model.apply(.toolCall(callId: "c1", name: "search", args: #"{"pattern":"relay"}"#))
        model.apply(.toolResult(callId: "c1",
                                content: "Architecture call · Launch deck · 2 notes",
                                isError: false))
        for i in 2...7 {
            model.apply(.toolCall(callId: "c\(i)", name: "read", args: #"{"file_path":"n\#(i).md"}"#))
            model.apply(.toolResult(callId: "c\(i)", content: "ok", isError: false))
        }
        model.apply(.artifact(name: "report.md", mime: "text/markdown"))
        model.apply(.assistantDelta(text: "The blind Noise relay protects the gateway end to end."))
        model.apply(.done(reason: "end"))
        return model
    }

    // "Then the run reads as a Finding card, not a bare done row"
    func testFinishedToolRunBecomesAFinding() throws {
        let model = finishedSevenStepModel()
        let finding = try XCTUnwrap(AgentRunFinding.make(from: model),
                                    "a completed tool-using turn renders the Finding card")
        XCTAssertEqual(finding.headline, "Done. report.md is ready.")
        XCTAssertEqual(finding.body,
                       "The blind Noise relay protects the gateway end to end.")
    }

    // A plain answer (no tools) or a still-streaming run is NOT a finding card.
    func testPlainOrUnfinishedTurnsRenderNoFindingCard() {
        let plain = ChatViewModel()
        plain.beginUserTurn("hello")
        plain.apply(.assistantDelta(text: "hi"))
        plain.apply(.done(reason: "end"))
        XCTAssertNil(AgentRunFinding.make(from: plain), "no tools → no run card")

        let streaming = ChatViewModel()
        streaming.beginUserTurn("go")
        streaming.apply(.toolCall(callId: "c1", name: "read", args: "{}"))
        XCTAssertNil(AgentRunFinding.make(from: streaming), "unfinished → no card yet")
    }

    // "And the three older steps are folded behind '3 more steps'"
    func testSevenStepRunFoldsOlderSteps() throws {
        let finding = try XCTUnwrap(AgentRunFinding.make(from: finishedSevenStepModel()))
        XCTAssertEqual(finding.steps.count, 7)
        XCTAssertEqual(finding.fold.foldLabel, "3 more steps")
        XCTAssertEqual(finding.fold.visible, 3..<7, "the most recent four stay visible")
    }

    // "And the card carries the sources-consulted line"
    func testFindingCarriesSourcesConsultedLine() throws {
        let finding = try XCTUnwrap(AgentRunFinding.make(from: finishedSevenStepModel()))
        XCTAssertEqual(finding.sourcesLine,
                       "Sources consulted · Architecture call · Launch deck · 2 notes")
    }

    // Without a search step the line still states plainly what the run did.
    func testSourcesLineFallsBackToStepCount() {
        let steps = [
            RunStepTile(id: "1", title: "ran: ls", outcome: "done", symbol: "terminal"),
            RunStepTile(id: "2", title: "read a.md", outcome: "ok", symbol: "doc.text"),
        ]
        XCTAssertEqual(AgentRunFinding.sourcesLine(steps: steps),
                       "Sources consulted · 2 steps")
    }
}
