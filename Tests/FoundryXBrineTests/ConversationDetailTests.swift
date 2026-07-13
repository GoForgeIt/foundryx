import XCTest
import Foundation
import FoundryXKit

/// Conversation detail: three faces + transcript search
/// (features/conversation-detail.feature, track 20260713T0904).
///
/// The detail UI renders PURELY from these kit pieces — DetailFace (the three
/// faces), TranscriptSearch/TranscriptSearchState (text search + next/prev),
/// TranscriptSearchCapability (the honest meaning-search gate), and
/// ConversationActions (action cards joined to their logged outcomes). These
/// tests pin each scenario at that layer.
final class ConversationDetailTests: XCTestCase {

    // MARK: - fixtures

    /// Three transcript rows mentioning "budget" three times (two rows, one twice).
    private let budgetRows = [
        "Let's go over the budget for the quarter.",
        "The venue is booked for Friday afternoon.",
        "If the budget holds we can extend the budget review.",
    ]

    /// AmbientDecision is the other lane's type (no public memberwise init) —
    /// build test decisions the way the log does: through their Codable wire shape.
    private func decision(
        captureId: String, outcome: String, utterance: String? = nil,
        summary: String = "do the thing", ts: UInt64 = 100, skipReason: String? = nil
    ) -> AmbientDecision {
        var obj: [String: Any] = [
            "ts": ts, "captureId": captureId, "windowChars": 500,
            "outcome": outcome, "latencyMs": 12,
        ]
        if let utterance {
            obj["candidate"] = ["utterance": utterance, "summary": summary, "confidence": 0.9]
        }
        if let skipReason { obj["skipReason"] = skipReason }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(AmbientDecision.self, from: data)
    }

    private func candidateDecision(
        captureId: String, utterance: String, ts: UInt64 = 100
    ) -> AmbientDecision {
        decision(captureId: captureId, outcome: "candidate", utterance: utterance, ts: ts)
    }

    // MARK: - three faces

    // Scenario: A conversation opens into three faces
    func testDetailHasThreeFacesSummaryFirst() {
        XCTAssertEqual(DetailFace.allCases, [.summary, .actions, .transcript])
        XCTAssertEqual(DetailFace.allCases.first, .summary, "the Summary face is shown first")
    }

    // Scenario: A conversation opens into three faces (the switcher shows their names)
    func testFaceTitles() {
        XCTAssertEqual(DetailFace.summary.title, "Summary")
        XCTAssertEqual(DetailFace.actions.title, "Actions")
        XCTAssertEqual(DetailFace.transcript.title, "Transcript")
    }

    // MARK: - transcript text search

    // Scenario: Searching the transcript highlights matches and shows the count
    func testSubstringSearchFindsAllMatchesWithRanges() {
        let matches = TranscriptSearch.matches(query: "budg", in: budgetRows)
        XCTAssertEqual(matches.count, 3)
        // Every returned range slices the query text back out of its row.
        for m in matches {
            XCTAssertEqual(TranscriptSearch.text(of: m, in: budgetRows)?.lowercased(), "budg")
        }
        // Matches land on the right rows: one in row 0, two in row 2.
        XCTAssertEqual(matches.map(\.row), [0, 2, 2])
        let state = TranscriptSearchState(matches: matches)
        XCTAssertEqual(state.count, 3)
        XCTAssertEqual(state.positionLabel, "1 of 3", "I am on the first of three matches")
    }

    // Scenario: Search matches regardless of letter case
    func testSearchIsCaseInsensitive() {
        let rows = ["Budget review on Friday"]
        let matches = TranscriptSearch.matches(query: "budget", in: rows)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(TranscriptSearch.text(of: matches[0], in: rows), "Budget")
    }

    // Scenario: Next and previous step through the matches
    func testNextAndPreviousStepAndWrap() {
        var state = TranscriptSearchState(
            matches: TranscriptSearch.matches(query: "budg", in: budgetRows))
        XCTAssertEqual(state.positionLabel, "1 of 3")
        state.next()
        XCTAssertEqual(state.positionLabel, "2 of 3", "next steps to the second match")
        state.next()
        state.next()
        XCTAssertEqual(state.positionLabel, "1 of 3", "stepping past the last wraps to the first")
        state.previous()
        XCTAssertEqual(state.positionLabel, "3 of 3", "stepping back from the first wraps to the last")
    }

    // Scenario: Clearing the search removes the highlights
    func testEmptyQueryHasNoMatches() {
        XCTAssertTrue(TranscriptSearch.matches(query: "", in: budgetRows).isEmpty)
        XCTAssertTrue(TranscriptSearch.matches(query: "   ", in: budgetRows).isEmpty,
                      "whitespace-only queries match nothing")
    }

    // Scenario: A search with no matches says so honestly
    func testNoMatchesIsHonestAndNavigationIsInert() {
        var state = TranscriptSearchState(
            matches: TranscriptSearch.matches(query: "regatta", in: budgetRows))
        XCTAssertEqual(state.count, 0)
        XCTAssertNil(state.current)
        XCTAssertEqual(state.positionLabel, "No matches")
        state.next()
        state.previous()
        XCTAssertNil(state.current, "next/previous do nothing when there are no matches")
    }

    // The current match is the one the view scrolls to and emphasizes.
    func testCurrentMatchFollowsNavigation() {
        let matches = TranscriptSearch.matches(query: "budg", in: budgetRows)
        var state = TranscriptSearchState(matches: matches)
        XCTAssertEqual(state.current, matches[0])
        state.next()
        XCTAssertEqual(state.current, matches[1])
    }

    // MARK: - meaning search (the honest tier)

    private struct FakeMeaningIndex: TranscriptMeaningIndex {
        let isAvailable: Bool
        func nearestPassages(to query: String, limit: Int) async throws -> [MeaningMatch] { [] }
    }

    // Scenario: Meaning search is offered only when the phone can actually do it
    func testMeaningToggleAbsentWithoutAnIndex() {
        XCTAssertFalse(TranscriptSearchCapability.meaningSearchOffered(nil),
                       "no index on the phone means NO toggle, not a dead one")
        XCTAssertFalse(
            TranscriptSearchCapability.meaningSearchOffered(FakeMeaningIndex(isAvailable: false)),
            "an index that reports itself unavailable also hides the toggle")
    }

    // Scenario: Meaning search appears when an index is available
    func testMeaningToggleDerivesFromAvailability() {
        XCTAssertTrue(
            TranscriptSearchCapability.meaningSearchOffered(FakeMeaningIndex(isAvailable: true)))
    }

    // MARK: - action cards + outcomes

    // Scenario: Action cards show what came of them
    func testActionCardsJoinTheirLoggedOutcomes() {
        let capture = "cap-1"
        let decisions = [
            candidateDecision(captureId: capture, utterance: "send the deck to Maria", ts: 100),
            candidateDecision(captureId: capture, utterance: "book the dentist", ts: 200),
            candidateDecision(captureId: capture, utterance: "email the landlord", ts: 300),
        ]
        let outcomes = [
            CardOutcomeRecord(ts: 150, outcome: "run",
                              seed: "While I was recording, this came up: \u{201C}send the deck to Maria\u{201D}\n\nPlease do the thing."),
            CardOutcomeRecord(ts: 250, outcome: "dismissed",
                              seed: "While I was recording, this came up: \u{201C}book the dentist\u{201D}\n\nPlease do the thing."),
        ]
        let cards = ConversationActions.cards(
            for: capture, decisions: decisions, outcomes: outcomes)
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[0].outcome, .sentToChat)
        XCTAssertEqual(cards[0].outcome.label, "Sent to chat")
        XCTAssertEqual(cards[1].outcome, .dismissed)
        XCTAssertEqual(cards[1].outcome.label, "Dismissed")
        XCTAssertEqual(cards[2].outcome, .pending, "an undecided card is still waiting on me")
    }

    // Scenario: An action card knows which conversation it came from
    func testActionCardCarriesItsConversation() {
        let cards = ConversationActions.cards(
            for: "cap-9",
            decisions: [candidateDecision(captureId: "cap-9", utterance: "call Sam")],
            outcomes: [])
        XCTAssertEqual(cards.first?.captureId, "cap-9",
                       "the card links back to the conversation it surfaced from")
    }

    // Scenario: A conversation with no actions says so honestly
    func testNoCandidatesMeansNoCards() {
        let quiet = decision(captureId: "cap-2", outcome: "gated_no", ts: 10)
        let skipped = decision(captureId: "cap-2", outcome: "skipped", ts: 20,
                               skipReason: "gate_unavailable")
        XCTAssertTrue(ConversationActions.cards(
            for: "cap-2", decisions: [quiet, skipped], outcomes: []).isEmpty,
            "gated-no and skipped windows never fabricate action cards")
    }

    // Cards belong to THEIR conversation — another capture's candidates stay out.
    func testCardsFilterByConversation() {
        let decisions = [
            candidateDecision(captureId: "cap-a", utterance: "one"),
            candidateDecision(captureId: "cap-b", utterance: "two"),
        ]
        let cards = ConversationActions.cards(for: "cap-a", decisions: decisions, outcomes: [])
        XCTAssertEqual(cards.map(\.utterance), ["one"])
    }

    // The same moment re-surfaced across growing windows renders ONE card.
    func testDuplicateUtterancesFoldIntoOneCard() {
        let decisions = [
            candidateDecision(captureId: "cap-c", utterance: "call Sam", ts: 100),
            candidateDecision(captureId: "cap-c", utterance: "call Sam", ts: 160),
        ]
        let cards = ConversationActions.cards(for: "cap-c", decisions: decisions, outcomes: [])
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].ts, 100, "the first surfacing is the card's moment")
    }

    // The outcome log on disk (ambient-cards.jsonl) parses line-per-record;
    // unknown outcome words never crash and map to pending.
    func testOutcomeLogParsesFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conv-detail-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(ConversationActions.outcomeLogFilename)
        let lines = """
        {"ts": 1, "outcome": "run", "seed": "seed one"}
        {"ts": 2, "outcome": "dismissed", "seed": "seed two"}
        not-json garbage line
        {"ts": 3, "outcome": "mystery", "seed": "seed three"}
        """
        try lines.data(using: .utf8)!.write(to: url)

        let records = ConversationActions.readOutcomes(at: url)
        XCTAssertEqual(records.count, 3, "the garbage line is skipped, not fatal")
        XCTAssertEqual(records[0].outcome, "run")
        XCTAssertEqual(ActionOutcome(wire: records[2].outcome), .pending,
                       "an unknown outcome word degrades to pending, never crashes")
        // A missing log file reads as no outcomes.
        XCTAssertTrue(ConversationActions.readOutcomes(
            at: dir.appendingPathComponent("absent.jsonl")).isEmpty)
    }

    // Forward-compat: an "answered" outcome (a lookup card that showed its answer)
    // maps to the answered state the Actions face renders.
    func testAnsweredOutcomeMaps() {
        XCTAssertEqual(ActionOutcome(wire: "answered"), .answered)
        XCTAssertEqual(ActionOutcome.answered.label, "Answered")
        XCTAssertEqual(ActionOutcome(wire: "run"), .sentToChat)
        XCTAssertEqual(ActionOutcome(wire: "dismissed"), .dismissed)
    }
}
