import XCTest
import Foundation
import BrineSwiftCore
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
    // (updated by track 20260714T1800: the rendered outcome vocabulary is the
    // prototype's Completed / Ready / Open / Dismissed — asserted through the
    // presentation the Actions face actually renders from.)
    func testActionCardsJoinTheirLoggedOutcomes() {
        let capture = "cap-1"
        let decisions = [
            candidateDecision(captureId: capture, utterance: "send the deck to Maria", ts: 100),
            candidateDecision(captureId: capture, utterance: "book the dentist", ts: 200),
            candidateDecision(captureId: capture, utterance: "email the landlord", ts: 300),
        ]
        let outcomes = [
            CardOutcomeRecord(ts: 150, outcome: "run",
                              seed: "While I was taking a note, this came up: \u{201C}send the deck to Maria\u{201D}\n\nPlease do the thing."),
            CardOutcomeRecord(ts: 250, outcome: "dismissed",
                              seed: "While I was taking a note, this came up: \u{201C}book the dentist\u{201D}\n\nPlease do the thing."),
        ]
        let cards = ConversationActions.cards(
            for: capture, decisions: decisions, outcomes: outcomes)
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[0].outcome, .sentToChat)
        XCTAssertEqual(cards[1].outcome, .dismissed)
        XCTAssertEqual(cards[2].outcome, .pending, "an undecided card is still waiting on me")

        let presentation = ConversationActionsPresentation.build(
            captureId: capture, decisions: decisions, outcomes: outcomes,
            answers: [], userActions: [])
        XCTAssertEqual(presentation.rows.map(\.state.rawValue),
                       ["Completed", "Dismissed", "Open"],
                       "the face renders the human outcome vocabulary")
        XCTAssertTrue(presentation.rows[0].done)
        XCTAssertFalse(presentation.rows[2].done)
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
        XCTAssertEqual(ActionOutcome(wire: "run"), .sentToChat)
        XCTAssertEqual(ActionOutcome(wire: "dismissed"), .dismissed)
    }

    // MARK: - summary face: "What mattered" bullets (track 20260714T1800 §5)

    // Scenario: The summary face says what mattered
    func testWhatMatteredBulletsDeriveFromTheSummary() {
        let summary = "Sarah will finish the appendix tonight once she has the template. "
            + "Send her the deck Friday at 9:00 AM. "
            + "The relay figures come from the June 30 architecture call."
        let bullets = ConversationSummaryPresentation.bullets(fromSummary: summary)
        XCTAssertEqual(bullets.count, 3, "one bullet per sentence, capped at three")
        XCTAssertEqual(bullets[0],
                       "Sarah will finish the appendix tonight once she has the template.")
        XCTAssertEqual(ConversationSummaryPresentation.whatMatteredLabel, "What mattered")
    }

    func testWhatMatteredBulletsAreCapped() {
        let summary = "One. Two. Three. Four. Five."
        XCTAssertEqual(ConversationSummaryPresentation.bullets(fromSummary: summary).count, 3)
    }

    func testAOneSentenceSummaryHasNoBulletList() {
        XCTAssertTrue(ConversationSummaryPresentation.bullets(
            fromSummary: "Just the one thing happened.").isEmpty,
            "a one-line summary IS the lede — no list repeats it")
        XCTAssertTrue(ConversationSummaryPresentation.bullets(fromSummary: nil).isEmpty)
        XCTAssertTrue(ConversationSummaryPresentation.bullets(fromSummary: "   ").isEmpty)
    }

    // MARK: - summary face: the linked relay answer

    // Scenario: The summary face links to the relay answer
    func testLinkedAnswerReadsFromTheDeliveredAnswerLog() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conv-detail-answers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ambient-answers.jsonl")
        let lines = """
        {"ts": 10, "kind": "answer", "answer": "Use the blind Noise relay.", "utterance": "What did we decide about the relay?", "captureId": "cap-r"}
        {"ts": 11, "kind": "answer", "answer": "Different capture.", "utterance": "other", "captureId": "cap-other"}
        {"ts": 12, "rating": "helpful"}
        garbage line
        """
        try lines.data(using: .utf8)!.write(to: url)

        let answers = ConversationAnswerLog.answers(at: url, captureId: "cap-r")
        XCTAssertEqual(answers.count, 1, "only THIS capture's answers link")
        XCTAssertEqual(answers[0].title, "What did we decide about the relay?")
        XCTAssertEqual(answers[0].text, "Use the blind Noise relay.")

        let face = ConversationSummaryPresentation.build(
            summary: "A. B.", linkedAnswers: answers)
        XCTAssertNotNil(face.linkedAnswer)
        XCTAssertEqual(ConversationSummaryPresentation.openRelayAnswerLabel,
                       "Open the relay answer")

        // No linked answer ⇒ no row (never a dead control).
        XCTAssertNil(ConversationSummaryPresentation.build(
            summary: "A. B.", linkedAnswers: []).linkedAnswer)
        // A missing log reads as no answers.
        XCTAssertTrue(ConversationAnswerLog.answers(
            at: dir.appendingPathComponent("absent.jsonl"), captureId: "cap-r").isEmpty)
    }

    // MARK: - actions face: populated from real surfaced items

    // Scenario: The actions face is populated from what actually surfaced
    func testActionsPresentationMixesSurfacedAnswersAndUserItems() {
        let capture = "cap-mix"
        let decisions = [
            candidateDecision(captureId: capture, utterance: "send Sarah the deck", ts: 100),
            candidateDecision(captureId: capture, utterance: "review the appendix", ts: 200),
        ]
        let outcomes = [
            CardOutcomeRecord(ts: 150, outcome: "run",
                              seed: "this came up: \u{201C}send Sarah the deck\u{201D}"),
        ]
        let answers = [LinkedConversationAnswer(
            title: "The relay decision", text: "Use the blind Noise relay.")]
        let user = [UserConversationAction(title: "Call the venue", done: false, createdAt: 300)]

        let face = ConversationActionsPresentation.build(
            captureId: capture, decisions: decisions, outcomes: outcomes,
            answers: answers, userActions: user)
        XCTAssertFalse(face.isEmpty, "a conversation WITH surfaced items is never empty")
        let states = Set(face.rows.map(\.state))
        XCTAssertTrue(states.contains(.completed))
        XCTAssertTrue(states.contains(.ready))
        XCTAssertTrue(states.contains(.open))

        let answerRow = face.rows.first { $0.kind == .answer }
        XCTAssertEqual(answerRow?.label, "Answer found")
        XCTAssertEqual(answerRow?.meta, "The relay decision")
        XCTAssertEqual(answerRow?.state, .ready)

        let userRow = face.rows.first { $0.kind == .user }
        XCTAssertEqual(userRow?.label, "Call the venue")
        XCTAssertEqual(userRow?.state, .open)
    }

    // Scenario: A conversation with no actions says so honestly
    func testActionsEmptyStateCopy() {
        let face = ConversationActionsPresentation.build(
            captureId: "cap-quiet", decisions: [], outcomes: [], answers: [], userActions: [])
        XCTAssertTrue(face.isEmpty)
        XCTAssertEqual(ConversationActionsPresentation.emptyStateText,
                       "Nothing surfaced from this voice note yet.")
        XCTAssertEqual(ConversationActionsPresentation.addActionLabel, "Add an action")
    }

    // Scenario: I can add an action to a conversation
    func testUserActionStoreAppendsAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conv-detail-useractions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertTrue(UserActionStore.load(captureId: "cap-u", baseDir: dir).isEmpty)
        XCTAssertNil(UserActionStore.add(title: "   ", captureId: "cap-u", baseDir: dir),
                     "a blank title adds nothing")

        let added = UserActionStore.add(title: "  Send Sarah the deck ",
                                        captureId: "cap-u", baseDir: dir)
        XCTAssertEqual(added?.title, "Send Sarah the deck", "titles are trimmed")

        // Persisted: a FRESH load from disk still has it.
        let reloaded = UserActionStore.load(captureId: "cap-u", baseDir: dir)
        XCTAssertEqual(reloaded.map(\.title), ["Send Sarah the deck"])
        XCTAssertEqual(reloaded.first?.done, false)

        // It renders as an open user row on the face.
        let face = ConversationActionsPresentation.build(
            captureId: "cap-u", decisions: [], outcomes: [],
            answers: [], userActions: reloaded)
        XCTAssertEqual(face.rows.count, 1)
        XCTAssertEqual(face.rows[0].kind, .user)
        XCTAssertEqual(face.rows[0].state, .open)

        // Other captures don't see it.
        XCTAssertTrue(UserActionStore.load(captureId: "cap-other", baseDir: dir).isEmpty)
    }

    // MARK: - transcript face: the standing people-hint copy

    func testSpeakerSuggestionHintReadsLikeThePrototype() {
        XCTAssertEqual(SpeakerNameSuggestion.standingHint(name: "Sarah", matchCount: 3),
                       "Sarah matches 3 past conversations. Use this name in all 3.")
        XCTAssertEqual(SpeakerNameSuggestion.standingHint(name: "Sarah", matchCount: 1),
                       "Sarah matches 1 past conversation. Use this name in it.")
        XCTAssertEqual(SpeakerNameSuggestion.standingHint(name: "", matchCount: 3), "")
        XCTAssertEqual(SpeakerNameSuggestion.standingHint(name: "Sarah", matchCount: 0), "")
    }

    // MARK: - no stepper inside the detail faces (source guard, B1b)

    // Scenario: The detail faces show no processing stepper
    func testDetailFacesRenderNoProcessingStepper() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let source = try String(
            contentsOf: url.appendingPathComponent("App/ConversationFacesView.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains("ConversationStepper"),
                       "the prototype detail has no processing stepper inside the faces")
    }

    // MARK: - brine: the @faces realignment scenarios drive the real builders

    func testFacesRealignmentScenarios() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let root = url
        let text = try String(
            contentsOf: root.appendingPathComponent("features/conversation-detail.feature"),
            encoding: .utf8)
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        let world = DetailFacesWorld(repoRoot: root)
        defer { world.tearDown() }
        let registry = StepRegistry(DetailFacesSteps.make(world: world))

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry,
                                             resources: [],
                                             tagFilter: TagFilter(include: ["@faces"]),
                                             collector: { collected.append($0) })

        var failures: [String] = []
        for ev in collected {
            guard case .object(let o) = ev,
                  case .string("scenario_end")? = o["type"],
                  case .string(let status)? = o["status"], status != "passed" else { continue }
            let name: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(name): \(err)")
        }
        XCTAssertTrue(failures.isEmpty,
                      "@faces scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.passed, 7, "all @faces scenarios ran and passed")
    }
}

// MARK: - @faces world + step definitions

private struct DetailFacesError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The @faces scenarios' world: a hermetic captures dir (the per-capture stores
/// and the delivered-answer log live here) + the seeded ambient records, with
/// the REAL presentation builders producing what the steps assert on.
private final class DetailFacesWorld: @unchecked Sendable {
    let repoRoot: URL
    let baseDir: URL
    let captureId = "cap-faces"

    var summary: String?
    var decisions: [AmbientDecision] = []
    var outcomes: [CardOutcomeRecord] = []
    var summaryFace: ConversationSummaryPresentation?
    var actionsFace: ConversationActionsPresentation?

    init(repoRoot: URL) {
        self.repoRoot = repoRoot
        baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detail-faces-world-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    var answersLogURL: URL { baseDir.appendingPathComponent("ambient-answers.jsonl") }

    func reset() {
        summary = nil
        decisions = []
        outcomes = []
        summaryFace = nil
        actionsFace = nil
        try? FileManager.default.removeItem(at: baseDir)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: baseDir)
    }

    func appendAnswerLine(captureId: String) {
        let obj: [String: Any] = [
            "ts": 10, "kind": "answer",
            "answer": "Use the blind Noise relay.",
            "utterance": "What did we decide about the relay?",
            "captureId": captureId,
        ]
        var data = try! JSONSerialization.data(withJSONObject: obj)
        data.append(UInt8(ascii: "\n"))
        if let handle = try? FileHandle(forWritingTo: answersLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: answersLogURL)
        }
    }

    func candidate(_ utterance: String, ts: UInt64) -> AmbientDecision {
        let obj: [String: Any] = [
            "ts": ts, "captureId": captureId, "windowChars": 500,
            "outcome": "candidate", "latencyMs": 12,
            "candidate": ["utterance": utterance, "summary": "", "confidence": 0.9],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(AmbientDecision.self, from: data)
    }

    var linkedAnswers: [LinkedConversationAnswer] {
        ConversationAnswerLog.answers(at: answersLogURL, captureId: captureId)
    }

    func buildSummaryFace() {
        summaryFace = ConversationSummaryPresentation.build(
            summary: summary, linkedAnswers: linkedAnswers)
    }

    func buildActionsFace() {
        actionsFace = ConversationActionsPresentation.build(
            captureId: captureId, decisions: decisions, outcomes: outcomes,
            answers: linkedAnswers,
            userActions: UserActionStore.load(captureId: captureId, baseDir: baseDir))
    }
}

private enum DetailFacesSteps {
    static func make(world: DetailFacesWorld) -> [StepDefinition] {
        [
            // MARK: givens
            defineStep("a transcribed conversation whose summary covers several points") { ctx, _, _ in
                world.reset()
                world.summary = "Sarah will finish the appendix tonight once she has the template. "
                    + "Send her the deck Friday at 9:00 AM. "
                    + "The relay figures come from the June 30 architecture call."
                return ctx
            },
            defineStep("a conversation that has been transcribed") { ctx, _, _ in
                world.reset()
                return ctx
            },
            defineStep("an ambient answer surfaced from this conversation") { ctx, _, _ in
                world.appendAnswerLine(captureId: world.captureId)
                return ctx
            },
            defineStep("no ambient answer surfaced from this conversation") { ctx, _, _ in
                world.reset()
                // An answer for ANOTHER capture proves the link filters honestly.
                world.appendAnswerLine(captureId: "cap-someone-else")
                return ctx
            },
            defineStep("the conversation surfaced an action that I sent to chat") { ctx, _, _ in
                world.reset()
                world.decisions.append(world.candidate("send Sarah the deck", ts: 100))
                world.outcomes.append(CardOutcomeRecord(
                    ts: 150, outcome: "run",
                    seed: "this came up: \u{201C}send Sarah the deck\u{201D}"))
                return ctx
            },
            defineStep("the conversation surfaced an action I have not decided on") { ctx, _, _ in
                world.decisions.append(world.candidate("review the appendix", ts: 200))
                return ctx
            },
            defineStep("a conversation during which nothing actionable surfaced") { ctx, _, _ in
                world.reset()
                return ctx
            },
            defineStep("a conversation that is still being processed") { ctx, _, _ in
                world.reset()
                return ctx
            },

            // MARK: whens
            defineStep("I open the Summary face") { ctx, _, _ in
                world.buildSummaryFace()
                return ctx
            },
            defineStep("I open the Actions face") { ctx, _, _ in
                world.buildActionsFace()
                return ctx
            },
            defineStep("I open the conversation") { ctx, _, _ in
                world.buildSummaryFace()
                world.buildActionsFace()
                return ctx
            },
            defineStep("I add an action {string}") { ctx, params, _ in
                UserActionStore.add(title: try params.requireString(0),
                                    captureId: world.captureId, baseDir: world.baseDir)
                world.buildActionsFace()
                return ctx
            },

            // MARK: thens
            defineCheck("I see a \"What mattered\" list with one bullet per point") { _, _, _ in
                guard let face = world.summaryFace else {
                    throw DetailFacesError("summary face not built")
                }
                guard face.bullets.count == 3 else {
                    throw DetailFacesError("expected 3 bullets, got \(face.bullets.count)")
                }
                guard ConversationSummaryPresentation.whatMatteredLabel == "What mattered" else {
                    throw DetailFacesError("wrong list label")
                }
            },
            defineCheck("I can open the relay answer from the summary") { _, _, _ in
                guard let linked = world.summaryFace?.linkedAnswer else {
                    throw DetailFacesError("no linked answer on the summary face")
                }
                guard !linked.text.isEmpty else {
                    throw DetailFacesError("linked answer carries no text")
                }
                guard ConversationSummaryPresentation.openRelayAnswerLabel
                    == "Open the relay answer" else {
                    throw DetailFacesError("wrong answer-row label")
                }
            },
            defineCheck("there is no answer row to open") { _, _, _ in
                guard let face = world.summaryFace else {
                    throw DetailFacesError("summary face not built")
                }
                guard face.linkedAnswer == nil else {
                    throw DetailFacesError("an answer row appeared with no linked answer")
                }
            },
            defineCheck("I see rows marked Completed, Ready, and Open") { _, _, _ in
                guard let face = world.actionsFace else {
                    throw DetailFacesError("actions face not built")
                }
                let states = Set(face.rows.map(\.state.rawValue))
                for wanted in ["Completed", "Ready", "Open"] where !states.contains(wanted) {
                    throw DetailFacesError("missing a \(wanted) row; got \(states)")
                }
            },
            defineCheck("the Actions face lists {string} as an open item") { _, params, _ in
                let title = try params.requireString(0)
                guard let row = world.actionsFace?.rows.first(where: { $0.label == title }) else {
                    throw DetailFacesError("no row titled \(title)")
                }
                guard row.state == .open, row.kind == .user else {
                    throw DetailFacesError("expected an open user row, got \(row)")
                }
            },
            defineCheck("it is still there when I come back") { _, _, _ in
                // A FRESH load from disk — nothing held in memory.
                let reloaded = UserActionStore.load(
                    captureId: world.captureId, baseDir: world.baseDir)
                guard reloaded.contains(where: { $0.title == "Send Sarah the deck" }) else {
                    throw DetailFacesError("the added action did not persist")
                }
            },
            defineCheck("I see that nothing surfaced from this conversation yet, not an error") { _, _, _ in
                guard let face = world.actionsFace else {
                    throw DetailFacesError("actions face not built")
                }
                guard face.isEmpty else {
                    throw DetailFacesError("expected an empty face, got \(face.rows.count) rows")
                }
                guard ConversationActionsPresentation.emptyStateText
                    == "Nothing surfaced from this voice note yet." else {
                    throw DetailFacesError("wrong empty-state copy")
                }
            },
            defineCheck("I can still add an action") { _, _, _ in
                guard ConversationActionsPresentation.addActionLabel == "Add an action" else {
                    throw DetailFacesError("wrong add-action label")
                }
            },
            defineCheck("no processing stepper appears in any face") { _, _, _ in
                let viewSource = world.repoRoot.appendingPathComponent("App/ConversationFacesView.swift")
                let source = (try? String(contentsOf: viewSource, encoding: .utf8)) ?? ""
                guard !source.isEmpty else {
                    throw DetailFacesError("could not read ConversationFacesView.swift")
                }
                guard !source.contains("ConversationStepper") else {
                    throw DetailFacesError("the detail faces still render ConversationStepper")
                }
            },
        ]
    }
}
