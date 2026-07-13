import XCTest
import Foundation
import FoundryXKit

/// Closing the answer loop (features/ambient-answer-loop.feature): answers and
/// agent runs get WRITERS, ratings merge onto their answers, and the ledger
/// renders only what actually happened.
final class AmbientAnswerLoopTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-answerloop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ lines: [String], to url: URL) throws {
        try lines.joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func urls(_ dir: URL) -> (decisions: URL, cards: URL, answers: URL) {
        (dir.appendingPathComponent("ambient-decisions.jsonl"),
         dir.appendingPathComponent("ambient-cards.jsonl"),
         dir.appendingPathComponent("ambient-answers.jsonl"))
    }

    // Scenario: a delivered answer is remembered in my activity
    func testAnswerLogLineBecomesLedgerEntry() throws {
        let dir = try tempDir()
        let u = urls(dir)
        try write([
            #"{"ts":100,"kind":"answer","answer":"The relay decision was made June 30.","captureId":"omi-1"}"#,
        ], to: u.answers)

        let entries = ActivityStore.entries(decisionLogURL: u.decisions,
                                            cardsLogURL: u.cards,
                                            answersLogURL: u.answers)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .answer)
        XCTAssertEqual(entries[0].detail, "The relay decision was made June 30.")
        // …and it links back to the conversation it came from
        if case .conversation(let id) = entries[0].source {
            XCTAssertEqual(id, "omi-1")
        } else {
            XCTFail("answer must link home to its conversation")
        }
    }

    // Scenario: my rating lands on the answer in the ledger
    func testRatingMergesOntoTheAnswerEntry() throws {
        let dir = try tempDir()
        let u = urls(dir)
        try write([
            #"{"ts":100,"kind":"answer","answer":"Flight lands 4pm.","captureId":"omi-2"}"#,
            #"{"ts":140,"outcome":"done","rating":"helpful","note":"","answer_title":"From your memory"}"#,
        ], to: u.answers)

        let entries = ActivityStore.entries(decisionLogURL: u.decisions,
                                            cardsLogURL: u.cards,
                                            answersLogURL: u.answers)
        // …the rating is not a separate ledger entry
        XCTAssertEqual(entries.count, 1, "a rating annotates; it never duplicates")
        XCTAssertEqual(entries[0].kind, .answer)
        XCTAssertEqual(entries[0].rating, "helpful")
    }

    // A rating with nothing before it has nowhere to land — dropped, not invented.
    func testOrphanRatingIsDroppedHonestly() throws {
        let dir = try tempDir()
        let u = urls(dir)
        try write([
            #"{"ts":140,"outcome":"done","rating":"helpful","answer_title":"From your memory"}"#,
        ], to: u.answers)
        let entries = ActivityStore.entries(decisionLogURL: u.decisions,
                                            cardsLogURL: u.cards,
                                            answersLogURL: u.answers)
        XCTAssertTrue(entries.isEmpty, "no answer to rate ⇒ nothing appears")
    }

    // "not-useful" reads as words, not a slug.
    func testRatingWordIsHumanized() throws {
        let dir = try tempDir()
        let u = urls(dir)
        try write([
            #"{"ts":100,"kind":"answer","answer":"A."}"#,
            #"{"ts":110,"outcome":"done","rating":"not-useful"}"#,
        ], to: u.answers)
        let entries = ActivityStore.entries(decisionLogURL: u.decisions,
                                            cardsLogURL: u.cards,
                                            answersLogURL: u.answers)
        XCTAssertEqual(entries.first?.rating, "not useful")
    }

    // Scenario: a finished agent run is remembered in my activity
    func testAgentRunLineBecomesLedgerEntry() throws {
        let dir = try tempDir()
        let u = urls(dir)
        try write([
            #"{"ts":200,"kind":"agent_run","answer":"Ran 3 steps · searched your memory"}"#,
        ], to: u.answers)
        let entries = ActivityStore.entries(decisionLogURL: u.decisions,
                                            cardsLogURL: u.cards,
                                            answersLogURL: u.answers)
        XCTAssertEqual(entries.first?.kind, .agentRun)
        XCTAssertEqual(entries.first?.detail, "Ran 3 steps · searched your memory")
    }

    // The two-log entry point keeps its exact old behavior (regression).
    func testTwoLogEntryPointUnchanged() throws {
        let dir = try tempDir()
        let u = urls(dir)
        try write([#"{"ts":1,"outcome":"candidate","candidate":{"utterance":"look that up","summary":""}}"#],
                  to: u.decisions)
        let entries = ActivityStore.entries(decisionLogURL: u.decisions, cardsLogURL: u.cards)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .nudgeShown)
    }

    // Scenario: a finished agent run is remembered / no tools = no run
    @MainActor
    func testRunCompletionHookFiresOnlyForToolTurns() {
        let vm = ChatViewModel()
        var completions: [[ChatViewModel.ToolActivity]] = []
        vm.onRunCompleted = { completions.append($0) }

        // A turn with tools → one completion carrying them.
        vm.beginUserTurn("find the relay decision")
        vm.apply(.toolCall(callId: "t1", name: "lore_search", args: "{}"))
        vm.apply(.toolResult(callId: "t1", content: "3 hits", isError: false))
        vm.apply(.done(reason: "end"))
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].count, 1)

        // A plain text turn → no run recorded.
        vm.beginUserTurn("thanks")
        vm.apply(.assistantDelta(text: "welcome"))
        vm.apply(.done(reason: "end"))
        XCTAssertEqual(completions.count, 1, "no tools ⇒ not a run")

        // A refused turn never records a run.
        vm.beginUserTurn("do the thing")
        vm.apply(.toolCall(callId: "t2", name: "x", args: "{}"))
        vm.apply(.error(code: "e", reason: "nope"))
        vm.apply(.done(reason: "refused"))
        XCTAssertEqual(completions.count, 1, "refused ⇒ not a completed run")
    }
}
