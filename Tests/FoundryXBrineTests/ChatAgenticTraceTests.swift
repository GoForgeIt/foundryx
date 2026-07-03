import XCTest
@testable import FoundryXKit

/// The phone chat runs Kiln's full agentic loop (Mode-B: read/write/edit/bash + MCP). This
/// track makes that LEGIBLE: an inline tool-activity trace, a live status line, step counts,
/// and rich approval cards. These drive the REAL ChatViewModel folding REAL DoorEvents parsed
/// from the REAL kiln-runtime SSE wire shape (`tool_call`/`tool_result` keyed by `id`,
/// `approval_request` keyed by `call_id`) — no mocks.
@MainActor
final class ChatAgenticTraceTests: XCTestCase {

    // MARK: SSE wire shape — kiln-runtime tags tool_call/tool_result by `id`

    func testParsesToolCallByIdNotCallId() {
        guard case .toolCall(let id, let name, let args) = DoorEvent.parse(
            #"{"type":"tool_call","id":"c1","name":"read","args":{"file_path":"/repo/foo.rs"}}"#
        ) else { return XCTFail("expected tool_call") }
        XCTAssertEqual(id, "c1", "kiln keys tool_call by `id`, not `call_id`")
        XCTAssertEqual(name, "read")
        XCTAssertTrue(args.contains("foo.rs"))
    }

    func testParsesToolResultByIdWithError() {
        guard case .toolResult(let id, let content, let isError) = DoorEvent.parse(
            #"{"type":"tool_result","id":"c1","content":"file not found","is_error":true}"#
        ) else { return XCTFail("expected tool_result") }
        XCTAssertEqual(id, "c1")
        XCTAssertEqual(content, "file not found")
        XCTAssertTrue(isError)
    }

    func testParsesApprovalRequestByCallId() {
        guard case .approvalRequest(let callId, let name, let args) = DoorEvent.parse(
            #"{"type":"approval_request","call_id":"c9","name":"bash","args":{"command":"ls -la"}}"#
        ) else { return XCTFail("expected approval_request") }
        XCTAssertEqual(callId, "c9")
        XCTAssertEqual(name, "bash")
        XCTAssertTrue(args.contains("ls -la"))
    }

    // MARK: Inline tool-activity trace

    func testToolActivityRowsAppearAsToolsRun() {
        let m = ChatViewModel()
        m.beginUserTurn("clean up the repo")
        XCTAssertTrue(m.activities.isEmpty, "a fresh turn starts with no activity")

        m.apply(.toolCall(callId: "c1", name: "read", args: #"{"file_path":"/repo/foo.rs"}"#))
        m.apply(.toolCall(callId: "c2", name: "bash", args: #"{"command":"ls -la"}"#))
        XCTAssertEqual(m.activities.count, 2, "one row per tool action")

        XCTAssertEqual(m.activities[0].summary, "reading foo.rs", "file tools show the basename")
        XCTAssertEqual(m.activities[1].summary, "running: ls -la", "bash shows the command")
        XCTAssertTrue(m.activities.allSatisfy { $0.isRunning }, "no results yet → all running")
    }

    func testToolResultClosesRowAndCarriesOutput() {
        let m = ChatViewModel()
        m.beginUserTurn("what files are here")
        m.apply(.toolCall(callId: "c2", name: "bash", args: #"{"command":"ls"}"#))
        m.apply(.toolResult(callId: "c2", content: "foo.rs\nbar.rs", isError: false))

        let row = m.activities.first { $0.id == "c2" }
        XCTAssertNotNil(row)
        XCTAssertFalse(row!.isRunning, "the result closed the row")
        XCTAssertEqual(row!.resultContent, "foo.rs\nbar.rs", "the output is retained for expansion")
        XCTAssertEqual(row!.summary, "ran: ls", "verb tenses to past once done")
    }

    func testActivityClearedOnNextTurn() {
        let m = ChatViewModel()
        m.beginUserTurn("one")
        m.apply(.toolCall(callId: "c1", name: "read", args: #"{"file_path":"a.txt"}"#))
        XCTAssertEqual(m.activities.count, 1)
        m.beginUserTurn("two")
        XCTAssertTrue(m.activities.isEmpty, "a new turn starts a fresh trace")
    }

    // MARK: Live status line + step count

    func testStatusLineReflectsRunningTool() {
        let m = ChatViewModel()
        m.beginUserTurn("go")
        XCTAssertEqual(m.statusLine, "Thinking…", "no tokens, no tools yet")

        m.apply(.toolCall(callId: "c2", name: "bash", args: #"{"command":"npm test"}"#))
        XCTAssertEqual(m.statusLine, "Running: npm test…", "status names the running tool + its arg")

        m.apply(.toolResult(callId: "c2", content: "ok", isError: false))
        XCTAssertEqual(m.statusLine, "Thinking…", "tool done, no text yet → back to thinking")
        m.apply(.assistantDelta(text: "All tests pass."))
        XCTAssertEqual(m.statusLine, "Responding…", "text streaming with no running tool → responding")
    }

    func testStatusLineDoneReportsSteps() {
        let m = ChatViewModel()
        m.beginUserTurn("multi-step")
        m.apply(.toolCall(callId: "c1", name: "read", args: #"{"file_path":"a"}"#))
        m.apply(.toolResult(callId: "c1", content: "x", isError: false))
        m.apply(.toolCall(callId: "c2", name: "bash", args: #"{"command":"ls"}"#))
        m.apply(.toolResult(callId: "c2", content: "y", isError: false))
        m.apply(.done(reason: "stop"))

        XCTAssertEqual(m.stepCount, 2)
        XCTAssertEqual(m.statusLine, "Done (2 steps)")
    }

    func testStatusLineDoneSingularAndZero() {
        let one = ChatViewModel()
        one.beginUserTurn("x")
        one.apply(.toolCall(callId: "c1", name: "read", args: "{}"))
        one.apply(.done(reason: "stop"))
        XCTAssertEqual(one.statusLine, "Done (1 step)")

        let none = ChatViewModel()
        none.beginUserTurn("hi")
        none.apply(.assistantDelta(text: "hello"))
        none.apply(.done(reason: "stop"))
        XCTAssertEqual(none.statusLine, "Done", "a plain answer reports no steps")
    }

    func testStatusLineWaitingOnApproval() {
        let m = ChatViewModel()
        m.beginUserTurn("run something")
        m.apply(.approvalRequest(callId: "c9", name: "bash", args: #"{"command":"rm -rf /tmp/x"}"#))
        XCTAssertEqual(m.statusLine, "Waiting for your approval")
    }

    // MARK: Rich approval detail

    func testApprovalDetailForCommandShowsExactCommand() {
        let d = ChatViewModel.approvalDetail(name: "bash", argsJSON: #"{"command":"rm -rf build"}"#)
        XCTAssertEqual(d.kind, .command)
        XCTAssertEqual(d.title, "Run command")
        XCTAssertEqual(d.command, "rm -rf build", "the exact command is surfaced before approve")
    }

    func testApprovalDetailForEditShowsFileAndDiff() {
        let d = ChatViewModel.approvalDetail(
            name: "edit",
            argsJSON: #"{"file_path":"/repo/src/bar.rs","old_string":"let x = 1","new_string":"let x = 2"}"#)
        XCTAssertEqual(d.kind, .fileEdit)
        XCTAssertEqual(d.title, "Edit bar.rs")
        XCTAssertEqual(d.filePath, "/repo/src/bar.rs")
        XCTAssertEqual(d.oldText, "let x = 1")
        XCTAssertEqual(d.newText, "let x = 2")
    }

    func testApprovalDetailForWriteShowsContent() {
        let d = ChatViewModel.approvalDetail(
            name: "write", argsJSON: #"{"file_path":"note.md","content":"hello world"}"#)
        XCTAssertEqual(d.kind, .fileWrite)
        XCTAssertEqual(d.title, "Write note.md")
        XCTAssertEqual(d.newText, "hello world")
    }

    func testApprovalDetailGenericFallsBackToArgs() {
        let d = ChatViewModel.approvalDetail(
            name: "lore_search", argsJSON: #"{"query":"meeting notes"}"#)
        XCTAssertEqual(d.kind, .generic)
        XCTAssertEqual(d.title, "Run lore_search")
        XCTAssertEqual(d.body, "query: meeting notes")
    }

    // MARK: The approval keeps the turn suspended (no auto-run)

    func testApprovalRequestSuspendsTurn() {
        let m = ChatViewModel()
        m.beginUserTurn("go")
        m.apply(.approvalRequest(callId: "c9", name: "bash", args: #"{"command":"ls"}"#))
        guard case .awaitingApproval(let callId, let name, _) = m.turnState else {
            return XCTFail("expected awaitingApproval, got \(m.turnState)")
        }
        XCTAssertEqual(callId, "c9")
        XCTAssertEqual(name, "bash")
    }
}
