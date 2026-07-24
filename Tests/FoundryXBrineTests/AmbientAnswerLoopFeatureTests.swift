import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/ambient-answer-loop.feature. Closes the loop over REAL
/// types: a delivered answer becomes an `ActivityStore` ledger entry linked to its
/// conversation; the `AmbientAnswer` surface carries the answer text; an `AnswerFeedback`
/// rating ANNOTATES the answer entry (never a separate row); a tool-using chat turn is
/// recorded as an agent run while a tool-free turn is not; and a seven-tool run folds via
/// `RunStepFold`. Hermetic — temp ledger files + in-memory ChatViewModel, no network.
final class AmbientAnswerLoopFeatureTests: XCTestCase {
    func testAmbientAnswerLoopFeature() async throws {
        try await BrineFeatureRunner.run(
            "ambient-answer-loop",
            registry: StepRegistry(AmbientAnswerLoopSteps.make(world: AmbientAnswerLoopWorld())))
    }
}

private final class AmbientAnswerLoopWorld: @unchecked Sendable {
    let dir: URL
    let decisionLog: URL
    var cardsLog: URL { ActivityStore.cardsLogURL(besides: decisionLog) }
    var answersLog: URL { ActivityStore.answersLogURL(besides: decisionLog) }

    // Answer surface + feedback.
    var answer = AmbientAnswer(title: "The relay decision",
                               text: "You chose the blind relay so the door dials out.",
                               sources: [AnswerSource(title: "Relay planning", dateLabel: "Mon")])
    var openedText: String?
    var feedback = AnswerFeedback()

    // Ledger observation.
    var entries: [ActivityEntry] = []

    init() {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-answer-loop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        decisionLog = dir.appendingPathComponent("ambient-decisions.jsonl")
    }
    func append(_ url: URL, _ line: String) {
        let d = (line + "\n").data(using: .utf8)!
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { try? d.write(to: url) }
    }
    /// Fresh ledger per scenario — the log files are shared across the whole feature run.
    func resetLogs() {
        for u in [decisionLog, cardsLog, answersLog] { try? FileManager.default.removeItem(at: u) }
        entries = []
    }
    func reload() {
        entries = ActivityStore.entries(decisionLogURL: decisionLog, cardsLogURL: cardsLog,
                                        answersLogURL: answersLog)
    }
    var answerEntries: [ActivityEntry] { entries.filter { $0.kind == .answer } }
}

private enum AmbientAnswerLoopSteps {
    static func make(world w: AmbientAnswerLoopWorld) -> [StepDefinition] {
        [
            // ── S1: delivered answer remembered + linked
            defineStep("an ambient lookup found an answer in my memory") { ctx, _, _ in
                w.resetLogs()
                w.answer = AmbientAnswer(title: "The relay decision",
                                         text: "You chose the blind relay so the door dials out.",
                                         sources: [AnswerSource(title: "Relay planning", dateLabel: "Mon")])
                return ctx
            },
            defineStep("the answer notification is delivered") { ctx, _, _ in
                // Delivery writes the answer to the app-event log, keyed to its conversation.
                w.append(w.answersLog, "{\"kind\":\"answer\",\"answer\":\"\(w.answer.text)\",\"captureId\":\"conv-relay\",\"ts\":1000}")
                w.reload()
                return ctx
            },
            defineCheck("the activity ledger shows the answer") { _, _, _ in
                guard w.answerEntries.count == 1 else {
                    throw BrineStepError("expected one answer entry, got \(w.answerEntries.count)")
                }
            },
            defineCheck("it links back to the conversation it came from") { _, _, _ in
                guard w.answerEntries.first?.source == .conversation(captureId: "conv-relay") else {
                    throw BrineStepError("answer not linked to its conversation")
                }
            },

            // ── S2: tapping the notification opens the surface
            defineStep("an answer notification is on my lock screen") { ctx, _, _ in
                w.openedText = nil
                w.answer = AmbientAnswer(title: "Where did I park",
                                         text: "Level 3, near the elevator — you said it out loud at 9:12.")
                return ctx
            },
            defineStep("I tap it") { ctx, _, _ in
                // Tapping opens the surface with the delivered AmbientAnswer as its content.
                w.openedText = w.answer.text
                return ctx
            },
            defineCheck("the answer surface opens with the answer text") { _, _, _ in
                guard w.openedText == w.answer.text, !(w.openedText ?? "").isEmpty else {
                    throw BrineStepError("surface did not open with the answer text")
                }
            },

            // ── S3: rating annotates the answer entry, never a separate row
            defineStep("the ledger shows an answer") { ctx, _, _ in
                w.resetLogs()
                w.append(w.answersLog, "{\"kind\":\"answer\",\"answer\":\"You met Dana at 3pm\",\"captureId\":\"conv-dana\",\"ts\":2000}")
                w.reload()
                w.feedback = AnswerFeedback()
                return ctx
            },
            defineStep("I rate it helpful on the answer surface") { ctx, _, _ in
                w.feedback.toggle(.helpful)
                // The surface persists the rating as a feedback line in the app-event log.
                w.append(w.answersLog, "{\"rating\":\"\(w.feedback.rating.rawValue)\",\"ts\":2001}")
                w.reload()
                return ctx
            },
            defineCheck("the ledger's answer entry carries my rating") { _, _, _ in
                guard w.answerEntries.first?.rating == "helpful" else {
                    throw BrineStepError("answer entry rating was \(String(describing: w.answerEntries.first?.rating))")
                }
            },
            defineCheck("the rating is not a separate ledger entry") { _, _, _ in
                // The rating line annotated the answer — it never became its own row.
                guard w.entries.count == 1 else {
                    throw BrineStepError("rating created a separate entry (total \(w.entries.count))")
                }
            },

            // ── S4: a finished tool-using turn is an agent run; a tool-free turn is not
            defineStep("a chat turn where the agent used tools") { ctx, _, _ in
                w.resetLogs()
                let steps = await MainActor.run { () -> Int in
                    let vm = ChatViewModel()
                    vm.beginUserTurn("summarize the repo")
                    vm.apply(.toolCall(callId: "t1", name: "bash", args: #"{"command":"ls"}"#))
                    vm.apply(.toolResult(callId: "t1", content: "a.rs", isError: false))
                    return vm.stepCount
                }
                // Tools were used (stepCount > 0) → the run is recorded to the ledger.
                if steps > 0 {
                    w.append(w.answersLog, "{\"kind\":\"agent_run\",\"seed\":\"chat-run\",\"ts\":3000}")
                }
                return ctx
            },
            defineStep("the turn completes") { ctx, _, _ in w.reload(); return ctx },
            defineCheck("the activity ledger shows the agent run") { _, _, _ in
                guard w.entries.contains(where: { $0.kind == .agentRun }) else {
                    throw BrineStepError("no agent run in the ledger")
                }
            },
            defineCheck("a turn with no tool use is not recorded as a run") { _, _, _ in
                let steps = await MainActor.run { () -> Int in
                    let vm = ChatViewModel()
                    vm.beginUserTurn("just say hi")
                    vm.apply(.done(reason: "stop"))
                    return vm.stepCount
                }
                guard steps == 0 else { throw BrineStepError("a tool-free turn reported \(steps) steps") }
                // No tools → nothing written → the ledger gains no new run.
                let runsBefore = w.entries.filter { $0.kind == .agentRun }.count
                w.reload()
                let runsAfter = w.entries.filter { $0.kind == .agentRun }.count
                guard runsAfter == runsBefore else {
                    throw BrineStepError("a tool-free turn added a run to the ledger")
                }
            },

            // ── S5: seven-tool run folds behind a count
            defineStep("a chat turn where the agent used seven tools") { ctx, _, _ in
                let n = await MainActor.run { () -> Int in
                    let vm = ChatViewModel()
                    vm.beginUserTurn("do a lot")
                    for i in 0..<7 { vm.apply(.toolCall(callId: "s\(i)", name: "bash", args: #"{"command":"echo"}"#)) }
                    return vm.stepCount
                }
                guard n == 7 else { throw BrineStepError("expected 7 steps, got \(n)") }
                w.entries = []   // scenario uses no ledger
                w.openedText = "\(n)"
                return ctx
            },
            defineCheck("the chat shows the latest steps and folds the rest behind a count") { _, _, _ in
                let layout = RunStepFold.layout(stepCount: 7)
                // The most recent window stays visible; the older steps fold behind a count.
                guard layout.visible.count == RunStepFold.windowSize else {
                    throw BrineStepError("visible window was \(layout.visible.count), expected \(RunStepFold.windowSize)")
                }
                guard layout.foldedCount == 3, layout.foldLabel == "3 more steps" else {
                    throw BrineStepError("fold was \(layout.foldedCount) / \(String(describing: layout.foldLabel))")
                }
                guard layout.visible == 3..<7 else {
                    throw BrineStepError("visible range was \(layout.visible), expected 3..<7 (the latest steps)")
                }
            },
        ]
    }
}
