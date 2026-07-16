import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/chat-agentic-legibility.feature. Drives the REAL
/// `ChatViewModel` folding tool events (the same folds ChatAgenticTraceTests unit-tests):
/// an inline activity row per tool action naming the tool + its primary arg, the row
/// closing and carrying its output once the result arrives, the live status line, the
/// completed step count, and rich approval detail that shows exactly what will run while
/// the turn stays suspended. Hermetic — no door, no network.
final class ChatAgenticLegibilityFeatureTests: XCTestCase {
    func testChatAgenticLegibilityFeature() async throws {
        try await BrineFeatureRunner.run("chat-agentic-legibility",
                                         registry: StepRegistry(ChatAgenticLegibilitySteps.make(world: .init())))
    }
}

@MainActor
private final class ChatLegibilityWorld: @unchecked Sendable {
    var vm = ChatViewModel()
    var pendingName = ""
    var pendingArgs = ""
    var detail: ChatViewModel.ApprovalDetail?

    func newChat() { vm = ChatViewModel() }
}

private enum ChatAgenticLegibilitySteps {
    static func make(world w: ChatLegibilityWorld) -> [StepDefinition] {
        [
            // MARK: the user can tell chat is agentic
            defineStep("I open a new chat") { ctx, _, _ in
                await MainActor.run { w.newChat() }; return ctx
            },
            defineCheck("I see a clear signal that the assistant can read/write files and run commands") { _, _, _ in
                let signal = ChatViewModel.agenticAffordance
                let lower = signal.lowercased()
                guard !signal.isEmpty, lower.contains("file"), lower.contains("command") else {
                    throw BrineStepError("no clear agentic signal (got: \(signal))")
                }
            },

            // MARK: tool activity visible inline
            defineStep("a turn is in flight") { ctx, _, _ in
                await MainActor.run { w.newChat(); w.vm.beginUserTurn("go") }; return ctx
            },
            defineStep("the assistant reads a file and runs a command") { ctx, _, _ in
                await MainActor.run {
                    w.vm.apply(.toolCall(callId: "c1", name: "read", args: #"{"file_path":"/repo/foo.rs"}"#))
                    w.vm.apply(.toolCall(callId: "c2", name: "bash", args: #"{"command":"ls -la"}"#))
                }
                return ctx
            },
            defineCheck("I see one inline activity row per tool action") { _, _, _ in
                let n = await MainActor.run { w.vm.activities.count }
                guard n == 2 else { throw BrineStepError("expected one row per tool action, got \(n)") }
            },
            defineCheck("each row names the tool and its primary argument") { _, _, _ in
                let ok = await MainActor.run { () -> Bool in
                    let a = w.vm.activities
                    guard a.count == 2 else { return false }
                    return a[0].name == "read" && a[0].summary.contains("foo.rs")
                        && a[1].name == "bash" && a[1].summary.contains("ls -la")
                }
                guard ok else { throw BrineStepError("rows did not name the tool + primary argument") }
            },

            // MARK: a tool row shows its result once complete
            defineStep("the assistant ran a command in the current turn") { ctx, _, _ in
                await MainActor.run {
                    w.newChat(); w.vm.beginUserTurn("what files are here")
                    w.vm.apply(.toolCall(callId: "c2", name: "bash", args: #"{"command":"ls"}"#))
                }
                return ctx
            },
            defineStep("the tool result arrives") { ctx, _, _ in
                await MainActor.run {
                    w.vm.apply(.toolResult(callId: "c2", content: "foo.rs\nbar.rs", isError: false))
                }
                return ctx
            },
            defineCheck("the row for that command is no longer running") { _, _, _ in
                let running = await MainActor.run { w.vm.activities.first { $0.id == "c2" }?.isRunning }
                guard running == false else { throw BrineStepError("the completed command row is still running") }
            },
            defineCheck("the row carries the command's output for expansion") { _, _, _ in
                let content = await MainActor.run { w.vm.activities.first { $0.id == "c2" }?.resultContent }
                guard content == "foo.rs\nbar.rs" else {
                    throw BrineStepError("row did not carry the output (\(String(describing: content)))")
                }
            },

            // MARK: live status line + step count
            defineStep("the assistant is running a command") { ctx, _, _ in
                await MainActor.run { w.vm.apply(.toolCall(callId: "c2", name: "bash", args: #"{"command":"npm test"}"#)) }
                return ctx
            },
            defineCheck("the status line reads that it is running that tool") { _, _, _ in
                let line = await MainActor.run { w.vm.statusLine }
                guard line == "Running: npm test…" else { throw BrineStepError("status line was \(line)") }
            },
            defineCheck("when the turn completes the status line reports the number of steps") { _, _, _ in
                let line = await MainActor.run { () -> String? in
                    w.vm.apply(.done(reason: "stop"))
                    return w.vm.statusLine
                }
                guard line == "Done (1 step)" else { throw BrineStepError("completed status line was \(line ?? "nil")") }
            },

            // MARK: approval shows exactly what will run
            defineStep("the assistant wants to run a shell command") { ctx, _, _ in
                await MainActor.run {
                    w.newChat(); w.vm.beginUserTurn("run something")
                    w.pendingName = "bash"; w.pendingArgs = #"{"command":"rm -rf build"}"#
                }
                return ctx
            },
            defineStep("the assistant wants to edit a file") { ctx, _, _ in
                await MainActor.run {
                    w.newChat(); w.vm.beginUserTurn("fix the bug")
                    w.pendingName = "edit"
                    w.pendingArgs = #"{"file_path":"/repo/src/bar.rs","old_string":"let x = 1","new_string":"let x = 2"}"#
                }
                return ctx
            },
            defineStep("the approval prompt appears") { ctx, _, _ in
                await MainActor.run {
                    w.detail = ChatViewModel.approvalDetail(name: w.pendingName, argsJSON: w.pendingArgs)
                    w.vm.apply(.approvalRequest(callId: "c9", name: w.pendingName, args: w.pendingArgs))
                }
                return ctx
            },
            defineCheck("it shows the exact command before I approve") { _, _, _ in
                let (kind, command) = await MainActor.run { (w.detail?.kind, w.detail?.command) }
                guard kind == .command, command == "rm -rf build" else {
                    throw BrineStepError("approval did not surface the exact command (\(String(describing: command)))")
                }
            },
            defineCheck("the turn stays suspended until I answer") { _, _, _ in
                let suspended = await MainActor.run { () -> Bool in
                    if case .awaitingApproval(let callId, let name, _) = w.vm.turnState {
                        return callId == "c9" && name == w.pendingName
                    }
                    return false
                }
                guard suspended else { throw BrineStepError("the turn did not stay suspended awaiting approval") }
            },
            defineCheck("it shows the file path and the before/after text of the edit") { _, _, _ in
                let (kind, filePath, oldText, newText) = await MainActor.run {
                    (w.detail?.kind, w.detail?.filePath, w.detail?.oldText, w.detail?.newText)
                }
                guard kind == .fileEdit, filePath == "/repo/src/bar.rs",
                      oldText == "let x = 1", newText == "let x = 2" else {
                    throw BrineStepError("edit approval did not show path + before/after (\(String(describing: filePath)))")
                }
            },
        ]
    }
}
