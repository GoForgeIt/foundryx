import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Acting on a surfaced action (features/action-feedback.feature, track
/// 20260715T1500 addendum): tapping an Actions-face row offers act-in-chat /
/// refine / not-an-action, and the rejections + refinement notes persist as
/// feedback the action spotter learns from.
///
/// The steps drive the REAL kit pieces the view renders from — the decision
/// log read (AmbientLane.readDecisions), the card-outcome log
/// (ConversationActions.readOutcomes; outcome lines written in the exact wire
/// shape AmbientCardBroker writes), ActionFeedbackStore, UserActionStore, and
/// ConversationActionsPresentation.build — all file-backed in a temp dir, so a
/// "fresh look" is a genuine re-read from disk.
final class ActionFeedbackFeatureTests: XCTestCase {
    func testActionFeedbackScenarios() async throws {
        let world = ActionFeedbackWorld()
        try await BrineFeatureRunner.run(
            "action-feedback", registry: StepRegistry(ActionFeedbackSteps.make(world: world)))
    }
}

// MARK: - World

private final class ActionFeedbackWorld: @unchecked Sendable {
    let captureId = "conv-actions-1"
    let utterance = "Remind me to send Sarah the numbers section tonight"
    let summary = "Set a reminder to send Sarah the numbers section tonight"

    var dir: URL!
    /// What the chat composer was prefilled with (nil = never opened).
    var prefill: String?
    /// The row whose options the user is looking at.
    var row: ConversationActionsPresentation.Row?

    var decisionsURL: URL { dir.appendingPathComponent("ambient-decisions.jsonl") }
    var cardsURL: URL { dir.appendingPathComponent(ConversationActions.outcomeLogFilename) }

    func reset() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-action-feedback-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        prefill = nil
        row = nil
    }

    /// A decision-log line exactly as AmbientLane writes it.
    func writeCandidate() throws {
        let line = """
        {"ts":100,"captureId":"\(captureId)","windowChars":480,"outcome":"candidate","candidate":{"utterance":"\(utterance)","summary":"\(summary)","confidence":0.86},"latencyMs":210}
        """
        try appendLine(line, to: decisionsURL)
    }

    /// A card-outcome line exactly as AmbientCardBroker.logOutcome writes it.
    func writeOutcome(_ outcome: String, seed: String) throws {
        let obj: [String: Any] = ["ts": Int(Date().timeIntervalSince1970),
                                  "outcome": outcome, "seed": String(seed.prefix(300))]
        let data = try JSONSerialization.data(withJSONObject: obj)
        try appendLine(String(decoding: data, as: UTF8.self), to: cardsURL)
    }

    private func appendLine(_ line: String, to url: URL) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (existing + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// What the app's recordFeedback does: the full record into the feedback
    /// store + the outcome word into the card log.
    func giveFeedback(_ kind: ActionFeedbackRecord.Kind, comment: String) throws {
        ActionFeedbackStore.append(
            ActionFeedbackRecord(captureId: captureId, utterance: utterance,
                                 summary: summary, kind: kind, comment: comment),
            baseDir: dir)
        try writeOutcome(kind == .rejected ? "rejected" : "refined", seed: utterance)
    }

    /// A genuine re-read of every store from disk — what loadFaceData does.
    func rebuild() -> ConversationActionsPresentation {
        ConversationActionsPresentation.build(
            captureId: captureId,
            decisions: AmbientLane.readDecisions(at: decisionsURL),
            outcomes: ConversationActions.readOutcomes(at: cardsURL),
            answers: [],
            userActions: UserActionStore.load(captureId: captureId, baseDir: dir),
            feedback: ActionFeedbackStore.load(captureId: captureId, baseDir: dir))
    }

    func firstRow() throws -> ConversationActionsPresentation.Row {
        guard let r = rebuild().rows.first else {
            throw BrineStepError("expected an action row, found none")
        }
        return r
    }

    /// The app's act-in-chat: prefill the composer (no auto-send).
    func actInChat() throws {
        let r = try firstRow()
        guard let seed = r.seed else { throw BrineStepError("row has no chat seed") }
        prefill = seed
    }

    /// The user actually sends the prefilled turn — the moment `run` is logged
    /// (AmbientCardBroker.prefillSent semantics, with the ORIGINAL seed).
    func sendPrefilled() throws {
        guard let seed = prefill else { throw BrineStepError("nothing was prefilled") }
        try writeOutcome("run", seed: seed)
    }
}

// MARK: - Steps

private enum ActionFeedbackSteps {
    static func make(world w: ActionFeedbackWorld) -> [StepDefinition] {
        [
            defineStep("a conversation that surfaced an action") { ctx, _, _ in
                try w.reset()
                try w.writeCandidate()
                return ctx
            },
            defineStep("a conversation that surfaced an action that I sent to chat") { ctx, _, _ in
                try w.reset()
                try w.writeCandidate()
                try w.actInChat()
                try w.sendPrefilled()
                return ctx
            },
            defineStep("a conversation where I added my own action") { ctx, _, _ in
                try w.reset()
                UserActionStore.add(title: "Book the venue for the offsite",
                                    captureId: w.captureId, baseDir: w.dir)
                return ctx
            },
            defineStep("a conversation that surfaced nothing") { ctx, _, _ in
                try w.reset()
                return ctx
            },
            defineStep("I marked an action as not an action with a comment") { ctx, _, _ in
                try w.reset()
                try w.writeCandidate()
                try w.giveFeedback(.rejected, comment: "that was just small talk")
                return ctx
            },

            defineStep("I look at the action's options") { ctx, _, _ in
                w.row = try w.firstRow()
                return ctx
            },
            defineStep("I choose to act on it in chat") { ctx, _, _ in
                try w.actInChat()
                try w.sendPrefilled()
                return ctx
            },
            defineStep("I mark it as not an action with the comment {string}") { ctx, p, _ in
                try w.giveFeedback(.rejected, comment: p.requireString(0))
                return ctx
            },
            defineStep("I mark it as not an action without a comment") { ctx, _, _ in
                try w.giveFeedback(.rejected, comment: "")
                return ctx
            },
            defineStep("I refine it with the comment {string}") { ctx, p, _ in
                try w.giveFeedback(.refined, comment: p.requireString(0))
                return ctx
            },
            defineStep("the actions are rebuilt from disk") { ctx, _, _ in
                w.row = try w.firstRow()
                return ctx
            },

            defineCheck("I can act on it in chat, mark it as not an action, or refine it") { _, _, _ in
                guard let row = w.row else { throw BrineStepError("no row under review") }
                guard row.seed != nil else { throw BrineStepError("no act-in-chat option") }
                guard row.utterance != nil else {
                    throw BrineStepError("no reject/refine option on a surfaced row")
                }
            },
            defineCheck("the chat opens pre-filled with what was heard and what could be done") { _, _, _ in
                guard let prefill = w.prefill else { throw BrineStepError("chat was not prefilled") }
                guard prefill.contains(w.utterance) else {
                    throw BrineStepError("prefill is missing what was heard: \(prefill)")
                }
                guard prefill.contains(w.summary) else {
                    throw BrineStepError("prefill is missing what could be done: \(prefill)")
                }
            },
            defineCheck("the chat opens pre-filled with my action") { _, _, _ in
                guard let prefill = w.prefill else { throw BrineStepError("chat was not prefilled") }
                guard prefill.contains("Book the venue for the offsite") else {
                    throw BrineStepError("prefill is missing the user's action: \(prefill)")
                }
            },
            defineCheck("the action reads as sent to chat") { _, _, _ in
                let state = try w.firstRow().state
                guard state == .completed else {
                    throw BrineStepError("expected Completed, got \(state.rawValue)")
                }
            },
            defineCheck("the action still reads as sent to chat") { _, _, _ in
                let state = try w.firstRow().state
                guard state == .completed else {
                    throw BrineStepError("refine must not change what came of it; got \(state.rawValue)")
                }
            },
            defineCheck("the action shows {string}") { _, p, _ in
                let want = try p.requireString(0)
                let state = try w.firstRow().state
                guard state.rawValue == want else {
                    throw BrineStepError("expected \(want), got \(state.rawValue)")
                }
            },
            defineCheck("the action still shows {string}") { _, p, _ in
                let want = try p.requireString(0)
                guard let row = w.row else { throw BrineStepError("no rebuilt row") }
                guard row.state.rawValue == want else {
                    throw BrineStepError("expected \(want) after rebuild, got \(row.state.rawValue)")
                }
            },
            defineCheck("my rejection and comment are recorded for the action spotter to learn from") { _, _, _ in
                let records = ActionFeedbackStore.load(captureId: w.captureId, baseDir: w.dir)
                guard let r = records.last(where: { $0.kind == .rejected }) else {
                    throw BrineStepError("no rejection recorded")
                }
                guard r.utterance == w.utterance, !r.comment.isEmpty else {
                    throw BrineStepError("rejection record incomplete: \(r)")
                }
            },
            defineCheck("the rejection is recorded for the action spotter to learn from") { _, _, _ in
                let records = ActionFeedbackStore.load(captureId: w.captureId, baseDir: w.dir)
                guard records.contains(where: { $0.kind == .rejected && $0.utterance == w.utterance }) else {
                    throw BrineStepError("no rejection recorded")
                }
            },
            defineCheck("my refinement is recorded for the action spotter to learn from") { _, _, _ in
                let records = ActionFeedbackStore.load(captureId: w.captureId, baseDir: w.dir)
                guard let r = records.last(where: { $0.kind == .refined }) else {
                    throw BrineStepError("no refinement recorded")
                }
                guard r.utterance == w.utterance, !r.comment.isEmpty else {
                    throw BrineStepError("refinement record incomplete: \(r)")
                }
            },
            defineCheck("the action stays open and shows my note") { _, _, _ in
                let row = try w.firstRow()
                guard row.state == .open else {
                    throw BrineStepError("refine must keep the row open; got \(row.state.rawValue)")
                }
                guard let note = row.note, !note.isEmpty else {
                    throw BrineStepError("the refinement note is not on the row")
                }
            },
            defineCheck("the recorded feedback still carries my comment") { _, _, _ in
                let records = ActionFeedbackStore.load(captureId: w.captureId, baseDir: w.dir)
                guard records.contains(where: {
                    $0.kind == .rejected && $0.comment == "that was just small talk"
                }) else {
                    throw BrineStepError("the comment did not survive")
                }
            },
            defineCheck("there are no actions to act on") { _, _, _ in
                let built = w.rebuild()
                guard built.isEmpty else {
                    throw BrineStepError("expected no rows, got \(built.rows.count)")
                }
            },
        ]
    }
}

// MARK: - Ordering + store units (plan-review finding 1: explicit ordering tests)

final class ActionFeedbackOrderingTests: XCTestCase {
    private var dir: URL!
    private let utterance = "We should get the relay figures into the deck"

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-feedback-order-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func outcomes(_ pairs: [(String, String)]) -> [CardOutcomeRecord] {
        pairs.enumerated().map { i, p in
            CardOutcomeRecord(ts: UInt64(100 + i), outcome: p.0, seed: p.1)
        }
    }

    private func cards(_ records: [CardOutcomeRecord]) -> [ConversationActionCard] {
        let decision = try! JSONDecoder().decode(AmbientDecision.self, from: JSONSerialization.data(withJSONObject: [
            "ts": 100, "captureId": "c1", "windowChars": 480, "outcome": "candidate",
            "candidate": ["utterance": utterance, "summary": "add the figures", "confidence": 0.8],
            "latencyMs": 10,
        ]))
        return ConversationActions.cards(for: "c1", decisions: [decision], outcomes: records)
    }

    /// run → refine must NOT revert Sent-to-chat to pending.
    func testRefineAfterRunKeepsSentToChat() {
        let recs = outcomes([("run", "this came up: \(utterance) — please act"),
                             ("refined", utterance)])
        XCTAssertEqual(cards(recs).first?.outcome, .sentToChat,
                       "a refined line is state-transparent")
    }

    /// reject → refine must NOT lose Not-an-action.
    func testRefineAfterRejectKeepsRejected() {
        let recs = outcomes([("rejected", utterance), ("refined", utterance)])
        XCTAssertEqual(cards(recs).first?.outcome, .rejected)
    }

    /// refine alone leaves the card pending (open).
    func testRefineAloneStaysPending() {
        let recs = outcomes([("refined", utterance)])
        XCTAssertEqual(cards(recs).first?.outcome, .pending)
    }

    /// reject after run: the LAST decisive word wins (the user changed their mind).
    func testRejectAfterRunFlipsToRejected() {
        let recs = outcomes([("run", "this came up: \(utterance) — please act"),
                             ("rejected", utterance)])
        XCTAssertEqual(cards(recs).first?.outcome, .rejected)
    }

    func testRejectedWireMapping() {
        XCTAssertEqual(ActionOutcome(wire: "rejected"), .rejected)
        XCTAssertEqual(ActionOutcome.rejected.label, "Not an action")
        XCTAssertEqual(ConversationActionsPresentation.state(of: .rejected), .notAnAction)
    }

    func testFeedbackStoreRoundTripAndGarbageTolerance() throws {
        ActionFeedbackStore.append(
            ActionFeedbackRecord(captureId: "c1", utterance: utterance,
                                 summary: "add the figures", kind: .refined,
                                 comment: "the Q3 deck, not Q2"),
            baseDir: dir)
        // Garbage between records must be skipped, not fatal.
        let url = ActionFeedbackStore.url(baseDir: dir)
        let existing = try String(contentsOf: url, encoding: .utf8)
        try (existing + "not json at all\n").write(to: url, atomically: true, encoding: .utf8)
        ActionFeedbackStore.append(
            ActionFeedbackRecord(captureId: "c2", utterance: "other", summary: "s",
                                 kind: .rejected, comment: ""),
            baseDir: dir)

        let all = ActionFeedbackStore.load(baseDir: dir)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(ActionFeedbackStore.load(captureId: "c1", baseDir: dir).count, 1)
        XCTAssertEqual(
            ActionFeedbackStore.latestRefinement(forUtterance: utterance, in: all),
            "the Q3 deck, not Q2")
        XCTAssertNil(ActionFeedbackStore.latestRefinement(forUtterance: "other", in: all),
                     "a rejection is not a refinement note")
    }

    /// Only spotter-surfaced rows may log a `run` when their prefill is sent —
    /// answer/user rows carry NO runSeed (a fabricated `run` would poison the
    /// router's true-positive signal and the Activity ledger).
    func testOnlySurfacedRowsCarryARunSeed() throws {
        let decision = try JSONDecoder().decode(AmbientDecision.self, from: JSONSerialization.data(withJSONObject: [
            "ts": 100, "captureId": "c1", "windowChars": 480, "outcome": "candidate",
            "candidate": ["utterance": utterance, "summary": "add the figures", "confidence": 0.8],
            "latencyMs": 10,
        ]))
        let built = ConversationActionsPresentation.build(
            captureId: "c1", decisions: [decision], outcomes: [],
            answers: [LinkedConversationAnswer(title: "what was decided?", text: "the answer")],
            userActions: [UserConversationAction(title: "Book the venue")])
        let byKind = Dictionary(grouping: built.rows, by: \.kind)
        XCTAssertEqual(byKind[.surfaced]?.first?.runSeed, utterance)
        for row in byKind[.answer] ?? [] {
            XCTAssertNotNil(row.seed, "answer rows still offer act-in-chat")
            XCTAssertNil(row.runSeed, "…but never log a run")
        }
        for row in byKind[.user] ?? [] {
            XCTAssertNotNil(row.seed)
            XCTAssertNil(row.runSeed)
        }
    }

    func testChatSeedTemplates() {
        let seed = ConversationActionsPresentation.chatSeed(
            utterance: utterance, summary: "add the figures")
        XCTAssertTrue(seed.contains(utterance))
        XCTAssertTrue(seed.contains("add the figures"))
        XCTAssertTrue(
            ConversationActionsPresentation.chatSeed(utterance: utterance, summary: "")
                .contains("help with that"),
            "an empty summary degrades to the generic ask, never an empty prompt")
        XCTAssertTrue(ConversationActionsPresentation
            .userActionSeed(title: "Book the venue").contains("Book the venue"))
    }
}
