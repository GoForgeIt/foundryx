import XCTest
import Foundation
import FoundryXKit

/// Run artifacts on the chat stream (features/chat-answer-and-artifacts.feature,
/// track 20260713T1500): the door announces files the agent actually wrote as
/// `artifact` SSE events; the view model collects them per turn; the fetch path
/// is the door's bearer-gated run-artifact route.
final class RunArtifactStreamTests: XCTestCase {

    // The wire event parses into a typed case (old apps fell into .other — the
    // graceful-degradation property this replaces deliberately).
    func testArtifactEventParses() {
        let e = DoorEvent.parse(#"{"type":"artifact","name":"report.md","mime":"text/markdown"}"#)
        XCTAssertEqual(e, .artifact(name: "report.md", mime: "text/markdown"))
    }

    // Scenario: a file the agent wrote arrives as an artifact in the chat
    @MainActor
    func testTurnCollectsAnnouncedArtifacts() {
        let vm = ChatViewModel()
        vm.beginUserTurn("write me a report")
        vm.apply(.artifact(name: "report.md", mime: "text/markdown"))
        vm.apply(.done(reason: "end"))
        XCTAssertEqual(vm.artifacts.map(\.name), ["report.md"])
        XCTAssertEqual(vm.artifacts.first?.mime, "text/markdown")
    }

    // Scenario: artifacts belong to their turn
    @MainActor
    func testNextTurnClearsArtifacts() {
        let vm = ChatViewModel()
        vm.beginUserTurn("write me a report")
        vm.apply(.artifact(name: "report.md", mime: "text/markdown"))
        vm.apply(.done(reason: "end"))
        vm.beginUserTurn("thanks")
        XCTAssertTrue(vm.artifacts.isEmpty, "an artifact offer belongs to its turn")
    }

    // Scenario: the same artifact announced twice is offered once
    @MainActor
    func testDuplicateAnnouncementsDedupe() {
        let vm = ChatViewModel()
        vm.beginUserTurn("write it")
        vm.apply(.artifact(name: "report.md", mime: "text/markdown"))
        vm.apply(.artifact(name: "report.md", mime: "text/markdown"))
        XCTAssertEqual(vm.artifacts.count, 1)
    }

    // And opening it fetches the file from my desktop: the route contract, one
    // place (the door serves GET /foundryx/run-artifact/<name>).
    func testArtifactRoutePath() {
        XCTAssertEqual(RunArtifactRoute.path(name: "report.md"),
                       "/foundryx/run-artifact/report.md")
    }
}
