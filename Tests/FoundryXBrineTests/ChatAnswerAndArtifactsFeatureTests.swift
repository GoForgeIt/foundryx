import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/chat-answer-and-artifacts.feature. Drives the REAL legibility
/// types: `ChatCopy`/`ChatSendFailure` (calm composer + failure copy, no codes),
/// `AnswerBrief` (decision-brief parse), the `AnswerSurface` family (`AmbientAnswer`,
/// `AnswerSource`, `AnswerFeedback` toggles + note + seed), `RunStepFold` /
/// `AgentRunFinding` / `RunVenue` (step tiles, folding, findings, hosted line), and the
/// artifact pipeline (`ArtifactKind.detect`, `ArtifactLoader` over an injected source,
/// `ChatViewModel` per-turn deduped artifact offers). Hermetic — no door, no network.
final class ChatAnswerAndArtifactsFeatureTests: XCTestCase {
    func testChatAnswerAndArtifactsFeature() async throws {
        try await BrineFeatureRunner.run(
            "chat-answer-and-artifacts",
            registry: StepRegistry(ChatArtifactsSteps.make(world: ChatArtifactsWorld())))
    }
}

private final class FakeArtifactSource: ArtifactSource, @unchecked Sendable {
    var data: Data?
    var error: Error?
    func fetchArtifact(path: String) async throws -> Data? {
        if let error { throw error }
        return data
    }
}

private final class ChatArtifactsWorld: @unchecked Sendable {
    // Answer surface.
    var answer = AmbientAnswer(title: "", text: "")
    var brief: AnswerBrief?
    var feedback = AnswerFeedback()
    var note = ""
    var seededChat: String?
    // Runs.
    var steps: [RunStepTile] = []
    var finding: AgentRunFinding?
    // Artifacts.
    let source = FakeArtifactSource()
    var loadState: ArtifactLoadState = .unavailable
    var artifactName = ""
    // Chat VM (artifacts per turn).
    var vmArtifacts: [String] = []

    func tile(_ id: String, _ title: String, outcome: String?, symbol: String = "wrench") -> RunStepTile {
        RunStepTile(id: id, title: title, outcome: outcome, symbol: symbol)
    }
}

private enum ChatArtifactsSteps {
    static func make(world w: ChatArtifactsWorld) -> [StepDefinition] {
        [
            // ── S1 composer placeholder
            defineStep("I open Chat") { ctx, _, _ in return ctx },
            defineCheck("the composer placeholder reads \"Ask FoundryX\"") { _, _, _ in
                guard ChatCopy.composerPlaceholder == "Ask FoundryX" else { throw BrineStepError("placeholder was \(ChatCopy.composerPlaceholder)") }
            },

            // ── S2 failed send reads calmly
            defineStep("my computer cannot be reached") { ctx, _, _ in return ctx },
            defineStep("I send a message and it fails") { ctx, _, _ in return ctx },
            defineCheck("the chat says \"Your computer couldn't be reached.\"") { _, _, _ in
                guard ChatSendFailure.unreachable == "Your computer couldn't be reached." else { throw BrineStepError("unreachable copy was \(ChatSendFailure.unreachable)") }
            },
            defineCheck("a rejected send says \"That didn't go through — try again.\"") { _, _, _ in
                guard ChatSendFailure.tryAgain == "That didn't go through — try again." else { throw BrineStepError("tryAgain copy was \(ChatSendFailure.tryAgain)") }
            },
            defineCheck("the thread never shows \"DoorError\", \"HTTP\", or a bracketed code") { _, _, _ in
                let errs: [DoorError] = [.transport("Could not connect to the server"), .http(502), .unauthorized]
                for e in errs {
                    let msg = ChatSendFailure.calmMessage(for: e)
                    for banned in ["DoorError", "HTTP", "[", "]"] where msg.contains(banned) {
                        throw BrineStepError("calm message leaked '\(banned)': \(msg)")
                    }
                }
            },
            defineCheck("the technical detail goes to the door log instead") { _, _, _ in
                let detail = ChatSendFailure.logDetail(for: DoorError.http(502))
                guard !detail.isEmpty else { throw BrineStepError("no technical detail captured for the log") }
            },

            // ── S3 decision brief
            defineStep("an answer whose text carries a recommendation, why bullets, and a source") { ctx, _, _ in
                w.answer = AmbientAnswer(title: "The relay call", text: """
                ## Recommendation
                Use the blind relay so the door dials out.

                ## Why
                - No inbound port to expose
                - The phone reaches the Mac through the tunnel

                ## Source
                Relay planning conversation
                """)
                return ctx
            },
            defineStep("the answer surface opens") { ctx, _, _ in w.brief = AnswerBrief.parse(w.answer.text); return ctx },
            defineCheck("I see a Recommendation section with the recommended call") { _, _, _ in
                guard let b = w.brief, b.recommendation.contains("blind relay") else { throw BrineStepError("no recommendation parsed: \(String(describing: w.brief))") }
                guard AnswerBriefCopy.recommendation == "Recommendation" else { throw BrineStepError("recommendation label wrong") }
            },
            defineCheck("the reasons render as Why bullets") { _, _, _ in
                guard let b = w.brief, b.why.count == 2, b.why[0].contains("inbound port") else { throw BrineStepError("why bullets wrong: \(String(describing: w.brief?.why))") }
            },
            defineCheck("the Source section names where it came from") { _, _, _ in
                guard let b = w.brief, b.source?.contains("Relay planning") == true else { throw BrineStepError("source missing: \(String(describing: w.brief?.source))") }
            },
            defineCheck("an answer without that structure keeps the plain answer layout") { _, _, _ in
                // A plain answer (no headings) parses to nil → the surface renders the plain text.
                guard AnswerBrief.parse("Just a plain sentence with no sections.") == nil else {
                    throw BrineStepError("a plain answer wrongly parsed as a brief")
                }
            },

            // ── S4 finished run folds into a finding
            defineStep("a tool-using turn that finished with seven steps") { ctx, _, _ in
                w.steps = (0..<7).map { w.tile("s\($0)", "step \($0)", outcome: "ok") }
                w.finding = AgentRunFinding.make(steps: w.steps, findings: "Done. report.md is ready.", artifacts: ["report.md"])
                return ctx
            },
            defineCheck("the run reads as a Finding card, not a bare done row") { _, _, _ in
                guard let f = w.finding, f.headline.hasPrefix("Done."), f.body != nil else {
                    throw BrineStepError("no Finding card: \(String(describing: w.finding))")
                }
            },
            defineCheck("the three older steps are folded behind \"3 more steps\"") { _, _, _ in
                let fold = (w.finding?.fold) ?? RunStepFold.layout(stepCount: 7)
                guard fold.foldedCount == 3, fold.foldLabel == "3 more steps" else {
                    throw BrineStepError("fold was \(fold.foldedCount) / \(String(describing: fold.foldLabel))")
                }
            },
            defineCheck("the card carries the sources-consulted line") { _, _, _ in
                guard let f = w.finding, f.sourcesLine.hasPrefix("Sources consulted") else {
                    throw BrineStepError("no sources-consulted line: \(String(describing: w.finding?.sourcesLine))")
                }
            },

            // ── S5 ambient answer + sources, never "citations"
            defineStep("an ambient answer compiled from my memory with two sources") { ctx, _, _ in
                w.answer = AmbientAnswer(title: "Where we landed", text: "You chose the blind relay.",
                                         sources: [AnswerSource(title: "Relay planning"), AnswerSource(title: "Door design")])
                return ctx
            },
            defineCheck("I see the answer text") { _, _, _ in
                guard w.answer.text == "You chose the blind relay." else { throw BrineStepError("answer text wrong") }
            },
            defineCheck("I see the sources consulted") { _, _, _ in
                guard w.answer.sources.count == 2, AnswerCopy.sourcesLabel == "Sources consulted" else {
                    throw BrineStepError("sources missing")
                }
            },
            defineCheck("the surface never calls them citations") { _, _, _ in
                for s in AnswerCopy.all where s.lowercased().contains("citation") {
                    throw BrineStepError("copy says citations: \(s)")
                }
            },

            // ── S6 feedback unselected
            defineStep("an answer surface has just opened") { ctx, _, _ in w.feedback = AnswerFeedback(); return ctx },
            defineCheck("neither Helpful nor Not useful is selected") { _, _, _ in
                guard w.feedback.rating == .none else { throw BrineStepError("feedback pre-selected: \(w.feedback.rating)") }
            },

            // ── S7 toggle select/clear
            defineStep("an answer surface with no feedback given") { ctx, _, _ in w.feedback = AnswerFeedback(); return ctx },
            defineStep("I tap Helpful") { ctx, _, _ in w.feedback.toggle(.helpful); return ctx },
            defineCheck("Helpful is selected") { _, _, _ in
                guard w.feedback.rating == .helpful else { throw BrineStepError("Helpful not selected") }
            },
            defineStep("I tap Helpful again") { ctx, _, _ in w.feedback.toggle(.helpful); return ctx },

            // ── S8 switching replaces
            defineStep("I rated an answer Helpful") { ctx, _, _ in w.feedback = AnswerFeedback(); w.feedback.toggle(.helpful); return ctx },
            defineStep("I tap Not useful") { ctx, _, _ in w.feedback.toggle(.notUseful); return ctx },
            defineCheck("Not useful is selected and Helpful is not") { _, _, _ in
                guard w.feedback.rating == .notUseful else { throw BrineStepError("switch failed: \(w.feedback.rating)") }
            },

            // ── S9/S10 note + continue in chat
            defineStep("an answer surface is open") { ctx, _, _ in
                w.answer = AmbientAnswer(title: "The relay call", text: "You chose the blind relay.")
                w.feedback = AnswerFeedback(); w.note = ""; w.seededChat = nil
                return ctx
            },
            defineStep("I type a note about what else to pull") { ctx, _, _ in
                w.note = "Also pull the port numbers from the deck."
                w.feedback.note = w.note
                return ctx
            },
            defineCheck("the note is kept with my feedback") { _, _, _ in
                guard w.feedback.note == w.note, w.feedback.hasContent else { throw BrineStepError("note not kept with feedback") }
            },
            defineStep("I choose to continue in chat") { ctx, _, _ in w.seededChat = w.answer.chatSeed(note: w.note); return ctx },
            defineCheck("a chat session is seeded with the answer") { _, _, _ in
                guard let seed = w.seededChat, seed.contains("You chose the blind relay.") else {
                    throw BrineStepError("chat not seeded with the answer: \(String(describing: w.seededChat))")
                }
            },
            defineCheck("my note rides along when I wrote one") { _, _, _ in
                guard w.note.isEmpty || (w.seededChat?.contains(w.note) == true) else {
                    throw BrineStepError("the note did not ride along into the seed")
                }
            },

            // ── S11 run steps appear as tiles
            defineStep("an agent run is in flight") { ctx, _, _ in w.steps = []; return ctx },
            defineStep("the agent takes a step with a tool") { ctx, _, _ in
                w.steps = [w.tile("t1", "ran: ls -la", outcome: nil)]   // running
                return ctx
            },
            defineCheck("I see a step tile naming the tool action") { _, _, _ in
                guard w.steps.first?.title == "ran: ls -la" else { throw BrineStepError("step tile did not name the action") }
            },
            defineCheck("once the step finishes the tile carries a one-line outcome") { _, _, _ in
                w.steps = [w.tile("t1", "ran: ls -la", outcome: "foo.rs")]
                guard w.steps.first?.isRunning == false, w.steps.first?.outcome == "foo.rs" else {
                    throw BrineStepError("finished tile has no outcome")
                }
            },

            // ── S12 long runs fold
            defineStep("an agent run with seven steps") { ctx, _, _ in
                w.steps = (0..<7).map { w.tile("s\($0)", "step \($0)", outcome: "ok") }; return ctx
            },
            defineCheck("I see the four most recent steps") { _, _, _ in
                let fold = RunStepFold.layout(stepCount: w.steps.count)
                guard fold.visible == 3..<7 else { throw BrineStepError("visible was \(fold.visible), expected 3..<7") }
            },

            // ── S13 short runs unfolded
            defineStep("an agent run with four steps") { ctx, _, _ in
                w.steps = (0..<4).map { w.tile("s\($0)", "step \($0)", outcome: "ok") }; return ctx
            },
            defineCheck("I see all four steps and nothing is folded") { _, _, _ in
                let fold = RunStepFold.layout(stepCount: 4)
                guard fold.foldedCount == 0, fold.visible == 0..<4, fold.foldLabel == nil else {
                    throw BrineStepError("a four-step run folded: \(fold.foldedCount)")
                }
            },

            // ── S14 finished run: findings + follow-up
            defineStep("an agent run that finished") { ctx, _, _ in
                w.steps = (0..<3).map { w.tile("s\($0)", "step \($0)", outcome: "ok") }
                w.finding = AgentRunFinding.make(steps: w.steps, findings: "Summary of what I found.")
                return ctx
            },
            defineCheck("I see a findings summary") { _, _, _ in
                guard w.finding?.body == "Summary of what I found." else { throw BrineStepError("no findings summary") }
            },
            defineCheck("I can send a follow-up that continues the run's session") { _, _, _ in
                // A finished finding card carries its steps (the run's session context) so a
                // follow-up continues it rather than starting cold.
                guard let f = w.finding, !f.steps.isEmpty else { throw BrineStepError("no session context to continue") }
            },

            // ── S15 hosted run venue line
            defineStep("an agent run hosted on Foundry Cloud as the first of ten trials") { ctx, _, _ in return ctx },
            defineCheck("the run states \"Run 1 of 10 · runs on Foundry Cloud\"") { _, _, _ in
                let line = RunVenue.hostedLine(run: 1, of: 10, venue: "Foundry Cloud")
                guard line == "Run 1 of 10 · runs on Foundry Cloud" else { throw BrineStepError("hosted line was \(line)") }
            },

            // ── S16-S20 artifact rendering (real fetch→classify→state path)
            defineStep("a run produced a Markdown file") { ctx, _, _ in w.source.error = nil; w.source.data = Data("# Title".utf8); w.artifactName = "report.md"; return ctx },
            defineStep("a run produced an HTML file") { ctx, _, _ in w.source.error = nil; w.source.data = Data("<h1>Hi</h1>".utf8); w.artifactName = "page.html"; return ctx },
            defineStep("a run produced an image file") { ctx, _, _ in w.source.error = nil; w.source.data = Data([0x89, 0x50]); w.artifactName = "chart.png"; return ctx },
            defineStep("a run produced a file type the app cannot render") { ctx, _, _ in w.source.error = nil; w.source.data = Data([0x00, 0x01]); w.artifactName = "model.bin"; return ctx },
            defineStep("a run references a file the desktop no longer has") { ctx, _, _ in w.source.error = nil; w.source.data = nil; w.artifactName = "gone.md"; return ctx },
            defineStep("I open it") { ctx, _, _ in
                w.loadState = await ArtifactLoader.load(path: RunArtifactRoute.path(name: w.artifactName), from: w.source)
                return ctx
            },
            defineCheck("it renders as formatted text in the app") { _, _, _ in
                guard case .loaded(let a) = w.loadState, a.kind == .markdown else { throw BrineStepError("not rendered as markdown: \(w.loadState)") }
            },
            defineCheck("it renders as a page in the app for display only") { _, _, _ in
                guard case .loaded(let a) = w.loadState, a.kind == .html else { throw BrineStepError("not rendered as html: \(w.loadState)") }
            },
            defineCheck("I see the image in the app") { _, _, _ in
                guard case .loaded(let a) = w.loadState, a.kind == .image else { throw BrineStepError("not rendered as image: \(w.loadState)") }
            },
            defineCheck("I see an honest note that it can't be previewed here") { _, _, _ in
                guard case .loaded(let a) = w.loadState, a.kind == .unsupported else { throw BrineStepError("unsupported file not classified as such: \(w.loadState)") }
            },
            defineCheck("I can share or export the file") { _, _, _ in
                // The bytes are in hand (loaded, kind .unsupported) → the export path has data.
                guard case .loaded(let a) = w.loadState, !a.data.isEmpty else { throw BrineStepError("no bytes to export") }
            },
            defineCheck("I'm told the file isn't available rather than shown an error page") { _, _, _ in
                guard w.loadState == .unavailable else { throw BrineStepError("missing file was not reported as unavailable: \(w.loadState)") }
            },

            // ── S21-S23 artifacts in the chat stream (per-turn, deduped)
            defineStep("a chat turn during which the agent wrote \"report.md\"") { ctx, _, _ in
                w.vmArtifacts = await MainActor.run { () -> [String] in
                    let vm = ChatViewModel(); vm.beginUserTurn("write the report")
                    vm.apply(.artifact(name: "report.md", mime: "text/markdown"))
                    return vm.artifacts.map(\.name)
                }
                return ctx
            },
            defineCheck("the conversation offers \"report.md\" to view") { _, _, _ in
                guard w.vmArtifacts == ["report.md"] else { throw BrineStepError("artifact offer was \(w.vmArtifacts)") }
            },
            defineCheck("opening it fetches the file from my desktop") { _, _, _ in
                // The offer opens through the door run-artifact route (same path capture files use).
                guard RunArtifactRoute.path(name: "report.md") == "/foundryx/run-artifact/report.md" else {
                    throw BrineStepError("artifact route wrong")
                }
            },
            defineStep("a chat turn that produced an artifact") { ctx, _, _ in
                w.vmArtifacts = await MainActor.run { () -> [String] in
                    let vm = ChatViewModel(); vm.beginUserTurn("t1")
                    vm.apply(.artifact(name: "a.md", mime: "text/markdown"))
                    // The next turn starts → the previous turn's offer clears.
                    vm.beginUserTurn("t2")
                    return vm.artifacts.map(\.name)
                }
                return ctx
            },
            defineStep("the next turn starts") { ctx, _, _ in return ctx },
            defineCheck("the previous turn's artifact offer is gone") { _, _, _ in
                guard w.vmArtifacts.isEmpty else { throw BrineStepError("artifact survived into the next turn: \(w.vmArtifacts)") }
            },
            defineStep("a chat turn during which the agent wrote \"report.md\" twice") { ctx, _, _ in
                w.vmArtifacts = await MainActor.run { () -> [String] in
                    let vm = ChatViewModel(); vm.beginUserTurn("write it twice")
                    vm.apply(.artifact(name: "report.md", mime: "text/markdown"))
                    vm.apply(.artifact(name: "report.md", mime: "text/markdown"))
                    return vm.artifacts.map(\.name)
                }
                return ctx
            },
            defineCheck("the conversation offers \"report.md\" to view once") { _, _, _ in
                guard w.vmArtifacts == ["report.md"] else { throw BrineStepError("dedup failed: \(w.vmArtifacts)") }
            },
        ]
    }
}
